extends RefCounted
class_name WorldWorkerSaveLoad
## Persists role templates and work priorities; workers still respawn on load.

const WorldSaveTransactionScript = preload("res://scripts/world_save_transaction.gd")

const WORKER_FILE_NAME := "workers.dat"
const WORKER_MAGIC := 0x574F524B
const WorkerRolesScript = preload("res://scripts/worker_roles.gd")
const WorkPriorities = preload("res://scripts/worker_work_priorities.gd")


func save_workers(world: World, world_dir: String) -> bool:
	if world == null:
		return false
	var roles: Array = []
	for worker: Worker in world.workers:
		if worker == null:
			continue
		roles.append({
			"worker_id": worker.worker_id,
			"role_id": worker.role_id,
			"work_priorities": worker.work_priorities.duplicate(),
			"position": worker.position,
		})
	var path := world_dir.path_join(WORKER_FILE_NAME)
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		push_warning("Worker save failed: %s" % path)
		return false
	var ok := file.store_32(WORKER_MAGIC) and file.store_var({"roles": roles}, false)
	return WorldSaveTransactionScript.finish_write(file) and ok


func read_snapshot(world_dir: String) -> Dictionary:
	var path := world_dir.path_join(WORKER_FILE_NAME)
	if not FileAccess.file_exists(path):
		return {"ok": true, "roles": []}
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return {"ok": false}
	if file.get_32() != WORKER_MAGIC:
		push_warning("Worker load failed: bad magic")
		return {"ok": false}
	var data = file.get_var(false)
	if typeof(data) != TYPE_DICTIONARY:
		return {"ok": false}
	var roles_value: Variant = data.get("roles", [])
	if typeof(roles_value) != TYPE_ARRAY:
		return {"ok": false}
	if roles_value.size() > World.MAX_WORKERS:
		return {"ok": false}
	var seen_ids := {}
	for entry in roles_value:
		if typeof(entry) != TYPE_DICTIONARY:
			return {"ok": false}
		var worker_id = entry.get("worker_id", -1)
		if typeof(worker_id) != TYPE_INT or worker_id <= 0 or seen_ids.has(worker_id):
			return {"ok": false}
		seen_ids[worker_id] = true
		if not WorkerRolesScript.is_valid(int(entry.get("role_id", -1))):
			return {"ok": false}
		if not _valid_work_priorities(entry.get("work_priorities", {})):
			return {"ok": false}
		# Optional since V9; older saves respawn workers at the default spot.
		if entry.has("position"):
			var position = entry.position
			if typeof(position) != TYPE_VECTOR3 or not position.is_finite():
				return {"ok": false}
	return {"ok": true, "roles": roles_value.duplicate(true)}


func apply_snapshot(world: World, snapshot: Dictionary) -> void:
	if world == null or not bool(snapshot.get("ok", false)):
		return
	# V9 records (with positions) list the whole roster, which may differ from
	# the default four after debug add/remove. Older files only annotate the
	# default roster, so they never add or remove workers.
	var saved_ids: Array = []
	var full_roster := false
	for entry: Dictionary in snapshot.get("roles", []):
		saved_ids.append(int(entry.get("worker_id", -1)))
		full_roster = full_roster or entry.has("position")
	if full_roster:
		world.sync_worker_roster(saved_ids)
	for entry: Dictionary in snapshot.get("roles", []):
		world.set_worker_role(
			int(entry.get("worker_id", -1)),
			int(entry.get("role_id", WorkerRolesScript.Role.MINER)),
			false
		)
		for worker: Worker in world.workers:
			if worker.worker_id == int(entry.get("worker_id", -1)):
				worker.work_priorities = entry.get("work_priorities", {}).duplicate()
				if entry.has("position"):
					_restore_position(world, worker, entry.position)
				break
	world.notify_worker_roles_changed()


## Places a respawned worker back where it was saved when that cell can still
## be stood on; otherwise it keeps its default spawn position.
static func _restore_position(world: World, worker: Worker, saved: Vector3) -> void:
	var coord := Vector3i(int(round(saved.x)), int(floor(saved.y)), int(round(saved.z)))
	if not world.is_block_coord_valid(coord.x, coord.y, coord.z):
		return
	# Read the saved terrain under the worker (never generate) to check support.
	for cell: Vector3i in [coord, coord + Vector3i.DOWN]:
		if world.is_block_coord_valid(cell.x, cell.y, cell.z):
			_load_saved_chunk(world, world.world_to_chunk_coords(cell.x, cell.y, cell.z))
	if not world._is_loaded_generated_cell(coord) or not world._is_loaded_generated_cell(coord + Vector3i.DOWN):
		return
	if not worker._can_stand_at(world, coord.x, coord.y, coord.z):
		return
	worker.position = saved
	worker.target_pos = saved


static func _load_saved_chunk(world: World, chunk_coord: Vector3i) -> void:
	var chunk: ChunkData = world.ensure_chunk(chunk_coord)
	if chunk == null or chunk.generated or world.save_load == null:
		return
	if world.save_load.load_chunk_into(chunk_coord, chunk):
		world.touch_chunk(chunk)
		world.notify_chunk_loaded(chunk_coord)


static func _valid_work_priorities(value: Variant) -> bool:
	if not value is Dictionary:
		return false
	var available: Dictionary = {}
	for work: Dictionary in WorkPriorities.entries():
		if work.implemented: available[work.id] = true
	for key: Variant in value:
		if not key is String or not available.has(key) or not value[key] is int:
			return false
		if value[key] < 0 or value[key] > 9:
			return false
	return true
