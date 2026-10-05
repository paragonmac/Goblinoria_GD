extends SceneTree

const Fixture = preload("res://tools/validate_save_load_transaction.gd")
const Transaction = preload("res://scripts/world_save_transaction.gd")
const Flight = preload("res://scripts/stair_flight.gd")

var checks := 0
var failures: Array[String] = []


func _init() -> void:
	_run.call_deferred()


func _check(value: bool, message: String) -> void:
	checks += 1
	if not value:
		failures.append(message)
		push_error(message)


func _write_workers(slot: String, data: Dictionary) -> void:
	var file := FileAccess.open(slot.path_join(WorldWorkerSaveLoad.WORKER_FILE_NAME), FileAccess.WRITE)
	_check(file != null, "Open worker fixture")
	if file == null:
		return
	file.store_32(WorldWorkerSaveLoad.WORKER_MAGIC)
	file.store_var(data, false)
	file.close()


func _write_tasks(slot: String, records: Array, magic: int = WorldTaskSaveLoad.TASK_MAGIC) -> void:
	var file := FileAccess.open(slot.path_join(WorldTaskSaveLoad.TASK_FILE_NAME), FileAccess.WRITE)
	_check(file != null, "Open task fixture")
	if file == null:
		return
	file.store_32(magic)
	file.store_var({"tasks": records}, false)
	file.close()


func _put(world: World, cell: Vector3i, block_id: int) -> void:
	world.set_block_raw(cell.x, cell.y, cell.z, block_id, true)


func _task_at(world: World, task_type: int, pos: Vector3i):
	for task in world.task_queue.tasks:
		if task.type == task_type and task.pos == pos:
			return task
	return null


func _run() -> void:
	var world := Fixture.TestWorld.new()
	world._init_ramp_lookup()
	world.block_registry.load_from_csv(World.BLOCK_DATA_PATH)
	world.save_load = WorldSaveLoad.new(world)
	world.world_seed = 76543
	world.task_manager = TaskManager.new(world, world.task_queue)
	world.spawn_initial_workers()
	var chunk := ChunkData.new(World.CHUNK_SIZE, World.BLOCK_ID_AIR)
	chunk.generated = true
	chunk.dirty = true
	world.chunks[Vector3i.ZERO] = chunk
	var test_root := ProjectSettings.globalize_path("res://.local-task-persistence-%d-%d" % [OS.get_process_id(), Time.get_ticks_usec()])
	var root_created := DirAccess.make_dir_absolute(test_root) == OK
	_check(root_created, "Create isolated task-persistence directory")
	if not root_created:
		world.task_manager.shutdown()
		world.free()
		print("Task persistence: %d checks, %d failures" % [checks, failures.size()])
		quit(1)
		return
	var path := test_root.path_join("slot.save")
	var slot := path.get_basename()

	# Keep all tested cells in one generated chunk, which the bulk save persists.
	var dig_pos := Vector3i(2, 3, 2)
	var place_pos := Vector3i(3, 3, 2)
	_put(world, dig_pos, World.BLOCK_ID_GRANITE)
	world.task_queue.add_dig_task(dig_pos)
	world.task_queue.add_place_task(place_pos, World.BLOCK_ID_CLAY)
	var progress_id := world.task_queue.add_dig_task(Vector3i(5, 3, 2))
	var progress_task = world.task_queue.get_task(progress_id)
	var assigned_worker: Worker = world.workers[0]
	progress_task.status = TaskQueue.TaskStatus.IN_PROGRESS
	progress_task.assigned_worker = assigned_worker
	assigned_worker.current_task_id = progress_task.id

	var build_anchor := Vector3i(4, 4, 4)
	var build_rotation := 1
	var build_cells := Flight.cells(build_anchor, build_rotation)
	for cell: Vector3i in build_cells:
		_put(world, cell + Vector3i.DOWN, World.BLOCK_ID_GRANITE)
		_put(world, cell, World.BLOCK_ID_AIR)
		_put(world, cell + Vector3i.UP, World.BLOCK_ID_AIR)
	_check(world.queue_stair_flight(build_anchor, build_rotation, true), "Queue up-flight build")

	var removal_anchor := Vector3i(6, 4, 4)
	var removal_rotation := 0
	var removal_cells := Flight.cells(removal_anchor, removal_rotation)
	_put(world, removal_cells[0], Flight.lower_id(removal_rotation))
	_put(world, removal_cells[1], Flight.upper_id(removal_rotation))
	_check(world.queue_stair_removal(removal_cells[1]), "Queue two-cell stair removal")

	# Case 5 uses read_snapshot directly: HAUL is excluded from serialized records.
	world.task_queue.add_haul_task(42, Vector3i(14, 3, 2), World.BLOCK_ID_DIRT, 1, Vector3i(15, 3, 2))
	_check(world.save_world(path), "Save V9 task and worker fixture")
	var snapshot: Dictionary = world.save_load.task_save_load.read_snapshot(world, slot)
	var haul_saved := false
	for record: Dictionary in snapshot.get("tasks", []):
		if int(record.get("type", -1)) == TaskQueue.TaskType.HAUL:
			haul_saved = true
	_check(bool(snapshot.get("ok", false)) and not haul_saved, "tasks.dat snapshot contains no HAUL record")

	# Capture the normal respawn location, then save worker 1 on supported terrain.
	_check(world.load_world(path), "Reload baseline before position checks")
	var loaded_chunk: ChunkData = world.ensure_chunk(Vector3i.ZERO)
	_check(loaded_chunk != null and world.save_load.load_chunk_into(Vector3i.ZERO, loaded_chunk),
		"Load persisted terrain before extending the worker fixture")
	var worker_one: Worker = world.workers[0]
	var default_spawn := worker_one.position
	var supported_position := Vector3(2, 5, 2)
	_put(world, Vector3i(2, 4, 2), World.BLOCK_ID_GRANITE)
	_put(world, Vector3i(2, 5, 2), World.BLOCK_ID_AIR)
	_put(world, Vector3i(2, 6, 2), World.BLOCK_ID_AIR)
	worker_one.position = supported_position
	worker_one.target_pos = supported_position
	_check(world.save_world(path), "Save supported worker position")
	_check(world.load_world(path), "Reload V9 tasks and supported worker position")
	var dig_task = _task_at(world, TaskQueue.TaskType.DIG, dig_pos)
	var place_task = _task_at(world, TaskQueue.TaskType.PLACE, place_pos)
	_check(dig_task != null and dig_task.material == 0 and dig_task.status == TaskQueue.TaskStatus.PENDING,
		"DIG round-trips at the same position and material as PENDING")
	_check(place_task != null and place_task.material == World.BLOCK_ID_CLAY and place_task.status == TaskQueue.TaskStatus.PENDING,
		"PLACE round-trips at the same position and material as PENDING")
	var restored_progress = _task_at(world, TaskQueue.TaskType.DIG, Vector3i(5, 3, 2))
	_check(restored_progress != null and restored_progress.status == TaskQueue.TaskStatus.PENDING
		and restored_progress.assigned_worker == null,
		"In-progress DIG reloads as PENDING without an assigned worker")
	_check(world.workers[0].position == supported_position, "Supported worker position restores")
	var build_task = _task_at(world, TaskQueue.TaskType.STAIRS, build_anchor)
	_check(build_task != null and build_task.data.get("footprint", []) == build_cells,
		"Up-flight task restores the typed two-cell footprint")
	_check(build_task != null and world.complete_stair_flight(build_task), "Reloaded up-flight task completes")
	_check(world.get_block_no_generate(build_cells[0].x, build_cells[0].y, build_cells[0].z) == Flight.lower_id(build_rotation)
		and world.get_block_no_generate(build_cells[1].x, build_cells[1].y, build_cells[1].z) == Flight.upper_id(build_rotation),
		"Completed up-flight writes both oriented block IDs")
	var removal_task = _task_at(world, TaskQueue.TaskType.STAIRS, removal_anchor)
	_check(removal_task != null and bool(removal_task.data.get("remove_stairs", false))
		and removal_task.data.get("footprint", []) == removal_cells,
		"Stair-removal task round-trips both cells")
	_check(removal_task != null and world.complete_stair_flight(removal_task), "Reloaded stair-removal task completes")
	_check(world.get_block_no_generate(removal_cells[0].x, removal_cells[0].y, removal_cells[0].z) == World.BLOCK_ID_AIR
		and world.get_block_no_generate(removal_cells[1].x, removal_cells[1].y, removal_cells[1].z) == World.BLOCK_ID_AIR,
		"Reloaded stair removal clears both halves")

	# Unsupported saved positions must leave the worker at its ordinary spawn.
	var midair_position := Vector3(6, 7, 6)
	_put(world, Vector3i(6, 7, 6), World.BLOCK_ID_AIR)
	_put(world, Vector3i(6, 6, 6), World.BLOCK_ID_AIR)
	world.workers[0].position = midair_position
	world.workers[0].target_pos = midair_position
	_check(world.save_world(path), "Save unsupported worker position")
	_check(world.load_world(path), "Reload with unsupported worker position")
	_check(world.workers[0].position != midair_position and world.workers[0].position == default_spawn,
		"Unsupported mid-air worker position falls back to default spawn")

	# V8 represents the same V9 save without tasks.dat or worker position fields.
	_check(DirAccess.remove_absolute(slot.path_join(WorldTaskSaveLoad.TASK_FILE_NAME)) == OK,
		"Remove tasks.dat for V8 compatibility fixture")
	_check(world.save_load.metadata_save_load.write_world_meta(world, slot, 8, world.save_load._get_block_table_hash()),
		"Rewrite metadata as V8")
	var worker_file := FileAccess.open(slot.path_join(WorldWorkerSaveLoad.WORKER_FILE_NAME), FileAccess.READ)
	var worker_data: Dictionary = {}
	if worker_file != null:
		worker_file.get_32()
		worker_data = worker_file.get_var(false)
		worker_file.close()
	var roles: Array = worker_data.get("roles", [])
	for entry: Dictionary in roles:
		entry.erase("position")
	_write_workers(slot, {"roles": roles})
	_check(world.load_world(path), "V8 save without tasks or worker positions loads")
	_check(world.task_queue.tasks.is_empty(), "V8 save restores an empty task queue")
	_check(world.workers[0].position == default_spawn, "V8 worker respawns at its default position")

	# Corrupt and malformed snapshots are rejected before replacing live state.
	world.task_queue.add_dig_task(Vector3i(3, 3, 3))
	_check(world.save_world(path), "Create fresh V9 baseline for corruption checks")
	var live_epoch := world.runtime_epoch
	var live_tasks: Array = world.task_queue.tasks.duplicate()
	_write_tasks(slot, [], WorldTaskSaveLoad.TASK_MAGIC ^ 1)
	_check(not world.load_world(path) and world.runtime_epoch == live_epoch and world.task_queue.tasks == live_tasks,
		"Wrong task magic rejects load without changing epoch or task queue")
	var valid_record := {"type": TaskQueue.TaskType.DIG, "pos": Vector3i(2, 3, 2), "material": 0,
		"data": {}, "expected_blocks": []}
	var unknown_data := valid_record.duplicate(true)
	unknown_data.data["unexpected"] = true
	_write_tasks(slot, [unknown_data])
	_check(not world.load_world(path), "Unknown task data key rejects load")
	var invalid_pos := valid_record.duplicate(true)
	invalid_pos["pos"] = Vector3(2, 3, 2)
	_write_tasks(slot, [invalid_pos])
	_check(not world.load_world(path), "Non-Vector3i task position rejects load")

	_check(ProjectSettings.globalize_path("res://").trim_suffix("/") == test_root.get_base_dir()
		and test_root.get_file().begins_with(".local-task-persistence-"), "Cleanup target is the isolated fixture directory")
	world.task_manager.shutdown()
	world.free()
	await process_frame
	if test_root.get_file().begins_with(".local-task-persistence-"):
		_check(Transaction.new()._remove_tree(test_root), "Remove isolated fixture files")
	print("Task persistence: %d checks, %d failures" % [checks, failures.size()])
	quit(1 if not failures.is_empty() else 0)
