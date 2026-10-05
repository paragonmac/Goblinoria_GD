extends SceneTree

const Flight = preload("res://scripts/stair_flight.gd")
const Transaction = preload("res://scripts/world_save_transaction.gd")


class BoundaryWorld extends World:
	func ensure_chunk_generated(coord: Vector3i) -> ChunkData:
		var chunk := ensure_chunk(coord)
		if chunk == null or chunk.generated:
			return chunk
		if save_load != null and (save_load.bulk_chunk_save_load.is_loaded() or not save_load.current_world_dir.is_empty()):
			if save_load.load_chunk_into(coord, chunk):
				return chunk
		chunk.generated = true
		return chunk

	func _start_worker_trace_for_spawned_workers() -> void:
		pass


var checks := 0
var failures: Array[String] = []
var test_root := ""


func _init() -> void:
	_run.call_deferred()


func _run() -> void:
	test_root = ProjectSettings.globalize_path("res://.local-stair-chunk-boundaries-%d-%d" % [OS.get_process_id(), Time.get_ticks_usec()])
	_check(DirAccess.make_dir_absolute(test_root) == OK, "Create isolated stair seam save directory")
	if failures.is_empty():
		for rotation in range(Flight.ROTATION_COUNT):
			var anchor := _anchor_for_rotation(rotation)
			for up in [true, false]:
				_test_flight(anchor, rotation, up)
	_check(_remove_test_tree(test_root), "Remove only isolated stair seam save directory")
	if failures.is_empty():
		print("STAIR_CHUNK_BOUNDARIES_OK (%d checks)" % checks)
		quit(0)
	else:
		for message in failures:
			push_error(message)
		push_error("Stair chunk boundary contract failed (%d/%d checks)" % [failures.size(), checks])
		quit(1)


func _anchor_for_rotation(rotation: int) -> Vector3i:
	match rotation:
		0:
			return Vector3i(2, 2, 0) # North crosses the negative Z seam -1/0.
		1:
			return Vector3i(World.CHUNK_SIZE - 1, 2, 2) # East crosses X seam 7/8.
		2:
			return Vector3i(2, 2, World.CHUNK_SIZE - 1) # South crosses Z seam 7/8.
		_:
			return Vector3i(0, 2, 2) # West crosses the negative X seam -1/0.


func _test_flight(anchor: Vector3i, rotation: int, up: bool) -> void:
	var world := _new_world()
	var cells := Flight.cells(anchor, rotation)
	_prepare_area(world, anchor, cells, rotation, up)
	var chunk_coords: Array[Vector3i] = []
	for cell: Vector3i in cells:
		var chunk_coord := world.world_to_chunk_coords(cell.x, cell.y, cell.z)
		if not chunk_coords.has(chunk_coord):
			chunk_coords.append(chunk_coord)
	_check(chunk_coords.size() == 2, "rotation %d cells straddle two owning chunks" % rotation)
	if chunk_coords.size() != 2:
		_dispose_world(world)
		return

	_check(world.queue_stair_flight(anchor, rotation, up), "rotation %d up=%s queues at seam" % [rotation, up])
	var task = _flight_task(world, cells[0])
	_check(task != null and world.task_queue.get_active_tasks_at(cells[1]).has(task), "rotation %d up=%s indexes both halves" % [rotation, up])
	_check(world.cancel_pending_task_requests_at(cells[1]).size() == 1, "rotation %d up=%s cancels through the far half" % [rotation, up])
	_check(world.task_queue.active_count() == 0 and _cell(world, cells[0]) == (World.BLOCK_ID_AIR if up else World.BLOCK_ID_GRANITE) and _cell(world, cells[1]) == (World.BLOCK_ID_AIR if up else World.BLOCK_ID_GRANITE), "rotation %d up=%s cancellation preserves both source cells" % [rotation, up])

	_check(world.queue_stair_flight(anchor, rotation, up), "rotation %d up=%s requeues at seam" % [rotation, up])
	task = _flight_task(world, cells[0])
	var revisions_before: Dictionary = _chunk_revisions(world, chunk_coords)
	_check(world.complete_stair_flight(task), "rotation %d up=%s completion writes the seam pair" % [rotation, up])
	_check(_cell(world, cells[0]) == Flight.lower_id(rotation) and _cell(world, cells[1]) == Flight.upper_id(rotation), "rotation %d up=%s identities survive cross-chunk completion" % [rotation, up])
	_check(_both_chunks_changed(world, chunk_coords, revisions_before), "rotation %d up=%s dirties and revises both owning chunks" % [rotation, up])
	world.task_queue.complete_task(task)
	_check(world.pathfinder.is_valid_flight_cell(world, cells[0]) and world.pathfinder.is_valid_flight_cell(world, cells[1]), "rotation %d up=%s pair validates across chunks" % [rotation, up])
	var direction := Flight.direction(rotation)
	var entry := anchor - direction
	var exit := anchor + direction * 2 + Vector3i.UP
	_check(world.pathfinder.can_traverse(world, entry, anchor), "rotation %d low entry crosses the seam" % rotation)
	_check(world.pathfinder.can_traverse(world, anchor, cells[1]), "rotation %d midpoint crosses the seam" % rotation)
	_check(world.pathfinder.can_traverse(world, cells[1], exit), "rotation %d high exit crosses the seam" % rotation)
	_check(_walk_route(world, [entry, anchor, cells[1], exit], 1000 + rotation * 2), "rotation %d worker completes entry-to-exit flight without falling" % rotation)
	_check(_walk_route(world, [exit, cells[1], anchor, entry], 1001 + rotation * 2), "rotation %d worker completes exit-to-entry flight without falling" % rotation)

	_check(world.task_queue.add_dig_task(anchor + Vector3i(2, 0, 2)) >= 0, "Add an unfinished task for restart-semantics check")
	var slot_path := test_root.path_join("case_%d_%s.save" % [rotation, "up" if up else "down"])
	_check(world.save_world(slot_path), "rotation %d up=%s saves cross-chunk halves" % [rotation, up])
	var reader := _new_world()
	_check(reader.load_world(slot_path), "rotation %d up=%s reloads cross-chunk halves" % [rotation, up])
	_check(_cell(reader, cells[0]) == Flight.lower_id(rotation) and _cell(reader, cells[1]) == Flight.upper_id(rotation), "rotation %d up=%s restores both saved half identities" % [rotation, up])
	_check(reader.task_queue.active_count() == 0, "rotation %d up=%s keeps unfinished jobs out of save data" % [rotation, up])
	_check(reader.pathfinder.is_valid_flight_cell(reader, cells[0]) and reader.pathfinder.is_valid_flight_cell(reader, cells[1]), "rotation %d up=%s restored pair is traversable across chunks" % [rotation, up])
	_dispose_world(reader)

	_check(world.queue_stair_removal(cells[1]), "rotation %d up=%s removal queues from far half" % [rotation, up])
	var removal = _flight_task(world, cells[0])
	_check(removal != null and world.task_queue.get_active_tasks_at(cells[1]).has(removal), "rotation %d up=%s removal reserves both chunks" % [rotation, up])
	_check(world.cancel_pending_task_requests_at(cells[0]).size() == 1, "rotation %d up=%s removal cancels through anchor half" % [rotation, up])
	_check(_cell(world, cells[0]) == Flight.lower_id(rotation) and _cell(world, cells[1]) == Flight.upper_id(rotation), "rotation %d up=%s removal cancellation preserves both halves" % [rotation, up])
	_check(world.queue_stair_removal(cells[0]), "rotation %d up=%s requeues removal from anchor" % [rotation, up])
	removal = _flight_task(world, cells[0])
	revisions_before = _chunk_revisions(world, chunk_coords)
	_check(world.complete_stair_flight(removal), "rotation %d up=%s dismantles the pair across chunks" % [rotation, up])
	_check(_cell(world, cells[0]) == World.BLOCK_ID_AIR and _cell(world, cells[1]) == World.BLOCK_ID_AIR, "rotation %d up=%s removal clears both identities" % [rotation, up])
	_check(_both_chunks_changed(world, chunk_coords, revisions_before), "rotation %d up=%s removal dirties and revises both owning chunks" % [rotation, up])
	_check(not world.pathfinder.can_traverse(world, cells[1], exit), "rotation %d removed pair no longer supports its vertical exit" % rotation)
	_dispose_world(world)


func _new_world() -> BoundaryWorld:
	var world := BoundaryWorld.new()
	world._init_ramp_lookup()
	world.block_registry.load_from_csv(World.BLOCK_DATA_PATH)
	world.world_size_y = 16
	world.sea_level = 8
	world.save_load = WorldSaveLoad.new(world)
	world.task_manager = TaskManager.new(world, world.task_queue)
	return world


func _prepare_area(world: World, anchor: Vector3i, cells: Array[Vector3i], rotation: int, up: bool) -> void:
	var direction := Flight.direction(rotation)
	var entry := anchor - direction
	var exit := anchor + direction * 2 + Vector3i.UP
	var positions: Array[Vector3i] = []
	for cell: Vector3i in cells:
		positions.append(cell + Vector3i.DOWN)
		positions.append(cell)
		positions.append(cell + Vector3i.UP)
	for cell in [entry + Vector3i.DOWN, entry, entry + Vector3i.UP, exit + Vector3i.DOWN, exit, exit + Vector3i.UP]:
		positions.append(cell)
	for pos: Vector3i in positions:
		world.ensure_chunk_generated(world.world_to_chunk_coords(pos.x, pos.y, pos.z))
	for cell: Vector3i in cells:
		world.set_block_raw(cell.x, cell.y - 1, cell.z, World.BLOCK_ID_GRANITE, false)
		world.set_block_raw(cell.x, cell.y, cell.z, World.BLOCK_ID_AIR if up else World.BLOCK_ID_GRANITE, false)
		world.set_block_raw(cell.x, cell.y + 1, cell.z, World.BLOCK_ID_AIR, false)
	world.set_block_raw(entry.x, entry.y - 1, entry.z, World.BLOCK_ID_GRANITE, false)
	world.set_block_raw(entry.x, entry.y, entry.z, World.BLOCK_ID_AIR, false)
	world.set_block_raw(entry.x, entry.y + 1, entry.z, World.BLOCK_ID_AIR, false)
	world.set_block_raw(exit.x, exit.y - 1, exit.z, World.BLOCK_ID_GRANITE, false)
	world.set_block_raw(exit.x, exit.y, exit.z, World.BLOCK_ID_AIR, false)
	world.set_block_raw(exit.x, exit.y + 1, exit.z, World.BLOCK_ID_AIR, false)
	for cell: Vector3i in cells:
		var coord := world.world_to_chunk_coords(cell.x, cell.y, cell.z)
		world.chunks[coord].dirty = false


func _chunk_revisions(world: World, chunk_coords: Array[Vector3i]) -> Dictionary:
	var revisions := {}
	for coord: Vector3i in chunk_coords:
		var chunk = world.get_chunk(coord)
		revisions[coord] = chunk.mesh_revision
	return revisions


func _both_chunks_changed(world: World, chunk_coords: Array[Vector3i], before: Dictionary) -> bool:
	for coord: Vector3i in chunk_coords:
		var chunk = world.get_chunk(coord)
		if chunk == null or not chunk.dirty or chunk.mesh_revision <= int(before[coord]):
			return false
	return true


func _flight_task(world: World, cell: Vector3i):
	for task in world.task_queue.get_active_tasks_at(cell):
		if task.type == TaskQueue.TaskType.STAIRS and bool(task.data.get("flight", false)):
			return task
	return null


func _walk_route(world: World, route: Array[Vector3i], worker_id: int) -> bool:
	if route.size() < 2:
		return false
	var worker := Worker.new()
	worker.worker_id = worker_id
	var start: Vector3i = route[0]
	worker.position = Vector3(start)
	var start_id := _cell(world, start)
	if world.is_ramp_block_id(start_id):
		worker.position.y += worker._ramp_center_offset(start_id)
	worker.path = route.duplicate()
	worker.path_index = 1
	worker.movement_intent = Worker.MovementIntent.WANDER
	worker.state = Worker.WorkerState.MOVING
	worker.set_target_from_path(world)
	world.workers.append(worker)
	var fell := false
	var finished := false
	for _frame in range(400):
		worker.update_worker(0.05, world, world.task_queue, world.pathfinder)
		if worker.state == Worker.WorkerState.FALLING:
			fell = true
		if worker.state == Worker.WorkerState.IDLE and worker.path.is_empty():
			finished = true
			break
	var destination: Vector3i = route[route.size() - 1]
	var destination_y := float(destination.y)
	var destination_id := _cell(world, destination)
	if world.is_ramp_block_id(destination_id):
		destination_y += worker._ramp_center_offset(destination_id)
	var reached := finished and not fell and worker.state == Worker.WorkerState.IDLE \
			and worker.get_block_coord() == destination \
			and is_equal_approx(worker.position.x, float(destination.x)) \
			and is_equal_approx(worker.position.z, float(destination.z)) \
			and is_equal_approx(worker.position.y, destination_y) \
			and worker.worker_id == worker_id
	world.workers.erase(worker)
	worker.free()
	return reached


func _cell(world: World, pos: Vector3i) -> int:
	return world.get_block(pos.x, pos.y, pos.z)


func _dispose_world(world: BoundaryWorld) -> void:
	if world.task_manager != null:
		world.task_manager.shutdown()
	world.free()


func _remove_test_tree(path: String) -> bool:
	var absolute := ProjectSettings.globalize_path(path).simplify_path().trim_suffix("/")
	if absolute != test_root or not absolute.get_file().begins_with(".local-stair-chunk-boundaries-"):
		return false
	return Transaction.new()._remove_tree(absolute)


func _check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)
