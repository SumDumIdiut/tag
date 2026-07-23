extends Control
class_name TeamLobbyView

# Shared live team-card view for 2-sided playlists (1v1, 2v2) -- used as
# both the pre-match "waiting for more players" room (lobby_room.gd for
# casual, ranked_queue.gd for ranked) and the post-"match found" reveal
# (match_intro.gd), since the user asked for those to be the same visual at
# two points in time rather than three separate screens. Only ever used for
# team_count == 2 playlists (1v1/2v2) -- 3+-way FFA playlists (1v1v1,
# 1v1v1v1) have no "sides" to show and keep the existing plain roster list.
#
# Generalizes match_intro.gd's original single-card-per-side VS layout
# (built earlier this session) to a vertical stack of up to `team_size`
# card slots per side -- a filled slot is a real player's card, an empty
# slot is a dark placeholder square, exactly the "2 people on one side,
# 1 person and a black square on the other" the user asked for.

const UIStyle := preload("res://ui/ui_style.gd")
const CharacterPreviewScene := preload("res://ui/character_preview.gd")
const RankBadgeScene := preload("res://ui/rank_badge.gd")
const PlaylistCatalog := preload("res://net/playlist_catalog.gd")

const CARD_PORTRAIT_SIZE := Vector2(150, 190)
const CARD_WIDTH := 260.0
const CARD_HEIGHT := 320.0
const SLOT_SEPARATION := 14.0

@export var playlist_id: String = "1v1"
@export var ranked: bool = false
@export var my_id: int = -1
@export var accent_color: Color = UIStyle.COLOR_RANKED

var _roster := {} # peer_id -> info dict (username, color_id, elo, tier, team)
var _slot_nodes := [[], []] # per side: ordered list of Control currently occupying each slot (card or placeholder)
var _side_boxes: Array = [null, null] # per side: the VBoxContainer stacking that side's slots
var _vs_label: Label
var _built := false

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_build_static_shell()

## Each side lives in its own CenterContainer spanning half the screen
## (leaving a gap in the middle for the divider/VS label) -- Godot's layout
## engine then centers the (variable-height, since a filled card and an
## empty placeholder aren't the same size) VBoxContainer stack both axes on
## its own, correctly, as slots fill/empty. A first pass hand-computed each
## side's position instead and got it visibly wrong (confirmed by
## screenshot: the second slot landed nowhere near its side) the moment slot
## heights weren't all identical -- not worth re-deriving that math by hand.
func _build_static_shell() -> void:
	var split := _SplitBackground.new()
	split.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	split.accent_color = accent_color
	add_child(split)

	var badge := _VsBadge.new()
	badge.accent_color = accent_color
	badge.custom_minimum_size = Vector2(132, 132)
	badge.size = Vector2(132, 132)
	badge.set_anchors_preset(Control.PRESET_CENTER)
	badge.position = -badge.size * 0.5
	badge.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(badge)

	_vs_label = Label.new()
	_vs_label.text = "VS"
	_vs_label.add_theme_font_size_override("font_size", 34)
	_vs_label.add_theme_color_override("font_color", Color(0.95, 0.96, 0.98))
	_vs_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_vs_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_vs_label.set_anchors_preset(Control.PRESET_CENTER)
	_vs_label.pivot_offset = Vector2(30, 22)
	_vs_label.position = Vector2(-30, -22)
	add_child(_vs_label)

	# Fixed-height slots (a placeholder reserves the exact same height a
	# real card would, just centering its own smaller box within that space)
	# so both sides' rows always land level with each other -- previously
	# each side's stack centered independently by its own actual content
	# height, so a side with a card + a placeholder visibly didn't line up
	# against a side with two placeholders.
	var team_size := PlaylistCatalog.team_size(playlist_id)
	for side in 2:
		var half := CenterContainer.new()
		half.name = "SideHalf%d" % side
		half.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		half.mouse_filter = Control.MOUSE_FILTER_IGNORE
		if side == 0:
			half.anchor_right = 0.44
		else:
			half.anchor_left = 0.56
		add_child(half)

		var side_box := VBoxContainer.new()
		side_box.add_theme_constant_override("separation", int(SLOT_SEPARATION))
		half.add_child(side_box)
		_side_boxes[side] = side_box
		for slot in team_size:
			var placeholder := _build_placeholder_slot()
			side_box.add_child(placeholder)
			_slot_nodes[side].append(placeholder)
	_built = true

## Full replace -- diffs against the currently-shown roster so only newly
## filled/emptied slots animate; already-settled cards are left alone.
func set_roster(new_roster: Dictionary) -> void:
	var team_count := PlaylistCatalog.team_count(playlist_id)
	var teams := _resolve_teams(new_roster, team_count)
	# 2-sided view: side 0 is my own team (or team 0 if I'm not in the
	# roster yet, e.g. previewing before joining), side 1 is the other.
	var my_team: int = teams.get(my_id, 0)
	var side_peers := [[], []]
	for peer_id in new_roster.keys():
		var t: int = teams.get(peer_id, 0)
		var side := 0 if t == my_team else 1
		side_peers[side].append(peer_id)

	var team_size := PlaylistCatalog.team_size(playlist_id)
	for side in 2:
		var side_box: VBoxContainer = _side_boxes[side]
		for slot in team_size:
			var peer_id = side_peers[side][slot] if slot < side_peers[side].size() else null
			var prev: Control = _slot_nodes[side][slot]
			# get_meta(name, default) still logs a console ERROR for a
			# missing key even though it returns the default fine (a known
			# Godot quirk) -- has_meta() first avoids the noise for every
			# placeholder slot, which never carries this key at all.
			var prev_peer = prev.get_meta("peer_id") if prev and prev.has_meta("peer_id") else null
			if peer_id == prev_peer:
				continue # unchanged -- leave whatever's already shown (and its animation state) alone
			side_box.remove_child(prev)
			prev.queue_free()
			var fresh: Control
			if peer_id == null:
				fresh = _build_placeholder_slot()
			else:
				# The peer's own color_id can be stale here -- it's whatever
				# per-connection color the server assigned before team/side
				# was even known, not the fixed by-team color the real match
				# will actually use (see PlaylistCatalog.slot_colors_for()).
				# Pass the real resolved team (not `side`, which is
				# viewer-relative -- "my own team" always renders on the
				# left) so the card shows the same color you'll actually see
				# in the match, not a mismatched preview.
				var actual_team: int = teams.get(peer_id, 0)
				fresh = _build_card(peer_id, new_roster[peer_id], actual_team)
				fresh.set_meta("peer_id", peer_id)
			side_box.add_child(fresh)
			side_box.move_child(fresh, slot)
			_slot_nodes[side][slot] = fresh
			if peer_id != null:
				_pop_in(fresh)
	_roster = new_roster

## Prefers whatever team assignment the server already actually made
## (present once a match has started -- see ServerMatch.roster, built from
## network_manager.gd's own assign_teams_grouped() before ServerMatch even
## exists) over recomputing one independently, so a party shown together in
## the live waiting-room preview below can never end up split apart in the
## post-match VS reveal just because this view re-derived teams from
## different, staler-or-differently-shaped data than the server used. Only
## meaningful for a real team playlist -- a 2-sided FFA playlist (1v1) has
## no server-assigned "team" at all (nothing to tag-protect), so it always
## falls through to the plain round robin, same as before.
func _resolve_teams(roster: Dictionary, team_count: int) -> Dictionary:
	if not PlaylistCatalog.is_team_mode(playlist_id):
		return PlaylistCatalog.assign_teams(roster.keys(), team_count)
	if _roster_has_real_teams(roster):
		var teams := {}
		for peer_id in roster.keys():
			teams[peer_id] = int(roster[peer_id].get("team", 0))
		return teams
	var peer_party_id := {}
	for peer_id in roster.keys():
		peer_party_id[peer_id] = roster[peer_id].get("party_id", "")
	return PlaylistCatalog.assign_teams_grouped(roster.keys(), peer_party_id, team_count, PlaylistCatalog.team_size(playlist_id))

func _roster_has_real_teams(roster: Dictionary) -> bool:
	if roster.is_empty():
		return false
	for peer_id in roster.keys():
		if int(roster[peer_id].get("team", -1)) < 0:
			return false
	return true

## The "match found" beat -- call once every slot is filled. Just the VS
## label's punch-in flourish; per-slot pop-ins already happened as each
## player joined via set_roster(), so this doesn't re-animate the cards.
func play_full_reveal() -> void:
	_vs_label.scale = Vector2.ZERO
	var tween := create_tween()
	tween.tween_property(_vs_label, "scale", Vector2(1.35, 1.35), 0.18).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tween.tween_property(_vs_label, "scale", Vector2.ONE, 0.12).set_trans(Tween.TRANS_SINE)

func _pop_in(node: Control) -> void:
	node.scale = Vector2(0.4, 0.4)
	node.pivot_offset = node.custom_minimum_size * 0.5
	var tween := create_tween()
	tween.tween_property(node, "scale", Vector2.ONE, 0.3).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)

## Reserves the exact same height a real card would (CARD_HEIGHT), the
## visible dark box centered within that space -- keeps this slot's row
## level with the same slot on the other side even when one side has a
## filled card and the other doesn't, since a filled card's own height is
## fixed too (see _build_card).
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
	label.add_theme_font_size_override("font_size", 13)
	label.add_theme_color_override("font_color", Color(1, 1, 1, 0.22))
	box.add_child(label)
	return reserved

func _build_card(peer_id: int, info: Dictionary, team: int) -> VBoxContainer:
	var team_color: Color = PlayerColors.color_for(PlaylistCatalog.SLOT_COLORS[team % PlaylistCatalog.SLOT_COLORS.size()])

	var card := VBoxContainer.new()
	card.custom_minimum_size = Vector2(CARD_WIDTH, CARD_HEIGHT)
	card.alignment = BoxContainer.ALIGNMENT_CENTER
	card.add_theme_constant_override("separation", 8)

	var portrait_wrap := PanelContainer.new()
	portrait_wrap.custom_minimum_size = Vector2(0, CARD_PORTRAIT_SIZE.y * 0.7)
	# A soft panel behind the portrait, tinted to the player's own team
	# color -- replaces the old bare CenterContainer with something that
	# actually reads as "this player's card," not just a floating square.
	var wrap_style := StyleBoxFlat.new()
	wrap_style.bg_color = Color(team_color.r, team_color.g, team_color.b, 0.12)
	wrap_style.border_width_left = 1
	wrap_style.border_width_top = 1
	wrap_style.border_width_right = 1
	wrap_style.border_width_bottom = 1
	wrap_style.border_color = Color(team_color.r, team_color.g, team_color.b, 0.5)
	wrap_style.corner_radius_top_left = 14
	wrap_style.corner_radius_top_right = 14
	wrap_style.corner_radius_bottom_right = 14
	wrap_style.corner_radius_bottom_left = 14
	wrap_style.shadow_color = Color(team_color.r, team_color.g, team_color.b, 0.35)
	wrap_style.shadow_size = 16
	portrait_wrap.add_theme_stylebox_override("panel", wrap_style)
	card.add_child(portrait_wrap)
	var portrait_center := CenterContainer.new()
	portrait_wrap.add_child(portrait_center)
	var portrait := CharacterPreviewScene.new()
	# By-team color (see PlaylistCatalog.SLOT_COLORS/slot_colors_for), not
	# info's own color_id -- this view is only ever used for 1v1/2v2 (both
	# among the 4 playlists that get the fixed by-team scheme at real match
	# start), so team directly determines the color you'll actually have.
	portrait.color_id = PlaylistCatalog.SLOT_COLORS[team % PlaylistCatalog.SLOT_COLORS.size()]
	portrait.custom_minimum_size = CARD_PORTRAIT_SIZE * 0.65
	portrait_center.add_child(portrait)

	var you_tag := "  (You)" if peer_id == my_id else ""
	var name_label := Label.new()
	name_label.text = "%s%s" % [info.get("username", "Player"), you_tag]
	name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	name_label.add_theme_font_size_override("font_size", 18)
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
			badge.custom_minimum_size = Vector2(22, 26)
			stats_row.add_child(badge)
			var elo_label := Label.new()
			elo_label.text = "%s · %d" % [tier, elo]
			elo_label.add_theme_font_size_override("font_size", 13)
			elo_label.add_theme_color_override("font_color", UIStyle.tier_color(tier))
			stats_row.add_child(elo_label)
		else:
			var unranked := Label.new()
			unranked.text = "Unranked"
			unranked.add_theme_font_size_override("font_size", 13)
			unranked.add_theme_color_override("font_color", UIStyle.COLOR_NEUTRAL)
			stats_row.add_child(unranked)

	return card

## A plain dark base (matching every other screen's own dark background)
## with each side's own identity color as a soft glow behind that side's
## cards -- reads as mood lighting, not a hazard-stripe split. A slim
## glowing divider replaces the old random-jitter jagged seam. Concentric
## alpha-blended circles for the glow (same technique _VsBadge below uses
## for its own ring) rather than a GradientTexture2D stretched over
## draw_texture_rect -- simpler to reason about and get right than fighting
## UV-space fill_from/fill_to math for a result this soft anyway.
class _SplitBackground extends Control:
	const BG_COLOR := Color(0.06, 0.065, 0.095)
	const SIDE_B_COLOR := Color(0.3, 0.42, 0.85)
	var accent_color: Color = Color(0.91, 0.29, 0.35)

	func _ready() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		resized.connect(queue_redraw)

	func _draw() -> void:
		var w: float = size.x
		var h: float = size.y
		draw_rect(Rect2(Vector2.ZERO, size), BG_COLOR)

		# Contained near each side's own cards, not spanning past the
		# midline -- half the width at most, so it reads as a glow behind
		# that side specifically rather than a wash across the whole screen.
		var glow_radius := minf(w * 0.5, h * 0.9)
		_draw_glow(Vector2(w * 0.24, h * 0.5), glow_radius, accent_color)
		_draw_glow(Vector2(w * 0.76, h * 0.5), glow_radius, SIDE_B_COLOR)

		var cx := w * 0.5
		draw_line(Vector2(cx, 0), Vector2(cx, h), Color(1, 1, 1, 0.05), 160.0)
		draw_line(Vector2(cx, 0), Vector2(cx, h), Color(1, 1, 1, 0.3), 1.5)

	func _draw_glow(center: Vector2, max_radius: float, color: Color) -> void:
		var steps := 28
		for i in steps:
			var t := float(steps - i) / float(steps) # 1.0 (largest, faintest) down to ~1/steps (smallest, strongest)
			var radius := max_radius * t
			var alpha := 0.006 + 0.02 * (1.0 - t)
			draw_circle(center, radius, Color(color.r, color.g, color.b, alpha))

## A small, restrained circular badge behind the "VS" text -- a soft glow
## ring in the round's own accent color, not an oversized jagged comic-book
## impact star dominating the middle of the screen.
class _VsBadge extends Control:
	var accent_color: Color = Color(0.91, 0.29, 0.35)

	func _ready() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func _draw() -> void:
		var c := size * 0.5
		var radius := minf(size.x, size.y) * 0.5
		for i in 5:
			var t := float(5 - i) / 5.0
			draw_circle(c, radius * (0.55 + 0.45 * t), Color(accent_color.r, accent_color.g, accent_color.b, 0.05 + 0.05 * (1.0 - t)))
		draw_circle(c, radius * 0.6, Color(0.086, 0.09, 0.125, 0.96))
		draw_arc(c, radius * 0.6, 0, TAU, 48, accent_color, 3.0, true)
