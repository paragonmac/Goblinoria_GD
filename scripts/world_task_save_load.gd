extends RefCounted
class_name WorldTaskSaveLoad
## Persists player designations (dig, place, stairs, stair removal) so queued
## work survives save/load. Hauling is derived from items and stockpiles and is
## rebuilt after load, so it is not saved. Jobs in progress reload as pending;
## sites are revalidated by the normal completion checks, never here, because
## terrain chunks are not resident while a save is being read.

const WorldSaveTransactionScript = preload("res://scripts/world_save_transaction.gd")

const TASK_FILE_NAME := "tasks.dat"
const TASK_MAGIC := 0x5441534B
const MAX_TASKS := 65536
const SAVED_TYPES := [TaskQueue.TaskType.DIG, TaskQueue.TaskType.PLACE, TaskQueue.TaskType.STAIRS]
const DATA_KEYS := ["flight", "rotation", "up", "footprint", "materials", "remove_stairs"]


func save_tasks(world: World, world_dir: String) -> bool:
	if world == null or world.task_queue == null:
		return false
	var records: Array = []
	for task in world.task_queue.tasks:
		# Phase 6 adds torches.dat; V9 tasks.dat intentionally omits TORCH jobs.
		if task == null or task.status == TaskQueue.TaskStatus.COMPLETED or not SAVED_TYPES.has(task.type):
			continue
		var data := {}
		for key: String in DATA_KEYS:
			if task.data.has(key):
				data[key] = task.data[key]
		records.append({"type": task.type, "pos": task.pos, "material": task.material,
			"data": data, "expected_blocks": Array(task.expected_blocks)})
	var path := world_dir.path_join(TASK_FILE_NAME)
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		push_warning("Task save failed: %s" % path)
		return false
	var ok := file.store_32(TASK_MAGIC) and file.store_var({"tasks": records}, false)
	return WorldSaveTransactionScript.finish_write(file) and ok


func read_snapshot(world: World, world_dir: String) -> Dictionary:
	var path := world_dir.path_join(TASK_FILE_NAME)
	if not FileAccess.file_exists(path):
		return {"ok": true, "tasks": []}
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return {"ok": false}
	if file.get_32() != TASK_MAGIC:
		push_warning("Task load failed: bad magic")
		return {"ok": false}
	var value = file.get_var(false)
	if typeof(value) != TYPE_DICTIONARY or typeof(value.get("tasks")) != TYPE_ARRAY:
		return {"ok": false}
	var records: Array = value.tasks
	if records.size() > MAX_TASKS:
		return {"ok": false}
	for record in records:
		if not _valid_record(world, record):
			push_warning("Task load failed: invalid task record")
			return {"ok": false}
	return {"ok": true, "tasks": records.duplicate(true)}


## Call after the live task queue has been cleared for the loaded world.
func apply_snapshot(world: World, snapshot: Dictionary) -> int:
	if world == null or world.task_queue == null or not bool(snapshot.get("ok", false)):
		return 0
	var restored := 0
	for record: Dictionary in snapshot.get("tasks", []):
		var expected: Array[int] = []
		for block_id in record.expected_blocks:
			expected.append(int(block_id))
		# Restore the typed arrays live code compares against (stair footprints).
		var data: Dictionary = record.data.duplicate(true)
		if data.has("footprint"):
			var footprint: Array[Vector3i] = []
			for cell in data.footprint:
				footprint.append(cell)
			data["footprint"] = footprint
		if data.has("materials"):
			var materials: Array[int] = []
			for block_id in data.materials:
				materials.append(int(block_id))
			data["materials"] = materials
		if world.task_queue.add_task(record.pos, int(record.type), int(record.material), data, expected) >= 0:
			restored += 1
	return restored


func _valid_record(world: World, record: Variant) -> bool:
	if typeof(record) != TYPE_DICTIONARY:
		return false
	if not SAVED_TYPES.has(record.get("type")) or typeof(record.get("pos")) != TYPE_VECTOR3I:
		return false
	var pos: Vector3i = record.pos
	if world != null and not world.is_block_coord_valid(pos.x, pos.y, pos.z):
		return false
	if typeof(record.get("material")) != TYPE_INT or typeof(record.get("data")) != TYPE_DICTIONARY:
		return false
	var expected = record.get("expected_blocks")
	if typeof(expected) != TYPE_ARRAY:
		return false
	for block_id in expected:
		if typeof(block_id) != TYPE_INT or block_id < 0 or block_id > 255:
			return false
	var data: Dictionary = record.data
	for key in data:
		if not DATA_KEYS.has(key):
			return false
	var footprint = data.get("footprint", [])
	if typeof(footprint) != TYPE_ARRAY:
		return false
	for cell in footprint:
		if typeof(cell) != TYPE_VECTOR3I:
			return false
		if world != null and not world.is_block_coord_valid(cell.x, cell.y, cell.z):
			return false
	return true
