extends Node

func _ready() -> void:
	var port := NetworkManager.DEFAULT_PORT
	for arg in OS.get_cmdline_args():
		if arg.begins_with("--port="):
			port = int(arg.substr(7))
	var ok := NetworkManager.start_server(port)
	if not ok:
		push_error("Server failed to start -- exiting.")
		get_tree().quit(1)
