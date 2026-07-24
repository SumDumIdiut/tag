extends RefCounted
class_name TrainedPolicy

# Runs a trained RL policy's forward pass in plain GDScript -- Godot has no
# built-in ONNX/PyTorch runtime, so this is a small hand-written matrix-
# multiply + tanh stack instead (see ai_training/export_weights.py, which
# dumps a trained model's weights to the JSON this loads; net_arch=[64,64]
# was chosen specifically to keep this forward pass cheap).
#
# _build_observation() mirrors ai_training/tag_env.py's TagVecEnv._obs()
# feature-for-feature, same order, same normalization constants -- any
# drift between the two means the policy sees something different at
# inference time than what it was actually trained on, which would degrade
# behavior in a way that's hard to notice just from watching it play.

const WEIGHTS_PATH := "res://assets/ai/npc_policy_weights.json"

# Mirrors ai_training/tag_env.py's own constant exactly -- sim.py now trains
# across every map in the online pool (domain randomization, not one fixed
# arena), so this covers the largest of them (classic_arena) with margin,
# not just whichever single arena used to be the only one. IMPORTANT: the
# currently-bundled npc_policy_weights.json was trained against the OLD
# single-arena (600, 650) scale -- it's now out of sync with this constant
## until a model trained against the new multi-arena sim.py is re-exported
# and re-bundled (see ai_training/README.md). Using the old model with this
# new normalization would feed it inputs scaled differently than what it
# actually learned on.
const ARENA_HALF_EXTENT := Vector2(1250.0, 550.0)
const SCALE := 32.0 / 11.0
const DASH_SPEED := 240.0 * SCALE * 1.5
const MAX_FALL_SPEED := 160.0 * SCALE
# The policy was only ever trained on 180s rounds (ai_training/sim.py's
# ROUND_DURATION_SEC) -- normalizing by a casual match's real 300s duration
# instead would shift this feature outside the range it was trained on, so
# this stays fixed at the training-time constant regardless of the actual
# match's round_timer ceiling.
const TRAINED_ROUND_DURATION_SEC := 180.0

static var _shared = null

var _layers: Array = []
var _action_dims: Array = [3, 2, 2]
var loaded := false

## Lazily loads once and reuses across every NPC that wants it -- the JSON
## parse + weight arrays are the same for all of them, no reason to repeat
## it per-instance. Untyped return (not -> TrainedPolicy) -- a self-
## referential static return type here doesn't reliably resolve on a fresh
## class-cache build (confirmed: a clean headless load fails to find
## "TrainedPolicy" from within its own file), same class of issue
## match_results.gd hit with AchievementToast earlier.
static func get_shared():
	if _shared == null:
		# load(self path), not TrainedPolicy.new() -- a self-referential
		# class_name construction from within this same file hits the exact
		# same fresh-compile resolution failure the type annotations above
		# did, so this uses a plain resource load instead.
		_shared = load("res://npc/trained_policy.gd").new()
		_shared.load_weights(WEIGHTS_PATH)
	return _shared

func load_weights(path: String) -> void:
	if not FileAccess.file_exists(path):
		push_warning("TrainedPolicy: no weights file at %s -- falling back to the scripted AI" % path)
		return
	var f := FileAccess.open(path, FileAccess.READ)
	if not f:
		push_warning("TrainedPolicy: couldn't open %s" % path)
		return
	var parsed = JSON.parse_string(f.get_as_text())
	if typeof(parsed) != TYPE_DICTIONARY or not parsed.has("layers"):
		push_warning("TrainedPolicy: %s didn't parse as expected" % path)
		return
	_layers = parsed.layers
	_action_dims = parsed.get("action_dims", [3, 2, 2])
	loaded = _layers.size() > 0

## `self_p`/`target_p` are real Player nodes (an NPC and whatever
## tag_mode.get_ai_target() picked for it), `tag_mode` the real TagMode.
## Returns the same shape npc.gd's own heuristic decision produces, so a
## caller can use either interchangeably.
func decide(self_p: Node, target_p: Node, tag_mode: Node) -> Dictionary:
	var x: PackedFloat32Array = _build_observation(self_p, target_p, tag_mode)
	for layer in _layers:
		x = _dense(x, layer.weight, layer.bias, String(layer.activation))

	var offset := 0
	var move_idx := _argmax(x, offset, int(_action_dims[0]))
	offset += int(_action_dims[0])
	var jump_idx := _argmax(x, offset, int(_action_dims[1]))
	offset += int(_action_dims[1])
	var dash_idx := _argmax(x, offset, int(_action_dims[2]))

	return {
		"move_dir": Vector2(float(move_idx - 1), 0.0), # 0/1/2 -> -1/0/1, matches sim.py's ACT_MOVE_* convention
		"jump": jump_idx == 1,
		"dash": dash_idx == 1,
	}

func _build_observation(self_p: Node, target_p: Node, tag_mode: Node) -> PackedFloat32Array:
	var self_pos: Vector2 = self_p.global_position
	var self_vel: Vector2 = self_p.velocity
	var other_pos: Vector2 = target_p.global_position
	var other_vel: Vector2 = target_p.velocity

	var obs := PackedFloat32Array()
	obs.resize(13)
	obs[0] = self_pos.x / ARENA_HALF_EXTENT.x
	obs[1] = self_pos.y / ARENA_HALF_EXTENT.y
	obs[2] = self_vel.x / DASH_SPEED
	obs[3] = self_vel.y / MAX_FALL_SPEED
	obs[4] = 1.0 if self_p.is_on_floor() else 0.0
	obs[5] = 1.0 if tag_mode.is_it(self_p) else 0.0
	obs[6] = 1.0 if self_p.dash_cooldown_timer <= 0.0 else 0.0
	obs[7] = (other_pos.x - self_pos.x) / (ARENA_HALF_EXTENT.x * 2.0)
	obs[8] = (other_pos.y - self_pos.y) / (ARENA_HALF_EXTENT.y * 2.0)
	obs[9] = other_vel.x / DASH_SPEED
	obs[10] = other_vel.y / MAX_FALL_SPEED
	obs[11] = 1.0 if tag_mode.is_it(target_p) else 0.0
	obs[12] = tag_mode.round_timer / TRAINED_ROUND_DURATION_SEC
	return obs

func _dense(x: PackedFloat32Array, weight: Array, bias: Array, activation: String) -> PackedFloat32Array:
	var out_dim := weight.size()
	var in_dim := x.size()
	var y := PackedFloat32Array()
	y.resize(out_dim)
	for o in out_dim:
		var row: Array = weight[o]
		var s: float = float(bias[o])
		for i in in_dim:
			s += float(row[i]) * x[i]
		y[o] = s
	if activation == "tanh":
		for o in out_dim:
			y[o] = tanh(y[o])
	return y

func _argmax(vals: PackedFloat32Array, start: int, count: int) -> int:
	var best_idx := 0
	var best_val := vals[start]
	for i in range(1, count):
		if vals[start + i] > best_val:
			best_val = vals[start + i]
			best_idx = i
	return best_idx
