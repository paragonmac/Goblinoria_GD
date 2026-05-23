extends RefCounted
class_name ChunkMesherUv


func atlas_tile_scale(columns: int, rows: int) -> Vector2:
	return Vector2(1.0 / float(columns), 1.0 / float(rows))


func atlas_tile_offset(tile_index: int, columns: int, tile_scale: Vector2) -> Vector2:
	var col := 0
	var row := 0
	if columns > 0:
		col = tile_index % columns
		row = int(floor(float(tile_index) / float(columns)))
	return Vector2(float(col) * tile_scale.x, float(row) * tile_scale.y)


func tile_index_for_id(block_id: int, tile_count: int) -> int:
	if tile_count <= 0:
		return 0
	if block_id < 0:
		return 0
	return block_id % tile_count


func planar_uv(vertex: Vector3, base: Vector3, normal: Vector3) -> Vector2:
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


func atlas_uv(local_uv: Vector2, tile_offset: Vector2, tile_scale: Vector2) -> Vector2:
	return tile_offset + Vector2(local_uv.x * tile_scale.x, local_uv.y * tile_scale.y)