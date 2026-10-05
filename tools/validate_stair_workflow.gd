extends SceneTree
## Real worker, threaded assignment and canonical updates against the F1 terrain.

class FixtureWorld extends World:
	func _ready() -> void:
		# Fixture terrain is explicit; no renderer, save access or world generation.
		_init_ramp_lookup()
		block_registry.load_from_csv(BLOCK_DATA_PATH)
		block_drop_table.load_from_csv(BLOCK_DROPS_PATH)
		drop_rng.seed = 17
		task_manager = TaskManager.new(self, task_queue)

	func ensure_chunk_generated(coord: Vector3i) -> ChunkData:
		var chunk := ensure_chunk(coord)
		chunk.generated = true
		return chunk

const LOWER := Vector3i(-9, 226, -4)
const UPPER := Vector3i(-9, 226, -5)
const FIRST := Vector3i(-9, 226, -3)
const SECOND := Vector3i(-9, 226, -2)
var failures := 0
var steps := 0
var completed: Array[int] = []


func _init() -> void:
	call_deferred("_run")


func _check(value: bool, message: String) -> void:
	if not value:
		failures += 1
		push_error(message)


func _run() -> void:
	var world := FixtureWorld.new()
	root.add_child(world)
	for x in range(-14, -3):
		for z in range(-8, 3):
			for y in range(225, 230):
				var id := World.BLOCK_ID_AIR
				if y == 225: id = World.BLOCK_ID_DIRT
				if y == 226: id = World.BLOCK_ID_GRASS
				world.set_block_raw(x, y, z, id, true)
	world.set_block_raw(LOWER.x, LOWER.y, LOWER.z, 124, true)
	world.set_block_raw(UPPER.x, UPPER.y, UPPER.z, 128, true)
	var worker := Worker.new()
	worker.worker_id = 1
	worker.use_animated_model = false
	worker.position = Vector3(-9, 227, -6)
	worker.work_priorities = {"mining": 2, "building": 2, "hauling": 0}
	world.add_child(worker)
	world.workers.append(worker)
	world.task_queue.task_removed.connect(func(id: int):
		completed.append(id))
	var selection := MainSelectionController.new()
	selection.world = world
	world.player_mode = World.PlayerMode.DIG
	_check(selection._enqueue_task_at(FIRST.x, FIRST.y, FIRST.z).queued, "First dig designation accepted")
	_check(selection._enqueue_task_at(SECOND.x, SECOND.y, SECOND.z).queued, "Second dig designation accepted")
	var first_id: int = world.task_queue.get_active_tasks_at(FIRST)[0].id
	var second_id: int = world.task_queue.get_active_tasks_at(SECOND)[0].id
	var dug := await _advance_until(world, func():
		return _block(world, FIRST) == World.BLOCK_ID_AIR and _block(world, SECOND) == World.BLOCK_ID_AIR)
	_check(dug, "Miner descends, mines first block and opens second block through normal assignment")
	_check(completed.has(first_id) and completed.has(second_id), "Both dig jobs finish")
	_check(_block(world, LOWER) == 124 and _block(world, UPPER) == 128, "Mining leaves stairs intact")
	var dig_steps := steps
	_check(world.queue_stair_removal(UPPER), "Explicit removal designation accepted")
	var removal_id: int = world.task_queue.get_active_tasks_at(LOWER)[0].id
	var removed := await _advance_until(world, func():
		return _block(world, LOWER) == World.BLOCK_ID_AIR and _block(world, UPPER) == World.BLOCK_ID_AIR)
	_check(removed and completed.has(removal_id), "Worker dismantles both halves through normal assignment")
	_check(_block(world, LOWER + Vector3i.DOWN) == World.BLOCK_ID_DIRT, "Dismantling preserves support terrain")
	print("Stair workflow: dig_steps=%d removal_steps=%d failures=%d" % [dig_steps, steps - dig_steps, failures])
	world.queue_free()
	await process_frame
	quit(1 if failures else 0)


func _block(world: World, pos: Vector3i) -> int:
	return world.get_block_no_generate(pos.x, pos.y, pos.z)


func _advance_until(world: World, condition: Callable) -> bool:
	var deadline := Time.get_ticks_msec() + 15000
	for step in 1800:
		world.update_world(1.0 / 60.0)
		steps += 1
		if condition.call():
			return true
		if Time.get_ticks_msec() >= deadline:
			break
		await process_frame
	print("Workflow timeout: workers=%s tasks=%s" % [world.workers.map(func(w): return [w.position, w.state, w.current_task_id]),
		world.task_queue.tasks.map(func(t): return [t.pos, t.status, t.block_reason])])
	return false
