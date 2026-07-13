extends Control

# Lets a player pick from the shared skin/hat catalogs (built-in skin colors
# plus any custom images the server has on record) and draw their own. Skin
# and hat selections are stored server-side (see SkinCatalog) keyed by an
# anonymous client id -- two independent equip slots, switched between via
# the tab buttons.
#
# Cards are built entirely in code (no per-cosmetic scene files) so adding
# an item to a catalog is purely a data change -- neutral-toned border, big
# centered preview art, an EQUIPPED badge on your current pick.

const SKIN_EDITOR_SCENE := preload("res://main/skin_editor.tscn")
const UIStyle := preload("res://ui/ui_style.gd")

@onready var skin_grid: GridContainer = $VBox/ScrollContainer/SkinGrid
@onready var status_label: Label = $VBox/StatusLabel
@onready var back_button: Button = $VBox/BackButton
@onready var skins_tab_button: Button = $VBox/TabBar/SkinsTabButton
@onready var hats_tab_button: Button = $VBox/TabBar/HatsTabButton
@onready var draw_button: Button = $VBox/DrawButton

const CARD_SIZE := Vector2(140, 184)
const BANNER_HEIGHT_FRACTION := 0.3
const CARD_COLOR := UIStyle.COLOR_SHOP # matches the Shop bar's own color on the main menu

var _button_group := ButtonGroup.new()
var _mode := "skin" # "skin" or "hat"

func _ready() -> void:
	UIStyle.add_background(self)
	UIStyle.style_button(skins_tab_button, UIStyle.COLOR_SHOP, 8)
	UIStyle.style_button(hats_tab_button, UIStyle.COLOR_SHOP, 8)
	UIStyle.style_button(draw_button, UIStyle.COLOR_SHOP)
	UIStyle.style_back_button(back_button)

	back_button.pressed.connect(_on_back_pressed)
	skins_tab_button.pressed.connect(func(): _set_mode("skin"))
	hats_tab_button.pressed.connect(func(): _set_mode("hat"))
	draw_button.pressed.connect(_on_draw_pressed)
	SkinCatalog.catalog_loaded.connect(_refresh_grid)
	# A custom skin/hat's texture (from a previous session, or one just
	# added) can still be in flight when this screen opens -- re-render once
	# it actually lands instead of leaving its card blank forever.
	SkinCatalog.skin_received.connect(func(_id): _refresh_grid())
	SkinCatalog.hat_received.connect(func(_id): _refresh_grid())
	status_label.text = "Loading..."
	_refresh_grid()
	# Re-fetch every time the shop opens (not just once at game startup) so a
	# skin/hat someone else just published via the Art Tool's Publish button
	# actually shows up here without needing a restart -- catalog_loaded
	# above already re-renders the grid once this lands.
	SkinCatalog.refresh_catalog()

func _set_mode(mode: String) -> void:
	_mode = mode
	skins_tab_button.button_pressed = (mode == "skin")
	hats_tab_button.button_pressed = (mode == "hat")
	draw_button.text = "+ Draw a Skin" if mode == "skin" else "+ Draw a Hat"
	_refresh_grid()

func _refresh_grid() -> void:
	for child in skin_grid.get_children():
		child.queue_free()
	if _mode == "skin":
		var selected_id := SkinCatalog.selected_skin_id
		for skin in SkinCatalog.get_all_skins():
			skin_grid.add_child(_build_card(skin, selected_id, false))
	else:
		var selected_id := SkinCatalog.selected_hat_id
		skin_grid.add_child(_build_no_hat_card(selected_id))
		for hat in SkinCatalog.get_all_hats():
			skin_grid.add_child(_build_card(hat, selected_id, true))
	if status_label.text == "Loading...":
		status_label.text = ""

func _build_card(item: Dictionary, selected_id: String, is_hat: bool) -> Button:
	var is_selected: bool = item.id == selected_id

	var card := Button.new()
	card.custom_minimum_size = CARD_SIZE
	card.clip_contents = true
	card.toggle_mode = true
	card.button_group = _button_group
	card.button_pressed = is_selected
	card.focus_mode = Control.FOCUS_NONE
	card.pressed.connect(_on_item_pressed.bind(item.id, is_hat))
	card.add_theme_stylebox_override("normal", _card_style(0.05, 3))
	card.add_theme_stylebox_override("hover", _card_style(0.12, 3))
	card.add_theme_stylebox_override("pressed", _card_style(0.22, 4))
	card.add_theme_stylebox_override("focus", StyleBoxEmpty.new())

	var preview := TextureRect.new()
	preview.texture = SkinCatalog.get_hat_texture(item.id) if is_hat else SkinCatalog.get_texture(item.id)
	preview.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	preview.mouse_filter = Control.MOUSE_FILTER_IGNORE
	preview.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	preview.offset_top = 8
	preview.offset_bottom = CARD_SIZE.y * (1.0 - BANNER_HEIGHT_FRACTION)
	card.add_child(preview)

	if is_selected:
		card.add_child(_build_equipped_badge())

	var banner := Panel.new()
	banner.mouse_filter = Control.MOUSE_FILTER_IGNORE
	banner.add_theme_stylebox_override("panel", _banner_style())
	banner.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
	banner.offset_top = -CARD_SIZE.y * BANNER_HEIGHT_FRACTION

	var name_label := Label.new()
	name_label.text = item.name.to_upper()
	name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	name_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	name_label.add_theme_font_size_override("font_size", 14)
	name_label.add_theme_color_override("font_color", Color.WHITE)
	name_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	name_label.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	banner.add_child(name_label)
	card.add_child(banner)

	return card

func _build_no_hat_card(selected_hat_id: String) -> Button:
	var is_selected := selected_hat_id.is_empty()
	var card := Button.new()
	card.custom_minimum_size = CARD_SIZE
	card.clip_contents = true
	card.toggle_mode = true
	card.button_group = _button_group
	card.button_pressed = is_selected
	card.focus_mode = Control.FOCUS_NONE
	card.pressed.connect(_on_item_pressed.bind("", true))
	card.add_theme_stylebox_override("normal", _card_style(0.05, 3))
	card.add_theme_stylebox_override("hover", _card_style(0.12, 3))
	card.add_theme_stylebox_override("pressed", _card_style(0.22, 4))
	card.add_theme_stylebox_override("focus", StyleBoxEmpty.new())

	var label := Label.new()
	label.text = "No Hat"
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.add_theme_font_size_override("font_size", 16)
	label.add_theme_color_override("font_color", Color(0.8, 0.82, 0.86))
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	card.add_child(label)

	if is_selected:
		card.add_child(_build_equipped_badge())

	return card

func _build_equipped_badge() -> Control:
	# A small circular checkmark badge rather than a text label -- fixed
	# size means it can never collide with a longer item name.
	var badge := Panel.new()
	var badge_sb := StyleBoxFlat.new()
	badge_sb.bg_color = Color(0.25, 0.85, 0.45)
	badge_sb.corner_radius_top_left = 11
	badge_sb.corner_radius_top_right = 11
	badge_sb.corner_radius_bottom_left = 11
	badge_sb.corner_radius_bottom_right = 11
	badge.add_theme_stylebox_override("panel", badge_sb)
	badge.mouse_filter = Control.MOUSE_FILTER_IGNORE
	badge.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	badge.offset_left = -30
	badge.offset_top = 6
	badge.offset_right = -8
	badge.offset_bottom = 28
	var check := Label.new()
	check.text = "✓"
	check.add_theme_font_size_override("font_size", 15)
	check.add_theme_color_override("font_color", Color.WHITE)
	check.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	check.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	check.mouse_filter = Control.MOUSE_FILTER_IGNORE
	check.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	badge.add_child(check)
	return badge

func _card_style(bg_tint: float, border_width: int) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.06, 0.06, 0.09).lerp(CARD_COLOR, bg_tint)
	sb.border_width_left = border_width
	sb.border_width_top = border_width
	sb.border_width_right = border_width
	sb.border_width_bottom = border_width
	sb.border_color = CARD_COLOR
	sb.corner_radius_top_left = 10
	sb.corner_radius_top_right = 10
	sb.corner_radius_bottom_right = 10
	sb.corner_radius_bottom_left = 10
	sb.content_margin_left = 0
	sb.content_margin_top = 0
	sb.content_margin_right = 0
	sb.content_margin_bottom = 0
	return sb

func _banner_style() -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(CARD_COLOR.r * 0.4, CARD_COLOR.g * 0.4, CARD_COLOR.b * 0.4, 0.92)
	sb.corner_radius_bottom_left = 7
	sb.corner_radius_bottom_right = 7
	return sb

func _on_item_pressed(id: String, is_hat: bool) -> void:
	if is_hat:
		SkinCatalog.select_hat(id)
	else:
		SkinCatalog.select_skin(id)
	status_label.text = ""
	_refresh_grid()

func _on_draw_pressed() -> void:
	var editor := SKIN_EDITOR_SCENE.instantiate()
	editor.setup(_mode)
	get_tree().root.add_child(editor)
	get_tree().current_scene.queue_free()
	get_tree().current_scene = editor

func _on_back_pressed() -> void:
	get_tree().change_scene_to_file("res://main/main_menu.tscn")
