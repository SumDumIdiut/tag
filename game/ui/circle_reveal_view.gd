extends Control
class_name CircleRevealView

# Pre-match reveal for a private match with more than 4 players (see
# match_intro.gd's _circle_mode) -- there's no "sides" to show the way the
# 2-team VS view has, so everyone just gets arranged in a ring instead, text
# and color only (no icons -- see this feature's own no-decoration rule).
# Pure code, no .tscn, matching team_lobby_view.gd's own pattern. The whole
# roster is already known up front (match_started never fires with a
# partial one), so unlike team_lobby_view this only ever lays out once --
# no incremental diffing needed.

const CharacterPreviewScene := preload("res://ui/character_preview.gd")
const UIStyle := preload("res://ui/ui_style.gd")

const PORTRAIT_SIZE := Vector2(64, 64)
const BASE_RADIUS := 150.0
const RADIUS_PER_PLAYER := 12.0
const MAX_RADIUS := 340.0

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

	var portrait_wrap := CenterContainer.new()
	portrait_wrap.custom_minimum_size = PORTRAIT_SIZE
	card.add_child(portrait_wrap)
	var portrait := CharacterPreviewScene.new()
	portrait.color_id = info.get("color_id", PlayerColors.DEFAULT_ID)
	portrait.custom_minimum_size = PORTRAIT_SIZE
	portrait_wrap.add_child(portrait)

	var name_label := Label.new()
	var you_tag := "  (You)" if peer_id == my_id else ""
	name_label.text = "%s%s" % [info.get("username", "Player"), you_tag]
	name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	name_label.add_theme_font_size_override("font_size", 14)
	name_label.add_theme_color_override("font_color", UIStyle.tier_color(info.get("tier", "")))
	card.add_child(name_label)

	var angle := TAU * index / float(total) - PI / 2.0
	_center_on(card, Vector2(cos(angle), sin(angle)) * radius)

## Positions a control's top-left corner so it ends up centered on
## (viewport center + offset) -- plain top-left anchors throughout rather
## than Control's anchor-preset tricks, which depend on the parent's anchor
## propagation having already resolved by the time this runs; the viewport
## rect is always immediately correct, no such timing to worry about.
func _center_on(control: Control, offset: Vector2) -> void:
	var center := get_viewport_rect().size * 0.5
	control.position = center + offset - control.custom_minimum_size * 0.5
