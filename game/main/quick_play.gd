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
# NetworkManager is an autoload -- its signals outlive this screen. A
# CONNECT_ONE_SHOT hookup made right before an RPC round-trip (see
# _on_connected) can still be pending when Cancel is pressed; if the
# server's reply arrives in that window, the callback fires anyway and
# calls change_scene_to_file to lobby_room, stomping the "back to main
# menu" change Cancel just queued (the outgoing scene isn't actually freed
# until end-of-frame, so it's still very much alive to receive that late
# signal). Every async callback below checks this first.
var _cancelled := false

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
	if _cancelled:
		return
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
	if _cancelled:
		return
	# Only relevant while we're mid quick-play attempt -- once safely into a
	# lobby this screen is gone and no longer listening.
	status_label.text = "That server just went offline -- hosting a new one instead..."
	_host_new_match()

func _on_connected_to_existing_server() -> void:
	if _cancelled:
		return
	status_label.text = "Joining match..."
	NetworkManager.lobby_state_updated.connect(_on_in_lobby, CONNECT_ONE_SHOT)
	NetworkManager.quick_join_lobby()

func _host_new_match() -> void:
	if _cancelled:
		return
	status_label.text = "No open servers -- starting one..."
	_spawner.spawn("%s's Match" % _username, _username)

func _on_spawn_failed(reason: String) -> void:
	if _cancelled:
		return
	status_label.text = reason

func _on_connected_to_own_host() -> void:
	if _cancelled:
		return
	status_label.text = "Waiting for players..."
	NetworkManager.lobby_state_updated.connect(_on_in_lobby, CONNECT_ONE_SHOT)
	NetworkManager.quick_join_lobby()

func _on_in_lobby(_lobby: Dictionary) -> void:
	if _cancelled:
		return
	get_tree().change_scene_to_file("res://main/lobby_room.tscn")

func _on_back_pressed() -> void:
	_cancelled = true
	if NetworkManager.lobby_state_updated.is_connected(_on_in_lobby):
		NetworkManager.lobby_state_updated.disconnect(_on_in_lobby)
	# An in-flight HTTPRequest runs its actual I/O on a background thread;
	# queue_free()ing the node (which change_scene_to_file below does to
	# this whole screen) while a request is still pending makes the engine
	# block waiting for that thread to wind down -- freezing the game for
	# however long the request takes to time out. Cancelling first tells it
	# to stop immediately instead.
	_http.cancel_request()
	# Disconnect our own client connection BEFORE killing any server we
	# spawned, not after -- closing a WebSocket peer tries a graceful
	# close handshake, which can hang for a bit waiting on a reply from a
	# server that's already dead if the kill happens first.
	NetworkManager.disconnect_from_server()
	_spawner.kill_child()
	get_tree().change_scene_to_file("res://main/main_menu.tscn")
