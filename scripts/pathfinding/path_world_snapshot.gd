extends RefCounted
class_name PathWorldSnapshot
## Immutable chunk-buffer view used by background path searches.

var world_size_y := 0
var chunk_size := 0
var air_id := 0
var min_block := Vector3i.ZERO
var max_block := Vector3i.ZERO
var chunks: Dictionary = {}
var chunk_revisions: Dictionary = {}
var solid_table := PackedByteArray()
var ramp_table := PackedByteArray()


func capture_from_world(world, start: Vector3i, goals: Array, margin_xz: int, margin_y: int) -> void:
	world_size_y = world.world_size_y
	chunk_size = World.CHUNK_SIZE
	air_id = World.BLOCK_ID_AIR

	var min_pos := start
	var max_pos := start
	for goal: Vector3i in goals:
		min_pos.x = mini(min_pos.x, goal.x)
		min_pos.y = mini(min_pos.y, goal.y)
		min_pos.z = mini(min_pos.z, goal.z)
		max_pos.x = maxi(max_pos.x, goal.x)
		max_pos.y = maxi(max_pos.y, goal.y)
		max_pos.z = maxi(max_pos.z, goal.z)
	min_block = Vector3i(
		maxi(World.WORLD_MIN_BLOCK_X, min_pos.x - margin_xz),
		maxi(0, min_pos.y - margin_y),
		maxi(World.WORLD_MIN_BLOCK_Z, min_pos.z - margin_xz)
	)
	max_block = Vector3i(
		mini(World.WORLD_MAX_BLOCK_X, max_pos.x + margin_xz),
		mini(world.world_size_y - 1, max_pos.y + margin_y),
		mini(World.WORLD_MAX_BLOCK_Z, max_pos.z + margin_xz)
	)
	solid_table = world.block_registry.solid.duplicate()
	ramp_table.resize(BlockRegistry.TABLE_SIZE)
	for block_id in range(BlockRegistry.TABLE_SIZE):
		ramp_table[block_id] = 1 if world.is_ramp_block_id(block_id) else 0

	var min_chunk: Vector3i = world.world_to_chunk_coords(
		min_block.x,
		min_block.y,
		min_block.z
	)
	var max_chunk: Vector3i = world.world_to_chunk_coords(
		max_block.x,
		max_block.y,
		max_block.z
	)
	for cx in range(min_chunk.x, max_chunk.x + 1):
		for cy in range(min_chunk.y, max_chunk.y + 1):
			for cz in range(min_chunk.z, max_chunk.z + 1):
				var coord := Vector3i(cx, cy, cz)
				var chunk = world.get_chunk(coord)
				if chunk == null or not chunk.generated:
					chunk_revisions[coord] = -1
					continue
				chunks[coord] = chunk.blocks.duplicate()
				chunk_revisions[coord] = chunk.mesh_revision


func is_block_coord_valid(x: int, y: int, z: int) -> bool:
	return x >= min_block.x and x <= max_block.x \
		and y >= min_block.y and y <= max_block.y \
		and z >= min_block.z and z <= max_block.z \
		and y >= 0 and y < world_size_y


func get_block_no_generate(x: int, y: int, z: int) -> int:
	if not is_block_coord_valid(x, y, z):
		return air_id
	var coord := Vector3i(
		_floor_div(x, chunk_size),
		_floor_div(y, chunk_size),
		_floor_div(z, chunk_size)
	)
	if not chunks.has(coord):
		return air_id
	var local_x := _positive_mod(x, chunk_size)
	var local_y := _positive_mod(y, chunk_size)
	var local_z := _positive_mod(z, chunk_size)
	var blocks: PackedByteArray = chunks[coord]
	var index := (local_z * chunk_size + local_y) * chunk_size + local_x
	if index < 0 or index >= blocks.size():
		return air_id
	return int(blocks[index])


func is_block_solid_id(block_id: int) -> bool:
	return block_id >= 0 and block_id < solid_table.size() and solid_table[block_id] != 0


func is_ramp_block_id(block_id: int) -> bool:
	return block_id >= 0 and block_id < ramp_table.size() and ramp_table[block_id] != 0


func revisions_match(world) -> bool:
	for coord: Vector3i in chunk_revisions:
		var expected_revision: int = int(chunk_revisions[coord])
		var chunk = world.get_chunk(coord)
		var current_revision := -1
		if chunk != null and chunk.generated:
			current_revision = chunk.mesh_revision
		if current_revision != expected_revision:
			return false
	return true


func _floor_div(value: int, divisor: int) -> int:
	return floori(float(value) / float(divisor))


func _positive_mod(value: int, divisor: int) -> int:
	var result := value % divisor
	return result + divisor if result < 0 else result
