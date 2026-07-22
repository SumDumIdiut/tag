extends Node2D

const REMOTE_AVATAR_SCENE := preload("res://player/remote_avatar.tscn")
const MATCH_RESULTS_SCENE := preload("res://main/match_results.tscn")
const OnlineMapCatalog := preload("res://levels/online_maps/catalog.gd")

var arena: Node2D
var avatars := {} # peer_id -> RemoteAvatar, including your own
var my_peer_id := -1
var roster := {} # peer_id -> {username, color_id}
var level_id := ""
var hud: Label

func setup(p_my_peer_id: int, p_roster: Dictionary, p_level_id: String = "") -> void:
	my_peer_id = p_my_peer_id
	roster = p_roster
	level_id = p_level_id

func _ready() -> void:
	# Resolved purely locally, from the same built-in catalog server_match.gd
	# uses -- see that file's identical resolution for why there's no
	# network fetch here anymore either.
	arena = load(OnlineMapCatalog.scene_path_for(level_id)).instantiate()
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
		_apply_color(peer_id)

	# my_peer_id == -1 means we're spectating (see NetworkManager.start_
	# spectator) -- there's no local avatar to own the camera, so fall back
	# to following whichever roster entry came first instead of leaving no
	# camera active at all.
	if my_peer_id == -1 and not avatars.is_empty():
		var followed: RemoteAvatar = avatars[avatars.keys()[0]]
		followed.camera.enabled = true
		followed.camera.make_current()
		hud.text = "Spectating"

func _apply_color(peer_id: int) -> void:
	if not avatars.has(peer_id) or not roster.has(peer_id):
		return
	var color_id: String = roster[peer_id].get("color_id", PlayerColors.DEFAULT_ID)
	avatars[peer_id].set_color(color_id)

func _physics_process(_delta: float) -> void:
	# A spectator (my_peer_id == -1, see setup()/start_spectator()) has no
	# Player on the server to apply input to at all -- the server would just
	# no-op it (not in any _peer_lobby entry), but there's no reason to
	# spend a network message every tick doing nothing.
	if my_peer_id == -1:
		return
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
		avatars[peer_id].set_state(s.pos, s.vel, s.facing, s.is_dashing, s.get("is_climbing", false), s.get("on_floor", true), s.get("action", ""), s.get("action_id", 0), s.is_it)

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
