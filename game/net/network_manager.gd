extends Node

# Central networking hub, present identically on every peer (autoload path
# "/root/NetworkManager" always matches, which is what makes calling rpc()/
# rpc_id() on this node work without any per-scene node-path juggling).
# The server is always peer id 1 and is fully authoritative: it owns lobby
# state and runs every active match's simulation; clients only ever request
# things and render what the server tells them.

signal lobby_list_updated(lobbies: Array)
signal lobby_state_updated(lobby: Dictionary)
signal match_started(lobby_id: int, my_peer_id: int, roster: Dictionary, level_id: String, playlist_id: String)
signal match_state_received(tick: int, states: Dictionary)
## Fires once on every peer when a round's timer runs out (ranked or
## casual). `ranking` is [{peer_id, username, it_time, place}], sorted best
## (place 1) first.
signal match_ended(ranking: Array)
signal connected_to_server
signal connection_failed
signal disconnected_from_server
## Fires on a peer that tried start_spectator() when no match is currently
## in progress on that server to watch.
signal spectate_failed
## Fires once a lobby is actually about to start (fill/host-start/ranked-
## threshold reached) -- see _begin_match_sequence(). `duration` is how long
## voting stays open; the real match doesn't start until the vote result
## (see map_vote_phase_ended below) and a short countdown after that.
signal map_vote_phase_started(duration: float)
## Fires once voting closes -- `chosen_level_id` is the weighted-random
## pick (see _pick_voted_level()), `countdown` is how long until the match
## actually starts (match_started fires after that on its own).
signal map_vote_phase_ended(chosen_level_id: String, countdown: float)

const PlaylistCatalog := preload("res://net/playlist_catalog.gd")
const RankTiers := preload("res://cosmetics/rank_tiers.gd")
const OnlineMapCatalog := preload("res://levels/online_maps/catalog.gd")

const DEFAULT_PORT := 9000
const MAX_LOBBY_PLAYERS := 8
const MIN_RANKED_PLAYERS := 2
const RANKED_REPORT_URL := "https://codecade.co.za/tag/api/ranked/report-result"
## How long the map-vote popup stays open, and how long the "starting
## in..." countdown after it runs, before the match actually begins (see
## _begin_match_sequence()/_on_map_vote_timeout()) -- map selection is now
## a timed pop-up-vote-then-countdown moment right before a match starts,
## not a passive panel players could ignore indefinitely.
const MAP_VOTE_DURATION_SEC := 30.0
const MAP_VOTE_COUNTDOWN_SEC := 3.0
## How long a ranked playlist lobby waits for real players before topping
## the remaining slots up with bots (see _on_bot_fill_timeout()) rather than
## leaving whoever's already queued waiting indefinitely for a full lobby
## that may never arrive on a small player base.
const BOT_FILL_WAIT_SEC := 20.0
const BOT_NAMES := ["Nova", "Byte", "Ghost", "Volt", "Rex", "Echo", "Pixel", "Dash"]

var is_server := false
var is_ranked_server := false # set by server_main.gd from --ranked; auto-lobbies/starts ranked rounds instead of waiting for manual create/join/Start
var level_id := "" # set by server_main.gd from --level=<id>; "" means the built-in default arena, applies to every lobby this server process hosts
# set by server_main.gd from --playlist=<id>; "" means the legacy undifferentiated
# free-for-all ranked pool (any headcount 2-8) -- one playlist per process,
# same pattern as is_ranked_server/level_id. Casual servers also read this:
# host_setup.gd passes --playlist= for a playlist-restricted casual lobby.
var playlist_id := ""
var username := "Player"
var my_peer_id := -1
var current_lobby: Dictionary = {}
## Set by casual_matchmaker.gd right after spawning a --private local server
## and connecting to it, "host:port" for a friend to type into
## multiplayer_connect.tscn -- "" whenever this client isn't currently
## hosting a private match (the normal case). Purely client-local display
## state, read by lobby_room.gd; never synced to any peer.
var hosted_private_address := ""
## Set alongside hosted_private_address whenever it came from
## multiplayer_connect.gd's Host button (real UDP/ENet, see
## start_server_direct) rather than the usual Private-button relay-routed
## hosting -- lobby_room.gd's share-address panel reads this to warn that
## the shown address is this machine's LAN-local one, and a player outside
## that LAN needs the host's forwarded public address instead.
var hosted_private_is_direct := false

# ---- Server-side state only ----
var _lobbies := {}       # lobby_id -> {id, name, host_peer, max_players, members: {peer_id: {username, ready}}, in_match, ranked}
var _next_lobby_id := 1
var _ranked_lobby_id := -1 # the single reserved lobby a ranked server auto-fills, recreated after each round
var _peer_username := {} # peer_id -> String
var _peer_color_id := {} # peer_id -> String, auto-assigned (see PlayerColors.id_for_peer)
var _peer_client_id := {} # peer_id -> String, the anonymous ranked/friends identity -- server-side only, never broadcast to other clients
var _peer_party_id := {} # peer_id -> String, "" if not in a party -- see PartyManager, purely a grouping key for team assignment below
var _peer_party_size := {} # peer_id -> int, 1 if not in a party -- see _create_lobby_internal's is_party_private sizing
var _peer_lobby := {}    # peer_id -> lobby_id
var _matches := {}       # lobby_id -> ServerMatch
var _spectators := {}    # lobby_id -> Array[peer_id], read-only observers of an in-progress match
var _peer_spectating_lobby := {} # peer_id -> lobby_id, for disconnect cleanup

# ---- Client-side state only ----
var _pending_as_spectator := false # set by start_spectator(), consumed by _on_connected_to_server()

func _ready() -> void:
	# Godot's default automatic RPC dispatch happens at the SceneTree/engine
	# level, entirely outside the pausable node tree -- pausing a match has
	# never stopped multiplayer traffic from being received. Polling by hand
	# below moves that into an ordinary node callback, which by default DOES
	# respect get_tree().paused (PROCESS_MODE_INHERIT). Without this, pausing
	# during a match would silently stop ALL RPC dispatch -- not just
	# gameplay state, but lobby updates, chat, bot-fill results, everything
	# -- for as long as the tree stayed paused. And it can stay paused far
	# longer than "while the pause menu is open": nothing resets
	# get_tree().paused on a match ending naturally or a disconnect while
	# paused (see net_game.gd's _on_match_ended/_on_disconnected), so this
	# would otherwise silently break multiplayer for the rest of the session
	# after a single pause, not just during it.
	process_mode = Node.PROCESS_MODE_ALWAYS
	# By default Godot only dispatches received RPCs from the idle/render-
	# frame callback, not the physics tick -- fine for occasional lobby/chat
	# traffic, but it decouples receiving this project's tight 60Hz gameplay
	# RPCs (_server_submit_input, _client_receive_match_state) from the
	# physics tick they're actually paced to. Sending is unaffected (an RPC
	# called from _physics_process writes to the socket immediately); this
	# only closes the gap on the receiving end. Must be set before any peer
	# exists, so before start_server()/start_client()/start_spectator() can
	# ever run -- _ready() on this autoload always runs at boot, well before
	# any of those (user-triggered) calls.
	get_tree().set_multiplayer_poll_enabled(false)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.connected_to_server.connect(_on_connected_to_server)
	multiplayer.connection_failed.connect(_on_connection_failed)
	multiplayer.server_disconnected.connect(_on_server_disconnected)

func _physics_process(_delta: float) -> void:
	multiplayer.poll()

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

# lobby_id -> {players: [{clientId, username, x, y, isIt}], timeRemaining,
# arenaWidth, arenaHeight} -- a much-lower-frequency, JSON-safe echo of the
# per-tick `states` dict ServerMatch already builds for push_match_state,
# kept here (not inside ServerMatch/RelayClient directly) since RelayClient
# has no reference to any particular lobby's ServerMatch instance, only to
# this autoload. RelayClient's own timer reads this and reports it up to
# the relay for the website's live match viewer (see relay-server/public/
## watch.html) -- the native client's own spectate view never reads this,
# it gets full state over push_match_state instead.
var latest_match_summaries := {}

## Called by ServerMatch on its own throttled timer (not every physics
## tick -- this only ever needs to be "live enough for a webpage," not
## interpolation-smooth). Overwrites any previous summary for this lobby;
## cleared by clear_match_state_summary() once the match ends so a stale
## snapshot can't linger past what RelayClient last reported.
func report_match_state_summary(lobby_id: int, summary: Dictionary) -> void:
	latest_match_summaries[lobby_id] = summary

func clear_match_state_summary(lobby_id: int) -> void:
	latest_match_summaries.erase(lobby_id)

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

## Real UDP (ENetMultiplayerPeer), not WebSocket -- for two players who've
## deliberately agreed to connect directly (see multiplayer_connect.gd's
## Host/Connect pair) rather than going through the relay. WebSocket rides
## on TCP, which has no true "unreliable" delivery: a single lost packet
## blocks EVERY subsequent packet on that connection (including unrelated
## ones) until it's retransmitted -- head-of-line blocking. That's mostly
## invisible on a short/clean link, but on a long international one
## (confirmed live: South Africa <-> Netherlands, multi-second stalls vs.
## the ~250ms other UDP-based games manage on the same physical link) it's
## the actual cause of the stalls, not raw propagation delay. ENet is real
## UDP -- a lost "unreliable" packet is just gone, never blocking anything
## behind it. The tradeoff (see start_server's own comment on why WebSocket
## was chosen in the first place) is this can't cross the Cloudflare Tunnel
## at all -- it needs a real port forwarded to the host, which is why this
## is a separate, deliberately-opt-in path rather than replacing
## start_server/start_client outright.
func start_server_direct(port: int = DEFAULT_PORT) -> bool:
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_server(port)
	if err != OK:
		push_error("NetworkManager: failed to start direct (UDP) server on port %d (%s)" % [port, err])
		return false
	multiplayer.multiplayer_peer = peer
	is_server = true
	my_peer_id = 1
	print("NetworkManager: direct (UDP) server listening on port %d" % port)
	return true

## `address` is a bare host:port -- no ws://, this never goes through the
## relay/tunnel at all. See start_server_direct's own comment.
func start_client_direct(address: String, display_name: String) -> void:
	username = display_name
	is_server = false
	_pending_as_spectator = false
	var host := address
	var port := DEFAULT_PORT
	var colon := address.rfind(":")
	if colon != -1:
		host = address.substr(0, colon)
		port = int(address.substr(colon + 1))
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_client(host, port)
	if err != OK:
		push_error("NetworkManager: failed to create direct (UDP) client peer (%s)" % err)
		connection_failed.emit()
		return
	multiplayer.multiplayer_peer = peer

# ==================== WebRTC (migration in progress -- loopback only so far) ====================
#
# See C:\Users\Flipped\.claude\plans\humming-coalescing-otter.md for the
# full migration plan. This is Phase 1: same-machine hosting only, over a
# WebRTCSignalingChannel/WebRTCLoopbackListener pair on 127.0.0.1 -- proves
# the WebRTCPeerConnection/WebRTCMultiplayerPeer plumbing and RPC dispatch
# work end to end before Phase 2 wires the same signaling message shape
# through relay-server.js for real relay-routed and party-follow joins,
# which is the case that actually fixes the SA<->NL latency bug this
# migration exists for. Not yet reachable from any menu -- start_server()/
# start_client() (WebSocket) stay the default until Phase 2+ land.
#
# The connecting peer always creates the offer and picks its own peer id
# (a large random int, sent as part of the offer) -- deterministic, and
# avoids needing a round trip before either side can start negotiating.
# WebRTCMultiplayerPeer.add_peer() must be called before any offer/answer
# exists (it declares the reliable/unreliable/unreliable_ordered data
# channels that then get baked into the SDP), not after ICE connects.

var _webrtc_listener: WebRTCLoopbackListener
## peer_id -> {pc: WebRTCPeerConnection, channel: WebRTCSignalingChannel} --
## server side only, while a given peer's offer/answer/candidate exchange
## is still in flight. Godot's own multiplayer.peer_connected/
## peer_disconnected fire regardless of transport (already true for both
## WebSocketMultiplayerPeer and ENetMultiplayerPeer in this file) but
## nothing frees this bookkeeping on its own -- _on_webrtc_peer_disconnected
## below does that.
var _webrtc_pending_peers := {}

func start_server_webrtc_loopback(port: int) -> bool:
	var mp := WebRTCMultiplayerPeer.new()
	var err := mp.create_server()
	if err != OK:
		push_error("NetworkManager: failed to create WebRTC server multiplayer peer (%s)" % err)
		return false
	multiplayer.multiplayer_peer = mp
	is_server = true
	my_peer_id = 1
	_webrtc_listener = WebRTCLoopbackListener.new()
	add_child(_webrtc_listener)
	var listen_err := _webrtc_listener.listen(port)
	if listen_err != OK:
		push_error("NetworkManager: WebRTC signaling listener failed on port %d (%s)" % [port, listen_err])
		return false
	_webrtc_listener.channel_connected.connect(_on_webrtc_signaling_channel_connected)
	if not multiplayer.peer_disconnected.is_connected(_on_webrtc_peer_disconnected):
		multiplayer.peer_disconnected.connect(_on_webrtc_peer_disconnected)
	print("NetworkManager: WebRTC (loopback) server listening, signaling on port %d" % port)
	return true

func _on_webrtc_signaling_channel_connected(channel: WebRTCSignalingChannel) -> void:
	# The offer (see start_client_webrtc_loopback) carries the peer id the
	# connecting client already picked for itself -- nothing to assign
	# here, just wait for it.
	channel.message_received.connect(func(msg: Dictionary):
		if msg.get("type", "") != "offer":
			return # a stray candidate/answer arriving before the offer shouldn't happen, but ignore rather than crash if it does
		_accept_webrtc_offer(channel, msg)
	, CONNECT_ONE_SHOT)

func _accept_webrtc_offer(channel: WebRTCSignalingChannel, offer_msg: Dictionary) -> void:
	var peer_id := int(offer_msg.get("peerId", 0))
	if peer_id <= 1 or _webrtc_pending_peers.has(peer_id):
		return # 0/1 are reserved (invalid/server); a collision just drops this attempt rather than crashing
	var pc := WebRTCPeerConnection.new()
	pc.initialize({})
	(multiplayer.multiplayer_peer as WebRTCMultiplayerPeer).add_peer(pc, peer_id)
	_webrtc_pending_peers[peer_id] = {"pc": pc, "channel": channel}
	pc.session_description_created.connect(func(type: String, sdp: String):
		pc.set_local_description(type, sdp)
		channel.send({"type": type, "sdp": sdp})
	)
	pc.ice_candidate_created.connect(func(media: String, index: int, name: String):
		channel.send({"type": "candidate", "media": media, "index": index, "name": name})
	)
	channel.message_received.connect(func(msg: Dictionary):
		_handle_webrtc_signal(pc, msg)
	)
	pc.set_remote_description("offer", str(offer_msg.get("sdp", "")))

func _handle_webrtc_signal(pc: WebRTCPeerConnection, msg: Dictionary) -> void:
	match msg.get("type", ""):
		"offer":
			pc.set_remote_description("offer", str(msg.get("sdp", "")))
		"answer":
			pc.set_remote_description("answer", str(msg.get("sdp", "")))
		"candidate":
			pc.add_ice_candidate(str(msg.get("media", "")), int(msg.get("index", 0)), str(msg.get("name", "")))

func _on_webrtc_peer_disconnected(id: int) -> void:
	var entry: Dictionary = _webrtc_pending_peers.get(id, {})
	if entry.has("channel"):
		(entry["channel"] as WebRTCSignalingChannel).close()
	_webrtc_pending_peers.erase(id)

func start_client_webrtc_loopback(port: int, display_name: String) -> void:
	username = display_name
	is_server = false
	_pending_as_spectator = false
	var my_id := randi_range(2, 2147483647)
	var mp := WebRTCMultiplayerPeer.new()
	var create_err := mp.create_client(my_id)
	if create_err != OK:
		push_error("NetworkManager: failed to create WebRTC client multiplayer peer (%s)" % create_err)
		connection_failed.emit()
		return
	multiplayer.multiplayer_peer = mp
	var pc := WebRTCPeerConnection.new()
	pc.initialize({})
	mp.add_peer(pc, 1) # the server is always peer 1
	var channel := WebRTCSignalingChannel.for_loopback_client(port)
	add_child(channel)
	pc.session_description_created.connect(func(type: String, sdp: String):
		pc.set_local_description(type, sdp)
		channel.send({"type": type, "sdp": sdp, "peerId": my_id})
	)
	pc.ice_candidate_created.connect(func(media: String, index: int, name: String):
		channel.send({"type": "candidate", "media": media, "index": index, "name": name})
	)
	channel.message_received.connect(func(msg: Dictionary):
		_handle_webrtc_signal(pc, msg)
	)
	pc.create_offer()

func disconnect_from_server() -> void:
	if multiplayer.multiplayer_peer:
		multiplayer.multiplayer_peer.close()
	multiplayer.multiplayer_peer = null
	is_server = false
	my_peer_id = -1
	current_lobby = {}
	hosted_private_address = ""
	hosted_private_is_direct = false

func _on_connected_to_server() -> void:
	my_peer_id = multiplayer.get_unique_id()
	if _pending_as_spectator:
		_pending_as_spectator = false
		rpc_id(1, "_server_register_spectator")
	else:
		rpc_id(1, "_server_register_player", username, PlayerIdentity.client_id, PartyManager.current_party.get("id", ""), PartyManager.party_size())
	connected_to_server.emit()

func _on_connection_failed() -> void:
	connection_failed.emit()

func _on_server_disconnected() -> void:
	disconnected_from_server.emit()

func _on_peer_disconnected(id: int) -> void:
	if not is_server:
		return
	_peer_username.erase(id)
	_peer_color_id.erase(id)
	_peer_client_id.erase(id)
	_peer_party_id.erase(id)
	_peer_party_size.erase(id)
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
func _server_register_player(display_name: String, client_id: String = "", party_id: String = "", party_size: int = 1) -> void:
	if not is_server:
		return
	var sender := multiplayer.get_remote_sender_id()
	_peer_username[sender] = _sanitize_username(display_name)
	# No selection to take from the client -- color is just a deterministic
	# function of peer_id (see PlayerColors.id_for_peer).
	_peer_color_id[sender] = PlayerColors.id_for_peer(sender)
	_peer_client_id[sender] = client_id
	_peer_party_id[sender] = party_id
	_peer_party_size[sender] = party_size
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
	rpc_id(sender, "_client_match_started", target_lobby_id, -1, match_instance.roster, level_id, match_instance.playlist_id)

func _sanitize_username(raw: String) -> String:
	var trimmed := raw.strip_edges()
	if trimmed.is_empty():
		trimmed = "Player%d" % randi_range(1000, 9999)
	return trimmed.substr(0, 16)

@rpc("any_peer", "reliable")
func _server_create_lobby(lobby_name: String, max_players: int, p_playlist_id: String = "") -> void:
	if not is_server:
		return
	var sender := multiplayer.get_remote_sender_id()
	if _peer_lobby.has(sender):
		return # already in a lobby
	_create_lobby_internal(sender, lobby_name, max_players, p_playlist_id)

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
## `playlist_id` "" (default) keeps the original behavior exactly -- any open
## lobby regardless of playlist, creating a plain "Quick Match" one if none
## exists. A real playlist id restricts candidates to lobbies already
## restricted to that same playlist (never matches a "" lobby or a
## different playlist's), and the freshly-created fallback carries the
## playlist forward too -- see casual_queue.gd, the one caller that passes
## a real value today.
@rpc("any_peer", "reliable")
func _server_quick_join_lobby(playlist_id: String = "") -> void:
	if not is_server:
		return
	var sender := multiplayer.get_remote_sender_id()
	if _peer_lobby.has(sender):
		return
	for lobby in _lobbies.values():
		if not lobby.in_match and lobby.members.size() < lobby.max_players and lobby.get("playlist", "") == playlist_id:
			_join_lobby_internal(sender, lobby.id)
			return
	_create_lobby_internal(sender, "Quick Match", MAX_LOBBY_PLAYERS, playlist_id)

## color_id here (not just username/ready) so a live lobby-waiting view (see
## TeamLobbyView) can show real character portraits before the match even
## starts, not just names -- match-start's own members_with_extras
## duplicates this same lookup for the same reason.
func _member_entry(peer_id: int, ready: bool) -> Dictionary:
	return {
		"username": _peer_username.get(peer_id, "Player"), "ready": ready,
		"color_id": _peer_color_id.get(peer_id, PlayerColors.DEFAULT_ID),
		# Broadcast, not secret -- lets a client's own live waiting-room
		# preview (team_lobby_view.gd) group party members the same way
		# _start_match_for_lobby's real assignment below will.
		"party_id": _peer_party_id.get(peer_id, ""),
	}

func _create_lobby_internal(sender: int, lobby_name: String, max_players: int, p_playlist_id: String = "") -> void:
	var id := _next_lobby_id
	_next_lobby_id += 1
	var clean_name := lobby_name.strip_edges().substr(0, 24)
	if clean_name.is_empty():
		clean_name = "Lobby %d" % id
	# A playlist-restricted lobby's headcount comes from the catalog, not
	# the caller-supplied max_players -- 2v2 is always exactly 4, never
	# host-configurable, same as ranked's playlist lobbies below.
	var effective_max := clampi(max_players, 2, MAX_LOBBY_PLAYERS)
	if not p_playlist_id.is_empty():
		effective_max = PlaylistCatalog.total_players(p_playlist_id)
	# A party leader going Private auto-starts once the party's fully in and
	# skips the manual Start button/address-share panel (see lobby_room.gd)
	# -- solo/non-party private hosts keep today's manual Start flow
	# unchanged. Both still get the same map-vote pop-up as any other match.
	var is_party_private: bool = p_playlist_id.is_empty() and not String(_peer_party_id.get(sender, "")).is_empty()
	if is_party_private:
		# A private lobby otherwise caps at MAX_LOBBY_PLAYERS like any other
		# quick-joined one, but a party can be bigger than that (up to
		# PartyManager's own 16-member cap) -- size to fit the whole party
		# rather than splitting it across two lobbies on the same server.
		effective_max = maxi(effective_max, _peer_party_size.get(sender, 1))
	_lobbies[id] = {
		"id": id,
		"name": clean_name,
		"host_peer": sender,
		"max_players": effective_max,
		"members": {sender: _member_entry(sender, false)},
		"in_match": false,
		"playlist": p_playlist_id,
		"map_votes": {},
		"voting_open": false,
		"is_party_private": is_party_private,
	}
	_peer_lobby[sender] = id
	_broadcast_lobby_list()
	_send_lobby_state(id)
	_maybe_autostart_playlist_lobby(id)

func _join_lobby_internal(sender: int, lobby_id: int) -> void:
	if not _lobbies.has(lobby_id):
		return
	var lobby: Dictionary = _lobbies[lobby_id]
	if lobby.in_match or lobby.members.size() >= lobby.max_players:
		return
	lobby.members[sender] = _member_entry(sender, false)
	_peer_lobby[sender] = lobby_id
	_broadcast_lobby_list()
	_send_lobby_state(lobby_id)
	_maybe_autostart_playlist_lobby(lobby_id)

## Casual playlist lobbies (1v1/2v2/1v1v1/1v1v1v1) have no manual Start
## button at all -- they auto-start the instant they reach the playlist's
## exact headcount, mirroring how _join_ranked_lobby already auto-starts
## ranked. A "Free-for-all" casual lobby (empty playlist, today's default)
## is untouched -- still manual Start, any headcount, via _server_start_match.
##
## Same bot-fill as ranked below (_on_bot_fill_timeout is playlist-agnostic
## already -- it just reads whatever lobby it's given) -- without this, a
## casual queue for anything but the single busiest playlist would just
## wait forever for real players who never show up.
func _maybe_autostart_playlist_lobby(lobby_id: int) -> void:
	if not _lobbies.has(lobby_id):
		return
	var lobby: Dictionary = _lobbies[lobby_id]
	var lobby_playlist: String = lobby.get("playlist", "")
	if lobby_playlist.is_empty() or lobby.in_match:
		return
	if lobby.members.size() >= PlaylistCatalog.total_players(lobby_playlist):
		_begin_match_sequence(lobby_id, false)
	elif not lobby.get("bot_fill_scheduled", false):
		lobby["bot_fill_scheduled"] = true
		get_tree().create_timer(BOT_FILL_WAIT_SEC).timeout.connect(_on_bot_fill_timeout.bind(lobby_id))

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

## Casual and ranked lobbies both use this -- any member (not just the host)
## can vote, any number of times before the match starts (a later vote
## simply overwrites that peer's earlier one, same "last choice wins" rule
## _server_set_ready implicitly follows). No server-side catalog validation:
## the actual map id just needs to be something ServerMatch can (attempt to)
## fetch -- an unknown/bad id already falls back to the built-in arena on
## its own (see server_match.gd's _fetch_custom_arena), the same safety net
## a single bad host-picked map id relied on before voting existed.
@rpc("any_peer", "reliable")
func _server_submit_map_vote(map_level_id: String) -> void:
	if not is_server:
		return
	var sender := multiplayer.get_remote_sender_id()
	var lobby_id: int = _peer_lobby.get(sender, -1)
	if lobby_id == -1 or not _lobbies.has(lobby_id):
		return
	var lobby: Dictionary = _lobbies[lobby_id]
	if not lobby.get("voting_open", false):
		return
	if not lobby.has("map_votes"):
		lobby["map_votes"] = {}
	lobby["map_votes"][sender] = map_level_id
	_send_lobby_state(lobby_id)
	_maybe_resolve_map_vote_early(lobby_id)

## Weighted-random, not winner-take-all -- a map with 3 of 4 votes is much
## more likely to be picked than one with 1, but never guaranteed, matching
## "randomly decide with % based on votes." No votes at all (nobody voted,
## or voting isn't surfaced on this screen) keeps today's behavior: "" ends
## up chosen, which ServerMatch already treats as the built-in default arena.
func _pick_voted_level(lobby: Dictionary) -> String:
	var votes: Dictionary = lobby.get("map_votes", {})
	if votes.is_empty():
		return ""
	var tally := {}
	for voted_id in votes.values():
		tally[voted_id] = int(tally.get(voted_id, 0)) + 1
	var total := 0
	for count in tally.values():
		total += int(count)
	var roll := randi_range(1, total)
	var cumulative := 0
	for voted_id in tally.keys():
		cumulative += int(tally[voted_id])
		if roll <= cumulative:
			return voted_id
	return votes.values()[0] # unreachable in practice, keeps the return type honest

@rpc("any_peer", "reliable")
func _server_start_match() -> void:
	if not is_server:
		return
	var sender := multiplayer.get_remote_sender_id()
	var lobby_id: int = _peer_lobby.get(sender, -1)
	if lobby_id == -1 or not _lobbies.has(lobby_id):
		return
	var lobby: Dictionary = _lobbies[lobby_id]
	# Playlist lobbies auto-start on fill (_maybe_autostart_playlist_lobby)
	# and never expose a manual Start button client-side -- reject it
	# server-side too rather than trusting the client didn't send it anyway.
	if lobby.host_peer != sender or lobby.in_match or lobby.members.is_empty() or not lobby.get("playlist", "").is_empty():
		return
	_begin_match_sequence(lobby_id, false)

## A ranked server has no manual lobby-naming/browsing/Ready/Start step --
## everyone who connects is auto-added to the one reserved ranked lobby
## (recreated fresh after each round, see notify_match_ended), and the round
## auto-starts as soon as MIN_RANKED_PLAYERS are in it.
func _join_ranked_lobby(sender: int) -> void:
	# Playlist set -> exact headcount, team-mode-aware; empty -> the legacy
	# undifferentiated free-for-all pool (any headcount 2-8), same fallback
	# server_main.gd/is_ranked_server already follow for a process launched
	# without a matching flag.
	var target_size: int = PlaylistCatalog.total_players(playlist_id) if not playlist_id.is_empty() else MAX_LOBBY_PLAYERS
	var start_threshold: int = target_size if not playlist_id.is_empty() else MIN_RANKED_PLAYERS
	if _ranked_lobby_id == -1 or not _lobbies.has(_ranked_lobby_id) or _lobbies[_ranked_lobby_id].in_match:
		_ranked_lobby_id = _next_lobby_id
		_next_lobby_id += 1
		_lobbies[_ranked_lobby_id] = {
			"id": _ranked_lobby_id, "name": "Ranked Match", "host_peer": sender,
			"max_players": target_size, "members": {}, "in_match": false, "ranked": true,
			"playlist": playlist_id, "map_votes": {}, "voting_open": false,
		}
	var lobby: Dictionary = _lobbies[_ranked_lobby_id]
	if lobby.members.size() >= lobby.max_players:
		return # full -- rare, the directory listing should already hide a full ranked server from new searches
	lobby.members[sender] = _member_entry(sender, true)
	_peer_lobby[sender] = _ranked_lobby_id
	_broadcast_lobby_list()
	_send_lobby_state(_ranked_lobby_id)
	if lobby.members.size() >= start_threshold:
		_begin_match_sequence(_ranked_lobby_id, true)
	elif not playlist_id.is_empty() and not lobby.get("bot_fill_scheduled", false):
		# The legacy undifferentiated pool (empty playlist_id) keeps its
		# original wait-for-MIN_RANKED_PLAYERS-forever behavior -- bot-fill
		# only applies to a real playlist queue, where "how many bots" has an
		# unambiguous answer (PlaylistCatalog.total_players()).
		lobby["bot_fill_scheduled"] = true
		get_tree().create_timer(BOT_FILL_WAIT_SEC).timeout.connect(_on_bot_fill_timeout.bind(_ranked_lobby_id))

## Fires BOT_FILL_WAIT_SEC after a real player joins a playlist lobby
## (ranked or casual) that didn't immediately reach full headcount -- tops
## the remaining slots up with bots (see ServerMatch/npc.gd) scaled to
## whoever's actually queued's own elo, then starts the match through the
## exact same _begin_match_sequence() path a naturally-full lobby uses
## (ranked/casual determined by the lobby's own "ranked" flag, so this one
## function serves both callers unchanged). Bots are never
## added to `lobby.members` itself (that dict's keys double as "who to RPC
## to" everywhere else in this file) -- they ride along separately via
## `lobby["bots"]`, merged into the roster only once _start_match_for_lobby
## builds ServerMatch's member dict.
func _on_bot_fill_timeout(lobby_id: int) -> void:
	if not _lobbies.has(lobby_id):
		return
	var lobby: Dictionary = _lobbies[lobby_id]
	if lobby.in_match or lobby.members.is_empty():
		return
	if lobby.max_players - lobby.members.size() <= 0:
		return
	var skill_level: int = await _compute_bot_skill_level(lobby)
	# Re-check after the await -- the elo lookup can take a couple seconds,
	# during which the lobby could have filled naturally, emptied entirely,
	# or already started.
	if not _lobbies.has(lobby_id):
		return
	lobby = _lobbies[lobby_id]
	if lobby.in_match or lobby.members.is_empty():
		return
	var needed: int = lobby.max_players - lobby.members.size()
	if needed <= 0:
		return
	var bots := {}
	for i in needed:
		var bot_id := -(i + 1)
		bots[bot_id] = {
			"username": _bot_name(i), "color_id": PlayerColors.id_for_peer(bot_id),
			"is_bot": true, "skill_level": skill_level,
		}
	lobby["bots"] = bots
	_begin_match_sequence(lobby_id, lobby.get("ranked", false))

## Bots get harder as the real players queueing for them are better --
## averages every real member's own elo for this lobby's playlist (same
## per-client lookup ServerMatch._fill_ranked_stats does post-match, just
## earlier and averaged across whoever's actually waiting) and maps that
## onto NPC's existing 1-5 skill_level via the same Bronze..Diamond tier
## boundaries rank badges already use, so "Diamond bots" and "a Diamond
## player" mean the same thing intuitively. A brand-new/unresolvable player
## (no client_id, or a lookup that fails) defaults to the easiest bots
## rather than guessing high.
func _compute_bot_skill_level(lobby: Dictionary) -> int:
	var lobby_playlist: String = lobby.get("playlist", "")
	var total := 0
	var resolved := 0
	for peer_id in lobby.members.keys():
		var client_id: String = _peer_client_id.get(peer_id, "")
		if client_id.is_empty():
			continue
		var elo := await _fetch_elo(client_id, lobby_playlist)
		if elo > 0:
			total += elo
			resolved += 1
	var avg_elo: int = int(float(total) / resolved) if resolved > 0 else RankTiers.TIERS[0].min_elo
	for i in range(RankTiers.TIERS.size() - 1, -1, -1):
		if avg_elo >= int(RankTiers.TIERS[i].min_elo):
			return i + 1
	return 1

## GET-only lookup, same endpoint/shape ServerMatch.RANKED_LOOKUP_URL already
## fetches per-match -- reused directly (one URL, no second copy to keep in
## sync) rather than duplicating the string here.
func _fetch_elo(client_id: String, playlist: String) -> int:
	var req := HTTPRequest.new()
	req.timeout = 3.0
	add_child(req)
	req.request(ServerMatch.RANKED_LOOKUP_URL % client_id + "?playlist=" + playlist.uri_encode())
	var result: Array = await req.request_completed
	req.queue_free()
	var response_code: int = result[1]
	var body: PackedByteArray = result[3]
	if response_code == 200:
		var parsed = JSON.parse_string(body.get_string_from_utf8())
		if typeof(parsed) == TYPE_DICTIONARY and parsed.has("elo"):
			return int(parsed.elo)
	return -1

func _bot_name(index: int) -> String:
	return "[Bot] " + BOT_NAMES[index % BOT_NAMES.size()]

## The moment a lobby is ready to start (fill/host-start/ranked-threshold
## reached), map selection becomes a timed pop-up vote instead of the match
## starting immediately -- locks the lobby (in_match=true, same timing as
## before, which already keeps it out of the server list via
## _lobby_summaries() and blocks new joins via _join_lobby_internal/
## _join_ranked_lobby's existing in_match checks) and broadcasts a
## vote-start to every member, then waits up to MAP_VOTE_DURATION_SEC before
## resolving the winner and starting a short countdown -- resolved sooner if
## every voter (members + bots, see _maybe_resolve_map_vote_early) has
## already voted, so a full lobby isn't stuck waiting out a timer nobody
## needs. Every match gets this, including a party's auto-started Private
## match (is_party_private still skips the manual Start button/share-address
## panel -- see lobby_room.gd -- just not the map picker itself, which runs
## before the circle reveal like any other match's map vote runs before its
## own intro).
func _begin_match_sequence(lobby_id: int, ranked: bool) -> void:
	if not _lobbies.has(lobby_id):
		return
	var lobby: Dictionary = _lobbies[lobby_id]
	lobby.in_match = true
	lobby["voting_open"] = true
	# Stashed on the lobby itself (not just threaded through as a bound timer
	# arg) so the early-resolve path (triggered from a vote RPC, which has no
	# other way to know this match's ranked-ness) can read it too.
	lobby["ranked"] = ranked
	_broadcast_lobby_list()
	for peer_id in lobby.members.keys():
		rpc_id(peer_id, "_client_map_vote_started", MAP_VOTE_DURATION_SEC)
	# Bots vote too (staggered, so a full-bot lobby doesn't resolve in a
	# single instant frame) -- see _bot_submit_map_vote.
	for bot_id in lobby.get("bots", {}).keys():
		get_tree().create_timer(randf_range(0.6, 3.5)).timeout.connect(_bot_submit_map_vote.bind(lobby_id, bot_id))
	_send_lobby_state(lobby_id) # so clients see the bot roster (for the ballot row) right away, not just once a vote trickles in
	get_tree().create_timer(MAP_VOTE_DURATION_SEC).timeout.connect(_on_map_vote_timeout.bind(lobby_id))

func _bot_submit_map_vote(lobby_id: int, bot_id: int) -> void:
	if not _lobbies.has(lobby_id):
		return
	var lobby: Dictionary = _lobbies[lobby_id]
	if not lobby.get("voting_open", false):
		return
	if not lobby.has("map_votes"):
		lobby["map_votes"] = {}
	lobby["map_votes"][bot_id] = OnlineMapCatalog.MAP_ORDER[randi() % OnlineMapCatalog.MAP_ORDER.size()]
	_send_lobby_state(lobby_id)
	_maybe_resolve_map_vote_early(lobby_id)

## Called after every vote (real or bot) lands -- once every voter this
## lobby actually has (members + bots) has one in, there's nothing left to
## wait MAP_VOTE_DURATION_SEC out for.
func _maybe_resolve_map_vote_early(lobby_id: int) -> void:
	if not _lobbies.has(lobby_id):
		return
	var lobby: Dictionary = _lobbies[lobby_id]
	if not lobby.get("voting_open", false):
		return
	var total_voters: int = lobby.members.size() + lobby.get("bots", {}).size()
	if lobby.get("map_votes", {}).size() >= total_voters:
		_resolve_map_vote(lobby_id)

## `_lobbies.has(lobby_id)` can fail here if every member left during the
## voting window (see _remove_peer_from_lobby's empty-lobby teardown) --
## nothing left to start, so just quietly do nothing rather than resurrect
## an abandoned lobby.
func _on_map_vote_timeout(lobby_id: int) -> void:
	_resolve_map_vote(lobby_id)

## The actual "voting's over" transition -- shared by the MAP_VOTE_DURATION_
## SEC timeout and the early-everyone-voted path, guarded by voting_open so
## whichever one fires first is the only one that does anything (the other
## finds voting_open already false and no-ops).
func _resolve_map_vote(lobby_id: int) -> void:
	if not _lobbies.has(lobby_id):
		return
	var lobby: Dictionary = _lobbies[lobby_id]
	if not lobby.get("voting_open", false):
		return
	lobby["voting_open"] = false
	var chosen_level_id := _pick_voted_level(lobby)
	for peer_id in lobby.members.keys():
		rpc_id(peer_id, "_client_map_vote_ended", chosen_level_id, MAP_VOTE_COUNTDOWN_SEC)
	get_tree().create_timer(MAP_VOTE_COUNTDOWN_SEC).timeout.connect(_start_match_for_lobby.bind(lobby_id, lobby.get("ranked", false), chosen_level_id))

func _start_match_for_lobby(lobby_id: int, ranked: bool, chosen_level_id: String) -> void:
	if not _lobbies.has(lobby_id):
		return
	var lobby: Dictionary = _lobbies[lobby_id]
	var lobby_playlist: String = lobby.get("playlist", "")
	var members_with_extras: Dictionary = lobby.members.duplicate(true)
	# Bots (see _on_bot_fill_timeout) never live in lobby.members itself --
	# that dict's keys double as "who to RPC to" everywhere else in this
	# file, and a bot's negative synthetic id has no real connection behind
	# it. They only join the roster here, right at match construction.
	var bots: Dictionary = lobby.get("bots", {})
	for bot_id in bots.keys():
		members_with_extras[bot_id] = bots[bot_id]
	if PlaylistCatalog.is_team_mode(lobby_playlist):
		var peer_party_id := {}
		for peer_id in members_with_extras.keys():
			peer_party_id[peer_id] = members_with_extras[peer_id].get("party_id", "")
		var teams := PlaylistCatalog.assign_teams_grouped(members_with_extras.keys(), peer_party_id, PlaylistCatalog.team_count(lobby_playlist), PlaylistCatalog.team_size(lobby_playlist))
		for peer_id in teams.keys():
			members_with_extras[peer_id]["team"] = teams[peer_id]
	# Fixed slot colors (red/blue/yellow/green) for the 4 official playlists,
	# overriding each peer's (and each bot's) own otherwise-stable per-
	# connection color -- see PlaylistCatalog.slot_colors_for(). Empty for
	# anything else (legacy undifferentiated pool, a private match), so
	# those fall through to today's per-peer color unchanged.
	var slot_colors := PlaylistCatalog.slot_colors_for(lobby_playlist, members_with_extras)
	for peer_id in members_with_extras.keys():
		if slot_colors.has(peer_id):
			members_with_extras[peer_id]["color_id"] = slot_colors[peer_id]
		elif not members_with_extras[peer_id].get("is_bot", false):
			# A bot outside the 4 known playlists keeps the color_id already
			# set when it was created (_on_bot_fill_timeout) -- _peer_color_id
			# only ever tracks real connections, it has nothing for a bot.
			members_with_extras[peer_id]["color_id"] = _peer_color_id.get(peer_id, PlayerColors.DEFAULT_ID)
		if not members_with_extras[peer_id].get("is_bot", false):
			members_with_extras[peer_id]["client_id"] = _peer_client_id.get(peer_id, "")
	var match_instance := ServerMatch.new(self, lobby_id, members_with_extras, ranked, chosen_level_id)
	match_instance.playlist_id = lobby_playlist
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
func notify_match_started(lobby_id: int, roster: Dictionary, match_level_id: String, match_playlist_id: String = "") -> void:
	for peer_id in roster.keys():
		rpc_id(peer_id, "_client_match_started", lobby_id, peer_id, roster, match_level_id, match_playlist_id)

## Called by ServerMatch every physics tick.
func push_match_state(peer_id: int, tick: int, states: Dictionary) -> void:
	rpc_id(peer_id, "_client_receive_match_state", tick, states)

## Called by ServerMatch once a round's timer runs out (ranked or casual --
## both are now a one-shot with a real duration, see server_match.gd's
## RANKED_ROUND_DURATION_SEC/CASUAL_ROUND_DURATION_SEC). There's no "return
## to the same lobby for another round," so this tears the match/lobby down
## the same way a fully-emptied one would, after fanning the result out and,
## only for a ranked match, reporting it to the relay for ELO.
func notify_match_ended(lobby_id: int, ranking: Array, ranked: bool) -> void:
	for entry in ranking:
		rpc_id(entry.peer_id, "_client_match_ended", ranking)
		_peer_lobby.erase(entry.peer_id)
	if ranked:
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
	# notify_match_ended's only caller now fires this for ranked matches only
	# (round_ended itself emits for casual too, see tag_mode.gd) -- so this
	# process's own playlist_id always is the match's playlist,
	# one-playlist-per-process (see the field's own doc).
	var body := JSON.stringify({"results": results, "playlist": playlist_id})
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
func _client_match_started(lobby_id: int, my_id: int, roster: Dictionary, match_level_id: String, match_playlist_id: String = "") -> void:
	my_peer_id = my_id
	match_started.emit(lobby_id, my_id, roster, match_level_id, match_playlist_id)

@rpc("authority", "unreliable_ordered")
func _client_receive_match_state(tick: int, states: Dictionary) -> void:
	match_state_received.emit(tick, states)

@rpc("authority", "reliable")
func _client_match_ended(ranking: Array) -> void:
	match_ended.emit(ranking)

@rpc("authority", "reliable")
func _client_spectate_failed() -> void:
	spectate_failed.emit()

@rpc("authority", "reliable")
func _client_map_vote_started(duration: float) -> void:
	map_vote_phase_started.emit(duration)

@rpc("authority", "reliable")
func _client_map_vote_ended(chosen_level_id: String, countdown: float) -> void:
	map_vote_phase_ended.emit(chosen_level_id, countdown)

# ==================== Client-facing API (called by UI) ====================

func set_username(display_name: String) -> void:
	username = display_name

func create_lobby(lobby_name: String, max_players: int, playlist_id: String = "") -> void:
	rpc_id(1, "_server_create_lobby", lobby_name, max_players, playlist_id)

func join_lobby(lobby_id: int) -> void:
	rpc_id(1, "_server_join_lobby", lobby_id)

func quick_join_lobby(playlist_id: String = "") -> void:
	rpc_id(1, "_server_quick_join_lobby", playlist_id)

func leave_lobby() -> void:
	rpc_id(1, "_server_leave_lobby")
	current_lobby = {}

func set_ready(ready: bool) -> void:
	rpc_id(1, "_server_set_ready", ready)

## `level_id` is "" for the built-in default arena, or a custom level's id
## (see MapVoteView) -- see _pick_voted_level() for how the tally of every
## member's vote turns into the one map that's actually played.
func submit_map_vote(level_id: String) -> void:
	rpc_id(1, "_server_submit_map_vote", level_id)

func start_match() -> void:
	rpc_id(1, "_server_start_match")

func submit_input(input: Dictionary) -> void:
	rpc_id(1, "_server_submit_input", input)
