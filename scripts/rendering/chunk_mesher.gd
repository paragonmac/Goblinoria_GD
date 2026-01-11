extends RefCounted
class_name ChunkMesher

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

func build_chunk_mesh(world: World, cx: int, cy: int, cz: int) -> Dictionary:
	var chunk_size: int = World.CHUNK_SIZE
	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	var colors := PackedColorArray()
	var visible_faces := 0
	var occluded_faces := 0

	for lx in range(chunk_size):
		var wx := cx * chunk_size + lx
		for ly in range(chunk_size):
			var wy := cy * chunk_size + ly
			if wy > world.top_render_y:
				continue
			for lz in range(chunk_size):
				var wz := cz * chunk_size + lz
				var block_id := world.get_block(wx, wy, wz)
				if world.is_block_empty_id(block_id):
					continue

				var base := Vector3(lx, ly, lz)
				var color := block_color(world, block_id, wx, wy, wz)

				if not world.is_solid(wx, wy + 1, wz) or wy + 1 > world.top_render_y:
					add_face(vertices, normals, colors, base, Vector3.UP, color)
					visible_faces += 1
				else:
					occluded_faces += 1
				if not world.is_solid(wx, wy - 1, wz):
					add_face(vertices, normals, colors, base, Vector3.DOWN, color)
					visible_faces += 1
				else:
					occluded_faces += 1
				if not world.is_solid(wx, wy, wz + 1):
					add_face(vertices, normals, colors, base, Vector3.FORWARD, color)
					visible_faces += 1
				else:
					occluded_faces += 1
				if not world.is_solid(wx, wy, wz - 1):
					add_face(vertices, normals, colors, base, Vector3.BACK, color)
					visible_faces += 1
				else:
					occluded_faces += 1
				if not world.is_solid(wx + 1, wy, wz):
					add_face(vertices, normals, colors, base, Vector3.RIGHT, color)
					visible_faces += 1
				else:
					occluded_faces += 1
				if not world.is_solid(wx - 1, wy, wz):
					add_face(vertices, normals, colors, base, Vector3.LEFT, color)
					visible_faces += 1
				else:
					occluded_faces += 1

	var mesh := ArrayMesh.new()
	var has_geometry := vertices.size() > 0
	if has_geometry:
		var arrays := []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = vertices
		arrays[Mesh.ARRAY_NORMAL] = normals
		arrays[Mesh.ARRAY_COLOR] = colors
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)

	return {
		"mesh": mesh,
		"visible_faces": visible_faces,
		"occluded_faces": occluded_faces,
		"has_geometry": has_geometry,
	}


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


func block_noise(wx: int, wy: int, wz: int) -> float:
	var h: int = wx * HASH_X ^ wy * HASH_Y ^ wz * HASH_Z
	h = (h ^ (h >> HASH_SHIFT)) & HASH_MASK
	return float(h % BLOCK_NOISE_MOD) / BLOCK_NOISE_DIV


func add_face(vertices: PackedVector3Array, normals: PackedVector3Array, colors: PackedColorArray, base: Vector3, normal: Vector3, color: Color) -> void:
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

	vertices.append_array([v1, v3, v2, v1, v4, v3])
	normals.append_array([normal, normal, normal, normal, normal, normal])
	colors.append_array([shaded, shaded, shaded, shaded, shaded, shaded])


func face_shade(normal: Vector3) -> float:
	if normal.y > SHADE_THRESHOLD:
		return SHADE_TOP
	if normal.y < -SHADE_THRESHOLD:
		return SHADE_BOTTOM
	if abs(normal.x) > SHADE_THRESHOLD:
		return SHADE_SIDE
	return SHADE_FRONT_BACK
