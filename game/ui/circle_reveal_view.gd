extends Control
class_name CircleRevealView

# Pre-match reveal for a private match with more than 4 players (see
# match_intro.gd's _circle_mode) -- there's no "sides" to show the way the
# 2-team VS view has, so everyone just gets arranged in a ring instead.
# Portraits get the same bordered/tinted panel treatment as
# corners_reveal_view.gd/columns_reveal_view.gd for visual consistency
# across all four reveal types -- still text and color only, no icons. Pure
# code, no .tscn, matching team_lobby_view.gd's own pattern. The whole
# roster is already known up front (match_started never fires with a
# partial one), so unlike team_lobby_view this only ever lays out once --
# no incremental diffing needed.
#
# Unlike corners (fixed 4) and columns (fixed 3), this can have up to
# DEFAULT_MAX_PLAYERS (16) participants, so a strict one-at-a-time stagger
# like theirs would eat most of CIRCLE_REVEAL_DURATION_SEC on its own at
# high counts. Delays are instead spread evenly across a fixed total span
# (STAGGER_SPAN_SEC) regardless of headcount, so the ring always finishes
# settling well within the reveal window, and each card flies in from
# further out along its own resting angle -- the same "converge in from
# beyond the final spot" idea corners/columns use, applied radially.

const CharacterPreviewScene := preload("res://ui/character_preview.gd")
const UIStyle := preload("res://ui/ui_style.gd")

const PORTRAIT_SIZE := Vector2(64, 64)
const BASE_RADIUS := 150.0
const RADIUS_PER_PLAYER := 12.0
const MAX_RADIUS := 340.0
const INBOUND_TRAVEL := 200.0 # extra distance beyond final radius each card flies in from
const SLIDE_DURATION_SEC := 0.4
const STAGGER_SPAN_SEC := 1.6 # total time entrances are spread across, independent of headcount

@export var my_id: int = -1

var countdown_label: Label

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	countdown_label = Label.new()
	countdown_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	countdown_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	countdown_label.add_theme_font_size_override("font_size", 40)
	countdown_label.custom_minimum_size = Vector2(200, 80)
	add_child(countdown_label)
	_center_on(countdown_label, Vector2.ZERO)

func set_roster(roster: Dictionary) -> void:
	for child in get_children():
		if child != countdown_label:
			remove_child(child)
			child.queue_free()
	var peer_ids := roster.keys()
	var n := peer_ids.size()
	if n == 0:
		return
	# Radius grows with headcount (up to a cap) so a 16-player circle doesn't
	# crowd its portraits into each other the way a fixed radius would.
	var radius: float = minf(BASE_RADIUS + RADIUS_PER_PLAYER * n, MAX_RADIUS)
	for i in n:
		_place_participant(peer_ids[i], roster[peer_ids[i]], i, n, radius)

func _place_participant(peer_id: int, info: Dictionary, index: int, total: int, radius: float) -> void:
	var card := VBoxContainer.new()
	card.alignment = BoxContainer.ALIGNMENT_CENTER
	card.add_theme_constant_override("separation", 4)
	card.mouse_filter = Control.MOUSE_FILTER_IGNORE
	card.custom_minimum_size = Vector2(110, 90)
	add_child(card)

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
	portrait.custom_minimum_size = PORTRAIT_SIZE - Vector2(10, 10)
	var portrait_center := CenterContainer.new()
	portrait_center.add_child(portrait)
	portrait_wrap.add_child(portrait_center)

	var name_label := Label.new()
	var you_tag := "  (You)" if peer_id == my_id else ""
	name_label.text = "%s%s" % [info.get("username", "Player"), you_tag]
	name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	name_label.add_theme_font_size_override("font_size", 14)
	name_label.add_theme_color_override("font_color", UIStyle.tier_color(info.get("tier", "")))
	card.add_child(name_label)

	var angle := TAU * index / float(total) - PI / 2.0
	var direction := Vector2(cos(angle), sin(angle))
	_center_on(card, direction * radius)
	var final_pos := card.position

	# set_delay() on each Tweener directly, not tween_interval() + set_parallel()
	# -- set_parallel(true) makes every tweener appended after it run alongside
	# the one immediately before it rather than after the whole chain so far,
	# which would race the delay away entirely (see corners_reveal_view.gd's
	# own note on this). Explicit per-tweener delays sidestep the ordering
	# ambiguity -- both properties start at exactly the same time.
	card.position = final_pos + direction * INBOUND_TRAVEL
	card.scale = Vector2.ZERO
	card.pivot_offset = card.custom_minimum_size * 0.5

	var delay: float = (float(index) / float(total)) * STAGGER_SPAN_SEC
	var tween := create_tween()
	tween.set_parallel(true)
	tween.tween_property(card, "position", final_pos, SLIDE_DURATION_SEC).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT).set_delay(delay)
	tween.tween_property(card, "scale", Vector2.ONE, SLIDE_DURATION_SEC).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT).set_delay(delay)

## Positions a control's top-left corner so it ends up centered on
## (viewport center + offset) -- plain top-left anchors throughout rather
## than Control's anchor-preset tricks, which depend on the parent's anchor
## propagation having already resolved by the time this runs; the viewport
## rect is always immediately correct, no such timing to worry about.
func _center_on(control: Control, offset: Vector2) -> void:
	var center := get_viewport_rect().size * 0.5
	control.position = center + offset - control.custom_minimum_size * 0.5
