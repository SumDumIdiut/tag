extends Control

@onready var username_edit: LineEdit = $VBox/UsernameEdit
@onready var server_name_edit: LineEdit = $VBox/ServerNameEdit
@onready var host_button: Button = $VBox/HostButton
@onready var back_button: Button = $VBox/BackButton
@onready var status_label: Label = $VBox/StatusLabel

var _spawner: LocalServerSpawner
var _server_name := "Someone's Server"

func _ready() -> void:
	username_edit.text = GameSettings.saved_username
	host_button.pressed.connect(_on_host_pressed)
	back_button.pressed.connect(_on_back_pressed)

	_spawner = LocalServerSpawner.new()
	add_child(_spawner)
	_spawner.connected.connect(_on_spawned_and_connected)
	_spawner.failed.connect(_on_spawn_failed)

func _on_host_pressed() -> void:
	_server_name = server_name_edit.text.strip_edges()
	if _server_name.is_empty():
		_server_name = "Someone's Server"

	var username := username_edit.text
	GameSettings.save_username(username)
	host_button.disabled = true
	status_label.text = "Starting server..."
	_spawner.spawn(_server_name, username)

func _on_spawn_failed(reason: String) -> void:
	status_label.text = reason
	host_button.disabled = false

func _on_spawned_and_connected() -> void:
	# Skip lobby_browser's manual create/browse step entirely -- as the host,
	# there's nothing to browse for and re-typing the server name as a lobby
	# name too would just be re-doing what this screen already collected.
	NetworkManager.lobby_state_updated.connect(_on_lobby_created, CONNECT_ONE_SHOT)
	NetworkManager.create_lobby(_server_name, NetworkManager.MAX_LOBBY_PLAYERS)

func _on_lobby_created(_lobby: Dictionary) -> void:
	get_tree().change_scene_to_file("res://main/lobby_room.tscn")

func _on_back_pressed() -> void:
	_spawner.kill_child()
	get_tree().change_scene_to_file("res://main/online_menu.tscn")
