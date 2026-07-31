extends Node

# Procedurally builds several new built-in arenas for Local (bot) play, each
# saved as its own .tscn under game/levels/local_maps/ -- same node shape
# tag_arena.tscn uses (a "Tiles" TileMapLayer in group "arena_tiles", a
# "SpawnPoints" Node2D of Marker2D children, a "Waypoints" Node2D of
# Marker2D children in group "ai_waypoint") so game.gd's existing
# SpawnPoints/ai_waypoint lookups work unmodified regardless of which map
# got picked. Run via:
#   godot --headless --path . res://tools/generate_local_maps.tscn
#
# Waypoints don't need hand-wired edges -- ai/waypoint_graph.gd auto-
# connects any two within MAX_EDGE_DISTANCE that have clear line of sight
# through the arena's real collision geometry, so one marker per platform
# (or every ~300px along a wide one) is enough for NPCs to path the whole
# map correctly.

const TILE_SIZE := 10
const OUT_DIR := "res://levels/local_maps"
const TILESET := preload("res://levels/tag_tileset.tres")
const Catalog := preload("res://levels/local_maps/catalog.gd")
const OnlineMapCatalog := preload("res://levels/online_maps/catalog.gd") # tile_index_for() only -- see its own comment
const BackgroundScript := preload("res://levels/map_background.gd")
const FALLBACK_COLOR := Color(0.6, 0.6, 0.65) # matches build_tileset.gd's own fallback; defensive only
const BG_MARGIN := 150.0 # background extends this far past the outermost platform on every side

# Ground-floor platforms get spawns spread along their top surface --
# matches tag_arena's own all-spawns-on-the-floor layout. Catalog.gd's
# platform rects don't carry a "spawns" flag themselves (generation-only,
# not needed by the picker's preview icon), so it's derived here instead:
# 360 sits strictly between the highest non-floor platform's y0 (340, in
# staircase's middle steps) and the lowest actual floor's y0 (380, in
# scattered_islands) across every map in the catalog.
const SPAWN_FLOOR_Y := 360

func _ready() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DIR))
	for id in Catalog.MAP_ORDER:
		var def: Dictionary = Catalog.MAPS[id]
		if not def.has("platforms"):
			continue # defensive -- every current entry has platforms; skip anything that doesn't rather than crash
		_build_map(id, def, OnlineMapCatalog.tile_index_for(id))
	print("GENERATE_MAPS_DONE")
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
	# persistent=true is required for group membership to actually survive
	# ResourceSaver.save() below -- add_to_group()'s default (false) only
	# registers the group for the current in-memory SceneTree session and
	# is silently dropped when packing/serializing, confirmed by grepping
	# a first-pass output .tscn for "ai_waypoint"/"arena_tiles" and finding
	# neither string present anywhere in the saved file.
	tiles_layer.add_to_group("arena_tiles", true)
	arena.add_child(tiles_layer)
	tiles_layer.owner = arena

	var spawn_i := 0
	var waypoint_i := 0
	for plat_index in def.platforms.size():
		var plat: Dictionary = def.platforms[plat_index]
		var x0: int = plat.x0
		var y0: int = plat.y0
		var x1: int = plat.x1
		var y1: int = plat.y1
		_fill_tiles(tiles_layer, x0, y0, x1, y1, tile_index)
		_add_waypoints(waypoints, waypoint_i, x0, y0, x1)
		waypoint_i += 100 # keep names unique; exact numbering doesn't matter
		if y0 >= SPAWN_FLOOR_Y:
			spawn_i = _add_spawns(spawn_points, spawn_i, x0, y0, x1, plat_index, def.platforms)

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

func _fill_tiles(layer: TileMapLayer, x0: int, y0: int, x1: int, y1: int, tile_index: int) -> void:
	var gx0 := int(floor(float(x0) / TILE_SIZE))
	var gy0 := int(floor(float(y0) / TILE_SIZE))
	var gx1 := int(ceil(float(x1) / TILE_SIZE))
	var gy1 := int(ceil(float(y1) / TILE_SIZE))
	for gy in range(gy0, gy1):
		for gx in range(gx0, gx1):
			layer.set_cell(Vector2i(gx, gy), 0, Vector2i(tile_index, 0))

## One waypoint per platform, or every ~300px along a wide one -- see the
## file header comment on why no hand-wired edges are needed.
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

## A platform elevated above this one (e.g. Twin Towers' pillars, which
## rest directly on the main floor) can horizontally overlap a floor spawn
## candidate while its base touches that same y0 surface -- spawning a
## player there means their collider spawns embedded in the pillar's solid
## tiles, which physics then resolves by shoving them somewhere
## unpredictable. Confirmed as the actual cause of a live "player spawned
## outside the map" report on Twin Towers: two of the floor's 8 evenly
## -spaced candidates (x=-875 and x=875) land exactly inside the towers'
## 100px-wide bases (x -900..-800 and 800..900).
func _is_spawn_blocked(sx: float, y0: int, all_platforms: Array, self_index: int) -> bool:
	for i in all_platforms.size():
		if i == self_index:
			continue
		var other: Dictionary = all_platforms[i]
		var oy0: int = other.y0
		var oy1: int = other.y1
		if oy0 >= y0 or oy1 < y0:
			continue # not elevated structure whose base reaches this surface
		if sx >= other.x0 and sx <= other.x1:
			return true
	return false

## Spreads spawn points evenly along a platform's top surface, skipping any
## candidate blocked by another platform resting on this same surface (see
## _is_spawn_blocked), continuing the running index across multiple spawn
## -eligible platforms in the same map. Returns the updated index.
func _add_spawns(parent: Node2D, start_index: int, x0: int, y0: int, x1: int, self_index: int, all_platforms: Array) -> int:
	var width := x1 - x0
	var count := maxi(2, int(round(float(width) / 260.0)))
	var placed := 0
	for i in count:
		var t := (i + 0.5) / float(count)
		var sx := x0 + t * width
		if _is_spawn_blocked(sx, y0, all_platforms, self_index):
			continue
		var marker := Marker2D.new()
		marker.name = "Spawn%d" % (start_index + placed)
		marker.position = Vector2(sx, y0)
		parent.add_child(marker)
		marker.owner = parent.get_parent()
		placed += 1
	return start_index + placed
