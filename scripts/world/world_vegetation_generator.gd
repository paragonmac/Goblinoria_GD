extends RefCounted
class_name WorldVegetationGenerator
## Places flowers and maintains generated feature maps.

const WorldGenerationSharedScript = preload("res://scripts/world/world_generation_shared.gd")

const SEED_MASK := WorldGenerationSharedScript.SEED_MASK
const FLOWER_BASE_CHANCE := 0.008
const FLOWER_BIOME_BONUS := 0.025

var world_seed: int = 0
var world_size_x: int = 0
var world_size_y: int = 0
var world_size_z: int = 0
var biome_plains: int = 0
var biome_forest: int = 0

var elevation := PackedInt32Array()
var biome := PackedByteArray()
var feature_reserved := PackedByteArray()

var flowers_placed: int = 0


func configure(
	seed: int,
	size_x: int,
	size_y: int,
	size_z: int,
	elevation_map: PackedInt32Array,
	biome_map: PackedByteArray,
	feature_reserved_map: PackedByteArray,
	biome_ids: Dictionary
) -> void:
	world_seed = seed
	world_size_x = size_x
	world_size_y = size_y
	world_size_z = size_z
	elevation = elevation_map
	biome = biome_map
	feature_reserved = feature_reserved_map
	biome_plains = int(biome_ids.get("plains", 0))
	biome_forest = int(biome_ids.get("forest", 0))
	flowers_placed = 0


func place_flowers(volume: PackedByteArray) -> void:
	for local_z in range(1, world_size_z - 1):
		for local_x in range(1, world_size_x - 1):
			var map_idx: int = _map_index(local_x, local_z)
			if feature_reserved[map_idx] != 0:
				continue
			var surface_y: int = elevation[map_idx]
			var surface_idx: int = _volume_index(local_x, surface_y, local_z)
			var surface_block: int = volume[surface_idx]
			if surface_block != World.BLOCK_ID_GRASS and surface_block != World.BLOCK_ID_MOSS:
				continue
			var chance: float = FLOWER_BASE_CHANCE
			if biome[map_idx] == biome_forest or biome[map_idx] == biome_plains:
				chance += FLOWER_BIOME_BONUS
			chance = clampf(chance, 0.0, 0.24)
			if _rand01(local_x, local_z, 0x9101) <= chance:
				volume[surface_idx] = World.BLOCK_ID_FLOWER
				flowers_placed += 1


func final_cleanup(volume: PackedByteArray) -> void:
	for local_z in range(world_size_z):
		for local_x in range(world_size_x):
			var surface_y: int = elevation[_map_index(local_x, local_z)]
			if surface_y < 0 or surface_y >= world_size_y:
				continue
			var idx: int = _volume_index(local_x, surface_y, local_z)
			if volume[idx] == World.BLOCK_ID_FLOWER and surface_y + 1 < world_size_y:
				var above_idx: int = _volume_index(local_x, surface_y + 1, local_z)
				if volume[above_idx] != World.BLOCK_ID_AIR:
					volume[idx] = World.BLOCK_ID_GRASS


func get_feature_reserved() -> PackedByteArray:
	return feature_reserved


func get_stats() -> Dictionary:
	return {
		"flowers_placed": flowers_placed,
	}


func _rand01(a: int, b: int, salt: int) -> float:
	return float(_hash_u31(a, 0, b, salt) & 0xffff) / 65535.0


func _hash_u31(a: int, y: int, b: int, salt: int) -> int:
	var h: int = world_seed ^ salt
	h = WorldGenerationSharedScript.mix_seed(h ^ (a * 374761393))
	h = WorldGenerationSharedScript.mix_seed(h ^ (y * 668265263))
	h = WorldGenerationSharedScript.mix_seed(h ^ (b * 2246822519))
	return h & SEED_MASK


func _map_index(local_x: int, local_z: int) -> int:
	return local_z * world_size_x + local_x


func _volume_index(local_x: int, y: int, local_z: int) -> int:
	return (local_z * world_size_y + y) * world_size_x + local_x
