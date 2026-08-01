extends Control
class_name OnlineMapIcon

# A tiny top-down silhouette of an Online map's real platform layout, drawn
# straight from OnlineMapCatalog's platform rects -- same data-driven
# approach and same baked-PNG-first/live-_draw()-fallback pattern
# local_map_icon.gd already established for the (separate, offline-only)
# Local map catalog. Used by map_vote_view.gd's vote buttons so a player can
# actually see what they're voting for instead of a bare map name.

const Catalog := preload("res://levels/online_maps/catalog.gd")

# Same world-space bounds local_map_icon.gd fixes its own icons to -- online
# maps' platform rects (see catalog.gd) comfortably fit within this box too,
# and sharing the constant keeps both icon families reading at the same
# relative scale.
const WORLD_MIN := Vector2(-1000, -550)
const WORLD_MAX := Vector2(1000, 550)
const BAKED_DIR := "res://assets/icons/online_map_icons"
const BAKED_COLOR := Color(0.98, 0.75, 0.2) # UIStyle.COLOR_QUICKPLAY -- the only color ever actually baked

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
		draw_rect(Rect2(top_left, bottom_right - top_left), accent_color)
