extends Control
class_name AchievementBadge

# A small circular medallion for one achievement -- hard-edged pixel-art
# shapes (no anti-aliasing/gradients), same rule rank_badge.gd's shield
# follows. Color comes from the achievement's own category (see
# achievement_catalog.gd) -- a "tier" achievement reuses its real rank
# tier's own color (RankTiers.TIERS), tying the badge to the actual rank
# ladder instead of an arbitrary palette. A locked achievement renders as a
# dim gray silhouette instead of its real color, so the menu reads as "here's
# everything, here's what you have" rather than only ever listing unlocks.
#
# Tries a baked PNG first (see tools/build_procedural_sprites.gd, one per
# achievement id under res://assets/icons/achievement_badges/) and only
# falls back to the procedural _draw() below if that file is missing, same
# pattern rank_badge.gd/local_map_icon.gd already established. Locked state
# is never baked (it's just the unlocked art desaturated at draw time), so
# it always falls through to the procedural path.

const RankTiers := preload("res://cosmetics/rank_tiers.gd")
const BAKED_DIR := "res://assets/icons/achievement_badges"

const CATEGORY_COLORS := {
	"win": Color(1.0, 0.84, 0.0),
	"endurance": Color(0.4, 0.7, 1.0),
	"misc": Color(0.7, 0.4, 0.9),
}
const LOCKED_COLOR := Color(0.35, 0.36, 0.4)

@export var achievement_id: String = "":
	set(value):
		achievement_id = value
		_try_setup_baked()
		queue_redraw()
@export var category: String = "misc":
	set(value):
		category = value
		queue_redraw()
@export var tier: String = "":
	set(value):
		tier = value
		queue_redraw()
@export var unlocked: bool = true:
	set(value):
		unlocked = value
		_try_setup_baked()
		queue_redraw()

var _baked_rect: TextureRect = null

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_try_setup_baked()
	resized.connect(_sync_baked_rect_size)
	resized.connect(queue_redraw)
	_sync_baked_rect_size()

func _sync_baked_rect_size() -> void:
	if _baked_rect:
		_baked_rect.position = Vector2.ZERO
		_baked_rect.size = size

func _color() -> Color:
	if not unlocked:
		return LOCKED_COLOR
	if category == "tier":
		for t in RankTiers.TIERS:
			if t.name == tier:
				return t.color
		return LOCKED_COLOR
	return CATEGORY_COLORS.get(category, LOCKED_COLOR)

func _try_setup_baked() -> void:
	if _baked_rect:
		_baked_rect.queue_free()
		_baked_rect = null
	if not unlocked or achievement_id.is_empty():
		return
	var path := "%s/%s.png" % [BAKED_DIR, achievement_id]
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
	var c := size * 0.5
	var r := minf(size.x, size.y) * 0.5
	var color := _color()
	var dark := color.darkened(0.5)
	var light := color.lightened(0.3)

	draw_circle(c, r, dark)
	draw_circle(c, r * 0.86, color)

	match category:
		"win":
			# A simple upward-pointing star -- "you earned this."
			var pts := PackedVector2Array()
			for i in 10:
				var ang := -PI / 2.0 + i * PI / 5.0
				var rad := r * (0.5 if i % 2 == 1 else 0.95)
				pts.append(c + Vector2(cos(ang), sin(ang)) * rad)
			draw_colored_polygon(pts, light)
		"endurance":
			# A clock face -- time/repetition-based achievements.
			draw_circle(c, r * 0.5, light)
			draw_line(c, c + Vector2(0, -r * 0.4), dark, 3.0)
			draw_line(c, c + Vector2(r * 0.28, r * 0.1), dark, 3.0)
		"tier":
			# A small diamond -- rank-ladder achievements, color already
			# carries the real tier identity.
			var pts := PackedVector2Array([
				c + Vector2(0, -r * 0.6), c + Vector2(r * 0.6, 0),
				c + Vector2(0, r * 0.6), c + Vector2(-r * 0.6, 0),
			])
			draw_colored_polygon(pts, light)
		_:
			draw_circle(c, r * 0.4, light)

	if not unlocked:
		# A small padlock glyph over the dimmed medallion.
		var lock_w := r * 0.5
		var lock_h := r * 0.36
		var lock_top := c + Vector2(-lock_w * 0.5, -lock_h * 0.15)
		draw_rect(Rect2(lock_top, Vector2(lock_w, lock_h)), Color(0.12, 0.12, 0.14, 0.9))
		draw_arc(c + Vector2(0, -lock_h * 0.15), lock_w * 0.32, PI, TAU, 16, Color(0.12, 0.12, 0.14, 0.9), 2.5)
