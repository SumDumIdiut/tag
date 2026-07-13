extends RefCounted
class_name LimbPhysicsRig

# Spring-damper secondary motion instead of baked keyframe animation. Every
# limb's rotation (and the torso's own rotation/bob) is the live result of a
# damped spring chasing a target computed fresh each frame from actual
# velocity/state -- a sudden change (a jump, a wall-jump kick, landing)
# makes it swing and overshoot before settling, instead of snapping through
# a fixed timeline. This only ever writes rotation/position on the existing
# rig nodes -- limbs stay exactly as rigidly parented to the torso as
# before (same Sprite2D hierarchy player.tscn always had), so nothing can
# detach or fly off. It's reactive posing driven by physics, not a ragdoll.

const REST_TORSO_Y := -15.0

class Spring:
	var value := 0.0
	var _vel := 0.0
	var stiffness: float
	var damping: float

	func _init(p_stiffness: float, p_damping: float, start := 0.0) -> void:
		stiffness = p_stiffness
		damping = p_damping
		value = start

	func update(target: float, delta: float) -> void:
		var accel := -stiffness * (value - target) - damping * _vel
		_vel += accel * delta
		value += _vel * delta

	## A one-shot shove -- adds directly to the spring's velocity rather than
	## its value, so it reads as an impact (swing hard, then settle back)
	## instead of a teleport to a new pose.
	func kick(impulse: float) -> void:
		_vel += impulse

# Arms/head are lighter and bouncier (lower stiffness, less damping) than
# legs, which stay comparatively controlled since they're what reads as
# "planted" when grounded -- floppy legs would look broken, floppy arms
# just look alive.
var torso_rot := Spring.new(220.0, 16.0)
var torso_y := Spring.new(140.0, 16.0, REST_TORSO_Y)
var head_rot := Spring.new(170.0, 13.0)
var left_arm := Spring.new(190.0, 12.0)
var right_arm := Spring.new(190.0, 12.0)
var left_leg := Spring.new(260.0, 19.0)
var right_leg := Spring.new(260.0, 19.0)

var _stride_phase := 0.0
var _climb_phase := 0.0

var _torso_rot_target := 0.0
var _torso_y_target := REST_TORSO_Y
var _head_target := 0.0
var _left_arm_target := 0.0
var _right_arm_target := 0.0
var _left_leg_target := 0.0
var _right_leg_target := 0.0

## Advances every spring one step toward targets computed from the given
## state. `vel`/`on_floor`/`is_dashing`/`is_climbing`/`move_speed` are the
## same values player.gd/remote_avatar.gd already have on hand each frame,
## whether from local physics or the last network update.
func update(delta: float, vel: Vector2, on_floor: bool, is_dashing: bool, is_climbing: bool, move_speed: float) -> void:
	var speed_frac := clampf(absf(vel.x) / maxf(move_speed, 1.0), 0.0, 1.6)

	if is_dashing:
		_update_dash()
	elif is_climbing:
		_update_climb(delta)
	elif not on_floor:
		_update_air(vel)
	elif speed_frac > 0.06:
		_update_walk(speed_frac, delta)
	else:
		_update_idle()

	torso_rot.update(_torso_rot_target, delta)
	torso_y.update(_torso_y_target, delta)
	head_rot.update(_head_target, delta)
	left_arm.update(_left_arm_target, delta)
	right_arm.update(_right_arm_target, delta)
	left_leg.update(_left_leg_target, delta)
	right_leg.update(_right_leg_target, delta)

func _update_idle() -> void:
	_torso_rot_target = 0.0
	_torso_y_target = REST_TORSO_Y
	_head_target = 0.0
	_left_arm_target = 0.0
	_right_arm_target = 0.0
	_left_leg_target = 0.0
	_right_leg_target = 0.0

func _update_walk(speed_frac: float, delta: float) -> void:
	# Phase accumulates over real time at a rate tied to actual speed (not a
	# fixed loop length), so the stride frequency continuously tracks
	# whatever speed_frac actually is instead of only ever matching one
	# baked cadence.
	_stride_phase += delta * (6.0 + speed_frac * 6.0)
	var s := sin(_stride_phase)
	_left_leg_target = s * 42.0
	_right_leg_target = -s * 42.0
	_left_arm_target = -s * 32.0
	_right_arm_target = s * 32.0
	_torso_rot_target = s * 4.0
	_torso_y_target = REST_TORSO_Y - 2.0 * absf(cos(_stride_phase))
	_head_target = s * 2.0

func _update_air(vel: Vector2) -> void:
	var up := clampf(-vel.y / 400.0, -1.0, 1.0) # positive while rising, negative while falling
	_torso_rot_target = -up * 14.0
	_head_target = -up * 8.0
	_left_arm_target = -up * 48.0
	_right_arm_target = up * 48.0
	_left_leg_target = up * 32.0
	_right_leg_target = -up * 32.0
	_torso_y_target = REST_TORSO_Y

func _update_dash() -> void:
	_torso_rot_target = -16.0
	_head_target = 0.0
	_left_arm_target = -48.0
	_right_arm_target = 48.0
	_left_leg_target = 16.0
	_right_leg_target = -16.0
	_torso_y_target = REST_TORSO_Y

func _update_climb(delta: float) -> void:
	_climb_phase += delta * 5.0
	var s := sin(_climb_phase)
	_torso_rot_target = 0.0
	_head_target = 0.0
	_left_arm_target = s * 45.0
	_right_arm_target = -s * 45.0
	_left_leg_target = -s * 15.0
	_right_leg_target = s * 15.0
	_torso_y_target = REST_TORSO_Y

## A one-shot impulse for a discrete event (a wall jump, a dash-jump cancel,
## getting tagged) -- shoves the relevant springs so they swing hard and
## settle back on their own, instead of switching to a separate
## pre-authored clip the way this whole system replaces.
func kick(action: String) -> void:
	match action:
		"wall_jump":
			left_arm.kick(-900.0)
			right_arm.kick(900.0)
			left_leg.kick(700.0)
			right_leg.kick(-700.0)
			torso_rot.kick(-260.0)
			head_rot.kick(-180.0)
		"super_wall_jump":
			left_arm.kick(-1100.0)
			right_arm.kick(1100.0)
			left_leg.kick(850.0)
			right_leg.kick(-850.0)
			torso_rot.kick(-360.0)
			head_rot.kick(-240.0)
		"diagonal_wall_jump":
			left_arm.kick(900.0)
			right_arm.kick(-900.0)
			left_leg.kick(-650.0)
			right_leg.kick(650.0)
			torso_rot.kick(320.0)
			head_rot.kick(220.0)
		"dash_jump":
			left_arm.kick(-950.0)
			right_arm.kick(950.0)
			left_leg.kick(750.0)
			right_leg.kick(-750.0)
			torso_rot.kick(-320.0)
			head_rot.kick(-160.0)
		"tag_reaction":
			torso_rot.kick(-380.0)
			head_rot.kick(-420.0)

## Writes the current spring values onto the actual rig nodes. `parts` is
## the same {part_name -> Sprite2D} dict player.gd/remote_avatar.gd already
## build for set_skin(); `torso` is parts["torso"], passed separately since
## it's the one node this touches position on, not just rotation.
func apply_to(parts: Dictionary, torso: Node2D) -> void:
	torso.position = Vector2(0.0, torso_y.value)
	torso.rotation_degrees = torso_rot.value
	if parts.has("head"):
		parts["head"].rotation_degrees = head_rot.value
	if parts.has("left_arm"):
		parts["left_arm"].rotation_degrees = left_arm.value
	if parts.has("right_arm"):
		parts["right_arm"].rotation_degrees = right_arm.value
	if parts.has("left_leg"):
		parts["left_leg"].rotation_degrees = left_leg.value
	if parts.has("right_leg"):
		parts["right_leg"].rotation_degrees = right_leg.value
