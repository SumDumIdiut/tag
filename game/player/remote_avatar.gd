extends Node2D
class_name RemoteAvatar

# A non-simulated puppet for other players in a networked match -- no
# physics, no movement code, just interpolates toward whatever position the
# server last reported. The local player still runs the real Player
# movement script for prediction; everyone else is purely a rendering of
# server state.

@onready var visual: ColorRect = $Visual
@onready var name_label: Label = $NameLabel

const REMOTE_COLOR := Color(0.25, 0.45, 0.85, 1.0)
const LERP_WEIGHT := 0.35

var display_name: String = "":
	set(value):
		display_name = value
		if name_label:
			name_label.text = value

var target_position: Vector2 = Vector2.ZERO
var target_facing: int = 1

func _ready() -> void:
	if name_label:
		name_label.text = display_name

func _physics_process(_delta: float) -> void:
	global_position = global_position.lerp(target_position, LERP_WEIGHT)

func set_state(pos: Vector2, facing: int, is_dashing: bool, is_it: bool) -> void:
	target_position = pos
	target_facing = facing
	if visual:
		visual.color = Player.TAG_IT_COLOR if is_it else REMOTE_COLOR
		visual.scale = Vector2(1.5, 0.6) if is_dashing else Vector2.ONE
		var flip := absf(visual.scale.x) * (1.0 if facing >= 0 else -1.0)
		visual.scale.x = flip
