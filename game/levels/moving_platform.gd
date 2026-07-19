extends AnimatableBody2D
class_name MovingPlatform

# Deterministic ping-pong motion between two tile-grid points -- both the
# dedicated server (authoritative collision, server_match.gd) and every
# client (rendering only, net_game.gd) instantiate this exact same scene
# from the exact same level data (see level_data.gd's "platforms" array)
# and let it free-run locally from the moment it enters the tree. No
# position is ever sent over the network for this: there's nothing to
# desync, since both sides evaluate the same formula against elapsed
# physics time since their own copy spawned, not a value either side could
# disagree about. A real player standing on this rides along for free --
# AnimatableBody2D is Godot's purpose-built "moving platform" body, and
# CharacterBody2D.move_and_slide() (already how Player moves) already knows
# how to carry a rider standing on one, with zero extra code on the
# player's side.

const TILE_SIZE := 10.0
# A few tiles wide so there's a real surface to stand on, not a knife-edge --
# fixed rather than per-instance configurable, keeping the level-data schema
# to exactly {start, end, period_sec} as specified.
const PLATFORM_SIZE := Vector2(30, 10)

@export var start_cell := Vector2i.ZERO
@export var end_cell := Vector2i.ZERO
@export var period_sec := 4.0

var _start_pos: Vector2
var _end_pos: Vector2
var _start_frame := 0

func _ready() -> void:
	_start_pos = Vector2(start_cell) * TILE_SIZE
	_end_pos = Vector2(end_cell) * TILE_SIZE
	_start_frame = Engine.get_physics_frames()
	global_position = _start_pos

func _physics_process(_delta: float) -> void:
	if period_sec <= 0.0 or _start_pos == _end_pos:
		return
	var elapsed := float(Engine.get_physics_frames() - _start_frame) / 60.0
	var phase := fmod(elapsed, period_sec) / period_sec # 0..1 over one period
	# Triangle wave (0 -> 1 -> 0 across one period) -- a smooth reversal at
	# both endpoints rather than a snap-back sawtooth would give.
	var t := 1.0 - absf(phase * 2.0 - 1.0)
	global_position = _start_pos.lerp(_end_pos, t)
