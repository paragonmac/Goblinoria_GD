extends RefCounted
class_name Pathfinder
## A* pathfinding for voxel worlds with stair support.

#region Constants
const MIN_WALKABLE_Y := 1
const LEVEL_STEP := 1
const MAX_ITERATIONS := 10000
const NEAR_GOAL_DISTANCE := 1
const COST_UNIT := 1.0
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
#endregion


#region Walkability
func is_blocking(world, block_id: int) -> bool:
	if world.is_ramp_block_id(block_id):
		return false
	return world.is_block_solid_id(block_id)


func is_walkable(world, x: int, y: int, z: int) -> bool:
	if y < 0 or y >= world.world_size_y:
		return false
	if y < MIN_WALKABLE_Y:
		return false
	var below_block: int = world.get_block_no_generate(x, y - 1, z)
	if not world.is_block_solid_id(below_block):
		return false
	var current_block: int = world.get_block_no_generate(x, y, z)
	if is_blocking(world, current_block):
		return false
	return true


func can_change_level(world, from: Vector3i, to: Vector3i) -> bool:
	if from.y == to.y:
		return true
	var from_block: int = world.get_block_no_generate(from.x, from.y, from.z)
	var to_block: int = world.get_block_no_generate(to.x, to.y, to.z)
	return world.is_ramp_block_id(from_block) or world.is_ramp_block_id(to_block)
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
		if is_walkable(world, nx, y, nz):
			neighbors.append(Vector3i(nx, y, nz))

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
func find_path(world, start: Vector3i, goal: Vector3i, allow_near_goal: bool = true, return_best_effort: bool = false) -> Array:
	var profiler: DebugProfiler = debug_profiler
	if profiler != null and profiler.enabled:
		profiler.begin("Pathfinder.find_path")

	var came_from: Dictionary = {}
	var g_score: Dictionary = {}

	g_score[start] = 0
	_heap_clear()
	_heap_push(float(heuristic(start, goal)), start)
	var in_open: Dictionary = {start: true}

	var max_iterations: int = MAX_ITERATIONS
	var iterations: int = 0
	var best_node: Vector3i = start
	var best_h: float = float(heuristic(start, goal))

	var result: Array = []
	while not _heap_is_empty() and iterations < max_iterations:
		iterations += 1
		var current: Vector3i = _heap_pop()
		in_open.erase(current)

		if current == goal:
			result = reconstruct_path(came_from, current)
			break
		if allow_near_goal and abs(current.x - goal.x) <= NEAR_GOAL_DISTANCE and abs(current.y - goal.y) <= NEAR_GOAL_DISTANCE and abs(current.z - goal.z) <= NEAR_GOAL_DISTANCE:
			result = reconstruct_path(came_from, current)
			break

		var current_h: float = float(heuristic(current, goal))
		if current_h < best_h:
			best_h = current_h
			best_node = current

		for neighbor: Vector3i in get_neighbors(world, current):
			var tentative_g: float = float(g_score.get(current, INF)) + COST_UNIT
			if tentative_g < float(g_score.get(neighbor, INF)):
				came_from[neighbor] = current
				g_score[neighbor] = tentative_g
				var f: float = tentative_g + float(heuristic(neighbor, goal))
				if not in_open.has(neighbor):
					in_open[neighbor] = true
					_heap_push(f, neighbor)
				# Note: for a proper decrease-key we'd need to update the heap.
				# Re-inserting with lower f is acceptable — stale entries are
				# skipped because their g_score will be higher.
				else:
					_heap_push(f, neighbor)

	if result.is_empty() and return_best_effort and best_node != start:
		result = reconstruct_path(came_from, best_node)

	if profiler != null and profiler.enabled:
		profiler.end("Pathfinder.find_path")
	return result


func find_path_to_adjacent_on_level(world, start: Vector3i, target: Vector3i, level: int) -> Array:
	if level < 0 or level >= world.world_size_y:
		return []

	var candidates: Array[Vector3i] = []
	for dir in CARDINAL_DIRS_3D:
		var candidate := Vector3i(target.x + dir.x, level, target.z + dir.z)
		if is_walkable(world, candidate.x, candidate.y, candidate.z):
			candidates.append(candidate)

	if candidates.is_empty():
		return []

	candidates.sort_custom(func(a, b):
		return a.distance_squared_to(start) < b.distance_squared_to(start)
	)

	for goal in candidates:
		var path: Array = find_path(world, start, goal, false, false)
		if path.size() > 0:
			return path

	return []
#endregion


#region Path Reconstruction
func reconstruct_path(came_from: Dictionary, current: Vector3i) -> Array:
	var path: Array = [current]
	while came_from.has(current):
		current = came_from[current]
		path.push_front(current)
	return path
#endregion
