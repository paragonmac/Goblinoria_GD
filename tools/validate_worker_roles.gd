extends SceneTree

const TEST_PATH := "user://worker_roles_contract/world.save"
const WorkerRolesScript = preload("res://scripts/worker_roles.gd")
const WorldWorkerSaveLoadScript = preload("res://scripts/world_worker_save_load.gd")


func _init() -> void:
	var world := World.new()
	root.add_child(world)
	_run.call_deferred(world)


func _run(world: World) -> void:
	await process_frame
	world.start_new_world(24680)
	var roster_ok := _role_ids(world) == WorkerRolesScript.DEFAULT_SPAWN_ROLES

	var dig_task_id := world.task_queue.add_dig_task(Vector3i(0, world.sea_level, 0))
	var dig_task = world.task_queue.get_task(dig_task_id)
	world.task_manager._start_assignment_auction(dig_task)
	var miner_auction_ok := _worker_ids(world.task_manager.assignment_workers) == [1, 2]
	world.task_manager.reset_assignment_auction()

	var haul_task_id := world.task_queue.add_haul_task(
		1,
		Vector3i(1, world.sea_level, 0),
		World.BLOCK_ID_DIRT,
		1,
		Vector3i(2, world.sea_level, 0)
	)
	var haul_task = world.task_queue.get_task(haul_task_id)
	world.task_manager._start_assignment_auction(haul_task)
	var hauler_auction_ok := _worker_ids(world.task_manager.assignment_workers) == [3]
	world.task_manager.reset_assignment_auction()
	world.set_worker_role(3, WorkerRolesScript.Role.FIGHTER)
	world.task_manager._classify_task_accessibility(haul_task)
	var no_eligible_worker_ok: bool = haul_task.block_reason == TaskQueue.TaskBlockReason.NO_ELIGIBLE_WORKER
	world.set_worker_role(3, WorkerRolesScript.Role.HAULER)

	var fighter: Worker = world.workers[3]
	fighter.wander_wait = 0.0
	fighter.update_idle(0.0, world, world.task_queue, world.pathfinder)
	var fighter_reserve_ok := fighter.state == Worker.WorkerState.IDLE and fighter.path.is_empty()

	var reassigned_ok := world.set_worker_role(4, WorkerRolesScript.Role.HAULER)
	var save_ok := world.save_world(TEST_PATH)
	world.set_worker_role(4, WorkerRolesScript.Role.FIGHTER)
	var load_ok := world.load_world(TEST_PATH)
	var persisted_role_ok := _worker_role(world, 4) == WorkerRolesScript.Role.HAULER
	var v5_migration_ok := _mark_save_as_v5_without_workers(TEST_PATH) \
		and world.load_world(TEST_PATH) \
		and _role_ids(world) == WorkerRolesScript.DEFAULT_SPAWN_ROLES

	world.task_manager.shutdown()
	world.queue_free()
	if not roster_ok:
		_fail("Default roster is not Miner, Miner, Hauler, Fighter")
		return
	if not miner_auction_ok:
		_fail("Dig task auction included a non-miner")
		return
	if not hauler_auction_ok:
		_fail("Haul task auction included a non-hauler")
		return
	if not no_eligible_worker_ok:
		_fail("Unstaffable haul task did not report no eligible worker")
		return
	if not fighter_reserve_ok:
		_fail("Fighter did not remain in reserve without combat work")
		return
	if not reassigned_ok or not save_ok or not load_ok or not persisted_role_ok:
		_fail("Worker role did not persist across save/load")
		return
	if not v5_migration_ok:
		_fail("V5 save without worker roles did not receive the default roster")
		return
	print("Worker role contract OK")
	quit(0)


func _worker_ids(workers: Array) -> Array[int]:
	var ids: Array[int] = []
	for worker: Worker in workers:
		ids.append(worker.worker_id)
	return ids


func _role_ids(world: World) -> Array[int]:
	var roles: Array[int] = []
	for worker: Worker in world.workers:
		roles.append(worker.role_id)
	return roles


func _worker_role(world: World, worker_id: int) -> int:
	for worker: Worker in world.workers:
		if worker.worker_id == worker_id:
			return worker.role_id
	return -1


func _mark_save_as_v5_without_workers(path: String) -> bool:
	var world_dir := path.get_basename()
	var meta_path := world_dir.path_join(WorldMetadataSaveLoad.META_FILE_NAME)
	var meta_file := FileAccess.open(meta_path, FileAccess.READ_WRITE)
	if meta_file == null:
		return false
	meta_file.seek(4)
	meta_file.store_16(WorldSaveLoad.WORKER_ROLES_LEGACY_SAVE_VERSION)
	meta_file.flush()
	var worker_path := world_dir.path_join(WorldWorkerSaveLoadScript.WORKER_FILE_NAME)
	return DirAccess.remove_absolute(ProjectSettings.globalize_path(worker_path)) == OK


func _fail(message: String) -> void:
	push_error(message)
	quit(1)
