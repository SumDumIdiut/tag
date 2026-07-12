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
var _coalesced_input := {} # peer_id -> Dictionary, merged since the last tick
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
	# Coalesce everything received since the last tick into one effective
	# input, rather than either extreme: overwriting outright (a burst of
	# several inputs arriving between two server ticks -- real under
	# WebSocket/TCP head-of-line blocking, which can stall delivery then
	# flush several at once even with nothing truly dropped -- would
	# silently discard every EDGE-TRIGGERED press but the last, so a
	# queued jump_pressed=true that gets overtaken by a newer packet
	# before this tick just never fires, even though the client predicted
	# and replayed it) or queuing-and-draining-one-per-tick (tried this;
	# it falls permanently behind under any sustained rate mismatch
	# between arrival and physics tick rate, which real relay-path jitter
	# reliably produces -- measured worse, not better, via the bot harness).
	# Continuous fields (move_dir, jump_held, climb_held, tick) take the
	# latest value, so the server is never processing stale-by-many-ticks
	# state. Edge-triggered ones (jump_pressed/dash_pressed) OR together
	# everything received since the last tick, so a press that arrived
	# and got overtaken still fires exactly once when this tick consumes it.
	if not _coalesced_input.has(peer_id):
		_coalesced_input[peer_id] = {}
	var merged: Dictionary = _coalesced_input[peer_id]
	for key in input.keys():
		if key == "jump_pressed" or key == "dash_pressed":
			merged[key] = merged.get(key, false) or input[key]
		else:
			merged[key] = input[key]

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
	_coalesced_input.erase(peer_id)

func _physics_process(delta: float) -> void:
	if _players.is_empty():
		return
	_tick += 1
	for peer_id in _players.keys():
		var input: Dictionary = _coalesced_input.get(peer_id, {})
		_players[peer_id].apply_input(input, delta)
		# Edge-triggered flags mean "this was just pressed" and must fire
		# exactly once. Clear them after use so if nothing new arrives
		# before the next tick, this same dict being reused verbatim can't
		# replay a jump/dash a second time -- a phantom repeat the client
		# never intended, and a genuine divergence in the server's own
		# authoritative simulation that client-side replay can't paper
		# over, since the server itself did something the client never
		# asked for.
		if input.has("jump_pressed"):
			input["jump_pressed"] = false
		if input.has("dash_pressed"):
			input["dash_pressed"] = false

	# Lightweight state for rendering everyone else's avatar -- this is all
	# remote_avatar.gd ever reads, no need to pay for the full snapshot below
	# on every peer's view of every OTHER peer, just their own.
	var light_states := {}
	for peer_id in _players.keys():
		var p: Player = _players[peer_id]
		light_states[peer_id] = {
			"pos": p.global_position,
			"vel": p.velocity,
			"facing": p.facing,
			"is_dashing": p.is_dashing,
			"is_climbing": p.is_climbing,
			"is_it": _tag_mode.is_it(p),
		}

	for peer_id in _players.keys():
		# Each peer's OWN entry gets swapped for a full physics-state
		# snapshot instead of the lightweight fields above, plus input_tick
		# so the client knows which of its own already-predicted inputs this
		# reflects and can replay just what's newer instead of hard-
		# snapping. Reconciliation needs the complete internal state (see
		# Player.get_state_snapshot()), not just position/velocity, or
		# replaying an edge-triggered input like a jump press can re-trigger
		# it instead of correctly continuing past it. 0 is a safe "nothing
		# acked yet" sentinel -- client ticks start at 1.
		var states := light_states.duplicate()
		var p: Player = _players[peer_id]
		var full: Dictionary = p.get_state_snapshot()
		full["is_it"] = _tag_mode.is_it(p)
		full["input_tick"] = int(_coalesced_input.get(peer_id, {}).get("tick", 0))
		states[peer_id] = full
		_network_manager.push_match_state(peer_id, _tick, states)

func teardown() -> void:
	queue_free()
