extends Control
class_name ModeIcon

# Small procedural vector icons for the main menu's mode bars -- no image
# assets in the project for this, so each icon is drawn directly with
# CanvasItem primitives, sized to whatever this control's rect is.
@export var icon_type: String = "bolt"
@export var icon_color: Color = Color.WHITE
@export var line_width: float = 3.0

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE

func _draw() -> void:
	var s: Vector2 = size
	var c: Vector2 = s * 0.5
	match icon_type:
		"bolt":
			var pts := PackedVector2Array([
				Vector2(0.58, 0.0), Vector2(0.18, 0.56), Vector2(0.46, 0.56),
				Vector2(0.38, 1.0), Vector2(0.86, 0.4), Vector2(0.56, 0.4),
			])
			for i in pts.size():
				pts[i] = pts[i] * s
			draw_colored_polygon(pts, icon_color)
		"star":
			var pts := PackedVector2Array()
			var outer := s.x * 0.5
			var inner := outer * 0.42
			for i in 10:
				var ang := -PI / 2.0 + i * PI / 5.0
				var r := outer if i % 2 == 0 else inner
				pts.append(c + Vector2(cos(ang), sin(ang)) * r)
			draw_colored_polygon(pts, icon_color)
		"controller":
			var body := Rect2(s.x * 0.08, s.y * 0.32, s.x * 0.84, s.y * 0.4)
			draw_rect(body, icon_color, true, -1.0)
			draw_circle(Vector2(s.x * 0.08, s.y * 0.52), s.x * 0.14, icon_color)
			draw_circle(Vector2(s.x * 0.92, s.y * 0.52), s.x * 0.14, icon_color)
			var dpad_c := Vector2(s.x * 0.27, s.y * 0.52)
			draw_line(dpad_c + Vector2(-0.07, 0) * s.x, dpad_c + Vector2(0.07, 0) * s.x, icon_color.darkened(0.5), line_width)
			draw_line(dpad_c + Vector2(0, -0.07) * s.y, dpad_c + Vector2(0, 0.07) * s.y, icon_color.darkened(0.5), line_width)
			draw_circle(Vector2(s.x * 0.73, s.y * 0.44), s.x * 0.05, icon_color.darkened(0.5))
			draw_circle(Vector2(s.x * 0.8, s.y * 0.58), s.x * 0.05, icon_color.darkened(0.5))
		"globe":
			var r := s.x * 0.42
			draw_arc(c, r, 0.0, TAU, 40, icon_color, line_width)
			draw_arc(c, r * 0.55, 0.0, TAU, 32, icon_color, line_width * 0.8)
			draw_line(Vector2(c.x, c.y - r), Vector2(c.x, c.y + r), icon_color, line_width * 0.8)
			draw_line(Vector2(c.x - r, c.y), Vector2(c.x + r, c.y), icon_color, line_width * 0.8)
		"tag":
			var pts := PackedVector2Array([
				Vector2(0.06, 0.42), Vector2(0.5, 0.02), Vector2(0.94, 0.42),
				Vector2(0.7, 1.0), Vector2(0.3, 1.0),
			])
			for i in pts.size():
				pts[i] = pts[i] * s
			draw_colored_polygon(pts, icon_color)
			draw_circle(Vector2(0.5, 0.34) * s, s.x * 0.07, icon_color.darkened(0.6))
		_:
			draw_circle(c, s.x * 0.4, icon_color)
