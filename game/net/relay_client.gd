extends Node
class_name RelayClient

# Registers a locally-running dedicated server with the relay/directory
# backend (relay-server/server.js) and bridges each incoming player through
# it, so the host needs no port-forwarding or their own tunnel.
#
# Protocol: one long-lived "control" WebSocketPeer to {relay_url} (which ends
# in /relay/host) carries register/heartbeat/connect_request JSON messages.
# For each connect_request, this opens a *second* outbound WebSocketPeer to
# the matching /relay/data/<token> endpoint, plus a plain loopback
# WebSocketPeer into the server's own already-listening WebSocketMultiplayerPeer
# on 127.0.0.1 -- then just forwards raw packets between those two, in both
# directions, every physics tick. The relay and this bridge have no idea
# they're carrying Godot multiplayer traffic; it's a pure byte pipe.
#
# Polls from _physics_process, not _process -- this bridge carries every
# relay-routed match's real gameplay bytes (the production path for anyone
# found via the server browser, not just direct-IP connections), and those
# are paced to the 60Hz physics tick on both ends. Polling from the idle/
# render-frame callback instead would leave this hop riding whatever frame
# rate this process happens to render at, same issue NetworkManager's own
# RPC dispatch was decoupled from -- see its _ready()'s
# set_multiplayer_poll_enabled(false) for the other half of this fix.

const HEARTBEAT_INTERVAL_SEC := 5.0
const RECONNECT_DELAY_SEC := 5.0
# Separate from (and faster than) the heartbeat above -- HEARTBEAT_INTERVAL_SEC
# is sized for "is this server still alive," which 5s is plenty responsive
# for; the website's live match viewer (watch.html) wants to feel closer to
# live than that. Matches ServerMatch's own STATE_SUMMARY_INTERVAL_TICKS
# (15 ticks @ 60Hz = 250ms) -- was 100ms, dialed back after noticeable
# real-gameplay input lag on a machine already busy hosting several
# matches; watch.html interpolates client-side regardless, so this only
# trades a little freshness for meaningfully less work on this process's
# own main thread. The relay pushes each of these straight to any browser
# watching over its own WebSocket the moment it arrives (see relay-server's
# "match_state" broadcast) rather than making the browser poll for it.
const MATCH_STATE_INTERVAL_SEC := 0.25
# Generous headroom -- up to MAX_LOBBY_PLAYERS worth of match state can be
# pushed every physics tick; relying on WebSocketPeer's small defaults here
# risks silently dropped or errored packets under load.
const BRIDGE_BUFFER_SIZE := 1 << 20 # 1 MiB

var relay_url: String
var server_name: String
var max_players: int
var local_port: int
var ranked: bool
var playlist: String
## A private match (server_main.gd's --private) still registers with the
## relay like any other server -- otherwise a party member on a different
## network than the host could never reach it, LAN sharing being the only
## alternative -- it just never appears in /api/servers, so it can't be
## publicly browsed or auto-picked by casual/ranked matchmaking. See
## relay-server/server.js's own registration handler and its
## handlePartyQueueStart, which is how a following party member still
## reaches this exact server despite the public directory staying blind
## to it.
var unlisted: bool
## See C:\Users\Flipped\.claude\plans\humming-coalescing-otter.md, Phase 2.
## When true, _start_bridge() below hands each incoming join straight to
## NetworkManager.accept_webrtc_peer() as a signaling channel instead of
## opening a second (local_port) WebSocketPeer leg and blind-forwarding
## bytes between the two -- the whole point of WebRTC is that real
## gameplay traffic never flows through this process at all once
## negotiated, only the small offer/answer/candidate exchange does. Set
## by server_main.gd's --webrtc flag; NetworkManager itself must already
## be running start_server_webrtc() (not start_server()) for this to make
## sense, since accept_webrtc_peer() assumes a WebRTCMultiplayerPeer is
## already the active multiplayer_peer.
var use_webrtc: bool

var _control: WebSocketPeer = null
var _server_id: String = ""
var _register_sent := false
var _heartbeat_timer: Timer
var _reconnect_timer: Timer
var _match_state_timer: Timer
var _pairs: Array[_BridgePair] = []

class _BridgePair:
	var relay_leg: WebSocketPeer
	var local_leg: WebSocketPeer
	var closing := false

func _init(p_relay_url: String, p_name: String, p_max_players: int, p_local_port: int, p_ranked: bool = false, p_playlist: String = "", p_unlisted: bool = false, p_use_webrtc: bool = false) -> void:
	relay_url = p_relay_url
	server_name = p_name
	max_players = p_max_players
	local_port = p_local_port
	ranked = p_ranked
	playlist = p_playlist
	unlisted = p_unlisted
	use_webrtc = p_use_webrtc

func _ready() -> void:
	_heartbeat_timer = Timer.new()
	_heartbeat_timer.wait_time = HEARTBEAT_INTERVAL_SEC
	_heartbeat_timer.timeout.connect(_send_heartbeat)
	add_child(_heartbeat_timer)

	_reconnect_timer = Timer.new()
	_reconnect_timer.wait_time = RECONNECT_DELAY_SEC
	_reconnect_timer.one_shot = true
	_reconnect_timer.timeout.connect(_connect_control)
	add_child(_reconnect_timer)

	_match_state_timer = Timer.new()
	_match_state_timer.wait_time = MATCH_STATE_INTERVAL_SEC
	_match_state_timer.timeout.connect(_send_match_state)
	add_child(_match_state_timer)

	_connect_control()

func _connect_control() -> void:
	_control = WebSocketPeer.new()
	_control.inbound_buffer_size = BRIDGE_BUFFER_SIZE
	_control.outbound_buffer_size = BRIDGE_BUFFER_SIZE
	var err := _control.connect_to_url(relay_url)
	if err != OK:
		push_warning("RelayClient: failed to start connecting to relay (%s) -- retrying in %ds" % [err, RECONNECT_DELAY_SEC])
		_control = null
		_reconnect_timer.start()
		return
	print("RelayClient: connecting to relay at %s" % relay_url)

func _physics_process(_delta: float) -> void:
	_poll_control()
	_poll_pairs()

func _poll_control() -> void:
	if _control == null:
		return
	_control.poll()
	var state := _control.get_ready_state()
	if state == WebSocketPeer.STATE_OPEN:
		if _server_id.is_empty() and not _register_sent:
			# Registering is a request/reply round-trip over a real network
			# link, so several frames pass before "registered" comes back --
			# without this flag, the is_empty() check alone re-fires on every
			# one of those frames and the relay ends up with a pile of
			# duplicate registrations for what's really one server.
			_register_sent = true
			_send_json(_control, {"type": "register", "name": server_name, "maxPlayers": max_players, "ranked": ranked, "playlist": playlist, "unlisted": unlisted, "webrtc": use_webrtc})
		while _control.get_available_packet_count() > 0:
			_handle_control_message(_control.get_packet())
	elif state == WebSocketPeer.STATE_CLOSED:
		# Already-spliced player<->host data pairs are independent sockets and
		# are untouched by this -- only *new* joins stop being possible until
		# we reconnect and re-register.
		if not _server_id.is_empty():
			print("RelayClient: control channel closed -- reconnecting in %ds" % RECONNECT_DELAY_SEC)
		_server_id = ""
		_register_sent = false
		_control = null
		_heartbeat_timer.stop()
		_match_state_timer.stop()
		_reconnect_timer.start()

func _handle_control_message(raw: PackedByteArray) -> void:
	var parsed = JSON.parse_string(raw.get_string_from_utf8())
	if typeof(parsed) != TYPE_DICTIONARY:
		return
	var msg: Dictionary = parsed
	match msg.get("type", ""):
		"registered":
			_server_id = str(msg.get("serverId", ""))
			print("RelayClient: registered as server id %s" % _server_id)
			_heartbeat_timer.start()
			_send_heartbeat()
			_match_state_timer.start()
		"connect_request":
			_start_bridge(str(msg.get("token", "")))

func _send_heartbeat() -> void:
	if _control == null or _control.get_ready_state() != WebSocketPeer.STATE_OPEN or _server_id.is_empty():
		return
	_send_json(_control, {
		"type": "heartbeat",
		"playerCount": NetworkManager.get_player_count(),
		"clientIds": NetworkManager.get_connected_client_ids(),
	})

## One message per currently in-progress lobby on this server (usually just
## one in practice) -- see NetworkManager.latest_match_summaries, kept
## updated by each lobby's own ServerMatch. Silently sends nothing if no
## match is in progress right now, rather than an empty/stale message.
func _send_match_state() -> void:
	if _control == null or _control.get_ready_state() != WebSocketPeer.STATE_OPEN or _server_id.is_empty():
		return
	for lobby_id in NetworkManager.latest_match_summaries.keys():
		var summary: Dictionary = NetworkManager.latest_match_summaries[lobby_id]
		_send_json(_control, {
			"type": "match_state",
			"players": summary.get("players", []),
			"timeRemaining": summary.get("timeRemaining", 0.0),
			"arenaWidth": summary.get("arenaWidth", 0.0),
			"arenaHeight": summary.get("arenaHeight", 0.0),
			"arenaCenterX": summary.get("arenaCenterX", 0.0),
			"arenaCenterY": summary.get("arenaCenterY", 0.0),
			"levelId": summary.get("levelId", ""),
		})

func _send_json(peer: WebSocketPeer, data: Dictionary) -> void:
	peer.send_text(JSON.stringify(data))

func _start_bridge(token: String) -> void:
	if token.is_empty():
		return
	var data_url := relay_url.replace("/relay/host", "/relay/data/" + token)
	if use_webrtc:
		# No local_leg, no byte-bridging at all -- this WS is purely a
		# signaling channel now (see WebRTCSignalingChannel's own header
		# comment: relay-server.js's splice() forwards these same bytes
		# without caring that they're JSON instead of raw multiplayer
		# packets). Real gameplay traffic goes directly between the
		# joining player and this process's WebRTCPeerConnection once
		# negotiated -- this process is never in that path again.
		var channel := WebRTCSignalingChannel.for_url(data_url)
		NetworkManager.accept_webrtc_peer(channel)
		return

	var relay_leg := WebSocketPeer.new()
	relay_leg.inbound_buffer_size = BRIDGE_BUFFER_SIZE
	relay_leg.outbound_buffer_size = BRIDGE_BUFFER_SIZE
	if relay_leg.connect_to_url(data_url) != OK:
		push_warning("RelayClient: failed to open data leg for token %s" % token)
		return

	var local_leg := WebSocketPeer.new()
	local_leg.inbound_buffer_size = BRIDGE_BUFFER_SIZE
	local_leg.outbound_buffer_size = BRIDGE_BUFFER_SIZE
	if local_leg.connect_to_url("ws://127.0.0.1:%d" % local_port) != OK:
		push_warning("RelayClient: failed to open local loopback leg for token %s" % token)
		return

	var pair := _BridgePair.new()
	pair.relay_leg = relay_leg
	pair.local_leg = local_leg
	_pairs.append(pair)

func _poll_pairs() -> void:
	var i := _pairs.size() - 1
	while i >= 0:
		var pair := _pairs[i]
		pair.relay_leg.poll()
		pair.local_leg.poll()

		_forward(pair.relay_leg, pair.local_leg)
		_forward(pair.local_leg, pair.relay_leg)

		var relay_done := pair.relay_leg.get_ready_state() == WebSocketPeer.STATE_CLOSED
		var local_done := pair.local_leg.get_ready_state() == WebSocketPeer.STATE_CLOSED
		if relay_done or local_done:
			if not pair.closing:
				# Ask the still-open side to close gracefully rather than
				# yanking the pair immediately -- keeps polling (above) so
				# any in-flight packets on it still get drained/forwarded
				# before removal below.
				pair.closing = true
				if not relay_done and pair.relay_leg.get_ready_state() == WebSocketPeer.STATE_OPEN:
					pair.relay_leg.close()
				if not local_done and pair.local_leg.get_ready_state() == WebSocketPeer.STATE_OPEN:
					pair.local_leg.close()
			elif relay_done and local_done:
				_pairs.remove_at(i)
		i -= 1

func _forward(from_peer: WebSocketPeer, to_peer: WebSocketPeer) -> void:
	if to_peer.get_ready_state() != WebSocketPeer.STATE_OPEN:
		return
	while from_peer.get_available_packet_count() > 0:
		to_peer.send(from_peer.get_packet())

## Called by server_main.gd on graceful shutdown so the listing disappears
## immediately instead of lingering until the heartbeat timeout.
func shutdown() -> void:
	if _control != null and _control.get_ready_state() == WebSocketPeer.STATE_OPEN and not _server_id.is_empty():
		_send_json(_control, {"type": "unregister"})
		_control.poll()
	for pair in _pairs:
		pair.relay_leg.close()
		pair.local_leg.close()
