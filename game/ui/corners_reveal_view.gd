extends Control
class_name CornersRevealView

# Pre-match reveal for a 4-way FFA playlist (1v1v1v1, see match_intro.gd's
# _corners_mode) -- exactly 4 participants, always, one at each screen
# corner. Text and color only (no icons), pure code/no .tscn, matching
# circle_reveal_view.gd's own pattern -- roster is fully known up front, so
# this only ever lays out once.

const CharacterPreviewScene := preload("res://ui/character_preview.gd")

const PORTRAIT_SIZE := Vector2(90, 110)
const EDGE_MARGIN := 70.0
# Corner order matches a natural reading order (top-left, top-right,
# bottom-left, bottom-right); each card slides in from further out along its
# own corner's diagonal while punching to full scale, so all 4 visibly
# converge in from their corners rather than just popping in place -- the
# "custom" part of this reveal, distinct from the plain center-scale pop
# every other reveal uses.
const CORNERS := [Vector2(0, 0), Vector2(1, 0), Vector2(0, 1), Vector2(1, 1)]
const SLIDE_DISTANCE := 90.0
const STAGGER_SEC := 0.1

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
	var viewport_size := get_viewport_rect().size
	countdown_label.position = viewport_size * 0.5 - countdown_label.custom_minimum_size * 0.5

func set_roster(roster: Dictionary) -> void:
	for card in _cards:
		card.queue_free()
	_cards.clear()
	var peer_ids := roster.keys()
	for i in mini(peer_ids.size(), CORNERS.size()):
		_build_corner(peer_ids[i], roster[peer_ids[i]], i)

func _build_corner(peer_id: int, info: Dictionary, corner_index: int) -> void:
	var card := VBoxContainer.new()
	card.alignment = BoxContainer.ALIGNMENT_CENTER
	card.add_theme_constant_override("separation", 8)
	card.mouse_filter = Control.MOUSE_FILTER_IGNORE
	card.custom_minimum_size = Vector2(PORTRAIT_SIZE.x, PORTRAIT_SIZE.y + 34)
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
	portrait.custom_minimum_size = PORTRAIT_SIZE - Vector2(14, 14)
	var portrait_center := CenterContainer.new()
	portrait_center.add_child(portrait)
	portrait_wrap.add_child(portrait_center)

	var name_label := Label.new()
	var you_tag := "  (You)" if peer_id == my_id else ""
	name_label.text = "%s%s" % [info.get("username", "Player"), you_tag]
	name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	name_label.add_theme_font_size_override("font_size", 15)
	card.add_child(name_label)

	var corner: Vector2 = CORNERS[corner_index]
	var viewport_size := get_viewport_rect().size
	var final_pos := Vector2(
		lerp(EDGE_MARGIN, viewport_size.x - EDGE_MARGIN - card.custom_minimum_size.x, corner.x),
		lerp(EDGE_MARGIN, viewport_size.y - EDGE_MARGIN - card.custom_minimum_size.y, corner.y)
	)
	# Diagonal unit vector pointing further into that same corner, to slide
	# in FROM (e.g. top-left's card starts up and to the left of its own
	# resting spot).
	var diagonal := (Vector2(corner.x, corner.y) * 2.0 - Vector2.ONE).normalized()
	card.position = final_pos + diagonal * SLIDE_DISTANCE

	card.scale = Vector2.ZERO
	card.pivot_offset = card.custom_minimum_size * 0.5
	var tween := create_tween()
	tween.tween_interval(corner_index * STAGGER_SEC)
	tween.set_parallel(true)
	tween.tween_property(card, "position", final_pos, 0.34).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tween.tween_property(card, "scale", Vector2.ONE, 0.34).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
