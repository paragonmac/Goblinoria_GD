extends RefCounted
class_name WorldTerrainRampBuilder
## Applies generated ramp blocks to a chunk buffer.

const WorldRampRulesScript = preload("res://scripts/world/world_ramp_rules.gd")
const WorldTerrainHeightSamplerScript = preload("res://scripts/world/world_terrain_height_sampler.gd")


static func apply_blocks(
	coord: Vector3i,
	blocks: PackedByteArray,
	chunk_size: int,
	sea_level: int,
	world_size_y: int,
	flat_noise: FastNoiseLite,
	small_noise: FastNoiseLite,
	large_noise: FastNoiseLite,
	macro_noise: FastNoiseLite
) -> void:
	var base_y: int = coord.y * chunk_size
	for lx in range(chunk_size):
		var wx: int = coord.x * chunk_size + lx
		for lz in range(chunk_size):
			var wz: int = coord.z * chunk_size + lz
			var h_nw := _height_at(wx, wz, sea_level, world_size_y, flat_noise, small_noise, large_noise, macro_noise)
			var h_ne := _height_at(wx + 1, wz, sea_level, world_size_y, flat_noise, small_noise, large_noise, macro_noise)
			var h_sw := _height_at(wx, wz + 1, sea_level, world_size_y, flat_noise, small_noise, large_noise, macro_noise)
			var h_se := _height_at(wx + 1, wz + 1, sea_level, world_size_y, flat_noise, small_noise, large_noise, macro_noise)
			var result := WorldRampRulesScript.marching_squares_ramp(h_nw, h_ne, h_sw, h_se)
			var ramp_id: int = result["ramp_id"]
			if ramp_id < 0:
				continue
			var low_corner := WorldRampRulesScript.inner_ramp_low_corner(ramp_id)
			if not low_corner.is_empty():
				var min_h := mini(mini(h_nw, h_ne), mini(h_sw, h_se))
				if not WorldRampRulesScript.inner_ramp_low_edges_clear(
					wx,
					wz,
					low_corner,
					min_h,
					sea_level,
					world_size_y,
					flat_noise,
					small_noise,
					large_noise,
					macro_noise
				):
					continue
			var is_outer_corner := WorldRampRulesScript.is_outer_corner_id(ramp_id)
			var require_same_id := low_corner.is_empty() and not is_outer_corner
			var min_matches := WorldRampRulesScript.RAMP_MIN_NEIGHBOR_MATCH
			if is_outer_corner:
				min_matches = 0
			if not WorldRampRulesScript.ramp_has_neighbor_support(
				wx,
				wz,
				ramp_id,
				h_nw,
				h_ne,
				h_sw,
				h_se,
				require_same_id,
				low_corner,
				min_matches,
				sea_level,
				world_size_y,
				flat_noise,
				small_noise,
				large_noise,
				macro_noise
			):
				continue
			var ramp_y: int = result["ramp_y"]
			if ramp_y < base_y or ramp_y >= base_y + chunk_size:
				continue
			var ly: int = ramp_y - base_y
			var idx: int = (lz * chunk_size + ly) * chunk_size + lx
			blocks[idx] = ramp_id


static func _height_at(
	wx: int,
	wz: int,
	sea_level: int,
	world_size_y: int,
	flat_noise: FastNoiseLite,
	small_noise: FastNoiseLite,
	large_noise: FastNoiseLite,
	macro_noise: FastNoiseLite
) -> int:
	return WorldTerrainHeightSamplerScript.height_at(
		wx,
		wz,
		sea_level,
		world_size_y,
		flat_noise,
		small_noise,
		large_noise,
		macro_noise
	)
