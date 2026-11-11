extends SceneTree
## Chunk mesher output must stay byte-identical unless a change is meant to alter
## geometry. Builds a fixed set of deterministic chunks (cubes of every solid
## block, every ramp, slope and stair-flight id, with present and missing
## neighbours) and compares a hash of each result with a recorded fixture. Slice
## cap geometry for three layers of each chunk is pinned the same way.
##
## After an intentional geometry change, regenerate the fixture:
##   godot --headless --path <repo> --script res://tools/validate_mesher_golden.gd -- --update
## Also prints the total build time, which makes it a quick mesher benchmark.

const FIXTURE_PATH := "res://tools/fixtures/mesher_golden.json"
const CASES_PER_PATTERN := 40
const PATTERNS := ["noise", "terrain", "solid", "empty", "checker", "layers", "shapes"]
const NEIGHBOR_SIDES := ["x_neg", "x_pos", "y_neg", "y_pos", "z_neg", "z_pos"]
const CAP_LAYERS := [0, 3, 7]

var mesher := ChunkMesher.new()
var cube_ids: Array[int] = []
var shape_ids: Array[int] = []


func _init() -> void:
	var update := OS.get_cmdline_user_args().has("--update")
	var world := World.new()
	world._init_ramp_lookup()
	world.block_registry.load_from_csv(World.BLOCK_DATA_PATH)
	mesher._ensure_block_tables(world)
	for block_id in range(1, BlockRegistry.TABLE_SIZE):
		if mesher.block_ramp_table[block_id] != 0:
			shape_ids.append(block_id)
		elif mesher.block_solid_table[block_id] != 0:
			cube_ids.append(block_id)
	world.free()

	var hashes: Array[String] = []
	var cap_hashes: Array[String] = []
	var cap_usec := 0
	var cap_quads := 0
	var build_usec := 0
	var vertex_total := 0
	for pattern: String in PATTERNS:
		for index in CASES_PER_PATTERN:
			var job := _job(pattern, index)
			var started := Time.get_ticks_usec()
			var result: Dictionary = mesher.build_chunk_arrays_from_data(job)
			build_usec += Time.get_ticks_usec() - started
			vertex_total += int(result.get("vertex_count", 0))
			hashes.append(_hash(result))
			# The top layer is covered by the chunk above; use this chunk's own
			# blocks as that neighbour so the case needs no extra data.
			var blocks: PackedByteArray = job["blocks"]
			for ly: int in CAP_LAYERS:
				started = Time.get_ticks_usec()
				var cap: Dictionary = mesher.build_cap_arrays(blocks, blocks, World.CHUNK_SIZE, int(job["cx"]), int(job["cy"]), int(job["cz"]), ly,
					World.BLOCK_ID_AIR, mesher.block_solid_table, mesher.block_ramp_table, mesher.block_color_table)
				cap_usec += Time.get_ticks_usec() - started
				cap_quads += cap["vertices"].size() / 6
				cap_hashes.append(var_to_bytes([cap["vertices"], cap["normals"], cap["colors"], cap["uv"], cap["uv2"]]).hex_encode().sha256_text())
	var case_count := hashes.size()
	print("Mesher golden: %d cases, %d vertices, %.1f ms total, %.3f ms per chunk" % [
		case_count, vertex_total, build_usec / 1000.0, build_usec / 1000.0 / case_count])
	print("Mesher golden: %d caps, %d quads, %.1f ms total, %.2f us per quad" % [
		cap_hashes.size(), cap_quads, cap_usec / 1000.0, float(cap_usec) / maxf(1.0, cap_quads)])

	if update:
		var file := FileAccess.open(FIXTURE_PATH, FileAccess.WRITE)
		file.store_string(JSON.stringify({"format_version": 1, "cases_per_pattern": CASES_PER_PATTERN,
			"patterns": PATTERNS, "hashes": hashes, "cap_layers": CAP_LAYERS, "cap_hashes": cap_hashes}, "\t") + "\n")
		file.close()
		print("Mesher golden: fixture written with %d hashes" % case_count)
		quit(0)
		return
	var fixture: Variant = JSON.parse_string(FileAccess.get_file_as_string(FIXTURE_PATH))
	if not fixture is Dictionary or fixture.get("patterns") != PATTERNS \
			or int(fixture.get("cases_per_pattern", -1)) != CASES_PER_PATTERN:
		push_error("Mesher golden: fixture missing or built for a different case list")
		quit(1)
		return
	var expected: Array = fixture.get("hashes", [])
	var mismatches := 0
	for index in case_count:
		if index >= expected.size() or str(expected[index]) != hashes[index]:
			mismatches += 1
			if mismatches <= 5:
				push_error("Mesher golden: case %d (%s #%d) differs from the fixture" % [
					index, PATTERNS[index / CASES_PER_PATTERN], index % CASES_PER_PATTERN])
	var expected_caps: Array = fixture.get("cap_hashes", [])
	var fixture_layers: Array = fixture.get("cap_layers", [])
	var layers_match := fixture_layers.size() == CAP_LAYERS.size()
	for index in mini(fixture_layers.size(), CAP_LAYERS.size()):
		# JSON numbers come back as floats.
		layers_match = layers_match and int(fixture_layers[index]) == CAP_LAYERS[index]
	if not layers_match or expected_caps.size() != cap_hashes.size():
		push_error("Mesher golden: fixture has no cap hashes for these layers")
		mismatches += 1
	else:
		var cap_mismatches := 0
		for index in cap_hashes.size():
			if str(expected_caps[index]) != cap_hashes[index]:
				cap_mismatches += 1
		if cap_mismatches > 0:
			push_error("Mesher golden: %d slice caps differ from the fixture" % cap_mismatches)
		mismatches += cap_mismatches
	print("Mesher golden: %d checks, %d failures" % [case_count + cap_hashes.size(), mismatches])
	quit(1 if mismatches > 0 else 0)


func _hash(result: Dictionary) -> String:
	var payload := [result["vertices"], result["normals"], result["colors"], result["uv"], result["uv2"]]
	for key in ["visible_faces", "occluded_faces", "vertex_count", "triangle_count", "greedy_visible_faces",
			"greedy_occluded_faces", "greedy_source_visible_faces", "ramp_visible_faces", "ramp_occluded_faces", "has_geometry"]:
		payload.append(result[key])
	return var_to_bytes(payload).hex_encode().sha256_text()


func _job(pattern: String, index: int) -> Dictionary:
	var size: int = World.CHUNK_SIZE
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(pattern) * 1000 + index
	var coord := Vector3i(rng.randi_range(-30, 30), rng.randi_range(0, 31), rng.randi_range(-30, 30))
	var blocks := _fill(pattern, rng, coord)
	var neighbors := {}
	for side: String in NEIGHBOR_SIDES:
		# About a quarter of neighbours are missing, as at a loading edge.
		if rng.randf() < 0.25:
			neighbors[side] = null
		else:
			neighbors[side] = _fill("noise" if rng.randf() < 0.5 else pattern, rng, coord)
	var job := {
		"coord": coord, "cx": coord.x, "cy": coord.y, "cz": coord.z, "chunk_size": size,
		"air_id": World.BLOCK_ID_AIR, "blocks": blocks,
		"solid_table": mesher.block_solid_table, "ramp_table": mesher.block_ramp_table,
		"color_table": mesher.block_color_table,
	}
	# Production jobs carry a prebuilt padded buffer; the fallback builds it from
	# the neighbour arrays on the worker. Cover both.
	if index % 4 == 3:
		job["neighbors"] = neighbors
	else:
		job["padded_blocks"] = mesher.build_padded_block_buffer(size, blocks, neighbors, World.BLOCK_ID_AIR)
	return job


func _fill(pattern: String, rng: RandomNumberGenerator, coord: Vector3i) -> PackedByteArray:
	var size: int = World.CHUNK_SIZE
	var blocks := PackedByteArray()
	blocks.resize(size * size * size)
	if pattern == "empty":
		return blocks
	var main_id: int = cube_ids[rng.randi_range(0, cube_ids.size() - 1)]
	var other_id: int = cube_ids[rng.randi_range(0, cube_ids.size() - 1)]
	var phase := rng.randf() * TAU
	for lz in size:
		for ly in size:
			for lx in size:
				var value := 0
				match pattern:
					"noise":
						var roll := rng.randf()
						if roll < 0.45:
							value = cube_ids[rng.randi_range(0, cube_ids.size() - 1)]
						elif roll < 0.55:
							value = shape_ids[rng.randi_range(0, shape_ids.size() - 1)]
					"terrain":
						var height := 3.5 + 2.0 * sin(phase + (coord.x * size + lx) * 0.35) + 1.5 * cos((coord.z * size + lz) * 0.3)
						if ly < int(height):
							value = main_id if ly < int(height) - 1 else other_id
						elif ly == int(height) and rng.randf() < 0.2:
							value = shape_ids[rng.randi_range(0, shape_ids.size() - 1)]
					"solid":
						value = main_id
					"checker":
						value = main_id if (lx + ly + lz) % 2 == 0 else 0
					"layers":
						value = main_id if ly % 3 == 0 else (other_id if ly % 3 == 1 and rng.randf() < 0.7 else 0)
					"shapes":
						if ly == 0:
							value = main_id
						elif ly == 1 and rng.randf() < 0.6:
							value = shape_ids[rng.randi_range(0, shape_ids.size() - 1)]
						elif ly == 2 and rng.randf() < 0.15:
							value = other_id
				blocks[(lz * size + ly) * size + lx] = value
	return blocks
