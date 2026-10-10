extends SceneTree
## Depth-scaling assignment regression. 36 idle surface miners must be assigned
## 47 dig tasks in a room at y=223 that is reachable only through four two-cell
## north-facing stair flights. Also checks that a sealed-rock dig task is marked
## unreachable with NO_WORKER_PATH. Capped bids must never mark unreachable.

const StairFlightScript = preload("res://scripts/stair_flight.gd")
const WorkerRolesScript = preload("res://scripts/worker_roles.gd")
const TaskWorkRulesScript = preload("res://scripts/task_work_position_rules.gd")

const SURFACE_Y := 227
const ROOM_Y := 223
const GRANITE_TOP_Y := 226
const BEDROCK_Y := 216
const HALF := 40
const WORLD_SIZE_Y := 256
const MAX_STEPS := 600
const NEGATIVE_MAX_STEPS := 300
const DT := 1.0 / 60.0
const WORKER_COUNT := 36
const UNCAPPED_ITERATIONS := 200000

var failures: Array[String] = []
var checks := 0
var steps := 0
var steps_until_all_assigned := -1
var room_no_path_seen := false
var room_task_ids: Array[int] = []


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
	func invalidate(_subject: String, _subject_id: Variant, _reason: String) -> void:
		pass
	func begin_world(_reason: String) -> void:
		pass
	func mark_event(_reason: String, _data: Dictionary = {}) -> void:
		pass
	func count(reason: String) -> int:
		var total := 0
		for event in events:
			if event.reason == reason:
				total += 1
		return total


func _init() -> void:
	_run.call_deferred()


func _check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)
		push_error(message)
		print("FAIL: " + message)
	else:
		print("PASS: " + message)


func _make_world() -> TestWorld:
	var world := TestWorld.new()
	world.world_size_y = WORLD_SIZE_Y
	world._init_ramp_lookup()
	world.block_registry.load_from_csv(World.BLOCK_DATA_PATH)
	world.block_drop_table.load_from_csv(World.BLOCK_DROPS_PATH)
	world.task_manager = TaskManager.new(world, world.task_queue)
	return world


func _dispose(world: TestWorld) -> void:
	if world.task_manager != null:
		world.task_manager.shutdown()
	world.free()


func _new_worker(world: TestWorld, worker_id: int, cell: Vector3i) -> Worker:
	var worker := Worker.new()
	worker.worker_id = worker_id
	worker.role_id = WorkerRolesScript.Role.MINER
	worker.work_priorities = {"mining": 1, "hauling": 1, "building": 1}
	worker.position = Vector3(cell)
	world.add_child(worker)
	world.workers.append(worker)
	return worker


func _build_depth_terrain(world: TestWorld) -> void:
	# Solid granite from bedrock up to the cell below the surface.
	for x in range(-HALF, HALF):
		for z in range(-HALF, HALF):
			for y in range(BEDROCK_Y, GRANITE_TOP_Y + 1):
				world.set_block_raw(x, y, z, World.BLOCK_ID_GRANITE, false)
	# Four north-facing two-cell flights down a single shaft at x=0.
	for k in range(4):
		var level := GRANITE_TOP_Y - k
		for z in range(3 * k - 1, 3 * k + 2):
			for y in range(level, SURFACE_Y + 1):
				world.set_block_raw(0, y, z, 0, false)
		world.set_block_raw(0, level, 3 * k - 1, StairFlightScript.upper_id(0), false)
		world.set_block_raw(0, level, 3 * k, StairFlightScript.lower_id(0), false)
	# Room air at y=223..224.
	for x in range(-12, 13):
		for z in range(10, 23):
			world.set_block_raw(x, ROOM_Y, z, 0, false)
			world.set_block_raw(x, ROOM_Y + 1, z, 0, false)
	# set_block_raw creates chunks without marking them generated; background
	# path searches only snapshot generated chunks, so mark the fixture's.
	for chunk: ChunkData in world.chunks.values():
		chunk.generated = true


func _add_room_tasks(world: TestWorld) -> void:
	for x in range(-12, 13):
		room_task_ids.append(world.task_queue.add_dig_task(Vector3i(x, ROOM_Y, 23)))
	for z in range(12, 23):
		room_task_ids.append(world.task_queue.add_dig_task(Vector3i(-13, ROOM_Y, z)))
		room_task_ids.append(world.task_queue.add_dig_task(Vector3i(13, ROOM_Y, z)))


func _assigned_count(workers: Array[Worker]) -> int:
	var total := 0
	for worker in workers:
		if worker.current_task_id >= 0:
			total += 1
	return total


func _any_room_task_no_path(world: TestWorld) -> bool:
	for task_id in room_task_ids:
		var task = world.task_queue.get_task(task_id)
		if task != null and task.block_reason == TaskQueue.TaskBlockReason.NO_WORKER_PATH:
			return true
	return false


func _count_unreachable_after_capped_bid(recorder: Recorder) -> int:
	var capped_workers := {}
	var violations := 0
	for event in recorder.events:
		if event.subject != "worker":
			continue
		if event.reason == "assignment_bid_inconclusive":
			capped_workers[event.id] = true
		elif event.reason == "task_worker_unreachable" and capped_workers.has(event.id):
			violations += 1
	return violations


func _uncapped_reach_count(world: TestWorld, spawn_cells: Array[Vector3i], goals: Array[Vector3i]) -> int:
	var reached := 0
	for cell in spawn_cells:
		for goal in goals:
			var path = world.pathfinder.find_path(world, cell, goal, false, false, UNCAPPED_ITERATIONS)
			if not path.is_empty():
				reached += 1
				break
	return reached


func _run_negative_fixture() -> Dictionary:
	# Single-cell air pocket sealed in granite, with the dig target on its face.
	# The worker stands on an open surface, so the only failure is no route.
	var world := _make_world()
	for x in range(-6, 7):
		for z in range(-6, 7):
			for y in range(BEDROCK_Y, GRANITE_TOP_Y + 1):
				world.set_block_raw(x, y, z, World.BLOCK_ID_GRANITE, false)
	world.set_block_raw(5, 220, 5, 0, false)
	for chunk: ChunkData in world.chunks.values():
		chunk.generated = true
	var recorder := Recorder.new()
	world.live_diagnostics = recorder
	var task_id: int = world.task_queue.add_dig_task(Vector3i(4, 220, 5))
	_new_worker(world, 1001, Vector3i(-4, SURFACE_Y, -4))
	var reached := false
	var negative_steps := 0
	for _step in NEGATIVE_MAX_STEPS:
		world.update_world(DT)
		negative_steps += 1
		await process_frame
		var task = world.task_queue.get_task(task_id)
		if task != null and task.accessibility == TaskQueue.TaskAccessibility.UNREACHABLE \
				and task.block_reason == TaskQueue.TaskBlockReason.NO_WORKER_PATH:
			reached = true
			break
	var result := {
		"reached": reached,
		"steps": negative_steps,
		"no_worker_path_events": recorder.count("no_worker_path"),
	}
	_dispose(world)
	return result


func _run() -> void:
	var started_msec := Time.get_ticks_msec()
	var world := _make_world()
	_build_depth_terrain(world)
	_add_room_tasks(world)
	var recorder := Recorder.new()
	world.live_diagnostics = recorder

	var spawn_cells: Array[Vector3i] = []
	var workers: Array[Worker] = []
	for i in WORKER_COUNT:
		var cell := Vector3i(-15 + (i % 6) * 6, SURFACE_Y, 4 + (i / 6) * 4)
		spawn_cells.append(cell)
		workers.append(_new_worker(world, i + 1, cell))

	print("Fixture: %d room dig tasks, %d workers, world_size_y=%d" % [room_task_ids.size(), workers.size(), world.world_size_y])

	for _step in MAX_STEPS:
		world.update_world(DT)
		steps += 1
		await process_frame
		if not room_no_path_seen and _any_room_task_no_path(world):
			room_no_path_seen = true
		if _assigned_count(workers) == WORKER_COUNT:
			steps_until_all_assigned = steps
			break

	var assigned := _assigned_count(workers)
	var inconclusive := recorder.count("assignment_bid_inconclusive")
	var unreachable := recorder.count("task_worker_unreachable")
	var capped_then_unreachable := _count_unreachable_after_capped_bid(recorder)

	# Uncapped evidence: every surface worker can reach a work position of the room.
	var goals: Array[Vector3i] = []
	var first_task = world.task_queue.get_task(room_task_ids[0])
	if first_task != null:
		goals = TaskWorkRulesScript.task_work_positions(world, world.pathfinder, first_task.pos, TaskQueue.TaskType.DIG)
	var uncapped_reached := _uncapped_reach_count(world, spawn_cells, goals)

	var negative: Dictionary = await _run_negative_fixture()
	var elapsed := (Time.get_ticks_msec() - started_msec) / 1000.0

	_dispose(world)

	print("Summary:")
	print("  steps until all assigned: %s" % (str(steps_until_all_assigned) if steps_until_all_assigned >= 0 else "not reached"))
	print("  assigned workers: %d / %d after %d steps" % [assigned, WORKER_COUNT, steps])
	print("  inconclusive bids: %d" % inconclusive)
	print("  unreachable marks: %d" % unreachable)
	print("  unreachable marks after a capped bid: %d" % capped_then_unreachable)
	print("  uncapped find_path reach: %d / %d surface workers to a room work position" % [uncapped_reached, WORKER_COUNT])
	print("  negative fixture: reached=%s after %d steps (no_worker_path events: %d)" % [str(negative.reached), negative.steps, negative.no_worker_path_events])
	print("  auction winners: %d" % recorder.count("auction_winner"))
	for event in recorder.events:
		if event.reason == "task_worker_unreachable":
			print("  first unreachable event: %s" % str(event))
			break
	print("  wall-clock seconds: %.2f" % elapsed)

	_check(steps_until_all_assigned >= 0,
		"all %d workers assigned within %d steps (assigned %d)" % [WORKER_COUNT, MAX_STEPS, assigned])
	_check(capped_then_unreachable == 0,
		"no worker marked unreachable after an iteration-capped bid (%d violations)" % capped_then_unreachable)
	_check(not room_no_path_seen,
		"no room dig task has block_reason NO_WORKER_PATH at any step")
	_check(bool(negative.reached),
		"sealed-rock dig task marked UNREACHABLE / NO_WORKER_PATH within %d steps" % NEGATIVE_MAX_STEPS)

	print("Assignment depth scaling: %d checks, %d failures" % [checks, failures.size()])
	quit(1 if not failures.is_empty() else 0)
