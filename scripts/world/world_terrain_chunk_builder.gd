extends RefCounted
class_name WorldTerrainChunkBuilder
## Builds the base terrain and ramps for one chunk.

const WorldGenerationSharedScript = preload("res://scripts/world/world_generation_shared.gd")
const WorldTerrainHeightSamplerScript = preload("res://scripts/world/world_terrain_height_sampler.gd")
const WorldTerrainRampBuilderScript = preload("res://scripts/world/world_terrain_ramp_builder.gd")

const MAX_HEIGHT_AMPLITUDE := WorldGenerationSharedScript.LARGE_AMPLITUDE


static func can_contain_terrain(
	coord: Vector3i,
	chunk_size: int,
	sea_level: int,
	world_size_y: int
) -> bool:
	var base_y: int = coord.y * chunk_size
	var max_height: int = min(sea_level + MAX_HEIGHT_AMPLITUDE, world_size_y - 1)
	return base_y <= max_height


static func build_blocks(
	coord: Vector3i,
	chunk_size: int,
	world_seed: int,
	sea_level: int,
	world_size_y: int,
	block_air: int,
	block_default: int,
	block_grass: int,
	block_dirt: int,
	flat_noise: FastNoiseLite,
	small_noise: FastNoiseLite,
	large_noise: FastNoiseLite,
	macro_noise: FastNoiseLite
) -> PackedByteArray:
	if not can_contain_terrain(coord, chunk_size, sea_level, world_size_y):
		return PackedByteArray()
	var blocks := PackedByteArray()
	blocks.resize(chunk_size * chunk_size * chunk_size)
	blocks.fill(block_air)
	fill_blocks(
		coord,
		blocks,
		chunk_size,
		world_seed,
		sea_level,
		world_size_y,
		block_default,
		block_grass,
		block_dirt,
		flat_noise,
		small_noise,
		large_noise,
		macro_noise
	)
	return blocks


static func fill_blocks(
	coord: Vector3i,
	blocks: PackedByteArray,
	chunk_size: int,
	world_seed: int,
	sea_level: int,
	world_size_y: int,
	block_default: int,
	block_grass: int,
	block_dirt: int,
	flat_noise: FastNoiseLite,
	small_noise: FastNoiseLite,
	large_noise: FastNoiseLite,
	macro_noise: FastNoiseLite
) -> void:
	var base_y: int = coord.y * chunk_size
	var rng := RandomNumberGenerator.new()
	rng.seed = chunk_seed_from_coord(coord, world_seed)
	var dirt_depth: int = rng.randi_range(
		WorldGenerationSharedScript.TOPSOIL_DEPTH_MIN,
		WorldGenerationSharedScript.TOPSOIL_DEPTH_MAX
	)
	for lx in range(chunk_size):
		var wx: int = coord.x * chunk_size + lx
		for lz in range(chunk_size):
			var wz: int = coord.z * chunk_size + lz
			var surface_y := WorldTerrainHeightSamplerScript.height_at(
				wx,
				wz,
				sea_level,
				world_size_y,
				flat_noise,
				small_noise,
				large_noise,
				macro_noise
			)
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
	WorldTerrainRampBuilderScript.apply_blocks(
		coord,
		blocks,
		chunk_size,
		sea_level,
		world_size_y,
		flat_noise,
		small_noise,
		large_noise,
		macro_noise
	)


static func chunk_seed_from_coord(coord: Vector3i, world_seed: int) -> int:
	var h: int = WorldGenerationSharedScript.mix_seed(world_seed ^ coord.x)
	h = WorldGenerationSharedScript.mix_seed(h ^ coord.y)
	h = WorldGenerationSharedScript.mix_seed(h ^ coord.z)
	return h
