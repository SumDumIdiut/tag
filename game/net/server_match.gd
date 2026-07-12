extends Node
class_name ServerMatch

# The authoritative simulation for one lobby's match. Reuses the exact same
# Player movement script and TagMode logic as local/singleplayer play --
# same reasoning as the very first architecture decision on this project:
# one shared movement script means client prediction can never silently
# drift from what the server actually simulates.

const PLAYER_SCENE := preload("res://player/player.tscn")
const ARENA_SCENE := preload("res://levels/tag_arena.tscn")
const TICK_RATE := 1.0 / 60.0

var lobby_id: int
var _network_manager: Node
var _usernames := {} # peer_id -> String
var _players := {}   # peer_id -> Player
var _pending_input := {} # peer_id -> Dictionary
var _tag_mode: TagMode
var _arena: Node2D
var _tick := 0

func _init(network_manager: Node, p_lobby_id: int, members: Dictionary) -> void:
	_network_manager = network_manager
	lobby_id = p_lobby_id
	for peer_id in members.keys():
		_usernames[peer_id] = members[peer_id].username

func _ready() -> void:
	_arena = ARENA_SCENE.instantiate()
	add_child(_arena)
	var spawn_points := _arena.get_node("SpawnPoints").get_children()
	spawn_points.shuffle()

	var participants: Array = []
	var i := 0
	for peer_id in _usernames.keys():
		var p: Player = PLAYER_SCENE.instantiate()
		add_child(p)
		p.global_position = spawn_points[i % spawn_points.size()].global_position
		_players[peer_id] = p
		participants.append(p)
		i += 1

	_tag_mode = TagMode.new()
	add_child(_tag_mode)
	_tag_mode.setup(participants, randi() % participants.size())

	_network_manager.notify_match_started(lobby_id, _usernames)

func receive_input(peer_id: int, input: Dictionary) -> void:
	_pending_input[peer_id] = input

## Called by NetworkManager when a player disconnects mid-match. Without
## this, _physics_process below kept pushing match-state RPCs to the
## disconnected peer_id forever (there was nothing to ever stop it) --
## visible as a continuous stream of "ready_state != STATE_OPEN" send
## errors in the server log for the rest of the match.
func remove_peer(peer_id: int) -> void:
	if not _players.has(peer_id):
		return
	var p: Player = _players[peer_id]
	if _tag_mode:
		_tag_mode.remove_participant(p)
	p.queue_free()
	_players.erase(peer_id)
	_usernames.erase(peer_id)
	_pending_input.erase(peer_id)

func _physics_process(delta: float) -> void:
	if _players.is_empty():
		return
	_tick += 1
	for peer_id in _players.keys():
		var input: Dictionary = _pending_input.get(peer_id, {})
		_players[peer_id].apply_input(input, delta)

	var states := {}
	for peer_id in _players.keys():
		var p: Player = _players[peer_id]
		# input_tick lets each client know which of its own already-predicted
		# inputs this state reflects, so it can discard everything up to that
		# point and replay only what's newer instead of hard-snapping. 0 is a
		# safe "nothing acked yet" sentinel -- client ticks start at 1.
		states[peer_id] = {
			"pos": p.global_position,
			"vel": p.velocity,
			"facing": p.facing,
			"is_dashing": p.is_dashing,
			"is_climbing": p.is_climbing,
			"is_it": _tag_mode.is_it(p),
			"input_tick": int(_pending_input.get(peer_id, {}).get("tick", 0)),
		}
	for peer_id in _players.keys():
		_network_manager.push_match_state(peer_id, _tick, states)

func teardown() -> void:
	queue_free()
