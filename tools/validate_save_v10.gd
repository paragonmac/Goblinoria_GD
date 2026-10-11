extends SceneTree
## V13 torch facing and V10 migration contract.

const WorldSaveLoadScript = preload("res://scripts/world_save_load.gd")
const TransactionScript = preload("res://scripts/world_save_transaction.gd")
const WorkerScript = preload("res://scripts/worker.gd")
const CHUNK := preload("res://scripts/chunk_data.gd")

class TestWorld extends World:
	func _ready() -> void:
		super._ready()

	func ensure_chunk_generated(coord: Vector3i) -> ChunkData:
		var chunk := ensure_chunk(coord)
		chunk.generated = true
		return chunk

var root_dir := ""
var checks := 0
var failures := 0


func _init() -> void:
	_run.call_deferred()


func _run() -> void:
	root_dir = ProjectSettings.globalize_path("res://.playtest/luna-save10/%d-%d" % [OS.get_process_id(), Time.get_ticks_usec()])
	_check(DirAccess.make_dir_recursive_absolute(root_dir) == OK, "create isolated save root")
	var source := _make_world()
	var source_slot := root_dir.path_join("v10.save")
	var source_explored: PackedByteArray = source.light_field.explored.duplicate()
	var source_torches := source.torch_store.torch_positions()
	_check(source.save_world(source_slot), "write V13 fixture")
	var reader := _make_world()
	_check(reader.load_world(source_slot), "load V13 fixture")
	_load_fixture_chunks(reader)
	reader.rebuild_light_field()
	_check(reader.light_field.explored == source_explored, "V13 round trip preserves explored bytes")
	_check(reader.torch_store.torch_positions().size() == source_torches.size() and reader.torch_store.has_torch(Vector3i(4, 20, 1)), "V13 restores torch positions")
	_check(reader.torch_store.facing(Vector3i(4, 20, 1)) == Vector3i.LEFT, "V13 round trip preserves wall torch facing")
	_check(reader.light_field.get_block_light(4, 20, 1) == 15 and reader.light_field.pending_events() == 0, "restored torch light is ready at level 15")
	_check(reader.task_queue.has_active_task_at(Vector3i(6, 20, 1), TaskQueue.TaskType.TORCH), "V13 restores pending TORCH task")
	var support_changed_reader := _make_world()
	_check(support_changed_reader.load_world(source_slot), "load V13 for stale torch support recovery")
	_load_fixture_chunks(support_changed_reader)
	support_changed_reader.set_block_raw(3, 20, 1, World.BLOCK_ID_AIR, false)
	support_changed_reader.set_block_raw(5, 20, 1, World.BLOCK_ID_GRANITE, false)
	support_changed_reader.rebuild_light_field()
	_check(support_changed_reader.torch_store.facing(Vector3i(4, 20, 1)) == Vector3i.RIGHT,
		"V13 restored torch remounts when its saved wall support is gone")
	var second_slot := root_dir.path_join("v10_second.save")
	_check(reader.save_world(second_slot), "write second V13 fixture")
	_check(FileAccess.get_file_as_bytes(source_slot.path_join("explored.dat")) == FileAccess.get_file_as_bytes(second_slot.path_join("explored.dat")), "explored.dat content is byte-identical after round trip")
	_check(FileAccess.get_file_as_bytes(source_slot.path_join("torches.dat")) == FileAccess.get_file_as_bytes(second_slot.path_join("torches.dat")), "torches.dat content is byte-identical after round trip")
	var legacy_torch_slot := root_dir.path_join("v10_torch_format.save")
	_check(_copy_slot(source_slot.get_basename(), legacy_torch_slot.get_basename()), "copy V10 torch-format fixture")
	_check(_write_v1_torches(legacy_torch_slot.get_basename().path_join("torches.dat"), Vector3i(4, 20, 1)), "write V10 torches.dat format 1")
	_check(source.save_load.metadata_save_load.write_world_meta(source, legacy_torch_slot.get_basename(), 10, source.save_load._get_block_table_hash()), "write V10 metadata")
	var legacy_torch_reader := _make_world()
	_check(legacy_torch_reader.load_world(legacy_torch_slot), "V10 format 1 torch fixture loads")
	_load_fixture_chunks(legacy_torch_reader)
	legacy_torch_reader.rebuild_light_field()
	_check(legacy_torch_reader.torch_store.has_torch(Vector3i(4, 20, 1)) \
		and legacy_torch_reader.torch_store.facing(Vector3i(4, 20, 1)) == Vector3i.LEFT,
		"V10 format 1 torch facing derives from loaded wall support")

	var legacy_slot := root_dir.path_join("v9.save")
	_check(_copy_slot(source_slot.get_basename(), legacy_slot.get_basename()), "copy V9 fixture")
	_check(DirAccess.remove_absolute(legacy_slot.get_basename().path_join("explored.dat")) == OK, "remove V9 explored file")
	_check(DirAccess.remove_absolute(legacy_slot.get_basename().path_join("torches.dat")) == OK, "remove V9 torch file")
	_check(source.save_load.metadata_save_load.write_world_meta(source, legacy_slot.get_basename(), 9, source.save_load._get_block_table_hash()), "write V9 metadata")
	var legacy_reader := _make_world()
	_check(legacy_reader.load_world(legacy_slot), "V9 fixture loads")
	_load_fixture_chunks(legacy_reader)
	legacy_reader.rebuild_light_field()
	_check(legacy_reader.light_field.get_sky(0, 200, 0) > 0 and legacy_reader.light_field.is_explored(0, 200, 0), "V9 migration includes sky-lit cells")
	_check(legacy_reader.light_field.is_explored(2, 20, 1) and legacy_reader.light_field.is_explored(3, 20, 1), "V9 migration includes worker-connected cave air")
	_check(legacy_reader.light_field.is_explored(6, 20, 1), "V9 migration includes pending task cell")
	_check(not legacy_reader.light_field.is_explored(11, 21, 2), "V9 migration keeps sealed unconnected cave unexplored")
	_check(legacy_reader.save_load.get_last_load_metrics().has("explored_migration_ms"), "V9 migration reports elapsed cost")

	var corrupt_slot := root_dir.path_join("corrupt.save")
	_check(_copy_slot(source_slot.get_basename(), corrupt_slot.get_basename()), "copy corrupt fixture")
	_write_bytes(corrupt_slot.get_basename().path_join("explored.dat"), PackedByteArray([1, 2, 3]))
	var live_seed := reader.world_seed
	var live_explored: PackedByteArray = reader.light_field.explored.duplicate()
	var live_torches := reader.torch_store.torch_positions()
	_check(not reader.load_world(corrupt_slot), "corrupt explored file rejects load")
	_check(reader.world_seed == live_seed and reader.light_field.explored == live_explored and reader.torch_store.torch_positions() == live_torches, "corrupt explored file leaves live world intact")

	var future_slot := root_dir.path_join("v14.save")
	_check(_copy_slot(source_slot.get_basename(), future_slot.get_basename()), "copy future-version fixture")
	_check(source.save_load.metadata_save_load.write_world_meta(source, future_slot.get_basename(), 14, source.save_load._get_block_table_hash()), "write future-version metadata")
	var future_reader := _make_world()
	_check(not future_reader.load_world(future_slot), "V14 rejected")

	for world in [source, reader, support_changed_reader, legacy_reader, legacy_torch_reader, future_reader]:
		if world.task_manager != null: world.task_manager.shutdown()
		world.free()
	_check(_remove_tree(root_dir), "remove isolated save fixtures")
	print("Save V13: %d checks, %d failures" % [checks, failures])
	quit(1 if failures else 0)


func _make_world() -> TestWorld:
	var world := TestWorld.new()
	root.add_child(world)
	for cy in range(World.WORLD_CHUNKS_Y):
		var chunk := world.ensure_chunk_generated(Vector3i(0, cy, 0))
		chunk.blocks.fill(World.BLOCK_ID_GRANITE)
	for y in range(30, 256):
		world.set_block_raw(0, y, 0, World.BLOCK_ID_AIR, false)
	for x in range(1, 8):
		for z in range(0, 4):
			world.set_block_raw(x, 19, z, World.BLOCK_ID_GRANITE, false)
			for y in range(20, 24):
				world.set_block_raw(x, y, z, World.BLOCK_ID_AIR, false)
	world.set_block_raw(3, 20, 1, World.BLOCK_ID_GRANITE, false)
	for x in range(10, 13):
		for z in range(1, 4):
			for y in range(20, 23):
				world.set_block_raw(x, y, z, World.BLOCK_ID_AIR, false)
	var worker := WorkerScript.new()
	worker.worker_id = 1
	worker.position = Vector3(2, 20, 1)
	worker.target_pos = worker.position
	world.workers.clear()
	world.add_child(worker)
	world.workers.append(worker)
	world.spawn_coord = Vector3i(2, 20, 1)
	world.light_field.build(world)
	world.light_field_built = true
	world.torch_store.bind_world(world)
	world.torch_store.add_torch(Vector3i(4, 20, 1), world.torch_mount_facing(Vector3i(4, 20, 1)))
	world.light_field.process_events(1000000)
	world.task_queue.add_task(Vector3i(6, 20, 1), TaskQueue.TaskType.TORCH, 0, {}, [])
	world.light_field.mark_explored(11, 21, 2)
	return world


func _load_fixture_chunks(world: TestWorld) -> void:
	for cy in range(World.WORLD_CHUNKS_Y):
		var coord := Vector3i(0, cy, 0)
		var chunk := world.ensure_chunk(coord)
		if not chunk.generated:
			world.save_load.load_chunk_into(coord, chunk)
		chunk.generated = true


func _copy_slot(source: String, destination: String) -> bool:
	if DirAccess.make_dir_recursive_absolute(destination) != OK:
		return false
	var dir := DirAccess.open(source)
	if dir == null:
		return false
	for name in dir.get_files():
		if not _write_bytes(destination.path_join(name), FileAccess.get_file_as_bytes(source.path_join(name))):
			return false
	for name in dir.get_directories():
		if not _copy_slot(source.path_join(name), destination.path_join(name)):
			return false
	return true


func _write_bytes(path: String, bytes: PackedByteArray) -> bool:
	var file := FileAccess.open(path, FileAccess.WRITE)
	return file != null and file.store_buffer(bytes) and TransactionScript.finish_write(file)


func _write_v1_torches(path: String, pos: Vector3i) -> bool:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return false
	var ok := file.store_32(0x544F5243) and file.store_16(1) and file.store_32(1) \
		and file.store_32(pos.x) and file.store_32(pos.y) and file.store_32(pos.z)
	return TransactionScript.finish_write(file) and ok


func _remove_tree(path: String) -> bool:
	var absolute := ProjectSettings.globalize_path(path).simplify_path()
	if absolute != root_dir and not absolute.begins_with(root_dir + "/"):
		return false
	var dir := DirAccess.open(absolute)
	if dir == null:
		return not DirAccess.dir_exists_absolute(absolute)
	for name in dir.get_directories():
		if dir.is_link(name) or not _remove_tree(absolute.path_join(name)):
			return false
	for name in dir.get_files():
		if DirAccess.remove_absolute(absolute.path_join(name)) != OK:
			return false
	return DirAccess.remove_absolute(absolute) == OK


func _check(condition: bool, label: String) -> void:
	checks += 1
	if not condition:
		failures += 1
		push_error(label)
