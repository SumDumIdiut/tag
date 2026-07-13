extends Control

# "Find Ranked Match": joins an existing open ranked server if one's already
# listed, or silently hosts one and waits in it if not -- mirrors
# quick_play.gd's shape, but a ranked server auto-adds/auto-starts on its
# own (see NetworkManager.is_ranked_server), so this screen never has to
# call create/join/quick-join lobby RPCs itself, just connect and wait.

const MATCH_INTRO_SCENE := preload("res://main/match_intro.tscn")
const DIRECTORY_URL := "https://codecade.co.za/tag/api/servers"
const RELAY_JOIN_BASE := "wss://codecade.co.za/tag/relay/join/"

@onready var status_label: Label = $VBox/StatusLabel
@onready var back_button: Button = $VBox/BackButton

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
	_spawner.failed.connect(_on_spawn_failed)

	# Covers both paths -- joining an already-open ranked server, and the
	# spawner's own internal start_client() once a freshly-hosted one comes
	# up -- since both ultimately go through the same NetworkManager signal.
	NetworkManager.connected_to_server.connect(_on_connected)
	NetworkManager.connection_failed.connect(_on_join_existing_failed)
	NetworkManager.match_started.connect(_on_match_started)

	status_label.text = "Finding a ranked match..."
	if _http.request(DIRECTORY_URL) != OK:
		_host_new_ranked_server()

func _on_directory_response(result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	if result != HTTPRequest.RESULT_SUCCESS or response_code != 200:
		_host_new_ranked_server()
		return
	var parsed = JSON.parse_string(body.get_string_from_utf8())
	if typeof(parsed) != TYPE_ARRAY:
		_host_new_ranked_server()
		return
	var best = null
	for s in parsed:
		if not s.get("ranked", false):
			continue
		if s.playerCount >= s.maxPlayers:
			continue
		if best == null or s.playerCount > best.playerCount:
			best = s
	if best == null:
		_host_new_ranked_server()
		return
	status_label.text = "Joining a ranked match..."
	NetworkManager.set_username(_username)
	NetworkManager.start_client(RELAY_JOIN_BASE + str(best.id), _username)

func _on_join_existing_failed() -> void:
	status_label.text = "That server just went offline -- hosting a new one instead..."
	_host_new_ranked_server()

func _host_new_ranked_server() -> void:
	status_label.text = "No open ranked matches -- starting one..."
	_spawner.spawn("%s's Ranked Match" % _username, _username, ["--ranked"])

func _on_spawn_failed(reason: String) -> void:
	status_label.text = reason

func _on_connected() -> void:
	status_label.text = "Waiting for more players..."

func _on_match_started(_lobby_id: int, my_id: int, roster: Dictionary) -> void:
	var scene := MATCH_INTRO_SCENE.instantiate()
	scene.setup(my_id, roster)
	get_tree().root.add_child(scene)
	get_tree().current_scene.queue_free()
	get_tree().current_scene = scene

func _on_back_pressed() -> void:
	_spawner.kill_child()
	get_tree().change_scene_to_file("res://main/main_menu.tscn")
