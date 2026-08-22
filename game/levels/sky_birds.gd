extends Node2D
class_name SkyBirds

# Small black-silhouette birds continuously crossing the fixed-camera sky,
# each independently flapping and drifting at its own speed/height/phase.
# Purely decorative -- see game.gd/net_game.gd for where this gets attached
# (only when the level has a real uploaded background image, gated on
# MapBackground.background_texture != null, so it doesn't clutter every
# built-in map's flat backdrop -- currently just the "Stage" custom level).
#
# Each bird is drawn as 5 points forming a wide "M": two low wingtips, two
# raised peaks, and a low body-center between them. Animating the peak
# height with abs(sin(...)) continuously morphs it from a flat line (wings
# level) to a full "M" (wings raised) and back -- a smooth version of the
# classic multi-frame flapping-bird sprite, without needing sprite frames.

@export var bounds: Rect2 = Rect2(-1100, -100, 2200, 700)

const BIRD_COUNT := 8
const SKY_BAND_TOP := 0.06 # fraction of bounds.size.y -- birds stay in the upper sky
const SKY_BAND_BOTTOM := 0.42
const WRAP_MARGIN := 60.0 # how far off-screen a bird flies before recycling to the far edge
const BOB_AMPLITUDE := 8.0
const BIRD_COLOR := Color(0.05, 0.05, 0.07, 0.85)
const LINE_WIDTH := 2.2

var _birds: Array[Dictionary] = []
var _time := 0.0

func _ready() -> void:
	z_index = -5 # behind Tiles/Placements/players (z_index 0/1), in front of Background (-10)
	z_as_relative = false
	for i in BIRD_COUNT:
		_birds.append(_make_bird(true))

func _make_bird(initial: bool) -> Dictionary:
	var direction := 1.0 if randf() < 0.5 else -1.0
	var base_y := bounds.position.y + bounds.size.y * randf_range(SKY_BAND_TOP, SKY_BAND_BOTTOM)
	# A freshly-spawned flock starts already spread across the whole sky
	# (not bunched at one edge); recycled birds re-enter from whichever
	# edge is behind their direction of travel.
	var x: float
	if initial:
		x = bounds.position.x + randf() * bounds.size.x
	elif direction > 0.0:
		x = bounds.position.x - WRAP_MARGIN
	else:
		x = bounds.position.x + bounds.size.x + WRAP_MARGIN
	return {
		pos = Vector2(x, base_y),
		base_y = base_y,
		direction = direction,
		speed = randf_range(40.0, 90.0),
		wing_span = randf_range(16.0, 26.0),
		flap_speed = randf_range(6.0, 10.0),
		flap_phase = randf() * TAU,
		bob_speed = randf_range(0.8, 1.6),
		bob_phase = randf() * TAU,
	}

func _process(delta: float) -> void:
	_time += delta
	for b in _birds:
		b.pos.x += b.speed * b.direction * delta
		b.pos.y = b.base_y + sin(_time * b.bob_speed + b.bob_phase) * BOB_AMPLITUDE
		var off_right: bool = b.direction > 0.0 and b.pos.x > bounds.position.x + bounds.size.x + WRAP_MARGIN
		var off_left: bool = b.direction < 0.0 and b.pos.x < bounds.position.x - WRAP_MARGIN
		if off_right or off_left:
			_recycle(b)
	queue_redraw()

# Re-rolls everything about a bird except the direction it was already
# flying, so it re-enters from the correct edge without ever visibly
# reversing mid-flight.
func _recycle(b: Dictionary) -> void:
	var direction: float = b.direction
	var fresh := _make_bird(false)
	fresh.direction = direction
	fresh.pos.x = bounds.position.x - WRAP_MARGIN if direction > 0.0 else bounds.position.x + bounds.size.x + WRAP_MARGIN
	for key in fresh:
		b[key] = fresh[key]

func _draw() -> void:
	for b in _birds:
		var h: float = b.wing_span * 0.5 * absf(sin(_time * b.flap_speed + b.flap_phase))
		var w: float = b.wing_span * 0.5
		var p: Vector2 = b.pos
		var pts := PackedVector2Array([
			p + Vector2(-w, 0.0),
			p + Vector2(-w * 0.5, -h),
			p,
			p + Vector2(w * 0.5, -h),
			p + Vector2(w, 0.0),
		])
		draw_polyline(pts, BIRD_COLOR, LINE_WIDTH, true)
