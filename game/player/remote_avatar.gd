extends Node2D
class_name RemoteAvatar

# A non-simulated puppet for a player in a networked match -- no physics, no
# movement code, just interpolates toward whatever position the server last
# reported. Used uniformly for every player, the local one included: no
# client-side prediction happens anywhere anymore, so every avatar is purely
# a rendering of confirmed server state. That trades instant local
# responsiveness for input lag equal to round-trip time, in exchange for the
# render never needing a correction/snap.

@onready var visual: Sprite2D = $Visual
@onready var name_label: Label = $NameLabel
@onready var camera: Camera2D = $Camera2D

const LERP_WEIGHT := 0.35
# Dead-reckoning cap -- how far past the last known update we'll still trust
# its velocity to extrapolate forward. Past this, a stale/no-longer-accurate
# velocity (e.g. the real player just hit a wall) could badly overshoot, so
# beyond it we fall back to just trusting the last known position instead of
# extending the guess further.
const MAX_EXTRAPOLATION_SEC := 0.15

## Set before _ready() (net_game.gd sets this right after instantiating) --
## enables this instance's camera.
var is_local := false

var display_name: String = "":
	set(value):
		display_name = value
		if name_label:
			name_label.text = value

var target_position: Vector2 = Vector2.ZERO
var target_velocity: Vector2 = Vector2.ZERO
var target_facing: int = 1
var _time_since_update := 0.0

func _ready() -> void:
	if name_label:
		name_label.text = display_name
	if visual:
		# Sensible default until set_skin() overrides it with this peer's
		# actual choice -- covers the brief window before it's known.
		visual.texture = SkinCatalog.get_texture("red")
	if is_local and camera:
		camera.enabled = true
		camera.make_current()

func _physics_process(delta: float) -> void:
	_time_since_update += delta
	# Lerping toward the last known position alone always trails a
	# fast-moving remote player by roughly velocity * update-interval --
	# worse the faster they move, since a new position only arrives once per
	# network tick and pure lerp never catches up between them. Dead-reckon
	# from the last known velocity instead, capped so a stale velocity can't
	# overshoot far past where the real player actually is.
	var extrapolated := target_position + target_velocity * minf(_time_since_update, MAX_EXTRAPOLATION_SEC)
	global_position = global_position.lerp(extrapolated, LERP_WEIGHT)

## Sets which skin's texture this avatar displays -- called once by
## net_game.gd when this peer's skin choice becomes known, not on every
## state update below (skin choice doesn't change every tick).
func set_skin(texture: Texture2D) -> void:
	if visual and texture:
		visual.texture = texture

func set_state(pos: Vector2, vel: Vector2, facing: int, is_dashing: bool, is_it: bool) -> void:
	target_position = pos
	target_velocity = vel
	target_facing = facing
	_time_since_update = 0.0
	if visual:
		# Tints via modulate rather than swapping the texture, so this works
		# the same for every skin, built-in or custom.
		visual.modulate = Player.TAG_IT_COLOR if is_it else Color.WHITE
		visual.scale = Vector2(1.5, 0.6) if is_dashing else Vector2.ONE
		var flip := absf(visual.scale.x) * (1.0 if facing >= 0 else -1.0)
		visual.scale.x = flip
