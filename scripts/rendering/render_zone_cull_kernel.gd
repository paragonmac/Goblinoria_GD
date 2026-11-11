extends RefCounted
class_name RenderZoneCullKernel
## Value-only, inclusive chunk bounds. Traversal matches the renderer: Y/X/Z.
## The owner supplies an immutable job and exclusively owns this cursor.

var job: Dictionary
var done := true
var candidate_count := 0
var accepted_coords: Array[Vector3i] = []
var accepted: Dictionary = {}
var _coord := Vector3i.ZERO
var _min := Vector3i.ZERO
var _max := Vector3i.ZERO
var _planes: Array = []
var _chunk_size := 1
var _padding := 0.0
# Optional second frustum shifted along the pan direction (look-ahead).
var _lead_planes: Array = []
# FrustumCuller planes normalized so every test is "reject if distance < 0" at
# the corner picked by normal sign. Bit-identical to FrustumCuller: negating a
# plane negates its distance exactly, and the corner choice differs only where
# the normal component is zero (no effect on the distance).
var _fast: Array[Plane] = []
var _fast_lead: Array[Plane] = []
# Row culling state. Along one Z row every plane test changes at most once (see
# _row_interval), so a row's accepted cells are one inclusive interval per
# frustum. Testing every cell made a job on a 512 world visit about 37,000
# candidates with up to twelve plane tests each, roughly 65 ms.
var _row_ready := false
var _row_lo := 0
var _row_hi := -1
var _lead_lo := 0
var _lead_hi := -1
var _row_len := 0
# Corner coordinates per axis index, exactly as _in_view builds them. Stored as
# the float32 values the Vector3 held, so rebuilding a corner from them gives
# the same Vector3.
var _corner_min_x := PackedFloat64Array()
var _corner_max_x := PackedFloat64Array()
var _corner_min_y := PackedFloat64Array()
var _corner_max_y := PackedFloat64Array()
var _corner_min_z := PackedFloat64Array()
var _corner_max_z := PackedFloat64Array()

func _init(snapshot: Dictionary = {}) -> void:
	job = snapshot
	_min = job.get("min", Vector3i.ZERO)
	_max = job.get("max", Vector3i(-1, -1, -1))
	_coord = _min
	_planes = job.get("planes", [])
	_chunk_size = int(job.get("chunk_size", 1))
	_padding = float(job.get("padding", 0.0))
	_lead_planes = job.get("lead_planes", [])
	_fast = _compile(_planes)
	_fast_lead = _compile(_lead_planes)
	done = _min.x > _max.x or _min.y > _max.y or _min.z > _max.z
	if not done:
		_row_len = _max.z - _min.z + 1
		_build_corner_tables()

## deadline_usec is an absolute Time.get_ticks_usec() deadline; 0 is unlimited.
## Each step accounts for exactly one candidate, including rejected candidates.
## A row with no accepted cell is counted in one go when the step budget covers
## all of it; otherwise it is walked cell by cell, so max_steps is never exceeded.
func advance(max_steps: int, deadline_usec: int = 0) -> int:
	var processed := 0
	while not done and processed < max_steps:
		if deadline_usec > 0 and Time.get_ticks_usec() >= deadline_usec:
			break
		if not _row_ready:
			_prepare_row()
		var z := _coord.z
		if z == _min.z and _row_lo > _row_hi and _lead_lo > _lead_hi and max_steps - processed >= _row_len:
			candidate_count += _row_len
			processed += _row_len
			_coord.z = _max.z
			_next_row()
			continue
		if (z >= _row_lo and z <= _row_hi) or (z >= _lead_lo and z <= _lead_hi):
			accepted_coords.append(_coord)
			accepted[_coord] = true
		candidate_count += 1
		processed += 1
		# Compare before incrementing to avoid wrapping at Vector3i limits.
		if z < _max.z:
			_coord.z = z + 1
		else:
			_next_row()
	return processed


func _next_row() -> void:
	_row_ready = false
	if _coord.x < _max.x:
		_coord.z = _min.z
		_coord.x += 1
	elif _coord.y < _max.y:
		_coord.z = _min.z
		_coord.x = _min.x
		_coord.y += 1
	else:
		done = true


func _prepare_row() -> void:
	_row_ready = true
	var interval := _row_interval(_fast, _coord.x, _coord.y)
	_row_lo = interval.x
	_row_hi = interval.y
	if _fast_lead.is_empty():
		_lead_lo = 0
		_lead_hi = -1
	else:
		interval = _row_interval(_fast_lead, _coord.x, _coord.y)
		_lead_lo = interval.x
		_lead_hi = interval.y


func _build_corner_tables() -> void:
	var pad := Vector3(_padding, _padding, _padding)
	var size := Vector3(_chunk_size, _chunk_size, _chunk_size)
	for axis in 3:
		var low: int = _min[axis]
		var high: int = _max[axis]
		var mins := PackedFloat64Array()
		var maxs := PackedFloat64Array()
		mins.resize(high - low + 1)
		maxs.resize(high - low + 1)
		for value in range(low, high + 1):
			# Same operations, in the same order, as _in_view.
			var min_corner := Vector3(value * _chunk_size, value * _chunk_size, value * _chunk_size)
			var max_corner := min_corner + size
			if _padding > 0.0:
				min_corner -= pad
				max_corner += pad
			mins[value - low] = min_corner.x
			maxs[value - low] = max_corner.x
		match axis:
			0:
				_corner_min_x = mins
				_corner_max_x = maxs
			1:
				_corner_min_y = mins
				_corner_max_y = maxs
			_:
				_corner_min_z = mins
				_corner_max_z = maxs


## Inclusive Z interval of the cells of row (x, y) that _in_view accepts, or an
## empty interval (lo > hi).
##
## For one plane the tested corner's Z grows with the cell's Z, and the plane
## distance is a monotone function of that corner Z in floating point as well
## as in exact arithmetic (every multiply and add involved is monotone). So a
## plane accepts either an upper end of the row (normal.z >= 0) or a lower end,
## and its boundary can be found by bisection with the exact test.
func _row_interval(planes: Array[Plane], x: int, y: int) -> Vector2i:
	var lo := _min.z
	var hi := _max.z
	var base_z := _min.z
	var xi := x - _min.x
	var yi := y - _min.y
	for p in planes:
		var n := p.normal
		var px: float = _corner_max_x[xi] if n.x >= 0.0 else _corner_min_x[xi]
		var py: float = _corner_max_y[yi] if n.y >= 0.0 else _corner_min_y[yi]
		if n.z >= 0.0:
			if p.distance_to(Vector3(px, py, _corner_max_z[hi - base_z])) < 0.0:
				return Vector2i(0, -1)
			if p.distance_to(Vector3(px, py, _corner_max_z[lo - base_z])) < 0.0:
				# lo rejects, hi accepts: find the first accepting cell.
				var reject := lo
				var accept := hi
				while accept - reject > 1:
					var mid := reject + (accept - reject) / 2
					if p.distance_to(Vector3(px, py, _corner_max_z[mid - base_z])) < 0.0:
						reject = mid
					else:
						accept = mid
				lo = accept
		else:
			if p.distance_to(Vector3(px, py, _corner_min_z[lo - base_z])) < 0.0:
				return Vector2i(0, -1)
			if p.distance_to(Vector3(px, py, _corner_min_z[hi - base_z])) < 0.0:
				# lo accepts, hi rejects: find the last accepting cell.
				var accept := lo
				var reject := hi
				while reject - accept > 1:
					var mid := accept + (reject - accept) / 2
					if p.distance_to(Vector3(px, py, _corner_min_z[mid - base_z])) < 0.0:
						reject = mid
					else:
						accept = mid
				hi = accept
	return Vector2i(lo, hi)


## Ownership transfer after completion; no copying of the coordinate buffers.
func take_result() -> Dictionary:
	assert(done)
	var result := job.duplicate()
	result["accepted_coords"] = accepted_coords
	result["accepted"] = accepted
	result["candidate_count"] = candidate_count
	result["accepted_count"] = accepted_coords.size()
	accepted_coords = []
	accepted = {}
	return result

## Builds value-only changes against a previously published accepted set.
## Neither input set is modified; call this before publishing result ownership.
static func attach_delta(result: Dictionary, base_sequence: int, base_accepted: Dictionary) -> void:
	var entering: Array[Vector3i] = []
	var exiting: Array[Vector3i] = []
	var accepted_now: Dictionary = result.accepted
	for coord in result.accepted_coords:
		if not base_accepted.has(coord):
			entering.append(coord)
	for coord in base_accepted:
		if not accepted_now.has(coord):
			exiting.append(coord)
	result["delta_base_sequence"] = base_sequence
	result["entering_coords"] = entering
	result["exiting_coords"] = exiting

static func _compile(planes: Array) -> Array[Plane]:
	var compiled: Array[Plane] = []
	for entry in planes:
		var p: Plane = entry["plane"]
		compiled.append(p if entry["inside_positive"] else Plane(-p.normal, -p.d))
	return compiled

## Same result as FrustumCuller.is_chunk_in_view, including padding only when > 0.
func _in_view(planes: Array[Plane], coord: Vector3i) -> bool:
	var min_corner := Vector3(coord.x * _chunk_size, coord.y * _chunk_size, coord.z * _chunk_size)
	var max_corner := min_corner + Vector3(_chunk_size, _chunk_size, _chunk_size)
	if _padding > 0.0:
		var pad := Vector3(_padding, _padding, _padding)
		min_corner -= pad
		max_corner += pad
	for p in planes:
		var n := p.normal
		if p.distance_to(Vector3(max_corner.x if n.x >= 0.0 else min_corner.x,
				max_corner.y if n.y >= 0.0 else min_corner.y,
				max_corner.z if n.z >= 0.0 else min_corner.z)) < 0.0:
			return false
	return true
