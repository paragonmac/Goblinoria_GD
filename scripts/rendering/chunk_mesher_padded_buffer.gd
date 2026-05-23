extends RefCounted
class_name ChunkMesherPaddedBuffer


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