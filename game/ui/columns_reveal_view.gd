extends Control
class_name ColumnsRevealView

# Pre-match reveal for a 3-way FFA playlist (1v1v1, see match_intro.gd's
# _columns_mode) -- exactly 3 participants, always, so a fixed 3-lane layout
# reads cleaner than the generic N-player ring circle_reveal_view.gd uses for
# a private match. Text and color only (no icons), pure code/no .tscn,
# matching circle_reveal_view.gd's own pattern -- roster is fully known up
# front, so this only ever lays out once.

const CharacterPreviewScene := preload("res://ui/character_preview.gd")
const UIStyle := preload("res://ui/ui_style.gd")

const PORTRAIT_SIZE := Vector2(110, 140)
const COLUMN_COUNT := 3
# Columns slide in strictly one at a time (each card's own slide finishes
# before the next one starts, not just an overlapping stagger) alternating
# vertical direction per column -- 1st drops in from above, 2nd rises from
# below, 3rd drops again -- rather than every card doing the same motion.
const SLIDE_DURATION_SEC := 0.4
const SLIDE_GAP_SEC := 0.15 # a clean beat between each column's turn

@export var my_id: int = -1

var countdown_label: Label
var _cards: Array[Control] = []

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	countdown_label = Label.new()
	countdown_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	countdown_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	countdown_label.add_theme_font_size_override("font_size", 22)
	countdown_label.custom_minimum_size = Vector2(300, 40)
	add_child(countdown_label)
	_anchor_bottom_center(countdown_label)

func set_roster(roster: Dictionary) -> void:
	for card in _cards:
		card.queue_free()
	_cards.clear()
	var peer_ids := roster.keys()
	for i in mini(peer_ids.size(), COLUMN_COUNT):
		_build_column(peer_ids[i], roster[peer_ids[i]], i)

func _build_column(peer_id: int, info: Dictionary, column_index: int) -> void:
	var card := VBoxContainer.new()
	card.alignment = BoxContainer.ALIGNMENT_CENTER
	card.add_theme_constant_override("separation", 10)
	card.mouse_filter = Control.MOUSE_FILTER_IGNORE
	card.custom_minimum_size = Vector2(PORTRAIT_SIZE.x, PORTRAIT_SIZE.y + 40)
	add_child(card)
	_cards.append(card)

	var color: Color = PlayerColors.color_for(info.get("color_id", PlayerColors.DEFAULT_ID))
	var portrait_wrap := PanelContainer.new()
	var box := StyleBoxFlat.new()
	box.bg_color = Color(color.r, color.g, color.b, 0.16)
	box.border_width_left = 3
	box.border_width_top = 3
	box.border_width_right = 3
	box.border_width_bottom = 3
	box.border_color = color
	box.corner_radius_top_left = 10
	box.corner_radius_top_right = 10
	box.corner_radius_bottom_right = 10
	box.corner_radius_bottom_left = 10
	portrait_wrap.add_theme_stylebox_override("panel", box)
	portrait_wrap.custom_minimum_size = PORTRAIT_SIZE
	card.add_child(portrait_wrap)
	var portrait := CharacterPreviewScene.new()
	portrait.color_id = info.get("color_id", PlayerColors.DEFAULT_ID)
	portrait.custom_minimum_size = PORTRAIT_SIZE - Vector2(16, 16)
	var portrait_center := CenterContainer.new()
	portrait_center.add_child(portrait)
	portrait_wrap.add_child(portrait_center)

	var name_label := Label.new()
	var you_tag := "  (You)" if peer_id == my_id else ""
	name_label.text = "%s%s" % [info.get("username", "Player"), you_tag]
	name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	name_label.add_theme_font_size_override("font_size", 18)
	card.add_child(name_label)

	# Column slot's own x, evenly spanning the viewport width (COLUMN_COUNT
	# lanes, this card centered within its own lane), vertically centered.
	var viewport_size := get_viewport_rect().size
	var lane_width := viewport_size.x / float(COLUMN_COUNT)
	var lane_center_x := lane_width * (column_index + 0.5)
	var final_pos := Vector2(lane_center_x, viewport_size.y * 0.5) - card.custom_minimum_size * 0.5

	# Even columns (1st, 3rd) drop in from above; odd columns (2nd) rise in
	# from below -- far enough off (half the viewport plus the card's own
	# height) that it starts fully off-screen, no separate visibility toggle
	# needed to hide it before its turn.
	var dropping := column_index % 2 == 0
	var travel := viewport_size.y * 0.5 + card.custom_minimum_size.y
	card.position = final_pos + Vector2(0, -travel if dropping else travel)

	var tween := create_tween()
	tween.tween_interval(column_index * (SLIDE_DURATION_SEC + SLIDE_GAP_SEC))
	tween.tween_property(card, "position", final_pos, SLIDE_DURATION_SEC).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)

func _anchor_bottom_center(control: Control) -> void:
	var viewport_size := get_viewport_rect().size
	control.position = Vector2(viewport_size.x * 0.5, viewport_size.y - 90.0) - control.custom_minimum_size * 0.5
