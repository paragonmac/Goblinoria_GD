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
const WorldSaveTransactionScript = preload("res://scripts/world_save_transaction.gd")
const WorldGenerationSharedScript = preload("res://scripts/world/world_generation_shared.gd")
const WorldTerrainHeightSamplerScript = preload("res://scripts/world/world_terrain_height_sampler.gd")
const WorldRampRulesScript = preload("res://scripts/world/world_ramp_rules.gd")
#endregion

#region Constants
const CHUNK_MAGIC := 0x43484B53
const SAVE_VERSION := 8
const LEGACY_SAVE_VERSION := 4
const WORKER_ROLES_LEGACY_SAVE_VERSION := 5
const NAMED_WORK_SETTINGS_LEGACY_SAVE_VERSION := 6
const PREVIOUS_STAIR_FLIGHT_SAVE_VERSION := 7
const LEGACY_SAVE_VERSIONS := [LEGACY_SAVE_VERSION, WORKER_ROLES_LEGACY_SAVE_VERSION, NAMED_WORK_SETTINGS_LEGACY_SAVE_VERSION, PREVIOUS_STAIR_FLIGHT_SAVE_VERSION]
const CHUNK_DIR_NAME := "chunks"
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
	if not save_transaction.begin(world_dir):
		push_error("World save failed: %s" % world_dir)
		return false
	var previous_bulk_state := bulk_chunk_save_load.snapshot_state()
	var previous_mesh_state := mesh_cache_save_load.snapshot_state()
	var stage_dir: String = save_transaction.stage_dir
	var ok := DirAccess.make_dir_recursive_absolute(_chunk_dir_path(stage_dir)) == OK \
		and _write_world_meta(stage_dir) and _collect_legacy_chunks() and _save_bulk_chunks(stage_dir)
	if ok:
		if not _save_mesh_cache(stage_dir):
			# Cache data is optional, but a partial or stale cache must not be promoted.
			var cache_path := stage_dir.path_join(WorldMeshCacheSaveLoadScript.MESH_CACHE_FILE_NAME)
			if FileAccess.file_exists(cache_path):
				ok = DirAccess.remove_absolute(cache_path) == OK
			mesh_cache_save_load.restore_state(previous_mesh_state)
		ok = ok and _save_items_and_stockpiles(stage_dir) and _save_workers(stage_dir)
	if not ok or not save_transaction.promote():
		bulk_chunk_save_load.restore_state(previous_bulk_state)
		mesh_cache_save_load.restore_state(previous_mesh_state)
		save_transaction.abort()
		return false
	current_world_dir = world_dir
	for chunk in world.chunks.values():
		var entry: ChunkData = chunk
		entry.dirty = false
	return true
#endregion


#region Load
func load_world(path: String) -> bool:
	var load_start_usec: int = Time.get_ticks_usec()
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


func _save_workers(world_dir: String) -> bool:
	return worker_save_load.save_workers(world, world_dir)
#endregion
