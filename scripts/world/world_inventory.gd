extends RefCounted
class_name WorldInventory
## Owns inventory item counts while preserving Dictionary-backed save/HUD access.

var items: Dictionary = {}


func add(block_id: int, count: int = 1) -> void:
	if block_id <= 0 or count <= 0:
		return
	items[block_id] = int(items.get(block_id, 0)) + count


func remove(block_id: int, count: int = 1) -> bool:
	if count <= 0:
		return false
	var current: int = int(items.get(block_id, 0))
	if current < count:
		return false
	var remaining: int = current - count
	if remaining <= 0:
		items.erase(block_id)
	else:
		items[block_id] = remaining
	return true


func count(block_id: int) -> int:
	return int(items.get(block_id, 0))


func clear() -> void:
	items.clear()
