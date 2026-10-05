extends SceneTree

const WorkerRolesScript = preload("res://scripts/worker_roles.gd")

class TestWorld extends World:
	func ensure_chunk_generated(coord: Vector3i) -> ChunkData:
		var chunk := ensure_chunk(coord)
		if chunk != null:
			chunk.generated = true
		return chunk

var checks := 0
var failures := 0


func _init() -> void:
	_test_worker_in_solid()
	_test_worker_unsupported()
	_test_worker_no_progress()
	_test_worker_out_of_tree()
	_test_task_assignment_mismatch()
	_test_task_pending_with_idle_worker()
	_test_task_cycling()
	_test_paused_ticks()
	_test_entity_gone()
	_test_epoch_reset()
	_test_event_rate_limit()
	_test_worker_removed()
	_test_disabled()
	print("Anomaly watchdog: %d checks, %d failures" % [checks, failures])
	quit(1 if failures else 0)


func _check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
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
	var dog = world.anomaly_watchdog
	dog.setup(world)
	dog.enabled = true
	dog.output_root = ""
	dog.keep_records = true
	return world


func _put(world: World, cell: Vector3i, block_id: int) -> void:
	world.set_block_raw(cell.x, cell.y, cell.z, block_id, true)


func _worker(world: World, worker_id: int, cell: Vector3i, state: int = Worker.WorkerState.IDLE, add_to_tree: bool = true) -> Worker:
	var worker := Worker.new()
	worker.worker_id = worker_id
	worker.role_id = WorkerRolesScript.Role.MINER
	worker.position = Vector3(cell)
	worker.state = state
	worker.current_task_id = -1
	world.workers.append(worker)
	if add_to_tree:
		root.add_child(worker)
	return worker


func _dispose(world: World, extra_workers: Array = []) -> void:
	for worker: Worker in world.workers:
		if is_instance_valid(worker):
			worker.free()
	world.workers.clear()
	for worker: Worker in extra_workers:
		if is_instance_valid(worker):
			worker.free()
	world.task_manager.shutdown()
	world.free()


func _records(world: World, kind: String, check: String = "") -> Array:
	var found := []
	for record: Dictionary in world.anomaly_watchdog.records:
		if record.kind == kind and (check.is_empty() or record.check == check):
			found.append(record)
	return found


func _resolved_reason(world: World, check: String, subject: String, reason: String) -> bool:
	for record: Dictionary in _records(world, "resolved", check):
		if record.subject == subject and record.data.get("reason", "") == reason:
			return true
	return false


func _test_worker_in_solid() -> void:
	var world := _world()
	var dog = world.anomaly_watchdog
	_put(world, Vector3i(0, 4, 0), World.BLOCK_ID_GRANITE)
	var worker := _worker(world, 1, Vector3i(0, 4, 0))
	for i in 6:
		dog.tick(0.25, true)
	var opened := _records(world, "opened", "worker_in_solid")
	_check(opened.size() == 1, "Worker in granite opens once after the threshold")
	for i in 8:
		dog.tick(0.25, true)
	_check(_records(world, "opened", "worker_in_solid").size() == 1, "Persistent solid condition is logged only once")
	worker.position = Vector3(0, 4, 0)
	_put(world, Vector3i(0, 4, 0), World.BLOCK_ID_AIR)
	for i in 2:
		dog.tick(0.25, true)
	_check(_resolved_reason(world, "worker_in_solid", "worker:1", "cleared"), "Leaving granite resolves the condition as cleared")
	_dispose(world)

	world = _world()
	dog = world.anomaly_watchdog
	_put(world, Vector3i(0, 4, 0), World.BLOCK_ID_GRANITE)
	_worker(world, 2, Vector3i(0, 4, 0), Worker.WorkerState.FALLING)
	for i in 12:
		dog.tick(0.25, true)
	_check(_records(world, "opened", "worker_in_solid").is_empty(), "Falling worker inside granite does not open worker_in_solid")
	_dispose(world)


func _test_worker_unsupported() -> void:
	var world := _world()
	var dog = world.anomaly_watchdog
	_put(world, Vector3i(2, 3, 0), World.BLOCK_ID_AIR)
	_put(world, Vector3i(2, 4, 0), World.BLOCK_ID_AIR)
	_worker(world, 1, Vector3i(2, 4, 0))
	_worker(world, 2, Vector3i(0, 4, 0))
	for i in 6:
		dog.tick(0.25, true)
	_check(_records(world, "opened", "worker_unsupported").size() == 1, "Unsupported worker opens while supported worker does not")
	_check(_records(world, "opened", "worker_unsupported")[0].subject == "worker:1", "Supported worker has no unsupported record")
	_dispose(world)


func _test_worker_no_progress() -> void:
	var world := _world()
	var dog = world.anomaly_watchdog
	var worker := _worker(world, 1, Vector3i(0, 4, 0), Worker.WorkerState.MOVING)
	for i in 116:
		dog.tick(0.25, true)
	_check(_records(world, "opened", "worker_no_progress").is_empty(), "Unchanged position has not opened at 29 seconds")
	worker.position = Vector3(1, 4, 0)
	for i in 118:
		dog.tick(0.25, true)
	_check(_records(world, "opened", "worker_no_progress").is_empty(), "Changing coordinate restarts the no-progress clock")
	for i in 2:
		dog.tick(0.25, true)
	_check(_records(world, "opened", "worker_no_progress").is_empty(), "No-progress remains closed before 30 seconds at the new coordinate")
	for i in 2:
		dog.tick(0.25, true)
	_check(_records(world, "opened", "worker_no_progress").size() == 1, "No-progress condition opens after 30 seconds at one coordinate")
	for i in 20:
		dog.tick(0.25, true)
	_check(_records(world, "opened", "worker_no_progress").size() == 1, "Persistent no-progress condition is logged only once")
	_dispose(world)


func _test_worker_out_of_tree() -> void:
	var world := _world()
	var dog = world.anomaly_watchdog
	_worker(world, 1, Vector3i(0, 4, 0), Worker.WorkerState.IDLE, false)
	for i in 6:
		dog.tick(0.25, true)
	_check(_records(world, "opened", "worker_out_of_tree").size() == 1, "Worker outside the scene tree opens worker_out_of_tree")
	_dispose(world)


func _test_task_assignment_mismatch() -> void:
	var world := _world()
	var dog = world.anomaly_watchdog
	var task_id: int = world.task_queue.add_dig_task(Vector3i(2, 4, 0))
	var task = world.task_queue.get_task(task_id)
	var worker := _worker(world, 1, Vector3i(1, 4, 0), Worker.WorkerState.WORKING)
	worker.current_task_id = task_id + 1
	task.assigned_worker = worker
	task.status = TaskQueue.TaskStatus.IN_PROGRESS
	for i in 10:
		dog.tick(0.25, true)
	_check(_records(world, "opened", "task_assignment_mismatch").size() == 1, "Mismatched in-progress assignment opens after two seconds")
	_dispose(world)

	world = _world()
	dog = world.anomaly_watchdog
	task_id = world.task_queue.add_dig_task(Vector3i(2, 4, 0))
	task = world.task_queue.get_task(task_id)
	worker = _worker(world, 1, Vector3i(1, 4, 0), Worker.WorkerState.WORKING)
	worker.current_task_id = task_id
	task.assigned_worker = worker
	task.status = TaskQueue.TaskStatus.IN_PROGRESS
	for i in 16:
		dog.tick(0.25, true)
	_check(_records(world, "opened", "task_assignment_mismatch").is_empty(), "Consistent in-progress assignment does not open mismatch")
	_dispose(world)


func _test_task_pending_with_idle_worker() -> void:
	var world := _world()
	var dog = world.anomaly_watchdog
	var task_id: int = world.task_queue.add_dig_task(Vector3i(2, 4, 0))
	world.task_queue.get_task(task_id).status = TaskQueue.TaskStatus.PENDING
	_worker(world, 1, Vector3i(0, 4, 0))
	for i in 242:
		dog.tick(0.25, true)
	_check(_records(world, "opened", "task_pending_with_idle_worker").size() == 1, "Pending task with eligible idle Miner opens after 60 seconds")
	_dispose(world)

	world = _world()
	dog = world.anomaly_watchdog
	task_id = world.task_queue.add_dig_task(Vector3i(2, 4, 0))
	var unreachable = world.task_queue.get_task(task_id)
	unreachable.accessibility = TaskQueue.TaskAccessibility.UNREACHABLE
	_worker(world, 1, Vector3i(0, 4, 0))
	for i in 250:
		dog.tick(0.25, true)
	_check(_records(world, "opened", "task_pending_with_idle_worker").is_empty(), "Unreachable pending task does not open against an idle worker")
	_dispose(world)


func _test_task_cycling() -> void:
	var world := _world()
	var dog = world.anomaly_watchdog
	var task_id: int = world.task_queue.add_dig_task(Vector3i(2, 4, 0))
	var task = world.task_queue.get_task(task_id)
	for flip in 6:
		task.status = TaskQueue.TaskStatus.IN_PROGRESS
		for i in 2:
			dog.tick(0.25, true)
		task.status = TaskQueue.TaskStatus.PENDING
		for i in 2:
			dog.tick(0.25, true)
		if flip == 2:
			_check(_records(world, "event", "task_cycling").size() == 0, "Task cycling is not reported before four releases")
	_check(_records(world, "event", "task_cycling").size() == 1, "Four or more releases report exactly one task_cycling event")
	_dispose(world)


func _test_paused_ticks() -> void:
	var world := _world()
	var dog = world.anomaly_watchdog
	_put(world, Vector3i(0, 4, 0), World.BLOCK_ID_GRANITE)
	_worker(world, 1, Vector3i(0, 4, 0))
	for i in 200:
		dog.tick(0.25, false)
	_check(_records(world, "opened").is_empty(), "Paused ticks do not age simulation checks")
	_dispose(world)


func _test_entity_gone() -> void:
	var world := _world()
	var dog = world.anomaly_watchdog
	var task_id: int = world.task_queue.add_dig_task(Vector3i(2, 4, 0))
	var task = world.task_queue.get_task(task_id)
	var worker := _worker(world, 1, Vector3i(1, 4, 0), Worker.WorkerState.WORKING)
	worker.current_task_id = task_id + 1
	task.assigned_worker = worker
	task.status = TaskQueue.TaskStatus.IN_PROGRESS
	for i in 10:
		dog.tick(0.25, true)
	_check(_records(world, "opened", "task_assignment_mismatch").size() == 1, "Mismatch is open before its task is removed")
	world.task_queue.remove_task(task)
	for i in 6:
		dog.tick(0.25, true)
	_check(_resolved_reason(world, "task_assignment_mismatch", "task:%d" % task_id, "entity_gone"), "Removed task resolves mismatch as entity_gone")
	_dispose(world)


func _test_epoch_reset() -> void:
	var world := _world()
	var dog = world.anomaly_watchdog
	_put(world, Vector3i(0, 4, 0), World.BLOCK_ID_GRANITE)
	_worker(world, 1, Vector3i(0, 4, 0))
	for i in 6:
		dog.tick(0.25, true)
	_check(_records(world, "opened", "worker_in_solid").size() == 1, "Condition is open before epoch reset")
	var sessions_before := _records(world, "session", "world_epoch").size()
	world.runtime_epoch += 1
	dog.tick(0.25, true)
	_check(_resolved_reason(world, "worker_in_solid", "worker:1", "world_reset"), "Epoch change resolves open condition as world_reset")
	_check(_records(world, "session", "world_epoch").size() == sessions_before + 1, "Epoch change writes a new session record")
	_dispose(world)


func _test_event_rate_limit() -> void:
	var world := _world()
	var dog = world.anomaly_watchdog
	for i in 25:
		dog.report_event("worker_fall", "worker:1", {})
	_check(_records(world, "event", "worker_fall").size() == 20, "Per-check event rate limit keeps exactly 20 events")
	_check(dog.suppressed >= 5, "Per-check event rate limit counts at least five suppressed events")
	_dispose(world)


func _test_worker_removed() -> void:
	var world := _world()
	var dog = world.anomaly_watchdog
	var worker := _worker(world, 1, Vector3i(0, 4, 0))
	for i in 2:
		dog.tick(0.25, true)
	world.workers.erase(worker)
	for i in 2:
		dog.tick(0.25, true)
	var removed := _records(world, "event", "worker_removed")
	_check(removed.size() == 1 and removed[0].subject == "worker:1", "Worker removed after observation emits one worker_removed event")
	_dispose(world, [worker])


func _test_disabled() -> void:
	var world := _world()
	var dog = world.anomaly_watchdog
	dog.enabled = false
	_put(world, Vector3i(0, 4, 0), World.BLOCK_ID_GRANITE)
	_worker(world, 1, Vector3i(0, 4, 0))
	for i in 200:
		dog.tick(0.25, true)
	_check(dog.records.is_empty(), "Disabled watchdog produces no records")
	_dispose(world)
