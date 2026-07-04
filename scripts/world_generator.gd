extends RefCounted
class_name WorldGenerator
## Handles chunk generation, seeding, and terrain algorithms.

const WorldGenerationPipelineScript = preload("res://scripts/world_generation_pipeline.gd")
const WorldGenerationSharedScript = preload("res://scripts/world/world_generation_shared.gd")
const WorldGenerationJobQueueScript = preload("res://scripts/world/world_generation_job_queue.gd")
const WorldTerrainHeightSamplerScript = preload("res://scripts/world/world_terrain_height_sampler.gd")
const WorldTerrainChunkBuilderScript = preload("res://scripts/world/world_terrain_chunk_builder.gd")

#region Constants
const SEED_MASK := WorldGenerationSharedScript.SEED_MASK
#endregion

#region State
var world: World
var height_noise_flat: FastNoiseLite
var height_noise_small: FastNoiseLite
var height_noise_large: FastNoiseLite
var height_noise_macro: FastNoiseLite
var height_noise_seed: int = -1
var generation_thread: Thread
var generation_thread_running: bool = false
var generation_thread_quit: bool = false
var generation_queue := WorldGenerationJobQueueScript.new()
#endregion


#region Initialization
func _init(world_ref: World) -> void:
	world = world_ref
#endregion


#region World Seeding
func generate_world_seed() -> int:
	var rng := RandomNumberGenerator.new()
	rng.randomize()
	return int(rng.randi() & SEED_MASK)


func chunk_seed_from_coord(coord: Vector3i) -> int:
	return WorldTerrainChunkBuilderScript.chunk_seed_from_coord(coord, world.world_seed)
#endregion




func build_layered_world_config(seed: int, sea_level_value: int, world_size_y_value: int) -> Dictionary:
	return {
		"world_seed": seed,
		"sea_level": sea_level_value,
		"world_size_y": world_size_y_value,
		"chunk_size": World.CHUNK_SIZE,
		"world_chunks_x": World.WORLD_CHUNKS_X,
		"world_chunks_y": World.WORLD_CHUNKS_Y,
		"world_chunks_z": World.WORLD_CHUNKS_Z,
		"world_min_chunk_x": World.WORLD_MIN_CHUNK_X,
		"world_max_chunk_x": World.WORLD_MAX_CHUNK_X,
		"world_min_chunk_z": World.WORLD_MIN_CHUNK_Z,
		"world_max_chunk_z": World.WORLD_MAX_CHUNK_Z,
	}


func generate_layered_world(config: Dictionary) -> Dictionary:
	var pipeline = WorldGenerationPipelineScript.new()
	return pipeline.generate(config)
#region Chunk Generation
func generate_chunk(coord: Vector3i, chunk: World.ChunkDataType) -> void:
	if not world.is_chunk_coord_valid(coord):
		return
	var chunk_size: int = World.CHUNK_SIZE
	if not WorldTerrainChunkBuilderScript.can_contain_terrain(
		coord,
		chunk_size,
		world.sea_level,
		world.world_size_y
	):
		chunk.generated = true
		world.touch_chunk(chunk)
		return
	_ensure_height_noise()
	WorldTerrainChunkBuilderScript.fill_blocks(
		coord,
		chunk.blocks,
		chunk_size,
		world.world_seed,
		world.sea_level,
		world.world_size_y,
		World.DEFAULT_MATERIAL,
		World.BLOCK_ID_GRASS,
		World.BLOCK_ID_DIRT,
		height_noise_flat,
		height_noise_small,
		height_noise_large,
		height_noise_macro
	)
	chunk.generated = true
	world.touch_chunk(chunk)


func prime_spawn_chunks() -> void:
	var center_x: int = world.spawn_coord.x
	var center_z: int = world.spawn_coord.z
	var sample_y: int = clampi(world.sea_level - 1, 0, world.world_size_y - 1)
	for offset in World.WORKER_SPAWN_OFFSETS:
		var spawn_x: int = center_x + offset.x
		var spawn_z: int = center_z + offset.y
		var coord := world.world_to_chunk_coords(spawn_x, sample_y, spawn_z)
		world.ensure_chunk_generated(coord)
#endregion


#region Async Generation
func queue_chunk_generation(coord: Vector3i, high_priority: bool = false, queue_mesh_on_complete: bool = true) -> bool:
	if not world.is_chunk_coord_valid(coord):
		return false
	if not generation_queue.contains(coord) and not generation_thread_running:
		_start_generation_thread()
	var job := {
		"coord": coord,
		"world_seed": world.world_seed,
		"sea_level": world.sea_level,
		"world_size_y": world.world_size_y,
		"chunk_size": World.CHUNK_SIZE,
		"epoch": generation_queue.get_epoch(),
		"block_id_air": World.BLOCK_ID_AIR,
		"block_id_default": World.DEFAULT_MATERIAL,
		"block_id_grass": World.BLOCK_ID_GRASS,
		"block_id_dirt": World.BLOCK_ID_DIRT,
		"high_priority": high_priority,
		"queue_mesh_on_complete": queue_mesh_on_complete,
	}
	return generation_queue.enqueue(coord, job, high_priority, queue_mesh_on_complete)


func process_generation_results(budget: int) -> int:
	if budget <= 0:
		return 0
	var applied := 0
	while applied < budget:
		var result := generation_queue.pop_result()
		if result.is_empty():
			break
		var epoch: int = int(result.get("epoch", -1))
		if epoch != generation_queue.get_epoch():
			continue
		var coord: Vector3i = result.get("coord", Vector3i.ZERO)
		var chunk: ChunkData = world.get_chunk(coord)
		if chunk == null or chunk.generated:
			_clear_generation_job(coord)
			continue
		var blocks: PackedByteArray = result.get("blocks", PackedByteArray())
		if blocks.size() > 0:
			chunk.blocks = blocks
		else:
			chunk.blocks.fill(World.BLOCK_ID_AIR)
		chunk.generated = true
		chunk.dirty = false
		chunk.mesh_state = ChunkData.MESH_STATE_NONE
		world.touch_chunk(chunk)
		world.notify_chunk_loaded(coord)
		var queue_mesh_on_complete: bool = bool(result.get("queue_mesh_on_complete", true))
		if queue_mesh_on_complete and world.renderer != null:
			var high_priority: bool = bool(result.get("high_priority", false))
			world.renderer.queue_chunk_mesh_build(coord, -1, false, high_priority)
		_clear_generation_job(coord)
		applied += 1
	return applied


func get_generation_stats() -> Dictionary:
	return generation_queue.get_stats()


func reset_generation_jobs() -> void:
	generation_queue.reset()


func shutdown_generation_thread() -> void:
	if not generation_thread_running:
		return
	generation_thread_quit = true
	generation_queue.wake()
	generation_thread.wait_to_finish()
	generation_thread_running = false


func _start_generation_thread() -> void:
	if generation_thread_running:
		return
	generation_thread_quit = false
	generation_thread = Thread.new()
	generation_thread_running = true
	generation_thread.start(Callable(self, "_generation_thread_main"))


func _generation_thread_main() -> void:
	var flat_noise := FastNoiseLite.new()
	var small_noise := FastNoiseLite.new()
	var large_noise := FastNoiseLite.new()
	var macro_noise := FastNoiseLite.new()
	var noise_seed: int = -1
	while true:
		generation_queue.wait_for_job_signal()
		if generation_thread_quit:
			break
		var job := generation_queue.pop_job()
		if job.is_empty():
			continue
		var seed: int = int(job.get("world_seed", 0))
		if seed != noise_seed:
			_configure_height_noises(seed, flat_noise, small_noise, large_noise, macro_noise)
			noise_seed = seed
		var blocks := _generate_chunk_blocks(job, flat_noise, small_noise, large_noise, macro_noise)
		var result := {
			"coord": job.get("coord", Vector3i.ZERO),
			"blocks": blocks,
			"epoch": job.get("epoch", 0),
			"high_priority": bool(job.get("high_priority", false)),
			"queue_mesh_on_complete": bool(job.get("queue_mesh_on_complete", true)),
		}
		generation_queue.push_result(result)


func _generate_chunk_blocks(job: Dictionary, flat_noise: FastNoiseLite, small_noise: FastNoiseLite, large_noise: FastNoiseLite, macro_noise: FastNoiseLite) -> PackedByteArray:
	var coord: Vector3i = job.get("coord", Vector3i.ZERO)
	var chunk_size: int = int(job.get("chunk_size", World.CHUNK_SIZE))
	var world_size_y: int = int(job.get("world_size_y", 0))
	var sea_level: int = int(job.get("sea_level", 0))
	return WorldTerrainChunkBuilderScript.build_blocks(
		coord,
		chunk_size,
		int(job.get("world_seed", 0)),
		sea_level,
		world_size_y,
		int(job.get("block_id_air", World.BLOCK_ID_AIR)),
		int(job.get("block_id_default", World.DEFAULT_MATERIAL)),
		int(job.get("block_id_grass", World.BLOCK_ID_GRASS)),
		int(job.get("block_id_dirt", World.BLOCK_ID_DIRT)),
		flat_noise,
		small_noise,
		large_noise,
		macro_noise
	)


func _clear_generation_job(coord: Vector3i) -> void:
	generation_queue.clear_job(coord)


#endregion


func _ensure_height_noise() -> void:
	if height_noise_flat == null:
		height_noise_flat = FastNoiseLite.new()
	if height_noise_small == null:
		height_noise_small = FastNoiseLite.new()
	if height_noise_large == null:
		height_noise_large = FastNoiseLite.new()
	if height_noise_macro == null:
		height_noise_macro = FastNoiseLite.new()
	if height_noise_seed != world.world_seed:
		_configure_height_noises(world.world_seed, height_noise_flat, height_noise_small, height_noise_large, height_noise_macro)
		height_noise_seed = world.world_seed


func _height_at(wx: int, wz: int) -> int:
	return WorldTerrainHeightSamplerScript.height_at(
		wx,
		wz,
		world.sea_level,
		world.world_size_y,
		height_noise_flat,
		height_noise_small,
		height_noise_large,
		height_noise_macro
	)


func get_surface_y(wx: int, wz: int) -> int:
	_ensure_height_noise()
	return _height_at(wx, wz)


func _configure_height_noises(
	seed: int,
	flat_noise: FastNoiseLite,
	small_noise: FastNoiseLite,
	large_noise: FastNoiseLite,
	macro_noise: FastNoiseLite
) -> void:
	WorldGenerationSharedScript.configure_height_noises(seed, flat_noise, small_noise, large_noise, macro_noise)
