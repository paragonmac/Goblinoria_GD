extends SceneTree
const Fixture = preload("res://tools/validate_save_load_transaction.gd")
const Transaction = preload("res://scripts/world_save_transaction.gd")
var failures: Array[String] = []
var checks := 0

func _init() -> void:
	_run.call_deferred()

func check(value: bool, message: String) -> void:
	checks += 1
	if not value: failures.append(message)

func _write_workers(slot: String, data: Dictionary) -> void:
	var file := FileAccess.open(slot.path_join("workers.dat"), FileAccess.WRITE)
	file.store_32(WorldWorkerSaveLoad.WORKER_MAGIC)
	file.store_var(data, false)
	file.close()

func _run() -> void:
	var world := Fixture.TestWorld.new()
	world._init_ramp_lookup()
	world.block_registry.load_from_csv(World.BLOCK_DATA_PATH)
	world.save_load = WorldSaveLoad.new(world)
	world.world_seed = 12345
	world.spawn_initial_workers()
	var chunk := ChunkData.new(World.CHUNK_SIZE, World.BLOCK_ID_GRANITE)
	chunk.generated = true
	chunk.dirty = true
	world.chunks[Vector3i.ZERO] = chunk
	var cells: Array[Vector3i] = [Vector3i(2, 8, 2)]
	var stockpile := world.create_stockpile(cells)
	check(world.stockpile_store.rename_stockpile(stockpile, "Deep stores"), "Name set before save")
	check(world.set_worker_work_priority(4, "hauling", 2), "Custom hauling set")
	check(world.set_worker_work_priority(4, "mining", 1), "Custom mining set")
	check(world.set_worker_work_priority(1, "building", 0), "Explicit Off set")
	var test_root := ProjectSettings.globalize_path("res://.local-assignment-save-%d-%d" % [OS.get_process_id(), Time.get_ticks_usec()])
	check(DirAccess.make_dir_absolute(test_root) == OK, "Create isolated save-test root")
	var path := test_root.path_join("slot.save")
	var slot := path.get_basename()
	check(world.save_world(path), "V9 transactional save succeeds")
	check(WorldSaveLoad.SAVE_VERSION == 9, "Save format includes worker positions and designations")
	var worker_file := FileAccess.get_file_as_bytes(slot.path_join("workers.dat"))
	world.stockpile_store.rename_stockpile(stockpile, "Unsaved name")
	world.set_worker_work_priority(4, "mining", 9)
	check(world.load_world(path), "V9 reload succeeds")
	check(world.stockpile_store.display_name(stockpile) == "Deep stores", "Name survives real reload")
	check(world.workers[3].get_work_priority("hauling") == 2 and world.workers[3].get_work_priority("mining") == 1, "Per-worker priorities survive respawn")
	check(world.workers[0].get_work_priority("building") == 0, "Explicit Off survives reload")
	var roles: Array = [{"worker_id": 1, "role_id": 0, "work_priorities": {"mining": 10}}]
	_write_workers(slot, {"roles": roles})
	var epoch := world.runtime_epoch
	check(not world.load_world(path) and world.runtime_epoch == epoch, "Invalid priority rejects load before world replacement")
	check(world.workers[3].get_work_priority("mining") == 1, "Rejected load preserves assignments")
	for invalid in [{"crafting": 1}, {"mining": -1}, {"hauling": 1.5}, {"hauling": "2"}, []]:
		roles[0].work_priorities = invalid
		_write_workers(slot, {"roles": roles})
		check(not world.save_load.worker_save_load.read_snapshot(slot).ok, "Reject invalid priority data " + str(invalid))
	# A V6 worker-role file lacks priority overrides; defaults are reconstructed.
	roles = [{"worker_id": 1, "role_id": 0}, {"worker_id": 4, "role_id": 2}]
	_write_workers(slot, {"roles": roles})
	var meta := slot.path_join("world_meta.dat")
	var file := FileAccess.open(meta, FileAccess.READ_WRITE)
	file.seek(4)
	file.store_16(6)
	file.close()
	check(world.load_world(path), "V6 loads without work-priority fields")
	check(world.workers[0].get_work_priority("mining") == 2 and world.workers[3].get_work_priority("hauling") == 0, "Legacy role defaults restored")
	file = FileAccess.open(slot.path_join("workers.dat"), FileAccess.WRITE)
	file.store_buffer(worker_file)
	file.close()
	file = FileAccess.open(meta, FileAccess.READ_WRITE)
	file.seek(4)
	file.store_16(999)
	file.close()
	epoch = world.runtime_epoch
	check(not world.load_world(path) and world.runtime_epoch == epoch, "Unsupported save version is rejected without mutation")
	world.free()
	await process_frame
	# Only the fresh, exact test directory may be removed.
	check(test_root.get_base_dir() == ProjectSettings.globalize_path("res://").trim_suffix("/") and test_root.get_file().begins_with(".local-assignment-save-"), "Cleanup scope is isolated")
	if test_root.get_file().begins_with(".local-assignment-save-"):
		check(Transaction.new()._remove_tree(test_root), "Clean isolated fixture files")
	if failures.is_empty():
		print("ASSIGNMENT_PERSISTENCE_OK (%d checks)" % checks)
		quit(0)
	else:
		for message in failures: push_error(message)
		quit(1)
