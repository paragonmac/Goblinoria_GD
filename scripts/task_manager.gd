extends RefCounted
class_name TaskManager

var world: World
var task_queue: TaskQueue
var blocked_tasks: Array = []
var blocked_recheck_timer := 1.0


func _init(world_ref: World, queue_ref: TaskQueue) -> void:
	world = world_ref
	task_queue = queue_ref


func update_task_queue() -> void:
	task_queue.cleanup_completed()


func update_blocked_tasks(dt: float) -> void:
	blocked_recheck_timer -= dt
	if blocked_recheck_timer <= 0.0:
		recheck_blocked_tasks()
		blocked_recheck_timer = 0.5


func reassess_waiting_tasks() -> void:
	for task in task_queue.tasks:
		if task.status != TaskQueue.TaskStatus.IN_PROGRESS:
			continue
		var worker = task.assigned_worker
		if worker == null:
			task.status = TaskQueue.TaskStatus.PENDING
			continue
		if worker.state == Worker.WorkerState.WAITING or worker.state == Worker.WorkerState.IDLE:
			task.status = TaskQueue.TaskStatus.PENDING
			task.assigned_worker = null
			if worker.current_task_id == task.id:
				worker.current_task_id = -1
				worker.set_state(Worker.WorkerState.IDLE)


func queue_task_request(task_type: int, pos: Vector3i, material: int) -> void:
	if is_task_already_queued(task_type, pos):
		return
	if is_task_accessible(task_type, pos):
		add_task_to_queue(task_type, pos, material)
	else:
		blocked_tasks.append({"type": task_type, "pos": pos, "material": material})


func recheck_blocked_tasks() -> void:
	var i := 0
	while i < blocked_tasks.size():
		var task = blocked_tasks[i]
		var task_type: int = task["type"]
		var pos: Vector3i = task["pos"]
		if is_task_accessible(task_type, pos):
			add_task_to_queue(task_type, pos, task["material"])
			blocked_tasks.remove_at(i)
		else:
			i += 1


func is_task_accessible(task_type: int, pos: Vector3i) -> bool:
	if world == null or world.workers.is_empty():
		return false
	for worker: Worker in world.workers:
		var start: Vector3i = worker.get_block_coord()
		var path: Array = []
		if task_type == TaskQueue.TaskType.STAIRS:
			path = worker.find_path_to_stairs(world, start, pos, world.pathfinder)
		else:
			path = world.pathfinder.find_path_to_adjacent_on_level(world, start, pos, pos.y)
		if path.size() > 0:
			return true
	return false


func add_task_to_queue(task_type: int, pos: Vector3i, material: int) -> void:
	match task_type:
		TaskQueue.TaskType.DIG:
			task_queue.add_dig_task(pos)
		TaskQueue.TaskType.PLACE:
			task_queue.add_place_task(pos, material)
		TaskQueue.TaskType.STAIRS:
			task_queue.add_stairs_task(pos, material)


func is_task_already_queued(task_type: int, pos: Vector3i) -> bool:
	for task in task_queue.tasks:
		if task.status == TaskQueue.TaskStatus.COMPLETED:
			continue
		if task.type == task_type and task.pos == pos:
			return true
	for task in blocked_tasks:
		if task["type"] == task_type and task["pos"] == pos:
			return true
	return false
