extends RefCounted
class_name WorldGenerationShared
## Shared deterministic generation constants and seed helpers.

const SEED_MIX_FACTOR := 0x45d9f3b
const SEED_MASK := 0x7fffffff

const TERRAIN_CELL_SIZE := 4
const FLAT_NOISE_FREQUENCY := 0.02
const SMALL_NOISE_FREQUENCY := 0.01
const LARGE_NOISE_FREQUENCY := 0.005
const MACRO_NOISE_FREQUENCY := 0.0015

const FLAT_AMPLITUDE := 1
const SMALL_AMPLITUDE := 4
const LARGE_AMPLITUDE := 10
const MACRO_FLAT_CUTOFF := 0.88
const MACRO_SMALL_CUTOFF := 0.96

const TOPSOIL_DEPTH_MIN := 2
const TOPSOIL_DEPTH_MAX := 4


static func mix_seed(value: int) -> int:
	var v: int = value & 0xffffffff
	v = int(((v >> 16) ^ v) * SEED_MIX_FACTOR) & 0xffffffff
	v = int(((v >> 16) ^ v) * SEED_MIX_FACTOR) & 0xffffffff
	v = int((v >> 16) ^ v) & 0xffffffff
	return v & SEED_MASK


static func configure_noise(noise: FastNoiseLite, seed: int, frequency: float) -> void:
	noise.seed = seed
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	noise.frequency = frequency


static func configure_height_noises(
	seed: int,
	flat_noise: FastNoiseLite,
	small_noise: FastNoiseLite,
	large_noise: FastNoiseLite,
	macro_noise: FastNoiseLite
) -> void:
	configure_noise(flat_noise, mix_seed(seed ^ 0x1f), FLAT_NOISE_FREQUENCY)
	configure_noise(small_noise, mix_seed(seed ^ 0x2f), SMALL_NOISE_FREQUENCY)
	configure_noise(large_noise, mix_seed(seed ^ 0x3f), LARGE_NOISE_FREQUENCY)
	configure_noise(macro_noise, mix_seed(seed ^ 0x4f), MACRO_NOISE_FREQUENCY)
