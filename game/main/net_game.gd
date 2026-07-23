extends Node2D

const REMOTE_AVATAR_SCENE := preload("res://player/remote_avatar.tscn")
const MATCH_RESULTS_SCENE := preload("res://main/match_results.tscn")
const OnlineMapCatalog := preload("res://levels/online_maps/catalog.gd")
const UIStyle := preload("res://ui/ui_style.gd")

var arena: Node2D
var avatars := {} # peer_id -> RemoteAvatar, including your own
var my_peer_id := -1
var roster := {} # peer_id -> {username, color_id}
var level_id := ""
var hud: Label
var _leaderboard_box: VBoxContainer
# 0 is never a real peer_id (server is 1, real clients unique positive,
# bots negative synthetic ids -- see server_match.gd) or a bot id, so it's
# safe as an "nothing rendered yet" sentinel distinct from every possible
# real "who's it" value, including a bot being it.
var _last_it_peer_id := 0

func setup(p_my_peer_id: int, p_roster: Dictionary, p_level_id: String = "") -> void:
	my_peer_id = p_my_peer_id
	roster = p_roster
	level_id = p_level_id

func _ready() -> void:
	# Resolved purely locally, from the same built-in catalog server_match.gd
	# uses -- see that file's identical resolution for why there's no
	# network fetch here anymore either.
	arena = load(OnlineMapCatalog.scene_path_for(level_id)).instantiate()
	add_child(arena)

	hud = Label.new()
	hud.offset_left = 16.0
	hud.offset_top = 16.0
	hud.offset_right = 400.0
	hud.offset_bottom = 60.0
	hud.add_theme_color_override("font_color", Color.WHITE)
	hud.add_theme_font_size_override("font_size", 20)
	hud.text = "Connecting..."
	add_child(hud)

	_build_leaderboard()

	NetworkManager.match_state_received.connect(_on_match_state)
	NetworkManager.disconnected_from_server.connect(_on_disconnected)
	NetworkManager.match_ended.connect(_on_match_ended)

	# Every player, yours included, is a RemoteAvatar -- there's no local
	# prediction anywhere anymore, so no reason for your own avatar to be
	# built any differently from everyone else's. Only difference is which
	# one owns the active camera.
	for peer_id in roster.keys():
		var info: Dictionary = roster[peer_id]
		var avatar: RemoteAvatar = REMOTE_AVATAR_SCENE.instantiate()
		avatar.is_local = (peer_id == my_peer_id)
		add_child(avatar)
		avatar.display_name = info.username
		avatars[peer_id] = avatar
		_apply_color(peer_id)

	# my_peer_id == -1 means we're spectating (see NetworkManager.start_
	# spectator) -- there's no local avatar to own the camera, so fall back
	# to following whichever roster entry came first instead of leaving no
	# camera active at all.
	if my_peer_id == -1 and not avatars.is_empty():
		var followed: RemoteAvatar = avatars[avatars.keys()[0]]
		followed.camera.enabled = true
		followed.camera.make_current()
		hud.text = "Spectating"

func _apply_color(peer_id: int) -> void:
	if not avatars.has(peer_id) or not roster.has(peer_id):
		return
	var color_id: String = roster[peer_id].get("color_id", PlayerColors.DEFAULT_ID)
	avatars[peer_id].set_color(color_id)

## A fixed-size side panel (no scrolling -- 420px comfortably fits a private
## match's max 16 participants) ranking everyone by time spent as "it" so
## far, least first -- the same ordering the actual end-of-match placement
## uses (see server_match.gd's _rank_individually/_rank_by_team). Rows are
## built once here as placeholders; _render_leaderboard() repopulates them.
func _build_leaderboard() -> void:
	var panel := PanelContainer.new()
	panel.anchor_left = 1.0
	panel.anchor_right = 1.0
	panel.offset_left = -240.0
	panel.offset_right = -16.0
	panel.offset_top = 16.0
	panel.offset_bottom = 420.0
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_theme_stylebox_override("panel", UIStyle.panel_box(UIStyle.COLOR_NEUTRAL))
	add_child(panel)

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

	var currently_it := 0
	for peer_id in states.keys():
		if states[peer_id].get("is_it", false):
			currently_it = peer_id
			break

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

		var name_label := Label.new()
		name_label.text = "%s%s" % [info.get("username", "Player"), "  (you)" if peer_id == my_peer_id else ""]
		name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		name_label.clip_text = true
		name_label.add_theme_font_size_override("font_size", 13)
		if peer_id == currently_it:
			name_label.add_theme_color_override("font_color", Color(1.0, 0.3, 0.3))
		elif peer_id == my_peer_id:
			name_label.add_theme_color_override("font_color", Color(0.5, 0.85, 1.0))
		row.add_child(name_label)

		var time_label := Label.new()
		time_label.text = "%.1fs" % float(entry.it_time)
		time_label.add_theme_font_size_override("font_size", 13)
		time_label.add_theme_color_override("font_color", Color(0.7, 0.72, 0.78))
		row.add_child(time_label)

		_leaderboard_box.add_child(row)

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
	if states.has(my_peer_id):
		hud.text = "IT: %s" % ("you" if states[my_peer_id].is_it else "someone else")

	var currently_it := 0
	for peer_id in states.keys():
		if not avatars.has(peer_id):
			continue
		var s: Dictionary = states[peer_id]
		avatars[peer_id].set_state(s.pos, s.vel, s.facing, s.is_dashing, s.get("is_climbing", false), s.get("on_floor", true), s.get("action", ""), s.get("action_id", 0), s.is_it)
		if s.is_it:
			currently_it = peer_id

	if currently_it != _last_it_peer_id:
		_last_it_peer_id = currently_it
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
