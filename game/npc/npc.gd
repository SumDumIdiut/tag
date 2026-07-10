extends Player
class_name NPC

# Scripted Tag AI. Chasing uses a waypoint graph (see WaypointGraph) for
# macro-navigation across platforms -- steering straight at a target's raw
# position falls apart the moment the target is on a different platform,
# behind a pillar, or otherwise unreachable in a straight line, which is
# exactly why a chaser could wander forever without ever closing in. Fleeing
# stays local/reactive (it doesn't need a destination, just "away"), but adds
# separation from other nearby non-it participants so fleeing NPCs spread out
# instead of clumping into a single mass that can physically wall off the
# chaser from ever reaching anyone.
# skill_level (1-5) tunes reaction speed, mistake rate, dash readiness, and
# how far ahead a chaser leads a moving target.
@export var skill_level: int = 3

var tag_mode: TagMode = null
var waypoint_graph: WaypointGraph = null

var _decision_timer := 0.0
var _decision_move_dir := Vector2.ZERO
var _decision_jump := false
var _decision_dash := false

# Tracks how long horizontal movement has been requested without the body
# actually going anywhere -- catches "jammed against geometry or another
# character" cases the one-shot reactive obstacle probe below can miss.
var _stuck_timer := 0.0

const SEPARATION_RADIUS := 70.0

func _skill_t() -> float:
	return clampf(float(skill_level - 1) / 4.0, 0.0, 1.0)

func _reaction_interval() -> float:
	return lerpf(0.3, 0.04, _skill_t())

func _mistake_chance() -> float:
	return lerpf(0.3, 0.0, _skill_t())

func _dash_chance() -> float:
	return lerpf(0.1, 0.8, _skill_t())

# How far ahead of a target's current velocity a chaser aims -- reads as
# anticipation at high skill instead of always chasing a position that's
# already stale by the time this decision lands.
func _lead_amount() -> float:
	return lerpf(0.0, 0.4, _skill_t())

# Fleeing at close range should feel like a panicked burst, not a coin flip --
# distance shrinks (more reliably panics) and reach grows with skill.
func _panic_distance() -> float:
	return lerpf(70.0, 170.0, _skill_t())

func _physics_process(delta: float) -> void:
	if not tag_mode:
		return
	_decision_timer -= delta
	if _decision_timer <= 0.0:
		_decision_timer = _reaction_interval()
		_make_decision()
	_check_stuck(delta)

	var input := {
		"move_dir": _decision_move_dir,
		"jump_pressed": _decision_jump,
		"jump_held": _decision_jump,
		"dash_pressed": _decision_dash,
		"climb_held": false,
	}
	apply_input(input, delta)
	_decision_jump = false
	_decision_dash = false

## Forces a jump if we're trying to move but going nowhere for a sustained
## stretch -- covers cases (corners, a wall of other fleeing NPCs) where the
## AI would otherwise just push uselessly into something.
func _check_stuck(delta: float) -> void:
	if absf(_decision_move_dir.x) > 0.1 and is_on_floor() and absf(velocity.x) < 20.0:
		_stuck_timer += delta
		if _stuck_timer > 0.2:
			_decision_jump = true
			_stuck_timer = 0.0
	else:
		_stuck_timer = 0.0

func _make_decision() -> void:
	var target := tag_mode.get_ai_target(self)
	if target == null:
		_decision_move_dir = Vector2.ZERO
		return

	var am_it := tag_mode.is_it(self)
	var to_target: Vector2 = target.global_position - global_position
	var dir_sign: float

	if am_it:
		# Aim through the waypoint graph's next hop toward the target rather
		# than the target's raw position -- handles multi-platform routing
		# (the actual fix for "never gets close": a straight-line heading
		# toward someone on a different platform just walks into whatever's
		# in between forever).
		var target_vel: Vector2 = target.velocity
		var lead_target: Vector2 = target.global_position + target_vel * _lead_amount()
		var steer_pos: Vector2 = lead_target
		if waypoint_graph:
			steer_pos = waypoint_graph.next_hop(global_position, lead_target)
		dir_sign = signf(steer_pos.x - global_position.x)
	else:
		dir_sign = -signf(to_target.x)
		# Don't flee straight into a nearby wall/boundary and trap ourselves
		# in a corner -- if that direction is blocked close by, the other
		# direction (even toward the chaser) beats getting cornered.
		if dir_sign != 0.0 and _blocked_ahead(dir_sign, 60.0):
			dir_sign = -dir_sign
		# Separation: nudge away from whichever other non-it participant is
		# closest, if it's crowding us -- keeps fleeing NPCs from clumping
		# into a single mass that (now that players physically collide) can
		# wall the chaser off from ever reaching anyone.
		var nearest_other := _nearest_crowding_participant()
		if nearest_other:
			var away: Vector2 = global_position - nearest_other.global_position
			if absf(away.x) > 1.0:
				dir_sign = signf(away.x)

	if randf() < _mistake_chance():
		dir_sign = -dir_sign
	_decision_move_dir = Vector2(dir_sign, 0.0)

	if dir_sign == 0.0:
		return

	# Reactive obstacle handling: a blocked path or a ledge just ahead both
	# call for a jump, and so does a target clearly above us.
	var blocked := _blocked_ahead(dir_sign, 20.0)
	var floor_ahead := _floor_ahead(dir_sign, 20.0)
	if blocked or not floor_ahead or to_target.y < -20.0:
		_decision_jump = randf() > _mistake_chance()

	# Dashing is purposeful, not random noise: chasers dash to close real
	# distance, fleers dash as a panic burst when the chaser gets close, both
	# scaled by skill via _dash_chance/_panic_distance.
	var panicking := not am_it and to_target.length() < _panic_distance()
	var closing_distance := am_it and absf(to_target.x) > 150.0
	if panicking or (closing_distance and randf() < _dash_chance()):
		_decision_dash = true

func _nearest_crowding_participant() -> Node:
	if not tag_mode:
		return null
	var it := tag_mode.get_it()
	var nearest: Node = null
	var nearest_dist := SEPARATION_RADIUS
	for p in tag_mode.participants:
		if p == self or p == it:
			continue
		var d: float = global_position.distance_to(p.global_position)
		if d < nearest_dist:
			nearest_dist = d
			nearest = p
	return nearest

func _blocked_ahead(dir_sign: float, distance: float) -> bool:
	var space_state := get_world_2d().direct_space_state
	var ahead := Vector2(dir_sign * distance, 0.0)
	var params := PhysicsRayQueryParameters2D.create(
		global_position, global_position + ahead, WORLD_COLLISION_MASK, [get_rid()]
	)
	return space_state.intersect_ray(params).size() > 0

func _floor_ahead(dir_sign: float, distance: float) -> bool:
	var space_state := get_world_2d().direct_space_state
	var ahead := Vector2(dir_sign * distance, 0.0)
	var params := PhysicsRayQueryParameters2D.create(
		global_position + ahead, global_position + ahead + Vector2(0.0, 40.0), WORLD_COLLISION_MASK, [get_rid()]
	)
	return space_state.intersect_ray(params).size() > 0
