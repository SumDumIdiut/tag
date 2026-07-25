extends Node
class_name WebRTCLoopbackListener

# Accepts incoming same-machine signaling connections for a dedicated
# server hosted via NetworkManager.start_server_webrtc_loopback() -- a
# raw TCPServer on 127.0.0.1, each accepted connection upgraded to a
# WebRTCSignalingChannel. Only ever reachable from this same machine
# (bound to 127.0.0.1 specifically); Phase 2's relay-routed joins don't
# use this at all.

signal channel_connected(channel: WebRTCSignalingChannel)

var _tcp_server := TCPServer.new()

func listen(port: int) -> Error:
	return _tcp_server.listen(port, "127.0.0.1")

func _process(_delta: float) -> void:
	while _tcp_server.is_connection_available():
		var conn := _tcp_server.take_connection()
		var channel := WebRTCSignalingChannel.for_loopback_stream(conn)
		add_child(channel)
		channel_connected.emit(channel)

func stop() -> void:
	_tcp_server.stop()
