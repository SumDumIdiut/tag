extends Node

# Anonymous player identity -- the one thing that ever lives locally
# (there's no account/login system beyond an optional linked session, see
# login_screen.gd). Friends (the friend code itself), Ranked reporting,
# Progression, and Login all key off this id; it used to live inside
# SkinCatalog (cosmetics selections are keyed by it too) but none of those
# other systems have anything to do with cosmetics, so it's a standalone
# autoload instead.

signal client_id_changed(new_id: String)

const CLIENT_ID_PATH := "user://client_id.txt"

var client_id := ""

func _ready() -> void:
	client_id = _load_or_create_client_id()

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
