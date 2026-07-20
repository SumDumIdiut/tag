extends Control

const UIStyle := preload("res://ui/ui_style.gd")
const LEVELS_CATALOG_URL := "https://codecade.co.za/tag/api/levels/catalog"

@onready var username_edit: LineEdit = $VBox/UsernameEdit
@onready var server_name_edit: LineEdit = $VBox/ServerNameEdit
@onready var map_select: OptionButton = $VBox/MapSelect
@onready var host_button: Button = $VBox/HostButton
@onready var back_button: Button = $VBox/BackButton
@onready var status_label: Label = $VBox/StatusLabel

var _spawner: LocalServerSpawner
var _server_name := "Someone's Server"
# item index -> level_id ("" for the built-in default, at index 0)
var _map_level_ids: Array[String] = [""]
# NetworkManager is an autoload -- its signals outlive this screen, so a
# late lobby_state_updated (from the CONNECT_ONE_SHOT below) can still fire
# after Back is pressed and pull the player into lobby_room anyway. See
# quick_play.gd's _cancelled for the full explanation.
var _cancelled := false

func _ready() -> void:
	UIStyle.add_background(self, "host_setup")
	UIStyle.style_button(host_button, UIStyle.COLOR_ONLINE)
	UIStyle.style_back_button(back_button)

	username_edit.text = GameSettings.saved_username
	host_button.pressed.connect(_on_host_pressed)
	back_button.pressed.connect(_on_back_pressed)

	map_select.add_item("Classic Arena")
	_fetch_map_catalog()

	_spawner = LocalServerSpawner.new()
	add_child(_spawner)
	_spawner.connected.connect(_on_spawned_and_connected)
	_spawner.failed.connect(_on_spawn_failed)

## Custom levels are live-published (see the Art Tool's Level page) with no
## review step -- if the fetch fails, the dropdown just quietly stays at
## "Classic Arena" only, same fallback-to-default philosophy server_match.gd
## and net_game.gd already use if a chosen level can't be loaded.
func _fetch_map_catalog() -> void:
	var req := HTTPRequest.new()
	add_child(req)
	req.request_completed.connect(func(_result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray):
		req.queue_free()
		if response_code != 200:
			return
		var parsed = JSON.parse_string(body.get_string_from_utf8())
		if typeof(parsed) != TYPE_ARRAY:
			return
		for entry in parsed:
			if typeof(entry) != TYPE_DICTIONARY or not entry.has("id") or not entry.has("name"):
				continue
			map_select.add_item(String(entry.name))
			_map_level_ids.append(String(entry.id))
	)
	req.request(LEVELS_CATALOG_URL)

func _on_host_pressed() -> void:
	_server_name = server_name_edit.text.strip_edges()
	if _server_name.is_empty():
		_server_name = "Someone's Server"

	var username := username_edit.text
	GameSettings.save_username(username)
	host_button.disabled = true
	status_label.text = "Starting server..."

	var level_id := ""
	var selected := map_select.selected
	if selected >= 0 and selected < _map_level_ids.size():
		level_id = _map_level_ids[selected]
	var extra_args := PackedStringArray(["--level=%s" % level_id]) if not level_id.is_empty() else PackedStringArray()
	_spawner.spawn(_server_name, username, extra_args)

func _on_spawn_failed(reason: String) -> void:
	if _cancelled:
		return
	status_label.text = reason
	host_button.disabled = false

func _on_spawned_and_connected() -> void:
	if _cancelled:
		return
	# As the host, there's nothing to browse for -- re-typing the server name
	# as a lobby name too would just be re-doing what this screen collected.
	NetworkManager.lobby_state_updated.connect(_on_lobby_created, CONNECT_ONE_SHOT)
	NetworkManager.create_lobby(_server_name, NetworkManager.MAX_LOBBY_PLAYERS)

func _on_lobby_created(_lobby: Dictionary) -> void:
	if _cancelled:
		return
	get_tree().change_scene_to_file("res://main/lobby_room.tscn")

func _on_back_pressed() -> void:
	_cancelled = true
	if NetworkManager.lobby_state_updated.is_connected(_on_lobby_created):
		NetworkManager.lobby_state_updated.disconnect(_on_lobby_created)
	# Disconnect our own client connection BEFORE killing the server we
	# spawned, not after -- closing a WebSocket peer tries a graceful close
	# handshake, which can hang for a bit waiting on a reply from a server
	# that's already dead if the kill happens first.
	NetworkManager.disconnect_from_server()
	_spawner.kill_child()
	get_tree().change_scene_to_file("res://main/online_menu.tscn")
