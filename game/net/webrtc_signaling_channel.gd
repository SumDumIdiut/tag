extends Node
class_name WebRTCSignalingChannel

# One JSON signaling channel between a connecting client and the dedicated
# server while a single WebRTCPeerConnection negotiates (offer/answer/ICE
# candidates) -- never carries real gameplay traffic, that's the
# WebRTCPeerConnection's own data channels once negotiation finishes (see
# network_manager.gd's start_server_webrtc_loopback/
# start_client_webrtc_loopback). Wraps a raw WebSocketPeer, client or
# server side of one -- Phase 2 adds a relay-routed variant carrying the
# exact same message shape over the existing relay-server.js connection.

signal message_received(msg: Dictionary)
signal closed

var _ws: WebSocketPeer
## WebRTCPeerConnection.session_description_created fires (and this class's
## send() gets called for the offer) essentially immediately after
## create_offer() -- confirmed live even the CLIENT's own loopback WS
## handshake to 127.0.0.1 hadn't reached STATE_OPEN yet at that point, so
## the offer (and any candidate gathered before the handshake finishes)
## was silently dropped by send()'s old "only if already open" guard,
## stalling the whole negotiation with nothing to show for it. Queue
## instead, flush once the socket actually opens.
var _pending: Array[Dictionary] = []

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

func _process(_delta: float) -> void:
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
				message_received.emit(parsed)
	elif state == WebSocketPeer.STATE_CLOSED:
		set_process(false)
		closed.emit()

func send(msg: Dictionary) -> void:
	if _ws == null:
		return
	if _ws.get_ready_state() == WebSocketPeer.STATE_OPEN:
		_ws.send_text(JSON.stringify(msg))
	else:
		_pending.append(msg)

func close() -> void:
	if _ws != null:
		_ws.close()
	set_process(false)
