extends RefCounted
class_name ChunkMesherPaddedBuffer


## Copies a chunk and the facing layer of each present neighbour into a buffer
## padded by one cell on every side. Runs for every mesh job, on the main thread.
## Rows along X are contiguous in both layouts, so 8-cell rows move as one
## 64-bit value; other chunk sizes copy cell by cell.
func build_padded_block_buffer(chunk_size: int, blocks: PackedByteArray, neighbors: Dictionary, air_id: int) -> PackedByteArray:
	var n := chunk_size
	var ps: int = n + 2
	var padded := PackedByteArray()
	padded.resize(ps * ps * ps)
	padded.fill(air_id)
	var wide_rows := n == 8
	for lz in range(n):
		for ly in range(n):
			var source := (lz * n + ly) * n
			var target := ((lz + 1) * ps + ly + 1) * ps + 1
			if wide_rows:
				padded.encode_s64(target, blocks.decode_s64(source))
			else:
				for lx in range(n):
					padded[target + lx] = blocks[source + lx]
	var cell_count := n * n * n
	for side: String in ["x_neg", "x_pos", "y_neg", "y_pos", "z_neg", "z_pos"]:
		var value: Variant = neighbors.get(side, null)
		if typeof(value) != TYPE_PACKED_BYTE_ARRAY:
			continue
		var other: PackedByteArray = value
		if other.size() != cell_count:
			continue
		match side:
			"x_neg", "x_pos":
				# One cell per row: the neighbour's far or near X column.
				var source_x := n - 1 if side == "x_neg" else 0
				var target_x := 0 if side == "x_neg" else n + 1
				for lz in range(n):
					for ly in range(n):
						padded[((lz + 1) * ps + ly + 1) * ps + target_x] = other[(lz * n + ly) * n + source_x]
			"y_neg", "y_pos":
				var source_y := n - 1 if side == "y_neg" else 0
				var target_y := 0 if side == "y_neg" else n + 1
				for lz in range(n):
					_copy_row(padded, ((lz + 1) * ps + target_y) * ps + 1, other, (lz * n + source_y) * n, n, wide_rows)
			_:
				var source_z := n - 1 if side == "z_neg" else 0
				var target_z := 0 if side == "z_neg" else n + 1
				for ly in range(n):
					_copy_row(padded, (target_z * ps + ly + 1) * ps + 1, other, (source_z * n + ly) * n, n, wide_rows)
	return padded


func _copy_row(padded: PackedByteArray, target: int, source_blocks: PackedByteArray, source: int, n: int, wide_rows: bool) -> void:
	if wide_rows:
		padded.encode_s64(target, source_blocks.decode_s64(source))
		return
	for lx in range(n):
		padded[target + lx] = source_blocks[source + lx]


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