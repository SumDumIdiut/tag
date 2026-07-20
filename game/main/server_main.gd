extends Node

const DEFAULT_RELAY_URL := "wss://codecade.co.za/tag/relay/host"
const DEFAULT_SERVER_NAME := "Someone's Server"
const DEFAULT_MAX_PLAYERS := 16
const EMPTY_CHECK_INTERVAL_SEC := 2.0

var _relay_client: RelayClient = null
var _had_a_player := false

func _ready() -> void:
	# This process has nothing to render for anyone, so vsync (Godot's
	# default) buys nothing -- it just ties this loop's pacing to display
	# vertical-blank timing, which is real jitter for a process with no
	# frames to actually show. Disabling it removes that jitter for free.
	# Deliberately NOT uncapping max_fps to run flat-out, though: "Host
	# Server" spawns this as a second full Godot process on the SAME
	# machine as the player's own client (host_setup.gd), and letting it
	# busy-loop at whatever rate the CPU allows was directly regressing
	# that exact case -- competing hard enough for CPU against the client
	# to make the client itself stutter/hang right when hosting starts, a
	# worse version of the CPU-contention issue already mitigated once
	# this session by slowing host_setup's own retry interval. 60 keeps
	# this at the same footprint vsync would have given on a typical 60Hz
	# display, just without vsync's own added jitter.
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 60

	var port := NetworkManager.DEFAULT_PORT
	var server_name := DEFAULT_SERVER_NAME
	var max_players := DEFAULT_MAX_PLAYERS
	var relay_url := DEFAULT_RELAY_URL
	var is_private := false
	var quit_when_empty := false
	var is_ranked := false
	var level_id := ""
	var playlist_id := ""

	for arg in OS.get_cmdline_args():
		if arg.begins_with("--port="):
			port = int(arg.substr(7))
		elif arg.begins_with("--name="):
			server_name = arg.substr(7)
		elif arg.begins_with("--max-players="):
			max_players = int(arg.substr(14))
		elif arg.begins_with("--relay-url="):
			relay_url = arg.substr(12)
		elif arg.begins_with("--level="):
			level_id = arg.substr(8)
		elif arg.begins_with("--playlist="):
			playlist_id = arg.substr(11)
		elif arg == "--private":
			is_private = true
		elif arg == "--quit-when-empty":
			quit_when_empty = true
		elif arg == "--ranked":
			is_ranked = true

	var ok := NetworkManager.start_server(port)
	if not ok:
		push_error("Server failed to start -- exiting.")
		get_tree().quit(1)
		return
	NetworkManager.is_ranked_server = is_ranked
	NetworkManager.level_id = level_id
	NetworkManager.playlist_id = playlist_id

	if not is_private:
		_relay_client = RelayClient.new(relay_url, server_name, max_players, port, is_ranked, playlist_id)
		add_child(_relay_client)

	# Godot has no native "die with parent". This used to poll
	# OS.is_process_running(parent_pid), but that call only reliably tracks
	# processes *this* instance itself spawned as a child -- checking an
	# arbitrary external PID (the client that spawned *us*, the reverse
	# relationship) isn't valid, and was observed returning false for a
	# very-much-alive client, killing the server out from under a connected
	# player. Watching the real, already-working peer connection instead:
	# Host Server (host_setup.gd) passes --quit-when-empty, and once someone
	# has actually joined and then everyone leaves, there's no reason for
	# this ephemeral per-host server to keep running. A standalone dedicated
	# server (no --quit-when-empty) behaves as before -- always persistent.
	if quit_when_empty:
		var timer := Timer.new()
		timer.wait_time = EMPTY_CHECK_INTERVAL_SEC
		timer.timeout.connect(_check_empty)
		add_child(timer)
		timer.start()

	get_tree().auto_accept_quit = false

func _check_empty() -> void:
	var count := NetworkManager.get_player_count()
	if count > 0:
		_had_a_player = true
		return
	if not _had_a_player:
		return # nobody has joined yet -- keep waiting, not "emptied out"
	print("server_main: empty -- shutting down")
	_graceful_quit()

func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		_graceful_quit()

func _graceful_quit() -> void:
	if _relay_client != null:
		_relay_client.shutdown()
	get_tree().quit()
