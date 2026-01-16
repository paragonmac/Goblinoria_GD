extends RefCounted
class_name WorldGenerator
## Handles chunk generation, seeding, and terrain algorithms.

#region Constants
const SEED_MIX_FACTOR := 0x45d9f3b
const SEED_MASK := 0x7fffffff
const TOPSOIL_DEPTH_MIN := 2
const TOPSOIL_DEPTH_MAX := 4
const SEA_LEVEL_FILL_OFFSET := 1
const HEIGHT_NOISE_FREQUENCY := 0.01
const HEIGHT_NOISE_AMPLITUDE := 8
#endregion

#region State
var world: World
var height_noise: FastNoiseLite
var height_noise_seed: int = -1
var generation_thread: Thread
var generation_thread_running: bool = false
var generation_thread_quit: bool = false
var generation_job_queue: Array = []
var generation_job_set: Dictionary = {}
var generation_result_queue: Array = []
var generation_mutex := Mutex.new()
var generation_semaphore := Semaphore.new()
var generation_active: int = 0
var generation_epoch: int = 0
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
	var h: int = mix_seed(world.world_seed ^ coord.x)
	h = mix_seed(h ^ coord.y)
	h = mix_seed(h ^ coord.z)
	return h


func mix_seed(value: int) -> int:
	var v: int = value & 0xffffffff
	v = int(((v >> 16) ^ v) * SEED_MIX_FACTOR) & 0xffffffff
	v = int(((v >> 16) ^ v) * SEED_MIX_FACTOR) & 0xffffffff
	v = int((v >> 16) ^ v) & 0xffffffff
	return v & SEED_MASK
#endregion


#region Chunk Generation
func generate_chunk(coord: Vector3i, chunk: World.ChunkDataType) -> void:
	var chunk_size: int = World.CHUNK_SIZE
	var base_y: int = coord.y * chunk_size
	var max_height: int = min(world.sea_level + HEIGHT_NOISE_AMPLITUDE, world.world_size_y - 1)
	if base_y > max_height:
		chunk.generated = true
		world.touch_chunk(chunk)
		return
	_ensure_height_noise()
	var rng := RandomNumberGenerator.new()
	rng.seed = chunk_seed_from_coord(coord)
	var dirt_depth: int = rng.randi_range(TOPSOIL_DEPTH_MIN, TOPSOIL_DEPTH_MAX)
	for lx in range(chunk_size):
		var wx: int = coord.x * chunk_size + lx
		for lz in range(chunk_size):
			var wz: int = coord.z * chunk_size + lz
			var surface_y: int = _height_at(wx, wz)
			if surface_y < base_y:
				continue
			var fill_max: int = min(chunk_size - 1, surface_y - base_y)
			for ly in range(fill_max + 1):
				var world_y: int = base_y + ly
				var idx := world.chunk_index(lx, ly, lz)
				var block_id: int = World.DEFAULT_MATERIAL
				if world_y == surface_y:
					block_id = World.BLOCK_ID_GRASS
				elif world_y >= surface_y - dirt_depth:
					block_id = World.BLOCK_ID_DIRT
				chunk.blocks[idx] = block_id
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
func queue_chunk_generation(coord: Vector3i) -> bool:
	if generation_job_set.has(coord):
		return false
	if not generation_thread_running:
		_start_generation_thread()
	var job := {
		"coord": coord,
		"world_seed": world.world_seed,
		"sea_level": world.sea_level,
		"world_size_y": world.world_size_y,
		"chunk_size": World.CHUNK_SIZE,
		"epoch": generation_epoch,
		"block_id_air": World.BLOCK_ID_AIR,
		"block_id_default": World.DEFAULT_MATERIAL,
		"block_id_grass": World.BLOCK_ID_GRASS,
		"block_id_dirt": World.BLOCK_ID_DIRT,
	}
	generation_mutex.lock()
	generation_job_set[coord] = true
	generation_job_queue.append(job)
	generation_mutex.unlock()
	generation_semaphore.post()
	return true


func process_generation_results(budget: int) -> int:
	if budget <= 0:
		return 0
	var applied := 0
	while applied < budget:
		var result: Dictionary
		generation_mutex.lock()
		if generation_result_queue.is_empty():
			generation_mutex.unlock()
			break
		result = generation_result_queue.pop_front()
		generation_mutex.unlock()
		var epoch: int = int(result.get("epoch", -1))
		if epoch != generation_epoch:
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
		if world.renderer != null:
			world.renderer.queue_chunk_mesh_build(coord)
		_clear_generation_job(coord)
		applied += 1
	return applied


func get_generation_stats() -> Dictionary:
	generation_mutex.lock()
	var stats := {
		"queued": generation_job_queue.size(),
		"results": generation_result_queue.size(),
		"active": generation_active,
	}
	generation_mutex.unlock()
	return stats


func reset_generation_jobs() -> void:
	generation_epoch += 1
	generation_mutex.lock()
	generation_job_queue.clear()
	generation_result_queue.clear()
	generation_job_set.clear()
	generation_mutex.unlock()


func shutdown_generation_thread() -> void:
	if not generation_thread_running:
		return
	generation_thread_quit = true
	generation_semaphore.post()
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
	var noise := FastNoiseLite.new()
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	noise.frequency = HEIGHT_NOISE_FREQUENCY
	var noise_seed: int = -1
	while true:
		generation_semaphore.wait()
		if generation_thread_quit:
			break
		var job: Dictionary
		generation_mutex.lock()
		if generation_job_queue.is_empty():
			generation_mutex.unlock()
			continue
		job = generation_job_queue.pop_front()
		generation_active += 1
		generation_mutex.unlock()
		var seed: int = int(job.get("world_seed", 0))
		if seed != noise_seed:
			noise.seed = seed
			noise_seed = seed
		var blocks := _generate_chunk_blocks(job, noise)
		var result := {
			"coord": job.get("coord", Vector3i.ZERO),
			"blocks": blocks,
			"epoch": job.get("epoch", 0),
		}
		generation_mutex.lock()
		generation_active -= 1
		generation_result_queue.append(result)
		generation_mutex.unlock()


func _generate_chunk_blocks(job: Dictionary, noise: FastNoiseLite) -> PackedByteArray:
	var coord: Vector3i = job.get("coord", Vector3i.ZERO)
	var chunk_size: int = int(job.get("chunk_size", World.CHUNK_SIZE))
	var world_size_y: int = int(job.get("world_size_y", 0))
	var sea_level: int = int(job.get("sea_level", 0))
	var base_y: int = coord.y * chunk_size
	var max_height: int = min(sea_level + HEIGHT_NOISE_AMPLITUDE, world_size_y - 1)
	if base_y > max_height:
		return PackedByteArray()
	var block_air: int = int(job.get("block_id_air", World.BLOCK_ID_AIR))
	var block_default: int = int(job.get("block_id_default", World.DEFAULT_MATERIAL))
	var block_grass: int = int(job.get("block_id_grass", World.BLOCK_ID_GRASS))
	var block_dirt: int = int(job.get("block_id_dirt", World.BLOCK_ID_DIRT))
	var volume: int = chunk_size * chunk_size * chunk_size
	var blocks := PackedByteArray()
	blocks.resize(volume)
	blocks.fill(block_air)
	var rng := RandomNumberGenerator.new()
	rng.seed = _chunk_seed_from_coord_with_seed(coord, int(job.get("world_seed", 0)))
	var dirt_depth: int = rng.randi_range(TOPSOIL_DEPTH_MIN, TOPSOIL_DEPTH_MAX)
	for lx in range(chunk_size):
		var wx: int = coord.x * chunk_size + lx
		for lz in range(chunk_size):
			var wz: int = coord.z * chunk_size + lz
			var n: float = noise.get_noise_2d(float(wx), float(wz))
			var surface_y := sea_level + int(round(n * HEIGHT_NOISE_AMPLITUDE))
			surface_y = clampi(surface_y, 0, world_size_y - 1)
			if surface_y < base_y:
				continue
			var fill_max: int = min(chunk_size - 1, surface_y - base_y)
			for ly in range(fill_max + 1):
				var world_y: int = base_y + ly
				var idx: int = (lz * chunk_size + ly) * chunk_size + lx
				var block_id: int = block_default
				if world_y == surface_y:
					block_id = block_grass
				elif world_y >= surface_y - dirt_depth:
					block_id = block_dirt
				blocks[idx] = block_id
	return blocks


func _clear_generation_job(coord: Vector3i) -> void:
	generation_mutex.lock()
	generation_job_set.erase(coord)
	generation_mutex.unlock()


func _chunk_seed_from_coord_with_seed(coord: Vector3i, seed: int) -> int:
	var h: int = mix_seed(seed ^ coord.x)
	h = mix_seed(h ^ coord.y)
	h = mix_seed(h ^ coord.z)
	return h
#endregion


func _ensure_height_noise() -> void:
	if height_noise == null:
		height_noise = FastNoiseLite.new()
	if height_noise_seed != world.world_seed:
		height_noise.seed = world.world_seed
		height_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
		height_noise.frequency = HEIGHT_NOISE_FREQUENCY
		height_noise_seed = world.world_seed


func _height_at(wx: int, wz: int) -> int:
	var n: float = height_noise.get_noise_2d(float(wx), float(wz))
	var height := world.sea_level + int(round(n * HEIGHT_NOISE_AMPLITUDE))
	return clampi(height, 0, world.world_size_y - 1)
