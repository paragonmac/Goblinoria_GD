extends SceneTree

const TEST_PATH := "user://terrain_slope_migration_contract/world.save"
const WorldGenerationSharedScript = preload("res://scripts/world/world_generation_shared.gd")
const WorldTerrainHeightSamplerScript = preload("res://scripts/world/world_terrain_height_sampler.gd")
const WorldRampRulesScript = preload("res://scripts/world/world_ramp_rules.gd")


func _init() -> void:
	var world := World.new()
	root.add_child(world)
	_run.call_deferred(world)


func _run(world: World) -> void:
	await process_frame
	var seed := 123456
	world.start_new_world(seed)
	var terrain := _find_terrain_ramp(seed, world.sea_level, world.world_size_y)
	if terrain.is_empty():
		_fail(world, "Could not find a deterministic terrain ramp")
		return
	var terrain_pos: Vector3i = terrain["pos"]
	var old_ramp_id: int = terrain["ramp_id"]
	var player_pos := Vector3i(terrain_pos.x, 1, terrain_pos.z)
	world.set_block_raw(terrain_pos.x, terrain_pos.y, terrain_pos.z, old_ramp_id, true)
	world.set_block_raw(player_pos.x, player_pos.y, player_pos.z, old_ramp_id, true)
	if not world.save_world(TEST_PATH):
		_fail(world, "Could not write V5 baseline save")
		return
	if not _mark_save_as_v4(TEST_PATH):
		_fail(world, "Could not rewrite save headers as V4")
		return
	if not world.load_world(TEST_PATH):
		_fail(world, "Could not load V4 migration save")
		return
	var terrain_migrated: bool = world.get_block(
		terrain_pos.x,
		terrain_pos.y,
		terrain_pos.z
	) == World.terrain_slope_id_for_shape(old_ramp_id)
	var player_preserved: bool = world.get_block(
		player_pos.x,
		player_pos.y,
		player_pos.z
	) == old_ramp_id
	world.task_manager.shutdown()
	world.queue_free()
	if not terrain_migrated or not player_preserved:
		push_error("V4 terrain slope migration changed the wrong ramp identity")
		quit(1)
		return
	print("Terrain slope migration contract OK")
	quit(0)


func _find_terrain_ramp(seed: int, sea_level: int, world_size_y: int) -> Dictionary:
	var flat_noise := FastNoiseLite.new()
	var small_noise := FastNoiseLite.new()
	var large_noise := FastNoiseLite.new()
	var macro_noise := FastNoiseLite.new()
	WorldGenerationSharedScript.configure_height_noises(
		seed,
		flat_noise,
		small_noise,
		large_noise,
		macro_noise
	)
	for z in range(-32, 32):
		for x in range(-32, 32):
			var h_nw := _height_at(x, z, sea_level, world_size_y, flat_noise, small_noise, large_noise, macro_noise)
			var h_ne := _height_at(x + 1, z, sea_level, world_size_y, flat_noise, small_noise, large_noise, macro_noise)
			var h_sw := _height_at(x, z + 1, sea_level, world_size_y, flat_noise, small_noise, large_noise, macro_noise)
			var h_se := _height_at(x + 1, z + 1, sea_level, world_size_y, flat_noise, small_noise, large_noise, macro_noise)
			var result := WorldRampRulesScript.marching_squares_ramp(h_nw, h_ne, h_sw, h_se)
			var ramp_id: int = int(result.get("ramp_id", -1))
			if ramp_id >= 0:
				return {
					"pos": Vector3i(x, int(result.get("ramp_y", 0)), z),
					"ramp_id": ramp_id,
				}
	return {}


func _height_at(
	x: int,
	z: int,
	sea_level: int,
	world_size_y: int,
	flat_noise: FastNoiseLite,
	small_noise: FastNoiseLite,
	large_noise: FastNoiseLite,
	macro_noise: FastNoiseLite
) -> int:
	return WorldTerrainHeightSamplerScript.height_at(
		x,
		z,
		sea_level,
		world_size_y,
		flat_noise,
		small_noise,
		large_noise,
		macro_noise,
		true
	)


func _mark_save_as_v4(path: String) -> bool:
	var world_dir := path.get_basename()
	var meta_path := world_dir.path_join(WorldMetadataSaveLoad.META_FILE_NAME)
	var bulk_path := world_dir.path_join(WorldBulkChunkSaveLoad.BULK_CHUNKS_FILE_NAME)
	var meta_file := FileAccess.open(meta_path, FileAccess.READ_WRITE)
	if meta_file == null:
		return false
	meta_file.seek(4)
	meta_file.store_16(WorldSaveLoad.LEGACY_SAVE_VERSION)
	meta_file.seek(42)
	meta_file.store_32(0)
	meta_file.flush()
	var bulk_file := FileAccess.open(bulk_path, FileAccess.READ_WRITE)
	if bulk_file == null:
		return false
	bulk_file.seek(18)
	bulk_file.store_32(0)
	bulk_file.flush()
	return true


func _fail(world: World, message: String) -> void:
	world.task_manager.shutdown()
	world.queue_free()
	push_error(message)
	quit(1)
