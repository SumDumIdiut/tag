extends RefCounted
class_name UIStyle

# Shared visual language for every menu screen, built to match main_menu.gd's
# mode-bar redesign: a dark radial-gradient backdrop, colored
# rounded-border panels/buttons (built in code rather than baked into
# theme.tres since each screen needs its own accent color, not one global
# one), and a small hover-grow tween on primary buttons. Each mode keeps its
# own identity color from the main menu bars, carried through into that
# mode's sub-screens (ranked_queue is red like the Ranked bar, the online
# flow is green like the Online bar, etc.) so the whole app reads as one
# coherent set of colored "sections" rather than a flat list of screens.

const COLOR_QUICKPLAY := Color(0.98, 0.75, 0.2)
const COLOR_RANKED := Color(0.91, 0.29, 0.35)
const COLOR_LOCAL := Color(0.35, 0.78, 0.98)
const COLOR_ONLINE := Color(0.42, 0.85, 0.55)
const COLOR_SHOP := Color(0.65, 0.48, 0.98)
const COLOR_SANDBOX := Color(0.15, 0.75, 0.7)
const COLOR_NEUTRAL := Color(0.6, 0.63, 0.72)

const BG_TOP := Color(0.106, 0.11, 0.157)
const BG_BOTTOM := Color(0.043, 0.047, 0.075)

## Adds the shared dark backdrop as the first child of `root` -- call once
## from a screen's _ready(), before any other setup, so it renders behind
## everything else without needing every screen's own .tscn to carry a
## duplicate gradient sub-resource.
static func add_background(root: Control) -> void:
	var grad := Gradient.new()
	grad.colors = PackedColorArray([BG_TOP, BG_BOTTOM])
	var tex := GradientTexture2D.new()
	tex.gradient = grad
	tex.fill = GradientTexture2D.FILL_RADIAL
	tex.fill_from = Vector2(0.5, 0.5)
	tex.fill_to = Vector2(1.0, 1.0)
	var bg := TextureRect.new()
	bg.texture = tex
	bg.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	bg.stretch_mode = TextureRect.STRETCH_SCALE
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.add_child(bg)
	root.move_child(bg, 0)

static func button_box(color: Color, bg_alpha: float, border_alpha: float, radius: int = 10) -> StyleBoxFlat:
	var box := StyleBoxFlat.new()
	box.bg_color = Color(color.r, color.g, color.b, bg_alpha)
	box.border_width_left = 2
	box.border_width_top = 2
	box.border_width_right = 2
	box.border_width_bottom = 2
	box.border_color = Color(color.r, color.g, color.b, border_alpha)
	box.corner_radius_top_left = radius
	box.corner_radius_top_right = radius
	box.corner_radius_bottom_right = radius
	box.corner_radius_bottom_left = radius
	box.content_margin_left = 16.0
	box.content_margin_top = 10.0
	box.content_margin_right = 16.0
	box.content_margin_bottom = 10.0
	return box

## Applies a colored bordered look to an existing Button (normal/hover/
## pressed/focus) plus a hover-grow tween, the same treatment the main
## menu's mode bars use. Safe to call on any Button regardless of size.
## `grow`: the hover-scale tween is meant for spaced-out primary buttons
## (mode bars, page tabs, toolbar actions); pass false for buttons packed
## tightly in a vertical/grid list (sidebar entries) where growing on
## hover visually overlaps the neighboring item above/below/beside it --
## the color/border hover state alone is still enough feedback there.
static func style_button(btn: Button, color: Color, radius: int = 10, grow: bool = true) -> void:
	btn.add_theme_stylebox_override("normal", button_box(color, 0.14, 0.35, radius))
	btn.add_theme_stylebox_override("hover", button_box(color, 0.26, 0.75, radius))
	btn.add_theme_stylebox_override("pressed", button_box(color, 0.4, 1.0, radius))
	# A toggled-on button that's still under the mouse (e.g. right after you
	# click it) uses this state, not "pressed" -- left unset, it fell back to
	# the engine's default theme box, which has different border/padding
	# than button_box() and made the button visibly resize/jump the instant
	# it became both selected and hovered.
	btn.add_theme_stylebox_override("hover_pressed", button_box(color, 0.4, 1.0, radius))
	btn.add_theme_stylebox_override("focus", button_box(color, 0.26, 0.75, radius))
	btn.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	btn.clip_contents = false
	if grow:
		_wire_hover(btn)

static func _wire_hover(btn: Button) -> void:
	if btn.has_meta("_ui_style_hover_wired"):
		return
	btn.set_meta("_ui_style_hover_wired", true)
	btn.pivot_offset = btn.size * 0.5
	btn.resized.connect(func() -> void: btn.pivot_offset = btn.size * 0.5)
	btn.mouse_entered.connect(_on_hover.bind(btn, true))
	btn.mouse_exited.connect(_on_hover.bind(btn, false))

static func _on_hover(btn: Button, entered: bool) -> void:
	if not is_instance_valid(btn):
		return
	var target := Vector2.ONE * 1.045 if entered else Vector2.ONE
	var tween := btn.create_tween()
	tween.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tween.tween_property(btn, "scale", target, 0.15)

## Recolors an HSlider's default light-gray/white track and grabber (jarring
## against the dark theme) to match the rest of the UI -- a dark groove, a
## colored fill up to the current value, and a small solid-color grabber
## dot instead of the engine's default white circle icon.
static func style_slider(slider: HSlider, color: Color) -> void:
	var groove := StyleBoxFlat.new()
	groove.bg_color = Color(1, 1, 1, 0.08)
	groove.corner_radius_top_left = 4
	groove.corner_radius_top_right = 4
	groove.corner_radius_bottom_right = 4
	groove.corner_radius_bottom_left = 4
	groove.content_margin_top = 4.0
	groove.content_margin_bottom = 4.0
	slider.add_theme_stylebox_override("slider", groove)

	var fill := StyleBoxFlat.new()
	fill.bg_color = Color(color.r, color.g, color.b, 0.85)
	fill.corner_radius_top_left = 4
	fill.corner_radius_top_right = 4
	fill.corner_radius_bottom_right = 4
	fill.corner_radius_bottom_left = 4
	fill.content_margin_top = 4.0
	fill.content_margin_bottom = 4.0
	slider.add_theme_stylebox_override("grabber_area", fill)
	slider.add_theme_stylebox_override("grabber_area_highlight", fill)

	var dot := Image.create(12, 12, false, Image.FORMAT_RGBA8)
	dot.fill(Color(0, 0, 0, 0))
	for y in 12:
		for x in 12:
			if Vector2(x - 5.5, y - 5.5).length() <= 5.5:
				dot.set_pixel(x, y, Color(color.r, color.g, color.b).lightened(0.4))
	var dot_tex := ImageTexture.create_from_image(dot)
	slider.add_theme_icon_override("grabber", dot_tex)
	slider.add_theme_icon_override("grabber_highlight", dot_tex)
	slider.add_theme_icon_override("grabber_disabled", dot_tex)

## A soft radial glow, fading from the given color to fully transparent --
## originally main_menu.gd's own private helper for the mode bars' behind-
## the-portrait glow; factored out here so any other screen wanting that
## same "this card is alive" treatment (see online_menu.gd) doesn't need
## its own copy.
static func glow_texture(color: Color, size: int = 170) -> GradientTexture2D:
	var grad := Gradient.new()
	grad.colors = PackedColorArray([Color(color.r, color.g, color.b, 0.35), Color(color.r, color.g, color.b, 0.0)])
	var tex := GradientTexture2D.new()
	tex.gradient = grad
	tex.fill = GradientTexture2D.FILL_RADIAL
	tex.fill_from = Vector2(0.5, 0.5)
	tex.fill_to = Vector2(1.0, 0.5)
	tex.width = size
	tex.height = size
	return tex

## A translucent bordered panel background -- used for roster lists, server
## lists, cards, and other content wells that need to visually separate
## from the backdrop without competing with buttons for attention.
static func panel_box(color: Color = COLOR_NEUTRAL, bg_alpha: float = 0.05, border_alpha: float = 0.12, radius: int = 14) -> StyleBoxFlat:
	var box := StyleBoxFlat.new()
	box.bg_color = Color(color.r, color.g, color.b, bg_alpha)
	box.border_width_left = 2
	box.border_width_top = 2
	box.border_width_right = 2
	box.border_width_bottom = 2
	box.border_color = Color(color.r, color.g, color.b, border_alpha)
	box.corner_radius_top_left = radius
	box.corner_radius_top_right = radius
	box.corner_radius_bottom_right = radius
	box.corner_radius_bottom_left = radius
	box.content_margin_left = 14.0
	box.content_margin_top = 14.0
	box.content_margin_right = 14.0
	box.content_margin_bottom = 14.0
	return box

## The muted "leave this screen" treatment shared by every back/cancel
## button -- deliberately never the mode's own accent color, so it never
## competes with the screen's real primary action for attention.
static func style_back_button(btn: Button) -> void:
	style_button(btn, COLOR_NEUTRAL, 8)

static func title_label(text: String, size: int = 40) -> Label:
	var l := Label.new()
	l.text = text
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.add_theme_font_size_override("font_size", size)
	return l

static func subtitle_label(text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.add_theme_font_size_override("font_size", 14)
	l.add_theme_color_override("font_color", Color(0.7, 0.72, 0.78))
	return l
