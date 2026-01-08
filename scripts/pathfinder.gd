extends RefCounted
class_name Pathfinder

const STAIR_BLOCK_ID := 100

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
            if is_walkable(world, nx, ny, nz) and not is_blocking(head_block):
                neighbors.append(Vector3i(nx, ny, nz))

    for dir in dirs:
        var nx: int = x + dir.x
        var nz: int = z + dir.y
        var ny: int = y - 1
        if ny >= 0 and is_walkable(world, nx, ny, nz):
            neighbors.append(Vector3i(nx, ny, nz))

    return neighbors

func heuristic(a: Vector3i, b: Vector3i) -> int:
    return abs(a.x - b.x) + abs(a.y - b.y) + abs(a.z - b.z)

func find_path(world, start: Vector3i, goal: Vector3i) -> Array:
    var open_set: Array[Vector3i] = []
    var came_from: Dictionary = {}
    var g_score: Dictionary = {}
    var f_score: Dictionary = {}

    g_score[start] = 0
    f_score[start] = heuristic(start, goal)
    open_set.append(start)

    var max_iterations: int = 10000
    var iterations: int = 0

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
            return reconstruct_path(came_from, current)
        if abs(current.x - goal.x) <= 1 and abs(current.y - goal.y) <= 1 and abs(current.z - goal.z) <= 1:
            return reconstruct_path(came_from, current)

        open_set.erase(current)
        for neighbor: Vector3i in get_neighbors(world, current):
            var tentative_g: float = float(g_score.get(current, INF)) + 1.0
            if tentative_g < float(g_score.get(neighbor, INF)):
                came_from[neighbor] = current
                g_score[neighbor] = tentative_g
                f_score[neighbor] = tentative_g + heuristic(neighbor, goal)
                if not open_set.has(neighbor):
                    open_set.append(neighbor)

    return []

func reconstruct_path(came_from: Dictionary, current: Vector3i) -> Array:
    var path: Array = [current]
    while came_from.has(current):
        current = came_from[current]
        path.push_front(current)
    return path
