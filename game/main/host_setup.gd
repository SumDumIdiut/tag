extends Control

@onready var username_edit: LineEdit = $VBox/UsernameEdit
@onready var server_name_edit: LineEdit = $VBox/ServerNameEdit
@onready var host_button: Button = $VBox/HostButton
@onready var back_button: Button = $VBox/BackButton
@onready var status_label: Label = $VBox/StatusLabel

const MAX_CONNECT_ATTEMPTS := 15
const RETRY_INTERVAL_SEC := 0.5

var _child_pid := -1
var _pending_port := -1
var _attempts := 0
var _username := "Player"
var _server_name := "Someone's Server"
var _retry_timer: Timer

func _ready() -> void:
	host_button.pressed.connect(_on_host_pressed)
	back_button.pressed.connect(_on_back_pressed)
	NetworkManager.connected_to_server.connect(_on_connected)
	NetworkManager.connection_failed.connect(_on_connect_attempt_failed)

	_retry_timer = Timer.new()
	_retry_timer.wait_time = RETRY_INTERVAL_SEC
	_retry_timer.one_shot = true
	_retry_timer.timeout.connect(_try_connect)
	add_child(_retry_timer)

func _on_host_pressed() -> void:
	var exe_dir := OS.get_executable_path().get_base_dir()
	var server_exe := exe_dir.path_join("Tag-Server.exe")
	if not FileAccess.file_exists(server_exe):
		status_label.text = "Tag-Server.exe not found next to this client -- can't host."
		return

	var port := _find_free_port()
	if port == -1:
		status_label.text = "Couldn't find a free local port."
		return

	_server_name = server_name_edit.text.strip_edges()
	if _server_name.is_empty():
		_server_name = "Someone's Server"

	var args := PackedStringArray([
		"--port=%d" % port,
		"--name=%s" % _server_name,
		"--parent-pid=%d" % OS.get_process_id(),
	])
	_child_pid = OS.create_process(server_exe, args)
	if _child_pid == -1:
		status_label.text = "Failed to launch Tag-Server.exe."
		return

	_username = username_edit.text
	_pending_port = port
	_attempts = 0
	host_button.disabled = true
	status_label.text = "Starting server..."
	_retry_timer.start()

func _try_connect() -> void:
	_attempts += 1
	if _attempts > MAX_CONNECT_ATTEMPTS:
		status_label.text = "Server didn't come up in time."
		host_button.disabled = false
		_pending_port = -1
		return
	NetworkManager.set_username(_username)
	NetworkManager.start_client("127.0.0.1:%d" % _pending_port, _username)

func _on_connect_attempt_failed() -> void:
	if _pending_port == -1:
		return # not from our own host-spawn attempt (e.g. a stray signal)
	_retry_timer.start()

func _on_connected() -> void:
	if _pending_port == -1:
		return
	# Skip lobby_browser's manual create/browse step entirely -- as the host,
	# there's nothing to browse for and re-typing the server name as a lobby
	# name too would just be re-doing what this screen already collected.
	NetworkManager.lobby_state_updated.connect(_on_lobby_created, CONNECT_ONE_SHOT)
	NetworkManager.create_lobby(_server_name, NetworkManager.MAX_LOBBY_PLAYERS)

func _on_lobby_created(_lobby: Dictionary) -> void:
	get_tree().change_scene_to_file("res://main/lobby_room.tscn")

func _on_back_pressed() -> void:
	if _child_pid != -1:
		OS.kill(_child_pid)
	get_tree().change_scene_to_file("res://main/online_menu.tscn")

## Bind to port 0 so the OS assigns a free one, read it back, then release --
## there's a small window before Tag-Server.exe binds it where another
## process could grab it, but that's the standard tradeoff for this idiom.
func _find_free_port() -> int:
	var probe := TCPServer.new()
	if probe.listen(0) != OK:
		return -1
	var port := probe.get_local_port()
	probe.stop()
	return port
