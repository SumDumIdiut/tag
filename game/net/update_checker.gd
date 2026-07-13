extends Node
class_name UpdateChecker

# Checks the tag repo's latest GitHub Release against this build's own
# stamped version (see build_version.gd) and reports whether a newer build
# exists, plus the direct download URL for whichever asset this instance
# was told to care about ("Tag.exe" or "TagArtTool.exe" -- the same release
# always carries both, see .github/workflows/build.yml). Never fires "update
# available" for a local/dev build (BUILD_NUMBER == 0, never stamped outside
# CI) -- there's no sane "newer" comparison to make against that.

signal check_completed(result: Dictionary) # {available: bool, version: int, download_url: String}

const RELEASES_URL := "https://api.github.com/repos/SumDumIdiut/tag/releases/latest"

var _asset_filename: String

func _init(asset_filename: String) -> void:
	_asset_filename = asset_filename

func check() -> void:
	var req := HTTPRequest.new()
	add_child(req)
	req.request_completed.connect(_on_completed.bind(req))
	# GitHub's API rejects requests with no User-Agent header.
	var err := req.request(RELEASES_URL, ["User-Agent: TagUpdateChecker"])
	if err != OK:
		req.queue_free()
		check_completed.emit({"available": false})

func _on_completed(result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray, req: HTTPRequest) -> void:
	req.queue_free()
	if BuildVersion.BUILD_NUMBER <= 0:
		check_completed.emit({"available": false})
		return
	if result != HTTPRequest.RESULT_SUCCESS or response_code != 200:
		check_completed.emit({"available": false})
		return
	var parsed = JSON.parse_string(body.get_string_from_utf8())
	if typeof(parsed) != TYPE_DICTIONARY or not parsed.has("tag_name"):
		check_completed.emit({"available": false})
		return
	var tag: String = parsed.tag_name
	if not tag.begins_with("build-") or not tag.substr(6).is_valid_int():
		check_completed.emit({"available": false})
		return
	var remote_version := int(tag.substr(6))
	if remote_version <= BuildVersion.BUILD_NUMBER:
		check_completed.emit({"available": false})
		return
	var download_url := ""
	for asset in parsed.get("assets", []):
		if typeof(asset) == TYPE_DICTIONARY and asset.get("name", "") == _asset_filename:
			download_url = asset.get("browser_download_url", "")
			break
	if download_url.is_empty():
		check_completed.emit({"available": false})
		return
	check_completed.emit({"available": true, "version": remote_version, "download_url": download_url})
