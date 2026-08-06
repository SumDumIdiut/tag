extends Control
class_name FfaLobbyView

# Live N-sided card view for 3+-way FFA playlists (1v1v1, 1v1v1v1) -- the
# same idea team_lobby_view.gd already covers for exactly 2 sides (1v1/2v2),
# generalized to however many team_count() says. Each of these playlists is
# team_size 1, so exactly one card slot per side (no per-side stacking like
# team_lobby_view.gd's team_size>1 case needs for 2v2).
#
# Colors are the same fixed by-slot scheme (red/blue/yellow[/green]) real
# match start already assigns for these 4 official playlists -- see
# PlaylistCatalog.SLOT_COLORS/slot_colors_for() and network_manager.gd's
# _start_match_for_lobby, which overrides each peer's color_id to this same
# scheme right when a match is actually built. During live queueing (before
# that override happens) a roster entry's own color_id is still whatever
# stale per-connection color the server assigned on connect -- same
# staleness team_lobby_view.gd's set_roster() already documents and works
# around, by resolving each peer's side itself and coloring off of *that*,
# never off of info.color_id, so the live preview always matches what the
# real match will show instead of flashing a color that then changes.

const UIStyle := preload("res://ui/ui_style.gd")
const CharacterPreviewScene := preload("res://ui/character_preview.gd")
const RankBadgeScene := preload("res://ui/rank_badge.gd")
const PlaylistCatalog := preload("res://net/playlist_catalog.gd")

const CARD_PORTRAIT_SIZE := Vector2(120, 150)
const CARD_WIDTH := 200.0
const CARD_HEIGHT := 250.0
const SLIDE_DURATION_SEC := 0.34
const SLIDE_GAP_SEC := 0.12

@export var playlist_id: String = "1v1v1"
@export var ranked: bool = false
@export var my_id: int = -1

var _side_count: int = 3
var _side_boxes: Array = []
var _slot_nodes: Array = []
var _vs_labels: Array[Label] = []
# See team_lobby_view.gd's identical field/set_roster() comment -- a
# sentinel distinct from any real peer_id (including -1) so the first real
# set_roster() call always forces a rebuild rather than being mistaken for
# "my_id didn't change."
var _last_my_id: int = -999999

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_side_count = maxi(PlaylistCatalog.team_count(playlist_id), 1)
	_build_static_shell()

func _side_color(side: int) -> Color:
	return PlayerColors.color_for(PlaylistCatalog.SLOT_COLORS[side % PlaylistCatalog.SLOT_COLORS.size()])

## Same per-side CenterContainer-column idea as team_lobby_view.gd's own two
## halves, just N of them evenly spanning the width instead of a fixed 44%/
## 56% pair.
func _build_static_shell() -> void:
	var side_colors: Array[Color] = []
	for side in _side_count:
		side_colors.append(_side_color(side))

	var split := _MultiSplitBackground.new()
	split.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	split.side_colors = side_colors
	add_child(split)

	_side_boxes.resize(_side_count)
	_slot_nodes.resize(_side_count)
	for side in _side_count:
		var half := CenterContainer.new()
		half.name = "SideHalf%d" % side
		half.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		half.mouse_filter = Control.MOUSE_FILTER_IGNORE
		half.anchor_left = float(side) / _side_count
		half.anchor_right = float(side + 1) / _side_count
		add_child(half)
		_side_boxes[side] = half
		var placeholder := _build_placeholder_slot()
		var wrapper := _wrap_slot(placeholder)
		half.add_child(wrapper)
		_slot_nodes[side] = wrapper

	_build_vs_badges()

## See team_lobby_view.gd's identical helper for why a slot's real content
## needs a plain, non-container-managed wrapper: the CenterContainer that
## actually holds the wrapper repositions it on every resort, but never
## touches the wrapper's own children -- so animating the content's
## `position` inside the wrapper is safe, animating it directly as the
## CenterContainer's own child isn't.
func _wrap_slot(content: Control) -> Control:
	var wrapper := Control.new()
	wrapper.custom_minimum_size = content.custom_minimum_size
	wrapper.mouse_filter = Control.MOUSE_FILTER_IGNORE
	content.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	content.size = content.custom_minimum_size
	wrapper.add_child(content)
	return wrapper

## One small "VS" badge per divider line (side_count - 1 of them), like 1v1/
## 2v2's single badge sitting on their one shared line -- not one badge dead
## center, which for 3+ sides only ever sits on ONE of the divider lines
## (or on none of them, for an even split like 1v1v1) and reads as
## arbitrary. Sized as a fraction of the actual gap between two neighboring
## cards (section width minus a card's own width), not a fixed pixel size
## or a fixed-margin subtraction -- a fixed 110px badge (right for the
## 2-side view's much wider single gap) visibly overlapped both neighboring
## cards once sections got narrower than that, and a first fix here
## (section_w - CARD_WIDTH - 16, floored at 50px regardless of how much
## room actually existed) still only left ~8px of true clearance at this
## project's actual 1152-wide design viewport (see project.godot's
## window/size/viewport_width) once the 1v1v1v1 4-way case's narrower
## sections were accounted for -- enough for the badge's own soft glow to
## visibly bleed into the neighboring card. Taking half the gap and
## clamping well under the 3-way case's own generous width keeps a real,
## visible margin on every side count instead of assuming a margin that
## happened to just barely work at one specific resolution.
func _build_vs_badges() -> void:
	var viewport_w: float = maxf(get_viewport_rect().size.x, 1.0)
	var section_w := viewport_w / _side_count
	var available_gap := section_w - CARD_WIDTH
	var badge_diam := clampf(available_gap * 0.5, 32.0, 84.0)
	_vs_labels.clear()
	for i in range(1, _side_count):
		var frac := float(i) / _side_count
		var badge := _VsBadge.new()
		badge.accent_color = Color(0.85, 0.87, 0.93)
		badge.custom_minimum_size = Vector2(badge_diam, badge_diam)
		badge.size = Vector2(badge_diam, badge_diam)
		badge.anchor_left = frac
		badge.anchor_right = frac
		badge.anchor_top = 0.5
		badge.anchor_bottom = 0.5
		badge.position = Vector2(-badge_diam * 0.5, -badge_diam * 0.5)
		badge.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(badge)

		var label := Label.new()
		label.text = "VS"
		label.add_theme_font_size_override("font_size", maxi(int(badge_diam * 0.24), 12))
		label.add_theme_color_override("font_color", Color(0.95, 0.96, 0.98))
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		label.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		label.pivot_offset = badge.size * 0.5
		badge.add_child(label)
		_vs_labels.append(label)

func set_roster(new_roster: Dictionary) -> void:
	var teams := PlaylistCatalog.assign_teams(new_roster.keys(), _side_count)
	var side_peer := {}
	for peer_id in new_roster.keys():
		side_peer[teams.get(peer_id, 0)] = peer_id

	# See team_lobby_view.gd's identical comment -- a stale my_id (e.g. the
	# very first roster update landing before NetworkManager.my_peer_id
	# finished populating) can bake a wrong/missing "(You)" tag into a card
	# that the diff below then never revisits, since it only checks whether
	# a slot's OCCUPANT changed, not whether the viewer's own identity did.
	var force_rebuild := my_id != _last_my_id
	_last_my_id = my_id

	for side in _side_count:
		var peer_id = side_peer.get(side, null)
		var prev: Control = _slot_nodes[side]
		var prev_peer = prev.get_meta("peer_id") if prev and prev.has_meta("peer_id") else null
		if peer_id == prev_peer and not force_rebuild:
			continue
		var half: CenterContainer = _side_boxes[side]
		half.remove_child(prev)
		prev.queue_free()
		var fresh: Control
		if peer_id == null:
			fresh = _build_placeholder_slot()
		else:
			fresh = _build_card(peer_id, new_roster[peer_id], side)
		var wrapper := _wrap_slot(fresh)
		if peer_id != null:
			wrapper.set_meta("peer_id", peer_id)
		half.add_child(wrapper)
		_slot_nodes[side] = wrapper
		if peer_id != null:
			_slide_in(fresh, side)

func play_full_reveal() -> void:
	for i in _vs_labels.size():
		var label := _vs_labels[i]
		label.scale = Vector2.ZERO
		var tween := create_tween()
		tween.tween_property(label, "scale", Vector2(1.3, 1.3), 0.18).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
		tween.tween_property(label, "scale", Vector2.ONE, 0.12).set_trans(Tween.TRANS_SINE)

## Same staggered top/bottom slide as team_lobby_view.gd's own _slide_in
## (see there for the full reasoning) -- `content` is a slot's actual card/
## placeholder, a free-floating child of _wrap_slot()'s wrapper, so
## animating its own `position` is safe.
func _slide_in(content: Control, index: int) -> void:
	var final_pos := content.position
	var dropping := index % 2 == 0
	var viewport_size := get_viewport_rect().size
	var travel := viewport_size.y * 0.5 + content.custom_minimum_size.y
	content.modulate.a = 0.0
	content.position = final_pos + Vector2(0, -travel if dropping else travel)
	var delay: float = index * (SLIDE_DURATION_SEC + SLIDE_GAP_SEC)
	var tween := create_tween()
	tween.set_parallel(true)
	tween.tween_property(content, "position", final_pos, SLIDE_DURATION_SEC).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT).set_delay(delay)
	tween.tween_property(content, "modulate:a", 1.0, SLIDE_DURATION_SEC * 0.65).set_delay(delay)

func _build_placeholder_slot() -> Control:
	var reserved := CenterContainer.new()
	reserved.custom_minimum_size = Vector2(CARD_WIDTH, CARD_HEIGHT)

	var box := PanelContainer.new()
	box.custom_minimum_size = Vector2(CARD_WIDTH, CARD_PORTRAIT_SIZE.y * 0.55)
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.06, 0.065, 0.09, 0.7)
	style.border_width_left = 1
	style.border_width_top = 1
	style.border_width_right = 1
	style.border_width_bottom = 1
	style.border_color = Color(1, 1, 1, 0.07)
	style.corner_radius_top_left = 12
	style.corner_radius_top_right = 12
	style.corner_radius_bottom_right = 12
	style.corner_radius_bottom_left = 12
	box.add_theme_stylebox_override("panel", style)
	reserved.add_child(box)

	var label := Label.new()
	label.text = "Waiting..."
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.add_theme_font_size_override("font_size", 12)
	label.add_theme_color_override("font_color", Color(1, 1, 1, 0.22))
	box.add_child(label)
	return reserved

func _build_card(peer_id: int, info: Dictionary, side: int) -> VBoxContainer:
	var side_color: Color = _side_color(side)

	var card := VBoxContainer.new()
	card.custom_minimum_size = Vector2(CARD_WIDTH, CARD_HEIGHT)
	card.alignment = BoxContainer.ALIGNMENT_CENTER
	card.add_theme_constant_override("separation", 6)

	var portrait_wrap := PanelContainer.new()
	portrait_wrap.custom_minimum_size = Vector2(0, CARD_PORTRAIT_SIZE.y * 0.7)
	var wrap_style := StyleBoxFlat.new()
	wrap_style.bg_color = Color(side_color.r, side_color.g, side_color.b, 0.12)
	wrap_style.border_width_left = 1
	wrap_style.border_width_top = 1
	wrap_style.border_width_right = 1
	wrap_style.border_width_bottom = 1
	wrap_style.border_color = Color(side_color.r, side_color.g, side_color.b, 0.5)
	wrap_style.corner_radius_top_left = 14
	wrap_style.corner_radius_top_right = 14
	wrap_style.corner_radius_bottom_right = 14
	wrap_style.corner_radius_bottom_left = 14
	wrap_style.shadow_color = Color(side_color.r, side_color.g, side_color.b, 0.35)
	wrap_style.shadow_size = 14
	portrait_wrap.add_theme_stylebox_override("panel", wrap_style)
	card.add_child(portrait_wrap)
	var portrait_center := CenterContainer.new()
	portrait_wrap.add_child(portrait_center)
	var portrait := CharacterPreviewScene.new()
	# By-slot color (see PlaylistCatalog.SLOT_COLORS), not info's own
	# color_id -- same reasoning as team_lobby_view.gd's _build_card: this
	# preview needs to show the color the real match will actually assign,
	# not whichever stale per-connection color the roster entry still carries.
	portrait.color_id = PlaylistCatalog.SLOT_COLORS[side % PlaylistCatalog.SLOT_COLORS.size()]
	portrait.custom_minimum_size = CARD_PORTRAIT_SIZE * 0.65
	portrait_center.add_child(portrait)

	var you_tag := "  (You)" if peer_id == my_id else ""
	var name_label := Label.new()
	name_label.text = "%s%s" % [info.get("username", "Player"), you_tag]
	name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	name_label.add_theme_font_size_override("font_size", 16)
	name_label.add_theme_color_override("font_color", UIStyle.tier_color(info.get("tier", "")))
	card.add_child(name_label)

	if ranked:
		var elo: int = int(info.get("elo", -1))
		var tier: String = String(info.get("tier", ""))
		var stats_row := HBoxContainer.new()
		stats_row.alignment = BoxContainer.ALIGNMENT_CENTER
		stats_row.add_theme_constant_override("separation", 6)
		card.add_child(stats_row)
		if elo >= 0:
			var badge := RankBadgeScene.new()
			badge.tier = tier
			badge.custom_minimum_size = Vector2(20, 24)
			stats_row.add_child(badge)
			var elo_label := Label.new()
			elo_label.text = "%s · %d" % [tier, elo]
			elo_label.add_theme_font_size_override("font_size", 12)
			elo_label.add_theme_color_override("font_color", UIStyle.tier_color(tier))
			stats_row.add_child(elo_label)
		else:
			var unranked := Label.new()
			unranked.text = "Unranked"
			unranked.add_theme_font_size_override("font_size", 12)
			unranked.add_theme_color_override("font_color", UIStyle.COLOR_NEUTRAL)
			stats_row.add_child(unranked)

	return card

## Same dark base + per-side glow + divider technique as
## team_lobby_view.gd's own _SplitBackground, generalized from a fixed
## red/blue pair to however many colors the side list holds.
class _MultiSplitBackground extends Control:
	const BG_COLOR := Color(0.06, 0.065, 0.095)
	var side_colors: Array[Color] = []

	func _ready() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		resized.connect(queue_redraw)

	func _draw() -> void:
		var w: float = size.x
		var h: float = size.y
		draw_rect(Rect2(Vector2.ZERO, size), BG_COLOR)
		var n := maxi(1, side_colors.size())
		var section_w := w / float(n)
		var glow_radius := minf(section_w * 1.1, h * 0.9)
		for i in n:
			var cx := section_w * (i + 0.5)
			_draw_glow(Vector2(cx, h * 0.5), glow_radius, side_colors[i])
		for i in range(1, n):
			var lx := section_w * i
			draw_line(Vector2(lx, 0), Vector2(lx, h), Color(1, 1, 1, 0.05), 120.0)
			draw_line(Vector2(lx, 0), Vector2(lx, h), Color(1, 1, 1, 0.3), 1.5)

	func _draw_glow(center: Vector2, max_radius: float, color: Color) -> void:
		var steps := 28
		for i in steps:
			var t := float(steps - i) / float(steps)
			var radius := max_radius * t
			var alpha := 0.006 + 0.02 * (1.0 - t)
			draw_circle(center, radius, Color(color.r, color.g, color.b, alpha))

## Same glow-ring badge as team_lobby_view.gd's own _VsBadge (see there for
## the original/full comment) -- kept as a duplicate rather than a shared
## dependency between the two views, matching this codebase's own established
## preference for a little duplication between separate concerns over a
## shared abstraction neither side should have to know about the other
## through.
class _VsBadge extends Control:
	var accent_color: Color = Color(0.91, 0.29, 0.35)

	func _ready() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		resized.connect(queue_redraw)

	func _draw() -> void:
		var c := size * 0.5
		var radius := minf(size.x, size.y) * 0.5
		_draw_glow(c, radius, accent_color)
		draw_circle(c, radius * 0.6, Color(0.086, 0.09, 0.125, 0.96))

	func _draw_glow(center: Vector2, max_radius: float, color: Color) -> void:
		var steps := 28
		for i in steps:
			var t := float(steps - i) / float(steps)
			var r := max_radius * (0.55 + 0.45 * t)
			var alpha := 0.006 + 0.03 * (1.0 - t)
			draw_circle(center, r, Color(color.r, color.g, color.b, alpha))
