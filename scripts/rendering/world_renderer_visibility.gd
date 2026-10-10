extends RefCounted
## Main-thread visibility state; the scheduler never receives this owner.
const Scheduler = preload("res://scripts/rendering/render_zone_cull_scheduler.gd")
const Slots = preload("res://scripts/rendering/stable_coord_slots.gd")
const KernelScript = preload("res://scripts/rendering/render_zone_cull_kernel.gd")
var scheduler = Scheduler.new()
var eligible = Slots.new()
var shown = Slots.new()
var reconcile: Dictionary = {}
var renderer
var initialized := false
var epoch := 0
var requested_sequence := 0
var accepted_sequence := 0
var applied_sequence := 0
var requested_epoch := -1
var accepted_epoch := -1
var applied_epoch := -1
var applied_usec := 0
var accepted_usec := 0
var requested_key: Array = []
var applied_key: Array = []
var _hard_key: Array = []
var _camera: WeakRef
var _batch: Dictionary = {}
var _phase := 0
var _index := 0
var _eligible_limit := 0
var _initial_limit := 0
var _needs_initial_reconcile := true
var _eligible_dirty := true
var _dirty_revision := 0
var _batch_dirty_revision := 0
var _reconcile_was_nonempty := false
var _batch_mode := "full"
var _started := false
var _warned := false
var last_steps := 0
var last_application_mode := "full"
var delta_applications := 0
var full_applications := 0
var last_requested_bounds: Dictionary = {}

func configure(owner) -> void:
	renderer = owner
	clear()

func stop() -> void:
	invalidate()
	scheduler.stop()
	_started = false

func clear() -> void:
	invalidate()
	_mark_eligible_dirty()
	eligible.clear()
	shown.clear()
	reconcile.clear()
	_reconcile_was_nonempty = false
	initialized = false
	_needs_initial_reconcile = true
	applied_key = []
	applied_epoch = -1
	last_requested_bounds = {}

func invalidate() -> void:
	_mark_eligible_dirty()
	epoch += 1
	scheduler.invalidate(epoch)
	_batch = {}
	requested_key = []
	_phase = 0
	_index = 0

func _hard_view(camera: Camera3D) -> Array:
	var key: Array = [renderer.world.top_render_y]
	if camera != null:
		key.append_array([camera.get_instance_id(), camera.get_viewport().get_instance_id(), camera.get_viewport().get_visible_rect()])
	return key

func observe(camera: Camera3D) -> void:
	var key := _hard_view(camera)
	if key != _hard_key:
		invalidate()
		_hard_key = key
	_camera = weakref(camera) if camera != null else null

func needs_request(key: Array) -> bool:
	_observe_reconcile()
	return requested_key != key or not reconcile.is_empty()

## mode: "async" (worker cull), "area" (no frustum: whole box), "sync" (cull and
## apply on the main thread now, unbudgeted; debug comparison only).
func request(min_coord: Vector3i, max_coord: Vector3i, camera: Camera3D, key: Array, mode: String = "async") -> void:
	observe(camera)
	if not needs_request(key):
		return
	if not _started:
		_started = true
		if not scheduler.start() and not _warned:
			_warned = true
			push_warning("Visibility worker unavailable; using budgeted main-thread fallback.")
	var started: int = renderer.world.begin_performance_timing()
	var planes: Array = renderer.frustum_culler.build_planes(camera, renderer.NEAR_SAMPLE_OFFSET, renderer.NEAR_SAMPLE_MIN) if camera != null and mode != "area" else []
	requested_sequence += 1
	requested_epoch = epoch
	requested_key = key
	var now := Time.get_ticks_usec()
	var lead: Vector3 = renderer.motion_lead_offset.limit_length(renderer.RENDER_FRUSTUM_MAX_LEAD_DISTANCE)
	var lead_planes: Array = _translated_planes(planes, lead) if not planes.is_empty() and lead.length_squared() > 0.25 else []
	last_requested_bounds = {"min_x": min_coord.x, "max_x": max_coord.x, "min_y": min_coord.y, "max_y": max_coord.y,
		"min_z": min_coord.z, "max_z": max_coord.z, "camera_culling": not planes.is_empty(),
		"frame_id": renderer.world.live_diagnostics.frame_id if renderer.world.live_diagnostics != null else null,
		"monotonic_usec": now, "lead_offset": [lead.x, lead.y, lead.z] if not lead_planes.is_empty() else [0.0, 0.0, 0.0]}
	last_requested_bounds["mode"] = mode
	var job := {"min": min_coord, "max": max_coord, "chunk_size": World.CHUNK_SIZE,
		"padding": renderer.RENDER_FRUSTUM_PADDING_CHUNKS * World.CHUNK_SIZE, "planes": planes, "lead_planes": lead_planes,
		"request_id": requested_sequence, "base_sequence": accepted_sequence,
		"epoch": epoch, "submitted_usec": now,
		"view_key": key, "bounds": last_requested_bounds}
	if mode == "sync":
		# Main-thread comparison mode: cull and apply completely this frame. Older
		# worker results arrive with lower request ids and are ignored.
		var kernel = KernelScript.new(job)
		kernel.advance(1 << 30)
		var result: Dictionary = kernel.take_result()
		result["fallback"] = true
		_adopt(result)
		while not _batch.is_empty():
			_step()
		renderer.world.end_performance_timing("RenderZone.snapshot_ms", started)
		return
	scheduler.submit(job)
	renderer.world.end_performance_timing("RenderZone.snapshot_ms", started)

## Frustum planes moved by offset: n.(x - o) = d  ->  n.x = d + n.o.
static func _translated_planes(planes: Array, offset: Vector3) -> Array:
	var moved: Array = []
	for entry: Dictionary in planes:
		var p: Plane = entry.plane
		moved.append({"plane": Plane(p.normal, p.d + p.normal.dot(offset)), "inside_positive": entry.inside_positive})
	return moved

func get_camera() -> Camera3D:
	return _camera.get_ref() as Camera3D if _camera != null else null

func is_eligible(coord: Vector3i) -> bool:
	return not initialized or eligible.members.has(coord)

func set_node_visibility(coord: Vector3i, desired: bool) -> void:
	var node: MeshInstance3D = renderer.chunk_cache.get_chunk(coord)
	if node == null:
		shown.erase(coord)
		return
	desired = desired and node.mesh != null and node.mesh.get_surface_count() > 0
	if node.visible != desired:
		node.visible = desired
	if desired:
		shown.add(coord)
	else:
		shown.erase(coord)

func remove_node(coord: Vector3i) -> void:
	shown.erase(coord)
	_observe_reconcile()
	_erase_reconcile(coord)

func _adopt(result: Dictionary) -> void:
	if int(result.get("epoch", -1)) != epoch or int(result.get("request_id", -1)) <= accepted_sequence:
		return
	_observe_reconcile()
	if bool(result.get("fallback", false)):
		_mark_eligible_dirty()
	_batch = result
	accepted_sequence = int(result.request_id)
	if not bool(result.get("fallback", false)):
		scheduler.note_adopted(accepted_sequence, epoch)
	accepted_epoch = epoch
	accepted_usec = int(result.submitted_usec)
	initialized = true
	_phase = 0
	_index = 0
	_eligible_limit = eligible.slots.size()
	_initial_limit = renderer.chunk_cache.coordinate_slots.slots.size() if _needs_initial_reconcile else 0
	_batch_mode = "delta" if _can_apply_delta(result) else "full"
	_batch_dirty_revision = _dirty_revision

func pump(max_ms: float, max_steps: int) -> int:
	last_steps = 0
	if renderer == null or renderer.world == null or max_ms <= 0 or max_steps <= 0:
		return 0
	var started: int = renderer.world.begin_performance_timing()
	var deadline := Time.get_ticks_usec() + int(max_ms * 1000.0)
	var camera: Camera3D = _camera.get_ref() if _camera != null else null
	observe(camera)
	_observe_reconcile()
	if not _batch.is_empty() and _batch_mode == "delta" and not reconcile.is_empty():
		_mark_eligible_dirty()
		_switch_to_full_application()
	if _batch.is_empty() and _started:
		var fallback_started: int = renderer.world.begin_performance_timing()
		last_steps += scheduler.pump_fallback(max_steps, deadline)
		if last_steps > 0:
			renderer.world.end_performance_timing("RenderZone.fallback_cull_ms", fallback_started)
		if Time.get_ticks_usec() < deadline:
			var adoption: int = renderer.world.begin_performance_timing()
			var result: Dictionary = scheduler.take_result()
			if not result.is_empty():
				_adopt(result)
				renderer.world.end_performance_timing("RenderZone.adopt_ms", adoption)
	var apply_started: int = renderer.world.begin_performance_timing() if not _batch.is_empty() else -1
	while not _batch.is_empty() and last_steps < max_steps and Time.get_ticks_usec() < deadline:
		if _step():
			last_steps += 1
	renderer.world.end_performance_timing("RenderZone.apply_ms", apply_started)
	renderer.world.end_performance_timing("RenderZone.pump_ms", started)
	return last_steps

func _step() -> bool:
	if _batch_mode == "delta":
		return _step_delta()
	var target: Dictionary = _batch.accepted
	if _phase == 0:
		var coords: Array = _batch.accepted_coords
		if _index < coords.size():
			var coord: Vector3i = coords[_index]
			_index += 1
			var entering: bool = not eligible.members.has(coord) or reconcile.has(coord)
			eligible.add(coord)
			if entering:
				renderer._set_chunk_visibility(coord, true)
			_erase_reconcile(coord)
			return true
		_phase = 1
		_index = 0
	elif _phase == 1:
		if _index < _eligible_limit:
			var coord: Variant = eligible.slots[_index]
			_index += 1
			if coord != null and not target.has(coord):
				eligible.erase(coord)
				renderer._set_chunk_visibility(coord, false)
				_erase_reconcile(coord)
			return true
		_phase = 2
		_index = 0
	elif _phase == 2:
		if _index < _initial_limit:
			var coord: Variant = renderer.chunk_cache.coordinate_slots.slots[_index]
			_index += 1
			if coord != null and not target.has(coord):
				renderer._set_chunk_visibility(coord, false)
				_erase_reconcile(coord)
			return true
		_needs_initial_reconcile = false
		_finish()
	return false

func _step_delta() -> bool:
	if _phase == 0:
		var entering: Array = _batch.entering_coords
		if _index < entering.size():
			var coord: Vector3i = entering[_index]
			_index += 1
			eligible.add(coord)
			renderer._set_chunk_visibility(coord, true)
			return true
		_phase = 1
		_index = 0
	elif _phase == 1:
		var exiting: Array = _batch.exiting_coords
		if _index < exiting.size():
			var coord: Vector3i = exiting[_index]
			_index += 1
			eligible.erase(coord)
			renderer._set_chunk_visibility(coord, false)
			return true
		_finish()
	return false

func _switch_to_full_application() -> void:
	_batch_mode = "full"
	# The full scan resolves the dirtiness that forced it; only later changes
	# should keep the next result off the delta path.
	_batch_dirty_revision = _dirty_revision
	_phase = 0
	_index = 0
	_eligible_limit = eligible.slots.size()
	_initial_limit = renderer.chunk_cache.coordinate_slots.slots.size() if _needs_initial_reconcile else 0

func _finish() -> void:
	applied_sequence = accepted_sequence
	applied_epoch = epoch
	applied_key = _batch.view_key
	applied_usec = int(_batch.submitted_usec)
	last_application_mode = _batch_mode
	if _batch_mode == "delta":
		delta_applications += 1
	else:
		full_applications += 1
	renderer.diagnostics_render_bounds = _batch.bounds
	if renderer._performance_recording():
		var recorder = renderer.world.performance_recorder
		recorder.add_counter("RenderZone.refreshes")
		recorder.add_counter("RenderZone.candidates", int(_batch.candidate_count))
		recorder.add_counter("RenderZone.accepted_coords", int(_batch.accepted_count))
		# Keep the long-standing full-scan-equivalent candidate workload metric
		# stable across modes; pump steps and mode counters show actual work.
		recorder.add_counter("RenderZone.hide_candidates", _eligible_limit + _initial_limit)
		recorder.add_timing("RenderZone.result_age_ms", float(Time.get_ticks_usec() - applied_usec) / 1000.0)
	if _batch_dirty_revision == _dirty_revision and reconcile.is_empty() and not _needs_initial_reconcile:
		_eligible_dirty = false
	else:
		_eligible_dirty = true
	_batch = {}
	_batch_mode = "full"

func snapshot() -> Dictionary:
	var state: Dictionary = scheduler.get_stats()
	var remaining := 0
	if not _batch.is_empty():
		if _batch_mode == "delta":
			remaining = (_batch.entering_coords.size() - _index + _batch.exiting_coords.size()) if _phase == 0 else \
				_batch.exiting_coords.size() - _index
		else:
			remaining = (int(_batch.accepted_count) - _index + _eligible_limit + _initial_limit) if _phase == 0 else \
				(_eligible_limit - _index + _initial_limit if _phase == 1 else _initial_limit - _index)
	state.merge({"epoch": epoch, "requested_sequence": requested_sequence, "accepted_sequence": accepted_sequence,
		"requested_epoch": requested_epoch, "accepted_epoch": accepted_epoch,
		"applied_sequence": applied_sequence, "applied_epoch": applied_epoch, "initialized": initialized,
		"application_pending": not _batch.is_empty(), "application_remaining": remaining,
		"mixed_view": initialized and (not _batch.is_empty() or applied_epoch != epoch),
		"requested_view_pending": requested_key != applied_key or applied_epoch != epoch,
		"effective_eligible": eligible.members.size(), "shown_nodes": shown.members.size(), "last_steps": last_steps,
		"last_application_mode": last_application_mode, "delta_applications": delta_applications,
		"full_applications": full_applications, "eligible_dirty": _eligible_dirty,
		"result_age_ms": float(Time.get_ticks_usec() - applied_usec) / 1000.0 if applied_usec > 0 else null,
		"accepted_result_age_ms": float(Time.get_ticks_usec() - accepted_usec) / 1000.0 if accepted_usec > 0 else null,
		"requested_bounds": last_requested_bounds}, true)
	return state

func _can_apply_delta(result: Dictionary) -> bool:
	# The worker diffs against the most recently adopted result, which is the
	# last fully applied one by the time this result is adopted.
	return result.has("delta_base_sequence") \
		and int(result.get("delta_base_sequence", -1)) == applied_sequence \
		and int(result.get("epoch", -1)) == epoch and applied_epoch == epoch \
		and not _eligible_dirty and reconcile.is_empty() and not _needs_initial_reconcile \
		and not bool(result.get("fallback", false))

func _mark_eligible_dirty() -> void:
	_eligible_dirty = true
	_dirty_revision += 1

func _erase_reconcile(coord: Vector3i) -> void:
	reconcile.erase(coord)
	_reconcile_was_nonempty = not reconcile.is_empty()

func _observe_reconcile() -> void:
	var has_reconcile := not reconcile.is_empty()
	if has_reconcile and not _reconcile_was_nonempty:
		_mark_eligible_dirty()
	_reconcile_was_nonempty = has_reconcile
