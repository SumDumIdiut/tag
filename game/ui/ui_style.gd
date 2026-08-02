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
const COLOR_ACCENT := Color(0.65, 0.48, 0.98)
const COLOR_SANDBOX := Color(0.15, 0.75, 0.7)
const COLOR_NEUTRAL := Color(0.6, 0.63, 0.72)

const BG_TOP := Color(0.106, 0.11, 0.157)
const BG_BOTTOM := Color(0.043, 0.047, 0.075)

const ModeIconScene := preload("res://ui/mode_icon.gd")

## Matches relay-server/server.js's RANK_TIERS names exactly (case-sensitive
## keys straight off /api/ranked/:clientId's "tier" field) -- used anywhere
## a tier needs a color, e.g. match_intro.gd's ranked VS screen badges.
const RANK_TIER_COLORS := {
	"Bronze": Color(0.72, 0.47, 0.28),
	"Silver": Color(0.75, 0.78, 0.82),
	"Gold": Color(0.95, 0.8, 0.25),
	"Platinum": Color(0.4, 0.85, 0.8),
	"Diamond": Color(0.55, 0.8, 0.98),
	"Master": Color(0.75, 0.35, 0.95),
	"Grandmaster": Color(0.95, 0.25, 0.25),
	"Champion": Color(1.0, 0.55, 0.15),
	"Legend": Color(0.3, 0.95, 0.85),
	"Mythic": Color(0.95, 0.2, 0.65),
	"Immortal": Color(1.0, 0.92, 0.55),
	"Creator": Color(1.0, 0.65, 0.0),
}
const RANK_TIER_DEFAULT_COLOR := Color(0.6, 0.63, 0.72)

static func tier_color(tier: String) -> Color:
	return RANK_TIER_COLORS.get(tier, RANK_TIER_DEFAULT_COLOR)

## Adds a screen's plain radial-gradient backdrop as the first child of
## `root` -- call once from a screen's _ready(), before any other setup, so
## it renders behind everything else without needing every screen's own
## .tscn to carry a duplicate gradient sub-resource. `screen_key` is kept as
## a no-op parameter so every existing call site (`add_background(self,
## "online_menu")` etc.) still compiles unchanged; it no longer selects
## anything.
static func add_background(root: Control, _screen_key: String = "") -> void:
	var grad := Gradient.new()
	grad.colors = PackedColorArray([BG_TOP, BG_BOTTOM])
	var grad_tex := GradientTexture2D.new()
	grad_tex.gradient = grad
	grad_tex.fill = GradientTexture2D.FILL_RADIAL
	grad_tex.fill_from = Vector2(0.5, 0.5)
	grad_tex.fill_to = Vector2(1.0, 1.0)
	var grad_rect := TextureRect.new()
	grad_rect.texture = grad_tex
	grad_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	grad_rect.stretch_mode = TextureRect.STRETCH_SCALE
	grad_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	grad_rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.add_child(grad_rect)
	root.move_child(grad_rect, 0)

## Same dark base + soft alpha-blended-circle glow technique as
## team_lobby_view.gd's own _SplitBackground/_VsBadge (see those for the
## original), just one centered glow in a single accent color instead of
## a two-team split -- for screens with no "other side" yet (matchmaking/
## queue screens) that still want the same moody, energetic look the VS
## reveal has, instead of the plain flat gradient add_background() gives.
## Call once from a screen's _ready(), same as add_background().
static func add_glow_background(root: Control, accent_color: Color) -> void:
	var glow := _GlowBackground.new()
	glow.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	glow.accent_color = accent_color
	root.add_child(glow)
	root.move_child(glow, 0)

class _GlowBackground extends Control:
	const BG_COLOR := Color(0.06, 0.065, 0.095)
	var accent_color: Color = Color(0.91, 0.29, 0.35)

	func _ready() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		resized.connect(queue_redraw)

	func _draw() -> void:
		var w: float = size.x
		var h: float = size.y
		draw_rect(Rect2(Vector2.ZERO, size), BG_COLOR)
		# One big centered glow (the screen's main mood lighting) plus a
		# smaller, brighter one riding on top -- reads as a single richer
		# light source rather than two competing evenly-matched ones, which
		# a flat single-radius glow at this scale looked flat/dim.
		var big_radius := minf(w * 0.75, h * 1.1)
		_draw_glow(Vector2(w * 0.5, h * 0.42), big_radius, accent_color)
		_draw_glow(Vector2(w * 0.5, h * 0.42), big_radius * 0.4, accent_color)

	func _draw_glow(center: Vector2, max_radius: float, color: Color) -> void:
		var steps := 28
		for i in steps:
			var t := float(steps - i) / float(steps)
			var radius := max_radius * t
			var alpha := 0.006 + 0.02 * (1.0 - t)
			draw_circle(center, radius, Color(color.r, color.g, color.b, alpha))

const CHROME_DIR := "res://assets/icons/chrome"

## Loads a baked 9-patch chrome sprite (see tools/build_chrome_art.gd) as a
## StyleBoxTexture, or null if it's missing -- falls back to a procedural
## StyleBoxFlat in button_box()/panel_box()/style_slider() below when it is.
## `texture_margin` keeps the border/corner pixels a fixed on-screen size
## while the middle stretches to whatever size the caller's real button/
## panel/slider ends up at. `modulate` carries both the accent color AND
## the target alpha -- see build_chrome_art.gd's header comment for why a
## single alpha scalar on the whole baked image reproduces button_box()'s
## real per-state border/fill alpha pairs almost exactly.
static func _chrome_stylebox(kind: String, modulate: Color, texture_margin: float) -> StyleBoxTexture:
	var tex: Texture2D = GameAssetOverrides.load_override_texture(GameAssetOverrides.bar_override_path("chrome", kind))
	if not tex:
		var path := "%s/%s.png" % [CHROME_DIR, kind]
		if ResourceLoader.exists(path):
			tex = load(path)
	if not tex:
		return null
	var box := StyleBoxTexture.new()
	box.texture = tex
	box.texture_margin_left = texture_margin
	box.texture_margin_top = texture_margin
	box.texture_margin_right = texture_margin
	box.texture_margin_bottom = texture_margin
	box.modulate_color = modulate
	return box

static func button_box(color: Color, bg_alpha: float, border_alpha: float, radius: int = 10) -> StyleBox:
	var chrome := _chrome_stylebox("button", Color(color.r, color.g, color.b, border_alpha), 12.0)
	if chrome:
		chrome.content_margin_left = 16.0
		chrome.content_margin_top = 10.0
		chrome.content_margin_right = 16.0
		chrome.content_margin_bottom = 10.0
		return chrome
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

## A grey scrim + plain "X" over an existing button, blocking clicks through
## to it -- style_button()'s chrome look has no disabled variant of its own
## to fall back on (Godot's default disabled stylebox would look completely
## out of place next to it), so this is a small standalone overlay instead.
## Idempotent and toggleable: safe to call every frame/refresh with whatever
## the current disabled state should be.
static func set_disabled_overlay(btn: Button, is_disabled: bool) -> void:
	var overlay: Control = btn.get_node_or_null("_DisabledOverlay")
	if is_disabled and overlay == null:
		overlay = Control.new()
		overlay.name = "_DisabledOverlay"
		overlay.mouse_filter = Control.MOUSE_FILTER_STOP
		overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		btn.add_child(overlay)
		var scrim := ColorRect.new()
		scrim.color = Color(0.05, 0.05, 0.07, 0.75)
		scrim.mouse_filter = Control.MOUSE_FILTER_IGNORE
		scrim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		overlay.add_child(scrim)
		var x_label := Label.new()
		x_label.text = "X"
		x_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		x_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		x_label.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		x_label.add_theme_font_size_override("font_size", 28)
		x_label.add_theme_color_override("font_color", Color(0.75, 0.78, 0.85))
		x_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		overlay.add_child(x_label)
	elif not is_disabled and overlay != null:
		overlay.queue_free()
	btn.disabled = is_disabled

## Recolors an HSlider's default light-gray/white track and grabber (jarring
## against the dark theme) to match the rest of the UI -- a dark groove, a
## colored fill up to the current value, and a small grabber dot instead of
## the engine's default white circle icon. Several accent colors used here
## (e.g. COLOR_LOCAL) are themselves bright sky-blues -- a lightened fill
## plus a lightened-further white-ish grabber on top of it read as no
## different from Godot's own stock slider theme, which is the same light-
## blue-with-white-knob look. The groove is darkened instead of barely-there
## and the grabber keeps its full accent color with a dark ring around it
## (not lightened) so it stays visually distinct at a glance.
static func style_slider(slider: HSlider, color: Color) -> void:
	# Baked at exactly the groove's real flat black/0.35 alpha (see
	# tools/build_chrome_art.gd) -- no accent color involved, so modulate
	# is a pure white no-op, just carrying the texture through untouched.
	var groove: StyleBox = _chrome_stylebox("slider_groove", Color(1, 1, 1, 1), 5.0)
	if not groove:
		var groove_flat := StyleBoxFlat.new()
		groove_flat.bg_color = Color(0, 0, 0, 0.35)
		groove_flat.corner_radius_top_left = 4
		groove_flat.corner_radius_top_right = 4
		groove_flat.corner_radius_bottom_right = 4
		groove_flat.corner_radius_bottom_left = 4
		groove_flat.content_margin_top = 4.0
		groove_flat.content_margin_bottom = 4.0
		groove = groove_flat
	slider.add_theme_stylebox_override("slider", groove)

	# Baked white at the real 0.9 alpha -- modulate's RGB tints it to the
	# accent color, its alpha of 1.0 leaves the baked 0.9 untouched.
	var fill: StyleBox = _chrome_stylebox("slider_fill", Color(color.r, color.g, color.b, 1.0), 5.0)
	if not fill:
		var fill_flat := StyleBoxFlat.new()
		fill_flat.bg_color = Color(color.r, color.g, color.b, 0.9)
		fill_flat.corner_radius_top_left = 4
		fill_flat.corner_radius_top_right = 4
		fill_flat.corner_radius_bottom_right = 4
		fill_flat.corner_radius_bottom_left = 4
		fill_flat.content_margin_top = 4.0
		fill_flat.content_margin_bottom = 4.0
		fill = fill_flat
	slider.add_theme_stylebox_override("grabber_area", fill)
	slider.add_theme_stylebox_override("grabber_area_highlight", fill)

	# Baked once (see tools/build_procedural_sprites.gd) for the one color
	# every real call site actually uses (COLOR_LOCAL) -- "nothing made at
	# runtime" per the project's own convention. Any other color still
	# generates live below, so this never hard-fails on an uncommon accent.
	var dot_tex: Texture2D = null
	const BAKED_GRABBER_PATH := "res://assets/icons/slider_grabber_local.png"
	if color.is_equal_approx(COLOR_LOCAL) and ResourceLoader.exists(BAKED_GRABBER_PATH):
		dot_tex = load(BAKED_GRABBER_PATH)
	if not dot_tex:
		var dot := Image.create(14, 14, false, Image.FORMAT_RGBA8)
		dot.fill(Color(0, 0, 0, 0))
		var ring := Color(0.08, 0.08, 0.11)
		for y in 14:
			for x in 14:
				var dist := Vector2(x - 6.5, y - 6.5).length()
				if dist <= 6.5:
					dot.set_pixel(x, y, ring)
				if dist <= 5.0:
					dot.set_pixel(x, y, color)
		dot_tex = ImageTexture.create_from_image(dot)
	slider.add_theme_icon_override("grabber", dot_tex)
	slider.add_theme_icon_override("grabber_highlight", dot_tex)
	slider.add_theme_icon_override("grabber_disabled", dot_tex)

## A translucent bordered panel background -- used for roster lists, server
## lists, cards, and other content wells that need to visually separate
## from the backdrop without competing with buttons for attention.
static func panel_box(color: Color = COLOR_NEUTRAL, bg_alpha: float = 0.05, border_alpha: float = 0.12, radius: int = 14) -> StyleBox:
	var chrome := _chrome_stylebox("panel", Color(color.r, color.g, color.b, border_alpha), 16.0)
	if chrome:
		chrome.content_margin_left = 14.0
		chrome.content_margin_top = 14.0
		chrome.content_margin_right = 14.0
		chrome.content_margin_bottom = 14.0
		return chrome
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

## Every LineEdit in the app previously fell through to theme.tres's one
## generic near-transparent purple box (4-6% bg alpha) regardless of
## screen, reading as barely-there next to every button's opaque
## hard-bordered panel_box()/button_box() look -- this gives text fields
## the exact same visual language as style_back_button() (same
## button_box() alpha levels, same neutral color by default).
static func style_line_edit(edit: LineEdit, color: Color = COLOR_NEUTRAL, radius: int = 8) -> void:
	edit.add_theme_color_override("font_color", Color(0.894, 0.906, 0.941, 1))
	edit.add_theme_color_override("font_placeholder_color", Color(color.r, color.g, color.b, 0.6))
	edit.add_theme_color_override("font_uneditable_color", Color(color.r, color.g, color.b, 0.8))
	edit.add_theme_color_override("caret_color", color.lightened(0.4))
	edit.add_theme_color_override("selection_color", Color(color.r, color.g, color.b, 0.35))
	edit.add_theme_stylebox_override("normal", button_box(color, 0.14, 0.35, radius))
	edit.add_theme_stylebox_override("focus", button_box(color, 0.26, 0.75, radius))
	edit.add_theme_stylebox_override("read_only", button_box(color, 0.08, 0.2, radius))

## A small colored icon glyph anchored to a button's left edge, over its
## existing text (which should start with a couple spaces of padding to
## make room) -- for buttons too narrow for full painted whole-button art
## to read cleanly (inline actions like a chat Send button or a friend-code
## Copy button), same "give it a sprite" treatment as everywhere else in
## the app, at a scale that actually fits. Matches main_menu.gd's corner-
## button icon_wrap pattern, factored out here now that more than one
## screen needs it.
static func prefix_icon(btn: Button, icon_type: String, color: Color) -> void:
	var icon_wrap := Control.new()
	icon_wrap.mouse_filter = Control.MOUSE_FILTER_IGNORE
	icon_wrap.set_anchors_preset(Control.PRESET_CENTER_LEFT)
	icon_wrap.position = Vector2(12, -9)
	icon_wrap.custom_minimum_size = Vector2(18, 18)
	var icon := ModeIconScene.new()
	icon.icon_type = icon_type
	icon.icon_color = color
	icon.set_anchors_preset(Control.PRESET_FULL_RECT)
	icon_wrap.add_child(icon)
	btn.add_child(icon_wrap)

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
