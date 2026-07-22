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
const NPC_SCENE := preload("res://npc/npc.tscn")
const ARENA_SCENE := preload("res://levels/tag_arena.tscn")
const LevelData := preload("res://levels/level_data.gd")
const LEVEL_DATA_URL := "https://codecade.co.za/tag/api/levels/data/%s"
const RANKED_LOOKUP_URL := "https://codecade.co.za/tag/api/ranked/%s"
const TICK_RATE := 1.0 / 60.0

## Fired once every ranked participant's elo/tier lookup has resolved (or
## failed) -- see _fill_ranked_stats().
signal _ranked_stats_fetched

const ROUND_DURATION_SEC := 180.0

var lobby_id: int
var ranked := false
var playlist_id := "" # set by network_manager.gd right after construction, "" for the legacy FFA pool
## Set by _init() from network_manager.gd's map-vote tally -- "" means "no
## one voted (or this lobby doesn't surface voting), fall back to this
## server process's own --level= default" (_network_manager.level_id),
## exactly today's pre-voting behavior. A real id here always wins even if
## the process itself was launched with a different --level=, since a vote
## is a live per-match choice, not a per-process constant.
var _level_id_override := ""
var _network_manager: Node
var _usernames := {} # peer_id -> String
var _color_ids := {} # peer_id -> String
var _client_ids := {} # peer_id -> String, server-side only -- never sent to clients
var _teams := {} # peer_id -> int, -1 if no team-mode playlist is active for this match
## Backfilled participants (see NetworkManager._on_bot_fill_timeout) --
## always a negative synthetic id, never a real connected peer. Keyed the
## same as every other peer_id -> X dict here so bots flow through the
## exact same roster/ranking/state-summary code real players do; only the
## couple of places that talk to an actual network connection (input
## application, the per-tick state-push RPC) need to check this and skip.
var _is_bot := {} # peer_id -> bool
var _skill_levels := {} # peer_id -> int, bots only (see npc.gd's skill_level)
var _players := {}   # peer_id -> Player
var _coalesced_input := {} # peer_id -> Dictionary, merged since the last tick
var _tag_mode: TagMode
var _arena: Node2D
var _tick := 0
# Throttles report_match_state_summary() (see NetworkManager) instead of
# running every physics tick -- the website's live match viewer doesn't
# need full 60Hz precision. Was 6 (10Hz); dialed back to 15 (4Hz) after
# noticeable real-gameplay input lag on a machine already busy hosting
# several matches -- watch.html now interpolates between updates on the
# client side regardless (see prevSnapshot/targetSnapshot there), so a
# lower report rate still reads as smooth motion; it just costs less
# main-thread work building/sending a summary on this process's own tick
# loop, on top of the real per-tick player-state RPCs that already happen
# at full 60Hz for actual connected players. RelayClient's own reporting
# timer runs at the same cadence.
const STATE_SUMMARY_INTERVAL_TICKS := 15
var _arena_bounds := {"size": Vector2.ZERO, "center": Vector2.ZERO}
## Set once by _finish_setup() and kept for the lifetime of the match --
## a late-joining spectator (see NetworkManager._server_register_spectator)
## needs this exact shape to send as its own "_client_match_started" payload,
## and unlike a lobby's `members` this never changes as players disconnect
## mid-match (matches roster.gd's read-only "who was originally in this").
var roster := {}

func _init(network_manager: Node, p_lobby_id: int, members: Dictionary, p_ranked: bool = false, p_level_id_override: String = "") -> void:
	_network_manager = network_manager
	lobby_id = p_lobby_id
	ranked = p_ranked
	_level_id_override = p_level_id_override
	for peer_id in members.keys():
		_usernames[peer_id] = members[peer_id].username
		_color_ids[peer_id] = members[peer_id].get("color_id", PlayerColors.DEFAULT_ID)
		_client_ids[peer_id] = members[peer_id].get("client_id", "")
		_teams[peer_id] = members[peer_id].get("team", -1)
		_is_bot[peer_id] = members[peer_id].get("is_bot", false)
		_skill_levels[peer_id] = members[peer_id].get("skill_level", 3)

func _ready() -> void:
	var level_id: String = _level_id_override if not _level_id_override.is_empty() else _network_manager.level_id
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
	_arena_bounds = _compute_arena_bounds_px()
	var spawn_points := _arena.get_node("SpawnPoints").get_children()
	spawn_points.shuffle()

	# Built once per match regardless of whether any bots actually joined --
	# cheap, and degrades gracefully to direct steering on a level with no
	# ai_waypoint markers (see WaypointGraph.next_hop), same as local play.
	var waypoint_graph := WaypointGraph.new()
	waypoint_graph.build(get_tree().get_nodes_in_group("ai_waypoint"))

	var participants: Array = []
	var i := 0
	for peer_id in _usernames.keys():
		var p: Player
		if _is_bot.get(peer_id, false):
			var npc: NPC = NPC_SCENE.instantiate()
			npc.skill_level = _skill_levels.get(peer_id, 3)
			npc.waypoint_graph = waypoint_graph
			p = npc
		else:
			p = PLAYER_SCENE.instantiate()
		add_child(p)
		p.global_position = spawn_points[i % spawn_points.size()].global_position
		p.team = _teams.get(peer_id, -1)
		_players[peer_id] = p
		participants.append(p)
		i += 1

	_tag_mode = TagMode.new()
	add_child(_tag_mode)
	_tag_mode.setup(participants, randi() % participants.size(), ranked, ROUND_DURATION_SEC)
	if ranked:
		_tag_mode.round_ended.connect(_on_round_ended)
	# NPC needs tag_mode to actually act (see npc.gd's _physics_process) --
	# only settable now that _tag_mode exists, which needs `participants`
	# fully built first, hence the separate pass instead of setting it in
	# the spawn loop above.
	for peer_id in _usernames.keys():
		if _is_bot.get(peer_id, false):
			(_players[peer_id] as NPC).tag_mode = _tag_mode

	for peer_id in _usernames.keys():
		roster[peer_id] = {
			"username": _usernames[peer_id], "color_id": _color_ids[peer_id],
			"team": _teams.get(peer_id, -1), "is_bot": _is_bot.get(peer_id, false),
		}
	# Simulation is already ticking (players spawned, TagMode running) by this
	# point -- only the client-facing "match started" notice waits on this, so
	# a slow/unreachable relay costs a brief extra beat before the VS screen
	# appears, never a stuck match.
	if ranked:
		await _fill_ranked_stats()
	_network_manager.notify_match_started(lobby_id, roster, _network_manager.level_id, playlist_id)

## Enriches each ranked participant's roster entry with their current elo/
## tier (see match_intro.gd's VS screen) -- looked up server-side by the
## already-private _client_ids, never sent to peers directly (client_id
## itself stays server-only, same as everywhere else in this file). Fires
## all lookups in parallel (one HTTPRequest each) rather than one after
## another, so N players costs roughly one round-trip, not N. A lookup that
## fails or times out just leaves that player's roster entry without
## elo/tier -- match_intro.gd falls back to an "Unranked" placeholder
## rather than blocking match start on the relay being briefly unreachable.
func _fill_ranked_stats() -> void:
	var pending_peers: Array = []
	for peer_id in _client_ids.keys():
		if not String(_client_ids[peer_id]).is_empty():
			pending_peers.append(peer_id)
	if pending_peers.is_empty():
		return
	# A 1-element Array, not a raw int -- GDScript lambdas capture outer LOCAL
	# variables by value, so `remaining -= 1` inside the closure below would
	# only ever decrement each lambda's own private copy, never a shared
	# counter -- meaning with 2+ pending peers, no closure's copy would ever
	# reach 0 and _ranked_stats_fetched would never emit. Array/Dictionary
	# *contents* mutate through the captured reference fine; only a direct
	# reassignment of the outer variable itself doesn't propagate.
	var remaining := [pending_peers.size()]
	for peer_id in pending_peers:
		var req := HTTPRequest.new()
		req.timeout = 3.0
		add_child(req)
		req.request_completed.connect(func(_result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray):
			req.queue_free()
			if response_code == 200:
				var parsed = JSON.parse_string(body.get_string_from_utf8())
				if typeof(parsed) == TYPE_DICTIONARY and parsed.has("elo") and roster.has(peer_id):
					roster[peer_id]["elo"] = int(parsed.elo)
					roster[peer_id]["tier"] = String(parsed.get("tier", "Bronze"))
			remaining[0] -= 1
			if remaining[0] <= 0:
				_ranked_stats_fetched.emit()
		)
		req.request(RANKED_LOOKUP_URL % String(_client_ids[peer_id]) + "?playlist=" + playlist_id.uri_encode())
	await _ranked_stats_fetched

## Fires once when a ranked round's timer runs out. Ranks every participant
## still in the match by least time spent as "it" (ascending -- lowest is
## best) and hands the result to NetworkManager, which reports it to the
## relay for ELO and tells every client the match is over.
func _on_round_ended() -> void:
	var has_teams := false
	for t in _teams.values():
		if t != -1:
			has_teams = true
			break
	var ranking := []
	if has_teams:
		_rank_by_team(ranking)
	else:
		_rank_individually(ranking)
	_network_manager.notify_match_ended(lobby_id, ranking)

## FFA path (no team-mode playlist active) -- ascending by it_time (least =
## best), peer_id as a deterministic tiebreak for the vanishingly rare
## exact-float tie.
func _rank_individually(ranking: Array) -> void:
	for peer_id in _players.keys():
		var p: Player = _players[peer_id]
		ranking.append({
			"peer_id": peer_id,
			"client_id": _client_ids.get(peer_id, ""),
			"username": _usernames.get(peer_id, "Player"),
			"it_time": _tag_mode.get_it_time(p),
		})
	ranking.sort_custom(func(a, b):
		if a.it_time == b.it_time:
			return a.peer_id < b.peer_id
		return a.it_time < b.it_time
	)
	for i in ranking.size():
		ranking[i]["place"] = i + 1

## Team-mode path -- teams are ranked by their combined it_time (least =
## best, same "least time spent as it wins" rule as FFA, just summed across
## teammates), and every member of a team shares that team's place.
func _rank_by_team(ranking: Array) -> void:
	var team_time := {} # team -> summed it_time
	var team_members := {} # team -> [peer_id, ...]
	for peer_id in _players.keys():
		var p: Player = _players[peer_id]
		var t: int = _teams.get(peer_id, -1)
		team_time[t] = team_time.get(t, 0.0) + _tag_mode.get_it_time(p)
		if not team_members.has(t):
			team_members[t] = []
		team_members[t].append(peer_id)

	var teams_sorted: Array = team_time.keys()
	teams_sorted.sort_custom(func(a, b):
		if team_time[a] == team_time[b]:
			return a < b
		return team_time[a] < team_time[b]
	)

	var place := 1
	for t in teams_sorted:
		for peer_id in team_members[t]:
			var p: Player = _players[peer_id]
			ranking.append({
				"peer_id": peer_id,
				"client_id": _client_ids.get(peer_id, ""),
				"username": _usernames.get(peer_id, "Player"),
				"it_time": _tag_mode.get_it_time(p),
				"place": place,
			})
		place += 1

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
	_color_ids.erase(peer_id)
	_coalesced_input.erase(peer_id)

func _physics_process(delta: float) -> void:
	if _players.is_empty():
		return
	_tick += 1
	for peer_id in _players.keys():
		if _is_bot.get(peer_id, false):
			# NPC drives its own movement via its own inherited
			# _physics_process (see npc.gd) -- it's a real node in this
			# scene tree, so Godot already calls that automatically every
			# physics frame. Calling apply_input() again here too would
			# double-apply input on top of what the NPC just fed itself.
			continue
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
		if _is_bot.get(peer_id, false):
			continue # no real connection behind a bot's synthetic id to push an RPC to
		_network_manager.push_match_state(peer_id, _tick, states)
	# Read-only watchers (see NetworkManager._server_register_spectator) get
	# the exact same states dict, unmodified -- there's no receive_input path
	# wired to a spectator's peer_id at all, so they can render everything
	# but never act on it.
	for spectator_peer_id in _network_manager.get_spectators(lobby_id):
		_network_manager.push_match_state(spectator_peer_id, _tick, states)

	if _tick % STATE_SUMMARY_INTERVAL_TICKS == 0:
		_report_state_summary()

## A JSON-safe, much-smaller echo of `states` above -- position/is_it per
## player plus the round timer, keyed by the stable client_id (not peer_id,
## which means nothing outside this process) so the website can label
## players consistently. See NetworkManager.report_match_state_summary and
## RelayClient's own reporting timer for where this actually goes.
func _report_state_summary() -> void:
	var players := []
	for peer_id in _players.keys():
		var p: Player = _players[peer_id]
		players.append({
			"clientId": _client_ids.get(peer_id, ""),
			"username": _usernames.get(peer_id, "Player"),
			"x": p.global_position.x,
			"y": p.global_position.y,
			"isIt": _tag_mode.is_it(p),
			"colorId": _color_ids.get(peer_id, PlayerColors.DEFAULT_ID),
			"facing": p.facing,
		})
	_network_manager.report_match_state_summary(lobby_id, {
		"players": players,
		"timeRemaining": _tag_mode.round_timer,
		"arenaWidth": _arena_bounds.size.x,
		"arenaHeight": _arena_bounds.size.y,
		"arenaCenterX": _arena_bounds.center.x,
		"arenaCenterY": _arena_bounds.center.y,
		# "" means the built-in default arena (watch.html's default_arena.json,
		# see tools/export_default_arena.gd) -- otherwise this is a real level
		# id the website can fetch the exact same JSON for via the existing
		# public GET /api/levels/data/:id, no new endpoint needed.
		"levelId": _network_manager.level_id,
	})

## Mirrors tag_tileset.tres's texture_region_size (10x10) -- see
## build_tileset.gd's TILE_SIZE, the source of truth for this value.
const TILE_SIZE_PX := 10

## Tile-grid bounding box of whatever arena actually got built (built-in or
## a fetched custom level, see _finish_setup/_fetch_custom_arena above),
## converted to pixels -- the website's live match viewer (watch.html)
## needs this once, up front, to size its canvas/scale player positions
## correctly, since a custom level's dimensions aren't known ahead of time.
## Returns {size, center} in world pixels -- center matters just as much as
## size here: tile cell (0,0) is NOT necessarily world-pixel (0,0) (the
## arena's tile bounding box isn't guaranteed centered on the origin), but
## Player.global_position IS reported in that same world-pixel space, so
## the website needs the bounding box's real center to align tiles and
## player dots in one consistent frame instead of assuming they share an
## origin they might not.
func _compute_arena_bounds_px() -> Dictionary:
	var tiles: TileMapLayer = _arena.get_node_or_null("Tiles")
	if not tiles:
		return {"size": Vector2.ZERO, "center": Vector2.ZERO}
	var used_rect := tiles.get_used_rect()
	var size_px := Vector2(used_rect.size) * TILE_SIZE_PX
	var center_px := (Vector2(used_rect.position) * TILE_SIZE_PX) + size_px * 0.5
	return {"size": size_px, "center": center_px}

func teardown() -> void:
	_network_manager.clear_match_state_summary(lobby_id)
	queue_free()
