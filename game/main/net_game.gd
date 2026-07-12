extends Node2D

const PLAYER_SCENE := preload("res://player/player.tscn")
const REMOTE_AVATAR_SCENE := preload("res://player/remote_avatar.tscn")
const ARENA_SCENE := preload("res://levels/tag_arena.tscn")

# Every locally-predicted input is kept here (tagged with its own tick) until
# the server confirms it's been processed. On every correction we don't just
# snap to the server's position -- that's what read as being "shot back"
# under real latency, since the snapshot the server just sent is already
# several ticks stale by the time it arrives. Instead we jump to the
# server's authoritative state for that tick and then immediately replay
# every input newer than it, so the visible result is (unless the server
# genuinely diverged, e.g. a real desync) exactly where prediction already
# had us -- the correction resolves invisibly instead of rubber-banding.
const MAX_INPUT_HISTORY := 180 # 3s at 60fps -- generous headroom over any realistic RTT

var arena: Node2D
var local_player: Player
var remote_avatars := {} # peer_id -> RemoteAvatar
var my_peer_id := -1
var roster := {}
var hud: Label

var _local_tick := 0
var _input_history: Array[Dictionary] = [] # [{tick, input, delta}], oldest first

func setup(p_my_peer_id: int, p_roster: Dictionary) -> void:
	my_peer_id = p_my_peer_id
	roster = p_roster

func _ready() -> void:
	arena = ARENA_SCENE.instantiate()
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

	NetworkManager.match_state_received.connect(_on_match_state)
	NetworkManager.disconnected_from_server.connect(_on_disconnected)

	local_player = PLAYER_SCENE.instantiate()
	add_child(local_player)
	local_player.get_node("Camera2D").enabled = true
	local_player.get_node("Camera2D").make_current()

	for peer_id in roster.keys():
		if peer_id == my_peer_id:
			continue
		var avatar: RemoteAvatar = REMOTE_AVATAR_SCENE.instantiate()
		add_child(avatar)
		avatar.display_name = roster[peer_id]
		remote_avatars[peer_id] = avatar

func _physics_process(delta: float) -> void:
	if not local_player:
		return
	_local_tick += 1
	var input := {
		"tick": _local_tick,
		"move_dir": Vector2(
			Input.get_action_strength("move_right") - Input.get_action_strength("move_left"),
			Input.get_action_strength("move_down") - Input.get_action_strength("move_up")
		),
		"jump_pressed": Input.is_action_just_pressed("jump"),
		"jump_held": Input.is_action_pressed("jump"),
		"dash_pressed": Input.is_action_just_pressed("dash"),
		"climb_held": Input.is_action_pressed("climb"),
	}
	# Client-side prediction: apply input locally immediately using the same
	# movement script the server runs, so local input feels instant instead
	# of waiting on a round trip. The server's periodic snapshot in
	# _on_match_state corrects any drift via replay, not this call directly.
	local_player.apply_input(input, delta)
	NetworkManager.submit_input(input)

	_input_history.append({"tick": _local_tick, "input": input, "delta": delta})
	if _input_history.size() > MAX_INPUT_HISTORY:
		_input_history.pop_front()

func _on_match_state(_tick: int, states: Dictionary) -> void:
	if not states.has(my_peer_id):
		return
	var my_state: Dictionary = states[my_peer_id]
	var acked_tick: int = int(my_state.get("input_tick", 0))
	var pre_snap_pos := local_player.global_position

	# Jump to the server's authoritative state for the tick it just
	# acknowledged -- the FULL internal state (timers, dash/jump
	# availability, etc.), not just position/velocity, or replaying a
	# buffered edge-triggered input like a jump press below could re-trigger
	# it instead of correctly continuing past it (see
	# Player.restore_state_snapshot()) -- then replay (apply_input only --
	# NOT submit_input, that would re-send everything we're just replaying
	# locally) every input already predicted since. move_and_slide()
	# displaces by get_physics_process_delta_time(), not the delta passed
	# here, so this is only exactly correct because physics_ticks_per_second
	# is fixed at 60 project-wide (project.godot) and nothing scales it at
	# runtime -- each replayed entry's recorded delta always matches the
	# engine's actual physics delta. If that ever changes, this replay needs
	# revisiting.
	local_player.restore_state_snapshot(my_state)

	while not _input_history.is_empty() and _input_history[0].tick <= acked_tick:
		_input_history.pop_front()
	for entry in _input_history:
		local_player.apply_input(entry.input, entry.delta)

	# Only break interpolation when the resync actually moved us somewhere
	# meaningfully different from where prediction already had us -- doing
	# this unconditionally at up to 60hz would fight physics_interpolation
	# (on project-wide) and read as constant micro-jitter instead of smooth
	# motion for the common, in-sync case.
	if pre_snap_pos.distance_to(local_player.global_position) > 0.5:
		local_player.reset_physics_interpolation()

	hud.text = "IT: %s" % ("you" if my_state.is_it else "someone else")

	for peer_id in states.keys():
		if peer_id == my_peer_id or not remote_avatars.has(peer_id):
			continue
		var s: Dictionary = states[peer_id]
		remote_avatars[peer_id].set_state(s.pos, s.vel, s.facing, s.is_dashing, s.is_it)

func _on_disconnected() -> void:
	get_tree().change_scene_to_file("res://main/main_menu.tscn")
