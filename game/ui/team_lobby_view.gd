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
const SLIDE_DURATION_SEC := 0.34
const SLIDE_GAP_SEC := 0.12

@export var playlist_id: String = "1v1"
@export var ranked: bool = false
@export var my_id: int = -1
@export var accent_color: Color = UIStyle.COLOR_RANKED
# The queue's own colored split, VS badge, and glowing/rank-line cards give
# a plain waiting room some identity while nothing else is happening --
# match_intro.gd's post-"match found" reveal sets this to false, matching
# the plain flat-bordered cards on a plain black backdrop that columns_
# reveal_view.gd/corners_reveal_view.gd's own 3+-way reveals already use (no
# background, no badge, no glow, no rank line -- see _build_plain_card()),
# so the reveal's slide-in cards are the only thing moving/visible instead
# of competing with a still-visible glowing waiting-room look left over from
# a moment before.
@export var queue_style: bool = true

var _roster := {} # peer_id -> info dict (username, color_id, elo, tier, team)
var _slot_nodes := [[], []] # per side: ordered list of Control currently occupying each slot (card or placeholder)
var _side_boxes: Array = [null, null] # per side: the VBoxContainer stacking that side's slots
var _vs_label: Label
var _built := false
# See set_roster()'s own force_rebuild comment -- a sentinel distinct from
# any real peer_id (including the -1 "not connected yet" default) so the
# very first real set_roster() call is never mistaken for "my_id didn't
# change."
var _last_my_id: int = -999999

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
	if queue_style:
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

		# A child of badge, sized to fill it exactly (PRESET_FULL_RECT), rather
		# than a sibling independently anchored to screen-center with a
		# hand-guessed pixel offset -- that guess assumed the Label's auto-size
		# would land at exactly 60x44, which it doesn't (font metrics for "VS"
		# at this size come out slightly different), so the text visibly drifted
		# off-center from the badge's own true center. Filling the badge's own
		# rect and centering via alignment is correct regardless of glyph size.
		_vs_label = Label.new()
		_vs_label.text = "VS"
		_vs_label.add_theme_font_size_override("font_size", 34)
		_vs_label.add_theme_color_override("font_color", Color(0.95, 0.96, 0.98))
		_vs_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_vs_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		_vs_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_vs_label.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		_vs_label.pivot_offset = badge.size * 0.5
		badge.add_child(_vs_label)

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
			var wrapper := _wrap_slot(placeholder)
			side_box.add_child(wrapper)
			_slot_nodes[side].append(wrapper)
	_built = true

## A slot's real content (card or placeholder) sits inside a plain, non-
## container-managed wrapper -- side_box (a VBoxContainer) lays out and
## repositions the wrapper on every resort, while the content inside it
## keeps a freely animatable `position` of its own, so _slide_in() below can
## move it without a layout pass stomping the animation mid-flight. This is
## exactly the failure mode this file's own header comment already
## describes hitting once, the first time a slot's position was animated
## directly as a container's own child.
func _wrap_slot(content: Control) -> Control:
	var wrapper := Control.new()
	wrapper.custom_minimum_size = content.custom_minimum_size
	wrapper.mouse_filter = Control.MOUSE_FILTER_IGNORE
	content.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	content.size = content.custom_minimum_size
	wrapper.add_child(content)
	return wrapper

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

	# A change in my_id invalidates every slot's already-built side
	# assignment and "(You)" tag even for a peer that hasn't otherwise
	# moved -- the diff below only checks "did the OCCUPANT of this slot
	# change," not "did the viewer's own identity," so without this a
	# my_id that was still -1 (or otherwise stale) on an earlier call --
	# e.g. the very first roster update arriving a tick before
	# NetworkManager.my_peer_id finished populating -- could bake in the
	# WRONG side/tag permanently: once a slot's occupant stops changing,
	# the diff below never revisits it again, even after my_id later
	# becomes correct. Confirmed as the live "my own screen tags the OTHER
	# player (You)" report: the fix is forcing every slot to rebuild the
	# one time my_id itself changes, not just when who's in a slot does.
	var force_rebuild := my_id != _last_my_id
	_last_my_id = my_id

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
			if peer_id == prev_peer and not force_rebuild:
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
			var wrapper := _wrap_slot(fresh)
			if peer_id != null:
				wrapper.set_meta("peer_id", peer_id)
			side_box.add_child(wrapper)
			side_box.move_child(wrapper, slot)
			_slot_nodes[side][slot] = wrapper
			if peer_id != null:
				_slide_in(fresh, side * team_size + slot)
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
## No-op in the plain reveal style (queue_style == false) -- there's no
## badge/label to punch, matching columns/corners_reveal_view.gd having no
## such flourish of their own either.
func play_full_reveal() -> void:
	if not _vs_label:
		return
	_vs_label.scale = Vector2.ZERO
	var tween := create_tween()
	tween.tween_property(_vs_label, "scale", Vector2(1.35, 1.35), 0.18).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tween.tween_property(_vs_label, "scale", Vector2.ONE, 0.12).set_trans(Tween.TRANS_SINE)

## Same staggered top/bottom slide columns_reveal_view.gd/corners_reveal_
## view.gd's own reveals use (drop for an even index, rise for an odd one,
## strictly one card at a time rather than an overlapping stagger), replacing
## the old plain scale-in pop and a first slide attempt that was both too
## subtle (a fixed 70px travel next to these reveals' near-full-viewport
## slide) and, worse, silently not staggering at all: delay must be set per-
## Tweener via set_delay(), NOT tween_interval()+set_parallel() -- see
## corners_reveal_view.gd's own header comment on that exact bug
## (set_parallel(true) makes the tweener right after it run alongside the
## one before it, which here was the interval itself, racing the delay away
## entirely so every card animated from frame 0 regardless of index).
## `content` is a slot's actual card/placeholder, a free-floating child of
## _wrap_slot()'s wrapper (see there for why), so animating its own
## `position` is safe here in a way it isn't for something still directly
## parented to the VBoxContainer itself.
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
	if not queue_style:
		return _build_plain_card(peer_id, info, team)

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

## The reveal's plain card style (queue_style == false) -- a flat solid-
## color border instead of the queue's glowing/shadowed panel, and no rank/
## elo row regardless of `ranked`, matching columns_reveal_view.gd's/
## corners_reveal_view.gd's own _build_column()/_build_corner() exactly
## (same border width, same fill alpha, same lack of a rank line) so the
## "match found" moment reads identically for every playlist shape instead
## of 1v1/2v2 alone keeping the richer waiting-room look a beat too long.
func _build_plain_card(peer_id: int, info: Dictionary, team: int) -> VBoxContainer:
	var team_color: Color = PlayerColors.color_for(PlaylistCatalog.SLOT_COLORS[team % PlaylistCatalog.SLOT_COLORS.size()])

	var card := VBoxContainer.new()
	card.custom_minimum_size = Vector2(CARD_WIDTH, CARD_HEIGHT)
	card.alignment = BoxContainer.ALIGNMENT_CENTER
	card.add_theme_constant_override("separation", 10)

	# Tight box hugging the portrait (matches columns_reveal_view.gd's own
	# _build_column() exactly: box == CARD_PORTRAIT_SIZE, portrait inset only
	# 16px, SHRINK_CENTER so it doesn't stretch to the VBoxContainer's full
	# CARD_WIDTH) -- a first pass reused the rich style's own wrap sizing
	# (0.7x height, full card width, 0.65x portrait), which was tuned for a
	# wide glowing panel, not this flat style: the result was a much wider
	# box than its own portrait, reading as nested vertical bands instead of
	# one solid-colored square.
	var portrait_wrap := PanelContainer.new()
	portrait_wrap.custom_minimum_size = CARD_PORTRAIT_SIZE
	portrait_wrap.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	var box := StyleBoxFlat.new()
	box.bg_color = Color(team_color.r, team_color.g, team_color.b, 0.16)
	box.border_width_left = 3
	box.border_width_top = 3
	box.border_width_right = 3
	box.border_width_bottom = 3
	box.border_color = team_color
	box.corner_radius_top_left = 10
	box.corner_radius_top_right = 10
	box.corner_radius_bottom_right = 10
	box.corner_radius_bottom_left = 10
	portrait_wrap.add_theme_stylebox_override("panel", box)
	card.add_child(portrait_wrap)
	var portrait_center := CenterContainer.new()
	portrait_wrap.add_child(portrait_center)
	var portrait := CharacterPreviewScene.new()
	portrait.color_id = PlaylistCatalog.SLOT_COLORS[team % PlaylistCatalog.SLOT_COLORS.size()]
	portrait.custom_minimum_size = CARD_PORTRAIT_SIZE - Vector2(16, 16)
	portrait_center.add_child(portrait)

	var you_tag := "  (You)" if peer_id == my_id else ""
	var name_label := Label.new()
	name_label.text = "%s%s" % [info.get("username", "Player"), you_tag]
	name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	name_label.add_theme_font_size_override("font_size", 18)
	name_label.add_theme_color_override("font_color", UIStyle.tier_color(info.get("tier", "")))
	card.add_child(name_label)

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
		# Without this, a size change after the first _draw() (e.g. the
		# explicit size assignment in _build_static_shell landing before
		# layout has settled) leaves the glow baked in at whatever radius
		# was true at that first, possibly-wrong draw -- looking like a
		# lopsided/broken ring frozen mid-transition instead of a clean
		# circle, since nothing ever tells it to redraw at the corrected size.
		resized.connect(queue_redraw)

	func _draw() -> void:
		var c := size * 0.5
		var radius := minf(size.x, size.y) * 0.5
		_draw_glow(c, radius, accent_color)
		draw_circle(c, radius * 0.6, Color(0.086, 0.09, 0.125, 0.96))

	# Same 28-step smooth ring-stack _SplitBackground's own glow uses (see
	# its _draw_glow below) -- the previous 5-step version here was coarse
	# enough to show visible banding (concentric hard edges) instead of a
	# smooth soft glow, reading as "broken" next to the rest of this screen.
	func _draw_glow(center: Vector2, max_radius: float, color: Color) -> void:
		var steps := 28
		for i in steps:
			var t := float(steps - i) / float(steps)
			var r := max_radius * (0.55 + 0.45 * t)
			var alpha := 0.006 + 0.03 * (1.0 - t)
			draw_circle(center, r, Color(color.r, color.g, color.b, alpha))
