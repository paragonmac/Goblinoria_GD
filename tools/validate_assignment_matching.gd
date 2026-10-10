extends SceneTree
## Grid auction + round matching (SEE-ADR-005 amendment 2026-10-10): regression
## scenarios from the review of the assignment redesign. Real TaskManager and
## search thread, headless.

const WorkerRolesScript = preload("res://scripts/worker_roles.gd")

const SURFACE_Y := 227
const DT := 1.0 / 60.0

var checks := 0
var failures := 0


class TestWorld extends World:
	func ensure_chunk_generated(coord: Vector3i) -> ChunkData:
		var chunk := ensure_chunk(coord)
		if chunk != null:
			chunk.generated = true
		return chunk


class Recorder:
	extends RefCounted
	var enabled := true
	var events: Array = []
	func observe(subject: String, subject_id: Variant, reason: String, data: Dictionary = {}) -> void:
		events.append({"subject": subject, "id": str(subject_id), "reason": reason, "data": data})
	func invalidate(_s: String, _i: Variant, _r: String) -> void:
		pass
	func begin_world(_r: String) -> void:
		pass
	func mark_event(_r: String, _d: Dictionary = {}) -> void:
		pass
	func count(reason: String) -> int:
		var total := 0
		for event in events:
			if event.reason == reason:
				total += 1
		return total


func _init() -> void:
	_run.call_deferred()


func _check(ok: bool, message: String) -> void:
	checks += 1
	if not ok:
		failures += 1
		push_error(message)


func _make_world(half: int) -> TestWorld:
	var world := TestWorld.new()
	world.world_size_y = 256
	world._init_ramp_lookup()
	world.block_registry.load_from_csv(World.BLOCK_DATA_PATH)
	world.block_drop_table.load_from_csv(World.BLOCK_DROPS_PATH)
	world.task_manager = TaskManager.new(world, world.task_queue)
	for x in range(-half, half):
		for z in range(-half, half):
			for y in range(216, 227):
				world.set_block_raw(x, y, z, World.BLOCK_ID_GRANITE, false)
	return world


## set_block_raw does not mark chunks generated; path snapshots only see generated ones.
func _generate(world: TestWorld) -> void:
	for chunk: ChunkData in world.chunks.values():
		chunk.generated = true


func _worker(world: TestWorld, id: int, cell: Vector3i) -> Worker:
	var worker := Worker.new()
	worker.worker_id = id
	worker.role_id = WorkerRolesScript.Role.MINER
	worker.work_priorities = {"mining": 1, "hauling": 1, "building": 1}
	worker.position = Vector3(cell)
	world.add_child(worker)
	world.workers.append(worker)
	return worker


func _dispose(world: TestWorld) -> void:
	world.task_manager.shutdown()
	world.free()


func _run() -> void:
	await _test_nearer_worker_wins()
	await _test_trapped_worker_blocks_task()
	await _test_place_material_budget()
	await _test_assignment_under_digging_churn()
	print("Assignment matching: %d checks, %d failures" % [checks, failures])
	quit(1 if failures > 0 else 0)


## T0 at x=0, T at x=6. W1 (x=1) is nearest T0; W2 (x=2) is 4 from T; W3 (x=12)
## is 6 from T. Shortest valid path wins: T goes to W2, not W3.
func _test_nearer_worker_wins() -> void:
	var world := _make_world(24)
	world.set_block_raw(0, SURFACE_Y, 0, World.BLOCK_ID_GRANITE, false)
	world.set_block_raw(6, SURFACE_Y, 0, World.BLOCK_ID_GRANITE, false)
	_generate(world)
	var t0: int = world.task_queue.add_dig_task(Vector3i(0, SURFACE_Y, 0))
	var t: int = world.task_queue.add_dig_task(Vector3i(6, SURFACE_Y, 0))
	_worker(world, 1, Vector3i(1, SURFACE_Y, 0))
	_worker(world, 2, Vector3i(2, SURFACE_Y, 0))
	_worker(world, 3, Vector3i(12, SURFACE_Y, 0))
	for step in 300:
		world.update_world(DT)
		await process_frame
		var task_t = world.task_queue.get_task(t)
		var task_t0 = world.task_queue.get_task(t0)
		if task_t != null and task_t.assigned_worker != null and task_t0 != null and task_t0.assigned_worker != null:
			break
	var owner_t = world.task_queue.get_task(t).assigned_worker if world.task_queue.get_task(t) != null else null
	var owner_t0 = world.task_queue.get_task(t0).assigned_worker if world.task_queue.get_task(t0) != null else null
	_check(owner_t0 != null and owner_t0.worker_id == 1, "Nearest worker takes T0 (got %s)" % str(owner_t0.worker_id if owner_t0 else -1))
	_check(owner_t != null and owner_t.worker_id == 2, "Nearer idle worker takes T over a farther one (got %s)" % str(owner_t.worker_id if owner_t else -1))
	_dispose(world)


## A miner sealed underground cannot reach a surface dig: the task must be
## blocked, not re-auctioned forever as inconclusive.
func _test_trapped_worker_blocks_task() -> void:
	var world := _make_world(70)
	world.set_block_raw(5, 220, 5, World.BLOCK_ID_AIR, false)
	world.set_block_raw(0, SURFACE_Y, 0, World.BLOCK_ID_GRANITE, false)
	_generate(world)
	var recorder := Recorder.new()
	world.live_diagnostics = recorder
	var task_id: int = world.task_queue.add_dig_task(Vector3i(0, SURFACE_Y, 0))
	_worker(world, 1, Vector3i(5, 220, 5))
	var blocked_step := -1
	for step in 600:
		world.update_world(DT)
		await process_frame
		var task = world.task_queue.get_task(task_id)
		if task.block_reason == TaskQueue.TaskBlockReason.NO_WORKER_PATH:
			blocked_step = step
			break
	_check(blocked_step >= 0, "Trapped worker's task is blocked as NO_WORKER_PATH (grid auctions %d, inconclusive %d)" % [recorder.count("grid_auction_queued"), recorder.count("assignment_bid_inconclusive")])
	_dispose(world)


## One stored granite, five PLACE tasks and five builders: one commit must not
## send more builders than there is material.
func _test_place_material_budget() -> void:
	var world := _make_world(24)
	_generate(world)
	world.add_to_inventory(World.BLOCK_ID_GRANITE, 1)
	for i in 5:
		world.task_queue.add_place_task(Vector3i(i * 4, SURFACE_Y, 0), World.BLOCK_ID_GRANITE)
		_worker(world, i + 1, Vector3i(i * 4, SURFACE_Y, 2))
	var max_assigned := 0
	for step in 120:
		world.update_world(DT)
		await process_frame
		var assigned := 0
		for worker: Worker in world.workers:
			if worker.current_task_id >= 0:
				assigned += 1
		max_assigned = maxi(max_assigned, assigned)
	_check(max_assigned == 1, "PLACE assignments respect stored material (max concurrently assigned %d with 1 granite)" % max_assigned)
	_dispose(world)


## 36 miners and 240 surface digs: digs complete constantly (terrain churn
## inside every auction box). Assignment must keep workers busy.
func _test_assignment_under_digging_churn() -> void:
	var world := _make_world(64)
	var cells: Array[Vector3i] = []
	for i in 240:
		var cell := Vector3i(-40 + (i % 20) * 4, SURFACE_Y, -40 + (i / 20) * 7)
		world.set_block_raw(cell.x, cell.y, cell.z, World.BLOCK_ID_GRANITE, false)
		cells.append(cell)
	_generate(world)
	for cell in cells:
		world.task_queue.add_dig_task(cell)
	for i in 36:
		_worker(world, i + 1, Vector3i(-30 + (i % 6) * 10, SURFACE_Y, -38 + (i / 6) * 14 + 1))
	var started := Time.get_ticks_msec()
	var idle_sum := 0
	var samples := 0
	var first_mostly_busy := -1
	for step in 1800:
		world.update_world(DT)
		await process_frame
		var idle := 0
		for worker: Worker in world.workers:
			if worker.current_task_id < 0:
				idle += 1
		if idle <= 12 and first_mostly_busy < 0:
			first_mostly_busy = step
		if step >= 600:
			idle_sum += idle
			samples += 1
	var mean_idle := float(idle_sum) / maxf(1.0, samples)
	# Baseline before the grid auction (2f99c79): no assignments at all here,
	# mean idle 36 / 36. Workers are briefly idle between digs, so "all busy at
	# once" is not a fair criterion.
	print("  churn: first step with >= 24 busy %d, mean idle after step 600 = %.1f / 36, %.1f s" % [first_mostly_busy, mean_idle, (Time.get_ticks_msec() - started) / 1000.0])
	# Bounds leave room for search-thread timing; per-round grid caching (backlog)
	# is the next improvement (measured 2026-10-10: >= 24 busy by ~step 1100,
	# mean idle ~12).
	_check(first_mostly_busy >= 0 and first_mostly_busy <= 1500, "At least 24 of 36 miners busy within 1500 steps under digging churn (step %d)" % first_mostly_busy)
	_check(mean_idle <= 18.0, "Mean idle miners after step 600 stays at most half under churn (%.1f)" % mean_idle)
	_dispose(world)
