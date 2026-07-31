extends Node

# One-off utility: reads a hand-built arena's "Tiles" TileMapLayer (solid
# ground/pillars/ledges baked as individual tiles, not a `platforms` rect
# list like every generated map has) and greedily merges its solid cells
# into a minimal set of rects in the exact same {x0,y0,x1,y1} convention
# game/levels/online_maps/catalog.gd and game/levels/local_maps/catalog.gd
# already use -- so a hand-built arena (currently only tag_arena.tscn,
# "Classic Arena") can also get a `platforms` list, for anything that reads
# one (ai_training/sim.py's MAP_PLATFORMS, primarily).
#
# Greedy "grow a rect as wide then as tall as it'll go" scan -- not a
# minimal decomposition, but always an exact cover of the solid cells, and
# in practice produces a small, sane rect count for the block-y shapes
# these tile arenas actually are. Also reports the arena's non-tile static
# platforms (StaticBody2D/AnimatableBody2D children, e.g. tag_arena.tscn's
# PlatformGap/PlatformLift bridges) separately, since those aren't in the
# TileMapLayer at all and need to be unioned in by hand afterward.
#
# Run via:
#   godot --headless --path . res://tools/extract_arena_rects.tscn -- --scene=res://levels/tag_arena.tscn

const TILE_SIZE := 10.0

func _ready() -> void:
	var scene_path := ""
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--scene="):
			scene_path = arg.substr(8)
	if scene_path.is_empty():
		print("ERROR: --scene=res://... is required (no default hand-built arena exists anymore)")
		get_tree().quit(1)
		return

	var arena = load(scene_path).instantiate()
	add_child(arena)

	var layer := _find_tile_layer(arena)
	if not layer:
		print("ERROR: no TileMapLayer found under ", scene_path)
		get_tree().quit(1)
		return

	var cells := {}
	for cell in layer.get_used_cells():
		cells[cell] = true

	var rects := _merge_to_rects(cells)
	print("=== TileMapLayer-derived platforms (%d rects) ===" % rects.size())
	for r in rects:
		print("(%d.0, %d.0, %d.0, %d.0)," % [r.x0, r.y0, r.x1, r.y1])

	print("=== Other static bodies (not in the TileMapLayer -- union these in by hand) ===")
	_report_static_bodies(arena)

	print("EXTRACT_DONE")
	get_tree().quit()

func _find_tile_layer(root: Node) -> TileMapLayer:
	if root is TileMapLayer:
		return root
	for child in root.get_children():
		var found := _find_tile_layer(child)
		if found:
			return found
	return null

## Greedy scan: for each not-yet-covered solid cell (row-major order), grow
## a run rightward while cells stay solid+uncovered, then grow that same
## column-run downward while every cell in it stays solid+uncovered each
## row. Marks every covered cell so it's never reused by a later rect.
func _merge_to_rects(cells: Dictionary) -> Array:
	var covered := {}
	var min_gx := 999999
	var max_gx := -999999
	var min_gy := 999999
	var max_gy := -999999
	for c in cells.keys():
		min_gx = mini(min_gx, c.x)
		max_gx = maxi(max_gx, c.x)
		min_gy = mini(min_gy, c.y)
		max_gy = maxi(max_gy, c.y)

	var rects := []
	for gy in range(min_gy, max_gy + 1):
		for gx in range(min_gx, max_gx + 1):
			var start := Vector2i(gx, gy)
			if not cells.has(start) or covered.has(start):
				continue
			var width := 1
			while cells.has(Vector2i(gx + width, gy)) and not covered.has(Vector2i(gx + width, gy)):
				width += 1
			var height := 1
			var can_grow := true
			while can_grow:
				for wx in range(width):
					var probe := Vector2i(gx + wx, gy + height)
					if not cells.has(probe) or covered.has(probe):
						can_grow = false
						break
				if can_grow:
					height += 1
			for hy in range(height):
				for wx in range(width):
					covered[Vector2i(gx + wx, gy + hy)] = true
			rects.append({
				"x0": gx * TILE_SIZE, "y0": gy * TILE_SIZE,
				"x1": (gx + width) * TILE_SIZE, "y1": (gy + height) * TILE_SIZE,
			})
	return rects

func _report_static_bodies(root: Node, path: String = "") -> void:
	for child in root.get_children():
		var child_path := path + "/" + child.name
		if (child is StaticBody2D or child is AnimatableBody2D) and child.name != "Tiles":
			var shape_node := child.get_node_or_null("CollisionShape2D")
			if shape_node and shape_node.shape is RectangleShape2D:
				var size: Vector2 = shape_node.shape.size
				var center: Vector2 = child.position + shape_node.position
				print("%s: center=%s size=%s -> (%.1f, %.1f, %.1f, %.1f)" % [
					child_path, center, size,
					center.x - size.x * 0.5, center.y - size.y * 0.5,
					center.x + size.x * 0.5, center.y + size.y * 0.5,
				])
		_report_static_bodies(child, child_path)
