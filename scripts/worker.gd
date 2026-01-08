extends Node3D
class_name Worker

enum WorkerState { IDLE, MOVING, WORKING }

const WORK_DURATION := 0.5
const IDLE_PAUSE := 0.5
const DEFAULT_SPEED := 4.0
const WANDER_WAIT_MIN := 3.0
const WANDER_WAIT_MAX := 5.0
const STAIR_BLOCK_ID := 100

var state: WorkerState = WorkerState.IDLE
var current_task_id := -1
var target_pos := Vector3.ZERO
var move_speed := DEFAULT_SPEED
var path: Array = []
var path_index := 0
var work_timer := 0.0
var idle_timer := 0.0
var wander_wait := 0.0
var rng := RandomNumberGenerator.new()

var mesh_instance: MeshInstance3D
var mat_idle: StandardMaterial3D
var mat_moving: StandardMaterial3D
var mat_working: StandardMaterial3D

func _ready() -> void:
    rng.seed = hash(Vector3(position.x, position.y, position.z))
    wander_wait = rng.randf_range(WANDER_WAIT_MIN, WANDER_WAIT_MAX)

    mesh_instance = MeshInstance3D.new()
    var box := BoxMesh.new()
    box.size = Vector3(0.5, 0.8, 0.5)
    mesh_instance.mesh = box
    mesh_instance.position.y = -0.1
    add_child(mesh_instance)

    mat_idle = StandardMaterial3D.new()
    mat_idle.albedo_color = Color(0.2, 0.8, 0.2)
    mat_moving = StandardMaterial3D.new()
    mat_moving.albedo_color = Color(1.0, 0.8, 0.2)
    mat_working = StandardMaterial3D.new()
    mat_working.albedo_color = Color(1.0, 0.5, 0.0)

    mesh_instance.material_override = mat_idle

func set_state(new_state: WorkerState) -> void:
    state = new_state
    match state:
        WorkerState.IDLE:
            mesh_instance.material_override = mat_idle
        WorkerState.MOVING:
            mesh_instance.material_override = mat_moving
        WorkerState.WORKING:
            mesh_instance.material_override = mat_working

func get_block_coord() -> Vector3i:
    return Vector3i(int(round(position.x)), int(floor(position.y)), int(round(position.z)))

func update_worker(dt: float, world, task_queue, pathfinder) -> void:
    if idle_timer > 0.0:
        idle_timer -= dt
        return

    match state:
        WorkerState.IDLE:
            update_idle(dt, world, task_queue, pathfinder)
        WorkerState.MOVING:
            update_moving(dt)
        WorkerState.WORKING:
            update_working(dt, world, task_queue)

func update_idle(dt: float, world, task_queue, pathfinder) -> void:
    var worker_y := int(floor(position.y))
    var task = task_queue.find_nearest(TaskQueue.TaskType.DIG, position)
    if task == null:
        task = task_queue.find_nearest_stairs_at_level(position, worker_y)
    if task == null:
        task = task_queue.find_nearest(TaskQueue.TaskType.PLACE, position)

    if task != null:
        var start := get_block_coord()
        var maybe_path: Array = []
        if task.type == TaskQueue.TaskType.STAIRS:
            maybe_path = find_path_to_stairs(world, start, task.pos, pathfinder)
        else:
            maybe_path = pathfinder.find_path(world, start, task.pos)

        if maybe_path.size() > 0:
            task.status = TaskQueue.TaskStatus.IN_PROGRESS
            task.assigned_worker = self
            current_task_id = task.id
            path = maybe_path
            path_index = 0
            set_target_from_path()
            set_state(WorkerState.MOVING)
    else:
        update_wander(dt, world, pathfinder)

func set_target_from_path() -> void:
    if path_index < path.size():
        var node: Vector3i = path[path_index]
        target_pos = Vector3(node.x, node.y, node.z)

func update_moving(dt: float) -> void:
    var delta := target_pos - position
    var dist := delta.length()
    if dist < 0.15:
        position = target_pos
        path_index += 1
        if path_index >= path.size():
            path.clear()
            if current_task_id >= 0:
                set_state(WorkerState.WORKING)
                work_timer = WORK_DURATION
            else:
                set_state(WorkerState.IDLE)
                wander_wait = rng.randf_range(WANDER_WAIT_MIN, WANDER_WAIT_MAX)
            return
        set_target_from_path()
        return

    var move_dist := move_speed * dt
    if move_dist >= dist:
        position = target_pos
    else:
        position += delta.normalized() * move_dist

func update_working(dt: float, world, task_queue) -> void:
    work_timer -= dt
    if work_timer > 0.0:
        return

    if current_task_id >= 0:
        var task = task_queue.get_task(current_task_id)
        if task != null:
            match task.type:
                TaskQueue.TaskType.DIG:
                    world.set_block(task.pos.x, task.pos.y, task.pos.z, 0)
                TaskQueue.TaskType.PLACE:
                    world.set_block(task.pos.x, task.pos.y, task.pos.z, task.material)
                TaskQueue.TaskType.STAIRS:
                    world.set_block(task.pos.x, task.pos.y, task.pos.z, task.material)
            task.status = TaskQueue.TaskStatus.COMPLETED

    current_task_id = -1
    idle_timer = IDLE_PAUSE
    set_state(WorkerState.IDLE)

func update_wander(dt: float, world, pathfinder) -> void:
    if wander_wait > 0.0:
        wander_wait -= dt
        return

    var start: Vector3i = get_block_coord()
    for _i in range(8):
        var dist: int = rng.randi_range(1, 10)
        var dx: int = rng.randi_range(-dist, dist)
        var dz: int = rng.randi_range(-dist, dist)
        if dx == 0 and dz == 0:
            continue
        var x: int = start.x + dx
        var y: int = start.y
        var z: int = start.z + dz
        if not pathfinder.is_walkable(world, x, y, z):
            continue
        var goal: Vector3i = Vector3i(x, y, z)
        var found: Array = pathfinder.find_path(world, start, goal)
        if found.size() > 0:
            path = found
            path_index = 0
            set_target_from_path()
            set_state(WorkerState.MOVING)
            return

    wander_wait = rng.randf_range(WANDER_WAIT_MIN, WANDER_WAIT_MAX)

func find_path_to_stairs(world, start: Vector3i, target: Vector3i, pathfinder) -> Array:
    var candidates: Array[Vector3i] = []
    for dy in range(0, 3):
        for dx in range(-1, 2):
            for dz in range(-1, 2):
                var x: int = target.x + dx
                var y: int = target.y + dy
                var z: int = target.z + dz
                if pathfinder.is_walkable(world, x, y, z):
                    candidates.append(Vector3i(x, y, z))

    candidates.sort_custom(func(a, b):
        var da: float = a.distance_squared_to(start)
        var db: float = b.distance_squared_to(start)
        return da < db
    )

    for goal in candidates:
        var found: Array = pathfinder.find_path(world, start, goal)
        if found.size() > 0:
            return found

    return []
