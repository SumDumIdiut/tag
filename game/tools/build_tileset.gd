extends Node

# One-off tool: builds the tile atlas image + TileSet resource used by
# tag_arena.tscn (see convert_arena_to_tiles.gd) and any future hand-painted
# level. Run via:
#   godot --headless --path . res://tools/build_tileset.tscn
# Re-running regenerates both from scratch; safe/idempotent.

const TILE_SIZE := 10
const OUT_ATLAS := "res://assets/tiles/tag_tiles.png"
const OUT_TILESET := "res://levels/tag_tileset.tres"

# Each of the 3 base types (matching tag_arena.tscn's original ColorRects,
# same order convert_arena_to_tiles.gd expects) now gets 3 art variants --
# Piece (a straight edge), Corner, and Internal (fully surrounded) -- so a
# hand-placed level can use the right-looking piece at a platform's edges/
# corners instead of one flat texture tiling awkwardly everywhere.
#
# Laid out **variant-major** (all 3 types' Piece, then all 3 types'
# Corner, then all 3 types' Internal) rather than type-major, specifically
# so atlas indices 0/1/2 stay exactly Boundary/Pillar/Platform's Piece
# variant -- the same colors, in the same order, at the same atlas
# coordinates the original 3-tile atlas used. That's what keeps this change
# backward compatible with data that already encodes raw tile_type ints
# 0/1/2: tag_arena.tscn's already-painted TileMapLayer cells, and any
# level already published to the relay server before this change (see
# level_data.gd). Index into this array is exactly what tile_type means
# everywhere else (level_data.gd, tile_canvas.gd, art_tool.gd's
# tile_index()): variant_index * 3 + type_index, type order always
# [Boundary, Pillar, Platform] and variant order always [Piece, Corner,
# Internal] -- see VARIANT_NAMES below, which every other file's
# tile-index math assumes matches this.
const VARIANT_NAMES := ["Piece", "Corner", "Internal"]
const TILES := [
	{"name": "boundary piece", "color": Color(0.5, 0.5, 0.55, 1)},
	{"name": "pillar piece", "color": Color(0.6, 0.5, 0.35, 1)},
	{"name": "platform piece", "color": Color(0.65, 0.65, 0.7, 1)},
	{"name": "boundary corner", "color": Color(0.42, 0.42, 0.47, 1)},
	{"name": "pillar corner", "color": Color(0.5, 0.41, 0.27, 1)},
	{"name": "platform corner", "color": Color(0.56, 0.56, 0.61, 1)},
	{"name": "boundary internal", "color": Color(0.58, 0.58, 0.63, 1)},
	{"name": "pillar internal", "color": Color(0.68, 0.58, 0.42, 1)},
	{"name": "platform internal", "color": Color(0.73, 0.73, 0.78, 1)},
]

func _ready() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://assets/tiles"))

	var atlas := Image.create(TILE_SIZE * TILES.size(), TILE_SIZE, false, Image.FORMAT_RGBA8)
	for i in TILES.size():
		atlas.fill_rect(Rect2i(i * TILE_SIZE, 0, TILE_SIZE, TILE_SIZE), TILES[i].color)
	atlas.save_png(OUT_ATLAS)
	print("wrote atlas: ", OUT_ATLAS)

	# Loaded back rather than kept as the in-memory ImageTexture just built
	# -- assigning that directly would make the saved TileSet embed a raw
	# copy of the pixel data instead of referencing tag_tiles.png, which
	# would leave that file on disk but silently unused by the actual
	# tileset. Loading it back makes it a real external resource reference,
	# so the atlas stays its own editable file (paint over it like any
	# other sprite) rather than baked into the .tres.
	var tex: Texture2D = load(OUT_ATLAS)
	var tileset := TileSet.new()
	tileset.tile_size = Vector2i(TILE_SIZE, TILE_SIZE)
	tileset.add_physics_layer()
	var phys_layer_idx := tileset.get_physics_layers_count() - 1
	# Matches every platform's current collision_layer = 1 (Godot's default
	# "World" bit, also what WORLD_COLLISION_MASK in player.gd/npc.gd/
	# waypoint_graph.gd checks against) -- static tile geometry doesn't need
	# to detect anything itself, so the mask stays empty.
	tileset.set_physics_layer_collision_layer(phys_layer_idx, 1)
	tileset.set_physics_layer_collision_mask(phys_layer_idx, 0)

	var source := TileSetAtlasSource.new()
	source.texture = tex
	source.texture_region_size = Vector2i(TILE_SIZE, TILE_SIZE)
	# The source has to actually belong to the tileset before its tiles'
	# TileData objects know about the tileset's physics layers -- configuring
	# collision polygons on a not-yet-added source's tiles fails with
	# "physics.size() = 0" (the TileData's own synced-from-tileset physics
	# layer list is still empty at that point).
	tileset.add_source(source, 0)

	var half := TILE_SIZE / 2.0
	var full_tile_poly := PackedVector2Array([
		Vector2(-half, -half), Vector2(half, -half), Vector2(half, half), Vector2(-half, half),
	])
	for i in TILES.size():
		var coords := Vector2i(i, 0)
		source.create_tile(coords)
		var tile_data := source.get_tile_data(coords, 0)
		tile_data.add_collision_polygon(phys_layer_idx)
		tile_data.set_collision_polygon_points(phys_layer_idx, 0, full_tile_poly)

	var err := ResourceSaver.save(tileset, OUT_TILESET)
	print("wrote tileset: ", OUT_TILESET, " err=", err)
	print("BUILD_TILESET_DONE")
	get_tree().quit()
