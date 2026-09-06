extends RefCounted
class_name RenderZoneCullKernel
## Value-only, inclusive chunk bounds. Traversal matches the renderer: Y/X/Z.
## The owner supplies an immutable job and exclusively owns this cursor.

const CullerScript = preload("res://scripts/rendering/frustum_culler.gd")

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
var _culler := CullerScript.new()


func _init(snapshot: Dictionary = {}) -> void:
	job = snapshot
	_min = job.get("min", Vector3i.ZERO)
	_max = job.get("max", Vector3i(-1, -1, -1))
	_coord = _min
	_planes = job.get("planes", [])
	_chunk_size = int(job.get("chunk_size", 1))
	_padding = float(job.get("padding", 0.0))
	done = _min.x > _max.x or _min.y > _max.y or _min.z > _max.z


## deadline_usec is an absolute Time.get_ticks_usec() deadline; 0 is unlimited.
## Each step visits exactly one candidate, including rejected candidates.
func advance(max_steps: int, deadline_usec: int = 0) -> int:
	var processed := 0
	while not done and processed < max_steps:
		if deadline_usec > 0 and Time.get_ticks_usec() >= deadline_usec:
			break
		# Reuse the authoritative implementation, including strict plane tests,
		# negative normals, and padding only when padding > 0.
		if _culler.is_chunk_in_view(_planes, _coord, _chunk_size, _padding):
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
