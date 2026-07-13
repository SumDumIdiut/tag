extends Node2D

const REMOTE_AVATAR_SCENE := preload("res://player/remote_avatar.tscn")
const ARENA_SCENE := preload("res://levels/tag_arena.tscn")
const MATCH_RESULTS_SCENE := preload("res://main/match_results.tscn")

var arena: Node2D
var avatars := {} # peer_id -> RemoteAvatar, including your own
var my_peer_id := -1
var roster := {} # peer_id -> {username, skin_id}
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
	NetworkManager.match_ended.connect(_on_match_ended)
	SkinCatalog.skin_received.connect(_on_skin_received)
	SkinCatalog.hat_received.connect(_on_hat_received)

	# Every player, yours included, is a RemoteAvatar -- there's no local
	# prediction anywhere anymore, so no reason for your own avatar to be
	# built any differently from everyone else's. Only difference is which
	# one owns the active camera.
	for peer_id in roster.keys():
		var info: Dictionary = roster[peer_id]
		var avatar: RemoteAvatar = REMOTE_AVATAR_SCENE.instantiate()
		avatar.is_local = (peer_id == my_peer_id)
		add_child(avatar)
		avatar.display_name = info.username
		avatars[peer_id] = avatar
		_apply_skin(peer_id)
		_apply_hat(peer_id)

## A custom skin's image can still be in flight (relayed from the server,
## see NetworkManager) when a match starts -- SkinCatalog.get_part_textures()
## just returns {} for a not-yet-known custom id, so avatar.set_skin() no-ops
## and the avatar keeps its default placeholder until _on_skin_received
## re-applies it for real.
func _apply_skin(peer_id: int) -> void:
	if not avatars.has(peer_id) or not roster.has(peer_id):
		return
	var skin_id: String = roster[peer_id].get("skin_id", "red")
	avatars[peer_id].set_skin(skin_id)

func _apply_hat(peer_id: int) -> void:
	if not avatars.has(peer_id) or not roster.has(peer_id):
		return
	var hat_id: String = roster[peer_id].get("hat_id", "")
	avatars[peer_id].set_hat(hat_id)

func _on_skin_received(skin_id: String) -> void:
	for peer_id in roster.keys():
		if roster[peer_id].get("skin_id", "") == skin_id:
			_apply_skin(peer_id)

func _on_hat_received(hat_id: String) -> void:
	for peer_id in roster.keys():
		if roster[peer_id].get("hat_id", "") == hat_id:
			_apply_hat(peer_id)

func _physics_process(_delta: float) -> void:
	# No client-side prediction/reconciliation at all -- just capture and
	# send input every tick. Every avatar (see _on_match_state), including
	# your own, only ever renders confirmed server state, dead-reckoned the
	# same way RemoteAvatar always smoothed everyone else. You feel your
	# own round-trip time as input delay instead of ever seeing a
	# correction/snap.
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
	NetworkManager.submit_input(input)

func _on_match_state(_tick: int, states: Dictionary) -> void:
	if states.has(my_peer_id):
		hud.text = "IT: %s" % ("you" if states[my_peer_id].is_it else "someone else")

	for peer_id in states.keys():
		if not avatars.has(peer_id):
			continue
		var s: Dictionary = states[peer_id]
		avatars[peer_id].set_state(s.pos, s.vel, s.facing, s.is_dashing, s.get("is_climbing", false), s.get("on_floor", true), s.is_it)

func _on_disconnected() -> void:
	get_tree().change_scene_to_file("res://main/main_menu.tscn")

## Only ever fires for a ranked round (see TagMode.round_ended) -- casual
## matches have no end condition and just keep running until everyone
## leaves. Swaps straight to the results screen without waiting for a
## disconnect.
func _on_match_ended(ranking: Array) -> void:
	var scene := MATCH_RESULTS_SCENE.instantiate()
	scene.setup(ranking, my_peer_id)
	get_tree().root.add_child(scene)
	get_tree().current_scene.queue_free()
	get_tree().current_scene = scene
