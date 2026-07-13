extends Control

const ModeIconScene := preload("res://ui/mode_icon.gd")
const CharacterPreviewScene := preload("res://ui/character_preview.gd")
const UIStyle := preload("res://ui/ui_style.gd")

# Each mode gets its own tall vertical bar (not a plain stacked list of
# buttons) laid out side by side in ModeBar, so the whole set reads as one
# menu at a glance rather than a list to scroll down. Colors here are the
# source of truth other screens pull from (see UIStyle.COLOR_*) so a mode's
# sub-screens carry the same identity color as its bar. `skin`/`hat` pick
# which real in-game character (see CharacterPreview) fronts each bar --
# built-in skin colors happen to line up 1:1 with the bar accent colors, so
# the character reads as "belonging" to its bar rather than a mismatched
# color. `icon` is a small corner badge kept alongside the character for an
# at-a-glance symbol (lightning/star/etc.), not the star of the button.
const MODES := [
	{"label": "QUICK\nPLAY", "icon": "bolt", "color": UIStyle.COLOR_QUICKPLAY, "skin": "yellow", "hat": "", "scene": "res://main/quick_play.tscn"},
	{"label": "RANKED", "icon": "star", "color": UIStyle.COLOR_RANKED, "skin": "red", "hat": "crown", "scene": "res://main/ranked_queue.tscn"},
	{"label": "LOCAL", "icon": "controller", "color": UIStyle.COLOR_LOCAL, "skin": "blue", "hat": "", "scene": "res://main/local_menu.tscn"},
	{"label": "ONLINE", "icon": "globe", "color": UIStyle.COLOR_ONLINE, "skin": "green", "hat": "", "scene": "res://main/online_menu.tscn"},
	{"label": "SHOP", "icon": "tag", "color": UIStyle.COLOR_SHOP, "skin": "purple", "hat": "tophat", "scene": "res://main/shop.tscn"},
]

const BAR_SIZE := Vector2(150, 340)

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
	btn.clip_contents = true
	UIStyle.style_button(btn, color, 16)
	btn.pressed.connect(_on_mode_pressed.bind(mode["scene"]))

	# A soft radial glow behind the character, in the bar's own color --
	# gives the portrait a bit of depth/stage-lighting instead of sitting
	# flat against the panel, and reads as "this button is alive" even
	# before the hover animation kicks in.
	var glow := TextureRect.new()
	glow.mouse_filter = Control.MOUSE_FILTER_IGNORE
	glow.texture = _glow_texture(color)
	glow.stretch_mode = TextureRect.STRETCH_SCALE
	glow.set_anchors_preset(Control.PRESET_CENTER_TOP)
	glow.position = Vector2(-70, -10)
	glow.custom_minimum_size = Vector2(140, 140)
	glow.size = Vector2(140, 140)
	btn.add_child(glow)

	var layout := VBoxContainer.new()
	layout.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layout.set_anchors_preset(Control.PRESET_FULL_RECT)
	layout.alignment = BoxContainer.ALIGNMENT_CENTER
	layout.add_theme_constant_override("separation", 14)
	btn.add_child(layout)

	var portrait_wrap := CenterContainer.new()
	portrait_wrap.mouse_filter = Control.MOUSE_FILTER_IGNORE
	portrait_wrap.custom_minimum_size = Vector2(0, 130)
	layout.add_child(portrait_wrap)
	var portrait = CharacterPreviewScene.new()
	portrait.skin_id = mode["skin"]
	portrait.hat_id = mode["hat"]
	portrait.custom_minimum_size = Vector2(90, 116)
	portrait_wrap.add_child(portrait)

	var label := Label.new()
	label.text = mode["label"]
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.add_theme_font_size_override("font_size", 17)
	label.add_theme_color_override("font_color", Color.WHITE)
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layout.add_child(label)

	# Small corner badge -- keeps a symbolic glyph alongside the character
	# portrait for instant recognition, without competing with it for focus.
	var badge_wrap := Control.new()
	badge_wrap.mouse_filter = Control.MOUSE_FILTER_IGNORE
	badge_wrap.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	badge_wrap.position = Vector2(-38, 12)
	badge_wrap.custom_minimum_size = Vector2(26, 26)
	btn.add_child(badge_wrap)
	var badge := ModeIconScene.new()
	badge.icon_type = mode["icon"]
	badge.icon_color = color
	badge.custom_minimum_size = Vector2(22, 26)
	badge_wrap.add_child(badge)

	return btn

func _glow_texture(color: Color) -> GradientTexture2D:
	var grad := Gradient.new()
	grad.colors = PackedColorArray([Color(color.r, color.g, color.b, 0.35), Color(color.r, color.g, color.b, 0.0)])
	var tex := GradientTexture2D.new()
	tex.gradient = grad
	tex.fill = GradientTexture2D.FILL_RADIAL
	tex.fill_from = Vector2(0.5, 0.5)
	tex.fill_to = Vector2(1.0, 0.5)
	tex.width = 140
	tex.height = 140
	return tex

func _on_mode_pressed(scene_path: String) -> void:
	get_tree().change_scene_to_file(scene_path)
