extends Node
class_name LocalServerSpawner

# Spawns a local Tag-Server.exe and connects this client to it as an
# ordinary player -- the exact mechanism the manual "Host Server" screen,
# one-click Quick Play, and ranked auto-host all need, factored out so none
# of them re-implement the spawn/port-pick/retry-connect dance separately.

signal connected
signal failed(reason: String)

const MAX_CONNECT_ATTEMPTS := 15
# The freshly-spawned Tag-Server.exe is a second full Godot process starting
# up on the same machine (loading the engine, initializing autoloads,
# connecting to the relay) -- it's briefly competing for CPU with this
# client. Retrying too fast just adds more connection-attempt churn on top
# of that contention instead of giving it room to finish starting.
const RETRY_INTERVAL_SEC := 1.0

var _child_pid := -1
var _pending := false
var _pending_port := -1
var _attempts := 0
var _username := ""
var _retry_timer: Timer

func _ready() -> void:
	_retry_timer = Timer.new()
	_retry_timer.wait_time = RETRY_INTERVAL_SEC
	_retry_timer.one_shot = true
	_retry_timer.timeout.connect(_try_connect)
	add_child(_retry_timer)
	NetworkManager.connected_to_server.connect(_on_connected)
	NetworkManager.connection_failed.connect(_on_connect_attempt_failed)

## extra_args are appended as-is to the spawned server's cmdline (e.g.
## ["--ranked"] for a ranked auto-host) alongside the port/name/
## quit-when-empty flags every spawned server needs regardless of caller.
func spawn(server_name: String, username: String, extra_args: PackedStringArray = PackedStringArray()) -> void:
	var exe_dir := OS.get_executable_path().get_base_dir()
	var server_exe := exe_dir.path_join("Tag-Server.exe")
	if not FileAccess.file_exists(server_exe):
		failed.emit("Tag-Server.exe not found next to this client -- can't host.")
		return

	var port := find_free_port()
	if port == -1:
		failed.emit("Couldn't find a free local port.")
		return

	var args := PackedStringArray([
		"--port=%d" % port,
		"--name=%s" % server_name,
		"--quit-when-empty",
	])
	args.append_array(extra_args)
	_child_pid = OS.create_process(server_exe, args)
	if _child_pid == -1:
		failed.emit("Failed to launch Tag-Server.exe.")
		return

	_username = username
	_pending_port = port
	_attempts = 0
	_pending = true
	_retry_timer.start()

func kill_child() -> void:
	if _child_pid != -1:
		OS.kill(_child_pid)
		_child_pid = -1

## Bind to port 0 so the OS assigns a free one, read it back, then release --
## there's a small window before Tag-Server.exe binds it where another
## process could grab it, but that's the standard tradeoff for this idiom.
static func find_free_port() -> int:
	var probe := TCPServer.new()
	if probe.listen(0) != OK:
		return -1
	var port := probe.get_local_port()
	probe.stop()
	return port

func _try_connect() -> void:
	if not _pending:
		return
	_attempts += 1
	if _attempts > MAX_CONNECT_ATTEMPTS:
		_pending = false
		failed.emit("Server didn't come up in time.")
		return
	NetworkManager.set_username(_username)
	NetworkManager.start_client("127.0.0.1:%d" % _pending_port, _username)

func _on_connect_attempt_failed() -> void:
	if not _pending:
		return
	_retry_timer.start()

func _on_connected() -> void:
	if not _pending:
		return
	_pending = false
	connected.emit()
