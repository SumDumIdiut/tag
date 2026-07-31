extends Node

# One-off tool: builds the tile atlas image + TileSet resource shared by
# every generated map (see tools/generate_local_maps.gd/generate_online_maps.gd).
# Run via:
#   godot --headless --path . res://tools/build_tileset.tscn
# Re-running regenerates both from scratch; safe/idempotent.
#
# One tile per LocalMapCatalog map, laid out left-to-right in a single row,
# atlas coord (index, 0) -- each map's platforms paint with its own
# theme_color (see catalog.gd) instead of a single shared grey, so a map
# reads as visually distinct at a glance, not just via its background. Each
# tile gets a light diagonal 2-tone split rather than a flat fill -- pure
# flat color reads as a solid color swatch at 10px; the split still reads
# as "one material" but gives the platform surface a hint of texture.

const LocalMapCatalog := preload("res://levels/local_maps/catalog.gd")
const OnlineMapCatalog := preload("res://levels/online_maps/catalog.gd")

const TILE_SIZE := 10
const OUT_ATLAS := "res://assets/tiles/tag_tiles.png"
const OUT_TILESET := "res://levels/tag_tileset.tres"
const FALLBACK_COLOR := Color(0.6, 0.6, 0.65, 1) # used for any map missing a theme_color, defensive only

## Every local map gets a slot (index == its LocalMapCatalog.MAP_ORDER
## position), then every online-exclusive map gets one appended after --
## see OnlineMapCatalog.ONLINE_ONLY_MAP_ORDER's own comment. tile_index_for()
## in both generate_*_maps.gd tools computes the same indices from the same
## two lists, so this atlas layout and what actually gets painted onto each
## generated map's Tiles layer can never drift apart.
static func all_theme_defs() -> Array:
	var defs: Array = []
	for id in LocalMapCatalog.MAP_ORDER:
		defs.append(LocalMapCatalog.MAPS[id])
	for id in OnlineMapCatalog.ONLINE_ONLY_MAP_ORDER:
		defs.append(OnlineMapCatalog.MAPS[id])
	return defs

func _ready() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://assets/tiles"))

	var defs := all_theme_defs()
	var count := defs.size()
	var atlas := Image.create(TILE_SIZE * count, TILE_SIZE, false, Image.FORMAT_RGBA8)
	for i in count:
		var base: Color = defs[i].get("theme_color", FALLBACK_COLOR)
		_paint_tile(atlas, i, base)
	atlas.save_png(OUT_ATLAS)
	print("wrote atlas: ", OUT_ATLAS, " (", count, " tiles)")

	# Built directly from the in-memory Image rather than round-tripping
	# through load(OUT_ATLAS) -- confirmed live that a plain load() right
	# after save_png() fails ("No loader found for resource") when this
	# runs outside the editor proper, since nothing has driven the asset
	# through Godot's importer yet and a bare script run doesn't trigger
	# that automatically. tag_tiles.png is still written to disk above (and
	# will get picked up as a real external resource the next time the
	# project's imported normally, e.g. opening it in the editor once) --
	# this just doesn't depend on that having already happened.
	var tex: Texture2D = ImageTexture.create_from_image(atlas)
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
	for i in count:
		var coords := Vector2i(i, 0)
		source.create_tile(coords)
		var tile_data := source.get_tile_data(coords, 0)
		tile_data.add_collision_polygon(phys_layer_idx)
		tile_data.set_collision_polygon_points(phys_layer_idx, 0, full_tile_poly)

	var err := ResourceSaver.save(tileset, OUT_TILESET)
	print("wrote tileset: ", OUT_TILESET, " err=", err)
	print("BUILD_TILESET_DONE")
	get_tree().quit()

## Diagonal 2-tone split: a touch lighter above-left of the diagonal, a
## touch darker below-right -- reads as one textured material, not two
## separate colors, at both 10px in-game and whatever size a screenshot
## or icon scales it to.
func _paint_tile(atlas: Image, index: int, base: Color) -> void:
	var light := base.lightened(0.12)
	var dark := base.darkened(0.12)
	var x_off := index * TILE_SIZE
	for y in TILE_SIZE:
		for x in TILE_SIZE:
			var c := light if (x + y) < TILE_SIZE else dark
			atlas.set_pixel(x_off + x, y, c)
