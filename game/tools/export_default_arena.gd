extends Node

# One-off export tool: dumps tag_arena.tscn's tile layout/spawn points/
# platforms to relay-server/public/default_arena.json, in the exact same
# {tiles, spawn_points, platforms} shape LevelData already uses for custom
# levels -- so the website's live match viewer (watch.html) can render the
# one arena every match actually uses without duplicating tile-layout data
# by hand. Re-run and re-commit the output whenever tag_arena.tscn's
# layout changes. Usage:
#   Godot.exe --headless --path . res://tools/export_default_arena.tscn

const ARENA_SCENE := preload("res://levels/tag_arena.tscn")

func _ready() -> void:
	var arena: Node2D = ARENA_SCENE.instantiate()
	add_child(arena)

	var tiles_layer: TileMapLayer = arena.get_node("Tiles")
	var tiles := []
	for cell in tiles_layer.get_used_cells():
		var atlas_coords := tiles_layer.get_cell_atlas_coords(cell)
		tiles.append([cell.x, cell.y, atlas_coords.x])

	var spawn_points := []
	for marker in arena.get_node("SpawnPoints").get_children():
		spawn_points.append([marker.position.x, marker.position.y])

	var platforms := []
	var platforms_node := arena.get_node_or_null("Platforms")
	if platforms_node:
		for platform in platforms_node.get_children():
			platforms.append({
				"start": [platform.start_cell.x, platform.start_cell.y],
				"end": [platform.end_cell.x, platform.end_cell.y],
				"period_sec": platform.period_sec,
			})

	var data := {"tiles": tiles, "spawn_points": spawn_points, "platforms": platforms}
	# res://.. isn't a reliable path for FileAccess -- go through the real
	# OS filesystem path instead (this project's own root, one level below
	# the repo root where relay-server/ lives).
	var project_root := ProjectSettings.globalize_path("res://")
	var output_path := project_root.path_join("../relay-server/public/default_arena.json")
	var f := FileAccess.open(output_path, FileAccess.WRITE)
	f.store_string(JSON.stringify(data))
	f.close()
	print("EXPORT_DONE tiles=%d spawns=%d platforms=%d" % [tiles.size(), spawn_points.size(), platforms.size()])
	get_tree().quit()
