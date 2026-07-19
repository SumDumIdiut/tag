extends Node
class_name ServerMatch

# The authoritative simulation for one lobby's match. Reuses the exact same
# Player movement script and TagMode logic as local/singleplayer play, so
# there's one movement implementation, not a server copy plus a separately-
# maintained client one. Clients never simulate movement themselves at all
# (see net_game.gd) -- every peer, their own included, is rendered purely
# from this simulation's confirmed state, interpolated for smoothness. That
# trades instant local responsiveness for input lag equal to round-trip
# time, in exchange for the render never needing a correction/snap.

const PLAYER_SCENE := preload("res://player/player.tscn")
const ARENA_SCENE := preload("res://levels/tag_arena.tscn")
const LevelData := preload("res://levels/level_data.gd")
const LEVEL_DATA_URL := "https://codecade.co.za/tag/api/levels/data/%s"
const TICK_RATE := 1.0 / 60.0

const ROUND_DURATION_SEC := 180.0

var lobby_id: int
var ranked := false
var _network_manager: Node
var _usernames := {} # peer_id -> String
var _skin_ids := {}  # peer_id -> String
var _client_ids := {} # peer_id -> String, server-side only -- never sent to clients
var _players := {}   # peer_id -> Player
var _coalesced_input := {} # peer_id -> Dictionary, merged since the last tick
var _tag_mode: TagMode
var _arena: Node2D
var _tick := 0
## Set once by _finish_setup() and kept for the lifetime of the match --
## a late-joining spectator (see NetworkManager._server_register_spectator)
## needs this exact shape to send as its own "_client_match_started" payload,
## and unlike a lobby's `members` this never changes as players disconnect
## mid-match (matches roster.gd's read-only "who was originally in this").
var roster := {}

func _init(network_manager: Node, p_lobby_id: int, members: Dictionary, p_ranked: bool = false) -> void:
	_network_manager = network_manager
	lobby_id = p_lobby_id
	ranked = p_ranked
	for peer_id in members.keys():
		_usernames[peer_id] = members[peer_id].username
		_skin_ids[peer_id] = members[peer_id].get("skin_id", "red")
		_client_ids[peer_id] = members[peer_id].get("client_id", "")

func _ready() -> void:
	var level_id: String = _network_manager.level_id
	if level_id.is_empty():
		_arena = ARENA_SCENE.instantiate()
		add_child(_arena)
		_finish_setup()
	else:
		_fetch_custom_arena(level_id)

## Fetches this server process's chosen custom level from the relay and
## builds it via LevelData -- same JSON every client independently fetches
## for rendering (see net_game.gd), so both sides simulate/render identical
## geometry. Falls back to the built-in arena on any fetch/parse/validation
## failure so a bad or unreachable custom level can never stop a match from
## starting at all.
func _fetch_custom_arena(id: String) -> void:
	var req := HTTPRequest.new()
	add_child(req)
	req.request_completed.connect(func(_result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray):
		req.queue_free()
		var built: Node2D = null
		if response_code == 200:
			var parsed = JSON.parse_string(body.get_string_from_utf8())
			if typeof(parsed) == TYPE_DICTIONARY and LevelData.is_valid(parsed):
				built = LevelData.build_arena_from_data(parsed)
		_arena = built if built != null else ARENA_SCENE.instantiate()
		add_child(_arena)
		_finish_setup()
	)
	req.request(LEVEL_DATA_URL % id)

func _finish_setup() -> void:
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
	_tag_mode.setup(participants, randi() % participants.size(), ranked, ROUND_DURATION_SEC)
	if ranked:
		_tag_mode.round_ended.connect(_on_round_ended)

	for peer_id in _usernames.keys():
		roster[peer_id] = {"username": _usernames[peer_id], "skin_id": _skin_ids[peer_id]}
	_network_manager.notify_match_started(lobby_id, roster, _network_manager.level_id)

## Fires once when a ranked round's timer runs out. Ranks every participant
## still in the match by least time spent as "it" (ascending -- lowest is
## best) and hands the result to NetworkManager, which reports it to the
## relay for ELO and tells every client the match is over.
func _on_round_ended() -> void:
	var ranking := []
	for peer_id in _players.keys():
		var p: Player = _players[peer_id]
		ranking.append({
			"peer_id": peer_id,
			"client_id": _client_ids.get(peer_id, ""),
			"username": _usernames.get(peer_id, "Player"),
			"it_time": _tag_mode.get_it_time(p),
		})
	# Ascending by it_time (least = best); peer_id as a deterministic
	# tiebreak for the vanishingly rare exact-float tie.
	ranking.sort_custom(func(a, b):
		if a.it_time == b.it_time:
			return a.peer_id < b.peer_id
		return a.it_time < b.it_time
	)
	for i in ranking.size():
		ranking[i]["place"] = i + 1
	_network_manager.notify_match_ended(lobby_id, ranking)

func receive_input(peer_id: int, input: Dictionary) -> void:
	# Coalesce everything received since the last tick into one effective
	# input, rather than either extreme: overwriting outright (a burst of
	# several inputs arriving between two server ticks -- real under
	# WebSocket/TCP head-of-line blocking, which can stall delivery then
	# flush several at once even with nothing truly dropped -- would
	# silently discard every EDGE-TRIGGERED press but the last, so a
	# queued jump_pressed=true that gets overtaken by a newer packet
	# before this tick just never fires) or queuing-and-draining-one-per-
	# tick (tried this; it falls permanently behind under any sustained
	# rate mismatch between arrival and physics tick rate, which real
	# relay-path jitter reliably produces -- measured worse, not better,
	# via the bot harness). Continuous fields (move_dir, jump_held,
	# climb_held) take the latest value, so the server is never processing
	# stale-by-many-ticks state. Edge-triggered ones (jump_pressed/
	# dash_pressed) OR together everything received since the last tick,
	# so a press that arrived and got overtaken still fires exactly once
	# when this tick consumes it.
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
	_skin_ids.erase(peer_id)
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

	# Every client renders every player -- their own included -- purely from
	# this confirmed state via RemoteAvatar's dead-reckoning interpolation,
	# with no local prediction/reconciliation involved at all, so one
	# shared, lightweight state dict for everyone is all any client ever
	# needs (no more per-peer full snapshot/input_tick for replay).
	var states := {}
	for peer_id in _players.keys():
		var p: Player = _players[peer_id]
		states[peer_id] = {
			"pos": p.global_position,
			"vel": p.velocity,
			"facing": p.facing,
			"is_dashing": p.is_dashing,
			"is_climbing": p.is_climbing,
			"on_floor": p.is_on_floor(),
			"action": p.current_action,
			"action_id": p.current_action_id,
			"is_it": _tag_mode.is_it(p),
		}
	for peer_id in _players.keys():
		_network_manager.push_match_state(peer_id, _tick, states)
	# Read-only watchers (see NetworkManager._server_register_spectator) get
	# the exact same states dict, unmodified -- there's no receive_input path
	# wired to a spectator's peer_id at all, so they can render everything
	# but never act on it.
	for spectator_peer_id in _network_manager.get_spectators(lobby_id):
		_network_manager.push_match_state(spectator_peer_id, _tick, states)

func teardown() -> void:
	queue_free()
