extends SceneTree
## Correctness/work-count regression, not a timing benchmark or GPU test.

class CountingRenderer extends WorldRenderer:
	var refreshes := 0
	var visibility_calls := 0
	func update_render_zone(a: int, b: int, c: int, d: int, e: int, f: int, camera: Camera3D = null) -> void:
		refreshes += 1
		super.update_render_zone(a, b, c, d, e, f, camera)
	func _set_chunk_visibility(coord: Vector3i, visible_value: bool) -> void:
		visibility_calls += 1
		super._set_chunk_visibility(coord, visible_value)

var failures := 0
var checks := 0


func _init() -> void:
	_run.call_deferred()


func _check(ok: bool, message: String) -> void:
	checks += 1
	if not ok:
		failures += 1
		push_error(message)


func _world() -> World:
	var world := World.new()
	world._init_ramp_lookup()
	world.block_registry.load_from_csv(World.BLOCK_DATA_PATH)
	world.top_render_y = 8
	var renderer := CountingRenderer.new()
	renderer.use_async_meshing = false
	world.add_child(renderer)
	world.renderer = renderer
	renderer.initialize(world)
	world.streaming = WorldStreaming.new(world)
	world.streaming.chunks_per_frame = 0
	world.streaming.stream_queue_budget = 0
	return world


func _run() -> void:
	await _test_view_changes()
	_test_mesh_handoffs()
	if failures:
		push_error("Change-driven visibility failed: %d/%d" % [failures, checks])
		quit(1)
	else:
		print("Change-driven visibility OK (%d checks)" % checks)
		quit(0)


func _test_view_changes() -> void:
	var world := _world()
	var renderer: CountingRenderer = world.renderer
	var viewport := SubViewport.new()
	viewport.size = Vector2i(800, 600)
	root.add_child(viewport)
	var camera := Camera3D.new()
	viewport.add_child(camera)
	camera.position = Vector3(0, 30, 40)
	camera.look_at(Vector3.ZERO)
	var tick := func(dt: float): world.update_streaming(Rect2(0, 0, 7, 7), 8, dt, camera)
	tick.call(0.1)
	_check(preload("res://tools/visibility_test_helpers.gd").settle(renderer), "Initial async view converges")
	var initial := renderer.refreshes
	var calls := renderer.visibility_calls
	for i in range(30):
		tick.call(0.1)
	_check(renderer.refreshes == initial and renderer.visibility_calls == calls, "Stationary view performs no repeated culls or visibility calls")
	camera.position.x += 0.1
	tick.call(0.001)
	_check(renderer.refreshes == initial, "Movement respects existing refresh throttle")
	tick.call(0.1)
	_check(renderer.refreshes == initial + 1, "Movement followed by stopping is not lost")
	var changes: Array[Callable] = [
		func(): camera.rotation.y += 0.1,
		func(): camera.fov += 5,
		func(): camera.near += 0.1,
		func(): camera.far += 10,
		func(): camera.h_offset += 1,
		func(): camera.v_offset += 1,
		func(): camera.keep_aspect = Camera3D.KEEP_WIDTH,
		func(): camera.projection = Camera3D.PROJECTION_ORTHOGONAL,
		func(): camera.size += 2,
		func(): camera.projection = Camera3D.PROJECTION_FRUSTUM,
		func(): camera.frustum_offset = Vector2(0.1, 0.2),
		func(): viewport.size = Vector2i(1000, 600),
		func(): world.top_render_y += 1,
	]
	for change in changes:
		initial = renderer.refreshes
		change.call()
		tick.call(0.1)
		_check(renderer.refreshes == initial + 1, "View/projection/viewport/level change refreshes once")
		tick.call(0.1)
		_check(renderer.refreshes == initial + 1, "Updated view stays cached")
	initial = renderer.refreshes
	world.streaming.refresh_render_zone(null)
	_check(renderer.refreshes == initial + 1, "Explicit refresh works immediately")
	tick.call(0.1)
	_check(renderer.refreshes == initial + 2, "Direct refresh updates authoritative camera key")
	initial = renderer.refreshes
	world.update_streaming(Rect2(0, 0, 7, 7), 8, 0.1, null)
	_check(renderer.refreshes == initial + 1, "Removing camera invalidates cached culling")
	renderer.clear_chunks()
	_check(not renderer.is_render_zone_initialized(), "Renderer-only clear resets initialized state")
	initial = renderer.refreshes
	tick.call(0.1)
	_check(renderer.refreshes == initial + 1, "Same view reestablished after clear")
	world.streaming.reset_state()
	initial = renderer.refreshes
	tick.call(0.0)
	_check(renderer.refreshes == initial + 1, "Streaming-only reset invalidates renderer even at zero delta")
	_check(world.chunks.is_empty(), "View changes do not generate terrain")
	renderer._stop_mesh_worker()
	world.free()
	viewport.queue_free()
	await process_frame


func _test_mesh_handoffs() -> void:
	var world := _world()
	var renderer: CountingRenderer = world.renderer
	var inside := Vector3i.ZERO
	var outside := Vector3i(2, 0, 0)
	for coord in [inside, outside]:
		var chunk := world.ensure_chunk(coord)
		chunk.generated = true
		chunk.blocks[WorldChunkSpace.chunk_index(1, 1, 1)] = World.BLOCK_ID_GRANITE
		renderer.regenerate_chunk(coord.x, coord.y, coord.z)
	_check(renderer.chunk_cache.get_chunk(outside).visible, "Pre-view startup geometry is initially available")
	renderer.update_render_zone(0, 0, 0, 0, 0, 0)
	_check(preload("res://tools/visibility_test_helpers.gd").settle(renderer), "Initial node reconciliation converges")
	_check(renderer.chunk_cache.get_chunk(inside).visible and not renderer.chunk_cache.get_chunk(outside).visible,
		"First refresh reconciles preexisting nodes")
	var calls := renderer.visibility_calls
	renderer.update_render_zone(0, 0, 0, 0, 0, 0)
	_check(renderer.visibility_calls == calls, "Unchanged membership requires no node visibility calls even on explicit refresh")
	renderer._hide_chunk_mesh(inside)
	_check(renderer.needs_render_zone_update(0, 0, 0, 0, 0, 0), "Legacy hide requests reconciliation")
	renderer.update_render_zone(0, 0, 0, 0, 0, 0)
	_check(preload("res://tools/visibility_test_helpers.gd").settle(renderer), "Legacy reconciliation converges")
	_check(renderer.chunk_cache.get_chunk(inside).visible, "Legacy hide inside unchanged membership is restored")
	renderer._hide_chunk_mesh(outside)
	_check(not renderer.needs_render_zone_update(0, 0, 0, 0, 0, 0), "Already excluded legacy hide does not cause endless reculls")
	for empty_view in [false, true]:
		if empty_view:
			renderer.update_render_zone(1, 0, 0, 0, 0, 0)
			_check(preload("res://tools/visibility_test_helpers.gd").settle(renderer), "Empty view converges")
			_check(not renderer._is_chunk_in_current_render_zone(inside), "Initialized empty set never uses startup fallback")
		for coord in [inside, outside]:
			var expected: bool = not empty_view and coord == inside
			var chunk := world.get_chunk(coord)
			var entry := renderer.export_persistent_mesh_cache_entry(coord, World.CHUNK_SIZE - 1)
			renderer.clear_chunk(coord)
			renderer.regenerate_chunk(coord.x, coord.y, coord.z)
			_check(renderer.chunk_cache.get_chunk(coord).visible == expected, "Sync replacement honors cached membership")
			renderer.clear_chunk(coord)
			renderer._apply_mesh_entry(coord, entry, chunk)
			_check(renderer.chunk_cache.get_chunk(coord).visible == expected, "Cached/pooled replacement honors membership")
			var job := renderer._build_mesh_job(coord, chunk.mesh_revision, 8, false, false)
			var result := renderer._build_mesh_result_on_worker(job)
			_check(renderer._apply_mesh_result(result), "Actual async-format mesh result accepted at handoff")
			_check(renderer.chunk_cache.get_chunk(coord).visible == expected, "Async handoff honors membership without reculling")
	# Empty meshes must not become visible just because their coordinate enters.
	world.get_chunk(inside).blocks.fill(World.BLOCK_ID_AIR)
	renderer.regenerate_chunk(0, 0, 0)
	renderer.update_render_zone(0, 0, 0, 0, 0, 0)
	_check(preload("res://tools/visibility_test_helpers.gd").settle(renderer), "Empty mesh entering view converges")
	_check(not renderer.chunk_cache.get_chunk(inside).visible, "Empty ArrayMesh stays hidden on entering membership")
	world.get_chunk(inside).blocks[WorldChunkSpace.chunk_index(1, 1, 1)] = World.BLOCK_ID_GRANITE
	renderer.regenerate_chunk(0, 0, 0)
	_check(renderer.chunk_cache.get_chunk(inside).visible, "New terrain geometry becomes visible without camera movement")
	_check(not renderer.needs_render_zone_update(0, 0, 0, 0, 0, 0), "Mesh handoffs do not trigger global reculls")
	_check(not renderer.diagnostics_render_bounds.is_empty(), "Applied view remains inspectable when diagnostics was disabled")
	renderer._stop_mesh_worker()
	world.free()
