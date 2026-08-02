extends Control
class_name AchievementIcon

# Small pixel-art icon for a non-tier achievement (first_win, ten_wins,
# fifty_wins, untouchable, veteran, century, marathon, last_place) -- the
# 10 "reach this rank" achievements reuse RankBadge directly instead (see
# achievements_menu.gd's _build_node), since that art already means exactly
# the same thing there. Same "baked PNG first, live _draw() fallback"
# pattern every other icon in the game follows, and the same hard-edged,
# no-gradient/anti-aliasing house style.

const UIStyle := preload("res://ui/ui_style.gd")
const BAKED_DIR := "res://assets/icons/achievement_icons"
const COLOR := UIStyle.COLOR_ACCENT

@export var achievement_id: String = "":
	set(value):
		achievement_id = value
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
	match achievement_id:
		"first_win":
			_draw_flag()
		"ten_wins":
			_draw_trophy(false)
		"fifty_wins":
			_draw_trophy(true)
		"untouchable":
			_draw_shield()
		"veteran":
			_draw_chevrons()
		"century":
			_draw_wreath()
		"marathon":
			_draw_track()
		"last_place":
			_draw_turtle()
		_:
			_draw_fallback()

func _draw_fallback() -> void:
	var c := size * 0.5
	draw_rect(Rect2(c - size * 0.3, size * 0.6), COLOR)

## A flag planted on a pole -- "first win," a first claim staked.
func _draw_flag() -> void:
	var w := size.x
	var h := size.y
	var pole_x := w * 0.28
	draw_rect(Rect2(pole_x, h * 0.12, w * 0.06, h * 0.76), COLOR.darkened(0.2))
	draw_colored_polygon(PackedVector2Array([
		Vector2(pole_x + w * 0.06, h * 0.14),
		Vector2(pole_x + w * 0.06, h * 0.42),
		Vector2(w * 0.82, h * 0.28),
	]), COLOR)
	draw_rect(Rect2(pole_x - w * 0.1, h * 0.86, w * 0.32, h * 0.06), COLOR.darkened(0.2))

## Trophy cup -- ten_wins gets the plain version, fifty_wins (`grand`) adds
## side handles and a small star, reading as the bigger accomplishment.
func _draw_trophy(grand: bool) -> void:
	var w := size.x
	var h := size.y
	var cup_top := h * 0.16
	var cup_bottom := h * 0.5
	draw_colored_polygon(PackedVector2Array([
		Vector2(w * 0.28, cup_top), Vector2(w * 0.72, cup_top),
		Vector2(w * 0.62, cup_bottom), Vector2(w * 0.38, cup_bottom),
	]), COLOR)
	draw_rect(Rect2(w * 0.46, cup_bottom, w * 0.08, h * 0.2), COLOR.darkened(0.15))
	draw_rect(Rect2(w * 0.3, h * 0.82, w * 0.4, h * 0.08), COLOR.darkened(0.15))
	if grand:
		draw_arc(Vector2(w * 0.24, cup_top + h * 0.1), w * 0.1, -PI * 0.6, PI * 0.6, 8, COLOR, w * 0.05)
		draw_arc(Vector2(w * 0.76, cup_top + h * 0.1), w * 0.1, PI * 0.4, PI * 1.6, 8, COLOR, w * 0.05)
		var c := Vector2(w * 0.5, cup_top - h * 0.02)
		var r := w * 0.09
		var pts := PackedVector2Array()
		for i in 4:
			var ang := i * PI / 2.0
			pts.append(c + Vector2(cos(ang), sin(ang)) * r)
		draw_colored_polygon(pts, COLOR.lightened(0.3))

## Plain shield -- "untouchable," never actually hit.
func _draw_shield() -> void:
	var w := size.x
	var h := size.y
	var rows := int(h)
	for y in rows:
		var t := float(y) / float(rows - 1)
		var inset: float
		if t < 0.7:
			inset = w * 0.1
		else:
			inset = w * 0.1 + (t - 0.7) / 0.3 * (w * 0.4)
		var x0 := inset
		var x1 := w - inset
		if x1 <= x0:
			continue
		draw_rect(Rect2(x0, y, x1 - x0, 1.0), COLOR.darkened(0.3) if t > 0.85 else COLOR)

## A single service chevron -- "veteran," time served.
func _draw_chevrons() -> void:
	var w := size.x
	var h := size.y
	for i in 2:
		var base_y := h * (0.32 + i * 0.28)
		draw_colored_polygon(PackedVector2Array([
			Vector2(w * 0.2, base_y + h * 0.16),
			Vector2(w * 0.5, base_y),
			Vector2(w * 0.8, base_y + h * 0.16),
			Vector2(w * 0.8, base_y + h * 0.28),
			Vector2(w * 0.5, base_y + h * 0.12),
			Vector2(w * 0.2, base_y + h * 0.28),
		]), COLOR)

## A laurel wreath -- "century," the classic round-number honor.
func _draw_wreath() -> void:
	var w := size.x
	var h := size.y
	var center := Vector2(w * 0.5, h * 0.56)
	for side in [-1, 1]:
		for i in 5:
			var t := float(i) / 4.0
			var ang: float = PI * 0.5 + side * (t * PI * 0.85)
			var radius := w * 0.4
			var pos := center + Vector2(cos(ang), sin(ang)) * radius
			var leaf_size := Vector2(w * 0.13, h * 0.08)
			draw_rect(Rect2(pos - leaf_size * 0.5, leaf_size), COLOR)

## A finish flag at the end of a dashed track -- "marathon," distance covered.
func _draw_track() -> void:
	var w := size.x
	var h := size.y
	var dash_y := h * 0.72
	for i in 4:
		draw_rect(Rect2(w * (0.08 + i * 0.16), dash_y, w * 0.1, h * 0.05), COLOR.darkened(0.1))
	var pole_x := w * 0.76
	draw_rect(Rect2(pole_x, h * 0.12, w * 0.05, h * 0.62), COLOR.darkened(0.2))
	var checks := 3
	var check_w := w * 0.16 / checks
	for r in 2:
		for c in checks:
			if (r + c) % 2 == 0:
				draw_rect(Rect2(pole_x + w * 0.05 + c * check_w, h * 0.14 + r * h * 0.1, check_w, h * 0.1), COLOR)

## A turtle -- "last place," playful, not punishing.
func _draw_turtle() -> void:
	var w := size.x
	var h := size.y
	draw_circle(Vector2(w * 0.5, h * 0.5), w * 0.34, COLOR)
	draw_arc(Vector2(w * 0.5, h * 0.5), w * 0.34, 0, TAU, 16, COLOR.darkened(0.25), w * 0.05)
	draw_circle(Vector2(w * 0.82, h * 0.42), w * 0.12, COLOR)
	var legs := [Vector2(0.24, 0.72), Vector2(0.42, 0.82), Vector2(0.58, 0.82), Vector2(0.76, 0.72)]
	for leg in legs:
		draw_rect(Rect2(w * leg.x - w * 0.05, h * leg.y, w * 0.1, h * 0.1), COLOR)
