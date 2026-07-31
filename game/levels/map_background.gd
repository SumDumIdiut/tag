extends Node2D
class_name MapBackground

# Procedural, per-map illustrative backdrop -- a themed two-tone sky gradient
# plus a handful of simple silhouette shapes (matching the game's existing
# "hard-edged, no gradients/anti-aliasing" procedural-art convention, see
# ui/local_map_icon.gd) hinting at the map's own theme (pyramid/mountain/
# island/etc.) rather than a flat color card. z_index keeps this behind the
# Tiles layer and every player regardless of node order in the scene tree.

@export var theme_color: Color = Color(0.5, 0.5, 0.55)
@export var theme_shape: String = "rect" # "triangle" | "circle" | "rect"
@export var bounds: Rect2 = Rect2(-1100, -100, 2200, 700)

func _ready() -> void:
	z_index = -10
	z_as_relative = false

func _draw() -> void:
	var sky_top := theme_color.darkened(0.55)
	var sky_bottom := theme_color.darkened(0.15)
	# A flat-shaded vertical gradient built from real bands (no
	# draw_rect_gradient equivalent that respects the "no smooth
	# anti-aliased blend" house style) -- coarse enough to read as
	# atmosphere, not a smooth photographic sky.
	const BANDS := 10
	var band_h := bounds.size.y / BANDS
	for i in BANDS:
		var t := float(i) / float(BANDS - 1)
		var c := sky_top.lerp(sky_bottom, t)
		draw_rect(Rect2(bounds.position.x, bounds.position.y + i * band_h, bounds.size.x, band_h + 1.0), c)

	var accent := theme_color.lightened(0.2)
	accent.a = 0.5
	match theme_shape:
		"triangle":
			_draw_triangles(accent)
		"circle":
			_draw_circles(accent)
		_:
			_draw_rects(accent)

func _draw_triangles(c: Color) -> void:
	var n := 4
	for i in n:
		var base_x := bounds.position.x + bounds.size.x * (i + 0.5) / n
		var w := bounds.size.x / n * 0.7
		var h := 90.0 + 40.0 * (i % 2)
		var base_y := bounds.position.y + bounds.size.y * 0.62
		draw_colored_polygon(PackedVector2Array([
			Vector2(base_x, base_y - h),
			Vector2(base_x - w * 0.5, base_y),
			Vector2(base_x + w * 0.5, base_y),
		]), c)

func _draw_circles(c: Color) -> void:
	var n := 5
	for i in n:
		var cx := bounds.position.x + bounds.size.x * (i + 0.5) / n
		var cy := bounds.position.y + bounds.size.y * (0.25 if i % 2 == 0 else 0.45)
		var r := 36.0 if i % 2 == 0 else 24.0
		draw_circle(Vector2(cx, cy), r, c)

func _draw_rects(c: Color) -> void:
	var n := 5
	for i in n:
		var w := 60.0 + 30.0 * (i % 3)
		var h := 50.0 + 60.0 * ((i + 1) % 3)
		var cx := bounds.position.x + bounds.size.x * (i + 0.5) / n
		var base_y := bounds.position.y + bounds.size.y * 0.62
		draw_rect(Rect2(cx - w * 0.5, base_y - h, w, h), c)
