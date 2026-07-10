extends RefCounted
class_name TaskQueue
## Priority queue for dig, place, and stairs tasks.

signal active_count_changed(count: int)
signal task_added(task)
signal task_removed(task_id: int)
signal task_visual_state_changed(task_id: int)

#region Enums
enum TaskType {DIG, PLACE, STAIRS, HAUL}
enum TaskStatus {PENDING, IN_PROGRESS, COMPLETED}
enum TaskAccessibility {UNKNOWN, REACHABLE, UNREACHABLE}
enum TaskBlockReason {NONE, NO_WORK_POSITION, NO_WORKER_PATH}
#endregion

#region Constants
const WORKER_UNREACHABLE_TTL_MSEC := 2500
const TASK_UNREACHABLE_TTL_MSEC := 2500
#endregion


#region Task Class
class Task:
	signal visual_state_changed

	var id: int
	var pos: Vector3i
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
	var unreachable_workers: Dictionary = {}
	var data: Dictionary = {}

	func _init(task_id: int, task_pos: Vector3i, task_type: int, task_material: int) -> void:
		id = task_id
		pos = task_pos
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
var _tasks_by_id: Dictionary = {}      # int -> Task
var _tasks_by_pos: Dictionary = {}     # Vector3i -> Array[Task]
var _assist_waiters: Array = []
var _assist_waiter_seq := 0
#endregion


#region Task Creation
func add_task(pos: Vector3i, task_type: int, material: int) -> int:
	var pos_tasks: Array = _tasks_by_pos.get(pos, [])
	for task in pos_tasks:
		if task_type != TaskType.HAUL and task.type == task_type and task.status != TaskStatus.COMPLETED:
			return task.id
	var task_id = next_id
	next_id += 1
	var task := Task.new(task_id, pos, task_type, material)
	task.visual_state_changed.connect(_on_task_visual_state_changed.bind(task))
	tasks.append(task)
	_tasks_by_id[task_id] = task
	if not _tasks_by_pos.has(pos):
		_tasks_by_pos[pos] = []
	_tasks_by_pos[pos].append(task)
	active_count_changed.emit(tasks.size())
	task_added.emit(task)
	task_visual_state_changed.emit(task.id)
	return task_id


func add_dig_task(pos: Vector3i) -> int:
	return add_task(pos, TaskType.DIG, 0)


func add_place_task(pos: Vector3i, material: int) -> int:
	return add_task(pos, TaskType.PLACE, material)


func add_stairs_task(pos: Vector3i, stair_material: int) -> int:
	return add_task(pos, TaskType.STAIRS, stair_material)


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
	var pos_tasks: Array = _tasks_by_pos.get(pos, [])
	for task in pos_tasks.duplicate():
		if task.status != TaskStatus.PENDING:
			continue
		if not task_types.is_empty() and not task_types.has(task.type):
			continue
		_tasks_by_id.erase(task.id)
		pos_tasks.erase(task)
		tasks.erase(task)
		removed.append(task)
		task_removed.emit(task.id)
		task_visual_state_changed.emit(task.id)
	if pos_tasks.is_empty():
		_tasks_by_pos.erase(pos)
	else:
		_tasks_by_pos[pos] = pos_tasks
	if not removed.is_empty():
		active_count_changed.emit(tasks.size())
	return removed


func remove_task(task) -> bool:
	if task == null:
		return false
	if not _tasks_by_id.has(task.id):
		return false
	_tasks_by_id.erase(task.id)
	var pos_tasks: Array = _tasks_by_pos.get(task.pos, [])
	pos_tasks.erase(task)
	if pos_tasks.is_empty():
		_tasks_by_pos.erase(task.pos)
	else:
		_tasks_by_pos[task.pos] = pos_tasks
	tasks.erase(task)
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
	for x in range(pos.x - radius_xz, pos.x + radius_xz + 1):
		for y in range(pos.y - radius_y, pos.y + radius_y + 1):
			for z in range(pos.z - radius_xz, pos.z + radius_xz + 1):
				for task in _tasks_by_pos.get(Vector3i(x, y, z), []):
					nearby.append(task)
	return nearby


func _on_task_visual_state_changed(task) -> void:
	if task != null and _tasks_by_id.has(task.id):
		task_visual_state_changed.emit(task.id)


func count_active_by_type_and_material(task_type: int, material: int) -> int:
	var count := 0
	for task in tasks:
		if task.status != TaskStatus.COMPLETED and task.type == task_type and task.material == material:
			count += 1
	return count
#endregion
