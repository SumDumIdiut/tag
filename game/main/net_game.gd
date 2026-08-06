extends Node2D

const REMOTE_AVATAR_SCENE := preload("res://player/remote_avatar.tscn")
const MATCH_RESULTS_SCENE := preload("res://main/match_results.tscn")
const OnlineMapCatalog := preload("res://levels/online_maps/catalog.gd")
const LevelData := preload("res://levels/level_data.gd")
const UIStyle := preload("res://ui/ui_style.gd")
const RankBadgeScene := preload("res://ui/rank_badge.gd")
const FixedView := preload("res://levels/fixed_view.gd")

# Leaderboard panel sizing -- see _build_leaderboard()/_render_leaderboard().
# Header is the "LEAST TIME AS IT WINS" title + its separation from the row
# list; row is one entry's own height plus the inter-row separation; padding
# is panel_box()'s own content margin (14px top + 14px bottom, see
# ui_style.gd) plus a couple px of slack so descenders never clip.
const LEADERBOARD_HEADER_HEIGHT := 24.0
const LEADERBOARD_ROW_HEIGHT := 23.0
const LEADERBOARD_PADDING := 30.0

var _leaderboard_panel: PanelContainer

var arena: Node2D
var avatars := {} # peer_id -> RemoteAvatar, including your own
var my_peer_id := -1
var roster := {} # peer_id -> {username, color_id}
var level_id := ""
var hud: Label
# hud/the leaderboard live here, not directly under this Node2D -- a plain
# Control child of a Node2D still renders through that Node2D's own 2D
# canvas transform, so without this isolation the local avatar's active
# Camera2D would drag both around the screen along with it instead of
# leaving them pinned to fixed screen corners.
var _ui_layer: CanvasLayer
var _leaderboard_box: VBoxContainer
# Whichever peer_ids are currently "it" -- a team playlist (2v2) can have
# two simultaneously (one per side, see tag_mode.gd), so this has to track
# the whole set, not just one, or a change to whichever peer isn't currently
# occupying a single tracked slot would silently never trigger a re-render.
var _last_it_peer_ids: Array = []

func setup(p_my_peer_id: int, p_roster: Dictionary, p_level_id: String = "") -> void:
	my_peer_id = p_my_peer_id
	roster = p_roster
	level_id = p_level_id

func _ready() -> void:
	# Most matches resolve purely locally, from the same built-in catalog
	# server_match.gd uses. A "level_..." id is a live-published custom
	# level instead, read straight out of CustomLevelCache -- see
	# server_match.gd's identical resolution and that autoload's own header
	# for the full reasoning (same LevelData build, just for rendering here
	# rather than authoritative collision).
	if level_id.begins_with("level_"):
		var data := CustomLevelCache.get_level_data(level_id)
		if data.is_empty():
			push_warning("NetGame: custom level %s not in the startup cache -- falling back to the default arena" % level_id)
			arena = load(OnlineMapCatalog.scene_path_for("")).instantiate()
		else:
			arena = LevelData.build_arena_from_data(data, CustomLevelCache.get_level_textures(level_id), CustomLevelCache.get_level_background(level_id))
	else:
		arena = load(OnlineMapCatalog.scene_path_for(level_id)).instantiate()
	add_child(arena)

	# Same fixed, non-following camera local/bot play uses (see game.gd) --
	# every player, spectator included, sees the whole map at once, so
	# there's no per-avatar "whose camera is active" logic needed here
	# anymore at all.
	add_child(FixedView.make_camera(arena.get_node("Background").bounds))

	_ui_layer = CanvasLayer.new()
	add_child(_ui_layer)

	var hud_panel := PanelContainer.new()
	hud_panel.anchor_left = 0.0
	hud_panel.anchor_right = 0.0
	hud_panel.offset_left = 16.0
	hud_panel.offset_right = 220.0
	hud_panel.offset_top = 16.0
	hud_panel.offset_bottom = 52.0
	hud_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hud_panel.add_theme_stylebox_override("panel", UIStyle.panel_box(UIStyle.COLOR_NEUTRAL))
	_ui_layer.add_child(hud_panel)

	hud = Label.new()
	hud.add_theme_color_override("font_color", Color.WHITE)
	hud.add_theme_font_size_override("font_size", 18)
	hud.text = "Connecting..."
	hud_panel.add_child(hud)

	_build_leaderboard()

	NetworkManager.match_state_received.connect(_on_match_state)
	NetworkManager.disconnected_from_server.connect(_on_disconnected)
	NetworkManager.match_ended.connect(_on_match_ended)

	# Every player, yours included, is a RemoteAvatar -- there's no local
	# prediction anywhere anymore, so no reason for your own avatar to be
	# built any differently from everyone else's, and (now that the camera
	# is fixed on the whole map, not following any one avatar) no reason to
	# track which peer is "you" for rendering purposes at all.
	for peer_id in roster.keys():
		var info: Dictionary = roster[peer_id]
		var avatar: RemoteAvatar = REMOTE_AVATAR_SCENE.instantiate()
		add_child(avatar)
		avatar.display_name = info.username
		avatars[peer_id] = avatar
		_apply_color(peer_id)

	# my_peer_id == -1 means we're spectating (see NetworkManager.start_
	# spectator) -- the fixed camera already shows the whole match either
	# way, so the only spectator-specific thing left is the HUD label.
	if my_peer_id == -1:
		hud.text = "Spectating"

func _apply_color(peer_id: int) -> void:
	if not avatars.has(peer_id) or not roster.has(peer_id):
		return
	var color_id: String = roster[peer_id].get("color_id", PlayerColors.DEFAULT_ID)
	avatars[peer_id].set_color(color_id)

## A side panel (no scrolling -- fits a private match's max 16 participants
## even at full height) ranking everyone by time spent as "it" so far, least
## first -- the same ordering the actual end-of-match placement uses (see
## server_match.gd's _rank_individually/_rank_by_team). Rows are built once
## here as placeholders; _render_leaderboard() repopulates them and resizes
## the panel to fit however many rows there actually are -- a small lobby
## (e.g. a 1v1) previously still got a tall fixed 420px box with most of it
## empty dead space below just 2 rows.
func _build_leaderboard() -> void:
	_leaderboard_panel = PanelContainer.new()
	_leaderboard_panel.anchor_left = 1.0
	_leaderboard_panel.anchor_right = 1.0
	_leaderboard_panel.offset_left = -240.0
	_leaderboard_panel.offset_right = -16.0
	_leaderboard_panel.offset_top = 16.0
	_leaderboard_panel.offset_bottom = 16.0 + LEADERBOARD_HEADER_HEIGHT + LEADERBOARD_PADDING
	_leaderboard_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_leaderboard_panel.add_theme_stylebox_override("panel", UIStyle.panel_box(UIStyle.COLOR_NEUTRAL))
	_ui_layer.add_child(_leaderboard_panel)
	var panel := _leaderboard_panel

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 6)
	panel.add_child(vbox)

	var title := Label.new()
	title.text = "LEAST TIME AS IT WINS"
	title.add_theme_font_size_override("font_size", 11)
	title.add_theme_color_override("font_color", Color(0.6, 0.63, 0.72))
	vbox.add_child(title)

	_leaderboard_box = VBoxContainer.new()
	_leaderboard_box.add_theme_constant_override("separation", 3)
	vbox.add_child(_leaderboard_box)

	_render_leaderboard({})

## Rebuilds the leaderboard's rows from the latest state snapshot -- only
## called when the "it" holder actually changes (see _on_match_state), not
## every tick a state update arrives, so standings hold still between tags
## instead of a number visibly ticking upward in real time.
func _render_leaderboard(states: Dictionary) -> void:
	for child in _leaderboard_box.get_children():
		_leaderboard_box.remove_child(child)
		child.queue_free()

	var entries := []
	for peer_id in roster.keys():
		var it_time: float = states.get(peer_id, {}).get("it_time", 0.0)
		entries.append({"peer_id": peer_id, "it_time": it_time})
	entries.sort_custom(func(a, b):
		if a.it_time == b.it_time:
			return a.peer_id < b.peer_id
		return a.it_time < b.it_time
	)

	# A team playlist (2v2) can have two peers "it" at once -- one per side,
	# see tag_mode.gd -- so this has to be a set to highlight both, not just
	# whichever one a single-slot check happened to find last.
	var currently_it: Array = []
	for peer_id in states.keys():
		if states[peer_id].get("is_it", false):
			currently_it.append(peer_id)

	for i in entries.size():
		var entry: Dictionary = entries[i]
		var peer_id: int = entry.peer_id
		var info: Dictionary = roster.get(peer_id, {})

		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 8)

		var rank_label := Label.new()
		rank_label.text = "#%d" % (i + 1)
		rank_label.custom_minimum_size = Vector2(24, 0)
		rank_label.add_theme_font_size_override("font_size", 13)
		row.add_child(rank_label)

		# Only for a real, resolved tier (a bot, or a lookup that failed/timed
		# out -- see server_match.gd's _fill_ranked_stats -- has no "tier" key
		# at all) -- skip the badge entirely rather than show one for
		# "Unranked", which would just be noise on every bot's row.
		if info.has("tier"):
			var badge := RankBadgeScene.new()
			badge.tier = String(info.tier)
			badge.custom_minimum_size = Vector2(14, 16)
			row.add_child(badge)

		var name_label := Label.new()
		name_label.text = "%s%s" % [info.get("username", "Player"), "  (you)" if peer_id == my_peer_id else ""]
		name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		name_label.clip_text = true
		name_label.add_theme_font_size_override("font_size", 13)
		# "Currently it"/"you" stay their own fixed colors -- real-time state
		# worth flagging at a glance -- everyone else's name is tier-colored,
		# same as the in-game nametag above their head (see remote_avatar.gd's
		# set_rank_tier).
		if peer_id in currently_it:
			name_label.add_theme_color_override("font_color", Color(1.0, 0.3, 0.3))
		elif peer_id == my_peer_id:
			name_label.add_theme_color_override("font_color", Color(0.5, 0.85, 1.0))
		else:
			name_label.add_theme_color_override("font_color", UIStyle.tier_color(info.get("tier", "")))
		row.add_child(name_label)

		var time_label := Label.new()
		time_label.text = "%.1fs" % float(entry.it_time)
		time_label.add_theme_font_size_override("font_size", 13)
		time_label.add_theme_color_override("font_color", Color(0.7, 0.72, 0.78))
		row.add_child(time_label)

		_leaderboard_box.add_child(row)

	_leaderboard_panel.offset_bottom = _leaderboard_panel.offset_top + LEADERBOARD_HEADER_HEIGHT + LEADERBOARD_PADDING + entries.size() * LEADERBOARD_ROW_HEIGHT

func _physics_process(_delta: float) -> void:
	# A spectator (my_peer_id == -1, see setup()/start_spectator()) has no
	# Player on the server to apply input to at all -- the server would just
	# no-op it (not in any _peer_lobby entry), but there's no reason to
	# spend a network message every tick doing nothing.
	if my_peer_id == -1:
		return
	# No client-side prediction/reconciliation at all -- just capture and
	# send input every tick. Every avatar (see _on_match_state), including
	# your own, only ever renders confirmed server state, dead-reckoned the
	# same way RemoteAvatar always smoothed everyone else. You feel your
	# own round-trip time as input delay instead of ever seeing a
	# correction/snap.
	var input := {
		"move_dir": Vector2(
			Input.get_action_strength("move_right") - Input.get_action_strength("move_left"),
			Input.get_action_strength("move_down") - Input.get_action_strength("move_up")
		),
		"jump_pressed": Input.is_action_just_pressed("jump"),
		"jump_held": Input.is_action_pressed("jump"),
		"dash_pressed": Input.is_action_just_pressed("dash"),
		"climb_held": Input.is_action_pressed("climb"),
	}
	NetworkManager.submit_input(input)

func _on_match_state(_tick: int, states: Dictionary) -> void:
	# time_remaining is the same for every entry (it's the round's own
	# timer, not per-player) -- read it off whichever one happens to be
	# first rather than requiring my_peer_id specifically, so this still
	# updates for a spectator (my_peer_id == -1, never a real key here).
	if not states.is_empty():
		var tr: float = float((states.values()[0] as Dictionary).get("time_remaining", 0.0))
		hud.text = "Time left: %d:%02d" % [int(tr) / 60, int(tr) % 60]

	var currently_it: Array = []
	for peer_id in states.keys():
		if not avatars.has(peer_id):
			continue
		var s: Dictionary = states[peer_id]
		avatars[peer_id].set_state(s.pos, s.vel, s.facing, s.is_dashing, s.get("is_climbing", false), s.get("on_floor", true), s.get("action", ""), s.get("action_id", 0), s.is_it)
		if s.is_it:
			currently_it.append(peer_id)

	# A team playlist (2v2) can have two peers "it" at once (one per side,
	# see tag_mode.gd) -- compare the whole set, not just one slot, so a
	# change to either still triggers a re-render. Sorted first since
	# Dictionary/states iteration order isn't guaranteed to be stable
	# between ticks.
	currently_it.sort()
	if currently_it != _last_it_peer_ids:
		_last_it_peer_ids = currently_it
		_render_leaderboard(states)

func _on_disconnected() -> void:
	# Only pause_menu.gd's own explicit "Menu" button reset this -- getting
	# here any other way (disconnect while paused) left get_tree().paused
	# stuck true for the rest of the session, silently breaking every
	# pause-sensitive thing project-wide (NetworkManager included -- see its
	# own process_mode comment).
	get_tree().paused = false
	get_tree().change_scene_to_file("res://main/main_menu.tscn")

## Fires once this round's timer runs out -- ranked and casual alike now
## (see TagMode.round_ended). Swaps straight to the results screen without
## waiting for a disconnect.
func _on_match_ended(ranking: Array) -> void:
	# Same reasoning as _on_disconnected() above -- a round can end from
	# its own timer while the pause menu happens to be open, which never
	# routed through pause_menu.gd's explicit unpause at all.
	get_tree().paused = false
	var scene := MATCH_RESULTS_SCENE.instantiate()
	scene.setup(ranking, my_peer_id)
	get_tree().root.add_child(scene)
	get_tree().current_scene.queue_free()
	get_tree().current_scene = scene
