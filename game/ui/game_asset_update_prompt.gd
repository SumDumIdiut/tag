extends Control
class_name GameAssetUpdatePrompt

# A small "new built-in art is available" card -- the same idea as
# UpdatePrompt, but for tiles/icons/mode-button-art (see
# game_asset_updater.gd) rather than a whole new binary. No relaunch dance:
# these are just a handful of PNGs, applied live the moment they land (see
# GameAssetOverrides), so Download just needs to finish and free itself.

const UIStyle := preload("res://ui/ui_style.gd")
const GameAssetUpdaterScript := preload("res://net/game_asset_updater.gd")

signal applied

var _categories: Array = []
var _manifest: Dictionary = {}
var _status_label: Label
var _update_button: Button
var _skip_button: Button

## Safe to call either before or after this node enters the tree.
func setup(categories: Array, manifest: Dictionary) -> void:
	_categories = categories
	_manifest = manifest
	if _status_label:
		_status_label.text = "Updated: %s. Download now?" % ", ".join(_categories)

func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP

	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.55)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(dim)

	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(center)

	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", UIStyle.panel_box(UIStyle.COLOR_NEUTRAL, 0.12, 0.3))
	panel.custom_minimum_size = Vector2(320, 0)
	center.add_child(panel)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 12)
	panel.add_child(box)

	box.add_child(UIStyle.title_label("NEW ART AVAILABLE", 18))

	var initial_text := "Updated: %s. Download now?" % ", ".join(_categories) if not _categories.is_empty() else "New built-in art is available."
	_status_label = UIStyle.subtitle_label(initial_text)
	_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD
	box.add_child(_status_label)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	box.add_child(row)

	_skip_button = Button.new()
	_skip_button.text = "Skip"
	_skip_button.custom_minimum_size = Vector2(100, 40)
	UIStyle.style_back_button(_skip_button)
	_skip_button.pressed.connect(func(): queue_free())
	row.add_child(_skip_button)

	_update_button = Button.new()
	_update_button.text = "Download"
	_update_button.custom_minimum_size = Vector2(140, 40)
	UIStyle.style_button(_update_button, UIStyle.COLOR_ONLINE)
	_update_button.pressed.connect(_on_download_pressed)
	row.add_child(_update_button)

func _on_download_pressed() -> void:
	_update_button.disabled = true
	_skip_button.disabled = true
	_status_label.text = "Downloading..."

	var updater := GameAssetUpdaterScript.new()
	add_child(updater)
	var ok: bool = await updater.download_and_apply(_categories, _manifest)
	updater.queue_free()

	if not ok:
		_status_label.text = "Some downloads failed -- try again later."
		_update_button.disabled = false
		_skip_button.disabled = false
		return

	GameAssetOverrides.apply_tile_texture_override()
	_status_label.text = "Updated -- new art is live now."
	applied.emit()
	await get_tree().create_timer(1.2).timeout
	queue_free()
