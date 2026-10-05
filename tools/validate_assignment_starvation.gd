extends SceneTree

const StairFlightScript = preload("res://scripts/stair_flight.gd")
const WorkerRolesScript = preload("res://scripts/worker_roles.gd")


class TestWorld extends World:
	func ensure_chunk_generated(coord: Vector3i) -> ChunkData:
		var chunk := ensure_chunk(coord)
		if chunk != null:
			chunk.generated = true
		return chunk


var checks := 0
var failures := 0


func _check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures += 1
		push_error(message)


func _init() -> void:
	_test_item_rest_cell()
	_test_spawn_mining_drops_on_stair()
	_test_settle_loose_items()
	_test_backoff()
	_test_per_auction_blocking()
	_test_same_start_skip()
	_test_add_workers_near_and_fallback()
	print("Assignment starvation: %d checks, %d failures" % [checks, failures])
	quit(1 if failures else 0)


func _make_world() -> TestWorld:
	var world := TestWorld.new()
	world.world_size_y = 16
	world._init_ramp_lookup()
	world.block_registry.load_from_csv(World.BLOCK_DATA_PATH)
	world.block_drop_table.load_from_csv(World.BLOCK_DROPS_PATH)
	world.task_manager = TaskManager.new(world, world.task_queue)
	return world


func _dispose(world: World) -> void:
	if world == null:
		return
	if world.task_manager != null:
		world.task_manager.shutdown()
	world.free()


func _put(world: World, cell: Vector3i, block_id: int) -> void:
	world.set_block_raw(cell.x, cell.y, cell.z, block_id, true)


func _prepare_floor(world: World, center: Vector3i, radius: int = 3, floor_y: int = 1) -> void:
	for x in range(center.x - radius, center.x + radius + 1):
		for z in range(center.z - radius, center.z + radius + 1):
			_put(world, Vector3i(x, floor_y, z), World.BLOCK_ID_GRANITE)
			_put(world, Vector3i(x, floor_y + 1, z), World.BLOCK_ID_AIR)
			_put(world, Vector3i(x, floor_y + 2, z), World.BLOCK_ID_AIR)
			_put(world, Vector3i(x, floor_y + 3, z), World.BLOCK_ID_AIR)


func _prepare_stair(world: World, anchor: Vector3i, rotation: int = 0) -> Array[Vector3i]:
	var cells := StairFlightScript.cells(anchor, rotation)
	for cell: Vector3i in cells:
		_put(world, cell + Vector3i.DOWN, World.BLOCK_ID_GRANITE)
		_put(world, cell, World.BLOCK_ID_AIR)
		_put(world, cell + Vector3i.UP, World.BLOCK_ID_AIR)
	_put(world, cells[0], StairFlightScript.lower_id(rotation))
	_put(world, cells[1], StairFlightScript.upper_id(rotation))
	return cells


func _test_item_rest_cell() -> void:
	var world := _make_world()
	var floor := Vector3i(0, 1, 0)
	_prepare_floor(world, floor, 2)
	var falling := Vector3i(0, 4, 0)
	_check(world.item_rest_cell(falling) == Vector3i(0, 2, 0), "A: item above two-cell drop did not land on floor")
	var normal_floor := Vector3i(1, 2, 0)
	_check(world.item_rest_cell(normal_floor) == normal_floor, "A: item already on normal floor moved")
	var solid_inside := Vector3i(2, 3, 0)
	_put(world, solid_inside, World.BLOCK_ID_GRANITE)
	_check(world.item_rest_cell(solid_inside) == solid_inside, "A: item inside solid cell moved")
	var stair_cells := _prepare_stair(world, Vector3i(0, 2, 2), 0)
	var above_upper := stair_cells[1] + Vector3i.UP
	_check(world.item_rest_cell(above_upper) == stair_cells[1], "A: item above stair upper half did not land on stair")
	var unloaded := Vector3i(64, 4, 0)
	_check(world.item_rest_cell(unloaded) == unloaded, "A: item in unloaded column moved")
	_dispose(world)


func _test_spawn_mining_drops_on_stair() -> void:
	var world := _make_world()
	var stair_cells := _prepare_stair(world, Vector3i(4, 2, 0), 0)
	world.drop_rng.seed = 7
	var spawned := world.spawn_mining_drops(World.BLOCK_ID_DIRT, stair_cells[1] + Vector3i.UP)
	_check(not spawned.is_empty(), "B: mining drop fixture produced no item")
	var all_on_stair := true
	for item_id: int in spawned:
		var item := world.item_store.get_item(item_id)
		all_on_stair = all_on_stair and item.get("pos", Vector3i.ZERO) == stair_cells[1]
	_check(all_on_stair, "B: mining drop above stair was not placed on stair cell")
	_dispose(world)


func _test_settle_loose_items() -> void:
	var world := _make_world()
	_prepare_floor(world, Vector3i(0, 1, 0), 4)
	var stockpile_id := world.create_stockpile([Vector3i(3, 2, 0)])
	var source := Vector3i(0, 4, 0)
	var rest := Vector3i(0, 2, 0)
	var item_id := world.item_store.add_stack(World.BLOCK_ID_DIRT, 1, source)
	var old_id := world.task_queue.add_haul_task(item_id, source, World.BLOCK_ID_DIRT, stockpile_id, Vector3i(3, 2, 0))
	var old_task = world.task_queue.get_task(old_id)
	world.item_store.reserve_item(item_id, old_id)
	world.task_manager._settle_loose_items()
	var settled_item := world.item_store.get_item(item_id)
	_check(settled_item.get("pos", Vector3i.ZERO) == rest, "C: pending haul item did not move to rest cell")
	_check(world.task_queue.get_task(old_id) == null, "C: old pending haul survived item settling")
	_check(int(settled_item.get("reserved_by_task_id", -1)) == -1, "C: settled item reservation was not released")
	world.task_manager.update_task_queue()
	var rebuilt: Variant = _haul_for_item(world, item_id)
	_check(rebuilt != null and rebuilt.id != old_id and rebuilt.pos == rest, "C: settled item did not rebuild a haul at new cell")
	_check(old_task != null, "C: pending haul fixture was not created")

	var in_progress_source := Vector3i(1, 4, 0)
	var in_progress_item_id := world.item_store.add_stack(World.BLOCK_ID_DIRT, 1, in_progress_source)
	var in_progress_id := world.task_queue.add_haul_task(
		in_progress_item_id,
		in_progress_source,
		World.BLOCK_ID_DIRT,
		stockpile_id,
		Vector3i(3, 2, 0)
	)
	var in_progress_task = world.task_queue.get_task(in_progress_id)
	in_progress_task.status = TaskQueue.TaskStatus.IN_PROGRESS
	world.item_store.reserve_item(in_progress_item_id, in_progress_id)
	world.task_manager._settle_loose_items()
	var in_progress_item := world.item_store.get_item(in_progress_item_id)
	_check(in_progress_item.get("pos", Vector3i.ZERO) == in_progress_source, "C: in-progress haul item moved during settling")
	_check(world.task_queue.get_task(in_progress_id) == in_progress_task, "C: in-progress haul was removed during settling")
	_check(int(in_progress_item.get("reserved_by_task_id", -1)) == in_progress_id, "C: in-progress haul reservation changed")
	_dispose(world)


func _test_backoff() -> void:
	var world := _make_world()
	var task_id := world.task_queue.add_dig_task(Vector3i(0, 2, 0))
	var task = world.task_queue.get_task(task_id)
	var now := 100000
	var expected := [2500, 5000, 10000]
	for index in 3:
		var call_now := now + index * 100
		world.task_manager._mark_task_path_blocked(task, call_now)
		_check(task.retry_due_msec - call_now == expected[index], "D: path block backoff delay %d was wrong" % (index + 1))
	for index in 10:
		world.task_manager._mark_task_path_blocked(task, now + 1000 + index)
	_check(task.retry_due_msec - (now + 1009) == TaskQueue.TASK_UNREACHABLE_MAX_TTL_MSEC, "D: path block backoff did not cap at 60000 ms")
	world.task_manager.invalidate_task_accessibility(task.pos)
	_check(task.path_block_streak == 0, "D: nearby terrain invalidation did not reset path streak")
	_dispose(world)


func _new_worker(world: World, worker_id: int, cell: Vector3i) -> Worker:
	var worker := Worker.new()
	worker.worker_id = worker_id
	worker.role_id = WorkerRolesScript.Role.MINER
	worker.work_priorities = {"mining": 1, "hauling": 1, "building": 1}
	worker.position = Vector3(cell)
	world.add_child(worker)
	world.workers.append(worker)
	return worker


func _test_per_auction_blocking() -> void:
	var world := _make_world()
	var task_id := world.task_queue.add_dig_task(Vector3i(20, 2, 0))
	var task = world.task_queue.get_task(task_id)
	for worker_id in 20:
		_new_worker(world, worker_id + 1, Vector3i(worker_id, 2, 0))
	world.task_manager._start_assignment_auction(task)
	_check(world.task_manager.assignment_workers.size() == 20, "E: not all 20 workers entered auction")
	for worker: Worker in world.task_manager.assignment_workers:
		world.task_manager.mark_worker_unreachable_for_task(task, worker)
	_check(task.accessibility == TaskQueue.TaskAccessibility.UNREACHABLE, "E: all failed auction workers did not block task")
	_check(task.block_reason == TaskQueue.TaskBlockReason.NO_WORKER_PATH, "E: all failed auction reason was not NO_WORKER_PATH")
	_check(world.task_manager.assignment_failed_count == 20, "E: failed worker count did not reach auction size")
	_dispose(world)


func _failed_bid_result(worker: Worker) -> Dictionary:
	return {
		"path": [],
		"search_ms": 0.0,
		"snapshot_ms": 0.0,
		"queue_wait_ms": 0.0,
		"search_stats": {"hit_iteration_cap": false, "reason": "fixture_failure", "iterations_used": 1, "max_iterations": 2},
		"worker_id": worker.worker_id,
	}


func _test_same_start_skip() -> void:
	var world := _make_world()
	_prepare_floor(world, Vector3i(0, 1, 0), 5)
	var task_id := world.task_queue.add_dig_task(Vector3i(8, 2, 0))
	var task = world.task_queue.get_task(task_id)
	var same_cell := Vector3i(0, 2, 0)
	var workers: Array[Worker] = []
	for worker_id in 10:
		workers.append(_new_worker(world, worker_id + 1, same_cell))
	world.task_manager._start_assignment_auction(task)
	world.task_manager._queue_worker_bid(task, workers[0])
	_check(world.task_manager.assignment_pending_jobs.size() == 1, "F: first same-start worker did not enqueue search")
	world.task_manager._collect_worker_bid_result(task, workers[0], _failed_bid_result(workers[0]))
	world.task_manager.assignment_pending_jobs.clear()
	world.task_manager.assignment_job_context.clear()
	world.task_manager.path_search_scheduler.clear()
	for index in range(1, workers.size()):
		world.task_manager._queue_worker_bid(task, workers[index])
	_check(world.task_manager.assignment_pending_jobs.is_empty(), "F: same-start workers enqueued searches after first uncapped failure")
	_check(task.accessibility == TaskQueue.TaskAccessibility.UNREACHABLE, "F: skipped same-start workers did not finish auction blocking")
	_check(task.block_reason == TaskQueue.TaskBlockReason.NO_WORKER_PATH, "F: same-start block reason was not NO_WORKER_PATH")
	_check(world.task_manager.assignment_failed_starts.has(same_cell), "F: failed start cell was not recorded")
	_dispose(world)

	world = _make_world()
	var different_task_id := world.task_queue.add_dig_task(Vector3i(8, 2, 0))
	var different_task = world.task_queue.get_task(different_task_id)
	var first := _new_worker(world, 1, Vector3i(0, 2, 0))
	var second := _new_worker(world, 2, Vector3i(2, 2, 0))
	world.task_manager._start_assignment_auction(different_task)
	world.task_manager._queue_worker_bid(different_task, first)
	world.task_manager.assignment_pending_jobs.clear()
	world.task_manager.assignment_job_context.clear()
	world.task_manager.path_search_scheduler.clear()
	world.task_manager._collect_worker_bid_result(different_task, first, _failed_bid_result(first))
	world.task_manager._queue_worker_bid(different_task, second)
	_check(world.task_manager.assignment_pending_jobs.size() == 1, "F negative: different-start worker was incorrectly skipped")
	_check(not world.task_manager.assignment_failed_starts.has(second.get_block_coord()), "F negative: different start was recorded as failed")
	_dispose(world)


func _test_add_workers_near_and_fallback() -> void:
	var world := _make_world()
	var near := Vector3i(5, 2, 5)
	_prepare_floor(world, near, 2)
	var added := world.add_workers(3, near)
	_check(added == 3, "G: add_workers did not add three workers")
	var all_near := true
	for worker: Worker in world.workers:
		all_near = all_near and worker.get_block_coord() == near \
			and world.pathfinder.is_walkable(world, near.x, near.y, near.z)
	_check(all_near, "G: added workers were not on the requested nearby walkable cell")
	_dispose(world)

	world = _make_world()
	var fallback_near := Vector3i(64, 2, 64)
	var fallback_count := world.add_workers(1, fallback_near)
	var expected_offset: Vector2i = World.WORKER_SPAWN_OFFSETS[0]
	var expected_position := Vector3(
		expected_offset.x,
		world.find_surface_y(expected_offset.x, expected_offset.y) + World.WORKER_SPAWN_HEIGHT_OFFSET,
		expected_offset.y
	)
	_check(fallback_count == 1, "G: unloaded near point did not add fallback worker")
	_check(not world.workers.is_empty() and world.workers[0].position == expected_position, "G: unloaded near point did not use old spawn fallback")
	_dispose(world)


func _haul_for_item(world: World, item_id: int):
	for task in world.task_queue.tasks:
		if task.type == TaskQueue.TaskType.HAUL and int(task.data.get("item_id", -1)) == item_id:
			return task
	return null
