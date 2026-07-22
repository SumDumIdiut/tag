extends Node2D
class_name CharacterBodyRect

# Flat colored rectangle standing in for the old painted 40x40 skin sprite --
# matches its exact footprint (the old Body Sprite2D's centered=false,
# offset=(-20,-9) over a 40x40 texture) so nothing else that was tuned
# against that footprint (e.g. character_preview.gd's camera framing) needs
# retuning.
const SIZE := Vector2(40, 40)
const TOP_LEFT := Vector2(-20, -9)

var color: Color = Color.WHITE:
	set(value):
		color = value
		queue_redraw()

func _draw() -> void:
	draw_rect(Rect2(TOP_LEFT, SIZE), color)
