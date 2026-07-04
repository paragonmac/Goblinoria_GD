extends RefCounted
class_name WorldMeshCacheSaveLoad
## Handles optional persistent raw mesh-cache acceleration data.

const WorldChunkSpaceScript = preload("res://scripts/world/world_chunk_space.gd")

#region Constants
const MESH_CACHE_MAGIC := 0x474D4553
const MESH_CACHE_VERSION := 1
const MESH_CACHE_FILE_NAME := "world_mesh_cache.dat"
#endregion

#region State
var pending_mesh_cache_entries: Dictionary = {}
var mesh_cache_stats: Dictionary = {}
#endregion


#region Public API
func clear() -> void:
	pending_mesh_cache_entries.clear()
	reset_stats()


func reset_stats() -> void:
	mesh_cache_stats = {
		"entries_read": 0,
		"entries_pending": 0,
		"entries_imported": 0,
		"entries_rejected": 0,
		"entries_saved": 0,
	}


func get_stats() -> Dictionary:
	return mesh_cache_stats.duplicate()


func save_mesh_cache(world: World, world_dir: String, bulk_chunk_blocks: Dictionary, block_table_hash: int) -> bool:
	if world == null or world.renderer == null:
		return true
	var path := world_dir.path_join(MESH_CACHE_FILE_NAME)
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		push_warning("Mesh cache save skipped: %s" % path)
		return false
	file.store_32(MESH_CACHE_MAGIC)
	file.store_16(MESH_CACHE_VERSION)
	file.store_16(WorldRenderer.MESHER_CACHE_VERSION)
	file.store_16(World.CHUNK_SIZE)
	file.store_16(World.WORLD_CHUNKS_X)
	file.store_16(World.WORLD_CHUNKS_Y)
	file.store_16(World.WORLD_CHUNKS_Z)
	file.store_32(block_table_hash)
	var count_pos: int = file.get_position()
	file.store_32(0)
	var entries_written := 0
	for coord in _build_persistent_mesh_cache_coords(world):
		var blocks: PackedByteArray = _get_blocks_for_coord(world, bulk_chunk_blocks, coord)
		if blocks.size() != World.CHUNK_VOLUME:
			continue
		var mesh_entry: Dictionary = _persistent_mesh_cache_entry_for_coord(world, bulk_chunk_blocks, coord, blocks)
		if mesh_entry.is_empty():
			continue
		file.store_var(mesh_entry, false)
		entries_written += 1
	var end_pos: int = file.get_position()
	file.seek(count_pos)
	file.store_32(entries_written)
	file.seek(end_pos)
	file.flush()
	mesh_cache_stats["entries_saved"] = entries_written
	return true


func load_mesh_cache(world: World, world_dir: String, block_table_hash: int) -> bool:
	clear()
	var path := world_dir.path_join(MESH_CACHE_FILE_NAME)
	if not FileAccess.file_exists(path):
		return true
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		push_warning("Mesh cache ignored: cannot open %s" % path)
		return true
	if file.get_32() != MESH_CACHE_MAGIC:
		push_warning("Mesh cache ignored: bad magic")
		return true
	if file.get_16() != MESH_CACHE_VERSION:
		push_warning("Mesh cache ignored: version mismatch")
		return true
	if file.get_16() != WorldRenderer.MESHER_CACHE_VERSION:
		push_warning("Mesh cache ignored: mesher version mismatch")
		return true
	if file.get_16() != World.CHUNK_SIZE:
		push_warning("Mesh cache ignored: chunk size mismatch")
		return true
	var chunks_x: int = file.get_16()
	var chunks_y: int = file.get_16()
	var chunks_z: int = file.get_16()
	if chunks_x != World.WORLD_CHUNKS_X or chunks_y != World.WORLD_CHUNKS_Y or chunks_z != World.WORLD_CHUNKS_Z:
		push_warning("Mesh cache ignored: world dimensions mismatch")
		return true
	var stored_block_table_hash: int = file.get_32()
	if stored_block_table_hash != block_table_hash:
		push_warning("Mesh cache ignored: block table hash mismatch")
		return true
	var count: int = file.get_32()
	mesh_cache_stats["entries_read"] = count
	for _i in range(count):
		var loaded_entry: Variant = file.get_var(false)
		if typeof(loaded_entry) != TYPE_DICTIONARY:
			push_warning("Mesh cache ignored: malformed entry")
			clear()
			return true
		var entry: Dictionary = loaded_entry
		if not _is_mesh_cache_entry_shape_valid(entry):
			mesh_cache_stats["entries_rejected"] = int(mesh_cache_stats.get("entries_rejected", 0)) + 1
			continue
		var coord := Vector3i(int(entry["cx"]), int(entry["cy"]), int(entry["cz"]))
		if world == null or not world.is_chunk_coord_valid(coord):
			mesh_cache_stats["entries_rejected"] = int(mesh_cache_stats.get("entries_rejected", 0)) + 1
			continue
		pending_mesh_cache_entries[coord] = entry
		mesh_cache_stats["entries_pending"] = int(mesh_cache_stats.get("entries_pending", 0)) + 1
	return true


func try_import_for_loaded_chunk(world: World, bulk_chunk_blocks: Dictionary, coord: Vector3i, chunk: ChunkData) -> void:
	if not pending_mesh_cache_entries.has(coord):
		return
	var entry = pending_mesh_cache_entries[coord]
	pending_mesh_cache_entries.erase(coord)
	if typeof(entry) != TYPE_DICTIONARY:
		mesh_cache_stats["entries_rejected"] = int(mesh_cache_stats.get("entries_rejected", 0)) + 1
		return
	var typed_entry: Dictionary = entry
	if not _is_mesh_cache_entry_valid_for_chunk(world, bulk_chunk_blocks, coord, chunk, typed_entry):
		mesh_cache_stats["entries_rejected"] = int(mesh_cache_stats.get("entries_rejected", 0)) + 1
		return
	if world == null or world.renderer == null:
		return
	if world.renderer.import_persistent_mesh_cache_entry(coord, typed_entry):
		mesh_cache_stats["entries_imported"] = int(mesh_cache_stats.get("entries_imported", 0)) + 1
	else:
		mesh_cache_stats["entries_rejected"] = int(mesh_cache_stats.get("entries_rejected", 0)) + 1
#endregion


#region Entry Building
func _build_persistent_mesh_cache_coords(world: World) -> Array[Vector3i]:
	var coords: Array[Vector3i] = []
	if world == null:
		return coords
	return WorldChunkSpaceScript.all_world_chunk_targets()


func _persistent_mesh_cache_entry_for_coord(world: World, bulk_chunk_blocks: Dictionary, coord: Vector3i, blocks: PackedByteArray) -> Dictionary:
	if world == null or world.renderer == null:
		return {}
	var mesh_entry: Dictionary = world.renderer.export_persistent_mesh_cache_entry(coord, _mesh_cache_full_local_top())
	if mesh_entry.is_empty() and pending_mesh_cache_entries.has(coord):
		var pending_entry = pending_mesh_cache_entries[coord]
		if typeof(pending_entry) == TYPE_DICTIONARY and _is_mesh_cache_entry_shape_valid(pending_entry) and _is_mesh_cache_entry_valid_for_blocks(world, bulk_chunk_blocks, coord, blocks, pending_entry):
			mesh_entry = pending_entry.duplicate(true)
	if mesh_entry.is_empty():
		return {}
	mesh_entry["cx"] = coord.x
	mesh_entry["cy"] = coord.y
	mesh_entry["cz"] = coord.z
	mesh_entry["block_hash"] = _hash_block_buffer(blocks)
	mesh_entry["neighbor_hashes"] = _build_neighbor_hashes(world, bulk_chunk_blocks, coord)
	return mesh_entry
#endregion


#region Validation
func _mesh_cache_full_local_top() -> int:
	return World.CHUNK_SIZE - 1


func _is_mesh_cache_entry_shape_valid(entry: Dictionary) -> bool:
	if not entry.has("cx") or not entry.has("cy") or not entry.has("cz"):
		return false
	if int(entry.get("local_top", -1)) != _mesh_cache_full_local_top():
		return false
	if not entry.has("block_hash"):
		return false
	if not entry.has("neighbor_hashes"):
		return false
	if not entry.has("has_geometry"):
		return false
	return true


func _is_mesh_cache_entry_valid_for_chunk(world: World, bulk_chunk_blocks: Dictionary, coord: Vector3i, chunk: ChunkData, entry: Dictionary) -> bool:
	return _is_mesh_cache_entry_valid_for_blocks(world, bulk_chunk_blocks, coord, chunk.blocks, entry)


func _is_mesh_cache_entry_valid_for_blocks(world: World, bulk_chunk_blocks: Dictionary, coord: Vector3i, blocks: PackedByteArray, entry: Dictionary) -> bool:
	if int(entry.get("local_top", -1)) != _mesh_cache_full_local_top():
		return false
	if _hash_block_buffer(blocks) != int(entry.get("block_hash", -1)):
		return false
	var expected_neighbors = entry.get("neighbor_hashes", {})
	if typeof(expected_neighbors) != TYPE_DICTIONARY:
		return false
	var actual_neighbors: Dictionary = _build_neighbor_hashes(world, bulk_chunk_blocks, coord)
	for key in expected_neighbors.keys():
		if int(expected_neighbors[key]) != int(actual_neighbors.get(key, -2)):
			return false
	return true
#endregion


#region Hashing
func _build_neighbor_hashes(world: World, bulk_chunk_blocks: Dictionary, coord: Vector3i) -> Dictionary:
	return {
		"x_neg": _hash_blocks_for_coord_or_missing(world, bulk_chunk_blocks, Vector3i(coord.x - 1, coord.y, coord.z)),
		"x_pos": _hash_blocks_for_coord_or_missing(world, bulk_chunk_blocks, Vector3i(coord.x + 1, coord.y, coord.z)),
		"y_neg": _hash_blocks_for_coord_or_missing(world, bulk_chunk_blocks, Vector3i(coord.x, coord.y - 1, coord.z)),
		"y_pos": _hash_blocks_for_coord_or_missing(world, bulk_chunk_blocks, Vector3i(coord.x, coord.y + 1, coord.z)),
		"z_neg": _hash_blocks_for_coord_or_missing(world, bulk_chunk_blocks, Vector3i(coord.x, coord.y, coord.z - 1)),
		"z_pos": _hash_blocks_for_coord_or_missing(world, bulk_chunk_blocks, Vector3i(coord.x, coord.y, coord.z + 1)),
	}


func _hash_blocks_for_coord_or_missing(world: World, bulk_chunk_blocks: Dictionary, coord: Vector3i) -> int:
	if world == null or not world.is_chunk_coord_valid(coord):
		return -1
	var blocks: PackedByteArray = _get_blocks_for_coord(world, bulk_chunk_blocks, coord)
	if blocks.size() != World.CHUNK_VOLUME:
		return -1
	return _hash_block_buffer(blocks)


func _get_blocks_for_coord(world: World, bulk_chunk_blocks: Dictionary, coord: Vector3i) -> PackedByteArray:
	if bulk_chunk_blocks.has(coord):
		var blocks = bulk_chunk_blocks[coord]
		if typeof(blocks) == TYPE_PACKED_BYTE_ARRAY:
			return PackedByteArray(blocks)
	if world != null:
		var chunk: ChunkData = world.get_chunk(coord)
		if chunk != null and chunk.generated:
			return chunk.blocks
	return PackedByteArray()


func _hash_block_buffer(blocks: PackedByteArray) -> int:
	var hash_value: int = 2166136261
	for value in blocks:
		hash_value = int((hash_value ^ int(value)) * 16777619) & 0xffffffff
	return hash_value
#endregion
