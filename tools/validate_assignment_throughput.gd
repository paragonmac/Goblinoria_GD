extends SceneTree
## Many pending jobs plus constant job churn (hauls finishing and being queued)
## must still assign idle workers promptly. Previously each priority round
## auctioned every pending task before committing, and any task removal
## restarted the scan, so with ~80 jobs and steady churn nobody was assigned.

const Fixture = preload("res://tools/validate_work_priorities.gd")

var checks := 0
var failures := 0


func _init() -> void:
	_run.call_deferred()


func _run() -> void:
	_churn_case()
	_steady_case()
	print("Assignment throughput: %d checks, %d failures" % [checks, failures])
	quit(1 if failures else 0)


func _setup(worker_count: int, task_count: int) -> Fixture.TestWorld:
	var world := Fixture.TestWorld.new()
	world._init_ramp_lookup()
	world.block_registry.load_from_csv(World.BLOCK_DATA_PATH)
	world.task_manager = TaskManager.new(world, world.task_queue)
	world.task_manager.path_search_scheduler.stop()
	world.task_manager.path_search_scheduler = Fixture.Scheduler.new()
	for index in range(worker_count):
		var worker := Worker.new()
		worker.worker_id = index + 1
		worker.position = Vector3(0, 1, 0)
		world.add_child(worker)
		world.workers.append(worker)
	for index in range(task_count):
		world.task_queue.add_dig_task(Vector3i(index + 2, 1, index % 7))
	return world


func _assigned(world: World) -> int:
	var count := 0
	for worker: Worker in world.workers:
		if worker.current_task_id >= 0:
			count += 1
	return count


func _churn_case() -> void:
	var world := _setup(10, 80)
	var next_x := 200
	for frame in range(1000):
		world.task_manager.update_task_assignments()
		if frame % 3 == 0:
			# Remove one unclaimed job (the newest, not the one under auction) and
			# queue a fresh one, like hauls being rebuilt as items move.
			for index in range(world.task_queue.tasks.size() - 1, -1, -1):
				var task = world.task_queue.tasks[index]
				if task.status == TaskQueue.TaskStatus.PENDING and task.id != world.task_manager.assignment_task_id:
					world.task_queue.remove_task(task)
					break
			world.task_queue.add_dig_task(Vector3i(next_x, 1, 3))
			next_x += 1
	_check(_assigned(world) >= 8, "Churn: at least 8 of 10 workers assigned within 1000 frames (got %d)" % _assigned(world))
	_dispose(world)


func _steady_case() -> void:
	var world := _setup(10, 80)
	var first_assignment_frame := -1
	for frame in range(1500):
		world.task_manager.update_task_assignments()
		if first_assignment_frame < 0 and _assigned(world) > 0:
			first_assignment_frame = frame
	_check(first_assignment_frame >= 0 and first_assignment_frame < 400, "Steady: first worker assigned within 400 frames (frame %d)" % first_assignment_frame)
	_check(_assigned(world) == 10, "Steady: all 10 workers assigned within 1500 frames (got %d)" % _assigned(world))
	_dispose(world)


func _dispose(world: World) -> void:
	world.task_manager.shutdown()
	world.free()


func _check(value: bool, message: String) -> void:
	checks += 1
	if not value:
		failures += 1
		push_error(message)
