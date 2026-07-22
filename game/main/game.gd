extends Node2D

const NPC_SCENE := preload("res://npc/npc.tscn")
const PLAYER_SCENE := preload("res://player/player.tscn")
const LocalMapCatalog := preload("res://levels/local_maps/catalog.gd")

@onready var hud: Label = $HUD

var arena: Node2D
var player: Player
var tag_mode: TagMode
var waypoint_graph: WaypointGraph
var participants: Array = []

func _ready() -> void:
	arena = load(LocalMapCatalog.scene_path_for(GameSettings.selected_local_map)).instantiate()
	add_child(arena)
	move_child(arena, 0) # keep it drawn behind HUD/PauseMenu, matching the old static-child order

	var spawn_points := arena.get_node("SpawnPoints").get_children()
	spawn_points.shuffle()

	waypoint_graph = WaypointGraph.new()
	waypoint_graph.build(get_tree().get_nodes_in_group("ai_waypoint"))

	tag_mode = TagMode.new()
	add_child(tag_mode)

	player = PLAYER_SCENE.instantiate()
	add_child(player)
	player.global_position = spawn_points[0].global_position
	player.get_node("Camera2D").enabled = true
	player.get_node("Camera2D").make_current()
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
		add_child(npc)
		npc.global_position = spawn_points[(i + 1) % spawn_points.size()].global_position
		participants.append(npc)

	tag_mode.setup(participants, randi() % participants.size(), false, GameSettings.round_duration)
	tag_mode.it_changed.connect(_on_it_changed)
	_on_it_changed(tag_mode.get_it())

func _on_it_changed(new_it: Node) -> void:
	if not hud:
		return
	var label: String = "you" if new_it == player else str(new_it.name)
	hud.text = "IT: %s" % label

func _physics_process(delta: float) -> void:
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
