extends RefCounted
class_name WorldRampRules
## Shared ramp block selection rules for generated terrain.

const WorldTerrainHeightSamplerScript = preload("res://scripts/world/world_terrain_height_sampler.gd")

const RAMP_MIN_NEIGHBOR_MATCH := 1
const INNER_RAMP_MIN_NEIGHBOR_MATCH := 0


static func marching_squares_ramp(h_nw: int, h_ne: int, h_sw: int, h_se: int) -> Dictionary:
	var min_h := mini(mini(h_nw, h_ne), mini(h_sw, h_se))
	var max_h := maxi(maxi(h_nw, h_ne), maxi(h_sw, h_se))
	if max_h - min_h != 1:
		return {"ramp_id": -1, "ramp_y": -1}
	var index := 0
	if h_nw == max_h:
		index += 1
	if h_ne == max_h:
		index += 2
	if h_sw == max_h:
		index += 4
	if h_se == max_h:
		index += 8
	return {"ramp_id": World.MARCHING_SQUARES_RAMP[index], "ramp_y": min_h + 1}


static func inner_ramp_low_corner(ramp_id: int) -> String:
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


static func is_outer_corner_id(ramp_id: int) -> bool:
	return ramp_id == World.RAMP_NORTHEAST_ID \
		or ramp_id == World.RAMP_NORTHWEST_ID \
		or ramp_id == World.RAMP_SOUTHEAST_ID \
		or ramp_id == World.RAMP_SOUTHWEST_ID


static func ramp_has_neighbor_support(
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
	var w_nw := _height_at(wx - 1, wz, sea_level, world_size_y, flat_noise, small_noise, large_noise, macro_noise)
	var w_sw := _height_at(wx - 1, wz + 1, sea_level, world_size_y, flat_noise, small_noise, large_noise, macro_noise)
	var w_result := marching_squares_ramp(w_nw, h_nw, w_sw, h_sw)
	var w_id := int(w_result.get("ramp_id", -1))
	if w_id >= 0 and (not require_same_id or w_id == ramp_id):
		matches += 1
	var e_ne := _height_at(wx + 2, wz, sea_level, world_size_y, flat_noise, small_noise, large_noise, macro_noise)
	var e_se := _height_at(wx + 2, wz + 1, sea_level, world_size_y, flat_noise, small_noise, large_noise, macro_noise)
	var e_result := marching_squares_ramp(h_ne, e_ne, h_se, e_se)
	var e_id := int(e_result.get("ramp_id", -1))
	if e_id >= 0 and (not require_same_id or e_id == ramp_id):
		matches += 1
	var n_nw := _height_at(wx, wz - 1, sea_level, world_size_y, flat_noise, small_noise, large_noise, macro_noise)
	var n_ne := _height_at(wx + 1, wz - 1, sea_level, world_size_y, flat_noise, small_noise, large_noise, macro_noise)
	var n_result := marching_squares_ramp(n_nw, n_ne, h_nw, h_ne)
	var n_id := int(n_result.get("ramp_id", -1))
	if n_id >= 0 and (not require_same_id or n_id == ramp_id):
		matches += 1
	var s_sw := _height_at(wx, wz + 2, sea_level, world_size_y, flat_noise, small_noise, large_noise, macro_noise)
	var s_se := _height_at(wx + 1, wz + 2, sea_level, world_size_y, flat_noise, small_noise, large_noise, macro_noise)
	var s_result := marching_squares_ramp(h_sw, h_se, s_sw, s_se)
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


static func inner_ramp_low_edges_clear(
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
			return _height_at(wx - 1, wz + 1, sea_level, world_size_y, flat_noise, small_noise, large_noise, macro_noise) <= min_h \
				and _height_at(wx, wz + 2, sea_level, world_size_y, flat_noise, small_noise, large_noise, macro_noise) <= min_h
		"se":
			return _height_at(wx + 2, wz + 1, sea_level, world_size_y, flat_noise, small_noise, large_noise, macro_noise) <= min_h \
				and _height_at(wx + 1, wz + 2, sea_level, world_size_y, flat_noise, small_noise, large_noise, macro_noise) <= min_h
		"nw":
			return _height_at(wx - 1, wz, sea_level, world_size_y, flat_noise, small_noise, large_noise, macro_noise) <= min_h \
				and _height_at(wx, wz - 1, sea_level, world_size_y, flat_noise, small_noise, large_noise, macro_noise) <= min_h
		"ne":
			return _height_at(wx + 2, wz, sea_level, world_size_y, flat_noise, small_noise, large_noise, macro_noise) <= min_h \
				and _height_at(wx + 1, wz - 1, sea_level, world_size_y, flat_noise, small_noise, large_noise, macro_noise) <= min_h
	return true


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
