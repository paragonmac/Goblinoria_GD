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
	var neighbors: Dictionary = {
		"x_neg": _copy_neighbor_blocks(world, Vector3i(cx - 1, cy, cz)),
		"x_pos": _copy_neighbor_blocks(world, Vector3i(cx + 1, cy, cz)),
		"y_neg": _copy_neighbor_blocks(world, Vector3i(cx, cy - 1, cz)),
		"y_pos": _copy_neighbor_blocks(world, Vector3i(cx, cy + 1, cz)),
		"z_neg": _copy_neighbor_blocks(world, Vector3i(cx, cy, cz - 1)),
		"z_pos": _copy_neighbor_blocks(world, Vector3i(cx, cy, cz + 1)),
	}
	var job := {
		"chunk_size": World.CHUNK_SIZE,
		"cx": cx,
		"cy": cy,
		"cz": cz,
		"top_render_y": world.top_render_y,
		"air_id": World.BLOCK_ID_AIR,
		"blocks": chunk.blocks,
		"neighbors": neighbors,
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
		"visible_faces": visible_faces,
		"occluded_faces": occluded_faces,
		"has_geometry": has_geometry,
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
	var neighbors: Dictionary = job["neighbors"]
	var solid_table: PackedByteArray = job["solid_table"]
	var ramp_table: PackedByteArray = job.get("ramp_table", PackedByteArray())
	var color_table: PackedColorArray = job["color_table"]
	var atlas_columns: int = int(job.get("atlas_columns", ATLAS_COLUMNS))
	var atlas_rows: int = int(job.get("atlas_rows", ATLAS_ROWS))
	if atlas_columns <= 0:
		atlas_columns = 1
	if atlas_rows <= 0:
		atlas_rows = 1
	var tile_scale := _atlas_tile_scale(atlas_columns, atlas_rows)
	var tile_count := atlas_columns * atlas_rows
	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	var colors := PackedColorArray()
	var uvs := PackedVector2Array()
	var uv2s := PackedVector2Array()
	var visible_faces := 0
	var occluded_faces := 0

	for lx in range(chunk_size):
		var wx := cx * chunk_size + lx
		for ly in range(chunk_size):
			var wy := cy * chunk_size + ly
			for lz in range(chunk_size):
				var wz := cz * chunk_size + lz
				var idx := chunk_index(chunk_size, lx, ly, lz)
				var block_id := blocks[idx]
				if block_id == air_id:
					continue

				var base := Vector3(lx, ly, lz)
				var block_center_y: float = float(wy)

				var above_id := air_id
				if ly + 1 < chunk_size:
					above_id = blocks[chunk_index(chunk_size, lx, ly + 1, lz)]
				else:
					above_id = neighbor_block(neighbors.get("y_pos", null), chunk_size, lx, 0, lz, air_id)

				var below_id := air_id
				if ly - 1 >= 0:
					below_id = blocks[chunk_index(chunk_size, lx, ly - 1, lz)]
				else:
					below_id = neighbor_block(neighbors.get("y_neg", null), chunk_size, lx, chunk_size - 1, lz, air_id)
				var color_id := block_id
				if is_ramp_id(block_id, ramp_table) and below_id != air_id:
					if not _is_inner_corner_id(block_id):
						color_id = below_id
				var color := block_color_from_table(color_table, color_id, wx, wy, wz)
				var tile_id := color_id
				var tile_index := _tile_index_for_id(tile_id, tile_count)
				var tile_offset := _atlas_tile_offset(tile_index, atlas_columns, tile_scale)

				var forward_id := air_id
				if lz + 1 < chunk_size:
					forward_id = blocks[chunk_index(chunk_size, lx, ly, lz + 1)]
				else:
					forward_id = neighbor_block(neighbors.get("z_pos", null), chunk_size, lx, ly, 0, air_id)

				var back_id := air_id
				if lz - 1 >= 0:
					back_id = blocks[chunk_index(chunk_size, lx, ly, lz - 1)]
				else:
					back_id = neighbor_block(neighbors.get("z_neg", null), chunk_size, lx, ly, chunk_size - 1, air_id)

				var right_id := air_id
				if lx + 1 < chunk_size:
					right_id = blocks[chunk_index(chunk_size, lx + 1, ly, lz)]
				else:
					right_id = neighbor_block(neighbors.get("x_pos", null), chunk_size, 0, ly, lz, air_id)

				var left_id := air_id
				if lx - 1 >= 0:
					left_id = blocks[chunk_index(chunk_size, lx - 1, ly, lz)]
				else:
					left_id = neighbor_block(neighbors.get("x_neg", null), chunk_size, chunk_size - 1, ly, lz, air_id)
				var above_occluding := is_solid_id(above_id, solid_table)
				var below_occluding := is_solid_id(below_id, solid_table)
				var forward_occluding_ramp := is_occluding_id(forward_id, solid_table, ramp_table)
				var back_occluding_ramp := is_occluding_id(back_id, solid_table, ramp_table)
				var right_occluding_ramp := is_occluding_id(right_id, solid_table, ramp_table)
				var left_occluding_ramp := is_occluding_id(left_id, solid_table, ramp_table)
				var forward_occluding := is_face_occluding(forward_id, solid_table, ramp_table, Vector3.BACK)
				var back_occluding := is_face_occluding(back_id, solid_table, ramp_table, Vector3.FORWARD)
				var right_occluding := is_face_occluding(right_id, solid_table, ramp_table, Vector3.LEFT)
				var left_occluding := is_face_occluding(left_id, solid_table, ramp_table, Vector3.RIGHT)

				if is_ramp_id(block_id, ramp_table):
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
					visible_faces += int(counts.get("visible", 0))
					occluded_faces += int(counts.get("occluded", 0))
					continue

				var top_flag := 1.0 if above_occluding else 0.0
				add_face(vertices, normals, colors, uvs, uv2s, base, Vector3.UP, color, block_center_y, top_flag, tile_offset, tile_scale)
				if above_occluding:
					occluded_faces += 1
				else:
					visible_faces += 1

				if not below_occluding:
					add_face(vertices, normals, colors, uvs, uv2s, base, Vector3.DOWN, color, block_center_y, 0.0, tile_offset, tile_scale)
					visible_faces += 1
				else:
					occluded_faces += 1

				if not forward_occluding:
					add_face(vertices, normals, colors, uvs, uv2s, base, Vector3.FORWARD, color, block_center_y, 0.0, tile_offset, tile_scale)
					visible_faces += 1
				else:
					occluded_faces += 1

				if not back_occluding:
					add_face(vertices, normals, colors, uvs, uv2s, base, Vector3.BACK, color, block_center_y, 0.0, tile_offset, tile_scale)
					visible_faces += 1
				else:
					occluded_faces += 1

				if not right_occluding:
					add_face(vertices, normals, colors, uvs, uv2s, base, Vector3.RIGHT, color, block_center_y, 0.0, tile_offset, tile_scale)
					visible_faces += 1
				else:
					occluded_faces += 1

				if not left_occluding:
					add_face(vertices, normals, colors, uvs, uv2s, base, Vector3.LEFT, color, block_center_y, 0.0, tile_offset, tile_scale)
					visible_faces += 1
				else:
					occluded_faces += 1

	var has_geometry := vertices.size() > 0
	return {
		"vertices": vertices,
		"normals": normals,
		"colors": colors,
		"uv": uvs,
		"uv2": uv2s,
		"visible_faces": visible_faces,
		"occluded_faces": occluded_faces,
		"has_geometry": has_geometry,
	}
#endregion


#region Block Colors
func block_color(world: World, block_id: int, wx: int, wy: int, wz: int) -> Color:
	var base: Color = world.get_block_color(block_id)
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
	var h: int = wx * HASH_X ^ wy * HASH_Y ^ wz * HASH_Z
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


func _copy_neighbor_blocks(world: World, coord: Vector3i) -> Variant:
	if world == null:
		return null
	var chunk: ChunkData = world.get_chunk(coord)
	if chunk == null or not chunk.generated:
		return null
	return chunk.blocks


func chunk_index(chunk_size: int, lx: int, ly: int, lz: int) -> int:
	return (lz * chunk_size + ly) * chunk_size + lx


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
		row = int(tile_index / columns)
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
