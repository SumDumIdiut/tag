extends Control

# Standalone paint tool, exported as its own executable (TagArtTool.exe, see
# export_presets.cfg's "Art Tool" preset) -- a friend downloads this,
# nothing else, and it already contains every sprite the game uses (the
# templates from game/assets/character_templates/ are bundled into this
# tool's own .pck at export time). Paints in the same neutral marker tones
# tools/bake_character_art.gd looks for, so an exported edit slots straight
# into the real pipeline with zero extra steps on their end.

const UIStyle := preload("res://ui/ui_style.gd")
const CharacterPreviewScene := preload("res://ui/character_preview.gd")
const PixelCanvasScene := preload("res://main/pixel_canvas.gd")

const TEMPLATE_DIR := "res://assets/character_templates"
const ZOOM := 18

const PART_LIST := [
	{"key": "torso", "label": "Torso", "is_hat": false},
	{"key": "head", "label": "Head", "is_hat": false},
	{"key": "left_arm", "label": "Left Arm", "is_hat": false},
	{"key": "right_arm", "label": "Right Arm", "is_hat": false},
	{"key": "left_leg", "label": "Left Leg", "is_hat": false},
	{"key": "right_leg", "label": "Right Leg", "is_hat": false},
	{"key": "cap", "label": "Cap (hat)", "is_hat": true},
	{"key": "beanie", "label": "Beanie (hat)", "is_hat": true},
	{"key": "tophat", "label": "Top Hat (hat)", "is_hat": true},
	{"key": "crown", "label": "Crown (hat)", "is_hat": true},
]

const PREVIEW_SKINS := ["red", "blue", "teal"]
const HAT_OPTIONS := ["None", "cap", "beanie", "tophat", "crown"]

const INSTRUCTIONS_TEXT := """Thanks for drawing for Tag!

To get your art into the actual game:
1. Zip up this whole "edited_templates" folder.
2. Send it to whoever gave you this tool (Discord, email, wherever),
   or open a pull request on the game's GitHub repo replacing the
   matching files under game/assets/character_templates/ (and
   game/assets/character_templates/hats/ for hat files) with these.
3. Once it's merged into the main branch, every future automatic build
   of the game will already include your art -- nothing else to do.

Only edit the shapes -- if you paint in a brand new color instead of
the gray "Base/Shade/Highlight" swatches, that's fine too, it'll just
get a simple recolor per skin rather than the exact shading the
original design used. The gray swatches exist so your edit can share
the same shading trick across all 8 skin colors automatically.
"""

@onready var part_list: VBoxContainer = $VBox/MainRow/PartPanel/PartScroll/PartList
@onready var canvas_holder: CenterContainer = $VBox/MainRow/CanvasPanel/CanvasBox/CanvasHolder
@onready var toolbar: HBoxContainer = $VBox/MainRow/CanvasPanel/CanvasBox/Toolbar
@onready var marker_row: HBoxContainer = $VBox/MainRow/RightPanel/RightScroll/RightBox/MarkerRow
@onready var color_picker: ColorPicker = $VBox/MainRow/RightPanel/RightScroll/RightBox/ColorPicker
@onready var hat_select_row: HBoxContainer = $VBox/MainRow/RightPanel/RightScroll/RightBox/HatSelectRow
@onready var preview_row: HBoxContainer = $VBox/MainRow/RightPanel/RightScroll/RightBox/PreviewRow
@onready var status_label: Label = $VBox/BottomRow/StatusLabel
@onready var export_button: Button = $VBox/BottomRow/ExportButton

var _images := {} # key (part name or hat shape) -> Image, the working copy
var _current_key := "torso"
var _current_canvas: PixelCanvas = null
var _part_buttons := {}
var _preview_hat := "" # "" = no hat shown in preview
var _previews := []
var _part_group := ButtonGroup.new()
var _tool_group: ButtonGroup = null
var _current_tool := 0 # PixelCanvas.Tool.BRUSH

func _ready() -> void:
	get_window().size = Vector2i(1300, 860)
	get_window().title = "Tag Art Tool"
	UIStyle.add_background(self)
	_load_images()
	_build_part_list()
	_build_toolbar()
	_build_marker_row()
	_build_hat_select_row()
	_build_previews()
	color_picker.color_changed.connect(_on_color_picked_from_wheel)
	export_button.pressed.connect(_on_export_pressed)
	UIStyle.style_button(export_button, UIStyle.COLOR_SHOP)
	_show_part("torso")
	_refresh_previews()

func _load_images() -> void:
	for entry in PART_LIST:
		var key: String = entry.key
		var path: String = "%s/hats/%s.png" % [TEMPLATE_DIR, key] if entry.is_hat else "%s/%s.png" % [TEMPLATE_DIR, key]
		# load(), not Image.load() -- this needs to work from inside the
		# exported .pck (that's the whole point: the tool ships bundled
		# with every current template), and Image.load() only ever reads
		# raw files off disk, which breaks the moment this is an export.
		if ResourceLoader.exists(path):
			var tex: Texture2D = load(path)
			_images[key] = tex.get_image()
		else:
			# Shouldn't happen (templates are bundled into this tool's own
			# .pck at export time) but fall back to a blank canvas rather
			# than crash if one's ever missing.
			var size: Vector2i = Vector2i(SkinCatalog.HAT_WIDTH, SkinCatalog.HAT_HEIGHT) if entry.is_hat else SkinCatalog.PART_DEFS[key].rect.size
			var blank := Image.create(size.x, size.y, false, Image.FORMAT_RGBA8)
			blank.fill(Color(0, 0, 0, 0))
			_images[key] = blank

func _build_part_list() -> void:
	part_list.add_child(_section_label("BODY"))
	for entry in PART_LIST:
		if not entry.is_hat:
			part_list.add_child(_build_part_button(entry))
	part_list.add_child(_section_label("HATS"))
	for entry in PART_LIST:
		if entry.is_hat:
			part_list.add_child(_build_part_button(entry))

func _section_label(text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", 12)
	l.add_theme_color_override("font_color", Color(0.7, 0.72, 0.78))
	return l

func _build_part_button(entry: Dictionary) -> Button:
	var btn := Button.new()
	btn.text = entry.label
	btn.toggle_mode = true
	btn.button_group = _part_group
	btn.button_pressed = (entry.key == _current_key)
	UIStyle.style_button(btn, UIStyle.COLOR_SHOP, 8)
	btn.pressed.connect(_show_part.bind(entry.key))
	_part_buttons[entry.key] = btn
	return btn

func _show_part(key: String) -> void:
	_current_key = key
	for k in _part_buttons:
		_part_buttons[k].button_pressed = (k == key)
	if _current_canvas:
		_current_canvas.queue_free()
	var canvas = PixelCanvasScene.new(_images[key], ZOOM)
	canvas_holder.add_child(canvas)
	canvas.painted.connect(_on_painted)
	canvas.color_picked.connect(_on_eyedropper_picked)
	_current_canvas = canvas
	_apply_tool_state()

func _build_toolbar() -> void:
	var brush_btn := _tool_button("Brush", 0)
	var eraser_btn := _tool_button("Eraser", 1)
	var fill_btn := _tool_button("Fill", 2)
	var eyedrop_btn := _tool_button("Eyedrop", 3)
	for b in [brush_btn, eraser_btn, fill_btn, eyedrop_btn]:
		toolbar.add_child(b)
	brush_btn.button_pressed = true

	var sep := VSeparator.new()
	toolbar.add_child(sep)

	for size_px in [1, 2, 3]:
		var size_btn := Button.new()
		size_btn.text = "%dpx" % size_px
		size_btn.custom_minimum_size = Vector2(44, 0)
		UIStyle.style_button(size_btn, UIStyle.COLOR_NEUTRAL, 8)
		size_btn.pressed.connect(func():
			if _current_canvas:
				_current_canvas.brush_size = size_px
		)
		toolbar.add_child(size_btn)

	var sep2 := VSeparator.new()
	toolbar.add_child(sep2)

	var undo_btn := Button.new()
	undo_btn.text = "Undo"
	UIStyle.style_button(undo_btn, UIStyle.COLOR_NEUTRAL, 8)
	undo_btn.pressed.connect(func():
		if _current_canvas:
			_current_canvas.undo()
	)
	var redo_btn := Button.new()
	redo_btn.text = "Redo"
	UIStyle.style_button(redo_btn, UIStyle.COLOR_NEUTRAL, 8)
	redo_btn.pressed.connect(func():
		if _current_canvas:
			_current_canvas.redo()
	)
	toolbar.add_child(undo_btn)
	toolbar.add_child(redo_btn)

func _tool_button(label: String, tool_id: int) -> Button:
	var btn := Button.new()
	btn.text = label
	btn.toggle_mode = true
	if not _tool_group:
		_tool_group = ButtonGroup.new()
	btn.button_group = _tool_group
	UIStyle.style_button(btn, UIStyle.COLOR_LOCAL, 8)
	btn.pressed.connect(func():
		_current_tool = tool_id
		_apply_tool_state()
	)
	return btn

func _apply_tool_state() -> void:
	if _current_canvas:
		_current_canvas.tool = _current_tool
		_current_canvas.erasing = false
		_current_canvas.paint_color = color_picker.color

func _build_marker_row() -> void:
	var markers := [
		{"label": "Base", "color": SkinCatalog.TEMPLATE_BASE},
		{"label": "Shade", "color": SkinCatalog.TEMPLATE_SHADE},
		{"label": "Hi-lite", "color": SkinCatalog.TEMPLATE_HIGHLIGHT},
	]
	for m in markers:
		var btn := Button.new()
		btn.custom_minimum_size = Vector2(0, 34)
		btn.size_flags_horizontal = SIZE_EXPAND_FILL
		btn.text = m.label
		var sb := StyleBoxFlat.new()
		sb.bg_color = m.color
		sb.border_width_left = 2
		sb.border_width_top = 2
		sb.border_width_right = 2
		sb.border_width_bottom = 2
		sb.border_color = Color(1, 1, 1, 0.35)
		sb.corner_radius_top_left = 6
		sb.corner_radius_top_right = 6
		sb.corner_radius_bottom_right = 6
		sb.corner_radius_bottom_left = 6
		btn.add_theme_stylebox_override("normal", sb)
		btn.add_theme_stylebox_override("hover", sb)
		btn.add_theme_stylebox_override("pressed", sb)
		btn.add_theme_color_override("font_color", Color(0, 0, 0, 0.75))
		btn.add_theme_color_override("font_hover_color", Color(0, 0, 0, 0.75))
		var swatch_color: Color = m.color
		btn.pressed.connect(func():
			color_picker.color = swatch_color
			if _current_canvas:
				_current_canvas.paint_color = swatch_color
		)
		marker_row.add_child(btn)

func _on_color_picked_from_wheel(color: Color) -> void:
	if _current_canvas:
		_current_canvas.paint_color = color

func _on_eyedropper_picked(color: Color) -> void:
	color_picker.color = color

func _build_hat_select_row() -> void:
	var group := ButtonGroup.new()
	for opt in HAT_OPTIONS:
		var btn := Button.new()
		btn.text = opt if opt == "None" else opt.capitalize()
		btn.toggle_mode = true
		btn.button_group = group
		btn.button_pressed = (opt == "None")
		btn.custom_minimum_size = Vector2(0, 28)
		btn.size_flags_horizontal = SIZE_EXPAND_FILL
		UIStyle.style_button(btn, UIStyle.COLOR_RANKED, 6)
		var hat_shape: String = "" if opt == "None" else opt
		btn.pressed.connect(func():
			_preview_hat = hat_shape
			_refresh_previews()
		)
		hat_select_row.add_child(btn)

func _build_previews() -> void:
	for skin in PREVIEW_SKINS:
		var wrap := PanelContainer.new()
		wrap.custom_minimum_size = Vector2(74, 94)
		var preview = CharacterPreviewScene.new()
		preview.skin_id = skin
		preview.hat_id = ""
		preview.zoom = 2.2
		preview.custom_minimum_size = Vector2(70, 90)
		wrap.add_child(preview)
		preview_row.add_child(wrap)
		_previews.append(preview)

func _on_painted() -> void:
	_refresh_previews()

func _refresh_previews() -> void:
	for i in _previews.size():
		var preview = _previews[i]
		var skin_color := _skin_color(PREVIEW_SKINS[i])
		for entry in PART_LIST:
			if entry.is_hat:
				continue
			var tinted := SkinCatalog.tint_template(_images[entry.key], skin_color, SkinCatalog.CHARACTER_SHADE_AMOUNT, SkinCatalog.CHARACTER_HIGHLIGHT_AMOUNT)
			preview.set_part_override(entry.key, ImageTexture.create_from_image(tinted))
		if _preview_hat.is_empty():
			preview.set_hat_override(null)
		else:
			var hat_color := _hat_color(_preview_hat)
			var tinted_hat := SkinCatalog.tint_template(_images[_preview_hat], hat_color, SkinCatalog.HAT_SHADE_AMOUNT, SkinCatalog.HAT_HIGHLIGHT_AMOUNT)
			preview.set_hat_override(ImageTexture.create_from_image(tinted_hat))

func _skin_color(id: String) -> Color:
	for s in SkinCatalog.BUILTIN_SKINS:
		if s.id == id:
			return s.color
	return Color.WHITE

func _hat_color(shape: String) -> Color:
	for h in SkinCatalog.BUILTIN_HATS:
		if h.shape == shape:
			return h.color
	return Color.WHITE

func _on_export_pressed() -> void:
	var base_dir := OS.get_executable_path().get_base_dir()
	var out_dir := base_dir.path_join("edited_templates")
	DirAccess.make_dir_recursive_absolute(out_dir.path_join("hats"))
	for entry in PART_LIST:
		var img: Image = _images[entry.key]
		var path: String = out_dir.path_join("hats/%s.png" % entry.key) if entry.is_hat else out_dir.path_join("%s.png" % entry.key)
		img.save_png(path)
	var f := FileAccess.open(out_dir.path_join("HOW_TO_SUBMIT.txt"), FileAccess.WRITE)
	if f:
		f.store_string(INSTRUCTIONS_TEXT)
	status_label.text = "Exported to: " + out_dir
