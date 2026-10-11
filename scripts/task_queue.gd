extends RefCounted
class_name TaskQueue
## Priority queue for dig, place, and stairs tasks.

const StairFlightScript = preload("res://scripts/stair_flight.gd")

signal active_count_changed(count: int)
signal task_added(task)
signal task_removed(task_id: int)
signal task_visual_state_changed(task_id: int)

#region Enums
enum TaskType {DIG, PLACE, STAIRS, HAUL, TORCH, CHOP}
enum TaskStatus {PENDING, IN_PROGRESS, COMPLETED}
enum TaskAccessibility {UNKNOWN, REACHABLE, UNREACHABLE}
enum TaskBlockReason {NONE, NO_WORK_POSITION, NO_WORKER_PATH, NO_ELIGIBLE_WORKER}
#endregion

#region Constants
const WORKER_UNREACHABLE_TTL_MSEC := 2500
const TASK_UNREACHABLE_TTL_MSEC := 2500
const TASK_UNREACHABLE_MAX_TTL_MSEC := 60000
#endregion


#region Task Class
class Task:
	signal visual_state_changed

	var id: int
	var _pos_initialized := false
	var pos: Vector3i:
		set(value):
			if _pos_initialized and pos != value:
				push_error("Queued task positions are immutable; replace the task instead")
				return
			pos = value
	var type: int
	var status: int:
		set(value):
			if status == value:
				return
			status = value
			visual_state_changed.emit()
	var accessibility: int:
		set(value):
			if accessibility == value:
				return
			accessibility = value
			if accessibility != TaskAccessibility.UNREACHABLE:
				block_reason = TaskBlockReason.NONE
				retry_due_msec = 0
			visual_state_changed.emit()
	var accessibility_updated_msec: int
	var material: int
	var assigned_worker = null:
		set(value):
			if assigned_worker == value:
				return
			assigned_worker = value
			visual_state_changed.emit()
	var block_reason: int:
		set(value):
			if block_reason == value:
				return
			block_reason = value
			visual_state_changed.emit()
	var retry_due_msec: int = 0
	## Consecutive no-path blocks; drives retry backoff until a path succeeds or
	## nearby terrain changes.
	var path_block_streak: int = 0
	var unreachable_workers: Dictionary = {}
	var data: Dictionary = {}
	var expected_blocks: Array[int] = []
	var diagnostics_world: WeakRef

	func _init(task_id: int, task_pos: Vector3i, task_type: int, task_material: int) -> void:
		id = task_id
		pos = task_pos
		_pos_initialized = true
		type = task_type
		status = TaskStatus.PENDING
		accessibility = TaskAccessibility.UNKNOWN
		accessibility_updated_msec = 0
		material = task_material
		block_reason = TaskBlockReason.NONE

	func set_accessibility(
		new_accessibility: int,
		now_msec: int,
		new_block_reason: int = TaskBlockReason.NONE
	) -> void:
		accessibility = new_accessibility
		accessibility_updated_msec = now_msec
		block_reason = new_block_reason if new_accessibility == TaskAccessibility.UNREACHABLE \
			else TaskBlockReason.NONE

	func mark_worker_unreachable(worker_id: int, now_msec: int) -> void:
		unreachable_workers[worker_id] = now_msec

	func is_worker_unreachable(worker_id: int, now_msec: int, ttl_msec: int = WORKER_UNREACHABLE_TTL_MSEC) -> bool:
		if not unreachable_workers.has(worker_id):
			return false
		var marked_msec: int = int(unreachable_workers[worker_id])
		if now_msec - marked_msec <= ttl_msec:
			return true
		unreachable_workers.erase(worker_id)
		return false

	func clear_expired_worker_unreachable(now_msec: int, ttl_msec: int = WORKER_UNREACHABLE_TTL_MSEC) -> bool:
		var expired := false
		var worker_ids: Array = unreachable_workers.keys()
		for worker_id in worker_ids:
			var marked_msec: int = int(unreachable_workers[worker_id])
			if now_msec - marked_msec > ttl_msec:
				unreachable_workers.erase(worker_id)
				expired = true
		return expired
#endregion


#region State
var tasks: Array = []
var next_id: int = 1
var diagnostics_membership_revision := 0
# Weak ownership: the manager supplies World; its service may be replaced.
var diagnostics_world: WeakRef
var _tasks_by_id: Dictionary = {}      # int -> Task
var _tasks_by_pos: Dictionary = {}     # Vector3i -> Array[Task]
var _assist_waiters: Array = []
var _assist_waiter_seq := 0
#endregion


#region Task Creation
func add_task(
	pos: Vector3i,
	task_type: int,
	material: int,
	task_data: Dictionary = {},
	expected_blocks: Array[int] = []
) -> int:
	var pos_tasks: Array = _tasks_by_pos.get(pos, [])
	for task in pos_tasks:
		if task_type != TaskType.HAUL and bool(task.data.get("flight", false)) \
				and task.status != TaskStatus.COMPLETED:
			return -1
		if task_type != TaskType.HAUL and task.type == task_type and task.status != TaskStatus.COMPLETED:
			return task.id
	var task_id = next_id
	next_id += 1
	var task := Task.new(task_id, pos, task_type, material)
	task.data = task_data.duplicate(true)
	task.expected_blocks = expected_blocks.duplicate()
	task.diagnostics_world = diagnostics_world
	task.visual_state_changed.connect(_on_task_visual_state_changed.bind(task))
	tasks.append(task)
	_tasks_by_id[task_id] = task
	for footprint_pos: Vector3i in _task_footprint(task):
		if not _tasks_by_pos.has(footprint_pos):
			_tasks_by_pos[footprint_pos] = []
		_tasks_by_pos[footprint_pos].append(task)
	diagnostics_membership_revision += 1
	if _diagnostics_enabled():
		_diagnostics_service().observe("task", str(task.id), "task_added", {"type": task.type, "pos": task.pos})
	active_count_changed.emit(tasks.size())
	task_added.emit(task)
	task_visual_state_changed.emit(task.id)
	return task_id


func add_dig_task(pos: Vector3i) -> int:
	return add_task(pos, TaskType.DIG, 0)


func add_place_task(pos: Vector3i, material: int) -> int:
	return add_task(pos, TaskType.PLACE, material)


func add_torch_task(pos: Vector3i) -> int:
	return add_task(pos, TaskType.TORCH, 0)


func add_chop_task(pos: Vector3i) -> int:
	return add_task(pos, TaskType.CHOP, 0)


func add_stairs_task(pos: Vector3i, stair_material: int) -> int:
	return add_task(pos, TaskType.STAIRS, stair_material)


func add_stair_flight_task(
	anchor: Vector3i,
	rotation: int,
	up: bool,
	lower_material: int,
	upper_material: int,
	expected_blocks: Array[int] = []
) -> int:
	var footprint := StairFlightScript.cells(anchor, rotation)
	for cell: Vector3i in footprint:
		if not get_active_tasks_at(cell).is_empty():
			return -1
	var task_data := {
		"flight": true,
		"rotation": rotation,
		"up": up,
		"footprint": footprint.duplicate(),
		"materials": [lower_material, upper_material],
	}
	var task_id := add_task(anchor, TaskType.STAIRS, lower_material, task_data, expected_blocks)
	var task = get_task(task_id)
	if task == null:
		return -1
	return task_id


func add_haul_task(item_id: int, item_pos: Vector3i, material: int, stockpile_id: int, destination: Vector3i) -> int:
	var task_id := add_task(item_pos, TaskType.HAUL, material)
	var task = get_task(task_id)
	if task != null:
		task.data = {
			"item_id": item_id,
			"stockpile_id": stockpile_id,
			"destination": destination,
			"stage": "pickup",
		}
	return task_id
#endregion


#region Task Lookup
func get_task(task_id: int) -> Task:
	return _tasks_by_id.get(task_id, null)


func has_active_task_at(pos: Vector3i, task_type: int) -> bool:
	var pos_tasks: Array = _tasks_by_pos.get(pos, [])
	for task in pos_tasks:
		if task.type == task_type and task.status != TaskStatus.COMPLETED:
			return true
	return false


func get_active_tasks_at(pos: Vector3i) -> Array:
	var active: Array = []
	for task in _tasks_by_pos.get(pos, []):
		if task.status != TaskStatus.COMPLETED and not active.has(task):
			active.append(task)
	return active


func has_pending_task_at(pos: Vector3i, task_types: Array = []) -> bool:
	var pos_tasks: Array = _tasks_by_pos.get(pos, [])
	for task in pos_tasks:
		if task.status != TaskStatus.PENDING:
			continue
		if not task_types.is_empty() and not task_types.has(task.type):
			continue
		return true
	return false


func remove_pending_task_at(pos: Vector3i, task_type: int) -> bool:
	return not remove_pending_tasks_at(pos, [task_type]).is_empty()


func remove_pending_tasks_at(pos: Vector3i, task_types: Array = []) -> Array:
	var removed: Array = []
	var candidates: Array = _tasks_by_pos.get(pos, []).duplicate()
	for task in candidates:
		if task.status != TaskStatus.PENDING:
			continue
		if not task_types.is_empty() and not task_types.has(task.type):
			continue
		if remove_task(task):
			removed.append(task)
	if not removed.is_empty():
		pass
	return removed


func remove_task(task) -> bool:
	if task == null:
		return false
	if not _tasks_by_id.has(task.id):
		return false
	_tasks_by_id.erase(task.id)
	for footprint_pos: Vector3i in _task_footprint(task):
		var pos_tasks: Array = _tasks_by_pos.get(footprint_pos, [])
		pos_tasks.erase(task)
		if pos_tasks.is_empty():
			_tasks_by_pos.erase(footprint_pos)
		else:
			_tasks_by_pos[footprint_pos] = pos_tasks
	tasks.erase(task)
	diagnostics_membership_revision += 1
	if _diagnostics_enabled():
		_diagnostics_service().invalidate("task", str(task.id), "task_removed")
	active_count_changed.emit(tasks.size())
	task_removed.emit(task.id)
	task_visual_state_changed.emit(task.id)
	return true


func complete_task(task) -> bool:
	# SEE-ADR-009: Completed tasks leave every queue index immediately.
	if task == null or not _tasks_by_id.has(task.id):
		return false
	task.status = TaskStatus.COMPLETED
	return remove_task(task)


func find_nearest(task_type: int, from_pos: Vector3) -> Task:
	var nearest: Task = null
	var nearest_dist: float = INF
	for task in tasks:
		if task.status != TaskStatus.PENDING:
			continue
		if task.type != task_type:
			continue
		var dx: float = float(task.pos.x) - from_pos.x
		var dy: float = float(task.pos.y) - from_pos.y
		var dz: float = float(task.pos.z) - from_pos.z
		var dist_sq: float = dx * dx + dy * dy + dz * dz
		if dist_sq < nearest_dist:
			nearest_dist = dist_sq
			nearest = task
	return nearest


func find_nearest_stairs_at_level(from_pos: Vector3, y_level: int) -> Task:
	var nearest: Task = null
	var nearest_dist: float = INF
	var below_y: int = max(y_level - 1, 0)
	var below2_y: int = max(y_level - 2, 0)
	var above_y: int = y_level + 1
	for task in tasks:
		if task.status != TaskStatus.PENDING:
			continue
		if task.type != TaskType.STAIRS:
			continue
		var ty: int = task.pos.y
		if ty != y_level and ty != below_y and ty != below2_y and ty != above_y:
			continue
		var dx: float = float(task.pos.x) - from_pos.x
		var dy: float = float(task.pos.y) - from_pos.y
		var dz: float = float(task.pos.z) - from_pos.z
		var dist_sq: float = dx * dx + dy * dy + dz * dz
		if dist_sq < nearest_dist:
			nearest_dist = dist_sq
			nearest = task
	return nearest
#endregion


#region Assist Waiters
func register_assist_waiter(worker) -> void:
	if worker == null:
		return
	clear_assist_waiter(worker)
	_assist_waiter_seq += 1
	_assist_waiters.append({
		"worker": worker,
		"worker_id": worker.worker_id,
		"seq": _assist_waiter_seq,
		"arrived_msec": Time.get_ticks_msec(),
	})


func clear_assist_waiter(worker) -> void:
	if worker == null:
		return
	var i := 0
	while i < _assist_waiters.size():
		if _assist_waiters[i].get("worker") == worker:
			_assist_waiters.remove_at(i)
		else:
			i += 1


func has_assist_waiters() -> bool:
	_prune_invalid_assist_waiters()
	return not _assist_waiters.is_empty()


func is_oldest_assist_waiter(worker) -> bool:
	_prune_invalid_assist_waiters()
	if worker == null or _assist_waiters.is_empty():
		return false
	return _assist_waiters[0].get("worker") == worker


func get_oldest_assist_waiter_id() -> int:
	_prune_invalid_assist_waiters()
	if _assist_waiters.is_empty():
		return -1
	return int(_assist_waiters[0].get("worker_id", -1))


func _prune_invalid_assist_waiters() -> void:
	var i := 0
	while i < _assist_waiters.size():
		var worker = _assist_waiters[i].get("worker")
		if worker == null or worker.current_task_id >= 0:
			_assist_waiters.remove_at(i)
		else:
			i += 1
#endregion


#region Task Maintenance
func clear() -> void:
	diagnostics_membership_revision += 1
	if _diagnostics_enabled():
		for task_id in _tasks_by_id:
			_diagnostics_service().invalidate("task", str(task_id), "queue_cleared")
	var had_tasks := not tasks.is_empty()
	var removed_ids: Array = _tasks_by_id.keys()
	tasks.clear()
	_tasks_by_id.clear()
	_tasks_by_pos.clear()
	_assist_waiters.clear()
	_assist_waiter_seq = 0
	next_id = 1
	if had_tasks:
		active_count_changed.emit(0)
		for task_id in removed_ids:
			task_removed.emit(int(task_id))
			task_visual_state_changed.emit(int(task_id))


func active_count() -> int:
	return tasks.size()


func tasks_near(
	pos: Vector3i,
	radius_xz: int,
	radius_y: int
) -> Array:
	var nearby: Array = []
	var seen: Dictionary = {}
	for x in range(pos.x - radius_xz, pos.x + radius_xz + 1):
		for y in range(pos.y - radius_y, pos.y + radius_y + 1):
			for z in range(pos.z - radius_xz, pos.z + radius_xz + 1):
				for task in _tasks_by_pos.get(Vector3i(x, y, z), []):
					if seen.has(task.id):
						continue
					seen[task.id] = true
					nearby.append(task)
	return nearby


func _task_footprint(task) -> Array:
	if task != null and task.data is Dictionary and bool(task.data.get("flight", false)):
		var rotation := int(task.data.get("rotation", -1))
		if rotation >= 0 and rotation < StairFlightScript.ROTATION_COUNT:
			return StairFlightScript.cells(task.pos, rotation)
	if task != null and task.data is Dictionary and task.data.get("footprint", []) is Array:
		var footprint: Array = task.data.get("footprint", [])
		if not footprint.is_empty():
			return footprint
	return [task.pos] if task != null else []


func _on_task_visual_state_changed(task) -> void:
	if task != null and _tasks_by_id.has(task.id):
		if _diagnostics_enabled():
			_diagnostics_service().invalidate("task", str(task.id), "task_state_changed")
		task_visual_state_changed.emit(task.id)


func _diagnostics_service():
	var world = diagnostics_world.get_ref() if diagnostics_world != null else null
	return world.live_diagnostics if world != null else null


func _diagnostics_enabled() -> bool:
	var service = _diagnostics_service()
	return service != null and service.enabled


func count_active_by_type_and_material(task_type: int, material: int) -> int:
	var count := 0
	for task in tasks:
		if task.status != TaskStatus.COMPLETED and task.type == task_type and task.material == material:
			count += 1
	return count
#endregion
