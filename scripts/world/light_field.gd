extends RefCounted
class_name LightField
## CPU light and exploration mirror. Leaves and flowers transmit light: although
## both are marked solid in blocks.csv, the light prototype treated these
## non-terrain solids as transparent. Other solid registry blocks occlude;
## ramps, terrain slopes and stair flights transmit like the terrain mesher.

var NX := 256
var NZ := 256
var NY := 256
var LAYER_SIZE := NX * NZ
var VOLUME := LAYER_SIZE * NY
var _shift_x := 8
var _shift_layer := 16
const UNGENERATED := 255
const RegistryScript = preload("res://scripts/block_registry.gd")

var light := PackedByteArray()
var explored := PackedByteArray()
var display := PackedByteArray()
var block_mirror := PackedByteArray()
var opacity := PackedByteArray()
var dirty_light_layers: Dictionary = {}
var dirty_explored_layers: Dictionary = {}
var last_build_ms := 0.0
## Increments on every build(); the GPU sync rebinds textures when it changes.
var build_count := 0
var events_processed := 0
var bfs_cells := 0
var explored_count := 0
var _bulk_build := false
var _world
var _sources: Dictionary = {}
var _events: Array[Dictionary] = []


func build(world) -> void:
	_world = world
	NX = World.WORLD_CHUNKS_X * World.CHUNK_SIZE
	NZ = World.WORLD_CHUNKS_Z * World.CHUNK_SIZE
	NY = World.WORLD_CHUNKS_Y * World.CHUNK_SIZE
	LAYER_SIZE = NX * NZ
	VOLUME = LAYER_SIZE * NY
	_shift_x = int(round(log(float(NX)) / log(2.0)))
	_shift_layer = int(round(log(float(LAYER_SIZE)) / log(2.0)))
	var started := Time.get_ticks_usec()
	block_mirror.resize(VOLUME)
	light.resize(VOLUME)
	light.fill(0)
	explored.resize(VOLUME)
	explored.fill(0)
	display.resize(VOLUME)
	display.fill(0)
	explored_count = 0
	_build_opacity()
	dirty_light_layers.clear()
	dirty_explored_layers.clear()
	for y in range(NY):
		dirty_light_layers[y] = true
		dirty_explored_layers[y] = true
	_bulk_build = true
	var chunk_size: int = World.CHUNK_SIZE
	var chunk_x_offset: int = -World.WORLD_MIN_CHUNK_X * chunk_size
	var chunk_z_offset: int = -World.WORLD_MIN_CHUNK_Z * chunk_size
	var all_chunks_generated: bool = world.chunks.size() == World.WORLD_CHUNKS_X * World.WORLD_CHUNKS_Y * World.WORLD_CHUNKS_Z
	if all_chunks_generated:
		for coord: Vector3i in world.chunks:
			var chunk = world.chunks[coord]
			if chunk == null or not chunk.generated or coord.x < World.WORLD_MIN_CHUNK_X or coord.x > World.WORLD_MAX_CHUNK_X or coord.y < 0 or coord.y >= World.WORLD_CHUNKS_Y or coord.z < World.WORLD_MIN_CHUNK_Z or coord.z > World.WORLD_MAX_CHUNK_Z:
				all_chunks_generated = false
				break
	if not all_chunks_generated:
		block_mirror.fill(UNGENERATED)
	for coord: Vector3i in world.chunks:
		var chunk = world.chunks[coord]
		var base_x: int = coord.x * chunk_size + chunk_x_offset
		var base_y: int = coord.y * chunk_size
		var base_z: int = coord.z * chunk_size + chunk_z_offset
		if all_chunks_generated:
			var full_chunk_blocks: PackedByteArray = chunk.blocks
			for lz in range(chunk_size):
				var z: int = base_z + lz
				for ly in range(chunk_size):
					var y: int = base_y + ly
					var src: int = (lz * chunk_size + ly) * chunk_size
					var dst: int = (y * NZ + z) * NX + base_x
					block_mirror.encode_u64(dst, full_chunk_blocks.decode_u64(src))
			continue
		if chunk == null or not chunk.generated:
			continue
		var partial_chunk_blocks: PackedByteArray = chunk.blocks
		for lz in range(chunk_size):
			var z: int = base_z + lz
			if z < 0 or z >= NZ:
				continue
			for ly in range(chunk_size):
				var y: int = base_y + ly
				if y < 0 or y >= NY:
					continue
				var src: int = (lz * chunk_size + ly) * chunk_size
				var dst: int = (y * NZ + z) * NX + base_x
				if base_x >= 0 and base_x + chunk_size <= NX:
					block_mirror.encode_u64(dst, partial_chunk_blocks.decode_u64(src))
				else:
					for lx in range(chunk_size):
						var x: int = base_x + lx
						if x >= 0 and x < NX:
							block_mirror[dst + lx] = partial_chunk_blocks[src + lx]
	_events.clear()
	_build_sky(true)
	var source_queue := PackedInt32Array()
	for source in _sources:
		_set_channel(int(source), 1, int(_sources[source]))
		source_queue.append(int(source))
	_run_add(source_queue, 1)
	_bulk_build = false
	build_count += 1
	last_build_ms = float(Time.get_ticks_usec() - started) / 1000.0


func notify_block_changed(x: int, y: int, z: int, old_id: int, new_id: int) -> void:
	if not _valid(x, y, z) or block_mirror.size() != VOLUME:
		return
	var idx := _index(x - World.WORLD_MIN_BLOCK_X, y, z - World.WORLD_MIN_BLOCK_Z)
	block_mirror[idx] = clampi(new_id, 0, 255)
	_events.append({"kind": "block", "index": idx, "old": old_id, "new": new_id})


func notify_chunk_loaded(coord: Vector3i) -> void:
	if _world == null or block_mirror.size() != VOLUME:
		return
	var chunk = _world.get_chunk(coord)
	if chunk == null or not chunk.generated:
		return
	var base_x: int = coord.x * World.CHUNK_SIZE - World.WORLD_MIN_BLOCK_X
	var base_y: int = coord.y * World.CHUNK_SIZE
	var base_z: int = coord.z * World.CHUNK_SIZE - World.WORLD_MIN_BLOCK_Z
	for lz in range(World.CHUNK_SIZE):
		for ly in range(World.CHUNK_SIZE):
			var y := base_y + ly
			if y < 0 or y >= NY:
				continue
			for lx in range(World.CHUNK_SIZE):
				var x := base_x + lx
				var z := base_z + lz
				if x >= 0 and x < NX and z >= 0 and z < NZ:
					block_mirror[_index(x, y, z)] = chunk.blocks[(lz * 8 + ly) * 8 + lx]
	_events.append({"kind": "chunk", "coord": coord})


func process_events(budget_usec: int = 2000) -> int:
	var started := Time.get_ticks_usec()
	var processed := 0
	while not _events.is_empty():
		if processed > 0 and Time.get_ticks_usec() - started >= maxi(1, budget_usec):
			break
		var event: Dictionary = _events.pop_front()
		match event.kind:
			"source_add":
				_relight_block_source(int(event.index), int(event.level))
			"source_remove":
				_remove_block_source(int(event.index))
			"block":
				_relight_changed_cell(int(event.index))
			"chunk":
				_relight_chunk_region(event.coord)
		processed += 1
		events_processed += 1
	return processed


func add_light_source(pos: Vector3i, level: int) -> void:
	if not _valid(pos.x, pos.y, pos.z):
		return
	var idx := _index(pos.x - World.WORLD_MIN_BLOCK_X, pos.y, pos.z - World.WORLD_MIN_BLOCK_Z)
	_sources[idx] = clampi(level, 0, 15)
	_events.append({"kind": "source_add", "index": idx, "level": clampi(level, 0, 15)})


func has_light_source(pos: Vector3i) -> bool:
	if not _valid(pos.x, pos.y, pos.z):
		return false
	var idx := _index(pos.x - World.WORLD_MIN_BLOCK_X, pos.y, pos.z - World.WORLD_MIN_BLOCK_Z)
	return _sources.has(idx)


func remove_light_source(pos: Vector3i) -> void:
	if not _valid(pos.x, pos.y, pos.z):
		return
	var idx := _index(pos.x - World.WORLD_MIN_BLOCK_X, pos.y, pos.z - World.WORLD_MIN_BLOCK_Z)
	_sources.erase(idx)
	_events.append({"kind": "source_remove", "index": idx})


func get_sky(x: int, y: int, z: int) -> int:
	return int(light[_world_index(x, y, z)] & 15) if _valid(x, y, z) and light.size() == VOLUME else 0


func get_block_light(x: int, y: int, z: int) -> int:
	return int(light[_world_index(x, y, z)] >> 4) if _valid(x, y, z) and light.size() == VOLUME else 0


func get_level(x: int, y: int, z: int) -> int:
	return maxi(get_sky(x, y, z), get_block_light(x, y, z))


func is_explored(x: int, y: int, z: int) -> bool:
	return _valid(x, y, z) and explored.size() == VOLUME and explored[_world_index(x, y, z)] != 0


func mark_explored(x: int, y: int, z: int) -> void:
	if not _valid(x, y, z) or explored.size() != VOLUME:
		return
	_set_explored(_world_index(x, y, z))


## Marks raw field indices explored (goblin light batches its cells).
func mark_explored_indices(indices: PackedInt32Array) -> void:
	if explored.size() != VOLUME:
		return
	for idx in indices:
		_set_explored(idx)


## Unions a persisted fog snapshot with exploration discovered during this build.
func apply_explored(snapshot: PackedByteArray) -> void:
	if snapshot.size() != VOLUME or explored.size() != VOLUME:
		return
	for idx in VOLUME:
		if snapshot[idx] != 0 and explored[idx] == 0:
			explored[idx] = 255
			explored_count += 1
			dirty_explored_layers[idx >> _shift_layer] = true


func pending_events() -> int:
	return _events.size()


func take_dirty_layers(max_layers: int, near_y: int) -> Array[int]:
	var layers := {}
	for y in dirty_light_layers:
		layers[y] = true
	for y in dirty_explored_layers:
		layers[y] = true
	var result: Array[int] = []
	var candidates: Array = layers.keys()
	candidates.sort_custom(func(a, b): return abs(int(a) - near_y) < abs(int(b) - near_y))
	for y in candidates:
		if result.size() >= maxi(0, max_layers):
			break
		result.append(int(y))
		dirty_light_layers.erase(y)
		dirty_explored_layers.erase(y)
	return result


func layer_slice(channel: String, y: int) -> PackedByteArray:
	if y < 0 or y >= NY or light.size() != VOLUME:
		var output := PackedByteArray()
		output.resize(LAYER_SIZE)
		return output
	var start := y * LAYER_SIZE
	if channel == "explored":
		return explored.slice(start, start + LAYER_SIZE)
	return display.slice(start, start + LAYER_SIZE)


func _build_opacity() -> void:
	var registry = RegistryScript.new()
	registry.load_from_csv(World.BLOCK_DATA_PATH)
	opacity.resize(256)
	for id in range(256):
		var opaque := registry.is_solid(id)
		if World.RAMP_BLOCK_IDS.has(id) or World.STAIR_FLIGHT_BLOCK_IDS.has(id) or id == 13 or id == 14:
			opaque = false
		opacity[id] = 1 if opaque else 0
	opacity[UNGENERATED] = 1


func _build_sky(bulk_build: bool = false) -> void:
	var heights := PackedInt32Array()
	heights.resize(LAYER_SIZE)
	for z in range(NZ):
		for x in range(NX):
			var y := NY - 1
			var idx := _index(x, y, z)
			while y >= 0 and opacity[block_mirror[idx]] == 0:
				y -= 1
				idx -= LAYER_SIZE
			heights[z * NX + x] = y + 1
	for z in range(NZ):
		for x in range(NX):
			var height: int = heights[z * NX + x]
			var idx := _index(x, NY - 1, z)
			for y in range(NY - 1, height - 1, -1):
				if bulk_build:
					light[idx] = 15
					display[idx] = 255
					if explored[idx] == 0:
						explored[idx] = 255
						explored_count += 1
				else:
					_set_channel(idx, 0, 15)
				idx -= LAYER_SIZE
			if bulk_build and height > 0 and height < NY and explored[idx] == 0:
				explored[idx] = 255
				explored_count += 1
			if bulk_build and x < NX - 1:
				var neighbor_height: int = heights[z * NX + x + 1]
				for y in range(height, neighbor_height):
					var neighbor_idx := _index(x + 1, y, z)
					if explored[neighbor_idx] == 0:
						explored[neighbor_idx] = 255
						explored_count += 1
			if bulk_build and x > 0:
				var neighbor_height: int = heights[z * NX + x - 1]
				for y in range(height, neighbor_height):
					var neighbor_idx := _index(x - 1, y, z)
					if explored[neighbor_idx] == 0:
						explored[neighbor_idx] = 255
						explored_count += 1
			if bulk_build and z < NZ - 1:
				var neighbor_height: int = heights[(z + 1) * NX + x]
				for y in range(height, neighbor_height):
					var neighbor_idx := _index(x, y, z + 1)
					if explored[neighbor_idx] == 0:
						explored[neighbor_idx] = 255
						explored_count += 1
			if bulk_build and z > 0:
				var neighbor_height: int = heights[(z - 1) * NX + x]
				for y in range(height, neighbor_height):
					var neighbor_idx := _index(x, y, z - 1)
					if explored[neighbor_idx] == 0:
						explored[neighbor_idx] = 255
						explored_count += 1
	var queue := PackedInt32Array()
	var spill_directions := [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]
	for z in range(NZ):
		for x in range(NX):
			var h: int = heights[z * NX + x]
			for d: Vector2i in spill_directions:
				var nx: int = x + d.x
				var nz: int = z + d.y
				if nx < 0 or nx >= NX or nz < 0 or nz >= NZ:
					continue
				var neighbor_height: int = heights[nz * NX + nx]
				if h >= neighbor_height:
					continue
				for y in range(h, neighbor_height):
					var source_idx := _index(x, y, z)
					var neighbor_idx := _index(nx, y, nz)
					if opacity[block_mirror[neighbor_idx]] == 0:
						queue.append(source_idx)
	_run_add(queue, 0)


func _rebuild_all() -> void:
	if light.size() != VOLUME:
		return
	light.fill(0)
	display.fill(0)
	_build_sky()
	var source_queue := PackedInt32Array()
	for source in _sources:
		_set_channel(int(source), 1, int(_sources[source]))
		source_queue.append(int(source))
	_run_add(source_queue, 1)


func _relight_changed_cell(idx: int) -> void:
	var current: int = light[idx]
	if opacity[block_mirror[idx]] != 0 and (current >> 4) == 0 and (current & 15) == 15 and not _sources.has(idx):
		_set_channel(idx, 0, 0)
		return
	var x := idx & (NX - 1)
	var z := (idx >> _shift_x) & (NZ - 1)
	_rebuild_light_region(x, z, x, z)


func _relight_chunk_region(coord: Vector3i) -> void:
	var x0: int = coord.x * World.CHUNK_SIZE - World.WORLD_MIN_BLOCK_X
	var z0: int = coord.z * World.CHUNK_SIZE - World.WORLD_MIN_BLOCK_Z
	_rebuild_light_region(x0, z0, x0 + World.CHUNK_SIZE - 1, z0 + World.CHUNK_SIZE - 1)


func _rebuild_light_region(x0: int, z0: int, x1: int, z1: int) -> void:
	x0 = clampi(x0 - 15, 0, NX - 1)
	z0 = clampi(z0 - 15, 0, NZ - 1)
	x1 = clampi(x1 + 15, 0, NX - 1)
	z1 = clampi(z1 + 15, 0, NZ - 1)
	var sky_queue := PackedInt32Array()
	var block_queue := PackedInt32Array()
	for z in range(z0, z1 + 1):
		for x in range(x0, x1 + 1):
			var base := _index(x, 0, z)
			for y in range(NY):
				_set_channel(base + y * LAYER_SIZE, 0, 0)
				_set_channel(base + y * LAYER_SIZE, 1, 0)
			var y := NY - 1
			var idx := base + y * LAYER_SIZE
			while y >= 0 and opacity[block_mirror[idx]] == 0:
				_set_channel(idx, 0, 15)
				sky_queue.append(idx)
				y -= 1
				idx -= LAYER_SIZE
	for source in _sources:
		var source_idx: int = int(source)
		var sx := source_idx & (NX - 1)
		var sz := (source_idx >> _shift_x) & (NZ - 1)
		if sx >= x0 and sx <= x1 and sz >= z0 and sz <= z1:
			_set_channel(source_idx, 1, int(_sources[source]))
			block_queue.append(source_idx)
	_add_region_boundary_seeds(x0, z0, x1, z1, sky_queue, block_queue)
	_run_add(sky_queue, 0)
	_run_add(block_queue, 1)


func _add_region_boundary_seeds(x0: int, z0: int, x1: int, z1: int, sky_queue: PackedInt32Array, block_queue: PackedInt32Array) -> void:
	for z in range(maxi(0, z0 - 1), mini(NZ - 1, z1 + 1) + 1):
		for x in range(maxi(0, x0 - 1), mini(NX - 1, x1 + 1) + 1):
			if x >= x0 and x <= x1 and z >= z0 and z <= z1:
				continue
			for y in range(NY):
				var idx := _index(x, y, z)
				if (light[idx] & 15) > 1:
					sky_queue.append(idx)
				if (light[idx] >> 4) > 1:
					block_queue.append(idx)


func _relight_block_source(idx: int, level: int) -> void:
	_set_channel(idx, 1, level)
	_run_add(PackedInt32Array([idx]), 1)


func _remove_block_source(idx: int) -> void:
	var old := int(light[idx] >> 4)
	if old <= 0:
		return
	_set_channel(idx, 1, 0)
	var remove_q := PackedInt32Array([idx])
	var remove_levels := PackedByteArray([old])
	var relight := PackedInt32Array()
	var head := 0
	while head < remove_q.size():
		var ci: int = remove_q[head]
		var lv: int = remove_levels[head]
		head += 1
		var x: int = ci & (NX - 1)
		var z: int = (ci >> _shift_x) & (NZ - 1)
		var y: int = ci >> _shift_layer
		var ni: int
		if x < NX - 1:
			ni = ci + 1
			var nl: int = light[ni] >> 4
			if nl > 0 and nl < lv:
				_set_channel(ni, 1, 0)
				remove_q.append(ni)
				remove_levels.append(nl)
			elif nl >= lv: relight.append(ni)
		if x > 0:
			ni = ci - 1
			var nl: int = light[ni] >> 4
			if nl > 0 and nl < lv:
				_set_channel(ni, 1, 0)
				remove_q.append(ni)
				remove_levels.append(nl)
			elif nl >= lv: relight.append(ni)
		if z < NZ - 1:
			ni = ci + NX
			var nl: int = light[ni] >> 4
			if nl > 0 and nl < lv:
				_set_channel(ni, 1, 0)
				remove_q.append(ni)
				remove_levels.append(nl)
			elif nl >= lv: relight.append(ni)
		if z > 0:
			ni = ci - NX
			var nl: int = light[ni] >> 4
			if nl > 0 and nl < lv:
				_set_channel(ni, 1, 0)
				remove_q.append(ni)
				remove_levels.append(nl)
			elif nl >= lv: relight.append(ni)
		if y < NY - 1:
			ni = ci + LAYER_SIZE
			var nl: int = light[ni] >> 4
			if nl > 0 and nl < lv:
				_set_channel(ni, 1, 0)
				remove_q.append(ni)
				remove_levels.append(nl)
			elif nl >= lv: relight.append(ni)
		if y > 0:
			ni = ci - LAYER_SIZE
			var nl: int = light[ni] >> 4
			if nl > 0 and nl < lv:
				_set_channel(ni, 1, 0)
				remove_q.append(ni)
				remove_levels.append(nl)
			elif nl >= lv: relight.append(ni)
	_run_add(relight, 1)


func _run_add(queue: PackedInt32Array, channel: int) -> void:
	var head := 0
	while head < queue.size():
		var idx: int = queue[head]
		head += 1
		if channel == 1 and opacity[block_mirror[idx]] != 0:
			_set_channel(idx, 1, 0)
			continue
		var current: int = int(light[idx] >> 4) if channel == 1 else int(light[idx] & 15)
		var next_level := current - 1
		if next_level <= 0:
			continue
		var x: int = idx & (NX - 1)
		var z: int = (idx >> _shift_x) & (NZ - 1)
		var y: int = idx >> _shift_layer
		for direction in range(6):
			var ni := -1
			match direction:
				0: if x < NX - 1: ni = idx + 1
				1: if x > 0: ni = idx - 1
				2: if z < NZ - 1: ni = idx + NX
				3: if z > 0: ni = idx - NX
				4: if y < NY - 1: ni = idx + LAYER_SIZE
				5: if y > 0: ni = idx - LAYER_SIZE
			if ni < 0 or opacity[block_mirror[ni]] != 0:
				continue
			var old: int = light[ni]
			var neighbor_level: int = int(old >> 4) if channel == 1 else int(old & 15)
			if neighbor_level >= next_level:
				continue
			if _bulk_build:
				var updated: int = ((old & 15) | (next_level << 4)) if channel == 1 else ((old & 240) | next_level)
				light[ni] = updated
				display[ni] = maxi(updated & 15, updated >> 4) * 17
				_mark_explored_neighborhood(ni)
			else:
				_set_channel(ni, channel, next_level)
			queue.append(ni)
			bfs_cells += 1


func _mark_explored_neighborhood(idx: int) -> void:
	var x: int = idx & (NX - 1)
	var z: int = (idx >> _shift_x) & (NZ - 1)
	var y: int = idx >> _shift_layer
	if explored[idx] == 0:
		explored[idx] = 255
		explored_count += 1
	if x < NX - 1 and explored[idx + 1] == 0:
		explored[idx + 1] = 255
		explored_count += 1
	if x > 0 and explored[idx - 1] == 0:
		explored[idx - 1] = 255
		explored_count += 1
	if z < NZ - 1 and explored[idx + NX] == 0:
		explored[idx + NX] = 255
		explored_count += 1
	if z > 0 and explored[idx - NX] == 0:
		explored[idx - NX] = 255
		explored_count += 1
	if y < NY - 1 and explored[idx + LAYER_SIZE] == 0:
		explored[idx + LAYER_SIZE] = 255
		explored_count += 1
	if y > 0 and explored[idx - LAYER_SIZE] == 0:
		explored[idx - LAYER_SIZE] = 255
		explored_count += 1


func _set_explored(idx: int) -> void:
	if explored[idx] != 0:
		return
	explored[idx] = 255
	explored_count += 1
	var layer: int = idx >> _shift_layer
	if not dirty_explored_layers.has(layer):
		dirty_explored_layers[layer] = true


func _set_channel(idx: int, channel: int, value: int) -> void:
	value = clampi(value, 0, 15)
	var old: int = light[idx]
	var updated := ((old & 15) | (value << 4)) if channel == 1 else ((old & 240) | value)
	if updated == old:
		return
	light[idx] = updated
	var display_level: int = maxi(updated & 15, updated >> 4)
	display[idx] = display_level * 17
	if _bulk_build:
		if value > 0:
			_mark_explored_neighborhood(idx)
		return
	var layer: int = idx >> _shift_layer
	if not dirty_light_layers.has(layer):
		dirty_light_layers[layer] = true
	if value > 0:
		_mark_explored_neighborhood(idx)


func _index(x: int, y: int, z: int) -> int:
	return (y * NZ + z) * NX + x


func _world_index(x: int, y: int, z: int) -> int:
	return _index(x - World.WORLD_MIN_BLOCK_X, y, z - World.WORLD_MIN_BLOCK_Z)


func _valid(x: int, y: int, z: int) -> bool:
	return x >= World.WORLD_MIN_BLOCK_X and x <= World.WORLD_MAX_BLOCK_X and z >= World.WORLD_MIN_BLOCK_Z and z <= World.WORLD_MAX_BLOCK_Z and y >= 0 and y < NY
