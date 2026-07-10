extends RefCounted
class_name RemotePlayerController

# Drives a REMOTE player on the client: no prediction, just interpolates
# between the last couple of received snapshots to smooth over network
# jitter and the gaps between snapshot arrivals.

const INTERP_DELAY := 0.1 # seconds "behind now" remote players render at
const MAX_BUFFER := 32

var player: Player
var _buffer: Array[Dictionary] = [] # {time, position, facing, is_dashing, is_it}

func _init(p_player: Player) -> void:
	player = p_player

func push_snapshot(state: Dictionary) -> void:
	_buffer.append({
		"time": Time.get_ticks_msec() / 1000.0,
		"position": state.position,
		"facing": state.facing,
		"is_dashing": state.is_dashing,
		"is_it": state.is_it,
	})
	while _buffer.size() > MAX_BUFFER:
		_buffer.pop_front()

func update(_delta: float) -> void:
	if _buffer.is_empty():
		return
	if _buffer.size() == 1:
		_apply(_buffer[0])
		return

	var render_time := Time.get_ticks_msec() / 1000.0 - INTERP_DELAY
	for i in range(_buffer.size() - 1):
		var a: Dictionary = _buffer[i]
		var b: Dictionary = _buffer[i + 1]
		if a.time <= render_time and render_time <= b.time:
			var span: float = maxf(b.time - a.time, 0.0001)
			var t: float = clampf((render_time - a.time) / span, 0.0, 1.0)
			player.position = a.position.lerp(b.position, t)
			player.facing = b.facing
			player.is_dashing = b.is_dashing
			player.set_it(b.is_it)
			return

	# render_time falls outside the buffered range -- snap to the newest
	# known snapshot rather than extrapolating blindly.
	_apply(_buffer.back())

func _apply(snap: Dictionary) -> void:
	player.position = snap.position
	player.facing = snap.facing
	player.is_dashing = snap.is_dashing
	player.set_it(snap.is_it)
	# Both callers of _apply() are discontinuous jumps (first snapshot ever,
	# or a buffer gap) rather than smooth interpolated motion -- avoid a
	# visible slide across them.
	player.reset_physics_interpolation()
