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
