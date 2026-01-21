extends RefCounted
class_name WorldGenerator
## Handles chunk generation, seeding, and terrain algorithms.

#region Constants
const SEED_MIX_FACTOR := 0x45d9f3b
const SEED_MASK := 0x7fffffff
const TOPSOIL_DEPTH_MIN := 2
const TOPSOIL_DEPTH_MAX := 4
const SEA_LEVEL_FILL_OFFSET := 1
const FLAT_NOISE_FREQUENCY := 0.02
const SMALL_NOISE_FREQUENCY := 0.01
const LARGE_NOISE_FREQUENCY := 0.005
const MACRO_NOISE_FREQUENCY := 0.0015
const FLAT_AMPLITUDE := 1
const SMALL_AMPLITUDE := 4
const LARGE_AMPLITUDE := 10
const MACRO_FLAT_CUTOFF := 0.88
const MACRO_SMALL_CUTOFF := 0.96
const MAX_HEIGHT_AMPLITUDE := LARGE_AMPLITUDE
const RAMP_MIN_NEIGHBOR_MATCH := 1
const INNER_RAMP_MIN_NEIGHBOR_MATCH := 0
# Minimum terrain feature size - heights are sampled on this grid and interpolated
# This prevents isolated holes smaller than this size
# Smaller values = more varied terrain with corner ramps, larger = smoother slopes
const TERRAIN_CELL_SIZE := 4
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
	var max_height: int = min(world.sea_level + MAX_HEIGHT_AMPLITUDE, world.world_size_y - 1)
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
	_apply_ramp_blocks(coord, chunk)
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
	var flat_noise := FastNoiseLite.new()
	var small_noise := FastNoiseLite.new()
	var large_noise := FastNoiseLite.new()
	var macro_noise := FastNoiseLite.new()
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
			_configure_height_noises(seed, flat_noise, small_noise, large_noise, macro_noise)
			noise_seed = seed
		var blocks := _generate_chunk_blocks(job, flat_noise, small_noise, large_noise, macro_noise)
		var result := {
			"coord": job.get("coord", Vector3i.ZERO),
			"blocks": blocks,
			"epoch": job.get("epoch", 0),
		}
		generation_mutex.lock()
		generation_active -= 1
		generation_result_queue.append(result)
		generation_mutex.unlock()


func _generate_chunk_blocks(job: Dictionary, flat_noise: FastNoiseLite, small_noise: FastNoiseLite, large_noise: FastNoiseLite, macro_noise: FastNoiseLite) -> PackedByteArray:
	var coord: Vector3i = job.get("coord", Vector3i.ZERO)
	var chunk_size: int = int(job.get("chunk_size", World.CHUNK_SIZE))
	var world_size_y: int = int(job.get("world_size_y", 0))
	var sea_level: int = int(job.get("sea_level", 0))
	var base_y: int = coord.y * chunk_size
	var max_height: int = min(sea_level + MAX_HEIGHT_AMPLITUDE, world_size_y - 1)
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
			var surface_y := _height_at_with_noise(wx, wz, sea_level, world_size_y, flat_noise, small_noise, large_noise, macro_noise)
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
	_apply_ramp_blocks_with_noise(job, blocks, flat_noise, small_noise, large_noise, macro_noise)
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
	return _height_at_with_noise(wx, wz, world.sea_level, world.world_size_y, height_noise_flat, height_noise_small, height_noise_large, height_noise_macro)


func get_surface_y(wx: int, wz: int) -> int:
	_ensure_height_noise()
	return _height_at(wx, wz)


## Marching squares ramp selection using 4 corner heights.
## Returns {"ramp_id": int, "ramp_y": int} where ramp_y is placement height.
## Corners: NW=(wx,wz), NE=(wx+1,wz), SW=(wx,wz+1), SE=(wx+1,wz+1)
func _get_marching_squares_ramp(h_nw: int, h_ne: int, h_sw: int, h_se: int) -> Dictionary:
	var min_h := mini(mini(h_nw, h_ne), mini(h_sw, h_se))
	var max_h := maxi(maxi(h_nw, h_ne), maxi(h_sw, h_se))
	# Only handle 1-block height transitions
	if max_h - min_h != 1:
		return {"ramp_id": -1, "ramp_y": -1}
	# Build 4-bit index: corners at max height are "high"
	var index := 0
	if h_nw == max_h: index += 1
	if h_ne == max_h: index += 2
	if h_sw == max_h: index += 4
	if h_se == max_h: index += 8
	return {"ramp_id": World.MARCHING_SQUARES_RAMP[index], "ramp_y": min_h + 1}


func _apply_ramp_blocks(coord: Vector3i, chunk: ChunkData) -> void:
	var chunk_size: int = World.CHUNK_SIZE
	var base_y: int = coord.y * chunk_size
	for lx in range(chunk_size):
		var wx: int = coord.x * chunk_size + lx
		for lz in range(chunk_size):
			var wz: int = coord.z * chunk_size + lz
			# Marching squares: sample 4 corner heights
			var h_nw := _height_at(wx, wz)
			var h_ne := _height_at(wx + 1, wz)
			var h_sw := _height_at(wx, wz + 1)
			var h_se := _height_at(wx + 1, wz + 1)
			var result := _get_marching_squares_ramp(h_nw, h_ne, h_sw, h_se)
			var ramp_id: int = result["ramp_id"]
			if ramp_id < 0:
				continue
			var low_corner := _inner_ramp_low_corner(ramp_id)
			if not low_corner.is_empty():
				var min_h := mini(mini(h_nw, h_ne), mini(h_sw, h_se))
				if not _inner_ramp_low_edges_clear(wx, wz, low_corner, min_h):
					continue
			var is_outer_corner := _is_outer_corner_id(ramp_id)
			var require_same_id := low_corner.is_empty() and not is_outer_corner
			var min_matches := RAMP_MIN_NEIGHBOR_MATCH
			if is_outer_corner:
				min_matches = 0
			if not _ramp_has_neighbor_support(wx, wz, ramp_id, h_nw, h_ne, h_sw, h_se, require_same_id, low_corner, min_matches):
				continue
			var ramp_y: int = result["ramp_y"]
			if ramp_y < base_y or ramp_y >= base_y + chunk_size:
				continue
			var ly: int = ramp_y - base_y
			var idx := world.chunk_index(lx, ly, lz)
			# Ramp replaces terrain at transition boundaries (don't check for air)
			chunk.blocks[idx] = ramp_id


func _apply_ramp_blocks_with_noise(
	job: Dictionary,
	blocks: PackedByteArray,
	flat_noise: FastNoiseLite,
	small_noise: FastNoiseLite,
	large_noise: FastNoiseLite,
	macro_noise: FastNoiseLite
) -> void:
	var coord: Vector3i = job.get("coord", Vector3i.ZERO)
	var chunk_size: int = int(job.get("chunk_size", World.CHUNK_SIZE))
	var world_size_y: int = int(job.get("world_size_y", 0))
	var sea_level: int = int(job.get("sea_level", 0))
	var base_y: int = coord.y * chunk_size
	for lx in range(chunk_size):
		var wx: int = coord.x * chunk_size + lx
		for lz in range(chunk_size):
			var wz: int = coord.z * chunk_size + lz
			# Marching squares: sample 4 corner heights
			var h_nw := _height_at_with_noise(wx, wz, sea_level, world_size_y, flat_noise, small_noise, large_noise, macro_noise)
			var h_ne := _height_at_with_noise(wx + 1, wz, sea_level, world_size_y, flat_noise, small_noise, large_noise, macro_noise)
			var h_sw := _height_at_with_noise(wx, wz + 1, sea_level, world_size_y, flat_noise, small_noise, large_noise, macro_noise)
			var h_se := _height_at_with_noise(wx + 1, wz + 1, sea_level, world_size_y, flat_noise, small_noise, large_noise, macro_noise)
			var result := _get_marching_squares_ramp(h_nw, h_ne, h_sw, h_se)
			var ramp_id: int = result["ramp_id"]
			if ramp_id < 0:
				continue
			var low_corner := _inner_ramp_low_corner(ramp_id)
			if not low_corner.is_empty():
				var min_h := mini(mini(h_nw, h_ne), mini(h_sw, h_se))
				if not _inner_ramp_low_edges_clear_with_noise(wx, wz, low_corner, min_h, sea_level, world_size_y, flat_noise, small_noise, large_noise, macro_noise):
					continue
			var is_outer_corner := _is_outer_corner_id(ramp_id)
			var require_same_id := low_corner.is_empty() and not is_outer_corner
			var min_matches := RAMP_MIN_NEIGHBOR_MATCH
			if is_outer_corner:
				min_matches = 0
			if not _ramp_has_neighbor_support_with_noise(wx, wz, ramp_id, h_nw, h_ne, h_sw, h_se, require_same_id, low_corner, min_matches, sea_level, world_size_y, flat_noise, small_noise, large_noise, macro_noise):
				continue
			var ramp_y: int = result["ramp_y"]
			if ramp_y < base_y or ramp_y >= base_y + chunk_size:
				continue
			var ly: int = ramp_y - base_y
			var idx: int = (lz * chunk_size + ly) * chunk_size + lx
			# Ramp replaces terrain at transition boundaries (don't check for air)
			blocks[idx] = ramp_id


func _height_at_with_noise(
	wx: int,
	wz: int,
	sea_level: int,
	world_size_y: int,
	flat_noise: FastNoiseLite,
	small_noise: FastNoiseLite,
	large_noise: FastNoiseLite,
	macro_noise: FastNoiseLite
) -> int:
	# Sample on coarse grid and bilinearly interpolate for smooth terrain
	var cell_x := floori(float(wx) / float(TERRAIN_CELL_SIZE))
	var cell_z := floori(float(wz) / float(TERRAIN_CELL_SIZE))
	var frac_x := (float(wx) - float(cell_x * TERRAIN_CELL_SIZE)) / float(TERRAIN_CELL_SIZE)
	var frac_z := (float(wz) - float(cell_z * TERRAIN_CELL_SIZE)) / float(TERRAIN_CELL_SIZE)
	# Sample heights at 4 cell corners
	var h00 := _raw_height_at(cell_x * TERRAIN_CELL_SIZE, cell_z * TERRAIN_CELL_SIZE, sea_level, world_size_y, flat_noise, small_noise, large_noise, macro_noise)
	var h10 := _raw_height_at((cell_x + 1) * TERRAIN_CELL_SIZE, cell_z * TERRAIN_CELL_SIZE, sea_level, world_size_y, flat_noise, small_noise, large_noise, macro_noise)
	var h01 := _raw_height_at(cell_x * TERRAIN_CELL_SIZE, (cell_z + 1) * TERRAIN_CELL_SIZE, sea_level, world_size_y, flat_noise, small_noise, large_noise, macro_noise)
	var h11 := _raw_height_at((cell_x + 1) * TERRAIN_CELL_SIZE, (cell_z + 1) * TERRAIN_CELL_SIZE, sea_level, world_size_y, flat_noise, small_noise, large_noise, macro_noise)
	# Bilinear interpolation
	var h0 := lerpf(h00, h10, frac_x)
	var h1 := lerpf(h01, h11, frac_x)
	var height := lerpf(h0, h1, frac_z)
	return clampi(int(round(height)), 0, world_size_y - 1)


func _ramp_has_neighbor_support(wx: int, wz: int, ramp_id: int, h_nw: int, h_ne: int, h_sw: int, h_se: int, require_same_id: bool, low_corner: String, min_matches: int) -> bool:
	var matches := 0
	var w_nw := _height_at(wx - 1, wz)
	var w_sw := _height_at(wx - 1, wz + 1)
	var w_result := _get_marching_squares_ramp(w_nw, h_nw, w_sw, h_sw)
	var w_id := int(w_result.get("ramp_id", -1))
	if w_id >= 0 and (not require_same_id or w_id == ramp_id):
		matches += 1
	var e_ne := _height_at(wx + 2, wz)
	var e_se := _height_at(wx + 2, wz + 1)
	var e_result := _get_marching_squares_ramp(h_ne, e_ne, h_se, e_se)
	var e_id := int(e_result.get("ramp_id", -1))
	if e_id >= 0 and (not require_same_id or e_id == ramp_id):
		matches += 1
	var n_nw := _height_at(wx, wz - 1)
	var n_ne := _height_at(wx + 1, wz - 1)
	var n_result := _get_marching_squares_ramp(n_nw, n_ne, h_nw, h_ne)
	var n_id := int(n_result.get("ramp_id", -1))
	if n_id >= 0 and (not require_same_id or n_id == ramp_id):
		matches += 1
	var s_sw := _height_at(wx, wz + 2)
	var s_se := _height_at(wx + 1, wz + 2)
	var s_result := _get_marching_squares_ramp(h_sw, h_se, s_sw, s_se)
	var s_id := int(s_result.get("ramp_id", -1))
	if s_id >= 0 and (not require_same_id or s_id == ramp_id):
		matches += 1
	if not low_corner.is_empty():
		var low_matches := 0
		match low_corner:
			"sw":
				if w_id >= 0:
					low_matches += 1
				if s_id >= 0:
					low_matches += 1
			"se":
				if e_id >= 0:
					low_matches += 1
				if s_id >= 0:
					low_matches += 1
			"nw":
				if w_id >= 0:
					low_matches += 1
				if n_id >= 0:
					low_matches += 1
			"ne":
				if e_id >= 0:
					low_matches += 1
				if n_id >= 0:
					low_matches += 1
		return low_matches >= INNER_RAMP_MIN_NEIGHBOR_MATCH
	return matches >= min_matches


func _ramp_has_neighbor_support_with_noise(
	wx: int,
	wz: int,
	ramp_id: int,
	h_nw: int,
	h_ne: int,
	h_sw: int,
	h_se: int,
	require_same_id: bool,
	low_corner: String,
	min_matches: int,
	sea_level: int,
	world_size_y: int,
	flat_noise: FastNoiseLite,
	small_noise: FastNoiseLite,
	large_noise: FastNoiseLite,
	macro_noise: FastNoiseLite
) -> bool:
	var matches := 0
	var w_nw := _height_at_with_noise(wx - 1, wz, sea_level, world_size_y, flat_noise, small_noise, large_noise, macro_noise)
	var w_sw := _height_at_with_noise(wx - 1, wz + 1, sea_level, world_size_y, flat_noise, small_noise, large_noise, macro_noise)
	var w_result := _get_marching_squares_ramp(w_nw, h_nw, w_sw, h_sw)
	var w_id := int(w_result.get("ramp_id", -1))
	if w_id >= 0 and (not require_same_id or w_id == ramp_id):
		matches += 1
	var e_ne := _height_at_with_noise(wx + 2, wz, sea_level, world_size_y, flat_noise, small_noise, large_noise, macro_noise)
	var e_se := _height_at_with_noise(wx + 2, wz + 1, sea_level, world_size_y, flat_noise, small_noise, large_noise, macro_noise)
	var e_result := _get_marching_squares_ramp(h_ne, e_ne, h_se, e_se)
	var e_id := int(e_result.get("ramp_id", -1))
	if e_id >= 0 and (not require_same_id or e_id == ramp_id):
		matches += 1
	var n_nw := _height_at_with_noise(wx, wz - 1, sea_level, world_size_y, flat_noise, small_noise, large_noise, macro_noise)
	var n_ne := _height_at_with_noise(wx + 1, wz - 1, sea_level, world_size_y, flat_noise, small_noise, large_noise, macro_noise)
	var n_result := _get_marching_squares_ramp(n_nw, n_ne, h_nw, h_ne)
	var n_id := int(n_result.get("ramp_id", -1))
	if n_id >= 0 and (not require_same_id or n_id == ramp_id):
		matches += 1
	var s_sw := _height_at_with_noise(wx, wz + 2, sea_level, world_size_y, flat_noise, small_noise, large_noise, macro_noise)
	var s_se := _height_at_with_noise(wx + 1, wz + 2, sea_level, world_size_y, flat_noise, small_noise, large_noise, macro_noise)
	var s_result := _get_marching_squares_ramp(h_sw, h_se, s_sw, s_se)
	var s_id := int(s_result.get("ramp_id", -1))
	if s_id >= 0 and (not require_same_id or s_id == ramp_id):
		matches += 1
	if not low_corner.is_empty():
		var low_matches := 0
		match low_corner:
			"sw":
				if w_id >= 0:
					low_matches += 1
				if s_id >= 0:
					low_matches += 1
			"se":
				if e_id >= 0:
					low_matches += 1
				if s_id >= 0:
					low_matches += 1
			"nw":
				if w_id >= 0:
					low_matches += 1
				if n_id >= 0:
					low_matches += 1
			"ne":
				if e_id >= 0:
					low_matches += 1
				if n_id >= 0:
					low_matches += 1
		return low_matches >= INNER_RAMP_MIN_NEIGHBOR_MATCH
	return matches >= min_matches


func _inner_ramp_low_corner(ramp_id: int) -> String:
	match ramp_id:
		World.INNER_SOUTHWEST_ID:
			return "sw"
		World.INNER_SOUTHEAST_ID:
			return "se"
		World.INNER_NORTHWEST_ID:
			return "nw"
		World.INNER_NORTHEAST_ID:
			return "ne"
		_:
			return ""


func _inner_ramp_low_edges_clear(wx: int, wz: int, low_corner: String, min_h: int) -> bool:
	match low_corner:
		"sw":
			return _height_at(wx - 1, wz + 1) <= min_h and _height_at(wx, wz + 2) <= min_h
		"se":
			return _height_at(wx + 2, wz + 1) <= min_h and _height_at(wx + 1, wz + 2) <= min_h
		"nw":
			return _height_at(wx - 1, wz) <= min_h and _height_at(wx, wz - 1) <= min_h
		"ne":
			return _height_at(wx + 2, wz) <= min_h and _height_at(wx + 1, wz - 1) <= min_h
	return true


func _inner_ramp_low_edges_clear_with_noise(
	wx: int,
	wz: int,
	low_corner: String,
	min_h: int,
	sea_level: int,
	world_size_y: int,
	flat_noise: FastNoiseLite,
	small_noise: FastNoiseLite,
	large_noise: FastNoiseLite,
	macro_noise: FastNoiseLite
) -> bool:
	match low_corner:
		"sw":
			return _height_at_with_noise(wx - 1, wz + 1, sea_level, world_size_y, flat_noise, small_noise, large_noise, macro_noise) <= min_h \
				and _height_at_with_noise(wx, wz + 2, sea_level, world_size_y, flat_noise, small_noise, large_noise, macro_noise) <= min_h
		"se":
			return _height_at_with_noise(wx + 2, wz + 1, sea_level, world_size_y, flat_noise, small_noise, large_noise, macro_noise) <= min_h \
				and _height_at_with_noise(wx + 1, wz + 2, sea_level, world_size_y, flat_noise, small_noise, large_noise, macro_noise) <= min_h
		"nw":
			return _height_at_with_noise(wx - 1, wz, sea_level, world_size_y, flat_noise, small_noise, large_noise, macro_noise) <= min_h \
				and _height_at_with_noise(wx, wz - 1, sea_level, world_size_y, flat_noise, small_noise, large_noise, macro_noise) <= min_h
		"ne":
			return _height_at_with_noise(wx + 2, wz, sea_level, world_size_y, flat_noise, small_noise, large_noise, macro_noise) <= min_h \
				and _height_at_with_noise(wx + 1, wz - 1, sea_level, world_size_y, flat_noise, small_noise, large_noise, macro_noise) <= min_h
	return true


func _is_outer_corner_id(ramp_id: int) -> bool:
	return ramp_id == World.RAMP_NORTHEAST_ID \
		or ramp_id == World.RAMP_NORTHWEST_ID \
		or ramp_id == World.RAMP_SOUTHEAST_ID \
		or ramp_id == World.RAMP_SOUTHWEST_ID


func _raw_height_at(
	wx: int,
	wz: int,
	sea_level: int,
	_world_size_y: int,
	flat_noise: FastNoiseLite,
	small_noise: FastNoiseLite,
	large_noise: FastNoiseLite,
	macro_noise: FastNoiseLite
) -> float:
	var macro_value := (macro_noise.get_noise_2d(float(wx), float(wz)) + 1.0) * 0.5
	var amplitude := FLAT_AMPLITUDE
	var n := 0.0
	if macro_value < MACRO_FLAT_CUTOFF:
		n = flat_noise.get_noise_2d(float(wx), float(wz))
		amplitude = FLAT_AMPLITUDE
	elif macro_value < MACRO_SMALL_CUTOFF:
		n = small_noise.get_noise_2d(float(wx), float(wz))
		amplitude = SMALL_AMPLITUDE
	else:
		n = large_noise.get_noise_2d(float(wx), float(wz))
		amplitude = LARGE_AMPLITUDE
	return float(sea_level) + n * float(amplitude)


func _configure_height_noises(
	seed: int,
	flat_noise: FastNoiseLite,
	small_noise: FastNoiseLite,
	large_noise: FastNoiseLite,
	macro_noise: FastNoiseLite
) -> void:
	_configure_noise(flat_noise, mix_seed(seed ^ 0x1f), FLAT_NOISE_FREQUENCY)
	_configure_noise(small_noise, mix_seed(seed ^ 0x2f), SMALL_NOISE_FREQUENCY)
	_configure_noise(large_noise, mix_seed(seed ^ 0x3f), LARGE_NOISE_FREQUENCY)
	_configure_noise(macro_noise, mix_seed(seed ^ 0x4f), MACRO_NOISE_FREQUENCY)


func _configure_noise(noise: FastNoiseLite, seed: int, frequency: float) -> void:
	noise.seed = seed
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	noise.frequency = frequency
