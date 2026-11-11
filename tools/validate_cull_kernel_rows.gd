extends SceneTree
## The render-zone cull kernel finds each row's accepted cells as an interval
## instead of testing every cell. Its output must stay identical to testing
## every cell with FrustumCuller, in the same order, for any planes and box:
## random frustum-like plane sets, planes parallel or nearly parallel to an
## axis, padding, a second (look-ahead) plane set, and any step budget.

const KernelScript = preload("res://scripts/rendering/render_zone_cull_kernel.gd")
const RANDOM_CASES := 3000

var checks := 0
var failures := 0
var culler := FrustumCuller.new()
var rng := RandomNumberGenerator.new()


func _init() -> void:
	rng.seed = 20261111
	var accepted_total := 0
	var candidate_total := 0
	for index in RANDOM_CASES:
		var job := _random_job(index)
		var expected := _reference(job)
		var kernel = KernelScript.new(job)
		var steps_ok := true
		var processed_total := 0
		var guard := 0
		while not kernel.done and guard < 200000:
			guard += 1
			var budget := rng.randi_range(1, 300) if index % 3 != 0 else 1 << 30
			var processed: int = kernel.advance(budget)
			steps_ok = steps_ok and processed >= 1 and processed <= budget
			processed_total += processed
		var volume: int = _volume(job)
		var result: Dictionary = kernel.take_result() if kernel.done else {}
		var actual: Array = result.get("accepted_coords", [])
		_check(kernel.done and steps_ok, "case %d: stepping broke its budget or never finished" % index)
		_check(processed_total == volume and int(result.get("candidate_count", -1)) == volume,
			"case %d: counted %d candidates (steps %d), box holds %d" % [index, int(result.get("candidate_count", -1)), processed_total, volume])
		var same: bool = actual.size() == expected.size()
		if same:
			for i in expected.size():
				if actual[i] != expected[i]:
					same = false
					break
		_check(same, "case %d: accepted %d cells, the per-cell reference accepts %d (or order differs)" % [index, actual.size(), expected.size()])
		_check(result.get("accepted", {}).size() == expected.size(), "case %d: accepted set size differs" % index)
		accepted_total += expected.size()
		candidate_total += volume
	_test_empty_box()
	print("Cull kernel rows: %d checks, %d failures (%d candidates, %d accepted)" % [checks, failures, candidate_total, accepted_total])
	quit(1 if failures else 0)


func _check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures += 1
		if failures <= 12:
			push_error(message)


func _volume(job: Dictionary) -> int:
	var low: Vector3i = job["min"]
	var high: Vector3i = job["max"]
	return (high.x - low.x + 1) * (high.y - low.y + 1) * (high.z - low.z + 1)


func _reference(job: Dictionary) -> Array:
	var accepted: Array = []
	var low: Vector3i = job["min"]
	var high: Vector3i = job["max"]
	var size: int = job["chunk_size"]
	var padding: float = job["padding"]
	var lead: Array = job.get("lead_planes", [])
	for y in range(low.y, high.y + 1):
		for x in range(low.x, high.x + 1):
			for z in range(low.z, high.z + 1):
				var coord := Vector3i(x, y, z)
				if culler.is_chunk_in_view(job["planes"], coord, size, padding) \
						or (not lead.is_empty() and culler.is_chunk_in_view(lead, coord, size, padding)):
					accepted.append(coord)
	return accepted


func _random_job(index: int) -> Dictionary:
	var low := Vector3i(rng.randi_range(-40, 20), rng.randi_range(0, 20), rng.randi_range(-40, 20))
	var high := low + Vector3i(rng.randi_range(0, 14), rng.randi_range(0, 6), rng.randi_range(0, 40))
	var size := 8 if index % 5 != 0 else rng.randi_range(1, 16)
	var centre := (Vector3(low) + Vector3(high)) * 0.5 * float(size) + Vector3(
		rng.randf_range(-40.0, 40.0), rng.randf_range(-20.0, 20.0), rng.randf_range(-60.0, 60.0))
	var job := {
		"min": low, "max": high, "chunk_size": size,
		"padding": [0.0, 0.0, 0.5, 8.0, 3.25][rng.randi_range(0, 4)],
		"planes": _planes(centre, index),
	}
	if index % 4 == 1:
		job["lead_planes"] = _planes(centre + Vector3(rng.randf_range(-48.0, 48.0), 0.0, rng.randf_range(-48.0, 48.0)), index + 7)
	return job


## Six planes around a point. Some are axis-aligned or nearly so, which gives
## plane tests that are constant or almost constant along a row.
func _planes(centre: Vector3, index: int) -> Array:
	var planes: Array = []
	for plane_index in 6:
		var normal: Vector3
		match (index + plane_index) % 7:
			0:
				normal = [Vector3.RIGHT, Vector3.LEFT, Vector3.UP, Vector3.DOWN, Vector3.FORWARD, Vector3.BACK][plane_index]
			1:
				normal = Vector3(rng.randf_range(-1.0, 1.0), rng.randf_range(-1.0, 1.0), rng.randf_range(-1.0e-7, 1.0e-7))
			2:
				normal = Vector3(rng.randf_range(-1.0e-6, 1.0e-6), rng.randf_range(-1.0, 1.0), rng.randf_range(-1.0, 1.0))
			3:
				normal = Vector3(rng.randf_range(-1.0, 1.0), 0.0, rng.randf_range(-0.01, 0.01))
			_:
				normal = Vector3(rng.randf_range(-1.0, 1.0), rng.randf_range(-1.0, 1.0), rng.randf_range(-1.0, 1.0))
		if normal.length() < 0.001:
			normal = Vector3.BACK
		normal = normal.normalized()
		# The plane passes near the centre, so most boxes are cut, not missed.
		var plane := Plane(normal, normal.dot(centre) - rng.randf_range(10.0, 90.0))
		var inside_positive := rng.randf() < 0.5
		if not inside_positive:
			plane = Plane(-plane.normal, -plane.d)
		planes.append({"plane": plane, "inside_positive": inside_positive})
	return planes


func _test_empty_box() -> void:
	var kernel = KernelScript.new({"min": Vector3i(2, 0, 0), "max": Vector3i(1, 0, 0), "chunk_size": 8, "padding": 0.0, "planes": []})
	_check(kernel.done and kernel.advance(100) == 0, "an empty box is done at once")
	# No planes at all accepts every cell.
	kernel = KernelScript.new({"min": Vector3i(-1, 0, -1), "max": Vector3i(1, 1, 2), "chunk_size": 8, "padding": 0.0, "planes": []})
	kernel.advance(1 << 30)
	_check(kernel.done and kernel.take_result().accepted_coords.size() == 24, "a box with no planes accepts all 24 cells")
