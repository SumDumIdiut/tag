extends Control
class_name PixelCanvas

# A pixel-art painting widget -- click/drag paints image pixels 1:1,
# displayed scaled up by `zoom` with nearest-neighbor filtering so brush
# strokes stay crisp instead of blurring. Used by skin_editor.gd (one
# instance per paintable cosmetic part, brush/eraser only via `erasing`) and
# by the standalone Art Tool (tools/art_tool.gd, the full toolset below) --
# the caller owns `image` and reads it back directly after painting, no
# signal round-trip needed for that.

enum Tool {
	BRUSH, ERASER, FILL, EYEDROPPER,
	LINE, RECT, RECT_FILL, ELLIPSE, ELLIPSE_FILL,
	SELECT, MOVE, STAMP,
}

var image: Image
var zoom: int = 12
var paint_color := Color(1, 1, 1, 1)
var erasing := false # kept for skin_editor.gd's existing usage; equivalent to tool = ERASER
var tool: int = Tool.BRUSH
var brush_size: int = 1
## 0..1 -- painted color is alpha-blended onto the existing pixel instead of
## a hard replace when this is below 1. Lets the brush act like a soft/
## translucent tool (shading, highlights) without needing a separate mode.
var brush_alpha: float = 1.0
## Mirrors every paint operation across the canvas's vertical/horizontal
## center line(s) -- the standard "symmetry" tool most pixel-art editors
## have, invaluable for anything meant to look hand-crafted-symmetric
## (characters, tiles) without manually mirroring every stroke.
var mirror_h: bool = false
var mirror_v: bool = false
var show_grid: bool = false
## What copy/cut puts pixels into -- a plain Image, not a class-level
## static, so each canvas's clipboard is independent (matches how `image`
## itself is per-instance, not shared).
var clipboard: Image = null

signal color_picked(color: Color)
signal painted
## Emitted whenever the zoom level changes (via set_zoom), so a host UI can
## keep a "100%"-style readout in sync without polling.
signal zoom_changed(new_zoom: int)

var _texture_rect: TextureRect
var _overlay: Control
var _is_pressing := false
var _undo_stack: Array = []
var _redo_stack: Array = []
const MAX_UNDO := 60

# Shape-tool drag state (LINE/RECT/RECT_FILL/ELLIPSE/ELLIPSE_FILL): the
# image is restored to `_shape_base` and the shape re-drawn from
# `_shape_start` to the current pointer on every motion event, so the shape
# previews live instead of only appearing once the mouse is released.
var _shape_start := Vector2i.ZERO
var _shape_base: Image = null

# Selection state (SELECT/MOVE): `_selection` is the committed rect in
# pixel coordinates (empty/zero-size = no selection). MOVE drags the pixels
# currently inside it; the region it's lifted from is left transparent.
var _selection := Rect2i()
var _select_start := Vector2i.ZERO
var _move_base: Image = null
var _move_offset := Vector2i.ZERO

func _init(p_image: Image = null, p_zoom: int = 12) -> void:
	image = p_image
	zoom = p_zoom

func _ready() -> void:
	custom_minimum_size = Vector2(image.get_width() * zoom, image.get_height() * zoom)
	# A brand-new part starts fully transparent, which is indistinguishable
	# from "nothing rendered" against the tool's dark panel background --
	# a checkerboard behind the pixels is the standard paint-tool fix so an
	# empty canvas still visibly looks like a canvas.
	var checker := TextureRect.new()
	checker.texture = _make_checker_texture()
	checker.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	checker.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	checker.stretch_mode = TextureRect.STRETCH_TILE
	checker.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(checker)

	_texture_rect = TextureRect.new()
	_texture_rect.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_texture_rect.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_texture_rect.stretch_mode = TextureRect.STRETCH_SCALE
	_texture_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_texture_rect)
	_refresh_texture()

	# Grid lines + selection marquee are drawn on a separate overlay Control
	# rather than PixelCanvas itself, so _draw() logic for "decoration on
	# top of the image" stays independent of the image TextureRect below it.
	_overlay = Control.new()
	_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_overlay.draw.connect(_draw_overlay)
	add_child(_overlay)

func _make_checker_texture() -> ImageTexture:
	var tile := Image.create(zoom * 2, zoom * 2, false, Image.FORMAT_RGB8)
	tile.fill(Color(0.5, 0.5, 0.54))
	for y in range(zoom):
		for x in range(zoom):
			tile.set_pixel(x, y, Color(0.35, 0.35, 0.38))
	for y in range(zoom, zoom * 2):
		for x in range(zoom, zoom * 2):
			tile.set_pixel(x, y, Color(0.35, 0.35, 0.38))
	return ImageTexture.create_from_image(tile)

func _refresh_texture() -> void:
	_texture_rect.texture = ImageTexture.create_from_image(image)
	if _overlay:
		_overlay.queue_redraw()

## Changes zoom level at runtime (view-only -- doesn't touch image content),
## e.g. from a "+"/"-"/reset zoom control in a host toolbar.
func set_zoom(new_zoom: int) -> void:
	zoom = maxi(1, new_zoom)
	custom_minimum_size = Vector2(image.get_width() * zoom, image.get_height() * zoom)
	_texture_rect.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	var checker := get_child(0) as TextureRect
	if checker:
		checker.texture = _make_checker_texture()
	zoom_changed.emit(zoom)
	if _overlay:
		_overlay.queue_redraw()

func _draw_overlay() -> void:
	if show_grid and zoom >= 4:
		var grid_color := Color(1, 1, 1, 0.12)
		for x in range(image.get_width() + 1):
			_overlay.draw_line(Vector2(x * zoom, 0), Vector2(x * zoom, image.get_height() * zoom), grid_color)
		for y in range(image.get_height() + 1):
			_overlay.draw_line(Vector2(0, y * zoom), Vector2(image.get_width() * zoom, y * zoom), grid_color)
	if _selection.size != Vector2i.ZERO:
		var r := Rect2(_selection.position * zoom, _selection.size * zoom)
		_overlay.draw_rect(r, Color(0.3, 0.8, 1.0, 0.15), true)
		_overlay.draw_rect(r, Color(0.3, 0.8, 1.0, 0.9), false, 2.0)

func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			_on_press(event.position)
		else:
			_on_release(event.position)
	elif event is InputEventMouseMotion and _is_pressing:
		_on_drag(event.position)

func _to_cell(local_pos: Vector2) -> Vector2i:
	return Vector2i(int(local_pos.x / zoom), int(local_pos.y / zoom))

func _in_bounds(c: Vector2i) -> bool:
	return c.x >= 0 and c.y >= 0 and c.x < image.get_width() and c.y < image.get_height()

func _on_press(local_pos: Vector2) -> void:
	_is_pressing = true
	var cell := _to_cell(local_pos)
	match tool:
		Tool.LINE, Tool.RECT, Tool.RECT_FILL, Tool.ELLIPSE, Tool.ELLIPSE_FILL:
			_push_undo()
			_shape_start = cell
			_shape_base = image.duplicate()
		Tool.SELECT:
			_select_start = cell
			_selection = Rect2i(cell, Vector2i.ONE)
			_overlay.queue_redraw()
		Tool.MOVE:
			if _selection.size == Vector2i.ZERO or not _selection.has_point(cell):
				return
			_push_undo()
			_move_base = image.duplicate()
			_move_offset = Vector2i.ZERO
			_select_start = cell
		Tool.STAMP:
			if clipboard:
				_push_undo()
				_stamp_at(cell)
				_refresh_texture()
				painted.emit()
		_:
			_push_undo()
			_apply_tool_at(cell)

func _on_drag(local_pos: Vector2) -> void:
	var cell := _to_cell(local_pos)
	match tool:
		Tool.LINE, Tool.RECT, Tool.RECT_FILL, Tool.ELLIPSE, Tool.ELLIPSE_FILL:
			image = _shape_base.duplicate()
			_draw_shape_preview(_shape_start, cell)
			_refresh_texture()
		Tool.SELECT:
			var min_c := Vector2i(mini(_select_start.x, cell.x), mini(_select_start.y, cell.y))
			var max_c := Vector2i(maxi(_select_start.x, cell.x), maxi(_select_start.y, cell.y))
			_selection = Rect2i(min_c, max_c - min_c + Vector2i.ONE)
			_overlay.queue_redraw()
		Tool.MOVE:
			if not _move_base:
				return
			_move_offset = cell - _select_start
			_apply_move_preview()
		_:
			_apply_tool_at(cell)

func _on_release(_local_pos: Vector2) -> void:
	_is_pressing = false
	match tool:
		Tool.LINE, Tool.RECT, Tool.RECT_FILL, Tool.ELLIPSE, Tool.ELLIPSE_FILL:
			_shape_base = null
			painted.emit()
		Tool.MOVE:
			_move_base = null
	if tool != Tool.SELECT:
		return

func _apply_tool_at(cell: Vector2i) -> void:
	if not _in_bounds(cell):
		return
	var effective_tool := Tool.ERASER if erasing else tool
	match effective_tool:
		Tool.BRUSH:
			_paint_at(cell.x, cell.y, paint_color)
		Tool.ERASER:
			_paint_at(cell.x, cell.y, Color(0, 0, 0, 0))
		Tool.FILL:
			_flood_fill(cell.x, cell.y, paint_color)
		Tool.EYEDROPPER:
			paint_color = image.get_pixel(cell.x, cell.y)
			color_picked.emit(paint_color)
	_refresh_texture()
	painted.emit()

## Blends `color` onto the existing pixel at `brush_alpha` (1.0 = hard
## replace, matching the tool's original behavior exactly), then mirrors
## the stroke across whichever axes mirror_h/mirror_v have enabled.
func _paint_at(px: int, py: int, color: Color) -> void:
	var half := (brush_size - 1) / 2
	for oy in range(-half, brush_size - half):
		for ox in range(-half, brush_size - half):
			_paint_single(px + ox, py + oy, color)
			if mirror_h:
				_paint_single(image.get_width() - 1 - (px + ox), py + oy, color)
			if mirror_v:
				_paint_single(px + ox, image.get_height() - 1 - (py + oy), color)
			if mirror_h and mirror_v:
				_paint_single(image.get_width() - 1 - (px + ox), image.get_height() - 1 - (py + oy), color)

func _paint_single(x: int, y: int, color: Color) -> void:
	if x < 0 or y < 0 or x >= image.get_width() or y >= image.get_height():
		return
	if brush_alpha >= 1.0:
		image.set_pixel(x, y, color)
	else:
		var existing := image.get_pixel(x, y)
		image.set_pixel(x, y, existing.lerp(color, brush_alpha * color.a) if color.a > 0 else existing)

func _flood_fill(px: int, py: int, color: Color) -> void:
	var target := image.get_pixel(px, py)
	if target.is_equal_approx(color):
		return
	var w := image.get_width()
	var h := image.get_height()
	var stack: Array[Vector2i] = [Vector2i(px, py)]
	var visited := {}
	while not stack.is_empty():
		var p: Vector2i = stack.pop_back()
		if p.x < 0 or p.y < 0 or p.x >= w or p.y >= h or visited.has(p):
			continue
		visited[p] = true
		if not image.get_pixel(p.x, p.y).is_equal_approx(target):
			continue
		image.set_pixel(p.x, p.y, color)
		stack.append(Vector2i(p.x + 1, p.y))
		stack.append(Vector2i(p.x - 1, p.y))
		stack.append(Vector2i(p.x, p.y + 1))
		stack.append(Vector2i(p.x, p.y - 1))

# ─── Shape tools ────────────────────────────────────────────────────────────
func _draw_shape_preview(from: Vector2i, to: Vector2i) -> void:
	match tool:
		Tool.LINE:
			_draw_line(from, to, paint_color)
		Tool.RECT:
			_draw_rect_outline(from, to, paint_color)
		Tool.RECT_FILL:
			_draw_rect_filled(from, to, paint_color)
		Tool.ELLIPSE:
			_draw_ellipse(from, to, paint_color, false)
		Tool.ELLIPSE_FILL:
			_draw_ellipse(from, to, paint_color, true)

## Bresenham's line algorithm -- the standard integer-only approach for a
## pixel-perfect line with no gaps, regardless of slope.
func _draw_line(from: Vector2i, to: Vector2i, color: Color) -> void:
	var x0 := from.x; var y0 := from.y
	var x1 := to.x; var y1 := to.y
	var dx := absi(x1 - x0); var sx := 1 if x0 < x1 else -1
	var dy := -absi(y1 - y0); var sy := 1 if y0 < y1 else -1
	var err := dx + dy
	while true:
		_paint_single_bounded(x0, y0, color)
		if x0 == x1 and y0 == y1:
			break
		var e2 := 2 * err
		if e2 >= dy:
			err += dy
			x0 += sx
		if e2 <= dx:
			err += dx
			y0 += sy

func _draw_rect_outline(from: Vector2i, to: Vector2i, color: Color) -> void:
	var min_c := Vector2i(mini(from.x, to.x), mini(from.y, to.y))
	var max_c := Vector2i(maxi(from.x, to.x), maxi(from.y, to.y))
	for x in range(min_c.x, max_c.x + 1):
		_paint_single_bounded(x, min_c.y, color)
		_paint_single_bounded(x, max_c.y, color)
	for y in range(min_c.y, max_c.y + 1):
		_paint_single_bounded(min_c.x, y, color)
		_paint_single_bounded(max_c.x, y, color)

func _draw_rect_filled(from: Vector2i, to: Vector2i, color: Color) -> void:
	var min_c := Vector2i(mini(from.x, to.x), mini(from.y, to.y))
	var max_c := Vector2i(maxi(from.x, to.x), maxi(from.y, to.y))
	for y in range(min_c.y, max_c.y + 1):
		for x in range(min_c.x, max_c.x + 1):
			_paint_single_bounded(x, y, color)

## Midpoint-ellipse-style approach via a bounding box: for filled, every
## point inside the (from, to) box that satisfies the ellipse equation is
## painted; outline paints only points near the boundary. Simple and exact
## enough at the small pixel-art sizes this tool actually operates at.
func _draw_ellipse(from: Vector2i, to: Vector2i, color: Color, filled: bool) -> void:
	var min_c := Vector2i(mini(from.x, to.x), mini(from.y, to.y))
	var max_c := Vector2i(maxi(from.x, to.x), maxi(from.y, to.y))
	var cx := (min_c.x + max_c.x) / 2.0
	var cy := (min_c.y + max_c.y) / 2.0
	var rx := maxf((max_c.x - min_c.x) / 2.0, 0.5)
	var ry := maxf((max_c.y - min_c.y) / 2.0, 0.5)
	for y in range(min_c.y, max_c.y + 1):
		for x in range(min_c.x, max_c.x + 1):
			var nx := (x + 0.5 - cx - 0.5) / rx
			var ny := (y + 0.5 - cy - 0.5) / ry
			var d := nx * nx + ny * ny
			if filled:
				if d <= 1.0:
					_paint_single_bounded(x, y, color)
			else:
				if d <= 1.0 and d > 0.65:
					_paint_single_bounded(x, y, color)

func _paint_single_bounded(x: int, y: int, color: Color) -> void:
	if x >= 0 and y >= 0 and x < image.get_width() and y < image.get_height():
		image.set_pixel(x, y, color)

# ─── Selection / move / stamp ───────────────────────────────────────────────
func _apply_move_preview() -> void:
	image = _move_base.duplicate()
	var w := image.get_width(); var h := image.get_height()
	for y in range(_selection.position.y, _selection.position.y + _selection.size.y):
		for x in range(_selection.position.x, _selection.position.x + _selection.size.x):
			if x < 0 or y < 0 or x >= w or y >= h:
				continue
			var src := _move_base.get_pixel(x, y)
			image.set_pixel(x, y, Color(0, 0, 0, 0))
			var dx := x + _move_offset.x; var dy := y + _move_offset.y
			if dx >= 0 and dy >= 0 and dx < w and dy < h:
				image.set_pixel(dx, dy, src)
	_refresh_texture()
	painted.emit()

## Copies the current selection into `clipboard` (a standalone Image sized
## to just the selection, not the whole canvas), so paste/stamp can place it
## anywhere without carrying the selection rect's absolute position along.
func copy_selection() -> void:
	if _selection.size == Vector2i.ZERO:
		return
	clipboard = image.get_region(_selection)

func cut_selection() -> void:
	if _selection.size == Vector2i.ZERO:
		return
	copy_selection()
	_push_undo()
	for y in range(_selection.position.y, _selection.position.y + _selection.size.y):
		for x in range(_selection.position.x, _selection.position.x + _selection.size.x):
			_paint_single_bounded(x, y, Color(0, 0, 0, 0))
	_refresh_texture()
	painted.emit()

## Stamps `clipboard` centered on `cell` -- used by both the STAMP tool
## (click anywhere to place) and paste (places at the canvas center).
func _stamp_at(cell: Vector2i) -> void:
	if not clipboard:
		return
	var origin := cell - Vector2i(clipboard.get_width() / 2, clipboard.get_height() / 2)
	for y in range(clipboard.get_height()):
		for x in range(clipboard.get_width()):
			var c := clipboard.get_pixel(x, y)
			if c.a > 0:
				_paint_single_bounded(origin.x + x, origin.y + y, c)

func paste() -> void:
	if not clipboard:
		return
	_push_undo()
	_stamp_at(Vector2i(image.get_width() / 2, image.get_height() / 2))
	_refresh_texture()
	painted.emit()

func clear_selection() -> void:
	_selection = Rect2i()
	if _overlay:
		_overlay.queue_redraw()

# ─── Whole-canvas operations ────────────────────────────────────────────────
func clear_canvas() -> void:
	_push_undo()
	image.fill(Color(0, 0, 0, 0))
	_refresh_texture()
	painted.emit()

func invert_colors() -> void:
	_push_undo()
	for y in range(image.get_height()):
		for x in range(image.get_width()):
			var c := image.get_pixel(x, y)
			image.set_pixel(x, y, Color(1.0 - c.r, 1.0 - c.g, 1.0 - c.b, c.a))
	_refresh_texture()
	painted.emit()

func flip_horizontal() -> void:
	_push_undo()
	var w := image.get_width(); var h := image.get_height()
	var src := image.duplicate()
	for y in range(h):
		for x in range(w):
			image.set_pixel(x, y, src.get_pixel(w - 1 - x, y))
	_refresh_texture()
	painted.emit()

func flip_vertical() -> void:
	_push_undo()
	var w := image.get_width(); var h := image.get_height()
	var src := image.duplicate()
	for y in range(h):
		for x in range(w):
			image.set_pixel(x, y, src.get_pixel(x, h - 1 - y))
	_refresh_texture()
	painted.emit()

## Only exact for square canvases (width == height), which covers this
## tool's actual use cases (skin/hat parts are all square-ish, tile
## textures are always square) -- a non-square rotate-in-place would need
## to resize the canvas, which no caller currently expects.
func rotate_90_cw() -> void:
	if image.get_width() != image.get_height():
		return
	_push_undo()
	var n := image.get_width()
	var src := image.duplicate()
	for y in range(n):
		for x in range(n):
			image.set_pixel(n - 1 - y, x, src.get_pixel(x, y))
	_refresh_texture()
	painted.emit()

func rotate_90_ccw() -> void:
	if image.get_width() != image.get_height():
		return
	_push_undo()
	var n := image.get_width()
	var src := image.duplicate()
	for y in range(n):
		for x in range(n):
			image.set_pixel(y, n - 1 - x, src.get_pixel(x, y))
	_refresh_texture()
	painted.emit()

func _push_undo() -> void:
	_undo_stack.append(image.duplicate())
	if _undo_stack.size() > MAX_UNDO:
		_undo_stack.pop_front()
	_redo_stack.clear()

func undo() -> void:
	if _undo_stack.is_empty():
		return
	_redo_stack.append(image.duplicate())
	image = _undo_stack.pop_back()
	_refresh_texture()
	painted.emit()

func redo() -> void:
	if _redo_stack.is_empty():
		return
	_undo_stack.append(image.duplicate())
	image = _redo_stack.pop_back()
	_refresh_texture()
	painted.emit()
