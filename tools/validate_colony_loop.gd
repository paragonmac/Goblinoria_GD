extends SceneTree
## Production-path dig, haul, stockpile, placement and restart integration contract.


class FixtureWorld extends World:
	func _ready() -> void:
		_init_ramp_lookup()
		block_registry.load_from_csv(BLOCK_DATA_PATH)
		block_drop_table.load_from_csv(BLOCK_DROPS_PATH)
		drop_rng.seed = 17
		sea_level = 0
		top_render_y = 0
		deepest_structure_y = 0
		spawn_coord = Vector3i.ZERO
		task_manager = TaskManager.new(self, task_queue)
		save_load = WorldSaveLoad.new(self)

	func ensure_chunk_generated(coord: Vector3i) -> ChunkData:
		var chunk := ensure_chunk(coord)
		if chunk.generated:
			return chunk
		if save_load != null and save_load.load_chunk_into(coord, chunk):
			return chunk
		chunk.generated = true
		return chunk

	func find_surface_y(_x: int, _z: int) -> int:
		return 0


const FLOOR_Y := 0
const DIG_POS := Vector3i(2, 1, 0)
const STOCKPILE_POS := Vector3i(4, 1, 0)
const PLACE_POS := Vector3i(2, 1, 0)
const SECOND_DIG_POS := Vector3i(7, 1, 0)
const MID_HAUL_DIG_POS := Vector3i(9, 1, -10)
const LOOP_MATERIAL := World.BLOCK_ID_GRANITE

var failures: Array[String] = []
var steps := 0


func _init() -> void:
	_run.call_deferred()


func _check(value: bool, message: String) -> void:
	if not value:
		failures.append(message)
		push_error(message)


func _run() -> void:
	var world := FixtureWorld.new()
	root.add_child(world)
	_build_fixture_terrain(world)
	var worker := Worker.new()
	worker.worker_id = 1
	worker.use_animated_model = false
	worker.position = Vector3(0, 1, 0)
	worker.work_priorities = {"mining": 1, "hauling": 1, "building": 1}
	world.add_child(worker)
	world.workers.append(worker)
	var stockpile_id := world.create_stockpile([STOCKPILE_POS])
	world.stockpile_store.rename_stockpile(stockpile_id, "Loop Granite")
	world.stockpile_store.set_category_allowed(stockpile_id, StockpileStore.CATEGORY_STONE, false)
	world.stockpile_store.set_material_override(stockpile_id, LOOP_MATERIAL, true)

	var initial_material := _terrain_count(world, LOOP_MATERIAL) \
		+ _item_count(world, LOOP_MATERIAL)
	_check(initial_material == 627, "fixture begins with two extra granite blocks above its 625-block floor")
	_check(world.queue_task_request(TaskQueue.TaskType.DIG, DIG_POS, 0), "dig designation accepted")
	var dig_task_id := _task_id_at(world, DIG_POS, TaskQueue.TaskType.DIG)
	var dug := await _advance_until(world, func():
		return _block(world, DIG_POS) == World.BLOCK_ID_AIR \
			and _item_count(world, LOOP_MATERIAL) == 1
	)
	_check(dug, "worker mines the designated block through World.update_world")
	var dropped := _loose_items(world)
	var mined_drop_count := 0
	var mined_drop_id := -1
	for item: Dictionary in dropped:
		if int(item.get("material_id", -1)) == LOOP_MATERIAL:
			mined_drop_count += int(item.get("count", 0))
			mined_drop_id = int(item.get("id", -1))
	_check(mined_drop_count == 1 and mined_drop_id >= 0 and dropped.size() == 1,
		"dig creates one physical granite drop")
	_check(world.get_inventory_count(LOOP_MATERIAL) == 0, "loose mined granite is not usable inventory")
	_check(_terrain_count(world, LOOP_MATERIAL) + _item_count(world, LOOP_MATERIAL) == initial_material,
		"granite is conserved between terrain and physical items after mining")
	_check(_task_was_removed(world, dig_task_id), "dig task completed through worker execution")

	var hauled := await _advance_until(world, func():
		return world.get_inventory_count(LOOP_MATERIAL) == 1 \
			and _loose_item_count(world) == 0 \
			and _active_task_count(world, TaskQueue.TaskType.HAUL) == 0
	)
	_check(hauled, "worker picks up loose drop and deposits it in an accepting stockpile")
	_check(_stored_count(world, LOOP_MATERIAL) == 1, "stockpile holds the hauled granite drop")
	_check(_terrain_count(world, LOOP_MATERIAL) + _item_count(world, LOOP_MATERIAL) == initial_material,
		"granite remains conserved after hauling")
	_check(world.queue_task_request(TaskQueue.TaskType.DIG, SECOND_DIG_POS, 0),
		"second dig designation accepted")
	var second_dig_task_id := _task_id_at(world, SECOND_DIG_POS, TaskQueue.TaskType.DIG)
	var dug_again := await _advance_until(world, func():
		return _block(world, SECOND_DIG_POS) == World.BLOCK_ID_AIR \
			and _item_count(world, LOOP_MATERIAL) == 2
	)
	_check(dug_again and _task_was_removed(world, second_dig_task_id),
		"worker mines the second block and creates its physical drop")
	var hauled_again := await _advance_until(world, func():
		return world.get_inventory_count(LOOP_MATERIAL) == 2 \
			and _loose_item_count(world) == 0 \
			and _active_task_count(world, TaskQueue.TaskType.HAUL) == 0
	)
	_check(hauled_again and _stored_count(world, LOOP_MATERIAL) == 2,
		"worker hauls the second drop into stockpile storage")

	_check(world.queue_task_request(TaskQueue.TaskType.PLACE, PLACE_POS, LOOP_MATERIAL),
		"basic PLACE designation accepted")
	var place_task_id := _task_id_at(world, PLACE_POS, TaskQueue.TaskType.PLACE)
	var placed := await _advance_until(world, func():
		return _block(world, PLACE_POS) == LOOP_MATERIAL \
			and world.get_inventory_count(LOOP_MATERIAL) == 1
	)
	_check(placed, "worker places a block and consumes stored stockpile material")
	_check(_task_was_removed(world, place_task_id), "PLACE task completed through worker execution")
	_check(_terrain_count(world, LOOP_MATERIAL) + _item_count(world, LOOP_MATERIAL) == initial_material,
		"granite remains conserved after placement consumes the stockpile item")
	var settled := await _advance_until(world, func():
		return _loose_item_count(world) == 0 and _active_task_count(world, TaskQueue.TaskType.HAUL) == 0
	)
	_check(settled, "first colony loop settles before save")

	var save_root := "user://colony_loop_%d_%d" % [OS.get_process_id(), Time.get_ticks_usec()]
	var settled_save := save_root.path_join("settled.save")
	_check(world.save_world(settled_save), "settled world saves to the isolated runner user-data directory")
	var settled_stockpile_count: int = world.stockpile_store.stockpiles.size()
	var settled_stockpile: Dictionary = world.stockpile_store.stockpiles[stockpile_id].duplicate(true)
	_check(world.load_world(settled_save), "settled world reloads")
	_hydrate_fixture_chunks(world)
	_check(_block(world, PLACE_POS) == LOOP_MATERIAL, "settled reload preserves placed terrain")
	_check(world.stockpile_store.stockpiles.size() == settled_stockpile_count,
		"settled reload preserves stockpile records")
	var restored_stockpile: Dictionary = world.stockpile_store.stockpiles.get(stockpile_id, {})
	_check(restored_stockpile == settled_stockpile,
		"settled reload preserves stockpile name, category filter, and material override")
	_check(_stored_count(world, LOOP_MATERIAL) == 1 and world.get_inventory_count(LOOP_MATERIAL) == 1,
		"settled reload preserves remaining stockpiled material")
	var restored_worker: Worker = _worker_with_id(world, 1)
	_check(restored_worker != null and restored_worker.get_work_configuration() == {"hauling": 1, "mining": 1, "building": 1},
		"settled reload preserves worker work priorities")
	_check(world.task_queue.active_count() == 0, "settled reload begins with no unfinished tasks")

	# Add a third mined block and wait until the ordinary HAUL worker is carrying it.
	world.set_block(MID_HAUL_DIG_POS.x, MID_HAUL_DIG_POS.y, MID_HAUL_DIG_POS.z, World.BLOCK_ID_GRANITE)
	_check(world.queue_task_request(TaskQueue.TaskType.DIG, MID_HAUL_DIG_POS, 0),
		"mid-haul dig designation accepted")
	var midhaul_dig_id := _task_id_at(world, MID_HAUL_DIG_POS, TaskQueue.TaskType.DIG)
	var carrying := await _advance_until(world, func():
		return _worker_carrying_material(world, World.BLOCK_ID_GRANITE)
	)
	_check(carrying, "worker picks up third mined item through ordinary HAUL execution")
	_check(_task_was_removed(world, midhaul_dig_id), "third dig completed before mid-haul save")
	var carried_worker: Worker = _carrying_worker(world, World.BLOCK_ID_GRANITE)
	var carried_item_id: int = carried_worker.carried_source_item_id if carried_worker != null else -1
	var expected_carried_pos: Vector3i = carried_worker.get_block_coord() if carried_worker != null else Vector3i.ZERO
	_check(carried_item_id >= 0, "mid-haul worker owns a physical carried item")
	_check(world.save_world(save_root.path_join("midhaul.save")), "mid-haul state saves")
	var midhaul_reload_ok := world.load_world(save_root.path_join("midhaul.save"))
	_check(midhaul_reload_ok, "mid-haul state reloads")
	_hydrate_fixture_chunks(world)
	var restored_item := world.item_store.get_item(carried_item_id)
	_check(not restored_item.is_empty() \
		and int(restored_item.get("material_id", -1)) == World.BLOCK_ID_GRANITE \
		and int(restored_item.get("count", 0)) == 1 \
		and restored_item.get("pos", Vector3i.ZERO) == expected_carried_pos \
		and not bool(restored_item.get("is_carried", false)) \
		and int(restored_item.get("reserved_by_task_id", -1)) == -1 \
		and int(restored_item.get("stored_stockpile_id", -1)) == -1,
		"mid-haul reload restores the carried item as a loose, unreserved item")
	_check(world.task_queue.active_count() == 0, "mid-haul reload resets unfinished task assignments")
	world.update_task_queue()
	var haul_rebuilt = _haul_task_for_item(world, carried_item_id)
	_check(haul_rebuilt != null and haul_rebuilt.status == TaskQueue.TaskStatus.PENDING,
		"normal task-queue update rebuilds a pending HAUL task after reload")
	_check(_item_count(world, World.BLOCK_ID_GRANITE) == 2 \
		and _stored_count(world, World.BLOCK_ID_GRANITE) == 1,
		"granite remains conserved as one stored stack and one loose stack through mid-haul reload")
	var recovered_source: Vector3i = restored_item.get("pos", Vector3i.ZERO)
	var cancelled: Array = world.cancel_pending_task_requests_at(recovered_source)
	var recovered_task_id := int(haul_rebuilt.id) if haul_rebuilt != null else -1
	_check(cancelled.size() == 1 and recovered_task_id >= 0 and int(cancelled[0].id) == recovered_task_id,
		"pending recovered haul can be cancelled at its physical item position")
	var released_item_before_rebuild := world.item_store.get_item(carried_item_id)
	_check(int(released_item_before_rebuild.get("reserved_by_task_id", -1)) == -1 \
		and world.task_queue.get_task(recovered_task_id) == null,
		"cancelling the pending haul immediately removes its task and releases the item")
	world.update_task_queue()
	var replacement = _haul_task_for_item(world, carried_item_id)
	var released_item := world.item_store.get_item(carried_item_id)
	_check(replacement != null and replacement.id != recovered_task_id \
		and int(released_item.get("reserved_by_task_id", -1)) == replacement.id,
		"cancelled pending haul releases and re-reserves the same loose item")
	var resumed_delivery := await _advance_until(world, func():
		return _stored_count(world, World.BLOCK_ID_GRANITE) == 2 \
			and world.get_inventory_count(World.BLOCK_ID_GRANITE) == 2 \
			and _active_task_count(world, TaskQueue.TaskType.HAUL) == 0
	)
	_check(resumed_delivery, "recovered haul completes delivery after cancel and requeue")

	print("Colony loop: steps=%d failures=%d" % [steps, failures.size()])
	world.task_manager.shutdown()
	world.queue_free()
	await process_frame
	quit(1 if not failures.is_empty() else 0)


func _build_fixture_terrain(world: FixtureWorld) -> void:
	for x in range(-12, 13):
		for z in range(-12, 13):
			world.set_block_raw(x, FLOOR_Y, z, World.BLOCK_ID_GRANITE, true)
	for chunk_x in range(-2, 3):
		for chunk_z in range(-2, 3):
			world.ensure_chunk(Vector3i(chunk_x, 0, chunk_z)).generated = true
	world.set_block_raw(DIG_POS.x, DIG_POS.y, DIG_POS.z, LOOP_MATERIAL, true)
	world.set_block_raw(SECOND_DIG_POS.x, SECOND_DIG_POS.y, SECOND_DIG_POS.z, LOOP_MATERIAL, true)


func _hydrate_fixture_chunks(world: FixtureWorld) -> void:
	for chunk_x in range(-2, 3):
		for chunk_z in range(-2, 3):
			world.ensure_chunk_generated(Vector3i(chunk_x, 0, chunk_z))


func _advance_until(world: FixtureWorld, condition: Callable, max_steps: int = 2400) -> bool:
	var deadline := Time.get_ticks_msec() + 30000
	for _step in max_steps:
		world.update_world(1.0 / 60.0)
		steps += 1
		if condition.call():
			return true
		if Time.get_ticks_msec() >= deadline:
			break
		await process_frame
	var path_debug := {}
	if not world.workers.is_empty() and not world.task_queue.tasks.is_empty():
		var first_task = world.task_queue.tasks[0]
		var first_worker: Worker = world.workers[0]
		path_debug = {
			"item": world.item_store.get_item(int(first_task.data.get("item_id", -1))),
			"worker_priority": first_worker.get_work_configuration(),
			"worker_block": world.get_block_no_generate(first_worker.get_block_coord().x, first_worker.get_block_coord().y, first_worker.get_block_coord().z),
			"task_block": world.get_block_no_generate(first_task.pos.x, first_task.pos.y, first_task.pos.z),
			"walkable": world.pathfinder.is_walkable(world, first_task.pos.x, first_task.pos.y, first_task.pos.z),
			"direct_path": world.pathfinder.find_path(world, first_worker.get_block_coord(), first_task.pos, false, false),
		}
	push_error("Colony loop timed out: workers=%s tasks=%s items=%s stockpiles=%s path_debug=%s" % [
		world.workers.map(func(w): return [w.worker_id, w.position, w.state, w.current_task_id, w.carried_source_item_id]),
		world.task_queue.tasks.map(func(t): return [t.type, t.pos, t.status, t.block_reason, t.data]),
		world.item_store.items,
		world.stockpile_store.stockpiles,
		path_debug,
	])
	return false


func _block(world: World, pos: Vector3i) -> int:
	return world.get_block_no_generate(pos.x, pos.y, pos.z)


func _terrain_count(world: World, material_id: int) -> int:
	var count := 0
	for x in range(-12, 13):
		for y in range(0, 3):
			for z in range(-12, 13):
				if _block(world, Vector3i(x, y, z)) == material_id:
					count += 1
	return count


func _item_count(world: World, material_id: int) -> int:
	var count := 0
	for item: Dictionary in world.item_store.items.values():
		if int(item.get("material_id", -1)) == material_id:
			count += int(item.get("count", 0))
	return count


func _stored_count(world: World, material_id: int) -> int:
	var count := 0
	for item: Dictionary in world.item_store.items.values():
		if int(item.get("material_id", -1)) == material_id \
				and int(item.get("stored_stockpile_id", -1)) >= 0:
			count += int(item.get("count", 0))
	return count


func _loose_items(world: World) -> Array:
	var items: Array = []
	for item: Dictionary in world.item_store.items.values():
		if int(item.get("stored_stockpile_id", -1)) < 0:
			items.append(item)
	return items


func _loose_item_count(world: World) -> int:
	var count := 0
	for item: Dictionary in _loose_items(world):
		if not bool(item.get("is_carried", false)):
			count += 1
	return count


func _active_task_count(world: World, task_type: int) -> int:
	var count := 0
	for task in world.task_queue.tasks:
		if task.type == task_type:
			count += 1
	return count


func _task_id_at(world: World, pos: Vector3i, task_type: int) -> int:
	for task in world.task_queue.tasks:
		if task.pos == pos and task.type == task_type:
			return task.id
	return -1


func _task_was_removed(world: World, task_id: int) -> bool:
	return task_id >= 0 and world.task_queue.get_task(task_id) == null


func _worker_carrying_material(world: World, material_id: int) -> bool:
	return _carrying_worker(world, material_id) != null


func _carrying_worker(world: World, material_id: int):
	for worker: Worker in world.workers:
		if worker.carried_material_id == material_id and worker.carried_count > 0:
			return worker
	return null


func _worker_with_id(world: World, worker_id: int):
	for worker: Worker in world.workers:
		if worker.worker_id == worker_id:
			return worker
	return null


func _haul_task_for_item(world: World, item_id: int):
	for task in world.task_queue.tasks:
		if task.type == TaskQueue.TaskType.HAUL and int(task.data.get("item_id", -1)) == item_id:
			return task
	return null
