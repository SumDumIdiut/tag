extends Node
class_name UILayoutUpdater

# Checks the relay's UI-layout manifest (see relay-server/server.js's
# "HTTP: ui-layout" section, published by the website's UI Editor) against
# whatever this client last downloaded, and silently applies anything newer
# -- unlike GameAssetUpdater's own check-then-prompt-the-player shape (see
# GameAssetUpdatePrompt), a button's position/size/text override is treated
# as part of the base game's own default look (same trust level as
# chrome/background art, just delivered differently), not optional content
# worth a "Download now?" interruption. One flat JSON manifest (not per-key
# files -- the whole payload is a handful of small numbers/strings per
# element, nothing like an image), so there's no separate per-key download
# step the way MULTI_KEY_CATEGORIES needs for images.

const MANIFEST_URL := "https://codecade.co.za/tag/api/ui-layout/manifest"
const VERSION_PATH := "user://ui_layout_version.json"

var _pending_overrides: Dictionary = {}
var _pending_version: int = 0

## Fetches the manifest and, if its version is newer than what's already
## saved locally, applies it immediately (writes UILayoutOverrides'
## OVERRIDES_PATH + records the new version) -- fully self-contained, no
## separate "apply" step for a caller to remember, since (unlike
## GameAssetUpdater) nothing here is ever conditional on player confirmation.
func check_and_apply() -> void:
	var req := HTTPRequest.new()
	req.timeout = 10.0 # same reasoning as CustomLevelCache's own explicit timeout -- an unreachable relay must never hang this forever
	add_child(req)
	req.request_completed.connect(_on_manifest_completed.bind(req))
	var err := req.request(MANIFEST_URL, ["User-Agent: TagUILayoutUpdater"])
	if err != OK:
		req.queue_free()

func _on_manifest_completed(result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray, req: HTTPRequest) -> void:
	req.queue_free()
	if result != HTTPRequest.RESULT_SUCCESS or response_code != 200:
		return
	var parsed = JSON.parse_string(body.get_string_from_utf8())
	if typeof(parsed) != TYPE_DICTIONARY:
		return
	var remote_version := int(parsed.get("version", 0))
	if remote_version <= _load_local_version():
		return
	var overrides = parsed.get("overrides", {})
	if typeof(overrides) != TYPE_DICTIONARY:
		return
	var f := FileAccess.open(UILayoutOverrides.OVERRIDES_PATH, FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(overrides))
		f.close()
		_save_local_version(remote_version)

func _load_local_version() -> int:
	if not FileAccess.file_exists(VERSION_PATH):
		return 0
	var f := FileAccess.open(VERSION_PATH, FileAccess.READ)
	if f == null:
		return 0
	var parsed = JSON.parse_string(f.get_as_text())
	return int(parsed) if (typeof(parsed) == TYPE_FLOAT or typeof(parsed) == TYPE_INT) else 0

func _save_local_version(v: int) -> void:
	var f := FileAccess.open(VERSION_PATH, FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(v))
