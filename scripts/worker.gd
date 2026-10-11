extends Node3D
class_name Worker
## Worker entity that performs tasks (dig, place, stairs) and wanders when idle.

const WorkerVisualsScript = preload("res://scripts/worker_visuals.gd")
const TaskWorkPositionRulesScript = preload("res://scripts/task_work_position_rules.gd")
const WorkerRolesScript = preload("res://scripts/worker_roles.gd")
const WorkPrioritiesScript = preload("res://scripts/worker_work_priorities.gd")
const StairFlightScript = preload("res://scripts/stair_flight.gd")

#region Enums
enum WorkerState {IDLE, MOVING, WORKING, WAITING, FALLING, WAITING_FOR_PATH}
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
var role_id: int = WorkerRolesScript.Role.MINER
var work_priorities: Dictionary = {}
var movement_intent: MovementIntent = MovementIntent.NONE
var assist_task_id := -1
var assist_goal := Vector3i.ZERO
var carried_material_id := 0
var carried_count := 0
var carried_source_item_id := -1
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
func set_state(new_state: WorkerState, world = null) -> void:
	if state == new_state:
		return
	var previous_state := state
	state = new_state
	_apply_visual_state(true)
	if world == null:
		world = get_parent()
	if _diagnostics_enabled(world):
		world.live_diagnostics.invalidate("worker", str(worker_id), "worker_state_changed")
		world.live_diagnostics.observe("worker", str(worker_id), "worker_state_changed", {"from_state": previous_state, "to_state": state, "task_id": current_task_id, "movement_intent": movement_intent})


func get_block_coord() -> Vector3i:
	return Vector3i(int(round(position.x)), int(floor(position.y)), int(round(position.z)))


func set_role(new_role_id: int, world = null) -> bool:
	if not WorkerRolesScript.is_valid(new_role_id) or role_id == new_role_id:
		return false
	var previous_role := role_id
	role_id = new_role_id
	if world == null:
		world = get_parent()
	if _diagnostics_enabled(world):
		world.live_diagnostics.invalidate("worker", str(worker_id), "worker_role_changed")
		world.live_diagnostics.observe("worker", str(worker_id), "worker_role_changed", {"from_role": previous_role, "to_role": role_id})
	return true


func get_role_name() -> String:
	return WorkerRolesScript.display_name(role_id)


func get_role_idle_status() -> String:
	return WorkerRolesScript.idle_status(role_id)


func can_accept_task(task) -> bool:
	return task != null and get_work_priority(WorkPrioritiesScript.task_work_id(task.type)) > 0


func get_work_priority(work_id: String) -> int:
	return WorkPrioritiesScript.effective_priority(role_id, work_priorities, work_id)


func get_work_configuration() -> Dictionary:
	return WorkPrioritiesScript.effective_values(role_id, work_priorities)


func can_idle_wander() -> bool:
	return WorkerRolesScript.allows_idle_wander(role_id) and (
		get_work_priority("hauling") > 0 or get_work_priority("mining") > 0 \
		or get_work_priority("building") > 0)
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
		WorkerState.WAITING_FOR_PATH:
			pass

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
		_report_anomaly(world, "worker_fall", {"from": get_block_coord()})
		_begin_fall(world, task_queue)
	fall_target_y = _find_fall_target_y(world)
	if fall_target_y < float(RESCUE_MIN_WALKABLE_Y) and _recover_to_surface(world, task_queue, "fall_target_below_walkable_floor"):
		return false
	if position.y <= fall_target_y + FALL_TARGET_EPSILON:
		position.y = fall_target_y
		_finish_fall(world)
		_trace(world, "fall_completed", null, "landed_y=%d" % get_block_coord().y)
		return false
	position.y = maxf(fall_target_y, position.y - FALL_SPEED * dt)
	_ensure_anim_playing_while_moving()
	return true


func _begin_fall(world, task_queue) -> void:
	_interrupt_current_task(task_queue, world)
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
	set_state(WorkerState.FALLING, world)


func _finish_fall(world = null) -> void:
	path.clear()
	path_index = 0
	path_segment_validated = false
	target_pos = position
	movement_intent = MovementIntent.NONE
	assist_task_id = -1
	wander_wait = rng.randf_range(WANDER_WAIT_MIN, WANDER_WAIT_MAX)
	task_search_timer = 0.0
	idle_timer = IDLE_PAUSE
	set_state(WorkerState.IDLE, world)


func _recover_to_surface(world, task_queue, reason: String) -> bool:
	if world == null or not world.has_method("find_surface_y"):
		return false
	var old_coord := get_block_coord()
	_interrupt_current_task(task_queue, world)
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
	set_state(WorkerState.IDLE, world)
	_trace(world, "worker_rescued", null, "reason=%s from=%s to=%s" % [
		reason,
		old_coord,
		get_block_coord(),
	])
	_report_anomaly(world, "worker_rescued", {"reason": reason, "from": old_coord, "to": get_block_coord()})
	return true


func _interrupt_current_task(task_queue, world = null) -> void:
	if task_queue != null:
		task_queue.clear_assist_waiter(self)
	if current_task_id >= 0 and task_queue != null:
		var task = task_queue.get_task(current_task_id)
		if task != null and task.status == TaskQueue.TaskStatus.IN_PROGRESS and task.assigned_worker == self:
			if task.type == TaskQueue.TaskType.HAUL and world != null:
				_cancel_interrupted_haul(world, task_queue, task)
			else:
				task.status = TaskQueue.TaskStatus.PENDING
				task.accessibility = TaskQueue.TaskAccessibility.UNKNOWN
				task.assigned_worker = null
	current_task_id = -1
	active_work_anim = &""
	carried_material_id = 0
	carried_count = 0
	carried_source_item_id = -1
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
	if StairFlightScript.is_flight(current_block) \
			and world.get("pathfinder") != null \
			and not world.pathfinder.is_valid_flight_cell(world, Vector3i(x, y, z)):
		return false
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
		if not _has_pending_tasks_for_role(task_queue) and can_idle_wander():
			update_wander(dt, world, pathfinder)
		return
	task_search_timer = IDLE_TASK_SEARCH_INTERVAL

	if _has_pending_tasks_for_role(task_queue):
		if world != null \
			and world.task_manager != null \
			and world.task_manager.has_assignable_pending_task_for_worker(self):
			if _diagnostics_enabled(world):
				world.live_diagnostics.observe("worker", str(worker_id), "awaiting_assignment_auction", {"auction_task_id": world.task_manager.assignment_task_id, "pending_jobs": world.task_manager.assignment_pending_jobs.size()})
			return
		if _move_to_work_front(world, task_queue, pathfinder):
			return
		task_search_timer = FAILED_TASK_SEARCH_INTERVAL
		if _diagnostics_enabled(world):
			world.live_diagnostics.observe("worker", str(worker_id), "no_assignment_or_assist_path", {"role_id": role_id, "retry_seconds": task_search_timer})
		return

	if can_idle_wander():
		update_wander(dt, world, pathfinder)
	elif _diagnostics_enabled(world):
		world.live_diagnostics.observe("worker", str(worker_id), "role_reserve_idle", {"role_id": role_id})
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
	if not can_accept_task(task):
		if _diagnostics_enabled(world):
			world.live_diagnostics.observe("worker", str(worker_id), "assignment_role_rejected", {"task_id": task.id if task != null else -1, "role_id": role_id})
		return
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
	set_state(WorkerState.MOVING, world)
	var details := "path_length=%d search_ms=%.3f" % [
		path.size(),
		search_ms,
	]
	if not trace_details.is_empty():
		details += " " + trace_details
	_trace(world, trace_event, task, details)
	if _diagnostics_enabled(world):
		world.live_diagnostics.observe("worker", str(worker_id), trace_event, {"task_id": task.id, "path_length": path.size(), "search_ms": search_ms, "role_id": role_id})
		world.live_diagnostics.observe("task", str(task.id), trace_event, {"worker_id": worker_id, "path_length": path.size()})


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
		set_state(WorkerState.IDLE, world)
	_trace(world, "task_transferred_out", task)
	if _diagnostics_enabled(world):
		world.live_diagnostics.invalidate("worker", str(worker_id), "task_transferred_out")
		world.live_diagnostics.observe("worker", str(worker_id), "task_transferred_out", {"task_id": task.id, "movement_intent": movement_intent})
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


func _has_pending_tasks_for_role(task_queue) -> bool:
	if task_queue == null:
		return false
	for task in task_queue.tasks:
		if task.status == TaskQueue.TaskStatus.PENDING and can_accept_task(task):
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
		if not can_accept_task(task):
			continue
		if task.type != TaskQueue.TaskType.DIG and task.type != TaskQueue.TaskType.STAIRS:
			continue
		var work_positions: Array = []
		if task.type == TaskQueue.TaskType.STAIRS:
			var flight_rotation := int(task.data.get("rotation", -1)) if task.data is Dictionary else -1
			work_positions = TaskWorkPositionRulesScript.stair_work_positions(
				world,
				pathfinder,
				task.pos,
				flight_rotation,
				_stair_excluded_cells_for_task(task)
			)
		else:
			work_positions = TaskWorkPositionRulesScript.task_work_positions(
				world,
				pathfinder,
				task.pos,
				task.type
			)
		for pos in work_positions:
			var work_rotation := int(task.data.get("rotation", -1)) if task.type == TaskQueue.TaskType.STAIRS and task.data is Dictionary else -1
			if not _can_work_task_from_coord(
				task.type,
				pos,
				task.pos,
				world,
				pathfinder,
				work_rotation,
				_stair_excluded_cells_for_task(task)
			):
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
	set_state(WorkerState.MOVING, world)
	_trace(world, "assist_started", task, "goal=%s path_length=%d snapshot_ms=%.3f queue_wait_ms=%.3f search_ms=%.3f" % [
		goal,
		path.size(),
		snapshot_ms,
		queue_wait_ms,
		search_ms,
	])
	if _diagnostics_enabled(world):
		world.live_diagnostics.observe("worker", str(worker_id), "assist_started", {"task_id": task.id, "goal": goal, "path_length": path.size(), "search_ms": search_ms})


func can_work_task(task, world = null, pathfinder = null) -> bool:
	# Work settings govern the NEXT claim, never invalidate the owned job in transit.
	if not can_accept_task(task) and not (task != null and current_task_id == task.id and task.assigned_worker == self):
		return false
	if task.type == TaskQueue.TaskType.DIG or task.type == TaskQueue.TaskType.PLACE or task.type == TaskQueue.TaskType.TORCH:
		var worker_pos := get_block_coord()
		return _can_work_task_from_coord(task.type, worker_pos, task.pos, world, pathfinder)
	if task.type == TaskQueue.TaskType.STAIRS:
		return TaskWorkPositionRulesScript.can_work_stairs_from(
			world,
			pathfinder,
			get_block_coord(),
			task.pos,
			int(task.data.get("rotation", -1)) if task.data is Dictionary else -1,
			_stair_excluded_cells_for_task(task)
		)
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
					_face_task_work_target(task, world)
					set_state(WorkerState.WORKING, world)
					work_timer = _get_work_duration(world, task)
					_trace_work_duration_resolved(world, task, work_timer)
					_trace(world, "work_started", task, "duration_sec=%.2f" % work_timer)
					if _diagnostics_enabled(world):
						world.live_diagnostics.observe("worker", str(worker_id), "work_started", {"task_id": task.id, "type": task.type, "duration_seconds": work_timer})
				else:
					movement_intent = MovementIntent.NONE
					set_state(WorkerState.WAITING, world)
					idle_timer = IDLE_PAUSE
					waiting_repath_timer = WAITING_REPATH_INTERVAL
					_trace(world, "task_waiting", task, "work position invalid")
					if _diagnostics_enabled(world):
						world.live_diagnostics.observe("worker", str(worker_id), "work_position_invalid", {"task_id": current_task_id, "retry_seconds": waiting_repath_timer})
			elif movement_intent == MovementIntent.ASSIST:
				var assist_task = _assist_task(task_queue)
				var goal := assist_goal
				movement_intent = MovementIntent.NONE
				assist_task_id = -1
				set_state(WorkerState.IDLE, world)
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
				set_state(WorkerState.IDLE, world)
				wander_wait = rng.randf_range(WANDER_WAIT_MIN, WANDER_WAIT_MAX)
				_trace(world, "wander_completed")
			return
		set_target_from_path(world)
		return

	if dist > 0.000001:
		position += (delta / dist) * move_dist


func _ramp_center_offset(block_id: int) -> float:
	if StairFlightScript.is_flight(block_id):
		return 0.5 + StairFlightScript.center_offset(block_id)
	match World.ramp_shape_id(block_id):
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
		TaskQueue.TaskType.HAUL:
			return WORK_DURATION
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


func _face_task_work_target(task, world) -> void:
	if task == null:
		return
	var target := Vector3(task.pos)
	if task.type == TaskQueue.TaskType.STAIRS and bool(task.data.get("flight", false)):
		var footprint = task.data.get("footprint", [])
		if footprint is Array and not footprint.is_empty():
			var nearest: Vector3i = footprint[0]
			var nearest_distance := Vector3(nearest).distance_squared_to(position)
			for cell in footprint:
				var cell_pos: Vector3i = cell
				var distance := Vector3(cell_pos).distance_squared_to(position)
				if distance < nearest_distance:
					nearest = cell_pos
					nearest_distance = distance
			target = Vector3(nearest)
	elif task.type == TaskQueue.TaskType.HAUL:
		var stage := str(task.data.get("stage", "pickup"))
		if stage == "pickup":
			if world != null and world.item_store != null:
				var item: Dictionary = world.item_store.get_item(int(task.data.get("item_id", -1)))
				var item_pos = item.get("pos")
				if item_pos is Vector3i:
					target = Vector3(item_pos)
		else:
			var destination = task.data.get("destination")
			if destination is Vector3i:
				target = Vector3(destination)
	visuals.face_point(target)
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
				# A pending DIG can become stale when a player stair or its
				# protected support is placed before the worker reaches it. Never
				# mutate protected infrastructure or emit a mining drop here.
				var stair_dig_reject_reason := ""
				if world != null and world.has_method("stair_dig_reject_reason"):
					stair_dig_reject_reason = world.stair_dig_reject_reason(task.pos)
				if not stair_dig_reject_reason.is_empty():
					task_queue.remove_task(task)
					_trace(world, "task_cancelled", task, "reason=%s" % stair_dig_reject_reason)
					current_task_id = -1
					active_work_anim = &""
					set_state(WorkerState.IDLE, world)
					idle_timer = IDLE_PAUSE
					return
				var blocking_workers: Array = world.get_workers_blocking_dig(task.pos)
				if not blocking_workers.is_empty():
					work_timer = DIG_OCCUPIED_RETRY_INTERVAL
					if _diagnostics_enabled(world):
						world.live_diagnostics.observe("worker", str(worker_id), "dig_deferred_occupied", {"task_id": task.id, "blocking_worker_count": blocking_workers.size(), "retry_seconds": work_timer})
					_trace(world, "dig_deferred_occupied", task, "blocking_workers=%s" % _worker_ids(blocking_workers))
					return
			match task.type:
				TaskQueue.TaskType.DIG:
					var old_block: int = world.get_block(task.pos.x, task.pos.y, task.pos.z)
					world.set_block(task.pos.x, task.pos.y, task.pos.z, World.BLOCK_ID_AIR)
					world.spawn_mining_drops(old_block, task.pos)
				TaskQueue.TaskType.PLACE:
					if not world.remove_from_inventory(task.material):
						if _diagnostics_enabled(world):
							world.live_diagnostics.observe("task", str(task.id), "material_unavailable", {"worker_id": worker_id, "material_id": task.material})
						_trace(world, "task_deferred", task, "material unavailable")
						task.status = TaskQueue.TaskStatus.PENDING
						task.accessibility = TaskQueue.TaskAccessibility.UNKNOWN
						task.assigned_worker = null
						current_task_id = -1
						active_work_anim = &""
						idle_timer = IDLE_PAUSE
						set_state(WorkerState.IDLE, world)
						return
					world.set_block(task.pos.x, task.pos.y, task.pos.z, task.material)
				TaskQueue.TaskType.STAIRS:
					if bool(task.data.get("flight", false)):
						# Transient blockers keep this worker on the job, like occupied
						# digs. Releasing it would let workers cycle through it forever.
						var stair_wait_reason: String = world.stair_task_wait_reason(task)
						if not stair_wait_reason.is_empty():
							work_timer = DIG_OCCUPIED_RETRY_INTERVAL
							if _diagnostics_enabled(world):
								world.live_diagnostics.observe("worker", str(worker_id), "stairs_deferred", {"task_id": task.id, "reason": stair_wait_reason, "retry_seconds": work_timer})
							_trace(world, "stairs_deferred", task, "reason=%s" % stair_wait_reason)
							return
						if not world.complete_stair_flight(task):
							# Nothing transient blocked it, so the site changed underneath
							# the job (support dug out, stairs already gone, ...).
							task_queue.remove_task(task)
							_trace(world, "task_cancelled", task, "reason=stair_site_invalid")
							current_task_id = -1
							active_work_anim = &""
							idle_timer = IDLE_PAUSE
							set_state(WorkerState.IDLE, world)
							return
					else:
						world.set_block(task.pos.x, task.pos.y, task.pos.z, task.material)
						world.cancel_digs_protected_by_stairs([task.pos])
				TaskQueue.TaskType.TORCH:
					var torch_reject_reason: String = world.torch_site_reject_reason(task.pos)
					if not torch_reject_reason.is_empty():
						task_queue.remove_task(task)
						_trace(world, "task_cancelled", task, "reason=torch_site_invalid:%s" % torch_reject_reason)
						current_task_id = -1
						active_work_anim = &""
						idle_timer = IDLE_PAUSE
						set_state(WorkerState.IDLE, world)
						return
					if not world.torch_store.add_torch(task.pos):
						task_queue.remove_task(task)
						_trace(world, "task_cancelled", task, "reason=torch_already_exists")
						current_task_id = -1
						active_work_anim = &""
						idle_timer = IDLE_PAUSE
						set_state(WorkerState.IDLE, world)
						return
				TaskQueue.TaskType.HAUL:
					if not _advance_haul_task(world, task_queue, task):
						return
			task_queue.complete_task(task)
			_trace(world, "task_completed", task)
			if _diagnostics_enabled(world):
				world.live_diagnostics.observe("task", str(task.id), "task_completed", {"worker_id": worker_id, "type": task.type})
			if task.type == TaskQueue.TaskType.DIG:
				world.reassess_waiting_tasks()

	current_task_id = -1
	active_work_anim = &""
	set_state(WorkerState.IDLE, world)
	idle_timer = IDLE_PAUSE
#endregion


func _advance_haul_task(world, task_queue, task) -> bool:
	var stage := str(task.data.get("stage", "pickup"))
	var item_id := int(task.data.get("item_id", -1))
	if stage == "pickup":
		var item: Dictionary = world.item_store.get_item(item_id)
		if item.is_empty():
			if _diagnostics_enabled(world):
				world.live_diagnostics.observe("worker", str(worker_id), "haul_item_missing", {"task_id": task.id, "item_id": item_id})
			_trace(world, "haul_failed", task, "reason=item_missing")
			return true
		if int(item.get("reserved_by_task_id", -1)) != task.id:
			if _diagnostics_enabled(world):
				world.live_diagnostics.observe("worker", str(worker_id), "haul_reservation_lost", {"task_id": task.id, "item_id": item_id, "reserved_by_task_id": int(item.get("reserved_by_task_id", -1))})
			_trace(world, "haul_failed", task, "reason=item_reservation_lost")
			return true
		carried_material_id = int(item.get("material_id", 0))
		carried_count = int(item.get("count", 0))
		carried_source_item_id = item_id
		if not world.item_store.mark_carried(item_id):
			if _diagnostics_enabled(world):
				world.live_diagnostics.observe("worker", str(worker_id), "haul_pickup_state_invalid", {"task_id": task.id, "item_id": item_id})
			_trace(world, "haul_failed", task, "reason=item_pickup_state_invalid")
			_release_carried_item(world, task)
			return true
		var destination: Vector3i = task.data.get("destination", Vector3i.ZERO)
		task.data["stage"] = "delivery_path_pending"
		if _diagnostics_enabled(world):
			world.live_diagnostics.invalidate("task", str(task.id), "haul_stage_changed")
			world.live_diagnostics.observe("item", str(item_id), "item_picked_up", {"worker_id": worker_id, "task_id": task.id, "count": carried_count, "destination": destination})
		active_work_anim = &""
		set_state(WorkerState.WAITING_FOR_PATH, world)
		_trace(world, "item_picked_up", task, "item_id=%d material=%d count=%d destination=%s" % [
			item_id,
			carried_material_id,
			carried_count,
			destination,
		])
		if world.task_manager == null \
				or not world.task_manager.request_haul_delivery_path(self, task, destination):
			fail_haul_delivery_path(world, task_queue, task, "reason=path_request_failed")
		return false

	var destination_stockpile := int(task.data.get("stockpile_id", -1))
	var destination_pos: Vector3i = task.data.get("destination", get_block_coord())
	if not world.deposit_item_to_stockpile(item_id, destination_stockpile, destination_pos):
		fail_haul_delivery_path(world, task_queue, task, "reason=deposit_rejected")
		return false
	_trace(world, "item_deposited", task, "item_id=%d stockpile=%d" % [item_id, destination_stockpile])
	if _diagnostics_enabled(world):
		world.live_diagnostics.observe("worker", str(worker_id), "item_deposited", {"task_id": task.id, "item_id": item_id, "stockpile_id": destination_stockpile, "destination": destination_pos})
	carried_material_id = 0
	carried_count = 0
	carried_source_item_id = -1
	return true


func start_haul_delivery_path(
	world,
	task,
	found_path: Array,
	search_ms: float,
	snapshot_ms: float,
	queue_wait_ms: float
) -> void:
	if task == null or found_path.is_empty():
		return
	task.data["stage"] = "deposit"
	if _diagnostics_enabled(world):
		world.live_diagnostics.invalidate("task", str(task.id), "haul_stage_changed")
	path = found_path.duplicate()
	path_index = 0
	movement_intent = MovementIntent.TASK
	path_segment_validated = false
	set_target_from_path(world)
	set_state(WorkerState.MOVING, world)
	_trace(world, "haul_delivery_path_started", task, "path_length=%d snapshot_ms=%.3f queue_wait_ms=%.3f search_ms=%.3f" % [
		path.size(),
		snapshot_ms,
		queue_wait_ms,
		search_ms,
	])
	if _diagnostics_enabled(world):
		world.live_diagnostics.observe("worker", str(worker_id), "haul_delivery_path_started", {"task_id": task.id, "item_id": carried_source_item_id, "path_length": path.size(), "search_ms": search_ms})


func fail_haul_delivery_path(world, task_queue, task, details: String) -> void:
	if _diagnostics_enabled(world):
		world.live_diagnostics.observe("worker", str(worker_id), "haul_delivery_deferred", {"task_id": task.id if task != null else -1, "item_id": carried_source_item_id})
	_trace(world, "haul_deferred", task, details)
	_drop_carried_item(world, task)
	if task_queue != null:
		task_queue.remove_task(task)
	current_task_id = -1
	active_work_anim = &""
	path.clear()
	path_index = 0
	path_segment_validated = false
	movement_intent = MovementIntent.NONE
	idle_timer = IDLE_PAUSE
	set_state(WorkerState.IDLE, world)


func _release_carried_item(world, task) -> void:
	if carried_source_item_id >= 0 and world != null:
		world.item_store.release_reservation(carried_source_item_id, task.id if task != null else -1)
	carried_material_id = 0
	carried_count = 0
	carried_source_item_id = -1


func _drop_carried_item(world, task) -> void:
	if carried_source_item_id < 0 or world == null:
		return
	world.item_store.mark_loose(carried_source_item_id, get_block_coord())
	if _diagnostics_enabled(world):
		world.live_diagnostics.observe("item", str(carried_source_item_id), "item_dropped", {"worker_id": worker_id, "task_id": task.id if task != null else -1, "pos": get_block_coord()})
	_trace(world, "item_dropped", task, "item_id=%d pos=%s" % [carried_source_item_id, get_block_coord()])
	carried_material_id = 0
	carried_count = 0
	carried_source_item_id = -1


func _cancel_interrupted_haul(world, task_queue, task) -> void:
	var item_id := int(task.data.get("item_id", -1))
	if carried_source_item_id >= 0:
		_drop_carried_item(world, task)
	else:
		world.item_store.release_reservation(item_id, task.id)
	task_queue.remove_task(task)


#region Waiting State
func update_waiting(_dt: float, world, task_queue, _pathfinder) -> void:
	if current_task_id < 0:
		set_state(WorkerState.IDLE, world)
		return

	var task = task_queue.get_task(current_task_id)
	if task == null or task.status == TaskQueue.TaskStatus.COMPLETED:
		current_task_id = -1
		set_state(WorkerState.IDLE, world)
		return
	if waiting_repath_timer > 0.0:
		return
	waiting_repath_timer = WAITING_REPATH_INTERVAL

	# SEE-ADR-005: Waiting workers release tasks so the changed world can be re-auctioned.
	_trace(world, "task_released_for_repath", task, "retry through assignment auction")
	if _diagnostics_enabled(world):
		world.live_diagnostics.observe("worker", str(worker_id), "task_released_for_repath", {"task_id": task.id, "retry_seconds": waiting_repath_timer})
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
	set_state(WorkerState.IDLE, world)
#endregion


#region Wandering
func update_wander(dt: float, world, pathfinder) -> void:
	if wander_wait > 0.0:
		wander_wait -= dt
		return

	var start: Vector3i = get_block_coord()
	var neighbors: Array = pathfinder.get_neighbors(world, start)
	if not neighbors.is_empty():
		var goal: Vector3i = neighbors[rng.randi_range(0, neighbors.size() - 1)]
		if world != null and world.task_queue != null:
			world.task_queue.clear_assist_waiter(self)
		path = [goal]
		path_index = 0
		movement_intent = MovementIntent.WANDER
		assist_task_id = -1
		set_target_from_path(world)
		set_state(WorkerState.MOVING, world)
		_trace(world, "wander_started", null, "target=%s path_length=%d mode=local_step candidates=%d" % [
			goal,
			path.size(),
			neighbors.size(),
		])
		return

	wander_wait = rng.randf_range(WANDER_WAIT_MIN, WANDER_WAIT_MAX)
	_trace(world, "wander_failed", null, "reason=no_local_neighbors")
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
		return find_path_to_stairs(world, start, target, pathfinder, -1)
	if task_type == TaskQueue.TaskType.HAUL:
		return pathfinder.find_path(world, start, target, false, false, max_iterations_cap)

	return find_path_to_work_position(world, start, task_type, target, pathfinder, max_iterations_cap)


func find_path_to_work_position(
	world,
	start: Vector3i,
	task_type: int,
	target: Vector3i,
	pathfinder,
	max_iterations_cap: int
) -> Array:
	var work_positions: Array[Vector3i] = TaskWorkPositionRulesScript.task_work_positions(
		world,
		pathfinder,
		target,
		task_type
	)
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


func find_path_to_stairs(
	world,
	start: Vector3i,
	target: Vector3i,
	pathfinder,
	flight_rotation: int = -1,
	excluded_cells: Array = []
) -> Array:
	var candidates := TaskWorkPositionRulesScript.stair_work_positions(
		world,
		pathfinder,
		target,
		flight_rotation,
		excluded_cells
	)
	return pathfinder.find_path_to_any(world, start, candidates, WORKER_PATH_SEARCH_MAX_ITERATIONS)
#endregion


func _current_task(task_queue):
	if current_task_id < 0 or task_queue == null:
		return null
	return task_queue.get_task(current_task_id)


func _stair_excluded_cells_for_task(task) -> Array[Vector3i]:
	return TaskWorkPositionRulesScript.stair_excluded_cells_for_task(task)


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


func _can_work_task_from_coord(
	task_type: int,
	worker_pos: Vector3i,
	task_pos: Vector3i,
	world,
	pathfinder,
	flight_rotation: int = -1,
	stair_excluded_cells: Array = []
) -> bool:
	# SEE-ADR-001: Normal DIG/PLACE work is same-level and cardinal-adjacent.
	if task_type == TaskQueue.TaskType.STAIRS:
		return TaskWorkPositionRulesScript.can_work_stairs_from(
			world,
			pathfinder,
			worker_pos,
			task_pos,
			flight_rotation,
			stair_excluded_cells
		)
	if task_type != TaskQueue.TaskType.DIG and task_type != TaskQueue.TaskType.PLACE and task_type != TaskQueue.TaskType.TORCH:
		return true
	if world == null or pathfinder == null:
		return worker_pos.y == _work_level_for_task(task_type, task_pos, world) \
			and abs(worker_pos.x - task_pos.x) + abs(worker_pos.z - task_pos.z) == ADJACENT_MANHATTAN_DISTANCE
	return TaskWorkPositionRulesScript.can_work_task_from(
		world,
		pathfinder,
		worker_pos,
		task_pos,
		task_type
	)


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
	if _diagnostics_enabled(world):
		world.live_diagnostics.invalidate("worker", str(worker_id), "path_invalidated")
		world.live_diagnostics.observe("worker", str(worker_id), "path_invalidated", {"task_id": movement_task.id if movement_task != null else -1, "from": current_node, "next_node": next_node, "movement_intent": movement_intent})
	_trace(world, "path_invalidated", movement_task, "%s from=%s next_node=%s" % [
		_movement_intent_name(),
		current_node,
		next_node,
	])
	path.clear()
	path_index = 0
	path_segment_validated = false
	if task != null:
		if task.type == TaskQueue.TaskType.HAUL:
			# SEE-ADR-008: Interrupted hauling drops locally and replaces the pickup task.
			_interrupt_current_task(task_queue, world)
		else:
			task.status = TaskQueue.TaskStatus.PENDING
			task.accessibility = TaskQueue.TaskAccessibility.UNKNOWN
			task.unreachable_workers.clear()
			task.assigned_worker = null
		current_task_id = -1
		movement_intent = MovementIntent.NONE
		assist_task_id = -1
		task_search_timer = IDLE_TASK_SEARCH_INTERVAL
		set_state(WorkerState.IDLE, world)
	else:
		if movement_intent == MovementIntent.ASSIST:
			_trace(world, "assist_interrupted", movement_task, "path invalidated")
		movement_intent = MovementIntent.NONE
		assist_task_id = -1
		wander_wait = 0.0
		task_search_timer = 0.0
		set_state(WorkerState.IDLE, world)
	return false


func _worker_ids(worker_list: Array) -> String:
	var ids: Array[String] = []
	for worker in worker_list:
		ids.append(str(worker.worker_id))
	return "|".join(ids)


func _trace(world, event: String, task = null, details: String = "") -> void:
	if world != null:
		world.trace_worker_event(self, event, task, details)


func _report_anomaly(world, check: String, details: Dictionary) -> void:
	var watchdog = world.get("anomaly_watchdog") if world != null else null
	if watchdog != null:
		watchdog.report_event(check, "worker:%d" % worker_id, details, self)


func _diagnostics_enabled(world) -> bool:
	return world != null and world.get("live_diagnostics") != null and world.live_diagnostics.enabled
