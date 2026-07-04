extends RefCounted
class_name WorldChunkSpace
## Shared finite-world chunk coordinate helpers.


static func chunk_coord_from_world(value: float, chunk_size: int = World.CHUNK_SIZE) -> int:
	return int(floor(value / float(chunk_size)))


static func world_to_chunk_coords(x: int, y: int, z: int, chunk_size: int = World.CHUNK_SIZE) -> Vector3i:
	return Vector3i(
		floor_div(x, chunk_size),
		floor_div(y, chunk_size),
		floor_div(z, chunk_size)
	)


static func chunk_to_local_coords(x: int, y: int, z: int, chunk_size: int = World.CHUNK_SIZE) -> Vector3i:
	return Vector3i(
		positive_mod(x, chunk_size),
		positive_mod(y, chunk_size),
		positive_mod(z, chunk_size)
	)


static func floor_div(a: int, b: int) -> int:
	return int(floor(float(a) / float(b)))


static func positive_mod(a: int, b: int) -> int:
	var r := a % b
	return r + b if r < 0 else r


static func chunk_index(lx: int, ly: int, lz: int, chunk_size: int = World.CHUNK_SIZE) -> int:
	return (lz * chunk_size + ly) * chunk_size + lx


static func chunk_y_for_render_y(render_y: int, world_size_y: int, chunk_size: int = World.CHUNK_SIZE) -> int:
	var clamped_y: int = clampi(render_y, 0, world_size_y - 1)
	return clampi(chunk_coord_from_world(float(clamped_y), chunk_size), 0, World.WORLD_CHUNKS_Y - 1)


static func full_top_y(coord: Vector3i, chunk_size: int = World.CHUNK_SIZE) -> int:
	return coord.y * chunk_size + chunk_size - 1


static func is_chunk_coord_valid(coord: Vector3i) -> bool:
	return is_chunk_coord_valid_for_height(coord, World.WORLD_CHUNKS_Y * World.CHUNK_SIZE)


static func is_chunk_coord_valid_for_height(coord: Vector3i, world_size_y: int, chunk_size: int = World.CHUNK_SIZE) -> bool:
	var max_cy: int = int(floor(float(world_size_y) / float(chunk_size)))
	return coord.x >= World.WORLD_MIN_CHUNK_X \
		and coord.x <= World.WORLD_MAX_CHUNK_X \
		and coord.y >= 0 \
		and coord.y < max_cy \
		and coord.z >= World.WORLD_MIN_CHUNK_Z \
		and coord.z <= World.WORLD_MAX_CHUNK_Z


static func is_block_xz_valid(x: int, z: int) -> bool:
	return x >= World.WORLD_MIN_BLOCK_X \
		and x <= World.WORLD_MAX_BLOCK_X \
		and z >= World.WORLD_MIN_BLOCK_Z \
		and z <= World.WORLD_MAX_BLOCK_Z


static func is_block_coord_valid(x: int, y: int, z: int, world_size_y: int) -> bool:
	return is_block_xz_valid(x, z) and y >= 0 and y < world_size_y


static func clamp_block_xz(pos: Vector3) -> Vector3:
	return Vector3(
		clampf(pos.x, float(World.WORLD_MIN_BLOCK_X), float(World.WORLD_MAX_BLOCK_X)),
		pos.y,
		clampf(pos.z, float(World.WORLD_MIN_BLOCK_Z), float(World.WORLD_MAX_BLOCK_Z))
	)


static func world_bounds_rect(world_size_x: int, world_size_z: int) -> Rect2:
	return Rect2(
		Vector2(float(World.WORLD_MIN_BLOCK_X), float(World.WORLD_MIN_BLOCK_Z)),
		Vector2(float(world_size_x), float(world_size_z))
	)


static func band_range(center_cy: int, radius: int) -> Array[int]:
	var bands: Array[int] = []
	var min_cy: int = maxi(0, center_cy - radius)
	var max_cy: int = mini(World.WORLD_CHUNKS_Y - 1, center_cy + radius)
	for cy: int in range(min_cy, max_cy + 1):
		bands.append(cy)
	return bands


static func all_world_chunk_targets() -> Array[Vector3i]:
	var targets: Array[Vector3i] = []
	for cy: int in range(World.WORLD_CHUNKS_Y):
		for cx: int in range(World.WORLD_MIN_CHUNK_X, World.WORLD_MAX_CHUNK_X + 1):
			for cz: int in range(World.WORLD_MIN_CHUNK_Z, World.WORLD_MAX_CHUNK_Z + 1):
				targets.append(Vector3i(cx, cy, cz))
	return targets


static func chunk_targets_for_bands(bands: Array[int]) -> Array[Vector3i]:
	return chunk_targets_for_bands_in_bounds(bands, {
		"min_x": World.WORLD_MIN_CHUNK_X,
		"max_x": World.WORLD_MAX_CHUNK_X,
		"min_z": World.WORLD_MIN_CHUNK_Z,
		"max_z": World.WORLD_MAX_CHUNK_Z,
	})


static func chunk_targets_for_bands_in_bounds(bands: Array[int], bounds: Dictionary) -> Array[Vector3i]:
	var targets: Array[Vector3i] = []
	var min_cx: int = int(bounds.get("min_x", World.WORLD_MIN_CHUNK_X))
	var max_cx: int = int(bounds.get("max_x", World.WORLD_MAX_CHUNK_X))
	var min_cz: int = int(bounds.get("min_z", World.WORLD_MIN_CHUNK_Z))
	var max_cz: int = int(bounds.get("max_z", World.WORLD_MAX_CHUNK_Z))
	if min_cx > max_cx or min_cz > max_cz:
		return targets
	for cy_value in bands:
		var cy: int = int(cy_value)
		for cx: int in range(min_cx, max_cx + 1):
			for cz: int in range(min_cz, max_cz + 1):
				var coord := Vector3i(cx, cy, cz)
				if is_chunk_coord_valid(coord):
					targets.append(coord)
	return targets
