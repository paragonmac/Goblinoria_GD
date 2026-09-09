extends SceneTree
const Fixture = preload("res://tools/validate_save_load_transaction.gd")
const Transaction = preload("res://scripts/world_save_transaction.gd")
const Flight = preload("res://scripts/stair_flight.gd")
var failures: Array[String] = []
var checks := 0

func _init() -> void:
	_run.call_deferred()

func check(value: bool, message: String) -> void:
	checks += 1
	if not value: failures.append(message)

func _run() -> void:
	var world := Fixture.TestWorld.new()
	world._init_ramp_lookup()
	world.block_registry.load_from_csv(World.BLOCK_DATA_PATH)
	world.save_load = WorldSaveLoad.new(world)
	var chunk := ChunkData.new(World.CHUNK_SIZE, World.BLOCK_ID_AIR)
	chunk.generated = true
	world.chunks[Vector3i.ZERO] = chunk
	world.set_block_raw(2, 1, 2, Flight.lower_id(1), true)
	world.set_block_raw(3, 1, 2, Flight.upper_id(1), true)
	world.set_block_raw(4, 1, 2, World.RAMP_NORTH_ID, true)
	var test_root := ProjectSettings.globalize_path("res://.local-stair-save-%d-%d" % [OS.get_process_id(), Time.get_ticks_usec()])
	check(DirAccess.make_dir_absolute(test_root) == OK, "Create isolated save fixture")
	var path := test_root.path_join("slot.save")
	var slot := path.get_basename()
	check(world.save_world(path) and world.load_world(path), "V8 flight round trip")
	var restored := ChunkData.new(World.CHUNK_SIZE, World.BLOCK_ID_AIR)
	check(world.save_load.load_chunk_into(Vector3i.ZERO, restored), "Restore flight chunk")
	world.chunks[Vector3i.ZERO] = restored
	check(world.get_block_no_generate(2, 1, 2) == Flight.lower_id(1) and world.get_block_no_generate(3, 1, 2) == Flight.upper_id(1), "Both oriented halves survive")
	check(world.get_block_no_generate(4, 1, 2) == World.RAMP_NORTH_ID, "Legacy stair ID is unchanged")
	# Produce old-version files using the exact accepted pre-flight table hashes.
	world.chunks[Vector3i.ZERO] = restored
	world.set_block_raw(2, 1, 2, World.BLOCK_ID_AIR, true)
	world.set_block_raw(3, 1, 2, World.BLOCK_ID_AIR, true)
	for version in [5, 6, 7]:
		for old_hash in world.save_load._pre_flight_block_table_hashes():
			check(world.save_load.metadata_save_load.write_world_meta(world, slot, version, old_hash), "Write legacy metadata")
			check(world.save_load.bulk_chunk_save_load.save_bulk_chunks(world, slot, old_hash), "Write matching legacy blocks")
			check(world.load_world(path), "Read legacy table version %d" % version)
			check(not world.save_load.legacy_terrain_slope_migration, "V5-V7 never run V4 terrain migration")
			check(world.save_load.load_chunk_into(Vector3i.ZERO, restored), "Legacy chunk restored")
			world.chunks[Vector3i.ZERO] = restored
			check(world.get_block_no_generate(4, 1, 2) == World.RAMP_NORTH_ID, "Legacy ramp identity retained")
	var epoch := world.runtime_epoch
	world.save_load.metadata_save_load.write_world_meta(world, slot, 7, 123)
	check(not world.load_world(path) and world.runtime_epoch == epoch, "Unknown legacy table rejected before replacement")
	var old_hash: int = world.save_load._pre_flight_block_table_hashes()[0]
	world.save_load.metadata_save_load.write_world_meta(world, slot, 8, old_hash)
	check(not world.load_world(path) and world.runtime_epoch == epoch, "V8 requires current table")
	world.save_load.metadata_save_load.write_world_meta(world, slot, 7, old_hash)
	world.save_load.bulk_chunk_save_load.save_bulk_chunks(world, slot, 123)
	check(not world.load_world(path) and world.runtime_epoch == epoch, "Legacy bulk hash must match validated metadata")
	world.free()
	await process_frame
	if test_root.get_base_dir() == ProjectSettings.globalize_path("res://").trim_suffix("/") and test_root.get_file().begins_with(".local-stair-save-"):
		check(Transaction.new()._remove_tree(test_root), "Remove only isolated fixture")
	if failures.is_empty():
		print("STAIR_SAVE_OK (%d checks)" % checks)
		quit(0)
	else:
		for message in failures: push_error(message)
		quit(1)
