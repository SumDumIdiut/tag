extends Node

# Bakes every button's and panel's rounded-border box, and the slider
# groove/fill, into real 9-patch PNG source images, so UIStyle.button_box()/
# panel_box()/style_slider() can render them via StyleBoxTexture
# (fixed-width border pixels, stretchy middle) instead of generating a
# StyleBoxFlat at runtime. These are the pixel-art foundation ui_style.gd's
# art-first rewrite loads from disk.
#
# Also bakes MovingPlatform's 3 tile pieces (left/middle/right, see
# levels/moving_platform.gd) as flat placeholder squares matching its
# current solid-color look exactly -- real end-cap/middle art can replace
# these later via the Art Tool's Platform section without any code change.
#
# Painted flat white on transparent (button/panel) so ONE shared image
# covers every accent color via StyleBoxTexture.modulate_color at
# runtime, same "paint white, retint via modulate" convention
# build_icon_atlas.gd established. Button/panel bake the border region at
# full alpha and the fill region at a fixed ratio (0.4) of it -- chosen
# because it reproduces UIStyle's real normal/hover/pressed alpha pairs
# (0.14/0.35, 0.26/0.75, 0.4/1.0) almost exactly when the whole image is
# then modulated by the target border_alpha alone (fill_alpha comes out
# to border_alpha*0.4, matching two of the three states exactly and the
# third within ~0.04, imperceptible at these sizes).
#
# Run via:
#   godot --headless --path . res://tools/build_chrome_art.tscn
# Pure Image pixel math (no _draw()/SubViewport capture needed, unlike
# build_icon_atlas.gd/build_procedural_sprites.gd) -- safe headless.

const Categories := preload("res://net/game_asset_categories.gd")

const OUT_DIR := "res://assets/icons/chrome"

const PLATFORM_OUT_DIR := "res://assets/icons/platform"
const PLATFORM_TILE_SIZE := 10
# Matches moving_platform.tscn's current flat Visual ColorRect color exactly
# -- the placeholder bake should look identical to today until real left/
# middle/right art is painted over it via the Art Tool's Platform section.
const PLATFORM_COLOR := Color(0.85, 0.55, 0.2, 1)

const BUTTON_SIZE := 32
const BUTTON_RADIUS := 10
const BUTTON_BORDER := 2

const PANEL_SIZE := 40
const PANEL_RADIUS := 14
const PANEL_BORDER := 2

const FILL_RATIO := 0.4

const SLIDER_W := 20
const SLIDER_H := 14
const SLIDER_RADIUS := 4
# Matches style_slider()'s real groove color exactly (flat black, not
# accent-tinted) -- baked in directly, no runtime modulate needed.
const GROOVE_COLOR := Color(0, 0, 0, 0.35)
# Matches style_slider()'s real fill alpha (0.9) -- baked in white at that
# exact alpha; only the RGB gets tinted per accent color at runtime.
const FILL_ALPHA := 0.9

func _ready() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DIR))

	_make_border_fill_chrome(BUTTON_SIZE, BUTTON_SIZE, BUTTON_RADIUS, BUTTON_BORDER, FILL_RATIO).save_png("%s/button.png" % OUT_DIR)
	print("baked chrome: button")

	_make_border_fill_chrome(PANEL_SIZE, PANEL_SIZE, PANEL_RADIUS, PANEL_BORDER, FILL_RATIO).save_png("%s/panel.png" % OUT_DIR)
	print("baked chrome: panel")

	_make_flat_rounded(SLIDER_W, SLIDER_H, SLIDER_RADIUS, GROOVE_COLOR).save_png("%s/slider_groove.png" % OUT_DIR)
	print("baked chrome: slider_groove")

	_make_flat_rounded(SLIDER_W, SLIDER_H, SLIDER_RADIUS, Color(1, 1, 1, FILL_ALPHA)).save_png("%s/slider_fill.png" % OUT_DIR)
	print("baked chrome: slider_fill")

	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(PLATFORM_OUT_DIR))
	for key in Categories.PLATFORM_KEYS:
		_make_flat_rounded(PLATFORM_TILE_SIZE, PLATFORM_TILE_SIZE, 0, PLATFORM_COLOR).save_png("%s/%s.png" % [PLATFORM_OUT_DIR, key])
		print("baked platform: %s" % key)

	print("BUILD_CHROME_ART_DONE")
	get_tree().quit()

## Standard rounded-rect "inside" test: qx/qy measure how far px,py is
## outside the straight-edged core rect [r, w-r] x [r, h-r] in each axis
## (0 if within that range); a pixel is inside the rounded rect if that
## remaining offset is within radius r of the nearest corner.
func _rounded_rect_inside(px: float, py: float, w: float, h: float, r: float) -> bool:
	if r <= 0.0:
		return px >= 0.0 and px < w and py >= 0.0 and py < h
	var qx: float = maxf(0.0, maxf(r - px, px - (w - r)))
	var qy: float = maxf(0.0, maxf(r - py, py - (h - r)))
	return qx * qx + qy * qy <= r * r

## Border region (alpha=1.0) surrounding a fill region (alpha=fill_ratio),
## both white -- the border ring is the outer rounded rect minus the same
## shape inset by `border` pixels on every side (radius shrunk to match).
func _make_border_fill_chrome(w: int, h: int, radius: int, border: int, fill_ratio: float) -> Image:
	var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	var inner_r: float = maxf(float(radius - border), 0.0)
	for y in h:
		for x in w:
			var px := x + 0.5
			var py := y + 0.5
			if not _rounded_rect_inside(px, py, w, h, radius):
				continue
			var is_inner := _rounded_rect_inside(px - border, py - border, w - border * 2, h - border * 2, inner_r)
			var a: float = fill_ratio if is_inner else 1.0
			img.set_pixel(x, y, Color(1, 1, 1, a))
	return img

func _make_flat_rounded(w: int, h: int, radius: int, color: Color) -> Image:
	var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	for y in h:
		for x in w:
			if _rounded_rect_inside(x + 0.5, y + 0.5, w, h, radius):
				img.set_pixel(x, y, color)
	return img
