extends Node2D

const NPC_SCENE := preload("res://npc/npc.tscn")
const PLAYER_SCENE := preload("res://player/player.tscn")
const LocalMapCatalog := preload("res://levels/local_maps/catalog.gd")
const FixedView := preload("res://levels/fixed_view.gd")

@onready var hud: Label = $HUD

var arena: Node2D
var player: Player
var tag_mode: TagMode
var waypoint_graph: WaypointGraph
var participants: Array = []
var _spawn_points: Array = []
var _death_rect: Rect2

func _ready() -> void:
	arena = load(LocalMapCatalog.scene_path_for(GameSettings.selected_local_map)).instantiate()
	add_child(arena)
	move_child(arena, 0) # keep it drawn behind HUD/PauseMenu, matching the old static-child order

	# Same rect MapBackground draws itself to (see generate_local_maps.gd) --
	# reusing it here means the camera, the backdrop, and the death boundary
	# below can never drift out of sync with each other.
	var view_rect: Rect2 = arena.get_node("Background").bounds
	add_child(FixedView.make_camera(view_rect))
	_death_rect = FixedView.death_rect(view_rect)

	_spawn_points = arena.get_node("SpawnPoints").get_children()
	_spawn_points.shuffle()

	waypoint_graph = WaypointGraph.new()
	waypoint_graph.build(get_tree().get_nodes_in_group("ai_waypoint"))

	tag_mode = TagMode.new()
	add_child(tag_mode)

	player = PLAYER_SCENE.instantiate()
	add_child(player)
	player.global_position = _spawn_points[0].global_position
	# NPCs all keep Player's own default color (see player.gd's _ready()) --
	# distinguishing the human player from them is the only thing that
	# matters here, there's no other player to tell apart in local/bot play.
	player.set_color("blue")
	participants.append(player)

	var npc_count: int = clampi(GameSettings.npc_count, 0, 7)
	for i in npc_count:
		var npc: NPC = NPC_SCENE.instantiate()
		npc.skill_level = GameSettings.npc_skill
		npc.tag_mode = tag_mode
		npc.waypoint_graph = waypoint_graph
		# TEMPORARY -- see GameSettings.use_trained_ai's own comment. Only
		# the first NPC, not all of them, so there's always a normal
		# scripted bot to compare it against in the same match.
		if i == 0 and GameSettings.use_trained_ai:
			npc.use_trained_policy = true
		add_child(npc)
		npc.global_position = _spawn_points[(i + 1) % _spawn_points.size()].global_position
		participants.append(npc)

	tag_mode.setup(participants, randi() % participants.size(), false, GameSettings.round_duration)
	# Local/bot play is always FFA (no team playlist here) -- every
	# participant shares team -1, so that's the one bucket to watch.
	tag_mode.it_changed.connect(_on_it_changed)
	_on_it_changed(tag_mode.get_it_for_team(-1), -1)

func _on_it_changed(new_it: Node, _team: int) -> void:
	if not hud:
		return
	var label: String = "you" if new_it == player else str(new_it.name)
	hud.text = "IT: %s" % label

func _physics_process(delta: float) -> void:
	# Checked every tick for every participant, bots included -- same real
	# penalty server_match.gd enforces for online play (see its own
	# identical comment): going off the fixed camera's visible frame makes
	# you "it" for your own team-bucket, then respawns you like the
	# match's own opening placement.
	for p in participants:
		if not _death_rect.has_point(p.global_position):
			tag_mode.force_it(p)
			_respawn(p)

	if not player:
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
	player.apply_input(input, delta)

func _respawn(p: Node) -> void:
	if _spawn_points.is_empty():
		return
	var point: Node2D = _spawn_points[randi() % _spawn_points.size()]
	p.global_position = point.global_position
	p.velocity = Vector2.ZERO
