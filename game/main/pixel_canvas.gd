extends Control
class_name PixelCanvas

# A tiny pixel-art painting widget -- click/drag paints image pixels 1:1,
# displayed scaled up by `zoom` with nearest-neighbor filtering so brush
# strokes stay crisp instead of blurring. Used by skin_editor.gd, one
# instance per paintable cosmetic part; the caller owns `image` and reads it
# back directly after painting, no signal round-trip needed for that.

var image: Image
var zoom: int = 12
var paint_color := Color(1, 1, 1, 1)
var erasing := false

var _texture_rect: TextureRect
var _is_pressing := false

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
		_is_pressing = event.pressed
		if event.pressed:
			_paint_at(event.position)
	elif event is InputEventMouseMotion and _is_pressing:
		_paint_at(event.position)

func _paint_at(local_pos: Vector2) -> void:
	var px := int(local_pos.x / zoom)
	var py := int(local_pos.y / zoom)
	if px < 0 or py < 0 or px >= image.get_width() or py >= image.get_height():
		return
	image.set_pixel(px, py, Color(0, 0, 0, 0) if erasing else paint_color)
	_refresh_texture()
