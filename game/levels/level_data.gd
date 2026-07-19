extends RefCounted
class_name LevelData

# The live-published level format: plain data, never scenes/scripts, so a
# level fetched from the relay-server can never carry anything more
# dangerous than tile-index numbers and spawn coordinates. Both the
# dedicated server (authoritative collision, server_match.gd) and clients
# (rendering, net_game.gd) independently fetch the same JSON from the relay
# and build an identical arena from it via build_arena_from_data() -- the
# Art Tool's level editor is the only thing that goes the other direction
# (serialize()), turning a painted layout into the same JSON to publish.
#
# {"tiles": [[x, y, tile_type], ...], "spawn_points": [[x, y], ...],
#  "platforms": [{"start": [x, y], "end": [x, y], "period_sec": n}, ...]}
# tile_type is 0-8, matching tag_tileset.tres's 9 atlas-x tiles (all at
# atlas-y 0): 3 base types (boundary/pillar/platform) x 3 art variants
# (Piece/Corner/Internal), encoded variant-major as variant_index * 3 +
# type_index -- see build_tileset.gd's TILES/VARIANT_NAMES, the source of
# truth for this ordering. (Values 0/1/2 are deliberately still exactly
# Boundary/Pillar/Platform's Piece variant, same as the original 3-tile
# format, so every level published before variants existed still decodes
# to the same tiles it always did.) tiles/spawn_points coordinates:
# tile-grid cells for tiles, world/pixel position for spawn points
# (straight into Marker2D.position). "platforms" is optional (older/
# simpler levels just omit it) -- start/end are tile-grid cells too, the
# two points a MovingPlatform pendulums between; see moving_platform.gd for
# why no position for these is ever sent over the network at match time.
#
# No waypoints/AI-pathing in this format -- custom levels simply aren't
# offered for Sandbox/bot matches, only real player-vs-player ones.

const TileSetResource := preload("res://levels/tag_tileset.tres")
const MovingPlatformScene := preload("res://levels/moving_platform.tscn")

const MAX_TILES := 6000 # generous headroom over the default arena's own ~2968 cells -- just an abuse guard
const MIN_SPAWN_POINTS := 2
const MAX_SPAWN_POINTS := 16
const MAX_PLATFORMS := 20 # generous for any hand-built level -- just an abuse guard
const MIN_PERIOD_SEC := 0.5 # anything faster starts feeling like a teleport, not a ride
const MAX_PERIOD_SEC := 60.0

## Structural/size validation only (correct types, sane counts) -- doesn't
## guarantee the layout is fun or even fully enclosed, same trust level
## already accepted for player-drawn skins/hats.
static func is_valid(data: Dictionary) -> bool:
	if typeof(data) != TYPE_DICTIONARY:
		return false
	var tiles = data.get("tiles")
	var spawns = data.get("spawn_points")
	if typeof(tiles) != TYPE_ARRAY or typeof(spawns) != TYPE_ARRAY:
		return false
	if tiles.size() > MAX_TILES:
		return false
	if spawns.size() < MIN_SPAWN_POINTS or spawns.size() > MAX_SPAWN_POINTS:
		return false
	for entry in tiles:
		if typeof(entry) != TYPE_ARRAY or entry.size() < 3:
			return false
		var tile_type = entry[2]
		if typeof(tile_type) != TYPE_FLOAT and typeof(tile_type) != TYPE_INT:
			return false
		if int(tile_type) < 0 or int(tile_type) > 8:
			return false
	for entry in spawns:
		if typeof(entry) != TYPE_ARRAY or entry.size() < 2:
			return false
	var platforms = data.get("platforms", [])
	if typeof(platforms) != TYPE_ARRAY:
		return false
	if platforms.size() > MAX_PLATFORMS:
		return false
	for entry in platforms:
		if typeof(entry) != TYPE_DICTIONARY:
			return false
		var start = entry.get("start")
		var end = entry.get("end")
		var period = entry.get("period_sec")
		if typeof(start) != TYPE_ARRAY or start.size() < 2:
			return false
		if typeof(end) != TYPE_ARRAY or end.size() < 2:
			return false
		if typeof(period) != TYPE_FLOAT and typeof(period) != TYPE_INT:
			return false
		if float(period) < MIN_PERIOD_SEC or float(period) > MAX_PERIOD_SEC:
			return false
	return true

## Builds a real arena Node2D (a "Tiles" TileMapLayer + a "SpawnPoints" node
## of Marker2D children) from validated level data -- matches the shape of
## the built-in tag_arena.tscn closely enough that server_match.gd's
## `_arena.get_node("SpawnPoints")` and net_game.gd's rendering both work
## unmodified against it. Caller must validate with is_valid() first.
static func build_arena_from_data(data: Dictionary) -> Node2D:
	var arena := Node2D.new()
	arena.name = "Arena"

	var tiles_layer := TileMapLayer.new()
	tiles_layer.name = "Tiles"
	tiles_layer.tile_set = TileSetResource
	for entry in data.get("tiles", []):
		var x := int(entry[0])
		var y := int(entry[1])
		var tile_type := int(entry[2])
		tiles_layer.set_cell(Vector2i(x, y), 0, Vector2i(tile_type, 0))
	arena.add_child(tiles_layer)

	var spawn_points := Node2D.new()
	spawn_points.name = "SpawnPoints"
	for entry in data.get("spawn_points", []):
		var marker := Marker2D.new()
		marker.position = Vector2(float(entry[0]), float(entry[1]))
		spawn_points.add_child(marker)
	arena.add_child(spawn_points)

	var platforms := Node2D.new()
	platforms.name = "Platforms"
	for entry in data.get("platforms", []):
		var platform: MovingPlatform = MovingPlatformScene.instantiate()
		var start: Array = entry.start
		var end: Array = entry.end
		platform.start_cell = Vector2i(int(start[0]), int(start[1]))
		platform.end_cell = Vector2i(int(end[0]), int(end[1]))
		platform.period_sec = float(entry.period_sec)
		platforms.add_child(platform)
	arena.add_child(platforms)

	return arena

## Inverse of build_arena_from_data -- `cells` is {Vector2i: tile_type},
## `spawn_positions` is an Array of Vector2, `platform_defs` is an Array of
## {start: Vector2i, end: Vector2i, period_sec: float}. Used by the Art
## Tool's level editor to build the publish payload.
static func serialize(cells: Dictionary, spawn_positions: Array, platform_defs: Array = []) -> Dictionary:
	var tiles := []
	for coord in cells.keys():
		tiles.append([coord.x, coord.y, cells[coord]])
	var spawns := []
	for pos in spawn_positions:
		spawns.append([pos.x, pos.y])
	var platforms := []
	for p in platform_defs:
		platforms.append({
			"start": [p.start.x, p.start.y],
			"end": [p.end.x, p.end.y],
			"period_sec": p.period_sec,
		})
	return {"tiles": tiles, "spawn_points": spawns, "platforms": platforms}
