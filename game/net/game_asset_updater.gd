extends Node
class_name GameAssetUpdater

# Checks the relay's built-in-art manifest (icons/chrome -- see
# relay-server/server.js's "HTTP: game assets" section, and art_tool.gd's
# Export Edits button, the one thing that publishes to it) against whatever
# this client last downloaded, and offers to fetch anything newer. Distinct
# from UpdateChecker/UpdatePrompt (whole-binary updates, requires a
# relaunch): this only ever moves a handful of small PNGs and applies them
# live, no restart needed -- see GameAssetOverrides for where each category
# actually gets read back at render time.

signal check_completed(result: Dictionary) # {available: bool, categories: Array, manifest: Dictionary}

const Categories := preload("res://net/game_asset_categories.gd")

const MANIFEST_URL := "https://codecade.co.za/tag/api/game-assets/manifest"
const DOWNLOAD_BASE := "https://codecade.co.za/tag/api/game-assets"
const VERSIONS_PATH := "user://game_asset_versions.json"

# Multi-key categories publish as one file per key (like mode_buttons/
# backgrounds/online_bars) rather than a single shared atlas image (like
# icons/tiles) -- this maps each such category to its key list and override-
# path function so _download_category doesn't need one hand-written branch
# per category.
#
# static var + _static_init(), NOT const: a dict literal containing
# cross-class static-method references (GameAssetOverrides.xxx_path) isn't
# actually foldable as a GDScript constant expression -- confirmed via a
# real repro (isolated single-entry dict, same error) that this has been
# silently broken since this pattern was first introduced, cascading into
# main_menu.gd failing to compile at all (its preload of this script fails)
# the moment anything actually forces this script to reload/recompile,
# which none of this session's prior verification passes happened to
# trigger. _static_init() runs as real code, not constant-folding, so the
# same cross-class references that fail as a const work here unchanged.
static var MULTI_KEY_CATEGORIES: Dictionary = {}

static func _static_init() -> void:
	MULTI_KEY_CATEGORIES = {
		"chrome": [Categories.CHROME_KEYS, GameAssetOverrides.chrome_override_path],
		"platform": [Categories.PLATFORM_KEYS, GameAssetOverrides.platform_override_path],
		"playlist_thumbnails": [Categories.PLAYLIST_THUMBNAIL_KEYS, GameAssetOverrides.playlist_thumbnail_override_path],
		"backgrounds": [Categories.BACKGROUND_KEYS, GameAssetOverrides.background_override_path],
		"button_art": [Categories.BUTTON_ART_KEYS, GameAssetOverrides.button_art_override_path],
	}

func check() -> void:
	var req := HTTPRequest.new()
	add_child(req)
	req.request_completed.connect(_on_manifest_completed.bind(req))
	var err := req.request(MANIFEST_URL, ["User-Agent: TagGameAssetUpdater"])
	if err != OK:
		req.queue_free()
		check_completed.emit({"available": false})

func _on_manifest_completed(result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray, req: HTTPRequest) -> void:
	req.queue_free()
	if result != HTTPRequest.RESULT_SUCCESS or response_code != 200:
		check_completed.emit({"available": false})
		return
	var parsed = JSON.parse_string(body.get_string_from_utf8())
	if typeof(parsed) != TYPE_DICTIONARY:
		check_completed.emit({"available": false})
		return
	var local := _load_local_versions()
	var stale: Array = []
	for category in parsed.keys():
		var entry = parsed[category]
		if typeof(entry) != TYPE_DICTIONARY:
			continue
		var remote_version := int(entry.get("version", 0))
		var local_version := int(local.get(category, 0))
		if remote_version > local_version:
			stale.append(category)
	if stale.is_empty():
		check_completed.emit({"available": false})
	else:
		check_completed.emit({"available": true, "categories": stale, "manifest": parsed})

## Downloads and writes every category in `categories` to its
## GameAssetOverrides path, then records the new local version so the next
## check() doesn't re-offer the same update. Returns true only if every
## category succeeded (a category with nothing actually published for any
## of its slots -- e.g. mode_buttons before anyone's painted a single mode
## -- still counts as success: there's nothing there to fail to get).
func download_and_apply(categories: Array, manifest: Dictionary) -> bool:
	var local := _load_local_versions()
	var all_ok := true
	for category in categories:
		var ok: bool = await _download_category(category)
		if ok:
			var entry = manifest.get(category, {})
			local[category] = int(entry.get("version", 0)) if typeof(entry) == TYPE_DICTIONARY else 0
		else:
			all_ok = false
	_save_local_versions(local)
	return all_ok

func _download_category(category: String) -> bool:
	if MULTI_KEY_CATEGORIES.has(category):
		var keys: Array = MULTI_KEY_CATEGORIES[category][0]
		var path_fn: Callable = MULTI_KEY_CATEGORIES[category][1]
		var any_ok := false
		for key in keys:
			var ok: bool = await _download_file(
				"%s/%s/%s/download" % [DOWNLOAD_BASE, category, key], path_fn.call(key)
			)
			any_ok = any_ok or ok
		return any_ok
	return await _download_file("%s/%s/download" % [DOWNLOAD_BASE, category], "user://game_assets/%s.png" % category)

## A 404 here just means "nothing published for this slot yet" (e.g. one
## mode button never painted) -- not a hard failure for the whole batch,
## which is why the caller treats a false return as "skip this one," not
## "abort everything."
func _download_file(url: String, dest_path: String) -> bool:
	var req := HTTPRequest.new()
	add_child(req)
	var err := req.request(url)
	if err != OK:
		req.queue_free()
		return false
	var response: Array = await req.request_completed
	req.queue_free()
	if response[1] != 200:
		return false
	var bytes: PackedByteArray = response[3]
	if bytes.is_empty():
		return false
	DirAccess.make_dir_recursive_absolute(dest_path.get_base_dir())
	var f := FileAccess.open(dest_path, FileAccess.WRITE)
	if not f:
		return false
	f.store_buffer(bytes)
	f.close()
	return true

func _load_local_versions() -> Dictionary:
	if not FileAccess.file_exists(VERSIONS_PATH):
		return {}
	var f := FileAccess.open(VERSIONS_PATH, FileAccess.READ)
	if not f:
		return {}
	var parsed = JSON.parse_string(f.get_as_text())
	return parsed if typeof(parsed) == TYPE_DICTIONARY else {}

func _save_local_versions(versions: Dictionary) -> void:
	var f := FileAccess.open(VERSIONS_PATH, FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(versions))
