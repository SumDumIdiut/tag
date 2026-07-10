extends Node

# Thin wrapper around Godot's high-level multiplayer (ENetMultiplayerPeer).
# Owns connection setup only -- server_main.gd / client_main.gd own what
# happens once connected (spawning players, running the tag mode, etc).

const DEFAULT_PORT := 8910
const MAX_CLIENTS := 8

signal server_started
signal client_connected(peer_id: int)
signal client_disconnected(peer_id: int)
signal connected_to_server
signal connection_failed
signal server_disconnected

signal input_received(peer_id: int, seq: int, input: Dictionary)
signal player_state_received(state: Dictionary)
signal roster_received(roster: Array)
signal round_state_received(state: Dictionary)
signal game_over_received(results: Dictionary)

func _ready() -> void:
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.connected_to_server.connect(_on_connected_to_server)
	multiplayer.connection_failed.connect(_on_connection_failed)
	multiplayer.server_disconnected.connect(_on_server_disconnected)

func start_server(port: int = DEFAULT_PORT) -> Error:
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_server(port, MAX_CLIENTS)
	if err != OK:
		push_error("Failed to start server on port %d: %s" % [port, err])
		return err
	multiplayer.multiplayer_peer = peer
	server_started.emit()
	return OK

func join_server(address: String, port: int = DEFAULT_PORT) -> Error:
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_client(address, port)
	if err != OK:
		push_error("Failed to connect to %s:%d: %s" % [address, port, err])
		return err
	multiplayer.multiplayer_peer = peer
	return OK

func close() -> void:
	if multiplayer.multiplayer_peer != null:
		multiplayer.multiplayer_peer.close()
		multiplayer.multiplayer_peer = null

func is_server() -> bool:
	return multiplayer.multiplayer_peer != null and multiplayer.is_server()

# --- Gameplay RPC surface -------------------------------------------------
# Routed through this autoload (rather than the gameplay nodes themselves)
# because autoloads exist at the same NodePath on every peer, which is what
# Godot's high-level multiplayer needs to dispatch an RPC to the right node.
# Actual handling lives in server_main.gd / client_main.gd via these signals.

@rpc("any_peer", "unreliable_ordered")
func submit_input(seq: int, input: Dictionary) -> void:
	input_received.emit(multiplayer.get_remote_sender_id(), seq, input)

func send_input(seq: int, input: Dictionary) -> void:
	submit_input.rpc_id(1, seq, input)

# One small message per player per tick, rather than one big dict of every
# player's state -- keeps each packet comfortably under ENet's MTU even at
# 8 players, and a single dropped packet only costs one player's update
# instead of the whole tick's worth of position data for everyone.
@rpc("authority", "unreliable_ordered")
func receive_player_state(state: Dictionary) -> void:
	player_state_received.emit(state)

func broadcast_player_state(state: Dictionary) -> void:
	receive_player_state.rpc(state)

## Full current player roster, sent on any join/leave. The client reconciles
## its local player list against this rather than tracking incremental
## spawn/despawn events, so a late joiner still learns about everyone.
@rpc("authority", "reliable")
func receive_roster(roster: Array) -> void:
	roster_received.emit(roster)

func broadcast_roster(roster: Array) -> void:
	receive_roster.rpc(roster)

@rpc("authority", "reliable")
func receive_round_state(state: Dictionary) -> void:
	round_state_received.emit(state)

func broadcast_round_state(state: Dictionary) -> void:
	receive_round_state.rpc(state)

@rpc("authority", "reliable")
func receive_game_over(results: Dictionary) -> void:
	game_over_received.emit(results)

func broadcast_game_over(results: Dictionary) -> void:
	receive_game_over.rpc(results)

func _on_peer_connected(peer_id: int) -> void:
	client_connected.emit(peer_id)

func _on_peer_disconnected(peer_id: int) -> void:
	client_disconnected.emit(peer_id)

func _on_connected_to_server() -> void:
	connected_to_server.emit()

func _on_connection_failed() -> void:
	connection_failed.emit()

func _on_server_disconnected() -> void:
	server_disconnected.emit()
