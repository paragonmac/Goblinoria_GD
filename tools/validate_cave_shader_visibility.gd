extends SceneTree


const SHADER_PATHS := [
	"res://scripts/rendering/block_terrain.gdshader",
	"res://scripts/rendering/block_terrain_debug.gdshader",
	"res://scripts/rendering/block_terrain_poly_debug.gdshader",
	"res://scripts/rendering/block_terrain_poly_wire.gdshader",
]
const CAVE_WALL_Y := 1.0

var failures := 0


func _init() -> void:
	var result := _build_covered_cave_wall_fixture()
	_check_mesher_encoding(result, "mesher")
	_check_cached_encoding(result)
	_check_slice_cap_and_migration(result)
	_check_shader_source_contracts()
	if failures > 0:
		push_error("Cave shader visibility contracts failed: %d" % failures)
		quit(1)
		return
	print("Cave shader visibility contracts OK (mesher/cache encoding and shader source; not a GPU render test)")
	quit(0)


func _build_covered_cave_wall_fixture() -> Dictionary:
	var mesher := ChunkMesher.new()
	var blocks := PackedByteArray()
	blocks.resize(World.CHUNK_VOLUME)
	# The lower cube borders cave air horizontally while a solid roof continues
	# above it. Its side is a real cave wall, not an interior covered face.
	blocks[mesher.chunk_index(World.CHUNK_SIZE, 3, 1, 3)] = World.BLOCK_ID_GRANITE
	blocks[mesher.chunk_index(World.CHUNK_SIZE, 3, 2, 3)] = World.BLOCK_ID_GRANITE
	var solid_table := PackedByteArray()
	solid_table.resize(BlockRegistry.TABLE_SIZE)
	solid_table[World.BLOCK_ID_GRANITE] = 1
	var ramp_table := PackedByteArray()
	ramp_table.resize(BlockRegistry.TABLE_SIZE)
	var color_table := PackedColorArray()
	color_table.resize(BlockRegistry.TABLE_SIZE)
	color_table[World.BLOCK_ID_GRANITE] = Color.WHITE
	return mesher.build_chunk_arrays_from_data({
		"chunk_size": World.CHUNK_SIZE,
		"cx": 0,
		"cy": 0,
		"cz": 0,
		"air_id": World.BLOCK_ID_AIR,
		"blocks": blocks,
		"solid_table": solid_table,
		"ramp_table": ramp_table,
		"color_table": color_table,
	})


func _check_mesher_encoding(result: Dictionary, label: String) -> void:
	var uv2s := PackedVector2Array(result.get("uv2", PackedVector2Array()))
	var normals := PackedVector3Array(result.get("normals", PackedVector3Array()))
	var covered_wall_found := false
	var synthetic_cap_found := false
	for index in range(mini(uv2s.size(), normals.size())):
		var uv2 := uv2s[index]
		var normal := normals[index]
		if not is_equal_approx(uv2.x, CAVE_WALL_Y):
			continue
		if uv2.y < ChunkMesher.COVERED_FROM_ABOVE_FLAG:
			continue
		if absf(normal.y) < 0.5:
			covered_wall_found = true
		if normal.y > 0.5 and _decoded_top_flag(uv2.y) > 0.5:
			synthetic_cap_found = true
	_check(covered_wall_found, "%s: covered cave-wall side encoding missing" % label)
	# Covered tops live in the per-level slice cap now, not in chunk meshes.
	_check(not synthetic_cap_found, "%s: chunk mesh still bakes covered cut tops" % label)


## The slice cap carries the covered cut top with the same encoding the shader
## expects, and legacy (cache v9) meshes are migrated by stripping baked cut tops.
func _check_slice_cap_and_migration(chunk_result: Dictionary) -> void:
	var mesher := ChunkMesher.new()
	var blocks := PackedByteArray()
	blocks.resize(World.CHUNK_VOLUME)
	blocks[mesher.chunk_index(World.CHUNK_SIZE, 3, 1, 3)] = World.BLOCK_ID_GRANITE
	blocks[mesher.chunk_index(World.CHUNK_SIZE, 3, 2, 3)] = World.BLOCK_ID_GRANITE
	var solid_table := PackedByteArray()
	solid_table.resize(BlockRegistry.TABLE_SIZE)
	solid_table[World.BLOCK_ID_GRANITE] = 1
	var ramp_table := PackedByteArray()
	ramp_table.resize(BlockRegistry.TABLE_SIZE)
	var color_table := PackedColorArray()
	color_table.resize(BlockRegistry.TABLE_SIZE)
	color_table[World.BLOCK_ID_GRANITE] = Color.WHITE
	var cap := mesher.build_cap_arrays(blocks, blocks, World.CHUNK_SIZE, 0, 0, 0, int(CAVE_WALL_Y), World.BLOCK_ID_AIR,
		solid_table, ramp_table, color_table)
	var cap_uv2 := PackedVector2Array(cap.uv2)
	var cap_normals := PackedVector3Array(cap.normals)
	var cap_ok := cap_uv2.size() == 6
	for index in range(cap_uv2.size()):
		cap_ok = cap_ok and is_equal_approx(cap_uv2[index].x, CAVE_WALL_Y) and cap_normals[index].y > 0.5 			and cap_uv2[index].y >= ChunkMesher.COVERED_FROM_ABOVE_FLAG and _decoded_top_flag(cap_uv2[index].y) > 0.5
	_check(cap_ok, "slice cap: one covered cut-top quad with level and top-flag encoding")
	var empty_cap := mesher.build_cap_arrays(blocks, blocks, World.CHUNK_SIZE, 0, 0, 0, 2, World.BLOCK_ID_AIR,
		solid_table, ramp_table, color_table)
	_check(PackedVector3Array(empty_cap.vertices).is_empty(), "slice cap: an exposed top layer has no cut face")
	# Legacy entry = chunk mesh + baked cut top; stripping restores the chunk mesh.
	var legacy := {}
	for key in ["vertices", "normals", "colors", "uv", "uv2"]:
		var merged = chunk_result[key].duplicate()
		merged.append_array(cap[key])
		legacy[key] = merged
	legacy["has_geometry"] = true
	var stripped := ChunkMesher.strip_legacy_cut_faces(legacy)
	_check(PackedVector3Array(stripped.vertices) == PackedVector3Array(chunk_result.vertices)
		and PackedVector2Array(stripped.uv2) == PackedVector2Array(chunk_result.uv2), "migration: stripping a v9 entry leaves exactly the v10 chunk mesh")
	var only_cap := {"vertices": cap.vertices, "normals": cap.normals, "colors": cap.colors, "uv": cap.uv, "uv2": cap.uv2, "has_geometry": true}
	_check(not bool(ChunkMesher.strip_legacy_cut_faces(only_cap).has_geometry), "migration: a buried chunk becomes empty")


func _check_cached_encoding(result: Dictionary) -> void:
	var mesh_cache := WorldRendererMeshCache.new()
	var runtime_entry := mesh_cache.entry_from_mesher_result(result, World.CHUNK_SIZE - 1, 1)
	var persistent_entry := mesh_cache.export_persistent_entry(runtime_entry, World.CHUNK_SIZE - 1)
	_check(not persistent_entry.is_empty(), "cache: fixture did not export")
	if persistent_entry.is_empty():
		return
	var restored_entry := mesh_cache.entry_from_persistent(persistent_entry, 1)
	_check_mesher_encoding(restored_entry, "persistent cache round trip")


func _check_shader_source_contracts() -> void:
	# These checks cover the committed shader source contract. They deliberately
	# do not claim fragment execution or framebuffer/GPU coverage.
	for path in SHADER_PATHS:
		var source := FileAccess.get_file_as_string(path)
		_check(not source.is_empty(), "%s: shader source missing" % path)
		_check(source.contains("if (UV2.x < min_render_y)"), "%s: lower level clip missing" % path)
		_check(source.contains("if (UV2.x > top_render_y)"), "%s: upper level clip missing" % path)
		_check(
			source.contains("if (top_flag > 0.5 && top_render_y >= UV2.x + 1.0)"),
			"%s: covered synthetic top suppression missing" % path
		)
		_check(
			not source.contains("if (covered_from_above && NORMAL.y < 0.5)"),
			"%s: covered cave-wall sides are still discarded" % path
		)


func _decoded_top_flag(encoded_uv2_y: float) -> float:
	var encoded := encoded_uv2_y
	if encoded >= ChunkMesher.COVERED_FROM_ABOVE_FLAG:
		encoded -= ChunkMesher.COVERED_FROM_ABOVE_FLAG
	if encoded < ChunkMesher.GREEDY_UV2_FLAG:
		return encoded
	return fmod(encoded - ChunkMesher.GREEDY_UV2_FLAG, 2.0)


func _check(condition: bool, message: String) -> void:
	if condition:
		return
	failures += 1
	push_error(message)
