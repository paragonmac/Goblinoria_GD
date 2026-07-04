extends Node3D
class_name Worker
## Worker entity that performs tasks (dig, place, stairs) and wanders when idle.

const WorkerVisualsScript = preload("res://scripts/worker_visuals.gd")

#region Enums
enum WorkerState {IDLE, MOVING, WORKING, WAITING, FALLING}
#endregion

#region Constants
const WORK_DURATION := 0.5
const IDLE_PAUSE := 0.5
const DEFAULT_SPEED := 1.3
const WANDER_WAIT_MIN := 3.0
const WANDER_WAIT_MAX := 5.0
const BUILD_DURATION := 0.6
const DIG_DURATION_DEFAULT := 8.0
const DIG_DURATION_GRASS := 1.0
const DIG_DURATION_DIRT := 1.0
const DIG_DURATION_CLAY := 2.0
const DIG_DURATION_SANDSTONE := 6.0
const DIG_DURATION_LIMESTONE := 7.0
const DIG_DURATION_GRANITE := 10.0
const DIG_DURATION_SLATE := 10.0
const DIG_DURATION_BASALT := 12.0
const DIG_DURATION_COAL := 15.0
const DIG_DURATION_IRON_ORE := 20.0
const MOVE_TARGET_EPSILON := 0.01
const ADJACENT_MANHATTAN_DISTANCE := 1
const WANDER_ATTEMPTS := 8
const WANDER_DIST_MIN := 1
const WANDER_DIST_MAX := 10
const IDLE_TASK_SEARCH_INTERVAL := 0.15
const WAITING_REPATH_INTERVAL := 0.25
const FALL_SPEED := 14.0
const FALL_TARGET_EPSILON := 0.01
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
var task_search_timer := 0.0
var waiting_repath_timer := 0.0
var fall_target_y := 0.0
var rng := RandomNumberGenerator.new()
#endregion

#region Visual Components
@export var use_animated_model := true
@export var model_path: String = WorkerVisualsScript.WORKER_MODEL_DEFAULT_PATH
@export var model_import_scale := 0.01
@export var show_debug_box := false
@export var move_anim_hint := "003"
@export var dig_anim_hint := "002"
@export var work_anim_hint := ""
@export var model_yaw_offset_degrees := 180.0
@export var debug_print_animations := false
@export var animation_speed_multiplier := 1.5
@export var moving_animation_speed_multiplier := 3.0
@export var working_animation_speed_multiplier := 1.5
@export var move_speed_multiplier := 1.0
@export var dig_duration_multiplier := 1.0

var active_work_anim: StringName = &""
var visuals = WorkerVisualsScript.new()
#endregion


#region Lifecycle
func _ready() -> void:
	rng.seed = hash(Vector3(position.x, position.y, position.z))
	wander_wait = rng.randf_range(WANDER_WAIT_MIN, WANDER_WAIT_MAX)
	move_speed = DEFAULT_SPEED * move_speed_multiplier
	visuals.setup(self, _build_visual_config())
	_apply_visual_state(true)
#endregion


#region State Management
func set_state(new_state: WorkerState) -> void:
	if state == new_state:
		return
	state = new_state
	_apply_visual_state(true)


func get_block_coord() -> Vector3i:
	return Vector3i(int(round(position.x)), int(floor(position.y)), int(round(position.z)))
#endregion


#region Update Loop
func update_worker(dt: float, world, task_queue, pathfinder) -> void:
	if _update_falling(dt, world, task_queue):
		return
	if task_search_timer > 0.0:
		task_search_timer = maxf(0.0, task_search_timer - dt)
	if waiting_repath_timer > 0.0:
		waiting_repath_timer = maxf(0.0, waiting_repath_timer - dt)
	if idle_timer > 0.0:
		idle_timer -= dt
		return

	match state:
		WorkerState.IDLE:
			update_idle(dt, world, task_queue, pathfinder)
		WorkerState.MOVING:
			update_moving(dt, world, task_queue, pathfinder)
		WorkerState.WORKING:
			update_working(dt, world, task_queue)
		WorkerState.WAITING:
			update_waiting(dt, world, task_queue, pathfinder)

func _update_falling(dt: float, world, task_queue) -> bool:
	if world == null:
		return false
	if state != WorkerState.FALLING and _has_standing_support(world):
		return false
	if state != WorkerState.FALLING:
		_begin_fall(task_queue)
	fall_target_y = _find_fall_target_y(world)
	if position.y <= fall_target_y + FALL_TARGET_EPSILON:
		position.y = fall_target_y
		_finish_fall()
		return false
	position.y = maxf(fall_target_y, position.y - FALL_SPEED * dt)
	_ensure_anim_playing_while_moving()
	return true


func _begin_fall(task_queue) -> void:
	_interrupt_current_task(task_queue)
	path.clear()
	path_index = 0
	target_pos = position
	idle_timer = 0.0
	waiting_repath_timer = 0.0
	set_state(WorkerState.FALLING)


func _finish_fall() -> void:
	path.clear()
	path_index = 0
	target_pos = position
	wander_wait = rng.randf_range(WANDER_WAIT_MIN, WANDER_WAIT_MAX)
	task_search_timer = 0.0
	idle_timer = IDLE_PAUSE
	set_state(WorkerState.IDLE)


func _interrupt_current_task(task_queue) -> void:
	if current_task_id >= 0 and task_queue != null:
		var task = task_queue.get_task(current_task_id)
		if task != null and task.status == TaskQueue.TaskStatus.IN_PROGRESS and task.assigned_worker == self:
			task.status = TaskQueue.TaskStatus.PENDING
			task.assigned_worker = null
	current_task_id = -1
	active_work_anim = &""


func _has_standing_support(world) -> bool:
	var coord: Vector3i = get_block_coord()
	return _can_stand_at(world, coord.x, coord.y, coord.z)


func _find_fall_target_y(world) -> float:
	var coord: Vector3i = get_block_coord()
	var start_y: int = clampi(coord.y, 0, world.world_size_y - 1)
	for y in range(start_y, 0, -1):
		if _can_stand_at(world, coord.x, y, coord.z):
			return _standing_y_for_coord(world, coord.x, y, coord.z)
	return 0.0


func _can_stand_at(world, x: int, y: int, z: int) -> bool:
	if not world.is_block_coord_valid(x, y, z):
		return false
	var current_block: int = world.get_block_no_generate(x, y, z)
	if _is_worker_blocking(world, current_block):
		return false
	if y <= 0:
		return true
	var below_block: int = world.get_block_no_generate(x, y - 1, z)
	return world.is_block_solid_id(below_block)


func _is_worker_blocking(world, block_id: int) -> bool:
	if world.is_ramp_block_id(block_id):
		return false
	return world.is_block_solid_id(block_id)


func _standing_y_for_coord(world, x: int, y: int, z: int) -> float:
	var block_id: int = world.get_block_no_generate(x, y, z)
	if world.is_ramp_block_id(block_id):
		return float(y) + _ramp_center_offset(block_id)
	return float(y)
#endregion


#region Idle State
func update_idle(dt: float, world, task_queue, pathfinder) -> void:
	if task_search_timer > 0.0:
		update_wander(dt, world, pathfinder)
		return
	task_search_timer = IDLE_TASK_SEARCH_INTERVAL
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
		task_search_timer = 0.0
		waiting_repath_timer = 0.0
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
		if world != null and not world.is_block_coord_valid(task.pos.x, task.pos.y, task.pos.z):
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


func update_moving(dt: float, world, task_queue, _pathfinder) -> void:
	var delta := target_pos - position
	var dist := delta.length()
	_update_facing_from_delta(delta)
	_ensure_anim_playing_while_moving()
	var move_dist := move_speed * dt
	if dist <= move_dist + MOVE_TARGET_EPSILON:
		position = target_pos
		path_index += 1
		if path_index >= path.size():
			path.clear()
			if current_task_id >= 0:
				var task = task_queue.get_task(current_task_id)
				if task != null and can_work_task(task):
					active_work_anim = _get_work_anim_for_task(task)
					set_state(WorkerState.WORKING)
					work_timer = _get_work_duration(world, task)
				else:
					set_state(WorkerState.WAITING)
					idle_timer = IDLE_PAUSE
			else:
				set_state(WorkerState.IDLE)
				wander_wait = rng.randf_range(WANDER_WAIT_MIN, WANDER_WAIT_MAX)
			return
		set_target_from_path(world)
		return

	if dist > 0.000001:
		position += (delta / dist) * move_dist


func _ramp_center_offset(block_id: int) -> float:
	match block_id:
		World.RAMP_NORTHEAST_ID, World.RAMP_NORTHWEST_ID, World.RAMP_SOUTHEAST_ID, World.RAMP_SOUTHWEST_ID:
			return 0.25
		World.INNER_SOUTHWEST_ID, World.INNER_SOUTHEAST_ID, World.INNER_NORTHWEST_ID, World.INNER_NORTHEAST_ID:
			return 0.75
		_:
			return 0.5
#endregion


#region Visuals
func _build_visual_config() -> Dictionary:
	return {
		"use_animated_model": use_animated_model,
		"model_path": model_path,
		"model_import_scale": model_import_scale,
		"show_debug_box": show_debug_box,
		"move_anim_hint": move_anim_hint,
		"dig_anim_hint": dig_anim_hint,
		"work_anim_hint": work_anim_hint,
		"model_yaw_offset_degrees": model_yaw_offset_degrees,
		"debug_print_animations": debug_print_animations,
		"animation_speed_multiplier": animation_speed_multiplier,
		"moving_animation_speed_multiplier": moving_animation_speed_multiplier,
		"working_animation_speed_multiplier": working_animation_speed_multiplier,
	}


func _visual_state_for_worker_state() -> int:
	match state:
		WorkerState.MOVING, WorkerState.FALLING:
			return WorkerVisualsScript.VisualState.MOVING
		WorkerState.WORKING:
			return WorkerVisualsScript.VisualState.WORKING
		_:
			return WorkerVisualsScript.VisualState.IDLE


func _apply_visual_state(force_restart: bool) -> void:
	visuals.apply_state(_visual_state_for_worker_state(), active_work_anim, move_speed, force_restart)


func _ensure_anim_playing_while_moving() -> void:
	if state != WorkerState.MOVING and state != WorkerState.FALLING:
		return
	visuals.ensure_moving_animation()


func _ensure_anim_playing_while_working() -> void:
	if state != WorkerState.WORKING:
		return
	visuals.ensure_working_animation(active_work_anim)


func _get_work_anim_for_task(task) -> StringName:
	return visuals.get_work_anim_for_task(task)


func _get_work_duration(world, task) -> float:
	if task == null:
		return WORK_DURATION
	match task.type:
		TaskQueue.TaskType.DIG:
			if world == null:
				return DIG_DURATION_DEFAULT * dig_duration_multiplier
			var block_id: int = world.get_block(task.pos.x, task.pos.y, task.pos.z)
			return _get_dig_duration_for_block_id(block_id) * dig_duration_multiplier
		TaskQueue.TaskType.PLACE, TaskQueue.TaskType.STAIRS:
			return BUILD_DURATION
		_:
			return WORK_DURATION


func _get_dig_duration_for_block_id(block_id: int) -> float:
	if World.RAMP_BLOCK_IDS.has(block_id):
		return DIG_DURATION_SANDSTONE
	match block_id:
		World.BLOCK_ID_GRASS:
			return DIG_DURATION_GRASS
		World.BLOCK_ID_DIRT:
			return DIG_DURATION_DIRT
		World.BLOCK_ID_CLAY:
			return DIG_DURATION_CLAY
		World.BLOCK_ID_SANDSTONE:
			return DIG_DURATION_SANDSTONE
		World.BLOCK_ID_LIMESTONE:
			return DIG_DURATION_LIMESTONE
		World.BLOCK_ID_BASALT:
			return DIG_DURATION_BASALT
		World.BLOCK_ID_SLATE:
			return DIG_DURATION_SLATE
		World.BLOCK_ID_IRON_ORE:
			return DIG_DURATION_IRON_ORE
		World.BLOCK_ID_COAL:
			return DIG_DURATION_COAL
		World.BLOCK_ID_GRANITE:
			return DIG_DURATION_GRANITE
		_:
			return DIG_DURATION_DEFAULT


func _update_facing_from_delta(delta: Vector3) -> void:
	visuals.update_facing_from_delta(delta)
#endregion


#region Working State
func update_working(dt: float, world, task_queue) -> void:
	_ensure_anim_playing_while_working()
	work_timer -= dt
	if work_timer > 0.0:
		return

	if current_task_id >= 0:
		var task = task_queue.get_task(current_task_id)
		if task != null:
			match task.type:
				TaskQueue.TaskType.DIG:
					var old_block: int = world.get_block(task.pos.x, task.pos.y, task.pos.z)
					var drop_id: int = world.block_registry.get_drop(old_block)
					if drop_id > 0:
						world.add_to_inventory(drop_id)
					world.set_block(task.pos.x, task.pos.y, task.pos.z, World.BLOCK_ID_AIR)
				TaskQueue.TaskType.PLACE:
					if not world.remove_from_inventory(task.material):
						task.status = TaskQueue.TaskStatus.PENDING
						task.assigned_worker = null
						current_task_id = -1
						active_work_anim = &""
						idle_timer = IDLE_PAUSE
						set_state(WorkerState.IDLE)
						return
					world.set_block(task.pos.x, task.pos.y, task.pos.z, task.material)
				TaskQueue.TaskType.STAIRS:
					world.set_block(task.pos.x, task.pos.y, task.pos.z, task.material)
			task.status = TaskQueue.TaskStatus.COMPLETED
			if task.type == TaskQueue.TaskType.DIG:
				world.reassess_waiting_tasks()

	current_task_id = -1
	active_work_anim = &""
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
	if waiting_repath_timer > 0.0:
		return
	waiting_repath_timer = WAITING_REPATH_INTERVAL

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
		waiting_repath_timer = 0.0
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
		if not world.is_block_coord_valid(x, y, z):
			continue
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
