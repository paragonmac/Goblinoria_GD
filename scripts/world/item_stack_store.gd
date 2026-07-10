extends RefCounted
class_name ItemStackStore

signal haul_state_changed(reason: String)
signal visual_state_changed(reason: String)

var items: Dictionary = {}
var next_id := 1


func clear() -> void:
	var had_items := not items.is_empty()
	items.clear()
	next_id = 1
	if had_items:
		haul_state_changed.emit("items_cleared")
		visual_state_changed.emit("items_cleared")


func add_stack(material_id: int, count: int, pos: Vector3i, stored_stockpile_id: int = -1) -> int:
	if material_id <= 0 or count <= 0:
		return -1
	var item_id := next_id
	next_id += 1
	items[item_id] = {
		"id": item_id,
		"material_id": material_id,
		"count": count,
		"pos": pos,
		"reserved_by_task_id": -1,
		"stored_stockpile_id": stored_stockpile_id,
		"is_carried": false,
	}
	haul_state_changed.emit("stack_added")
	visual_state_changed.emit("stack_added")
	return item_id


func restore_stack(item: Dictionary) -> void:
	var item_id := int(item.get("id", -1))
	if item_id <= 0:
		return
	items[item_id] = {
		"id": item_id,
		"material_id": int(item.get("material_id", 0)),
		"count": int(item.get("count", 0)),
		"pos": item.get("pos", Vector3i.ZERO),
		"reserved_by_task_id": int(item.get("reserved_by_task_id", -1)),
		"stored_stockpile_id": int(item.get("stored_stockpile_id", -1)),
		"is_carried": false,
	}
	next_id = maxi(next_id, item_id + 1)
	visual_state_changed.emit("stack_restored")


func get_item(item_id: int) -> Dictionary:
	return items.get(item_id, {})


func has_item(item_id: int) -> bool:
	return items.has(item_id)


func remove_item(item_id: int) -> Dictionary:
	var item: Dictionary = items.get(item_id, {})
	if not item.is_empty():
		items.erase(item_id)
		haul_state_changed.emit("stack_removed")
		visual_state_changed.emit("stack_removed")
	return item


func reserve_item(item_id: int, task_id: int) -> bool:
	if not items.has(item_id):
		return false
	var item: Dictionary = items[item_id]
	if int(item.get("reserved_by_task_id", -1)) >= 0:
		return false
	item["reserved_by_task_id"] = task_id
	items[item_id] = item
	return true


func release_reservation(item_id: int, task_id: int = -1) -> void:
	if not items.has(item_id):
		return
	var item: Dictionary = items[item_id]
	if task_id >= 0 and int(item.get("reserved_by_task_id", -1)) != task_id:
		return
	item["reserved_by_task_id"] = -1
	item["is_carried"] = false
	items[item_id] = item
	haul_state_changed.emit("reservation_released")
	visual_state_changed.emit("reservation_released")


func mark_carried(item_id: int) -> bool:
	if not items.has(item_id):
		return false
	var item: Dictionary = items[item_id]
	if int(item.get("reserved_by_task_id", -1)) < 0:
		return false
	item["is_carried"] = true
	items[item_id] = item
	visual_state_changed.emit("stack_carried")
	return true


func mark_stored(item_id: int, stockpile_id: int, pos: Vector3i) -> bool:
	if not items.has(item_id):
		return false
	var item: Dictionary = items[item_id]
	item["pos"] = pos
	item["stored_stockpile_id"] = stockpile_id
	item["reserved_by_task_id"] = -1
	item["is_carried"] = false
	items[item_id] = item
	haul_state_changed.emit("stack_stored")
	visual_state_changed.emit("stack_stored")
	return true


func mark_loose(item_id: int, pos: Vector3i) -> bool:
	if not items.has(item_id):
		return false
	var item: Dictionary = items[item_id]
	item["pos"] = pos
	item["stored_stockpile_id"] = -1
	item["reserved_by_task_id"] = -1
	item["is_carried"] = false
	items[item_id] = item
	haul_state_changed.emit("stack_loose")
	visual_state_changed.emit("stack_loose")
	return true


func loose_items() -> Array:
	var result: Array = []
	for item in items.values():
		if int(item.get("stored_stockpile_id", -1)) < 0:
			result.append(item)
	return result


func stored_items() -> Array:
	var result: Array = []
	for item in items.values():
		if int(item.get("stored_stockpile_id", -1)) >= 0:
			result.append(item)
	return result


func stored_item_at(pos: Vector3i) -> Dictionary:
	for item: Dictionary in items.values():
		if int(item.get("stored_stockpile_id", -1)) < 0:
			continue
		if item.get("pos", Vector3i.ZERO) == pos:
			return item
	return {}


func stored_items_at(pos: Vector3i) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for item: Dictionary in items.values():
		if int(item.get("stored_stockpile_id", -1)) < 0:
			continue
		if item.get("pos", Vector3i.ZERO) == pos:
			result.append(item)
	return result


func deposit_into_cell(item_id: int, stockpile_id: int, pos: Vector3i, capacity: int) -> Dictionary:
	if not items.has(item_id) or capacity <= 0:
		return {}
	var source: Dictionary = items[item_id]
	if int(source.get("stored_stockpile_id", -1)) >= 0:
		return {}
	var material_id := int(source.get("material_id", 0))
	var source_count := int(source.get("count", 0))
	if material_id <= 0 or source_count <= 0:
		return {}

	var stored := stored_item_at(pos)
	if not stored.is_empty() and int(stored.get("material_id", 0)) != material_id:
		return {}
	var stored_count := int(stored.get("count", 0))
	var deposited := mini(source_count, capacity - stored_count)
	if deposited <= 0:
		return {}

	if stored.is_empty() and deposited == source_count:
		mark_stored(item_id, stockpile_id, pos)
		return {"deposited": deposited, "remaining": 0, "stored_item_id": item_id}

	var stored_item_id := int(stored.get("id", -1))
	if stored.is_empty():
		stored_item_id = add_stack(material_id, deposited, pos, stockpile_id)
	else:
		stored["count"] = stored_count + deposited
		items[stored_item_id] = stored

	var remaining := source_count - deposited
	if remaining <= 0:
		items.erase(item_id)
	else:
		source["count"] = remaining
		source["pos"] = pos
		source["reserved_by_task_id"] = -1
		source["stored_stockpile_id"] = -1
		source["is_carried"] = false
		items[item_id] = source
	haul_state_changed.emit("cell_deposit")
	visual_state_changed.emit("cell_deposit")
	return {
		"deposited": deposited,
		"remaining": remaining,
		"stored_item_id": stored_item_id,
	}


func normalize_stored_cells(stockpile_store: StockpileStore) -> void:
	var occupied: Dictionary = {}
	var item_ids: Array = items.keys()
	item_ids.sort()
	for item_id in item_ids:
		if not items.has(item_id):
			continue
		var item: Dictionary = items[item_id]
		var stockpile_id := int(item.get("stored_stockpile_id", -1))
		if stockpile_id < 0:
			continue
		var pos: Vector3i = item.get("pos", Vector3i.ZERO)
		var material_id := int(item.get("material_id", 0))
		if stockpile_store.stockpile_at(pos) != stockpile_id \
				or not stockpile_store.accepts_material(stockpile_id, material_id):
			mark_loose(int(item_id), pos)
			continue
		var capacity := stockpile_store.cell_capacity(pos)
		if not occupied.has(pos):
			var kept := mini(int(item.get("count", 0)), capacity)
			var overflow := int(item.get("count", 0)) - kept
			item["count"] = kept
			items[item_id] = item
			occupied[pos] = item_id
			if overflow > 0:
				add_stack(material_id, overflow, pos)
			continue

		var stored_item_id: int = int(occupied[pos])
		var stored: Dictionary = items[stored_item_id]
		if int(stored.get("material_id", 0)) != material_id:
			mark_loose(int(item_id), pos)
			continue
		var available := capacity - int(stored.get("count", 0))
		var moved := mini(int(item.get("count", 0)), available)
		stored["count"] = int(stored.get("count", 0)) + moved
		items[stored_item_id] = stored
		var remaining := int(item.get("count", 0)) - moved
		if remaining <= 0:
			items.erase(item_id)
		else:
			item["count"] = remaining
			items[item_id] = item
			mark_loose(int(item_id), pos)
	haul_state_changed.emit("storage_normalized")
	visual_state_changed.emit("storage_normalized")


func aggregate_stored_counts() -> Dictionary:
	var counts: Dictionary = {}
	for item: Dictionary in stored_items():
		var material_id := int(item.get("material_id", 0))
		var count := int(item.get("count", 0))
		if material_id <= 0 or count <= 0:
			continue
		counts[material_id] = int(counts.get(material_id, 0)) + count
	return counts


func remove_stored_material(material_id: int, count: int) -> bool:
	if material_id <= 0 or count <= 0:
		return false
	var available := int(aggregate_stored_counts().get(material_id, 0))
	if available < count:
		return false
	var remaining := count
	for item_id in items.keys():
		if remaining <= 0:
			break
		var item: Dictionary = items[item_id]
		if int(item.get("stored_stockpile_id", -1)) < 0:
			continue
		if int(item.get("material_id", 0)) != material_id:
			continue
		var item_count := int(item.get("count", 0))
		var consumed := mini(item_count, remaining)
		item_count -= consumed
		remaining -= consumed
		if item_count <= 0:
			items.erase(item_id)
		else:
			item["count"] = item_count
			items[item_id] = item
	haul_state_changed.emit("stored_material_removed")
	visual_state_changed.emit("stored_material_removed")
	return true


func as_save_array() -> Array:
	var saved: Array = []
	for item: Dictionary in items.values():
		saved.append(item.duplicate(true))
	return saved
