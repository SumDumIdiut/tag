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
# directions, every frame. The relay and this bridge have no idea they're
# carrying Godot multiplayer traffic; it's a pure byte pipe.

const HEARTBEAT_INTERVAL_SEC := 5.0
const RECONNECT_DELAY_SEC := 5.0
# Generous headroom -- up to MAX_LOBBY_PLAYERS worth of match state can be
# pushed every physics tick; relying on WebSocketPeer's small defaults here
# risks silently dropped or errored packets under load.
const BRIDGE_BUFFER_SIZE := 1 << 20 # 1 MiB

var relay_url: String
var server_name: String
var max_players: int
var local_port: int

var _control: WebSocketPeer = null
var _server_id: String = ""
var _register_sent := false
var _heartbeat_timer: Timer
var _reconnect_timer: Timer
var _pairs: Array[_BridgePair] = []

class _BridgePair:
	var relay_leg: WebSocketPeer
	var local_leg: WebSocketPeer
	var closing := false

func _init(p_relay_url: String, p_name: String, p_max_players: int, p_local_port: int) -> void:
	relay_url = p_relay_url
	server_name = p_name
	max_players = p_max_players
	local_port = p_local_port

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

func _process(_delta: float) -> void:
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
			_send_json(_control, {"type": "register", "name": server_name, "maxPlayers": max_players})
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
		"connect_request":
			_start_bridge(str(msg.get("token", "")))

func _send_heartbeat() -> void:
	if _control == null or _control.get_ready_state() != WebSocketPeer.STATE_OPEN or _server_id.is_empty():
		return
	_send_json(_control, {"type": "heartbeat", "playerCount": NetworkManager.get_player_count()})

func _send_json(peer: WebSocketPeer, data: Dictionary) -> void:
	peer.send_text(JSON.stringify(data))

func _start_bridge(token: String) -> void:
	if token.is_empty():
		return
	var relay_leg := WebSocketPeer.new()
	relay_leg.inbound_buffer_size = BRIDGE_BUFFER_SIZE
	relay_leg.outbound_buffer_size = BRIDGE_BUFFER_SIZE
	var data_url := relay_url.replace("/relay/host", "/relay/data/" + token)
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
