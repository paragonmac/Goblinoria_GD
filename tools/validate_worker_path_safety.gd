extends SceneTree


class FakeWorld:
	extends RefCounted

	const MIN_XZ := -4
	const MAX_XZ := 4

	var world_size_y := 4
	var task_queue := TaskQueue.new()

	func is_block_coord_valid(x: int, y: int, z: int) -> bool:
		return x >= MIN_XZ and x <= MAX_XZ \
			and z >= MIN_XZ and z <= MAX_XZ \
			and y >= 0 and y < world_size_y

	func get_block_no_generate(_x: int, y: int, _z: int) -> int:
		return 1 if y == 0 else 0

	func is_block_solid_id(block_id: int) -> bool:
		return block_id == 1

	func is_ramp_block_id(_block_id: int) -> bool:
		return false


class LongPathWorld:
	extends RefCounted

	var world_size_y := 4

	func is_block_coord_valid(x: int, y: int, z: int) -> bool:
		return x >= -4 and x <= 80 and z >= -4 and z <= 4 and y >= 0 and y < world_size_y

	func get_block_no_generate(_x: int, y: int, _z: int) -> int:
		return 1 if y == 0 else 0

	func is_block_solid_id(block_id: int) -> bool:
		return block_id == 1

	func is_ramp_block_id(_block_id: int) -> bool:
		return false


class RampWorld:
	extends RefCounted

	var world_size_y := 4

	func is_block_coord_valid(x: int, y: int, z: int) -> bool:
		return x >= -2 and x <= 2 and z >= -2 and z <= 2 and y >= 0 and y < world_size_y

	func get_block_no_generate(x: int, y: int, z: int) -> int:
		if y == 0:
			return 1
		if Vector3i(x, y, z) == Vector3i(0, 1, 0):
			return 1
		if Vector3i(x, y, z) == Vector3i(1, 1, 0):
			return 2
		return 0

	func is_block_solid_id(block_id: int) -> bool:
		return block_id == 1

	func is_ramp_block_id(block_id: int) -> bool:
		return block_id == 2


class DirectionalRampWorld:
	extends RefCounted

	var world_size_y := 4

	func is_block_coord_valid(x: int, y: int, z: int) -> bool:
		return x >= -2 and x <= 2 and z >= -2 and z <= 2 and y >= 0 and y < world_size_y

	func get_block_no_generate(x: int, y: int, z: int) -> int:
		if y == 0:
			return World.BLOCK_ID_GRANITE
		if Vector3i(x, y, z) == Vector3i(0, 1, 0):
			return World.RAMP_NORTH_ID
		if Vector3i(x, y, z) == Vector3i(0, 1, -1):
			return World.BLOCK_ID_GRANITE
		return World.BLOCK_ID_AIR

	func is_block_solid_id(block_id: int) -> bool:
		return block_id == World.BLOCK_ID_GRANITE or is_ramp_block_id(block_id)

	func is_ramp_block_id(block_id: int) -> bool:
		return World.RAMP_BLOCK_IDS.has(block_id)


class RescueWorld:
	extends RefCounted

	var world_size_y := 8
	var task_queue := TaskQueue.new()
	var trace_events: Array[String] = []

	func is_block_coord_valid(x: int, y: int, z: int) -> bool:
		return x >= -2 and x <= 2 and z >= -2 and z <= 2 and y >= 0 and y < world_size_y

	func get_block_no_generate(_x: int, y: int, _z: int) -> int:
		return World.BLOCK_ID_GRANITE if y == 3 else World.BLOCK_ID_AIR

	func is_block_solid_id(block_id: int) -> bool:
		return block_id == World.BLOCK_ID_GRANITE

	func is_ramp_block_id(block_id: int) -> bool:
		return World.RAMP_BLOCK_IDS.has(block_id)

	func find_surface_y(_x: int, _z: int) -> int:
		return 3

	func trace_worker_event(_worker: Worker, event: String, _task = null, _details: String = "") -> void:
		trace_events.append(event)


class CountingPathfinder:
	extends Pathfinder

	var walkable_checks := 0

	func is_walkable(world, x: int, y: int, z: int) -> bool:
		walkable_checks += 1
		return super.is_walkable(world, x, y, z)


func _make_threaded_path_snapshot():
	var snapshot := PathWorldSnapshot.new()
	snapshot.world_size_y = 4
	snapshot.chunk_size = World.CHUNK_SIZE
	snapshot.air_id = World.BLOCK_ID_AIR
	snapshot.min_block = Vector3i(-4, 0, -4)
	snapshot.max_block = Vector3i(80, 3, 4)
	snapshot.solid_table.resize(BlockRegistry.TABLE_SIZE)
	snapshot.solid_table[World.BLOCK_ID_GRANITE] = 1
	snapshot.ramp_table.resize(BlockRegistry.TABLE_SIZE)
	for cx in range(-1, 11):
		for cz in range(-1, 1):
			var blocks := PackedByteArray()
			blocks.resize(World.CHUNK_VOLUME)
			for lx in range(World.CHUNK_SIZE):
				for lz in range(World.CHUNK_SIZE):
					var index := (lz * World.CHUNK_SIZE + 0) * World.CHUNK_SIZE + lx
					blocks[index] = World.BLOCK_ID_GRANITE
			snapshot.chunks[Vector3i(cx, 0, cz)] = blocks
	var target := Vector3i(60, 1, 0)
	var target_chunk := Vector3i(7, 0, 0)
	var target_blocks: PackedByteArray = snapshot.chunks[target_chunk]
	var target_index := (
		target.z * World.CHUNK_SIZE + target.y
	) * World.CHUNK_SIZE + (target.x % World.CHUNK_SIZE)
	target_blocks[target_index] = World.BLOCK_ID_GRANITE
	snapshot.chunks[target_chunk] = target_blocks
	return snapshot


func _make_snapshot_index_contract() -> PathWorldSnapshot:
	var snapshot := PathWorldSnapshot.new()
	snapshot.world_size_y = World.CHUNK_SIZE
	snapshot.chunk_size = World.CHUNK_SIZE
	snapshot.air_id = World.BLOCK_ID_AIR
	snapshot.min_block = Vector3i.ZERO
	snapshot.max_block = Vector3i(World.CHUNK_SIZE - 1, World.CHUNK_SIZE - 1, World.CHUNK_SIZE - 1)
	snapshot.solid_table.resize(BlockRegistry.TABLE_SIZE)
	snapshot.ramp_table.resize(BlockRegistry.TABLE_SIZE)
	var blocks := PackedByteArray()
	blocks.resize(World.CHUNK_VOLUME)
	var index := (3 * World.CHUNK_SIZE + 2) * World.CHUNK_SIZE + 1
	blocks[index] = World.BLOCK_ID_COAL
	snapshot.chunks[Vector3i.ZERO] = blocks
	return snapshot


func _init() -> void:
	var world := FakeWorld.new()
	var pathfinder := Pathfinder.new()
	var support_pos := Vector3i(1, 0, 0)
	var task_id := world.task_queue.add_dig_task(support_pos)
	world.task_queue.clear()
	var requeued_id := world.task_queue.add_dig_task(support_pos)
	var queue_clear_ok: bool = \
		world.task_queue.active_count() == 1 \
		and world.task_queue.next_id == 2 \
		and requeued_id == 1 \
		and world.task_queue.has_active_task_at(support_pos, TaskQueue.TaskType.DIG)
	task_id = requeued_id
	var same_level_work_position_ok: bool = \
		pathfinder.has_walkable_adjacent_on_level(world, Vector3i.ZERO, 1) \
		and not pathfinder.has_walkable_adjacent_on_level(world, Vector3i.ZERO, 2)

	var active_support_path := pathfinder.find_path(
		world,
		Vector3i(0, 1, 0),
		Vector3i(2, 1, 0),
		false,
		false
	)
	if not active_support_path.has(Vector3i(1, 1, 0)):
		push_error("Worker path did not use available queued dig support")
		quit(1)
		return

	var task = world.task_queue.get_task(task_id)
	task.status = TaskQueue.TaskStatus.COMPLETED
	var direct_path := pathfinder.find_path(
		world,
		Vector3i(0, 1, 0),
		Vector3i(2, 1, 0),
		false,
		false
	)
	if not direct_path.has(Vector3i(1, 1, 0)):
		push_error("Worker path did not restore completed dig support")
		quit(1)
		return

	var worker := Worker.new()
	worker.worker_id = 1
	worker.position = Vector3(0, 1, 0)
	var ramp_worker := Worker.new()
	ramp_worker.state = Worker.WorkerState.MOVING
	ramp_worker.position = Vector3(0.49, 1.75, 0)
	ramp_worker.path = [Vector3i(0, 2, 0), Vector3i(1, 1, 0)]
	ramp_worker.path_index = 1
	var ramp_world := RampWorld.new()
	var ramp_transition_ok: bool = \
		not ramp_worker._has_standing_support(ramp_world) \
		and ramp_worker._has_supported_path_segment(ramp_world) \
		and not ramp_worker._update_falling(0.016, ramp_world, null) \
		and ramp_worker.state == Worker.WorkerState.MOVING
	var directional_ramp_world := DirectionalRampWorld.new()
	var legal_ramp_up_path := pathfinder.find_path(
		directional_ramp_world,
		Vector3i(0, 1, 1),
		Vector3i(0, 2, -1),
		false,
		false
	)
	var directional_ramp_ok: bool = \
		legal_ramp_up_path.has(Vector3i(0, 1, 0)) \
		and legal_ramp_up_path.has(Vector3i(0, 2, -1)) \
		and not pathfinder.can_move_same_level(directional_ramp_world, Vector3i(0, 1, -1), Vector3i(0, 1, 0)) \
		and not pathfinder.is_walkable(directional_ramp_world, 0, 2, 0)
	var interpolating_ramp_worker := Worker.new()
	interpolating_ramp_worker.state = Worker.WorkerState.MOVING
	interpolating_ramp_worker.position = Vector3(0, 1.75, -0.75)
	interpolating_ramp_worker.path = [
		Vector3i(0, 2, -1),
		Vector3i(0, 1, 0),
		Vector3i(0, 1, 1),
	]
	interpolating_ramp_worker.path_index = 1
	var ramp_descent_interpolation_ok: bool = interpolating_ramp_worker._validate_next_path_node(
		directional_ramp_world,
		TaskQueue.new(),
		pathfinder
	)
	var ramp_face_worker := Worker.new()
	ramp_face_worker.position = Vector3(0, 1, 0)
	var ramp_face_dig := TaskQueue.Task.new(103, Vector3i(0, 1, -1), TaskQueue.TaskType.DIG, 0)
	var ramp_face_work_blocked_ok: bool = not ramp_face_worker.can_work_task(
		ramp_face_dig,
		directional_ramp_world,
		pathfinder
	)
	var ramp_segment_worker := Worker.new()
	ramp_segment_worker.state = Worker.WorkerState.MOVING
	ramp_segment_worker.position = Vector3(0.49, 1.0, 1.0)
	ramp_segment_worker.path = [Vector3i(0, 1, 1), Vector3i(0, 1, 0)]
	ramp_segment_worker.path_index = 1
	var same_level_ramp_segment_ok: bool = \
		ramp_segment_worker._has_supported_path_segment(directional_ramp_world) \
		and not ramp_segment_worker._update_falling(0.016, directional_ramp_world, null) \
		and ramp_segment_worker.state == Worker.WorkerState.MOVING
	var segment_worker := Worker.new()
	segment_worker.state = Worker.WorkerState.MOVING
	segment_worker.position = Vector3(0, 1, 0)
	segment_worker.path = [Vector3i(0, 1, 0), Vector3i(1, 1, 0)]
	segment_worker.path_index = 1
	segment_worker.target_pos = Vector3(1, 1, 0)
	var counting_pathfinder := CountingPathfinder.new()
	segment_worker.update_moving(0.1, world, world.task_queue, counting_pathfinder)
	var checks_after_commit: int = counting_pathfinder.walkable_checks
	segment_worker.update_moving(0.1, world, world.task_queue, counting_pathfinder)
	var segment_validated_once_ok: bool = \
		checks_after_commit == 1 \
		and counting_pathfinder.walkable_checks == checks_after_commit \
		and segment_worker.path_segment_validated
	var path_owner_worker := Worker.new()
	var path_owner_queue := TaskQueue.new()
	var path_owner_task_id := path_owner_queue.add_dig_task(Vector3i(1, 1, 0))
	var path_owner_task = path_owner_queue.get_task(path_owner_task_id)
	var auction_path := [Vector3i(0, 1, 0), Vector3i(1, 1, 0)]
	path_owner_worker.assign_task_with_path(null, path_owner_queue, path_owner_task, auction_path, 0.0)
	auction_path.clear()
	var assigned_path_owned_ok: bool = path_owner_worker.path.size() == 2
	var horizontal_dig := TaskQueue.Task.new(100, Vector3i(1, 1, 0), TaskQueue.TaskType.DIG, 0)
	var downward_dig := TaskQueue.Task.new(101, Vector3i(1, 0, 0), TaskQueue.TaskType.DIG, 0)
	var horizontal_dig_ok: bool = worker.can_work_task(horizontal_dig, world, pathfinder) \
		and not worker.can_work_task(downward_dig, world, pathfinder)
	var horizontal_dig_path := worker.find_path_to_task(
		world,
		Vector3i(0, 1, 0),
		TaskQueue.TaskType.DIG,
		Vector3i(1, 1, 0),
		pathfinder
	)
	var downward_dig_path := worker.find_path_to_task(
		world,
		Vector3i(0, 1, 0),
		TaskQueue.TaskType.DIG,
		Vector3i(1, 0, 0),
		pathfinder
	)
	var horizontal_dig_path_ok: bool = \
		horizontal_dig_path.size() > 0 \
		and horizontal_dig_path[horizontal_dig_path.size() - 1].y == 1 \
		and downward_dig_path.is_empty()
	var long_path_world := LongPathWorld.new()
	var long_dig_path := worker.find_path_to_task(
		long_path_world,
		Vector3i(0, 1, 0),
		TaskQueue.TaskType.DIG,
		Vector3i(60, 1, 0),
		pathfinder
	)
	var long_dig_path_ok: bool = \
		not long_dig_path.is_empty() \
		and long_dig_path[long_dig_path.size() - 1].y == 1 \
		and abs(long_dig_path[long_dig_path.size() - 1].x - 60) \
			+ abs(long_dig_path[long_dig_path.size() - 1].z) == 1
	var scheduler := PathSearchScheduler.new()
	var threaded_snapshot = _make_threaded_path_snapshot()
	var index_snapshot := _make_snapshot_index_contract()
	var snapshot_index_ok: bool = \
		index_snapshot.get_block_no_generate(1, 2, 3) == World.BLOCK_ID_COAL \
		and index_snapshot.get_block_no_generate(1, 3, 2) == World.BLOCK_ID_AIR
	var queued_usec := Time.get_ticks_usec()
	scheduler.start()
	scheduler._enqueue_job({
		"job_id": 1,
		"kind": "assignment",
		"request_id": 0,
		"auction_id": 1,
		"task_id": 1,
		"task_type": TaskQueue.TaskType.DIG,
		"worker_id": 1,
		"start": Vector3i(0, 1, 0),
		"target": Vector3i(60, 1, 0),
		"max_iterations": Pathfinder.TASK_SEARCH_MAX_ITERATIONS,
		"snapshot": threaded_snapshot,
		"snapshot_ms": 0.25,
		"queued_usec": queued_usec,
	})
	var threaded_result: Dictionary = {}
	var threaded_deadline := Time.get_ticks_msec() + 2000
	while threaded_result.is_empty() and Time.get_ticks_msec() < threaded_deadline:
		OS.delay_msec(1)
		threaded_result = scheduler.pop_result()
	scheduler.stop()
	var threaded_path: Array = threaded_result.get("path", [])
	var threaded_scheduler_ok: bool = \
		not threaded_path.is_empty() \
		and threaded_path[threaded_path.size() - 1].y == 1 \
		and abs(threaded_path[threaded_path.size() - 1].x - 60) \
			+ abs(threaded_path[threaded_path.size() - 1].z) == 1 \
		and float(threaded_result.get("snapshot_ms", 0.0)) == 0.25 \
		and float(threaded_result.get("queue_wait_ms", -1.0)) >= 0.0
	worker.current_task_id = 1
	worker.path = [Vector3i(0, 1, 0), Vector3i(2, 1, 0)]
	var bottom_level_stable: bool = worker._can_stand_at(world, 0, 0, 0)
	var rescue_world := RescueWorld.new()
	var stranded_worker := Worker.new()
	stranded_worker.position = Vector3(1, 0, 1)
	stranded_worker.update_worker(0.016, rescue_world, rescue_world.task_queue, pathfinder)
	var low_position_rescue_ok: bool = \
		stranded_worker.get_block_coord() == Vector3i(1, 4, 1) \
		and stranded_worker.state == Worker.WorkerState.IDLE \
		and rescue_world.trace_events.has("worker_rescued")
	rescue_world.trace_events.clear()
	var falling_void_worker := Worker.new()
	falling_void_worker.state = Worker.WorkerState.FALLING
	falling_void_worker.position = Vector3(1, 2, 1)
	falling_void_worker._update_falling(0.016, rescue_world, rescue_world.task_queue)
	var fall_target_rescue_ok: bool = \
		falling_void_worker.get_block_coord() == Vector3i(1, 4, 1) \
		and falling_void_worker.state == Worker.WorkerState.IDLE \
		and rescue_world.trace_events.has("worker_rescued")
	var worker_two := Worker.new()
	worker_two.worker_id = 2
	var reservation_world := World.new()
	reservation_world.workers = [worker, worker_two]
	var blockers := reservation_world.get_workers_blocking_dig(Vector3i(2, 0, 0))
	var support_reserved := blockers.has(worker)

	var near_blocked_id := reservation_world.task_queue.add_dig_task(Vector3i(1, 0, 1))
	var far_blocked_id := reservation_world.task_queue.add_dig_task(Vector3i(3, 0, 3))
	var near_reachable_id := reservation_world.task_queue.add_dig_task(Vector3i(-1, 0, -1))
	var near_blocked = reservation_world.task_queue.get_task(near_blocked_id)
	var far_blocked = reservation_world.task_queue.get_task(far_blocked_id)
	var near_reachable = reservation_world.task_queue.get_task(near_reachable_id)
	near_blocked.accessibility = TaskQueue.TaskAccessibility.UNREACHABLE
	far_blocked.accessibility = TaskQueue.TaskAccessibility.UNREACHABLE
	near_reachable.accessibility = TaskQueue.TaskAccessibility.REACHABLE
	var task_manager := TaskManager.new(reservation_world, reservation_world.task_queue)
	var stair_convert_pos := Vector3i(0, 0, 1)
	var planned_dig_id := reservation_world.task_queue.add_dig_task(stair_convert_pos)
	var stairs_replaced_pending_dig_ok: bool = \
		task_manager.queue_task_request(TaskQueue.TaskType.STAIRS, stair_convert_pos, World.RAMP_NORTH_ID) \
		and not reservation_world.task_queue.has_active_task_at(stair_convert_pos, TaskQueue.TaskType.DIG) \
		and reservation_world.task_queue.has_active_task_at(stair_convert_pos, TaskQueue.TaskType.STAIRS) \
		and reservation_world.task_queue.get_task(planned_dig_id) == null
	var cancel_pos := Vector3i(0, 0, 2)
	var cancel_dig_id := reservation_world.task_queue.add_dig_task(cancel_pos)
	var cancel_stairs_id := reservation_world.task_queue.add_stairs_task(cancel_pos, World.RAMP_NORTH_ID)
	var cancelled_tasks: Array = task_manager.cancel_pending_task_requests_at(cancel_pos)
	var pending_cancel_ok: bool = \
		cancelled_tasks.size() == 2 \
		and reservation_world.task_queue.get_task(cancel_dig_id) == null \
		and reservation_world.task_queue.get_task(cancel_stairs_id) == null \
		and not reservation_world.task_queue.has_pending_task_at(cancel_pos)
	var in_progress_cancel_pos := Vector3i(0, 0, 3)
	var in_progress_cancel_id := reservation_world.task_queue.add_dig_task(in_progress_cancel_pos)
	var in_progress_cancel_task = reservation_world.task_queue.get_task(in_progress_cancel_id)
	in_progress_cancel_task.status = TaskQueue.TaskStatus.IN_PROGRESS
	var in_progress_cancel_blocked_ok: bool = \
		task_manager.cancel_pending_task_requests_at(in_progress_cancel_pos).is_empty() \
		and reservation_world.task_queue.get_task(in_progress_cancel_id) != null
	var stair_world := World.new()
	stair_world._init_ramp_lookup()
	stair_world.block_registry.load_from_csv(World.BLOCK_DATA_PATH)
	stair_world.set_block_raw(0, 0, 0, World.BLOCK_ID_GRANITE, true)
	stair_world.set_block_raw(1, 0, 0, World.RAMP_NORTH_ID, true)
	var stairs_on_supported_air_ok: bool = stair_world.can_place_stairs_at(0, 1, 0)
	var unsupported_stairs_blocked_ok: bool = not stair_world.can_place_stairs_at(2, 1, 0)
	var ramp_supported_stairs_blocked_ok: bool = not stair_world.can_place_stairs_at(1, 1, 0)
	task_manager.mark_worker_unreachable_for_task(near_reachable, worker)
	var per_worker_failure_ok: bool = \
		near_reachable.accessibility == TaskQueue.TaskAccessibility.REACHABLE \
		and near_reachable.is_worker_unreachable(worker.worker_id, Time.get_ticks_msec()) \
		and not near_reachable.is_worker_unreachable(worker_two.worker_id, Time.get_ticks_msec())
	var expired_failure := TaskQueue.Task.new(102, Vector3i.ZERO, TaskQueue.TaskType.DIG, 0)
	expired_failure.mark_worker_unreachable(worker.worker_id, 0)
	var per_worker_failure_expiry_ok: bool = not expired_failure.is_worker_unreachable(
		worker.worker_id,
		TaskQueue.WORKER_UNREACHABLE_TTL_MSEC + 1
	)
	task_manager.invalidate_task_accessibility(Vector3i.ZERO)
	var local_invalidation_ok: bool = \
		near_blocked.accessibility == TaskQueue.TaskAccessibility.UNKNOWN \
		and far_blocked.accessibility == TaskQueue.TaskAccessibility.UNREACHABLE \
		and near_reachable.accessibility == TaskQueue.TaskAccessibility.REACHABLE \
		and near_reachable.unreachable_workers.is_empty()
	var batch_blocked_id := reservation_world.task_queue.add_dig_task(Vector3i(-2, 0, 2))
	var batch_blocked = reservation_world.task_queue.get_task(batch_blocked_id)
	task_manager.recheck_task_accessibility()
	var batch_classification_ok: bool = \
		near_blocked.accessibility == TaskQueue.TaskAccessibility.UNREACHABLE \
		and batch_blocked.accessibility == TaskQueue.TaskAccessibility.UNREACHABLE
	task_manager.assignment_best_worker = worker_two
	task_manager.assignment_best_path = [Vector3i.ZERO, Vector3i.RIGHT, Vector3i(2, 0, 0)]
	var closest_bid_rule_ok: bool = \
		task_manager._is_better_assignment_bid(2, 4) \
		and task_manager._is_better_assignment_bid(3, worker.worker_id) \
		and not task_manager._is_better_assignment_bid(3, 3) \
		and not task_manager._is_better_assignment_bid(4, worker.worker_id)
	task_manager.reset_assignment_auction()

	var owner_worker := Worker.new()
	owner_worker.worker_id = 4
	owner_worker.position = Vector3(5, 1, 0)
	var arrived_worker := Worker.new()
	arrived_worker.worker_id = 3
	arrived_worker.position = Vector3(0, 1, 0)
	var transfer_task_id := reservation_world.task_queue.add_dig_task(Vector3i(1, 1, 0))
	var transfer_task = reservation_world.task_queue.get_task(transfer_task_id)
	transfer_task.status = TaskQueue.TaskStatus.IN_PROGRESS
	transfer_task.accessibility = TaskQueue.TaskAccessibility.REACHABLE
	transfer_task.assigned_worker = owner_worker
	owner_worker.current_task_id = transfer_task_id
	owner_worker.state = Worker.WorkerState.MOVING
	owner_worker.movement_intent = Worker.MovementIntent.TASK
	owner_worker.path = [
		Vector3i(5, 1, 0),
		Vector3i(4, 1, 0),
		Vector3i(3, 1, 0),
		Vector3i(2, 1, 0),
		Vector3i(1, 1, 0),
	]
	owner_worker.path_index = 1
	var arrived_worker_transfer_ok: bool = \
		task_manager.transfer_task_to_arrived_worker(transfer_task, arrived_worker) \
		and transfer_task.assigned_worker == arrived_worker \
		and arrived_worker.current_task_id == transfer_task_id \
		and owner_worker.current_task_id == -1 \
		and owner_worker.movement_intent == Worker.MovementIntent.WANDER

	reservation_world.workers.clear()
	worker.free()
	worker_two.free()
	ramp_worker.free()
	ramp_face_worker.free()
	ramp_segment_worker.free()
	interpolating_ramp_worker.free()
	segment_worker.free()
	path_owner_worker.free()
	stranded_worker.free()
	falling_void_worker.free()
	owner_worker.free()
	arrived_worker.free()
	task_manager.shutdown()
	reservation_world.free()
	stair_world.free()
	if not support_reserved:
		push_error("Worker final standing support was not reserved")
		quit(1)
		return
	if not queue_clear_ok:
		push_error("TaskQueue.clear did not reset task indexes")
		quit(1)
		return
	if not bottom_level_stable:
		push_error("Worker world-bottom fallback was not stable")
		quit(1)
		return
	if not low_position_rescue_ok:
		push_error("Worker stranded below the walkable floor was not rescued")
		quit(1)
		return
	if not fall_target_rescue_ok:
		push_error("Worker falling toward the world bottom was not rescued")
		quit(1)
		return
	if not horizontal_dig_ok:
		push_error("Worker DIG work was not restricted to the horizontal plane")
		quit(1)
		return
	if not horizontal_dig_path_ok:
		push_error("Worker DIG path was not restricted to the target's horizontal plane")
		quit(1)
		return
	if not long_dig_path_ok:
		push_error("Distance-scaled worker search failed to find a 60-block DIG route")
		quit(1)
		return
	if not threaded_scheduler_ok:
		push_error("Threaded path scheduler failed its 60-block snapshot round trip")
		quit(1)
		return
	if not snapshot_index_ok:
		push_error("PathWorldSnapshot did not match chunk block index ordering")
		quit(1)
		return
	if not ramp_transition_ok:
		push_error("Supported ramp transition incorrectly triggered a fall")
		quit(1)
		return
	if not directional_ramp_ok:
		push_error("Directional ramp traversal contract failed")
		quit(1)
		return
	if not ramp_descent_interpolation_ok:
		push_error("Worker invalidated a legal ramp descent while interpolating between path nodes")
		quit(1)
		return
	if not ramp_face_work_blocked_ok:
		push_error("Worker could dig through a blocked ramp face")
		quit(1)
		return
	if not same_level_ramp_segment_ok:
		push_error("Worker fell while traversing a supported ramp segment")
		quit(1)
		return
	if not segment_validated_once_ok:
		push_error("Worker revalidated a committed path segment while interpolating")
		quit(1)
		return
	if not assigned_path_owned_ok:
		push_error("Worker assignment retained the auction's mutable path array")
		quit(1)
		return
	if not same_level_work_position_ok:
		push_error("Same-level task work position classification was incorrect")
		quit(1)
		return
	if not per_worker_failure_ok:
		push_error("Worker-specific task path failure affected other workers")
		quit(1)
		return
	if not closest_bid_rule_ok:
		push_error("Task assignment did not prefer shortest paths with deterministic worker-ID ties")
		quit(1)
		return
	if not arrived_worker_transfer_ok:
		push_error("Task ownership did not transfer to an assistant already at the work position")
		quit(1)
		return
	if not per_worker_failure_expiry_ok:
		push_error("Worker-specific task path failure did not expire")
		quit(1)
		return
	if not local_invalidation_ok:
		push_error("Terrain change did not preserve localized accessibility state")
		quit(1)
		return
	if not batch_classification_ok:
		push_error("Impossible tasks were not classified in one accessibility update")
		quit(1)
		return
	if not stairs_replaced_pending_dig_ok:
		push_error("Stairs designation did not replace a pending dig designation")
		quit(1)
		return
	if not pending_cancel_ok:
		push_error("Erase mode cancellation did not remove pending designations")
		quit(1)
		return
	if not in_progress_cancel_blocked_ok:
		push_error("Erase mode cancellation removed an in-progress task")
		quit(1)
		return
	if not stairs_on_supported_air_ok:
		push_error("Stairs could not be placed in empty air above solid support")
		quit(1)
		return
	if not unsupported_stairs_blocked_ok:
		push_error("Stairs were allowed in unsupported air")
		quit(1)
		return
	if not ramp_supported_stairs_blocked_ok:
		push_error("Stairs were allowed above ramp support")
		quit(1)
		return

	print("Worker path safety contract OK")
	quit(0)
