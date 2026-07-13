extends Control

# In-shop drawing tool: paints one small canvas per rig part (skins) or a
# single canvas (hats), then uploads it via SkinCatalog.add_drawn_skin/
# add_drawn_hat -- visible to everyone immediately, same as any catalog
# item (see skin_catalog.gd's top comment for the tradeoff this deliberately
# accepts: freehand strokes only, no arbitrary file upload).

const UIStyle := preload("res://ui/ui_style.gd")

const ZOOM := 14

const PALETTE := [
	Color(0.95, 0.95, 0.96), Color(0.1, 0.1, 0.12), Color(0.85, 0.2, 0.2),
	Color(0.25, 0.45, 0.85), Color(0.25, 0.75, 0.35), Color(0.9, 0.8, 0.15),
	Color(0.6, 0.3, 0.8), Color(0.9, 0.5, 0.15), Color(0.15, 0.75, 0.7),
	Color(0.9, 0.45, 0.7), Color(0.55, 0.4, 0.3),
]

@onready var name_edit: LineEdit = $VBox/NameEdit
@onready var part_tabs: HBoxContainer = $VBox/PartTabs
@onready var canvas_holder: CenterContainer = $VBox/CanvasPanel/CanvasHolder
@onready var palette_box: HBoxContainer = $VBox/PaletteRow/PaletteBox
@onready var eraser_button: Button = $VBox/PaletteRow/EraserButton
@onready var status_label: Label = $VBox/StatusLabel
@onready var upload_button: Button = $VBox/UploadButton
@onready var back_button: Button = $VBox/BackButton

var _mode := "skin" # "skin" or "hat"
var _images := {} # part_name (or "hat") -> Image, the artist's in-progress work
var _current_canvas: PixelCanvas = null
var _current_color: Color = PALETTE[2]
var _erasing := false
var _part_group := ButtonGroup.new()
var _color_group := ButtonGroup.new()

func setup(mode: String) -> void:
	_mode = mode

func _ready() -> void:
	UIStyle.add_background(self)
	$VBox/CanvasPanel.add_theme_stylebox_override("panel", UIStyle.panel_box(UIStyle.COLOR_SHOP, 0.05, 0.3))
	UIStyle.style_button(upload_button, UIStyle.COLOR_SHOP)
	UIStyle.style_button(eraser_button, UIStyle.COLOR_NEUTRAL, 8)
	UIStyle.style_back_button(back_button)

	upload_button.pressed.connect(_on_upload_pressed)
	back_button.pressed.connect(_on_back_pressed)
	eraser_button.pressed.connect(_on_eraser_pressed)
	_build_palette()

	if _mode == "skin":
		for part_name in SkinCatalog.PART_NAMES:
			_images[part_name] = _blank_image(SkinCatalog.PART_DEFS[part_name].rect.size)
			_build_part_tab_button(part_name)
		_show_part("head")
		name_edit.text = "My Skin"
		upload_button.text = "Upload Skin"
	else:
		_images["hat"] = _blank_image(SkinCatalog.PART_DEFS["head"].rect.size)
		part_tabs.visible = false
		_show_part("hat")
		name_edit.text = "My Hat"
		upload_button.text = "Upload Hat"

func _blank_image(size: Vector2i) -> Image:
	var img := Image.create(size.x, size.y, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	return img

func _build_palette() -> void:
	for color in PALETTE:
		var swatch := Button.new()
		swatch.custom_minimum_size = Vector2(26, 26)
		swatch.toggle_mode = true
		swatch.button_group = _color_group
		swatch.button_pressed = (color == _current_color)
		var sb := StyleBoxFlat.new()
		sb.bg_color = color
		sb.border_width_left = 2
		sb.border_width_top = 2
		sb.border_width_right = 2
		sb.border_width_bottom = 2
		sb.border_color = Color(1, 1, 1, 0.35)
		swatch.add_theme_stylebox_override("normal", sb)
		swatch.add_theme_stylebox_override("hover", sb)
		swatch.add_theme_stylebox_override("pressed", sb)
		swatch.pressed.connect(_on_color_pressed.bind(color))
		palette_box.add_child(swatch)

func _on_color_pressed(color: Color) -> void:
	_current_color = color
	_erasing = false
	_apply_tool_to_canvas()

func _on_eraser_pressed() -> void:
	_erasing = true
	_apply_tool_to_canvas()

func _apply_tool_to_canvas() -> void:
	if not _current_canvas:
		return
	_current_canvas.erasing = _erasing
	_current_canvas.paint_color = _current_color

func _build_part_tab_button(part_name: String) -> void:
	var btn := Button.new()
	btn.text = part_name.capitalize().replace("_", " ")
	btn.toggle_mode = true
	btn.button_group = _part_group
	btn.button_pressed = (part_name == "head")
	btn.pressed.connect(_show_part.bind(part_name))
	UIStyle.style_button(btn, UIStyle.COLOR_SHOP, 8)
	part_tabs.add_child(btn)

func _show_part(part_name: String) -> void:
	for child in canvas_holder.get_children():
		child.queue_free()
	var canvas := PixelCanvas.new(_images[part_name], ZOOM)
	canvas_holder.add_child(canvas)
	_current_canvas = canvas
	_apply_tool_to_canvas()

func _on_upload_pressed() -> void:
	var name_text := name_edit.text.strip_edges()
	if name_text.is_empty():
		name_text = "My Skin" if _mode == "skin" else "My Hat"
	status_label.text = "Uploading..."
	upload_button.disabled = true
	var id: String
	if _mode == "skin":
		id = await SkinCatalog.add_drawn_skin(_images, name_text)
	else:
		id = await SkinCatalog.add_drawn_hat(_images["hat"], name_text)
	upload_button.disabled = false
	if id.is_empty():
		status_label.text = "Couldn't upload that -- try again."
		return
	SkinCatalog.refresh_catalog()
	if _mode == "skin":
		SkinCatalog.select_skin(id)
	else:
		SkinCatalog.select_hat(id)
	_return_to_shop()

func _on_back_pressed() -> void:
	_return_to_shop()

func _return_to_shop() -> void:
	get_tree().change_scene_to_file("res://main/shop.tscn")
