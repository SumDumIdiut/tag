extends RefCounted
class_name ClientPlayerController

# Drives the LOCAL player on the client: applies input immediately
# (prediction) and reconciles against the server's authoritative snapshots.

const HISTORY_LIMIT := 240 # ~4s at 60Hz
const RECONCILE_TOLERANCE := 2.0 # px; below this we consider client/server agreed

var player: Player
var next_seq: int = 0
var bot_mode := false
var _history: Array[Dictionary] = [] # {seq, input, state_after}
var _bot_time := 0.0

# Input is sent over an unreliable channel (net/network_manager.gd), so a
# single-tick edge-triggered flag like "jump was just pressed" can simply
# vanish if that one packet drops -- the server would never see the jump at
# all, then yank the client's locally-predicted jump back on the next
# snapshot. Keeping jump/dash "pressed" true for a few consecutive outgoing
# packets gives the server several chances to see it; once one of them
# lands the resulting jump/dash is idempotent (re-triggering while already
# jumping/dashing is a no-op), so this is safe.
const INPUT_STICKY_TICKS := 4
var _jump_sticky_ticks := 0
var _dash_sticky_ticks := 0

func _init(p_player: Player, p_bot_mode: bool = false) -> void:
	player = p_player
	bot_mode = p_bot_mode

func read_local_input() -> Dictionary:
	if bot_mode:
		return _bot_input()
	if Input.is_action_just_pressed("jump"):
		_jump_sticky_ticks = INPUT_STICKY_TICKS
	if Input.is_action_just_pressed("dash"):
		_dash_sticky_ticks = INPUT_STICKY_TICKS
	var jump_pressed := _jump_sticky_ticks > 0
	var dash_pressed := _dash_sticky_ticks > 0
	_jump_sticky_ticks = maxi(_jump_sticky_ticks - 1, 0)
	_dash_sticky_ticks = maxi(_dash_sticky_ticks - 1, 0)
	return {
		"move_dir": Vector2(
			Input.get_action_strength("move_right") - Input.get_action_strength("move_left"),
			Input.get_action_strength("move_down") - Input.get_action_strength("move_up")
		),
		"jump_pressed": jump_pressed,
		"jump_released": Input.is_action_just_released("jump"),
		"dash_pressed": dash_pressed,
		"climb_held": Input.is_action_pressed("climb"),
	}

# Scripted movement loop (walk, jump, dash, turn around) so a headless
# instance is visibly doing something instead of standing idle -- useful for
# eyeballing that networked movement/animation actually renders correctly.
func _bot_input() -> Dictionary:
	var t := fmod(_bot_time, 6.0)
	var moving_right := t < 3.0
	var leg_t := t if moving_right else t - 3.0
	return {
		"move_dir": Vector2(1.0 if moving_right else -1.0, 0.0),
		"jump_pressed": leg_t < 0.05 or (leg_t > 1.4 and leg_t < 1.45),
		"jump_released": false,
		"dash_pressed": leg_t > 0.7 and leg_t < 0.75,
	}

func tick(delta: float) -> void:
	if bot_mode:
		_bot_time += delta
	var input := read_local_input()
	var seq := next_seq
	next_seq += 1
	player.apply_input(input, delta)
	_history.append({"seq": seq, "input": input, "state_after": player.get_state()})
	if _history.size() > HISTORY_LIMIT:
		_history.pop_front()
	NetworkManager.send_input(seq, input)

func reconcile(server_state: Dictionary) -> void:
	# is_it is authoritative-only (never predicted locally) so it's applied
	# unconditionally here, independent of the position-mismatch check below.
	player.set_it(server_state.get("is_it", player.is_it))

	var server_seq: int = server_state.get("seq", -1)
	if server_seq < 0:
		return
	var index := -1
	for i in _history.size():
		if _history[i].seq == server_seq:
			index = i
			break
	if index == -1:
		return # already trimmed / too old to reconcile against

	var predicted_pos: Vector2 = _history[index].state_after.position
	var server_pos: Vector2 = server_state.position
	if predicted_pos.distance_to(server_pos) <= RECONCILE_TOLERANCE:
		_history = _history.slice(index + 1)
		return

	# Misprediction: snap to authoritative state and replay every input since.
	# The server snapshot only carries position/velocity/facing/dash -- the
	# finer movement timers (coyote/jump-buffer/dash_direction/etc) are left
	# out of this dict on purpose, and player.set_state() correspondingly
	# keeps whatever the client already had for any field not present here
	# rather than resetting it. Those fields are input-derived and already
	# correct locally; only position/velocity actually need correcting from
	# the server since those are physics/collision-derived and can diverge.
	player.set_state({
		"position": server_pos,
		"velocity": server_state.velocity,
		"facing": server_state.facing,
		"is_dashing": server_state.is_dashing,
	})
	# This is a deliberate mid-tick jump, not continuous motion -- without this
	# Godot's physics interpolation would visibly slide the sprite across the
	# correction instead of snapping.
	player.reset_physics_interpolation()
	var replay: Array = _history.slice(index + 1)
	var fixed_delta := 1.0 / Engine.physics_ticks_per_second
	for entry in replay:
		player.apply_input(entry.input, fixed_delta)
		entry.state_after = player.get_state()
	_history = replay
