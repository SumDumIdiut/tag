extends RefCounted
class_name WaypointGraph

# A small hand-placed navigation graph over an arena's platforms, built once
# at match start. NPCs use this for cross-platform macro-navigation (which
# platform to head to next) instead of just steering blindly toward a
# target's raw position, which falls apart the moment the target is on a
# different platform, behind a pillar, or otherwise not reachable in a
# straight line -- exactly the "AI never actually gets close" failure mode.

const MAX_EDGE_DISTANCE := 900.0

var _positions: Array[Vector2] = []
var _adjacency: Array = []

## Connects every pair of waypoints within MAX_EDGE_DISTANCE that has clear
## line of sight through world geometry -- a rough but effective proxy for
## "reachable by running, jumping, or dashing" on an open arena like this one
## (no mazes/corridors where line-of-sight would lie about true reachability).
func build(waypoint_nodes: Array) -> void:
	_positions.clear()
	_adjacency.clear()
	for n in waypoint_nodes:
		_positions.append(n.global_position)
		_adjacency.append([])
	if _positions.is_empty():
		return
	var space_state := (waypoint_nodes[0] as Node2D).get_world_2d().direct_space_state
	for i in _positions.size():
		for j in range(i + 1, _positions.size()):
			var a: Vector2 = _positions[i]
			var b: Vector2 = _positions[j]
			if a.distance_to(b) > MAX_EDGE_DISTANCE:
				continue
			var params := PhysicsRayQueryParameters2D.create(a, b, Player.WORLD_COLLISION_MASK)
			if not space_state.intersect_ray(params):
				_adjacency[i].append(j)
				_adjacency[j].append(i)

func _nearest_index(pos: Vector2) -> int:
	var best := -1
	var best_dist := INF
	for i in _positions.size():
		var d: float = _positions[i].distance_to(pos)
		if d < best_dist:
			best_dist = d
			best = i
	return best

## Returns the next waypoint to head toward when travelling from `from`
## to `to` (not the whole path -- callers re-path every decision anyway, so
## only the immediate next hop matters), or `to` itself if there's no useful
## graph (empty graph, or already at/near the nearest shared waypoint).
func next_hop(from: Vector2, to: Vector2) -> Vector2:
	if _positions.is_empty():
		return to
	var start := _nearest_index(from)
	var goal := _nearest_index(to)
	if start == -1 or goal == -1 or start == goal:
		return to

	# BFS over the small hand-placed graph -- unweighted is fine at this scale.
	var prev := {}
	var visited := {start: true}
	var queue := [start]
	var head := 0
	while head < queue.size():
		var current: int = queue[head]
		head += 1
		if current == goal:
			break
		for next in _adjacency[current]:
			if not visited.has(next):
				visited[next] = true
				prev[next] = current
				queue.append(next)

	if not visited.has(goal):
		return to # no connected path -- fall back to direct steering

	var step := goal
	while prev.has(step) and prev[step] != start:
		step = prev[step]
	return _positions[step]
