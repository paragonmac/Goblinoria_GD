extends Node3D
class_name Worker
## Worker entity that performs tasks (dig, place, stairs) and wanders when idle.

const WorkerVisualsScript = preload("res://scripts/worker_visuals.gd")

#region Enums
enum WorkerState {IDLE, MOVING, WORKING, WAITING, FALLING}
enum MovementIntent {NONE, TASK, WANDER, ASSIST}
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
const WAITING_REPATH_INTERVAL := 2.5
const FALL_SPEED := 14.0
const FALL_TARGET_EPSILON := 0.01
const RESCUE_MIN_WALKABLE_Y := Pathfinder.MIN_WALKABLE_Y
const DIG_OCCUPIED_RETRY_INTERVAL := 0.25
const FAILED_TASK_SEARCH_INTERVAL := 2.5
const ASSIST_WAIT_RETRY_INTERVAL := 0.25
const WORKER_PATH_SEARCH_MAX_ITERATIONS := Pathfinder.TASK_SEARCH_MAX_ITERATIONS
const ASSIST_PATH_SEARCH_MAX_ITERATIONS := Pathfinder.TASK_SEARCH_MAX_ITERATIONS
#endregion

#region State
var state: WorkerState = WorkerState.IDLE
var current_task_id := -1
var target_pos := Vector3.ZERO
var move_speed := DEFAULT_SPEED
var path: Array = []
var path_index := 0
var path_segment_validated := false
var work_timer := 0.0
var idle_timer := 0.0
var wander_wait := 0.0
var task_search_timer := 0.0
var waiting_repath_timer := 0.0
var fall_target_y := 0.0
var rng := RandomNumberGenerator.new()
var worker_id := 0
var movement_intent: MovementIntent = MovementIntent.NONE
var assist_task_id := -1
var assist_goal := Vector3i.ZERO
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
	if position.y < float(RESCUE_MIN_WALKABLE_Y):
		_recover_to_surface(world, task_queue, "below_walkable_floor")
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
			update_working(dt, world, task_queue, pathfinder)
		WorkerState.WAITING:
			update_waiting(dt, world, task_queue, pathfinder)

func _update_falling(dt: float, world, task_queue) -> bool:
	if world == null:
		return false
	if state == WorkerState.MOVING and path_segment_validated:
		return false
	if state != WorkerState.FALLING and _has_standing_support(world):
		return false
	if state != WorkerState.FALLING and _has_supported_path_segment(world):
		return false
	if state != WorkerState.FALLING:
		_trace(world, "fall_started", _current_task(task_queue))
		_begin_fall(task_queue)
	fall_target_y = _find_fall_target_y(world)
	if fall_target_y < float(RESCUE_MIN_WALKABLE_Y) and _recover_to_surface(world, task_queue, "fall_target_below_walkable_floor"):
		return false
	if position.y <= fall_target_y + FALL_TARGET_EPSILON:
		position.y = fall_target_y
		_finish_fall()
		_trace(world, "fall_completed", null, "landed_y=%d" % get_block_coord().y)
		return false
	position.y = maxf(fall_target_y, position.y - FALL_SPEED * dt)
	_ensure_anim_playing_while_moving()
	return true


func _begin_fall(task_queue) -> void:
	_interrupt_current_task(task_queue)
	if task_queue != null:
		task_queue.clear_assist_waiter(self)
	path.clear()
	path_index = 0
	path_segment_validated = false
	target_pos = position
	movement_intent = MovementIntent.NONE
	assist_task_id = -1
	idle_timer = 0.0
	waiting_repath_timer = 0.0
	set_state(WorkerState.FALLING)


func _finish_fall() -> void:
	path.clear()
	path_index = 0
	path_segment_validated = false
	target_pos = position
	movement_intent = MovementIntent.NONE
	assist_task_id = -1
	wander_wait = rng.randf_range(WANDER_WAIT_MIN, WANDER_WAIT_MAX)
	task_search_timer = 0.0
	idle_timer = IDLE_PAUSE
	set_state(WorkerState.IDLE)


func _recover_to_surface(world, task_queue, reason: String) -> bool:
	if world == null or not world.has_method("find_surface_y"):
		return false
	var old_coord := get_block_coord()
	_interrupt_current_task(task_queue)
	if task_queue != null:
		task_queue.clear_assist_waiter(self)
	var safe_x: int = old_coord.x
	var safe_z: int = old_coord.z
	if world.has_method("is_block_xz_valid") \
		and world.has_method("clamp_block_xz") \
		and not world.is_block_xz_valid(safe_x, safe_z):
		var clamped: Vector3 = world.clamp_block_xz(Vector3(float(safe_x), 0.0, float(safe_z)))
		safe_x = int(clamped.x)
		safe_z = int(clamped.z)
	var surface_y: int = int(world.find_surface_y(safe_x, safe_z))
	position = Vector3(float(safe_x), float(surface_y) + 1.0, float(safe_z))
	path.clear()
	path_index = 0
	path_segment_validated = false
	target_pos = position
	movement_intent = MovementIntent.NONE
	assist_task_id = -1
	wander_wait = rng.randf_range(WANDER_WAIT_MIN, WANDER_WAIT_MAX)
	task_search_timer = 0.0
	waiting_repath_timer = 0.0
	idle_timer = IDLE_PAUSE
	set_state(WorkerState.IDLE)
	_trace(world, "worker_rescued", null, "reason=%s from=%s to=%s" % [
		reason,
		old_coord,
		get_block_coord(),
	])
	return true


func _interrupt_current_task(task_queue) -> void:
	if task_queue != null:
		task_queue.clear_assist_waiter(self)
	if current_task_id >= 0 and task_queue != null:
		var task = task_queue.get_task(current_task_id)
		if task != null and task.status == TaskQueue.TaskStatus.IN_PROGRESS and task.assigned_worker == self:
			task.status = TaskQueue.TaskStatus.PENDING
			task.accessibility = TaskQueue.TaskAccessibility.UNKNOWN
			task.assigned_worker = null
	current_task_id = -1
	active_work_anim = &""
	if movement_intent == MovementIntent.TASK:
		movement_intent = MovementIntent.NONE


func _has_standing_support(world) -> bool:
	var coord: Vector3i = get_block_coord()
	return _can_stand_at(world, coord.x, coord.y, coord.z)


func _has_supported_path_segment(world) -> bool:
	if state != WorkerState.MOVING:
		return false
	if path_index <= 0 or path_index >= path.size():
		return false
	var from_node: Vector3i = path[path_index - 1]
	var to_node: Vector3i = path[path_index]
	if not _can_stand_at(world, from_node.x, from_node.y, from_node.z) \
		or not _can_stand_at(world, to_node.x, to_node.y, to_node.z):
		return false
	if world.get("pathfinder") == null:
		return true
	return world.pathfinder.can_traverse(world, from_node, to_node)


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
	if y <= 0:
		return true
	var current_block: int = world.get_block_no_generate(x, y, z)
	if _is_worker_blocking(world, current_block):
		return false
	var below_block: int = world.get_block_no_generate(x, y - 1, z)
	if world.is_ramp_block_id(below_block):
		return false
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
		if not _has_pending_tasks(task_queue):
			update_wander(dt, world, pathfinder)
		return
	task_search_timer = IDLE_TASK_SEARCH_INTERVAL

	if _has_pending_tasks(task_queue):
		if world != null \
			and world.task_manager != null \
			and world.task_manager.has_assignable_pending_task():
			return
		if _move_to_work_front(world, task_queue, pathfinder):
			return
		task_search_timer = FAILED_TASK_SEARCH_INTERVAL
		return

	update_wander(dt, world, pathfinder)
#endregion


#region Task Assignment
func assign_task_with_path(
	world,
	task_queue,
	task,
	maybe_path: Array,
	search_ms: float,
	trace_event: String = "task_assigned",
	trace_details: String = ""
) -> void:
	task.status = TaskQueue.TaskStatus.IN_PROGRESS
	task.accessibility = TaskQueue.TaskAccessibility.REACHABLE
	task.assigned_worker = self
	current_task_id = task.id
	task_queue.clear_assist_waiter(self)
	path = maybe_path.duplicate()
	path_index = 0
	movement_intent = MovementIntent.TASK
	assist_task_id = -1
	task_search_timer = 0.0
	waiting_repath_timer = 0.0
	set_target_from_path(world)
	set_state(WorkerState.MOVING)
	var details := "path_length=%d search_ms=%.3f" % [
		path.size(),
		search_ms,
	]
	if not trace_details.is_empty():
		details += " " + trace_details
	_trace(world, trace_event, task, details)


func release_task_for_transfer(task, world) -> bool:
	if task == null or current_task_id != task.id:
		return false
	if state == WorkerState.WORKING:
		return false
	current_task_id = -1
	active_work_anim = &""
	if state == WorkerState.MOVING and movement_intent == MovementIntent.TASK:
		movement_intent = MovementIntent.WANDER
	else:
		path.clear()
		path_index = 0
		path_segment_validated = false
		target_pos = position
		movement_intent = MovementIntent.NONE
		set_state(WorkerState.IDLE)
	_trace(world, "task_transferred_out", task)
	return true
#endregion


#region Task Discovery
func _has_pending_tasks(task_queue) -> bool:
	if task_queue == null:
		return false
	for task in task_queue.tasks:
		if task.status == TaskQueue.TaskStatus.PENDING:
			return true
	return false


func _move_to_work_front(world, task_queue, pathfinder) -> bool:
	if world == null \
		or world.task_manager == null \
		or task_queue == null \
		or pathfinder == null:
		return false
	var start: Vector3i = get_block_coord()
	var candidates: Array = []
	for task in task_queue.tasks:
		if task.status != TaskQueue.TaskStatus.IN_PROGRESS:
			continue
		if task.assigned_worker == null or task.assigned_worker == self:
			continue
		if task.type != TaskQueue.TaskType.DIG and task.type != TaskQueue.TaskType.STAIRS:
			continue
		var work_level: int = _work_level_for_task(task.type, task.pos, world)
		for pos in pathfinder.get_walkable_adjacent_on_level(world, task.pos, work_level):
			if not _can_work_task_from_coord(task.type, pos, task.pos, world, pathfinder):
				continue
			if pos == start:
				continue
			candidates.append({
				"pos": pos,
				"task": task,
				"dist": pos.distance_squared_to(start),
			})

	candidates.sort_custom(func(a, b):
		return a["dist"] < b["dist"]
	)
	return world.task_manager.request_assist_path(self, candidates)


func start_assist_path(
	world,
	task,
	found_path: Array,
	goal: Vector3i,
	search_ms: float,
	snapshot_ms: float,
	queue_wait_ms: float
) -> void:
	if world == null or task == null or found_path.is_empty():
		return
	if world.task_queue != null:
		world.task_queue.clear_assist_waiter(self)
	path = found_path.duplicate()
	path_index = 0
	movement_intent = MovementIntent.ASSIST
	assist_task_id = task.id
	assist_goal = goal
	task_search_timer = FAILED_TASK_SEARCH_INTERVAL
	waiting_repath_timer = 0.0
	set_target_from_path(world)
	set_state(WorkerState.MOVING)
	_trace(world, "assist_started", task, "goal=%s path_length=%d snapshot_ms=%.3f queue_wait_ms=%.3f search_ms=%.3f" % [
		goal,
		path.size(),
		snapshot_ms,
		queue_wait_ms,
		search_ms,
	])


func can_work_task(task, world = null, pathfinder = null) -> bool:
	if task.type == TaskQueue.TaskType.DIG or task.type == TaskQueue.TaskType.PLACE:
		var worker_pos := get_block_coord()
		return _can_work_task_from_coord(task.type, worker_pos, task.pos, world, pathfinder)
	return true
#endregion


#region Movement
func set_target_from_path(world) -> void:
	path_segment_validated = false
	if path_index < path.size():
		var node: Vector3i = path[path_index]
		target_pos = Vector3(node.x, node.y, node.z)
		if world != null:
			var block_id: int = world.get_block_no_generate(node.x, node.y, node.z)
			if world.is_ramp_block_id(block_id):
				target_pos.y += _ramp_center_offset(block_id)


func update_moving(dt: float, world, task_queue, pathfinder) -> void:
	if not path_segment_validated:
		if not _validate_next_path_node(world, task_queue, pathfinder):
			return
		path_segment_validated = true
	var delta := target_pos - position
	var dist := delta.length()
	_update_facing_from_delta(delta)
	_ensure_anim_playing_while_moving()
	var move_dist := move_speed * dt
	if dist <= move_dist + MOVE_TARGET_EPSILON:
		position = target_pos
		path_index += 1
		var movement_task = _current_movement_task(task_queue)
		var movement_kind := _movement_intent_name()
		_trace(world, "movement_step", movement_task, "%s node=%d/%d" % [
			movement_kind,
			path_index,
			path.size(),
		])
		if path_index >= path.size():
			path.clear()
			path_segment_validated = false
			if current_task_id >= 0:
				var task = task_queue.get_task(current_task_id)
				if task != null and can_work_task(task, world, pathfinder):
					movement_intent = MovementIntent.NONE
					active_work_anim = _get_work_anim_for_task(task)
					set_state(WorkerState.WORKING)
					work_timer = _get_work_duration(world, task)
					_trace_work_duration_resolved(world, task, work_timer)
					_trace(world, "work_started", task, "duration_sec=%.2f" % work_timer)
				else:
					movement_intent = MovementIntent.NONE
					set_state(WorkerState.WAITING)
					idle_timer = IDLE_PAUSE
					waiting_repath_timer = WAITING_REPATH_INTERVAL
					_trace(world, "task_waiting", task, "work position invalid")
			elif movement_intent == MovementIntent.ASSIST:
				var assist_task = _assist_task(task_queue)
				var goal := assist_goal
				movement_intent = MovementIntent.NONE
				assist_task_id = -1
				set_state(WorkerState.IDLE)
				wander_wait = 0.0
				task_search_timer = 0.0
				if world != null \
					and world.task_manager != null \
					and world.task_manager.transfer_task_to_arrived_worker(assist_task, self):
					return
				if task_queue != null:
					task_queue.register_assist_waiter(self)
				_trace(world, "assist_arrived", assist_task, "goal=%s" % goal)
				if _has_pending_tasks(task_queue):
					task_search_timer = ASSIST_WAIT_RETRY_INTERVAL
					_trace(world, "assist_waiting", assist_task, "no pathable task from staging")
				elif task_queue != null:
					task_queue.clear_assist_waiter(self)
			else:
				movement_intent = MovementIntent.NONE
				set_state(WorkerState.IDLE)
				wander_wait = rng.randf_range(WANDER_WAIT_MIN, WANDER_WAIT_MAX)
				_trace(world, "wander_completed")
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


func _trace_work_duration_resolved(world, task, duration: float) -> void:
	if task == null or task.type != TaskQueue.TaskType.DIG:
		return
	var block_id := -1
	var block_name := "unknown"
	if world != null:
		block_id = world.get_block(task.pos.x, task.pos.y, task.pos.z)
		block_name = world.get_block_name(block_id)
	_trace(world, "dig_duration_resolved", task, "block_id=%d block_name=%s duration_sec=%.2f multiplier=%.2f" % [
		block_id,
		block_name,
		duration,
		dig_duration_multiplier,
	])


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
func update_working(dt: float, world, task_queue, pathfinder) -> void:
	_ensure_anim_playing_while_working()
	work_timer -= dt
	if work_timer > 0.0:
		return

	if current_task_id >= 0:
		var task = task_queue.get_task(current_task_id)
		if task != null:
			if task.type == TaskQueue.TaskType.DIG:
				var blocking_workers: Array = world.get_workers_blocking_dig(task.pos)
				if not blocking_workers.is_empty():
					work_timer = DIG_OCCUPIED_RETRY_INTERVAL
					_trace(world, "dig_deferred_occupied", task, "blocking_workers=%s" % _worker_ids(blocking_workers))
					return
			match task.type:
				TaskQueue.TaskType.DIG:
					var old_block: int = world.get_block(task.pos.x, task.pos.y, task.pos.z)
					var drop_id: int = world.block_registry.get_drop(old_block)
					if drop_id > 0:
						world.add_to_inventory(drop_id)
					world.set_block(task.pos.x, task.pos.y, task.pos.z, World.BLOCK_ID_AIR)
				TaskQueue.TaskType.PLACE:
					if not world.remove_from_inventory(task.material):
						_trace(world, "task_deferred", task, "material unavailable")
						task.status = TaskQueue.TaskStatus.PENDING
						task.accessibility = TaskQueue.TaskAccessibility.UNKNOWN
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
			_trace(world, "task_completed", task)
			if task.type == TaskQueue.TaskType.DIG:
				world.reassess_waiting_tasks()

	current_task_id = -1
	active_work_anim = &""
	set_state(WorkerState.IDLE)
	idle_timer = IDLE_PAUSE
#endregion


#region Waiting State
func update_waiting(_dt: float, world, task_queue, _pathfinder) -> void:
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

	# SEE-ADR-005: Waiting workers release tasks so the changed world can be re-auctioned.
	_trace(world, "task_released_for_repath", task, "retry through assignment auction")
	task.status = TaskQueue.TaskStatus.PENDING
	task.accessibility = TaskQueue.TaskAccessibility.UNKNOWN
	task.unreachable_workers.clear()
	task.assigned_worker = null
	current_task_id = -1
	path.clear()
	path_index = 0
	path_segment_validated = false
	movement_intent = MovementIntent.NONE
	assist_task_id = -1
	idle_timer = IDLE_PAUSE
	set_state(WorkerState.IDLE)
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
			if world != null and world.task_queue != null:
				world.task_queue.clear_assist_waiter(self)
			path = found
			path_index = 0
			movement_intent = MovementIntent.WANDER
			assist_task_id = -1
			set_target_from_path(world)
			set_state(WorkerState.MOVING)
			_trace(world, "wander_started", null, "target=%s path_length=%d" % [goal, path.size()])
			return

	wander_wait = rng.randf_range(WANDER_WAIT_MIN, WANDER_WAIT_MAX)
#endregion


#region Pathfinding Helpers
func find_path_to_task(
	world,
	start: Vector3i,
	task_type: int,
	target: Vector3i,
	pathfinder,
	max_iterations_cap: int = WORKER_PATH_SEARCH_MAX_ITERATIONS
) -> Array:
	if task_type == TaskQueue.TaskType.STAIRS:
		return find_path_to_stairs(world, start, target, pathfinder)

	return find_path_to_work_position(world, start, task_type, target, pathfinder, max_iterations_cap)


func find_path_to_work_position(
	world,
	start: Vector3i,
	task_type: int,
	target: Vector3i,
	pathfinder,
	max_iterations_cap: int
) -> Array:
	var work_positions: Array[Vector3i] = []
	var work_level: int = _work_level_for_task(task_type, target, world)
	for candidate in pathfinder.get_walkable_adjacent_on_level(world, target, work_level):
		if _can_work_task_from_coord(task_type, candidate, target, world, pathfinder):
			work_positions.append(candidate)
	if work_positions.is_empty():
		pathfinder.last_search_stats = {
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
			"reason": "no_workable_adjacent_candidates",
		}
		return []

	return pathfinder.find_path_to_any(world, start, work_positions, max_iterations_cap)


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


func _current_task(task_queue):
	if current_task_id < 0 or task_queue == null:
		return null
	return task_queue.get_task(current_task_id)


func _assist_task(task_queue):
	if assist_task_id < 0 or task_queue == null:
		return null
	return task_queue.get_task(assist_task_id)


func _current_movement_task(task_queue):
	if current_task_id >= 0:
		return _current_task(task_queue)
	if movement_intent == MovementIntent.ASSIST:
		return _assist_task(task_queue)
	return null


func _can_work_task_from_coord(task_type: int, worker_pos: Vector3i, task_pos: Vector3i, world, pathfinder) -> bool:
	# SEE-ADR-001: Normal DIG/PLACE work is same-level and cardinal-adjacent.
	if task_type != TaskQueue.TaskType.DIG and task_type != TaskQueue.TaskType.PLACE:
		return true
	if worker_pos.y != _work_level_for_task(task_type, task_pos, world):
		return false
	var dx: int = abs(worker_pos.x - task_pos.x)
	var dz: int = abs(worker_pos.z - task_pos.z)
	if dx + dz != ADJACENT_MANHATTAN_DISTANCE:
		return false
	if world == null or pathfinder == null:
		return true
	return pathfinder.can_move_same_level(world, worker_pos, task_pos)


func _work_level_for_task(_task_type: int, task_pos: Vector3i, _world = null) -> int:
	return task_pos.y


func _movement_intent_name() -> String:
	match movement_intent:
		MovementIntent.TASK:
			return "task"
		MovementIntent.ASSIST:
			return "assist"
		MovementIntent.WANDER:
			return "wander"
		_:
			return "none"


func _validate_next_path_node(world, task_queue, pathfinder) -> bool:
	if path_index < 0 or path_index >= path.size():
		return true
	var next_node: Vector3i = path[path_index]
	var current_node := get_block_coord()
	if path_index > 0:
		current_node = path[path_index - 1]
	if next_node == current_node:
		return true
	if pathfinder.is_walkable(world, next_node.x, next_node.y, next_node.z) \
		and pathfinder.can_traverse(world, current_node, next_node):
		return true

	var task = _current_task(task_queue)
	var movement_task = _current_movement_task(task_queue)
	_trace(world, "path_invalidated", movement_task, "%s from=%s next_node=%s" % [
		_movement_intent_name(),
		current_node,
		next_node,
	])
	path.clear()
	path_index = 0
	path_segment_validated = false
	if task != null:
		task.status = TaskQueue.TaskStatus.PENDING
		task.accessibility = TaskQueue.TaskAccessibility.UNKNOWN
		task.unreachable_workers.clear()
		task.assigned_worker = null
		current_task_id = -1
		movement_intent = MovementIntent.NONE
		assist_task_id = -1
		task_search_timer = IDLE_TASK_SEARCH_INTERVAL
		set_state(WorkerState.IDLE)
	else:
		if movement_intent == MovementIntent.ASSIST:
			_trace(world, "assist_interrupted", movement_task, "path invalidated")
		movement_intent = MovementIntent.NONE
		assist_task_id = -1
		wander_wait = 0.0
		task_search_timer = 0.0
		set_state(WorkerState.IDLE)
	return false


func _worker_ids(worker_list: Array) -> String:
	var ids: Array[String] = []
	for worker in worker_list:
		ids.append(str(worker.worker_id))
	return "|".join(ids)


func _trace(world, event: String, task = null, details: String = "") -> void:
	if world != null:
		world.trace_worker_event(self, event, task, details)
