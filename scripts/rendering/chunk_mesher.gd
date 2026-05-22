extends RefCounted
class_name ChunkMesher
## Generates chunk meshes with per-face culling and vertex colors.

#region Constants
const COLOR_MIN := 0.0
const COLOR_MAX := 1.0
const FACE_HALF_SIZE := 0.5
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
const ATLAS_COLUMNS := 4
const ATLAS_ROWS := 4
const GREEDY_UV2_FLAG := 2.0
#endregion

#region State
var block_solid_table := PackedByteArray()
var block_color_table := PackedColorArray()
var block_ramp_table := PackedByteArray()
#endregion


#region Mesh Building
func build_chunk_mesh(world: World, cx: int, cy: int, cz: int) -> Dictionary:
	if world == null:
		return _build_empty_mesh_result()
	var coord := Vector3i(cx, cy, cz)
	var chunk: ChunkData = world.get_chunk(coord)
	if chunk == null or not chunk.generated:
		return _build_empty_mesh_result()
	_ensure_block_tables(world)
	var missing_neighbors: Array = []
	var neighbors: Dictionary = {
		"x_neg": _copy_neighbor_blocks(world, Vector3i(cx - 1, cy, cz), missing_neighbors),
		"x_pos": _copy_neighbor_blocks(world, Vector3i(cx + 1, cy, cz), missing_neighbors),
		"y_neg": _copy_neighbor_blocks(world, Vector3i(cx, cy - 1, cz), missing_neighbors),
		"y_pos": _copy_neighbor_blocks(world, Vector3i(cx, cy + 1, cz), missing_neighbors),
		"z_neg": _copy_neighbor_blocks(world, Vector3i(cx, cy, cz - 1), missing_neighbors),
		"z_pos": _copy_neighbor_blocks(world, Vector3i(cx, cy, cz + 1), missing_neighbors),
	}
	var padded_blocks := build_padded_block_buffer(World.CHUNK_SIZE, chunk.blocks, neighbors, World.BLOCK_ID_AIR)
	var job := {
		"chunk_size": World.CHUNK_SIZE,
		"cx": cx,
		"cy": cy,
		"cz": cz,
		"top_render_y": world.top_render_y,
		"air_id": World.BLOCK_ID_AIR,
		"blocks": chunk.blocks,
		"padded_blocks": padded_blocks,
		"solid_table": block_solid_table,
		"ramp_table": block_ramp_table,
		"color_table": block_color_table,
	}
	var data := build_chunk_arrays_from_data(job)
	var vertices: PackedVector3Array = data["vertices"]
	var normals: PackedVector3Array = data["normals"]
	var colors: PackedColorArray = data["colors"]
	var uvs: PackedVector2Array = data["uv"]
	var uv2s: PackedVector2Array = data["uv2"]
	var visible_faces: int = int(data["visible_faces"])
	var occluded_faces: int = int(data["occluded_faces"])
	var has_geometry: bool = bool(data["has_geometry"])
	var mesh := ArrayMesh.new()
	if has_geometry:
		var arrays := []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = vertices
		arrays[Mesh.ARRAY_NORMAL] = normals
		arrays[Mesh.ARRAY_COLOR] = colors
		arrays[Mesh.ARRAY_TEX_UV] = uvs
		arrays[Mesh.ARRAY_TEX_UV2] = uv2s
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)

	return {
		"mesh": mesh,
		"vertices": vertices,
		"normals": normals,
		"colors": colors,
		"uv": uvs,
		"uv2": uv2s,
		"visible_faces": visible_faces,
		"occluded_faces": occluded_faces,
		"vertex_count": int(data.get("vertex_count", vertices.size())),
		"triangle_count": int(data.get("triangle_count", int(vertices.size() / 3))),
		"greedy_visible_faces": int(data.get("greedy_visible_faces", 0)),
		"greedy_occluded_faces": int(data.get("greedy_occluded_faces", 0)),
		"greedy_source_visible_faces": int(data.get("greedy_source_visible_faces", 0)),
		"ramp_visible_faces": int(data.get("ramp_visible_faces", 0)),
		"ramp_occluded_faces": int(data.get("ramp_occluded_faces", 0)),
		"has_geometry": has_geometry,
		"missing_neighbors": missing_neighbors,
	}
#endregion


#region Mesh Data (Threaded)
func build_chunk_arrays_from_data(job: Dictionary) -> Dictionary:
	var chunk_size: int = int(job["chunk_size"])
	var cx: int = int(job["cx"])
	var cy: int = int(job["cy"])
	var cz: int = int(job["cz"])
	var air_id: int = int(job.get("air_id", 0))
	var blocks: PackedByteArray = job["blocks"]
	var solid_table: PackedByteArray = job["solid_table"]
	var ramp_table := PackedByteArray()
	var ramp_table_value = job.get("ramp_table", PackedByteArray())
	if typeof(ramp_table_value) == TYPE_PACKED_BYTE_ARRAY:
		ramp_table = PackedByteArray(ramp_table_value)
	var color_table: PackedColorArray = job["color_table"]
	var atlas_columns: int = int(job.get("atlas_columns", ATLAS_COLUMNS))
	var atlas_rows: int = int(job.get("atlas_rows", ATLAS_ROWS))
	if atlas_columns <= 0:
		atlas_columns = 1
	if atlas_rows <= 0:
		atlas_rows = 1
	var tile_scale := _atlas_tile_scale(atlas_columns, atlas_rows)
	var tile_count := atlas_columns * atlas_rows
	var padded_size: int = chunk_size + 2
	var padded_blocks := PackedByteArray()
	var padded_blocks_value = job.get("padded_blocks", PackedByteArray())
	if typeof(padded_blocks_value) == TYPE_PACKED_BYTE_ARRAY:
		padded_blocks = PackedByteArray(padded_blocks_value)
	if padded_blocks.size() != padded_size * padded_size * padded_size:
		var neighbors := {}
		var neighbors_value = job.get("neighbors", {})
		if typeof(neighbors_value) == TYPE_DICTIONARY:
			neighbors = neighbors_value
		padded_blocks = build_padded_block_buffer(chunk_size, blocks, neighbors, air_id)
	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	var colors := PackedColorArray()
	var uvs := PackedVector2Array()
	var uv2s := PackedVector2Array()
	var visible_faces := 0
	var occluded_faces := 0
	var greedy_visible_faces := 0
	var greedy_occluded_faces := 0
	var greedy_source_visible_faces := 0
	var ramp_visible_faces := 0
	var ramp_occluded_faces := 0

	var greedy_counts := add_greedy_cube_faces(vertices, normals, colors, uvs, uv2s, padded_blocks, padded_size, chunk_size, cx, cy, cz, air_id, solid_table, ramp_table, color_table, tile_count, tile_scale)
	greedy_visible_faces = int(greedy_counts.get("visible", 0))
	greedy_occluded_faces = int(greedy_counts.get("occluded", 0))
	greedy_source_visible_faces = int(greedy_counts.get("source_visible", greedy_visible_faces))
	visible_faces += greedy_visible_faces
	occluded_faces += greedy_occluded_faces

	for lx in range(chunk_size):
		var wx := cx * chunk_size + lx
		for ly in range(chunk_size):
			var wy := cy * chunk_size + ly
			for lz in range(chunk_size):
				var wz := cz * chunk_size + lz
				var block_id := padded_block(padded_blocks, padded_size, lx + 1, ly + 1, lz + 1, air_id)
				if block_id == air_id:
					continue
				if not is_ramp_id(block_id, ramp_table):
					continue

				var base := Vector3(lx, ly, lz)
				var block_center_y: float = float(wy)

				var above_id := padded_block(padded_blocks, padded_size, lx + 1, ly + 2, lz + 1, air_id)
				var below_id := padded_block(padded_blocks, padded_size, lx + 1, ly, lz + 1, air_id)
				var color_id := block_id
				if below_id != air_id and not _is_inner_corner_id(block_id):
					color_id = below_id
				var color := block_color_from_table(color_table, color_id, wx, wy, wz)
				var tile_id := color_id
				var tile_index := _tile_index_for_id(tile_id, tile_count)
				var tile_offset := _atlas_tile_offset(tile_index, atlas_columns, tile_scale)

				var forward_id := padded_block(padded_blocks, padded_size, lx + 1, ly + 1, lz + 2, air_id)
				var back_id := padded_block(padded_blocks, padded_size, lx + 1, ly + 1, lz, air_id)
				var right_id := padded_block(padded_blocks, padded_size, lx + 2, ly + 1, lz + 1, air_id)
				var left_id := padded_block(padded_blocks, padded_size, lx, ly + 1, lz + 1, air_id)
				var above_occluding := is_solid_id(above_id, solid_table)
				var below_occluding := is_solid_id(below_id, solid_table)
				var forward_occluding_ramp := is_occluding_id(forward_id, solid_table, ramp_table)
				var back_occluding_ramp := is_occluding_id(back_id, solid_table, ramp_table)
				var right_occluding_ramp := is_occluding_id(right_id, solid_table, ramp_table)
				var left_occluding_ramp := is_occluding_id(left_id, solid_table, ramp_table)

				var counts := add_ramp_faces(
					vertices,
					normals,
					colors,
					uvs,
					uv2s,
					base,
					block_id,
					color,
					block_center_y,
					tile_offset,
					tile_scale,
					above_occluding,
					below_occluding,
					back_occluding_ramp,
					forward_occluding_ramp,
					right_occluding_ramp,
					left_occluding_ramp
				)
				var ramp_visible_count := int(counts.get("visible", 0))
				var ramp_occluded_count := int(counts.get("occluded", 0))
				ramp_visible_faces += ramp_visible_count
				ramp_occluded_faces += ramp_occluded_count
				visible_faces += ramp_visible_count
				occluded_faces += ramp_occluded_count

	var has_geometry := vertices.size() > 0
	return {
		"vertices": vertices,
		"normals": normals,
		"colors": colors,
		"uv": uvs,
		"uv2": uv2s,
		"visible_faces": visible_faces,
		"occluded_faces": occluded_faces,
		"vertex_count": vertices.size(),
		"triangle_count": int(vertices.size() / 3),
		"greedy_visible_faces": greedy_visible_faces,
		"greedy_occluded_faces": greedy_occluded_faces,
		"greedy_source_visible_faces": greedy_source_visible_faces,
		"ramp_visible_faces": ramp_visible_faces,
		"ramp_occluded_faces": ramp_occluded_faces,
		"has_geometry": has_geometry,
	}
#endregion


#region Block Colors
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
		clamp(base.r + (n1 - NOISE_CENTER) * jitter, COLOR_MIN, COLOR_MAX),
		clamp(base.g + (n2 - NOISE_CENTER) * jitter, COLOR_MIN, COLOR_MAX),
		clamp(base.b + (n3 - NOISE_CENTER) * jitter, COLOR_MIN, COLOR_MAX),
		base.a
	)


func block_noise(wx: int, wy: int, wz: int) -> float:
	var h: int = ((wx * HASH_X) & HASH_MASK) ^ ((wy * HASH_Y) & HASH_MASK) ^ ((wz * HASH_Z) & HASH_MASK)
	h = (h ^ (h >> HASH_SHIFT)) & HASH_MASK
	return float(h % BLOCK_NOISE_MOD) / BLOCK_NOISE_DIV
#endregion


#region Mesh Data Helpers
func _build_empty_mesh_result() -> Dictionary:
	return {
		"mesh": ArrayMesh.new(),
		"visible_faces": 0,
		"occluded_faces": 0,
		"has_geometry": false,
	}


func _ensure_block_tables(world: World) -> void:
	if world == null:
		return
	if block_solid_table.size() == BlockRegistry.TABLE_SIZE \
		and block_color_table.size() == BlockRegistry.TABLE_SIZE \
		and block_ramp_table.size() == BlockRegistry.TABLE_SIZE:
		return
	block_solid_table.resize(BlockRegistry.TABLE_SIZE)
	block_color_table.resize(BlockRegistry.TABLE_SIZE)
	block_ramp_table.resize(BlockRegistry.TABLE_SIZE)
	for i in range(BlockRegistry.TABLE_SIZE):
		block_solid_table[i] = 1 if world.is_block_solid_id(i) else 0
		block_color_table[i] = world.get_block_color(i)
		block_ramp_table[i] = 1 if world.is_ramp_block_id(i) else 0


func _copy_neighbor_blocks(world: World, coord: Vector3i, missing_neighbors: Array) -> Variant:
	if world == null:
		return null
	if not world.is_chunk_coord_valid(coord):
		return null
	var chunk: ChunkData = world.get_chunk(coord)
	if chunk == null or not chunk.generated:
		missing_neighbors.append(coord)
		return null
	return chunk.blocks.duplicate()


func build_padded_block_buffer(chunk_size: int, blocks: PackedByteArray, neighbors: Dictionary, air_id: int) -> PackedByteArray:
	var padded_size: int = chunk_size + 2
	var padded := PackedByteArray()
	padded.resize(padded_size * padded_size * padded_size)
	padded.fill(air_id)
	for lx in range(chunk_size):
		for ly in range(chunk_size):
			for lz in range(chunk_size):
				padded[padded_index(padded_size, lx + 1, ly + 1, lz + 1)] = blocks[chunk_index(chunk_size, lx, ly, lz)]
	_copy_neighbor_face_into_padded(padded, padded_size, chunk_size, neighbors.get("x_neg", null), "x_neg")
	_copy_neighbor_face_into_padded(padded, padded_size, chunk_size, neighbors.get("x_pos", null), "x_pos")
	_copy_neighbor_face_into_padded(padded, padded_size, chunk_size, neighbors.get("y_neg", null), "y_neg")
	_copy_neighbor_face_into_padded(padded, padded_size, chunk_size, neighbors.get("y_pos", null), "y_pos")
	_copy_neighbor_face_into_padded(padded, padded_size, chunk_size, neighbors.get("z_neg", null), "z_neg")
	_copy_neighbor_face_into_padded(padded, padded_size, chunk_size, neighbors.get("z_pos", null), "z_pos")
	return padded


func _copy_neighbor_face_into_padded(padded: PackedByteArray, padded_size: int, chunk_size: int, neighbor_blocks: Variant, side: String) -> void:
	if typeof(neighbor_blocks) != TYPE_PACKED_BYTE_ARRAY:
		return
	var blocks: PackedByteArray = PackedByteArray(neighbor_blocks)
	if blocks.size() != chunk_size * chunk_size * chunk_size:
		return
	for a in range(chunk_size):
		for b in range(chunk_size):
			match side:
				"x_neg":
					padded[padded_index(padded_size, 0, a + 1, b + 1)] = blocks[chunk_index(chunk_size, chunk_size - 1, a, b)]
				"x_pos":
					padded[padded_index(padded_size, chunk_size + 1, a + 1, b + 1)] = blocks[chunk_index(chunk_size, 0, a, b)]
				"y_neg":
					padded[padded_index(padded_size, a + 1, 0, b + 1)] = blocks[chunk_index(chunk_size, a, chunk_size - 1, b)]
				"y_pos":
					padded[padded_index(padded_size, a + 1, chunk_size + 1, b + 1)] = blocks[chunk_index(chunk_size, a, 0, b)]
				"z_neg":
					padded[padded_index(padded_size, a + 1, b + 1, 0)] = blocks[chunk_index(chunk_size, a, b, chunk_size - 1)]
				"z_pos":
					padded[padded_index(padded_size, a + 1, b + 1, chunk_size + 1)] = blocks[chunk_index(chunk_size, a, b, 0)]


func chunk_index(chunk_size: int, lx: int, ly: int, lz: int) -> int:
	return (lz * chunk_size + ly) * chunk_size + lx


func padded_index(padded_size: int, px: int, py: int, pz: int) -> int:
	return (pz * padded_size + py) * padded_size + px


func padded_block(padded_blocks: PackedByteArray, padded_size: int, px: int, py: int, pz: int, air_id: int) -> int:
	if px < 0 or py < 0 or pz < 0 or px >= padded_size or py >= padded_size or pz >= padded_size:
		return air_id
	var idx := padded_index(padded_size, px, py, pz)
	if idx < 0 or idx >= padded_blocks.size():
		return air_id
	return int(padded_blocks[idx])


func neighbor_block(neighbor_blocks: Variant, chunk_size: int, lx: int, ly: int, lz: int, air_id: int) -> int:
	if neighbor_blocks == null or neighbor_blocks.size() == 0:
		return air_id
	var idx := chunk_index(chunk_size, lx, ly, lz)
	return neighbor_blocks[idx]


func is_solid_id(block_id: int, solid_table: PackedByteArray) -> bool:
	if block_id < 0 or block_id >= solid_table.size():
		return false
	return solid_table[block_id] != 0


func is_ramp_id(block_id: int, ramp_table: PackedByteArray) -> bool:
	if block_id < 0 or block_id >= ramp_table.size():
		return false
	return ramp_table[block_id] != 0


func is_occluding_id(block_id: int, solid_table: PackedByteArray, ramp_table: PackedByteArray) -> bool:
	if is_ramp_id(block_id, ramp_table):
		return false
	return is_solid_id(block_id, solid_table)


func is_face_occluding(block_id: int, solid_table: PackedByteArray, ramp_table: PackedByteArray, neighbor_face: Vector3) -> bool:
	if is_ramp_id(block_id, ramp_table):
		return _ramp_side_is_full(block_id, neighbor_face)
	return is_solid_id(block_id, solid_table)


func _ramp_side_is_full(block_id: int, side: Vector3) -> bool:
	var h := FACE_HALF_SIZE
	var heights := _ramp_corner_heights(block_id, h)
	var a: float
	var b: float
	if side == Vector3.BACK:
		a = float(heights["nw"])
		b = float(heights["ne"])
	elif side == Vector3.FORWARD:
		a = float(heights["sw"])
		b = float(heights["se"])
	elif side == Vector3.RIGHT:
		a = float(heights["ne"])
		b = float(heights["se"])
	elif side == Vector3.LEFT:
		a = float(heights["nw"])
		b = float(heights["sw"])
	else:
		return false
	return a > 0.0 and b > 0.0


func _atlas_tile_scale(columns: int, rows: int) -> Vector2:
	return Vector2(1.0 / float(columns), 1.0 / float(rows))


func _atlas_tile_offset(tile_index: int, columns: int, tile_scale: Vector2) -> Vector2:
	var col := 0
	var row := 0
	if columns > 0:
		col = tile_index % columns
		row = int(floor(float(tile_index) / float(columns)))
	return Vector2(float(col) * tile_scale.x, float(row) * tile_scale.y)


func _tile_index_for_id(block_id: int, tile_count: int) -> int:
	if tile_count <= 0:
		return 0
	if block_id < 0:
		return 0
	return block_id % tile_count


func _planar_uv(vertex: Vector3, base: Vector3, normal: Vector3) -> Vector2:
	var local := vertex - base
	var abs_normal := Vector3(abs(normal.x), abs(normal.y), abs(normal.z))
	var u: float
	var v: float
	if abs_normal.y >= abs_normal.x and abs_normal.y >= abs_normal.z:
		u = local.x + 0.5
		v = local.z + 0.5
	elif abs_normal.x >= abs_normal.z:
		u = local.z + 0.5
		v = local.y + 0.5
	else:
		u = local.x + 0.5
		v = local.y + 0.5
	return Vector2(u, v)


func _atlas_uv(local_uv: Vector2, tile_offset: Vector2, tile_scale: Vector2) -> Vector2:
	return tile_offset + Vector2(local_uv.x * tile_scale.x, local_uv.y * tile_scale.y)


func add_greedy_cube_faces(
	vertices: PackedVector3Array,
	normals: PackedVector3Array,
	colors: PackedColorArray,
	uvs: PackedVector2Array,
	uv2s: PackedVector2Array,
	padded_blocks: PackedByteArray,
	padded_size: int,
	chunk_size: int,
	cx: int,
	cy: int,
	cz: int,
	air_id: int,
	solid_table: PackedByteArray,
	ramp_table: PackedByteArray,
	color_table: PackedColorArray,
	tile_count: int,
	tile_scale: Vector2
) -> Dictionary:
	var counts := {"visible": 0, "occluded": 0, "source_visible": 0}
	_merge_counts(counts, _add_greedy_top_bottom_faces(vertices, normals, colors, uvs, uv2s, padded_blocks, padded_size, chunk_size, cx, cy, cz, air_id, solid_table, ramp_table, color_table, tile_count, tile_scale, true))
	_merge_counts(counts, _add_greedy_top_bottom_faces(vertices, normals, colors, uvs, uv2s, padded_blocks, padded_size, chunk_size, cx, cy, cz, air_id, solid_table, ramp_table, color_table, tile_count, tile_scale, false))
	_merge_counts(counts, _add_greedy_z_side_faces(vertices, normals, colors, uvs, uv2s, padded_blocks, padded_size, chunk_size, cx, cy, cz, air_id, solid_table, ramp_table, color_table, tile_count, tile_scale, true))
	_merge_counts(counts, _add_greedy_z_side_faces(vertices, normals, colors, uvs, uv2s, padded_blocks, padded_size, chunk_size, cx, cy, cz, air_id, solid_table, ramp_table, color_table, tile_count, tile_scale, false))
	_merge_counts(counts, _add_greedy_x_side_faces(vertices, normals, colors, uvs, uv2s, padded_blocks, padded_size, chunk_size, cx, cy, cz, air_id, solid_table, ramp_table, color_table, tile_count, tile_scale, true))
	_merge_counts(counts, _add_greedy_x_side_faces(vertices, normals, colors, uvs, uv2s, padded_blocks, padded_size, chunk_size, cx, cy, cz, air_id, solid_table, ramp_table, color_table, tile_count, tile_scale, false))
	return counts


func _merge_counts(target: Dictionary, source: Dictionary) -> void:
	target["visible"] = int(target.get("visible", 0)) + int(source.get("visible", 0))
	target["occluded"] = int(target.get("occluded", 0)) + int(source.get("occluded", 0))
	target["source_visible"] = int(target.get("source_visible", 0)) + int(source.get("source_visible", 0))


func _add_greedy_top_bottom_faces(
	vertices: PackedVector3Array,
	normals: PackedVector3Array,
	colors: PackedColorArray,
	uvs: PackedVector2Array,
	uv2s: PackedVector2Array,
	padded_blocks: PackedByteArray,
	padded_size: int,
	chunk_size: int,
	cx: int,
	cy: int,
	cz: int,
	air_id: int,
	solid_table: PackedByteArray,
	ramp_table: PackedByteArray,
	color_table: PackedColorArray,
	tile_count: int,
	tile_scale: Vector2,
	is_top: bool
) -> Dictionary:
	var counts := {"visible": 0, "occluded": 0, "source_visible": 0}
	for ly in range(chunk_size):
		var mask := []
		mask.resize(chunk_size * chunk_size)
		for lx in range(chunk_size):
			for lz in range(chunk_size):
				var block_id := padded_block(padded_blocks, padded_size, lx + 1, ly + 1, lz + 1, air_id)
				if not _is_greedy_cube_block(block_id, air_id, ramp_table):
					continue
				var neighbor_id: int
				if is_top:
					neighbor_id = padded_block(padded_blocks, padded_size, lx + 1, ly + 2, lz + 1, air_id)
				else:
					neighbor_id = padded_block(padded_blocks, padded_size, lx + 1, ly, lz + 1, air_id)
				var neighbor_occluding := is_solid_id(neighbor_id, solid_table)
				if is_top:
					var top_flag := 1.0 if neighbor_occluding else 0.0
					if neighbor_occluding:
						counts["occluded"] = int(counts["occluded"]) + 1
					mask[lz * chunk_size + lx] = _make_greedy_cell(block_id, lx, ly, lz, cx, cy, cz, chunk_size, top_flag, not neighbor_occluding)
				elif neighbor_occluding:
					counts["occluded"] = int(counts["occluded"]) + 1
				else:
					mask[lz * chunk_size + lx] = _make_greedy_cell(block_id, lx, ly, lz, cx, cy, cz, chunk_size, 0.0, true)
		_merge_counts(counts, _emit_greedy_xz_mask(vertices, normals, colors, uvs, uv2s, mask, chunk_size, ly, is_top, color_table, tile_count, tile_scale))
	return counts


func _emit_greedy_xz_mask(
	vertices: PackedVector3Array,
	normals: PackedVector3Array,
	colors: PackedColorArray,
	uvs: PackedVector2Array,
	uv2s: PackedVector2Array,
	mask: Array,
	chunk_size: int,
	ly: int,
	is_top: bool,
	color_table: PackedColorArray,
	tile_count: int,
	tile_scale: Vector2
) -> Dictionary:
	var counts := {"visible": 0, "occluded": 0, "source_visible": 0}
	for z in range(chunk_size):
		for x in range(chunk_size):
			var index: int = z * chunk_size + x
			var cell = mask[index]
			if typeof(cell) != TYPE_DICTIONARY:
				continue
			var width := 1
			while x + width < chunk_size and _same_greedy_cell(cell, mask[z * chunk_size + x + width]):
				width += 1
			var depth := 1
			var can_grow := true
			while z + depth < chunk_size and can_grow:
				for dx in range(width):
					if not _same_greedy_cell(cell, mask[(z + depth) * chunk_size + x + dx]):
						can_grow = false
						break
				if can_grow:
					depth += 1
			for dz in range(depth):
				for dx in range(width):
					mask[(z + dz) * chunk_size + x + dx] = null
			_emit_greedy_xz_face(vertices, normals, colors, uvs, uv2s, x, z, width, depth, ly, is_top, cell, color_table, tile_count, tile_scale)
			if bool(cell.get("visible_counted", true)):
				counts["visible"] = int(counts["visible"]) + 1
				counts["source_visible"] = int(counts["source_visible"]) + width * depth
	return counts


func _add_greedy_z_side_faces(
	vertices: PackedVector3Array,
	normals: PackedVector3Array,
	colors: PackedColorArray,
	uvs: PackedVector2Array,
	uv2s: PackedVector2Array,
	padded_blocks: PackedByteArray,
	padded_size: int,
	chunk_size: int,
	cx: int,
	cy: int,
	cz: int,
	air_id: int,
	solid_table: PackedByteArray,
	ramp_table: PackedByteArray,
	color_table: PackedColorArray,
	tile_count: int,
	tile_scale: Vector2,
	is_forward: bool
) -> Dictionary:
	var counts := {"visible": 0, "occluded": 0, "source_visible": 0}
	for ly in range(chunk_size):
		for lz in range(chunk_size):
			var run_start := -1
			var run_cell: Variant = null
			for lx in range(chunk_size + 1):
				var cell: Variant = null
				if lx < chunk_size:
					var block_id := padded_block(padded_blocks, padded_size, lx + 1, ly + 1, lz + 1, air_id)
					if _is_greedy_cube_block(block_id, air_id, ramp_table):
						var neighbor_id: int
						var neighbor_face: Vector3
						if is_forward:
							neighbor_id = padded_block(padded_blocks, padded_size, lx + 1, ly + 1, lz + 2, air_id)
							neighbor_face = Vector3.BACK
						else:
							neighbor_id = padded_block(padded_blocks, padded_size, lx + 1, ly + 1, lz, air_id)
							neighbor_face = Vector3.FORWARD
						if is_face_occluding(neighbor_id, solid_table, ramp_table, neighbor_face):
							counts["occluded"] = int(counts["occluded"]) + 1
						else:
							cell = _make_greedy_cell(block_id, lx, ly, lz, cx, cy, cz, chunk_size, 0.0, true)
				if run_start >= 0 and not _same_greedy_cell(run_cell, cell):
					_emit_greedy_z_face(vertices, normals, colors, uvs, uv2s, run_start, lx - run_start, ly, lz, is_forward, run_cell, color_table, tile_count, tile_scale)
					counts["visible"] = int(counts["visible"]) + 1
					counts["source_visible"] = int(counts["source_visible"]) + lx - run_start
					run_start = -1
					run_cell = null
				if run_start < 0 and typeof(cell) == TYPE_DICTIONARY:
					run_start = lx
					run_cell = cell
	return counts


func _add_greedy_x_side_faces(
	vertices: PackedVector3Array,
	normals: PackedVector3Array,
	colors: PackedColorArray,
	uvs: PackedVector2Array,
	uv2s: PackedVector2Array,
	padded_blocks: PackedByteArray,
	padded_size: int,
	chunk_size: int,
	cx: int,
	cy: int,
	cz: int,
	air_id: int,
	solid_table: PackedByteArray,
	ramp_table: PackedByteArray,
	color_table: PackedColorArray,
	tile_count: int,
	tile_scale: Vector2,
	is_right: bool
) -> Dictionary:
	var counts := {"visible": 0, "occluded": 0, "source_visible": 0}
	for ly in range(chunk_size):
		for lx in range(chunk_size):
			var run_start := -1
			var run_cell: Variant = null
			for lz in range(chunk_size + 1):
				var cell: Variant = null
				if lz < chunk_size:
					var block_id := padded_block(padded_blocks, padded_size, lx + 1, ly + 1, lz + 1, air_id)
					if _is_greedy_cube_block(block_id, air_id, ramp_table):
						var neighbor_id: int
						var neighbor_face: Vector3
						if is_right:
							neighbor_id = padded_block(padded_blocks, padded_size, lx + 2, ly + 1, lz + 1, air_id)
							neighbor_face = Vector3.LEFT
						else:
							neighbor_id = padded_block(padded_blocks, padded_size, lx, ly + 1, lz + 1, air_id)
							neighbor_face = Vector3.RIGHT
						if is_face_occluding(neighbor_id, solid_table, ramp_table, neighbor_face):
							counts["occluded"] = int(counts["occluded"]) + 1
						else:
							cell = _make_greedy_cell(block_id, lx, ly, lz, cx, cy, cz, chunk_size, 0.0, true)
				if run_start >= 0 and not _same_greedy_cell(run_cell, cell):
					_emit_greedy_x_face(vertices, normals, colors, uvs, uv2s, lx, ly, run_start, lz - run_start, is_right, run_cell, color_table, tile_count, tile_scale)
					counts["visible"] = int(counts["visible"]) + 1
					counts["source_visible"] = int(counts["source_visible"]) + lz - run_start
					run_start = -1
					run_cell = null
				if run_start < 0 and typeof(cell) == TYPE_DICTIONARY:
					run_start = lz
					run_cell = cell
	return counts


func _is_greedy_cube_block(block_id: int, air_id: int, ramp_table: PackedByteArray) -> bool:
	return block_id != air_id and not is_ramp_id(block_id, ramp_table)


func _make_greedy_cell(block_id: int, lx: int, ly: int, lz: int, cx: int, cy: int, cz: int, chunk_size: int, top_flag: float, visible_counted: bool) -> Dictionary:
	var top_key := 1 if top_flag > 0.5 else 0
	var visible_key := 1 if visible_counted else 0
	return {
		"key": "%d:%d:%d" % [block_id, top_key, visible_key],
		"block_id": block_id,
		"sample_x": cx * chunk_size + lx,
		"sample_y": cy * chunk_size + ly,
		"sample_z": cz * chunk_size + lz,
		"top_flag": top_flag,
		"visible_counted": visible_counted,
	}


func _same_greedy_cell(a: Variant, b: Variant) -> bool:
	if typeof(a) != TYPE_DICTIONARY or typeof(b) != TYPE_DICTIONARY:
		return false
	return String(a.get("key", "")) == String(b.get("key", ""))


func _emit_greedy_xz_face(
	vertices: PackedVector3Array,
	normals: PackedVector3Array,
	colors: PackedColorArray,
	uvs: PackedVector2Array,
	uv2s: PackedVector2Array,
	x: int,
	z: int,
	width: int,
	depth: int,
	ly: int,
	is_top: bool,
	cell: Dictionary,
	color_table: PackedColorArray,
	tile_count: int,
	tile_scale: Vector2
) -> void:
	var h := FACE_HALF_SIZE
	var y := float(ly) + (h if is_top else -h)
	var x_min := float(x) - h
	var x_max := float(x + width) - h
	var z_min := float(z) - h
	var z_max := float(z + depth) - h
	var normal := Vector3.UP if is_top else Vector3.DOWN
	var v1: Vector3
	var v2: Vector3
	var v3: Vector3
	var v4: Vector3
	if is_top:
		v1 = Vector3(x_min, y, z_min)
		v2 = Vector3(x_min, y, z_max)
		v3 = Vector3(x_max, y, z_max)
		v4 = Vector3(x_max, y, z_min)
	else:
		v1 = Vector3(x_min, y, z_min)
		v2 = Vector3(x_max, y, z_min)
		v3 = Vector3(x_max, y, z_max)
		v4 = Vector3(x_min, y, z_max)
	var uv1 := Vector2(0.0, 0.0)
	var uv2_local := Vector2(0.0, float(depth))
	var uv3 := Vector2(float(width), float(depth))
	var uv4 := Vector2(float(width), 0.0)
	_emit_greedy_quad(vertices, normals, colors, uvs, uv2s, v1, v2, v3, v4, normal, uv1, uv2_local, uv3, uv4, cell, color_table, tile_count)


func _emit_greedy_z_face(
	vertices: PackedVector3Array,
	normals: PackedVector3Array,
	colors: PackedColorArray,
	uvs: PackedVector2Array,
	uv2s: PackedVector2Array,
	x: int,
	width: int,
	ly: int,
	lz: int,
	is_forward: bool,
	cell: Dictionary,
	color_table: PackedColorArray,
	tile_count: int,
	tile_scale: Vector2
) -> void:
	var h := FACE_HALF_SIZE
	var x_min := float(x) - h
	var x_max := float(x + width) - h
	var y_min := float(ly) - h
	var y_max := float(ly) + h
	var z := float(lz) + (h if is_forward else -h)
	var normal := Vector3.FORWARD if is_forward else Vector3.BACK
	var v1: Vector3
	var v2: Vector3
	var v3: Vector3
	var v4: Vector3
	if is_forward:
		v1 = Vector3(x_min, y_min, z)
		v2 = Vector3(x_max, y_min, z)
		v3 = Vector3(x_max, y_max, z)
		v4 = Vector3(x_min, y_max, z)
	else:
		v1 = Vector3(x_min, y_min, z)
		v2 = Vector3(x_min, y_max, z)
		v3 = Vector3(x_max, y_max, z)
		v4 = Vector3(x_max, y_min, z)
	var uv1 := Vector2(0.0, 0.0)
	var uv2_local := Vector2(float(width), 0.0)
	var uv3 := Vector2(float(width), 1.0)
	var uv4 := Vector2(0.0, 1.0)
	_emit_greedy_quad(vertices, normals, colors, uvs, uv2s, v1, v2, v3, v4, normal, uv1, uv2_local, uv3, uv4, cell, color_table, tile_count)


func _emit_greedy_x_face(
	vertices: PackedVector3Array,
	normals: PackedVector3Array,
	colors: PackedColorArray,
	uvs: PackedVector2Array,
	uv2s: PackedVector2Array,
	lx: int,
	ly: int,
	z: int,
	depth: int,
	is_right: bool,
	cell: Dictionary,
	color_table: PackedColorArray,
	tile_count: int,
	tile_scale: Vector2
) -> void:
	var h := FACE_HALF_SIZE
	var x := float(lx) + (h if is_right else -h)
	var y_min := float(ly) - h
	var y_max := float(ly) + h
	var z_min := float(z) - h
	var z_max := float(z + depth) - h
	var normal := Vector3.RIGHT if is_right else Vector3.LEFT
	var v1: Vector3
	var v2: Vector3
	var v3: Vector3
	var v4: Vector3
	if is_right:
		v1 = Vector3(x, y_min, z_min)
		v2 = Vector3(x, y_max, z_min)
		v3 = Vector3(x, y_max, z_max)
		v4 = Vector3(x, y_min, z_max)
	else:
		v1 = Vector3(x, y_min, z_min)
		v2 = Vector3(x, y_min, z_max)
		v3 = Vector3(x, y_max, z_max)
		v4 = Vector3(x, y_max, z_min)
	var uv1 := Vector2(0.0, 0.0)
	var uv2_local: Vector2
	var uv3: Vector2
	var uv4: Vector2
	if is_right:
		uv2_local = Vector2(0.0, 1.0)
		uv3 = Vector2(float(depth), 1.0)
		uv4 = Vector2(float(depth), 0.0)
	else:
		uv2_local = Vector2(float(depth), 0.0)
		uv3 = Vector2(float(depth), 1.0)
		uv4 = Vector2(0.0, 1.0)
	_emit_greedy_quad(vertices, normals, colors, uvs, uv2s, v1, v2, v3, v4, normal, uv1, uv2_local, uv3, uv4, cell, color_table, tile_count)


func _emit_greedy_quad(
	vertices: PackedVector3Array,
	normals: PackedVector3Array,
	colors: PackedColorArray,
	uvs: PackedVector2Array,
	uv2s: PackedVector2Array,
	v1: Vector3,
	v2: Vector3,
	v3: Vector3,
	v4: Vector3,
	normal: Vector3,
	uv1: Vector2,
	uv2_local: Vector2,
	uv3: Vector2,
	uv4: Vector2,
	cell: Dictionary,
	color_table: PackedColorArray,
	tile_count: int
) -> void:
	var block_id: int = int(cell.get("block_id", 0))
	var wx: int = int(cell.get("sample_x", 0))
	var wy: int = int(cell.get("sample_y", 0))
	var wz: int = int(cell.get("sample_z", 0))
	var color := block_color_from_table(color_table, block_id, wx, wy, wz)
	var tile_index := _tile_index_for_id(block_id, tile_count)
	var shade := face_shade(normal)
	var shaded := Color(color.r * shade, color.g * shade, color.b * shade, COLOR_MAX)
	var encoded_top_flag: float = GREEDY_UV2_FLAG + float(tile_index) * 2.0 + float(cell.get("top_flag", 0.0))
	var uv2 := Vector2(float(wy), encoded_top_flag)
	vertices.append_array([v1, v3, v2, v1, v4, v3])
	normals.append_array([normal, normal, normal, normal, normal, normal])
	colors.append_array([shaded, shaded, shaded, shaded, shaded, shaded])
	uvs.append_array([uv1, uv3, uv2_local, uv1, uv4, uv3])
	uv2s.append_array([uv2, uv2, uv2, uv2, uv2, uv2])
#endregion


#region Face Generation
func add_face(
	vertices: PackedVector3Array,
	normals: PackedVector3Array,
	colors: PackedColorArray,
	uvs: PackedVector2Array,
	uv2s: PackedVector2Array,
	base: Vector3,
	normal: Vector3,
	color: Color,
	block_center_y: float,
	top_flag: float,
	tile_offset: Vector2,
	tile_scale: Vector2
) -> void:
	var h := FACE_HALF_SIZE
	var v1: Vector3
	var v2: Vector3
	var v3: Vector3
	var v4: Vector3

	if normal == Vector3.UP:
		v1 = base + Vector3(-h, h, -h)
		v2 = base + Vector3(-h, h, h)
		v3 = base + Vector3(h, h, h)
		v4 = base + Vector3(h, h, -h)
	elif normal == Vector3.DOWN:
		v1 = base + Vector3(-h, -h, -h)
		v2 = base + Vector3(h, -h, -h)
		v3 = base + Vector3(h, -h, h)
		v4 = base + Vector3(-h, -h, h)
	elif normal == Vector3.FORWARD:
		v1 = base + Vector3(-h, -h, h)
		v2 = base + Vector3(h, -h, h)
		v3 = base + Vector3(h, h, h)
		v4 = base + Vector3(-h, h, h)
	elif normal == Vector3.BACK:
		v1 = base + Vector3(-h, -h, -h)
		v2 = base + Vector3(-h, h, -h)
		v3 = base + Vector3(h, h, -h)
		v4 = base + Vector3(h, -h, -h)
	elif normal == Vector3.RIGHT:
		v1 = base + Vector3(h, -h, -h)
		v2 = base + Vector3(h, h, -h)
		v3 = base + Vector3(h, h, h)
		v4 = base + Vector3(h, -h, h)
	else:
		v1 = base + Vector3(-h, -h, -h)
		v2 = base + Vector3(-h, -h, h)
		v3 = base + Vector3(-h, h, h)
		v4 = base + Vector3(-h, h, -h)

	var shade := face_shade(normal)
	var shaded := Color(color.r * shade, color.g * shade, color.b * shade, COLOR_MAX)
	var uv2 := Vector2(block_center_y, top_flag)
	var uv1 := _atlas_uv(_planar_uv(v1, base, normal), tile_offset, tile_scale)
	var uv2_local := _atlas_uv(_planar_uv(v2, base, normal), tile_offset, tile_scale)
	var uv3 := _atlas_uv(_planar_uv(v3, base, normal), tile_offset, tile_scale)
	var uv4 := _atlas_uv(_planar_uv(v4, base, normal), tile_offset, tile_scale)

	vertices.append_array([v1, v3, v2, v1, v4, v3])
	normals.append_array([normal, normal, normal, normal, normal, normal])
	colors.append_array([shaded, shaded, shaded, shaded, shaded, shaded])
	uvs.append_array([uv1, uv3, uv2_local, uv1, uv4, uv3])
	uv2s.append_array([uv2, uv2, uv2, uv2, uv2, uv2])


func add_quad_with_normal(
	vertices: PackedVector3Array,
	normals: PackedVector3Array,
	colors: PackedColorArray,
	uvs: PackedVector2Array,
	uv2s: PackedVector2Array,
	base: Vector3,
	v1: Vector3,
	v2: Vector3,
	v3: Vector3,
	v4: Vector3,
	expected_normal: Vector3,
	color: Color,
	block_center_y: float,
	top_flag: float,
	tile_offset: Vector2,
	tile_scale: Vector2,
	flip_winding: bool = false
) -> void:
	var normal := (v2 - v1).cross(v3 - v1).normalized()
	var reverse := normal.dot(expected_normal) < 0.0
	if reverse:
		normal = -normal
	if flip_winding:
		reverse = not reverse
	var shade := face_shade(normal)
	var shaded := Color(color.r * shade, color.g * shade, color.b * shade, COLOR_MAX)
	var uv2 := Vector2(block_center_y, top_flag)
	var uv1 := _atlas_uv(_planar_uv(v1, base, expected_normal), tile_offset, tile_scale)
	var uv2_local := _atlas_uv(_planar_uv(v2, base, expected_normal), tile_offset, tile_scale)
	var uv3 := _atlas_uv(_planar_uv(v3, base, expected_normal), tile_offset, tile_scale)
	var uv4 := _atlas_uv(_planar_uv(v4, base, expected_normal), tile_offset, tile_scale)
	if reverse:
		vertices.append_array([v1, v2, v3, v1, v3, v4])
		uvs.append_array([uv1, uv2_local, uv3, uv1, uv3, uv4])
	else:
		vertices.append_array([v1, v3, v2, v1, v4, v3])
		uvs.append_array([uv1, uv3, uv2_local, uv1, uv4, uv3])
	normals.append_array([normal, normal, normal, normal, normal, normal])
	colors.append_array([shaded, shaded, shaded, shaded, shaded, shaded])
	uv2s.append_array([uv2, uv2, uv2, uv2, uv2, uv2])


func add_tri_with_normal(
	vertices: PackedVector3Array,
	normals: PackedVector3Array,
	colors: PackedColorArray,
	uvs: PackedVector2Array,
	uv2s: PackedVector2Array,
	base: Vector3,
	v1: Vector3,
	v2: Vector3,
	v3: Vector3,
	expected_normal: Vector3,
	color: Color,
	block_center_y: float,
	top_flag: float,
	tile_offset: Vector2,
	tile_scale: Vector2,
	flip_winding: bool = false
) -> void:
	var normal := (v2 - v1).cross(v3 - v1).normalized()
	if normal.dot(expected_normal) < 0.0:
		var swap := v2
		v2 = v3
		v3 = swap
		normal = (v2 - v1).cross(v3 - v1).normalized()
	if flip_winding:
		# Flip cull side without changing lighting normal.
		var swap := v2
		v2 = v3
		v3 = swap
	var shade := face_shade(normal)
	var shaded := Color(color.r * shade, color.g * shade, color.b * shade, COLOR_MAX)
	var uv2 := Vector2(block_center_y, top_flag)
	var uv1 := _atlas_uv(_planar_uv(v1, base, expected_normal), tile_offset, tile_scale)
	var uv2_local := _atlas_uv(_planar_uv(v2, base, expected_normal), tile_offset, tile_scale)
	var uv3 := _atlas_uv(_planar_uv(v3, base, expected_normal), tile_offset, tile_scale)
	vertices.append_array([v1, v2, v3])
	normals.append_array([normal, normal, normal])
	colors.append_array([shaded, shaded, shaded])
	uvs.append_array([uv1, uv2_local, uv3])
	uv2s.append_array([uv2, uv2, uv2])


func add_tri_double_sided(
	vertices: PackedVector3Array,
	normals: PackedVector3Array,
	colors: PackedColorArray,
	uvs: PackedVector2Array,
	uv2s: PackedVector2Array,
	base: Vector3,
	v1: Vector3,
	v2: Vector3,
	v3: Vector3,
	expected_normal: Vector3,
	color: Color,
	block_center_y: float,
	top_flag: float,
	tile_offset: Vector2,
	tile_scale: Vector2,
	flip_winding: bool = false
) -> void:
	add_tri_with_normal(vertices, normals, colors, uvs, uv2s, base, v1, v2, v3, expected_normal, color, block_center_y, top_flag, tile_offset, tile_scale, flip_winding)
	add_tri_with_normal(vertices, normals, colors, uvs, uv2s, base, v1, v2, v3, expected_normal, color, block_center_y, top_flag, tile_offset, tile_scale, not flip_winding)


func add_quad_double_sided(
	vertices: PackedVector3Array,
	normals: PackedVector3Array,
	colors: PackedColorArray,
	uvs: PackedVector2Array,
	uv2s: PackedVector2Array,
	base: Vector3,
	v1: Vector3,
	v2: Vector3,
	v3: Vector3,
	v4: Vector3,
	expected_normal: Vector3,
	color: Color,
	block_center_y: float,
	top_flag: float,
	tile_offset: Vector2,
	tile_scale: Vector2
) -> void:
	add_quad_with_normal(vertices, normals, colors, uvs, uv2s, base, v1, v2, v3, v4, expected_normal, color, block_center_y, top_flag, tile_offset, tile_scale, false)
	add_quad_with_normal(vertices, normals, colors, uvs, uv2s, base, v1, v2, v3, v4, expected_normal, color, block_center_y, top_flag, tile_offset, tile_scale, true)


func add_ramp_faces(
	vertices: PackedVector3Array,
	normals: PackedVector3Array,
	colors: PackedColorArray,
	uvs: PackedVector2Array,
	uv2s: PackedVector2Array,
	base: Vector3,
	block_id: int,
	color: Color,
	block_center_y: float,
	tile_offset: Vector2,
	tile_scale: Vector2,
	above_occluding: bool,
	below_occluding: bool,
	north_occluding: bool,
	south_occluding: bool,
	east_occluding: bool,
	west_occluding: bool
) -> Dictionary:
	var counts := {"visible": 0, "occluded": 0}
	var h := FACE_HALF_SIZE
	var heights := _ramp_corner_heights(block_id, h)
	var y_nw: float = float(heights["nw"])
	var y_ne: float = float(heights["ne"])
	var y_se: float = float(heights["se"])
	var y_sw: float = float(heights["sw"])
	var nw := base + Vector3(-h, y_nw, -h)
	var ne := base + Vector3(h, y_ne, -h)
	var se := base + Vector3(h, y_se, h)
	var sw := base + Vector3(-h, y_sw, h)
	var bnw := base + Vector3(-h, -h, -h)
	var bne := base + Vector3(h, -h, -h)
	var bse := base + Vector3(h, -h, h)
	var bsw := base + Vector3(-h, -h, h)

	var top_flag := 1.0 if above_occluding else 0.0
	# Check if this is an inner corner (non-planar quad with 3 corners at one height, 1 at another)
	var is_inner_corner := _is_inner_corner_id(block_id)
	if is_inner_corner:
		# Split along the diagonal through the low corner so both tris slope.
		var low_corner := _get_inner_corner_low_corner(block_id)
		var flip_inner_winding := block_id == 108 or block_id == 109 or block_id == 111
		match low_corner:
			"sw":
				add_tri_double_sided(vertices, normals, colors, uvs, uv2s, base, sw, nw, ne, Vector3.UP, color, block_center_y, top_flag, tile_offset, tile_scale, flip_inner_winding)
				add_tri_double_sided(vertices, normals, colors, uvs, uv2s, base, sw, ne, se, Vector3.UP, color, block_center_y, top_flag, tile_offset, tile_scale, flip_inner_winding)
			"se":
				add_tri_double_sided(vertices, normals, colors, uvs, uv2s, base, se, ne, nw, Vector3.UP, color, block_center_y, top_flag, tile_offset, tile_scale, flip_inner_winding)
				add_tri_double_sided(vertices, normals, colors, uvs, uv2s, base, se, nw, sw, Vector3.UP, color, block_center_y, top_flag, tile_offset, tile_scale, flip_inner_winding)
			"nw":
				add_tri_double_sided(vertices, normals, colors, uvs, uv2s, base, nw, ne, se, Vector3.UP, color, block_center_y, top_flag, tile_offset, tile_scale, flip_inner_winding)
				add_tri_double_sided(vertices, normals, colors, uvs, uv2s, base, nw, se, sw, Vector3.UP, color, block_center_y, top_flag, tile_offset, tile_scale, flip_inner_winding)
			"ne":
				add_tri_double_sided(vertices, normals, colors, uvs, uv2s, base, ne, nw, sw, Vector3.UP, color, block_center_y, top_flag, tile_offset, tile_scale, flip_inner_winding)
				add_tri_double_sided(vertices, normals, colors, uvs, uv2s, base, ne, sw, se, Vector3.UP, color, block_center_y, top_flag, tile_offset, tile_scale, flip_inner_winding)
	else:
		# Regular ramps use quad rendering, except ramp_se which needs flipped cull.
		if block_id == 106:
			add_tri_double_sided(vertices, normals, colors, uvs, uv2s, base, nw, se, sw, Vector3.UP, color, block_center_y, top_flag, tile_offset, tile_scale, true)
			add_tri_double_sided(vertices, normals, colors, uvs, uv2s, base, nw, ne, se, Vector3.UP, color, block_center_y, top_flag, tile_offset, tile_scale, true)
		else:
			add_quad_double_sided(vertices, normals, colors, uvs, uv2s, base, nw, sw, se, ne, Vector3.UP, color, block_center_y, top_flag, tile_offset, tile_scale)
	if above_occluding:
		counts["occluded"] += 2
	else:
		counts["visible"] += 2

	if below_occluding:
		counts["occluded"] += 2
	else:
		add_quad_double_sided(vertices, normals, colors, uvs, uv2s, base, bnw, bne, bse, bsw, Vector3.DOWN, color, block_center_y, 0.0, tile_offset, tile_scale)
		counts["visible"] += 2

	var north_counts := _add_ramp_side(vertices, normals, colors, uvs, uv2s, base, Vector3.BACK, bnw, bne, nw, ne, color, block_center_y, tile_offset, tile_scale, north_occluding)
	var south_counts := _add_ramp_side(vertices, normals, colors, uvs, uv2s, base, Vector3.FORWARD, bsw, bse, sw, se, color, block_center_y, tile_offset, tile_scale, south_occluding)
	var east_counts := _add_ramp_side(vertices, normals, colors, uvs, uv2s, base, Vector3.RIGHT, bne, bse, ne, se, color, block_center_y, tile_offset, tile_scale, east_occluding)
	var west_counts := _add_ramp_side(vertices, normals, colors, uvs, uv2s, base, Vector3.LEFT, bnw, bsw, nw, sw, color, block_center_y, tile_offset, tile_scale, west_occluding)

	counts["visible"] += int(north_counts["visible"]) + int(south_counts["visible"]) + int(east_counts["visible"]) + int(west_counts["visible"])
	counts["occluded"] += int(north_counts["occluded"]) + int(south_counts["occluded"]) + int(east_counts["occluded"]) + int(west_counts["occluded"])
	return counts


func _add_ramp_side(
	vertices: PackedVector3Array,
	normals: PackedVector3Array,
	colors: PackedColorArray,
	uvs: PackedVector2Array,
	uv2s: PackedVector2Array,
	base: Vector3,
	expected_normal: Vector3,
	bottom_a: Vector3,
	bottom_b: Vector3,
	top_a: Vector3,
	top_b: Vector3,
	color: Color,
	block_center_y: float,
	tile_offset: Vector2,
	tile_scale: Vector2,
	neighbor_occluding: bool
) -> Dictionary:
	var counts := {"visible": 0, "occluded": 0}
	if neighbor_occluding:
		counts["occluded"] = 2
		return counts
	var bottom_y := bottom_a.y
	var top_a_flat := is_equal_approx(top_a.y, bottom_y)
	var top_b_flat := is_equal_approx(top_b.y, bottom_y)
	if top_a_flat and top_b_flat:
		return counts
	if top_a_flat and not top_b_flat:
		add_tri_double_sided(vertices, normals, colors, uvs, uv2s, base, bottom_a, bottom_b, top_b, expected_normal, color, block_center_y, 0.0, tile_offset, tile_scale)
		counts["visible"] = 2
		return counts
	if top_b_flat and not top_a_flat:
		add_tri_double_sided(vertices, normals, colors, uvs, uv2s, base, bottom_a, bottom_b, top_a, expected_normal, color, block_center_y, 0.0, tile_offset, tile_scale)
		counts["visible"] = 2
		return counts
	add_quad_double_sided(vertices, normals, colors, uvs, uv2s, base, bottom_a, bottom_b, top_b, top_a, expected_normal, color, block_center_y, 0.0, tile_offset, tile_scale)
	counts["visible"] = 2
	return counts


func _ramp_corner_heights(block_id: int, h: float) -> Dictionary:
	# Using literal IDs to avoid any const resolution issues
	match block_id:
		100:  # RAMP_NORTH
			return {"nw": h, "ne": h, "se": -h, "sw": -h}
		101:  # RAMP_SOUTH
			return {"nw": -h, "ne": -h, "se": h, "sw": h}
		102:  # RAMP_EAST
			return {"nw": -h, "ne": h, "se": h, "sw": -h}
		103:  # RAMP_WEST
			return {"nw": h, "ne": -h, "se": -h, "sw": h}
		104:  # RAMP_NORTHEAST - index 2: only NE high
			return {"nw": -h, "ne": h, "se": -h, "sw": -h}
		105:  # RAMP_NORTHWEST - index 1: only NW high
			return {"nw": h, "ne": -h, "se": -h, "sw": -h}
		106:  # RAMP_SOUTHEAST - index 8: only SE high
			return {"nw": -h, "ne": -h, "se": h, "sw": -h}
		107:  # RAMP_SOUTHWEST - index 4: only SW high
			return {"nw": -h, "ne": -h, "se": -h, "sw": h}
		108:  # INNER_SOUTHWEST
			return {"nw": h, "ne": h, "se": h, "sw": -h}
		109:  # INNER_SOUTHEAST
			return {"nw": h, "ne": h, "se": -h, "sw": h}
		110:  # INNER_NORTHWEST
			return {"nw": -h, "ne": h, "se": h, "sw": h}
		111:  # INNER_NORTHEAST
			return {"nw": h, "ne": -h, "se": h, "sw": h}
		_:
			return {"nw": -h, "ne": -h, "se": -h, "sw": -h}


func _is_inner_corner_id(block_id: int) -> bool:
	return block_id == 108 or block_id == 109 or block_id == 110 or block_id == 111


func _get_inner_corner_low_corner(block_id: int) -> String:
	match block_id:
		108:  # INNER_SOUTHWEST
			return "sw"
		109:  # INNER_SOUTHEAST
			return "se"
		110:  # INNER_NORTHWEST
			return "nw"
		111:  # INNER_NORTHEAST
			return "ne"
		_:
			return ""


func face_shade(normal: Vector3) -> float:
	if normal.y > SHADE_THRESHOLD:
		return SHADE_TOP
	if normal.y < -SHADE_THRESHOLD:
		return SHADE_BOTTOM
	if abs(normal.x) > SHADE_THRESHOLD:
		return SHADE_SIDE
	return SHADE_FRONT_BACK
#endregion
