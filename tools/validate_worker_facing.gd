extends SceneTree

class TestWorld extends World:
	func ensure_chunk_generated(coord: Vector3i) -> ChunkData:
		var chunk := ensure_chunk(coord)
		chunk.generated = true
		return chunk

var checks := 0
var failures := 0


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	_test_dig_work_start_facing()
	_test_flight_facing()
	_test_vertical_target_keeps_facing()
	print("Worker facing: %d checks, %d failures" % [checks, failures])
	quit(1 if failures else 0)


func _check(value: bool, message: String) -> void:
	checks += 1
	if not value:
		failures += 1
		push_error(message)


func _world() -> World:
	var world := TestWorld.new()
	world.world_size_y = 16
	world._init_ramp_lookup()
	world.block_registry.load_from_csv(World.BLOCK_DATA_PATH)
	world.task_manager = TaskManager.new(world, world.task_queue)
	for x in range(-3, 4):
		for z in range(-3, 4):
			world.set_block_raw(x, 3, z, World.BLOCK_ID_GRANITE, true)
			world.set_block_raw(x, 4, z, World.BLOCK_ID_AIR, true)
	return world


func _worker_at(pos: Vector3) -> Worker:
	var worker := Worker.new()
	worker.use_animated_model = false
	worker.show_debug_box = false
	root.add_child(worker)
	worker.position = pos
	return worker


func _dispose(world: World, worker: Worker) -> void:
	worker.free()
	world.task_manager.shutdown()
	world.free()


func _test_dig_work_start_facing() -> void:
	var offsets: Array[Vector3i] = [
		Vector3i(1, 0, 0),
		Vector3i(-1, 0, 0),
		Vector3i(0, 0, -1),
		Vector3i(0, 0, 1),
	]
	var labels := ["east", "west", "north", "south"]
	for index in offsets.size():
		var world := _world()
		var worker := _worker_at(Vector3(0, 4, 0))
		var worker_cell := Vector3i(0, 4, 0)
		var target_cell: Vector3i = worker_cell + offsets[index]
		world.set_block_raw(target_cell.x, target_cell.y, target_cell.z, World.BLOCK_ID_GRANITE, true)
		var task_id := world.task_queue.add_dig_task(target_cell)
		var task = world.task_queue.get_task(task_id)
		task.status = TaskQueue.TaskStatus.IN_PROGRESS
		task.assigned_worker = worker
		worker.current_task_id = task_id
		worker.path = [worker_cell]
		worker.path_index = 0
		worker.target_pos = worker.position
		worker.path_segment_validated = true
		worker.update_moving(0.01, world, world.task_queue, world.pathfinder)
		var forward := -worker.global_transform.basis.z
		forward.y = 0.0
		var desired := Vector3(offsets[index])
		var dot := forward.normalized().dot(desired.normalized())
		_check(worker.state == Worker.WorkerState.WORKING, "%s DIG enters WORKING through arrival path" % labels[index])
		_check(dot > 0.99, "%s DIG faces its work target (dot=%.4f)" % [labels[index], dot])
		_dispose(world, worker)


func _test_flight_facing() -> void:
	var world := _world()
	var worker := _worker_at(Vector3(0, 4, 0))
	var task := TaskQueue.Task.new(1, Vector3i(1, 4, 0), TaskQueue.TaskType.STAIRS, 1)
	task.data = {
		"flight": true,
		"footprint": [Vector3i(1, 4, 0), Vector3i(0, 4, 2)],
	}
	worker._face_task_work_target(task, world)
	var forward := -worker.global_transform.basis.z
	forward.y = 0.0
	_check(forward.normalized().dot(Vector3.RIGHT) > 0.99, "Flight faces the nearest footprint cell")
	_dispose(world, worker)


func _test_vertical_target_keeps_facing() -> void:
	var world := _world()
	var worker := _worker_at(Vector3(0, 4, 0))
	worker.visuals.update_facing_from_delta(Vector3.RIGHT)
	var prior_basis := worker.global_transform.basis
	var task := TaskQueue.Task.new(1, Vector3i(0, 3, 0), TaskQueue.TaskType.DIG, 0)
	worker._face_task_work_target(task, world)
	_check(worker.global_transform.basis.is_equal_approx(prior_basis), "Directly below target preserves facing")
	_dispose(world, worker)
