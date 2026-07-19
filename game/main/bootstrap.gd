extends Node

# Real entry point (project.godot's main scene). Branches by which
# custom_feature tag the current export preset set (see export_presets.cfg):
# "dedicated_server" boots the headless server scene, "art_tool" boots the
# standalone paint tool, otherwise the normal client boots into the main
# menu -- lets one project produce a client build, a headless server build,
# and the friend-facing art tool build, all from the same codebase.
#
# The client build ALSO boots straight into the server scene if launched
# with a "--server" argument -- this is what makes local hosting (Quick
# Play/Ranked auto-host/manual Host Server, see local_server_spawner.gd)
# work for anyone who only downloaded Tag.exe: rather than needing a
# separate Tag-Server.exe sitting next to it (which only ever existed on
# the machine that happened to grab both files), the client spawns a second
# copy of *itself* with this flag. Tag.exe already contains every line of
# server code either way -- "dedicated_server" only changes which one boots
# by default, not what's actually bundled inside the binary.

func _ready() -> void:
	# Applies whatever tiles override GameAssetUpdater downloaded in a past
	# session (see game_asset_overrides.gd) before any arena gets built --
	# harmless no-op if nothing's ever been downloaded. Purely cosmetic
	# (pixels only, never tile behavior), so this is safe to run
	# unconditionally on every build variant, including the headless server
	# (which never renders it, but doesn't hurt to have it loaded either).
	GameAssetOverrides.apply_tile_texture_override()

	# Deferred: changing scenes from the very first _ready() of the main
	# scene, while the SceneTree is still finishing its own initial setup,
	# throws a spurious "parent node is busy" error otherwise.
	if OS.has_feature("dedicated_server") or "--server" in OS.get_cmdline_args():
		get_tree().change_scene_to_file.call_deferred("res://main/server_main.tscn")
	elif OS.has_feature("art_tool"):
		get_tree().change_scene_to_file.call_deferred("res://tools/art_tool.tscn")
	else:
		get_tree().change_scene_to_file.call_deferred("res://main/main_menu.tscn")
