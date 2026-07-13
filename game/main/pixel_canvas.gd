extends Control
class_name PixelCanvas

# A tiny pixel-art painting widget -- click/drag paints image pixels 1:1,
# displayed scaled up by `zoom` with nearest-neighbor filtering so brush
# strokes stay crisp instead of blurring. Used by skin_editor.gd (one
# instance per paintable cosmetic part, brush/eraser only via `erasing`) and
# by the standalone Art Tool (tools/art_tool.gd, the full toolset below) --
# the caller owns `image` and reads it back directly after painting, no
# signal round-trip needed for that.

enum Tool { BRUSH, ERASER, FILL, EYEDROPPER }

var image: Image
var zoom: int = 12
var paint_color := Color(1, 1, 1, 1)
var erasing := false # kept for skin_editor.gd's existing usage; equivalent to tool = ERASER
var tool: int = Tool.BRUSH
var brush_size: int = 1

## Emitted when the eyedropper tool picks a color, so a host UI can update
## whatever's showing the "current color" (e.g. deselect a palette swatch).
signal color_picked(color: Color)
## Emitted after any stroke actually changes the image (paint/erase/fill,
## and undo/redo) -- a live preview panel hooks this to refresh.
signal painted

var _texture_rect: TextureRect
var _is_pressing := false
var _undo_stack: Array = []
var _redo_stack: Array = []
const MAX_UNDO := 60

func _init(p_image: Image = null, p_zoom: int = 12) -> void:
	image = p_image
	zoom = p_zoom

func _ready() -> void:
	custom_minimum_size = Vector2(image.get_width() * zoom, image.get_height() * zoom)
	_texture_rect = TextureRect.new()
	_texture_rect.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_texture_rect.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_texture_rect.stretch_mode = TextureRect.STRETCH_SCALE
	_texture_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_texture_rect)
	_refresh_texture()

func _refresh_texture() -> void:
	_texture_rect.texture = ImageTexture.create_from_image(image)

func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			_push_undo()
			_is_pressing = true
			_apply_tool_at(event.position)
		else:
			_is_pressing = false
	elif event is InputEventMouseMotion and _is_pressing:
		_apply_tool_at(event.position)

func _apply_tool_at(local_pos: Vector2) -> void:
	var px := int(local_pos.x / zoom)
	var py := int(local_pos.y / zoom)
	if px < 0 or py < 0 or px >= image.get_width() or py >= image.get_height():
		return
	var effective_tool := Tool.ERASER if erasing else tool
	match effective_tool:
		Tool.BRUSH:
			_paint_at(px, py, paint_color)
		Tool.ERASER:
			_paint_at(px, py, Color(0, 0, 0, 0))
		Tool.FILL:
			_flood_fill(px, py, paint_color)
		Tool.EYEDROPPER:
			paint_color = image.get_pixel(px, py)
			color_picked.emit(paint_color)
	_refresh_texture()
	painted.emit()

func _paint_at(px: int, py: int, color: Color) -> void:
	var half := (brush_size - 1) / 2
	for oy in range(-half, brush_size - half):
		for ox in range(-half, brush_size - half):
			var x := px + ox
			var y := py + oy
			if x >= 0 and y >= 0 and x < image.get_width() and y < image.get_height():
				image.set_pixel(x, y, color)

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
