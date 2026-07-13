extends Control

const ModeIconScene := preload("res://ui/mode_icon.gd")
const UIStyle := preload("res://ui/ui_style.gd")

# Each mode gets its own tall vertical bar (not a plain stacked list of
# buttons) laid out side by side in ModeBar, so the whole set reads as one
# menu at a glance rather than a list to scroll down. Colors here are the
# source of truth other screens pull from (see UIStyle.COLOR_*) so a mode's
# sub-screens carry the same identity color as its bar.
const MODES := [
	{"label": "QUICK\nPLAY", "icon": "bolt", "color": UIStyle.COLOR_QUICKPLAY, "scene": "res://main/quick_play.tscn"},
	{"label": "RANKED", "icon": "star", "color": UIStyle.COLOR_RANKED, "scene": "res://main/ranked_queue.tscn"},
	{"label": "LOCAL", "icon": "controller", "color": UIStyle.COLOR_LOCAL, "scene": "res://main/local_menu.tscn"},
	{"label": "ONLINE", "icon": "globe", "color": UIStyle.COLOR_ONLINE, "scene": "res://main/online_menu.tscn"},
	{"label": "SHOP", "icon": "tag", "color": UIStyle.COLOR_SHOP, "scene": "res://main/shop.tscn"},
]

const BAR_SIZE := Vector2(140, 320)

@onready var mode_bar: HBoxContainer = $VBox/ModeBar

func _ready() -> void:
	UIStyle.add_background(self)
	for mode in MODES:
		mode_bar.add_child(_build_bar(mode))

func _build_bar(mode: Dictionary) -> Button:
	var color: Color = mode["color"]
	var btn := Button.new()
	btn.text = ""
	btn.custom_minimum_size = BAR_SIZE
	btn.focus_mode = Control.FOCUS_ALL
	UIStyle.style_button(btn, color, 14)
	btn.pressed.connect(_on_mode_pressed.bind(mode["scene"]))

	var layout := VBoxContainer.new()
	layout.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layout.set_anchors_preset(Control.PRESET_FULL_RECT)
	layout.alignment = BoxContainer.ALIGNMENT_CENTER
	layout.add_theme_constant_override("separation", 18)
	btn.add_child(layout)

	var icon_wrap := CenterContainer.new()
	icon_wrap.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layout.add_child(icon_wrap)
	var icon = ModeIconScene.new()
	icon.icon_type = mode["icon"]
	icon.icon_color = color
	icon.custom_minimum_size = Vector2(56, 56)
	icon_wrap.add_child(icon)

	var label := Label.new()
	label.text = mode["label"]
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.add_theme_font_size_override("font_size", 17)
	label.add_theme_color_override("font_color", Color.WHITE)
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layout.add_child(label)

	return btn

func _on_mode_pressed(scene_path: String) -> void:
	get_tree().change_scene_to_file(scene_path)
