extends Node

# Central networking hub, present identically on every peer (autoload path
# "/root/NetworkManager" always matches, which is what makes calling rpc()/
# rpc_id() on this node work without any per-scene node-path juggling).
# The server is always peer id 1 and is fully authoritative: it owns lobby
# state and runs every active match's simulation; clients only ever request
# things and render what the server tells them.

signal lobby_list_updated(lobbies: Array)
signal lobby_state_updated(lobby: Dictionary)
signal match_started(lobby_id: int, my_peer_id: int, roster: Dictionary, level_id: String)
signal match_state_received(tick: int, states: Dictionary)
## Fires once on every peer when a ranked round's timer runs out. `ranking`
## is [{peer_id, username, it_time, place}], sorted best (place 1) first.
signal match_ended(ranking: Array)
signal connected_to_server
signal connection_failed
signal disconnected_from_server
## Fires on a peer once the server relays a lobby chat message -- see
## send_chat_message()/lobby_room.gd. Lobby-only by design (not in-match),
## to keep the tight tag-gameplay netcode path untouched by this.
signal chat_message_received(username: String, text: String)
## Fires on a peer that tried start_spectator() when no match is currently
## in progress on that server to watch.
signal spectate_failed

const DEFAULT_PORT := 9000
const MAX_LOBBY_PLAYERS := 8
const MIN_RANKED_PLAYERS := 2
const RANKED_REPORT_URL := "https://codecade.co.za/tag/api/ranked/report-result"
const MAX_CHAT_MESSAGE_LEN := 200

var is_server := false
var is_ranked_server := false # set by server_main.gd from --ranked; auto-lobbies/starts ranked rounds instead of waiting for manual create/join/Start
var level_id := "" # set by server_main.gd from --level=<id>; "" means the built-in default arena, applies to every lobby this server process hosts
var username := "Player"
var my_peer_id := -1
var current_lobby: Dictionary = {}

# ---- Server-side state only ----
var _lobbies := {}       # lobby_id -> {id, name, host_peer, max_players, members: {peer_id: {username, ready}}, in_match, ranked}
var _next_lobby_id := 1
var _ranked_lobby_id := -1 # the single reserved lobby a ranked server auto-fills, recreated after each round
var _peer_username := {} # peer_id -> String
var _peer_skin_id := {}  # peer_id -> String
var _peer_hat_id := {}   # peer_id -> String, "" means no hat
var _peer_trail_id := {} # peer_id -> String, "" means no trail
var _peer_client_id := {} # peer_id -> String, the anonymous cosmetics/ranked identity -- server-side only, never broadcast to other clients
var _peer_lobby := {}    # peer_id -> lobby_id
var _matches := {}       # lobby_id -> ServerMatch
var _spectators := {}    # lobby_id -> Array[peer_id], read-only observers of an in-progress match
var _peer_spectating_lobby := {} # peer_id -> lobby_id, for disconnect cleanup

# ---- Client-side state only ----
var _pending_as_spectator := false # set by start_spectator(), consumed by _on_connected_to_server()

func _ready() -> void:
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.connected_to_server.connect(_on_connected_to_server)
	multiplayer.connection_failed.connect(_on_connection_failed)
	multiplayer.server_disconnected.connect(_on_server_disconnected)

func is_online() -> bool:
	return multiplayer.multiplayer_peer != null \
		and multiplayer.multiplayer_peer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED

## Used by RelayClient to report live player counts in its heartbeat. The
## dedicated server never plays (peer 1 is a non-participating authority), so
## get_peers() -- which already excludes the local id -- is the full count.
func get_player_count() -> int:
	if not is_server:
		return 0
	return multiplayer.get_peers().size()

## Used by RelayClient to report which players are currently connected in
## its heartbeat, so the relay's server directory can answer "is my friend
## online, and where" (see relay-server/server.js's friends endpoints) --
## the only other consumer of _peer_client_id besides ServerMatch's own
## per-match roster, and same "server-side only" scope: this never reaches
## other players directly, only the relay's aggregate directory.
func get_connected_client_ids() -> Array:
	if not is_server:
		return []
	return _peer_client_id.values()

## Called by ServerMatch every physics tick to also push state to anyone
## watching lobby_id's match read-only (see _server_register_spectator).
func get_spectators(lobby_id: int) -> Array:
	if not is_server:
		return []
	return _spectators.get(lobby_id, [])

## WebSockets (not ENet/raw UDP) specifically because this needs to be
## reachable through a Cloudflare Tunnel -- Cloudflare's edge can proxy a
## WebSocket connection to an arbitrary public hostname, but can't carry
## raw UDP traffic to random internet players without them running
## Cloudflare WARP. WebSocketMultiplayerPeer implements the same
## MultiplayerPeer interface ENetMultiplayerPeer did, so none of the RPC/
## lobby/match code above needed to change -- only how the peer is created.
func start_server(port: int = DEFAULT_PORT) -> bool:
	var peer := WebSocketMultiplayerPeer.new()
	var err := peer.create_server(port)
	if err != OK:
		push_error("NetworkManager: failed to start server on port %d (%s)" % [port, err])
		return false
	multiplayer.multiplayer_peer = peer
	is_server = true
	my_peer_id = 1
	print("NetworkManager: server listening on port %d" % port)
	return true

## `address` accepts either a bare host[:port] (assumed ws://, for local
## testing) or a full ws://.../wss://... URL (for connecting through the
## Cloudflare Tunnel's public hostname, which terminates TLS at Cloudflare's
## edge -- the local server itself still only ever speaks plain ws://).
func start_client(address: String, display_name: String) -> void:
	username = display_name
	is_server = false
	_pending_as_spectator = false
	var url := _normalize_address(address)
	var peer := WebSocketMultiplayerPeer.new()
	var err := peer.create_client(url)
	if err != OK:
		push_error("NetworkManager: failed to create client peer (%s)" % err)
		connection_failed.emit()
		return
	multiplayer.multiplayer_peer = peer

## Connects the same way start_client() does, but registers as a read-only
## spectator instead of a simulated player once connected (see
## _on_connected_to_server()) -- never sends input, never occupies a Player
## slot. Attaches to whichever match on this server is currently in
## progress; emits spectate_failed if none is.
func start_spectator(address: String) -> void:
	is_server = false
	_pending_as_spectator = true
	var url := _normalize_address(address)
	var peer := WebSocketMultiplayerPeer.new()
	var err := peer.create_client(url)
	if err != OK:
		push_error("NetworkManager: failed to create client peer (%s)" % err)
		_pending_as_spectator = false
		connection_failed.emit()
		return
	multiplayer.multiplayer_peer = peer

func _normalize_address(address: String) -> String:
	var trimmed := address.strip_edges()
	if trimmed.begins_with("ws://") or trimmed.begins_with("wss://"):
		return trimmed
	return "ws://%s" % trimmed

func disconnect_from_server() -> void:
	if multiplayer.multiplayer_peer:
		multiplayer.multiplayer_peer.close()
	multiplayer.multiplayer_peer = null
	is_server = false
	my_peer_id = -1
	current_lobby = {}

func _on_connected_to_server() -> void:
	my_peer_id = multiplayer.get_unique_id()
	if _pending_as_spectator:
		_pending_as_spectator = false
		rpc_id(1, "_server_register_spectator")
	else:
		rpc_id(1, "_server_register_player", username, SkinCatalog.selected_skin_id, SkinCatalog.selected_hat_id, SkinCatalog.selected_trail_id, SkinCatalog.client_id)
	connected_to_server.emit()

func _on_connection_failed() -> void:
	connection_failed.emit()

func _on_server_disconnected() -> void:
	disconnected_from_server.emit()

func _on_peer_disconnected(id: int) -> void:
	if not is_server:
		return
	_peer_username.erase(id)
	_peer_skin_id.erase(id)
	_peer_hat_id.erase(id)
	_peer_trail_id.erase(id)
	_peer_client_id.erase(id)
	var lobby_id: int = _peer_lobby.get(id, -1)
	if lobby_id != -1:
		_remove_peer_from_lobby(id, lobby_id)
	_peer_lobby.erase(id)
	var spectating_lobby_id: int = _peer_spectating_lobby.get(id, -1)
	if spectating_lobby_id != -1 and _spectators.has(spectating_lobby_id):
		_spectators[spectating_lobby_id].erase(id)
	_peer_spectating_lobby.erase(id)

# ==================== Server-side RPC endpoints (client -> server) ====================

@rpc("any_peer", "reliable")
func _server_register_player(display_name: String, skin_id: String, hat_id: String = "", trail_id: String = "", client_id: String = "") -> void:
	if not is_server:
		return
	var sender := multiplayer.get_remote_sender_id()
	_peer_username[sender] = _sanitize_username(display_name)
	# Just the ids -- a custom skin/hat/trail's actual image lives on the
	# cosmetics service (codecade.co.za/tag/api/skins, /api/hats, /api/trails),
	# not here, so any client that needs to render it (see roster's skin_id/
	# hat_id/trail_id in match state) fetches it directly from there itself
	# instead of relying on peer-to-peer relay.
	_peer_skin_id[sender] = skin_id
	_peer_hat_id[sender] = hat_id
	_peer_trail_id[sender] = trail_id
	_peer_client_id[sender] = client_id
	if is_ranked_server:
		_join_ranked_lobby(sender)
	else:
		_send_lobby_list(sender)

## Attaches the sender to whichever lobby on this server currently has a
## match running -- there's no per-lobby "Watch" targeting from the server
## browser (it only knows about servers, not individual lobbies), so a
## spectator just gets whatever's live. Never touches _players/_peer_lobby;
## a spectator is not a lobby member and never becomes one.
@rpc("any_peer", "reliable")
func _server_register_spectator() -> void:
	if not is_server:
		return
	var sender := multiplayer.get_remote_sender_id()
	if _peer_lobby.has(sender) or _peer_spectating_lobby.has(sender):
		return
	var target_lobby_id := -1
	for lobby in _lobbies.values():
		if lobby.in_match:
			target_lobby_id = lobby.id
			break
	if target_lobby_id == -1 or not _matches.has(target_lobby_id):
		rpc_id(sender, "_client_spectate_failed")
		return
	var match_instance: ServerMatch = _matches[target_lobby_id]
	# roster is only populated once ServerMatch._finish_setup() completes --
	# briefly empty while a custom level is still being fetched (see
	# server_match.gd's _fetch_custom_arena). Reject rather than send a
	# match-started payload with no one in it; there's no second chance to
	# resend once this RPC has gone out.
	if match_instance.roster.is_empty():
		rpc_id(sender, "_client_spectate_failed")
		return
	if not _spectators.has(target_lobby_id):
		_spectators[target_lobby_id] = []
	_spectators[target_lobby_id].append(sender)
	_peer_spectating_lobby[sender] = target_lobby_id
	rpc_id(sender, "_client_match_started", target_lobby_id, -1, match_instance.roster, level_id)

func _sanitize_username(raw: String) -> String:
	var trimmed := raw.strip_edges()
	if trimmed.is_empty():
		trimmed = "Player%d" % randi_range(1000, 9999)
	return trimmed.substr(0, 16)

@rpc("any_peer", "reliable")
func _server_create_lobby(lobby_name: String, max_players: int) -> void:
	if not is_server:
		return
	var sender := multiplayer.get_remote_sender_id()
	if _peer_lobby.has(sender):
		return # already in a lobby
	_create_lobby_internal(sender, lobby_name, max_players)

@rpc("any_peer", "reliable")
func _server_join_lobby(lobby_id: int) -> void:
	if not is_server:
		return
	var sender := multiplayer.get_remote_sender_id()
	if _peer_lobby.has(sender):
		return
	_join_lobby_internal(sender, lobby_id)

## One-click matchmaking: joins the first open (not-in-match, not-full)
## lobby, or creates a fresh "Quick Match" one if none exists -- reuses the
## exact same internal helpers _server_create_lobby/_server_join_lobby call,
## so quick-joined and manually-joined lobbies behave identically once in
## lobby_room.
@rpc("any_peer", "reliable")
func _server_quick_join_lobby() -> void:
	if not is_server:
		return
	var sender := multiplayer.get_remote_sender_id()
	if _peer_lobby.has(sender):
		return
	for lobby in _lobbies.values():
		if not lobby.in_match and lobby.members.size() < lobby.max_players:
			_join_lobby_internal(sender, lobby.id)
			return
	_create_lobby_internal(sender, "Quick Match", MAX_LOBBY_PLAYERS)

func _create_lobby_internal(sender: int, lobby_name: String, max_players: int) -> void:
	var id := _next_lobby_id
	_next_lobby_id += 1
	var clean_name := lobby_name.strip_edges().substr(0, 24)
	if clean_name.is_empty():
		clean_name = "Lobby %d" % id
	_lobbies[id] = {
		"id": id,
		"name": clean_name,
		"host_peer": sender,
		"max_players": clampi(max_players, 2, MAX_LOBBY_PLAYERS),
		"members": {sender: {"username": _peer_username.get(sender, "Player"), "ready": false}},
		"in_match": false,
	}
	_peer_lobby[sender] = id
	_broadcast_lobby_list()
	_send_lobby_state(id)

func _join_lobby_internal(sender: int, lobby_id: int) -> void:
	if not _lobbies.has(lobby_id):
		return
	var lobby: Dictionary = _lobbies[lobby_id]
	if lobby.in_match or lobby.members.size() >= lobby.max_players:
		return
	lobby.members[sender] = {"username": _peer_username.get(sender, "Player"), "ready": false}
	_peer_lobby[sender] = lobby_id
	_broadcast_lobby_list()
	_send_lobby_state(lobby_id)

@rpc("any_peer", "reliable")
func _server_leave_lobby() -> void:
	if not is_server:
		return
	var sender := multiplayer.get_remote_sender_id()
	var lobby_id: int = _peer_lobby.get(sender, -1)
	if lobby_id != -1:
		_remove_peer_from_lobby(sender, lobby_id)
		_peer_lobby.erase(sender)

func _remove_peer_from_lobby(peer_id: int, lobby_id: int) -> void:
	if not _lobbies.has(lobby_id):
		return
	var lobby: Dictionary = _lobbies[lobby_id]
	lobby.members.erase(peer_id)
	# Drop the peer from the running match's own roster immediately, whether
	# or not this empties the whole lobby -- otherwise ServerMatch keeps
	# trying to push match-state to a peer_id nothing is listening on anymore.
	if _matches.has(lobby_id):
		_matches[lobby_id].remove_peer(peer_id)
	if lobby.members.is_empty():
		_lobbies.erase(lobby_id)
		if _matches.has(lobby_id):
			_matches[lobby_id].teardown()
			_matches.erase(lobby_id)
		_end_spectating_for_lobby(lobby_id)
	else:
		if lobby.host_peer == peer_id:
			lobby.host_peer = lobby.members.keys()[0]
		_send_lobby_state(lobby_id)
	_broadcast_lobby_list()

## Tells every spectator of lobby_id's match that it's over -- a match
## ending because every real player left has no ranking to report (empty
## Array default), a ranked round's real end (see notify_match_ended) passes
## its actual ranking through instead. Drops their spectator registration
## either way, so no dead match instance is left silently pushing no state.
func _end_spectating_for_lobby(lobby_id: int, ranking: Array = []) -> void:
	if not _spectators.has(lobby_id):
		return
	for spectator_peer_id in _spectators[lobby_id]:
		rpc_id(spectator_peer_id, "_client_match_ended", ranking)
		_peer_spectating_lobby.erase(spectator_peer_id)
	_spectators.erase(lobby_id)

@rpc("any_peer", "reliable")
func _server_set_ready(ready: bool) -> void:
	if not is_server:
		return
	var sender := multiplayer.get_remote_sender_id()
	var lobby_id: int = _peer_lobby.get(sender, -1)
	if lobby_id == -1 or not _lobbies.has(lobby_id):
		return
	_lobbies[lobby_id].members[sender].ready = ready
	_send_lobby_state(lobby_id)

@rpc("any_peer", "reliable")
func _server_start_match() -> void:
	if not is_server:
		return
	var sender := multiplayer.get_remote_sender_id()
	var lobby_id: int = _peer_lobby.get(sender, -1)
	if lobby_id == -1 or not _lobbies.has(lobby_id):
		return
	var lobby: Dictionary = _lobbies[lobby_id]
	if lobby.host_peer != sender or lobby.in_match or lobby.members.is_empty():
		return
	_start_match_for_lobby(lobby_id, false)

## A ranked server has no manual lobby-naming/browsing/Ready/Start step --
## everyone who connects is auto-added to the one reserved ranked lobby
## (recreated fresh after each round, see notify_match_ended), and the round
## auto-starts as soon as MIN_RANKED_PLAYERS are in it.
func _join_ranked_lobby(sender: int) -> void:
	if _ranked_lobby_id == -1 or not _lobbies.has(_ranked_lobby_id) or _lobbies[_ranked_lobby_id].in_match:
		_ranked_lobby_id = _next_lobby_id
		_next_lobby_id += 1
		_lobbies[_ranked_lobby_id] = {
			"id": _ranked_lobby_id, "name": "Ranked Match", "host_peer": sender,
			"max_players": MAX_LOBBY_PLAYERS, "members": {}, "in_match": false, "ranked": true,
		}
	var lobby: Dictionary = _lobbies[_ranked_lobby_id]
	if lobby.members.size() >= lobby.max_players:
		return # full -- rare, the directory listing should already hide a full ranked server from new searches
	lobby.members[sender] = {"username": _peer_username.get(sender, "Player"), "ready": true}
	_peer_lobby[sender] = _ranked_lobby_id
	_broadcast_lobby_list()
	_send_lobby_state(_ranked_lobby_id)
	if lobby.members.size() >= MIN_RANKED_PLAYERS:
		_start_match_for_lobby(_ranked_lobby_id, true)

func _start_match_for_lobby(lobby_id: int, ranked: bool) -> void:
	var lobby: Dictionary = _lobbies[lobby_id]
	lobby.in_match = true
	_broadcast_lobby_list()
	var members_with_extras: Dictionary = lobby.members.duplicate(true)
	for peer_id in members_with_extras.keys():
		members_with_extras[peer_id]["skin_id"] = _peer_skin_id.get(peer_id, "red")
		members_with_extras[peer_id]["hat_id"] = _peer_hat_id.get(peer_id, "")
		members_with_extras[peer_id]["trail_id"] = _peer_trail_id.get(peer_id, "")
		members_with_extras[peer_id]["client_id"] = _peer_client_id.get(peer_id, "")
	var match_instance := ServerMatch.new(self, lobby_id, members_with_extras, ranked)
	add_child(match_instance)
	_matches[lobby_id] = match_instance

@rpc("any_peer", "unreliable_ordered")
func _server_submit_input(input: Dictionary) -> void:
	if not is_server:
		return
	var sender := multiplayer.get_remote_sender_id()
	var lobby_id: int = _peer_lobby.get(sender, -1)
	if lobby_id != -1 and _matches.has(lobby_id):
		_matches[lobby_id].receive_input(sender, input)

## Lobby-only chat (not in-match, to keep this well clear of the tight tag-
## gameplay netcode path) -- rides the same bridged connection every other
## RPC here does, no relay-server changes needed. Relays to exactly the
## sender's own lobby, never a blind server-wide broadcast, since one
## dedicated server process can be hosting several unrelated lobbies at once.
@rpc("any_peer", "reliable")
func _server_send_chat_message(text: String) -> void:
	if not is_server:
		return
	var sender := multiplayer.get_remote_sender_id()
	var lobby_id: int = _peer_lobby.get(sender, -1)
	if lobby_id == -1 or not _lobbies.has(lobby_id):
		return
	var clean_text := text.strip_edges().left(MAX_CHAT_MESSAGE_LEN)
	if clean_text.is_empty():
		return
	var sender_username: String = _peer_username.get(sender, "Player")
	for member_peer_id in _lobbies[lobby_id].members.keys():
		rpc_id(member_peer_id, "_client_receive_chat_message", sender_username, clean_text)

# ==================== Server -> client push helpers ====================

func _lobby_summaries() -> Array:
	var summaries := []
	for lobby in _lobbies.values():
		if lobby.in_match:
			continue
		summaries.append({
			"id": lobby.id, "name": lobby.name,
			"player_count": lobby.members.size(), "max_players": lobby.max_players,
		})
	return summaries

func _broadcast_lobby_list() -> void:
	var summaries := _lobby_summaries()
	for peer_id in multiplayer.get_peers():
		rpc_id(peer_id, "_client_receive_lobby_list", summaries)

func _send_lobby_list(peer_id: int) -> void:
	rpc_id(peer_id, "_client_receive_lobby_list", _lobby_summaries())

func _send_lobby_state(lobby_id: int) -> void:
	if not _lobbies.has(lobby_id):
		return
	var lobby: Dictionary = _lobbies[lobby_id]
	for peer_id in lobby.members.keys():
		rpc_id(peer_id, "_client_receive_lobby_state", lobby)

## Called by ServerMatch once it's finished spawning players.
func notify_match_started(lobby_id: int, roster: Dictionary, match_level_id: String) -> void:
	for peer_id in roster.keys():
		rpc_id(peer_id, "_client_match_started", lobby_id, peer_id, roster, match_level_id)

## Called by ServerMatch every physics tick.
func push_match_state(peer_id: int, tick: int, states: Dictionary) -> void:
	rpc_id(peer_id, "_client_receive_match_state", tick, states)

## Called by ServerMatch once a ranked round's timer runs out. A ranked
## round is a one-shot -- there's no "return to the same lobby for another
## round" the way casual play works, so this tears the match/lobby down
## the same way a fully-emptied one would, after fanning the result out and
## reporting it to the relay for ELO.
func notify_match_ended(lobby_id: int, ranking: Array) -> void:
	for entry in ranking:
		rpc_id(entry.peer_id, "_client_match_ended", ranking)
		_peer_lobby.erase(entry.peer_id)
	_report_ranked_result(ranking)
	_end_spectating_for_lobby(lobby_id, ranking)
	if _matches.has(lobby_id):
		_matches[lobby_id].teardown()
		_matches.erase(lobby_id)
	if _lobbies.has(lobby_id):
		_lobbies.erase(lobby_id)
	if lobby_id == _ranked_lobby_id:
		_ranked_lobby_id = -1
	_broadcast_lobby_list()

func _report_ranked_result(ranking: Array) -> void:
	var results := []
	for entry in ranking:
		var client_id: String = entry.get("client_id", "")
		if client_id.is_empty():
			continue # no persistent identity to credit -- shouldn't happen for a real client, but don't let one bad entry crash the report
		results.append({"clientId": client_id, "itTime": entry.it_time, "place": entry.place, "username": entry.get("username", "")})
	if results.is_empty():
		return
	var req := HTTPRequest.new()
	add_child(req)
	req.request_completed.connect(func(_r, _c, _h, _b): req.queue_free())
	var body := JSON.stringify({"results": results})
	req.request(RANKED_REPORT_URL, ["Content-Type: application/json"], HTTPClient.METHOD_POST, body)

# ==================== Client-side RPC endpoints (server -> client) ====================

@rpc("authority", "reliable")
func _client_receive_lobby_list(lobbies: Array) -> void:
	lobby_list_updated.emit(lobbies)

@rpc("authority", "reliable")
func _client_receive_lobby_state(lobby: Dictionary) -> void:
	current_lobby = lobby
	lobby_state_updated.emit(lobby)

@rpc("authority", "reliable")
func _client_match_started(lobby_id: int, my_id: int, roster: Dictionary, match_level_id: String) -> void:
	my_peer_id = my_id
	match_started.emit(lobby_id, my_id, roster, match_level_id)

@rpc("authority", "unreliable_ordered")
func _client_receive_match_state(tick: int, states: Dictionary) -> void:
	match_state_received.emit(tick, states)

@rpc("authority", "reliable")
func _client_match_ended(ranking: Array) -> void:
	match_ended.emit(ranking)

@rpc("authority", "reliable")
func _client_receive_chat_message(sender_username: String, text: String) -> void:
	chat_message_received.emit(sender_username, text)

@rpc("authority", "reliable")
func _client_spectate_failed() -> void:
	spectate_failed.emit()

# ==================== Client-facing API (called by UI) ====================

func set_username(display_name: String) -> void:
	username = display_name

func create_lobby(lobby_name: String, max_players: int) -> void:
	rpc_id(1, "_server_create_lobby", lobby_name, max_players)

func join_lobby(lobby_id: int) -> void:
	rpc_id(1, "_server_join_lobby", lobby_id)

func quick_join_lobby() -> void:
	rpc_id(1, "_server_quick_join_lobby")

func leave_lobby() -> void:
	rpc_id(1, "_server_leave_lobby")
	current_lobby = {}

func set_ready(ready: bool) -> void:
	rpc_id(1, "_server_set_ready", ready)

func send_chat_message(text: String) -> void:
	rpc_id(1, "_server_send_chat_message", text)

func start_match() -> void:
	rpc_id(1, "_server_start_match")

func submit_input(input: Dictionary) -> void:
	rpc_id(1, "_server_submit_input", input)
