extends RefCounted
class_name WorldGenerator
## Handles chunk generation, seeding, and terrain algorithms.

#region Constants
const SEED_MIX_FACTOR := 0x45d9f3b
const SEED_MASK := 0x7fffffff
const TOPSOIL_DEPTH_MIN := 2
const TOPSOIL_DEPTH_MAX := 4
const SEA_LEVEL_FILL_OFFSET := 1
#endregion

#region State
var world: World
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
	var max_y: int = min(world.sea_level + SEA_LEVEL_FILL_OFFSET, world.world_size_y)
	if base_y >= max_y:
		chunk.generated = true
		world.touch_chunk(chunk)
		return
	var fill_y_max: int = min(chunk_size, max_y - base_y)
	var rng := RandomNumberGenerator.new()
	rng.seed = chunk_seed_from_coord(coord)
	var dirt_depth: int = rng.randi_range(TOPSOIL_DEPTH_MIN, TOPSOIL_DEPTH_MAX)
	var surface_y: int = min(world.sea_level, world.world_size_y - 1)
	for ly in range(fill_y_max):
		var world_y: int = base_y + ly
		for lx in range(chunk_size):
			for lz in range(chunk_size):
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
