extends Node
class_name WebRTCSignalingChannel

# One JSON signaling channel between a connecting client and the dedicated
# server while a single WebRTCPeerConnection negotiates (offer/answer/ICE
# candidates) -- never carries real gameplay traffic, that's the
# WebRTCPeerConnection's own data channels once negotiation finishes (see
# network_manager.gd's accept_webrtc_peer/_start_client_webrtc). Wraps a
# raw WebSocketPeer -- for_loopback_client/for_loopback_stream are a
# same-machine hosting pair (127.0.0.1); for_url wraps an arbitrary
# ws://.../wss://... connection, used both for a real relay-routed client
# join (network_manager.gd's start_client_webrtc_relay) and by
# relay_client.gd's own outbound /relay/data/<token> leg on the dedicated
# server side -- same message shape either way, relay-server.js's
# splice() just forwards bytes without caring what's inside them.

signal message_received(msg: Dictionary)
signal closed

var _ws: WebSocketPeer
## WebRTCPeerConnection.session_description_created fires (and this class's
## send() gets called for the offer) essentially immediately after
## create_offer() -- confirmed live even a loopback WS handshake to
## 127.0.0.1 hadn't reached STATE_OPEN yet at that point, so the offer
## (and any candidate gathered before the handshake finishes) was
## silently dropped by send()'s old "only if already open" guard,
## stalling the whole negotiation with nothing to show for it. Queue
## instead, flush once the socket actually opens.
var _pending: Array[Dictionary] = []
## A second, real-world race, confirmed live over the actual relay path
## (loopback never hits this -- both ends exist locally already): the
## connecting client's /relay/join/<serverId> leg opens and this class
## flushes the queued offer onto it well before the dedicated server's
## OWN /relay/data/<token> leg has even connected, let alone before
## relay-server.js's splice() has paired the two sockets together.
## relay-server.js's handlePlayerJoin never attaches a 'message' listener
## to the player's raw ws until splice() runs, so anything that arrives
## in that gap is just gone -- Node's EventEmitter doesn't buffer
## unlistened events. There's no application-level ack for a single
## offer/candidate send to know it actually got through, so the fix is
## the standard one for exactly this class of one-shot-message-over-an-
## not-yet-fully-wired-pipe problem: resend everything sent so far on a
## short timer until something comes back, proving the pipe is actually
## live end to end. Confirmed live: the dedicated server's own leg
## reaches OPEN and stays open for the client's whole (generous) timeout
## without ever receiving anything, then gets torn down abruptly only
## because the client itself gave up and exited -- not a transport
## failure, a lost first message with no retry.
var _sent_history: Array[Dictionary] = []
var _confirmed := false
var _resend_elapsed := 0.0
var _resend_attempts := 0
const RESEND_INTERVAL_SEC := 0.75
## Comfortably under relay-server.js's own JOIN_TIMEOUT_MS (10s) for the
## token this channel was opened with -- no point retrying past the point
## the token itself would already be expired server-side.
const MAX_RESEND_ATTEMPTS := 10

static func for_loopback_client(port: int) -> WebRTCSignalingChannel:
	var chan := WebRTCSignalingChannel.new()
	chan._ws = WebSocketPeer.new()
	chan._ws.connect_to_url("ws://127.0.0.1:%d" % port)
	return chan

static func for_loopback_stream(stream: StreamPeerTCP) -> WebRTCSignalingChannel:
	var chan := WebRTCSignalingChannel.new()
	chan._ws = WebSocketPeer.new()
	chan._ws.accept_stream(stream)
	return chan

## `url` is a full ws://.../wss://... address -- same convention
## NetworkManager.start_client()/_normalize_address already use, not a
## bare host:port.
static func for_url(url: String) -> WebRTCSignalingChannel:
	var chan := WebRTCSignalingChannel.new()
	chan._ws = WebSocketPeer.new()
	chan._ws.connect_to_url(url)
	return chan

func _process(delta: float) -> void:
	if _ws == null:
		return
	_ws.poll()
	var state := _ws.get_ready_state()
	if state == WebSocketPeer.STATE_OPEN:
		if not _pending.is_empty():
			for msg in _pending:
				_ws.send_text(JSON.stringify(msg))
			_pending.clear()
		while _ws.get_available_packet_count() > 0:
			var parsed = JSON.parse_string(_ws.get_packet().get_string_from_utf8())
			if typeof(parsed) == TYPE_DICTIONARY:
				_confirmed = true # the pipe is genuinely live end to end -- stop resending
				message_received.emit(parsed)
		if not _confirmed and not _sent_history.is_empty():
			_resend_elapsed += delta
			if _resend_elapsed >= RESEND_INTERVAL_SEC:
				_resend_elapsed = 0.0
				_resend_attempts += 1
				if _resend_attempts <= MAX_RESEND_ATTEMPTS:
					for msg in _sent_history:
						_ws.send_text(JSON.stringify(msg))
	elif state == WebSocketPeer.STATE_CLOSED:
		set_process(false)
		closed.emit()

func send(msg: Dictionary) -> void:
	if _ws == null:
		return
	_sent_history.append(msg)
	if _ws.get_ready_state() == WebSocketPeer.STATE_OPEN:
		_ws.send_text(JSON.stringify(msg))
	else:
		_pending.append(msg)

func close() -> void:
	if _ws != null:
		_ws.close()
	set_process(false)
