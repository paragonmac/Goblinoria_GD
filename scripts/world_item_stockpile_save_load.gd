extends RefCounted
class_name WorldItemStockpileSaveLoad

const ITEM_STOCKPILE_FILE_NAME := "items_stockpiles.dat"
const ITEM_STOCKPILE_MAGIC := 0x49544D53


func save_items_and_stockpiles(world: World, world_dir: String) -> bool:
	if world == null:
		return false
	var path := world_dir.path_join(ITEM_STOCKPILE_FILE_NAME)
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		push_warning("Item/stockpile save failed: %s" % path)
		return false
	var items: Array = world.item_store.as_save_array()
	for item: Dictionary in items:
		item["reserved_by_task_id"] = -1
		item["is_carried"] = false
		for worker in world.workers:
			if worker is Worker and worker.carried_source_item_id == int(item.get("id", -1)):
				item["pos"] = worker.get_block_coord()
				item["stored_stockpile_id"] = -1
				break
	file.store_32(ITEM_STOCKPILE_MAGIC)
	file.store_var({
		"items": items,
		"stockpiles": world.stockpile_store.as_save_array(),
	})
	file.flush()
	return true


func load_items_and_stockpiles(world: World, world_dir: String) -> bool:
	if world == null:
		return false
	var snapshot := read_snapshot(world_dir)
	if not bool(snapshot.get("ok", false)):
		return false
	apply_snapshot(world, snapshot)
	return true


func read_snapshot(world_dir: String) -> Dictionary:
	var path := world_dir.path_join(ITEM_STOCKPILE_FILE_NAME)
	if not FileAccess.file_exists(path):
		return {"ok": true, "items": [], "stockpiles": []}
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return {"ok": false}
	var magic: int = file.get_32()
	if magic != ITEM_STOCKPILE_MAGIC:
		push_warning("Item/stockpile load failed: bad magic")
		return {"ok": false}
	var data = file.get_var()
	if typeof(data) != TYPE_DICTIONARY:
		return {"ok": false}
	var items_value: Variant = data.get("items", [])
	var stockpiles_value: Variant = data.get("stockpiles", [])
	if typeof(items_value) != TYPE_ARRAY or typeof(stockpiles_value) != TYPE_ARRAY:
		return {"ok": false}
	var items: Array = items_value
	var stockpiles: Array = stockpiles_value
	for item in items:
		if typeof(item) != TYPE_DICTIONARY:
			return {"ok": false}
	for stockpile in stockpiles:
		if typeof(stockpile) != TYPE_DICTIONARY:
			return {"ok": false}
	return {
		"ok": true,
		"items": items.duplicate(true),
		"stockpiles": stockpiles.duplicate(true),
	}


func apply_snapshot(world: World, snapshot: Dictionary) -> void:
	if world == null or not bool(snapshot.get("ok", false)):
		return
	world.clear_items_and_stockpiles()
	for stockpile: Dictionary in snapshot.get("stockpiles", []):
		world.stockpile_store.restore_stockpile(stockpile)
	for item: Dictionary in snapshot.get("items", []):
		world.item_store.restore_stack(item)
	world.item_store.normalize_stored_cells(world.stockpile_store)
	world.refresh_inventory_from_stockpiles()
