extends Node
class_name TagMode

const IMMUNITY_TIME := 1.0
const TAG_DISTANCE := 40.0

const DEFAULT_ROUND_DURATION_SEC := 180.0

## Fires whenever a team-bucket's "it" changes -- `team` is whichever bucket
## changed (see _it_by_team below). server_match.gd never listens to this
## directly (every player's own is_it is read fresh off is_it() each tick
## regardless); it's for a local-play HUD (game.gd) and this file's own
## _apply_it_color().
signal it_changed(new_it: Node, team: int)
## Fires once, when this round's timer runs out -- every online match gets a
## real duration now (see server_match.gd's RANKED_ROUND_DURATION_SEC /
## CASUAL_ROUND_DURATION_SEC), ranked and casual alike, just with casual
## running longer. server_match.gd uses this as the hook to rank participants
## and report a result; `ranked` (see setup()) only gates whether that result
## actually gets reported to the relay for ELO.
signal round_ended

var participants: Array = []
## team (int) -> the participant currently "it" for that team-bucket. A real
## team-mode playlist (2v2) gets one independent it per side -- tagging stays
## cross-team only (see _physics_process below), so a side's own it changes
## only when the OPPOSING side's it tags one of their players, never their
## own. An FFA match (1v1/1v1v1/1v1v1v1) has every participant sharing
## team == -1, so this collapses to exactly one bucket -- the single shared
## it it's always been, unchanged in effect.
var _it_by_team: Dictionary = {}
var _immunity_timers: Dictionary = {} # team -> remaining seconds before that bucket's it can change again

var ranked := false
var round_timer := 0.0
var it_time := {} # participant instance_id -> accumulated seconds spent as "it"
var _round_over := false

## `initial_it_index` seeds one team-bucket's starting it (whichever team
## that participant is on) exactly like the old single-it version did; any
## OTHER team-bucket a real team playlist has picks its own random starting
## it independently, so every side still starts genuinely random, not just
## "first in the roster."
func setup(all_participants: Array, initial_it_index: int, p_ranked: bool = false, p_round_duration: float = DEFAULT_ROUND_DURATION_SEC) -> void:
	participants = all_participants
	ranked = p_ranked
	round_timer = p_round_duration
	for p in participants:
		it_time[p.get_instance_id()] = 0.0

	var by_team: Dictionary = {}
	for p in participants:
		var team: int = p.team
		if not by_team.has(team):
			by_team[team] = []
		by_team[team].append(p)
	for team in by_team.keys():
		var members: Array = by_team[team]
		_it_by_team[team] = members[randi() % members.size()]
	var seed_p: Node = participants[initial_it_index] if initial_it_index >= 0 and initial_it_index < participants.size() else null
	if seed_p:
		_it_by_team[seed_p.team] = seed_p
	# Brief grace period before any bucket's first tag can land, same as the
	# single-it version always gave -- otherwise a match could open with an
	# instant tag before anyone's even had a chance to move.
	for team in _it_by_team.keys():
		_immunity_timers[team] = IMMUNITY_TIME

	_apply_it_color()
	for team in _it_by_team.keys():
		it_changed.emit(_it_by_team[team], team)

## Total time this participant has spent as "it" so far this round -- what a
## round's end-of-match placement is sorted by (least = best), and what the
## live in-match leaderboard (see net_game.gd) tracks too.
func get_it_time(p: Node) -> float:
	return it_time.get(p.get_instance_id(), 0.0)

## The current it for one specific team-bucket -- an FFA match's shared
## bucket is keyed -1, same as every participant's own .team there.
func get_it_for_team(team: int) -> Node:
	return _it_by_team.get(team, null)

## Every currently-active it, one per team-bucket (just the one shared it
## for an FFA match).
func get_its() -> Array:
	return _it_by_team.values()

func is_it(p: Node) -> bool:
	return _it_by_team.get(p.team, null) == p

## Called when a participant leaves mid-match (e.g. a player disconnects).
func remove_participant(p: Node) -> void:
	var idx := participants.find(p)
	if idx == -1:
		return
	var p_team: int = p.team
	var was_it: bool = _it_by_team.get(p_team, null) == p
	participants.remove_at(idx)
	var removed_id := p.get_instance_id()
	it_time.erase(removed_id)
	if not was_it:
		return
	# Someone else still on p's own team inherits "it," if anyone's left
	# there; otherwise that whole team-bucket is gone (a side wiped out
	# entirely -- degenerate, but shouldn't crash the other side's own
	# independent bucket).
	var replacement: Node = null
	for other in participants:
		if other.team == p_team:
			replacement = other
			break
	if replacement == null:
		_it_by_team.erase(p_team)
		_immunity_timers.erase(p_team)
		return
	_it_by_team[p_team] = replacement
	_immunity_timers[p_team] = IMMUNITY_TIME
	_apply_it_color()
	it_changed.emit(replacement, p_team)

## What an NPC should move toward this decision: if it's the one chasing,
## the nearest OPPOSING participant (own teammates can never be tagged, so
## never worth chasing); otherwise, whichever it-holder can actually tag
## this participant -- the nearest one on a different team, never its own
## side's it (a teammate's own it status is no threat to them at all).
func get_ai_target(requester: Node) -> Node:
	if is_it(requester):
		var nearest: Node = null
		var nearest_dist := INF
		for p in participants:
			if p == requester or (requester.team != -1 and p.team == requester.team):
				continue
			var d: float = requester.global_position.distance_to(p.global_position)
			if d < nearest_dist:
				nearest_dist = d
				nearest = p
		return nearest
	var nearest_it: Node = null
	var nearest_it_dist := INF
	for team in _it_by_team.keys():
		if requester.team != -1 and team == requester.team:
			continue
		var candidate: Node = _it_by_team[team]
		if candidate == null or candidate == requester:
			continue
		var d: float = requester.global_position.distance_to(candidate.global_position)
		if d < nearest_it_dist:
			nearest_it_dist = d
			nearest_it = candidate
	return nearest_it

func _physics_process(delta: float) -> void:
	for team in _immunity_timers.keys():
		_immunity_timers[team] = maxf(_immunity_timers[team] - delta, 0.0)
	for team in _it_by_team.keys():
		var it: Node = _it_by_team[team]
		if it:
			it_time[it.get_instance_id()] = it_time.get(it.get_instance_id(), 0.0) + delta
	if not _round_over:
		round_timer = maxf(round_timer - delta, 0.0)
		if round_timer <= 0.0:
			_round_over = true
			round_ended.emit()

	# Each team-bucket's it independently checks for a tag this tick --
	# tagging someone only ever changes THAT tagged player's own team-bucket
	# (see the top-level doc comment), never the tagging it's own, so the
	# buckets never interfere with each other within the same tick even
	# when a tag happens on one of them.
	for team in _it_by_team.keys():
		if _immunity_timers.get(team, 0.0) > 0.0:
			continue
		var it: Node = _it_by_team[team]
		if it == null:
			continue
		for p in participants:
			# team == -1 (the default -- every non-team-playlist match) never
			# matches itself, so this is a no-op everywhere except a real team
			# playlist (see Player.team) where it blocks "it" from ever passing
			# to a teammate, only ever to an opposing-team player.
			if p == it or (it.team != -1 and p.team == it.team):
				continue
			if it.global_position.distance_to(p.global_position) < TAG_DISTANCE:
				_it_by_team[p.team] = p
				_immunity_timers[p.team] = IMMUNITY_TIME
				_apply_it_color()
				it_changed.emit(p, p.team)
				break

func _apply_it_color() -> void:
	for p in participants:
		if p.has_method("set_tagged_it"):
			p.set_tagged_it(is_it(p))
