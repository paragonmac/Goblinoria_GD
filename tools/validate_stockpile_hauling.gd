extends SceneTree


func _init() -> void:
	var world := World.new()
	world._init_ramp_lookup()
	world.block_registry.load_from_csv(World.BLOCK_DATA_PATH)
	world.block_drop_table.load_from_csv(World.BLOCK_DROPS_PATH)
	world.task_manager = TaskManager.new(world, world.task_queue)

	var dirt_drops := world.block_drop_table.resolve_drops(World.BLOCK_ID_DIRT, _fixed_rng(), 0)
	var deterministic_drop_ok := _has_drop(dirt_drops, World.BLOCK_ID_DIRT)

	var drop_pos := Vector3i(0, 1, 0)
	var spawned := world.spawn_mining_drops(World.BLOCK_ID_DIRT, drop_pos)
	var loose_not_inventory_ok: bool = not spawned.is_empty() \
		and world.get_inventory_count(World.BLOCK_ID_DIRT) == 0

	var stockpile_id := world.create_stockpile([
		Vector3i(1, 1, 0),
		Vector3i(2, 1, 0),
	])
	world.task_manager.rebuild_haul_tasks()
	var haul_task = _first_task_of_type(world.task_queue, TaskQueue.TaskType.HAUL)
	var haul_reserved_ok: bool = haul_task != null \
		and int(haul_task.data.get("item_id", -1)) >= 0 \
		and int(world.item_store.get_item(int(haul_task.data.get("item_id", -1))).get("reserved_by_task_id", -1)) == haul_task.id

	var item_id := int(haul_task.data.get("item_id", -1)) if haul_task != null else -1
	var deposit_ok := world.deposit_item_to_stockpile(item_id, stockpile_id, Vector3i(1, 1, 0)) \
		and world.get_inventory_count(World.BLOCK_ID_DIRT) > 0

	var bulk_item_id := world.item_store.add_stack(World.BLOCK_ID_DIRT, 20, Vector3i(0, 1, 1))
	var bulk_deposit_ok := world.deposit_item_to_stockpile(
		bulk_item_id,
		stockpile_id,
		Vector3i(2, 1, 0)
	)
	var bulk_stored := world.item_store.stored_item_at(Vector3i(2, 1, 0))
	var bulk_remainder := world.item_store.get_item(bulk_item_id)
	var stack_capacity_ok: bool = bulk_deposit_ok \
		and int(bulk_stored.get("count", 0)) == StockpileStore.BASE_CELL_CAPACITY \
		and int(bulk_remainder.get("count", 0)) == 4 \
		and int(bulk_remainder.get("stored_stockpile_id", -1)) < 0
	var granite_item_id := world.item_store.add_stack(World.BLOCK_ID_GRANITE, 1, Vector3i(0, 1, 2))
	var mixed_material_rejected: bool = not world.deposit_item_to_stockpile(
		granite_item_id,
		stockpile_id,
		Vector3i(2, 1, 0)
	)

	world.stockpile_store.set_category_allowed(stockpile_id, StockpileStore.CATEGORY_SOIL, false)
	world.stockpile_store.set_material_override(stockpile_id, World.BLOCK_ID_DIRT, true)
	var override_ok: bool = world.stockpile_store.accepts_material(stockpile_id, World.BLOCK_ID_DIRT)

	world.task_manager.shutdown()
	world.free()

	if not deterministic_drop_ok:
		push_error("Dirt deterministic drop missing")
		quit(1)
		return
	if not loose_not_inventory_ok:
		push_error("Loose mined item counted as stockpiled inventory")
		quit(1)
		return
	if not haul_reserved_ok:
		push_error("Loose item did not create a reserved haul task")
		quit(1)
		return
	if not deposit_ok:
		push_error("Deposited item did not become stockpiled inventory")
		quit(1)
		return
	if not stack_capacity_ok:
		push_error("Stockpile cell did not enforce the 16-item stack capacity")
		quit(1)
		return
	if not mixed_material_rejected:
		push_error("Stockpile cell accepted a second material type")
		quit(1)
		return
	if not override_ok:
		push_error("Exact material override did not beat stockpile category rejection")
		quit(1)
		return

	print("Stockpile hauling contract OK")
	quit(0)


func _fixed_rng() -> RandomNumberGenerator:
	var rng := RandomNumberGenerator.new()
	rng.seed = 1
	return rng


func _has_drop(drops: Array, material_id: int) -> bool:
	for drop: Dictionary in drops:
		if int(drop.get("material_id", -1)) == material_id and int(drop.get("count", 0)) > 0:
			return true
	return false


func _first_task_of_type(task_queue: TaskQueue, task_type: int):
	for task in task_queue.tasks:
		if task.type == task_type:
			return task
	return null
