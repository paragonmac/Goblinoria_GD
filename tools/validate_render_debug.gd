extends SceneTree
## Renderer side of the F7 Rendering debug panel: settings validation, visibility
## modes (async / area / sync), depth limit, freeze, look-ahead switch, void meter,
## stats and F1 snapshot exposure. Headless; no pixels are inspected.

const Fixture = preload("res://tools/validate_async_visibility.gd")
const WAIT_MS := 5000

var checks := 0
var failures := 0


func _init() -> void:
	_run.call_deferred()


func _check(ok: bool, message: String) -> void:
	checks += 1
	if not ok:
		failures += 1
		push_error(message)


func _world() -> Fixture.BareWorld:
	var world := Fixture.BareWorld.new()
	root.add_child(world)
	world._init_ramp_lookup()
	world.block_registry.load_from_csv(World.BLOCK_DATA_PATH)
	world.top_render_y = 8
	var renderer := Fixture.ProbeRenderer.new()
	renderer.use_async_meshing = false
	world.add_child(renderer)
	world.renderer = renderer
	renderer.initialize(world)
	var mesh := BoxMesh.new()
	for x in range(-2, 3):
		for y in range(0, 2):
			for z in range(-2, 3):
				var node: MeshInstance3D = renderer.chunk_cache.ensure_chunk(Vector3i(x, y, z), World.CHUNK_SIZE)
				node.mesh = mesh
				node.visible = true
	return world


func _settle(renderer) -> bool:
	var deadline := Time.get_ticks_msec() + WAIT_MS
	while Time.get_ticks_msec() < deadline:
		renderer.pump_visibility(1.0, 4096)
		var state: Dictionary = renderer.get_visibility_snapshot()
		if state.initialized and not state.application_pending and state.applied_sequence == state.requested_sequence:
			return true
		OS.delay_msec(1)
	return false


func _box(min_y: int, max_y: int) -> Dictionary:
	var out := {}
	for x in range(-2, 3):
		for y in range(min_y, max_y + 1):
			for z in range(-2, 3):
				out[Vector3i(x, y, z)] = true
	return out


func _same(a: Dictionary, b: Dictionary) -> bool:
	if a.size() != b.size():
		return false
	for key in a:
		if not b.has(key):
			return false
	return true


func _run() -> void:
	_test_setter()
	_test_modes_depth_freeze()
	_test_look_ahead_switch()
	_test_void_meter_and_stats()
	print("Render debug: %d checks, %d failures" % [checks, failures])
	quit(1 if failures > 0 else 0)


func _test_setter() -> void:
	var world := _world()
	var renderer = world.renderer
	_check(not renderer.set_render_debug("nonsense", true), "Unknown key is rejected")
	_check(not renderer.set_render_debug("visibility_mode", "fast"), "Unknown visibility mode is rejected")
	_check(not renderer.set_render_debug("depth_layers", 3), "Depth outside the option list is rejected")
	_check(not renderer.set_render_debug("freeze", 1), "Non-bool switch value is rejected")
	_check(renderer.get_render_debug().visibility_mode == "async" and renderer.get_render_debug().depth_layers == 0,
		"Rejected values leave settings unchanged")
	_check(renderer.set_render_debug("look_ahead_sec", 0.9) and is_equal_approx(renderer.get_render_debug().look_ahead_sec, 0.5),
		"Look-ahead seconds clamp to 0.5")
	var copy: Dictionary = renderer.get_render_debug()
	copy.freeze = true
	_check(not renderer.get_render_debug().freeze, "get_render_debug returns a copy")
	world.free()


func _test_modes_depth_freeze() -> void:
	var world := _world()
	var renderer = world.renderer
	# Sync applies immediately on the main thread, no pump needed.
	_check(renderer.set_render_debug("visibility_mode", "sync"), "Sync mode accepted")
	renderer.update_render_zone(-2, 2, -2, 2, 0, 1)
	var state: Dictionary = renderer.get_visibility_snapshot()
	_check(state.applied_sequence == state.requested_sequence and not state.application_pending,
		"Sync mode applies the view in the same call")
	_check(_same(renderer.render_zone_visible, _box(0, 1)), "Sync mode eligible set matches the box")
	_check(state.requested_bounds.mode == "sync", "Requested bounds record the mode")
	# Depth limit: top_render_y 8 -> top chunk layer 1; one layer keeps only y=1.
	_check(renderer.set_render_debug("depth_layers", 1), "Depth 1 accepted")
	renderer.update_render_zone(-2, 2, -2, 2, 0, 1)
	_check(_settle(renderer), "Depth-limited view settles")
	_check(int(renderer.get_visibility_snapshot().requested_bounds.min_y) == 1, "Depth limit raises the minimum chunk layer")
	_check(_same(renderer.render_zone_visible, _box(1, 1)), "Depth limit hides deeper layers")
	renderer.set_render_debug("depth_layers", 0)
	renderer.update_render_zone(-2, 2, -2, 2, 0, 1)
	_check(_settle(renderer) and _same(renderer.render_zone_visible, _box(0, 1)), "All layers restore the full box")
	# Area mode: camera motion alone does not trigger requests; the box is shown whole.
	var camera := Camera3D.new()
	world.add_child(camera)
	camera.position = Vector3(0, 40, 0)
	camera.rotation_degrees = Vector3(-90, 0, 0)
	_check(renderer.set_render_debug("visibility_mode", "area"), "Area mode accepted")
	renderer.update_render_zone(-2, 2, -2, 2, 0, 1, camera)
	_check(_settle(renderer), "Area view settles")
	_check(_same(renderer.render_zone_visible, _box(0, 1)), "Area mode shows the whole box")
	_check(not bool(renderer.get_visibility_snapshot().requested_bounds.camera_culling), "Area mode does not frustum-cull")
	camera.position += Vector3(5, 0, 0)
	_check(not renderer.needs_render_zone_update(-2, 2, -2, 2, 0, 1, camera), "Area mode ignores camera-only motion")
	# Freeze: no new requests until unfrozen; unfreezing re-requests the latest view.
	renderer.set_render_debug("visibility_mode", "async")
	renderer.update_render_zone(-2, 2, -2, 2, 0, 1, camera)
	_settle(renderer)
	var sequence: int = renderer.get_visibility_snapshot().requested_sequence
	_check(renderer.set_render_debug("freeze", true), "Freeze accepted")
	renderer.update_render_zone(-1, 1, -1, 1, 0, 1, camera)
	_check(renderer.get_visibility_snapshot().requested_sequence == sequence, "Frozen view submits no requests")
	_check(not renderer.needs_render_zone_update(-1, 1, -1, 1, 0, 1, camera), "Frozen view never needs an update")
	renderer.set_render_debug("freeze", false)
	var after: Dictionary = renderer.get_visibility_snapshot()
	_check(after.requested_sequence > sequence and int(after.requested_bounds.min_x) == -1,
		"Unfreezing requests the latest view")
	world.free()


func _test_look_ahead_switch() -> void:
	var world := _world()
	var renderer = world.renderer
	renderer.motion_lead_offset = Vector3(10, 0, 0)
	_check(is_equal_approx(renderer.get_look_ahead_sec(), renderer.RENDER_FRUSTUM_MOTION_LEAD_SEC), "Look-ahead defaults on")
	renderer.set_render_debug("look_ahead", false)
	_check(is_zero_approx(renderer.get_look_ahead_sec()) and renderer.motion_lead_offset.is_zero_approx(),
		"Disabling look-ahead zeroes the lead immediately")
	renderer.set_render_debug("look_ahead", true)
	renderer.set_render_debug("look_ahead_sec", 0.3)
	_check(is_equal_approx(renderer.get_look_ahead_sec(), 0.3), "Lead seconds follow the slider value")
	world.free()


func _test_void_meter_and_stats() -> void:
	var world := _world()
	var renderer = world.renderer
	var camera := Camera3D.new()
	world.add_child(camera)
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = 100.0
	camera.position = Vector3(0, 60, 0)
	camera.rotation_degrees = Vector3(-90, 0, 0)
	renderer.set_render_debug("visibility_mode", "sync")
	renderer.update_render_zone(-2, 2, -2, 2, 0, 1, camera)
	renderer.void_meter_enabled = true
	renderer.pump_visibility(1.0, 2048)
	var meter: Dictionary = renderer.get_render_debug_stats().void
	_check(int(meter.checked) == 50 and int(meter.hidden) == 0, "Void meter sees 50 on-screen chunks and no void")
	renderer.chunk_cache.get_chunk(Vector3i(0, 1, 0)).visible = false
	renderer.chunk_cache.get_chunk(Vector3i(1, 0, 1)).visible = false
	renderer._void_last_usec = 0
	renderer.pump_visibility(1.0, 2048)
	meter = renderer.get_render_debug_stats().void
	_check(int(meter.hidden) == 2 and int(meter.max_recent) == 2, "Void meter counts hidden on-screen chunks")
	renderer.chunk_cache.get_chunk(Vector3i(2, 1, 2)).mesh = null
	renderer._void_last_usec = 0
	renderer.pump_visibility(1.0, 2048)
	_check(int(renderer.get_render_debug_stats().void.checked) == 49, "Chunks without geometry are not void candidates")
	var stats: Dictionary = renderer.get_render_debug_stats()
	for key in ["fps", "frame_ms", "draw_calls", "shown_nodes", "eligible", "vis_lag_ms", "last_application_mode",
			"delta_per_sec", "full_per_sec", "cull_job_ms", "void", "settings"]:
		_check(stats.has(key), "Stats expose " + key)
	var snapshot: Dictionary = renderer.get_visibility_snapshot()
	_check(snapshot.render_debug.visibility_mode == "sync" and snapshot.void_meter.has("hidden"),
		"Visibility snapshot (F1 bundles) carries settings and void meter")
	renderer.void_meter_enabled = false
	_check(renderer.get_visibility_snapshot().void_meter.get("enabled", true) == false, "Snapshot marks the void meter off")
	world.free()
