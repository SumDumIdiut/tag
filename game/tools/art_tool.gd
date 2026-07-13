extends Control

# Standalone paint tool, exported as its own executable (TagArtTool.exe, see
# export_presets.cfg's "Art Tool" preset). Two pages, switched at the top
# like a dedicated app rather than one cramped screen: PAINT (create/edit
# any number of independent custom skins and hats -- no pre-made defaults,
# every one starts as a blank canvas) and PREVIEW (a single large render of
# any skin/hat combination, picked from real dropdowns).
#
# Custom skins/hats are unrelated to the game's built-in 8 colors -- they're
# painted in real color directly, the same way the game's own in-shop
# drawing tool works, not tinted from a shared template.

const UIStyle := preload("res://ui/ui_style.gd")
const CharacterPreviewScene := preload("res://ui/character_preview.gd")
const PixelCanvasScene := preload("res://main/pixel_canvas.gd")
const UpdateCheckerScript := preload("res://net/update_checker.gd")
const UpdatePromptScene := preload("res://ui/update_prompt.gd")

const ZOOM := 18

const SKIN_INSTRUCTIONS_TEXT := """Each skin here is a complete, independent design. Adding one to the
game doesn't need a rebuild or a pull request.

Each skin's folder has a ready-to-use composited PNG (named after the
skin) plus its individual parts/ (in case it needs re-editing later).
Send the composited PNG and the skin's name to whoever runs the game's
server -- they add it with one command:

    node add-skin.js path/to/your-skin.png "Skin Name"

and it's live for everyone immediately, no build or restart needed.
"""

const HAT_INSTRUCTIONS_TEXT := """Send each hat PNG and its name to whoever runs the game's server --
they add it with one command:

    node add-hat.js path/to/your-hat.png "Hat Name"

and it's live for everyone immediately, no build or restart needed.
"""

@onready var paint_tab_button: Button = $VBox/PageTabRow/PaintTabButton
@onready var preview_tab_button: Button = $VBox/PageTabRow/PreviewTabButton
@onready var paint_page: HBoxContainer = $VBox/PaintPage
@onready var preview_page: VBoxContainer = $VBox/PreviewPage

@onready var part_list: VBoxContainer = $VBox/PaintPage/PartPanel/PartScroll/PartList
@onready var canvas_holder: CenterContainer = $VBox/PaintPage/CanvasPanel/CanvasBox/CanvasHolder
@onready var empty_state_label: Label = $VBox/PaintPage/CanvasPanel/CanvasBox/EmptyStateLabel
@onready var toolbar: HBoxContainer = $VBox/PaintPage/CanvasPanel/CanvasBox/Toolbar
@onready var color_picker: ColorPicker = $VBox/PaintPage/RightPanel/RightBox/ColorPicker

@onready var big_preview_center: CenterContainer = $VBox/PreviewPage/BigPreviewPanel/BigPreviewCenter
@onready var skin_select: OptionButton = $VBox/PreviewPage/SelectorRow/SkinSelectBox/SkinSelect
@onready var hat_select: OptionButton = $VBox/PreviewPage/SelectorRow/HatSelectBox/HatSelect

@onready var status_label: Label = $VBox/BottomRow/StatusLabel
@onready var export_button: Button = $VBox/BottomRow/ExportButton

# Which part/hat canvas is currently open for editing -- `_current_id` is
# the stable internal id (see _custom_skins/_custom_hats below), tracked
# explicitly rather than by comparing image content, since two freshly
# created blank skins are byte-identical and would otherwise both appear
# "selected" at once.
var _current_images: Dictionary
var _current_key := ""
var _current_context := "" # "skin", "hat", or "" (nothing open)
var _current_id := ""
var _current_canvas: PixelCanvas = null

var _part_group := ButtonGroup.new()
var _tool_group: ButtonGroup = null
var _current_tool := 0 # PixelCanvas.Tool.BRUSH

var _custom_skins := {} # id -> {part_name -> Image}
var _skin_names := {} # id -> display name
var _skin_expanded := {} # id -> bool
var _custom_skins_list: VBoxContainer
var _next_skin_num := 1

var _custom_hats := {} # id -> {"design": Image}
var _hat_names := {} # id -> display name
var _custom_hats_list: VBoxContainer
var _next_hat_num := 1

var _big_preview
var _preview_skin_id := ""
var _preview_hat_id := ""

func _ready() -> void:
	get_window().size = Vector2i(1300, 860)
	get_window().title = "Tag Art Tool"
	UIStyle.add_background(self)
	_setup_page_tabs()
	_build_sidebar()
	_build_toolbar()
	color_picker.color_changed.connect(_on_color_picked_from_wheel)
	export_button.pressed.connect(_on_export_pressed)
	UIStyle.style_button(export_button, UIStyle.COLOR_SHOP)
	_build_big_preview()
	canvas_holder.visible = false
	empty_state_label.visible = true
	_check_for_update()

func _check_for_update() -> void:
	var checker := UpdateCheckerScript.new("TagArtTool.exe")
	add_child(checker)
	checker.check_completed.connect(_on_update_check_completed)
	checker.check()

func _on_update_check_completed(result: Dictionary) -> void:
	if not result.get("available", false):
		return
	var prompt := UpdatePromptScene.new()
	add_child(prompt)
	prompt.setup(result.version, result.download_url)

func _setup_page_tabs() -> void:
	var tab_group := ButtonGroup.new()
	paint_tab_button.button_group = tab_group
	preview_tab_button.button_group = tab_group
	UIStyle.style_button(paint_tab_button, UIStyle.COLOR_SHOP, 10)
	UIStyle.style_button(preview_tab_button, UIStyle.COLOR_ONLINE, 10)
	paint_tab_button.pressed.connect(func():
		paint_page.visible = true
		preview_page.visible = false
	)
	preview_tab_button.pressed.connect(func():
		paint_page.visible = false
		preview_page.visible = true
		_refresh_preview_selectors()
		_refresh_big_preview()
	)

## No pre-loaded defaults -- both lists start empty; "+ New Skin"/"+ New
## Hat" are the only way anything appears here.
func _build_sidebar() -> void:
	part_list.add_child(_section_label("CUSTOM SKINS"))
	_custom_skins_list = VBoxContainer.new()
	_custom_skins_list.add_theme_constant_override("separation", 4)
	part_list.add_child(_custom_skins_list)
	var add_skin_btn := Button.new()
	add_skin_btn.text = "+ New Skin"
	UIStyle.style_button(add_skin_btn, UIStyle.COLOR_ONLINE, 8)
	add_skin_btn.pressed.connect(_on_add_skin_pressed)
	part_list.add_child(add_skin_btn)

	var hat_spacer := Control.new()
	hat_spacer.custom_minimum_size = Vector2(0, 8)
	part_list.add_child(hat_spacer)

	part_list.add_child(_section_label("CUSTOM HATS"))
	_custom_hats_list = VBoxContainer.new()
	_custom_hats_list.add_theme_constant_override("separation", 4)
	part_list.add_child(_custom_hats_list)
	var add_hat_btn := Button.new()
	add_hat_btn.text = "+ New Hat"
	UIStyle.style_button(add_hat_btn, UIStyle.COLOR_RANKED, 8)
	add_hat_btn.pressed.connect(_on_add_hat_pressed)
	part_list.add_child(add_hat_btn)

func _section_label(text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", 12)
	l.add_theme_color_override("font_color", Color(0.7, 0.72, 0.78))
	return l

func _blank_image(size: Vector2i) -> Image:
	var img := Image.create(size.x, size.y, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	return img

func _on_add_skin_pressed() -> void:
	var id := "skin_%d" % _next_skin_num
	var display_num := _next_skin_num
	_next_skin_num += 1
	_skin_names[id] = "Skin %d" % display_num
	var parts := {}
	for part_name in SkinCatalog.PART_NAMES:
		parts[part_name] = _blank_image(SkinCatalog.PART_DEFS[part_name].rect.size)
	_custom_skins[id] = parts
	_skin_expanded[id] = true
	_rebuild_custom_skins_list()
	_show_part(parts, "torso", "skin", id)

func _on_add_hat_pressed() -> void:
	var id := "hat_%d" % _next_hat_num
	var display_num := _next_hat_num
	_next_hat_num += 1
	_hat_names[id] = "Hat %d" % display_num
	var parts := {"design": _blank_image(Vector2i(SkinCatalog.HAT_WIDTH, SkinCatalog.HAT_HEIGHT))}
	_custom_hats[id] = parts
	_rebuild_custom_hats_list()
	_show_part(parts, "design", "hat", id)

func _rebuild_custom_skins_list() -> void:
	for child in _custom_skins_list.get_children():
		child.queue_free()
	for id in _custom_skins.keys():
		_custom_skins_list.add_child(_build_skin_entry(id))

func _build_skin_entry(id: String) -> Control:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 2)

	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 4)
	var expand_btn := Button.new()
	var expanded: bool = _skin_expanded.get(id, false)
	expand_btn.text = ("▾  " if expanded else "▸  ") + _skin_names[id]
	expand_btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
	expand_btn.size_flags_horizontal = SIZE_EXPAND_FILL
	UIStyle.style_button(expand_btn, UIStyle.COLOR_SANDBOX, 8)
	expand_btn.pressed.connect(func():
		var now_expanded: bool = not _skin_expanded.get(id, false)
		_skin_expanded[id] = now_expanded
		if now_expanded:
			# Fixes "nothing loads when you click the dropdown" -- expanding
			# used to only reveal the part buttons underneath without ever
			# actually loading one onto the canvas, so the first click
			# looked like it did nothing. Expanding now immediately opens
			# this skin's torso, same as clicking any of its part buttons.
			_show_part(_custom_skins[id], "torso", "skin", id)
		_rebuild_custom_skins_list()
	)
	header.add_child(expand_btn)
	var publish_btn := Button.new()
	publish_btn.text = "Publish"
	publish_btn.custom_minimum_size = Vector2(72, 0)
	UIStyle.style_button(publish_btn, UIStyle.COLOR_ONLINE, 8)
	publish_btn.pressed.connect(_on_publish_skin_pressed.bind(id, publish_btn))
	header.add_child(publish_btn)
	header.add_child(_delete_button(func():
		_custom_skins.erase(id)
		_skin_names.erase(id)
		_skin_expanded.erase(id)
		if _current_context == "skin" and _current_id == id:
			_clear_canvas()
		_rebuild_custom_skins_list()
	))
	box.add_child(header)

	if expanded:
		var name_edit := LineEdit.new()
		name_edit.text = _skin_names[id]
		name_edit.placeholder_text = "Skin name"
		name_edit.text_submitted.connect(func(new_text: String):
			var trimmed := new_text.strip_edges()
			if not trimmed.is_empty():
				_skin_names[id] = trimmed
			_rebuild_custom_skins_list()
		)
		box.add_child(name_edit)

		for part_name in SkinCatalog.PART_NAMES:
			var part_btn := Button.new()
			part_btn.text = "     " + part_name.capitalize().replace("_", " ")
			part_btn.toggle_mode = true
			part_btn.button_group = _part_group
			part_btn.button_pressed = (_current_context == "skin" and _current_id == id and _current_key == part_name)
			part_btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
			UIStyle.style_button(part_btn, UIStyle.COLOR_SHOP, 6)
			part_btn.pressed.connect(_show_part.bind(_custom_skins[id], part_name, "skin", id))
			box.add_child(part_btn)

	return box

func _rebuild_custom_hats_list() -> void:
	for child in _custom_hats_list.get_children():
		child.queue_free()
	for id in _custom_hats.keys():
		_custom_hats_list.add_child(_build_hat_entry(id))

func _build_hat_entry(id: String) -> Control:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 2)

	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 4)
	var select_btn := Button.new()
	select_btn.text = _hat_names[id]
	select_btn.toggle_mode = true
	select_btn.button_group = _part_group
	select_btn.button_pressed = (_current_context == "hat" and _current_id == id)
	select_btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
	select_btn.size_flags_horizontal = SIZE_EXPAND_FILL
	UIStyle.style_button(select_btn, UIStyle.COLOR_SANDBOX, 8)
	select_btn.pressed.connect(_show_part.bind(_custom_hats[id], "design", "hat", id))
	header.add_child(select_btn)
	var publish_btn := Button.new()
	publish_btn.text = "Publish"
	publish_btn.custom_minimum_size = Vector2(72, 0)
	UIStyle.style_button(publish_btn, UIStyle.COLOR_ONLINE, 8)
	publish_btn.pressed.connect(_on_publish_hat_pressed.bind(id, publish_btn))
	header.add_child(publish_btn)
	header.add_child(_delete_button(func():
		_custom_hats.erase(id)
		_hat_names.erase(id)
		if _current_context == "hat" and _current_id == id:
			_clear_canvas()
		_rebuild_custom_hats_list()
	))
	box.add_child(header)

	var name_edit := LineEdit.new()
	name_edit.text = _hat_names[id]
	name_edit.placeholder_text = "Hat name"
	name_edit.text_submitted.connect(func(new_text: String):
		var trimmed := new_text.strip_edges()
		if not trimmed.is_empty():
			_hat_names[id] = trimmed
		_rebuild_custom_hats_list()
	)
	box.add_child(name_edit)

	return box

func _delete_button(on_delete: Callable) -> Button:
	var btn := Button.new()
	btn.text = "x"
	btn.custom_minimum_size = Vector2(28, 0)
	UIStyle.style_button(btn, UIStyle.COLOR_RANKED, 8)
	btn.pressed.connect(on_delete)
	return btn

## Uploads straight to the shared catalog via the same endpoint the in-game
## drawing tool already uses (SkinCatalog.add_drawn_skin) -- no server
## changes, no admin step, live for every player as soon as this returns.
## `btn` is re-enabled on both success and failure so publishing again (e.g.
## after touching the art up further) doesn't need a full list rebuild;
## is_instance_valid guards against the entry having been deleted or the
## list rebuilt (renamed) while the upload was in flight.
func _on_publish_skin_pressed(id: String, btn: Button) -> void:
	if not _custom_skins.has(id):
		return
	var skin_name: String = _skin_names[id]
	btn.disabled = true
	status_label.text = "Publishing \"%s\"..." % skin_name
	var server_id: String = await SkinCatalog.add_drawn_skin(_custom_skins[id], skin_name)
	if not is_instance_valid(btn):
		return
	btn.disabled = false
	if server_id.is_empty():
		status_label.text = "Publish failed for \"%s\" -- check your connection." % skin_name
	else:
		status_label.text = "Published \"%s\" -- live for everyone now." % skin_name

## Same idea as _on_publish_skin_pressed, for hats.
func _on_publish_hat_pressed(id: String, btn: Button) -> void:
	if not _custom_hats.has(id):
		return
	var hat_name: String = _hat_names[id]
	btn.disabled = true
	status_label.text = "Publishing \"%s\"..." % hat_name
	var server_id: String = await SkinCatalog.add_drawn_hat(_custom_hats[id]["design"], hat_name)
	if not is_instance_valid(btn):
		return
	btn.disabled = false
	if server_id.is_empty():
		status_label.text = "Publish failed for \"%s\" -- check your connection." % hat_name
	else:
		status_label.text = "Published \"%s\" -- live for everyone now." % hat_name

## `images` is whichever part-dict is being edited; `context` is "skin" or
## "hat" (drives the big preview's tinting-free rendering); `id` is the
## stable internal id used for selection-highlighting and delete/rebuild.
func _show_part(images: Dictionary, key: String, context: String, id: String) -> void:
	_current_images = images
	_current_key = key
	_current_context = context
	_current_id = id
	empty_state_label.visible = false
	canvas_holder.visible = true
	_clear_canvas_holder()
	var canvas = PixelCanvasScene.new(images[key], ZOOM)
	canvas_holder.add_child(canvas)
	canvas.painted.connect(_on_painted)
	canvas.color_picked.connect(_on_eyedropper_picked)
	_current_canvas = canvas
	_apply_tool_state()

func _clear_canvas() -> void:
	_current_context = ""
	_current_id = ""
	_current_key = ""
	_current_images = {}
	_clear_canvas_holder()
	canvas_holder.visible = false
	empty_state_label.visible = true

## queue_free() only *schedules* removal, it doesn't take a node out of the
## tree immediately -- switching parts faster than one deletion clears (a
## totally normal thing to do, just clicking through the sidebar) left the
## previous canvas still sitting in the CenterContainer when the next one
## was added, and multiple same-sized siblings fighting for centered
## position there collapses everyone's layout to zero size. This is why
## parts stopped rendering at all after a couple of clicks. remove_child()
## first takes it out of the tree synchronously, so there's never more than
## one canvas actually laid out here at a time; queue_free() after that
## still handles the actual memory cleanup.
func _clear_canvas_holder() -> void:
	for child in canvas_holder.get_children():
		canvas_holder.remove_child(child)
		child.queue_free()
	_current_canvas = null

func _build_toolbar() -> void:
	var brush_btn := _tool_button("Brush", 0)
	var eraser_btn := _tool_button("Eraser", 1)
	var fill_btn := _tool_button("Fill", 2)
	var eyedrop_btn := _tool_button("Eyedrop", 3)
	for b in [brush_btn, eraser_btn, fill_btn, eyedrop_btn]:
		toolbar.add_child(b)
	brush_btn.button_pressed = true

	toolbar.add_child(VSeparator.new())

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

	toolbar.add_child(VSeparator.new())

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

func _on_color_picked_from_wheel(color: Color) -> void:
	if _current_canvas:
		_current_canvas.paint_color = color

func _on_eyedropper_picked(color: Color) -> void:
	color_picker.color = color

func _on_painted() -> void:
	if preview_page.visible:
		_refresh_big_preview()

func _build_big_preview() -> void:
	_big_preview = CharacterPreviewScene.new()
	_big_preview.skin_id = "red"
	_big_preview.hat_id = ""
	_big_preview.zoom = 5.0
	_big_preview.custom_minimum_size = Vector2(260, 340)
	big_preview_center.add_child(_big_preview)

func _refresh_preview_selectors() -> void:
	skin_select.clear()
	skin_select.add_item("None")
	var skin_ids := _custom_skins.keys()
	for id in skin_ids:
		skin_select.add_item(_skin_names[id])
	var sel_idx := 0
	if not _preview_skin_id.is_empty() and _custom_skins.has(_preview_skin_id):
		sel_idx = skin_ids.find(_preview_skin_id) + 1
	else:
		_preview_skin_id = ""
	skin_select.selected = sel_idx
	if not skin_select.item_selected.is_connected(_on_skin_select_changed):
		skin_select.item_selected.connect(_on_skin_select_changed)

	hat_select.clear()
	hat_select.add_item("None")
	var hat_ids := _custom_hats.keys()
	for id in hat_ids:
		hat_select.add_item(_hat_names[id])
	var hsel_idx := 0
	if not _preview_hat_id.is_empty() and _custom_hats.has(_preview_hat_id):
		hsel_idx = hat_ids.find(_preview_hat_id) + 1
	else:
		_preview_hat_id = ""
	hat_select.selected = hsel_idx
	if not hat_select.item_selected.is_connected(_on_hat_select_changed):
		hat_select.item_selected.connect(_on_hat_select_changed)

func _on_skin_select_changed(idx: int) -> void:
	var skin_ids := _custom_skins.keys()
	_preview_skin_id = "" if idx == 0 else skin_ids[idx - 1]
	_refresh_big_preview()

func _on_hat_select_changed(idx: int) -> void:
	var hat_ids := _custom_hats.keys()
	_preview_hat_id = "" if idx == 0 else hat_ids[idx - 1]
	_refresh_big_preview()

## No selection ("None") falls back to a plain default-colored character
## (via the game's own normal builtin-skin system) rather than showing
## nothing -- there's always something to look at.
func _refresh_big_preview() -> void:
	if not _big_preview:
		return
	var default_parts := SkinCatalog.get_part_textures("red")
	var skin_parts: Dictionary = _custom_skins.get(_preview_skin_id, {})
	for part_name in SkinCatalog.PART_NAMES:
		if skin_parts.has(part_name):
			_big_preview.set_part_override(part_name, ImageTexture.create_from_image(skin_parts[part_name]))
		elif default_parts.has(part_name):
			_big_preview.set_part_override(part_name, default_parts[part_name])

	if _preview_hat_id.is_empty():
		_big_preview.set_hat_override(null)
	else:
		var hat_parts: Dictionary = _custom_hats.get(_preview_hat_id, {})
		if hat_parts.has("design"):
			_big_preview.set_hat_override(ImageTexture.create_from_image(hat_parts["design"]))

func _on_export_pressed() -> void:
	var base_dir := OS.get_executable_path().get_base_dir()
	var status_parts: Array[String] = []

	if not _custom_skins.is_empty():
		var skins_out_dir := base_dir.path_join("edited_skins")
		for id in _custom_skins.keys():
			var safe_name := _safe_filename(_skin_names[id], id)
			var skin_dir := skins_out_dir.path_join(safe_name)
			DirAccess.make_dir_recursive_absolute(skin_dir.path_join("parts"))
			for part_name in SkinCatalog.PART_NAMES:
				var part_img: Image = _custom_skins[id][part_name]
				part_img.save_png(skin_dir.path_join("parts/%s.png" % part_name))
			var whole := _composite_whole_skin(_custom_skins[id])
			whole.save_png(skin_dir.path_join("%s.png" % safe_name))
		var f := FileAccess.open(skins_out_dir.path_join("HOW_TO_SUBMIT.txt"), FileAccess.WRITE)
		if f:
			f.store_string(SKIN_INSTRUCTIONS_TEXT)
		status_parts.append(skins_out_dir)

	if not _custom_hats.is_empty():
		var hats_out_dir := base_dir.path_join("edited_hats")
		DirAccess.make_dir_recursive_absolute(hats_out_dir)
		for id in _custom_hats.keys():
			var safe_name := _safe_filename(_hat_names[id], id)
			var img: Image = _custom_hats[id]["design"]
			img.save_png(hats_out_dir.path_join("%s.png" % safe_name))
		var f2 := FileAccess.open(hats_out_dir.path_join("HOW_TO_SUBMIT.txt"), FileAccess.WRITE)
		if f2:
			f2.store_string(HAT_INSTRUCTIONS_TEXT)
		status_parts.append(hats_out_dir)

	if status_parts.is_empty():
		status_label.text = "Nothing to export yet -- create a skin or hat first."
	else:
		status_label.text = "Exported to: " + ", ".join(status_parts)

func _safe_filename(display_name: String, fallback_id: String) -> String:
	var safe := display_name.strip_edges().to_lower().replace(" ", "_")
	return safe if not safe.is_empty() else fallback_id

## Blits a custom skin's 6 parts into one 32x48 image at their real
## in-game positions (see SkinCatalog.PART_DEFS) -- the exact format the
## game's existing admin ingestion tool (relay-server/add-skin.js) already
## expects, so a custom skin needs no new server-side code to go live.
## Head is composited last (not PART_NAMES order): its crop overlaps the top
## corners of both arms' rects, and painting arms afterward would clip arm
## pixels into the exported head region -- this same image gets re-sliced
## by PART_DEFS later, so that corruption would be permanent, not cosmetic.
func _composite_whole_skin(parts: Dictionary) -> Image:
	var whole := Image.create(SkinCatalog.VISUAL_WIDTH, SkinCatalog.VISUAL_HEIGHT, false, Image.FORMAT_RGBA8)
	whole.fill(Color(0, 0, 0, 0))
	for part_name in ["torso", "left_arm", "right_arm", "left_leg", "right_leg", "head"]:
		if not parts.has(part_name):
			continue
		var rect: Rect2i = SkinCatalog.PART_DEFS[part_name].rect
		whole.blit_rect(parts[part_name], Rect2i(Vector2i.ZERO, rect.size), rect.position)
	return whole
