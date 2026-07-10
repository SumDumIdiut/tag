extends Node

const PLAYER_SCENE := preload("res://player/player.tscn")
const VOID_Y := 700.0 # fall this far below the level and you're teleported back

@onready var arena: Node2D = $TestArena
@onready var players_root: Node2D = $Players

var controllers: Dictionary = {} # peer_id -> ServerPlayerController
var tag_mode := TagMode.new()
var _round_state_heartbeat := 0.0

func _ready() -> void:
	NetworkManager.client_connected.connect(_on_client_connected)
	NetworkManager.client_disconnected.connect(_on_client_disconnected)
	NetworkManager.input_received.connect(_on_input_received)
	tag_mode.tagged.connect(_on_tagged)
	tag_mode.round_ended.connect(_on_round_ended)
	var err := NetworkManager.start_server()
	if err == OK:
		print("Tag server listening on port %d" % NetworkManager.DEFAULT_PORT)

func _physics_process(delta: float) -> void:
	if controllers.is_empty():
		return
	for peer_id in controllers.keys():
		var controller: ServerPlayerController = controllers[peer_id]
		var state := controller.process_tick(delta)
		if controller.player.position.y > VOID_Y:
			controller.player.teleport_to(_random_spawn_point().position)
			state = controller.latest_state() # refresh reported position post-teleport
		NetworkManager.broadcast_player_state(state)

	tag_mode.process_tick(delta)
	_round_state_heartbeat += delta
	if _round_state_heartbeat >= 1.0:
		_round_state_heartbeat = 0.0
		NetworkManager.broadcast_round_state(tag_mode.get_state())

func _random_spawn_point() -> Marker2D:
	var spawn_points := arena.get_node("SpawnPoints").get_children()
	return spawn_points[randi() % spawn_points.size()]

func _on_client_connected(peer_id: int) -> void:
	var spawn_points := arena.get_node("SpawnPoints").get_children()
	var spawn: Marker2D = spawn_points[controllers.size() % spawn_points.size()]

	var player: Player = PLAYER_SCENE.instantiate()
	player.name = "Player_%d" % peer_id
	players_root.add_child(player)
	player.position = spawn.position

	var controller := ServerPlayerController.new(player, peer_id)
	controllers[peer_id] = controller
	tag_mode.register_player(peer_id, player)
	print("Peer %d connected (%d players)" % [peer_id, controllers.size()])

	_broadcast_roster()

	if controllers.size() >= 2 and not tag_mode.round_active:
		tag_mode.start_round(_players_dict())
		NetworkManager.broadcast_round_state(tag_mode.get_state())
		print("Round started, it = peer %d" % tag_mode.it_peer_id)

func _on_client_disconnected(peer_id: int) -> void:
	if controllers.has(peer_id):
		controllers[peer_id].player.queue_free()
		controllers.erase(peer_id)
	tag_mode.unregister_player(peer_id)
	_broadcast_roster()
	print("Peer %d disconnected (%d players)" % [peer_id, controllers.size()])

func _on_input_received(peer_id: int, seq: int, input: Dictionary) -> void:
	if controllers.has(peer_id):
		controllers[peer_id].queue_input(seq, input)

func _on_tagged(_old_it_peer_id: int, _new_it_peer_id: int) -> void:
	NetworkManager.broadcast_round_state(tag_mode.get_state())

func _on_round_ended(results: Dictionary) -> void:
	NetworkManager.broadcast_game_over({"time_as_it": results})

func _players_dict() -> Dictionary:
	var out := {}
	for peer_id in controllers.keys():
		out[peer_id] = controllers[peer_id].player
	return out

func _broadcast_roster() -> void:
	var roster: Array = []
	for peer_id in controllers.keys():
		roster.append({"peer_id": peer_id, "position": controllers[peer_id].player.position})
	NetworkManager.broadcast_roster(roster)
