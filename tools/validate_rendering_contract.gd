extends SceneTree


func _init() -> void:
	var mesher := ChunkMesher.new()
	var blocks := PackedByteArray()
	blocks.resize(World.CHUNK_VOLUME)
	blocks[mesher.chunk_index(World.CHUNK_SIZE, 1, 2, 1)] = World.RAMP_NORTH_ID
	var solid_table := PackedByteArray()
	solid_table.resize(BlockRegistry.TABLE_SIZE)
	var ramp_table := PackedByteArray()
	ramp_table.resize(BlockRegistry.TABLE_SIZE)
	ramp_table[World.RAMP_NORTH_ID] = 1
	var color_table := PackedColorArray()
	color_table.resize(BlockRegistry.TABLE_SIZE)
	color_table[World.RAMP_NORTH_ID] = Color.WHITE
	var result := mesher.build_chunk_arrays_from_data({
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
	var uv2s: PackedVector2Array = result.get("uv2", PackedVector2Array())
	var ramp_encoding_ok := not uv2s.is_empty()
	for uv2 in uv2s:
		ramp_encoding_ok = ramp_encoding_ok \
			and is_equal_approx(uv2.x, 1.0) \
			and uv2.y < ChunkMesher.GREEDY_UV2_FLAG

	var terrain_slope_blocks := PackedByteArray()
	terrain_slope_blocks.resize(World.CHUNK_VOLUME)
	terrain_slope_blocks[mesher.chunk_index(World.CHUNK_SIZE, 2, 2, 1)] = World.TERRAIN_SLOPE_NORTH_ID
	ramp_table[World.TERRAIN_SLOPE_NORTH_ID] = 1
	color_table[World.TERRAIN_SLOPE_NORTH_ID] = Color.WHITE
	var terrain_slope_result := mesher.build_chunk_arrays_from_data({
		"chunk_size": World.CHUNK_SIZE,
		"cx": 0,
		"cy": 0,
		"cz": 0,
		"air_id": World.BLOCK_ID_AIR,
		"blocks": terrain_slope_blocks,
		"solid_table": solid_table,
		"ramp_table": ramp_table,
		"color_table": color_table,
	})
	var terrain_slope_uv2s := PackedVector2Array(terrain_slope_result.get("uv2", PackedVector2Array()))
	var terrain_slope_encoding_ok: bool = not terrain_slope_uv2s.is_empty()
	for uv2 in terrain_slope_uv2s:
		terrain_slope_encoding_ok = terrain_slope_encoding_ok \
			and is_equal_approx(uv2.x, 2.0) \
			and uv2.y < ChunkMesher.GREEDY_UV2_FLAG

	var cube_blocks := PackedByteArray()
	cube_blocks.resize(World.CHUNK_VOLUME)
	cube_blocks[mesher.chunk_index(World.CHUNK_SIZE, 3, 1, 3)] = World.BLOCK_ID_GRANITE
	cube_blocks[mesher.chunk_index(World.CHUNK_SIZE, 3, 2, 3)] = World.BLOCK_ID_GRANITE
	solid_table[World.BLOCK_ID_GRANITE] = 1
	color_table[World.BLOCK_ID_GRANITE] = Color.WHITE
	var cube_result := mesher.build_chunk_arrays_from_data({
		"chunk_size": World.CHUNK_SIZE,
		"cx": 0,
		"cy": 0,
		"cz": 0,
		"air_id": World.BLOCK_ID_AIR,
		"blocks": cube_blocks,
		"solid_table": solid_table,
		"ramp_table": ramp_table,
		"color_table": color_table,
	})
	var covered_lower_cube_ok := false
	var exposed_upper_cube_ok := false
	var covered_top_face_ok := false
	var covered_side_face_ok := false
	var cube_uv2s := PackedVector2Array(cube_result.get("uv2", PackedVector2Array()))
	var cube_normals := PackedVector3Array(cube_result.get("normals", PackedVector3Array()))
	for index in range(cube_uv2s.size()):
		var uv2 := cube_uv2s[index]
		if is_equal_approx(uv2.x, 1.0) and uv2.y >= ChunkMesher.COVERED_FROM_ABOVE_FLAG:
			covered_lower_cube_ok = true
			if cube_normals[index].y > 0.5:
				covered_top_face_ok = true
			else:
				covered_side_face_ok = true
		if is_equal_approx(uv2.x, 2.0) and uv2.y < ChunkMesher.COVERED_FROM_ABOVE_FLAG:
			exposed_upper_cube_ok = true

	var same_band := WorldStreaming.compute_render_chunk_y_bounds(6, 0, 1, World.CHUNK_SIZE, 0, 31)
	var boundary_band := WorldStreaming.compute_render_chunk_y_bounds(7, 0, 1, World.CHUNK_SIZE, 0, 31)
	var upper_connection_band_ok: bool = same_band == Vector2i(0, 0) \
		and boundary_band == Vector2i(0, 1)

	if not ramp_encoding_ok:
		push_error("Ramp visibility encoding changed its physical block height")
		quit(1)
		return
	if not terrain_slope_encoding_ok:
		push_error("Terrain slope visibility no longer uses its physical block height")
		quit(1)
		return
	if not covered_lower_cube_ok or not exposed_upper_cube_ok or not covered_top_face_ok or not covered_side_face_ok:
		push_error("Covered terrain faces no longer preserve level-cut visibility")
		quit(1)
		return
	if not upper_connection_band_ok:
		push_error("Render Y bounds do not retain upper-band ramp connections")
		quit(1)
		return
	print("Rendering contract OK")
	quit(0)
