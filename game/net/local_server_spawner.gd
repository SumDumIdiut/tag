extends Node
class_name LocalServerSpawner

# Spawns a local server (a second copy of this same client exe, launched
# with --server -- see spawn() below) and connects this client to it as an
# ordinary player -- the exact mechanism the manual "Host Server" screen,
# one-click Quick Play, and ranked auto-host all need, factored out so none
# of them re-implement the spawn/port-pick/retry-connect dance separately.

signal connected
signal failed(reason: String)

const MAX_CONNECT_ATTEMPTS := 15
# The freshly-spawned server is a second full Godot process starting up on
# the same machine (loading the engine, initializing autoloads, connecting
# to the relay) -- it's briefly competing for CPU with this client. Retrying
# too fast just adds more connection-attempt churn on top of that
# contention instead of giving it room to finish starting.
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
##
## Spawns a second copy of this same running executable with "--server"
## rather than looking for a separate Tag-Server.exe -- that used to only
## work on a machine that happened to have both files sitting side by side
## (i.e. only ever the repo owner's own machine), silently failing hosting
## for anyone who'd only downloaded the client. bootstrap.gd routes
## "--server" straight to the same server scene the dedicated-server export
## uses, so this needs nothing extra bundled -- Tag.exe already contains
## that code.
func spawn(server_name: String, username: String, extra_args: PackedStringArray = PackedStringArray()) -> void:
	var self_exe := OS.get_executable_path()
	if not FileAccess.file_exists(self_exe):
		failed.emit("Couldn't find this client's own executable -- can't host.")
		return

	var port := find_free_port()
	if port == -1:
		failed.emit("Couldn't find a free local port.")
		return

	# --headless (a real engine flag, not a custom one like --server below) --
	# this spawned copy is only ever driving server logic, never rendering
	# anything for anyone to look at, so there's no reason for a second game
	# window to visibly pop up over the host's own client every time they
	# host/quick-play/queue ranked. Already proven safe for this exact scene
	# (server_main.tscn) throughout local testing all session.
	var args := PackedStringArray([
		"--headless",
		"--server",
		"--port=%d" % port,
		"--name=%s" % server_name,
		"--quit-when-empty",
	])
	args.append_array(extra_args)
	_child_pid = OS.create_process(self_exe, args)
	if _child_pid == -1:
		failed.emit("Failed to launch a local server.")
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

## Only meaningful after `connected` has fired -- the port a caller needs to
## build a shareable "host:port" address (see Private hosting in
## casual_matchmaker.gd), since find_free_port() picks it internally and
## nothing outside this class otherwise sees it.
func get_port() -> int:
	return _pending_port

## Best-effort LAN-reachable IPv4 for sharing a privately-hosted server's
## address with a friend on the same network -- filters out loopback
## (127.x) and link-local (169.254.x, assigned when DHCP fails) addresses.
## Falls back to loopback if nothing else is found, which is still correct
## for same-machine testing, just not shareable across the network.
static func get_lan_ip() -> String:
	for ip in IP.get_local_addresses():
		if ip.count(".") == 3 and not ip.begins_with("127.") and not ip.begins_with("169.254."):
			return ip
	return "127.0.0.1"

## Bind to port 0 so the OS assigns a free one, read it back, then release --
## there's a small window before the spawned server binds it where another
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
