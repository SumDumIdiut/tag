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

# Same colors tag_tiles.png's atlas uses (see build_tileset.gd's TILES), so
# the painted grid reads as a preview of the real tiles rather than
# arbitrary editor colors. Indices 0-8: variant_index * 3 + type_index
# (variant-major -- see build_tileset.gd's comment on why: it keeps indices
# 0/1/2 exactly Boundary/Pillar/Platform's Piece variant, matching the
# original 3-tile atlas for backward compatibility with already-placed/
# published data), type order always [Boundary, Pillar, Platform], variant
# order always [Piece, Corner, Internal]. Indices 9-10 (Ice/Bouncy) are
# appended flat, outside that type/variant grid entirely -- see
# TILE_TYPE_NAMES below, they're not part of it.
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
	Color(0.65, 0.85, 0.95), # 9: ice
	Color(0.95, 0.35, 0.55), # 10: bouncy
]
const EMPTY_COLOR := Color(0.09, 0.09, 0.14)
const GRID_LINE_COLOR := Color(1, 1, 1, 0.04)
const SPAWN_COLOR := Color(0.35, 0.9, 0.55)
# Matches MovingPlatform's own Visual ColorRect color, so a placed platform
# reads as a preview of the real thing rather than an arbitrary editor color.
const PLATFORM_COLOR := Color(0.85, 0.55, 0.2)
const PLATFORM_PENDING_COLOR := Color(0.95, 0.8, 0.4)
const DEFAULT_PLATFORM_PERIOD_SEC := 4.0
const SELECTED_OUTLINE_COLOR := Color(1.0, 0.95, 0.3, 0.95)

enum Tool { PAINT, ERASE, SPAWN, PLATFORM, EDIT }
## What EDIT mode currently has grabbed -- a platform has two independently
## draggable handles (its start and end), so selecting "a platform" alone
## isn't enough to know which endpoint a drag should move.
enum SelectionKind { NONE, SPAWN, PLATFORM_START, PLATFORM_END }

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
## Emitted whenever EDIT mode's selection changes (a new object grabbed,
## the same one dragged -- position changes don't re-fire this, only a
## change of *what* is selected -- or deselected), so a host UI can show/
## hide/refresh a properties panel for whatever's currently selected.
signal selection_changed

var _is_pressing := false
var _selected_kind: int = SelectionKind.NONE
var _selected_spawn_index := -1
var _selected_platform_index := -1
var _dragging_selection := false

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
	match _selected_kind:
		SelectionKind.SPAWN:
			if _selected_spawn_index >= 0 and _selected_spawn_index < spawn_points.size():
				var c: Vector2 = Vector2(spawn_points[_selected_spawn_index]) * zoom + half
				draw_arc(c, zoom * 0.55, 0.0, TAU, 24, SELECTED_OUTLINE_COLOR, 2.5)
		SelectionKind.PLATFORM_START, SelectionKind.PLATFORM_END:
			if _selected_platform_index >= 0 and _selected_platform_index < platforms.size():
				var p: Dictionary = platforms[_selected_platform_index]
				var pt: Vector2i = p.start if _selected_kind == SelectionKind.PLATFORM_START else p.end
				var c: Vector2 = Vector2(pt) * zoom + half
				draw_rect(Rect2(c - half, half * 2.0), SELECTED_OUTLINE_COLOR, false, 2.5)

func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			_is_pressing = true
			if tool == Tool.EDIT:
				_start_edit_press(event.position)
			else:
				_apply_at(event.position)
		else:
			_is_pressing = false
			_dragging_selection = false
	elif event is InputEventMouseMotion and _is_pressing:
		if tool == Tool.EDIT:
			if _dragging_selection:
				_drag_selection_to(event.position)
		# Platform placement is two discrete clicks (start, then end), not a
		# drag -- unlike PAINT/ERASE/SPAWN, repeating on every motion event
		# while the button is held would place a garbage platform on every
		# pixel the mouse crossed.
		elif tool != Tool.PLATFORM:
			_apply_at(event.position)
	elif event is InputEventKey and event.pressed and not event.echo \
			and event.keycode == KEY_DELETE and tool == Tool.EDIT:
		delete_selected()

func _to_cell(local_pos: Vector2) -> Vector2i:
	return Vector2i(int(local_pos.x / zoom), int(local_pos.y / zoom))

func _apply_at(local_pos: Vector2) -> void:
	var coord := _to_cell(local_pos)
	if coord.x < 0 or coord.y < 0 or coord.x >= grid_size.x or coord.y >= grid_size.y:
		return
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

## EDIT mode's press handler -- grabbing an existing spawn point or platform
## endpoint selects it and starts a drag; clicking empty space deselects.
## Checked spawn points before platforms only because that's the order they
## were declared in; a cell can't be both anyway (spawn points and platform
## endpoints don't occupy shared bookkeeping) so there's no real precedence
## question here.
func _start_edit_press(local_pos: Vector2) -> void:
	var cell := _to_cell(local_pos)
	for i in spawn_points.size():
		if spawn_points[i] == cell:
			_select_spawn(i)
			_dragging_selection = true
			return
	for i in platforms.size():
		var p: Dictionary = platforms[i]
		if p.start == cell:
			_select_platform(i, SelectionKind.PLATFORM_START)
			_dragging_selection = true
			return
		if p.end == cell:
			_select_platform(i, SelectionKind.PLATFORM_END)
			_dragging_selection = true
			return
	deselect()

func _select_spawn(i: int) -> void:
	_selected_kind = SelectionKind.SPAWN
	_selected_spawn_index = i
	_selected_platform_index = -1
	queue_redraw()
	selection_changed.emit()

func _select_platform(i: int, kind: int) -> void:
	_selected_kind = kind
	_selected_platform_index = i
	_selected_spawn_index = -1
	queue_redraw()
	selection_changed.emit()

## Drags whatever's currently grabbed to follow the pointer, clamped to the
## paintable grid -- the direct click-and-drag manipulation a tile-grid
## click-to-place tool didn't have before (placing a spawn point or a
## platform endpoint used to mean deleting and re-placing it from scratch).
func _drag_selection_to(local_pos: Vector2) -> void:
	var cell := _to_cell(local_pos)
	cell.x = clampi(cell.x, 0, grid_size.x - 1)
	cell.y = clampi(cell.y, 0, grid_size.y - 1)
	match _selected_kind:
		SelectionKind.SPAWN:
			if _selected_spawn_index >= 0 and _selected_spawn_index < spawn_points.size():
				spawn_points[_selected_spawn_index] = cell
		SelectionKind.PLATFORM_START:
			if _selected_platform_index >= 0 and _selected_platform_index < platforms.size():
				platforms[_selected_platform_index]["start"] = cell
		SelectionKind.PLATFORM_END:
			if _selected_platform_index >= 0 and _selected_platform_index < platforms.size():
				platforms[_selected_platform_index]["end"] = cell
	queue_redraw()
	changed.emit()

func has_selection() -> bool:
	return _selected_kind != SelectionKind.NONE

func selected_kind() -> int:
	return _selected_kind

func get_selected_spawn() -> Vector2i:
	if _selected_spawn_index >= 0 and _selected_spawn_index < spawn_points.size():
		return spawn_points[_selected_spawn_index]
	return Vector2i.ZERO

## Numeric-entry counterpart to dragging -- a properties panel field calling
## this and a mouse drag both just move the same selected point.
func set_selected_spawn(cell: Vector2i) -> void:
	if _selected_spawn_index >= 0 and _selected_spawn_index < spawn_points.size():
		spawn_points[_selected_spawn_index] = cell
		queue_redraw()
		changed.emit()

func get_selected_platform() -> Dictionary:
	if _selected_platform_index >= 0 and _selected_platform_index < platforms.size():
		return platforms[_selected_platform_index]
	return {}

func set_selected_platform_start(cell: Vector2i) -> void:
	if _selected_platform_index >= 0 and _selected_platform_index < platforms.size():
		platforms[_selected_platform_index]["start"] = cell
		queue_redraw()
		changed.emit()

func set_selected_platform_end(cell: Vector2i) -> void:
	if _selected_platform_index >= 0 and _selected_platform_index < platforms.size():
		platforms[_selected_platform_index]["end"] = cell
		queue_redraw()
		changed.emit()

func set_selected_platform_period(period_sec: float) -> void:
	if _selected_platform_index >= 0 and _selected_platform_index < platforms.size():
		platforms[_selected_platform_index]["period_sec"] = period_sec
		changed.emit()

func delete_selected() -> void:
	match _selected_kind:
		SelectionKind.SPAWN:
			if _selected_spawn_index >= 0 and _selected_spawn_index < spawn_points.size():
				spawn_points.remove_at(_selected_spawn_index)
		SelectionKind.PLATFORM_START, SelectionKind.PLATFORM_END:
			if _selected_platform_index >= 0 and _selected_platform_index < platforms.size():
				platforms.remove_at(_selected_platform_index)
	deselect()
	changed.emit()

func deselect() -> void:
	if _selected_kind == SelectionKind.NONE:
		return
	_selected_kind = SelectionKind.NONE
	_selected_spawn_index = -1
	_selected_platform_index = -1
	queue_redraw()
	selection_changed.emit()

func clear() -> void:
	cells.clear()
	spawn_points.clear()
	platforms.clear()
	_has_pending_platform_start = false
	deselect()
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
