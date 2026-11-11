extends SceneTree
## Issue #27: a worker that loses its footing must land on real support or be
## recovered next to where it was. It must never pass through solid terrain.
##
## Every scenario runs the production worker update loop on a slab of rock with a
## sealed cavern underneath. That is the layout of the 2026-09-12 trace in which
## a worker went from y=226 to y=135 through solid rock and ended in a cave.

const TreeKinds = preload("res://scripts/world/tree_store.gd")
const StairFlightScript = preload("res://scripts/stair_flight.gd")
const Snapshots = preload("res://scripts/diagnostics/live_decision_snapshot.gd")

const DT := 1.0 / 60.0
const MIN_XZ := -4
const MAX_XZ := 8
## Cavern: air at y 5..6 over a solid floor, sealed by rock from y 7 to FLOOR_Y.
const CAVE_STAND_Y := 5
const CAVE_TOP_Y := 6
## Top solid layer of the slab; workers stand in the cell above it.
const FLOOR_Y := 19
const STAND_Y := 20


class TestWorld extends World:
	var trace_log: Array[String] = []

	func ensure_chunk_generated(coord: Vector3i) -> ChunkData:
		var chunk := ensure_chunk(coord)
		if chunk != null:
			chunk.generated = true
		return chunk

	func trace_worker_event(worker: Worker, event: String, _task = null, details: String = "") -> void:
		trace_log.append("%s|%d|%s" % [event, worker.worker_id if worker != null else -1, details])

	func remove_from_inventory(_block_id: int, _count: int = 1) -> bool:
		return true

	func find_surface_y(_x: int, _z: int) -> int:
		return 19

	func traced(event: String, worker_id: int) -> bool:
		for line in trace_log:
			if line.begins_with("%s|%d|" % [event, worker_id]):
				return true
		return false


var checks := 0
var failures := 0


func _init() -> void:
	_test_block_built_on_occupied_cell()
	_test_cell_turns_solid_under_worker()
	_test_interrupted_between_ramp_and_upper_floor()
	_test_orphaned_stair_half()
	_test_open_drops_still_fall()
	_test_no_floor_below()
	print("Worker fall safety: %d checks, %d failures" % [checks, failures])
	quit(1 if failures else 0)


func _check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures += 1
		push_error(message)


#region Fixtures
func _world() -> TestWorld:
	var world := TestWorld.new()
	world.world_size_y = 32
	world._init_ramp_lookup()
	world.block_registry.load_from_csv(World.BLOCK_DATA_PATH)
	world.block_drop_table.load_from_csv(World.BLOCK_DROPS_PATH)
	world.tree_store.set_chunk_size(World.CHUNK_SIZE)
	world.task_manager = TaskManager.new(world, world.task_queue)
	for x in range(MIN_XZ, MAX_XZ + 1):
		for z in range(MIN_XZ, MAX_XZ + 1):
			for y in range(0, FLOOR_Y + 1):
				if y < CAVE_STAND_Y or y > CAVE_TOP_Y:
					world.set_block_raw(x, y, z, World.BLOCK_ID_GRANITE, false)
	for chunk: ChunkData in world.chunks.values():
		chunk.generated = true
	var dog = world.anomaly_watchdog
	dog.setup(world)
	dog.enabled = true
	dog.output_root = ""
	dog.keep_records = true
	return world


func _put(world: World, cell: Vector3i, block_id: int) -> void:
	world.set_block_raw(cell.x, cell.y, cell.z, block_id, true)


func _worker(world: World, worker_id: int, cell: Vector3i) -> Worker:
	var worker := Worker.new()
	worker.worker_id = worker_id
	worker.position = Vector3(cell)
	worker.target_pos = worker.position
	# These scenarios are about involuntary moves only.
	worker.wander_wait = 1.0e9
	world.add_child(worker)
	world.workers.append(worker)
	return worker


func _dispose(world: TestWorld) -> void:
	world.workers.clear()
	world.task_manager.shutdown()
	world.free()


func _block(world: World, cell: Vector3i) -> int:
	return world.get_block_no_generate(cell.x, cell.y, cell.z)


## Steps the production update loop and records what happened to one worker.
func _observe(world: TestWorld, worker: Worker, frames: int) -> Dictionary:
	var seen := {"lowest_y": worker.position.y, "fell_through_solid": false, "fell": false}
	for _frame in frames:
		var before := worker.position
		# Falls and rescues re-arm the wander timer; keep voluntary steps out.
		worker.wander_wait = 1.0e9
		world.update_workers(DT)
		if not is_instance_valid(worker):
			break
		var cell := worker.get_block_coord()
		if worker.state == Worker.WorkerState.FALLING:
			seen.fell = true
			if worker.position.y < before.y - 0.0001 \
					and world.pathfinder.is_blocking(world, _block(world, cell)):
				seen.fell_through_solid = true
		seen.lowest_y = minf(seen.lowest_y, worker.position.y)
	return seen


func _report(label: String, world: TestWorld, worker: Worker, start: Vector3, seen: Dictionary) -> void:
	print("[%s] start=%s end=%s lowest_y=%.2f fell_through_solid=%s state=%d fall=%s rescue=%s" % [
		label, start, worker.position, seen.lowest_y, seen.fell_through_solid, worker.state,
		world.traced("fall_started", worker.worker_id), world.traced("worker_rescued", worker.worker_id),
	])


## The worker is still in the roster, did not travel through rock, stands on
## valid support, and is within one cell of where the scenario left it.
func _check_stayed_put(label: String, world: TestWorld, worker: Worker, start: Vector3, seen: Dictionary) -> void:
	_report(label, world, worker, start, seen)
	_check(is_instance_valid(worker) and world.workers.has(worker) and worker.get_parent() == world,
		"%s: worker left the roster or the scene" % label)
	_check(not seen.fell_through_solid, "%s: worker fell through solid terrain" % label)
	_check(seen.lowest_y >= float(STAND_Y) - 0.001,
		"%s: worker dropped to y=%.2f below its floor at y=%d" % [label, seen.lowest_y, STAND_Y])
	var cell := worker.get_block_coord()
	_check(worker.state != Worker.WorkerState.FALLING and worker._can_stand_at(world, cell.x, cell.y, cell.z),
		"%s: worker did not end on valid support (cell %s, state %d)" % [label, cell, worker.state])
	var start_cell := Vector3i(int(round(start.x)), int(floor(start.y)), int(round(start.z)))
	_check(maxi(absi(cell.x - start_cell.x), absi(cell.z - start_cell.z)) <= 1 and absi(cell.y - start_cell.y) <= 1,
		"%s: worker ended at %s, more than one cell from %s" % [label, cell, start_cell])


func _events(world: World, check: String) -> Array:
	var found := []
	for record: Dictionary in world.anomaly_watchdog.records:
		if record.kind == "event" and record.check == check:
			found.append(record)
	return found
#endregion


## A builder completes a real PLACE job on a cell another worker is standing in.
func _test_block_built_on_occupied_cell() -> void:
	var world := _world()
	var cell := Vector3i(0, STAND_Y, 0)
	var bystander := _worker(world, 1, cell)
	var builder := _worker(world, 2, Vector3i(1, STAND_Y, 0))
	builder.work_priorities = {"building": 1}
	var task_id := world.task_queue.add_place_task(cell, World.BLOCK_ID_GRANITE)
	builder.assign_task_with_path(world, world.task_queue, world.task_queue.get_task(task_id), [builder.get_block_coord()], 0.0)
	_check(builder.current_task_id == task_id, "place: setup failed, builder does not own the PLACE job")
	var start := bystander.position
	var seen := _observe(world, bystander, 300)
	var placed := _block(world, cell) == World.BLOCK_ID_GRANITE
	print("[place] block placed=%s bystander cell=%s" % [placed, bystander.get_block_coord()])
	_check(not (placed and bystander.get_block_coord() == cell), "place: bystander left inside the placed block")
	_check_stayed_put("place", world, bystander, start, seen)
	_dispose(world)


## Any edit that fills a worker's cell. Also checks what the diagnostics record.
func _test_cell_turns_solid_under_worker() -> void:
	var world := _world()
	var cell := Vector3i(0, STAND_Y, 0)
	var worker := _worker(world, 1, cell)
	var start := worker.position
	_put(world, cell, World.BLOCK_ID_GRANITE)
	var seen := _observe(world, worker, 300)
	_check_stayed_put("entombed", world, worker, start, seen)
	_check(worker.get_block_coord().y == STAND_Y, "entombed: worker was lifted onto the new block instead of stepping aside")

	var rescues := _events(world, "worker_rescued")
	_check(rescues.size() == 1, "entombed: expected one worker_rescued anomaly record, got %d" % rescues.size())
	if rescues.size() == 1:
		var data: Dictionary = rescues[0].data
		_check(str(data.get("reason", "")) == "inside_solid_block", "entombed: rescue reason is '%s'" % data.get("reason", ""))
		_check(data.get("from") == [cell.x, cell.y, cell.z], "entombed: rescue record lacks the origin cell")
		_check(data.get("to") is Array and data.get("to") != data.get("from"), "entombed: rescue record lacks the destination cell")
		var support: Dictionary = data.get("support", {})
		_check(support.get("cell_block_id", -1) == World.BLOCK_ID_GRANITE and support.get("in_solid", false) == true,
			"entombed: rescue record lacks floor status for the cell the worker was in")
		_check(support.has("below_block_id") and support.has("standing_support"), "entombed: floor status lacks the supporting block")
		var snapshot: Dictionary = data.get("worker", {})
		_check(snapshot.has("position") and snapshot.has("state") and snapshot.has("current_task_id"),
			"entombed: rescue record lacks the worker position, state or task")
	var live := Snapshots.worker_snapshot(worker)
	var last: Dictionary = live.get("last_displacement", {})
	_check(last.get("kind", "") == "rescue" and last.get("from") == cell and last.get("to") == worker.get_block_coord(),
		"entombed: worker snapshot does not keep the last rescue")
	_dispose(world)


## A worker is stopped between a ramp and the floor above it. Its rounded cell is
## then the rock under that floor. The trigger is the production tree-removal
## path, which stops a worker that is walking to a tree.
func _test_interrupted_between_ramp_and_upper_floor() -> void:
	var world := _world()
	for x in range(2, MAX_XZ + 1):
		for z in range(-1, 2):
			_put(world, Vector3i(x, STAND_Y, z), World.BLOCK_ID_GRANITE)
	var low := Vector3i(0, STAND_Y, 0)
	var ramp := Vector3i(1, STAND_Y, 0)
	var high := Vector3i(2, STAND_Y + 1, 0)
	var beside_tree := Vector3i(3, STAND_Y + 1, 0)
	var tree := Vector3i(4, STAND_Y + 1, 0)
	_put(world, ramp, World.RAMP_EAST_ID)
	_check(world.pathfinder.can_traverse(world, low, ramp) and world.pathfinder.can_traverse(world, ramp, high)
		and world.pathfinder.can_traverse(world, high, beside_tree), "ramp: setup failed, route is not traversable")
	_check(world.add_tree(tree, TreeKinds.KIND_OAK, 0, 5), "ramp: setup failed, tree was not added")
	var worker := _worker(world, 1, low)
	var task_id := world.task_queue.add_chop_task(tree)
	worker.assign_task_with_path(world, world.task_queue, world.task_queue.get_task(task_id), [low, ramp, high, beside_tree], 0.0)
	_check(worker.current_task_id == task_id, "ramp: setup failed, worker does not own the CHOP job")
	var on_upper_half := false
	for _frame in 600:
		world.update_workers(DT)
		if worker.path_index == 2 and worker.path_segment_validated and worker.position.x >= 1.6:
			on_upper_half = true
			break
	_check(on_upper_half, "ramp: setup failed, worker never reached the upper half of the ramp step")
	var start := worker.position
	_check(world.remove_tree(tree, false), "ramp: setup failed, tree was not removed")
	_check(worker.state == Worker.WorkerState.IDLE and worker.current_task_id < 0, "ramp: setup failed, tree removal did not stop the worker")
	var seen := _observe(world, worker, 300)
	_check_stayed_put("ramp", world, worker, start, seen)
	_check(worker.get_block_coord() == high, "ramp: worker ended at %s, expected the nearer end of its step %s" % [worker.get_block_coord(), high])
	_dispose(world)


## The recorded 2026-09-12 case: the worker stands on one half of a stair flight
## and the other half is gone. Digging stairs is now rejected, but old saves can
## hold such halves (see stair_removal.gd), so the fall code must cope.
func _test_orphaned_stair_half() -> void:
	var world := _world()
	var lower := Vector3i(-2, STAND_Y, -1)
	var upper := lower + StairFlightScript.direction(0)
	_put(world, lower, StairFlightScript.lower_id(0))
	_put(world, upper, StairFlightScript.upper_id(0))
	var worker := _worker(world, 1, upper)
	worker.position.y += worker._ramp_center_offset(StairFlightScript.upper_id(0))
	_check(worker._has_standing_support(world), "stairs: setup failed, worker is not supported on the intact flight")
	var start := worker.position
	_put(world, lower, World.BLOCK_ID_AIR)
	var seen := _observe(world, worker, 300)
	_check_stayed_put("stairs", world, worker, start, seen)
	_check(worker.get_block_coord().y == STAND_Y, "stairs: worker ended at %s, expected a cell on its own floor" % worker.get_block_coord())
	_dispose(world)


## Real drops through open air still happen, land on the first floor, hand the
## job back, and are recorded with where the worker went.
func _test_open_drops_still_fall() -> void:
	var world := _world()
	var pit := Vector3i(-3, STAND_Y, 3)
	for y in range(17, FLOOR_Y + 1):
		_put(world, Vector3i(pit.x, y, pit.z), World.BLOCK_ID_AIR)
	var worker := _worker(world, 1, pit)
	var task_id := world.task_queue.add_dig_task(Vector3i(pit.x + 1, STAND_Y - 1, pit.z))
	var task = world.task_queue.get_task(task_id)
	task.status = TaskQueue.TaskStatus.IN_PROGRESS
	task.assigned_worker = worker
	worker.current_task_id = task_id
	worker.state = Worker.WorkerState.WORKING
	worker.work_timer = 60.0
	var seen := _observe(world, worker, 300)
	_report("pit", world, worker, Vector3(pit), seen)
	_check(worker.get_block_coord() == Vector3i(pit.x, 17, pit.z) and worker.state == Worker.WorkerState.IDLE,
		"pit: worker ended at %s in state %d, expected the pit floor" % [worker.get_block_coord(), worker.state])
	_check(seen.fell and not seen.fell_through_solid, "pit: worker did not fall through the open pit only")
	_check(not world.traced("worker_rescued", 1), "pit: an ordinary fall was treated as a rescue")
	_check(task.status == TaskQueue.TaskStatus.PENDING and task.assigned_worker == null and worker.current_task_id < 0,
		"pit: the interrupted job was not handed back")
	var falls := _events(world, "worker_fall")
	_check(falls.size() == 1, "pit: expected one worker_fall anomaly record, got %d" % falls.size())
	if falls.size() == 1:
		var data: Dictionary = falls[0].data
		_check(data.get("from") == [pit.x, pit.y, pit.z] and data.get("landing") == [pit.x, 17, pit.z] and data.get("drop_cells", 0) == 3,
			"pit: fall record lacks origin, landing or drop depth")
		_check(data.get("task_id", -1) == task_id, "pit: fall record lacks the interrupted task")
		var support: Dictionary = data.get("support", {})
		_check(support.get("below_block_id", -1) == World.BLOCK_ID_AIR and support.get("standing_support", true) == false,
			"pit: fall record lacks floor status")
	var landed := _events(world, "worker_landed")
	_check(landed.size() == 1 and landed[0].data.get("to") == [pit.x, 17, pit.z], "pit: landing was not recorded")
	var last: Dictionary = Snapshots.worker_snapshot(worker).get("last_displacement", {})
	_check(last.get("kind", "") == "fall" and last.get("from") == pit and last.get("to") == Vector3i(pit.x, 17, pit.z),
		"pit: worker snapshot does not keep the last fall")

	# A shaft that is open all the way into the cavern is a real, deep fall.
	var shaft := Vector3i(5, STAND_Y, 5)
	for y in range(CAVE_TOP_Y + 1, FLOOR_Y + 1):
		_put(world, Vector3i(shaft.x, y, shaft.z), World.BLOCK_ID_AIR)
	var diver := _worker(world, 2, shaft)
	seen = _observe(world, diver, 300)
	_report("shaft", world, diver, Vector3(shaft), seen)
	_check(diver.get_block_coord() == Vector3i(shaft.x, CAVE_STAND_Y, shaft.z) and not seen.fell_through_solid,
		"shaft: worker ended at %s, expected the cavern floor under the open shaft" % diver.get_block_coord())
	_dispose(world)


## Nothing below at all: the worker is recovered onto the nearest floor instead of
## being parked at the bottom of the world or re-rescued every frame.
func _test_no_floor_below() -> void:
	var world := _world()
	var over_void := Vector3i(MAX_XZ + 2, STAND_Y, 0)
	var worker := _worker(world, 1, over_void)
	var seen := _observe(world, worker, 300)
	_report("void", world, worker, Vector3(over_void), seen)
	var cell := worker.get_block_coord()
	_check(worker.state != Worker.WorkerState.FALLING and worker._can_stand_at(world, cell.x, cell.y, cell.z),
		"void: worker did not end on valid support (cell %s, state %d)" % [cell, worker.state])
	_check(cell == Vector3i(MAX_XZ, STAND_Y, 0), "void: worker ended at %s, expected the nearest floor cell" % cell)
	_check(seen.lowest_y >= float(STAND_Y) - 0.001, "void: worker dropped to y=%.2f" % seen.lowest_y)
	_dispose(world)
