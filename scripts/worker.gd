extends Node3D
class_name Worker
## Worker entity that performs tasks (dig, place, stairs) and wanders when idle.

#region Enums
enum WorkerState {IDLE, MOVING, WORKING, WAITING}
#endregion

#region Constants
const WORK_DURATION := 0.5
const IDLE_PAUSE := 0.5
const DEFAULT_SPEED := 4.0
const WANDER_WAIT_MIN := 3.0
const WANDER_WAIT_MAX := 5.0
const WORKER_BOX_SIZE := Vector3(0.5, 0.8, 0.5)
const WORKER_BOX_Y_OFFSET := -0.1
const SHADOW_SIZE := Vector2(0.9, 0.9)
const SHADOW_Y_OFFSET := -0.48
const SHADOW_COLOR := Color(0.0, 0.0, 0.0, 0.35)
const IDLE_COLOR := Color(0.2, 0.8, 0.2)
const MOVING_COLOR := Color(1.0, 0.8, 0.2)
const WORKING_COLOR := Color(1.0, 0.5, 0.0)
const MOVE_TARGET_EPSILON := 0.15
const ADJACENT_MANHATTAN_DISTANCE := 1
const WANDER_ATTEMPTS := 8
const WANDER_DIST_MIN := 1
const WANDER_DIST_MAX := 10
#endregion

#region State
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
#endregion

#region Visual Components
var mesh_instance: MeshInstance3D
var mat_idle: StandardMaterial3D
var mat_moving: StandardMaterial3D
var mat_working: StandardMaterial3D
var shadow_instance: MeshInstance3D
var shadow_material: StandardMaterial3D
#endregion


#region Lifecycle
func _ready() -> void:
	rng.seed = hash(Vector3(position.x, position.y, position.z))
	wander_wait = rng.randf_range(WANDER_WAIT_MIN, WANDER_WAIT_MAX)

	mesh_instance = MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = WORKER_BOX_SIZE
	mesh_instance.mesh = box
	mesh_instance.position.y = WORKER_BOX_Y_OFFSET
	add_child(mesh_instance)

	shadow_instance = MeshInstance3D.new()
	var shadow_mesh := PlaneMesh.new()
	shadow_mesh.size = SHADOW_SIZE
	shadow_instance.mesh = shadow_mesh
	shadow_instance.position = Vector3(0.0, SHADOW_Y_OFFSET, 0.0)
	shadow_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	shadow_material = StandardMaterial3D.new()
	shadow_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	shadow_material.cull_mode = BaseMaterial3D.CULL_DISABLED
	shadow_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	shadow_material.albedo_color = SHADOW_COLOR
	shadow_instance.material_override = shadow_material
	add_child(shadow_instance)

	mat_idle = StandardMaterial3D.new()
	mat_idle.albedo_color = IDLE_COLOR
	mat_moving = StandardMaterial3D.new()
	mat_moving.albedo_color = MOVING_COLOR
	mat_working = StandardMaterial3D.new()
	mat_working.albedo_color = WORKING_COLOR

	mesh_instance.material_override = mat_idle
#endregion


#region State Management
func set_state(new_state: WorkerState) -> void:
	state = new_state
	match state:
		WorkerState.IDLE:
			mesh_instance.material_override = mat_idle
		WorkerState.MOVING:
			mesh_instance.material_override = mat_moving
		WorkerState.WORKING:
			mesh_instance.material_override = mat_working
		WorkerState.WAITING:
			mesh_instance.material_override = mat_idle


func get_block_coord() -> Vector3i:
	return Vector3i(int(round(position.x)), int(floor(position.y)), int(round(position.z)))
#endregion


#region Update Loop
func update_worker(dt: float, world, task_queue, pathfinder) -> void:
	if idle_timer > 0.0:
		idle_timer -= dt
		return

	match state:
		WorkerState.IDLE:
			update_idle(dt, world, task_queue, pathfinder)
		WorkerState.MOVING:
			update_moving(dt, world, task_queue)
		WorkerState.WORKING:
			update_working(dt, world, task_queue)
		WorkerState.WAITING:
			update_waiting(dt, world, task_queue, pathfinder)
#endregion


#region Idle State
func update_idle(dt: float, world, task_queue, pathfinder) -> void:
	var result: Dictionary = find_pathable_task(TaskQueue.TaskType.DIG, world, task_queue, pathfinder)
	if result.is_empty():
		result = find_pathable_task(TaskQueue.TaskType.STAIRS, world, task_queue, pathfinder)
	if result.is_empty():
		result = find_pathable_task(TaskQueue.TaskType.PLACE, world, task_queue, pathfinder)

	if not result.is_empty():
		var task = result["task"]
		var maybe_path: Array = result["path"]
		task.status = TaskQueue.TaskStatus.IN_PROGRESS
		task.assigned_worker = self
		current_task_id = task.id
		path = maybe_path
		path_index = 0
		set_target_from_path(world)
		set_state(WorkerState.MOVING)
		return

	update_wander(dt, world, pathfinder)
#endregion


#region Task Discovery
func find_pathable_task(task_type: int, world, task_queue, pathfinder) -> Dictionary:
	var candidates: Array = []
	for task in task_queue.tasks:
		if task.status != TaskQueue.TaskStatus.PENDING:
			continue
		if task.type != task_type:
			continue
		var dx: float = float(task.pos.x) - position.x
		var dy: float = float(task.pos.y) - position.y
		var dz: float = float(task.pos.z) - position.z
		var dist_sq: float = dx * dx + dy * dy + dz * dz
		candidates.append({"task": task, "dist": dist_sq})

	candidates.sort_custom(func(a, b):
		return a["dist"] < b["dist"]
	)

	var start: Vector3i = get_block_coord()
	for entry in candidates:
		var task = entry["task"]
		var maybe_path: Array = []
		if task.type == TaskQueue.TaskType.STAIRS:
			maybe_path = find_path_to_stairs(world, start, task.pos, pathfinder)
		elif task.type == TaskQueue.TaskType.DIG:
			maybe_path = pathfinder.find_path_to_adjacent_on_level(world, start, task.pos, task.pos.y)
			if maybe_path.is_empty() and task.pos.y == start.y:
				maybe_path = pathfinder.find_path(world, start, task.pos, false, true)
		else:
			maybe_path = pathfinder.find_path_to_adjacent_on_level(world, start, task.pos, task.pos.y)
		if maybe_path.size() > 0:
			return {"task": task, "path": maybe_path}

	return {}


func can_work_task(task) -> bool:
	if task.type == TaskQueue.TaskType.DIG or task.type == TaskQueue.TaskType.PLACE:
		var worker_pos := get_block_coord()
		if worker_pos.y != task.pos.y:
			return false
		var dx: int = abs(worker_pos.x - task.pos.x)
		var dz: int = abs(worker_pos.z - task.pos.z)
		return dx + dz == ADJACENT_MANHATTAN_DISTANCE
	return true
#endregion


#region Movement
func set_target_from_path(world) -> void:
	if path_index < path.size():
		var node: Vector3i = path[path_index]
		target_pos = Vector3(node.x, node.y, node.z)
		if world != null:
			var block_id: int = world.get_block(node.x, node.y, node.z)
			if world.is_ramp_block_id(block_id):
				target_pos.y += _ramp_center_offset(block_id)


func update_moving(dt: float, world, task_queue) -> void:
	var delta := target_pos - position
	var dist := delta.length()
	if dist < MOVE_TARGET_EPSILON:
		position = target_pos
		path_index += 1
		if path_index >= path.size():
			path.clear()
			if current_task_id >= 0:
				var task = task_queue.get_task(current_task_id)
				if task != null and can_work_task(task):
					set_state(WorkerState.WORKING)
					work_timer = WORK_DURATION
				else:
					set_state(WorkerState.WAITING)
					idle_timer = IDLE_PAUSE
			else:
				set_state(WorkerState.IDLE)
				wander_wait = rng.randf_range(WANDER_WAIT_MIN, WANDER_WAIT_MAX)
			return
		set_target_from_path(world)
		return

	var move_dist := move_speed * dt
	if move_dist >= dist:
		position = target_pos
	else:
		position += delta.normalized() * move_dist

func _ramp_center_offset(block_id: int) -> float:
	match block_id:
		World.RAMP_NORTHEAST_ID, World.RAMP_NORTHWEST_ID, World.RAMP_SOUTHEAST_ID, World.RAMP_SOUTHWEST_ID:
			return 0.25
		World.INNER_SOUTHWEST_ID, World.INNER_SOUTHEAST_ID, World.INNER_NORTHWEST_ID, World.INNER_NORTHEAST_ID:
			return 0.75
		_:
			return 0.5
#endregion


#region Working State
func update_working(dt: float, world, task_queue) -> void:
	work_timer -= dt
	if work_timer > 0.0:
		return

	if current_task_id >= 0:
		var task = task_queue.get_task(current_task_id)
		if task != null:
			match task.type:
				TaskQueue.TaskType.DIG:
					world.set_block(task.pos.x, task.pos.y, task.pos.z, World.BLOCK_ID_AIR)
				TaskQueue.TaskType.PLACE:
					world.set_block(task.pos.x, task.pos.y, task.pos.z, task.material)
				TaskQueue.TaskType.STAIRS:
					world.set_block(task.pos.x, task.pos.y, task.pos.z, task.material)
			task.status = TaskQueue.TaskStatus.COMPLETED
			if task.type == TaskQueue.TaskType.DIG:
				world.reassess_waiting_tasks()

	current_task_id = -1
	idle_timer = IDLE_PAUSE
	set_state(WorkerState.IDLE)
#endregion


#region Waiting State
func update_waiting(_dt: float, world, task_queue, pathfinder) -> void:
	if current_task_id < 0:
		set_state(WorkerState.IDLE)
		return

	var task = task_queue.get_task(current_task_id)
	if task == null or task.status == TaskQueue.TaskStatus.COMPLETED:
		current_task_id = -1
		set_state(WorkerState.IDLE)
		return

	var start: Vector3i = get_block_coord()
	var maybe_path: Array = []
	if task.type == TaskQueue.TaskType.STAIRS:
		maybe_path = find_path_to_stairs(world, start, task.pos, pathfinder)
	elif task.type == TaskQueue.TaskType.DIG:
		maybe_path = pathfinder.find_path_to_adjacent_on_level(world, start, task.pos, task.pos.y)
		if maybe_path.is_empty() and task.pos.y == start.y:
			maybe_path = pathfinder.find_path(world, start, task.pos, false, true)
	else:
		maybe_path = pathfinder.find_path_to_adjacent_on_level(world, start, task.pos, task.pos.y)

	if maybe_path.size() > 0:
		path = maybe_path
		path_index = 0
		set_target_from_path(world)
		set_state(WorkerState.MOVING)
		return

	idle_timer = IDLE_PAUSE
#endregion


#region Wandering
func update_wander(dt: float, world, pathfinder) -> void:
	if wander_wait > 0.0:
		wander_wait -= dt
		return

	var start: Vector3i = get_block_coord()
	for _i in range(WANDER_ATTEMPTS):
		var dist: int = rng.randi_range(WANDER_DIST_MIN, WANDER_DIST_MAX)
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
			set_target_from_path(world)
			set_state(WorkerState.MOVING)
			return

	wander_wait = rng.randf_range(WANDER_WAIT_MIN, WANDER_WAIT_MAX)
#endregion


#region Pathfinding Helpers
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
#endregion
