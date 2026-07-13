extends Control

const ModeIconScene := preload("res://ui/mode_icon.gd")

# Each mode gets its own tall vertical bar (not a plain stacked list of
# buttons) laid out side by side in ModeBar, so the whole set reads as one
# menu at a glance rather than a list to scroll down. Colors/icons are
# baked in here rather than the .tscn since every bar needs its own unique
# StyleBoxFlat per button-state (normal/hover/pressed) -- five buttons times
# three states is a lot of near-duplicate sub-resources to hand-author, and
# this mirrors the same "build styles in code" pattern shop.gd already uses
# for its cards.
const MODES := [
	{"label": "QUICK\nPLAY", "icon": "bolt", "color": Color(0.98, 0.75, 0.2), "scene": "res://main/quick_play.tscn"},
	{"label": "RANKED", "icon": "star", "color": Color(0.91, 0.29, 0.35), "scene": "res://main/ranked_queue.tscn"},
	{"label": "LOCAL", "icon": "controller", "color": Color(0.35, 0.78, 0.98), "scene": "res://main/local_menu.tscn"},
	{"label": "ONLINE", "icon": "globe", "color": Color(0.42, 0.85, 0.55), "scene": "res://main/online_menu.tscn"},
	{"label": "SHOP", "icon": "tag", "color": Color(0.65, 0.48, 0.98), "scene": "res://main/shop.tscn"},
]

const BAR_SIZE := Vector2(140, 320)
const HOVER_SCALE := 1.06

@onready var mode_bar: HBoxContainer = $VBox/ModeBar

func _ready() -> void:
	for mode in MODES:
		mode_bar.add_child(_build_bar(mode))

func _build_bar(mode: Dictionary) -> Button:
	var color: Color = mode["color"]
	var btn := Button.new()
	btn.text = ""
	btn.custom_minimum_size = BAR_SIZE
	btn.focus_mode = Control.FOCUS_ALL
	btn.pivot_offset = BAR_SIZE * 0.5
	btn.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	btn.add_theme_stylebox_override("normal", _bar_style(color, 0.14, 0.35))
	btn.add_theme_stylebox_override("hover", _bar_style(color, 0.26, 0.75))
	btn.add_theme_stylebox_override("pressed", _bar_style(color, 0.4, 1.0))
	btn.add_theme_stylebox_override("focus", _bar_style(color, 0.26, 0.75))
	btn.pressed.connect(_on_mode_pressed.bind(mode["scene"]))
	btn.mouse_entered.connect(_on_bar_hover.bind(btn, true))
	btn.mouse_exited.connect(_on_bar_hover.bind(btn, false))

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

func _bar_style(color: Color, bg_alpha: float, border_alpha: float) -> StyleBoxFlat:
	var box := StyleBoxFlat.new()
	box.bg_color = Color(color.r, color.g, color.b, bg_alpha)
	box.border_width_left = 2
	box.border_width_top = 2
	box.border_width_right = 2
	box.border_width_bottom = 2
	box.border_color = Color(color.r, color.g, color.b, border_alpha)
	box.corner_radius_top_left = 14
	box.corner_radius_top_right = 14
	box.corner_radius_bottom_right = 14
	box.corner_radius_bottom_left = 14
	return box

func _on_bar_hover(btn: Button, entered: bool) -> void:
	var target_scale := Vector2.ONE * HOVER_SCALE if entered else Vector2.ONE
	var tween := create_tween()
	tween.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tween.tween_property(btn, "scale", target_scale, 0.18)

func _on_mode_pressed(scene_path: String) -> void:
	get_tree().change_scene_to_file(scene_path)
