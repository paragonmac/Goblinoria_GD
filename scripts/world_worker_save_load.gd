extends RefCounted
class_name WorldWorkerSaveLoad
## Persists worker role assignments while workers continue to respawn on load.

const WORKER_FILE_NAME := "workers.dat"
const WORKER_MAGIC := 0x574F524B
const WorkerRolesScript = preload("res://scripts/worker_roles.gd")


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
		})
	var path := world_dir.path_join(WORKER_FILE_NAME)
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		push_warning("Worker save failed: %s" % path)
		return false
	file.store_32(WORKER_MAGIC)
	file.store_var({"roles": roles}, false)
	file.flush()
	return true


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
	for entry in roles_value:
		if typeof(entry) != TYPE_DICTIONARY:
			return {"ok": false}
		if not WorkerRolesScript.is_valid(int(entry.get("role_id", -1))):
			return {"ok": false}
	return {"ok": true, "roles": roles_value.duplicate(true)}


func apply_snapshot(world: World, snapshot: Dictionary) -> void:
	if world == null or not bool(snapshot.get("ok", false)):
		return
	for entry: Dictionary in snapshot.get("roles", []):
		world.set_worker_role(
			int(entry.get("worker_id", -1)),
			int(entry.get("role_id", WorkerRolesScript.Role.MINER)),
			false
		)
	world.notify_worker_roles_changed()
