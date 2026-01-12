extends RefCounted
class_name WorldSaveLoad
## Handles world save/load and serialization.

#region Constants
const SAVE_MAGIC := 0x474F424C
const SAVE_VERSION := 1
#endregion

#region State
var world: World
#endregion


#region Initialization
func _init(world_ref: World) -> void:
	world = world_ref
#endregion


#region Save
func save_world(path: String) -> bool:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		push_error("World save failed: %s" % path)
		return false
	var buffer := serialize_blocks()
	file.store_32(SAVE_MAGIC)
	file.store_32(SAVE_VERSION)
	file.store_32(world.world_size_x)
	file.store_32(world.world_size_y)
	file.store_32(world.world_size_z)
	file.store_32(World.CHUNK_SIZE)
	file.store_32(world.sea_level)
	file.store_32(world.top_render_y)
	file.store_32(buffer.size())
	file.store_buffer(buffer)
	file.flush()
	return true


func serialize_blocks() -> PackedByteArray:
	var total: int = world.world_size_x * world.world_size_y * world.world_size_z
	var buffer := PackedByteArray()
	buffer.resize(total)
	for z in range(world.world_size_z):
		for y in range(world.world_size_y):
			for x in range(world.world_size_x):
				var idx := world_index(x, y, z)
				buffer[idx] = world.get_block_no_generate(x, y, z)
	return buffer
#endregion


#region Load
func load_world(path: String) -> bool:
	if not FileAccess.file_exists(path):
		push_warning("World load failed: missing %s" % path)
		return false
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		push_warning("World load failed: cannot open %s" % path)
		return false
	var magic: int = file.get_32()
	if magic != SAVE_MAGIC:
		push_warning("World load failed: bad magic")
		return false
	var version: int = file.get_32()
	if version != SAVE_VERSION:
		push_warning("World load failed: version %d != %d" % [version, SAVE_VERSION])
		return false
	var size_x: int = file.get_32()
	var size_y: int = file.get_32()
	var size_z: int = file.get_32()
	var chunk_size: int = file.get_32()
	if size_x != world.world_size_x or size_y != world.world_size_y or size_z != world.world_size_z or chunk_size != World.CHUNK_SIZE:
		push_warning("World load failed: size mismatch")
		return false
	var saved_sea_level: int = file.get_32()
	var saved_top_render_y: int = file.get_32()
	var block_count: int = file.get_32()
	var expected_count: int = world.world_size_x * world.world_size_y * world.world_size_z
	if block_count != expected_count:
		push_warning("World load failed: block count mismatch")
		return false
	var buffer := file.get_buffer(block_count)
	if buffer.size() != block_count:
		push_warning("World load failed: incomplete block data")
		return false
	load_blocks_from_buffer(buffer)
	world.sea_level = clamp(saved_sea_level, 0, world.world_size_y - 1)
	world.top_render_y = clamp(saved_top_render_y, 0, world.world_size_y - 1)
	world.reset_streaming_state()
	world.clear_and_respawn_workers()
	if world.renderer != null:
		world.renderer.clear_chunks()
		world.renderer.reset_stats()
	return true


func load_blocks_from_buffer(buffer: PackedByteArray) -> void:
	world.chunks.clear()
	world.chunk_access_tick = 0
	var total: int = world.world_size_x * world.world_size_y * world.world_size_z
	if buffer.size() < total:
		return
	for z in range(world.world_size_z):
		for y in range(world.world_size_y):
			for x in range(world.world_size_x):
				var idx := world_index(x, y, z)
				world.set_block_raw(x, y, z, buffer[idx], false)
	for chunk in world.chunks.values():
		var entry: World.ChunkDataType = chunk
		entry.generated = true
#endregion


#region Helpers
func world_index(x: int, y: int, z: int) -> int:
	return (z * world.world_size_y + y) * world.world_size_x + x
#endregion
