extends Node

const DEFAULT_RELAY_URL := "wss://codecade.co.za/tag/relay/host"
const DEFAULT_SERVER_NAME := "Someone's Server"
const DEFAULT_MAX_PLAYERS := 16
const PARENT_CHECK_INTERVAL_SEC := 2.0

var _relay_client: RelayClient = null

func _ready() -> void:
	var port := NetworkManager.DEFAULT_PORT
	var server_name := DEFAULT_SERVER_NAME
	var max_players := DEFAULT_MAX_PLAYERS
	var relay_url := DEFAULT_RELAY_URL
	var is_private := false
	var parent_pid := -1

	for arg in OS.get_cmdline_args():
		if arg.begins_with("--port="):
			port = int(arg.substr(7))
		elif arg.begins_with("--name="):
			server_name = arg.substr(7)
		elif arg.begins_with("--max-players="):
			max_players = int(arg.substr(14))
		elif arg.begins_with("--relay-url="):
			relay_url = arg.substr(12)
		elif arg == "--private":
			is_private = true
		elif arg.begins_with("--parent-pid="):
			parent_pid = int(arg.substr(13))

	var ok := NetworkManager.start_server(port)
	if not ok:
		push_error("Server failed to start -- exiting.")
		get_tree().quit(1)
		return

	if not is_private:
		_relay_client = RelayClient.new(relay_url, server_name, max_players, port)
		add_child(_relay_client)

	# Godot has no native "die with parent" -- when spawned by a client via
	# Host Server (host_setup.gd), this polls to catch the client crashing
	# without a clean shutdown so the process doesn't linger as an orphan.
	if parent_pid != -1:
		var timer := Timer.new()
		timer.wait_time = PARENT_CHECK_INTERVAL_SEC
		timer.timeout.connect(func():
			if not OS.is_process_running(parent_pid):
				print("server_main: parent process %d gone -- shutting down" % parent_pid)
				_graceful_quit()
		)
		add_child(timer)
		timer.start()

	get_tree().auto_accept_quit = false

func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		_graceful_quit()

func _graceful_quit() -> void:
	if _relay_client != null:
		_relay_client.shutdown()
	get_tree().quit()
