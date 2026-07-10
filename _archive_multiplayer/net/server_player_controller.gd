extends RefCounted
class_name ServerPlayerController

# Owns one connected peer's authoritative simulation on the server: buffers
# their submitted inputs and steps the shared Player movement script once
# per physics tick, in order.

const MAX_QUEUE := 12

var player: Player
var peer_id: int
var last_processed_seq: int = -1
var last_input: Dictionary = {}
var _pending: Array[Dictionary] = []

func _init(p_player: Player, p_peer_id: int) -> void:
	player = p_player
	peer_id = p_peer_id
	player.peer_id = p_peer_id

func queue_input(seq: int, input: Dictionary) -> void:
	if seq <= last_processed_seq:
		return
	_pending.append({"seq": seq, "input": input})
	_pending.sort_custom(func(a, b): return a.seq < b.seq)
	while _pending.size() > MAX_QUEUE:
		_pending.pop_front()

func process_tick(delta: float) -> Dictionary:
	var seq_to_report := last_processed_seq
	if _pending.size() > 0:
		var next: Dictionary = _pending.pop_front()
		last_input = next.input
		last_processed_seq = next.seq
		seq_to_report = next.seq
	# No fresh input this tick (jitter/loss) -- keep applying the last known
	# input rather than snapping to idle, so brief gaps don't stutter motion.
	player.apply_input(last_input, delta)
	return _build_state(seq_to_report)

## Re-reads player state without consuming an input -- for reporting a
## snapshot after something outside apply_input changed the player mid-tick
## (e.g. a void-fall teleport in server_main.gd).
func _build_state(seq_to_report: int) -> Dictionary:
	return {
		"peer_id": peer_id,
		"seq": seq_to_report,
		"position": player.position,
		"velocity": player.velocity,
		"facing": player.facing,
		"is_dashing": player.is_dashing,
		"is_it": player.is_it,
	}

func latest_state() -> Dictionary:
	return _build_state(last_processed_seq)
