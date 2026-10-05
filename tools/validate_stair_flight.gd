extends SceneTree

const StairFlightScript = preload("res://scripts/stair_flight.gd")

class TestWorld extends World:
	func ensure_chunk_generated(coord: Vector3i) -> ChunkData:
		var chunk := ensure_chunk(coord)
		if chunk != null: chunk.generated = true
		return chunk

var checks := 0
var failures := 0


func _check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures += 1
		push_error(message)


func _init() -> void:
	_test_helper_contract()
	_test_path_contract()
	_test_queue_and_atomic_completion()
	_test_worker_completion()
	_test_worker_blocked_and_stale_flights()
	_test_side_access()
	if failures == 0:
		print("Stair flight contract OK (%d checks)" % checks)
		quit(0)
	else:
		push_error("Stair flight contract failed (%d/%d checks)" % [failures, checks])
		quit(1)


func _test_helper_contract() -> void:
	for rotation in 4:
		var lower_id := StairFlightScript.lower_id(rotation)
		var upper_id := StairFlightScript.upper_id(rotation)
		_check(StairFlightScript.is_flight(lower_id), "lower ID is not a flight")
		_check(StairFlightScript.is_flight(upper_id), "upper ID is not a flight")
		_check(StairFlightScript.is_lower(lower_id), "lower ID classification failed")
		_check(not StairFlightScript.is_lower(upper_id), "upper ID classified as lower")
		_check(StairFlightScript.rotation_for(lower_id) == rotation, "lower rotation round trip failed")
		_check(StairFlightScript.rotation_for(upper_id) == rotation, "upper rotation round trip failed")
		var anchor := Vector3i(4, 2, 4)
		var flight_cells := StairFlightScript.cells(anchor, rotation)
		_check(flight_cells.size() == 2, "flight footprint size changed")
		_check(flight_cells[1] == anchor + StairFlightScript.direction(rotation), "flight direction changed")
		_check(is_equal_approx(StairFlightScript.center_offset(lower_id), -0.25), "lower mesh center offset changed")
		_check(is_equal_approx(StairFlightScript.center_offset(upper_id), 0.25), "upper mesh center offset changed")
		var low_heights := StairFlightScript.corner_heights(lower_id)
		var high_heights := StairFlightScript.corner_heights(upper_id)
		_check(low_heights.values().has(-0.5) and low_heights.values().has(0.0), "lower half heights are wrong")
		_check(high_heights.values().has(0.0) and high_heights.values().has(0.5), "upper half heights are wrong")
	_check(not StairFlightScript.is_flight(123), "terrain slope range leaked into flight IDs")
	_check(not StairFlightScript.is_flight(132), "flight ID range is too broad")


func _make_world() -> World:
	var world := TestWorld.new()
	world.world_size_y = 8
	world._init_ramp_lookup()
	world.block_registry.load_from_csv(World.BLOCK_DATA_PATH)
	return world


func _load_cell(world: World, pos: Vector3i, block_id: int) -> void:
	world.set_block_raw(pos.x, pos.y, pos.z, block_id, true)


func _prepare_flight_area(world: World, anchor: Vector3i, rotation: int, up: bool) -> void:
	for cell: Vector3i in StairFlightScript.cells(anchor, rotation):
		_load_cell(world, cell + Vector3i.DOWN, World.BLOCK_ID_GRANITE)
		_load_cell(world, cell + Vector3i.UP, World.BLOCK_ID_AIR)
		_load_cell(world, cell, World.BLOCK_ID_AIR if up else World.BLOCK_ID_GRANITE)


func _test_path_contract() -> void:
	var world := _make_world()
	var anchor := Vector3i(0, 2, 0)
	var rotation := 0
	var cells := StairFlightScript.cells(anchor, rotation)
	_prepare_flight_area(world, anchor, rotation, true)
	_load_cell(world, anchor, StairFlightScript.lower_id(rotation))
	_load_cell(world, cells[1], StairFlightScript.upper_id(rotation))
	_load_cell(world, anchor + StairFlightScript.direction(rotation) * 2, World.BLOCK_ID_GRANITE)
	_load_cell(world, anchor + StairFlightScript.direction(rotation) * 2 + Vector3i.UP, World.BLOCK_ID_AIR)
	_load_cell(world, anchor + StairFlightScript.direction(rotation) * 2 + Vector3i.DOWN, World.BLOCK_ID_GRANITE)
	var entry := anchor - StairFlightScript.direction(rotation)
	_load_cell(world, entry, World.BLOCK_ID_AIR)
	_load_cell(world, entry + Vector3i.DOWN, World.BLOCK_ID_GRANITE)
	var exit := anchor + StairFlightScript.direction(rotation) * 2 + Vector3i.UP
	var pathfinder := Pathfinder.new()
	_check(pathfinder.can_traverse(world, entry, anchor), "low-side entry rejected")
	_check(pathfinder.can_traverse(world, anchor, cells[1]), "lower-to-upper midpoint rejected")
	_check(pathfinder.can_traverse(world, cells[1], exit), "upper-to-high ascent rejected")
	_check(pathfinder.can_traverse(world, exit, cells[1]), "high-to-upper descent rejected")
	_check(pathfinder.can_traverse(world, cells[1], anchor), "upper-to-lower midpoint rejected")
	_check(pathfinder.can_traverse(world, anchor, entry), "low-side exit rejected")
	_check(not pathfinder.can_traverse(world, Vector3i(1, 2, 0), anchor), "unsupported side cell entered lower half")
	_check(not pathfinder.can_traverse(world, cells[1], anchor + StairFlightScript.direction(rotation)), "high-side same-level exit allowed")
	var worker := Worker.new()
	_check(is_equal_approx(worker._ramp_center_offset(StairFlightScript.lower_id(rotation)), 0.25), "worker lower physical endpoint is wrong")
	_check(is_equal_approx(worker._ramp_center_offset(StairFlightScript.upper_id(rotation)), 0.75), "worker upper physical endpoint is wrong")
	worker.path = [anchor, cells[1]]
	worker.path_index = 1
	worker.state = Worker.WorkerState.MOVING
	worker.position = Vector3(anchor) + Vector3(0.0, 0.25, 0.0)
	worker.set_target_from_path(world)
	_check(is_equal_approx(worker.target_pos.y, 2.75), "worker interpolation target is wrong")
	_check(worker._has_supported_path_segment(world), "worker midpoint segment is unsupported")
	world.set_block_raw(cells[1].x, cells[1].y, cells[1].z, World.BLOCK_ID_AIR, true)
	_check(not pathfinder.can_traverse(world, anchor, cells[1]), "broken pair remained traversable")
	worker.free()
	world.free()
	_test_all_orientation_traversal()


func _test_all_orientation_traversal() -> void:
	var world := _make_world()
	var pathfinder := Pathfinder.new()
	for rotation in 4:
		var anchor := Vector3i(8 * rotation, 2, 8)
		var cells := StairFlightScript.cells(anchor, rotation)
		_prepare_flight_area(world, anchor, rotation, true)
		_load_cell(world, anchor, StairFlightScript.lower_id(rotation))
		_load_cell(world, cells[1], StairFlightScript.upper_id(rotation))
		var direction := StairFlightScript.direction(rotation)
		var entry := anchor - direction
		var exit := anchor + direction * 2 + Vector3i.UP
		_load_cell(world, entry, World.BLOCK_ID_AIR)
		_load_cell(world, entry + Vector3i.DOWN, World.BLOCK_ID_GRANITE)
		_load_cell(world, exit, World.BLOCK_ID_AIR)
		_load_cell(world, exit + Vector3i.DOWN, World.BLOCK_ID_GRANITE)
		_check(pathfinder.can_traverse(world, entry, anchor), "orientation %d low entry rejected" % rotation)
		_check(pathfinder.can_traverse(world, anchor, cells[1]), "orientation %d midpoint rejected" % rotation)
		_check(pathfinder.can_traverse(world, cells[1], exit), "orientation %d ascent rejected" % rotation)
		_check(pathfinder.can_traverse(world, exit, cells[1]), "orientation %d descent rejected" % rotation)
		_load_cell(world, cells[1] + Vector3i.UP, World.BLOCK_ID_GRANITE)
		_check(not pathfinder.can_traverse(world, entry, anchor) and not pathfinder.can_traverse(world, exit, cells[1]), "Covered pair blocks both approaches")
		_load_cell(world, cells[1] + Vector3i.UP, World.BLOCK_ID_AIR)
		_load_cell(world, anchor + Vector3i.DOWN, World.BLOCK_ID_AIR)
		_check(not pathfinder.is_walkable(world, cells[1].x, cells[1].y, cells[1].z), "Missing support invalidates both halves")
	world.free()


func _test_queue_and_atomic_completion() -> void:
	var world := _make_world()
	world.task_manager = TaskManager.new(world, world.task_queue)
	var anchor := Vector3i(4, 2, 4)
	var rotation := 1
	_prepare_flight_area(world, anchor, rotation, true)
	var cells := StairFlightScript.cells(anchor, rotation)
	world.task_queue.add_dig_task(cells[0])
	world.task_queue.add_dig_task(cells[1])
	_check(world.queue_stair_flight(anchor, rotation, true), "flight queueing failed")
	var task = world.task_queue.find_nearest(TaskQueue.TaskType.STAIRS, Vector3(anchor))
	_check(task != null and bool(task.data.get("flight", false)), "flight task metadata missing")
	_check(world.task_queue.get_active_tasks_at(cells[1]).has(task), "upper footprint reservation missing")
	_check(not world.task_queue.has_active_task_at(cells[0], TaskQueue.TaskType.DIG), "lower dig was not replaced")
	_check(not world.task_queue.has_active_task_at(cells[1], TaskQueue.TaskType.DIG), "upper dig was not replaced")
	_check(not world.queue_task_request(TaskQueue.TaskType.PLACE, cells[1], World.PLACE_MATERIAL_ID), "place overlapped reserved upper half")
	_check(world.cancel_pending_task_requests_at(cells[1]).size() == 1, "cancel by upper half failed")
	_check(world.task_queue.get_active_tasks_at(cells[0]).is_empty(), "lower reservation survived upper cancel")

	_prepare_flight_area(world, anchor, rotation, true)
	_check(world.queue_stair_flight(anchor, rotation, true), "second flight queueing failed")
	task = world.task_queue.find_nearest(TaskQueue.TaskType.STAIRS, Vector3(anchor))
	_check(task != null, "queued flight task not found")
	_check(task.expected_blocks == [World.BLOCK_ID_AIR, World.BLOCK_ID_AIR], "Queue captures expected terrain before dispatch")
	world.set_block_raw(cells[0].x, cells[0].y, cells[0].z, World.BLOCK_ID_GRANITE, true)
	_check(not world.complete_stair_flight(task), "stale pair completed partially")
	_check(world.get_block_no_generate(cells[1].x, cells[1].y, cells[1].z) == World.BLOCK_ID_AIR, "atomic failure changed upper half")
	world.set_block_raw(cells[0].x, cells[0].y, cells[0].z, World.BLOCK_ID_AIR, true)
	_check(world.complete_stair_flight(task), "valid pair completion failed")
	_check(world.get_block_no_generate(cells[0].x, cells[0].y, cells[0].z) == StairFlightScript.lower_id(rotation), "lower half material wrong")
	_check(world.get_block_no_generate(cells[1].x, cells[1].y, cells[1].z) == StairFlightScript.upper_id(rotation), "upper half material wrong")
	world.task_queue.remove_task(task)
	world.task_manager.shutdown()
	world.free()


func _test_worker_completion() -> void:
	for up in [true, false]:
		for rotation in 4:
			var world := _make_world()
			world.task_manager = TaskManager.new(world, world.task_queue)
			for x in range(-3, 4):
				for z in range(-3, 4):
					_load_cell(world, Vector3i(x, 1, z), World.BLOCK_ID_GRANITE)
					_load_cell(world, Vector3i(x, 2, z), World.BLOCK_ID_AIR if up else World.BLOCK_ID_GRANITE)
			var anchor := Vector3i(0, 2, 0)
			_prepare_flight_area(world, anchor, rotation, up)
			_check(world.queue_stair_flight(anchor, rotation, up), "Queue worker-executed flight")
			var task = world.task_queue.find_nearest(TaskQueue.TaskType.STAIRS, Vector3(anchor))
			var goals := TaskWorkPositionRules.stair_work_positions(world, world.pathfinder, anchor, rotation)
			_check(not goals.is_empty(), "Flight has a legal work position")
			if goals.is_empty():
				world.task_manager.shutdown()
				world.free()
				continue
			var cells := StairFlightScript.cells(anchor, rotation)
			for goal in goals:
				_check(not cells.has(goal) and not cells.has(goal - Vector3i.UP), "Work goals cannot obstruct their own construction")
			var worker := Worker.new()
			worker.worker_id = 1
			worker.position = Vector3(goals[0])
			worker.path = [goals[0]]
			worker.current_task_id = task.id
			worker.state = Worker.WorkerState.WORKING
			task.assigned_worker = worker
			task.status = TaskQueue.TaskStatus.IN_PROGRESS
			world.workers.append(worker)
			_check(worker.can_work_task(task, world, world.pathfinder), "Live work validation agrees with shared goals")
			_check(world.cancel_pending_task_requests_at(cells[1]).is_empty(), "Active flight cannot be erased as pending")
			worker.update_working(1.0, world, world.task_queue, world.pathfinder)
			_check(world.task_queue.active_count() == 0, "Worker completes one whole flight")
			_check(world.get_block_no_generate(anchor.x, anchor.y, anchor.z) == StairFlightScript.lower_id(rotation) and world.get_block_no_generate(cells[1].x, cells[1].y, cells[1].z) == StairFlightScript.upper_id(rotation), "Worker builds both oriented halves")
			_check(not world.complete_stair_flight(task), "Removed task object cannot rebuild terrain")
			world.workers.clear()
			worker.free()
			world.task_manager.shutdown()
			world.free()


func _start_flight_worker(world: World, anchor: Vector3i, rotation: int) -> Array:
	var task = world.task_queue.find_nearest(TaskQueue.TaskType.STAIRS, Vector3(anchor))
	var goals := TaskWorkPositionRules.stair_work_positions(world, world.pathfinder, anchor, rotation)
	_check(task != null and not goals.is_empty(), "Blocked flight test setup")
	if task == null or goals.is_empty():
		return []
	var worker := Worker.new()
	worker.worker_id = 1
	worker.position = Vector3(goals[0])
	worker.path = [goals[0]]
	worker.current_task_id = task.id
	worker.state = Worker.WorkerState.WORKING
	task.assigned_worker = worker
	task.status = TaskQueue.TaskStatus.IN_PROGRESS
	world.workers.append(worker)
	return [worker, task]


func _test_worker_blocked_and_stale_flights() -> void:
	var world := _make_world()
	world.task_manager = TaskManager.new(world, world.task_queue)
	for x in range(-3, 4):
		for z in range(-3, 4):
			_load_cell(world, Vector3i(x, 1, z), World.BLOCK_ID_GRANITE)
			_load_cell(world, Vector3i(x, 2, z), World.BLOCK_ID_AIR)
	var anchor := Vector3i(0, 2, 0)
	var rotation := 0
	var cells := StairFlightScript.cells(anchor, rotation)
	_prepare_flight_area(world, anchor, rotation, true)
	_check(world.queue_stair_flight(anchor, rotation, true), "Queue blocked flight")
	var support_dig_id := world.task_queue.add_dig_task(anchor + Vector3i.DOWN)
	var started := _start_flight_worker(world, anchor, rotation)
	if started.is_empty():
		world.task_manager.shutdown()
		world.free()
		return
	var worker: Worker = started[0]
	var task = started[1]
	var occupant := Worker.new()
	occupant.worker_id = 2
	occupant.position = Vector3(cells[1] + Vector3i.UP)
	world.workers.append(occupant)
	worker.update_working(1.0, world, world.task_queue, world.pathfinder)
	_check(world.task_queue.get_task(task.id) == task and task.status == TaskQueue.TaskStatus.IN_PROGRESS, "Occupied flight stays assigned instead of cycling")
	_check(worker.state == Worker.WorkerState.WORKING and worker.current_task_id == task.id, "Builder waits in place while flight is occupied")
	_check(world.get_block_no_generate(anchor.x, anchor.y, anchor.z) == World.BLOCK_ID_AIR, "Occupied flight is not built")
	world.workers.erase(occupant)
	occupant.free()
	worker.update_working(1.0, world, world.task_queue, world.pathfinder)
	_check(world.task_queue.get_task(task.id) == null, "Flight completes once the occupant leaves")
	_check(world.get_block_no_generate(anchor.x, anchor.y, anchor.z) == StairFlightScript.lower_id(rotation), "Flight built after waiting")
	_check(world.task_queue.get_task(support_dig_id) == null, "Completed flight cancels pending dig on its support")

	# A flight whose support is dug out after queueing is cancelled, not retried.
	var stale_anchor := Vector3i(0, 2, -2)
	_prepare_flight_area(world, stale_anchor, rotation, true)
	_check(world.queue_stair_flight(stale_anchor, rotation, true), "Queue stale flight")
	world.workers.erase(worker)
	worker.free()
	started = _start_flight_worker(world, stale_anchor, rotation)
	if not started.is_empty():
		worker = started[0]
		task = started[1]
		_load_cell(world, stale_anchor + Vector3i.DOWN, World.BLOCK_ID_AIR)
		worker.update_working(1.0, world, world.task_queue, world.pathfinder)
		_check(world.task_queue.get_task(task.id) == null, "Flight with lost support is cancelled")
		_check(worker.state == Worker.WorkerState.IDLE and worker.current_task_id == -1, "Builder is released from stale flight")
		_check(world.get_block_no_generate(stale_anchor.x, stale_anchor.y, stale_anchor.z) == World.BLOCK_ID_AIR, "Stale flight builds nothing")
	for remaining: Worker in world.workers:
		remaining.free()
	world.workers.clear()
	world.task_manager.shutdown()
	world.free()


func _test_side_access() -> void:
	# Lower half: within half a level of the same floor, so its sides connect there.
	# Upper half: within half a level of the next floor, so its sides connect up there.
	var world := _make_world()
	var pathfinder := Pathfinder.new()
	for x in range(-3, 4):
		for z in range(-3, 4):
			_load_cell(world, Vector3i(x, 1, z), World.BLOCK_ID_GRANITE)
			_load_cell(world, Vector3i(x, 2, z), World.BLOCK_ID_AIR)
			_load_cell(world, Vector3i(x, 3, z), World.BLOCK_ID_AIR)
	var anchor := Vector3i(0, 2, 0)
	var rotation := 0
	var cells := StairFlightScript.cells(anchor, rotation)
	_load_cell(world, cells[0], StairFlightScript.lower_id(rotation))
	_load_cell(world, cells[1], StairFlightScript.upper_id(rotation))
	var lower_east := cells[0] + Vector3i(1, 0, 0)
	var lower_west := cells[0] + Vector3i(-1, 0, 0)
	_check(pathfinder.can_traverse(world, lower_east, cells[0]) and pathfinder.can_traverse(world, cells[0], lower_east), "Same-level floor reaches lower half from the east side")
	_check(pathfinder.can_traverse(world, lower_west, cells[0]) and pathfinder.can_traverse(world, cells[0], lower_west), "Same-level floor reaches lower half from the west side")
	var upper_west_floor := cells[1] + Vector3i(-1, 0, 0)
	_check(not pathfinder.can_traverse(world, upper_west_floor, cells[1]), "Same-level floor cannot climb onto the upper half's side")
	_check(not pathfinder.can_traverse(world, cells[1], upper_west_floor), "Upper half cannot drop to same-level floor at its side")
	var upper_east_support := cells[1] + Vector3i(1, 0, 0)
	_load_cell(world, upper_east_support, World.BLOCK_ID_GRANITE)
	var upper_east_high := upper_east_support + Vector3i.UP
	_check(pathfinder.can_traverse(world, upper_east_high, cells[1]) and pathfinder.can_traverse(world, cells[1], upper_east_high), "Next-level floor reaches upper half from its side")
	_load_cell(world, cells[1] + Vector3i.UP, World.BLOCK_ID_GRANITE)
	_check(not pathfinder.can_traverse(world, upper_east_high, cells[1]) and not pathfinder.can_traverse(world, cells[1], upper_east_high), "Covered upper half blocks side access to the next level")
	_load_cell(world, cells[1] + Vector3i.UP, World.BLOCK_ID_AIR)
	_load_cell(world, lower_east, World.BLOCK_ID_GRANITE)
	var lower_east_high := lower_east + Vector3i.UP
	_check(not pathfinder.can_traverse(world, lower_east_high, cells[0]) and not pathfinder.can_traverse(world, cells[0], lower_east_high), "Next-level floor cannot drop onto the lower half's side")
	_load_cell(world, lower_west, World.TERRAIN_SLOPE_NORTH_ID)
	_check(not pathfinder.can_traverse(world, lower_west, cells[0]) and not pathfinder.can_traverse(world, cells[0], lower_west), "Terrain slope beside a flight does not connect sideways")
	world.free()

	# Parallel flights: matching halves are level with each other.
	world = _make_world()
	for x in range(-3, 4):
		for z in range(-3, 4):
			_load_cell(world, Vector3i(x, 1, z), World.BLOCK_ID_GRANITE)
			_load_cell(world, Vector3i(x, 2, z), World.BLOCK_ID_AIR)
			_load_cell(world, Vector3i(x, 3, z), World.BLOCK_ID_AIR)
	var left := StairFlightScript.cells(Vector3i(0, 2, 0), rotation)
	var right := StairFlightScript.cells(Vector3i(1, 2, 0), rotation)
	for pair in [left, right]:
		_load_cell(world, pair[0], StairFlightScript.lower_id(rotation))
		_load_cell(world, pair[1], StairFlightScript.upper_id(rotation))
	_check(pathfinder.can_traverse(world, left[0], right[0]) and pathfinder.can_traverse(world, left[1], right[1]), "Matching halves of parallel flights connect sideways")
	_check(not pathfinder.can_traverse(world, left[0], right[1]), "Mismatched halves do not connect diagonally")
	world.free()
