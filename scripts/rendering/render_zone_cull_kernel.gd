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

## deadline_usec is an absolute Time.get_ticks_usec() deadline; 0 is unlimited.
## Each step visits exactly one candidate, including rejected candidates.
func advance(max_steps: int, deadline_usec: int = 0) -> int:
	var processed := 0
	while not done and processed < max_steps:
		if deadline_usec > 0 and Time.get_ticks_usec() >= deadline_usec:
			break
		if _in_view(_fast, _coord) or (not _fast_lead.is_empty() and _in_view(_fast_lead, _coord)):
			accepted_coords.append(_coord)
			accepted[_coord] = true
		candidate_count += 1
		processed += 1
		# Compare before incrementing to avoid wrapping at Vector3i limits.
		if _coord.z < _max.z:
			_coord.z += 1
		elif _coord.x < _max.x:
			_coord.z = _min.z
			_coord.x += 1
		elif _coord.y < _max.y:
			_coord.z = _min.z
			_coord.x = _min.x
			_coord.y += 1
		else:
			done = true
	return processed

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
