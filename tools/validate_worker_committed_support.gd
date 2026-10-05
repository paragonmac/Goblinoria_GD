extends SceneTree
## A moving worker owns both cells of its committed path segment so terrain work
## cannot remove either support until the worker has cleared the segment.


class TestWorld extends World:
	var trace_events: Array[String] = []

	func ensure_chunk_generated(coord: Vector3i) -> ChunkData:
		var chunk := ensure_chunk(coord)
		chunk.generated = true
		return chunk

	func trace_worker_event(_worker: Worker, event: String, _task = null, _details: String = "") -> void:
		trace_events.append(event)


var checks := 0
var failures := 0


func _init() -> void:
	_test_committed_segment_endpoints()
	_test_segment_release_and_final_reservation()
	_test_dig_completion_waits_for_committed_segment()
	print("Worker committed support: %d checks, %d failures" % [checks, failures])
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
	world.block_drop_table.load_from_csv(World.BLOCK_DROPS_PATH)
	return world


func _dispose(world: World) -> void:
	for worker: Worker in world.workers:
		worker.free()
	world.workers.clear()
	world.free()


func _moving_worker(origin: Vector3i, destination: Vector3i, final: Vector3i, progress: float) -> Worker:
	var worker := Worker.new()
	worker.worker_id = 41
	worker.state = Worker.WorkerState.MOVING
	worker.movement_intent = Worker.MovementIntent.WANDER
	worker.current_task_id = -1
	worker.path = [origin, destination, final]
	worker.path_index = 1
	worker.path_segment_validated = true
	worker.position = Vector3(origin).lerp(Vector3(destination), progress)
	worker.target_pos = Vector3(destination)
	return worker


func _support(cell: Vector3i) -> Vector3i:
	return cell + Vector3i.DOWN


func _test_committed_segment_endpoints() -> void:
	# Include negative and positive chunk boundaries. The -1 -> 0 case also
	# exercises the world-origin boundary where floor division changes sign.
	for segment in [
		[Vector3i(-9, 3, 0), Vector3i(-8, 3, 0), Vector3i(-7, 3, 0)],
		[Vector3i(-1, 3, 0), Vector3i(0, 3, 0), Vector3i(1, 3, 0)],
		[Vector3i(7, 3, 0), Vector3i(8, 3, 0), Vector3i(9, 3, 0)],
	]:
		for progress in [0.25, 0.75]:
			var world := _world()
			var worker := _moving_worker(segment[0], segment[1], segment[2], progress)
			world.workers.append(worker)
			_check(
				world.get_workers_blocking_dig(_support(segment[0])).has(worker),
				"Committed origin support unprotected at segment %s progress %.2f" % [segment, progress]
			)
			_check(
				world.get_workers_blocking_dig(_support(segment[1])).has(worker),
				"Committed destination support unprotected at segment %s progress %.2f" % [segment, progress]
			)
			_dispose(world)


func _test_segment_release_and_final_reservation() -> void:
	var world := _world()
	var origin := Vector3i(-1, 3, 0)
	var destination := Vector3i(0, 3, 0)
	var final := Vector3i(1, 3, 0)
	var worker := _moving_worker(origin, destination, final, 0.25)
	world.workers.append(worker)
	worker.path_segment_validated = false
	_check(
		not world.get_workers_blocking_dig(_support(destination)).has(worker),
		"Uncommitted destination support remained reserved"
	)
	worker.path.clear()
	_check(
		not world.get_workers_blocking_dig(_support(destination)).has(worker),
		"Cleared segment destination support remained reserved"
	)
	worker.path = [origin, destination]
	worker.path_index = 1
	worker.current_task_id = 99
	_check(
		world.get_workers_blocking_dig(_support(destination)).has(worker),
		"Existing final work-position support reservation regressed"
	)
	worker.current_task_id = -1
	_check(
		not world.get_workers_blocking_dig(_support(destination)).has(worker),
		"Final work-position support did not release with task ownership"
	)
	_dispose(world)


func _test_dig_completion_waits_for_committed_segment() -> void:
	var world := _world()
	var origin := Vector3i(-1, 3, 0)
	var destination := Vector3i(0, 3, 0)
	var final := Vector3i(1, 3, 0)
	var target_support := _support(destination)
	var digger_pos := target_support + Vector3i(0, 0, 1)
	# Traveler supports plus a separate ledge for the digger. The destination
	# column has air beneath the target so premature excavation triggers a fall.
	for cell in [_support(origin), target_support, _support(final), digger_pos + Vector3i.DOWN]:
		world.set_block_raw(cell.x, cell.y, cell.z, World.BLOCK_ID_GRANITE, true)
	world.set_block_raw(target_support.x, target_support.y - 1, target_support.z, World.BLOCK_ID_AIR, true)
	world.set_block_raw(target_support.x, target_support.y - 2, target_support.z, World.BLOCK_ID_GRANITE, true)
	var traveler := _moving_worker(origin, destination, final, 0.25)
	var digger := Worker.new()
	digger.worker_id = 42
	digger.position = Vector3(digger_pos)
	digger.state = Worker.WorkerState.WORKING
	var task_id := world.task_queue.add_dig_task(target_support)
	var task = world.task_queue.get_task(task_id)
	task.status = TaskQueue.TaskStatus.IN_PROGRESS
	task.assigned_worker = digger
	digger.current_task_id = task_id
	digger.work_timer = 0.0
	world.workers = [digger, traveler]
	var original_workers: Array = world.workers.duplicate()
	var saw_fall := false
	var support_removed := false
	var support_removed_before_clear := false
	for _frame in 240:
		world.update_workers(1.0 / 60.0)
		saw_fall = saw_fall or traveler.state == Worker.WorkerState.FALLING
		var removed_now := world.get_block_no_generate(
			target_support.x,
			target_support.y,
			target_support.z
		) == World.BLOCK_ID_AIR
		if removed_now and not support_removed:
			support_removed_before_clear = traveler.get_block_coord() != final or not traveler.path.is_empty()
		support_removed = support_removed or removed_now
		if support_removed and (not support_removed_before_clear or saw_fall):
			break
	_check(support_removed, "DIG never completed after traveler cleared the committed support")
	_check(not support_removed_before_clear, "DIG completed before traveler cleared the committed support")
	_check(not saw_fall, "Traveler fell because DIG removed a committed segment support")
	_check(not world.trace_events.has("fall_started"), "Traveler entered fall handling during committed-support repro")
	_check(not world.trace_events.has("worker_rescued"), "Traveler was relocated by rescue during committed-support repro")
	_check(traveler.get_block_coord() == final, "Traveler did not clear support before DIG completion")
	_check(world.workers.size() == 2, "Worker count changed during committed-support repro")
	_check(world.workers == original_workers, "Worker identity/order changed during committed-support repro")
	_check(is_instance_valid(digger) and is_instance_valid(traveler), "Worker instance became invalid during committed-support repro")
	_dispose(world)
