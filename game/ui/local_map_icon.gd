extends Control
class_name LocalMapIcon

# A tiny top-down silhouette of a Local map's real platform layout, drawn
# straight from LocalMapCatalog's platform rects -- not a hand-painted
# sprite, but genuine data-driven pixel art (hard-edged rects, no
# gradients/anti-aliasing) that can never drift out of sync with what the
# generated .tscn actually looks like, the same guarantee the catalog
# refactor gives generate_local_maps.gd itself.
#
# Tries a baked PNG first (see tools/build_procedural_sprites.gd, one per
# map under res://assets/icons/local_map_icons/) and only falls back to the
# original procedural _draw() below if that map's file is missing -- same
# "never hard-fail on missing custom content" rule mode_icon.gd's atlas
# check already follows. Every real call site (local_menu.gd's inline map
# row) always uses UIStyle.COLOR_LOCAL, which is what got baked -- a caller
# passing a different accent_color still falls through to the live _draw()
# path below and renders correctly, just not from the baked file.

const Catalog := preload("res://levels/local_maps/catalog.gd")

# World-space bounds every generated map's platforms fall within (see
# catalog.gd) -- fixed rather than computed per-map so every icon shares
# the same scale and reads as "this map's platforms relative to the whole
# arena," not each rescaled to fill the icon on its own.
const WORLD_MIN := Vector2(-1080, -60)
const WORLD_MAX := Vector2(1080, 520)
const BAKED_DIR := "res://assets/icons/local_map_icons"
const BAKED_COLOR := Color(0.35, 0.78, 0.98) # UIStyle.COLOR_LOCAL -- the only color ever actually baked

@export var map_id: String = "":
	set(value):
		map_id = value
		_try_setup_baked()
		queue_redraw()
@export var accent_color: Color = Color(0.35, 0.78, 0.98):
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
	if not accent_color.is_equal_approx(BAKED_COLOR):
		return
	var path := "%s/%s.png" % [BAKED_DIR, map_id]
	if not ResourceLoader.exists(path):
		return
	var tex: Texture2D = load(path)
	if not tex:
		return
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
	var bg := Color(0, 0, 0, 0.25)
	draw_rect(Rect2(Vector2.ZERO, size), bg)

	var def: Dictionary = Catalog.MAPS.get(map_id, {})
	var platforms: Array = def.get("platforms", [])
	if platforms.is_empty():
		# Any map missing preview data (none currently do -- defensive
		# fallback) -- a simple crossed-pillars glyph stands in rather than
		# an empty box.
		var c := size * 0.5
		draw_rect(Rect2(c.x - size.x * 0.4, c.y + size.y * 0.15, size.x * 0.8, size.y * 0.12), accent_color)
		draw_rect(Rect2(c.x - size.x * 0.32, c.y - size.y * 0.3, size.x * 0.1, size.y * 0.5), accent_color)
		draw_rect(Rect2(c.x + size.x * 0.22, c.y - size.y * 0.3, size.x * 0.1, size.y * 0.5), accent_color)
		return

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
		# Every platform draws at least 2px thick -- thin ledges (~10-20 world
		# px tall) would otherwise round down to nothing at icon scale.
		bottom_right.y = maxf(bottom_right.y, top_left.y + 2.0)
		draw_rect(Rect2(top_left, bottom_right - top_left), accent_color)
