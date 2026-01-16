extends RefCounted
class_name WorldSaveLoad
## Handles world save/load and serialization.

#region Constants
const META_MAGIC := 0x474D4554
const CHUNK_MAGIC := 0x43484B53
const SAVE_VERSION := 2
const META_FILE_NAME := "world_meta.dat"
const CHUNK_DIR_NAME := "chunks"
const CHUNK_FILE_EXT := ".chunk"
const COMPRESSION_NONE := 0
#endregion

#region State
var world: World
var current_world_dir := ""
var warned_missing_world_dir: bool = false
#endregion


#region Initialization
func _init(world_ref: World) -> void:
	world = world_ref
#endregion


#region Save
func clear_world_dir() -> void:
	current_world_dir = ""
	warned_missing_world_dir = false


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
	for key in world.chunks.keys():
		var coord: Vector3i = key
		var chunk: ChunkData = world.chunks[coord]
		if not chunk.dirty:
			continue
		if not save_chunk(world_dir, coord, chunk):
			return false
		chunk.dirty = false
	return true
#endregion


#region Load
func load_world(path: String) -> bool:
	var world_dir := _world_dir_from_path(path)
	current_world_dir = world_dir
	if not _read_world_meta(world_dir):
		return false
	world.chunks.clear()
	world.chunk_access_tick = 0
	world.reset_streaming_state()
	world.clear_and_respawn_workers()
	if world.renderer != null:
		world.renderer.clear_chunks()
		world.renderer.reset_stats()
	return true


func load_chunk_into(coord: Vector3i, chunk: ChunkData) -> bool:
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
	return true


func save_chunk_current(coord: Vector3i, chunk: ChunkData) -> bool:
	if current_world_dir.is_empty():
		if not warned_missing_world_dir:
			push_warning("Chunk save skipped: no world directory set.")
			warned_missing_world_dir = true
		return false
	return save_chunk(current_world_dir, coord, chunk)
#endregion


#region Helpers
func save_chunk(world_dir: String, coord: Vector3i, chunk: ChunkData) -> bool:
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


func _write_world_meta(world_dir: String) -> bool:
	var path := world_dir.path_join(META_FILE_NAME)
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		push_warning("World meta save failed: %s" % path)
		return false
	file.store_32(META_MAGIC)
	file.store_16(SAVE_VERSION)
	file.store_16(World.CHUNK_SIZE)
	file.store_32(world.world_size_y)
	file.store_64(world.world_seed)
	file.store_32(world.spawn_coord.x)
	file.store_32(world.spawn_coord.y)
	file.store_32(world.spawn_coord.z)
	file.store_32(world.top_render_y)
	file.store_32(_get_block_table_hash())
	file.flush()
	return true


func _read_world_meta(world_dir: String) -> bool:
	var path := world_dir.path_join(META_FILE_NAME)
	if not FileAccess.file_exists(path):
		push_warning("World load failed: missing %s" % path)
		return false
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		push_warning("World load failed: cannot open %s" % path)
		return false
	var magic: int = file.get_32()
	if magic != META_MAGIC:
		push_warning("World load failed: bad meta magic")
		return false
	var version: int = file.get_16()
	if version != SAVE_VERSION:
		push_warning("World load failed: version %d != %d" % [version, SAVE_VERSION])
		return false
	var chunk_size: int = file.get_16()
	if chunk_size != World.CHUNK_SIZE:
		push_warning("World load failed: chunk size mismatch")
		return false
	var world_size_y: int = file.get_32()
	if world_size_y != world.world_size_y:
		push_warning("World load failed: height mismatch")
		return false
	var seed: int = int(file.get_64())
	var spawn_x: int = file.get_32()
	var spawn_y: int = file.get_32()
	var spawn_z: int = file.get_32()
	var top_y: int = file.get_32()
	var block_hash: int = file.get_32()
	if block_hash != _get_block_table_hash():
		push_warning("World load failed: block table hash mismatch")
		return false
	world.world_seed = seed
	world.spawn_coord = Vector3i(spawn_x, spawn_y, spawn_z)
	world.sea_level = max(world.world_size_y - World.SEA_LEVEL_DEPTH, World.SEA_LEVEL_MIN)
	world.top_render_y = clampi(top_y, 0, world.world_size_y - 1)
	return true


func _write_chunk_header(file: FileAccess, coord: Vector3i, data_len: int, block_hash: int) -> void:
	file.store_32(CHUNK_MAGIC)
	file.store_16(SAVE_VERSION)
	file.store_16(World.CHUNK_SIZE)
	file.store_32(coord.x)
	file.store_32(coord.y)
	file.store_32(coord.z)
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
	var cx: int = file.get_32()
	var cy: int = file.get_32()
	var cz: int = file.get_32()
	if cx != coord.x or cy != coord.y or cz != coord.z:
		return {}
	var data_len: int = file.get_32()
	var compression: int = file.get_8()
	if compression != COMPRESSION_NONE:
		return {}
	var block_hash: int = file.get_32()
	if block_hash != _get_block_table_hash():
		return {}
	return {"data_len": data_len}


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
#endregion
