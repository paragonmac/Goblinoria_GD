extends RefCounted
class_name TaskQueue

enum TaskType { DIG, PLACE, STAIRS }
enum TaskStatus { PENDING, IN_PROGRESS, COMPLETED }

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

var tasks: Array = []
var next_id: int = 1

func add_task(pos: Vector3i, task_type: int, material: int) -> int:
	for task in tasks:
		if task.pos == pos and task.type == task_type and task.status != TaskStatus.COMPLETED:
			return task.id
	var task_id = next_id
	next_id += 1
	tasks.append(Task.new(task_id, pos, task_type, material))
	return task_id

func add_dig_task(pos: Vector3i) -> int:
	return add_task(pos, TaskType.DIG, 0)

func add_place_task(pos: Vector3i, material: int) -> int:
	return add_task(pos, TaskType.PLACE, material)

func add_stairs_task(pos: Vector3i, stair_material: int) -> int:
	return add_task(pos, TaskType.STAIRS, stair_material)

func get_task(task_id: int) -> Task:
	for task in tasks:
		if task.id == task_id:
			return task
	return null

func cleanup_completed() -> void:
	var i := 0
	while i < tasks.size():
		if tasks[i].status == TaskStatus.COMPLETED:
			tasks.remove_at(i)
		else:
			i += 1

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

func active_count() -> int:
	var count := 0
	for task in tasks:
		if task.status != TaskStatus.COMPLETED:
			count += 1
	return count
