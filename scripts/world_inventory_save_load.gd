extends RefCounted
class_name WorldInventorySaveLoad

const INVENTORY_FILE_NAME := "inventory.dat"
const INVENTORY_MAGIC := 0x494E5654


func save_inventory(world: World, world_dir: String) -> bool:
	if world == null:
		return false
	var path := world_dir.path_join(INVENTORY_FILE_NAME)
	var inv: Dictionary = world.inventory
	if inv.is_empty():
		if FileAccess.file_exists(path):
			DirAccess.remove_absolute(path)
		return true
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		push_warning("Inventory save failed: %s" % path)
		return false
	file.store_32(INVENTORY_MAGIC)
	file.store_32(inv.size())
	for block_id in inv.keys():
		file.store_16(block_id)
		file.store_32(inv[block_id])
	file.flush()
	return true


func load_inventory(world: World, world_dir: String) -> bool:
	if world == null:
		return false
	world.clear_inventory()
	var path := world_dir.path_join(INVENTORY_FILE_NAME)
	if not FileAccess.file_exists(path):
		return true
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return false
	var magic: int = file.get_32()
	if magic != INVENTORY_MAGIC:
		push_warning("Inventory load failed: bad magic")
		return false
	var count: int = file.get_32()
	for _i in range(count):
		var block_id: int = file.get_16()
		var amount: int = file.get_32()
		if block_id > 0 and amount > 0:
			world.add_to_inventory(block_id, amount)
	return true