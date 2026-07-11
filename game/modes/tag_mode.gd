extends Node
class_name TagMode

const IMMUNITY_TIME := 1.0
const TAG_DISTANCE := 40.0

signal it_changed(new_it: Node)

var participants: Array = []
var it_index: int = -1
var immunity_timer := 0.0

func setup(all_participants: Array, initial_it_index: int) -> void:
	participants = all_participants
	it_index = initial_it_index
	immunity_timer = IMMUNITY_TIME
	_apply_it_color()
	it_changed.emit(get_it())

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
	var it := get_it()
	if it == null or immunity_timer > 0.0:
		return
	for i in participants.size():
		var p = participants[i]
		if p == it:
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
