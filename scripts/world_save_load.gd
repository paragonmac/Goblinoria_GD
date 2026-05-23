extends RefCounted
class_name WorldSaveLoad
## Handles world save/load and serialization.

#region Preloads
const WorldInventorySaveLoadScript = preload("res://scripts/world_inventory_save_load.gd")
const WorldMetadataSaveLoadScript = preload("res://scripts/world_metadata_save_load.gd")
const WorldBulkChunkSaveLoadScript = preload("res://scripts/world_bulk_chunk_save_load.gd")
const WorldMeshCacheSaveLoadScript = preload("res://scripts/world_mesh_cache_save_load.gd")
#endregion

#region Constants
const CHUNK_MAGIC := 0x43484B53
const SAVE_VERSION := 3
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
var metadata_save_load = WorldMetadataSaveLoadScript.new()
var bulk_chunk_save_load = WorldBulkChunkSaveLoadScript.new()
var mesh_cache_save_load = WorldMeshCacheSaveLoadScript.new()
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
	if not _save_inventory(world_dir):
		return false
	return true
#endregion


#region Load
func load_world(path: String) -> bool:
	last_load_metrics.clear()
	_reset_mesh_cache_stats()
	var load_start_usec: int = Time.get_ticks_usec()
	var world_dir := _world_dir_from_path(path)
	current_world_dir = world_dir
	var meta_start_usec: int = Time.get_ticks_usec()
	if not _read_world_meta(world_dir):
		return false
	last_load_metrics["meta_ms"] = _elapsed_ms(meta_start_usec)
	var bulk_start_usec: int = Time.get_ticks_usec()
	if not _load_bulk_chunks(world_dir):
		return false
	last_load_metrics["bulk_blocks_ms"] = _elapsed_ms(bulk_start_usec)
	var mesh_cache_start_usec: int = Time.get_ticks_usec()
	_load_mesh_cache(world_dir)
	last_load_metrics["mesh_cache_ms"] = _elapsed_ms(mesh_cache_start_usec)
	world.chunks.clear()
	world.chunk_access_tick = 0
	world.reset_streaming_state()
	world.clear_and_respawn_workers()
	if world.renderer != null:
		world.renderer.clear_chunks()
		world.renderer.reset_stats()
	var inventory_start_usec: int = Time.get_ticks_usec()
	_load_inventory(world_dir)
	last_load_metrics["inventory_ms"] = _elapsed_ms(inventory_start_usec)
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


func _load_bulk_chunks(world_dir: String) -> bool:
	var ok := bulk_chunk_save_load.load_bulk_chunks(world, world_dir, _get_block_table_hash())
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
	if version != SAVE_VERSION:
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
	if block_hash != _get_block_table_hash():
		return {}
	return {"data_len": data_len}


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
#endregion