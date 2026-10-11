extends RefCounted
class_name WorldMetadataSaveLoad

const WorldSaveTransactionScript = preload("res://scripts/world_save_transaction.gd")

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
	var ok := file.store_32(META_MAGIC) \
		and file.store_16(save_version) \
		and file.store_16(World.CHUNK_SIZE) \
		and file.store_16(World.WORLD_CHUNKS_X) \
		and file.store_16(World.WORLD_CHUNKS_Y) \
		and file.store_16(World.WORLD_CHUNKS_Z) \
		and file.store_32(world.world_size_y) \
		and file.store_64(world.world_seed) \
		and file.store_32(world.spawn_coord.x) \
		and file.store_32(world.spawn_coord.y) \
		and file.store_32(world.spawn_coord.z) \
		and file.store_32(world.top_render_y) \
		and file.store_32(block_table_hash)
	return WorldSaveTransactionScript.finish_write(file) and ok


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
	legacy_save_versions: Array = [],
	legacy_block_table_versions: Array = [],
	compatible_hashes_by_version: Dictionary = {}
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
	var legacy_version: bool = legacy_save_versions.has(version)
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
	if chunks_y != World.WORLD_CHUNKS_Y or chunks_x < 16 or chunks_x > 128 \
			or chunks_z < 16 or chunks_z > 128 or (chunks_x & (chunks_x - 1)) != 0 \
			or (chunks_z & (chunks_z - 1)) != 0:
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
	var legacy_block_table: bool = legacy_block_table_versions.has(version) \
		and block_hash != expected_block_table_hash
	var compatible_hash: bool = compatible_hashes_by_version.get(version, []).has(block_hash)
	if block_hash != expected_block_table_hash and not legacy_block_table and not compatible_hash:
		push_warning("World load failed: block table hash mismatch")
		return {"ok": false}
	return {
		"ok": true,
		"world_seed": seed,
		"spawn_coord": Vector3i(spawn_x, spawn_y, spawn_z),
		"top_render_y": clampi(top_y, 0, world.world_size_y - 1),
		"save_version": version,
		"chunks_x": chunks_x,
		"chunks_y": chunks_y,
		"chunks_z": chunks_z,
		"block_table_hash": block_hash,
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
