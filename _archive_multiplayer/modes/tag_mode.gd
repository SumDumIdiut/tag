extends RefCounted
class_name TagMode

# Server-authoritative FFA Tag: one player is "it" at a time; touching a
# non-immune player transfers "it" to them. Score = least cumulative time
# spent "it" over the round (a continuous stat, easier to reason about than
# raw tag counts, and the natural input to an ELO calc later).

const ROUND_DURATION := 120.0

signal tagged(old_it_peer_id: int, new_it_peer_id: int)
signal round_ended(results: Dictionary)

var round_active := false
var time_left := 0.0
var it_peer_id := -1
var time_as_it: Dictionary = {} # peer_id -> float seconds

var _players: Dictionary = {} # peer_id -> Player

func start_round(players: Dictionary) -> void:
	_players = players
	time_as_it.clear()
	for peer_id in _players.keys():
		time_as_it[peer_id] = 0.0
	var ids := _players.keys()
	it_peer_id = ids[randi() % ids.size()]
	for peer_id in _players.keys():
		_players[peer_id].set_it(peer_id == it_peer_id)
	time_left = ROUND_DURATION
	round_active = true

func register_player(peer_id: int, player: Player) -> void:
	_players[peer_id] = player
	if not time_as_it.has(peer_id):
		time_as_it[peer_id] = 0.0
	player.get_node("TagHitbox").body_entered.connect(
		func(body: Node) -> void: _on_tag_hitbox_body_entered(player, body)
	)

func unregister_player(peer_id: int) -> void:
	_players.erase(peer_id)
	time_as_it.erase(peer_id)
	if it_peer_id == peer_id and round_active:
		_pass_it_to_random_survivor()

func process_tick(delta: float) -> void:
	if not round_active:
		return
	time_left -= delta
	if it_peer_id != -1 and time_as_it.has(it_peer_id):
		time_as_it[it_peer_id] += delta
	if time_left <= 0.0:
		_end_round()

func _on_tag_hitbox_body_entered(owner_player: Player, other_body: Node) -> void:
	if not round_active:
		return
	if not owner_player.is_it:
		return
	if other_body == owner_player or not (other_body is Player):
		return
	var other: Player = other_body
	if not other.can_be_tagged():
		return
	owner_player.set_it(false)
	owner_player.grant_tag_immunity()
	other.set_it(true)
	var old_it := it_peer_id
	it_peer_id = other.peer_id
	tagged.emit(old_it, it_peer_id)

func _pass_it_to_random_survivor() -> void:
	if _players.is_empty():
		it_peer_id = -1
		round_active = false
		return
	var ids := _players.keys()
	var new_it: int = ids[randi() % ids.size()]
	for peer_id in _players.keys():
		_players[peer_id].set_it(peer_id == new_it)
	var old_it := it_peer_id
	it_peer_id = new_it
	tagged.emit(old_it, it_peer_id)

func _end_round() -> void:
	round_active = false
	round_ended.emit(time_as_it.duplicate())

func get_state() -> Dictionary:
	return {
		"time_left": time_left,
		"it_peer_id": it_peer_id,
		"round_active": round_active,
	}
