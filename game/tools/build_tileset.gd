extends Node

# One-off tool: builds the tile atlas image + TileSet resource shared by
# every generated map (see tools/generate_local_maps.gd/generate_online_maps.gd).
# Run via:
#   godot --headless --path . res://tools/build_tileset.tscn
# Re-running regenerates both from scratch; safe/idempotent.
#
# Every map shares ONE plain flat-color tile (reverted from a per-map
# theme_color'd tile, per explicit request) -- atlas coord (0, 0) for
# everything. Kept as a 1x1-tile atlas/TileSet (rather than removing the
# atlas machinery entirely) so generate_local_maps.gd/generate_online_maps.gd
# and every already-generated map scene keep working unchanged; they all
# already just paint whatever index OnlineMapCatalog.tile_index_for()
# returns, which still resolves, it's just that every index now points at
# the same single plain tile.

const TILE_SIZE := 10
const OUT_ATLAS := "res://assets/tiles/tag_tiles.png"
const OUT_TILESET := "res://levels/tag_tileset.tres"
const TILE_COLOR := Color(0.6, 0.6, 0.65, 1)

func _ready() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://assets/tiles"))

	var atlas := Image.create(TILE_SIZE, TILE_SIZE, false, Image.FORMAT_RGBA8)
	atlas.fill(TILE_COLOR)
	atlas.save_png(OUT_ATLAS)
	print("wrote atlas: ", OUT_ATLAS, " (1 tile)")

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
	var coords := Vector2i(0, 0)
	source.create_tile(coords)
	var tile_data := source.get_tile_data(coords, 0)
	tile_data.add_collision_polygon(phys_layer_idx)
	tile_data.set_collision_polygon_points(phys_layer_idx, 0, full_tile_poly)

	var err := ResourceSaver.save(tileset, OUT_TILESET)
	print("wrote tileset: ", OUT_TILESET, " err=", err)
	print("BUILD_TILESET_DONE")
	get_tree().quit()
