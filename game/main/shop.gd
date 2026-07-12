extends Control

# Lets a player pick from the shared skin catalog (built-in colors plus any
# custom image skins the server has on record). Selection is stored
# server-side (see SkinCatalog) keyed by an anonymous client id. Custom
# skins can only be added directly on the server (relay-server/add-skin.js)
# -- there is no in-game way to add or remove one, so this screen is
# select-only.
#
# Cards are built entirely in code (no per-skin scene files) so adding a
# skin to the catalog is purely a data change -- rarity-colored border +
# banner, big centered preview art, an EQUIPPED badge on your current pick.

@onready var skin_grid: GridContainer = $VBox/ScrollContainer/SkinGrid
@onready var status_label: Label = $VBox/StatusLabel
@onready var back_button: Button = $VBox/BackButton

const CARD_SIZE := Vector2(140, 184)
const BANNER_HEIGHT_FRACTION := 0.3

var _button_group := ButtonGroup.new()

func _ready() -> void:
	back_button.pressed.connect(_on_back_pressed)
	SkinCatalog.catalog_loaded.connect(_refresh_grid)
	# A custom skin's texture (from a previous session, or one just added
	# server-side) can still be in flight when this screen opens -- re-render
	# once it actually lands instead of leaving its card blank forever.
	SkinCatalog.skin_received.connect(func(_id): _refresh_grid())
	status_label.text = "Loading skins..."
	_refresh_grid()

func _refresh_grid() -> void:
	for child in skin_grid.get_children():
		child.queue_free()
	var selected_id := SkinCatalog.selected_skin_id
	for skin in SkinCatalog.get_all_skins():
		skin_grid.add_child(_build_card(skin, selected_id))
	if status_label.text == "Loading skins...":
		status_label.text = ""

func _build_card(skin: Dictionary, selected_id: String) -> Button:
	var rarity: String = skin.get("rarity", "common")
	var rarity_color: Color = SkinCatalog.RARITY_COLORS.get(rarity, SkinCatalog.RARITY_COLORS.common)
	var is_selected: bool = skin.id == selected_id

	var card := Button.new()
	card.custom_minimum_size = CARD_SIZE
	card.clip_contents = true
	card.toggle_mode = true
	card.button_group = _button_group
	card.button_pressed = is_selected
	card.focus_mode = Control.FOCUS_NONE
	card.pressed.connect(_on_skin_pressed.bind(skin.id))
	card.add_theme_stylebox_override("normal", _card_style(rarity_color, 0.05, 3))
	card.add_theme_stylebox_override("hover", _card_style(rarity_color, 0.12, 3))
	card.add_theme_stylebox_override("pressed", _card_style(rarity_color, 0.22, 4))
	card.add_theme_stylebox_override("focus", StyleBoxEmpty.new())

	var preview := TextureRect.new()
	preview.texture = SkinCatalog.get_texture(skin.id)
	preview.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	preview.mouse_filter = Control.MOUSE_FILTER_IGNORE
	preview.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	preview.offset_top = 8
	preview.offset_bottom = CARD_SIZE.y * (1.0 - BANNER_HEIGHT_FRACTION)
	card.add_child(preview)

	var rarity_tag := Label.new()
	rarity_tag.text = rarity.to_upper()
	rarity_tag.add_theme_font_size_override("font_size", 10)
	rarity_tag.add_theme_color_override("font_color", rarity_color)
	rarity_tag.mouse_filter = Control.MOUSE_FILTER_IGNORE
	rarity_tag.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	rarity_tag.offset_left = 8
	rarity_tag.offset_top = 6
	card.add_child(rarity_tag)

	if is_selected:
		# A small circular checkmark badge rather than a text label -- fixed
		# size means it can never collide with a long rarity name like
		# "LEGENDARY" the way a wider text badge would.
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
		card.add_child(badge)

	var banner := Panel.new()
	banner.mouse_filter = Control.MOUSE_FILTER_IGNORE
	banner.add_theme_stylebox_override("panel", _banner_style(rarity_color))
	banner.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
	banner.offset_top = -CARD_SIZE.y * BANNER_HEIGHT_FRACTION

	var name_label := Label.new()
	name_label.text = skin.name.to_upper()
	name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	name_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	name_label.add_theme_font_size_override("font_size", 14)
	name_label.add_theme_color_override("font_color", Color.WHITE)
	name_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	name_label.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	banner.add_child(name_label)
	card.add_child(banner)

	return card

func _card_style(rarity_color: Color, bg_tint: float, border_width: int) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.06, 0.06, 0.09).lerp(rarity_color, bg_tint)
	sb.border_width_left = border_width
	sb.border_width_top = border_width
	sb.border_width_right = border_width
	sb.border_width_bottom = border_width
	sb.border_color = rarity_color
	sb.corner_radius_top_left = 10
	sb.corner_radius_top_right = 10
	sb.corner_radius_bottom_right = 10
	sb.corner_radius_bottom_left = 10
	sb.content_margin_left = 0
	sb.content_margin_top = 0
	sb.content_margin_right = 0
	sb.content_margin_bottom = 0
	return sb

func _banner_style(rarity_color: Color) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(rarity_color.r * 0.4, rarity_color.g * 0.4, rarity_color.b * 0.4, 0.92)
	sb.corner_radius_bottom_left = 7
	sb.corner_radius_bottom_right = 7
	return sb

func _on_skin_pressed(id: String) -> void:
	SkinCatalog.select_skin(id)
	status_label.text = ""
	_refresh_grid()

func _on_back_pressed() -> void:
	get_tree().change_scene_to_file("res://main/main_menu.tscn")
