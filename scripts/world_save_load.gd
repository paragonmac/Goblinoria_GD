extends RefCounted
class_name WorldSaveLoad
## Handles world save/load and serialization.

#region Preloads
const WorldInventorySaveLoadScript = preload("res://scripts/world_inventory_save_load.gd")
const WorldItemStockpileSaveLoadScript = preload("res://scripts/world_item_stockpile_save_load.gd")
const WorldMetadataSaveLoadScript = preload("res://scripts/world_metadata_save_load.gd")
const WorldBulkChunkSaveLoadScript = preload("res://scripts/world_bulk_chunk_save_load.gd")
const WorldMeshCacheSaveLoadScript = preload("res://scripts/world_mesh_cache_save_load.gd")
const WorldWorkerSaveLoadScript = preload("res://scripts/world_worker_save_load.gd")
const WorldTaskSaveLoadScript = preload("res://scripts/world_task_save_load.gd")
const WorldExploredTorchSaveLoadScript = preload("res://scripts/world_explored_torch_save_load.gd")
const WorldSaveTransactionScript = preload("res://scripts/world_save_transaction.gd")
const WorldGenerationSharedScript = preload("res://scripts/world/world_generation_shared.gd")
const WorldTerrainHeightSamplerScript = preload("res://scripts/world/world_terrain_height_sampler.gd")
const WorldRampRulesScript = preload("res://scripts/world/world_ramp_rules.gd")
const WorldGenerationPipelineScript = preload("res://scripts/world_generation_pipeline.gd")
#endregion

#region Constants
const CHUNK_MAGIC := 0x43484B53
const SAVE_VERSION := 13
const LEGACY_SAVE_VERSION := 4
const WORKER_ROLES_LEGACY_SAVE_VERSION := 5
const NAMED_WORK_SETTINGS_LEGACY_SAVE_VERSION := 6
const PREVIOUS_STAIR_FLIGHT_SAVE_VERSION := 7
# V8 has no worker positions or saved designations; both default on load.
const NO_TASKS_LEGACY_SAVE_VERSION := 8
const SAVE_V9_LEGACY_VERSION := 9
const SAVE_V10_LEGACY_VERSION := 10
const SAVE_V11_LEGACY_VERSION := 11
const SAVE_V12_LEGACY_VERSION := 12
const LEGACY_SAVE_VERSIONS := [LEGACY_SAVE_VERSION, WORKER_ROLES_LEGACY_SAVE_VERSION, NAMED_WORK_SETTINGS_LEGACY_SAVE_VERSION, PREVIOUS_STAIR_FLIGHT_SAVE_VERSION, NO_TASKS_LEGACY_SAVE_VERSION, SAVE_V9_LEGACY_VERSION, SAVE_V10_LEGACY_VERSION, SAVE_V11_LEGACY_VERSION, SAVE_V12_LEGACY_VERSION]
const CHUNK_DIR_NAME := "chunks"
# Optional since V9: camera view at save time. Missing means the default view.
const VIEW_FILE_NAME := "view.dat"
const VIEW_MAGIC := 0x56494557
const CHUNK_FILE_EXT := ".chunk"
const COMPRESSION_NONE := 0
#endregion

#region State
var world: World
var current_world_dir := ""
var warned_missing_world_dir: bool = false
var last_load_metrics: Dictionary = {}
var inventory_save_load = WorldInventorySaveLoadScript.new()
var item_stockpile_save_load = WorldItemStockpileSaveLoadScript.new()
var metadata_save_load = WorldMetadataSaveLoadScript.new()
var bulk_chunk_save_load = WorldBulkChunkSaveLoadScript.new()
var mesh_cache_save_load = WorldMeshCacheSaveLoadScript.new()
var worker_save_load = WorldWorkerSaveLoadScript.new()
var task_save_load = WorldTaskSaveLoadScript.new()
var explored_torch_save_load = WorldExploredTorchSaveLoadScript.new()
# Read during load; applied by World after it clears the previous task queue.
var pending_task_snapshot: Dictionary = {}
var pending_explored_snapshot: Dictionary = {}
var pending_torch_snapshot: Dictionary = {}
var pending_tree_snapshot: Dictionary = {}
var pending_migration_task_snapshot: Dictionary = {}
var has_pending_light_snapshots := false
var save_transaction = WorldSaveTransactionScript.new()
var legacy_terrain_slope_migration: bool = false
#endregion


#region Initialization
func _init(world_ref: World) -> void:
	world = world_ref
#endregion


#region Save
func clear_world_dir() -> void:
	current_world_dir = ""
	warned_missing_world_dir = false
	_clear_bulk_chunk_cache()
	_clear_mesh_cache_entries()


func save_world(path: String) -> bool:
	var world_dir := _world_dir_from_path(path)
	var start_usec := Time.get_ticks_usec()
	# The mesh cache is rewritten whenever a renderer exists; copying the old one
	# into the stage first only to truncate it doubled save I/O.
	# Files this save rewrites are not copied into the stage first: copying then
	# immediately reopening a fresh copy for writing races antivirus scans on
	# Windows and wasted I/O. Only unknown slot files are carried over.
	var regenerated: Array = [
		WorldMetadataSaveLoad.META_FILE_NAME,
		WorldBulkChunkSaveLoadScript.BULK_CHUNKS_FILE_NAME,
		WorldItemStockpileSaveLoadScript.ITEM_STOCKPILE_FILE_NAME,
		WorldWorkerSaveLoadScript.WORKER_FILE_NAME,
		WorldTaskSaveLoadScript.TASK_FILE_NAME,
		WorldExploredTorchSaveLoadScript.EXPLORED_FILE_NAME,
		WorldExploredTorchSaveLoadScript.TORCH_FILE_NAME,
		WorldExploredTorchSaveLoadScript.TREE_FILE_NAME,
		VIEW_FILE_NAME,
	]
	if world.renderer != null:
		regenerated.append(WorldMeshCacheSaveLoadScript.MESH_CACHE_FILE_NAME)
	# Legacy per-chunk files are folded into the bulk file below (read from the
	# live slot, not the stage), and loading ignores them once bulk data exists.
	# Copying ~30k small files dominated save time, so new slots omit them.
	regenerated.append(CHUNK_DIR_NAME)
	if not save_transaction.begin(world_dir, regenerated):
		push_error("World save failed: %s" % world_dir)
		return false
	var begin_usec := Time.get_ticks_usec()
	var previous_bulk_state := bulk_chunk_save_load.snapshot_state()
	var previous_mesh_state := mesh_cache_save_load.snapshot_state()
	var stage_dir: String = save_transaction.stage_dir
	var ok := DirAccess.make_dir_recursive_absolute(_chunk_dir_path(stage_dir)) == OK \
		and _write_world_meta(stage_dir) and _collect_legacy_chunks() and _save_bulk_chunks(stage_dir)
	var bulk_usec := Time.get_ticks_usec()
	var mesh_usec := bulk_usec
	if ok:
		var mesh_ok := _save_mesh_cache(stage_dir)
		mesh_usec = Time.get_ticks_usec()
		if not mesh_ok:
			# Cache data is optional, but a partial or stale cache must not be promoted.
			var cache_path := stage_dir.path_join(WorldMeshCacheSaveLoadScript.MESH_CACHE_FILE_NAME)
			if FileAccess.file_exists(cache_path):
				ok = DirAccess.remove_absolute(cache_path) == OK
			mesh_cache_save_load.restore_state(previous_mesh_state)
		ok = ok and _save_items_and_stockpiles(stage_dir) and _save_workers(stage_dir) \
			and task_save_load.save_tasks(world, stage_dir) and _write_view(stage_dir) \
			and explored_torch_save_load.save_explored(world.light_field, stage_dir) \
			and explored_torch_save_load.save_torches(world, stage_dir) \
			and explored_torch_save_load.save_trees(world, stage_dir)
	if not ok or not save_transaction.promote():
		bulk_chunk_save_load.restore_state(previous_bulk_state)
		mesh_cache_save_load.restore_state(previous_mesh_state)
		save_transaction.abort()
		return false
	current_world_dir = world_dir
	for chunk in world.chunks.values():
		var entry: ChunkData = chunk
		entry.dirty = false
	var end_usec := Time.get_ticks_usec()
	print("World save: total %.0f ms (begin %.0f, blocks %.0f, mesh cache %.0f [%d entries], rest+promote %.0f)" % [
		(end_usec - start_usec) / 1000.0, (begin_usec - start_usec) / 1000.0, (bulk_usec - begin_usec) / 1000.0,
		(mesh_usec - bulk_usec) / 1000.0, int(mesh_cache_save_load.mesh_cache_stats.get("entries_saved", 0)),
		(end_usec - mesh_usec) / 1000.0])
	return true
#endregion


#region Load
func load_world(path: String) -> bool:
	var old_chunks_x: int = World.WORLD_CHUNKS_X
	var old_chunks_z: int = World.WORLD_CHUNKS_Z
	var old_world_size_x: int = world.world_size_x
	var old_world_size_y: int = world.world_size_y
	var old_world_size_z: int = world.world_size_z
	var ok := _load_world(path)
	if not ok:
		World.configure_dimensions(old_chunks_x, old_chunks_z)
		world.world_size_x = old_world_size_x
		world.world_size_y = old_world_size_y
		world.world_size_z = old_world_size_z
	return ok


func _load_world(path: String) -> bool:
	var load_start_usec: int = Time.get_ticks_usec()
	pending_task_snapshot = {}
	pending_explored_snapshot = {}
	pending_torch_snapshot = {}
	pending_tree_snapshot = {}
	pending_migration_task_snapshot = {}
	has_pending_light_snapshots = false
	var world_dir := _world_dir_from_path(path)
	if not save_transaction.recover(world_dir):
		return false
	var meta_start_usec: int = Time.get_ticks_usec()
	var meta_snapshot := metadata_save_load.read_world_meta_snapshot(
		world,
		world_dir,
		SAVE_VERSION,
		_get_block_table_hash(),
		LEGACY_SAVE_VERSIONS,
		[LEGACY_SAVE_VERSION],
		{5: _pre_flight_block_table_hashes(), 6: _pre_flight_block_table_hashes(), 7: _pre_flight_block_table_hashes()}
	)
	if not bool(meta_snapshot.get("ok", false)):
		return false
	if not World.configure_dimensions(int(meta_snapshot["chunks_x"]), int(meta_snapshot["chunks_z"])):
		return false
	world.world_size_x = World.WORLD_CHUNKS_X * World.CHUNK_SIZE
	world.world_size_z = World.WORLD_CHUNKS_Z * World.CHUNK_SIZE
	world.world_size_y = World.WORLD_CHUNKS_Y * World.CHUNK_SIZE
	if int(meta_snapshot["save_version"]) >= NAMED_WORK_SETTINGS_LEGACY_SAVE_VERSION \
		and not FileAccess.file_exists(world_dir.path_join(WorldBulkChunkSaveLoadScript.BULK_CHUNKS_FILE_NAME)) \
		and not _has_valid_chunk_save(world_dir):
		push_warning("World load failed: missing terrain data in %s" % world_dir)
		return false
	var load_metrics := {"meta_ms": _elapsed_ms(meta_start_usec)}
	var item_start_usec: int = Time.get_ticks_usec()
	var item_snapshot := item_stockpile_save_load.read_snapshot(world_dir)
	if not bool(item_snapshot.get("ok", false)):
		return false
	load_metrics["items_stockpiles_ms"] = _elapsed_ms(item_start_usec)
	var worker_start_usec: int = Time.get_ticks_usec()
	var worker_snapshot := worker_save_load.read_snapshot(world_dir)
	if not bool(worker_snapshot.get("ok", false)):
		return false
	var task_snapshot := task_save_load.read_snapshot(world, world_dir)
	if not bool(task_snapshot.get("ok", false)):
		return false
	var save_version := int(meta_snapshot.get("save_version", SAVE_VERSION))
	var explored_snapshot := explored_torch_save_load.read_explored_snapshot(world_dir, save_version >= SAVE_V10_LEGACY_VERSION, world)
	if not bool(explored_snapshot.get("ok", false)):
		return false
	var torch_snapshot := explored_torch_save_load.read_torch_snapshot(world, world_dir, save_version >= SAVE_V10_LEGACY_VERSION)
	if not bool(torch_snapshot.get("ok", false)):
		return false
	var tree_snapshot := explored_torch_save_load.read_tree_snapshot(world, world_dir, save_version >= SAVE_V12_LEGACY_VERSION)
	if not bool(tree_snapshot.get("ok", false)):
		return false
	var view_snapshot := _read_view(world_dir)
	if not bool(view_snapshot.get("ok", false)):
		return false
	load_metrics["worker_roles_ms"] = _elapsed_ms(worker_start_usec)
	var previous_bulk_state := bulk_chunk_save_load.snapshot_state()
	var bulk_start_usec: int = Time.get_ticks_usec()
	var migrate_legacy_slopes := int(meta_snapshot.get("save_version", SAVE_VERSION)) == LEGACY_SAVE_VERSION \
		and bool(meta_snapshot.get("legacy_block_table", false))
	if not _load_bulk_chunks(world_dir, migrate_legacy_slopes, int(meta_snapshot.get("block_table_hash", _get_block_table_hash()))):
		bulk_chunk_save_load.restore_state(previous_bulk_state)
		return false
	last_load_metrics = load_metrics
	var bulk_stats := bulk_chunk_save_load.get_last_load_stats()
	if not bulk_stats.is_empty():
		last_load_metrics["bulk_block_format"] = bulk_stats
	legacy_terrain_slope_migration = migrate_legacy_slopes
	if legacy_terrain_slope_migration:
		var migrated_slopes := _migrate_legacy_terrain_slopes(int(meta_snapshot.get("world_seed", 0)))
		last_load_metrics["migrated_terrain_slopes"] = migrated_slopes
	last_load_metrics["bulk_blocks_ms"] = _elapsed_ms(bulk_start_usec)
	current_world_dir = world_dir
	var mesh_cache_start_usec: int = Time.get_ticks_usec()
	_load_mesh_cache(world_dir)
	last_load_metrics["mesh_cache_ms"] = _elapsed_ms(mesh_cache_start_usec)
	metadata_save_load.apply_world_meta(world, meta_snapshot)
	# Runtime identity changes at the successful load commit, even on the same node.
	world.runtime_epoch += 1
	if world.live_diagnostics != null:
		world.live_diagnostics.begin_world("load_committed")
	world.chunks.clear()
	world.chunk_access_tick = 0
	world.reset_streaming_state()
	world.clear_and_respawn_workers()
	worker_save_load.apply_snapshot(world, worker_snapshot)
	if world.renderer != null:
		world.renderer.clear_chunks()
		world.renderer.reset_stats()
	item_stockpile_save_load.apply_snapshot(world, item_snapshot)
	pending_task_snapshot = task_snapshot
	pending_explored_snapshot = explored_snapshot
	pending_torch_snapshot = torch_snapshot
	pending_tree_snapshot = tree_snapshot
	pending_migration_task_snapshot = task_snapshot
	has_pending_light_snapshots = true
	world.loaded_view_state = view_snapshot.get("view", {})
	last_load_metrics["total_save_load_ms"] = _elapsed_ms(load_start_usec)
	return true


func load_chunk_into(coord: Vector3i, chunk: ChunkData) -> bool:
	if not world.is_chunk_coord_valid(coord):
		return false
	if bulk_chunk_save_load.is_loaded():
		if not bulk_chunk_save_load.has_chunk(coord):
			return false
		var blocks := bulk_chunk_save_load.get_chunk_blocks(coord)
		if blocks.size() != World.CHUNK_VOLUME:
			return false
		chunk.blocks = blocks.duplicate()
		chunk.generated = true
		chunk.dirty = false
		_try_import_mesh_cache_for_loaded_chunk(coord, chunk)
		return true
	if current_world_dir.is_empty():
		if not warned_missing_world_dir:
			push_warning("Chunk load skipped: no world directory set.")
			warned_missing_world_dir = true
		return false
	var world_dir := current_world_dir
	var path := _chunk_path(world_dir, coord)
	if not FileAccess.file_exists(path):
		return false
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return false
	var header := _read_chunk_header(file, coord, legacy_terrain_slope_migration)
	if header.is_empty():
		return false
	var data_len: int = int(header["data_len"])
	var buffer := file.get_buffer(data_len)
	if buffer.size() != data_len:
		return false
	chunk.blocks = buffer
	chunk.generated = true
	chunk.dirty = false
	_try_import_mesh_cache_for_loaded_chunk(coord, chunk)
	return true


func save_chunk_current(coord: Vector3i, chunk: ChunkData) -> bool:
	if not world.is_chunk_coord_valid(coord):
		return false
	if current_world_dir.is_empty():
		if not warned_missing_world_dir:
			push_warning("Chunk save skipped: no world directory set.")
			warned_missing_world_dir = true
		return false
	var ok := save_chunk(current_world_dir, coord, chunk)
	if ok:
		_remember_bulk_chunk(coord, chunk)
	return ok
#endregion


#region Helpers
func save_chunk(world_dir: String, coord: Vector3i, chunk: ChunkData) -> bool:
	if not world.is_chunk_coord_valid(coord):
		return false
	var path := _chunk_path(world_dir, coord)
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		push_warning("Chunk save failed: %s" % path)
		return false
	var block_hash: int = _get_block_table_hash()
	_write_chunk_header(file, coord, chunk.blocks.size(), block_hash)
	file.store_buffer(chunk.blocks)
	file.flush()
	return true


func _save_bulk_chunks(world_dir: String) -> bool:
	return bulk_chunk_save_load.save_bulk_chunks(world, world_dir, _get_block_table_hash())


func _load_bulk_chunks(world_dir: String, allow_legacy_block_table_hash: bool = false, expected_hash: int = -1) -> bool:
	return bulk_chunk_save_load.load_bulk_chunks(
		world,
		world_dir,
		_get_block_table_hash() if expected_hash < 0 else expected_hash,
		allow_legacy_block_table_hash
	)


func _has_valid_chunk_save(world_dir: String) -> bool:
	var dir := DirAccess.open(_chunk_dir_path(world_dir))
	if dir == null:
		return false
	for name in dir.get_files():
		if not name.ends_with(CHUNK_FILE_EXT):
			continue
		var parts := name.get_basename().split("_")
		if parts.size() != 3 or not parts[0].is_valid_int() \
			or not parts[1].is_valid_int() or not parts[2].is_valid_int():
			continue
		var coord := Vector3i(int(parts[0]), int(parts[1]), int(parts[2]))
		var file := FileAccess.open(_chunk_path(world_dir, coord), FileAccess.READ)
		if file == null:
			continue
		# Current metadata must never inherit the live world's legacy hash exemption.
		var header := _read_chunk_header(file, coord, false)
		if int(header.get("data_len", 0)) == World.CHUNK_VOLUME \
			and file.get_length() - file.get_position() == World.CHUNK_VOLUME:
			return true
	return false


func _collect_legacy_chunks() -> bool:
	if bulk_chunk_save_load.is_loaded() or current_world_dir.is_empty():
		return true
	var dir := DirAccess.open(_chunk_dir_path(current_world_dir))
	if dir == null:
		return not DirAccess.dir_exists_absolute(_chunk_dir_path(current_world_dir))
	for name in dir.get_files():
		if not name.ends_with(CHUNK_FILE_EXT):
			continue
		var parts := name.get_basename().split("_")
		if parts.size() != 3 or not parts[0].is_valid_int() \
			or not parts[1].is_valid_int() or not parts[2].is_valid_int():
			continue
		var coord := Vector3i(int(parts[0]), int(parts[1]), int(parts[2]))
		if not world.is_chunk_coord_valid(coord) or bulk_chunk_save_load.has_chunk(coord):
			continue
		var file := FileAccess.open(_chunk_path(current_world_dir, coord), FileAccess.READ)
		if file == null:
			return false
		var header := _read_chunk_header(file, coord, legacy_terrain_slope_migration)
		if int(header.get("data_len", 0)) != World.CHUNK_VOLUME:
			return false
		var blocks := file.get_buffer(World.CHUNK_VOLUME)
		if blocks.size() != World.CHUNK_VOLUME or file.get_error() != OK:
			return false
		bulk_chunk_save_load.replace_chunk_blocks(coord, blocks)
	return true


func _remember_bulk_chunk(coord: Vector3i, chunk: ChunkData) -> void:
	bulk_chunk_save_load.remember_chunk(world, coord, chunk)


func _clear_bulk_chunk_cache() -> void:
	bulk_chunk_save_load.clear_cache()


func _save_mesh_cache(world_dir: String) -> bool:
	return mesh_cache_save_load.save_mesh_cache(world, world_dir, bulk_chunk_save_load.get_cache(), _get_block_table_hash())


func _load_mesh_cache(world_dir: String) -> bool:
	return mesh_cache_save_load.load_mesh_cache(world, world_dir, _get_block_table_hash())


func _try_import_mesh_cache_for_loaded_chunk(coord: Vector3i, chunk: ChunkData) -> void:
	mesh_cache_save_load.try_import_for_loaded_chunk(world, bulk_chunk_save_load.get_cache(), coord, chunk)


func _clear_mesh_cache_entries() -> void:
	mesh_cache_save_load.clear()


func _reset_mesh_cache_stats() -> void:
	mesh_cache_save_load.reset_stats()


func get_last_load_metrics() -> Dictionary:
	var metrics := last_load_metrics.duplicate()
	metrics["mesh_cache"] = mesh_cache_save_load.get_stats()
	return metrics


func _elapsed_ms(start_usec: int) -> float:
	return float(Time.get_ticks_usec() - start_usec) / 1000.0


func _write_world_meta(world_dir: String) -> bool:
	return metadata_save_load.write_world_meta(world, world_dir, SAVE_VERSION, _get_block_table_hash())


func _read_world_meta(world_dir: String) -> bool:
	return metadata_save_load.read_world_meta(world, world_dir, SAVE_VERSION, _get_block_table_hash())

func _write_chunk_header(file: FileAccess, coord: Vector3i, data_len: int, block_hash: int) -> void:
	file.store_32(CHUNK_MAGIC)
	file.store_16(SAVE_VERSION)
	file.store_16(World.CHUNK_SIZE)
	_store_signed_32(file, coord.x)
	_store_signed_32(file, coord.y)
	_store_signed_32(file, coord.z)
	file.store_32(data_len)
	file.store_8(COMPRESSION_NONE)
	file.store_32(block_hash)


func _read_chunk_header(file: FileAccess, coord: Vector3i, allow_legacy_hash: bool = false) -> Dictionary:
	var magic: int = file.get_32()
	if magic != CHUNK_MAGIC:
		return {}
	var version: int = file.get_16()
	if version != SAVE_VERSION and not LEGACY_SAVE_VERSIONS.has(version):
		return {}
	var chunk_size: int = file.get_16()
	if chunk_size != World.CHUNK_SIZE:
		return {}
	var cx: int = _read_signed_32(file)
	var cy: int = _read_signed_32(file)
	var cz: int = _read_signed_32(file)
	if cx != coord.x or cy != coord.y or cz != coord.z:
		return {}
	if not world.is_chunk_coord_valid(coord):
		return {}
	var data_len: int = file.get_32()
	var compression: int = file.get_8()
	if compression != COMPRESSION_NONE:
		return {}
	var block_hash: int = file.get_32()
	var known_pre_flight_hash := version in [5, 6, 7] and _pre_flight_block_table_hashes().has(block_hash)
	if block_hash != _get_block_table_hash() and not allow_legacy_hash and not known_pre_flight_hash:
		return {}
	return {"data_len": data_len}


func _migrate_legacy_terrain_slopes(world_seed: int) -> int:
	var flat_noise := FastNoiseLite.new()
	var small_noise := FastNoiseLite.new()
	var large_noise := FastNoiseLite.new()
	var macro_noise := FastNoiseLite.new()
	WorldGenerationSharedScript.configure_height_noises(
		world_seed,
		flat_noise,
		small_noise,
		large_noise,
		macro_noise
	)
	var migrated := 0
	for coord_value in bulk_chunk_save_load.get_cache().keys():
		var coord: Vector3i = coord_value
		var blocks := bulk_chunk_save_load.get_chunk_blocks(coord)
		var changed := false
		for index in range(blocks.size()):
			var old_id: int = int(blocks[index])
			if old_id < World.RAMP_NORTH_ID or old_id > World.INNER_NORTHEAST_ID:
				continue
			var local_x: int = index % World.CHUNK_SIZE
			var local_y: int = (index / World.CHUNK_SIZE) % World.CHUNK_SIZE
			var local_z: int = index / (World.CHUNK_SIZE * World.CHUNK_SIZE)
			var world_pos := Vector3i(
				coord.x * World.CHUNK_SIZE + local_x,
				coord.y * World.CHUNK_SIZE + local_y,
				coord.z * World.CHUNK_SIZE + local_z
			)
			var terrain_id := _legacy_terrain_slope_id_at(
				world_pos,
				old_id,
				flat_noise,
				small_noise,
				large_noise,
				macro_noise
			)
			if terrain_id < 0:
				continue
			blocks[index] = terrain_id
			changed = true
			migrated += 1
		if changed:
			bulk_chunk_save_load.replace_chunk_blocks(coord, blocks)
	return migrated


func _legacy_terrain_slope_id_at(
	pos: Vector3i,
	old_id: int,
	flat_noise: FastNoiseLite,
	small_noise: FastNoiseLite,
	large_noise: FastNoiseLite,
	macro_noise: FastNoiseLite
) -> int:
	# V4 had no source bit. Matching the deterministic terrain ramp is the only
	# available migration signal; a player stair exactly matching terrain is rare.
	if pos.x < World.WORLD_MIN_BLOCK_X or pos.x >= World.WORLD_MAX_BLOCK_X:
		return -1
	if pos.z < World.WORLD_MIN_BLOCK_Z or pos.z >= World.WORLD_MAX_BLOCK_Z:
		return -1
	var h_nw := _terrain_height_at(pos.x, pos.z, flat_noise, small_noise, large_noise, macro_noise)
	var h_ne := _terrain_height_at(pos.x + 1, pos.z, flat_noise, small_noise, large_noise, macro_noise)
	var h_sw := _terrain_height_at(pos.x, pos.z + 1, flat_noise, small_noise, large_noise, macro_noise)
	var h_se := _terrain_height_at(pos.x + 1, pos.z + 1, flat_noise, small_noise, large_noise, macro_noise)
	var result := WorldRampRulesScript.marching_squares_ramp(h_nw, h_ne, h_sw, h_se)
	var expected_id: int = int(result.get("ramp_id", -1))
	if expected_id != old_id or int(result.get("ramp_y", -1)) != pos.y:
		return -1
	return World.terrain_slope_id_for_shape(expected_id)


func _terrain_height_at(
	x: int,
	z: int,
	flat_noise: FastNoiseLite,
	small_noise: FastNoiseLite,
	large_noise: FastNoiseLite,
	macro_noise: FastNoiseLite
) -> int:
	return WorldTerrainHeightSamplerScript.height_at(
		x,
		z,
		world.sea_level,
		world.world_size_y,
		flat_noise,
		small_noise,
		large_noise,
		macro_noise,
		true
	)


func _store_signed_32(file: FileAccess, value: int) -> void:
	file.store_32(value & 0xffffffff)


func _read_signed_32(file: FileAccess) -> int:
	var value: int = file.get_32()
	if value > 0x7fffffff:
		return value - 0x100000000
	return value


func _chunk_path(world_dir: String, coord: Vector3i) -> String:
	var name := "%d_%d_%d%s" % [coord.x, coord.y, coord.z, CHUNK_FILE_EXT]
	return _chunk_dir_path(world_dir).path_join(name)


func _chunk_dir_path(world_dir: String) -> String:
	return world_dir.path_join(CHUNK_DIR_NAME)


func _world_dir_from_path(path: String) -> String:
	var base := path.get_basename()
	return path if base.is_empty() else base


func _get_block_table_hash() -> int:
	if world == null:
		return 0
	if not FileAccess.file_exists(World.BLOCK_DATA_PATH):
		return 0
	var file := FileAccess.open(World.BLOCK_DATA_PATH, FileAccess.READ)
	if file == null:
		return 0
	var content := file.get_as_text()
	return int(content.hash() & 0xffffffff)


func _pre_flight_block_table_hashes() -> Array[int]:
	# The only V5-V7 table extension is the eight appended flight IDs. Preserve
	# strict validation of all older rows, accepting the known LF/CRLF forms.
	var text := FileAccess.get_file_as_string(World.BLOCK_DATA_PATH).replace("\r\n", "\n")
	var prefix := ""
	for line in text.split("\n"):
		if line.begins_with("124,"):
			break
		prefix += line + "\n"
	return [int(prefix.hash() & 0xffffffff), int(prefix.replace("\n", "\r\n").hash() & 0xffffffff)]


func _save_inventory(world_dir: String) -> bool:
	return inventory_save_load.save_inventory(world, world_dir)


func _load_inventory(world_dir: String) -> bool:
	return inventory_save_load.load_inventory(world, world_dir)


func _save_items_and_stockpiles(world_dir: String) -> bool:
	return item_stockpile_save_load.save_items_and_stockpiles(world, world_dir)


func _load_items_and_stockpiles(world_dir: String) -> bool:
	return item_stockpile_save_load.load_items_and_stockpiles(world, world_dir)


func _write_view(world_dir: String) -> bool:
	var file := FileAccess.open(world_dir.path_join(VIEW_FILE_NAME), FileAccess.WRITE)
	if file == null:
		return false
	var ok := file.store_32(VIEW_MAGIC) and file.store_var({"view": world.saved_view_state}, false)
	return WorldSaveTransactionScript.finish_write(file) and ok


func _read_view(world_dir: String) -> Dictionary:
	var path := world_dir.path_join(VIEW_FILE_NAME)
	if not FileAccess.file_exists(path):
		return {"ok": true, "view": {}}
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null or file.get_32() != VIEW_MAGIC:
		return {"ok": false}
	var value = file.get_var(false)
	if typeof(value) != TYPE_DICTIONARY or typeof(value.get("view")) != TYPE_DICTIONARY:
		return {"ok": false}
	# Field contents are validated when Main applies the view; bad fields only
	# fall back to the default camera instead of rejecting the save.
	return {"ok": true, "view": value.view}


## Applies designations read by the last successful load. Returns the count.
func restore_saved_tasks() -> int:
	var restored: int = task_save_load.apply_snapshot(world, pending_task_snapshot)
	pending_task_snapshot = {}
	return restored


## Called after the final full-map light build. This preserves fog discovered by
## the build, restores torch sources, and migrates old saves from worker/task sites.
func apply_final_light_snapshots() -> void:
	if not has_pending_light_snapshots:
		return
	if bool(pending_tree_snapshot.get("present", false)):
		for record: Dictionary in pending_tree_snapshot.get("trees", []):
			var base: Vector3i = record.base
			if _tree_site_is_valid(base) and not world.is_cell_obstructed(base):
				world.add_tree(base, int(record.kind), int(record.variant), int(record.height))
	else:
		_generate_legacy_trees()
	_cancel_restored_chops_without_trees()
	if bool(pending_torch_snapshot.get("present", false)):
		for pos: Vector3i in pending_torch_snapshot.get("positions", []):
			if not world.is_block_coord_valid(pos.x, pos.y, pos.z) \
					or world.get_block_no_generate(pos.x, pos.y, pos.z) != world.BLOCK_ID_AIR:
				push_warning("Skipping restored torch at %s: torch cell is not empty" % pos)
				continue
			var facing: Vector3i = world.torch_mount_facing(pos)
			if int(pending_torch_snapshot.get("format_version", 1)) >= 2:
				facing = pending_torch_snapshot.get("facings", {}).get(pos, Vector3i.ZERO)
			var support_pos := pos + facing if facing != Vector3i.ZERO else pos + Vector3i.DOWN
			if not world.is_block_solid_id(world.get_block_no_generate(support_pos.x, support_pos.y, support_pos.z)):
				facing = world.torch_mount_facing(pos)
				if facing == Vector3i.ZERO and (pos.y <= 0 or not world.is_block_solid_id(
					world.get_block_no_generate(pos.x, pos.y - 1, pos.z))):
					push_warning("Skipping restored torch at %s: no valid support" % pos)
					continue
			if not world.torch_store.add_torch(pos, facing):
				push_warning("Skipping restored torch at %s: duplicate attachment" % pos)
	world.torch_store.register_light_sources()
	# Drain restored sources synchronously so the first rendered frame has correct light.
	while world.light_field.pending_events() > 0:
		world.light_field.process_events(1000000)
	if bool(pending_explored_snapshot.get("present", false)):
		world.light_field.apply_explored(pending_explored_snapshot.explored)
	else:
		last_load_metrics["explored_migration_ms"] = explored_torch_save_load.migrate_explored(
			world, world.light_field, pending_migration_task_snapshot)
	pending_explored_snapshot = {}
	pending_torch_snapshot = {}
	pending_tree_snapshot = {}
	pending_migration_task_snapshot = {}
	has_pending_light_snapshots = false


func _generate_legacy_trees() -> void:
	var pipeline = WorldGenerationPipelineScript.new()
	var generated: Dictionary = pipeline.generate_tree_attachments({
		"world_seed": world.world_seed,
		"sea_level": world.sea_level,
		"world_size_y": world.world_size_y,
	})
	var added := 0
	var invalid_sites := 0
	var occupied_sites := 0
	var rejected_stores := 0
	for base: Vector3i in generated:
		if not _tree_site_is_valid(base):
			invalid_sites += 1
			continue
		if _tree_site_occupied(base):
			occupied_sites += 1
			continue
		var tree: Dictionary = generated[base]
		if world.add_tree(base, int(tree.kind), int(tree.variant), int(tree.height)):
			added += 1
		else:
			rejected_stores += 1
	last_load_metrics["legacy_tree_candidates"] = generated.size()
	last_load_metrics["legacy_trees_added"] = added
	last_load_metrics["legacy_tree_invalid_sites"] = invalid_sites
	last_load_metrics["legacy_tree_occupied_sites"] = occupied_sites
	last_load_metrics["legacy_tree_rejected_stores"] = rejected_stores


func _cancel_restored_chops_without_trees() -> void:
	if world.task_queue == null:
		return
	for task in world.task_queue.tasks.duplicate():
		if task.type != TaskQueue.TaskType.CHOP or world.tree_store.has_tree(task.pos):
			continue
		if task.status == TaskQueue.TaskStatus.PENDING:
			world.task_queue.remove_task(task)
			world.trace_task_event(task, "task_cancelled", "reason=tree_missing_after_load")


func _tree_site_is_valid(base: Vector3i) -> bool:
	if not world.is_block_coord_valid(base.x, base.y, base.z) or base.y <= 0:
		return false
	var floor_id: int = world.get_block_no_generate(base.x, base.y - 1, base.z)
	return (floor_id == World.BLOCK_ID_GRASS or floor_id == World.BLOCK_ID_MOSS or floor_id == World.BLOCK_ID_DIRT) \
		and world.get_block_no_generate(base.x, base.y, base.z) == World.BLOCK_ID_AIR


func _tree_site_occupied(base: Vector3i) -> bool:
	if _tree_site_has_active_task(base) or _tree_site_has_active_task(base + Vector3i.DOWN) \
			or world.is_stockpile_cell(base) \
			or world.torch_store.has_torch(base) or pending_torch_snapshot.get("positions", []).has(base):
		return true
	for item: Dictionary in world.item_store.items.values():
		if item.get("pos") == base:
			return true
	for worker: Worker in world.workers:
		var worker_cell := Vector3i(int(round(worker.position.x)), int(floor(worker.position.y)), int(round(worker.position.z)))
		if worker_cell == base:
			return true
	return false


func _tree_site_has_active_task(pos: Vector3i) -> bool:
	for task in world.task_queue.get_active_tasks_at(pos):
		if task.status != TaskQueue.TaskStatus.COMPLETED:
			return true
	return false


func _save_workers(world_dir: String) -> bool:
	return worker_save_load.save_workers(world, world_dir)
#endregion
