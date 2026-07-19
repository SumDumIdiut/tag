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
@onready var _hat: Sprite2D = $Visual/Body/Hat
@onready var _parts: Dictionary = {
	"body": $Visual/Body,
}
var _rig := LimbPhysicsRig.new()
var _trail_emitter: TrailEmitter

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
# The limb rig integrates every physics frame (see _physics_process below),
# not just when a new set_state() arrives -- state updates only land once
# per network tick, but the spring simulation needs to keep advancing every
# frame in between for the motion to actually look continuous rather than
# stepping. These hold the last state a real update reported, for
# _physics_process to keep feeding the rig from in the meantime.
var _last_on_floor := true
var _last_is_dashing := false
var _last_is_climbing := false
var _last_action_id := 0

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
	_trail_emitter = TrailEmitter.new()
	add_child(_trail_emitter)

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

	_rig.update(delta, target_velocity, _last_on_floor, _last_is_dashing, _last_is_climbing, Player.MOVE_SPEED)
	_rig.apply_to(_parts["body"], visual)
	_trail_emitter.update(delta, target_velocity.length())

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

## Sets the equipped trail, by id -- "" clears it. Unlike set_skin/set_hat
## there's no "not ready yet" retry needed here: TrailEmitter re-resolves its
## own texture from SkinCatalog.trail_received directly.
func set_trail(trail_id: String) -> void:
	if _trail_emitter:
		_trail_emitter.trail_id = trail_id

## Directly overrides one part's texture, bypassing SkinCatalog entirely --
## used by the Art Tool (tools/art_tool.gd) to preview an in-progress edit
## that hasn't been baked/uploaded anywhere yet. No-ops for an unknown part.
func set_part_texture_override(part_name: String, tex: Texture2D) -> void:
	if _parts.has(part_name):
		_parts[part_name].texture = tex

## Same idea as set_part_texture_override, for the hat slot.
func set_hat_texture_override(tex: Texture2D) -> void:
	if _hat:
		_hat.texture = tex

func set_state(pos: Vector2, vel: Vector2, facing: int, is_dashing: bool, is_climbing: bool, on_floor: bool, action: String, action_id: int, is_it: bool) -> void:
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
	# this a still-"it" peer would restart the flinch kick on every single
	# update instead of applying it once when tag actually happens.
	if is_it and not _was_it:
		_rig.kick("tag_reaction")
		SFX.play("tag")
	_was_it = is_it
	# A fresh wall-jump/dash-jump id is likewise a one-shot kick, not a
	# continuous state -- see player.gd's current_action_id comment for why
	# this compares ids instead of "did the action string change."
	if action_id != _last_action_id:
		_last_action_id = action_id
		_rig.kick(action)
	_last_on_floor = on_floor
	_last_is_dashing = is_dashing
	_last_is_climbing = is_climbing
