extends Node

# One-off tool: converts tag_arena.tscn's hand-placed StaticBody2D+ColorRect
# platforms into a single TileMapLayer painted with tag_tileset.tres,
# preserving the exact same collision footprint (every platform in this
# arena's geometry already aligns exactly to the tileset's 10px grid -- see
# the REGIONS list below, one entry per platform, in world-space pixels).
# SpawnPoints and Waypoints are untouched. Run via:
#   godot --headless --path . res://tools/convert_arena_to_tiles.tscn
# One-off, not part of any ongoing pipeline (unlike bake_character_art.gd)
# -- once this runs, the arena scene itself is the source of truth to keep
# hand-editing in the Godot editor's own TileMap painter.

const TILE_SIZE := 10
const TILESET_PATH := "res://levels/tag_tileset.tres"
const ARENA_PATH := "res://levels/tag_arena.tscn"

# tile index matches build_tileset.gd's TILES order: 0=boundary, 1=pillar, 2=platform.
const REGIONS := [
	{"name": "Floor", "rect": Rect2(-1200, 440, 2400, 40), "tile": 0},
	{"name": "Ceiling", "rect": Rect2(-1200, -480, 2400, 40), "tile": 0},
	{"name": "LeftWall", "rect": Rect2(-1220, -480, 40, 960), "tile": 0},
	{"name": "RightWall", "rect": Rect2(1180, -480, 40, 960), "tile": 0},
	{"name": "CenterPillarL", "rect": Rect2(-160, 300, 20, 160), "tile": 1},
	{"name": "CenterPillarR", "rect": Rect2(140, 300, 20, 160), "tile": 1},
	{"name": "PlatformL", "rect": Rect2(-760, 150, 220, 20), "tile": 2},
	{"name": "PlatformR", "rect": Rect2(540, 150, 220, 20), "tile": 2},
	{"name": "PlatformTop", "rect": Rect2(-140, -70, 280, 20), "tile": 2},
	{"name": "PlatformOuterL", "rect": Rect2(-1040, -130, 180, 20), "tile": 2},
	{"name": "PlatformOuterR", "rect": Rect2(860, -130, 180, 20), "tile": 2},
]

func _ready() -> void:
	var tileset: TileSet = load(TILESET_PATH)
	var arena: Node2D = load(ARENA_PATH).instantiate()

	var tile_layer := TileMapLayer.new()
	tile_layer.name = "Tiles"
	tile_layer.tile_set = tileset

	var cell_count := 0
	for region in REGIONS:
		var r: Rect2 = region.rect
		var x0 := int(round(r.position.x / TILE_SIZE))
		var y0 := int(round(r.position.y / TILE_SIZE))
		var x1 := int(round((r.position.x + r.size.x) / TILE_SIZE))
		var y1 := int(round((r.position.y + r.size.y) / TILE_SIZE))
		for ty in range(y0, y1):
			for tx in range(x0, x1):
				tile_layer.set_cell(Vector2i(tx, ty), 0, Vector2i(region.tile, 0))
				cell_count += 1
		print("painted ", region.name, " (", (x1 - x0) * (y1 - y0), " cells)")

	# Remove the old hand-placed platform bodies -- SpawnPoints/Waypoints
	# (and anything else that isn't one of the platforms above) stay exactly
	# as they are.
	var region_names := {}
	for region in REGIONS:
		region_names[region.name] = true
	for child in arena.get_children().duplicate():
		if region_names.has(child.name):
			arena.remove_child(child)
			child.queue_free()

	arena.add_child(tile_layer)
	tile_layer.owner = arena

	var packed := PackedScene.new()
	var err := packed.pack(arena)
	if err != OK:
		push_error("pack failed: " + str(err))
		get_tree().quit()
		return
	err = ResourceSaver.save(packed, ARENA_PATH)
	print("saved arena, total cells=", cell_count, " err=", err)
	print("CONVERT_DONE")
	get_tree().quit()
