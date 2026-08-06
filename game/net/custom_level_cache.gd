extends Node

# Fetches live-published custom level data and caches it in memory --
# map_vote_view.gd (the vote tile list), server_match.gd (authoritative
# arena), and net_game.gd/game.gd (rendering) all read from this instead of
# each doing their own per-use HTTP fetch.
#
# Persisted to disk under <exe folder>/maps/, not just held in memory --
# every already-downloaded level loads instantly from there at startup, no
# network wait and no "N maps available" prompt for content already on
# disk. check() then only compares the live catalog against what's already
# saved locally, so main_menu.gd's prompt (see MapsUpdatePrompt) only ever
# shows up for genuinely NEW maps, not the same ones every single launch.
# Same two-step shape as GameAssetUpdater/GameAssetUpdatePrompt otherwise:
# check() is cheap (just the catalog list), download_all() (Download
# pressed) fetches and saves whatever's actually new. Declining
# (skip_download(), Skip pressed) still resolves is_ready so nothing
# downstream waits forever.
#
# Runs identically in both a real player's client process and a dedicated
# server process (server_main.gd) -- both boot the same autoload list (see
# project.godot), and both write to the maps/ folder next to their own exe
# (a locally-spawned server is the same installed exe as the client that
# spawned it, so they already share one). A server process has no menu/
# prompt to click through, so _on_catalog_response() below downloads
# automatically for it (detected via DisplayServer.get_name() == "headless")
# rather than sitting on a check nobody will ever answer.

signal check_completed(available: bool, count: int)
signal levels_ready

const CATALOG_URL := "https://codecade.co.za/tag/api/levels/catalog"
const LEVEL_DATA_URL := "https://codecade.co.za/tag/api/levels/data/%s"
const LEVEL_TEXTURE_URL := "https://codecade.co.za/tag/api/levels/data/%s/texture/%d"
const LEVEL_BACKGROUND_URL := "https://codecade.co.za/tag/api/levels/data/%s/background"
const LEVEL_THUMBNAIL_URL := "https://codecade.co.za/tag/api/levels/data/%s/thumbnail"
const LevelData := preload("res://levels/level_data.gd")

const MAPS_DIR_NAME := "maps"

# Generous compared to map_vote_view.gd's own MAX_CUSTOM_LEVELS_IN_VOTE
# (what it actually displays) -- caching costs nothing but disk space and a
# handful of one-time fetches, so there's no reason to throw levels away
# here just because the vote UI only ever shows the newest handful.
const MAX_CACHED_LEVELS := 40
# A relay that's fully unreachable (offline, DNS hiccup, tunnel down) used
# to hang every HTTPRequest here forever -- Godot's own default timeout is
# 0 (never), so with no relay to answer, request_completed simply never
# fired and every consumer waiting on is_ready/levels_ready waited with it,
# confirmed live as "the maps updater hangs." Every request below sets this
# explicitly so a genuinely dead relay fails within a bounded time instead.
const REQUEST_TIMEOUT_SEC := 10.0

var is_ready := false
var check_done := false # true once check() itself has resolved -- distinct from is_ready, which also needs download_all()/skip_download()
var catalog_count := 0 # NEW-or-EDITED (not-yet-cached, or cached but stale) levels found by the last check(), even if never downloaded
# Guards against a real double-download: a headless process auto-downloads
# (see _on_catalog_response()) and a UI Download press can both call
# download_all() -- is_ready alone doesn't catch the case where the first
# call is still in flight when the second happens.
var _downloading := false
var _pending_entries: Array = [] # catalog entries NOT already cached locally, consumed by download_all()
var _levels := {} # id -> {name: String, created_at: float, updated_at: float, data: Dictionary, textures: Array[Texture2D], background: Texture2D, thumbnail: Texture2D}

func _ready() -> void:
	_load_cached_from_disk()
	if not _levels.is_empty():
		# Already have real content on disk -- usable immediately, no reason
		# to make Local/the vote screen wait on a network round trip that
		# only matters for finding anything NEWER than this.
		_finish_loading()
	check()

func _maps_dir() -> String:
	return OS.get_executable_path().get_base_dir().path_join(MAPS_DIR_NAME)

## Loads every previously-downloaded level straight off disk -- synchronous
## (a handful of small JSON/PNG files, no network involved) so it's already
## done by the time anything else in _ready() runs.
func _load_cached_from_disk() -> void:
	var dir := DirAccess.open(_maps_dir())
	if dir == null:
		return # nothing downloaded yet -- not an error, just a fresh install
	dir.list_dir_begin()
	var file_name := dir.get_next()
	while file_name != "":
		if file_name.ends_with(".json"):
			_load_one_cached_level(file_name.get_basename())
		file_name = dir.get_next()
	dir.list_dir_end()

func _load_one_cached_level(id: String) -> void:
	var meta_path := _maps_dir().path_join(id + ".json")
	var f := FileAccess.open(meta_path, FileAccess.READ)
	if f == null:
		return
	var parsed = JSON.parse_string(f.get_as_text())
	if typeof(parsed) != TYPE_DICTIONARY:
		return
	var data = parsed.get("data")
	if typeof(data) != TYPE_DICTIONARY or not LevelData.is_valid(data):
		push_warning("CustomLevelCache: cached level %s on disk is invalid, ignoring" % id)
		return
	var texture_count := int(parsed.get("textureCount", 0))
	var textures: Array = []
	textures.resize(texture_count)
	for i in texture_count:
		var tex_path := _maps_dir().path_join("%s.tex%d.png" % [id, i])
		var bytes := FileAccess.get_file_as_bytes(tex_path)
		if bytes.is_empty():
			continue
		var img := Image.new()
		if img.load_png_from_buffer(bytes) == OK:
			textures[i] = ImageTexture.create_from_image(img)
	var created_at := float(parsed.get("createdAt", 0))
	_levels[id] = {
		"name": String(parsed.get("name", id)),
		"created_at": created_at,
		# Falls back to created_at (not 0) for a level cached before updatedAt
		# existed -- matches _on_catalog_response()'s own fallback for a
		# catalog entry with no updatedAt yet, so an old, never-edited,
		# already-cached level compares equal (not "newer") on both sides
		# instead of spuriously looking stale and re-downloading on every launch.
		"updated_at": float(parsed.get("updatedAt", created_at)),
		"data": data,
		"textures": textures,
		"background": _load_cached_image(_maps_dir().path_join(id + ".bg.png")),
		"thumbnail": _load_cached_image(_maps_dir().path_join(id + ".thumb.png")),
	}

## Loads a single optional PNG (level background/thumbnail) from disk --
## null if the file doesn't exist (this level never had one) or fails to
## decode, same graceful "cosmetic content, degrade quietly" handling as a
## placement texture.
func _load_cached_image(path: String) -> Texture2D:
	var bytes := FileAccess.get_file_as_bytes(path)
	if bytes.is_empty():
		return null
	var img := Image.new()
	if img.load_png_from_buffer(bytes) != OK:
		return null
	return ImageTexture.create_from_image(img)

## Writes one level's data + texture bytes to <maps>/<id>.json and
## <maps>/<id>.tex<N>.png -- the same shape _load_one_cached_level() above
## reads back. `updated_at` is stored alongside `created_at` purely so
## _on_catalog_response() can later tell "still the same content" from "this
## id got edited since we last cached it" without re-fetching -- see that
## function's own comment. `texture_bytes` is the RAW PNG bytes (not the decoded
## Texture2D already sitting in _levels) since that's what needs to survive
## to next launch. `background_bytes`/`thumbnail_bytes` are likewise raw PNG
## bytes, empty if this level has none -- written to <id>.bg.png/
## <id>.thumb.png only when non-empty.
##
## Also cleans up anything stale left over from a PREVIOUS save of this same
## id (a re-download triggered by editing a level, see _on_catalog_response()'s
## updated_at comparison) -- a texture index beyond the new count, or a
## background/thumbnail this save no longer has, would otherwise linger on
## disk and get loaded right back in by _load_one_cached_level() next launch,
## silently reviving content the edit actually removed. Mirrors server.js's
## own validateAndStoreLevelFiles() doing the identical cleanup server-side.
func _save_level_to_disk(id: String, lvl_name: String, created_at: float, updated_at: float, data: Dictionary, texture_bytes: Array, background_bytes: PackedByteArray = PackedByteArray(), thumbnail_bytes: PackedByteArray = PackedByteArray()) -> void:
	var dir_path := _maps_dir()
	var err := DirAccess.make_dir_recursive_absolute(dir_path)
	if err != OK and err != ERR_ALREADY_EXISTS:
		push_warning("CustomLevelCache: could not create maps folder (%s), level %s won't persist to disk" % [err, id])
		return
	var meta := {"name": lvl_name, "createdAt": created_at, "updatedAt": updated_at, "textureCount": texture_bytes.size(), "data": data}
	var f := FileAccess.open(dir_path.path_join(id + ".json"), FileAccess.WRITE)
	if f == null:
		push_warning("CustomLevelCache: could not save level %s to disk" % id)
		return
	f.store_string(JSON.stringify(meta))
	f.close()
	for i in texture_bytes.size():
		var bytes: PackedByteArray = texture_bytes[i]
		if bytes.is_empty():
			continue
		var tf := FileAccess.open(dir_path.path_join("%s.tex%d.png" % [id, i]), FileAccess.WRITE)
		if tf:
			tf.store_buffer(bytes)
			tf.close()
	var stale_index := texture_bytes.size()
	while FileAccess.file_exists(dir_path.path_join("%s.tex%d.png" % [id, stale_index])):
		DirAccess.remove_absolute(dir_path.path_join("%s.tex%d.png" % [id, stale_index]))
		stale_index += 1
	var bg_path := dir_path.path_join(id + ".bg.png")
	if not background_bytes.is_empty():
		var bf := FileAccess.open(bg_path, FileAccess.WRITE)
		if bf:
			bf.store_buffer(background_bytes)
			bf.close()
	elif FileAccess.file_exists(bg_path):
		DirAccess.remove_absolute(bg_path)
	var thumb_path := dir_path.path_join(id + ".thumb.png")
	if not thumbnail_bytes.is_empty():
		var tf2 := FileAccess.open(thumb_path, FileAccess.WRITE)
		if tf2:
			tf2.store_buffer(thumbnail_bytes)
			tf2.close()
	elif FileAccess.file_exists(thumb_path):
		DirAccess.remove_absolute(thumb_path)

## Deletes a locally-cached level no longer present in the live catalog
## (see _on_catalog_response()) -- keeps the maps/ folder in sync with the
## relay instead of accumulating levels someone's since taken down forever.
func _delete_cached_from_disk(id: String) -> void:
	var dir_path := _maps_dir()
	DirAccess.remove_absolute(dir_path.path_join(id + ".json"))
	DirAccess.remove_absolute(dir_path.path_join(id + ".bg.png"))
	DirAccess.remove_absolute(dir_path.path_join(id + ".thumb.png"))
	var i := 0
	while FileAccess.file_exists(dir_path.path_join("%s.tex%d.png" % [id, i])):
		DirAccess.remove_absolute(dir_path.path_join("%s.tex%d.png" % [id, i]))
		i += 1

## {id, name, created_at}, newest first -- exactly what map_vote_view.gd
## needs to build its vote tiles, with zero network wait since this already
## happened before the vote screen could ever be reached.
func level_entries_newest_first() -> Array[Dictionary]:
	var entries: Array[Dictionary] = []
	for id in _levels:
		entries.append({"id": id, "name": _levels[id].name, "created_at": _levels[id].created_at})
	entries.sort_custom(func(a, b): return a.created_at > b.created_at)
	return entries

## The validated tiles/spawn_points/platforms/placements dict for a given
## id, or {} if it was never successfully cached (unknown id, download
## skipped/failed, or it failed validation) -- every caller already has its
## own built-in-arena fallback for exactly this case.
func get_level_data(id: String) -> Dictionary:
	return _levels.get(id, {}).get("data", {})

## Index-matched to get_level_data(id)'s own "placements".textureIndex --
## an entry is null if that specific texture failed to fetch/decode (still
## graceful: LevelData.build_arena_from_data() just skips a null texture's
## placement), or the whole array is empty if this id was never cached at
## all. Pass straight through to build_arena_from_data()'s `textures` param.
func get_level_textures(id: String) -> Array:
	return _levels.get(id, {}).get("textures", [])

## The level's uploaded backdrop, or null if it never had one (or hasn't
## loaded yet) -- pass straight through to build_arena_from_data()'s
## `background_texture` param.
func get_level_background(id: String) -> Texture2D:
	return _levels.get(id, {}).get("background", null)

## The level's uploaded picker thumbnail, or null if it never had one (or
## hasn't loaded yet) -- local_menu.gd/map_vote_view.gd fall back to a
## generic icon when this is null, same graceful degradation as every other
## optional custom-level asset here.
func get_level_thumbnail(id: String) -> Texture2D:
	return _levels.get(id, {}).get("thumbnail", null)

## Cheap -- just the catalog list (names/ids/counts), not any level's real
## data. Always resolves check_completed exactly once, success or failure;
## a failure here also means there's nothing new to download, so it goes
## straight to _finish_loading() (a no-op if disk cache already resolved it)
## rather than leaving is_ready pending on a download step nothing will
## ever trigger.
func check() -> void:
	var req := HTTPRequest.new()
	req.timeout = REQUEST_TIMEOUT_SEC
	add_child(req)
	req.request_completed.connect(func(_result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray):
		req.queue_free()
		_on_catalog_response(response_code, body)
	)
	var err := req.request(CATALOG_URL)
	if err != OK:
		push_warning("CustomLevelCache: catalog request() failed to start (%s)" % err)
		req.queue_free()
		_on_catalog_response(-1, PackedByteArray())

func _on_catalog_response(response_code: int, body: PackedByteArray) -> void:
	check_done = true
	if response_code != 200:
		push_warning("CustomLevelCache: catalog check failed (HTTP %d)" % response_code)
		check_completed.emit(false, 0)
		_finish_loading()
		return
	var parsed = JSON.parse_string(body.get_string_from_utf8())
	if typeof(parsed) != TYPE_ARRAY:
		push_warning("CustomLevelCache: catalog returned non-array data")
		check_completed.emit(false, 0)
		_finish_loading()
		return
	var entries: Array = []
	var live_ids := {}
	for entry in parsed:
		if typeof(entry) != TYPE_DICTIONARY or not entry.has("id") or not entry.has("name"):
			continue
		entries.append(entry)
		live_ids[String(entry.id)] = true
	entries.sort_custom(func(a, b): return float(a.get("createdAt", 0)) > float(b.get("createdAt", 0)))
	entries = entries.slice(0, MAX_CACHED_LEVELS)

	# Levels published since removed (see relay-server/data/catalog.json)
	# don't just stay cached forever -- prune them from disk and memory so
	# a deleted map stops showing up in Local/the vote screen without
	# needing a manual cache wipe.
	for id in _levels.keys().duplicate():
		if not live_ids.has(id):
			_levels.erase(id)
			_delete_cached_from_disk(id)

	# Not-yet-cached levels count as "new," and so does a level that IS
	# cached but whose live updatedAt has moved past what's on disk -- i.e.
	# someone edited it (see server.js's /update route and level-editor.
	# html's loadLevelForEdit()) since this client last downloaded it. Both
	# cases go through the exact same download_all() path, which always
	# overwrites _levels[id]/disk unconditionally regardless of whether the
	# id already existed -- so "new" here really means "(re)download," not
	# strictly "never seen before." A level with no updatedAt in the catalog
	# yet (published before this existed) falls back to its own createdAt,
	# matching _load_one_cached_level()'s identical fallback for the cached
	# side, so neither an old catalog entry nor an old cached copy looks
	# spuriously stale against the other.
	var new_entries: Array = []
	for entry in entries:
		var id := String(entry.id)
		if not _levels.has(id):
			new_entries.append(entry)
			continue
		var catalog_updated_at := float(entry.get("updatedAt", entry.get("createdAt", 0)))
		var cached_updated_at := float(_levels[id].get("updated_at", 0))
		if catalog_updated_at > cached_updated_at:
			new_entries.append(entry)
	_pending_entries = new_entries
	catalog_count = new_entries.size()
	check_completed.emit(catalog_count > 0, catalog_count)
	if catalog_count == 0:
		_finish_loading()
	elif DisplayServer.get_name() == "headless":
		# A dedicated server (or a headless test client, see
		# tools/headless_client.gd) has no menu to click a Download
		# prompt on -- download automatically rather than leave a
		# check nobody will ever answer (see this file's own header).
		download_all()

## Fetches every candidate level's actual tile/spawn data (and, once that
## validates, its texture images -- see _fetch_level_textures()) in
## parallel, finishing (is_ready = true, levels_ready emitted) only once
## every one of them has fully resolved, success or failure -- a single
## slow/unreachable level must never hold up every other one indefinitely.
## Each one that validates gets saved to disk (see _save_level_to_disk())
## so it's instant on every future launch.
##
## Guards on `_pending_entries.is_empty()`, NOT `is_ready` -- those used to be
## equivalent (is_ready only ever became true once a check()/download cycle
## fully settled), but _ready()'s disk-cache fast path can now set is_ready
## true immediately at startup while a genuinely new-or-edited entry is still
## sitting unfetched in `_pending_entries` (see _on_catalog_response()'s own
## updatedAt comparison). Guarding on is_ready here used to make this a
## silent no-op for exactly that case -- confirmed live: an edited level's
## new thumbnail never reached an already-primed client because of this.
func download_all() -> void:
	if _downloading or _pending_entries.is_empty():
		return
	_downloading = true
	var entries := _pending_entries
	# 1-element Array, not a bare int -- GDScript lambdas capture an outer
	# local BY VALUE, so `remaining -= 1` inside a shared closure called
	# from multiple separate HTTPRequest completions would only ever mutate
	# that closure's own private copy, never actually reaching 0 with 2+
	# entries (confirmed as a real, previously-shipped bug in this exact
	# codebase -- see server_match.gd's _fill_ranked_stats() history: it
	# only worked with exactly 1 real player for the same reason). Array
	# *contents* mutate through the captured reference fine.
	var remaining := [entries.size()]
	var on_entry_done := func():
		remaining[0] -= 1
		if remaining[0] == 0:
			_finish_loading()
	for entry in entries:
		var id := String(entry.id)
		var lvl_name := String(entry.name)
		var created_at := float(entry.get("createdAt", 0))
		var updated_at := float(entry.get("updatedAt", created_at))
		var texture_count := int(entry.get("textureCount", 0))
		var has_background := bool(entry.get("hasBackground", false))
		var has_thumbnail := bool(entry.get("hasThumbnail", false))
		var req := HTTPRequest.new()
		req.timeout = REQUEST_TIMEOUT_SEC
		add_child(req)
		req.request_completed.connect(func(_result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray):
			req.queue_free()
			if response_code != 200:
				push_warning("CustomLevelCache: level %s data fetch failed (HTTP %d), skipping" % [id, response_code])
				on_entry_done.call()
				return
			var parsed = JSON.parse_string(body.get_string_from_utf8())
			if typeof(parsed) != TYPE_DICTIONARY or not LevelData.is_valid(parsed):
				push_warning("CustomLevelCache: level %s failed validation, skipping" % id)
				on_entry_done.call()
				return
			if texture_count <= 0 and not has_background and not has_thumbnail:
				_levels[id] = {"name": lvl_name, "created_at": created_at, "updated_at": updated_at, "data": parsed, "textures": [], "background": null, "thumbnail": null}
				_save_level_to_disk(id, lvl_name, created_at, updated_at, parsed, [])
				on_entry_done.call()
				return
			_fetch_level_assets(id, lvl_name, created_at, updated_at, parsed, texture_count, has_background, has_thumbnail, on_entry_done)
		)
		var err := req.request(LEVEL_DATA_URL % id)
		if err != OK:
			push_warning("CustomLevelCache: level %s request() failed to start (%s), skipping" % [id, err])
			req.queue_free()
			on_entry_done.call()

## For a caller that needs levels available (and up to date) regardless of
## whether the main-menu prompt was ever shown/answered (Local mode has no
## fallback content at all without them -- see local_menu.gd) -- guarantees
## a download attempt happens by calling download_all() directly instead of
## waiting on a prompt that might never appear (e.g. the player navigated
## past the main menu before check() even resolved). No `is_ready` guard
## here -- download_all() itself is already a cheap no-op once nothing is
## actually pending (see its own comment on why that check moved), so it's
## always safe/idempotent to call this, including when already ready.
func ensure_loaded() -> void:
	if check_done:
		download_all()
	else:
		check_completed.connect(func(_available: bool, _count: int): download_all(), CONNECT_ONE_SHOT)

## Declining the download prompt still has to resolve is_ready -- every
## downstream consumer (map_vote_view.gd/local_menu.gd) is already built to
## treat "zero cached levels" as a normal, non-broken empty state, so
## skipping just means that state applies this session instead of a
## genuinely-empty catalog. A no-op if already resolved.
func skip_download() -> void:
	if is_ready:
		return
	_finish_loading()

## Fetches this one level's texture images, plus its background/thumbnail if
## the catalog said it has them, all in parallel (a level publishes up to
## MAX_LEVEL_TEXTURES, currently 12 -- trivial to fetch all of them eagerly).
## Textures are pre-sized so out-of-order completions still land at the
## right textureIndex; anything that fails to fetch/decode just stays null
## rather than aborting the whole level (LevelData.build_arena_from_data()
## already treats a null texture/background as "skip it") -- its saved
## bytes stay empty too, _save_level_to_disk() already skips those.
##
## background_tex_box/thumbnail_tex_box/background_bytes_box/
## thumbnail_bytes_box are 1-element Arrays, not bare locals -- same
## capture-by-value reasoning as download_all()'s own `remaining` (see its
## comment): a plain `var background_tex: Texture2D` assigned to inside the
## request_completed closure below would only ever mutate that closure's own
## private copy, never visible to on_asset_done reading it afterward.
func _fetch_level_assets(id: String, lvl_name: String, created_at: float, updated_at: float, data: Dictionary, texture_count: int, has_background: bool, has_thumbnail: bool, on_done: Callable) -> void:
	var textures: Array = []
	var raw_bytes: Array = []
	textures.resize(texture_count)
	raw_bytes.resize(texture_count)
	var background_tex_box: Array = [null]
	var thumbnail_tex_box: Array = [null]
	var background_bytes_box: Array = [PackedByteArray()]
	var thumbnail_bytes_box: Array = [PackedByteArray()]
	var total := texture_count + int(has_background) + int(has_thumbnail)
	var remaining := [total] # see download_all()'s own comment on why this is an Array, not a bare int
	var on_asset_done := func():
		remaining[0] -= 1
		if remaining[0] == 0:
			_levels[id] = {
				"name": lvl_name, "created_at": created_at, "updated_at": updated_at, "data": data,
				"textures": textures, "background": background_tex_box[0], "thumbnail": thumbnail_tex_box[0],
			}
			_save_level_to_disk(id, lvl_name, created_at, updated_at, data, raw_bytes, background_bytes_box[0], thumbnail_bytes_box[0])
			on_done.call()
	for i in texture_count:
		var req := HTTPRequest.new()
		req.timeout = REQUEST_TIMEOUT_SEC
		add_child(req)
		req.request_completed.connect(func(_result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray):
			req.queue_free()
			if response_code == 200:
				var img := Image.new()
				if img.load_png_from_buffer(body) == OK:
					textures[i] = ImageTexture.create_from_image(img)
					raw_bytes[i] = body
				else:
					push_warning("CustomLevelCache: level %s texture %d failed to decode, skipping" % [id, i])
			else:
				push_warning("CustomLevelCache: level %s texture %d fetch failed (HTTP %d), skipping" % [id, i, response_code])
			on_asset_done.call()
		)
		var err := req.request(LEVEL_TEXTURE_URL % [id, i])
		if err != OK:
			push_warning("CustomLevelCache: level %s texture %d request() failed to start (%s), skipping" % [id, i, err])
			req.queue_free()
			on_asset_done.call()
	if has_background:
		_fetch_level_image(id, LEVEL_BACKGROUND_URL % id, "background", background_tex_box, background_bytes_box, on_asset_done)
	if has_thumbnail:
		_fetch_level_image(id, LEVEL_THUMBNAIL_URL % id, "thumbnail", thumbnail_tex_box, thumbnail_bytes_box, on_asset_done)

## Shared by the background/thumbnail fetches above -- both are a single
## optional PNG at their own URL, decoded into `tex_box[0]` and kept as raw
## bytes in `bytes_box[0]` for _save_level_to_disk(), same box-array
## reasoning as _fetch_level_assets()'s own doc comment.
func _fetch_level_image(id: String, url: String, kind: String, tex_box: Array, bytes_box: Array, on_done: Callable) -> void:
	var req := HTTPRequest.new()
	req.timeout = REQUEST_TIMEOUT_SEC
	add_child(req)
	req.request_completed.connect(func(_result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray):
		req.queue_free()
		if response_code == 200:
			var img := Image.new()
			if img.load_png_from_buffer(body) == OK:
				tex_box[0] = ImageTexture.create_from_image(img)
				bytes_box[0] = body
			else:
				push_warning("CustomLevelCache: level %s %s failed to decode, skipping" % [id, kind])
		else:
			push_warning("CustomLevelCache: level %s %s fetch failed (HTTP %d), skipping" % [id, kind, response_code])
		on_done.call()
	)
	var err := req.request(url)
	if err != OK:
		push_warning("CustomLevelCache: level %s %s request() failed to start (%s), skipping" % [id, kind, err])
		req.queue_free()
		on_done.call()

func _finish_loading() -> void:
	is_ready = true
	levels_ready.emit()
