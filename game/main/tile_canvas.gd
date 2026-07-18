extends Control
class_name TileCanvas

# The level editor's paint surface -- click/drag sets tile cells, the same
# interaction model PixelCanvas uses for pixel art, just operating on a
# {Vector2i: tile_type} grid instead of an Image. `cells`/`spawn_points` are
# owned by the caller (Art Tool) and read back directly, same ownership
# model PixelCanvas uses for `image`.

const LevelData := preload("res://levels/level_data.gd")

# Matches tag_tileset.tres's tile_size exactly -- spawn points are stored/
# published in world-pixel coordinates (what Marker2D.position actually
# needs), so converting a painted grid cell to a spawn point has to use the
# real in-game tile size, not an arbitrary editor-only value.
const TILE_SIZE_PX := 10

# Same 3 colors tag_tiles.png's atlas uses, so the painted grid reads as a
# preview of the real tiles rather than arbitrary editor colors.
const TILE_COLORS := [
	Color(0.55, 0.55, 0.58), # 0: boundary
	Color(0.45, 0.32, 0.22), # 1: pillar
	Color(0.75, 0.75, 0.78), # 2: platform
]
const EMPTY_COLOR := Color(0.09, 0.09, 0.14)
const GRID_LINE_COLOR := Color(1, 1, 1, 0.04)
const SPAWN_COLOR := Color(0.35, 0.9, 0.55)

enum Tool { PAINT, ERASE, SPAWN }

@export var grid_size := Vector2i(70, 40) # paintable extent, in tile-grid cells
@export var zoom := 12

var cells: Dictionary = {} # Vector2i -> int (tile_type 0/1/2)
var spawn_points: Array = [] # Array[Vector2i], tile-grid coordinates
var current_tile_type := 0
var tool: int = Tool.PAINT

## Emitted after any cell/spawn-point change, so a host UI can update a
## live preview or an "N tiles, N spawns" status readout.
signal changed

var _is_pressing := false

func _ready() -> void:
	custom_minimum_size = Vector2(grid_size.x * zoom, grid_size.y * zoom)
	mouse_filter = Control.MOUSE_FILTER_STOP

func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, Vector2(grid_size) * zoom), EMPTY_COLOR)
	for coord in cells.keys():
		var tile_type: int = cells[coord]
		draw_rect(Rect2(Vector2(coord) * zoom, Vector2(zoom, zoom)), TILE_COLORS[tile_type])
	# Faint grid lines every 5 cells -- purely an orientation aid, cheap
	# enough to just redraw whole since the grid is small.
	for gx in range(0, grid_size.x + 1, 5):
		draw_line(Vector2(gx * zoom, 0), Vector2(gx * zoom, grid_size.y * zoom), GRID_LINE_COLOR)
	for gy in range(0, grid_size.y + 1, 5):
		draw_line(Vector2(0, gy * zoom), Vector2(grid_size.x * zoom, gy * zoom), GRID_LINE_COLOR)
	for sp in spawn_points:
		var center: Vector2 = Vector2(sp) * zoom + Vector2(zoom, zoom) * 0.5
		draw_circle(center, zoom * 0.35, SPAWN_COLOR)

func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			_is_pressing = true
			_apply_at(event.position)
		else:
			_is_pressing = false
	elif event is InputEventMouseMotion and _is_pressing:
		_apply_at(event.position)

func _apply_at(local_pos: Vector2) -> void:
	var cx := int(local_pos.x / zoom)
	var cy := int(local_pos.y / zoom)
	if cx < 0 or cy < 0 or cx >= grid_size.x or cy >= grid_size.y:
		return
	var coord := Vector2i(cx, cy)
	match tool:
		Tool.PAINT:
			cells[coord] = current_tile_type
		Tool.ERASE:
			cells.erase(coord)
		Tool.SPAWN:
			# Toggle per cell -- clicking an empty cell adds a spawn point,
			# clicking one that already has one removes it.
			var idx := spawn_points.find(coord)
			if idx != -1:
				spawn_points.remove_at(idx)
			else:
				spawn_points.append(coord)
	queue_redraw()
	changed.emit()

func clear() -> void:
	cells.clear()
	spawn_points.clear()
	queue_redraw()
	changed.emit()

## Converts the painted grid into the published level format -- tile-grid
## coordinates stay as-is (LevelData/TileMapLayer both index by cell, not
## pixel), spawn points convert to world-pixel positions centered in
## whichever cell they were placed on.
func to_level_data() -> Dictionary:
	var world_spawns: Array = []
	for sp in spawn_points:
		world_spawns.append(Vector2(sp) * TILE_SIZE_PX + Vector2(TILE_SIZE_PX, TILE_SIZE_PX) * 0.5)
	return LevelData.serialize(cells, world_spawns)
