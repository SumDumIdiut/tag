extends Control
class_name RankBadge

# A small pixel-art shield badge for a ranked tier -- hard-edged shapes (no
# anti-aliasing/gradients), same genuine-pixel-art rule the rest of the
# game's icons follow. Used on match_intro.gd's ranked VS screen next to
# each player's elo.
#
# Tries a baked PNG first (see tools/build_procedural_sprites.gd, one per
# tier under res://assets/icons/rank_badges/) and only falls back to the
# original procedural _draw() below if that specific tier's file is
# missing -- same "never hard-fail on missing custom content" rule
# mode_icon.gd's atlas check already follows.

@export var tier: String = "":
	set(value):
		tier = value
		_try_setup_baked()
		queue_redraw()

const UIStyle := preload("res://ui/ui_style.gd")
const BAKED_DIR := "res://assets/icons/rank_badges"

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
	var key: String = tier.to_lower() if not tier.is_empty() else "default"
	var path := "%s/%s.png" % [BAKED_DIR, key]
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
	var s: Vector2 = size
	var color: Color = UIStyle.tier_color(tier)
	var dark := color.darkened(0.45)
	var light := color.lightened(0.35)

	# Shield outline: a pentagon-ish silhouette (flat top, pointed bottom),
	# built as pixel-snapped rows rather than a smooth polygon so it upscales
	# blocky like every other icon in the game.
	var w := s.x
	var h := s.y
	var rows := int(h)
	for y in rows:
		var t := float(y) / float(rows - 1)
		var inset: float
		if t < 0.75:
			inset = 0.0
		else:
			# Taper to a point over the bottom quarter.
			inset = (t - 0.75) / 0.25 * (w * 0.5 - 1.0)
		var x0 := inset
		var x1 := w - inset
		if x1 <= x0:
			continue
		draw_rect(Rect2(x0, y, x1 - x0, 1.0), dark if t > 0.82 else color)

	# A lighter inner highlight band near the top, and a small centered
	# gem/star so this reads as a badge, not just a colored triangle.
	draw_rect(Rect2(w * 0.12, h * 0.08, w * 0.76, h * 0.18), light)
	var c := Vector2(w * 0.5, h * 0.48)
	var r := w * 0.16
	var pts := PackedVector2Array()
	for i in 4:
		var ang := i * PI / 2.0
		pts.append(c + Vector2(cos(ang), sin(ang)) * r)
	draw_colored_polygon(pts, dark)
