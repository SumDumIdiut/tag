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
}
const RANK_TIER_DEFAULT_COLOR := Color(0.6, 0.63, 0.72)

static func tier_color(tier: String) -> Color:
	return RANK_TIER_COLORS.get(tier, RANK_TIER_DEFAULT_COLOR)

## Matches project.godot's window/size/viewport_width/height -- a painted
## menu background (see the Art Tool's Icons page) is exported at exactly
## this size so it fills the screen at native resolution, same as
## MODE_BUTTON_SIZE matching main_menu.gd's BAR_SIZE.
const BACKGROUND_SIZE := Vector2i(1152, 648)
const BACKGROUND_ART_DIR := "res://assets/backgrounds"

## Adds a screen's backdrop as the first child of `root` -- call once from a
## screen's _ready(), before any other setup, so it renders behind
## everything else without needing every screen's own .tscn to carry a
## duplicate gradient sub-resource.
## `screen_key`: identifies which menu screen this is (e.g. "main_menu",
## "online_menu") so a friend's painted background (see the Art Tool's
## Icons page > MENU BACKGROUNDS) can be looked up for it -- a downloaded
## override (GameAssetOverrides) wins over whatever got baked in at CI
## time, same "newest wins" rule the mode-button art already follows. Left
## empty (the default), this always falls back to the plain procedural
## gradient -- used by screens that intentionally don't take a painted
## background, e.g. the Art Tool's own UI.
static func add_background(root: Control, screen_key: String = "") -> void:
	var bg: Control
	var tex: Texture2D = _load_background_texture(screen_key) if not screen_key.is_empty() else null
	if tex:
		var art := TextureRect.new()
		art.texture = tex
		art.stretch_mode = TextureRect.STRETCH_SCALE
		art.mouse_filter = Control.MOUSE_FILTER_IGNORE
		art.set_anchors_preset(Control.PRESET_FULL_RECT)
		bg = art
	else:
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
		bg = grad_rect
	root.add_child(bg)
	root.move_child(bg, 0)

## Override (a friend's painted background downloaded live, see
## GameAssetUpdater) first, baked-into-this-build second, same fallback
## order main_menu.gd already uses for mode-button art.
static func _load_background_texture(screen_key: String) -> Texture2D:
	var tex := GameAssetOverrides.load_override_texture(GameAssetOverrides.background_override_path(screen_key))
	if tex:
		return tex
	var art_path := "%s/%s.png" % [BACKGROUND_ART_DIR, screen_key]
	if ResourceLoader.exists(art_path):
		return load(art_path)
	return null

const CHROME_DIR := "res://assets/icons/chrome"

## Loads a baked 9-patch chrome sprite (see tools/build_chrome_art.gd) as a
## StyleBoxTexture, or null if it's missing -- same "art first, procedural
## StyleBoxFlat fallback" rule apply_bar_art()/apply_field_art() already
## follow. `texture_margin` keeps the border/corner pixels a fixed
## on-screen size while the middle stretches to whatever size the caller's
## real button/panel/slider ends up at (the same technique
## apply_field_art() already proved for LineEdit fields). `modulate`
## carries both the accent color AND the target alpha -- see
## build_chrome_art.gd's header comment for why a single alpha scalar on
## the whole baked image reproduces button_box()'s real per-state
## border/fill alpha pairs almost exactly.
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
## button_box() alpha levels, same neutral color by default) as a
## guaranteed fallback, but tries a real painted background first (see
## apply_field_art()) same "never hard-fail on missing custom content"
## rule as apply_bar_art() -- painted art wins when it exists, the flat
## box is what's left when it doesn't.
static func style_line_edit(edit: LineEdit, color: Color = COLOR_NEUTRAL, radius: int = 8) -> void:
	edit.add_theme_color_override("font_color", Color(0.894, 0.906, 0.941, 1))
	edit.add_theme_color_override("font_placeholder_color", Color(color.r, color.g, color.b, 0.6))
	edit.add_theme_color_override("font_uneditable_color", Color(color.r, color.g, color.b, 0.8))
	edit.add_theme_color_override("caret_color", color.lightened(0.4))
	edit.add_theme_color_override("selection_color", Color(color.r, color.g, color.b, 0.35))
	if apply_field_art(edit):
		return
	edit.add_theme_stylebox_override("normal", button_box(color, 0.14, 0.35, radius))
	edit.add_theme_stylebox_override("focus", button_box(color, 0.26, 0.75, radius))
	edit.add_theme_stylebox_override("read_only", button_box(color, 0.08, 0.2, radius))

## Whole-field painted background (see the Art Tool's Icons page "Input
## Field Art" section) -- unlike apply_bar_art() (which overlays a
## TextureRect on top of a Button, hiding its stylebox), a LineEdit draws
## its own stylebox with no child slot to overlay, so this wraps the same
## painted texture in a StyleBoxTexture instead: texture_margin_* keeps
## the border pixels fixed-width (9-patch stretch) so one shared image
## can stretch cleanly across every field's own width without warping,
## the same distortion problem apply_bar_art()'s KEEP_ASPECT_CENTERED
## fix solved for buttons. One shared image (like action_bars' "back")
## reused for every field, focus state modulated brighter for feedback
## instead of needing a second painted asset.
static func apply_field_art(edit: LineEdit) -> bool:
	var tex: Texture2D = GameAssetOverrides.load_override_texture(GameAssetOverrides.bar_override_path("field_art", "field"))
	if not tex:
		var path := "res://assets/icons/field_art/field.png"
		if ResourceLoader.exists(path):
			tex = load(path)
	if not tex:
		return false
	var normal := StyleBoxTexture.new()
	normal.texture = tex
	normal.texture_margin_left = 16
	normal.texture_margin_right = 16
	normal.texture_margin_top = 10
	normal.texture_margin_bottom = 10
	normal.content_margin_left = 12
	normal.content_margin_right = 12
	normal.content_margin_top = 8
	normal.content_margin_bottom = 8
	edit.add_theme_stylebox_override("normal", normal)
	edit.add_theme_stylebox_override("read_only", normal)
	var focus := normal.duplicate()
	focus.modulate_color = Color(1.3, 1.3, 1.35, 1.0)
	edit.add_theme_stylebox_override("focus", focus)
	return true

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

## Painted whole-button art if available (a downloaded live-published
## override first, then whatever got baked into this build at CI time),
## replacing the button's text with a full-bleed TextureRect -- same
## fallback chain every painted button in the app already uses (mode bars,
## online submenu bars, local menu's Play Tag/Back, the ranked VS screen's
## Ready button). No-op if neither exists, leaving the plain UIStyle-colored
## button already applied by style_button() as the fallback -- always safe
## to call speculatively, same "never hard-fail on missing custom content"
## rule the rest of the project follows.
## Returns true if real art was found and applied, false if the caller is
## left with the plain flat-colored fallback -- callers that build their own
## extra child controls (icon/label) on top of the plain fallback (e.g.
## ranked_playlist_select.gd's cards) use this to skip that procedural
## layer entirely when full art already covers it.
static func apply_bar_art(btn: Button, category: String, key: String) -> bool:
	var tex: Texture2D = GameAssetOverrides.load_override_texture(GameAssetOverrides.bar_override_path(category, key))
	if not tex:
		var path := "res://assets/icons/%s/%s.png" % [category, key]
		if ResourceLoader.exists(path):
			tex = load(path)
	if not tex:
		return false
	btn.text = ""
	btn.clip_contents = true
	var art := TextureRect.new()
	art.mouse_filter = Control.MOUSE_FILTER_IGNORE
	art.texture = tex
	# KEEP_ASPECT_CENTERED, not SCALE -- these buttons range from a narrow
	# half-width login button to a nearly-full-screen-wide friends-menu Back
	# button, all sharing the same handful of baked art pieces (deliberately,
	# to avoid painting a near-duplicate per screen). Force-stretching a
	# fixed-aspect image across that range visibly warped the icon/text at
	# the extremes (confirmed by screenshot on friends_menu's Back button --
	# the arrow and lettering both smeared sideways). Centered-and-preserved
	# just floats the art as a "pill" on the button's own flat-colored base
	# (already applied by style_button() before this runs) when the aspect
	# ratios don't match, which reads fine and never distorts.
	art.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	art.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	art.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	btn.add_child(art)
	return true

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
