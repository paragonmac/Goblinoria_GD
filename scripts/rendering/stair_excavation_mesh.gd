extends RefCounted
## Temporary faces exposed by a preview cutout; reads resident terrain only.

const Mesher = preload("res://scripts/rendering/chunk_mesher.gd")
const DIRECTIONS := [Vector3i.LEFT, Vector3i.RIGHT, Vector3i.FORWARD, Vector3i.BACK, Vector3i.DOWN, Vector3i.UP]


static func build(world: World, cells: Array[Vector3i]) -> ArrayMesh:
	var mesh := ArrayMesh.new()
	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	var colors := PackedColorArray()
	var uvs := PackedVector2Array()
	var uv2s := PackedVector2Array()
	var mesher := Mesher.new()
	var tile_scale: Vector2 = mesher.uv_helper.atlas_tile_scale(Mesher.ATLAS_COLUMNS, Mesher.ATLAS_ROWS)
	for cell: Vector3i in cells:
		var current_id := world.get_block_no_generate(cell.x, cell.y, cell.z)
		# Faces bordering air or an existing slope are already in the terrain mesh.
		if not world.is_block_solid_id(current_id) or world.is_ramp_block_id(current_id):
			continue
		for direction: Vector3i in DIRECTIONS:
			var neighbor := cell + direction
			if cells.has(neighbor):
				continue
			var block_id := world.get_block_no_generate(neighbor.x, neighbor.y, neighbor.z)
			if not world.is_block_solid_id(block_id) or world.is_ramp_block_id(block_id):
				continue
			var normal := -Vector3(direction)
			var center := Vector3(cell) + Vector3(direction) * 0.5
			var tangent := Vector3.RIGHT if direction.x == 0 else Vector3.BACK
			var bitangent := normal.cross(tangent)
			var tile: int = mesher.uv_helper.tile_index_for_id(block_id, Mesher.ATLAS_COLUMNS * Mesher.ATLAS_ROWS)
			var tile_offset: Vector2 = mesher.uv_helper.atlas_tile_offset(tile, Mesher.ATLAS_COLUMNS, tile_scale)
			mesher.add_quad_with_normal(
				vertices, normals, colors, uvs, uv2s, Vector3(neighbor),
				center - tangent * 0.5 - bitangent * 0.5,
				center + tangent * 0.5 - bitangent * 0.5,
				center + tangent * 0.5 + bitangent * 0.5,
				center - tangent * 0.5 + bitangent * 0.5,
				normal, world.get_block_color(block_id), float(neighbor.y), 0.0,
				tile_offset, tile_scale
			)
	if not vertices.is_empty():
		var arrays: Array = []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = vertices
		arrays[Mesh.ARRAY_NORMAL] = normals
		arrays[Mesh.ARRAY_COLOR] = colors
		arrays[Mesh.ARRAY_TEX_UV] = uvs
		arrays[Mesh.ARRAY_TEX_UV2] = uv2s
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh
