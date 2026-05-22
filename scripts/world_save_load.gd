extends RefCounted
class_name WorldSaveLoad
## Handles world save/load and serialization.

#region Preloads
const WorldInventorySaveLoadScript = preload("res://scripts/world_inventory_save_load.gd")
#endregion

#region Constants
const META_MAGIC := 0x474D4554
const CHUNK_MAGIC := 0x43484B53
const BULK_CHUNKS_MAGIC := 0x474D4150
const MESH_CACHE_MAGIC := 0x474D4553
const SAVE_VERSION := 3
const BULK_CHUNKS_VERSION := 2
const BULK_CHUNKS_LEGACY_RAW_VERSION := 3
const MESH_CACHE_VERSION := 1
const META_FILE_NAME := "world_meta.dat"
const BULK_CHUNKS_FILE_NAME := "world_blocks.dat"
const MESH_CACHE_FILE_NAME := "world_mesh_cache.dat"
const CHUNK_DIR_NAME := "chunks"
const CHUNK_FILE_EXT := ".chunk"
const COMPRESSION_NONE := 0
const COMPRESSION_ZSTD := FileAccess.COMPRESSION_ZSTD
const BULK_ENTRY_RAW := 0
const BULK_ENTRY_FILL := 1
const BULK_ENTRY_COMPRESSED := 2
const STARTUP_MESH_CACHE_BAND_RADIUS := 1
#endregion

#region State
var world: World
var current_world_dir := ""
var warned_missing_world_dir: bool = false
var bulk_chunk_blocks: Dictionary = {}
var bulk_chunks_loaded: bool = false
var pending_mesh_cache_entries: Dictionary = {}
var last_load_metrics: Dictionary = {}
var mesh_cache_stats: Dictionary = {}
var inventory_save_load = WorldInventorySaveLoadScript.new()
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
	if bulk_chunks_loaded:
		if not bulk_chunk_blocks.has(coord):
			return false
		var blocks = bulk_chunk_blocks[coord]
		if typeof(blocks) != TYPE_PACKED_BYTE_ARRAY:
			return false
		chunk.blocks = PackedByteArray(blocks).duplicate()
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
	var entries := {}
	for key in bulk_chunk_blocks.keys():
		var coord: Vector3i = key
		var blocks = bulk_chunk_blocks[coord]
		if typeof(blocks) != TYPE_PACKED_BYTE_ARRAY:
			continue
		if world.is_chunk_coord_valid(coord) and blocks.size() == World.CHUNK_VOLUME:
			entries[coord] = blocks
	for key in world.chunks.keys():
		var coord: Vector3i = key
		var chunk: ChunkData = world.chunks[coord]
		if not chunk.generated:
			continue
		if chunk.blocks.size() != World.CHUNK_VOLUME:
			continue
		entries[coord] = chunk.blocks.duplicate()

	var path := world_dir.path_join(BULK_CHUNKS_FILE_NAME)
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		push_warning("World bulk save failed: %s" % path)
		return false
	file.store_32(BULK_CHUNKS_MAGIC)
	file.store_16(BULK_CHUNKS_VERSION)
	file.store_16(World.CHUNK_SIZE)
	file.store_16(World.WORLD_CHUNKS_X)
	file.store_16(World.WORLD_CHUNKS_Y)
	file.store_16(World.WORLD_CHUNKS_Z)
	file.store_32(World.CHUNK_VOLUME)
	file.store_32(_get_block_table_hash())
	file.store_32(entries.size())
	for key in entries.keys():
		var coord: Vector3i = key
		var blocks = entries[coord]
		if typeof(blocks) != TYPE_PACKED_BYTE_ARRAY:
			continue
		_write_bulk_chunk_entry(file, coord, PackedByteArray(blocks))
	file.flush()
	bulk_chunk_blocks = entries
	bulk_chunks_loaded = true
	return true


func _load_bulk_chunks(world_dir: String) -> bool:
	_clear_bulk_chunk_cache()
	var path := world_dir.path_join(BULK_CHUNKS_FILE_NAME)
	if not FileAccess.file_exists(path):
		return true
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		push_warning("World load failed: cannot open %s" % path)
		return false
	if file.get_32() != BULK_CHUNKS_MAGIC:
		push_warning("World load failed: bad bulk map magic")
		return false
	var bulk_version: int = file.get_16()
	if bulk_version != BULK_CHUNKS_VERSION and bulk_version != BULK_CHUNKS_LEGACY_RAW_VERSION:
		push_warning("World load failed: bulk map version mismatch")
		return false
	if file.get_16() != World.CHUNK_SIZE:
		push_warning("World load failed: bulk map chunk size mismatch")
		return false
	var chunks_x: int = file.get_16()
	var chunks_y: int = file.get_16()
	var chunks_z: int = file.get_16()
	if chunks_x != World.WORLD_CHUNKS_X or chunks_y != World.WORLD_CHUNKS_Y or chunks_z != World.WORLD_CHUNKS_Z:
		push_warning("World load failed: bulk map dimensions mismatch")
		return false
	var chunk_volume: int = file.get_32()
	if chunk_volume != World.CHUNK_VOLUME:
		push_warning("World load failed: bulk map chunk volume mismatch")
		return false
	var block_hash: int = file.get_32()
	if block_hash != _get_block_table_hash():
		push_warning("World load failed: bulk map block table hash mismatch")
		return false
	var count: int = file.get_32()
	var stats := _new_bulk_load_stats(bulk_version, count)
	for _i in range(count):
		var entry := _read_bulk_chunk_entry(file, bulk_version, chunk_volume)
		if entry.is_empty():
			_clear_bulk_chunk_cache()
			return false
		_update_bulk_load_stats(stats, entry)
		var coord_value = entry["coord"]
		var blocks_value = entry["blocks"]
		if typeof(coord_value) != TYPE_VECTOR3I or typeof(blocks_value) != TYPE_PACKED_BYTE_ARRAY:
			push_warning("World load failed: malformed bulk map entry")
			_clear_bulk_chunk_cache()
			return false
		var coord: Vector3i = coord_value
		var blocks: PackedByteArray = PackedByteArray(blocks_value)
		if blocks.size() != chunk_volume:
			push_warning("World load failed: bad bulk map chunk size")
			_clear_bulk_chunk_cache()
			return false
		if world.is_chunk_coord_valid(coord):
			bulk_chunk_blocks[coord] = blocks
	bulk_chunks_loaded = true
	last_load_metrics["bulk_block_format"] = stats
	return true


func _write_bulk_chunk_entry(file: FileAccess, coord: Vector3i, blocks: PackedByteArray) -> void:
	_store_signed_32(file, coord.x)
	_store_signed_32(file, coord.y)
	_store_signed_32(file, coord.z)
	var fill_id: int = _uniform_block_id(blocks)
	if fill_id >= 0:
		file.store_8(BULK_ENTRY_FILL)
		file.store_16(fill_id)
		file.store_8(COMPRESSION_NONE)
		file.store_32(0)
		file.store_32(blocks.size())
		return
	var payload := blocks
	var entry_kind: int = BULK_ENTRY_RAW
	var compression: int = COMPRESSION_NONE
	var compressed := blocks.compress(COMPRESSION_ZSTD)
	if compressed.size() > 0 and compressed.size() < blocks.size():
		payload = compressed
		entry_kind = BULK_ENTRY_COMPRESSED
		compression = COMPRESSION_ZSTD
	file.store_8(entry_kind)
	file.store_16(0)
	file.store_8(compression)
	file.store_32(payload.size())
	file.store_32(blocks.size())
	file.store_buffer(payload)


func _read_bulk_chunk_entry(file: FileAccess, bulk_version: int, chunk_volume: int) -> Dictionary:
	var coord := Vector3i(_read_signed_32(file), _read_signed_32(file), _read_signed_32(file))
	if bulk_version == BULK_CHUNKS_LEGACY_RAW_VERSION:
		var legacy_blocks := file.get_buffer(chunk_volume)
		if legacy_blocks.size() != chunk_volume:
			push_warning("World load failed: truncated legacy bulk map chunk")
			return {}
		return {
			"coord": coord,
			"blocks": legacy_blocks,
			"kind": BULK_ENTRY_RAW,
			"stored_len": legacy_blocks.size(),
			"uncompressed_len": legacy_blocks.size(),
		}
	var entry_kind: int = file.get_8()
	var fill_id: int = file.get_16()
	var compression: int = file.get_8()
	var stored_len: int = file.get_32()
	var uncompressed_len: int = file.get_32()
	if uncompressed_len != chunk_volume:
		push_warning("World load failed: bulk chunk length mismatch")
		return {}
	var blocks := PackedByteArray()
	match entry_kind:
		BULK_ENTRY_FILL:
			if stored_len != 0 or compression != COMPRESSION_NONE:
				push_warning("World load failed: malformed fill chunk")
				return {}
			blocks.resize(chunk_volume)
			blocks.fill(fill_id)
		BULK_ENTRY_RAW:
			if stored_len != chunk_volume or compression != COMPRESSION_NONE:
				push_warning("World load failed: malformed raw chunk")
				return {}
			blocks = file.get_buffer(stored_len)
			if blocks.size() != stored_len:
				push_warning("World load failed: truncated raw bulk chunk")
				return {}
		BULK_ENTRY_COMPRESSED:
			if stored_len <= 0 or not _is_supported_bulk_compression(compression):
				push_warning("World load failed: unsupported compressed bulk chunk")
				return {}
			var payload := file.get_buffer(stored_len)
			if payload.size() != stored_len:
				push_warning("World load failed: truncated compressed bulk chunk")
				return {}
			blocks = payload.decompress(uncompressed_len, compression)
			if blocks.size() != chunk_volume:
				push_warning("World load failed: compressed bulk chunk did not decompress")
				return {}
		_:
			push_warning("World load failed: unknown bulk chunk entry type")
			return {}
	return {
		"coord": coord,
		"blocks": blocks,
		"kind": entry_kind,
		"stored_len": stored_len,
		"uncompressed_len": uncompressed_len,
	}


func _uniform_block_id(blocks: PackedByteArray) -> int:
	if blocks.is_empty():
		return -1
	var first_id: int = int(blocks[0])
	for block_id in blocks:
		if int(block_id) != first_id:
			return -1
	return first_id


func _is_supported_bulk_compression(compression: int) -> bool:
	return compression == COMPRESSION_ZSTD


func _new_bulk_load_stats(bulk_version: int, count: int) -> Dictionary:
	return {
		"version": bulk_version,
		"entries": count,
		"fill_entries": 0,
		"raw_entries": 0,
		"compressed_entries": 0,
		"stored_bytes": 0,
		"uncompressed_bytes": 0,
	}


func _update_bulk_load_stats(stats: Dictionary, entry: Dictionary) -> void:
	var kind: int = int(entry.get("kind", BULK_ENTRY_RAW))
	match kind:
		BULK_ENTRY_FILL:
			stats["fill_entries"] = int(stats.get("fill_entries", 0)) + 1
		BULK_ENTRY_COMPRESSED:
			stats["compressed_entries"] = int(stats.get("compressed_entries", 0)) + 1
		_:
			stats["raw_entries"] = int(stats.get("raw_entries", 0)) + 1
	stats["stored_bytes"] = int(stats.get("stored_bytes", 0)) + int(entry.get("stored_len", 0))
	stats["uncompressed_bytes"] = int(stats.get("uncompressed_bytes", 0)) + int(entry.get("uncompressed_len", 0))


func _remember_bulk_chunk(coord: Vector3i, chunk: ChunkData) -> void:
	if not world.is_chunk_coord_valid(coord):
		return
	if not chunk.generated or chunk.blocks.size() != World.CHUNK_VOLUME:
		return
	bulk_chunk_blocks[coord] = chunk.blocks.duplicate()


func _clear_bulk_chunk_cache() -> void:
	bulk_chunk_blocks.clear()
	bulk_chunks_loaded = false


func _save_mesh_cache(world_dir: String) -> bool:
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
	file.store_32(_get_block_table_hash())
	var count_pos: int = file.get_position()
	file.store_32(0)
	var entries_written := 0
	for coord in _build_persistent_mesh_cache_coords():
		var blocks: PackedByteArray = _get_blocks_for_coord(coord)
		if blocks.size() != World.CHUNK_VOLUME:
			continue
		var mesh_entry: Dictionary = _persistent_mesh_cache_entry_for_coord(coord, blocks)
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


func _load_mesh_cache(world_dir: String) -> bool:
	_clear_mesh_cache_entries()
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
	var block_table_hash: int = file.get_32()
	if block_table_hash != _get_block_table_hash():
		push_warning("Mesh cache ignored: block table hash mismatch")
		return true
	var count: int = file.get_32()
	mesh_cache_stats["entries_read"] = count
	for _i in range(count):
		var loaded_entry: Variant = file.get_var(false)
		if typeof(loaded_entry) != TYPE_DICTIONARY:
			push_warning("Mesh cache ignored: malformed entry")
			_clear_mesh_cache_entries()
			return true
		var entry = loaded_entry
		if not _is_mesh_cache_entry_shape_valid(entry):
			mesh_cache_stats["entries_rejected"] = int(mesh_cache_stats.get("entries_rejected", 0)) + 1
			continue
		var coord := Vector3i(int(entry["cx"]), int(entry["cy"]), int(entry["cz"]))
		if not world.is_chunk_coord_valid(coord):
			mesh_cache_stats["entries_rejected"] = int(mesh_cache_stats.get("entries_rejected", 0)) + 1
			continue
		pending_mesh_cache_entries[coord] = entry
		mesh_cache_stats["entries_pending"] = int(mesh_cache_stats.get("entries_pending", 0)) + 1
	return true


func _try_import_mesh_cache_for_loaded_chunk(coord: Vector3i, chunk: ChunkData) -> void:
	if not pending_mesh_cache_entries.has(coord):
		return
	var entry = pending_mesh_cache_entries[coord]
	pending_mesh_cache_entries.erase(coord)
	if not _is_mesh_cache_entry_valid_for_chunk(coord, chunk, entry):
		mesh_cache_stats["entries_rejected"] = int(mesh_cache_stats.get("entries_rejected", 0)) + 1
		return
	if world.renderer == null:
		return
	if world.renderer.import_persistent_mesh_cache_entry(coord, entry):
		mesh_cache_stats["entries_imported"] = int(mesh_cache_stats.get("entries_imported", 0)) + 1
	else:
		mesh_cache_stats["entries_rejected"] = int(mesh_cache_stats.get("entries_rejected", 0)) + 1


func _build_persistent_mesh_cache_coords() -> Array[Vector3i]:
	var coords: Array[Vector3i] = []
	for cy: int in range(World.WORLD_CHUNKS_Y):
		for cx: int in range(World.WORLD_MIN_CHUNK_X, World.WORLD_MAX_CHUNK_X + 1):
			for cz: int in range(World.WORLD_MIN_CHUNK_Z, World.WORLD_MAX_CHUNK_Z + 1):
				var coord := Vector3i(cx, cy, cz)
				if world.is_chunk_coord_valid(coord):
					coords.append(coord)
	return coords


func _persistent_mesh_cache_entry_for_coord(coord: Vector3i, blocks: PackedByteArray) -> Dictionary:
	var mesh_entry: Dictionary = world.renderer.export_persistent_mesh_cache_entry(coord, _mesh_cache_full_local_top())
	if mesh_entry.is_empty() and pending_mesh_cache_entries.has(coord):
		var pending_entry = pending_mesh_cache_entries[coord]
		if typeof(pending_entry) == TYPE_DICTIONARY and _is_mesh_cache_entry_shape_valid(pending_entry) and _is_mesh_cache_entry_valid_for_blocks(coord, blocks, pending_entry):
			mesh_entry = pending_entry.duplicate(true)
	if mesh_entry.is_empty():
		return {}
	mesh_entry["cx"] = coord.x
	mesh_entry["cy"] = coord.y
	mesh_entry["cz"] = coord.z
	mesh_entry["block_hash"] = _hash_block_buffer(blocks)
	mesh_entry["neighbor_hashes"] = _build_neighbor_hashes(coord)
	return mesh_entry


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


func _is_mesh_cache_entry_valid_for_chunk(coord: Vector3i, chunk: ChunkData, entry: Dictionary) -> bool:
	return _is_mesh_cache_entry_valid_for_blocks(coord, chunk.blocks, entry)


func _is_mesh_cache_entry_valid_for_blocks(coord: Vector3i, blocks: PackedByteArray, entry: Dictionary) -> bool:
	if int(entry.get("local_top", -1)) != _mesh_cache_full_local_top():
		return false
	if _hash_block_buffer(blocks) != int(entry.get("block_hash", -1)):
		return false
	var expected_neighbors = entry.get("neighbor_hashes", {})
	if typeof(expected_neighbors) != TYPE_DICTIONARY:
		return false
	var actual_neighbors: Dictionary = _build_neighbor_hashes(coord)
	for key in expected_neighbors.keys():
		if int(expected_neighbors[key]) != int(actual_neighbors.get(key, -2)):
			return false
	return true


func _build_neighbor_hashes(coord: Vector3i) -> Dictionary:
	return {
		"x_neg": _hash_blocks_for_coord_or_missing(Vector3i(coord.x - 1, coord.y, coord.z)),
		"x_pos": _hash_blocks_for_coord_or_missing(Vector3i(coord.x + 1, coord.y, coord.z)),
		"y_neg": _hash_blocks_for_coord_or_missing(Vector3i(coord.x, coord.y - 1, coord.z)),
		"y_pos": _hash_blocks_for_coord_or_missing(Vector3i(coord.x, coord.y + 1, coord.z)),
		"z_neg": _hash_blocks_for_coord_or_missing(Vector3i(coord.x, coord.y, coord.z - 1)),
		"z_pos": _hash_blocks_for_coord_or_missing(Vector3i(coord.x, coord.y, coord.z + 1)),
	}


func _hash_blocks_for_coord_or_missing(coord: Vector3i) -> int:
	if not world.is_chunk_coord_valid(coord):
		return -1
	var blocks: PackedByteArray = _get_blocks_for_coord(coord)
	if blocks.size() != World.CHUNK_VOLUME:
		return -1
	return _hash_block_buffer(blocks)


func _get_blocks_for_coord(coord: Vector3i) -> PackedByteArray:
	if bulk_chunk_blocks.has(coord):
		var blocks = bulk_chunk_blocks[coord]
		if typeof(blocks) == TYPE_PACKED_BYTE_ARRAY:
			return PackedByteArray(blocks)
	var chunk: ChunkData = world.get_chunk(coord)
	if chunk != null and chunk.generated:
		return chunk.blocks
	return PackedByteArray()


func _hash_block_buffer(blocks: PackedByteArray) -> int:
	var hash_value: int = 2166136261
	for value in blocks:
		hash_value = int((hash_value ^ int(value)) * 16777619) & 0xffffffff
	return hash_value


func _clear_mesh_cache_entries() -> void:
	pending_mesh_cache_entries.clear()
	_reset_mesh_cache_stats()


func _reset_mesh_cache_stats() -> void:
	mesh_cache_stats = {
		"entries_read": 0,
		"entries_pending": 0,
		"entries_imported": 0,
		"entries_rejected": 0,
		"entries_saved": 0,
	}


func get_last_load_metrics() -> Dictionary:
	var metrics := last_load_metrics.duplicate()
	metrics["mesh_cache"] = mesh_cache_stats.duplicate()
	return metrics


func _elapsed_ms(start_usec: int) -> float:
	return float(Time.get_ticks_usec() - start_usec) / 1000.0


func _write_world_meta(world_dir: String) -> bool:
	var path := world_dir.path_join(META_FILE_NAME)
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		push_warning("World meta save failed: %s" % path)
		return false
	file.store_32(META_MAGIC)
	file.store_16(SAVE_VERSION)
	file.store_16(World.CHUNK_SIZE)
	file.store_16(World.WORLD_CHUNKS_X)
	file.store_16(World.WORLD_CHUNKS_Y)
	file.store_16(World.WORLD_CHUNKS_Z)
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
	var chunks_x: int = file.get_16()
	var chunks_y: int = file.get_16()
	var chunks_z: int = file.get_16()
	if chunks_x != World.WORLD_CHUNKS_X or chunks_y != World.WORLD_CHUNKS_Y or chunks_z != World.WORLD_CHUNKS_Z:
		push_warning("World load failed: world dimensions mismatch")
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