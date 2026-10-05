extends SceneTree

const Fixture = preload("res://tools/validate_save_load_transaction.gd")
const Transaction = preload("res://scripts/world_save_transaction.gd")
const CameraController = preload("res://scripts/main_camera_controller.gd")
const Watchdog = preload("res://scripts/diagnostics/anomaly_watchdog.gd")


class DebugTestWorld:
	extends Fixture.TestWorld
	var worker_update_calls := 0

	func ensure_chunk_generated(coord: Vector3i) -> ChunkData:
		return ensure_chunk(coord)

	func update_workers(_dt: float) -> void:
		worker_update_calls += 1

var failures: Array[String] = []
var checks := 0
var test_root := ""


func _init() -> void:
	_run.call_deferred()


func check(value: bool, message: String) -> void:
	checks += 1
	if not value:
		failures.append(message)


func _write_workers(slot: String, data: Dictionary) -> void:
	var file := FileAccess.open(slot.path_join("workers.dat"), FileAccess.WRITE)
	if file == null:
		check(false, "Open legacy workers.dat for writing")
		return
	file.store_32(WorldWorkerSaveLoad.WORKER_MAGIC)
	file.store_var(data, false)
	file.close()


func _worker_ids(world: World) -> Array[int]:
	var ids: Array[int] = []
	for worker: Worker in world.workers:
		ids.append(worker.worker_id)
	ids.sort()
	return ids


func _new_world() -> DebugTestWorld:
	var world := DebugTestWorld.new()
	world._init_ramp_lookup()
	world.block_registry.load_from_csv(World.BLOCK_DATA_PATH)
	world.save_load = WorldSaveLoad.new(world)
	world.task_manager = TaskManager.new(world, world.task_queue)
	world.world_seed = 12345
	world.spawn_initial_workers()
	var chunk := ChunkData.new(World.CHUNK_SIZE, World.BLOCK_ID_GRANITE)
	chunk.generated = true
	chunk.dirty = true
	world.chunks[Vector3i.ZERO] = chunk
	return world


func _run() -> void:
	test_root = ProjectSettings.globalize_path("res://.local-debug-controls-%d-%d" % [OS.get_process_id(), Time.get_ticks_usec()])
	check(DirAccess.make_dir_absolute(test_root) == OK, "Create isolated debug-controls fixture root")
	if not DirAccess.dir_exists_absolute(test_root):
		_finish()
		return
	_test_sim_speed_and_steps()
	_test_worker_controls()
	_test_task_release()
	_test_roster_persistence()
	_test_legacy_roster()
	_test_view_persistence_and_camera()
	_test_watchdog()
	_finish()


func _test_sim_speed_and_steps() -> void:
	var world := _new_world()
	check(OS.is_debug_build(), "Headless run is a debug build, enabling speed controls")
	check(world.set_sim_speed(10) == 10 and world.sim_speed == 10, "Simulation speed accepts 10")
	check(world.set_sim_speed(0) == 1 and world.sim_speed == 1, "Simulation speed clamps 0 to 1")
	check(world.set_sim_speed(99) == 10 and world.sim_speed == 10, "Simulation speed clamps 99 to 10")
	world.remove_workers(3)
	check(world.task_manager != null and world.workers.size() == 1, "Simulation-step fixture has a task manager and one worker")
	world.set_sim_speed(1)
	world.update_world_controlled(0.1, true)
	check(world.worker_update_calls == 1, "Speed 1 runs the worker phase once")
	world.set_sim_speed(10)
	world.update_world_controlled(0.1, true)
	check(world.worker_update_calls == 11, "Speed 10 runs ten worker phases")
	world.update_world_controlled(0.1, false)
	check(world.worker_update_calls == 11, "Paused update does not run worker phases")
	world.free()


func _test_worker_controls() -> void:
	var world := _new_world()
	check(world.add_workers(3) == 3 and world.workers.size() == 7, "Add three workers to the default four")
	check(_worker_ids(world) == [1, 2, 3, 4, 5, 6, 7], "Added workers receive unique IDs 5, 6, and 7")
	check(world.remove_workers(2) == 2 and world.workers.size() == 5, "Remove two workers")
	check(_worker_ids(world) == [1, 2, 3, 4, 5], "Removal removes highest IDs first")
	check(world.add_workers(World.MAX_WORKERS + 1) == World.MAX_WORKERS - 5 and world.workers.size() == World.MAX_WORKERS,
		"Adding past MAX_WORKERS is clamped")
	check(world.remove_workers(World.MAX_WORKERS + 10) == World.MAX_WORKERS and world.workers.is_empty(),
		"Removing more than present leaves no workers")
	world.free()


func _test_task_release() -> void:
	var world := _new_world()
	var task_id := world.task_queue.add_dig_task(Vector3i(2, 1, 2))
	var task = world.task_queue.get_task(task_id)
	var worker: Worker = world.workers[3]
	worker.current_task_id = task_id
	worker.set_state(Worker.WorkerState.WORKING, world)
	task.assigned_worker = worker
	task.status = TaskQueue.TaskStatus.IN_PROGRESS
	check(world.remove_workers(1) == 1, "Remove worker holding an in-progress dig task")
	check(task.status == TaskQueue.TaskStatus.PENDING and task.assigned_worker == null,
		"Removed worker releases dig task back to pending without an assignee")
	world.free()


func _test_roster_persistence() -> void:
	var world := _new_world()
	var path := test_root.path_join("roster.save")
	check(world.add_workers(2) == 2 and world.save_world(path), "Save a six-worker roster")
	check(world.remove_workers(6) == 6, "Clear workers before roster reload")
	check(world.load_world(path), "Load six-worker roster")
	check(world.workers.size() == 6 and _worker_ids(world) == [1, 2, 3, 4, 5, 6], "Roster reload preserves all six worker IDs")
	check(world.remove_workers(3) == 3 and world.save_world(path), "Save a three-worker roster")
	check(world.load_world(path), "Reload three-worker roster")
	check(world.workers.size() == 3 and _worker_ids(world) == [1, 2, 3], "Roster reload restores three workers")
	world.free()


func _test_legacy_roster() -> void:
	var world := _new_world()
	var path := test_root.path_join("legacy.save")
	var slot := path.get_basename()
	check(world.save_world(path), "Save a legacy fixture slot")
	_write_workers(slot, {"roles": [
		{"worker_id": 1, "role_id": 0, "work_priorities": {}},
		{"worker_id": 2, "role_id": 0, "work_priorities": {}},
	]})
	check(world.load_world(path), "Load legacy worker records without positions")
	check(world.workers.size() == 4 and _worker_ids(world) == [1, 2, 3, 4],
		"Legacy two-record file keeps default four-worker roster")
	world.free()


func _test_view_persistence_and_camera() -> void:
	var world := _new_world()
	var path := test_root.path_join("view.save")
	var expected := {"position": Vector3(1, 2, 3), "pitch": -35.0, "yaw": 45.0, "size": 20.0}
	world.saved_view_state = expected.duplicate()
	check(world.save_world(path) and world.load_world(path), "Save and load populated camera view")
	check(world.loaded_view_state == expected, "Loaded view state equals saved values")
	world.saved_view_state = {}
	check(world.save_world(path) and world.load_world(path), "Save and load empty camera view")
	check(world.loaded_view_state.is_empty(), "Empty saved view loads as empty")
	var camera := Camera3D.new()
	root.add_child(camera)
	var controller = CameraController.new()
	controller.initialize(camera, root.get_viewport())
	controller.cam_zoom_max = 100.0
	check(controller.apply_view_state(expected), "Camera applies valid view state")
	check(camera.position == expected.position and controller.cam_pitch == expected.pitch
		and controller.cam_yaw == expected.yaw and camera.size == expected.size, "Camera fields match applied view")
	var invalid_non_finite := expected.duplicate()
	invalid_non_finite.position = Vector3(INF, 0, 0)
	check(not controller.apply_view_state(invalid_non_finite), "Camera rejects non-finite position")
	var invalid_type := expected.duplicate()
	invalid_type.pitch = "bad"
	check(not controller.apply_view_state(invalid_type), "Camera rejects wrongly typed field")
	camera.queue_free()
	world.free()
	await process_frame


func _test_watchdog() -> void:
	var world := _new_world()
	var watchdog = Watchdog.new()
	watchdog.setup(world)
	watchdog.enabled = true
	watchdog.output_root = ""
	watchdog.keep_records = true
	watchdog.tick(0.5, true, 10)
	check(is_equal_approx(watchdog.sim_time, 5.0), "Watchdog simulation time advances by dt times sim steps")
	world.free()


func _finish() -> void:
	await process_frame
	check(test_root.get_base_dir() == ProjectSettings.globalize_path("res://").trim_suffix("/")
		and test_root.get_file().begins_with(".local-debug-controls-"), "Cleanup path is the isolated fixture root")
	if test_root.get_file().begins_with(".local-debug-controls-") and DirAccess.dir_exists_absolute(test_root):
		check(Transaction.new()._remove_tree(test_root), "Remove isolated debug-controls fixture files")
	print("Debug controls: %d checks, %d failures" % [checks, failures.size()])
	for message in failures:
		push_error(message)
	quit(1 if not failures.is_empty() else 0)
