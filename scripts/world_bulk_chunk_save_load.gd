extends RefCounted
class_name WorldBulkChunkSaveLoad
## Handles finite-world bulk block persistence through world_blocks.dat.

#region Constants
const BULK_CHUNKS_MAGIC := 0x474D4150
const BULK_CHUNKS_VERSION := 2
const BULK_CHUNKS_LEGACY_RAW_VERSION := 3
const BULK_CHUNKS_FILE_NAME := "world_blocks.dat"
const COMPRESSION_NONE := 0
const COMPRESSION_ZSTD := FileAccess.COMPRESSION_ZSTD
const BULK_ENTRY_RAW := 0
const BULK_ENTRY_FILL := 1
const BULK_ENTRY_COMPRESSED := 2
#endregion

#region State
var bulk_chunk_blocks: Dictionary = {}
var bulk_chunks_loaded: bool = false
var last_load_stats: Dictionary = {}
#endregion


#region Public API
func clear_cache() -> void:
	bulk_chunk_blocks.clear()
	bulk_chunks_loaded = false
	last_load_stats.clear()


func is_loaded() -> bool:
	return bulk_chunks_loaded


func has_chunk(coord: Vector3i) -> bool:
	return bulk_chunk_blocks.has(coord)


func get_chunk_blocks(coord: Vector3i) -> PackedByteArray:
	if not bulk_chunk_blocks.has(coord):
		return PackedByteArray()
	var blocks = bulk_chunk_blocks[coord]
	if typeof(blocks) != TYPE_PACKED_BYTE_ARRAY:
		return PackedByteArray()
	return PackedByteArray(blocks)


func get_cache() -> Dictionary:
	return bulk_chunk_blocks


func replace_chunk_blocks(coord: Vector3i, blocks: PackedByteArray) -> void:
	if blocks.size() != World.CHUNK_VOLUME:
		return
	bulk_chunk_blocks[coord] = blocks.duplicate()


func get_last_load_stats() -> Dictionary:
	return last_load_stats.duplicate(true)


func snapshot_state() -> Dictionary:
	var cache: Dictionary = {}
	for coord in bulk_chunk_blocks.keys():
		var blocks_value: Variant = bulk_chunk_blocks[coord]
		if typeof(blocks_value) == TYPE_PACKED_BYTE_ARRAY:
			cache[coord] = PackedByteArray(blocks_value).duplicate()
	return {
		"cache": cache,
		"loaded": bulk_chunks_loaded,
		"stats": last_load_stats.duplicate(true),
	}


func restore_state(snapshot: Dictionary) -> void:
	bulk_chunk_blocks = snapshot.get("cache", {}).duplicate(true)
	bulk_chunks_loaded = bool(snapshot.get("loaded", false))
	last_load_stats = snapshot.get("stats", {}).duplicate(true)


func remember_chunk(world: World, coord: Vector3i, chunk: ChunkData) -> void:
	if world == null or not world.is_chunk_coord_valid(coord):
		return
	if not chunk.generated or chunk.blocks.size() != World.CHUNK_VOLUME:
		return
	bulk_chunk_blocks[coord] = chunk.blocks.duplicate()
#endregion


#region Save/Load
func save_bulk_chunks(world: World, world_dir: String, block_table_hash: int) -> bool:
	if world == null:
		return false
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
	file.store_32(block_table_hash)
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


func load_bulk_chunks(
	world: World,
	world_dir: String,
	block_table_hash: int,
	allow_legacy_block_table_hash: bool = false
) -> bool:
	clear_cache()
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
	var stored_block_hash: int = file.get_32()
	if stored_block_hash != block_table_hash and not allow_legacy_block_table_hash:
		push_warning("World load failed: bulk map block table hash mismatch")
		return false
	var count: int = file.get_32()
	var stats := _new_bulk_load_stats(bulk_version, count)
	stats["legacy_block_table"] = stored_block_hash != block_table_hash
	for _i in range(count):
		var entry := _read_bulk_chunk_entry(file, bulk_version, chunk_volume)
		if entry.is_empty():
			clear_cache()
			return false
		_update_bulk_load_stats(stats, entry)
		var coord_value = entry["coord"]
		var blocks_value = entry["blocks"]
		if typeof(coord_value) != TYPE_VECTOR3I or typeof(blocks_value) != TYPE_PACKED_BYTE_ARRAY:
			push_warning("World load failed: malformed bulk map entry")
			clear_cache()
			return false
		var coord: Vector3i = coord_value
		var blocks: PackedByteArray = PackedByteArray(blocks_value)
		if blocks.size() != chunk_volume:
			push_warning("World load failed: bad bulk map chunk size")
			clear_cache()
			return false
		if world != null and world.is_chunk_coord_valid(coord):
			bulk_chunk_blocks[coord] = blocks
	bulk_chunks_loaded = true
	last_load_stats = stats
	return true
#endregion


#region Bulk Entry Format
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
#endregion


#region Helpers
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


func _store_signed_32(file: FileAccess, value: int) -> void:
	file.store_32(value & 0xffffffff)


func _read_signed_32(file: FileAccess) -> int:
	var value: int = file.get_32()
	if value > 0x7fffffff:
		return value - 0x100000000
	return value
#endregion
