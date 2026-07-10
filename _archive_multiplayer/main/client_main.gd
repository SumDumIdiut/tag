extends Node2D

const PLAYER_SCENE := preload("res://player/player.tscn")

@onready var players_root: Node2D = $Players
@onready var connect_panel: Control = $UI/ConnectPanel
@onready var address_edit: LineEdit = $UI/ConnectPanel/VBox/AddressEdit
@onready var connect_button: Button = $UI/ConnectPanel/VBox/ConnectButton
@onready var status_label: Label = $UI/ConnectPanel/VBox/StatusLabel
@onready var hud: Label = $UI/HUD
@onready var game_over_panel: Control = $UI/GameOverPanel
@onready var results_box: VBoxContainer = $UI/GameOverPanel/ResultsBox

var local_peer_id: int = -1
var local_controller: ClientPlayerController
var remote_controllers: Dictionary = {} # peer_id -> RemotePlayerController
var latest_round_state: Dictionary = {}
var _bot_mode := false

func _ready() -> void:
	connect_button.pressed.connect(_on_connect_pressed)
	NetworkManager.connected_to_server.connect(_on_connected_to_server)
	NetworkManager.connection_failed.connect(_on_connection_failed)
	NetworkManager.server_disconnected.connect(_on_server_disconnected)
	NetworkManager.roster_received.connect(_on_roster_received)
	NetworkManager.player_state_received.connect(_on_player_state_received)
	NetworkManager.round_state_received.connect(_on_round_state_received)
	NetworkManager.game_over_received.connect(_on_game_over_received)

	# --address=<ip> skips the UI and connects immediately; --bot drives the
	# local player with a scripted movement loop instead of reading keyboard
	# input. Both are for scripted multi-instance testing (see the "run"
	# skill / CI), not normal play.
	for arg in OS.get_cmdline_user_args():
		if arg == "--bot":
			_bot_mode = true
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--address="):
			address_edit.text = arg.trim_prefix("--address=")
			_on_connect_pressed()

func _on_connect_pressed() -> void:
	status_label.text = "Connecting..."
	connect_button.disabled = true
	NetworkManager.join_server(address_edit.text.strip_edges())

func _on_connected_to_server() -> void:
	local_peer_id = multiplayer.get_unique_id()
	connect_panel.visible = false
	hud.visible = true
	print("Connected to server as peer %d" % local_peer_id)

func _on_connection_failed() -> void:
	status_label.text = "Connection failed."
	connect_button.disabled = false

func _on_server_disconnected() -> void:
	status_label.text = "Disconnected from server."
	connect_panel.visible = true
	connect_button.disabled = false
	hud.visible = false
	for controller in remote_controllers.values():
		controller.player.queue_free()
	remote_controllers.clear()
	if local_controller:
		local_controller.player.queue_free()
		local_controller = null

func _on_roster_received(roster: Array) -> void:
	var seen: Dictionary = {}
	for entry in roster:
		var peer_id: int = entry.peer_id
		seen[peer_id] = true
		if peer_id == local_peer_id:
			if local_controller == null:
				var player: Player = PLAYER_SCENE.instantiate()
				player.position = entry.position
				players_root.add_child(player)
				player.reset_physics_interpolation()
				player.get_node("Camera2D").enabled = true
				player.get_node("Camera2D").make_current()
				local_controller = ClientPlayerController.new(player, _bot_mode)
		elif not remote_controllers.has(peer_id):
			var player: Player = PLAYER_SCENE.instantiate()
			player.position = entry.position
			players_root.add_child(player)
			player.reset_physics_interpolation()
			remote_controllers[peer_id] = RemotePlayerController.new(player)

	if local_controller and not seen.has(local_peer_id):
		local_controller.player.queue_free()
		local_controller = null
	for peer_id in remote_controllers.keys().duplicate():
		if not seen.has(peer_id):
			remote_controllers[peer_id].player.queue_free()
			remote_controllers.erase(peer_id)

func _on_player_state_received(state: Dictionary) -> void:
	var peer_id: int = state.peer_id
	if peer_id == local_peer_id and local_controller:
		local_controller.reconcile(state)
	elif remote_controllers.has(peer_id):
		remote_controllers[peer_id].push_snapshot(state)

func _on_round_state_received(state: Dictionary) -> void:
	latest_round_state = state

func _on_game_over_received(results: Dictionary) -> void:
	hud.visible = false
	game_over_panel.visible = true
	for child in results_box.get_children():
		if child.name != "ResultsTitle":
			child.queue_free()
	var time_as_it: Dictionary = results.get("time_as_it", {})
	var entries := time_as_it.keys()
	entries.sort_custom(func(a, b): return time_as_it[a] < time_as_it[b])
	for peer_id in entries:
		var label := Label.new()
		var tag := " (you)" if peer_id == local_peer_id else ""
		label.text = "Peer %d%s -- %.1fs as it" % [peer_id, tag, time_as_it[peer_id]]
		results_box.add_child(label)

func _physics_process(delta: float) -> void:
	if local_controller:
		local_controller.tick(delta)
	for controller in remote_controllers.values():
		controller.update(delta)
	if hud.visible:
		var is_it := local_controller != null and local_controller.player.is_it
		var stamina_pct := 0
		var dash_ready := false
		if local_controller:
			stamina_pct = int(round(local_controller.player.stamina / Player.STAMINA_MAX * 100.0))
			dash_ready = local_controller.player.dash_available
		hud.text = "Time left: %.0f\n%s\nStamina: %d%%   Dash: %s" % [
			latest_round_state.get("time_left", 0.0),
			"YOU ARE IT" if is_it else "run!",
			stamina_pct,
			"ready" if dash_ready else "--",
		]
