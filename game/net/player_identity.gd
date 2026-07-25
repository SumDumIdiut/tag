extends Node

# Anonymous player identity -- the one thing that ever lives locally
# (there's no account/login system beyond an optional linked session, see
# login_screen.gd). Friends (the friend code itself), Ranked reporting,
# Progression, and Login all key off this id -- a standalone autoload since
# none of those systems have anything to do with cosmetics or any other
# single feature area.
#
# Session restore also lives here (not login_screen.gd) so it runs the
# instant the app boots (this is an autoload -- _ready() fires before any
# scene, including main_menu.tscn, does), not only when the player happens
# to open the Account screen. It used to live entirely in login_screen.gd's
# own _ready(), which only runs when that screen is actually opened -- every
# account-keyed feature (friends, party, display name, progression) silently
# stayed on this device's local id for the whole session unless the player
# specifically visited Account first. login_screen.gd now just reads
# logged_in_username/listens for account_restored instead of doing its own
# separate HTTP round-trip.

signal client_id_changed(new_id: String)
## Fired once a saved session token is confirmed valid server-side (either
## at boot, via _ready()'s restore, or right after a fresh login/register --
## see set_logged_in()). Never fired for "no session"/an expired or invalid
## token -- check logged_in_username directly for the current state instead
## of trying to infer "not logged in" from this signal's absence.
signal account_restored(username: String)

const CLIENT_ID_PATH := "user://client_id.txt"
const SESSION_TOKEN_PATH := "user://session_token.txt"
const AUTH_BASE := "https://codecade.co.za/tag/api/auth"

var client_id := ""
## "" means not logged in (or restore hasn't finished/failed) -- same
## always-check-the-value convention client_id itself already uses.
var logged_in_username := ""

func _ready() -> void:
	client_id = _load_or_create_client_id()
	_restore_session()

## Called by the login flow (see login_screen.gd) once an existing session is
## confirmed valid server-side and resolves to a different clientId than this
## device's own local one -- i.e. logging into an account whose progress
## actually lives under another device's id.
## A no-op if the account's clientId happens to already match this device's
## (e.g. this was the device that created the account in the first place).
func override_client_id(new_id: String) -> void:
	if new_id.is_empty() or new_id == client_id:
		return
	client_id = new_id
	client_id_changed.emit(new_id)

## This device's own local id, independent of whatever account may currently
## be overriding client_id -- used by the login flow to revert on logout.
func get_local_device_client_id() -> String:
	return _load_or_create_client_id()

## Shared by both a fresh login/register success and a restored session --
## both end up needing the exact same three side effects (adopt the
## account's clientId, remember the username, tell anyone listening).
func set_logged_in(username: String, account_client_id: String) -> void:
	override_client_id(account_client_id)
	logged_in_username = username
	GameSettings.save_username(username)
	account_restored.emit(username)

func save_token(token: String) -> void:
	var f := FileAccess.open(SESSION_TOKEN_PATH, FileAccess.WRITE)
	if f:
		f.store_string(token)

func log_out() -> void:
	logged_in_username = ""
	if FileAccess.file_exists(SESSION_TOKEN_PATH):
		DirAccess.remove_absolute(SESSION_TOKEN_PATH)
	override_client_id(get_local_device_client_id())

func _load_token() -> String:
	if not FileAccess.file_exists(SESSION_TOKEN_PATH):
		return ""
	var f := FileAccess.open(SESSION_TOKEN_PATH, FileAccess.READ)
	if not f:
		return ""
	return f.get_as_text().strip_edges()

## Silent on any failure (expired token, relay unreachable at boot, no token
## at all) -- session restore is a nice-to-have, never something that should
## block or show an error on the way to the main menu.
func _restore_session() -> void:
	var token := _load_token()
	if token.is_empty():
		return
	var req := HTTPRequest.new()
	add_child(req)
	req.request_completed.connect(func(_result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray):
		req.queue_free()
		if response_code != 200:
			return
		var parsed = JSON.parse_string(body.get_string_from_utf8())
		if typeof(parsed) != TYPE_DICTIONARY:
			return
		set_logged_in(str(parsed.get("username", "")), str(parsed.get("primaryClientId", "")))
	)
	req.request("%s/me" % AUTH_BASE, ["Authorization: Bearer %s" % token])

func _load_or_create_client_id() -> String:
	if FileAccess.file_exists(CLIENT_ID_PATH):
		var f := FileAccess.open(CLIENT_ID_PATH, FileAccess.READ)
		var existing := f.get_as_text().strip_edges()
		if existing.length() >= 8:
			return existing
	var chars := "0123456789abcdef"
	var id := ""
	for i in 32:
		id += chars[randi() % chars.length()]
	var f := FileAccess.open(CLIENT_ID_PATH, FileAccess.WRITE)
	f.store_string(id)
	return id
