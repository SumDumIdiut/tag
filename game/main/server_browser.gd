extends Control

const UIStyle := preload("res://ui/ui_style.gd")
const MATCH_INTRO_SCENE := preload("res://main/match_intro.tscn")

@onready var server_list: ItemList = $VBox/ServerList
@onready var username_edit: LineEdit = $VBox/UsernameEdit
@onready var connect_button: Button = $VBox/ConnectButton
@onready var watch_button: Button = $VBox/WatchButton
@onready var status_label: Label = $VBox/StatusLabel
@onready var back_button: Button = $VBox/BackButton

const DIRECTORY_URL := "https://codecade.co.za/tag/api/servers"
const RELAY_JOIN_BASE := "wss://codecade.co.za/tag/relay/join/"
const REFRESH_INTERVAL_SEC := 4.0

var _servers: Array = []
var _http: HTTPRequest
var _refresh_timer: Timer
var _request_in_flight := false
## Set by _on_watch_pressed(), read by _on_connected() to decide whether to
## quick_join_lobby (normal Connect) or just wait for a match already in
## progress to be pushed to us (Watch) -- start_spectator()/start_client()
## both end in the same connected_to_server signal, so this is the one bit
## of context that signal alone doesn't carry.
var _watching := false
# NetworkManager is an autoload -- its signals outlive this screen, so a late
# lobby_state_updated (from the CONNECT_ONE_SHOT below) can still fire after
# Back is pressed and pull the player into lobby_room anyway. See
# quick_play.gd's _cancelled for the full explanation.
var _cancelled := false

func _ready() -> void:
	UIStyle.add_background(self, "server_browser")
	UIStyle.style_button(connect_button, UIStyle.COLOR_ONLINE)
	UIStyle.style_button(watch_button, UIStyle.COLOR_NEUTRAL)
	UIStyle.style_back_button(back_button)
	UIStyle.apply_bar_art(connect_button, "action_bars", "connect")
	UIStyle.apply_bar_art(watch_button, "action_bars", "watch")
	UIStyle.apply_bar_art(back_button, "action_bars", "back")
	UIStyle.style_line_edit(username_edit)

	username_edit.text = GameSettings.saved_username
	connect_button.pressed.connect(_on_connect_pressed)
	watch_button.pressed.connect(_on_watch_pressed)
	back_button.pressed.connect(_on_back_pressed)
	server_list.item_activated.connect(func(_idx): _on_connect_pressed())
	NetworkManager.connected_to_server.connect(_on_connected)
	NetworkManager.connection_failed.connect(_on_connection_failed)
	NetworkManager.spectate_failed.connect(_on_spectate_failed)
	NetworkManager.match_started.connect(_on_spectate_match_started)

	_http = HTTPRequest.new()
	add_child(_http)
	_http.request_completed.connect(_on_request_completed)

	_refresh_timer = Timer.new()
	_refresh_timer.wait_time = REFRESH_INTERVAL_SEC
	_refresh_timer.timeout.connect(_refresh)
	add_child(_refresh_timer)
	_refresh_timer.start()

	_refresh()

func _refresh() -> void:
	if _request_in_flight:
		return
	_request_in_flight = true
	if _http.request(DIRECTORY_URL) != OK:
		_request_in_flight = false
		status_label.text = "Couldn't reach the server directory."

func _on_request_completed(result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	_request_in_flight = false
	if result != HTTPRequest.RESULT_SUCCESS or response_code != 200:
		status_label.text = "Couldn't reach the server directory."
		return
	var parsed = JSON.parse_string(body.get_string_from_utf8())
	if typeof(parsed) != TYPE_ARRAY:
		return
	_servers = parsed

	var selected_id = null
	var selected := server_list.get_selected_items()
	if not selected.is_empty() and selected[0] < _servers.size():
		selected_id = _servers[selected[0]].id

	server_list.clear()
	if _servers.is_empty():
		status_label.text = "No servers online right now. Host one from the main menu!"
	else:
		status_label.text = ""
	for i in _servers.size():
		var s: Dictionary = _servers[i]
		server_list.add_item("%s  (%d/%d)" % [s.name, s.playerCount, s.maxPlayers])
		if selected_id != null and s.id == selected_id:
			server_list.select(i)

func _on_connect_pressed() -> void:
	var selected := server_list.get_selected_items()
	if selected.is_empty():
		return
	var server: Dictionary = _servers[selected[0]]
	var username := username_edit.text
	GameSettings.save_username(username)
	NetworkManager.set_username(username)
	connect_button.disabled = true
	watch_button.disabled = true
	status_label.text = "Connecting..."
	NetworkManager.start_client(RELAY_JOIN_BASE + str(server.id), username)

func _on_watch_pressed() -> void:
	var selected := server_list.get_selected_items()
	if selected.is_empty():
		return
	var server: Dictionary = _servers[selected[0]]
	_watching = true
	connect_button.disabled = true
	watch_button.disabled = true
	status_label.text = "Connecting..."
	NetworkManager.start_spectator(RELAY_JOIN_BASE + str(server.id))

func _on_connected() -> void:
	if _cancelled:
		return
	if _watching:
		status_label.text = "Waiting for a match in progress..."
		return
	status_label.text = "Joining match..."
	NetworkManager.lobby_state_updated.connect(_on_in_lobby, CONNECT_ONE_SHOT)
	NetworkManager.quick_join_lobby()

func _on_in_lobby(_lobby: Dictionary) -> void:
	if _cancelled:
		return
	get_tree().change_scene_to_file("res://main/lobby_room.tscn")

## Only NetworkManager.start_spectator() (via _on_watch_pressed above) ever
## leaves this screen's connection sitting with no lobby to join, so this
## firing at all means we're spectating -- normal Connect always transitions
## away via _on_in_lobby well before a match (and this signal) exists.
func _on_spectate_match_started(_lobby_id: int, my_id: int, roster: Dictionary, level_id: String) -> void:
	if not _watching or _cancelled:
		return
	var scene := MATCH_INTRO_SCENE.instantiate()
	scene.setup(my_id, roster, level_id)
	get_tree().root.add_child(scene)
	get_tree().current_scene.queue_free()
	get_tree().current_scene = scene

func _on_spectate_failed() -> void:
	if _cancelled:
		return
	status_label.text = "No match is currently in progress on that server."
	NetworkManager.disconnect_from_server()
	_watching = false
	connect_button.disabled = false
	watch_button.disabled = false

func _on_connection_failed() -> void:
	status_label.text = "Couldn't connect to that server -- it may have gone offline."
	connect_button.disabled = false
	watch_button.disabled = false
	_watching = false

func _on_back_pressed() -> void:
	_cancelled = true
	if NetworkManager.lobby_state_updated.is_connected(_on_in_lobby):
		NetworkManager.lobby_state_updated.disconnect(_on_in_lobby)
	NetworkManager.disconnect_from_server()
	_http.cancel_request()
	get_tree().change_scene_to_file("res://main/online_menu.tscn")
