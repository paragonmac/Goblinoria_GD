extends RefCounted
class_name TaskQueue
## Priority queue for dig, place, and stairs tasks.

#region Enums
enum TaskType {DIG, PLACE, STAIRS}
enum TaskStatus {PENDING, IN_PROGRESS, COMPLETED}
enum TaskAccessibility {UNKNOWN, REACHABLE, UNREACHABLE}
#endregion

#region Constants
const WORKER_UNREACHABLE_TTL_MSEC := 2500
const TASK_UNREACHABLE_TTL_MSEC := 2500
#endregion


#region Task Class
class Task:
	var id: int
	var pos: Vector3i
	var type: int
	var status: int
	var accessibility: int
	var accessibility_updated_msec: int
	var material: int
	var assigned_worker = null
	var unreachable_workers: Dictionary = {}

	func _init(task_id: int, task_pos: Vector3i, task_type: int, task_material: int) -> void:
		id = task_id
		pos = task_pos
		type = task_type
		status = TaskStatus.PENDING
		accessibility = TaskAccessibility.UNKNOWN
		accessibility_updated_msec = 0
		material = task_material

	func set_accessibility(new_accessibility: int, now_msec: int) -> void:
		accessibility = new_accessibility
		accessibility_updated_msec = now_msec

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
		if task.type == task_type and task.status != TaskStatus.COMPLETED:
			return task.id
	var task_id = next_id
	next_id += 1
	var task := Task.new(task_id, pos, task_type, material)
	tasks.append(task)
	_tasks_by_id[task_id] = task
	if not _tasks_by_pos.has(pos):
		_tasks_by_pos[pos] = []
	_tasks_by_pos[pos].append(task)
	return task_id


func add_dig_task(pos: Vector3i) -> int:
	return add_task(pos, TaskType.DIG, 0)


func add_place_task(pos: Vector3i, material: int) -> int:
	return add_task(pos, TaskType.PLACE, material)


func add_stairs_task(pos: Vector3i, stair_material: int) -> int:
	return add_task(pos, TaskType.STAIRS, stair_material)
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
	tasks.clear()
	_tasks_by_id.clear()
	_tasks_by_pos.clear()
	_assist_waiters.clear()
	_assist_waiter_seq = 0
	next_id = 1


func cleanup_completed() -> void:
	var i := 0
	while i < tasks.size():
		if tasks[i].status == TaskStatus.COMPLETED:
			var task: Task = tasks[i]
			_tasks_by_id.erase(task.id)
			var pos_tasks: Array = _tasks_by_pos.get(task.pos, [])
			pos_tasks.erase(task)
			if pos_tasks.is_empty():
				_tasks_by_pos.erase(task.pos)
			tasks.remove_at(i)
		else:
			i += 1


func active_count() -> int:
	var count := 0
	for task in tasks:
		if task.status != TaskStatus.COMPLETED:
			count += 1
	return count


func count_active_by_type_and_material(task_type: int, material: int) -> int:
	var count := 0
	for task in tasks:
		if task.status != TaskStatus.COMPLETED and task.type == task_type and task.material == material:
			count += 1
	return count
#endregion
