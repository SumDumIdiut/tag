extends Node

# Both Tag-Client.exe and Tag-Server.exe are exported from this same project
# (so client and server always run identical movement/game-mode code). The
# "dedicated_server" custom feature tag is what tells them apart -- it's set
# on the server export preset only (see export_presets.cfg).

func _ready() -> void:
	var target := "res://main/server_main.tscn" if OS.has_feature("dedicated_server") else "res://main/client_main.tscn"
	get_tree().change_scene_to_file.call_deferred(target)
