extends Node

# Real entry point (project.godot's main scene). Branches by which
# custom_feature tag the current export preset set (see export_presets.cfg):
# "dedicated_server" boots the headless server scene, "art_tool" boots the
# standalone paint tool, otherwise the normal client boots into the main
# menu -- lets one project produce a client build, a headless server build,
# and the friend-facing art tool build, all from the same codebase.

func _ready() -> void:
	# Deferred: changing scenes from the very first _ready() of the main
	# scene, while the SceneTree is still finishing its own initial setup,
	# throws a spurious "parent node is busy" error otherwise.
	if OS.has_feature("dedicated_server"):
		get_tree().change_scene_to_file.call_deferred("res://main/server_main.tscn")
	elif OS.has_feature("art_tool"):
		get_tree().change_scene_to_file.call_deferred("res://tools/art_tool.tscn")
	else:
		get_tree().change_scene_to_file.call_deferred("res://main/main_menu.tscn")
