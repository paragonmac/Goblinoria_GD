extends SceneTree

const TEST_PATH := "user://transaction_contract/world.save"


func _init() -> void:
	var world := World.new()
	root.add_child(world)
	_run.call_deferred(world)


func _run(world: World) -> void:
	await process_frame
	world.world_seed = 111
	world.top_render_y = 10
	world.item_store.add_stack(World.BLOCK_ID_DIRT, 1, Vector3i(0, 1, 0))
	var save_ok := world.save_world(TEST_PATH)
	var item_path := TEST_PATH.get_basename().path_join(WorldItemStockpileSaveLoad.ITEM_STOCKPILE_FILE_NAME)
	var file := FileAccess.open(item_path, FileAccess.WRITE)
	if file != null:
		file.store_32(0)
		file.flush()

	world.world_seed = 222
	world.top_render_y = 20
	var live_item_id := world.item_store.add_stack(World.BLOCK_ID_GRANITE, 3, Vector3i(1, 1, 0))
	var load_ok := world.load_world(TEST_PATH)
	var unchanged_ok: bool = not load_ok \
		and world.world_seed == 222 \
		and world.top_render_y == 20 \
		and world.item_store.has_item(live_item_id)

	world.task_manager.shutdown()
	world.queue_free()
	if not save_ok:
		push_error("Transaction contract could not create its baseline save")
		quit(1)
		return
	if not unchanged_ok:
		push_error("Failed world load mutated live world state")
		quit(1)
		return
	print("Save/load transaction contract OK")
	quit(0)
