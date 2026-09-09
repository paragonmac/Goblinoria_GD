extends SceneTree

const Priorities = preload("res://scripts/worker_work_priorities.gd")
const Roles = preload("res://scripts/worker_roles.gd")

class Snapshot:
	extends RefCounted
	var valid := true
	func revisions_match(_world) -> bool:
		return valid

class Scheduler:
	extends RefCounted
	var results: Array = []
	var costs: Dictionary = {}
	var next_id := 1
	var held := false
	var enqueue_count := 0
	var maximum_results := 0
	func enqueue(_world, auction_id, task, worker, _iterations) -> int:
		var id := next_id
		next_id += 1
		enqueue_count += 1
		var path: Array = []
		for _step in range(int(costs.get(Vector2i(worker.worker_id, task.id), 3))):
			path.append(worker.get_block_coord())
		results.append({"kind": "assignment", "job_id": id, "auction_id": auction_id,
			"task_id": task.id, "worker_id": worker.worker_id, "path": path,
			"snapshot": Snapshot.new(), "search_ms": 0.1})
		maximum_results = maxi(maximum_results, results.size())
		return id
	func pop_result() -> Dictionary:
		return {} if held or results.is_empty() else results.pop_front()
	func clear() -> void:
		results.clear()
	func stop() -> void:
		clear()

class TestWorld:
	extends World
	func get_block_no_generate(_x: int, y: int, _z: int) -> int:
		return BLOCK_ID_GRANITE if y == 0 else BLOCK_ID_AIR
	func is_block_protected_from_dig(_pos: Vector3i) -> bool:
		return false

var checks := 0
var failures: Array[String] = []


func _init() -> void:
	_run.call_deferred()


func _run() -> void:
	_catalog_and_api()
	_choices(1, 2, 9, 2, TaskQueue.TaskType.DIG, "Priority 1 beats a closer priority 2")
	_choices(2, 2, 9, 2, TaskQueue.TaskType.HAUL, "Equal priorities use cheapest route across types")
	_choices(1, 2, 0, 2, TaskQueue.TaskType.HAUL, "Unreachable higher work does not starve lower work")
	_choices(0, 2, 1, 2, TaskQueue.TaskType.HAUL, "Off excludes even the closest job")
	_multiple_workers()
	_stale_results()
	_stale_collected_choice()
	_mutation_during_round()
	_bounded_scan()
	_pruning_and_materials()
	await _real_threaded_round()
	if failures.is_empty():
		print("Work priorities contract OK (%d checks)" % checks)
		quit(0)
	else:
		for failure in failures:
			push_error(failure)
		quit(1)


func _world(count: int = 1) -> TestWorld:
	var world := TestWorld.new()
	world._init_ramp_lookup()
	world.block_registry.load_from_csv(World.BLOCK_DATA_PATH)
	world.task_manager = TaskManager.new(world, world.task_queue)
	world.task_manager.path_search_scheduler.stop()
	world.task_manager.path_search_scheduler = Scheduler.new()
	for index in range(count):
		var worker := Worker.new()
		worker.worker_id = index + 1
		worker.position = Vector3(0, 1, 0)
		world.add_child(worker)
		world.workers.append(worker)
	return world


func _dispose(world: TestWorld) -> void:
	world.task_manager.shutdown()
	world.task_manager.shutdown()
	_check(world.task_manager.priority_choices.is_empty() and world.task_manager.assignment_bids.is_empty()
		and world.task_manager.assignment_pending_jobs.is_empty() and world.task_manager.assignment_job_context.is_empty()
		and world.task_manager.haul_path_requests_by_worker.is_empty() and world.task_manager.assist_requests_by_worker.is_empty(),
		"Idempotent shutdown releases retained nominations, bids and request contexts")
	world.free()


func _catalog_and_api() -> void:
	var world := _world()
	var worker: Worker = world.workers[0]
	var entries := Priorities.entries()
	_check(entries[0].id == "hauling" and entries[1].id == "mining" and entries[2].id == "crafting", "Catalog order")
	entries[0].label = "mutated"
	_check(Priorities.entries()[0].label == "Hauling", "Catalog copies are owned by caller")
	for role in [Roles.Role.MINER, Roles.Role.HAULER, Roles.Role.FIGHTER]:
		worker.role_id = role
		for task_type in [TaskQueue.TaskType.DIG, TaskQueue.TaskType.PLACE, TaskQueue.TaskType.STAIRS, TaskQueue.TaskType.HAUL]:
			var task := TaskQueue.Task.new(99, Vector3i.ONE, task_type, 0)
			_check(worker.can_accept_task(task) == Roles.allowed_task_types(role).has(task_type), "Role default eligibility preserved")
	_check(world.set_worker_work_priority(1, "hauling", 2), "Fighter can be cross-trained for hauling")
	_check(worker.get_work_priority("hauling") == 2 and worker.work_priorities == {"hauling": 2}, "Override dictionary contract")
	for key in ["crafting", "unknown"]:
		_check(not world.set_worker_work_priority(1, key, 1), "Unavailable work rejected")
	for value in [-1, 10]:
		_check(not world.set_worker_work_priority(1, "mining", value), "Out-of-range priority rejected")
	_check(not world.set_worker_work_priority(999, "mining", 1), "Unknown worker rejected")
	for value in range(10):
		_check(world.set_worker_work_priority(1, "building", value) and worker.get_work_priority("building") == value, "All priorities 0..9 accepted")
	var task = world.task_queue.get_task(world.task_queue.add_haul_task(1, Vector3i(1, 1, 0), 2, 1, Vector3i(2, 1, 0)))
	worker.assign_task_with_path(world, world.task_queue, task, [worker.get_block_coord()], 0.0)
	var path_before := worker.path.duplicate()
	world.task_manager.haul_path_requests_by_worker[1] = {"request_id": 123}
	_check(world.set_worker_work_priority(1, "hauling", 0), "Mid-job settings accepted")
	_check(worker.current_task_id == task.id and task.assigned_worker == worker and worker.path == path_before, "Active job and path unchanged")
	_check(worker.can_work_task(task, world, world.pathfinder) and not worker.can_accept_task(task), "Owned job can finish with category Off")
	_check(world.task_manager.haul_path_requests_by_worker.has(1), "Active delivery request retained")
	_dispose(world)
	world = _world()
	worker = world.workers[0]
	_check(worker.can_idle_wander(), "Default Miner retains idle wandering")
	for key in ["mining", "hauling", "building"]:
		world.set_worker_work_priority(1, key, 0)
	_check(not worker.can_idle_wander(), "All-Off Miner does not start reserve wandering")
	worker.task_search_timer = 0.0
	worker.update_idle(0.0, world, world.task_queue, world.pathfinder)
	_check(worker.state == Worker.WorkerState.IDLE and worker.path.is_empty(), "All-Off worker stays at reserve position")
	worker.role_id = Roles.Role.FIGHTER
	worker.work_priorities.clear()
	_check(not worker.can_idle_wander(), "Default Fighter retains reserve behavior")
	_dispose(world)


func _choices(mining: int, hauling: int, dig_cost: int, haul_cost: int, expected_type: int, message: String) -> void:
	var world := _world()
	world.set_worker_work_priority(1, "mining", mining)
	world.set_worker_work_priority(1, "hauling", hauling)
	var dig_id := world.task_queue.add_dig_task(Vector3i(8, 1, 0))
	var haul_id := world.task_queue.add_haul_task(1, Vector3i(1, 1, 0), 2, 1, Vector3i(2, 1, 0))
	var scheduler: Scheduler = world.task_manager.path_search_scheduler
	scheduler.costs[Vector2i(1, dig_id)] = dig_cost
	scheduler.costs[Vector2i(1, haul_id)] = haul_cost
	_pump_until_claimed(world, 1)
	var chosen = world.task_queue.get_task(world.workers[0].current_task_id)
	_check(chosen != null and chosen.type == expected_type, message)
	_check(scheduler.maximum_results <= 1, "Only one assignment result is outstanding")
	_dispose(world)


func _multiple_workers() -> void:
	var world := _world(2)
	for worker: Worker in world.workers:
		world.set_worker_work_priority(worker.worker_id, "mining", 1)
		world.set_worker_work_priority(worker.worker_id, "hauling", 2)
	var dig_id := world.task_queue.add_dig_task(Vector3i(8, 1, 0))
	var haul_id := world.task_queue.add_haul_task(1, Vector3i(1, 1, 0), 2, 1, Vector3i(2, 1, 0))
	var scheduler: Scheduler = world.task_manager.path_search_scheduler
	scheduler.costs[Vector2i(1, dig_id)] = 5
	scheduler.costs[Vector2i(2, dig_id)] = 3
	_pump_until_claimed(world, 2)
	_check(world.workers[1].current_task_id == dig_id, "Closest eligible worker wins contested high-priority job")
	_check(world.workers[0].current_task_id == haul_id, "Claimed higher work does not starve other worker's lower work")
	_dispose(world)
	world = _world(2)
	dig_id = world.task_queue.add_dig_task(Vector3i(8, 1, 0))
	_pump_until_claimed(world, 1)
	_check(world.workers[0].current_task_id == dig_id and world.workers[1].current_task_id == -1, "Equal route bids tie-break by worker ID")
	_dispose(world)


func _stale_results() -> void:
	for mode in ["setter", "direct_override", "terrain", "removed"]:
		var world := _world()
		world.set_worker_work_priority(1, "hauling", 2)
		var dig_id := world.task_queue.add_dig_task(Vector3i(8, 1, 0))
		var haul_id := world.task_queue.add_haul_task(1, Vector3i(1, 1, 0), 2, 1, Vector3i(2, 1, 0))
		var scheduler: Scheduler = world.task_manager.path_search_scheduler
		scheduler.held = true
		world.task_manager.update_task_assignments()
		_check(scheduler.results.size() == 1, "Asynchronous bid queued")
		if mode == "setter":
			world.set_worker_work_priority(1, "mining", 0)
		elif mode == "direct_override":
			world.workers[0].work_priorities["mining"] = 0
		elif mode == "terrain":
			scheduler.results[0].snapshot.valid = false
			scheduler.costs[Vector2i(1, dig_id)] = 0
		else:
			world.task_queue.remove_task(world.task_queue.get_task(dig_id))
		scheduler.held = false
		_pump_until_claimed(world, 1)
		_check(world.workers[0].current_task_id == haul_id, "Reject stale result: " + mode)
		_dispose(world)


func _bounded_scan() -> void:
	var world := _world()
	for index in range(1000):
		var task = world.task_queue.get_task(world.task_queue.add_dig_task(Vector3i(index, 1, 0)))
		task.accessibility = TaskQueue.TaskAccessibility.UNREACHABLE
	world.task_manager.update_task_assignments()
	_check(world.task_manager.priority_task_cursor <= 128, "Task filtering advances at most 128 records per update")
	_dispose(world)


func _stale_collected_choice() -> void:
	var world := _world()
	world.set_worker_work_priority(1, "mining", 1)
	world.set_worker_work_priority(1, "hauling", 2)
	world.task_queue.add_dig_task(Vector3i(8, 1, 0))
	var haul_id := world.task_queue.add_haul_task(1, Vector3i(1, 1, 0), 2, 1, Vector3i(2, 1, 0))
	for _frame in range(20):
		world.task_manager.update_task_assignments()
		if not world.task_manager.priority_choices.is_empty():
			break
	_check(not world.task_manager.priority_choices.is_empty(), "Reachable best bid retained before final commit")
	world.workers[0].work_priorities["mining"] = 0
	_pump_until_claimed(world, 1)
	_check(world.workers[0].current_task_id == haul_id, "Collected choice revalidates configuration at commit")
	_dispose(world)


func _real_threaded_round() -> void:
	var world := _world()
	world.task_manager.path_search_scheduler = preload("res://scripts/pathfinding/path_search_scheduler.gd").new()
	world.task_manager.path_search_scheduler.start()
	for x in range(-2, 12):
		for z in range(-2, 3):
			world.set_block_raw(x, 0, z, World.BLOCK_ID_GRANITE, true)
	world.set_worker_work_priority(1, "mining", 1)
	world.set_worker_work_priority(1, "hauling", 2)
	var dig_id := world.task_queue.add_dig_task(Vector3i(8, 1, 0))
	world.task_queue.add_haul_task(1, Vector3i(1, 1, 0), 2, 1, Vector3i(2, 1, 0))
	var deadline := Time.get_ticks_msec() + 5000
	while world.workers[0].current_task_id < 0 and Time.get_ticks_msec() < deadline:
		world.task_manager.update_task_assignments()
		await create_timer(0.001).timeout
	_check(world.workers[0].current_task_id == dig_id, "Real asynchronous path round honors cross-type priority")
	_check(world.workers[0].path.size() > 2, "Real winner uses farther reachable route over nearby haul")
	_dispose(world)


func _pruning_and_materials() -> void:
	var world := _world(4)
	var nearest_id := world.task_queue.add_dig_task(Vector3i(1, 1, 0))
	for index in range(999):
		world.task_queue.add_dig_task(Vector3i(10 + index, 1, 0))
	var scheduler: Scheduler = world.task_manager.path_search_scheduler
	for worker: Worker in world.workers:
		scheduler.costs[Vector2i(worker.worker_id, nearest_id)] = 1
	_pump_until_claimed(world, 1)
	_check(scheduler.enqueue_count == 4, "1000-task round prunes distant equal-priority routes after four near-worker bids")
	_check(world.workers[0].current_task_id == nearest_id, "Pruning preserves closest choice and worker tie-break")
	_dispose(world)
	world = _world()
	world.set_worker_work_priority(1, "building", 1)
	world.set_worker_work_priority(1, "hauling", 2)
	var place_id := world.task_queue.add_place_task(Vector3i(2, 1, 0), World.PLACE_MATERIAL_ID)
	var haul_id := world.task_queue.add_haul_task(1, Vector3i(3, 1, 0), 2, 1, Vector3i(4, 1, 0))
	_pump_until_claimed(world, 1)
	_check(world.workers[0].current_task_id == haul_id, "Unfunded higher-priority Place does not starve hauling")
	_check(world.task_queue.get_task(place_id).status == TaskQueue.TaskStatus.PENDING, "Unfunded Place remains pending, not path-blocked")
	_check(world.task_manager.path_search_scheduler.enqueue_count == 1, "Unfunded Place does not enqueue a path")
	_dispose(world)
	world = _world()
	for _frame in range(1000):
		world.task_manager.update_task_assignments()
	_check(not world.task_manager.priority_round_active and world.task_manager.path_search_scheduler.enqueue_count == 0, "Empty-queue idle frames do not start rounds or searches")
	_dispose(world)
	_check(Priorities.route_length_lower_bound(Vector3i(0, 1, 0), Vector3i(0, 0, 0), TaskQueue.TaskType.STAIRS) == 1, "Upper-level stair work uses admissible bound")
	_check(Priorities.route_length_lower_bound(Vector3i(0, 1, 0), Vector3i(3, 4, 0), TaskQueue.TaskType.HAUL) == 4, "Simultaneous horizontal/vertical edges are not double-counted")


func _mutation_during_round() -> void:
	var world := _world()
	var first_id := world.task_queue.add_dig_task(Vector3i(8, 1, 0))
	world.task_manager.path_search_scheduler.costs[Vector2i(1, first_id)] = 8
	for _frame in range(3):
		world.task_manager.update_task_assignments()
	var added_id := world.task_queue.add_dig_task(Vector3i(1, 1, 0))
	world.task_manager.path_search_scheduler.costs[Vector2i(1, added_id)] = 1
	_pump_until_claimed(world, 1)
	_check(world.workers[0].current_task_id == added_id, "New task during winner reduction participates before claim")
	_dispose(world)
	world = _world()
	var removed_id := world.task_queue.add_dig_task(Vector3i(0, 2, 0))
	world.task_queue.get_task(removed_id).accessibility = TaskQueue.TaskAccessibility.UNREACHABLE
	var far_id := world.task_queue.add_dig_task(Vector3i(8, 1, 0))
	for index in range(300):
		var task = world.task_queue.get_task(world.task_queue.add_dig_task(Vector3i(index, 3, 0)))
		task.accessibility = TaskQueue.TaskAccessibility.UNREACHABLE
	var near_id := world.task_queue.add_dig_task(Vector3i(1, 1, 0))
	var scheduler: Scheduler = world.task_manager.path_search_scheduler
	scheduler.costs[Vector2i(1, far_id)] = 8
	scheduler.costs[Vector2i(1, near_id)] = 1
	for _frame in range(4):
		world.task_manager.update_task_assignments()
	_check(world.task_manager.priority_task_cursor > 2 and world.task_manager.priority_task_cursor < 303, "Mutation fixture paused within bounded task scan")
	# Emulate swap-based storage: the unvisited tail moves behind the scan cursor.
	var removed = world.task_queue.get_task(removed_id)
	world.task_queue.tasks[0] = world.task_queue.get_task(near_id)
	world.task_queue.tasks[world.task_queue.tasks.size() - 1] = removed
	world.task_queue.remove_task(removed)
	_pump_until_claimed(world, 1)
	_check(world.workers[0].current_task_id == near_id, "Membership mutation cannot skip a moved unvisited cheaper job")
	_dispose(world)
	for mutation in ["start", "snapshot", "configuration"]:
		world = _world()
		world.set_worker_work_priority(1, "mining", 1)
		world.set_worker_work_priority(1, "hauling", 2)
		far_id = world.task_queue.add_dig_task(Vector3i(8, 1, 0))
		near_id = world.task_queue.add_haul_task(1, Vector3i(1, 1, 0), 2, 1, Vector3i(2, 1, 0))
		for _frame in range(2):
			world.task_manager.update_task_assignments()
		_check(world.task_manager.priority_choices.has(1), "Best choice available before freshness edit")
		if mutation == "start":
			world.workers[0].position.x += 1
		elif mutation == "snapshot":
			world.task_manager.priority_choices[1].snapshot.valid = false
		else:
			world.workers[0].work_priorities["mining"] = 0
		_check(world.task_manager._can_improve_priority_choice(world.task_queue.get_task(near_id), world.workers[0]), "Stale remembered choice cannot prune lower candidate: " + mutation)
		_check(not world.task_manager.priority_choices.has(1) and world.task_manager.priority_task_cursor == 0, "Invalid bound discarded and prior candidates revisited immediately")
		_dispose(world)


func _pump_until_claimed(world: TestWorld, count: int) -> void:
	for _frame in range(1000):
		world.task_manager.update_task_assignments()
		var assigned := 0
		for worker: Worker in world.workers:
			if worker.current_task_id >= 0:
				assigned += 1
		if assigned >= count:
			return
	_check(false, "Assignment round failed to converge")


func _check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)
