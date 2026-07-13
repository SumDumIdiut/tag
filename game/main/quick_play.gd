extends Control

# One-click multiplayer entry point: skip Online's Browse/Host/Direct-Connect
# submenu and the second lobby-naming step entirely. Picks the fullest
# not-full public server (packing games instead of spreading players thin);
# if none are online, silently hosts one via LocalServerSpawner -- the exact
# mechanism host_setup.gd uses for manual hosting -- so this screen never
# dead-ends with "no servers found."

@onready var status_label: Label = $VBox/StatusLabel
@onready var back_button: Button = $VBox/BackButton

const DIRECTORY_URL := "https://codecade.co.za/tag/api/servers"
const RELAY_JOIN_BASE := "wss://codecade.co.za/tag/relay/join/"

var _http: HTTPRequest
var _spawner: LocalServerSpawner
var _username := ""

func _ready() -> void:
	back_button.pressed.connect(_on_back_pressed)
	_username = GameSettings.saved_username
	GameSettings.save_username(_username)

	_http = HTTPRequest.new()
	add_child(_http)
	_http.request_completed.connect(_on_directory_response)

	_spawner = LocalServerSpawner.new()
	add_child(_spawner)
	_spawner.connected.connect(_on_connected_to_own_host)
	_spawner.failed.connect(_on_spawn_failed)

	NetworkManager.connected_to_server.connect(_on_connected_to_existing_server)
	NetworkManager.connection_failed.connect(_on_join_existing_failed)

	status_label.text = "Finding a match..."
	if _http.request(DIRECTORY_URL) != OK:
		_host_new_match()

func _on_directory_response(result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	if result != HTTPRequest.RESULT_SUCCESS or response_code != 200:
		_host_new_match()
		return
	var parsed = JSON.parse_string(body.get_string_from_utf8())
	if typeof(parsed) != TYPE_ARRAY or parsed.is_empty():
		_host_new_match()
		return
	var best = null
	for s in parsed:
		if s.playerCount >= s.maxPlayers:
			continue
		if best == null or s.playerCount > best.playerCount:
			best = s
	if best == null:
		_host_new_match()
		return
	status_label.text = "Joining %s..." % best.name
	NetworkManager.set_username(_username)
	NetworkManager.start_client(RELAY_JOIN_BASE + str(best.id), _username)

func _on_join_existing_failed() -> void:
	# Only relevant while we're mid quick-play attempt -- once safely into a
	# lobby this screen is gone and no longer listening.
	status_label.text = "That server just went offline -- hosting a new one instead..."
	_host_new_match()

func _on_connected_to_existing_server() -> void:
	status_label.text = "Joining match..."
	NetworkManager.lobby_state_updated.connect(_on_in_lobby, CONNECT_ONE_SHOT)
	NetworkManager.quick_join_lobby()

func _host_new_match() -> void:
	status_label.text = "No open servers -- starting one..."
	_spawner.spawn("%s's Match" % _username, _username)

func _on_spawn_failed(reason: String) -> void:
	status_label.text = reason

func _on_connected_to_own_host() -> void:
	status_label.text = "Waiting for players..."
	NetworkManager.lobby_state_updated.connect(_on_in_lobby, CONNECT_ONE_SHOT)
	NetworkManager.quick_join_lobby()

func _on_in_lobby(_lobby: Dictionary) -> void:
	get_tree().change_scene_to_file("res://main/lobby_room.tscn")

func _on_back_pressed() -> void:
	_spawner.kill_child()
	get_tree().change_scene_to_file("res://main/main_menu.tscn")
