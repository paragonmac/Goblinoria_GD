extends RefCounted
class_name Pathfinder
## A* pathfinding for voxel worlds with stair support.

#region Constants
const MIN_WALKABLE_Y := 1
const LEVEL_STEP := 1
const MAX_ITERATIONS := 10000
const NEAR_GOAL_DISTANCE := 1
const COST_UNIT := 1.0
const ADJACENT_SEARCH_MIN_ITERATIONS := 128
const ADJACENT_SEARCH_MAX_ITERATIONS := 512
const ADJACENT_SEARCH_DISTANCE_FACTOR := 8
const TASK_SEARCH_MIN_ITERATIONS := 192
const TASK_SEARCH_MAX_ITERATIONS := 8192
const TASK_SEARCH_DISTANCE_FACTOR := 24
const CARDINAL_DIRS_2D := [
	Vector2i(-1, 0),
	Vector2i(1, 0),
	Vector2i(0, -1),
	Vector2i(0, 1),
]
const CARDINAL_DIRS_3D := [
	Vector3i(-1, 0, 0),
	Vector3i(1, 0, 0),
	Vector3i(0, 0, -1),
	Vector3i(0, 0, 1),
]
#endregion

#region State
var debug_profiler: DebugProfiler
var last_search_stats := {}
#endregion


#region Walkability
func is_blocking(world, block_id: int) -> bool:
	if world.is_ramp_block_id(block_id):
		return false
	return world.is_block_solid_id(block_id)


func is_walkable(world, x: int, y: int, z: int) -> bool:
	if not world.is_block_coord_valid(x, y, z):
		return false
	if y < MIN_WALKABLE_Y:
		return false
	var below_block: int = world.get_block_no_generate(x, y - 1, z)
	if world.is_ramp_block_id(below_block):
		return false
	if not world.is_block_solid_id(below_block):
		return false
	var current_block: int = world.get_block_no_generate(x, y, z)
	if is_blocking(world, current_block):
		return false
	return true


func can_traverse(world, from: Vector3i, to: Vector3i) -> bool:
	var dx: int = to.x - from.x
	var dy: int = to.y - from.y
	var dz: int = to.z - from.z
	if abs(dx) + abs(dz) != 1:
		return false
	if dy == 0:
		return can_move_same_level(world, from, to)
	if abs(dy) != LEVEL_STEP:
		return false
	return can_change_level(world, from, to)


func can_move_same_level(world, from: Vector3i, to: Vector3i) -> bool:
	# SEE-ADR-002: Ramps expose directional low/high edges, not generic open space.
	if from.y != to.y:
		return false
	if not world.is_block_coord_valid(from.x, from.y, from.z):
		return false
	if not world.is_block_coord_valid(to.x, to.y, to.z):
		return false
	var from_block: int = world.get_block_no_generate(from.x, from.y, from.z)
	var to_block: int = world.get_block_no_generate(to.x, to.y, to.z)
	var dir := Vector2i(to.x - from.x, to.z - from.z)
	if world.is_ramp_block_id(from_block) and not _ramp_edge_has_low(from_block, dir):
		return false
	if world.is_ramp_block_id(to_block) and not _ramp_edge_has_low(to_block, -dir):
		return false
	return true


func can_change_level(world, from: Vector3i, to: Vector3i) -> bool:
	# SEE-ADR-002: Level changes must line up with the ramp's high edge.
	if from.y == to.y:
		return true
	if not world.is_block_coord_valid(from.x, from.y, from.z):
		return false
	if not world.is_block_coord_valid(to.x, to.y, to.z):
		return false
	var from_block: int = world.get_block_no_generate(from.x, from.y, from.z)
	var to_block: int = world.get_block_no_generate(to.x, to.y, to.z)
	var dir := Vector2i(to.x - from.x, to.z - from.z)
	if to.y == from.y + LEVEL_STEP:
		return world.is_ramp_block_id(from_block) and _ramp_edge_has_high(from_block, dir)
	if to.y == from.y - LEVEL_STEP:
		return world.is_ramp_block_id(to_block) and _ramp_edge_has_high(to_block, -dir)
	return false


func _ramp_edge_has_low(block_id: int, dir: Vector2i) -> bool:
	var heights := _ramp_corner_heights(block_id)
	for corner in _edge_corners(dir):
		if int(heights.get(corner, -1)) < 0:
			return true
	return false


func _ramp_edge_has_high(block_id: int, dir: Vector2i) -> bool:
	var heights := _ramp_corner_heights(block_id)
	for corner in _edge_corners(dir):
		if int(heights.get(corner, -1)) > 0:
			return true
	return false


func _edge_corners(dir: Vector2i) -> Array[String]:
	if dir == Vector2i(0, -1):
		return ["nw", "ne"]
	if dir == Vector2i(0, 1):
		return ["sw", "se"]
	if dir == Vector2i(1, 0):
		return ["ne", "se"]
	if dir == Vector2i(-1, 0):
		return ["nw", "sw"]
	return []


func _ramp_corner_heights(block_id: int) -> Dictionary:
	match World.ramp_shape_id(block_id):
		World.RAMP_NORTH_ID:
			return {"nw": 1, "ne": 1, "se": -1, "sw": -1}
		World.RAMP_SOUTH_ID:
			return {"nw": -1, "ne": -1, "se": 1, "sw": 1}
		World.RAMP_EAST_ID:
			return {"nw": -1, "ne": 1, "se": 1, "sw": -1}
		World.RAMP_WEST_ID:
			return {"nw": 1, "ne": -1, "se": -1, "sw": 1}
		World.RAMP_NORTHEAST_ID:
			return {"nw": -1, "ne": 1, "se": -1, "sw": -1}
		World.RAMP_NORTHWEST_ID:
			return {"nw": 1, "ne": -1, "se": -1, "sw": -1}
		World.RAMP_SOUTHEAST_ID:
			return {"nw": -1, "ne": -1, "se": 1, "sw": -1}
		World.RAMP_SOUTHWEST_ID:
			return {"nw": -1, "ne": -1, "se": -1, "sw": 1}
		World.INNER_SOUTHWEST_ID:
			return {"nw": 1, "ne": 1, "se": 1, "sw": -1}
		World.INNER_SOUTHEAST_ID:
			return {"nw": 1, "ne": 1, "se": -1, "sw": 1}
		World.INNER_NORTHWEST_ID:
			return {"nw": -1, "ne": 1, "se": 1, "sw": 1}
		World.INNER_NORTHEAST_ID:
			return {"nw": 1, "ne": -1, "se": 1, "sw": 1}
		_:
			return {"nw": -1, "ne": -1, "se": -1, "sw": -1}
#endregion


#region Neighbor Discovery
func get_neighbors(world, pos: Vector3i) -> Array:
	var neighbors: Array[Vector3i] = []
	var x: int = pos.x
	var y: int = pos.y
	var z: int = pos.z

	# Same level
	for dir in CARDINAL_DIRS_2D:
		var nx: int = x + dir.x
		var nz: int = z + dir.y
		var candidate := Vector3i(nx, y, nz)
		if is_walkable(world, nx, y, nz) and can_traverse(world, pos, candidate):
			neighbors.append(candidate)

	# Up level
	for dir in CARDINAL_DIRS_2D:
		var nx: int = x + dir.x
		var nz: int = z + dir.y
		var ny: int = y + LEVEL_STEP
		if ny < world.world_size_y:
			var head_block: int = world.get_block_no_generate(x, y + 1, z)
			var candidate := Vector3i(nx, ny, nz)
			if is_walkable(world, nx, ny, nz) and not is_blocking(world, head_block) and can_change_level(world, pos, candidate):
				neighbors.append(candidate)

	# Down level
	for dir in CARDINAL_DIRS_2D:
		var nx: int = x + dir.x
		var nz: int = z + dir.y
		var ny: int = y - LEVEL_STEP
		if ny >= 0:
			var candidate := Vector3i(nx, ny, nz)
			if is_walkable(world, nx, ny, nz) and can_change_level(world, pos, candidate):
				neighbors.append(candidate)

	return neighbors
#endregion


#region Heuristics
func heuristic(a: Vector3i, b: Vector3i) -> int:
	return abs(a.x - b.x) + abs(a.y - b.y) + abs(a.z - b.z)
#endregion


#region Binary Heap
# Binary min-heap storing [f_score, Vector3i] pairs.
# _heap_data[i] = [f: float, node: Vector3i]
var _heap_data: Array = []


func _heap_clear() -> void:
	_heap_data.clear()


func _heap_push(f: float, node: Vector3i) -> void:
	_heap_data.append([f, node])
	_heap_sift_up(_heap_data.size() - 1)


func _heap_pop() -> Vector3i:
	var top: Array = _heap_data[0]
	var last_idx: int = _heap_data.size() - 1
	if last_idx > 0:
		_heap_data[0] = _heap_data[last_idx]
	_heap_data.resize(last_idx)
	if _heap_data.size() > 0:
		_heap_sift_down(0)
	return top[1]


func _heap_is_empty() -> bool:
	return _heap_data.is_empty()


func _heap_sift_up(idx: int) -> void:
	while idx > 0:
		var parent: int = (idx - 1) >> 1
		if float(_heap_data[idx][0]) < float(_heap_data[parent][0]):
			var tmp: Array = _heap_data[idx]
			_heap_data[idx] = _heap_data[parent]
			_heap_data[parent] = tmp
			idx = parent
		else:
			break


func _heap_sift_down(idx: int) -> void:
	var size: int = _heap_data.size()
	while true:
		var smallest: int = idx
		var left: int = 2 * idx + 1
		var right: int = 2 * idx + 2
		if left < size and float(_heap_data[left][0]) < float(_heap_data[smallest][0]):
			smallest = left
		if right < size and float(_heap_data[right][0]) < float(_heap_data[smallest][0]):
			smallest = right
		if smallest != idx:
			var tmp: Array = _heap_data[idx]
			_heap_data[idx] = _heap_data[smallest]
			_heap_data[smallest] = tmp
			idx = smallest
		else:
			break
#endregion


#region Pathfinding
func find_path(
	world,
	start: Vector3i,
	goal: Vector3i,
	allow_near_goal: bool = true,
	return_best_effort: bool = false,
	max_iterations_override: int = MAX_ITERATIONS
) -> Array:
	return _find_path_to_goals(
		world,
		start,
		[goal],
		allow_near_goal,
		return_best_effort,
		max_iterations_override
	)


func find_path_to_any(
	world,
	start: Vector3i,
	goals: Array,
	max_iterations_cap: int = TASK_SEARCH_MAX_ITERATIONS
) -> Array:
	if goals.is_empty():
		return _find_path_to_goals(world, start, goals, false, false, 0)
	var direct_distance := _heuristic_to_goals(start, goals)
	var capped_max_iterations := clampi(
		max_iterations_cap,
		TASK_SEARCH_MIN_ITERATIONS,
		TASK_SEARCH_MAX_ITERATIONS
	)
	var search_budget := clampi(
		direct_distance * TASK_SEARCH_DISTANCE_FACTOR,
		TASK_SEARCH_MIN_ITERATIONS,
		capped_max_iterations
	)
	return _find_path_to_goals(world, start, goals, false, false, search_budget)


func _find_path_to_goals(
	world,
	start: Vector3i,
	goals: Array,
	allow_near_goal: bool,
	return_best_effort: bool,
	max_iterations: int
) -> Array:
	last_search_stats = {
		"start": start,
		"goals": goals.duplicate(),
		"goal_count": goals.size(),
		"allow_near_goal": allow_near_goal,
		"return_best_effort": return_best_effort,
		"max_iterations": max_iterations,
		"iterations_used": 0,
		"nodes_closed": 0,
		"best_node": start,
		"best_distance_to_goal": 0,
		"hit_iteration_cap": false,
		"open_remaining": 0,
		"result_found": false,
		"returned_best_effort": false,
		"reason": "not_started",
	}
	if not world.is_block_coord_valid(start.x, start.y, start.z):
		last_search_stats["reason"] = "invalid_start"
		return []
	if goals.is_empty():
		last_search_stats["reason"] = "no_goals"
		return []
	var goal_set: Dictionary = {}
	for goal: Vector3i in goals:
		if not world.is_block_coord_valid(goal.x, goal.y, goal.z):
			continue
		goal_set[goal] = true
	if goal_set.is_empty():
		last_search_stats["reason"] = "no_valid_goals"
		return []
	var profiler: DebugProfiler = debug_profiler
	if profiler != null and profiler.enabled:
		profiler.begin("Pathfinder.find_path")

	var came_from: Dictionary = {}
	var g_score: Dictionary = {}

	g_score[start] = 0
	_heap_clear()
	_heap_push(float(_heuristic_to_goals(start, goals)), start)
	var in_open: Dictionary = {start: true}
	var closed: Dictionary = {}

	var iterations: int = 0
	var best_node: Vector3i = start
	var best_h: float = float(_heuristic_to_goals(start, goals))

	var result: Array = []
	var returned_best_effort := false
	while not _heap_is_empty() and iterations < max_iterations:
		var current: Vector3i = _heap_pop()
		if closed.has(current):
			continue
		closed[current] = true
		in_open.erase(current)
		iterations += 1

		if goal_set.has(current):
			result = reconstruct_path(came_from, current)
			break
		if allow_near_goal:
			for goal: Vector3i in goals:
				if abs(current.x - goal.x) <= NEAR_GOAL_DISTANCE \
					and abs(current.y - goal.y) <= NEAR_GOAL_DISTANCE \
					and abs(current.z - goal.z) <= NEAR_GOAL_DISTANCE:
					result = reconstruct_path(came_from, current)
					break
			if not result.is_empty():
				break

		var current_h: float = float(_heuristic_to_goals(current, goals))
		if current_h < best_h:
			best_h = current_h
			best_node = current

		for neighbor: Vector3i in get_neighbors(world, current):
			if closed.has(neighbor):
				continue
			var tentative_g: float = float(g_score.get(current, INF)) + COST_UNIT
			if tentative_g < float(g_score.get(neighbor, INF)):
				came_from[neighbor] = current
				g_score[neighbor] = tentative_g
				var f: float = tentative_g + float(_heuristic_to_goals(neighbor, goals))
				if not in_open.has(neighbor):
					in_open[neighbor] = true
					_heap_push(f, neighbor)
				else:
					_heap_push(f, neighbor)

	if result.is_empty() and return_best_effort and best_node != start:
		result = reconstruct_path(came_from, best_node)
		returned_best_effort = true

	last_search_stats["iterations_used"] = iterations
	last_search_stats["nodes_closed"] = closed.size()
	last_search_stats["best_node"] = best_node
	last_search_stats["best_distance_to_goal"] = best_h
	last_search_stats["hit_iteration_cap"] = iterations >= max_iterations and not _heap_is_empty()
	last_search_stats["open_remaining"] = _heap_data.size()
	last_search_stats["result_found"] = not result.is_empty()
	last_search_stats["returned_best_effort"] = returned_best_effort
	if not result.is_empty():
		last_search_stats["reason"] = "best_effort" if returned_best_effort else "found"
	elif bool(last_search_stats["hit_iteration_cap"]):
		last_search_stats["reason"] = "iteration_cap"
	else:
		last_search_stats["reason"] = "no_path"

	if profiler != null and profiler.enabled:
		profiler.end("Pathfinder.find_path")
	return result


func _heuristic_to_goals(pos: Vector3i, goals: Array) -> int:
	var best := MAX_ITERATIONS
	for goal: Vector3i in goals:
		best = mini(best, heuristic(pos, goal))
	return best


func find_path_to_adjacent_on_level(
	world,
	start: Vector3i,
	target: Vector3i,
	level: int,
	max_iterations_cap: int = ADJACENT_SEARCH_MAX_ITERATIONS
) -> Array:
	if level < 0 or level >= world.world_size_y:
		last_search_stats = {
			"start": start,
			"goals": [],
			"goal_count": 0,
			"max_iterations": 0,
			"iterations_used": 0,
			"nodes_closed": 0,
			"best_node": start,
			"best_distance_to_goal": 0,
			"hit_iteration_cap": false,
			"open_remaining": 0,
			"result_found": false,
			"returned_best_effort": false,
			"reason": "invalid_level",
		}
		return []

	var candidates := get_walkable_adjacent_on_level(world, target, level)
	if candidates.is_empty():
		last_search_stats = {
			"start": start,
			"goals": [],
			"goal_count": 0,
			"max_iterations": 0,
			"iterations_used": 0,
			"nodes_closed": 0,
			"best_node": start,
			"best_distance_to_goal": 0,
			"hit_iteration_cap": false,
			"open_remaining": 0,
			"result_found": false,
			"returned_best_effort": false,
			"reason": "no_adjacent_candidates",
		}
		return []

	candidates.sort_custom(func(a, b):
		return a.distance_squared_to(start) < b.distance_squared_to(start)
	)

	var direct_distance := _heuristic_to_goals(start, candidates)
	var capped_max_iterations := clampi(
		max_iterations_cap,
		ADJACENT_SEARCH_MIN_ITERATIONS,
		ADJACENT_SEARCH_MAX_ITERATIONS
	)
	var search_budget := clampi(
		direct_distance * ADJACENT_SEARCH_DISTANCE_FACTOR,
		ADJACENT_SEARCH_MIN_ITERATIONS,
		capped_max_iterations
	)
	return _find_path_to_goals(world, start, candidates, false, false, search_budget)


func has_walkable_adjacent_on_level(world, target: Vector3i, level: int) -> bool:
	if level < 0 or level >= world.world_size_y:
		return false
	for dir in CARDINAL_DIRS_3D:
		var candidate := Vector3i(target.x + dir.x, level, target.z + dir.z)
		if is_walkable(world, candidate.x, candidate.y, candidate.z):
			return true
	return false


func get_walkable_adjacent_on_level(world, target: Vector3i, level: int) -> Array[Vector3i]:
	var candidates: Array[Vector3i] = []
	if level < 0 or level >= world.world_size_y:
		return candidates
	for dir in CARDINAL_DIRS_3D:
		var candidate := Vector3i(target.x + dir.x, level, target.z + dir.z)
		if is_walkable(world, candidate.x, candidate.y, candidate.z):
			candidates.append(candidate)
	return candidates
#endregion


#region Path Reconstruction
func reconstruct_path(came_from: Dictionary, current: Vector3i) -> Array:
	var path: Array = [current]
	while came_from.has(current):
		current = came_from[current]
		path.push_front(current)
	return path
#endregion
