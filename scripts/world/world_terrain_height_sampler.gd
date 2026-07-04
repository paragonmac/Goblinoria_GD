extends RefCounted
class_name WorldTerrainHeightSampler
## Shared terrain height sampling from configured generation noises.

const WorldGenerationSharedScript = preload("res://scripts/world/world_generation_shared.gd")


static func height_at(
	wx: int,
	wz: int,
	sea_level: int,
	world_size_y: int,
	flat_noise: FastNoiseLite,
	small_noise: FastNoiseLite,
	large_noise: FastNoiseLite,
	macro_noise: FastNoiseLite,
	clamp_macro_noise: bool = false
) -> int:
	var cell_size := WorldGenerationSharedScript.TERRAIN_CELL_SIZE
	var cell_x := floori(float(wx) / float(cell_size))
	var cell_z := floori(float(wz) / float(cell_size))
	var frac_x := (float(wx) - float(cell_x * cell_size)) / float(cell_size)
	var frac_z := (float(wz) - float(cell_z * cell_size)) / float(cell_size)
	var h00 := raw_height_at(
		cell_x * cell_size,
		cell_z * cell_size,
		sea_level,
		flat_noise,
		small_noise,
		large_noise,
		macro_noise,
		clamp_macro_noise
	)
	var h10 := raw_height_at(
		(cell_x + 1) * cell_size,
		cell_z * cell_size,
		sea_level,
		flat_noise,
		small_noise,
		large_noise,
		macro_noise,
		clamp_macro_noise
	)
	var h01 := raw_height_at(
		cell_x * cell_size,
		(cell_z + 1) * cell_size,
		sea_level,
		flat_noise,
		small_noise,
		large_noise,
		macro_noise,
		clamp_macro_noise
	)
	var h11 := raw_height_at(
		(cell_x + 1) * cell_size,
		(cell_z + 1) * cell_size,
		sea_level,
		flat_noise,
		small_noise,
		large_noise,
		macro_noise,
		clamp_macro_noise
	)
	var h0 := lerpf(h00, h10, frac_x)
	var h1 := lerpf(h01, h11, frac_x)
	return clampi(int(round(lerpf(h0, h1, frac_z))), 0, world_size_y - 1)


static func raw_height_at(
	wx: int,
	wz: int,
	sea_level: int,
	flat_noise: FastNoiseLite,
	small_noise: FastNoiseLite,
	large_noise: FastNoiseLite,
	macro_noise: FastNoiseLite,
	clamp_macro_noise: bool = false
) -> float:
	var macro_value := (macro_noise.get_noise_2d(float(wx), float(wz)) + 1.0) * 0.5
	if clamp_macro_noise:
		macro_value = clampf(macro_value, 0.0, 1.0)
	var amplitude := WorldGenerationSharedScript.FLAT_AMPLITUDE
	var n := 0.0
	if macro_value < WorldGenerationSharedScript.MACRO_FLAT_CUTOFF:
		n = flat_noise.get_noise_2d(float(wx), float(wz))
		amplitude = WorldGenerationSharedScript.FLAT_AMPLITUDE
	elif macro_value < WorldGenerationSharedScript.MACRO_SMALL_CUTOFF:
		n = small_noise.get_noise_2d(float(wx), float(wz))
		amplitude = WorldGenerationSharedScript.SMALL_AMPLITUDE
	else:
		n = large_noise.get_noise_2d(float(wx), float(wz))
		amplitude = WorldGenerationSharedScript.LARGE_AMPLITUDE
	return float(sea_level) + n * float(amplitude)
