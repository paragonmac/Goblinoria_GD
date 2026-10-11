extends SceneTree

const LightFieldScript = preload("res://scripts/world/light_field.gd")
const PipelineScript = preload("res://scripts/world_generation_pipeline.gd")
const ChunkDataScript = preload("res://scripts/chunk_data.gd")
const OPEN := Vector3i(40, 120, 0)
const ROOM := Vector3i(24, 92, 0)
const SHAFT := Vector3i(8, 60, 0)
const TORCH := Vector3i(32, 70, 32)

var checks := 0
var failures := 0


class TestWorld extends World:
	func ensure_chunk_generated(coord: Vector3i) -> ChunkData:
		var chunk := ensure_chunk(coord)
		if chunk != null:
			chunk.generated = true
		return chunk


func _init() -> void:
	_run.call_deferred()


func _check(value: bool, message: String) -> void:
	checks += 1
	if not value:
		failures += 1
		push_error(message)


func _make_world() -> TestWorld:
	var world := TestWorld.new()
	world.block_registry.load_from_csv(World.BLOCK_DATA_PATH)
	world._init_ramp_lookup()
	# Four generated chunks in a small X/Z footprint. All other cells remain
	# ungenerated and therefore opaque to LightField.
	for cx in range(-1, 7):
		for cz in range(-1, 7):
			for cy in range(32):
				world.ensure_chunk_generated(Vector3i(cx, cy, cz))
	for x in range(-3, 4):
		for z in range(-3, 4):
			for y in range(100, 106):
				world.set_block_raw(x, y, z, World.BLOCK_ID_GRANITE, false)
	for x in range(-8, 25):
		for z in range(-16, 17):
			world.set_block_raw(x, 100, z, World.BLOCK_ID_GRANITE, false)
	# A one-cell shaft connects the open sky to the lower cave.
	for y in range(100, 256):
		world.set_block_raw(SHAFT.x, y, SHAFT.z, World.BLOCK_ID_AIR, false)
	for x in range(6, 11):
		for z in range(-2, 3):
			for y in range(55, 61):
				world.set_block_raw(x, y, z, World.BLOCK_ID_AIR, false)
	# Sealed room under an opaque roof.
	for x in range(22, 27):
		for z in range(-2, 3):
			for y in range(90, 96):
				var boundary := x == 22 or x == 26 or z == -2 or z == 2 or y == 90 or y == 95
				world.set_block_raw(x, y, z, World.BLOCK_ID_GRANITE if boundary else World.BLOCK_ID_AIR, false)
	# Lit corridor with a one-cell wall and a corner. Keep it below the roof.
	for x in range(30, 46):
		for z in range(30, 46):
			world.set_block_raw(x, 68, z, World.BLOCK_ID_AIR, false)
	world.set_block_raw(38, 68, 38, World.BLOCK_ID_GRANITE, false)
	for y in range(69, 74):
		world.set_block_raw(38, y, 38, World.BLOCK_ID_GRANITE, false)
	for chunk: ChunkData in world.chunks.values():
		chunk.generated = true
	return world


func _drain(field) -> void:
	while field.pending_events() > 0:
		field.process_events(1000000)


func _same_light(field, world: TestWorld, message: String) -> void:
	var expected := LightFieldScript.new()
	expected.build(world)
	_check(field.light == expected.light, message)


func _run() -> void:
	var world := _make_world()
	var field := LightFieldScript.new()
	field.build(world)
	print("Light field build ms: %.2f" % field.last_build_ms)
	var explored_snapshot := PackedByteArray()
	explored_snapshot.resize(field.VOLUME)
	explored_snapshot.fill(0)
	var snapshot_only_index := field._world_index(100, 40, 100)
	var snapshot_overlaps_lit_index := field._world_index(OPEN.x, OPEN.y, OPEN.z)
	explored_snapshot[snapshot_only_index] = 255
	explored_snapshot[snapshot_overlaps_lit_index] = 255
	var previous_union := field.explored.duplicate()
	for idx in field.VOLUME:
		if explored_snapshot[idx] != 0 and previous_union[idx] == 0:
			previous_union[idx] = 255
	var preloaded_field = LightFieldScript.new()
	preloaded_field.build(world, explored_snapshot)
	_check(preloaded_field.explored == previous_union,
		"preloaded explored build is byte-identical to post-build snapshot union")
	_check(preloaded_field.is_explored(100, 40, 100) and preloaded_field.is_explored(OPEN.x, OPEN.y, OPEN.z),
		"preloaded explored bytes survive and union with newly lit cells")
	var brute_explored_count := 0
	for value in preloaded_field.explored:
		if value != 0:
			brute_explored_count += 1
	_check(preloaded_field.explored_count == brute_explored_count,
		"native explored count matches brute-force fixture count")
	_check(field.get_sky(OPEN.x, OPEN.y, OPEN.z) == 15, "open ground receives sky 15")
	_check(field.get_sky(ROOM.x, ROOM.y, ROOM.z) == 0, "sealed room under roof stays dark")
	_check(field.get_sky(SHAFT.x, 60, SHAFT.z) == 15, "shaft carries sky 15 into cave")
	_check(field.get_sky(SHAFT.x + 1, 60, SHAFT.z) == 14, "shaft spill falls off one sideways")
	_check(field.get_sky(SHAFT.x + 2, 60, SHAFT.z) == 13, "shaft spill continues falling off")
	_check(field.is_explored(SHAFT.x, 60, SHAFT.z) and field.is_explored(SHAFT.x + 1, 60, SHAFT.z + 1), "lit cells and six neighbours become explored")
	_check(not field.is_explored(ROOM.x, ROOM.y, ROOM.z), "sealed room remains unexplored")

	field.add_light_source(TORCH, 15)
	_drain(field)
	for distance in range(1, 15):
		_check(field.get_block_light(TORCH.x + distance, TORCH.y, TORCH.z) == 15 - distance, "source falloff distance %d" % distance)
	_check(field.get_block_light(TORCH.x + 15, TORCH.y, TORCH.z) == 0, "source ends at distance 15")
	field.remove_light_source(TORCH)
	_drain(field)
	_check(field.is_explored(TORCH.x + 4, TORCH.y, TORCH.z), "explored memory persists after light removal")
	_same_light(field, world, "source add and removal equals full rebuild")

	# Dig then fill an opaque roof cell; incremental and rebuilt fields must match.
	world.light_field = field
	world.light_field_built = true
	world.set_block_raw(24, 95, 0, World.BLOCK_ID_AIR, false)
	_drain(field)
	_check(field.get_sky(24, 92, 0) > 0, "digging roof relights sealed room")
	_same_light(field, world, "digging roof equals full rebuild")
	world.set_block_raw(24, 95, 0, World.BLOCK_ID_GRANITE, false)
	_drain(field)
	_check(field.get_sky(24, 92, 0) == 0, "filling roof darkens room")
	_same_light(field, world, "filling roof equals full rebuild")

	# A wall blocks the direct route, while adjacent open cells still receive light.
	field.add_light_source(Vector3i(36, 68, 38), 15)
	_drain(field)
	_check(field.get_block_light(37, 68, 38) == 14, "light travels around a corner")
	_check(field.get_block_light(38, 68, 38) == 0 and field.get_block_light(39, 68, 38) == 10, "wall blocks the direct route while light reaches around it")
	field.remove_light_source(Vector3i(36, 68, 38))
	_drain(field)

	field.dirty_light_layers.clear()
	field.dirty_explored_layers.clear()
	field.mark_explored(100, 50, 100)
	field.mark_explored(100, 60, 100)
	field.mark_explored(100, 70, 100)
	var dirty := field.take_dirty_layers(2, 61)
	_check(dirty.size() == 2 and dirty[0] == 60 and dirty[1] == 70, "dirty layers are nearest first")
	_check(field.take_dirty_layers(10, 0) == [50] and field.take_dirty_layers(10, 0).is_empty(), "dirty layers clear after taking")

	for x in range(3):
		world.set_block_raw(10 + x, 110, 0, World.BLOCK_ID_GRANITE, false)
	var first := field.process_events(1)
	_check(first == 1 and field.pending_events() == 2, "event budget leaves queued work for later calls")
	while field.pending_events() > 0:
		field.process_events(1)
	_check(field.pending_events() == 0, "many queued events drain across calls")

	world.light_field = null
	world.free()
	_benchmark_full_world()
	print("Light field: %d checks, %d failures" % [checks, failures])
	quit(1 if failures > 0 else 0)


func _benchmark_full_world() -> void:
	# Generating a full world takes ~70 s: opt in with GOB_LIGHT_BENCH=1.
	if not OS.has_environment("GOB_LIGHT_BENCH"):
		print("Light field full-world benchmark skipped (set GOB_LIGHT_BENCH=1)")
		return
	var config := {
		"world_seed": 12345,
		"sea_level": 226,
		"world_size_y": 256,
		"chunk_size": 8,
		"world_chunks_x": 32,
		"world_chunks_y": 32,
		"world_chunks_z": 32,
		"world_min_chunk_x": -16,
		"world_max_chunk_x": 15,
		"world_min_chunk_z": -16,
		"world_max_chunk_z": 15,
	}
	var pipeline = PipelineScript.new()
	var generation_started := Time.get_ticks_usec()
	var generated: Dictionary = pipeline.generate(config)
	print("Light field benchmark generation ms: %.2f" % ((Time.get_ticks_usec() - generation_started) / 1000.0))
	var generated_chunks: Dictionary = generated["chunks"]
	generated.clear()
	var world := TestWorld.new()
	for coord: Vector3i in generated_chunks:
		var chunk = ChunkDataScript.new(World.CHUNK_SIZE, 255)
		chunk.blocks = generated_chunks[coord]
		chunk.generated = true
		world.chunks[coord] = chunk
	generated_chunks.clear()
	_check(world.chunks.size() == World.WORLD_CHUNKS_X * World.WORLD_CHUNKS_Y * World.WORLD_CHUNKS_Z,
		"performance world has all generated chunks")
	var field = LightFieldScript.new()
	var best_build_ms := INF
	for attempt in range(3):
		field.build(world)
		best_build_ms = minf(best_build_ms, field.last_build_ms)
	print("Light field benchmark full build best of 3 ms: %.2f (target <= 400)" % best_build_ms)
	_soft_check(best_build_ms <= 400.0, "full generated 256^3 LightField build meets 400 ms target")
	var best_slices_us := INF
	var best_all_slices_ms := INF
	var best_explored_slices_us := INF
	var best_all_explored_slices_ms := INF
	for attempt in range(3):
		var slice_started := Time.get_ticks_usec()
		for y in range(field.NY):
			var slice: PackedByteArray = field.layer_slice("light", y)
			if slice.size() != field.LAYER_SIZE:
				_check(false, "light layer slice matches its dimensions")
		best_all_slices_ms = minf(best_all_slices_ms, (Time.get_ticks_usec() - slice_started) / 1000.0)
		best_slices_us = minf(best_slices_us, (Time.get_ticks_usec() - slice_started) / float(field.NY))
		slice_started = Time.get_ticks_usec()
		for y in range(field.NY):
			var explored_slice: PackedByteArray = field.layer_slice("explored", y)
			if explored_slice.size() != field.LAYER_SIZE:
				_check(false, "explored layer slice matches its dimensions")
		best_all_explored_slices_ms = minf(best_all_explored_slices_ms, (Time.get_ticks_usec() - slice_started) / 1000.0)
		best_explored_slices_us = minf(best_explored_slices_us, (Time.get_ticks_usec() - slice_started) / float(field.NY))
	print("Light field benchmark layer_slice best average us: light %.2f / explored %.2f (target <= 100 each); all layers ms: light %.2f / explored %.2f (target <= 60 each)" % [best_slices_us, best_explored_slices_us, best_all_slices_ms, best_all_explored_slices_ms])
	_soft_check(best_slices_us <= 100.0, "layer_slice meets 0.1 ms target")
	_soft_check(best_explored_slices_us <= 100.0, "explored layer_slice meets 0.1 ms target")
	_soft_check(best_all_slices_ms <= 60.0, "all light layers slice within 60 ms")
	_soft_check(best_all_explored_slices_ms <= 60.0, "all explored layers slice within 60 ms")
	var cave_idx := _find_cave_cell(field)
	_check(cave_idx >= 0, "generated world contains a dark cave cell for torch timing")
	if cave_idx >= 0:
		var cave_pos := Vector3i((cave_idx & (field.NX - 1)) + World.WORLD_MIN_BLOCK_X, cave_idx >> field._shift_layer, ((cave_idx >> field._shift_x) & (field.NZ - 1)) + World.WORLD_MIN_BLOCK_Z)
		var best_add_us := INF
		var best_remove_us := INF
		for attempt in range(3):
			var started := Time.get_ticks_usec()
			field.add_light_source(cave_pos, 15)
			field.process_events(1000000)
			best_add_us = minf(best_add_us, Time.get_ticks_usec() - started)
			started = Time.get_ticks_usec()
			field.remove_light_source(cave_pos)
			field.process_events(1000000)
			best_remove_us = minf(best_remove_us, Time.get_ticks_usec() - started)
		print("Light field benchmark torch cave add/remove best of 3 us: %.0f / %.0f (target <= 1000 each)" % [best_add_us, best_remove_us])
		_soft_check(best_add_us <= 1000.0, "cave torch add meets 1 ms target")
		_soft_check(best_remove_us <= 1000.0, "cave torch removal meets 1 ms target")
	var surface_cells := _find_surface_cells(field, 36)
	_check(surface_cells.size() == 36, "generated world supplies 36 surface cells for event timing")
	if surface_cells.size() == 36:
		var best_events_us := INF
		for attempt in range(3):
			field.build(world)
			var started := Time.get_ticks_usec()
			for index in range(surface_cells.size()):
				var pos: Vector3i = surface_cells[index]
				field.notify_block_changed(pos.x, pos.y, pos.z, World.BLOCK_ID_AIR, World.BLOCK_ID_GRANITE)
				field.process_events(1000000)
			best_events_us = minf(best_events_us, Time.get_ticks_usec() - started)
		print("Light field benchmark 36 sequential surface block events best of 3 ms: %.2f (target <= 10)" % (best_events_us / 1000.0))
		_soft_check(best_events_us <= 10000.0, "36 sequential surface block changes meet 10 ms target")
	field = null
	world.free()


func _find_cave_cell(field) -> int:
	for y in range(1, 240):
		var layer_start: int = y * field.LAYER_SIZE
		for i in range(layer_start, layer_start + field.LAYER_SIZE):
			if field.block_mirror[i] == World.BLOCK_ID_AIR and field.block_mirror[i - field.LAYER_SIZE] != World.BLOCK_ID_AIR and field.get_level((i & (field.NX - 1)) + World.WORLD_MIN_BLOCK_X, y, ((i >> field._shift_x) & (field.NZ - 1)) + World.WORLD_MIN_BLOCK_Z) == 0:
				return i
	return -1


func _find_surface_cells(field, count: int) -> Array[Vector3i]:
	var result: Array[Vector3i] = []
	for z in range(16, field.NZ - 16, 8):
		for x in range(16, field.NX - 16, 8):
			for y in range(field.NY - 16, 0, -1):
				var idx: int = field._index(x, y, z)
				if field.block_mirror[idx] != World.BLOCK_ID_AIR and field.block_mirror[idx + field.LAYER_SIZE] == World.BLOCK_ID_AIR:
					result.append(Vector3i(x + World.WORLD_MIN_BLOCK_X, y + 1, z + World.WORLD_MIN_BLOCK_Z))
					break
			if result.size() >= count:
				return result
	return result


## Timing targets vary by machine and load: report, do not fail.
func _soft_check(ok: bool, message: String) -> void:
	if not ok:
		print("WARN: timing target missed: " + message)
