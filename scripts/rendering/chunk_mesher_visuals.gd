extends RefCounted
class_name ChunkMesherVisuals

const COLOR_MIN := 0.0
const COLOR_MAX := 1.0
const SHADE_TOP := 1.0
const SHADE_BOTTOM := 0.6
const SHADE_SIDE := 0.75
const SHADE_FRONT_BACK := 0.82
const SHADE_THRESHOLD := 0.5
const BLOCK_NOISE_OFFSET_2 := Vector3i(17, 31, 47)
const BLOCK_NOISE_OFFSET_3 := Vector3i(59, 73, 101)
const BLOCK_JITTER := 0.08
const BLOCK_ALBEDO_MULT := 0.4
const NOISE_CENTER := 0.5
const HASH_X := 73856093
const HASH_Y := 19349663
const HASH_Z := 83492791
const HASH_SHIFT := 13
const HASH_MASK := 0x7fffffff
const BLOCK_NOISE_MOD := 1024
const BLOCK_NOISE_DIV := 1023.0


func block_color_from_table(color_table: PackedColorArray, block_id: int, wx: int, wy: int, wz: int) -> Color:
	var base := Color(1.0, 1.0, 1.0, 1.0)
	if block_id >= 0 and block_id < color_table.size():
		base = color_table[block_id]
	base = Color(base.r * BLOCK_ALBEDO_MULT, base.g * BLOCK_ALBEDO_MULT, base.b * BLOCK_ALBEDO_MULT, base.a)

	var n1 := block_noise(wx, wy, wz)
	var n2 := block_noise(wx + BLOCK_NOISE_OFFSET_2.x, wy + BLOCK_NOISE_OFFSET_2.y, wz + BLOCK_NOISE_OFFSET_2.z)
	var n3 := block_noise(wx + BLOCK_NOISE_OFFSET_3.x, wy + BLOCK_NOISE_OFFSET_3.y, wz + BLOCK_NOISE_OFFSET_3.z)
	var jitter := BLOCK_JITTER
	return Color(
		clampf(base.r + (n1 - NOISE_CENTER) * jitter, COLOR_MIN, COLOR_MAX),
		clampf(base.g + (n2 - NOISE_CENTER) * jitter, COLOR_MIN, COLOR_MAX),
		clampf(base.b + (n3 - NOISE_CENTER) * jitter, COLOR_MIN, COLOR_MAX),
		base.a
	)


func block_noise(wx: int, wy: int, wz: int) -> float:
	var h: int = ((wx * HASH_X) & HASH_MASK) ^ ((wy * HASH_Y) & HASH_MASK) ^ ((wz * HASH_Z) & HASH_MASK)
	h = (h ^ (h >> HASH_SHIFT)) & HASH_MASK
	return float(h % BLOCK_NOISE_MOD) / BLOCK_NOISE_DIV


func face_shade(normal: Vector3) -> float:
	if normal.y > SHADE_THRESHOLD:
		return SHADE_TOP
	if normal.y < -SHADE_THRESHOLD:
		return SHADE_BOTTOM
	if abs(normal.x) > SHADE_THRESHOLD:
		return SHADE_SIDE
	return SHADE_FRONT_BACK