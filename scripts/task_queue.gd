extends RefCounted
class_name TaskQueue
## Priority queue for dig, place, and stairs tasks.

#region Enums
enum TaskType {DIG, PLACE, STAIRS}
enum TaskStatus {PENDING, IN_PROGRESS, COMPLETED}
#endregion


#region Task Class
class Task:
	var id: int
	var pos: Vector3i
	var type: int
	var status: int
	var material: int
	var assigned_worker = null

	func _init(task_id: int, task_pos: Vector3i, task_type: int, task_material: int) -> void:
		id = task_id
		pos = task_pos
		type = task_type
		status = TaskStatus.PENDING
		material = task_material
#endregion


#region State
var tasks: Array = []
var next_id: int = 1
var _tasks_by_id: Dictionary = {}      # int -> Task
var _tasks_by_pos: Dictionary = {}     # Vector3i -> Array[Task]
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


#region Task Maintenance
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
#endregion
