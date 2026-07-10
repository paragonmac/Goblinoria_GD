extends RefCounted
class_name WorldSaveLoad
## Handles world save/load and serialization.

#region Preloads
const WorldInventorySaveLoadScript = preload("res://scripts/world_inventory_save_load.gd")
const WorldItemStockpileSaveLoadScript = preload("res://scripts/world_item_stockpile_save_load.gd")
const WorldMetadataSaveLoadScript = preload("res://scripts/world_metadata_save_load.gd")
const WorldBulkChunkSaveLoadScript = preload("res://scripts/world_bulk_chunk_save_load.gd")
const WorldMeshCacheSaveLoadScript = preload("res://scripts/world_mesh_cache_save_load.gd")
const WorldGenerationSharedScript = preload("res://scripts/world/world_generation_shared.gd")
const WorldTerrainHeightSamplerScript = preload("res://scripts/world/world_terrain_height_sampler.gd")
const WorldRampRulesScript = preload("res://scripts/world/world_ramp_rules.gd")
#endregion

#region Constants
const CHUNK_MAGIC := 0x43484B53
const SAVE_VERSION := 5
const LEGACY_SAVE_VERSION := 4
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
	current_world_dir = world_dir
	var chunk_dir := _chunk_dir_path(world_dir)
	var dir_ok := DirAccess.make_dir_recursive_absolute(chunk_dir)
	if dir_ok != OK:
		push_error("World save failed: %s" % world_dir)
		return false
	if not _write_world_meta(world_dir):
		return false
	if not _save_bulk_chunks(world_dir):
		return false
	_save_mesh_cache(world_dir)
	for chunk in world.chunks.values():
		var entry: ChunkData = chunk
		entry.dirty = false
	if not _save_items_and_stockpiles(world_dir):
		return false
	return true
#endregion


#region Load
func load_world(path: String) -> bool:
	last_load_metrics.clear()
	legacy_terrain_slope_migration = false
	_reset_mesh_cache_stats()
	var load_start_usec: int = Time.get_ticks_usec()
	var world_dir := _world_dir_from_path(path)
	var meta_start_usec: int = Time.get_ticks_usec()
	var meta_snapshot := metadata_save_load.read_world_meta_snapshot(
		world,
		world_dir,
		SAVE_VERSION,
		_get_block_table_hash(),
		LEGACY_SAVE_VERSION,
		true
	)
	if not bool(meta_snapshot.get("ok", false)):
		return false
	last_load_metrics["meta_ms"] = _elapsed_ms(meta_start_usec)
	var item_start_usec: int = Time.get_ticks_usec()
	var item_snapshot := item_stockpile_save_load.read_snapshot(world_dir)
	if not bool(item_snapshot.get("ok", false)):
		return false
	last_load_metrics["items_stockpiles_ms"] = _elapsed_ms(item_start_usec)
	var previous_bulk_state := bulk_chunk_save_load.snapshot_state()
	var bulk_start_usec: int = Time.get_ticks_usec()
	legacy_terrain_slope_migration = bool(meta_snapshot.get("legacy_block_table", false))
	if not _load_bulk_chunks(world_dir, legacy_terrain_slope_migration):
		bulk_chunk_save_load.restore_state(previous_bulk_state)
		legacy_terrain_slope_migration = false
		return false
	if legacy_terrain_slope_migration:
		var migrated_slopes := _migrate_legacy_terrain_slopes(int(meta_snapshot.get("world_seed", 0)))
		last_load_metrics["migrated_terrain_slopes"] = migrated_slopes
	last_load_metrics["bulk_blocks_ms"] = _elapsed_ms(bulk_start_usec)
	current_world_dir = world_dir
	var mesh_cache_start_usec: int = Time.get_ticks_usec()
	_load_mesh_cache(world_dir)
	last_load_metrics["mesh_cache_ms"] = _elapsed_ms(mesh_cache_start_usec)
	metadata_save_load.apply_world_meta(world, meta_snapshot)
	world.chunks.clear()
	world.chunk_access_tick = 0
	world.reset_streaming_state()
	world.clear_and_respawn_workers()
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
	var header := _read_chunk_header(file, coord)
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


func _load_bulk_chunks(world_dir: String, allow_legacy_block_table_hash: bool = false) -> bool:
	var ok := bulk_chunk_save_load.load_bulk_chunks(
		world,
		world_dir,
		_get_block_table_hash(),
		allow_legacy_block_table_hash
	)
	if ok:
		var stats := bulk_chunk_save_load.get_last_load_stats()
		if not stats.is_empty():
			last_load_metrics["bulk_block_format"] = stats
	return ok


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


func _read_chunk_header(file: FileAccess, coord: Vector3i) -> Dictionary:
	var magic: int = file.get_32()
	if magic != CHUNK_MAGIC:
		return {}
	var version: int = file.get_16()
	if version != SAVE_VERSION and not (legacy_terrain_slope_migration and version == LEGACY_SAVE_VERSION):
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
	if block_hash != _get_block_table_hash() and not legacy_terrain_slope_migration:
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


func _save_inventory(world_dir: String) -> bool:
	return inventory_save_load.save_inventory(world, world_dir)


func _load_inventory(world_dir: String) -> bool:
	return inventory_save_load.load_inventory(world, world_dir)


func _save_items_and_stockpiles(world_dir: String) -> bool:
	return item_stockpile_save_load.save_items_and_stockpiles(world, world_dir)


func _load_items_and_stockpiles(world_dir: String) -> bool:
	return item_stockpile_save_load.load_items_and_stockpiles(world, world_dir)
#endregion
