extends Node

# Procedurally builds every OnlineMapCatalog map, each saved as its own
# .tscn under game/levels/online_maps/ -- same node shape tag_arena.tscn
# uses (a "Tiles" TileMapLayer in group "arena_tiles", a "SpawnPoints"
# Node2D of Marker2D children, a "Waypoints" Node2D of Marker2D children in
# group "ai_waypoint") so server_match.gd/net_game.gd's existing
# SpawnPoints/ai_waypoint/Tiles lookups work unmodified regardless of which
# map got picked. Direct copy of tools/generate_local_maps.gd's proven
# approach (see that file for the reasoning behind waypoint spacing/the
# boundary box) -- kept as its own script rather than sharing one, matching
# this codebase's established preference for a little duplication between
# genuinely separate concerns (offline bot maps vs. real online maps) over
# a shared abstraction neither side should have to know about the other
# through. Run via:
#   godot --headless --path . res://tools/generate_online_maps.tscn

const TILE_SIZE := 10
const OUT_DIR := "res://levels/online_maps"
const TILESET := preload("res://levels/tag_tileset.tres")
const Catalog := preload("res://levels/online_maps/catalog.gd")
const BackgroundScript := preload("res://levels/map_background.gd")
const FALLBACK_COLOR := Color(0.6, 0.6, 0.65) # matches build_tileset.gd's own fallback; defensive only
const BG_MARGIN := 150.0

const SPAWN_FLOOR_Y := 420
const WALL_THICKNESS := 20
const CEILING_CLEARANCE := 300

func _ready() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DIR))
	for id in Catalog.MAP_ORDER:
		_build_map(id, Catalog.MAPS[id], Catalog.tile_index_for(id))
	print("GENERATE_ONLINE_MAPS_DONE")
	get_tree().quit()

func _build_map(id: String, def: Dictionary, tile_index: int) -> void:
	var arena := Node2D.new()
	arena.name = "Arena"

	var background := BackgroundScript.new()
	background.name = "Background"
	background.theme_color = def.get("theme_color", FALLBACK_COLOR)
	background.theme_shape = def.get("theme_shape", "rect")
	background.bounds = _compute_bounds(def.platforms).grow(BG_MARGIN)
	arena.add_child(background)
	background.owner = arena

	var spawn_points := Node2D.new()
	spawn_points.name = "SpawnPoints"
	arena.add_child(spawn_points)
	spawn_points.owner = arena

	var waypoints := Node2D.new()
	waypoints.name = "Waypoints"
	arena.add_child(waypoints)
	waypoints.owner = arena

	var tiles_layer := TileMapLayer.new()
	tiles_layer.name = "Tiles"
	tiles_layer.tile_set = TILESET
	tiles_layer.add_to_group("arena_tiles", true)
	arena.add_child(tiles_layer)
	tiles_layer.owner = arena

	var spawn_i := 0
	var waypoint_i := 0
	for plat in def.platforms:
		var x0: int = plat.x0
		var y0: int = plat.y0
		var x1: int = plat.x1
		var y1: int = plat.y1
		_fill_tiles(tiles_layer, x0, y0, x1, y1, tile_index)
		_add_waypoints(waypoints, waypoint_i, x0, y0, x1)
		waypoint_i += 100
		if y0 >= SPAWN_FLOOR_Y:
			spawn_i = _add_spawns(spawn_points, spawn_i, x0, y0, x1)

	_add_boundary_box(tiles_layer, def.platforms, tile_index)

	var packed := PackedScene.new()
	packed.pack(arena)
	var out_path := "%s/%s.tscn" % [OUT_DIR, id]
	var err := ResourceSaver.save(packed, out_path)
	print("wrote map: ", id, " err=", err)

func _compute_bounds(platforms: Array) -> Rect2:
	var min_v := Vector2(INF, INF)
	var max_v := Vector2(-INF, -INF)
	for plat in platforms:
		min_v.x = minf(min_v.x, plat.x0)
		min_v.y = minf(min_v.y, plat.y0)
		max_v.x = maxf(max_v.x, plat.x1)
		max_v.y = maxf(max_v.y, plat.y1)
	return Rect2(min_v, max_v - min_v)

func _add_boundary_box(layer: TileMapLayer, platforms: Array, tile_index: int) -> void:
	var min_x: float = INF
	var max_x: float = -INF
	var min_y: float = INF
	var max_y: float = -INF
	for plat in platforms:
		min_x = minf(min_x, plat.x0)
		max_x = maxf(max_x, plat.x1)
		min_y = minf(min_y, plat.y0)
		max_y = maxf(max_y, plat.y1)

	var ceiling_y: float = min_y - CEILING_CLEARANCE
	_fill_tiles(layer, int(min_x) - WALL_THICKNESS, int(ceiling_y), int(min_x), int(max_y), tile_index)
	_fill_tiles(layer, int(max_x), int(ceiling_y), int(max_x) + WALL_THICKNESS, int(max_y), tile_index)
	_fill_tiles(layer, int(min_x) - WALL_THICKNESS, int(ceiling_y) - WALL_THICKNESS, int(max_x) + WALL_THICKNESS, int(ceiling_y), tile_index)

func _fill_tiles(layer: TileMapLayer, x0: int, y0: int, x1: int, y1: int, tile_index: int) -> void:
	var gx0 := int(floor(float(x0) / TILE_SIZE))
	var gy0 := int(floor(float(y0) / TILE_SIZE))
	var gx1 := int(ceil(float(x1) / TILE_SIZE))
	var gy1 := int(ceil(float(y1) / TILE_SIZE))
	for gy in range(gy0, gy1):
		for gx in range(gx0, gx1):
			layer.set_cell(Vector2i(gx, gy), 0, Vector2i(tile_index, 0))

func _add_waypoints(parent: Node2D, start_index: int, x0: int, y0: int, x1: int) -> void:
	var width := x1 - x0
	var count := maxi(1, int(round(float(width) / 300.0)))
	for i in count:
		var t := (i + 0.5) / float(count)
		var wx := x0 + t * width
		var marker := Marker2D.new()
		marker.name = "W%d" % (start_index + i)
		marker.position = Vector2(wx, y0 + 4)
		marker.add_to_group("ai_waypoint", true)
		parent.add_child(marker)
		marker.owner = parent.get_parent()

func _add_spawns(parent: Node2D, start_index: int, x0: int, y0: int, x1: int) -> int:
	var width := x1 - x0
	var count := maxi(2, int(round(float(width) / 260.0)))
	for i in count:
		var t := (i + 0.5) / float(count)
		var sx := x0 + t * width
		var marker := Marker2D.new()
		marker.name = "Spawn%d" % (start_index + i)
		marker.position = Vector2(sx, y0)
		parent.add_child(marker)
		marker.owner = parent.get_parent()
	return start_index + count
