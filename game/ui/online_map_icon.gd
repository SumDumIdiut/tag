extends Control
class_name OnlineMapIcon

# A tiny top-down silhouette of an Online map's real platform layout, drawn
# straight from OnlineMapCatalog's platform rects -- same data-driven,
# theme_color/theme_shape-driven approach and same baked-PNG-first/live-
# _draw()-fallback pattern local_map_icon.gd already established for the
# (separate, offline-only) Local map catalog. Used by map_vote_view.gd's
# vote buttons so a player can actually see what they're voting for instead
# of a bare map name.
#
# Also matches local_map_icon.gd in preferring a live-published custom
# level's own uploaded thumbnail (via CustomLevelCache) over everything else
# when one exists -- see that script's own header comment for the full
# reasoning; OnlineMapCatalog.MAPS has no entry for a custom level id either,
# so without this every custom level tile fell through to _draw()'s empty
# platform list (nothing drawn at all, not even a fallback glyph here).

const Catalog := preload("res://levels/online_maps/catalog.gd")

# Same world-space bounds local_map_icon.gd fixes its own icons to -- online
# maps' platform rects (see catalog.gd) comfortably fit within this box too,
# and sharing the constant keeps both icon families reading at the same
# relative scale.
const WORLD_MIN := Vector2(-1000, -550)
const WORLD_MAX := Vector2(1000, 550)
const BAKED_DIR := "res://assets/icons/online_map_icons"
const BAKED_COLOR := Color(0.98, 0.75, 0.2) # UIStyle.COLOR_QUICKPLAY -- the only color ever actually baked
const FALLBACK_COLOR := Color(0.6, 0.6, 0.65) # matches local_map_icon.gd's own fallback; defensive only

@export var map_id: String = "":
	set(value):
		map_id = value
		_try_setup_baked()
		queue_redraw()
@export var accent_color: Color = Color(0.98, 0.75, 0.2):
	set(value):
		accent_color = value
		_try_setup_baked()
		queue_redraw()

var _baked_rect: TextureRect = null

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_try_setup_baked()
	resized.connect(_sync_baked_rect_size)
	_sync_baked_rect_size()

func _sync_baked_rect_size() -> void:
	if _baked_rect:
		_baked_rect.position = Vector2.ZERO
		_baked_rect.size = size

func _try_setup_baked() -> void:
	if _baked_rect:
		_baked_rect.queue_free()
		_baked_rect = null
	if map_id.begins_with("level_"):
		var custom_tex := CustomLevelCache.get_level_thumbnail(map_id)
		if custom_tex:
			_set_baked_texture(custom_tex)
			return
	if not accent_color.is_equal_approx(BAKED_COLOR):
		return
	var path := "%s/%s.png" % [BAKED_DIR, map_id]
	if not ResourceLoader.exists(path):
		return
	var tex: Texture2D = load(path)
	if not tex:
		return
	_set_baked_texture(tex)

func _set_baked_texture(tex: Texture2D) -> void:
	_baked_rect = TextureRect.new()
	_baked_rect.texture = tex
	_baked_rect.stretch_mode = TextureRect.STRETCH_SCALE
	_baked_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_baked_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_baked_rect)
	_sync_baked_rect_size()

func _draw() -> void:
	if _baked_rect:
		return
	var def: Dictionary = Catalog.MAPS.get(map_id, {})
	var theme_color: Color = def.get("theme_color", FALLBACK_COLOR)
	var theme_shape: String = def.get("theme_shape", "rect")
	_draw_theme_background(theme_color, theme_shape)

	var platforms: Array = def.get("platforms", [])
	var fg := theme_color.lightened(0.35)
	var world_size := WORLD_MAX - WORLD_MIN
	for plat in platforms:
		var x0: float = plat.x0
		var y0: float = plat.y0
		var x1: float = plat.x1
		var y1: float = plat.y1
		var top_left := Vector2(
			(x0 - WORLD_MIN.x) / world_size.x * size.x,
			(y0 - WORLD_MIN.y) / world_size.y * size.y
		)
		var bottom_right := Vector2(
			(x1 - WORLD_MIN.x) / world_size.x * size.x,
			(y1 - WORLD_MIN.y) / world_size.y * size.y
		)
		bottom_right.y = maxf(bottom_right.y, top_left.y + 2.0)
		draw_rect(Rect2(top_left, bottom_right - top_left), fg)

## Miniature of map_background.gd's own banded-gradient-plus-silhouette
## backdrop -- see local_map_icon.gd's identical helper for why bands are
## flat-shaded rather than a smooth gradient.
func _draw_theme_background(theme_color: Color, theme_shape: String) -> void:
	var sky_top := theme_color.darkened(0.55)
	var sky_bottom := theme_color.darkened(0.15)
	var bands := 4
	var band_h := size.y / bands
	for i in bands:
		var t := float(i) / float(bands - 1)
		var c := sky_top.lerp(sky_bottom, t)
		draw_rect(Rect2(0, i * band_h, size.x, band_h + 1.0), c)

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
	var n := 2
	for i in n:
		var base_x := size.x * (i + 0.5) / n
		var w := size.x / n * 0.7
		var h := size.y * 0.35
		var base_y := size.y * 0.85
		draw_colored_polygon(PackedVector2Array([
			Vector2(base_x, base_y - h),
			Vector2(base_x - w * 0.5, base_y),
			Vector2(base_x + w * 0.5, base_y),
		]), c)

func _draw_circles(c: Color) -> void:
	var n := 3
	for i in n:
		var cx := size.x * (i + 0.5) / n
		var cy := size.y * (0.25 if i % 2 == 0 else 0.4)
		var r := size.y * 0.16
		draw_circle(Vector2(cx, cy), r, c)

func _draw_rects(c: Color) -> void:
	var n := 3
	for i in n:
		var w := size.x * 0.12
		var h := size.y * (0.25 + 0.12 * ((i + 1) % 3))
		var cx := size.x * (i + 0.5) / n
		var base_y := size.y * 0.85
		draw_rect(Rect2(cx - w * 0.5, base_y - h, w, h), c)
