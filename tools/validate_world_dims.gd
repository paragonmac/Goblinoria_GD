extends SceneTree

const WorldScript = preload("res://scripts/world.gd")
const ChunkDataScript = preload("res://scripts/chunk_data.gd")
const LightFieldScript = preload("res://scripts/world/light_field.gd")
const LightTextureSyncScript = preload("res://scripts/rendering/light_texture_sync.gd")
const WorldGeneratorScript = preload("res://scripts/world_generator.gd")
const WorldSaveLoadScript = preload("res://scripts/world_save_load.gd")
const PipelineScript = preload("res://scripts/world_generation_pipeline.gd")
const WorkerScript = preload("res://scripts/worker.gd")
const GoblinLightScript = preload("res://scripts/world/goblin_light.gd")

var checks := 0
var failures := 0


class SilentWorkerTrace extends RefCounted:
	func start(_workers: Array) -> bool:
		return true

	func stop() -> void:
		pass

	func record(_worker, _event: String, _task = null, _details: String = "") -> void:
		pass

	func record_task_event(_task, _event: String, _details: String = "") -> void:
		pass

	func record_system_event(_event: String, _details: String = "") -> void:
		pass


func _init() -> void:
	_run.call_deferred()


func _check(ok: bool, message: String) -> void:
	checks += 1
	if not ok:
		failures += 1
		push_error(message)


func _new_world() -> Node:
	var world = WorldScript.new()
	world.worker_trace = SilentWorkerTrace.new()
	world._init_ramp_lookup()
	world.block_registry.load_from_csv(WorldScript.BLOCK_DATA_PATH)
	world.generator = WorldGeneratorScript.new(world)
	world.save_load = WorldSaveLoadScript.new(world)
	world.light_field = LightFieldScript.new()
	return world


func _fixture_chunk(world, coord: Vector3i, fill_id: int = WorldScript.BLOCK_ID_AIR):
	var chunk = ChunkDataScript.new(WorldScript.CHUNK_SIZE, fill_id)
	chunk.generated = true
	world.chunks[coord] = chunk
	return chunk


func _slot_path(name: String) -> String:
	var path := ProjectSettings.globalize_path("res://.playtest/world_dims/" + name + "/world.save")
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	return path


func _remove_slot(path: String) -> void:
	var directory := path.get_base_dir()
	if not DirAccess.dir_exists_absolute(directory):
		return
	var dir := DirAccess.open(directory)
	if dir == null:
		return
	for entry in dir.get_files():
		DirAccess.remove_absolute(directory.path_join(entry))
	for entry in dir.get_directories():
		_remove_slot(directory.path_join(entry).path_join("world.save"))
	DirAccess.remove_absolute(directory)


func _check_failed_load_restore(reader, path: String) -> void:
	_check(not reader.load_world(path), "Reject save with missing required trees.dat")
	_check(WorldScript.WORLD_CHUNKS_X == 32 and WorldScript.WORLD_CHUNKS_Z == 32 \
		and reader.world_size_x == 256 and reader.world_size_y == 256 and reader.world_size_z == 256 \
		and reader.light_field.NX == 256 and reader.light_field.NZ == 256 \
		and reader.is_chunk_coord_valid(Vector3i(10, 0, 0)),
		"Failed 128-wide load restores global and live world dimensions")


func _write_v12_explored_v1(slot_path: String) -> bool:
	var slot_dir: String = slot_path.get_basename()
	var raw := PackedByteArray()
	raw.resize(256 * 256 * 256)
	raw.fill(0)
	raw[(0 * 256 + 0) * 256 + 7] = 255
	var compressed := raw.compress(FileAccess.COMPRESSION_DEFLATE)
	var explored_file := FileAccess.open(slot_dir.path_join("explored.dat"), FileAccess.WRITE)
	if explored_file == null:
		return false
	var ok := explored_file.store_32(0x4558504C) and explored_file.store_16(1) \
		and explored_file.store_8(FileAccess.COMPRESSION_DEFLATE) \
		and explored_file.store_32(raw.size()) and explored_file.store_32(compressed.size()) \
		and explored_file.store_buffer(compressed)
	explored_file.close()
	var meta_path := slot_dir.path_join("world_meta.dat")
	var meta_file := FileAccess.open(meta_path, FileAccess.READ)
	if meta_file == null:
		return false
	var meta_bytes := meta_file.get_buffer(meta_file.get_length())
	meta_file.close()
	if meta_bytes.size() < 6:
		return false
	meta_bytes[4] = 12
	meta_bytes[5] = 0
	meta_file = FileAccess.open(meta_path, FileAccess.WRITE)
	if meta_file == null:
		return false
	ok = ok and meta_file.store_buffer(meta_bytes)
	meta_file.close()
	return ok


func _run() -> void:
	_check(WorldScript.configure_dimensions(16, 16), "Configure 16x16 chunk world")
	var world = _new_world()
	world.world_size_x = 128
	world.world_size_z = 128
	_check(WorldScript.WORLD_MIN_CHUNK_X == -8 and WorldScript.WORLD_MAX_CHUNK_X == 7 \
		and WorldScript.WORLD_MIN_BLOCK_X == -64 and WorldScript.WORLD_MAX_BLOCK_X == 63,
		"Centered chunk and block bounds")
	_check(world.is_chunk_coord_valid(Vector3i(-8, 0, -8)) \
		and world.is_chunk_coord_valid(Vector3i(7, 31, 7)) \
		and not world.is_chunk_coord_valid(Vector3i(8, 0, 0)), "WorldChunkSpace reads configured bounds")

	for cy in range(WorldScript.WORLD_CHUNKS_Y):
		_fixture_chunk(world, Vector3i(0, cy, 0))
	world.light_field.build(world)
	world.light_field_built = true
	var field = world.light_field
	_check(field.NX == 128 and field.NZ == 128 and field.NY == 256 \
		and field.LAYER_SIZE == 128 * 128 and field.VOLUME == 128 * 128 * 256,
		"LightField adopts configured dimensions")
	var rng := RandomNumberGenerator.new()
	rng.seed = 22022
	var cells: Array[Vector3i] = [Vector3i(0, 0, 0), Vector3i(127, 0, 127),
		Vector3i(0, 255, 0), Vector3i(127, 255, 127)]
	for _i in range(100):
		cells.append(Vector3i(rng.randi_range(0, 127), rng.randi_range(0, 255), rng.randi_range(0, 127)))
	var index_roundtrip_ok := true
	for cell: Vector3i in cells:
		var index: int = field._index(cell.x, cell.y, cell.z)
		var decoded := Vector3i(index & (field.NX - 1),
			index >> field._shift_layer,
			(index >> field._shift_x) & (field.NZ - 1))
		if decoded != cell:
			index_roundtrip_ok = false
			break
	_check(index_roundtrip_ok, "LightField index round trips corners and random cells")
	_check(field.get_sky(0, 255, 0) == 15 and field.is_explored(0, 255, 0),
		"Sky light and explored state build on a small fixture")
	var edge_sources := [
		[Vector3i(WorldScript.WORLD_MAX_CHUNK_X, 12, 0), Vector3i(WorldScript.WORLD_MAX_BLOCK_X, 100, 0), Vector3i(WorldScript.WORLD_MIN_BLOCK_X, 100, 0), Vector3i(-1, 0, 0)],
		[Vector3i(WorldScript.WORLD_MIN_CHUNK_X, 12, 0), Vector3i(WorldScript.WORLD_MIN_BLOCK_X, 100, 0), Vector3i(WorldScript.WORLD_MAX_BLOCK_X, 100, 0), Vector3i(1, 0, 0)],
		[Vector3i(0, 12, WorldScript.WORLD_MAX_CHUNK_Z), Vector3i(0, 100, WorldScript.WORLD_MAX_BLOCK_Z), Vector3i(0, 100, WorldScript.WORLD_MIN_BLOCK_Z), Vector3i(0, 0, -1)],
		[Vector3i(0, 12, WorldScript.WORLD_MIN_CHUNK_Z), Vector3i(0, 100, WorldScript.WORLD_MIN_BLOCK_Z), Vector3i(0, 100, WorldScript.WORLD_MAX_BLOCK_Z), Vector3i(0, 0, 1)],
	]
	var edge_light_ok := true
	for edge: Array in edge_sources:
		_fixture_chunk(world, edge[0])
		field.build(world)
		field.add_light_source(edge[1], 15)
		field.process_events()
		var inside: Vector3i = edge[1] + edge[3]
		if field.get_block_light(edge[1].x, edge[1].y, edge[1].z) != 15 \
				or field.get_block_light(inside.x, inside.y, inside.z) != 14 \
				or field.get_block_light(edge[2].x, edge[2].y, edge[2].z) != 0:
			edge_light_ok = false
		field.remove_light_source(edge[1])
		field.process_events()
	_check(edge_light_ok, "Production light stepping lights inward at all four edges without wrapping")
	var light_sync = LightTextureSyncScript.new()
	light_sync.bind(field)
	_check(light_sync.light_tex.get_width() == 128 and light_sync.light_tex.get_height() == 128 \
		and light_sync.light_tex.get_layers() == 256, "Light texture matches world X/Z and Y")

	var edge_worker = WorkerScript.new()
	edge_worker.worker_id = 1
	edge_worker.position = Vector3(WorldScript.WORLD_MAX_BLOCK_X, 200, WorldScript.WORLD_MAX_BLOCK_Z)
	world.workers.append(edge_worker)
	world.goblin_light.update(world)
	_check(world.goblin_light.get_level(WorldScript.WORLD_MAX_BLOCK_X, 200,
		WorldScript.WORLD_MAX_BLOCK_Z) == GoblinLightScript.SOURCE_LEVEL \
		and world.goblin_light.get_level(WorldScript.WORLD_MIN_BLOCK_X, 200,
			WorldScript.WORLD_MAX_BLOCK_Z) == 0,
		"Goblin light illuminates its edge center without wrapping to the opposite edge")
	world.workers.clear()
	edge_worker.free()

	var explored_path := _slot_path("explored_only")
	DirAccess.make_dir_recursive_absolute(explored_path.get_basename())
	field.mark_explored(WorldScript.WORLD_MIN_BLOCK_X, 0, WorldScript.WORLD_MIN_BLOCK_Z)
	field.mark_explored(WorldScript.WORLD_MAX_BLOCK_X, 255, WorldScript.WORLD_MAX_BLOCK_Z)
	_check(world.save_load.explored_torch_save_load.save_explored(world, explored_path.get_basename()),
		"Save 128-wide explored.dat")
	var explored_snapshot: Dictionary = world.save_load.explored_torch_save_load.read_explored_snapshot(
		explored_path.get_basename(), true, world)
	_check(bool(explored_snapshot.get("ok", false)) \
		and explored_snapshot.explored.size() == field.VOLUME \
		and explored_snapshot.explored[field._world_index(WorldScript.WORLD_MAX_BLOCK_X, 255, WorldScript.WORLD_MAX_BLOCK_Z)] == 255,
		"128-wide explored.dat round trip")
	_remove_slot(explored_path)

	var wide_slot := _slot_path("wide_world")
	var saved_chunk: Variant = _fixture_chunk(world, Vector3i(-8, 0, -8), WorldScript.BLOCK_ID_GRANITE)
	saved_chunk.blocks[0] = WorldScript.BLOCK_ID_DIRT
	_check(world.save_world(wide_slot), "Save metadata and bulk chunks at 128 wide")
	_check(WorldScript.configure_dimensions(32, 32), "Return globals to 32x32 before wide load")
	var reader = _new_world()
	_check(reader.load_world(wide_slot), "Load 128-wide metadata and bulk chunks")
	reader.save_load.apply_final_light_snapshots()
	_check(WorldScript.WORLD_CHUNKS_X == 16 and WorldScript.WORLD_CHUNKS_Z == 16 \
		and reader.world_size_x == 128 and reader.world_size_z == 128,
		"Load adopts dimensions from metadata while starting at 32x32")
	_check(reader.light_field.NX == 128 and reader.light_field.NZ == 128 \
		and reader.light_field_built and reader.light_field.light.size() == 128 * 128 * 256,
		"128-wide load rebuilds the light field at the saved dimensions")
	_check(reader.light_field.is_explored(WorldScript.WORLD_MAX_BLOCK_X, 255,
		WorldScript.WORLD_MAX_BLOCK_Z), "128-wide load restores saved explored cells")
	var reader_texture_sync = LightTextureSyncScript.new()
	reader_texture_sync.bind(reader.light_field)
	_check(reader_texture_sync.light_tex.get_width() == 128 \
		and reader_texture_sync.light_tex.get_height() == 128 \
		and reader_texture_sync.light_tex.get_layers() == 256,
		"128-wide load creates correctly sized light textures")
	var loaded_blocks: PackedByteArray = reader.save_load.bulk_chunk_save_load.get_chunk_blocks(Vector3i(-8, 0, -8))
	_check(loaded_blocks.size() == WorldScript.CHUNK_VOLUME \
		and loaded_blocks[0] == WorldScript.BLOCK_ID_DIRT, "128-wide bulk chunk round trip")
	_remove_slot(wide_slot)
	world.free()
	reader.free()

	_check(WorldScript.configure_dimensions(32, 32), "Reconfigure to default 32x32 world")
	var default_world = _new_world()
	_fixture_chunk(default_world, Vector3i(-16, 0, -16), WorldScript.BLOCK_ID_GRANITE)
	default_world.light_field.build(default_world)
	var default_slot := _slot_path("default_world")
	_check(default_world.save_world(default_slot), "Save 256-wide world")
	_check(_write_v12_explored_v1(default_slot), "Write V12 explored.dat format v1 fixture")
	var default_reader = _new_world()
	_check(default_reader.load_world(default_slot), "Load 256-wide save round trip")
	default_reader.save_load.apply_final_light_snapshots()
	_check(WorldScript.WORLD_CHUNKS_X == 32 and WorldScript.WORLD_CHUNKS_Z == 32 \
		and default_reader.save_load.bulk_chunk_save_load.get_chunk_blocks(Vector3i(-16, 0, -16)).size() == WorldScript.CHUNK_VOLUME,
		"Default 256-wide save retains dimensions and blocks")
	_check(default_reader.light_field.is_explored(WorldScript.WORLD_MIN_BLOCK_X + 7, 0,
		WorldScript.WORLD_MIN_BLOCK_Z),
		"V12 explored.dat format v1 restores the legacy 256-wide fog contents")
	var missing_tree_slot := _slot_path("failed_load_restore")
	_check(WorldScript.configure_dimensions(16, 16), "Configure 128-wide failed-load fixture")
	default_world.light_field.build(default_world)
	_check(default_world.save_world(missing_tree_slot), "Save slot for failed-load rollback")
	DirAccess.remove_absolute(missing_tree_slot.get_basename().path_join("trees.dat"))
	_check(WorldScript.configure_dimensions(32, 32), "Restore 256-wide dimensions before failed load")
	var rollback_reader = _new_world()
	_check_failed_load_restore(rollback_reader, missing_tree_slot)
	_remove_slot(missing_tree_slot)
	rollback_reader.free()

	_check(WorldScript.configure_dimensions(16, 32), "Configure non-square 16x32 chunk world")
	_check(WorldScript.WORLD_CHUNKS_X == 16 and WorldScript.WORLD_CHUNKS_Z == 32 \
		and WorldScript.WORLD_MIN_CHUNK_X == -8 and WorldScript.WORLD_MIN_CHUNK_Z == -16,
		"Non-square dimensions retain independent centered bounds")
	var nonsquare_world = _new_world()
	_check(nonsquare_world.world_size_x == 128 and nonsquare_world.world_size_z == 256,
		"Non-square world sizes follow each configured axis")
	nonsquare_world.free()
	_check(WorldScript.configure_dimensions(32, 32), "Restore default dimensions after non-square check")

	var replacement_world := WorldScript.new()
	get_root().add_child(replacement_world)
	var generation_coord := Vector3i(0, 2, 0)
	_check(replacement_world.generator.queue_chunk_generation(generation_coord), "Queue same-size load generation fixture")
	_fixture_chunk(replacement_world, generation_coord)
	replacement_world.renderer.queue_chunk_mesh_build(generation_coord)
	_check(replacement_world.load_world(default_slot), "Same-size load drains pending generation and mesh work")
	_check(replacement_world.generator.queue_chunk_generation(generation_coord), "Queue new-world generation fixture")
	_fixture_chunk(replacement_world, generation_coord)
	replacement_world.renderer.queue_chunk_mesh_build(generation_coord)
	_check(replacement_world.start_new_world(12345), "New-world start drains pending generation and mesh work")
	replacement_world.generator.reset_generation_jobs()
	replacement_world.generator.shutdown_generation_thread()
	replacement_world.renderer._stop_mesh_worker()
	replacement_world.queue_free()
	await process_frame
	_remove_slot(default_slot)
	default_world.free()
	default_reader.free()

	if OS.get_environment("GOB_DIMS_BENCH") == "1":
		await _run_benchmark_512()
	else:
		print("World dims 512 benchmark skipped (set GOB_DIMS_BENCH=1)")
	print("World dims: %d checks, %d failures" % [checks, failures])
	quit(1 if failures > 0 else 0)


func _run_benchmark_512() -> void:
	_check(WorldScript.configure_dimensions(64, 64), "Configure 512 benchmark world")
	var world = _new_world()
	var pipeline = PipelineScript.new()
	var memory_peak := OS.get_static_memory_usage()
	var started := Time.get_ticks_usec()
	var generated: Dictionary = pipeline.generate(world.generator.build_layered_world_config(12345, 226, 256))
	var generation_ms := float(Time.get_ticks_usec() - started) / 1000.0
	var chunk_data: Dictionary = generated["chunks"]
	for coord: Vector3i in chunk_data:
		var chunk = ChunkDataScript.new(WorldScript.CHUNK_SIZE, WorldScript.BLOCK_ID_AIR)
		chunk.blocks = chunk_data[coord]
		chunk.generated = true
		world.chunks[coord] = chunk
	generated.clear()
	chunk_data.clear()
	memory_peak = maxi(memory_peak, OS.get_static_memory_usage())
	started = Time.get_ticks_usec()
	world.light_field.build(world)
	var light_ms := float(Time.get_ticks_usec() - started) / 1000.0
	memory_peak = maxi(memory_peak, OS.get_static_memory_usage())
	var slot := _slot_path("benchmark_512")
	started = Time.get_ticks_usec()
	var saved: bool = world.save_world(slot)
	var save_ms := float(Time.get_ticks_usec() - started) / 1000.0
	memory_peak = maxi(memory_peak, OS.get_static_memory_usage())
	var reader = _new_world()
	started = Time.get_ticks_usec()
	var loaded: bool = reader.load_world(slot)
	var load_ms := float(Time.get_ticks_usec() - started) / 1000.0
	memory_peak = maxi(memory_peak, OS.get_static_memory_usage())
	print("World dims 512 benchmark ms: generation %.2f, light %.2f, save %.2f, load %.2f; static memory peak %.2f MiB" % [
		generation_ms, light_ms, save_ms, load_ms, float(memory_peak) / (1024.0 * 1024.0)])
	_check(saved and loaded and WorldScript.WORLD_CHUNKS_X == 64 and reader.world_size_x == 512,
		"512 blocks, light, save, and load round trip without mesh pre-cook")
	_remove_slot(slot)
	world.free()
	reader.free()
	_check(WorldScript.configure_dimensions(32, 32), "Restore default dimensions after benchmark")
