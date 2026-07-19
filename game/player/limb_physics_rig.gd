extends RefCounted
class_name LimbPhysicsRig

# Whole-body version of what used to be a 6-pendulum limb rig, stripped down
# after the player model became a single square (see SkinCatalog.PART_NAMES)
# -- there's only one sprite left to pose, so the per-limb pendulums (torso/
# head/arms/legs, each with their own gait/dash/air/climb drive) collapsed
# into one body-wide rotation pendulum plus the vertical bob spring and
# whole-body wind lean, which already applied to the visual root rather than
# any one limb. Same driven-damped-harmonic-oscillator math as before (see
# Pendulum/Spring below) -- just one pendulum doing the job six used to.

const REST_BODY_Y := -15.0
const GRAVITY := 2600.0

class Pendulum:
	var angle := 0.0
	var _vel := 0.0
	var inertia: float
	var damping: float
	var rest_angle := 0.0
	var max_angle := 80.0

	func _init(p_inertia: float, p_damping: float, p_max_angle: float = 80.0) -> void:
		inertia = p_inertia
		damping = p_damping
		max_angle = p_max_angle

	func update(drive_torque: float, delta: float) -> void:
		var gravity_torque := -GRAVITY * sin(deg_to_rad(angle - rest_angle))
		var damping_torque := -damping * _vel
		var angular_accel := (gravity_torque + drive_torque + damping_torque) / inertia
		_vel += angular_accel * delta
		angle += _vel * delta
		var lo := rest_angle - max_angle
		var hi := rest_angle + max_angle
		if angle < lo:
			angle = lo
			_vel = maxf(_vel, 0.0)
		elif angle > hi:
			angle = hi
			_vel = minf(_vel, 0.0)

	## A one-shot shove -- adds directly to angular velocity rather than
	## angle, so it reads as an impact (swing hard, then settle back) instead
	## of a teleport to a new pose.
	func kick(impulse: float) -> void:
		_vel += impulse / inertia

	static func equilibrium_torque(target_angle_deg: float) -> float:
		return GRAVITY * sin(deg_to_rad(target_angle_deg))

	func forced_drive_for_amplitude(amplitude_deg: float, w: float) -> float:
		var stiffness := GRAVITY * (PI / 180.0)
		var reactance := stiffness - inertia * w * w
		var resistance := damping * w
		return amplitude_deg * sqrt(reactance * reactance + resistance * resistance)

# Position bob (a vertical stride bounce) is a translation, not a rotation --
# a plain damped spring toward a target position is the right tool there,
# not a pendulum.
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

var body_rot := Pendulum.new(2.2, 13.0, 34.0)
var body_y := Spring.new(140.0, 16.0, REST_BODY_Y)

# Whole-body tilt from air drag -- rotates the entire visual root rather
# than body_rot itself, since body_rot pivots around the square's own top
# attach point while this effect (moving fast pushes the whole silhouette
# back) should pivot around the character's actual center. A plain spring
# chasing a speed-derived target angle reads as "leaning into the wind"
# without needing its own gravity term -- there's no rest pose for the whole
# body to sag back to except upright.
var body_lean := Spring.new(70.0, 15.0, 0.0)

# Real walking distance (not time) covered since the last full stride -- see
# the walk branch below. Stride frequency is an emergent result of speed
# (a real walker's cadence scales with speed because stride length is
# roughly constant), not a wave generator sped up with time.
const STEP_LENGTH := 55.0
const CLIMB_ANGULAR_FREQ := 5.0 # rad/s -- climbing cadence is roughly constant regardless of input, unlike walking's speed-derived one
var _stride_distance := 0.0
var _climb_phase := 0.0
var _last_vel := Vector2.ZERO

# How hard the character's own acceleration (speeding up, stopping,
# landing) shoves the body backward relative to the motion -- inertia, the
# same reason a passenger leans back when a car suddenly accelerates.
const LEAN_RESPONSE := 0.16
const MAX_LEAN_TORQUE := 260.0

const WIND_LEAN_PER_SPEED := 0.032
const MAX_WIND_LEAN_DEG := 26.0

## Advances the pendulum/springs one step from real dynamics driven by the
## given state. `vel`/`on_floor`/`is_dashing`/`is_climbing`/`move_speed` are
## the same values player.gd/remote_avatar.gd already have on hand each
## frame, whether from local physics or the last network update.
func update(delta: float, vel: Vector2, on_floor: bool, is_dashing: bool, is_climbing: bool, move_speed: float) -> void:
	var accel := (vel - _last_vel) / maxf(delta, 0.0001)
	_last_vel = vel
	var lean := clampf(-accel.x * LEAN_RESPONSE, -MAX_LEAN_TORQUE, MAX_LEAN_TORQUE)

	var body_drive := lean
	var body_y_target := REST_BODY_Y

	if is_dashing:
		body_drive += Pendulum.equilibrium_torque(-16.0)
	elif is_climbing:
		_climb_phase += delta * CLIMB_ANGULAR_FREQ
		var s := sin(_climb_phase)
		var torque := body_rot.forced_drive_for_amplitude(9.0, CLIMB_ANGULAR_FREQ)
		body_drive += s * torque
	elif not on_floor:
		var up := clampf(-vel.y / 400.0, -1.0, 1.0) # positive while rising, negative while falling
		body_drive += Pendulum.equilibrium_torque(-14.0 * up)
	else:
		var speed_frac := absf(vel.x) / maxf(move_speed, 1.0)
		if speed_frac > 0.06:
			_stride_distance += absf(vel.x) * delta
			var phase := (_stride_distance / STEP_LENGTH) * TAU
			body_drive += Pendulum.equilibrium_torque(sin(phase) * 4.0)
			body_y_target = REST_BODY_Y - 2.0 * absf(cos(phase))

	body_rot.update(body_drive, delta)
	body_y.update(body_y_target, delta)

	var wind_lean_target := clampf(-vel.x * WIND_LEAN_PER_SPEED, -MAX_WIND_LEAN_DEG, MAX_WIND_LEAN_DEG)
	body_lean.update(wind_lean_target, delta)

## A one-shot impulse for a discrete event (a wall jump, a dash-jump cancel,
## getting tagged, getting repelled) -- kicks the body pendulum so it swings
## hard and settles back on its own, on top of whatever the continuous
## per-frame drive above is already doing. Magnitudes match what each
## event's old torso_rot kick used to be, since that's the one pendulum
## every event already drove regardless of the rest of the old per-limb
## kicks.
func kick(action: String) -> void:
	match action:
		"wall_jump": body_rot.kick(-260.0)
		"super_wall_jump": body_rot.kick(-360.0)
		"diagonal_wall_jump": body_rot.kick(320.0)
		"dash_jump": body_rot.kick(-320.0)
		"tag_reaction": body_rot.kick(-380.0)
		"repel": body_rot.kick(-320.0)

## Writes the current pendulum/spring values onto the actual rig nodes.
## `body` is the Body Sprite2D (player.tscn et al); `visual_root` (the
## Visual node itself, optional) carries the whole-body wind lean -- kept
## separate from body's own rotation since that pivots around the square's
## top attach point, not the character's overall center, so leaning it
## directly would swing the attach point out rather than tilting the whole
## silhouette.
func apply_to(body: Node2D, visual_root: Node2D = null) -> void:
	body.position = Vector2(0.0, body_y.value)
	body.rotation_degrees = body_rot.angle
	if visual_root:
		visual_root.rotation_degrees = body_lean.value
