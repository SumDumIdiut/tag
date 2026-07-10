extends Node

# Real entry point (project.godot's main scene). Branches to the dedicated
# server scene when exported/run with the "dedicated_server" feature tag,
# otherwise boots the normal client into the main menu -- lets one project
# produce both a client build and a headless server build.

func _ready() -> void:
	# Deferred: changing scenes from the very first _ready() of the main
	# scene, while the SceneTree is still finishing its own initial setup,
	# throws a spurious "parent node is busy" error otherwise.
	if OS.has_feature("dedicated_server"):
		get_tree().change_scene_to_file.call_deferred("res://main/server_main.tscn")
	else:
		get_tree().change_scene_to_file.call_deferred("res://main/main_menu.tscn")
