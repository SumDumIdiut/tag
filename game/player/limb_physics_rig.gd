extends RefCounted
class_name LimbPhysicsRig

# Every limb (and the torso's own rotation) is a torque-driven pendulum, not
# a spring chasing a scripted target angle. Gravity constantly pulls each
# one back toward hanging at rest; a "drive" torque -- the walking gait,
# air-tuck, dash lean, climb reach, a one-shot kick -- pushes against that,
# and the resulting angle is the outcome of actually integrating those
# forces (torque -> angular acceleration -> angular velocity -> angle)
# every frame, the same equation that governs a real hanging weight. The
# walking gait itself is driven by distance actually traveled, not elapsed
# time, so stride frequency is an emergent result of speed (a real walker's
# cadence scales with speed because stride length is roughly constant, not
# because a wave generator sped up), and every state also feels the
# character's own acceleration as an inertial lean, the same way a
# passenger leans back when a vehicle suddenly speeds up. Limbs stay
# rigidly parented to the torso the whole time (same Sprite2D hierarchy
# player.tscn always had) -- this only ever changes rotation/position,
# never detaches anything, so it's physically-driven posing, not a ragdoll.
#
# Poses are still authored as target angles (e.g. "arms back 48 degrees on
# a dash") the same as the old spring system, but every one of them gets
# converted into the actual torque that would hold a damped pendulum there,
# via the standard driven-harmonic-oscillator equations, instead of being
# assigned to the angle directly:
#  - A held pose (dash, air-tuck, lean) uses the pure gravity-equilibrium
#    torque for that angle: GRAVITY*sin(target).
#  - An oscillating pose (walk, climb) uses the full forced-response
#    formula, amplitude = F0/sqrt((k-mw^2)^2+(cw)^2), inverted to solve for
#    the drive amplitude F0 that produces the desired swing at that
#    pendulum's own inertia/damping and the gait's actual angular
#    frequency -- without this, a fast stride (high w) driven by a fixed
#    torque amplitude gets massively attenuated by its own inertia and
#    barely moves, which is exactly what a first pass at this looked like.

const REST_TORSO_Y := -15.0
# Shared "weight" every pendulum feels, pulling it back toward its rest
# angle -- tuned in the same made-up torque units as the drive constants
# below, not real-world degrees/second^2, since nothing here is simulating
# actual physical units, just tuned for how it reads. Also doubles as the
# linearized restoring "stiffness" (GRAVITY * pi/180 per degree) the
# forced-oscillator formula below solves against.
const GRAVITY := 2600.0

class Pendulum:
	var angle := 0.0
	var _vel := 0.0
	var inertia: float
	var damping: float
	var rest_angle := 0.0
	# A hard joint-limit safety net -- a driven oscillator's transient
	# response (before it settles into true steady-state swinging) can
	# overshoot well past the eventual steady amplitude, and no amount of
	# tuning fully eliminates that for every possible speed/state
	# transition. Clamping here is also just physically honest: a real
	# limb has a real range of motion too, not just gravity/damping.
	var max_angle := 80.0

	func _init(p_inertia: float, p_damping: float, p_max_angle: float = 80.0) -> void:
		inertia = p_inertia
		damping = p_damping
		max_angle = p_max_angle

	## drive_torque is the sum of every external push this frame (gait,
	## air-tuck, dash lean, inertial sway, ...); gravity's own restoring
	## pull and joint damping are added internally so every caller gets
	## them for free.
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

	## The constant torque that exactly balances gravity's own pull at
	## target_angle_deg -- i.e. where this pendulum would sit in still
	## equilibrium if that torque were held forever. Lets a "pose" be
	## authored as an angle (dash arms back 48 degrees) and converted to
	## the torque that actually holds it there, instead of picking torque
	## values by trial and error.
	static func equilibrium_torque(target_angle_deg: float) -> float:
		return GRAVITY * sin(deg_to_rad(target_angle_deg))

	## The drive amplitude needed for this pendulum, oscillating at angular
	## frequency w (rad/s), to actually swing +/-amplitude_deg in steady
	## state -- the standard driven-damped-harmonic-oscillator amplitude
	## formula, inverted to solve for the forcing amplitude instead of the
	## response. Without this, the same fixed torque produces wildly
	## different swing sizes depending on how fast the gait is oscillating
	## (a fast stride is "stiffer" against a given pendulum's own inertia).
	func forced_drive_for_amplitude(amplitude_deg: float, w: float) -> float:
		var stiffness := GRAVITY * (PI / 180.0) # linearized gravity restoring torque per degree
		var reactance := stiffness - inertia * w * w
		var resistance := damping * w
		return amplitude_deg * sqrt(reactance * reactance + resistance * resistance)

# Position bob (the torso's vertical stride bounce) is a translation, not a
# rotation -- a plain damped spring toward a target position is the right
# tool there, not a pendulum.
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

# Arms/head are lighter (lower inertia, less damping) than legs, which stay
# comparatively controlled since they're what reads as "planted" when
# grounded -- floppy legs would look broken, floppy arms just look alive.
var torso_rot := Pendulum.new(3.0, 15.0, 32.0)
var torso_y := Spring.new(140.0, 16.0, REST_TORSO_Y)
var head_rot := Pendulum.new(1.0, 10.0, 38.0)
var left_arm := Pendulum.new(1.2, 9.5, 85.0)
var right_arm := Pendulum.new(1.2, 9.5, 85.0)
var left_leg := Pendulum.new(1.8, 24.0, 60.0)
var right_leg := Pendulum.new(1.8, 24.0, 60.0)

# Whole-body tilt from air drag, not a joint -- rotates the entire visual
# root rather than any one pendulum, since the effect being modeled (moving
# fast pushes the whole silhouette back, not just one limb) pivots around
# the character's actual center, not the torso's neck attach point the way
# torso_rot itself does. A plain spring chasing a speed-derived target angle
# reads as "leaning into the wind" without needing its own gravity term --
# unlike a limb, there's no rest pose for the whole body to sag back to
# except upright.
var body_lean := Spring.new(70.0, 15.0, 0.0)

# Real walking distance (not time) covered since the last full stride --
# see the walk branch below. Real world equivalent: roughly the length of
# one full left-right-left cycle for this rig's proportions.
const STEP_LENGTH := 55.0
const CLIMB_ANGULAR_FREQ := 5.0 # rad/s -- climbing cadence is roughly constant regardless of input, unlike walking's speed-derived one
var _stride_distance := 0.0
var _climb_phase := 0.0
var _last_vel := Vector2.ZERO

# How hard the character's own acceleration (speeding up, stopping,
# landing) shoves limbs/torso backward relative to the motion -- inertia,
# the same reason a passenger leans back when a car suddenly accelerates.
# Applies in every state, layered underneath whatever that state's own
# drive is doing.
const LEAN_RESPONSE := 0.16
const MAX_LEAN_TORQUE := 260.0

# Wind-resistance body tilt -- unlike LEAN above (which reacts to
# acceleration, i.e. speeding up or stopping), this reacts to raw speed
# itself, the same way a cyclist stays leaned into a headwind at a steady
# fast speed even while not accelerating at all.
const WIND_LEAN_PER_SPEED := 0.032
const MAX_WIND_LEAN_DEG := 26.0

## Advances every pendulum/spring one step from real dynamics driven by the
## given state. `vel`/`on_floor`/`is_dashing`/`is_climbing`/`move_speed` are
## the same values player.gd/remote_avatar.gd already have on hand each
## frame, whether from local physics or the last network update.
func update(delta: float, vel: Vector2, on_floor: bool, is_dashing: bool, is_climbing: bool, move_speed: float) -> void:
	var accel := (vel - _last_vel) / maxf(delta, 0.0001)
	_last_vel = vel
	var lean := clampf(-accel.x * LEAN_RESPONSE, -MAX_LEAN_TORQUE, MAX_LEAN_TORQUE)

	var torso_drive := lean
	var head_drive := lean * 0.5
	var left_arm_drive := -lean * 0.6
	var right_arm_drive := -lean * 0.6
	var left_leg_drive := lean * 0.35
	var right_leg_drive := lean * 0.35
	var torso_y_target := REST_TORSO_Y

	if is_dashing:
		torso_drive += Pendulum.equilibrium_torque(-16.0)
		left_arm_drive += Pendulum.equilibrium_torque(-48.0)
		right_arm_drive += Pendulum.equilibrium_torque(48.0)
		left_leg_drive += Pendulum.equilibrium_torque(16.0)
		right_leg_drive += Pendulum.equilibrium_torque(-16.0)
	elif is_climbing:
		_climb_phase += delta * CLIMB_ANGULAR_FREQ
		var s := sin(_climb_phase)
		var arm_torque := left_arm.forced_drive_for_amplitude(45.0, CLIMB_ANGULAR_FREQ)
		var leg_torque := left_leg.forced_drive_for_amplitude(15.0, CLIMB_ANGULAR_FREQ)
		left_arm_drive += s * arm_torque
		right_arm_drive += -s * arm_torque
		left_leg_drive += -s * leg_torque
		right_leg_drive += s * leg_torque
	elif not on_floor:
		var up := clampf(-vel.y / 400.0, -1.0, 1.0) # positive while rising, negative while falling
		torso_drive += Pendulum.equilibrium_torque(-14.0 * up)
		head_drive += Pendulum.equilibrium_torque(-8.0 * up)
		left_arm_drive += Pendulum.equilibrium_torque(-48.0 * up)
		right_arm_drive += Pendulum.equilibrium_torque(48.0 * up)
		left_leg_drive += Pendulum.equilibrium_torque(32.0 * up)
		right_leg_drive += Pendulum.equilibrium_torque(-32.0 * up)
	else:
		var speed_frac := absf(vel.x) / maxf(move_speed, 1.0)
		if speed_frac > 0.06:
			# Distance-based, not time-based: stride frequency is an
			# emergent result of how fast the character is actually
			# covering ground, not a wave generator sped up to match.
			_stride_distance += absf(vel.x) * delta
			var w := (absf(vel.x) / STEP_LENGTH) * TAU
			var phase := (_stride_distance / STEP_LENGTH) * TAU
			var s := cos(phase)
			# Bigger, snappier steps at a full sprint than a gentle walk.
			var leg_amp := lerpf(20.0, 45.0, speed_frac)
			var arm_amp := lerpf(14.0, 34.0, speed_frac)
			var leg_torque := left_leg.forced_drive_for_amplitude(leg_amp, w)
			var arm_torque := left_arm.forced_drive_for_amplitude(arm_amp, w)
			left_leg_drive += s * leg_torque
			right_leg_drive += -s * leg_torque
			left_arm_drive += -s * arm_torque
			right_arm_drive += s * arm_torque
			torso_drive += Pendulum.equilibrium_torque(sin(phase) * 4.0)
			torso_y_target = REST_TORSO_Y - 2.0 * absf(cos(phase))

	torso_rot.update(torso_drive, delta)
	torso_y.update(torso_y_target, delta)
	head_rot.update(head_drive, delta)
	left_arm.update(left_arm_drive, delta)
	right_arm.update(right_arm_drive, delta)
	left_leg.update(left_leg_drive, delta)
	right_leg.update(right_leg_drive, delta)

	var wind_lean_target := clampf(-vel.x * WIND_LEAN_PER_SPEED, -MAX_WIND_LEAN_DEG, MAX_WIND_LEAN_DEG)
	body_lean.update(wind_lean_target, delta)

## A one-shot impulse for a discrete event (a wall jump, a dash-jump cancel,
## getting tagged, getting repelled) -- shoves the relevant pendulums so
## they swing hard and settle back on their own, on top of whatever the
## continuous per-frame drive above is already doing.
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
		"repel":
			# A huge, sudden launch (see Player.REPEL_SPEED) deserves a
			# full-body flail, not a small twitch -- every limb kicked hard
			# and in a different direction from the wall-jump family so a
			# repel reads as distinctly more violent than any of those.
			left_arm.kick(-1400.0)
			right_arm.kick(1400.0)
			left_leg.kick(1000.0)
			right_leg.kick(-1000.0)
			torso_rot.kick(-320.0)
			head_rot.kick(320.0)

## Writes the current pendulum/spring values onto the actual rig nodes.
## `parts` is the same {part_name -> Sprite2D} dict player.gd/
## remote_avatar.gd already build for set_skin(); `torso` is
## parts["torso"], passed separately since it's the one node this touches
## position on, not just rotation. `visual_root` (the Visual node itself,
## optional) carries the whole-body wind lean -- kept separate from torso's
## own rotation since torso pivots around its neck attach point, not the
## character's overall center, so leaning it directly would swing the hips
## out rather than tilting the whole silhouette.
func apply_to(parts: Dictionary, torso: Node2D, visual_root: Node2D = null) -> void:
	torso.position = Vector2(0.0, torso_y.value)
	torso.rotation_degrees = torso_rot.angle
	if parts.has("head"):
		parts["head"].rotation_degrees = head_rot.angle
	if parts.has("left_arm"):
		parts["left_arm"].rotation_degrees = left_arm.angle
	if parts.has("right_arm"):
		parts["right_arm"].rotation_degrees = right_arm.angle
	if parts.has("left_leg"):
		parts["left_leg"].rotation_degrees = left_leg.angle
	if parts.has("right_leg"):
		parts["right_leg"].rotation_degrees = right_leg.angle
	if visual_root:
		visual_root.rotation_degrees = body_lean.value
