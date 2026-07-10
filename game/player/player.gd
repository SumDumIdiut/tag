extends CharacterBody2D
class_name Player

# Celeste movement, tuned to match the real game's constants (from the public
# decompiled source, Source/Player/Player.cs) rather than guessed. Celeste's
# constants are in its own pixel scale (Madeline's hitbox is ~11px tall,
# tiles are 8px); this player's capsule is 32px tall, so every distance/speed
# constant below is Celeste's real value scaled by SCALE = 32/11 ~= 2.909.
# Time-based constants (coyote time, dash duration, etc.) are already
# resolution-independent and used as-is.

const SCALE := 32.0 / 11.0

# Physics layer 1 ("world") only -- used for the wall-jump/corner-correction
# raycasts specifically, kept separate from this body's own collision_mask
# (which also includes other players/NPCs so they physically bump each
# other) so you can't wall-jump or corner-correct off a nearby player.
const WORLD_COLLISION_MASK := 1

const MOVE_SPEED := 90.0 * SCALE # Celeste: MaxRun
const GROUND_ACCEL := 1000.0 * SCALE # Celeste: RunAccel
const GROUND_FRICTION := 400.0 * SCALE # Celeste: RunReduce
const AIR_MULT := 0.65 # Celeste: AirMult
const AIR_ACCEL := GROUND_ACCEL * AIR_MULT
const AIR_FRICTION := GROUND_FRICTION * AIR_MULT

# Celeste's real Gravity is 900 (scaled); bumped up ~20% from that -- falling
# next to a wall (capped at WALL_BUMP_SLIDE_SPEED) was reading as "stuck" /
# unresponsive rather than actually falling, and stronger gravity gets
# through that state faster.
const GRAVITY := 1080.0 * SCALE
const MAX_FALL_SPEED := 160.0 * SCALE
const FAST_MAX_FALL_SPEED := 240.0 * SCALE # holding down while falling
# Near the apex of a jump (|vel.y| below this) gravity is halved -- this is
# what gives Celeste jumps their floaty hang at the top instead of a sharp
# ballistic arc.
const HALF_GRAV_THRESHOLD := 40.0 * SCALE

const JUMP_VELOCITY := -105.0 * SCALE
# Added to horizontal speed (in whatever direction you're already moving) on
# a ground jump -- makes running jumps carry noticeably more distance than
# jumping from a standstill.
const JUMP_H_BOOST := 40.0 * SCALE
# Variable jump height in real Celeste isn't "cut velocity on release" --
# holding jump SUSTAINS the initial jump velocity against gravity for up to
# this long; releasing early (or this timing out) just lets gravity resume.
const VAR_JUMP_TIME := 0.2
const COYOTE_TIME := 0.1 # Celeste: JumpGraceTime
const JUMP_BUFFER_TIME := 0.1

const WALL_JUMP_VELOCITY := Vector2(130.0 * SCALE, -105.0 * SCALE) # Celeste: WallJumpHSpeed, same vertical as a normal jump
const SUPER_WALL_JUMP_VELOCITY := Vector2(170.0 * SCALE, -160.0 * SCALE) # Celeste: SuperWallJumpH / SuperWallJumpSpeed -- dashing into a wall then jumping off it
const WALL_JUMP_LOCK_TIME := 0.16 # Celeste: WallJumpForceTime
# Wall-jump doesn't require actually pressing into the wall -- being
# airborne and within this reach of one is enough (Celeste: WallJumpCheckDist
# = 3px in its own scale), checked via a short raycast when not in contact.
const WALL_JUMP_PROXIMITY := 3.0 * SCALE
# Corner correction: hitting a platform's vertical edge (e.g. dashing into
# it) nudges you up onto its top surface if there's room, instead of just
# hanging on the wall face -- a hard 90-degree corner has no slope to slide
# you up over on its own. Eased over this long rather than snapped instantly
# so it reads as a quick mantle, not a teleport.
const CORNER_CORRECTION_REACH := 20.0
const CORNER_CORRECTION_DURATION := 0.12

# Passive contact with a wall (not holding climb) just stops you falling any
# faster than normal, like bumping into it -- you don't stick. Only holding
# "climb" gives the slow controlled slide/ascent, and costs stamina.
const WALL_BUMP_SLIDE_SPEED := 250.0

const DASH_SPEED := 240.0 * SCALE * 1.5 # Celeste's real value, boosted 1.5x
const DASH_END_SPEED := 160.0 * SCALE # residual speed once a dash ends naturally
const DASH_END_UP_MULT := 0.75 # upward dashes keep less of their end speed
const DASH_DURATION := 0.15 # Celeste: DashTime
const DASH_REFILL_COOLDOWN := 0.2 # Celeste: DashCooldown -- fixed minimum gap between dashes

# Jumping within this window of a dash ending keeps the dash's speed instead
# of snapping back down to MOVE_SPEED -- chaining dashes into extra distance.
const DASH_JUMP_WINDOW := 0.15

# A follow-up jump treats the dash it's chaining from as one of three angles:
# steep enough counts as an "up dash" (jump reads as a vertical boost, not a
# horizontal launch); flat (mostly horizontal) is a straight dash (full
# boosted wall jump, both axes); anything in between is "diagonal", which off
# a wall reflects the dash's own velocity back off it instead (see
# _dash_wall_jump_kick).
const UP_DASH_Y_THRESHOLD := -0.85
const DIAGONAL_DASH_Y_THRESHOLD := -0.3
const UP_DASH_JUMP_H_SUPPRESS := 0.35

# Jumping mid-dash (a flat/horizontal one, not an up-dash) doesn't just keep
# the dash's own speed -- it boosts past it to this flat speed, and that
# boosted speed is fully retained (no ground friction) through landing and
# for this many frames afterward, before normal ground control resumes.
const DASH_JUMP_SPEED := 900.0
const DASH_JUMP_LANDING_RETENTION_FRAMES := 6.0
# When a boost/kick's target speed is already exceeded by current speed, this
# fraction of it is still added on top as a smaller top-up -- some reward for
# chaining, but not the full value stacking on top of an already-high speed.
const SPEED_STACK_FRACTION := 0.35

# Climbing (hold "climb" against a wall): costs stamina, refills fully on
# ground contact, and dumps you off the wall if it hits zero.
const STAMINA_MAX := 110.0 # Celeste: ClimbMaxStamina
const STAMINA_DRAIN_CLING := 10.0 # Celeste: ClimbStillCost (per second)
const STAMINA_DRAIN_CLIMB := 45.0 # Celeste: ClimbUpCost (per second)
const CLIMB_UP_SPEED := 45.0 * SCALE
const CLIMB_DOWN_SPEED := 80.0 * SCALE # deliberately holding down while climbing
const CLIMB_SLIP_SPEED := 30.0 * SCALE # initial fall speed the instant stamina runs out
const CLIMB_EXHAUST_TIME := 0.6

# Not a Celeste move -- a plain extra air jump, refilled by touching ground
# or performing a wall jump (so wall-jump + double-jump chain together).
var double_jump_available := true

var _corner_correction_active := false
var _corner_correction_start := Vector2.ZERO
var _corner_correction_target := Vector2.ZERO
var _corner_correction_timer := 0.0

var coyote_timer := 0.0
var jump_buffer_timer := 0.0
var wall_jump_lock_timer := 0.0
var var_jump_timer := 0.0
var _held_jump_velocity_y := 0.0

var dash_timer := 0.0
var dash_cooldown_timer := 0.0
var dash_jump_grace_timer := 0.0
var dash_available := true
var is_dashing := false
var dash_direction := Vector2.ZERO
var facing := 1

# Horizontal speed at the instant a dash begins, before the dash's own fixed
# DASH_SPEED overwrites it -- a dash is a hard reset of velocity, so without
# this, momentum built up before the dash (e.g. a chained wall-jump/dash-jump
# streak) would just be silently lost the moment you dash, even though a
# wall-jump off that dash is supposed to carry it through, reflected.
var _pre_dash_speed := 0.0

var speed_boost_active := false
var landed_grace_timer := 0.0
var _was_on_floor_physics := false

var stamina := STAMINA_MAX
var is_climbing := false
var climb_exhausted_timer := 0.0

@onready var _visual: ColorRect = $Visual

var _was_on_floor_visual := false
var _base_color: Color

# Matches the Visual ColorRect's offsets in player.tscn (a 20x32 rect
# centered on the player origin).
const VISUAL_TOP_FULL := -16.0
const VISUAL_BOTTOM := 16.0

const TAG_IT_COLOR := Color(1.0, 0.85, 0.1, 1.0)

func _ready() -> void:
	if _visual:
		_base_color = _visual.color

## Recolors this player/NPC to flag it as the current Tag "it", or back to
## its own base color when it's no longer it -- lets TagMode mark whoever's
## chasing without every participant needing to know its own color scheme.
func set_tagged_it(active: bool) -> void:
	if not _visual:
		return
	_visual.color = TAG_IT_COLOR if active else _base_color

# Purely cosmetic squash/stretch, recomputed every rendered frame (not tied
# to the fixed physics tick) from state that's either authoritative or
# locally predicted.
func _process(delta: float) -> void:
	if not _visual:
		return
	var on_floor_now := is_on_floor()
	if on_floor_now and not _was_on_floor_visual:
		_visual.scale = Vector2(1.25, 0.75)
	_was_on_floor_visual = on_floor_now

	var target_scale := Vector2.ONE
	if is_dashing:
		target_scale = Vector2(1.5, 0.6)
	elif not on_floor_now:
		if velocity.y < -40.0:
			target_scale = Vector2(0.85, 1.2)
		elif velocity.y > 40.0:
			target_scale = Vector2(1.1, 0.9)
	_visual.scale = _visual.scale.lerp(target_scale, clampf(delta * 12.0, 0.0, 1.0))

	# Dashing shows only the bottom half of the body -- the top edge moves
	# down to the vertical midpoint, bottom edge stays put.
	_visual.offset_top = (VISUAL_TOP_FULL + VISUAL_BOTTOM) * 0.5 if is_dashing else VISUAL_TOP_FULL
	_visual.offset_bottom = VISUAL_BOTTOM
	_visual.pivot_offset = _visual.size * 0.5

func apply_input(input: Dictionary, delta: float) -> void:
	var move_dir: Vector2 = input.get("move_dir", Vector2.ZERO)
	var jump_pressed: bool = input.get("jump_pressed", false)
	var jump_held: bool = input.get("jump_held", false)
	var dash_pressed: bool = input.get("dash_pressed", false)
	var climb_held: bool = input.get("climb_held", false)

	_tick_timers(delta)

	if _corner_correction_active:
		_process_corner_correction(delta)
		return

	var on_floor := is_on_floor()
	var on_wall := is_on_wall_only()
	# Wall-jump eligibility is more generous than raw wall contact -- it also
	# accepts being close to a wall while airborne without pressing into it.
	var wall_jump_normal := _find_wall_jump_normal(on_wall)

	if on_floor:
		coyote_timer = COYOTE_TIME
		stamina = STAMINA_MAX
		double_jump_available = true
	# Just landed while still carrying a dash-jump speed boost -- start the
	# retention window instead of losing it to ground friction immediately.
	if on_floor and not _was_on_floor_physics and speed_boost_active:
		landed_grace_timer = DASH_JUMP_LANDING_RETENTION_FRAMES / 60.0
	_was_on_floor_physics = on_floor
	if jump_pressed:
		jump_buffer_timer = JUMP_BUFFER_TIME
	# Dash refills on touching ground or being close enough to wall-jump --
	# same generous check wall-jump itself uses (not just exact wall
	# contact), so anywhere a wallbang would let you wall-jump, it also
	# refills the dash, independent of the cooldown below. The cooldown only
	# gates *firing* a new dash, not whether one is available.
	if on_floor or wall_jump_normal != Vector2.ZERO:
		dash_available = true
	if dash_pressed and dash_available and dash_cooldown_timer <= 0.0 and not is_dashing:
		_start_dash(move_dir)

	# Jump always takes priority over climbing -- you can wall-jump off a
	# wall while holding climb, same as Celeste's grab button not blocking
	# the jump button.
	is_climbing = on_wall and climb_held and stamina > 0.0 and climb_exhausted_timer <= 0.0 \
		and not is_dashing and jump_buffer_timer <= 0.0

	# Jump cancels a dash immediately (rather than waiting for it to finish)
	# whenever a real jump is actually available, converting straight into a
	# jump that keeps the dash's full horizontal speed -- the "dash jump"
	# tech. Gated on coyote/wall so dashing can't be a free extra air jump.
	if is_dashing and jump_pressed and (coyote_timer > 0.0 or wall_jump_normal != Vector2.ZERO):
		_dash_jump_cancel(wall_jump_normal)
	elif is_dashing:
		_process_dash(delta)
	elif is_climbing:
		_process_climb(move_dir, delta)
	else:
		_process_gravity(delta, on_floor, on_wall, move_dir, jump_held)
		_process_horizontal(move_dir, delta, on_floor)
		_process_jump(on_floor, wall_jump_normal, move_dir)

	if move_dir.x != 0.0 and not is_climbing:
		facing = 1 if move_dir.x > 0.0 else -1

	move_and_slide()

	# Dashing (or just running) into the top edge of a platform hits its
	# vertical face square-on -- a hard 90-degree corner has no slope to
	# slide you up over it, so without this you just hang on the wall face
	# and keep wall-jumping instead of mantling onto the platform. Uses the
	# same generous proximity check as wall-jump (not just exact contact),
	# recomputed post-move, so being slightly above the platform's edge --
	# not just level with or below it -- still catches the correction.
	if not is_dashing and not is_climbing:
		var post_move_wall := _find_wall_jump_normal(is_on_wall_only())
		if post_move_wall != Vector2.ZERO:
			_try_corner_correction(post_move_wall)

func _tick_timers(delta: float) -> void:
	coyote_timer = maxf(coyote_timer - delta, 0.0)
	jump_buffer_timer = maxf(jump_buffer_timer - delta, 0.0)
	wall_jump_lock_timer = maxf(wall_jump_lock_timer - delta, 0.0)
	var_jump_timer = maxf(var_jump_timer - delta, 0.0)
	landed_grace_timer = maxf(landed_grace_timer - delta, 0.0)
	dash_cooldown_timer = maxf(dash_cooldown_timer - delta, 0.0)
	dash_jump_grace_timer = maxf(dash_jump_grace_timer - delta, 0.0)
	climb_exhausted_timer = maxf(climb_exhausted_timer - delta, 0.0)

func _process_gravity(delta: float, on_floor: bool, on_wall: bool, move_dir: Vector2, jump_held: bool) -> void:
	if on_floor:
		velocity.y = minf(velocity.y, 0.0)
		return
	# Sustain the jump's initial velocity against gravity while jump is held,
	# up to VAR_JUMP_TIME -- this is Celeste's real variable-jump-height
	# mechanism (not a cut-on-release multiplier).
	if var_jump_timer > 0.0 and jump_held and velocity.y < 0.0:
		velocity.y = _held_jump_velocity_y
		return
	var grav := GRAVITY
	if absf(velocity.y) < HALF_GRAV_THRESHOLD:
		grav *= 0.5
	if on_wall and velocity.y > 0.0 and wall_jump_lock_timer <= 0.0:
		velocity.y = minf(velocity.y + grav * delta, WALL_BUMP_SLIDE_SPEED)
	else:
		var fall_cap := FAST_MAX_FALL_SPEED if move_dir.y > 0.1 else MAX_FALL_SPEED
		velocity.y = minf(velocity.y + grav * delta, fall_cap)

func _process_climb(move_dir: Vector2, delta: float) -> void:
	velocity.x = 0.0
	if move_dir.y < -0.1:
		velocity.y = -CLIMB_UP_SPEED
		stamina -= STAMINA_DRAIN_CLIMB * delta
	elif move_dir.y > 0.1:
		velocity.y = CLIMB_DOWN_SPEED
		stamina -= STAMINA_DRAIN_CLING * delta
	else:
		velocity.y = 0.0
		stamina -= STAMINA_DRAIN_CLING * delta
	if stamina <= 0.0:
		stamina = 0.0
		climb_exhausted_timer = CLIMB_EXHAUST_TIME
		velocity.y = CLIMB_SLIP_SPEED

func _process_horizontal(move_dir: Vector2, delta: float, on_floor: bool) -> void:
	if wall_jump_lock_timer > 0.0:
		return
	# Dash-jump speed boost: fully retained (no accel/friction at all) while
	# airborne, and for a few frames after landing, before normal ground
	# control resumes.
	if speed_boost_active:
		if not on_floor or landed_grace_timer > 0.0:
			return
		speed_boost_active = false
	var target := move_dir.x * MOVE_SPEED
	var accel := GROUND_ACCEL if on_floor else AIR_ACCEL
	var friction := GROUND_FRICTION if on_floor else AIR_FRICTION
	var rate := accel if absf(target) > 0.01 else friction
	velocity.x = move_toward(velocity.x, target, rate * delta)

func _process_jump(on_floor: bool, wall_jump_normal: Vector2, move_dir: Vector2) -> void:
	if jump_buffer_timer <= 0.0:
		return
	if coyote_timer > 0.0:
		# A fresh ground jump clears a stale dash-jump speed boost -- by the
		# time this fires you're on/near the ground, so the landing-retention
		# window has already done its job; this is just a clean baseline.
		speed_boost_active = false
		landed_grace_timer = 0.0
		velocity.y = JUMP_VELOCITY
		if absf(velocity.x) > 10.0:
			velocity.x += signf(velocity.x) * JUMP_H_BOOST
		_start_jump_hold(JUMP_VELOCITY)
		jump_buffer_timer = 0.0
		coyote_timer = 0.0
		_try_dash_jump_boost()
	elif wall_jump_normal != Vector2.ZERO:
		# A dash that only just ended (grace window still open) chains into a
		# stronger wall jump, same as the mid-dash-cancel case below.
		# (_wall_jump() itself clears a stale speed boost -- a wall jump is a
		# deliberate redirect off a surface, so overriding prior momentum is
		# correct there.)
		var kick := WALL_JUMP_VELOCITY
		if dash_jump_grace_timer > 0.0:
			kick = _dash_wall_jump_kick()
			_carry_pre_dash_speed()
		dash_jump_grace_timer = 0.0
		_wall_jump(wall_jump_normal.x, kick)
		jump_buffer_timer = 0.0
	elif double_jump_available:
		# Deliberately does NOT touch speed_boost_active/landed_grace_timer --
		# a double jump is a pure vertical assist, not a redirect, so it
		# shouldn't interrupt existing horizontal momentum (e.g. a boosted
		# dash-jump still in its landing-retention window) by snapping it
		# back down to normal walking speed.
		velocity.y = JUMP_VELOCITY
		if absf(velocity.x) > 10.0:
			velocity.x += signf(velocity.x) * JUMP_H_BOOST
		_start_jump_hold(JUMP_VELOCITY)
		double_jump_available = false
		jump_buffer_timer = 0.0

## If there's clear space directly above (up to CORNER_CORRECTION_REACH) and
## solid ground just below that elevated spot, snaps the player up onto it.
## Only fires while pressed against a wall with nothing above -- exactly the
## "clipped the corner of a platform" case, not a real tall wall (which
## would still have wall above the reach distance and correctly fail the
## first check).
func _try_corner_correction(wall_normal: Vector2) -> void:
	# Probe from just past the capsule's edge, in the direction of the wall
	# (opposite its normal) -- probing at the player's own center would fall
	# short of the wall's actual footprint by the capsule radius and never
	# hit anything.
	var probe_x := global_position.x - wall_normal.x * 12.0
	var probe_top := Vector2(probe_x, global_position.y)
	var space_state := get_world_2d().direct_space_state
	var up_params := PhysicsRayQueryParameters2D.create(
		probe_top, probe_top + Vector2(0.0, -CORNER_CORRECTION_REACH), WORLD_COLLISION_MASK, [get_rid()]
	)
	if space_state.intersect_ray(up_params):
		return # something's directly overhead -- this is a real wall, not a low corner
	var down_params := PhysicsRayQueryParameters2D.create(
		probe_top + Vector2(0.0, -CORNER_CORRECTION_REACH),
		probe_top + Vector2(0.0, 4.0),
		WORLD_COLLISION_MASK, [get_rid()]
	)
	var down_result := space_state.intersect_ray(down_params)
	if not down_result:
		return # nothing to land on up there either -- don't nudge into open air
	# Snap to rest exactly on the detected surface (capsule half-height is
	# 16px) instead of a blind fixed offset, which could overshoot into open
	# air above the platform or undershoot back into the wall. Also carries
	# the player's X onto the platform's footprint (probe_x), since merely
	# rising while still pinned at the wall's edge would just touch the
	# corner again.
	var hit_y: float = down_result.position.y
	_corner_correction_active = true
	_corner_correction_start = global_position
	_corner_correction_target = Vector2(probe_x, hit_y - 16.0)
	_corner_correction_timer = 0.0


## Glides the player from where the corner correction was triggered up onto
## the detected ledge over CORNER_CORRECTION_DURATION, instead of teleporting
## instantly -- velocity is held at zero and move_and_slide is skipped for the
## duration (via the early-return in apply_input) so nothing fights the glide.
func _process_corner_correction(delta: float) -> void:
	_corner_correction_timer += delta
	var t := clampf(_corner_correction_timer / CORNER_CORRECTION_DURATION, 0.0, 1.0)
	var eased_t := t * t * (3.0 - 2.0 * t)
	global_position = _corner_correction_start.lerp(_corner_correction_target, eased_t)
	velocity = Vector2.ZERO
	if t >= 1.0:
		_corner_correction_active = false

## Finds a wall to jump off even if not in actual contact with one: real
## contact always counts, and failing that a short raycast on each side
## covers "close enough, airborne" so wall-jump doesn't require holding the
## direction key into the wall. Checked at a few heights around the player's
## center (not just dead-center), so being just below the top or bottom edge
## of a platform -- its short vertical edge, not a tall wall -- still counts,
## instead of requiring the ray to land exactly on the player's midline.
## Returns Vector2.ZERO if no wall qualifies.
func _find_wall_jump_normal(on_wall: bool) -> Vector2:
	if on_wall:
		return get_wall_normal()
	var space_state := get_world_2d().direct_space_state
	var reach := 10.0 + WALL_JUMP_PROXIMITY # 10.0 = capsule radius (player.tscn)
	for dir_sign in [-1.0, 1.0]:
		for y_offset in [0.0, -12.0, 12.0]:
			var from := global_position + Vector2(0.0, y_offset)
			var to := from + Vector2(dir_sign * reach, 0.0)
			var params := PhysicsRayQueryParameters2D.create(from, to, WORLD_COLLISION_MASK, [get_rid()])
			var result := space_state.intersect_ray(params)
			if result:
				return Vector2(-dir_sign, 0.0)
	return Vector2.ZERO

func _wall_jump(wall_normal_x: float, kick: Vector2) -> void:
	# Clears any stale dash-jump speed boost still pending from an earlier,
	# not-yet-landed jump -- otherwise _process_horizontal's "airborne ->
	# retain boost, skip normal control" check would freeze horizontal
	# velocity at whatever this wall jump just set it to for the rest of
	# the fall.
	speed_boost_active = false
	landed_grace_timer = 0.0
	# Floors speed in the kick's direction at the kick's own magnitude rather
	# than overwriting it outright -- wall-jumping while already carrying
	# more speed than that (e.g. mid dash-jump) keeps it instead of getting
	# cut down. But unlike plain addition, it doesn't stack the kick on top
	# of speed that's already above the floor -- that was blowing momentum
	# up far past anything reasonable (e.g. dash speed + kick + kick...).
	velocity.x = _speed_floor(velocity.x, wall_normal_x, kick.x)
	velocity.y = kick.y
	_start_jump_hold(kick.y)
	wall_jump_lock_timer = WALL_JUMP_LOCK_TIME
	facing = signi(wall_normal_x) if wall_normal_x != 0.0 else facing
	double_jump_available = true

func _start_jump_hold(initial_velocity_y: float) -> void:
	var_jump_timer = VAR_JUMP_TIME
	_held_jump_velocity_y = initial_velocity_y

## Restores whatever speed the player had right before this dash overwrote
## it, if that was higher than the dash's own current speed -- called just
## before a dash-into-wall kick, so _speed_floor's "preserve and redirect"
## case (see below) has the player's real pre-dash momentum to work with
## instead of just the dash's own fixed speed. Keeps the dash's current
## direction (into the wall), since _wall_jump/_speed_floor handles flipping
## it into the kick's direction.
func _carry_pre_dash_speed() -> void:
	if absf(velocity.x) < _pre_dash_speed:
		velocity.x = signf(velocity.x) * _pre_dash_speed

## Guarantees at least floor_speed of speed in dir_sign's direction, and never
## destroys speed you already had -- a wall-jump/dash-jump kick should always
## feel like a gain, never a cut, regardless of which way you were already
## moving when it landed:
## - already moving with the kick, above its floor: a partial top-up
##   (SPEED_STACK_FRACTION), not the full floor_speed stacked on -- that was
##   blowing up into runaway momentum on repeated chains.
## - moving opposite the kick, but with more total speed than floor_speed:
##   that speed is preserved, just fully redirected into the kick's
##   direction -- a wall shouldn't destroy your momentum, only redirect it.
## - otherwise (below floor_speed either way): raised straight up to it.
func _speed_floor(current_velocity_x: float, dir_sign: float, floor_speed: float) -> float:
	var component := current_velocity_x * dir_sign
	var magnitude := absf(current_velocity_x)
	if component >= floor_speed:
		component += floor_speed * SPEED_STACK_FRACTION
	elif magnitude >= floor_speed:
		component = magnitude
	else:
		component = floor_speed
	return component * dir_sign

## Jump pressed shortly after a dash naturally ended (not mid-dash -- see
## _dash_jump_cancel for that). _process_horizontal() already reset
## velocity.x to normal run behavior earlier this same tick, so this has to
## explicitly restore the boosted speed rather than just leaving it alone.
func _try_dash_jump_boost() -> void:
	if dash_jump_grace_timer <= 0.0:
		return
	dash_jump_grace_timer = 0.0
	if dash_direction.y < UP_DASH_Y_THRESHOLD:
		velocity.x *= UP_DASH_JUMP_H_SUPPRESS
	else:
		# Floors at DASH_JUMP_SPEED rather than overwriting or stacking on
		# top of it -- never a drop below it, but not an ever-escalating gain
		# on top of it either.
		velocity.x = _speed_floor(velocity.x, signf(dash_direction.x), DASH_JUMP_SPEED)
		speed_boost_active = true

## Jump pressed WHILE still dashing: cuts the dash short right there and
## converts it straight into a jump, boosting horizontal speed up to
## DASH_JUMP_SPEED (retained through landing, see speed_boost_active) --
## this is the main "dash jump" tech. An up-dash is the exception: its
## horizontal punch is suppressed instead, so the jump reads as a vertical
## boost rather than a horizontal launch.
func _dash_jump_cancel(wall_jump_normal: Vector2) -> void:
	is_dashing = false
	jump_buffer_timer = 0.0
	dash_jump_grace_timer = 0.0
	# Clears any stale boost from an earlier, not-yet-landed jump -- same
	# reasoning as in _process_jump; re-armed just below if this jump grants
	# a fresh one.
	speed_boost_active = false
	landed_grace_timer = 0.0
	if coyote_timer > 0.0:
		if dash_direction.y < UP_DASH_Y_THRESHOLD:
			velocity.x *= UP_DASH_JUMP_H_SUPPRESS
		else:
			# Floors at DASH_JUMP_SPEED -- cutting a dash short into a jump
			# should never drop below the dash's own (often higher) speed,
			# but shouldn't stack DASH_JUMP_SPEED on top of it either.
			velocity.x = _speed_floor(velocity.x, signf(dash_direction.x), DASH_JUMP_SPEED)
			speed_boost_active = true
		velocity.y = JUMP_VELOCITY
		_start_jump_hold(JUMP_VELOCITY)
		coyote_timer = 0.0
	elif wall_jump_normal != Vector2.ZERO:
		_carry_pre_dash_speed()
		_wall_jump(wall_jump_normal.x, _dash_wall_jump_kick())

## Shared by both dash-jump trigger paths (mid-dash-cancel and post-dash
## grace window) for the wall case, based on how steep the dash was:
## - flat (mostly horizontal): a straight dash, full boosted "super" wall
##   jump on both axes.
## - diagonal (in between): reflects the dash's own velocity back off the
##   wall instead of a fixed kick -- horizontal comes back at the same speed
##   you dashed in with (a wall only blocks the perpendicular component, so
##   it's mirrored via wall_normal same as any other kick), vertical carries
##   straight through unchanged (a wall doesn't block motion parallel to
##   itself), so a diagonal dash into a wall keeps exactly as much speed as
##   it went in with, just redirected.
## - up (steep): DASH_JUMP_SPEED boost on the rotated axis -- vertical
##   instead of horizontal, since it reads as climbing the wall, not
##   launching off it -- with only a small horizontal fraction so it isn't
##   perfectly vertical. (Retention of that boosted vertical speed is the
##   var-jump-hold sustain already triggered by every wall jump.)
func _dash_wall_jump_kick() -> Vector2:
	if dash_direction.y < UP_DASH_Y_THRESHOLD:
		return Vector2(WALL_JUMP_VELOCITY.x * UP_DASH_JUMP_H_SUPPRESS, -DASH_JUMP_SPEED)
	if dash_direction.y < DIAGONAL_DASH_Y_THRESHOLD:
		return Vector2(absf(dash_direction.x) * DASH_SPEED, dash_direction.y * DASH_SPEED)
	return SUPER_WALL_JUMP_VELOCITY

func _start_dash(move_dir: Vector2) -> void:
	var dir := move_dir
	if dir.length() < 0.1:
		dir = Vector2(facing, 0.0)
	dash_direction = dir.normalized()
	_pre_dash_speed = absf(velocity.x)
	# Clears any stale boost from an earlier, not-yet-landed dash-jump --
	# starting a fresh dash is itself a deliberate override of horizontal
	# control, same reasoning as _wall_jump/_dash_jump_cancel. Without this,
	# dash-jumping and then dashing again (e.g. a diagonal up-dash) left the
	# OLD boost flag stuck true after the new dash ended, and
	# _process_horizontal's "airborne + boost active -> skip all control"
	# check froze horizontal input completely until landing.
	speed_boost_active = false
	landed_grace_timer = 0.0
	is_dashing = true
	dash_available = false
	dash_timer = DASH_DURATION
	dash_cooldown_timer = DASH_REFILL_COOLDOWN

func _process_dash(delta: float) -> void:
	dash_timer -= delta
	velocity = dash_direction * DASH_SPEED
	if dash_timer <= 0.0:
		is_dashing = false
		var end_speed := DASH_END_SPEED
		if dash_direction.y < -0.5:
			end_speed *= DASH_END_UP_MULT
		velocity = dash_direction * end_speed
		dash_jump_grace_timer = DASH_JUMP_WINDOW
