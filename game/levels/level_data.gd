extends RefCounted
class_name LevelData

# The live-published level format: plain data, never scenes/scripts, so a
# level fetched from the relay-server can never carry anything more
# dangerous than tile-index numbers, spawn coordinates, and texture
# placements. Both the dedicated server (authoritative collision,
# server_match.gd) and clients (rendering, net_game.gd/game.gd) build an
# identical arena from the same JSON via build_arena_from_data() -- the web
# Level Editor is the thing that goes the other direction, turning a
# painted layout into this JSON to publish.
#
# {"tiles": [[x, y, tile_type], ...], "spawn_points": [[x, y], ...],
#  "platforms": [{"start": [x, y], "end": [x, y], "period_sec": n}, ...],
#  "placements": [{"textureIndex": n, "x": x, "y": y, "width": w, "height": h}, ...]}
# tile_type is always 0 -- a single regular tile, no Boundary/Pillar/
# Platform split, no art variants, no Ice/Bouncy behavior tiles (an earlier
# version of the format had all of that; the field is kept in the wire
# format purely so older published levels still decode without a migration
# step, but every tile now renders/behaves identically regardless of its
# value). tiles/platforms coordinates are LOGICAL tile-grid cells -- one
# cell is TILE_SIZE_PX world-pixels, currently sized to match a player (see
# that const's own comment), not the TileSet's own smaller real tile
# resolution. spawn_points are already world-pixel (straight into
# Marker2D.position). "platforms" is optional (older/simpler levels just
# omit it) -- start/end are logical tile-grid cells too, the two points a
# MovingPlatform pendulums between; see moving_platform.gd for why no
# position for these is ever sent over the network at match time.
# "placements" is optional -- textureIndex indexes into the level's own
# uploaded texture list (see CustomLevelCache, which fetches both this JSON
# and every referenced texture image at startup); x/y/width/height are
# GRID-CELL-relative (not world-pixel, not canvas-pixel -- see
# level-editor.html's publish handler for why), so a placement's apparent
# size/position relative to the tiles around it survives a future
# TILE_SIZE_PX change the same way tiles already do.
#
# No waypoints/AI-pathing in this format -- custom levels simply aren't
# offered for Sandbox/bot matches' pathfinding; bots fall back to direct
# steering on them (see WaypointGraph.next_hop).

const TileSetResource := preload("res://levels/tag_tileset.tres")
const MovingPlatformScene := preload("res://levels/moving_platform.tscn")
const MapBackgroundScript := preload("res://levels/map_background.gd")
const FixedView := preload("res://levels/fixed_view.gd")

# LOGICAL tile-grid cell size in world pixels -- one tile is one player
# (CharacterBodyRect is 40x40, see game/player/character_body_rect.gd), not
# tied to the TileSet's own real per-cell art resolution (REAL_TILE_PX
# below, which never changes -- no art was regenerated for this). Matches
# the web Level Editor's own TILE_SIZE_PX (relay-server/public/
# level-editor.html), which is what actually produces this format's "tiles"
# grid coordinates.
const TILE_SIZE_PX := 40
# tag_tileset.tres's real texture_region_size (see tools/build_tileset.gd) --
# fixed, shared by every map (built-in and custom alike). Each logical
# TILE_SIZE_PX cell below is filled with a solid block of this many real
# TileMapLayer cells per side, so painting stays chunky/player-scaled
# without the underlying tile art or built-in maps ever needing to change.
const REAL_TILE_PX := 10
const TILES_PER_LOGICAL_TILE := TILE_SIZE_PX / REAL_TILE_PX
# Same padding generate_online_maps.gd uses around a built-in map's platform
# rects before fitting to the fixed camera -- kept identical so a custom
# level's camera framing reads the same as every built-in one.
const BG_MARGIN := 150.0

const MAX_TILES := 6000 # generous headroom over the default arena's own ~2968 cells -- just an abuse guard
const MIN_SPAWN_POINTS := 2
const MAX_SPAWN_POINTS := 16
const MAX_PLATFORMS := 20 # generous for any hand-built level -- just an abuse guard
const MIN_PERIOD_SEC := 0.5 # anything faster starts feeling like a teleport, not a ride
const MAX_PERIOD_SEC := 60.0
const MAX_PLACEMENTS := 200 # mirrors server.js's MAX_LEVEL_PLACEMENTS

## Structural/size validation only (correct types, sane counts) -- doesn't
## guarantee the layout is fun or even fully enclosed, same low-friction
## trust level used elsewhere for player-published content.
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
		# Any value 0-10 is accepted (not just 0) purely so a level
		# published before the tile-type/variant system was removed still
		# validates -- build_arena_from_data() below ignores the value
		# either way and always renders the one remaining tile.
		if int(tile_type) < 0 or int(tile_type) > 10:
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
	var placements = data.get("placements", [])
	if typeof(placements) != TYPE_ARRAY:
		return false
	if placements.size() > MAX_PLACEMENTS:
		return false
	for entry in placements:
		# Only textureIndex is required -- x/y/width/height are checked
		# loosely (build_arena_from_data() skips a malformed/legacy one
		# individually, see _is_placement_renderable() below) rather than
		# invalidating the WHOLE level over one bad optional field. Confirmed
		# live as a real regression: a level published before width/height
		# replaced the old "scale" field (see level-editor.html's own
		# comment on why) failed is_valid() entirely -- its tiles/spawns
		# were perfectly fine, only that one placement was stale.
		if typeof(entry) != TYPE_DICTIONARY:
			return false
		var texture_index = entry.get("textureIndex")
		if (typeof(texture_index) != TYPE_FLOAT and typeof(texture_index) != TYPE_INT) or int(texture_index) < 0:
			return false
	return true

## A placement entry is only actually drawable if it has real x/y/width/
## height -- an older level published before that redesign (see is_valid()'s
## own comment) has "scale" instead, which this deliberately does NOT try to
## translate (that would need CELL_PX, an editor-only rendering constant
## with no meaning here); it just renders as if unplaced, same graceful
## "custom textures are cosmetic, missing one degrades gracefully" handling
## as a texture that failed to fetch/decode.
static func _is_placement_renderable(entry: Dictionary) -> bool:
	for field in ["x", "y", "width", "height"]:
		var v = entry.get(field)
		if typeof(v) != TYPE_FLOAT and typeof(v) != TYPE_INT:
			return false
	return float(entry.get("width", 0)) > 0.0 and float(entry.get("height", 0)) > 0.0

## Builds a real arena Node2D (a "Background" node the fixed camera/death-
## plane/backdrop all key off, a "Tiles" TileMapLayer, a "Placements" node
## of Sprite2D children, a "SpawnPoints" node of Marker2D children) from
## validated level data -- matches the shape of every built-in online map
## closely enough that server_match.gd's `_arena.get_node("SpawnPoints")`/
## `_arena.get_node("Background").bounds` and net_game.gd's identical
## camera/rendering lookups both work unmodified against it. Caller must
## validate with is_valid() first.
##
## `textures` is CustomLevelCache's own already-fetched Texture2D array for
## this level, index-matched to "placements"' textureIndex -- an empty
## array (the default) just means no placements render, same graceful
## degradation as everywhere else a custom level's optional content might
## not have loaded. `background_texture` is likewise CustomLevelCache's own
## already-fetched image (null if the level has none, or hasn't loaded yet) --
## see MapBackground.background_texture for how it's drawn.
static func build_arena_from_data(data: Dictionary, textures: Array = [], background_texture: Texture2D = null) -> Node2D:
	var arena := Node2D.new()
	arena.name = "Arena"

	var tiles_layer := TileMapLayer.new()
	tiles_layer.name = "Tiles"
	tiles_layer.tile_set = TileSetResource
	# Matches tag_arena.tscn's own Tiles node group -- player.gd's post-move
	# floor-tile lookup finds whichever arena is currently live this way,
	# without needing a direct node-path reference into either arena shape.
	tiles_layer.add_to_group("arena_tiles")
	# Collision-only -- a custom level's own visual is whatever the creator
	# places (see "Placements" below), not the shared flat-gray tile art
	# every built-in map uses. Besides matching that intent directly,
	# painting each logical TILE_SIZE_PX cell as TILES_PER_LOGICAL_TILE^2
	# separate real cells would otherwise show as a visible grid of small
	# squares instead of reading as one unified tile -- CanvasItem.visible
	# only affects rendering, TileMapLayer collision stays fully live
	# either way.
	tiles_layer.visible = false
	# Tracked alongside the cells themselves so Background's bounds (below)
	# can be fit to the actual painted layout, the same way
	# generate_online_maps.gd fits it to a built-in map's platform rects --
	# without this, min/max would stay at their +/-INF starting values for a
	# level with zero tiles (Rect2 arithmetic on that is nonsensical), hence
	# the explicit empty check below rather than trusting the loop to always run.
	var min_px := Vector2(INF, INF)
	var max_px := Vector2(-INF, -INF)
	for entry in data.get("tiles", []):
		var x := int(entry[0])
		var y := int(entry[1])
		# entry[2] (the old tile_type) is intentionally ignored -- the atlas
		# only has one tile now, at (0, 0), regardless of what value an
		# older published level happens to have stored there. Each logical
		# cell is a solid TILES_PER_LOGICAL_TILE x TILES_PER_LOGICAL_TILE
		# block of the TileSet's own real (smaller) cells -- see
		# TILES_PER_LOGICAL_TILE's own comment for why, mirrors
		# generate_online_maps.gd's _fill_tiles() filling a world-pixel
		# range with however many real cells it actually spans.
		for dx in TILES_PER_LOGICAL_TILE:
			for dy in TILES_PER_LOGICAL_TILE:
				tiles_layer.set_cell(Vector2i(x * TILES_PER_LOGICAL_TILE + dx, y * TILES_PER_LOGICAL_TILE + dy), 0, Vector2i(0, 0))
		min_px.x = minf(min_px.x, x * TILE_SIZE_PX)
		min_px.y = minf(min_px.y, y * TILE_SIZE_PX)
		max_px.x = maxf(max_px.x, (x + 1) * TILE_SIZE_PX)
		max_px.y = maxf(max_px.y, (y + 1) * TILE_SIZE_PX)
	arena.add_child(tiles_layer)

	# Drawn right after Tiles (and before Background, though Background's
	# own z_index=-10 already guarantees it stays behind everything
	# regardless of tree order) so placements always render on top of the
	# tile floor, never under it.
	var placements := Node2D.new()
	placements.name = "Placements"
	# Player/NPC nodes (added as game.gd's own later siblings, outside this
	# arena entirely -- see game.gd's own add_child(player)) default to
	# z_index=0, and CanvasItem z_index compares globally across the whole
	# 2D scene regardless of tree position -- without this, every placement
	# sprite painted BEHIND whoever was standing in front of it (tree order
	# alone put arena, and everything in it, under the later-added player).
	# Background keeps its own separate z_index=-10 (set below) either way,
	# so it's unaffected by this.
	placements.z_index = 1
	for entry in data.get("placements", []):
		if not _is_placement_renderable(entry):
			continue
		var texture_index := int(entry.get("textureIndex", -1))
		if texture_index < 0 or texture_index >= textures.size():
			continue
		var tex: Texture2D = textures[texture_index]
		if tex == null:
			continue
		var tex_size := tex.get_size()
		if tex_size.x <= 0.0 or tex_size.y <= 0.0:
			continue
		var sprite := Sprite2D.new()
		sprite.texture = tex
		sprite.position = Vector2(float(entry.x), float(entry.y)) * TILE_SIZE_PX
		var desired_size := Vector2(float(entry.width), float(entry.height)) * TILE_SIZE_PX
		sprite.scale = desired_size / tex_size
		placements.add_child(sprite)
		# Folded into the SAME min/max Background.bounds fits to below --
		# a decorative placement is very often bigger than (or offset from)
		# the tiles it sits on (that's the whole point of decoupling them),
		# so a camera fit to tiles alone left the actual visible art
		# cropped, shrunk, or pushed to one side of the frame -- confirmed
		# live on a real published level whose art extended well below and
		# past the edges of its own (much smaller) tile floor.
		var half_size := desired_size * 0.5
		min_px.x = minf(min_px.x, sprite.position.x - half_size.x)
		min_px.y = minf(min_px.y, sprite.position.y - half_size.y)
		max_px.x = maxf(max_px.x, sprite.position.x + half_size.x)
		max_px.y = maxf(max_px.y, sprite.position.y + half_size.y)
	arena.add_child(placements)

	var background := MapBackgroundScript.new()
	background.name = "Background"
	var tile_bounds := Rect2(min_px, max_px - min_px) if min_px.x != INF else Rect2(-200, -200, 400, 400)
	background.bounds = FixedView.compute(tile_bounds, BG_MARGIN)
	background.background_texture = background_texture
	arena.add_child(background)

	var spawn_points := Node2D.new()
	spawn_points.name = "SpawnPoints"
	for entry in data.get("spawn_points", []):
		var marker := Marker2D.new()
		marker.position = Vector2(float(entry[0]), float(entry[1]))
		spawn_points.add_child(marker)
	arena.add_child(spawn_points)

	var platforms := Node2D.new()
	platforms.name = "Platforms"
	platforms.z_index = 1 # same reasoning as Placements' own z_index above
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
