extends Node2D

# Single-player Celeste-movement sandbox: a box with a few platforms to test
# the full moveset (coyote time, jump buffer, variable jump height, wall
# jump, wall-jump proximity, dash, dash-jump, super wall jump, climbing).

@onready var player: Player = $Player
@onready var hud: Label = $HUD

func _ready() -> void:
	player.get_node("Camera2D").enabled = true
	player.get_node("Camera2D").make_current()

func _physics_process(delta: float) -> void:
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
	hud.text = "pos: %s\nvel: %s\non_floor: %s  on_wall: %s  dashing: %s\nclimbing: %s  stamina: %d  dash_available: %s" % [
		player.position.round(),
		player.velocity.round(),
		player.is_on_floor(),
		player.is_on_wall_only(),
		player.is_dashing,
		player.is_climbing,
		player.stamina,
		player.dash_available,
	]
