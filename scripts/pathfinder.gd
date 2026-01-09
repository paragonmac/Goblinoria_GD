extends RefCounted
class_name Pathfinder

const STAIR_BLOCK_ID := 100
var debug_profiler: DebugProfiler

func is_blocking(block_id: int) -> bool:
    return block_id != 0 and block_id != STAIR_BLOCK_ID

func is_walkable(world, x: int, y: int, z: int) -> bool:
    if x < 0 or y < 0 or z < 0:
        return false
    if x >= world.world_size_x or y >= world.world_size_y or z >= world.world_size_z:
        return false
    if y == 0:
        return false
    var below_block: int = world.get_block(x, y - 1, z)
    if below_block == 0:
        return false
    var current_block: int = world.get_block(x, y, z)
    if is_blocking(current_block):
        return false
    return true

func can_change_level(world, from: Vector3i, to: Vector3i) -> bool:
    if from.y == to.y:
        return true
    var from_block: int = world.get_block(from.x, from.y, from.z)
    var to_block: int = world.get_block(to.x, to.y, to.z)
    return from_block == STAIR_BLOCK_ID or to_block == STAIR_BLOCK_ID

func get_neighbors(world, pos: Vector3i) -> Array:
    var neighbors: Array[Vector3i] = []
    var x: int = pos.x
    var y: int = pos.y
    var z: int = pos.z

    var dirs: Array[Vector2i] = [Vector2i(-1, 0), Vector2i(1, 0), Vector2i(0, -1), Vector2i(0, 1)]
    for dir in dirs:
        var nx: int = x + dir.x
        var nz: int = z + dir.y
        if is_walkable(world, nx, y, nz):
            neighbors.append(Vector3i(nx, y, nz))

    for dir in dirs:
        var nx: int = x + dir.x
        var nz: int = z + dir.y
        var ny: int = y + 1
        if ny < world.world_size_y:
            var head_block: int = world.get_block(x, y + 1, z)
            var candidate := Vector3i(nx, ny, nz)
            if is_walkable(world, nx, ny, nz) and not is_blocking(head_block) and can_change_level(world, pos, candidate):
                neighbors.append(candidate)

    for dir in dirs:
        var nx: int = x + dir.x
        var nz: int = z + dir.y
        var ny: int = y - 1
        if ny >= 0:
            var candidate := Vector3i(nx, ny, nz)
            if is_walkable(world, nx, ny, nz) and can_change_level(world, pos, candidate):
                neighbors.append(candidate)

    return neighbors

func heuristic(a: Vector3i, b: Vector3i) -> int:
    return abs(a.x - b.x) + abs(a.y - b.y) + abs(a.z - b.z)

func find_path(world, start: Vector3i, goal: Vector3i, allow_near_goal: bool = true, return_best_effort: bool = false) -> Array:
    var profiler: DebugProfiler = debug_profiler
    if profiler != null and profiler.enabled:
        profiler.begin("pathfinder/find_path")
    var open_set: Array[Vector3i] = []
    var came_from: Dictionary = {}
    var g_score: Dictionary = {}
    var f_score: Dictionary = {}

    g_score[start] = 0
    f_score[start] = heuristic(start, goal)
    open_set.append(start)

    var max_iterations: int = 10000
    var iterations: int = 0
    var best_node: Vector3i = start
    var best_h: float = float(heuristic(start, goal))

    var result: Array = []
    while open_set.size() > 0 and iterations < max_iterations:
        iterations += 1
        var current: Vector3i = open_set[0]
        var current_f: float = float(f_score.get(current, INF))
        for candidate: Vector3i in open_set:
            var cand_f: float = float(f_score.get(candidate, INF))
            if cand_f < current_f:
                current = candidate
                current_f = cand_f

        if current == goal:
            result = reconstruct_path(came_from, current)
            break
        if allow_near_goal and abs(current.x - goal.x) <= 1 and abs(current.y - goal.y) <= 1 and abs(current.z - goal.z) <= 1:
            result = reconstruct_path(came_from, current)
            break

        var current_h: float = float(heuristic(current, goal))
        if current_h < best_h:
            best_h = current_h
            best_node = current

        open_set.erase(current)
        for neighbor: Vector3i in get_neighbors(world, current):
            var tentative_g: float = float(g_score.get(current, INF)) + 1.0
            if tentative_g < float(g_score.get(neighbor, INF)):
                came_from[neighbor] = current
                g_score[neighbor] = tentative_g
                f_score[neighbor] = tentative_g + heuristic(neighbor, goal)
                if not open_set.has(neighbor):
                    open_set.append(neighbor)

    if result.is_empty() and return_best_effort and best_node != start:
        result = reconstruct_path(came_from, best_node)

    if profiler != null and profiler.enabled:
        profiler.end("pathfinder/find_path")
    return result

func find_path_to_adjacent_on_level(world, start: Vector3i, target: Vector3i, level: int) -> Array:
    if level < 0 or level >= world.world_size_y:
        return []

    var candidates: Array[Vector3i] = []
    var dirs: Array[Vector3i] = [Vector3i(-1, 0, 0), Vector3i(1, 0, 0), Vector3i(0, 0, -1), Vector3i(0, 0, 1)]
    for dir in dirs:
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

func reconstruct_path(came_from: Dictionary, current: Vector3i) -> Array:
    var path: Array = [current]
    while came_from.has(current):
        current = came_from[current]
        path.push_front(current)
    return path
