extends SceneTree
## Pan limiter (ADR-015): the camera may not pan further than the frustum
## padding from the views that decide what is shown.
##
## 1. The geometric claim it rests on, checked against the production culler:
##    if the camera moves by at most the padding on each axis, every chunk in
##    the moved frustum was accepted by the original view.
## 2. The clamp rule: stays inside every anchor's margin, never pulls the camera
##    back, leaves jumps alone.
## 3. The visibility state feeds it the right anchors.

const Visibility = preload("res://scripts/rendering/world_renderer_visibility.gd")
const CHUNK := 8
const PADDING := 8.0

var checks := 0
var failures := 0
var rng := RandomNumberGenerator.new()


func _init() -> void:
	rng.seed = 271828
	_test_moved_frustum_is_covered()
	_test_clamp_rule()
	_test_drawn_part_box()
	_test_state_anchors()
	print("Pan limiter: %d checks, %d failures" % [checks, failures])
	quit(1 if failures else 0)


func _check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures += 1
		if failures <= 12:
			push_error(message)


## Six planes facing a centre point, like a view volume.
func _planes(centre: Vector3) -> Array:
	var planes: Array = []
	for index in 6:
		var normal := Vector3(rng.randf_range(-1.0, 1.0), rng.randf_range(-1.0, 1.0), rng.randf_range(-1.0, 1.0))
		if index < 3:
			normal = [Vector3.RIGHT, Vector3.UP, Vector3.BACK][index].rotated(Vector3.UP, rng.randf_range(0.0, TAU))
		if normal.length() < 0.01:
			normal = Vector3.UP
		normal = normal.normalized()
		planes.append({"plane": Plane(normal, normal.dot(centre) - rng.randf_range(15.0, 60.0)), "inside_positive": true})
	return planes


func _test_moved_frustum_is_covered() -> void:
	var culler := FrustumCuller.new()
	var uncovered := 0
	var on_screen := 0
	var beyond_margin_uncovered := 0
	for case_index in 400:
		var centre := Vector3(rng.randf_range(-60.0, 60.0), rng.randf_range(20.0, 120.0), rng.randf_range(-60.0, 60.0))
		var planes := _planes(centre)
		# A pan of at most the padding on every axis, and one well beyond it.
		var within := Vector3(rng.randf_range(-PADDING, PADDING), rng.randf_range(-PADDING, PADDING), rng.randf_range(-PADDING, PADDING))
		var beyond := within + Vector3(3.0 * PADDING, 0.0, 0.0) * (1.0 if rng.randf() < 0.5 else -1.0)
		var moved: Array = Visibility._translated_planes(planes, within)
		var moved_far: Array = Visibility._translated_planes(planes, beyond)
		var base := Vector3i(floori(centre.x / CHUNK), floori(centre.y / CHUNK), floori(centre.z / CHUNK))
		for dx in range(-11, 12):
			for dy in range(-4, 5):
				for dz in range(-11, 12):
					var coord := base + Vector3i(dx, dy, dz)
					var accepted := culler.is_chunk_in_view(planes, coord, CHUNK, PADDING)
					if culler.is_chunk_in_view(moved, coord, CHUNK, 0.0):
						on_screen += 1
						if not accepted:
							uncovered += 1
					if not accepted and culler.is_chunk_in_view(moved_far, coord, CHUNK, 0.0):
						beyond_margin_uncovered += 1
	_check(on_screen > 10000, "setup: only %d on-screen chunks were tested" % on_screen)
	_check(uncovered == 0, "%d chunks on screen after a pan within the padding were not accepted by the original view" % uncovered)
	# The bound is not vacuous: panning past it does expose chunks the view never accepted.
	_check(beyond_margin_uncovered > 0, "a pan well past the padding exposed nothing, so the test proves nothing")


func _test_clamp_rule() -> void:
	var margin := 7.0
	var one: Array[Vector3] = [Vector3(100, 60, 100)]
	_check(Visibility.clamp_pan(Vector3(100, 60, 100), Vector3(104, 60, 97), one, margin) == Vector3(104, 60, 97),
		"a pan inside the margin was changed")
	_check(Visibility.clamp_pan(Vector3(100, 60, 100), Vector3(130, 60, 100), one, margin) == Vector3(107, 60, 100),
		"a pan past the margin was not stopped at it")
	_check(Visibility.clamp_pan(Vector3(106, 60, 100), Vector3(80, 60, 100), one, margin) == Vector3(93, 60, 100),
		"a pan back across the view was not stopped at the far margin")
	# Two views in play: the camera must suit both.
	var two: Array[Vector3] = [Vector3(100, 60, 100), Vector3(105, 60, 100)]
	_check(Visibility.clamp_pan(Vector3(104, 60, 100), Vector3(120, 60, 100), two, margin) == Vector3(107, 60, 100),
		"with two views the older one did not bound the pan")
	_check(Visibility.clamp_pan(Vector3(104, 60, 100), Vector3(80, 60, 100), two, margin) == Vector3(98, 60, 100),
		"with two views the newer one did not bound the pan back")
	# Already outside (a view was adopted that the camera has moved away from):
	# no pull back, no further out, free to return.
	_check(Visibility.clamp_pan(Vector3(110, 60, 100), Vector3(118, 60, 100), one, margin) == Vector3(110, 60, 100),
		"a camera outside the margin was allowed further out")
	_check(Visibility.clamp_pan(Vector3(110, 60, 100), Vector3(110, 60, 100), one, margin) == Vector3(110, 60, 100),
		"a camera outside the margin was pulled back")
	_check(Visibility.clamp_pan(Vector3(110, 60, 100), Vector3(103, 60, 100), one, margin) == Vector3(103, 60, 100),
		"a camera outside the margin could not return")
	# A jump: far from every view, so holding the camera guarantees nothing.
	_check(Visibility.clamp_pan(Vector3(300, 60, 100), Vector3(330, 60, 100), one, margin) == Vector3(330, 60, 100),
		"a camera far from every view was held")
	# Views that disagree by more than they can jointly allow.
	var apart: Array[Vector3] = [Vector3(100, 60, 100), Vector3(140, 60, 100)]
	_check(Visibility.clamp_pan(Vector3(120, 60, 100), Vector3(150, 60, 100), apart, margin) == Vector3(150, 60, 100),
		"views too far apart to satisfy together still held the camera")
	# Axes are independent, and no views means no limit.
	_check(Visibility.clamp_pan(Vector3(100, 60, 100), Vector3(130, 60, 103), one, margin) == Vector3(107, 60, 103),
		"limiting one axis changed another")
	var none: Array[Vector3] = []
	_check(Visibility.clamp_pan(Vector3.ZERO, Vector3(500, 0, 0), none, margin) == Vector3(500, 0, 0), "no views still limited the pan")
	# Random walks never leave the margin once inside it.
	for walk in 200:
		var anchor := Vector3(rng.randf_range(-50, 50), 60, rng.randf_range(-50, 50))
		var anchors: Array[Vector3] = [anchor]
		var position := anchor
		var escaped := false
		for step in 50:
			position = Visibility.clamp_pan(position, position + Vector3(rng.randf_range(-20, 20), rng.randf_range(-20, 20), rng.randf_range(-20, 20)), anchors, margin)
			var offset := (position - anchor).abs()
			escaped = escaped or maxf(offset.x, maxf(offset.y, offset.z)) > margin + 0.001
		_check(not escaped, "a random walk left the margin of its only view")


## The void meter tests only the part of a top-layer chunk that can be drawn
## (up to one block above the cut). That box test must agree with the chunk test
## on a whole chunk, never accept more than it, and reject a chunk that reaches
## the view only above the cut.
func _test_drawn_part_box() -> void:
	var culler := FrustumCuller.new()
	var disagreements := 0
	var clipped_only := 0
	for case_index in 200:
		var centre := Vector3(rng.randf_range(-60.0, 60.0), rng.randf_range(20.0, 120.0), rng.randf_range(-60.0, 60.0))
		var planes := _planes(centre)
		var base := Vector3i(floori(centre.x / CHUNK), floori(centre.y / CHUNK), floori(centre.z / CHUNK))
		for dx in range(-6, 7):
			for dy in range(-3, 4):
				for dz in range(-6, 7):
					var coord := base + Vector3i(dx, dy, dz)
					var low := Vector3(coord) * float(CHUNK)
					var high := low + Vector3(CHUNK, CHUNK, CHUNK)
					var whole := culler.is_chunk_in_view(planes, coord, CHUNK, 0.0)
					if culler.is_box_in_view(planes, low, high) != whole:
						disagreements += 1
					if culler.is_box_in_view(planes, low, Vector3(high.x, low.y + 1.0, high.z)) and not whole:
						clipped_only += 1
	_check(disagreements == 0, "the box test disagreed with the chunk test on %d whole chunks" % disagreements)
	_check(clipped_only == 0, "%d chunks were in view when clipped but not as a whole" % clipped_only)
	# Only y >= 228 is inside: the chunk 224..232 reaches it, its drawn part 224..225 does not.
	var above: Array = [{"plane": Plane(Vector3.UP, 228.0), "inside_positive": true}]
	_check(culler.is_chunk_in_view(above, Vector3i(0, 28, 0), CHUNK, 0.0), "setup: the whole chunk should reach the view")
	_check(not culler.is_box_in_view(above, Vector3(0, 224, 0), Vector3(8, 225, 8)),
		"a chunk in view only above the cut was counted as on screen")


func _test_state_anchors() -> void:
	var state = Visibility.new()
	var from := Vector3(10, 60, 10)
	_check(state.limit_pan(from, Vector3(90, 60, 10), PADDING) == Vector3(90, 60, 10), "a state with no views limited the pan")
	# A fully applied view at `from`.
	state._applied_origin_valid = true
	state._applied_origin = from
	var limit: float = PADDING - Visibility.PAN_LIMIT_SAFETY_BLOCKS
	_check(state.limit_pan(from, Vector3(90, 60, 10), PADDING) == Vector3(10 + limit, 60, 10), "the applied view did not bound the pan")
	_check(state.pan_limited_count == 1 and state.pan_withheld_blocks > 70.0, "a limited pan was not counted")
	# A view being applied counts too.
	state._batch = {"request_id": 5}
	state._batch_origin_valid = true
	state._batch_origin = Vector3(14, 60, 10)
	_check(state.limit_pan(Vector3(13, 60, 10), Vector3(-40, 60, 10), PADDING) == Vector3(14 - limit, 60, 10),
		"the view being applied did not bound the pan back")
	# Clearing the visibility state keeps the applied view and drops the rest.
	state._request_origins[9] = Vector3(50, 60, 10)
	state.invalidate()
	_check(state._request_origins.is_empty() and state._applied_origin_valid and not state._batch_origin_valid,
		"invalidate did not keep only the applied view")
	# The last view whose terrain is all meshed bounds the pan too. Applied view
	# at x 10, meshed view still at x 6: the camera may reach 6 + limit, not 10 + limit.
	state.mesh_requester = MeshRequesterStub.new()
	state._adopted_origins[4] = Vector3(6, 60, 10)
	state._adopted_origins[5] = Vector3(9, 60, 10)
	_check(state.limit_pan(from, Vector3(90, 60, 10), PADDING) == Vector3(10 + limit, 60, 10),
		"a view that is not meshed yet bounded the pan")
	state.note_view_meshed(4)
	_check(state.limit_pan(from, Vector3(90, 60, 10), PADDING) == Vector3(6 + limit, 60, 10),
		"the meshed view did not bound the pan")
	_check(not state._adopted_origins.has(4) and state._adopted_origins.has(5), "reporting a meshed view did not drop only the older views")
	state.note_view_meshed(5)
	_check(state.limit_pan(from, Vector3(90, 60, 10), PADDING) == Vector3(9 + limit, 60, 10),
		"a newer meshed view did not move the bound")
	# A jump leaves the meshed view far behind: it must not hold or free the camera wrongly.
	state.forget_meshed_view()
	_check(state.limit_pan(from, Vector3(90, 60, 10), PADDING) == Vector3(10 + limit, 60, 10),
		"forgetting the meshed view did not lift its bound")
	state.stop()


## Stands in for the view mesh requester: the visibility state only tells it
## which view to serve.
class MeshRequesterStub extends RefCounted:
	func begin_view(_result: Dictionary) -> void:
		pass

	func clear_view() -> void:
		pass
