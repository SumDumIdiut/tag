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
@onready var _body: CharacterBodyRect = $Visual/Body
@onready var _it_label: Label = $ItLabel

# How fast the rendered position catches up to the dead-reckoned target
# each tick -- not prediction (this only ever reacts to already-confirmed
# server state, never simulates ahead of it), just how tightly it tracks
# that state. Raised from 0.35: steady-motion phase lag is dt*(1-w)/w
# (~31ms at 0.35, ~17ms at 0.5); a velocity discontinuity (dash start/end,
# landing) settles in ln(0.05)/ln(1-w) ticks (~117ms at 0.35, ~66ms at
# 0.5). Started conservative rather than higher (0.6-0.7 would settle
# faster still) since the risk concentrates exactly at those
# discontinuities -- too high and the position visibly pops toward the
# new target instead of settling.
const LERP_WEIGHT := 0.5
# Dead-reckoning cap -- how far past the last known update we'll still trust
# its velocity to extrapolate forward. Past this, a stale/no-longer-accurate
# velocity (e.g. the real player just hit a wall) could badly overshoot, so
# beyond it we fall back to just trusting the last known position instead of
# extending the guess further.
const MAX_EXTRAPOLATION_SEC := 0.15

var display_name: String = "":
	set(value):
		display_name = value
		if name_label:
			name_label.text = value

var target_position: Vector2 = Vector2.ZERO
var target_velocity: Vector2 = Vector2.ZERO
var target_facing: int = 1
var _time_since_update := 0.0
# Where the feet actually are in Visual's local space -- see player.gd's
# identical field/comment. Same rig offsets here (remote_avatar.tscn mirrors
# player.tscn's Visual/Body layout exactly), same fix for the same "dash
# squash on the ground opens a gap under the sprite" bug.
var _ground_line_y := 0.0
# See player.gd's identical fields for why the assigned color is tracked
# separately from _body.color, and why the tag uses an outright override
# instead of a modulate tint.
var _own_color: Color = PlayerColors.color_for(PlayerColors.DEFAULT_ID)
var _last_is_it := false
var _it_pulse_tween: Tween

func _ready() -> void:
	if name_label:
		name_label.text = display_name
	if visual:
		# Sensible default until set_color() overrides it with this peer's
		# actual server-assigned color -- covers the brief window before it's
		# known. Also colors the name tag itself (see set_color()).
		set_color(PlayerColors.DEFAULT_ID)
	if _body:
		_ground_line_y = _body.position.y + CharacterBodyRect.TOP_LEFT.y + CharacterBodyRect.SIZE.y

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

## Sets this avatar's color, by id -- called once by net_game.gd when this
## peer's server-assigned color becomes known, not on every state update
## below (it never changes mid-match). Also colors the floating name tag to
## match -- previously tinted by rank tier instead, which read as "everyone
## ranked Unranked/same tier has the same-colored name" rather than tying
## each name to the actual colored square it floats above.
func set_color(color_id: String) -> void:
	_own_color = PlayerColors.color_for(color_id)
	if _body and not _last_is_it:
		_body.color = _own_color
	if name_label:
		name_label.add_theme_color_override("font_color", _own_color)

func _update_it_label(active: bool) -> void:
	if not _it_label:
		return
	if _it_pulse_tween:
		_it_pulse_tween.kill()
		_it_pulse_tween = null
	_it_label.visible = active
	if active:
		_it_label.modulate.a = 1.0
		_it_pulse_tween = create_tween().set_loops()
		_it_pulse_tween.tween_property(_it_label, "modulate:a", 0.35, 0.5).set_trans(Tween.TRANS_SINE)
		_it_pulse_tween.tween_property(_it_label, "modulate:a", 1.0, 0.5).set_trans(Tween.TRANS_SINE)

## `action`/`action_id` are still part of the state dict shape
## server_match.gd sends (see player.gd's current_action/current_action_id
## comment) but have no visual consumer here anymore -- the square isn't
## animated by physics, so there's no rig left to feed or kick with them.
## `on_floor` IS used, for the squash-anchoring below.
func set_state(pos: Vector2, vel: Vector2, facing: int, is_dashing: bool, _is_climbing: bool, on_floor: bool, _action: String, _action_id: int, is_it: bool) -> void:
	target_position = pos
	target_velocity = vel
	target_facing = facing
	_time_since_update = 0.0
	if _body:
		_body.color = Player.TAG_IT_COLOR if is_it else _own_color
	if is_it != _last_is_it:
		_last_is_it = is_it
		_update_it_label(is_it)
	if visual:
		visual.scale = Vector2(1.5, 0.6) if is_dashing else Vector2.ONE
		var flip := absf(visual.scale.x) * (1.0 if facing >= 0 else -1.0)
		visual.scale.x = flip
		# While grounded, shift Visual down to compensate for its scale
		# origin sitting above the feet -- see _ground_line_y -- so a floor
		# dash's squash keeps the feet planted and only compresses the top,
		# instead of visibly opening a gap under the sprite.
		visual.position.y = _ground_line_y * (1.0 - visual.scale.y) if on_floor else 0.0
