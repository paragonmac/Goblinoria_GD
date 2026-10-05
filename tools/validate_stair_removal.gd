extends SceneTree

const Flight = preload("res://scripts/stair_flight.gd")

class TestWorld extends World:
	func ensure_chunk_generated(coord: Vector3i) -> ChunkData:
		var chunk := ensure_chunk(coord)
		chunk.generated = true
		return chunk

var checks := 0
var failures := 0


func _init() -> void:
	for rotation in 4:
		_test_pair(rotation)
	_test_legacy_and_terrain()
	_test_stale_dig()
	print("Stair removal: %d checks, %d failures" % [checks, failures])
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
			_put(world, Vector3i(x, 3, z), World.BLOCK_ID_GRANITE)
			_put(world, Vector3i(x, 4, z), World.BLOCK_ID_AIR)
	return world


func _put(world: World, cell: Vector3i, id: int) -> void:
	world.set_block_raw(cell.x, cell.y, cell.z, id, true)


func _block(world: World, cell: Vector3i) -> int:
	return world.get_block_no_generate(cell.x, cell.y, cell.z)


func _dispose(world: World) -> void:
	for worker: Worker in world.workers:
		worker.free()
	world.workers.clear()
	world.task_manager.shutdown()
	world.free()


func _test_pair(rotation: int) -> void:
	var world := _world()
	var anchor := Vector3i(0, 4, 0)
	var cells := Flight.cells(anchor, rotation)
	_put(world, cells[0], Flight.lower_id(rotation))
	_put(world, cells[1], Flight.upper_id(rotation))
	var selection := MainSelectionController.new()
	selection.world = world
	world.player_mode = World.PlayerMode.DIG
	for cell: Vector3i in cells:
		_check(selection._dig_selection_reject_reason(cell) == "stairs_require_removal", "Dig identifies protected stair")
		_check(not selection._enqueue_task_at(cell.x, cell.y, cell.z).queued, "Dig click cannot remove half")
		_check(not world.queue_task_request(TaskQueue.TaskType.DIG, cell, 0), "Direct dig request cannot remove half")
		_check(not world.queue_task_request(TaskQueue.TaskType.DIG, cell + Vector3i.DOWN, 0), "Dig cannot undermine stair")
	_check(world.get_stair_removal_spec(cells[0]) == world.get_stair_removal_spec(cells[1]), "Both halves resolve to one flight")
	_check(world.queue_stair_removal(cells[1]), "Queue removal from upper half")
	var task = world.task_queue.get_active_tasks_at(anchor)[0]
	_check(world.task_queue.get_active_tasks_at(cells[1]).has(task), "Removal reserves upper half")
	_check(not world.queue_stair_removal(anchor), "Duplicate removal rejected")
	_check(not world.queue_task_request(TaskQueue.TaskType.PLACE, cells[1], World.PLACE_MATERIAL_ID), "Other work cannot overlap removal")
	_check(world.cancel_pending_task_requests_at(cells[1]).size() == 1, "Erase cancels whole removal")
	_check(_block(world, anchor) == Flight.lower_id(rotation), "Cancellation preserves stairs")
	_check(world.queue_stair_removal(anchor), "Requeue removal")
	task = world.task_queue.get_active_tasks_at(anchor)[0]
	_put(world, cells[1], World.BLOCK_ID_GRANITE)
	_check(not world.complete_stair_flight(task), "Stale other half rejects removal")
	_check(_block(world, anchor) == Flight.lower_id(rotation), "Stale operation changes neither half")
	_put(world, cells[1], Flight.upper_id(rotation))
	var occupant := Worker.new()
	occupant.position = Vector3(anchor) + Vector3(0, 0.25, 0)
	world.workers.append(occupant)
	_check(not world.complete_stair_flight(task), "Standing worker prevents dismantling")
	occupant.position = Vector3(cells[1] + Flight.direction(rotation) + Vector3i.UP)
	occupant.state = Worker.WorkerState.MOVING
	occupant.path = [cells[1], cells[1] + Flight.direction(rotation) + Vector3i.UP]
	occupant.path_index = 1
	occupant.path_segment_validated = true
	_check(not world.complete_stair_flight(task), "Committed segment prevents dismantling")
	occupant.state = Worker.WorkerState.IDLE
	occupant.path.clear()
	var goals := TaskWorkPositionRules.stair_work_positions(world, world.pathfinder, anchor, rotation)
	_check(not goals.is_empty(), "Removal has exterior work position")
	var worker := Worker.new()
	worker.worker_id = 10
	worker.position = Vector3(goals[0])
	worker.current_task_id = task.id
	worker.state = Worker.WorkerState.WORKING
	worker.path = [goals[0]]
	task.assigned_worker = worker
	task.status = TaskQueue.TaskStatus.IN_PROGRESS
	world.workers.append(worker)
	_check(worker.can_work_task(task, world, world.pathfinder), "Worker can dismantle from outside flight")
	occupant.position = Vector3(anchor) + Vector3(0, 0.25, 0)
	worker.update_working(1.0, world, world.task_queue, world.pathfinder)
	_check(world.task_queue.get_task(task.id) == task and worker.current_task_id == task.id, "Occupied removal stays with its worker")
	_check(_block(world, anchor) == Flight.lower_id(rotation), "Occupied removal leaves stairs")
	occupant.position = Vector3(cells[1] + Flight.direction(rotation) * 3 + Vector3i.UP)
	worker.update_working(1.0, world, world.task_queue, world.pathfinder)
	_check(world.task_queue.active_count() == 0, "Worker completes removal job")
	for cell: Vector3i in cells:
		_check(_block(world, cell) == World.BLOCK_ID_AIR, "Whole flight removed")
		_check(world.is_diggable_at(cell.x, cell.y - 1, cell.z), "Support becomes diggable after explicit removal")
	_check(not world.complete_stair_flight(task), "Finished task cannot execute again")
	_dispose(world)


func _test_legacy_and_terrain() -> void:
	var world := _world()
	var pos := Vector3i(0, 4, 0)
	for id in World.PLAYER_STAIR_BLOCK_IDS:
		_put(world, pos, id)
		_check(not world.is_diggable_at(pos.x, pos.y, pos.z), "All player stairs protected, including legacy")
		_check(world.queue_stair_removal(pos), "Explicit removal handles legacy/orphan stair")
		var task = world.task_queue.get_active_tasks_at(pos)[0]
		_check(world.complete_stair_flight(task), "Single-cell removal completes")
		world.task_queue.remove_task(task)
	for id in World.TERRAIN_SLOPE_BLOCK_IDS:
		_put(world, pos, id)
		_check(world.is_diggable_at(pos.x, pos.y, pos.z), "Natural slopes remain diggable")
		_check(not world.queue_stair_removal(pos), "Natural slopes have no dismantle action")
	_dispose(world)


func _test_stale_dig() -> void:
	var world := _world()
	var pos := Vector3i(0, 4, 0)
	_put(world, pos, World.BLOCK_ID_GRANITE)
	var id := world.task_queue.add_dig_task(pos)
	var task = world.task_queue.get_task(id)
	var worker := Worker.new()
	worker.worker_id = 1
	worker.position = Vector3(1, 4, 0)
	worker.current_task_id = id
	worker.state = Worker.WorkerState.WORKING
	task.assigned_worker = worker
	task.status = TaskQueue.TaskStatus.IN_PROGRESS
	world.workers.append(worker)
	_put(world, pos, World.RAMP_NORTH_ID)
	worker.update_working(1.0, world, world.task_queue, world.pathfinder)
	_check(_block(world, pos) == World.RAMP_NORTH_ID, "Old dig cannot destroy newly built stairs at execution")
	_check(world.task_queue.active_count() == 0, "Protected stale dig is cancelled")
	_dispose(world)
