extends SceneTree
## Run headlessly with --path <repo> --script res://tools/validate_rendering_regressions.gd.

const WAIT_TIMEOUT_MS := 5000

var failures: int = 0


class BuildGate extends RefCounted:
	var renderer: WorldRenderer
	var entered := Semaphore.new()
	var release := Semaphore.new()
	var results: Array[Dictionary] = []

	func build(job: Dictionary) -> Dictionary:
		var result: Dictionary = renderer._build_mesh_result_on_worker(job)
		results.append(result)
		entered.post()
		# Pause a real completed build before the scheduler can publish it.
		release.wait()
		return result


func _init() -> void:
	for async_enabled in [false, true]:
		for block_id in [World.BLOCK_ID_GRANITE, World.RAMP_NORTH_ID, World.TERRAIN_SLOPE_NORTH_ID]:
			_test_above_slice_reveal(async_enabled, block_id)
	for reset_kind in ["world", "coord", "scheduler"]:
		for cache_only in [false, true]:
			_test_in_flight_reset(reset_kind, cache_only)
	if failures > 0:
		push_error("Rendering regressions failed: %d" % failures)
		quit(1)
		return
	print("Rendering regressions OK (above-slice reveal, upper-band stairs, cache reuse, in-flight resets)")
	quit(0)


func _make_world() -> World:
	var world := World.new()
	world._init_ramp_lookup()
	world.block_registry.load_from_csv(World.BLOCK_DATA_PATH)
	world.top_render_y = 1
	var renderer := WorldRenderer.new()
	renderer.use_async_meshing = false
	world.add_child(renderer)
	world.renderer = renderer
	renderer.initialize(world)
	return world


func _install_gate(renderer: WorldRenderer) -> BuildGate:
	var gate := BuildGate.new()
	gate.renderer = renderer
	renderer.mesh_scheduler.configure(Callable(gate, "build"), 32, 500)
	renderer.use_async_meshing = true
	return gate


func _dispose_world(world: World, gate: BuildGate = null) -> void:
	if gate != null:
		# Release either barrier even when a failed check takes an early exit.
		gate.release.post()
		gate.release.post()
	world.renderer._stop_mesh_worker()
	world.renderer.mesh_scheduler.build_callback = Callable()
	world.free()


func _check(condition: bool, message: String) -> bool:
	if not condition:
		failures += 1
		push_error(message)
	return condition


func _wait_for(predicate: Callable, message: String) -> bool:
	var deadline := Time.get_ticks_msec() + WAIT_TIMEOUT_MS
	while Time.get_ticks_msec() < deadline:
		if bool(predicate.call()):
			return true
		OS.delay_usec(500)
	return _check(false, message)


func _has_geometry(renderer: WorldRenderer, coord: Vector3i) -> bool:
	var instance: MeshInstance3D = renderer.chunk_cache.get_chunk(coord)
	return instance != null and instance.mesh != null and instance.mesh.get_surface_count() > 0


func _test_above_slice_reveal(async_enabled: bool, block_id: int) -> void:
	var label := "above-slice async=%s block=%d" % [async_enabled, block_id]
	var world := _make_world()
	var renderer: WorldRenderer = world.renderer
	var gate: BuildGate = _install_gate(renderer) if async_enabled else null
	var coord := Vector3i(0, 1, 0)
	var chunk: ChunkData = world.ensure_chunk(coord)
	chunk.generated = true
	chunk.dirty = true
	chunk.blocks[renderer.mesher.chunk_index(World.CHUNK_SIZE, 1, 0, 1)] = block_id
	var controller := MainRenderLevelController.new()
	controller.world = world
	var targets: Array[Vector3i] = [coord]
	# Cover both ordinary streaming requests and queued render-height requests.
	renderer.queue_chunk_mesh_build(coord, -1, block_id == World.RAMP_NORTH_ID)
	if async_enabled:
		if not _wait_for(Callable(gate.entered, "try_wait"), label + ": build did not start"):
			_dispose_world(world, gate)
			return
		_check(controller._count_ready_startup_chunks(targets) == 0, label + ": unbuilt chunk counted ready")
		for index in range(4):
			renderer.queue_chunk_mesh_build(coord, index + 1, true, true)
		_check(int(renderer.mesh_scheduler.get_stats()["job_queue"]) == 0, label + ": repeated slice requests duplicated in-flight work")
		gate.release.post()
		if not _wait_for(Callable(renderer.mesh_scheduler, "has_any_results"), label + ": build did not finish"):
			_dispose_world(world, gate)
			return
		_check(renderer.process_mesh_results(8) == 1, label + ": full mesh was not applied")
		_check(gate.results.size() == 1, label + ": duplicate builds completed")
	_check(_has_geometry(renderer, coord), label + ": READY without geometry above slice")
	_check(controller._count_ready_startup_chunks(targets) == 1, label + ": completed full mesh not ready")
	_check(renderer.has_cached_chunk_mesh(coord, World.CHUNK_SIZE - 1), label + ": full-chunk cache missing")
	var cached: Dictionary = renderer.export_persistent_mesh_cache_entry(coord, World.CHUNK_SIZE - 1)

	# Exercise the actual readiness gate after raising the slice, as in the repro.
	world.set_top_render_y(World.CHUNK_SIZE)
	controller._queue_startup_chunk_mesh(coord, true)
	_check(_has_geometry(renderer, coord), label + ": readiness gate skipped missing reveal geometry")
	_check(not renderer.has_pending_mesh_work(true), label + ": reveal queued another full build")

	# Lower across the band boundary through the legacy render-height queue too.
	world.set_top_render_y(World.CHUNK_SIZE - 1)
	renderer.queue_render_height_update(World.CHUNK_SIZE, World.CHUNK_SIZE - 1, Vector3.ZERO, 0, 0, 0, 0)
	renderer.process_render_height_queue(8)
	var bounds := WorldStreaming.compute_render_chunk_y_bounds(
		World.CHUNK_SIZE - 1, 0, 1, World.CHUNK_SIZE, 0, World.WORLD_CHUNKS_Y - 1
	)
	renderer.update_render_zone(0, 0, 0, 0, bounds.x, bounds.y)
	_check(preload("res://tools/visibility_test_helpers.gd").settle(renderer), label + ": async visibility converges")
	if _check(_has_geometry(renderer, coord), label + ": lowering destroyed upper-band geometry"):
		var instance: MeshInstance3D = renderer.chunk_cache.get_chunk(coord)
		_check(instance.visible, label + ": upper connection band hidden")
		var arrays: Array = instance.mesh.surface_get_arrays(0)
		var uv2s: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV2]
		var expected_y := float(World.CHUNK_SIZE - 1 if block_id == World.RAMP_NORTH_ID else World.CHUNK_SIZE)
		var encoding_ok := not uv2s.is_empty()
		for uv2 in uv2s:
			encoding_ok = encoding_ok and is_equal_approx(uv2.x, expected_y)
		_check(encoding_ok, label + ": ADR-011 visibility encoding wrong at Y=7 / chunk Y=1")
		var material := renderer.get_block_material() as ShaderMaterial
		_check(is_equal_approx(float(material.get_shader_parameter("top_render_y")), float(World.CHUNK_SIZE - 1)), label + ": shader slice not updated")
	_check(renderer.export_persistent_mesh_cache_entry(coord, World.CHUNK_SIZE - 1) == cached, label + ": slice change replaced full cache")
	_check(int(renderer.get_mesh_cache_metrics()["hits"]) > 0, label + ": slice change did not reuse full cache")
	_check(not renderer.has_pending_mesh_work(true), label + ": lowering left repeated mesh work")
	_dispose_world(world, gate)


func _queue_reset_job(renderer: WorldRenderer, coord: Vector3i, cache_only: bool) -> void:
	if cache_only:
		_check(renderer.queue_chunk_mesh_cache_build(coord, World.CHUNK_SIZE - 1), "Cache job was not queued")
	else:
		renderer.queue_chunk_mesh_build(coord)


func _test_in_flight_reset(reset_kind: String, cache_only: bool) -> void:
	var label := "in-flight reset=%s cache_only=%s" % [reset_kind, cache_only]
	var world := _make_world()
	world.top_render_y = World.CHUNK_SIZE - 1
	var renderer: WorldRenderer = world.renderer
	var gate := _install_gate(renderer)
	var coord := Vector3i.ZERO
	var old_chunk: ChunkData = world.ensure_chunk(coord)
	old_chunk.generated = true
	old_chunk.blocks.fill(World.BLOCK_ID_GRANITE)
	_queue_reset_job(renderer, coord, cache_only)
	if not _wait_for(Callable(gate.entered, "try_wait"), label + ": old build did not start"):
		_dispose_world(world, gate)
		return
	_check(bool(gate.results[0].get("has_geometry", false)), label + ": old build needs real geometry")
	match reset_kind:
		"world":
			renderer.clear_chunks()
			world.chunks.clear()
		"coord":
			renderer.clear_chunk(coord)
			world.chunks.erase(coord)
		"scheduler":
			renderer.mesh_scheduler.clear()
			world.chunks.erase(coord)
	var replacement: ChunkData = world.ensure_chunk(coord)
	replacement.generated = true
	replacement.dirty = true
	_check(replacement.mesh_revision == old_chunk.mesh_revision, label + ": revisions must collide for this regression")
	_queue_reset_job(renderer, coord, cache_only)
	var expected_state: int = replacement.mesh_state
	gate.release.post()
	# Reaching the second callback proves the first publication attempt finished.
	# Hold the new result so only an incorrectly accepted old result could apply.
	if not _wait_for(Callable(gate.entered, "try_wait"), label + ": replacement build did not start"):
		_dispose_world(world, gate)
		return
	_check(not renderer.mesh_scheduler.has_any_results(), label + ": late old result was published after reset")
	_check(renderer.process_mesh_results(8) == 0, label + ": late old result applied")
	# Also cover a result already held by a consumer when invalidation happens.
	_check(not renderer._apply_mesh_result(gate.results[0]), label + ": stale held result accepted")
	_check(replacement.mesh_state == expected_state and replacement.dirty, label + ": stale result changed replacement readiness/dirty state")
	_check(not renderer.has_cached_chunk_mesh(coord, World.CHUNK_SIZE - 1), label + ": old geometry entered replacement cache")
	_check(renderer.chunk_cache.get_chunk(coord) == null, label + ": old geometry installed on replacement")
	if cache_only:
		var key: String = renderer.mesh_scheduler.prefetch_key(coord, World.CHUNK_SIZE - 1)
		_check(renderer.mesh_scheduler.get_prefetch_revision(key) == replacement.mesh_revision, label + ": stale result cleared replacement prefetch record")
	else:
		_check(renderer.mesh_scheduler.get_job_revision(coord) == replacement.mesh_revision, label + ": stale result cleared replacement job record")
	gate.release.post()
	if not _wait_for(Callable(renderer.mesh_scheduler, "has_any_results"), label + ": replacement result missing"):
		_dispose_world(world, gate)
		return
	_check(renderer.process_mesh_results(8) == 1, label + ": replacement result rejected")
	_check(not renderer.has_pending_mesh_work(true), label + ": replacement job record not retired")
	var entry: Dictionary = renderer.export_persistent_mesh_cache_entry(coord, World.CHUNK_SIZE - 1)
	_check(not entry.is_empty() and not bool(entry.get("has_geometry", true)), label + ": replacement must cache empty geometry")
	if not cache_only:
		_check(replacement.mesh_state == ChunkData.MESH_STATE_READY and not _has_geometry(renderer, coord), label + ": empty replacement did not become ready")
	else:
		_check(replacement.mesh_state == expected_state, label + ": cache-only build changed visible readiness")
	_dispose_world(world, gate)
