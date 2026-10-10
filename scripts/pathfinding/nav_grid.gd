extends RefCounted
class_name NavGrid
## Dense snapshot of Pathfinder's directed, unit-cost navigation graph.
##
## For ordinary cells the mask fast path is equivalent because same-level
## traversal accepts every walkable cardinal neighbor and level changes require
## a ramp or stair at an endpoint. If the source or any of its 12 candidate
## endpoints is special (ramp/slope or stair flight), the authoritative
## Pathfinder.get_neighbors predicate is used instead.

const StairFlightScript = preload("res://scripts/stair_flight.gd")

const DIRS := [
	Vector3i(-1, 0, 0), Vector3i(1, 0, 0), Vector3i(0, 0, -1), Vector3i(0, 0, 1),
	Vector3i(-1, 1, 0), Vector3i(1, 1, 0), Vector3i(0, 1, -1), Vector3i(0, 1, 1),
	Vector3i(-1, -1, 0), Vector3i(1, -1, 0), Vector3i(0, -1, -1), Vector3i(0, -1, 1),
]

var box_min := Vector3i.ZERO
var box_max := Vector3i(-1, -1, -1)
var _sx := 0
var _sy := 0
var _sz := 0
var _layer := 0
var _walkable := PackedByteArray()
var _walkable_indices := PackedInt32Array()
var _requires_predicate := PackedByteArray()
var _valid := PackedByteArray()
var _special := PackedByteArray()
var _edge_mask := PackedInt32Array()
var _distance := PackedInt32Array()
var _built := false
var _flood_complete := false
var _flood_touched_box_edge := false
var _snapshot
var _pathfinder: Pathfinder
var _edge_mask_ready := PackedByteArray()

var _block_flat := PackedByteArray()
var _block_pad := PackedByteArray()
var _block_origin := Vector3i.ZERO
var _block_sx := 0
var _block_sy := 0
var _block_sz := 0


func build(snapshot, min_cell: Vector3i, max_cell: Vector3i, pathfinder: Pathfinder) -> void:
	box_min = min_cell
	box_max = max_cell
	_sx = maxi(0, box_max.x - box_min.x + 1)
	_sy = maxi(0, box_max.y - box_min.y + 1)
	_sz = maxi(0, box_max.z - box_min.z + 1)
	_layer = _sx * _sz
	var count := _sx * _sy * _sz
	_walkable.resize(count)
	_walkable.fill(0)
	_walkable_indices.clear()
	_requires_predicate.resize(count)
	_requires_predicate.fill(0)
	_valid.resize(count)
	_valid.fill(0)
	_special.resize(count)
	_special.fill(0)
	_edge_mask.resize(count)
	_edge_mask.fill(0)
	_edge_mask_ready.resize(count)
	_edge_mask_ready.fill(0)
	_distance.resize(count)
	_distance.fill(-1)
	_built = count > 0
	_flood_touched_box_edge = false
	_snapshot = snapshot
	_pathfinder = pathfinder
	if not _built:
		return
	var solid := PackedByteArray()
	var ramp := PackedByteArray()
	var flight := PackedByteArray()
	solid.resize(256)
	ramp.resize(256)
	flight.resize(256)
	for id in range(256):
		solid[id] = 1 if snapshot.is_block_solid_id(id) else 0
		ramp[id] = 1 if snapshot.is_ramp_block_id(id) else 0
		flight[id] = 1 if StairFlightScript.is_flight(id) else 0
	_copy_block_box(snapshot, ramp, flight)
	_classify_box(snapshot, pathfinder, solid, ramp, flight)
	_build_edge_masks(snapshot, pathfinder)


func _copy_block_box(snapshot, ramp: PackedByteArray, flight: PackedByteArray) -> void:
	_block_origin = Vector3i(box_min.x - 1, box_min.y - 1, box_min.z - 1)
	_block_sx = _sx + 2
	_block_sy = _sy + 2
	_block_sz = _sz + 2
	var block_count := _block_sx * _block_sz * _block_sy
	_block_flat.resize(_sx * _sy * _sz)
	_block_flat.fill(snapshot.air_id)
	_block_pad.resize(block_count)
	_block_pad.fill(snapshot.air_id)
	var cs: int = snapshot.chunk_size
	if cs <= 0:
		return
	var min_chunk := Vector3i(_floor_div_int(box_min.x, cs), _floor_div_int(box_min.y, cs), _floor_div_int(box_min.z, cs))
	var max_chunk := Vector3i(_floor_div_int(box_max.x, cs), _floor_div_int(box_max.y, cs), _floor_div_int(box_max.z, cs))
	for cy in range(min_chunk.y, max_chunk.y + 1):
		for cz in range(min_chunk.z, max_chunk.z + 1):
			for cx in range(min_chunk.x, max_chunk.x + 1):
				var coord := Vector3i(cx, cy, cz)
				if not snapshot.chunks.has(coord):
					continue
				var blocks: PackedByteArray = snapshot.chunks[coord]
				var x0 := maxi(maxi(box_min.x, cx * cs), snapshot.min_block.x)
				var x1 := mini(mini(box_max.x, (cx + 1) * cs - 1), snapshot.max_block.x)
				var y0 := maxi(maxi(box_min.y, cy * cs), maxi(snapshot.min_block.y, 0))
				var y1 := mini(mini(box_max.y, (cy + 1) * cs - 1), mini(snapshot.max_block.y, snapshot.world_size_y - 1))
				var z0 := maxi(maxi(box_min.z, cz * cs), snapshot.min_block.z)
				var z1 := mini(mini(box_max.z, (cz + 1) * cs - 1), snapshot.max_block.z)
				if x0 > x1 or y0 > y1 or z0 > z1:
					continue
				for y in range(y0, y1 + 1):
					var ly := y - cy * cs
					for z in range(z0, z1 + 1):
						var lz := z - cz * cs
						var source := (lz * cs + ly) * cs + x0 - cx * cs
						var target := ((y - box_min.y) * _sz + z - box_min.z) * _sx + x0 - box_min.x
						if blocks.size() >= cs * cs * cs:
							for x in range(x0, x1 + 1):
								_block_flat[target + x - x0] = blocks[source + x - x0]
						else:
							for x in range(x0, x1 + 1):
								var src := source + x - x0
								if src >= 0 and src < blocks.size():
									_block_flat[target + x - x0] = blocks[src]
	_copy_skirt(snapshot, cs, ramp, flight)


func _copy_skirt(snapshot, cs: int, ramp: PackedByteArray, flight: PackedByteArray) -> void:
	var copy_min := _block_origin
	var copy_max := Vector3i(box_max.x + 1, box_max.y + 1, box_max.z + 1)
	var min_chunk := Vector3i(_floor_div_int(copy_min.x, cs), _floor_div_int(copy_min.y, cs), _floor_div_int(copy_min.z, cs))
	var max_chunk := Vector3i(_floor_div_int(copy_max.x, cs), _floor_div_int(copy_max.y, cs), _floor_div_int(copy_max.z, cs))
	for cy in range(min_chunk.y, max_chunk.y + 1):
		for cz in range(min_chunk.z, max_chunk.z + 1):
			for cx in range(min_chunk.x, max_chunk.x + 1):
				var coord := Vector3i(cx, cy, cz)
				if not snapshot.chunks.has(coord):
					continue
				var blocks: PackedByteArray = snapshot.chunks[coord]
				var x0 := maxi(maxi(copy_min.x, cx * cs), snapshot.min_block.x)
				var x1 := mini(mini(copy_max.x, (cx + 1) * cs - 1), snapshot.max_block.x)
				var y0 := maxi(maxi(copy_min.y, cy * cs), maxi(snapshot.min_block.y, 0))
				var y1 := mini(mini(copy_max.y, (cy + 1) * cs - 1), mini(snapshot.max_block.y, snapshot.world_size_y - 1))
				var z0 := maxi(maxi(copy_min.z, cz * cs), snapshot.min_block.z)
				var z1 := mini(mini(copy_max.z, (cz + 1) * cs - 1), snapshot.max_block.z)
				if x0 > x1 or y0 > y1 or z0 > z1:
					continue
				for y in range(y0, y1 + 1):
					var ly := y - cy * cs
					var y_inside := y >= box_min.y and y <= box_max.y
					for z in range(z0, z1 + 1):
						var z_inside := z >= box_min.z and z <= box_max.z
						var lz := z - cz * cs
						var source := (lz * cs + ly) * cs
						if y_inside and z_inside:
							var left_x := box_min.x - 1
							var right_x := box_max.x + 1
							if left_x >= x0 and left_x <= x1:
								_copy_skirt_cell(blocks, source + left_x - cx * cs, left_x, y, z, left_x - copy_min.x, y - copy_min.y, z - copy_min.z, ramp, flight)
							if right_x >= x0 and right_x <= x1:
								_copy_skirt_cell(blocks, source + right_x - cx * cs, right_x, y, z, right_x - copy_min.x, y - copy_min.y, z - copy_min.z, ramp, flight)
						else:
							for x in range(x0, x1 + 1):
								_copy_skirt_cell(blocks, source + x - cx * cs, x, y, z, x - copy_min.x, y - copy_min.y, z - copy_min.z, ramp, flight)


func _copy_skirt_cell(blocks: PackedByteArray, source: int, x: int, y: int, z: int, px: int, py: int, pz: int, ramp: PackedByteArray, flight: PackedByteArray) -> void:
	if source < 0 or source >= blocks.size():
		return
	var block_id: int = blocks[source]
	var pad_index := (py * _block_sz + pz) * _block_sx + px
	_block_pad[pad_index] = block_id
	if ramp[block_id] == 0 and flight[block_id] == 0:
		return
	for bit in range(12):
		var d: Vector3i = DIRS[bit]
		var tx := x - d.x - box_min.x
		var ty := y - d.y - box_min.y
		var tz := z - d.z - box_min.z
		if tx >= 0 and tx < _sx and ty >= 0 and ty < _sy and tz >= 0 and tz < _sz:
			_requires_predicate[(ty * _sz + tz) * _sx + tx] = 1


func _classify_box(snapshot, pathfinder: Pathfinder, solid: PackedByteArray, ramp: PackedByteArray, flight: PackedByteArray) -> void:
	var all_valid: bool = box_min.x >= snapshot.min_block.x and box_max.x <= snapshot.max_block.x \
		and box_min.y >= snapshot.min_block.y and box_max.y <= snapshot.max_block.y \
		and box_min.z >= snapshot.min_block.z and box_max.z <= snapshot.max_block.z \
		and box_min.y >= 0 and box_max.y < snapshot.world_size_y
	if all_valid:
		_valid.fill(1)
	else:
		for y in range(_sy):
			var wy := y + box_min.y
			if wy < snapshot.min_block.y or wy > snapshot.max_block.y or wy < 0 or wy >= snapshot.world_size_y:
				continue
			var x0 := maxi(0, snapshot.min_block.x - box_min.x)
			var x1 := mini(_sx - 1, snapshot.max_block.x - box_min.x)
			for z in range(_sz):
				var wz := z + box_min.z
				if wz < snapshot.min_block.z or wz > snapshot.max_block.z:
					continue
				var row := (y * _sz + z) * _sx
				for x in range(x0, x1 + 1):
					_valid[row + x] = 1
	var first_walkable := maxi(0, Pathfinder.MIN_WALKABLE_Y - box_min.y) * _layer
	for i in range(_block_flat.size()):
		var id: int = _block_flat[i]
		var is_special := ramp[id] != 0 or flight[id] != 0
		if is_special:
			_special[i] = 1
			_requires_predicate[i] = 1
			var x := i % _sx
			var z := (i / _sx) % _sz
			var y := i / _layer
			for bit in range(12):
				var d: Vector3i = DIRS[bit]
				var nx := x + d.x
				var ny := y + d.y
				var nz := z + d.z
				if nx >= 0 and nx < _sx and ny >= 0 and ny < _sy and nz >= 0 and nz < _sz:
					_requires_predicate[(ny * _sz + nz) * _sx + nx] = 1
		if i < first_walkable or (not all_valid and _valid[i] == 0):
			continue
		var below: int
		if i >= _layer:
			below = _block_flat[i - _layer]
		else:
			var x := i % _sx
			var z := (i / _sx) % _sz
			var support_row := (z + 1) * _block_sx + 1
			below = _block_pad[support_row + x]
		if is_special:
			var x := i % _sx
			var z := (i / _sx) % _sz
			var y := i / _layer
			if pathfinder.is_walkable(snapshot, x + box_min.x, y + box_min.y, z + box_min.z):
				_walkable[i] = 1
				_walkable_indices.append(i)
		elif solid[below] != 0 and ramp[below] == 0 and solid[id] == 0:
			_walkable[i] = 1
			_walkable_indices.append(i)


func _build_edge_masks(snapshot, pathfinder: Pathfinder) -> void:
	for i: int in _walkable_indices:
		var x := i % _sx
		var z := (i / _sx) % _sz
		var y := i / _layer
		var wy := y + box_min.y
		var near_special := _requires_predicate[i] != 0
		if near_special:
			var p := Vector3i(x + box_min.x, wy, z + box_min.z)
			for neighbor: Vector3i in pathfinder.get_neighbors(snapshot, p):
				var ni := _index_or_minus_one(neighbor)
				if ni < 0:
					_flood_touched_box_edge = true
				else:
					var bit := _direction_bit(neighbor - p)
					if bit >= 0:
						_edge_mask[i] |= 1 << bit
		else:
			# Ordinary cells have only same-level cardinal edges. Check outside
			# candidates against Pathfinder so boundary exits cannot be missed.
			if x == 0:
				if pathfinder.is_walkable(snapshot, box_min.x - 1, wy, z + box_min.z):
					_flood_touched_box_edge = true
			else:
				if _walkable[i - 1] != 0:
					_edge_mask[i] |= 1
			if x == _sx - 1:
				if pathfinder.is_walkable(snapshot, box_max.x + 1, wy, z + box_min.z):
					_flood_touched_box_edge = true
			else:
				if _walkable[i + 1] != 0:
					_edge_mask[i] |= 1 << 1
			if z == 0:
				if pathfinder.is_walkable(snapshot, x + box_min.x, wy, box_min.z - 1):
					_flood_touched_box_edge = true
			else:
				if _walkable[i - _sx] != 0:
					_edge_mask[i] |= 1 << 2
			if z == _sz - 1:
				if pathfinder.is_walkable(snapshot, x + box_min.x, wy, box_max.z + 1):
					_flood_touched_box_edge = true
			else:
				if _walkable[i + _sx] != 0:
					_edge_mask[i] |= 1 << 3
		_edge_mask_ready[i] = 1


func _floor_div_int(value: int, divisor: int) -> int:
	var quotient := value / divisor
	if value < 0 and value % divisor != 0:
		quotient -= 1
	return quotient


## Distances use path-array length units: edge distance plus one for the start
## cell. With node_cap > 0 at most that many queue nodes are settled. If
## complete is false, missing start keys are unresolved; -1 is returned only
## for starts proven unreachable by a fully exhausted flood. nodes is settled
## queue nodes, and touched_box_edge reports dropped outgoing box-boundary edges.
func reverse_distances(goals: Array, starts: Array, node_cap: int = 0) -> Dictionary:
	var start_result := {}
	if not _built:
		for start: Vector3i in starts:
			start_result[start] = -1
		return {"distances": start_result, "complete": true, "touched_box_edge": false, "nodes": 0}
	_distance.fill(-1)
	var queue := PackedInt32Array()
	for goal_pos in goals:
		if not goal_pos is Vector3i:
			continue
		var gi := _index_or_minus_one(goal_pos)
		if gi < 0 or _valid[gi] == 0:
			continue
		if _distance[gi] < 0:
			_distance[gi] = 0
			queue.append(gi)
	var deltas := PackedInt32Array()
	for d: Vector3i in DIRS:
		deltas.append((d.y * _sz + d.z) * _sx + d.x)
	var head := 0
	var node_limit := node_cap if node_cap > 0 else 0x7fffffff
	# A predecessor outside the box can only lead into a cell on a box face, so a
	# flood that never settles a face cell is closed: its -1 results are proof.
	var flood_on_face := false
	while head < queue.size() and head < node_limit:
		var vi: int = queue[head]
		head += 1
		var vx := vi % _sx
		var vz := (vi / _sx) % _sz
		var vy := vi / _layer
		if vx == 0 or vx == _sx - 1 or vy == 0 or vy == _sy - 1 or vz == 0 or vz == _sz - 1:
			flood_on_face = true
		var dv: int = _distance[vi]
		for bit in range(12):
			var d: Vector3i = DIRS[bit]
			var ux := vx - d.x
			var uy := vy - d.y
			var uz := vz - d.z
			if ux < 0 or ux >= _sx or uy < 0 or uy >= _sy or uz < 0 or uz >= _sz:
				continue
			var ui := (uy * _sz + uz) * _sx + ux
			if _distance[ui] >= 0 or _walkable[ui] == 0:
				continue
			if (_edge_mask[ui] & (1 << bit)) != 0:
				_distance[ui] = dv + 1
				queue.append(ui)
	_flood_complete = head >= queue.size()
	for start_pos in starts:
		if not start_pos is Vector3i:
			continue
		var si := _index_or_minus_one(start_pos)
		if si < 0 or _valid[si] == 0:
			if _flood_complete:
				start_result[start_pos] = -1
			continue
		var edge_distance := _distance[si]
		if edge_distance < 0 and _walkable[si] == 0:
			_ensure_edge_mask(si)
			edge_distance = _distance_from_nonwalkable_start(si)
		if edge_distance >= 0:
			start_result[start_pos] = edge_distance + 1
		elif _flood_complete:
			start_result[start_pos] = -1
	return {
		"distances": start_result,
		"complete": _flood_complete,
		"touched_box_edge": _flood_touched_box_edge,
		"flood_touched_box_edge": flood_on_face,
		"nodes": head,
	}


## Returns a deterministic [start, ..., goal] path for the last flood, or [] if
## no route was found within its explored portion.
func path_from(start: Vector3i) -> Array:
	var si := _index_or_minus_one(start)
	if si < 0 or _valid[si] == 0:
		return []
	var current_distance: int = _distance[si]
	var current := start
	var current_index := si
	var path: Array[Vector3i] = [start]
	if current_distance < 0 and _walkable[si] == 0:
		_ensure_edge_mask(si)
		var first := _best_neighbor(si, -1)
		if first < 0:
			return []
		current_index = first
		current = _position(first)
		current_distance = _distance[first]
		path.append(current)
	if current_distance < 0:
		return []
	while current_distance > 0:
		var next_index := _best_neighbor(current_index, current_distance - 1)
		if next_index < 0:
			return []
		current_index = next_index
		current = _position(next_index)
		current_distance -= 1
		path.append(current)
	return path


func forward_neighbors(pos: Vector3i) -> Array[Vector3i]:
	var index := _index_or_minus_one(pos)
	var result: Array[Vector3i] = []
	if index < 0:
		return result
	_ensure_edge_mask(index)
	for bit in range(12):
		if (_edge_mask[index] & (1 << bit)) != 0:
			result.append(pos + DIRS[bit])
	return result


func _distance_from_nonwalkable_start(start_index: int) -> int:
	var best := -1
	var x := start_index % _sx
	var z := (start_index / _sx) % _sz
	var y := start_index / _layer
	for bit in range(12):
		if (_edge_mask[start_index] & (1 << bit)) == 0:
			continue
		var d: Vector3i = DIRS[bit]
		var nx := x + d.x
		var ny := y + d.y
		var nz := z + d.z
		if nx < 0 or nx >= _sx or ny < 0 or ny >= _sy or nz < 0 or nz >= _sz:
			continue
		var ni := (ny * _sz + nz) * _sx + nx
		if _distance[ni] >= 0:
			var candidate := _distance[ni] + 1
			if best < 0 or candidate < best:
				best = candidate
	return best


func _ensure_edge_mask(index: int) -> void:
	if _edge_mask_ready[index] != 0:
		return
	var p := _position(index)
	for neighbor: Vector3i in _pathfinder.get_neighbors(_snapshot, p):
		var ni := _index_or_minus_one(neighbor)
		if ni < 0:
			_flood_touched_box_edge = true
			continue
		var bit := _direction_bit(neighbor - p)
		if bit >= 0:
			_edge_mask[index] |= 1 << bit
	_edge_mask_ready[index] = 1


func _best_neighbor(index: int, wanted_distance: int) -> int:
	var x := index % _sx
	var z := (index / _sx) % _sz
	var y := index / _layer
	var best_index := -1
	var best_distance := 0x7fffffff
	for bit in range(12):
		if (_edge_mask[index] & (1 << bit)) == 0:
			continue
		var d: Vector3i = DIRS[bit]
		var nx := x + d.x
		var ny := y + d.y
		var nz := z + d.z
		if nx < 0 or nx >= _sx or ny < 0 or ny >= _sy or nz < 0 or nz >= _sz:
			continue
		var ni := (ny * _sz + nz) * _sx + nx
		if wanted_distance < 0:
			if _distance[ni] >= 0 and _distance[ni] < best_distance:
				best_index = ni
				best_distance = _distance[ni]
		elif _distance[ni] == wanted_distance:
			return ni
	return best_index


func _index_or_minus_one(p: Vector3i) -> int:
	if p.x < box_min.x or p.x > box_max.x or p.y < box_min.y or p.y > box_max.y \
			or p.z < box_min.z or p.z > box_max.z:
		return -1
	return ((p.y - box_min.y) * _sz + (p.z - box_min.z)) * _sx + (p.x - box_min.x)


func _position(index: int) -> Vector3i:
	return Vector3i(
		index % _sx + box_min.x,
		index / _layer + box_min.y,
		(index / _sx) % _sz + box_min.z
	)


func _direction_bit(delta: Vector3i) -> int:
	for bit in range(12):
		if DIRS[bit] == delta:
			return bit
	return -1
