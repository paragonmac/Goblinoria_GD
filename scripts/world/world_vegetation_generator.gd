extends RefCounted
class_name WorldVegetationGenerator
## Places trees and flowers and maintains generated feature maps.

const WorldGenerationSharedScript = preload("res://scripts/world/world_generation_shared.gd")

const SEED_MASK := WorldGenerationSharedScript.SEED_MASK
const TREE_CELL_SIZE := 8
const TREE_RESERVATION_RADIUS := 2
const TREE_INFLUENCE_RADIUS := 7
const FLOWER_BASE_CHANCE := 0.008
const FLOWER_TREE_BONUS := 0.095
const FLOWER_BIOME_BONUS := 0.025

var world_seed: int = 0
var world_size_x: int = 0
var world_size_y: int = 0
var world_size_z: int = 0
var biome_plains: int = 0
var biome_forest: int = 0
var biome_wetland: int = 0
var biome_dry: int = 0
var biome_cold: int = 0

var elevation := PackedInt32Array()
var moisture := PackedFloat32Array()
var temperature := PackedFloat32Array()
var biome := PackedByteArray()
var tree_density := PackedFloat32Array()
var feature_reserved := PackedByteArray()

var trees_placed: int = 0
var flowers_placed: int = 0


func configure(
	seed: int,
	size_x: int,
	size_y: int,
	size_z: int,
	elevation_map: PackedInt32Array,
	moisture_map: PackedFloat32Array,
	temperature_map: PackedFloat32Array,
	biome_map: PackedByteArray,
	tree_density_map: PackedFloat32Array,
	feature_reserved_map: PackedByteArray,
	biome_ids: Dictionary
) -> void:
	world_seed = seed
	world_size_x = size_x
	world_size_y = size_y
	world_size_z = size_z
	elevation = elevation_map
	moisture = moisture_map
	temperature = temperature_map
	biome = biome_map
	tree_density = tree_density_map
	feature_reserved = feature_reserved_map
	biome_plains = int(biome_ids.get("plains", 0))
	biome_forest = int(biome_ids.get("forest", 0))
	biome_wetland = int(biome_ids.get("wetland", 0))
	biome_dry = int(biome_ids.get("dry", 0))
	biome_cold = int(biome_ids.get("cold", 0))
	trees_placed = 0
	flowers_placed = 0


func place_trees(volume: PackedByteArray) -> void:
	for cell_z in range(int(ceil(float(world_size_z) / float(TREE_CELL_SIZE)))):
		for cell_x in range(int(ceil(float(world_size_x) / float(TREE_CELL_SIZE)))):
			var local_x: int = cell_x * TREE_CELL_SIZE + _hash_range(cell_x, cell_z, 0x7101, TREE_CELL_SIZE)
			var local_z: int = cell_z * TREE_CELL_SIZE + _hash_range(cell_x, cell_z, 0x7102, TREE_CELL_SIZE)
			if local_x < 1 or local_z < 1 or local_x >= world_size_x - 1 or local_z >= world_size_z - 1:
				continue
			var map_idx: int = _map_index(local_x, local_z)
			var biome_id: int = biome[map_idx]
			var density: float = _tree_chance_for(map_idx)
			if _rand01(local_x, local_z, 0x7103) > density:
				continue
			if _local_slope(local_x, local_z) > 1:
				continue
			if _has_reservation_near(local_x, local_z, TREE_RESERVATION_RADIUS):
				continue
			var surface_y: int = elevation[map_idx]
			if surface_y + 8 >= world_size_y:
				continue
			var surface_block: int = volume[_volume_index(local_x, surface_y, local_z)]
			if surface_block != World.BLOCK_ID_GRASS and surface_block != World.BLOCK_ID_MOSS:
				continue
			if biome_id == biome_dry and _rand01(local_x, local_z, 0x7104) > 0.12:
				continue
			_place_tree_at(volume, local_x, surface_y + 1, local_z, 3 + _hash_range(local_x, local_z, 0x7105, 3))
			trees_placed += 1
			_reserve_radius(local_x, local_z, TREE_RESERVATION_RADIUS)
			_paint_tree_density(local_x, local_z, TREE_INFLUENCE_RADIUS)


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
			var chance: float = FLOWER_BASE_CHANCE + tree_density[map_idx] * FLOWER_TREE_BONUS
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


func get_tree_density() -> PackedFloat32Array:
	return tree_density


func get_feature_reserved() -> PackedByteArray:
	return feature_reserved


func get_stats() -> Dictionary:
	return {
		"trees_placed": trees_placed,
		"flowers_placed": flowers_placed,
	}


func _place_tree_at(volume: PackedByteArray, local_x: int, base_y: int, local_z: int, trunk_height: int) -> void:
	for y in range(base_y, mini(base_y + trunk_height, world_size_y)):
		_set_volume_block(volume, local_x, y, local_z, World.BLOCK_ID_LOG)
	var crown_y: int = base_y + trunk_height
	for dy in range(-1, 3):
		var y: int = crown_y + dy
		if y < 0 or y >= world_size_y:
			continue
		var radius: int = 2 if dy <= 1 else 1
		for dz in range(-radius, radius + 1):
			for dx in range(-radius, radius + 1):
				if abs(dx) + abs(dz) > radius + 1:
					continue
				if dx == 0 and dz == 0 and dy < 1:
					continue
				var target_x: int = local_x + dx
				var target_z: int = local_z + dz
				if not _is_local_xz_valid(target_x, target_z):
					continue
				var idx: int = _volume_index(target_x, y, target_z)
				if volume[idx] == World.BLOCK_ID_AIR:
					volume[idx] = World.BLOCK_ID_LEAVES


func _set_volume_block(volume: PackedByteArray, local_x: int, y: int, local_z: int, block_id: int) -> void:
	if not _is_local_block_valid(local_x, y, local_z):
		return
	volume[_volume_index(local_x, y, local_z)] = block_id


func _tree_chance_for(map_idx: int) -> float:
	var biome_id: int = biome[map_idx]
	var moist: float = moisture[map_idx]
	var temp: float = temperature[map_idx]
	var base: float = 0.0
	if biome_id == biome_forest:
		base = 0.82
	elif biome_id == biome_plains:
		base = 0.28
	elif biome_id == biome_wetland:
		base = 0.22
	elif biome_id == biome_dry:
		base = 0.08
	elif biome_id == biome_cold:
		base = 0.06
	return clampf(base * clampf(moist + 0.20, 0.0, 1.0) * clampf(temp + 0.35, 0.0, 1.0), 0.0, 0.95)


func _local_slope(local_x: int, local_z: int) -> int:
	var center: int = elevation[_map_index(local_x, local_z)]
	var max_delta: int = 0
	for dz in range(-1, 2):
		for dx in range(-1, 2):
			var x: int = clampi(local_x + dx, 0, world_size_x - 1)
			var z: int = clampi(local_z + dz, 0, world_size_z - 1)
			max_delta = maxi(max_delta, abs(elevation[_map_index(x, z)] - center))
	return max_delta


func _has_reservation_near(local_x: int, local_z: int, radius: int) -> bool:
	for dz in range(-radius, radius + 1):
		for dx in range(-radius, radius + 1):
			var x: int = local_x + dx
			var z: int = local_z + dz
			if not _is_local_xz_valid(x, z):
				continue
			if feature_reserved[_map_index(x, z)] != 0:
				return true
	return false


func _reserve_radius(local_x: int, local_z: int, radius: int) -> void:
	for dz in range(-radius, radius + 1):
		for dx in range(-radius, radius + 1):
			var x: int = local_x + dx
			var z: int = local_z + dz
			if _is_local_xz_valid(x, z):
				feature_reserved[_map_index(x, z)] = 1


func _paint_tree_density(local_x: int, local_z: int, radius: int) -> void:
	for dz in range(-radius, radius + 1):
		for dx in range(-radius, radius + 1):
			var dist_sq: int = dx * dx + dz * dz
			if dist_sq > radius * radius:
				continue
			var x: int = local_x + dx
			var z: int = local_z + dz
			if not _is_local_xz_valid(x, z):
				continue
			var idx: int = _map_index(x, z)
			var dist: float = sqrt(float(dist_sq))
			tree_density[idx] = clampf(tree_density[idx] + (1.0 - dist / float(radius + 1)), 0.0, 1.0)


func _hash_range(a: int, b: int, salt: int, range_size: int) -> int:
	if range_size <= 0:
		return 0
	return _hash_u31(a, 0, b, salt) % range_size


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


func _is_local_xz_valid(local_x: int, local_z: int) -> bool:
	return local_x >= 0 and local_x < world_size_x and local_z >= 0 and local_z < world_size_z


func _is_local_block_valid(local_x: int, y: int, local_z: int) -> bool:
	return _is_local_xz_valid(local_x, local_z) and y >= 0 and y < world_size_y
