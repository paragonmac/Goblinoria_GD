extends RefCounted
class_name WorldCaveGenerator
## Carves deterministic cave walkers into a generated world volume.

const WorldGenerationSharedScript = preload("res://scripts/world/world_generation_shared.gd")

const SEED_MASK := WorldGenerationSharedScript.SEED_MASK
const CAVE_START_CELL_SIZE := 32
const CAVE_START_CHANCE := 0.55
const CAVE_ENERGY_MIN := 100
const CAVE_ENERGY_MAX := 1000
const CAVE_MAX_ACTIVE_WALKERS := 128
const CAVE_SURFACE_CLEARANCE := 8
const CAVE_BOTTOM_CLEARANCE := 4
const CAVE_STEP_LENGTH := 1.0
const CAVE_RADIUS_MIN := 1.15
const CAVE_RADIUS_MAX := 2.35
const CAVE_VERTICAL_RADIUS_SCALE := 0.72
const CAVE_TURN_STRENGTH := 0.36
const CAVE_VERTICAL_DRIFT := 0.22
const CAVE_BRANCH_CHANCE := 0.008
const CAVE_BRANCH_MIN_ENERGY := 90
const CAVE_BRANCH_ENERGY_SCALE := 0.35
const CAVE_ROOM_CHANCE := 0.003
const CAVE_ROOM_MIN_ENERGY := 140
const CAVE_ROOM_RADIUS_MIN := 3.0
const CAVE_ROOM_RADIUS_MAX := 6.5
const CAVE_ROOM_VERTICAL_SCALE := 0.58
const CAVE_DEPTH_ENERGY_BONUS := 0.55
const CAVE_DEPTH_RADIUS_BONUS := 0.35
const CAVE_DEPTH_BRANCH_CHANCE_BONUS := 0.006
const CAVE_DEPTH_BRANCH_ENERGY_BONUS := 0.10
const CAVE_DEPTH_ROOM_CHANCE_BONUS := 0.005
const CAVE_DEPTH_ROOM_RADIUS_BONUS := 0.35

var world_seed: int = 0
var world_size_x: int = 0
var world_size_y: int = 0
var world_size_z: int = 0
var elevation := PackedInt32Array()

var cave_systems_started: int = 0
var cave_branches_spawned: int = 0
var cave_rooms_carved: int = 0
var cave_carved_cells: int = 0
var cave_walker_steps: int = 0
var cave_brush_calls: int = 0


func carve(
	volume: PackedByteArray,
	elevation_map: PackedInt32Array,
	seed: int,
	size_x: int,
	size_y: int,
	size_z: int
) -> Dictionary:
	world_seed = seed
	world_size_x = size_x
	world_size_y = size_y
	world_size_z = size_z
	elevation = elevation_map
	_reset_stats()
	_carve_caves(volume)
	return {
		"cave_systems_started": cave_systems_started,
		"cave_branches_spawned": cave_branches_spawned,
		"cave_rooms_carved": cave_rooms_carved,
		"cave_carved_cells": cave_carved_cells,
		"cave_walker_steps": cave_walker_steps,
		"cave_brush_calls": cave_brush_calls,
	}


func _reset_stats() -> void:
	cave_systems_started = 0
	cave_branches_spawned = 0
	cave_rooms_carved = 0
	cave_carved_cells = 0
	cave_walker_steps = 0
	cave_brush_calls = 0


func _carve_caves(volume: PackedByteArray) -> void:
	var cell_count_x: int = int(ceil(float(world_size_x) / float(CAVE_START_CELL_SIZE)))
	var cell_count_z: int = int(ceil(float(world_size_z) / float(CAVE_START_CELL_SIZE)))
	var cave_queue: Array = []
	for cell_z in range(cell_count_z):
		for cell_x in range(cell_count_x):
			if _rand01(cell_x, cell_z, 0xC001) > CAVE_START_CHANCE:
				continue
			var cell_min_x: int = cell_x * CAVE_START_CELL_SIZE
			var cell_min_z: int = cell_z * CAVE_START_CELL_SIZE
			var cell_width: int = mini(CAVE_START_CELL_SIZE, world_size_x - cell_min_x)
			var cell_depth: int = mini(CAVE_START_CELL_SIZE, world_size_z - cell_min_z)
			if cell_width <= 0 or cell_depth <= 0:
				continue
			var local_x: int = cell_min_x + _hash_range(cell_x, cell_z, 0xC002, cell_width)
			var local_z: int = cell_min_z + _hash_range(cell_x, cell_z, 0xC003, cell_depth)
			var min_y: int = CAVE_BOTTOM_CLEARANCE
			var max_y: int = _cave_max_y_for_column(local_x, local_z)
			if max_y <= min_y:
				continue
			var local_y: int = min_y + _hash_range(cell_x, cell_z, 0xC004, max_y - min_y + 1)
			var angle: float = _rand01(cell_x, cell_z, 0xC005) * TAU
			var direction: Vector3 = Vector3(cos(angle), _rand_signed(cell_x, cell_z, 0xC006) * CAVE_VERTICAL_DRIFT, sin(angle)).normalized()
			var base_energy: int = CAVE_ENERGY_MIN + _hash_range(cell_x, cell_z, 0xC007, CAVE_ENERGY_MAX - CAVE_ENERGY_MIN + 1)
			var start_depth_factor: float = _cave_depth_factor(local_x, local_y, local_z)
			var energy: int = int(float(base_energy) * (1.0 + start_depth_factor * CAVE_DEPTH_ENERGY_BONUS))
			var salt: int = _hash_u31(cell_x, local_y, cell_z, 0xC008)
			cave_queue.append(_make_cave_walker(float(local_x), float(local_y), float(local_z), direction, energy, salt))
			cave_systems_started += 1
	while not cave_queue.is_empty():
		var walker: Dictionary = cave_queue.pop_back()
		_run_cave_walker(volume, walker, cave_queue)


func _make_cave_walker(x: float, y: float, z: float, direction: Vector3, energy: int, salt: int) -> Dictionary:
	if direction.length_squared() <= 0.0001:
		direction = Vector3(1.0, 0.0, 0.0)
	direction = direction.normalized()
	return {
		"x": x,
		"y": y,
		"z": z,
		"dx": direction.x,
		"dy": direction.y,
		"dz": direction.z,
		"energy": energy,
		"salt": salt,
	}


func _run_cave_walker(volume: PackedByteArray, walker: Dictionary, cave_queue: Array) -> void:
	var x: float = float(walker.get("x", 0.0))
	var y: float = float(walker.get("y", 0.0))
	var z: float = float(walker.get("z", 0.0))
	var direction := Vector3(
		float(walker.get("dx", 1.0)),
		float(walker.get("dy", 0.0)),
		float(walker.get("dz", 0.0))
	)
	if direction.length_squared() <= 0.0001:
		direction = Vector3(1.0, 0.0, 0.0)
	direction = direction.normalized()
	var energy: int = int(walker.get("energy", 0))
	var salt: int = int(walker.get("salt", 0))
	var step: int = 0
	while energy > 0:
		var local_x: int = int(round(x))
		var local_z: int = int(round(z))
		if not _is_local_xz_valid(local_x, local_z):
			break
		var max_cave_y: int = _cave_max_y_for_column(local_x, local_z)
		if max_cave_y <= CAVE_BOTTOM_CLEARANCE:
			break
		if y > float(max_cave_y):
			y = float(max_cave_y)
			direction.y = minf(direction.y, -0.08)
		elif y < float(CAVE_BOTTOM_CLEARANCE):
			y = float(CAVE_BOTTOM_CLEARANCE)
			direction.y = maxf(direction.y, 0.08)
		var local_y: int = clampi(int(round(y)), CAVE_BOTTOM_CLEARANCE, max_cave_y)
		cave_walker_steps += 1
		var depth_factor: float = _cave_depth_factor(local_x, local_y, local_z)
		var radius_bias: float = _rand01(local_x + step, local_z + salt, 0xC120)
		var energy_bias: float = clampf(float(energy) / float(CAVE_ENERGY_MAX), 0.0, 1.0)
		var radius: float = lerpf(CAVE_RADIUS_MIN, CAVE_RADIUS_MAX, radius_bias * 0.75 + energy_bias * 0.25)
		radius *= 1.0 + depth_factor * CAVE_DEPTH_RADIUS_BONUS
		_carve_cave_brush(volume, local_x, local_y, local_z, radius, radius * CAVE_VERTICAL_RADIUS_SCALE)
		var room_chance: float = CAVE_ROOM_CHANCE + depth_factor * CAVE_DEPTH_ROOM_CHANCE_BONUS
		if energy > CAVE_ROOM_MIN_ENERGY and _rand01(local_x + salt, step, 0xC220) < room_chance:
			var room_bias: float = _rand01(local_z + salt, step + local_x, 0xC221)
			var room_radius: float = lerpf(CAVE_ROOM_RADIUS_MIN, CAVE_ROOM_RADIUS_MAX, room_bias)
			room_radius *= 1.0 + depth_factor * CAVE_DEPTH_ROOM_RADIUS_BONUS
			_carve_cave_brush(volume, local_x, local_y, local_z, room_radius, room_radius * CAVE_ROOM_VERTICAL_SCALE)
			cave_rooms_carved += 1
			energy -= int(room_radius * 6.0)
		if energy > CAVE_BRANCH_MIN_ENERGY * 2 and cave_queue.size() < CAVE_MAX_ACTIVE_WALKERS:
			var branch_chance: float = CAVE_BRANCH_CHANCE + depth_factor * CAVE_DEPTH_BRANCH_CHANCE_BONUS
			if _rand01(local_x + salt, local_z + step, 0xC260) < branch_chance:
				var branch_energy_scale: float = CAVE_BRANCH_ENERGY_SCALE + depth_factor * CAVE_DEPTH_BRANCH_ENERGY_BONUS
				var branch_energy: int = clampi(int(float(energy) * branch_energy_scale), CAVE_BRANCH_MIN_ENERGY, energy - 20)
				var branch_turn: float = _rand_signed(local_z + step, local_x + salt, 0xC261) * PI * 0.85
				var branch_vertical: float = _rand_signed(local_x - step, local_z + salt, 0xC262) * CAVE_VERTICAL_DRIFT
				var branch_direction: Vector3 = _turn_cave_direction(direction, branch_turn, branch_vertical)
				var branch_salt: int = _hash_u31(local_x, step, local_z, salt ^ 0xC263)
				cave_queue.append(_make_cave_walker(x, y, z, branch_direction, branch_energy, branch_salt))
				cave_branches_spawned += 1
				energy -= int(float(branch_energy) * 0.35)
		var turn: float = _rand_signed(local_x + step, local_z + salt, 0xC300) * CAVE_TURN_STRENGTH
		var vertical_target: float = _rand_signed(local_x - step, local_z + salt, 0xC301) * CAVE_VERTICAL_DRIFT
		direction = _turn_cave_direction(direction, turn, vertical_target)
		x += direction.x * CAVE_STEP_LENGTH
		y += direction.y * CAVE_STEP_LENGTH
		z += direction.z * CAVE_STEP_LENGTH
		if x < -1.0 or x > float(world_size_x) or z < -1.0 or z > float(world_size_z):
			break
		energy -= 1
		step += 1


func _turn_cave_direction(direction: Vector3, turn: float, vertical_target: float) -> Vector3:
	var xz := Vector2(direction.x, direction.z)
	if xz.length_squared() <= 0.0001:
		xz = Vector2(1.0, 0.0)
	xz = xz.normalized().rotated(turn)
	var vertical: float = lerpf(direction.y, vertical_target, 0.18)
	return Vector3(xz.x, vertical, xz.y).normalized()


func _carve_cave_brush(volume: PackedByteArray, center_x: int, center_y: int, center_z: int, radius_xz: float, radius_y: float) -> void:
	cave_brush_calls += 1
	var safe_radius_xz: float = maxf(radius_xz, 0.5)
	var safe_radius_y: float = maxf(radius_y, 0.5)
	var radius_xz_int: int = int(ceil(safe_radius_xz))
	var radius_y_int: int = int(ceil(safe_radius_y))
	for local_z in range(center_z - radius_xz_int, center_z + radius_xz_int + 1):
		for local_x in range(center_x - radius_xz_int, center_x + radius_xz_int + 1):
			if not _is_local_xz_valid(local_x, local_z):
				continue
			var max_y: int = _cave_max_y_for_column(local_x, local_z)
			if max_y < CAVE_BOTTOM_CLEARANCE:
				continue
			var dx: float = float(local_x - center_x) / safe_radius_xz
			var dz: float = float(local_z - center_z) / safe_radius_xz
			var horizontal_distance: float = dx * dx + dz * dz
			if horizontal_distance > 1.0:
				continue
			for local_y in range(center_y - radius_y_int, center_y + radius_y_int + 1):
				if not _is_cave_y_valid(local_y, max_y):
					continue
				var dy: float = float(local_y - center_y) / safe_radius_y
				if horizontal_distance + dy * dy > 1.0:
					continue
				var idx: int = _volume_index(local_x, local_y, local_z)
				if volume[idx] != World.BLOCK_ID_AIR:
					volume[idx] = World.BLOCK_ID_AIR
					cave_carved_cells += 1


func _hash_range(a: int, b: int, salt: int, range_size: int) -> int:
	if range_size <= 0:
		return 0
	return _hash_u31(a, 0, b, salt) % range_size


func _rand01(a: int, b: int, salt: int) -> float:
	return float(_hash_u31(a, 0, b, salt) & 0xffff) / 65535.0


func _rand_signed(a: int, b: int, salt: int) -> float:
	return _rand01(a, b, salt) * 2.0 - 1.0


func _cave_depth_factor(local_x: int, local_y: int, local_z: int) -> float:
	var max_y: int = _cave_max_y_for_column(local_x, local_z)
	if max_y < CAVE_BOTTOM_CLEARANCE:
		return 0.0
	var cave_span: float = maxf(1.0, float(max_y - CAVE_BOTTOM_CLEARANCE))
	return clampf(float(max_y - local_y) / cave_span, 0.0, 1.0)


func _cave_max_y_for_column(local_x: int, local_z: int) -> int:
	if not _is_local_xz_valid(local_x, local_z):
		return -1
	var surface_y: int = elevation[_map_index(local_x, local_z)]
	return mini(surface_y - CAVE_SURFACE_CLEARANCE, world_size_y - 1)


func _is_cave_y_valid(local_y: int, max_y: int) -> bool:
	return local_y >= CAVE_BOTTOM_CLEARANCE and local_y <= max_y and local_y < world_size_y


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
