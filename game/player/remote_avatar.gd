extends Node2D
class_name RemoteAvatar

# A non-simulated puppet for a player in a networked match -- no physics, no
# movement code, just interpolates toward whatever position the server last
# reported. Used uniformly for every player, the local one included: no
# client-side prediction happens anywhere anymore, so every avatar is purely
# a rendering of confirmed server state. That trades instant local
# responsiveness for input lag equal to round-trip time, in exchange for the
# render never needing a correction/snap.

@onready var visual: Node2D = $Visual
@onready var name_label: Label = $NameLabel
@onready var camera: Camera2D = $Camera2D
@onready var _anim_player: AnimationPlayer = $Visual/AnimationPlayer
@onready var _hat: Sprite2D = $Visual/Torso/Head/Hat
@onready var _parts: Dictionary = {
	"head": $Visual/Torso/Head,
	"torso": $Visual/Torso,
	"left_arm": $Visual/Torso/LeftArm,
	"right_arm": $Visual/Torso/RightArm,
	"left_leg": $Visual/Torso/LeftLeg,
	"right_leg": $Visual/Torso/RightLeg,
}

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
var _was_it := false

func _ready() -> void:
	if name_label:
		name_label.text = display_name
	if visual:
		# Sensible default until set_skin() overrides it with this peer's
		# actual choice -- covers the brief window before it's known.
		set_skin("red")
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

## Sets which skin this avatar displays, by id -- called once by net_game.gd
## when this peer's skin choice becomes known, not on every state update
## below (skin choice doesn't change every tick). No-ops if that skin's
## per-part textures aren't ready yet (an unfetched custom skin) -- the
## caller's own skin_received retry re-calls this once they land.
func set_skin(skin_id: String) -> void:
	var parts := SkinCatalog.get_part_textures(skin_id)
	if parts.is_empty():
		return
	for part_name in parts:
		if _parts.has(part_name):
			_parts[part_name].texture = parts[part_name]

## Sets the equipped hat, by id -- "" clears it. No-ops (keeps showing
## nothing, not stale art) if a non-empty id's texture isn't ready yet; the
## caller's own hat_received retry re-calls this once it lands.
func set_hat(hat_id: String) -> void:
	if not _hat:
		return
	if hat_id.is_empty():
		_hat.texture = null
		return
	var tex := SkinCatalog.get_hat_texture(hat_id)
	if tex:
		_hat.texture = tex

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
	# Rising edge only -- state updates arrive every network tick, so without
	# this a still-"it" peer would restart the flinch clip on every single
	# update instead of playing it once when tag actually happens.
	if is_it and not _was_it:
		_play_anim("tag_reaction")
	_was_it = is_it
	_update_locomotion_anim(vel)

## Same idle/walk selection as Player._update_locomotion_anim, but driven by
## the last reported network velocity instead of local physics -- a
## RemoteAvatar never simulates movement itself.
func _update_locomotion_anim(vel: Vector2) -> void:
	if not _anim_player or _anim_player.current_animation == "tag_reaction" and _anim_player.is_playing():
		return
	if absf(vel.x) > 5.0:
		_anim_player.speed_scale = clampf(absf(vel.x) / Player.MOVE_SPEED, 0.4, 2.0)
		_play_anim("walk")
	else:
		_anim_player.speed_scale = 1.0
		_play_anim("idle")

func _play_anim(name: String) -> void:
	if not _anim_player or _anim_player.current_animation == name:
		return
	_anim_player.play(name)
