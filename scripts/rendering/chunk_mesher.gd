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
#endregion

#region State
var block_solid_table := PackedByteArray()
var block_color_table := PackedColorArray()
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
		"color_table": block_color_table,
	}
	var data := build_chunk_arrays_from_data(job)
	var vertices: PackedVector3Array = data["vertices"]
	var normals: PackedVector3Array = data["normals"]
	var colors: PackedColorArray = data["colors"]
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
	var color_table: PackedColorArray = job["color_table"]
	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	var colors := PackedColorArray()
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
				var color := block_color_from_table(color_table, block_id, wx, wy, wz)

				var above_id := air_id
				if ly + 1 < chunk_size:
					above_id = blocks[chunk_index(chunk_size, lx, ly + 1, lz)]
				else:
					above_id = neighbor_block(neighbors.get("y_pos", null), chunk_size, lx, 0, lz, air_id)
				var above_solid := is_solid_id(above_id, solid_table)
				var top_flag := 1.0 if above_solid else 0.0
				add_face(vertices, normals, colors, uv2s, base, Vector3.UP, color, block_center_y, top_flag)
				if above_solid:
					occluded_faces += 1
				else:
					visible_faces += 1

				var below_id := air_id
				if ly - 1 >= 0:
					below_id = blocks[chunk_index(chunk_size, lx, ly - 1, lz)]
				else:
					below_id = neighbor_block(neighbors.get("y_neg", null), chunk_size, lx, chunk_size - 1, lz, air_id)
				if not is_solid_id(below_id, solid_table):
					add_face(vertices, normals, colors, uv2s, base, Vector3.DOWN, color, block_center_y, 0.0)
					visible_faces += 1
				else:
					occluded_faces += 1

				var forward_id := air_id
				if lz + 1 < chunk_size:
					forward_id = blocks[chunk_index(chunk_size, lx, ly, lz + 1)]
				else:
					forward_id = neighbor_block(neighbors.get("z_pos", null), chunk_size, lx, ly, 0, air_id)
				if not is_solid_id(forward_id, solid_table):
					add_face(vertices, normals, colors, uv2s, base, Vector3.FORWARD, color, block_center_y, 0.0)
					visible_faces += 1
				else:
					occluded_faces += 1

				var back_id := air_id
				if lz - 1 >= 0:
					back_id = blocks[chunk_index(chunk_size, lx, ly, lz - 1)]
				else:
					back_id = neighbor_block(neighbors.get("z_neg", null), chunk_size, lx, ly, chunk_size - 1, air_id)
				if not is_solid_id(back_id, solid_table):
					add_face(vertices, normals, colors, uv2s, base, Vector3.BACK, color, block_center_y, 0.0)
					visible_faces += 1
				else:
					occluded_faces += 1

				var right_id := air_id
				if lx + 1 < chunk_size:
					right_id = blocks[chunk_index(chunk_size, lx + 1, ly, lz)]
				else:
					right_id = neighbor_block(neighbors.get("x_pos", null), chunk_size, 0, ly, lz, air_id)
				if not is_solid_id(right_id, solid_table):
					add_face(vertices, normals, colors, uv2s, base, Vector3.RIGHT, color, block_center_y, 0.0)
					visible_faces += 1
				else:
					occluded_faces += 1

				var left_id := air_id
				if lx - 1 >= 0:
					left_id = blocks[chunk_index(chunk_size, lx - 1, ly, lz)]
				else:
					left_id = neighbor_block(neighbors.get("x_neg", null), chunk_size, chunk_size - 1, ly, lz, air_id)
				if not is_solid_id(left_id, solid_table):
					add_face(vertices, normals, colors, uv2s, base, Vector3.LEFT, color, block_center_y, 0.0)
					visible_faces += 1
				else:
					occluded_faces += 1

	var has_geometry := vertices.size() > 0
	return {
		"vertices": vertices,
		"normals": normals,
		"colors": colors,
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
	if block_solid_table.size() == BlockRegistry.TABLE_SIZE and block_color_table.size() == BlockRegistry.TABLE_SIZE:
		return
	block_solid_table.resize(BlockRegistry.TABLE_SIZE)
	block_color_table.resize(BlockRegistry.TABLE_SIZE)
	for i in range(BlockRegistry.TABLE_SIZE):
		block_solid_table[i] = 1 if world.is_block_solid_id(i) else 0
		block_color_table[i] = world.get_block_color(i)


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
#endregion


#region Face Generation
func add_face(vertices: PackedVector3Array, normals: PackedVector3Array, colors: PackedColorArray, uv2s: PackedVector2Array, base: Vector3, normal: Vector3, color: Color, block_center_y: float, top_flag: float) -> void:
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

	vertices.append_array([v1, v3, v2, v1, v4, v3])
	normals.append_array([normal, normal, normal, normal, normal, normal])
	colors.append_array([shaded, shaded, shaded, shaded, shaded, shaded])
	uv2s.append_array([uv2, uv2, uv2, uv2, uv2, uv2])


func face_shade(normal: Vector3) -> float:
	if normal.y > SHADE_THRESHOLD:
		return SHADE_TOP
	if normal.y < -SHADE_THRESHOLD:
		return SHADE_BOTTOM
	if abs(normal.x) > SHADE_THRESHOLD:
		return SHADE_SIDE
	return SHADE_FRONT_BACK
#endregion
