extends Node2D

const PLAYER_SCENE := preload("res://player/player.tscn")
const REMOTE_AVATAR_SCENE := preload("res://player/remote_avatar.tscn")
const ARENA_SCENE := preload("res://levels/tag_arena.tscn")

# How far the server's authoritative position may drift from what we
# predicted locally before we just snap to it -- small mispredictions
# resolve invisibly next frame as normal control continues, large ones
# (a real desync, e.g. from packet loss during a dash) get hard-corrected
# rather than left to compound.
const RECONCILE_THRESHOLD := 24.0

var arena: Node2D
var local_player: Player
var remote_avatars := {} # peer_id -> RemoteAvatar
var my_peer_id := -1
var roster := {}
var hud: Label

func setup(p_my_peer_id: int, p_roster: Dictionary) -> void:
	my_peer_id = p_my_peer_id
	roster = p_roster

func _ready() -> void:
	arena = ARENA_SCENE.instantiate()
	add_child(arena)

	hud = Label.new()
	hud.offset_left = 16.0
	hud.offset_top = 16.0
	hud.offset_right = 400.0
	hud.offset_bottom = 60.0
	hud.add_theme_color_override("font_color", Color.WHITE)
	hud.add_theme_font_size_override("font_size", 20)
	hud.text = "Connecting..."
	add_child(hud)

	NetworkManager.match_state_received.connect(_on_match_state)
	NetworkManager.disconnected_from_server.connect(_on_disconnected)

	local_player = PLAYER_SCENE.instantiate()
	add_child(local_player)
	local_player.get_node("Camera2D").enabled = true
	local_player.get_node("Camera2D").make_current()

	for peer_id in roster.keys():
		if peer_id == my_peer_id:
			continue
		var avatar: RemoteAvatar = REMOTE_AVATAR_SCENE.instantiate()
		add_child(avatar)
		avatar.display_name = roster[peer_id]
		remote_avatars[peer_id] = avatar

func _physics_process(delta: float) -> void:
	if not local_player:
		return
	var input := {
		"move_dir": Vector2(
			Input.get_action_strength("move_right") - Input.get_action_strength("move_left"),
			Input.get_action_strength("move_down") - Input.get_action_strength("move_up")
		),
		"jump_pressed": Input.is_action_just_pressed("jump"),
		"jump_held": Input.is_action_pressed("jump"),
		"dash_pressed": Input.is_action_just_pressed("dash"),
		"climb_held": Input.is_action_pressed("climb"),
	}
	# Client-side prediction: apply input locally immediately using the same
	# movement script the server runs, so local input feels instant instead
	# of waiting on a round trip. The server's periodic snapshot in
	# _on_match_state corrects any drift.
	local_player.apply_input(input, delta)
	NetworkManager.submit_input(input)

func _on_match_state(_tick: int, states: Dictionary) -> void:
	if not states.has(my_peer_id):
		return
	var my_state: Dictionary = states[my_peer_id]
	var server_pos: Vector2 = my_state.pos
	if local_player.global_position.distance_to(server_pos) > RECONCILE_THRESHOLD:
		local_player.global_position = server_pos
		local_player.velocity = my_state.vel
		local_player.reset_physics_interpolation()
	hud.text = "IT: %s" % ("you" if my_state.is_it else "someone else")

	for peer_id in states.keys():
		if peer_id == my_peer_id or not remote_avatars.has(peer_id):
			continue
		var s: Dictionary = states[peer_id]
		remote_avatars[peer_id].set_state(s.pos, s.facing, s.is_dashing, s.is_it)

func _on_disconnected() -> void:
	get_tree().change_scene_to_file("res://main/main_menu.tscn")
