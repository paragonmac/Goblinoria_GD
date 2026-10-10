extends RefCounted
class_name GoblinLight
## Small wall-aware light grids owned by each worker.

const SOURCE_LEVEL := 6
const RADIUS := 5
const GRID := 11
const MAX_GPU_GOBLINS := 64
const GRID_CELLS := GRID * GRID * GRID
# Padded BFS grid: 2 extra cells per side so RADIUS + 1 neighbours resolve
# without bounds checks.
const PAD := RADIUS + 2
const PAD_SIDE := PAD * 2 + 1
const PAD_AREA := PAD_SIDE * PAD_SIDE
const PAD_CELLS := PAD_AREA * PAD_SIDE

var gpu_dirty := false
var bfs_count := 0
var bfs_cells := 0
var last_update_usec := 0

var _worker_cells: Dictionary = {}
var _worker_grids: Dictionary = {}
var _changed_cells: Dictionary = {}
var _queue := PackedInt32Array()
var _opaque_grid := PackedByteArray()
var _work := PackedByteArray()
var _marks := PackedInt32Array()


func update(world) -> bool:
	var started := Time.get_ticks_usec()
	var changed := false
	if _queue.size() != PAD_CELLS:
		_queue.resize(PAD_CELLS)
		_opaque_grid.resize(PAD_CELLS)
		_work.resize(PAD_CELLS)
	var live_ids: Dictionary = {}
	for worker in world.workers:
		if not is_instance_valid(worker):
			continue
		var worker_id := int(worker.worker_id)
		live_ids[worker_id] = true
		var cell: Vector3i = worker.get_block_coord()
		var needs_recompute: bool = not _worker_cells.has(worker_id) or _worker_cells[worker_id] != cell
		if not needs_recompute and not _changed_cells.is_empty():
			needs_recompute = _changed_near_cell(cell)
		if needs_recompute:
			_recompute(world, worker_id, cell)
			changed = true
	var removed_ids: Array[int] = []
	for worker_id in _worker_grids:
		if not live_ids.has(worker_id):
			removed_ids.append(int(worker_id))
	for worker_id in removed_ids:
		_worker_grids.erase(worker_id)
		_worker_cells.erase(worker_id)
		changed = true
	_changed_cells.clear()
	if changed:
		gpu_dirty = true
	last_update_usec = Time.get_ticks_usec() - started
	return changed


func notify_block_changed(x: int, y: int, z: int) -> void:
	_changed_cells[Vector3i(x, y, z)] = true


func get_level(x: int, y: int, z: int) -> int:
	var level := 0
	for worker_id in _worker_grids:
		var center: Vector3i = _worker_cells[worker_id]
		var dx := x - center.x
		var dy := y - center.y
		var dz := z - center.z
		if absi(dx) > RADIUS or absi(dy) > RADIUS or absi(dz) > RADIUS:
			continue
		var grid: PackedByteArray = _worker_grids[worker_id]
		var idx := _grid_index(dx, dy, dz)
		level = maxi(level, int(grid[idx]))
	return level


func build_gpu_data(focus: Vector3i, max_count: int = MAX_GPU_GOBLINS) -> Dictionary:
	var capacity := maxi(0, max_count)
	var candidates: Array[Dictionary] = []
	for worker_id in _worker_grids:
		var cell: Vector3i = _worker_cells[worker_id]
		var delta := cell - focus
		candidates.append({
			"worker_id": int(worker_id),
			"cell": cell,
			"distance": delta.length_squared(),
		})
	candidates.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if int(a.distance) == int(b.distance):
			return int(a.worker_id) < int(b.worker_id)
		return int(a.distance) < int(b.distance)
	)
	var count := mini(capacity, candidates.size())
	var cells := PackedVector4Array()
	cells.resize(capacity)
	var atlas := PackedByteArray()
	atlas.resize(121 * (GRID * capacity))
	for index in range(count):
		var candidate: Dictionary = candidates[index]
		var worker_id := int(candidate.worker_id)
		var cell: Vector3i = candidate.cell
		cells[index] = Vector4(cell.x, cell.y, cell.z, 0.0)
		var grid: PackedByteArray = _worker_grids[worker_id]
		for dy in range(-RADIUS, RADIUS + 1):
			for dz in range(-RADIUS, RADIUS + 1):
				var row := dz + RADIUS + GRID * index
				for dx in range(-RADIUS, RADIUS + 1):
					var column := dx + RADIUS + GRID * (dy + RADIUS)
					atlas[row * 121 + column] = grid[_grid_index(dx, dy, dz)] * 17
	gpu_dirty = false
	return {"count": count, "cells": cells, "atlas": atlas}


func _changed_near_cell(cell: Vector3i) -> bool:
	for changed_cell: Vector3i in _changed_cells:
		if absi(changed_cell.x - cell.x) + absi(changed_cell.y - cell.y) \
				+ absi(changed_cell.z - cell.z) <= RADIUS + 1:
			return true
	return false


func _recompute(world, worker_id: int, center: Vector3i) -> void:
	var grid: PackedByteArray = _worker_grids.get(worker_id, PackedByteArray())
	if grid.size() != GRID_CELLS:
		grid.resize(GRID_CELLS)
	grid.fill(0)
	_worker_cells[worker_id] = center
	var field = world.light_field
	var opacity: PackedByteArray = field.opacity
	var block_mirror: PackedByteArray = field.block_mirror
	var mirror_size := block_mirror.size()
	var base_x := center.x - World.WORLD_MIN_BLOCK_X
	var base_z := center.z - World.WORLD_MIN_BLOCK_Z
	# Padded work grid (PAD_SIDE^3): out-of-diamond cells stay opaque, so the
	# BFS needs no bounds checks and the explored pass can read neighbours.
	_work.fill(0)
	_opaque_grid.fill(1)
	for dy in range(-RADIUS, RADIUS + 1):
		var y := center.y + dy
		if y < 0 or y >= 256:
			continue
		var dy_distance := absi(dy)
		for dz in range(-RADIUS + dy_distance, RADIUS - dy_distance + 1):
			var z := base_z + dz
			if z < 0 or z >= 256:
				continue
			var remaining := RADIUS - dy_distance - absi(dz)
			var pad_row := ((dy + PAD) * PAD_SIDE + dz + PAD) * PAD_SIDE + PAD
			var mirror_row := (y * 256 + z) * 256
			for dx in range(-remaining, remaining + 1):
				var x := base_x + dx
				if x < 0 or x >= 256:
					continue
				var block_idx := mirror_row + x
				if block_idx < mirror_size:
					_opaque_grid[pad_row + dx] = opacity[block_mirror[block_idx]]
	var center_p := (PAD * PAD_SIDE + PAD) * PAD_SIDE + PAD
	_work[center_p] = SOURCE_LEVEL
	_queue[0] = center_p
	var head := 0
	var tail := 1
	while head < tail:
		var p := _queue[head]
		head += 1
		var level := int(_work[p])
		if level <= 1 or _opaque_grid[p] != 0:
			continue
		var next_level := level - 1
		var q := p + 1
		if _work[q] < next_level and _opaque_grid[q] == 0:
			_work[q] = next_level
			_queue[tail] = q
			tail += 1
		q = p - 1
		if _work[q] < next_level and _opaque_grid[q] == 0:
			_work[q] = next_level
			_queue[tail] = q
			tail += 1
		q = p + PAD_SIDE
		if _work[q] < next_level and _opaque_grid[q] == 0:
			_work[q] = next_level
			_queue[tail] = q
			tail += 1
		q = p - PAD_SIDE
		if _work[q] < next_level and _opaque_grid[q] == 0:
			_work[q] = next_level
			_queue[tail] = q
			tail += 1
		q = p + PAD_AREA
		if _work[q] < next_level and _opaque_grid[q] == 0:
			_work[q] = next_level
			_queue[tail] = q
			tail += 1
		q = p - PAD_AREA
		if _work[q] < next_level and _opaque_grid[q] == 0:
			_work[q] = next_level
			_queue[tail] = q
			tail += 1
	bfs_cells += tail
	# Copy lit cells into the worker grid and collect unexplored cells that are
	# lit or touch a lit cell (wall faces) within RADIUS + 1. A goblin walking
	# known ground reads one byte per cell and marks nothing.
	var explored: PackedByteArray = field.explored
	var volume := explored.size()
	_marks.clear()
	var reach := RADIUS + 1
	for dy in range(-reach, reach + 1):
		var y := center.y + dy
		if y < 0 or y >= 256:
			continue
		var dy_distance := absi(dy)
		for dz in range(-reach + dy_distance, reach - dy_distance + 1):
			var z := base_z + dz
			if z < 0 or z >= 256:
				continue
			var remaining := reach - dy_distance - absi(dz)
			var pad_row := ((dy + PAD) * PAD_SIDE + dz + PAD) * PAD_SIDE + PAD
			var grid_row := ((dy + RADIUS) * GRID + dz + RADIUS) * GRID + RADIUS
			var world_row := (y * 256 + z) * 256
			for dx in range(-remaining, remaining + 1):
				var x := base_x + dx
				if x < 0 or x >= 256:
					continue
				var p := pad_row + dx
				var lit := _work[p]
				if lit > 0:
					grid[grid_row + dx] = lit
				var idx := world_row + x
				if idx >= volume or explored[idx] != 0:
					continue
				if lit > 0 or _work[p + 1] > 0 or _work[p - 1] > 0 						or _work[p + PAD_SIDE] > 0 or _work[p - PAD_SIDE] > 0 						or _work[p + PAD_AREA] > 0 or _work[p - PAD_AREA] > 0:
					_marks.append(idx)
	# Drop the local reference before writing so the field's array is not
	# copied on write.
	explored = PackedByteArray()
	if not _marks.is_empty():
		field.mark_explored_indices(_marks)
	_worker_grids[worker_id] = grid
	bfs_count += 1


func _grid_index(dx: int, dy: int, dz: int) -> int:
	return ((dy + RADIUS) * GRID + (dz + RADIUS)) * GRID + dx + RADIUS
