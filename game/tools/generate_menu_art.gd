extends Node

# Paints genuine low-res pixel art (not smooth gradients) for the 2 mode
# buttons and 14 menu backgrounds, then nearest-neighbor-upscales each to
# its real in-game size so the blocky pixel look stays crisp. Text labels
# on the buttons are rendered separately via a real Label (crisp, not
# pixelated) and composited on top, same as any pixel-art game's UI text
# usually stays sharp over a pixel-art scene. Writes straight into
# game/assets/ -- the same baked-into-the-build fallback path
# UIStyle.add_background()/main_menu.gd check when no live-published
# override exists, so re-running this is what regenerates the game's
# actual default look, the same way build_tileset.gd/build_icon_atlas.gd
# do for their own assets. Run via:
#   godot --path . res://tools/generate_menu_art.tscn
# NOT --headless -- the button text step renders a Label through a
# SubViewport, which needs a real rendering backend.

const BACKGROUND_OUT_DIR := "res://assets/backgrounds"
const MODE_BUTTON_OUT_DIR := "res://assets/icons/mode_buttons"
const ONLINE_BAR_OUT_DIR := "res://assets/icons/online_bars"
const LOCAL_BAR_OUT_DIR := "res://assets/icons/local_bars"
const RANKED_BAR_OUT_DIR := "res://assets/icons/ranked_bars"

const BG_TOP := Color(0.106, 0.11, 0.157)
const BG_MID := Color(0.07, 0.075, 0.11)
const BG_BOTTOM := Color(0.043, 0.047, 0.075)

const COLOR_QUICKPLAY := Color(0.98, 0.75, 0.2)
const COLOR_RANKED := Color(0.91, 0.29, 0.35)
const COLOR_LOCAL := Color(0.35, 0.78, 0.98)
const COLOR_ONLINE := Color(0.42, 0.85, 0.55)
const COLOR_SHOP := Color(0.65, 0.48, 0.98)
const COLOR_NEUTRAL := Color(0.6, 0.63, 0.72)

const BG_FINAL_SIZE := Vector2i(1152, 648)
const BG_DESIGN_SIZE := Vector2i(144, 81) # 8x upscale
const BTN_FINAL_SIZE := Vector2i(190, 360)
const BTN_DESIGN_SIZE := Vector2i(38, 72) # 5x upscale
# Matches online_menu.tscn's bar custom_minimum_size exactly.
const BAR_FINAL_SIZE := Vector2i(170, 290)
const BAR_DESIGN_SIZE := Vector2i(34, 58) # 5x upscale
# Matches local_menu.tscn's StartButton/BackButton rendered size (they fill
# the 380px-wide VBox at fixed heights) -- landscape, not portrait, unlike
# every other painted button/bar so far, so these use their own
# _make_horizontal_bar_art() composition instead of _make_bar_art(). Design
# height kept much closer to final height than the other assets' ~5x
# upscale (only ~2.3-2.7x here) -- at these short heights a 5x-downscaled
# design gives the play-triangle/arrow icons too few pixels to read as
# anything but noise (confirmed by screenshot on a first pass at 13px/8px
# design height).
const PLAY_FINAL_SIZE := Vector2i(380, 64)
const PLAY_DESIGN_SIZE := Vector2i(142, 24)
const BACK_FINAL_SIZE := Vector2i(380, 36)
const BACK_DESIGN_SIZE := Vector2i(168, 16)
# The ranked VS reveal screen (match_intro.gd) gets a busier background than
# every other screen -- 192x108 instead of the standard 144x81 gives the
# light-ray/corner-flourish detail enough room to actually read once
# upscaled, rather than smearing into noise.
const RANKED_VS_BG_DESIGN_SIZE := Vector2i(192, 108)
const READY_FINAL_SIZE := Vector2i(320, 64)
const READY_DESIGN_SIZE := Vector2i(120, 24)

func _ready() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(BACKGROUND_OUT_DIR))
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(MODE_BUTTON_OUT_DIR))
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(ONLINE_BAR_OUT_DIR))
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(LOCAL_BAR_OUT_DIR))
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(RANKED_BAR_OUT_DIR))

	# No central icon here (unlike every other screen) -- the real UI
	# already places two big Online/Local cards front-and-center over this
	# background, at almost exactly the same position/size a bold icon
	# would occupy; painting one in makes it look like a rendering glitch
	# (confirmed by screenshot) rather than a deliberate design. Keep it to
	# the atmospheric sky/stars/border treatment alone.
	_make_background("main_menu", COLOR_ONLINE, "none", COLOR_LOCAL)
	_make_background("online_menu", COLOR_ONLINE, "globe")
	_make_background("local_menu", COLOR_LOCAL, "house")
	_make_background("shop", COLOR_SHOP, "gift")
	_make_background("friends_menu", COLOR_SHOP, "heart")
	_make_background("lobby_room", COLOR_ONLINE, "group")
	_make_background("host_setup", COLOR_ONLINE, "gear")
	_make_background("login_screen", COLOR_QUICKPLAY, "door")
	_make_background("match_intro", COLOR_QUICKPLAY, "faceoff", COLOR_RANKED)
	_make_background("match_results", COLOR_QUICKPLAY, "trophy")
	_make_background("multiplayer_connect", COLOR_NEUTRAL, "link")
	_make_background("quick_play", COLOR_QUICKPLAY, "bolt")
	_make_background("ranked_queue", COLOR_RANKED, "crown")
	_make_background("server_browser", COLOR_ONLINE, "signal")

	await _make_bar_art(MODE_BUTTON_OUT_DIR, "online", COLOR_ONLINE, "globe", "ONLINE", BTN_FINAL_SIZE, BTN_DESIGN_SIZE, 28)
	await _make_bar_art(MODE_BUTTON_OUT_DIR, "local", COLOR_LOCAL, "house", "LOCAL", BTN_FINAL_SIZE, BTN_DESIGN_SIZE, 28)

	# Full whole-bar art for the Online submenu's 5 plain bars (Quick Play/
	# Ranked/Browse Servers/Host Server/Friends) -- see online_menu.gd.
	# Same composition as the mode buttons above (background scene + icon +
	# character + label), not just a small icon glyph -- a first pass that
	# only added an icon on top of the existing styled button looked
	# inconsistent sitting next to the fully-painted mode buttons.
	await _make_bar_art(ONLINE_BAR_OUT_DIR, "quick_play", COLOR_QUICKPLAY, "bolt", "Quick Play", BAR_FINAL_SIZE, BAR_DESIGN_SIZE, 18)
	await _make_bar_art(ONLINE_BAR_OUT_DIR, "ranked", COLOR_RANKED, "crown", "Ranked", BAR_FINAL_SIZE, BAR_DESIGN_SIZE, 18)
	await _make_bar_art(ONLINE_BAR_OUT_DIR, "browse_servers", COLOR_ONLINE, "signal", "Browse Servers", BAR_FINAL_SIZE, BAR_DESIGN_SIZE, 16)
	await _make_bar_art(ONLINE_BAR_OUT_DIR, "host_server", COLOR_ONLINE, "gear", "Host Server", BAR_FINAL_SIZE, BAR_DESIGN_SIZE, 16)
	await _make_bar_art(ONLINE_BAR_OUT_DIR, "friends", COLOR_SHOP, "heart", "Friends", BAR_FINAL_SIZE, BAR_DESIGN_SIZE, 18)

	# Local menu's Play Tag / Back -- same painted treatment as every other
	# real button in the app, just in a wide landscape shape instead of the
	# tall portrait one every other bar/button above uses.
	await _make_horizontal_bar_art(LOCAL_BAR_OUT_DIR, "play", COLOR_LOCAL, "play", "Play Tag", PLAY_FINAL_SIZE, PLAY_DESIGN_SIZE, 22)
	await _make_horizontal_bar_art(LOCAL_BAR_OUT_DIR, "back", COLOR_NEUTRAL, "back_arrow", "Back", BACK_FINAL_SIZE, BACK_DESIGN_SIZE, 16)

	# Ranked "match found" VS reveal (match_intro.gd) -- deliberately busier/
	# flashier than every other screen's plain banded-sky treatment (light
	# rays, denser stars, corner flourishes), since this is a one-off hype
	# moment rather than a background players stare at during normal menu
	# navigation.
	_make_ranked_vs_background()
	await _make_horizontal_bar_art(RANKED_BAR_OUT_DIR, "ready", COLOR_RANKED, "crown", "Ready!", READY_FINAL_SIZE, READY_DESIGN_SIZE, 20)

	print("GENERATE_DONE")
	get_tree().quit()

# ─── Background composition ─────────────────────────────────────────────

func _make_background(key: String, color: Color, icon: String, color2: Color = Color.TRANSPARENT) -> void:
	var img := Image.create(BG_DESIGN_SIZE.x, BG_DESIGN_SIZE.y, false, Image.FORMAT_RGBA8)
	_paint_banded_sky(img, color)
	_scatter_stars(img, key)
	# A corner placement (tried first) mostly ended up hidden behind
	# whichever card happened to sit there, or cropped out of view
	# entirely depending on the screen's own layout -- confirmed by
	# screenshot, all that was actually visible on several screens was the
	# star scatter alone, reading as noise rather than deliberate art.
	# Big and dead-center is the only placement that's reliably in frame
	# on every screen regardless of its content; drawn onto a separate
	# transparent layer and blended in at low alpha (see _blend_onto) so
	# it stays a watermark behind foreground text/cards instead of a hard
	# collision with them.
	if icon != "none":
		var icon_img := Image.create(BG_DESIGN_SIZE.x, BG_DESIGN_SIZE.y, false, Image.FORMAT_RGBA8)
		icon_img.fill(Color(0, 0, 0, 0))
		_draw_icon(icon_img, icon, BG_DESIGN_SIZE.x / 2, int(BG_DESIGN_SIZE.y * 0.48), 28, color, color2)
		_blend_onto(img, icon_img, 0.32)
	_px_rect(img, 0, BG_DESIGN_SIZE.y - 6, BG_DESIGN_SIZE.x, 6, BG_BOTTOM.darkened(0.2))
	_px_border(img, color)
	# resize() modifies in place (no return value) -- INTERPOLATE_NEAREST
	# keeps the upscale genuinely blocky/pixelated instead of smoothing it
	# into a blurry gradient.
	img.resize(BG_FINAL_SIZE.x, BG_FINAL_SIZE.y, Image.INTERPOLATE_NEAREST)
	img.save_png("%s/%s.png" % [BACKGROUND_OUT_DIR, key])
	print("painted background: ", key)

## A deliberately busier composition than _make_background()'s plain banded
## sky -- radiating light rays behind the impending VS cards, denser stars,
## and corner flourish streaks -- for match_intro.gd's ranked "match found"
## reveal specifically. Saved under the "match_intro_ranked" screen key,
## separate from the plain "match_intro" background casual matches keep.
func _make_ranked_vs_background() -> void:
	var img := Image.create(RANKED_VS_BG_DESIGN_SIZE.x, RANKED_VS_BG_DESIGN_SIZE.y, false, Image.FORMAT_RGBA8)
	_paint_banded_sky(img, COLOR_RANKED)
	_paint_light_rays(img, COLOR_RANKED)
	_scatter_stars(img, "match_intro_ranked_a")
	_scatter_stars(img, "match_intro_ranked_b")
	_px_corner_flourish(img, COLOR_RANKED)
	_px_rect(img, 0, RANKED_VS_BG_DESIGN_SIZE.y - 7, RANKED_VS_BG_DESIGN_SIZE.x, 7, BG_BOTTOM.darkened(0.2))
	_px_border(img, COLOR_RANKED)
	img.resize(BG_FINAL_SIZE.x, BG_FINAL_SIZE.y, Image.INTERPOLATE_NEAREST)
	img.save_png("%s/match_intro_ranked.png" % BACKGROUND_OUT_DIR)
	print("painted ranked vs background")

## Alternating light/dark diagonal wedges radiating from center -- a classic
## "impact/reveal" motif, and most of what makes this background read as
## busier than every other screen's plain gradient.
func _paint_light_rays(img: Image, color: Color) -> void:
	var w := img.get_width()
	var h := img.get_height()
	var cx := w / 2.0
	var cy := h / 2.0
	var ray_color := Color(color.r, color.g, color.b, 1.0)
	for y in h:
		for x in w:
			var ang := atan2(float(y) - cy, float(x) - cx)
			var seg := int(floor((ang + PI) / (PI / 10.0))) # 20 wedges around the circle
			if seg % 2 == 0:
				var px := img.get_pixel(x, y)
				img.set_pixel(x, y, px.lerp(ray_color, 0.16))

## Small streaked chevrons in each corner, pointing inward -- cheap extra
## "this is a busy/energetic screen" detail beyond the plain border every
## other background gets.
func _px_corner_flourish(img: Image, color: Color) -> void:
	var w := img.get_width()
	var h := img.get_height()
	var n := int(minf(w, h) * 0.16)
	var accent := color.lightened(0.35)
	for corner in 4:
		var dx := 1 if corner % 2 == 0 else -1
		var dy := 1 if corner < 2 else -1
		var ox := 0 if corner % 2 == 0 else w
		var oy := 0 if corner < 2 else h
		for i in n:
			_px_rect(img, ox + dx * i, oy + dy * (n - i), 2, 2, accent)
			_px_rect(img, ox + dx * (i + 4), oy + dy * (n - i), 1, 1, accent)

## Shared by the 2 mode buttons and the 5 online-submenu bars -- same
## composition (background scene + icon + character + label) at whatever
## size/font each one actually renders at.
func _make_bar_art(out_dir: String, key: String, color: Color, icon: String, label_text: String, final_size: Vector2i, design_size: Vector2i, font_size: int) -> void:
	var img := Image.create(design_size.x, design_size.y, false, Image.FORMAT_RGBA8)
	_paint_banded_sky(img, color)
	_scatter_stars(img, key)
	_draw_icon(img, icon, design_size.x / 2, int(design_size.y * 0.28), int(design_size.x * 0.3), color)
	_px_character(img, design_size.x / 2 - 4, int(design_size.y * 0.53), 8, color)
	_px_rect(img, 0, design_size.y - 16, design_size.x, 16, BG_BOTTOM.darkened(0.3))
	_px_border(img, color)
	img.resize(final_size.x, final_size.y, Image.INTERPOLATE_NEAREST)
	# Real font rendering (crisp, not pixelated) for the label -- composited
	# on top of the pixel-art scene after upscaling, same as most pixel-art
	# games keep their UI text sharp over a blocky-pixel backdrop.
	var text_img := await _render_text(label_text, font_size)
	_blit_centered(img, text_img, final_size.x / 2, final_size.y - 44)
	img.save_png("%s/%s.png" % [out_dir, key])
	print("painted bar art: ", key)

## Landscape counterpart to _make_bar_art() -- icon sits left-of-center
## (there's no room for icon+character+label stacked vertically at 64px or
## 36px tall), label centered in the remaining right-hand space.
func _make_horizontal_bar_art(out_dir: String, key: String, color: Color, icon: String, label_text: String, final_size: Vector2i, design_size: Vector2i, font_size: int) -> void:
	var img := Image.create(design_size.x, design_size.y, false, Image.FORMAT_RGBA8)
	_paint_banded_sky(img, color)
	_scatter_stars(img, key)
	var icon_cx := int(design_size.x * 0.12)
	_draw_icon(img, icon, icon_cx, design_size.y / 2, int(design_size.y * 0.38), color)
	_px_border(img, color)
	img.resize(final_size.x, final_size.y, Image.INTERPOLATE_NEAREST)
	var text_img := await _render_text(label_text, font_size)
	_blit_centered(img, text_img, final_size.x / 2 + int(final_size.x * 0.06), final_size.y / 2)
	img.save_png("%s/%s.png" % [out_dir, key])
	print("painted local bar art: ", key)

func _render_text(text: String, font_size: int) -> Image:
	var viewport := SubViewport.new()
	viewport.size = Vector2i(220, 60)
	viewport.transparent_bg = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(viewport)
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", Color.WHITE)
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	viewport.add_child(label)
	await get_tree().process_frame
	await get_tree().process_frame
	var img := viewport.get_texture().get_image()
	viewport.queue_free()
	return img

func _blit_centered(dst: Image, src: Image, cx: int, cy: int) -> void:
	var ox := cx - src.get_width() / 2
	var oy := cy - src.get_height() / 2
	for y in src.get_height():
		for x in src.get_width():
			var px := src.get_pixel(x, y)
			if px.a <= 0.01:
				continue
			var dx := ox + x
			var dy := oy + y
			if dx >= 0 and dx < dst.get_width() and dy >= 0 and dy < dst.get_height():
				dst.set_pixel(dx, dy, dst.get_pixel(dx, dy).lerp(px, px.a))

## Composites `src` onto `dst` (same size) at `alpha` -- used to lay a big,
## centered icon over a background as a translucent watermark rather than a
## hard-edged, fully-opaque shape that would collide with foreground text.
func _blend_onto(dst: Image, src: Image, alpha: float) -> void:
	for y in src.get_height():
		for x in src.get_width():
			var px := src.get_pixel(x, y)
			if px.a <= 0.01:
				continue
			dst.set_pixel(x, y, dst.get_pixel(x, y).lerp(px, px.a * alpha))

# ─── Shared base treatment ───────────────────────────────────────────────

func _paint_banded_sky(img: Image, color: Color) -> void:
	var w := img.get_width()
	var h := img.get_height()
	var tint := color.darkened(0.75)
	for y in h:
		var t := float(y) / float(h - 1)
		var row: Color
		if t < 0.4:
			row = BG_TOP.lerp(tint, t / 0.4 * 0.5)
		elif t < 0.75:
			row = BG_TOP.lerp(BG_MID, (t - 0.4) / 0.35)
		else:
			row = BG_MID.lerp(BG_BOTTOM, (t - 0.75) / 0.25)
		for x in w:
			img.set_pixel(x, y, row)

## Deterministic (seeded by key) scatter of single-pixel "stars" -- cheap
## pixel-art texture that reads as atmosphere without needing real assets.
func _scatter_stars(img: Image, key: String) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(key)
	var w := img.get_width()
	var h := img.get_height()
	var count := int(w * h * 0.009)
	for i in count:
		var x := rng.randi_range(0, w - 1)
		var y := rng.randi_range(0, int(h * 0.7))
		var a := rng.randf_range(0.15, 0.5)
		var px := img.get_pixel(x, y)
		img.set_pixel(x, y, px.lerp(Color.WHITE, a))

func _px_border(img: Image, color: Color) -> void:
	var w := img.get_width()
	var h := img.get_height()
	var c := Color(color.r, color.g, color.b, 0.6)
	for x in w:
		img.set_pixel(x, 0, c)
		img.set_pixel(x, h - 1, c)
	for y in h:
		img.set_pixel(0, y, c)
		img.set_pixel(w - 1, y, c)

# ─── Icon dispatch ────────────────────────────────────────────────────────

func _draw_icon(img: Image, icon: String, cx: int, cy: int, r: int, color: Color, color2: Color = Color.TRANSPARENT) -> void:
	match icon:
		"globe": _icon_globe(img, cx, cy, r, color)
		"house": _icon_house(img, cx, cy, r, color)
		"gift": _icon_gift(img, cx, cy, r, color)
		"heart": _icon_heart(img, cx, cy, r, color)
		"group": _icon_group(img, cx, cy, r, color)
		"gear": _icon_gear(img, cx, cy, r, color)
		"door": _icon_door(img, cx, cy, r, color)
		"trophy": _icon_trophy(img, cx, cy, r, color)
		"link": _icon_link(img, cx, cy, r, color)
		"bolt": _icon_bolt(img, cx, cy, r, color)
		"crown": _icon_crown(img, cx, cy, r, color)
		"signal": _icon_signal(img, cx, cy, r, color)
		"diamond": _icon_diamond(img, cx, cy, r, color, color2)
		"faceoff": _icon_faceoff(img, cx, cy, r, color, color2)
		"play": _icon_play(img, cx, cy, r, color)
		"back_arrow": _icon_back_arrow(img, cx, cy, r, color)

# ─── Icon library (all operate in small pixel units around cx,cy) ────────

func _icon_globe(img: Image, cx: int, cy: int, r: int, color: Color) -> void:
	_px_ring(img, cx, cy, r, color)
	_px_line(img, cx - r, cy, cx + r, cy, color)
	_px_line(img, cx, cy - r, cx, cy + r, color)
	_px_ellipse_ring(img, cx, cy, int(r * 0.45), r, color)

func _icon_house(img: Image, cx: int, cy: int, r: int, color: Color) -> void:
	var body_w := int(r * 1.4)
	var body_h := int(r * 1.0)
	_px_rect(img, cx - body_w / 2, cy - body_h / 4, body_w, body_h, color.darkened(0.2))
	_px_triangle(img, cx, cy - body_h, cx - body_w / 2 - 3, cy - body_h / 4, cx + body_w / 2 + 3, cy - body_h / 4, color)
	_px_rect(img, cx - 3, cy + body_h / 2 - 5, 6, 6, BG_BOTTOM)

func _icon_gift(img: Image, cx: int, cy: int, r: int, color: Color) -> void:
	var w := int(r * 1.3)
	var h := int(r * 1.1)
	_px_rect(img, cx - w / 2, cy - h / 4, w, h, color.darkened(0.15))
	_px_rect(img, cx - 2, cy - h / 4, 4, h, color.lightened(0.3))
	_px_rect(img, cx - w / 2, cy - h / 4 - 4, w, 4, color.lightened(0.2))

## Explicit bitmap, same reasoning as BOLT_PATTERN -- the previous
## circles-plus-triangle version lost its notch entirely at small sizes
## (confirmed by screenshot on the online-menu Friends bar icon, where it
## just read as a rounded blob) since a couple pixels of gap between two
## small overlapping circles vanishes at low resolution. A hand-placed
## pattern stays a clearly-a-heart silhouette at any scale.
const HEART_PATTERN := [
	".XX.XX.",
	"XXXXXXX",
	"XXXXXXX",
	".XXXXX.",
	"..XXX..",
	"...X...",
]

func _icon_heart(img: Image, cx: int, cy: int, r: int, color: Color) -> void:
	var scale: int = maxi(1, int(r / 3.5))
	var pat_w := HEART_PATTERN[0].length()
	var pat_h := HEART_PATTERN.size()
	var ox := cx - (pat_w * scale) / 2
	var oy := cy - (pat_h * scale) / 2
	for row in pat_h:
		var line: String = HEART_PATTERN[row]
		for col in pat_w:
			if line[col] == "X":
				_px_rect(img, ox + col * scale, oy + row * scale, scale, scale, color)

func _icon_group(img: Image, cx: int, cy: int, r: int, color: Color) -> void:
	_px_character(img, cx - 4, cy - 4, 8, color)
	_px_character(img, cx - 14, cy + 2, 6, color.darkened(0.15))
	_px_character(img, cx + 8, cy + 2, 6, color.darkened(0.15))

func _icon_gear(img: Image, cx: int, cy: int, r: int, color: Color) -> void:
	_px_circle(img, cx, cy, r, color)
	_px_circle(img, cx, cy, int(r * 0.45), BG_BOTTOM)
	for i in 8:
		var ang := TAU * float(i) / 8.0
		var tx := cx + int(cos(ang) * (r + 4))
		var ty := cy + int(sin(ang) * (r + 4))
		_px_rect(img, tx - 2, ty - 2, 4, 4, color)

func _icon_door(img: Image, cx: int, cy: int, r: int, color: Color) -> void:
	var w := int(r * 1.0)
	var h := int(r * 1.8)
	_px_rect(img, cx - w / 2, cy - h / 2, w, h, color.darkened(0.2))
	_px_circle(img, cx + w / 2 - 5, cy, 2, color.lightened(0.4))

func _icon_trophy(img: Image, cx: int, cy: int, r: int, color: Color) -> void:
	_px_trapezoid(img, cx, cy - r, r, int(r * 0.5), int(r * 0.9), color)
	_px_ring(img, cx - r - 2, cy - r + 5, 5, color)
	_px_ring(img, cx + r + 2, cy - r + 5, 5, color)
	_px_rect(img, cx - 2, cy, 4, int(r * 0.6), color.darkened(0.2))
	_px_rect(img, cx - int(r * 0.5), cy + int(r * 0.6), int(r), 4, color.darkened(0.3))

func _icon_link(img: Image, cx: int, cy: int, r: int, color: Color) -> void:
	_px_ring(img, cx - r / 2, cy, int(r * 0.4), color)
	_px_ring(img, cx + r / 2, cy, int(r * 0.4), color)
	_px_line(img, cx - int(r * 0.2), cy, cx + int(r * 0.2), cy, color)

## Explicit bitmap (not freeform coordinate guesses) -- much more reliable
## for a shape this specific/recognizable than computed geometry.
const BOLT_PATTERN := [
	"....XX",
	"...XX.",
	"..XX..",
	".XXXXX",
	"XXXXX.",
	"....XX",
	"...XX.",
	"..XX..",
	".XX...",
]

func _icon_bolt(img: Image, cx: int, cy: int, r: int, color: Color) -> void:
	var scale: int = maxi(1, int(r / 3.0))
	var pat_w := BOLT_PATTERN[0].length()
	var pat_h := BOLT_PATTERN.size()
	var ox := cx - (pat_w * scale) / 2
	var oy := cy - (pat_h * scale) / 2
	for row in pat_h:
		var line: String = BOLT_PATTERN[row]
		for col in pat_w:
			if line[col] == "X":
				_px_rect(img, ox + col * scale, oy + row * scale, scale, scale, color)

func _icon_crown(img: Image, cx: int, cy: int, r: int, color: Color) -> void:
	var band_y := cy + int(r * 0.3)
	var band_h := int(r * 0.5)
	_px_rect(img, cx - r, band_y, r * 2, band_h, color)
	# 3 separate points with real gaps between them (unlike a single jagged
	# silhouette) so this reads as a crown's points, not a mountain range.
	var side_apex_y := cy - int(r * 0.1)
	var mid_apex_y := cy - int(r * 0.6)
	_px_triangle_up(img, cx - int(r * 0.65), side_apex_y, band_y, r * 0.28, color)
	_px_triangle_up(img, cx, mid_apex_y, band_y, r * 0.32, color)
	_px_triangle_up(img, cx + int(r * 0.65), side_apex_y, band_y, r * 0.28, color)
	_px_circle(img, cx - int(r * 0.65), side_apex_y - 2, 2, color.lightened(0.5))
	_px_circle(img, cx, mid_apex_y - 2, 2, color.lightened(0.5))
	_px_circle(img, cx + int(r * 0.65), side_apex_y - 2, 2, color.lightened(0.5))
	_px_circle(img, cx, band_y + band_h / 2, 2, color.lightened(0.3))

func _icon_signal(img: Image, cx: int, cy: int, r: int, color: Color) -> void:
	var bar_w := 5
	var gap := 3
	var heights := [int(r * 0.5), int(r * 0.9), int(r * 1.3), int(r * 1.7)]
	var start_x := cx - (heights.size() * (bar_w + gap)) / 2
	for i in heights.size():
		var bh: int = heights[i]
		_px_rect(img, start_x + i * (bar_w + gap), cy + r - bh, bar_w, bh, color)

func _icon_diamond(img: Image, cx: int, cy: int, r: int, color1: Color, color2: Color) -> void:
	_px_rect(img, cx - r - 4, cy - int(r * 0.7), int(r * 0.9), int(r * 1.4), color1)
	_px_rect(img, cx + r + 4 - int(r * 0.9), cy - int(r * 0.7), int(r * 0.9), int(r * 1.4), color2)
	_px_character(img, cx - r - 4 + int(r * 0.15), cy - 4, 8, color1.lightened(0.3))
	_px_character(img, cx + r + 4 - int(r * 0.9) + int(r * 0.15), cy - 4, 8, color2.lightened(0.3))

## A plain media-style "play" triangle -- the clearest possible glyph for
## "start the match" at these sizes, simpler than reusing "house"/"tag"
## (which already mean something else elsewhere) or drawing a character.
func _icon_play(img: Image, cx: int, cy: int, r: int, color: Color) -> void:
	_px_triangle(img, cx - int(r * 0.6), cy - r, cx - int(r * 0.6), cy + r, cx + r, cy, color)

func _icon_back_arrow(img: Image, cx: int, cy: int, r: int, color: Color) -> void:
	_px_triangle(img, cx + int(r * 0.5), cy - r, cx + int(r * 0.5), cy + r, cx - r, cy, color)
	_px_rect(img, cx, cy - 2, int(r * 0.9), 4, color)

func _icon_faceoff(img: Image, cx: int, cy: int, r: int, color1: Color, color2: Color) -> void:
	_px_character(img, cx - r, cy - 4, 9, color1)
	_px_character(img, cx + r - 9, cy - 4, 9, color2)
	for y in range(cy - r, cy + r, 4):
		_px_rect(img, cx - 1, y, 2, 2, Color(1, 1, 1, 0.6))

# ─── Pixel primitives ─────────────────────────────────────────────────────

func _px_rect(img: Image, x: int, y: int, w: int, h: int, color: Color) -> void:
	for py in range(maxi(y, 0), mini(y + h, img.get_height())):
		for px in range(maxi(x, 0), mini(x + w, img.get_width())):
			img.set_pixel(px, py, color)

func _px_circle(img: Image, cx: int, cy: int, r: int, color: Color) -> void:
	for y in range(maxi(cy - r, 0), mini(cy + r + 1, img.get_height())):
		for x in range(maxi(cx - r, 0), mini(cx + r + 1, img.get_width())):
			if Vector2(x - cx, y - cy).length() <= r:
				img.set_pixel(x, y, color)

func _px_ring(img: Image, cx: int, cy: int, r: int, color: Color) -> void:
	for y in range(maxi(cy - r - 1, 0), mini(cy + r + 2, img.get_height())):
		for x in range(maxi(cx - r - 1, 0), mini(cx + r + 2, img.get_width())):
			var d := Vector2(x - cx, y - cy).length()
			if d <= r + 1 and d >= r - 1:
				img.set_pixel(x, y, color)

func _px_ellipse_ring(img: Image, cx: int, cy: int, rx: int, ry: int, color: Color) -> void:
	if rx <= 0 or ry <= 0:
		return
	for y in range(maxi(cy - ry - 1, 0), mini(cy + ry + 2, img.get_height())):
		for x in range(maxi(cx - rx - 1, 0), mini(cx + rx + 2, img.get_width())):
			var d := pow(float(x - cx) / rx, 2) + pow(float(y - cy) / ry, 2)
			if d <= 1.15 and d >= 0.75:
				img.set_pixel(x, y, color)

func _px_line(img: Image, x0: int, y0: int, x1: int, y1: int, color: Color) -> void:
	var dx := absi(x1 - x0)
	var dy := -absi(y1 - y0)
	var sx := 1 if x0 < x1 else -1
	var sy := 1 if y0 < y1 else -1
	var err := dx + dy
	var x := x0
	var y := y0
	while true:
		if x >= 0 and x < img.get_width() and y >= 0 and y < img.get_height():
			img.set_pixel(x, y, color)
		if x == x1 and y == y1:
			break
		var e2 := 2 * err
		if e2 >= dy:
			err += dy
			x += sx
		if e2 <= dx:
			err += dx
			y += sy

func _px_triangle(img: Image, ax: int, ay: int, bx: int, by: int, cxp: int, cyp: int, color: Color) -> void:
	var min_y: int = mini(ay, mini(by, cyp))
	var max_y: int = maxi(ay, maxi(by, cyp))
	for y in range(maxi(min_y, 0), mini(max_y + 1, img.get_height())):
		var xs: Array = []
		for edge in [[ax, ay, bx, by], [bx, by, cxp, cyp], [cxp, cyp, ax, ay]]:
			var x0: int = edge[0]; var y0: int = edge[1]; var x1: int = edge[2]; var y1: int = edge[3]
			if y0 == y1:
				continue
			if (y >= mini(y0, y1)) and (y < maxi(y0, y1)):
				var t := float(y - y0) / float(y1 - y0)
				xs.append(x0 + t * (x1 - x0))
		if xs.size() >= 2:
			xs.sort()
			_px_rect(img, int(xs[0]), y, int(xs[-1] - xs[0]) + 1, 1, color)

func _px_triangle_up(img: Image, apex_x: float, apex_y: float, base_y: float, half_width: float, color: Color) -> void:
	var h := base_y - apex_y
	if h <= 0:
		return
	for y in range(int(apex_y), int(base_y) + 1):
		var t := (y - apex_y) / h
		var w := half_width * t
		_px_rect(img, int(apex_x - w), y, int(w * 2) + 1, 1, color)

func _px_trapezoid(img: Image, cx: int, top_y: int, top_half_w: int, bottom_half_w: int, height: int, color: Color) -> void:
	for i in height:
		var t := float(i) / float(height)
		var hw: float = lerp(float(top_half_w), float(bottom_half_w), t)
		_px_rect(img, cx - int(hw), top_y + i, int(hw * 2), 1, color)

## Matches the game's own real character rendering: a flat-colored square
## with 2 small dark eyes, same visual language as SkinCatalog's body.
func _px_character(img: Image, x: int, y: int, size: int, color: Color) -> void:
	_px_rect(img, x, y, size, size, color)
	_px_rect(img, x, y, size, 1, color.lightened(0.3))
	_px_rect(img, x, y + size - 1, size, 1, color.darkened(0.2))
	var eye := Color(0.05, 0.05, 0.08)
	var eye_y := y + int(size * 0.4)
	img.set_pixel(x + int(size * 0.3), eye_y, eye)
	img.set_pixel(x + int(size * 0.65), eye_y, eye)
