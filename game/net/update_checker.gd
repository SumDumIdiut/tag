extends Node
class_name UpdateChecker

# Checks the tag repo's GitHub Releases against this build's own stamped
# version (see build_version.gd) and reports whether a newer build exists,
# plus the direct download URL for whichever asset this instance was told
# to care about ("TagSetup.exe", the Inno Setup installer -- see
# installer/tag.iss -- or "TagArtTool.exe"; the same release always carries
# both, see .github/workflows/build.yml). Never fires "update available"
# for a local/dev build (BUILD_NUMBER == 0, never stamped outside CI) --
# there's no sane "newer" comparison to make against that.
#
# Scans /releases (plural, up to RELEASES_PAGE_SIZE most recent) and picks
# the highest "build-<N>" tag itself, rather than trusting GitHub's own
# /releases/latest -- that endpoint is "most recently created, non-draft,
# non-prerelease," which is usually the newest CI build but isn't
# guaranteed to be if anything else ever creates a release (a manual test,
# a docs-only tag) that doesn't match this project's own build-<N>
# convention; a release like that would silently outrank the real latest
# build and make every check underneath it report "no update" even years
# after a real one shipped, without a page size this small.
#
# Retries a few times on a transient failure (network hiccup, GitHub rate-
# limiting an unauthenticated request) before giving up -- previously a
# single failed request for any reason silently reported "no update" for
# the rest of the session (see main_menu.gd's own once-per-launch gate),
# indistinguishable from a real, successful "you're already current" check.
# A clean 200 response that just resolves to "nothing newer" is NOT
# retried -- that's a correct, final answer, not a failure.

signal check_completed(result: Dictionary) # {available: bool, version: int, download_url: String}

const RELEASES_PAGE_SIZE := 20
const RELEASES_URL := "https://api.github.com/repos/SumDumIdiut/tag/releases?per_page=%d" % RELEASES_PAGE_SIZE
const MAX_ATTEMPTS := 3
const RETRY_DELAY_SEC := 2.0

var _asset_filename: String
var _attempt := 0

func _init(asset_filename: String) -> void:
	_asset_filename = asset_filename

func check() -> void:
	if BuildVersion.BUILD_NUMBER <= 0:
		check_completed.emit({"available": false})
		return
	_attempt = 0
	_try_check()

func _try_check() -> void:
	_attempt += 1
	var req := HTTPRequest.new()
	add_child(req)
	req.request_completed.connect(_on_completed.bind(req))
	# GitHub's API rejects requests with no User-Agent header.
	var err := req.request(RELEASES_URL, ["User-Agent: TagUpdateChecker"])
	if err != OK:
		req.queue_free()
		_retry_or_give_up()

func _on_completed(result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray, req: HTTPRequest) -> void:
	req.queue_free()
	if result != HTTPRequest.RESULT_SUCCESS or response_code != 200:
		_retry_or_give_up()
		return
	var parsed = JSON.parse_string(body.get_string_from_utf8())
	if typeof(parsed) != TYPE_ARRAY:
		_retry_or_give_up()
		return
	var best_version := -1
	var best_release: Dictionary = {}
	for release in parsed:
		if typeof(release) != TYPE_DICTIONARY:
			continue
		var tag: String = str(release.get("tag_name", ""))
		if not tag.begins_with("build-") or not tag.substr(6).is_valid_int():
			continue
		var v := int(tag.substr(6))
		if v > best_version:
			best_version = v
			best_release = release
	if best_release.is_empty() or best_version <= BuildVersion.BUILD_NUMBER:
		check_completed.emit({"available": false})
		return
	var download_url := ""
	for asset in best_release.get("assets", []):
		if typeof(asset) == TYPE_DICTIONARY and asset.get("name", "") == _asset_filename:
			download_url = asset.get("browser_download_url", "")
			break
	if download_url.is_empty():
		check_completed.emit({"available": false})
		return
	check_completed.emit({"available": true, "version": best_version, "download_url": download_url})

func _retry_or_give_up() -> void:
	if _attempt < MAX_ATTEMPTS:
		get_tree().create_timer(RETRY_DELAY_SEC).timeout.connect(_try_check)
	else:
		check_completed.emit({"available": false})
