extends RefCounted
class_name WorldMetadataSaveLoad

const META_MAGIC := 0x474D4554
const META_FILE_NAME := "world_meta.dat"


func write_world_meta(world: World, world_dir: String, save_version: int, block_table_hash: int) -> bool:
	if world == null:
		return false
	var path := world_dir.path_join(META_FILE_NAME)
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		push_warning("World meta save failed: %s" % path)
		return false
	file.store_32(META_MAGIC)
	file.store_16(save_version)
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
	file.store_32(block_table_hash)
	file.flush()
	return true


func read_world_meta(world: World, world_dir: String, save_version: int, expected_block_table_hash: int) -> bool:
	var snapshot := read_world_meta_snapshot(world, world_dir, save_version, expected_block_table_hash)
	if not bool(snapshot.get("ok", false)):
		return false
	apply_world_meta(world, snapshot)
	return true


func read_world_meta_snapshot(
	world: World,
	world_dir: String,
	save_version: int,
	expected_block_table_hash: int,
	legacy_save_version: int = -1,
	allow_legacy_block_table_hash: bool = false
) -> Dictionary:
	if world == null:
		return {"ok": false}
	var path := world_dir.path_join(META_FILE_NAME)
	if not FileAccess.file_exists(path):
		push_warning("World load failed: missing %s" % path)
		return {"ok": false}
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		push_warning("World load failed: cannot open %s" % path)
		return {"ok": false}
	var magic: int = file.get_32()
	if magic != META_MAGIC:
		push_warning("World load failed: bad meta magic")
		return {"ok": false}
	var version: int = file.get_16()
	var legacy_version: bool = version == legacy_save_version
	if version != save_version and not legacy_version:
		push_warning("World load failed: version %d != %d" % [version, save_version])
		return {"ok": false}
	var chunk_size: int = file.get_16()
	if chunk_size != World.CHUNK_SIZE:
		push_warning("World load failed: chunk size mismatch")
		return {"ok": false}
	var chunks_x: int = file.get_16()
	var chunks_y: int = file.get_16()
	var chunks_z: int = file.get_16()
	if chunks_x != World.WORLD_CHUNKS_X or chunks_y != World.WORLD_CHUNKS_Y or chunks_z != World.WORLD_CHUNKS_Z:
		push_warning("World load failed: world dimensions mismatch")
		return {"ok": false}
	var world_size_y: int = file.get_32()
	if world_size_y != world.world_size_y:
		push_warning("World load failed: height mismatch")
		return {"ok": false}
	var seed: int = int(file.get_64())
	var spawn_x: int = file.get_32()
	var spawn_y: int = file.get_32()
	var spawn_z: int = file.get_32()
	var top_y: int = file.get_32()
	var block_hash: int = file.get_32()
	var legacy_block_table: bool = legacy_version and block_hash != expected_block_table_hash
	if block_hash != expected_block_table_hash and not (legacy_block_table and allow_legacy_block_table_hash):
		push_warning("World load failed: block table hash mismatch")
		return {"ok": false}
	return {
		"ok": true,
		"world_seed": seed,
		"spawn_coord": Vector3i(spawn_x, spawn_y, spawn_z),
		"top_render_y": clampi(top_y, 0, world.world_size_y - 1),
		"legacy_block_table": legacy_block_table,
	}


func apply_world_meta(world: World, snapshot: Dictionary) -> void:
	if world == null or not bool(snapshot.get("ok", false)):
		return
	var seed := int(snapshot.get("world_seed", 0))
	var spawn: Vector3i = snapshot.get("spawn_coord", Vector3i.ZERO)
	var top_y := int(snapshot.get("top_render_y", 0))
	world.world_seed = seed
	world.spawn_coord = spawn
	world.sea_level = max(world.world_size_y - World.SEA_LEVEL_DEPTH, World.SEA_LEVEL_MIN)
	world.top_render_y = clampi(top_y, 0, world.world_size_y - 1)
