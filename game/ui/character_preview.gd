extends Control
class_name CharacterPreview

# A character "portrait" for menu buttons/roster cards -- now that a
# character is just a flat colored rectangle (see
# player/character_body_rect.gd), this is just a colored swatch. Used to be
# a live SubViewport render of the actual in-game rig (RemoteAvatar, its
# own isolated World2D/Camera2D); no reason to carry that machinery for a
# single solid color.

@export var color_id: String = PlayerColors.DEFAULT_ID:
	set(value):
		color_id = value
		if _rect:
			_rect.color = PlayerColors.color_for(value)

var _rect: ColorRect

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_rect = ColorRect.new()
	_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_rect.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_rect.color = PlayerColors.color_for(color_id)
	add_child(_rect)
