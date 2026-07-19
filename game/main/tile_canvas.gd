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

# Same 9 colors tag_tiles.png's atlas uses (see build_tileset.gd's TILES),
# so the painted grid reads as a preview of the real tiles rather than
# arbitrary editor colors. Index = variant_index * 3 + type_index (variant-
# major -- see build_tileset.gd's comment on why: it keeps indices 0/1/2
# exactly Boundary/Pillar/Platform's Piece variant, matching the original
# 3-tile atlas for backward compatibility with already-placed/published
# data), type order always [Boundary, Pillar, Platform], variant order
# always [Piece, Corner, Internal].
const TILE_COLORS := [
	Color(0.5, 0.5, 0.55), # 0: boundary piece
	Color(0.6, 0.5, 0.35), # 1: pillar piece
	Color(0.65, 0.65, 0.7), # 2: platform piece
	Color(0.42, 0.42, 0.47), # 3: boundary corner
	Color(0.5, 0.41, 0.27), # 4: pillar corner
	Color(0.56, 0.56, 0.61), # 5: platform corner
	Color(0.58, 0.58, 0.63), # 6: boundary internal
	Color(0.68, 0.58, 0.42), # 7: pillar internal
	Color(0.73, 0.73, 0.78), # 8: platform internal
]
const EMPTY_COLOR := Color(0.09, 0.09, 0.14)
const GRID_LINE_COLOR := Color(1, 1, 1, 0.04)
const SPAWN_COLOR := Color(0.35, 0.9, 0.55)
# Matches MovingPlatform's own Visual ColorRect color, so a placed platform
# reads as a preview of the real thing rather than an arbitrary editor color.
const PLATFORM_COLOR := Color(0.85, 0.55, 0.2)
const PLATFORM_PENDING_COLOR := Color(0.95, 0.8, 0.4)
const DEFAULT_PLATFORM_PERIOD_SEC := 4.0

enum Tool { PAINT, ERASE, SPAWN, PLATFORM }

@export var grid_size := Vector2i(70, 40) # paintable extent, in tile-grid cells
@export var zoom := 12

var cells: Dictionary = {} # Vector2i -> int (tile_type 0-8, see TILE_COLORS)
var spawn_points: Array = [] # Array[Vector2i], tile-grid coordinates
# Array[{start: Vector2i, end: Vector2i, period_sec: float}], tile-grid
# coordinates -- mirrors LevelData's own "platforms" shape directly (see
# to_level_data()) so no conversion is needed at publish time beyond the
# spawn-point-style grid-to-pixel step tile coordinates never need.
var platforms: Array = []
var current_tile_type := 0
# Read by the host UI (Art Tool) to seed a period field, and by _apply_at
# when finalizing a new platform placement -- set externally the same way
# current_tile_type already is.
var current_platform_period_sec := DEFAULT_PLATFORM_PERIOD_SEC
var tool: int = Tool.PAINT
# Set after the first of a platform's two placement clicks; null (no
# pending Vector2i sentinel -- Godot has no nullable Vector2i, so this uses
# a separate has-pending flag instead) until the second click finalizes it.
var _has_pending_platform_start := false
var _pending_platform_start := Vector2i.ZERO

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
	var half := Vector2(zoom, zoom) * 0.5
	for p in platforms:
		var start_center: Vector2 = Vector2(p.start) * zoom + half
		var end_center: Vector2 = Vector2(p.end) * zoom + half
		draw_line(start_center, end_center, PLATFORM_COLOR, 2.0)
		draw_rect(Rect2(start_center - half * 0.7, half * 1.4), PLATFORM_COLOR)
		draw_rect(Rect2(end_center - half * 0.7, half * 1.4), PLATFORM_COLOR)
	if _has_pending_platform_start:
		var pending_center: Vector2 = Vector2(_pending_platform_start) * zoom + half
		draw_rect(Rect2(pending_center - half * 0.7, half * 1.4), PLATFORM_PENDING_COLOR)

func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			_is_pressing = true
			_apply_at(event.position)
		else:
			_is_pressing = false
	# Platform placement is two discrete clicks (start, then end), not a
	# drag -- unlike PAINT/ERASE/SPAWN, repeating on every motion event
	# while the button is held would place a garbage platform on every
	# pixel the mouse crossed.
	elif event is InputEventMouseMotion and _is_pressing and tool != Tool.PLATFORM:
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
		Tool.PLATFORM:
			_apply_platform_click(coord)
	queue_redraw()
	changed.emit()

## First click of a pair sets the pending start; the second finalizes a new
## platform ending at this cell. Clicking a cell that's already an existing
## platform's start or end (with no click pending) removes that platform
## instead -- same toggle-to-delete convenience SPAWN's click already has.
## Clicking the same cell twice in a row (an empty/zero-length platform)
## just cancels the pending start rather than creating a degenerate one.
func _apply_platform_click(coord: Vector2i) -> void:
	if _has_pending_platform_start:
		if coord != _pending_platform_start:
			platforms.append({"start": _pending_platform_start, "end": coord, "period_sec": current_platform_period_sec})
		_has_pending_platform_start = false
		return
	for i in platforms.size():
		var p: Dictionary = platforms[i]
		if p.start == coord or p.end == coord:
			platforms.remove_at(i)
			return
	_has_pending_platform_start = true
	_pending_platform_start = coord

func clear() -> void:
	cells.clear()
	spawn_points.clear()
	platforms.clear()
	_has_pending_platform_start = false
	queue_redraw()
	changed.emit()

## Converts the painted grid into the published level format -- tile-grid
## coordinates stay as-is (LevelData/TileMapLayer both index by cell, not
## pixel), spawn points convert to world-pixel positions centered in
## whichever cell they were placed on. Platforms stay tile-grid coordinates
## too (see moving_platform.gd), no conversion needed.
func to_level_data() -> Dictionary:
	var world_spawns: Array = []
	for sp in spawn_points:
		world_spawns.append(Vector2(sp) * TILE_SIZE_PX + Vector2(TILE_SIZE_PX, TILE_SIZE_PX) * 0.5)
	return LevelData.serialize(cells, world_spawns, platforms)
