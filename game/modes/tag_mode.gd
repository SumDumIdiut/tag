extends Node
class_name TagMode

const IMMUNITY_TIME := 1.0
const TAG_DISTANCE := 40.0
# Two participants physically colliding (not just within TAG_DISTANCE) for
# this long get shoved apart. Without this, a chaser and target can end up
# just standing inside each other -- and worse, since actual collision
# contact is much closer than TAG_DISTANCE, it's exactly what lets "it"
# ping-pong rapidly back and forth between the same two the instant each
# tag's immunity window expires, since they never actually separated.
const REPEL_CONTACT_THRESHOLD_SEC := 3.0

const DEFAULT_ROUND_DURATION_SEC := 180.0

signal it_changed(new_it: Node)
## Fires once, when this round's timer runs out -- every online match gets a
## real duration now (see server_match.gd's RANKED_ROUND_DURATION_SEC /
## CASUAL_ROUND_DURATION_SEC), ranked and casual alike, just with casual
## running longer. server_match.gd uses this as the hook to rank participants
## and report a result; `ranked` (see setup()) only gates whether that result
## actually gets reported to the relay for ELO.
signal round_ended

var participants: Array = []
var it_index: int = -1
var immunity_timer := 0.0
var _contact_timers := {} # "instance_id_a_instance_id_b" (a < b) -> seconds in continuous contact

var ranked := false
var round_timer := 0.0
var it_time := {} # participant instance_id -> accumulated seconds spent as "it"
var _round_over := false

func setup(all_participants: Array, initial_it_index: int, p_ranked: bool = false, p_round_duration: float = DEFAULT_ROUND_DURATION_SEC) -> void:
	participants = all_participants
	it_index = initial_it_index
	immunity_timer = IMMUNITY_TIME
	ranked = p_ranked
	round_timer = p_round_duration
	for p in participants:
		it_time[p.get_instance_id()] = 0.0
	_apply_it_color()
	it_changed.emit(get_it())

## Total time this participant has spent as "it" so far this round -- what a
## round's end-of-match placement is sorted by (least = best), and what the
## live in-match leaderboard (see net_game.gd) tracks too.
func get_it_time(p: Node) -> float:
	return it_time.get(p.get_instance_id(), 0.0)

func get_it() -> Node:
	if it_index < 0 or it_index >= participants.size():
		return null
	return participants[it_index]

func is_it(p: Node) -> bool:
	return p == get_it()

## Called when a participant leaves mid-match (e.g. a player disconnects).
## Keeps it_index pointing at the same logical "it" across the removal, or
## picks a new one (wrapping safely) if the removed participant was "it".
func remove_participant(p: Node) -> void:
	var idx := participants.find(p)
	if idx == -1:
		return
	var was_it := (idx == it_index)
	participants.remove_at(idx)
	var removed_id := p.get_instance_id()
	for key in _contact_timers.keys().duplicate():
		if str(removed_id) in String(key).split("_"):
			_contact_timers.erase(key)
	it_time.erase(removed_id)
	if participants.is_empty():
		it_index = -1
		return
	if was_it:
		it_index = idx % participants.size()
		immunity_timer = IMMUNITY_TIME
		_apply_it_color()
		it_changed.emit(get_it())
	elif idx < it_index:
		it_index -= 1

## What an NPC should move toward this decision: the nearest other
## participant if it's the one chasing, or the current "it" (to flee) if not.
func get_ai_target(requester: Node) -> Node:
	if is_it(requester):
		var nearest: Node = null
		var nearest_dist := INF
		for p in participants:
			if p == requester:
				continue
			var d: float = requester.global_position.distance_to(p.global_position)
			if d < nearest_dist:
				nearest_dist = d
				nearest = p
		return nearest
	return get_it()

func _physics_process(delta: float) -> void:
	immunity_timer = maxf(immunity_timer - delta, 0.0)
	_update_contact_repel(delta)
	var it := get_it()
	if it:
		it_time[it.get_instance_id()] = it_time.get(it.get_instance_id(), 0.0) + delta
	if not _round_over:
		round_timer = maxf(round_timer - delta, 0.0)
		if round_timer <= 0.0:
			_round_over = true
			round_ended.emit()
	if it == null or immunity_timer > 0.0:
		return
	for i in participants.size():
		var p = participants[i]
		# team == -1 (the default -- every non-team-playlist match) never
		# matches itself, so this is a no-op everywhere except a real team
		# playlist (see Player.team) where it blocks "it" from ever passing
		# to a teammate, only ever to an opposing-team player.
		if p == it or (it.team != -1 and p.team == it.team):
			continue
		if it.global_position.distance_to(p.global_position) < TAG_DISTANCE:
			it_index = i
			immunity_timer = IMMUNITY_TIME
			_apply_it_color()
			it_changed.emit(get_it())
			return

func _apply_it_color() -> void:
	var it := get_it()
	for p in participants:
		if p.has_method("set_tagged_it"):
			p.set_tagged_it(p == it)

func _pair_key(a: Node, b: Node) -> String:
	var ia := a.get_instance_id()
	var ib := b.get_instance_id()
	return "%d_%d" % [mini(ia, ib), maxi(ia, ib)]

func _is_colliding_with(a: Node, b: Node) -> bool:
	if not (a is CharacterBody2D):
		return false
	for i in a.get_slide_collision_count():
		if a.get_slide_collision(i).get_collider() == b:
			return true
	return false

## Tracks how long each pair of participants has been in continuous physical
## contact (run after Player.apply_input()/move_and_slide() for this tick,
## per server_match.gd's child order, so collision info here is fresh) and
## shoves them apart once that crosses REPEL_CONTACT_THRESHOLD_SEC.
func _update_contact_repel(delta: float) -> void:
	for i in participants.size():
		for j in range(i + 1, participants.size()):
			var a: Node2D = participants[i]
			var b: Node2D = participants[j]
			var key := _pair_key(a, b)
			if _is_colliding_with(a, b) or _is_colliding_with(b, a):
				var t: float = _contact_timers.get(key, 0.0) + delta
				if t >= REPEL_CONTACT_THRESHOLD_SEC:
					_repel(a, b)
					t = 0.0
				_contact_timers[key] = t
			else:
				_contact_timers.erase(key)

func _repel(a: Node2D, b: Node2D) -> void:
	var away: Vector2 = b.global_position - a.global_position
	if away.length() < 0.01:
		away = Vector2(1.0, 0.0) # degenerate case: exactly overlapping, pick an arbitrary direction
	away = away.normalized()
	if a.has_method("apply_repel"):
		a.apply_repel(-away)
	if b.has_method("apply_repel"):
		b.apply_repel(away)
