extends Control

# Lets a player pick from the shared skin/hat/trail catalogs (built-in skin
# colors plus any custom images the Art Tool has published). Drawing your
# own is Art-Tool-only now, not something the client itself offers -- skin
# and hat/trail selections are stored server-side (see SkinCatalog) keyed
# by an anonymous client id, three independent equip slots switched
# between via the tab buttons.
#
# Cards are built entirely in code (no per-cosmetic scene files) so adding
# an item to a catalog is purely a data change -- neutral-toned border, big
# centered preview art, an EQUIPPED badge on your current pick.

const UIStyle := preload("res://ui/ui_style.gd")

@onready var skin_grid: GridContainer = $VBox/ScrollContainer/SkinGrid
@onready var status_label: Label = $VBox/StatusLabel
@onready var back_button: Button = $VBox/BackButton
@onready var skins_tab_button: Button = $VBox/TabBar/SkinsTabButton
@onready var hats_tab_button: Button = $VBox/TabBar/HatsTabButton
@onready var trails_tab_button: Button = $VBox/TabBar/TrailsTabButton

const CARD_SIZE := Vector2(140, 184)
const BANNER_HEIGHT_FRACTION := 0.3
const CARD_COLOR := UIStyle.COLOR_SHOP # matches the Shop bar's own color on the main menu

var _button_group := ButtonGroup.new()
var _mode := "skin" # "skin", "hat", or "trail"

func _ready() -> void:
	UIStyle.add_background(self)
	UIStyle.style_button(skins_tab_button, UIStyle.COLOR_SHOP, 8)
	UIStyle.style_button(hats_tab_button, UIStyle.COLOR_SHOP, 8)
	UIStyle.style_button(trails_tab_button, UIStyle.COLOR_SHOP, 8)
	UIStyle.style_back_button(back_button)

	back_button.pressed.connect(_on_back_pressed)
	skins_tab_button.pressed.connect(func(): _set_mode("skin"))
	hats_tab_button.pressed.connect(func(): _set_mode("hat"))
	trails_tab_button.pressed.connect(func(): _set_mode("trail"))
	SkinCatalog.catalog_loaded.connect(_refresh_grid)
	# A custom skin/hat/trail's texture (from a previous session, or one just
	# added) can still be in flight when this screen opens -- re-render once
	# it actually lands instead of leaving its card blank forever.
	SkinCatalog.skin_received.connect(func(_id): _refresh_grid())
	SkinCatalog.hat_received.connect(func(_id): _refresh_grid())
	SkinCatalog.trail_received.connect(func(_id): _refresh_grid())
	status_label.text = "Loading..."
	_refresh_grid()
	# Re-fetch every time the shop opens (not just once at game startup) so a
	# skin/hat/trail someone else just published via the Art Tool's Publish
	# button actually shows up here without needing a restart -- catalog_
	# loaded above already re-renders the grid once this lands.
	SkinCatalog.refresh_catalog()

func _set_mode(mode: String) -> void:
	_mode = mode
	skins_tab_button.button_pressed = (mode == "skin")
	hats_tab_button.button_pressed = (mode == "hat")
	trails_tab_button.button_pressed = (mode == "trail")
	_refresh_grid()

func _refresh_grid() -> void:
	for child in skin_grid.get_children():
		child.queue_free()
	match _mode:
		"skin":
			var selected_id := SkinCatalog.selected_skin_id
			for skin in SkinCatalog.get_all_skins():
				skin_grid.add_child(_build_card(skin, selected_id, "skin"))
		"hat":
			var selected_id := SkinCatalog.selected_hat_id
			skin_grid.add_child(_build_no_item_card("No Hat", selected_id, "hat"))
			for hat in SkinCatalog.get_all_hats():
				skin_grid.add_child(_build_card(hat, selected_id, "hat"))
		"trail":
			var selected_id := SkinCatalog.selected_trail_id
			skin_grid.add_child(_build_no_item_card("No Trail", selected_id, "trail"))
			for trail in SkinCatalog.get_all_trails():
				skin_grid.add_child(_build_card(trail, selected_id, "trail"))
	if status_label.text == "Loading...":
		status_label.text = ""

func _texture_for(kind: String, id: String) -> Texture2D:
	match kind:
		"hat": return SkinCatalog.get_hat_texture(id)
		"trail": return SkinCatalog.get_trail_texture(id)
		_: return SkinCatalog.get_texture(id)

func _build_card(item: Dictionary, selected_id: String, kind: String) -> Button:
	var is_selected: bool = item.id == selected_id

	var card := Button.new()
	card.custom_minimum_size = CARD_SIZE
	card.clip_contents = true
	card.toggle_mode = true
	card.button_group = _button_group
	card.button_pressed = is_selected
	card.focus_mode = Control.FOCUS_NONE
	card.pressed.connect(_on_item_pressed.bind(item.id, kind))
	card.add_theme_stylebox_override("normal", _card_style(0.05, 3))
	card.add_theme_stylebox_override("hover", _card_style(0.12, 3))
	card.add_theme_stylebox_override("pressed", _card_style(0.22, 4))
	card.add_theme_stylebox_override("focus", StyleBoxEmpty.new())

	var preview := TextureRect.new()
	preview.texture = _texture_for(kind, item.id)
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

func _build_no_item_card(label_text: String, selected_id: String, kind: String) -> Button:
	var is_selected := selected_id.is_empty()
	var card := Button.new()
	card.custom_minimum_size = CARD_SIZE
	card.clip_contents = true
	card.toggle_mode = true
	card.button_group = _button_group
	card.button_pressed = is_selected
	card.focus_mode = Control.FOCUS_NONE
	card.pressed.connect(_on_item_pressed.bind("", kind))
	card.add_theme_stylebox_override("normal", _card_style(0.05, 3))
	card.add_theme_stylebox_override("hover", _card_style(0.12, 3))
	card.add_theme_stylebox_override("pressed", _card_style(0.22, 4))
	card.add_theme_stylebox_override("focus", StyleBoxEmpty.new())

	var label := Label.new()
	label.text = label_text
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

func _on_item_pressed(id: String, kind: String) -> void:
	match kind:
		"hat": SkinCatalog.select_hat(id)
		"trail": SkinCatalog.select_trail(id)
		_: SkinCatalog.select_skin(id)
	status_label.text = ""
	_refresh_grid()

func _on_back_pressed() -> void:
	get_tree().change_scene_to_file("res://main/main_menu.tscn")
