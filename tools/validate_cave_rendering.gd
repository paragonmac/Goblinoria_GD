extends SceneTree
## Headless cave coverage checks; GPU/pixel acceptance remains a graphical check.

var failures := 0
var checks := 0


class LimitedWorld extends World:
	var render_floor := 0

	func get_min_render_y() -> int:
		return render_floor


func _init() -> void:
	_run.call_deferred()


func _run() -> void:
	_test_lower_cave_bands(false)
	_test_lower_cave_bands(true)
	_test_projected_reveal_targets()
	_test_camera_footprints()
	_test_streaming_depth_policy()
	_test_surface_stream_footprint()
	_test_zero_buffer_coverage()
	await _test_cached_reveal_gate()
	if failures > 0:
		push_error("Cave rendering failed: %d/%d" % [failures, checks])
		quit(1)
	else:
		print("Cave rendering OK (%d checks)" % checks)
		quit(0)


func _check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures += 1
		push_error(message)


func _make_world() -> World:
	var world := LimitedWorld.new()
	world._init_ramp_lookup()
	world.block_registry.load_from_csv(World.BLOCK_DATA_PATH)
	world.top_render_y = 16
	world.streaming = WorldStreaming.new(world)
	world.streaming.chunks_per_frame = 0
	world.streaming.stream_queue_budget = 0
	var renderer := WorldRenderer.new()
	renderer.use_async_meshing = false
	world.add_child(renderer)
	world.renderer = renderer
	renderer.initialize(world)
	return world


func _test_lower_cave_bands(from_cache: bool) -> void:
	var world := _make_world()
	var renderer := world.renderer
	# An open shaft crosses two band boundaries. A one-band depth patch is
	# insufficient: both the nearer ledge and the deeper floor must survive.
	var coords: Array[Vector3i] = [Vector3i(0, 0, 0), Vector3i(0, 1, 0), Vector3i(0, 2, 0), Vector3i(0, 3, 0)]
	for coord in coords:
		var chunk := world.ensure_chunk(coord)
		chunk.generated = true
		chunk.blocks[WorldChunkSpace.chunk_index(2, 7, 2)] = World.BLOCK_ID_GRANITE
		renderer.queue_chunk_mesh_build(coord)
		if from_cache:
			var entry := renderer.export_persistent_mesh_cache_entry(coord, World.CHUNK_SIZE - 1)
			var restored: Dictionary = bytes_to_var(var_to_bytes(entry))
			renderer.clear_chunk(coord)
			chunk.mesh_state = ChunkData.MESH_STATE_NONE
			_check(renderer.import_persistent_mesh_cache_entry(coord, restored), "Saved raw mesh entry rejected")
			renderer.queue_chunk_mesh_build(coord)
	var builder := MainRenderLevelTargetBuilder.new()
	builder.initialize(world, func(_y: int) -> Rect2: return Rect2(0, 0, 8, 8))
	var targets := builder.build_reveal_chunk_targets(16)
	_check(targets.has(coords[0]), "Reveal gate omits cave floor two bands below the slice")
	_check(targets.has(coords[1]), "Reveal gate omits cave ledge in previous band")
	for render_y in [16, 15, 17, 24, 16]:
		world.streaming.last_stream_target_valid = false
		world.set_top_render_y(render_y)
		world.streaming.update_streaming(Rect2(0, 0, 8, 8), render_y, 0.1)
		_check(preload("res://tools/visibility_test_helpers.gd").settle(renderer), "Cave visibility converges asynchronously")
		for coord in [coords[0], coords[1]]:
			var instance: MeshInstance3D = renderer.chunk_cache.get_chunk(coord)
			_check(instance != null and instance.mesh != null and instance.visible,
				"Cave surface hidden at slice=%d coord=%s cache=%s" % [render_y, coord, from_cache])
		_check(world.streaming.stream_min_y <= coords[0].y, "Streaming cannot load deep cave floor")
		_check(world.streaming.current_render_max_cy <= int(floor(float(render_y + 1) / World.CHUNK_SIZE)),
			"Cave fix widens upper terrain visibility")
	world.streaming.last_stream_target_valid = false
	world.set_top_render_y(0)
	world.streaming.update_streaming(Rect2(0, 0, 8, 8), 0, 0.1)
	_check(preload("res://tools/visibility_test_helpers.gd").settle(renderer), "Bottom visibility converges asynchronously")
	_check(world.streaming.current_render_min_cy == 0, "Bottom view produces negative chunk bands")
	_check(not renderer.chunk_cache.get_chunk(coords[1]).visible, "Bottom view keeps upper terrain band visible")
	_check(world.chunks.size() == coords.size(), "Visibility-only update generated terrain")
	renderer._stop_mesh_worker()
	world.free()


func _test_projected_reveal_targets() -> void:
	var world := _make_world()
	var builder := MainRenderLevelTargetBuilder.new()
	# Emulate the lateral shift of an isometric view as its plane descends.
	builder.initialize(world, func(y: int) -> Rect2: return Rect2(float(24 - y) * 2.0, 0, 8, 8))
	var targets := builder.build_reveal_chunk_targets(24)
	_check(targets.has(Vector3i(5, 0, 0)), "Deep projected cave floor outside slice XZ footprint omitted")
	_check(not targets.has(Vector3i(-12, 0, -12)), "Readiness gate expands to unrelated world columns")
	var generation := builder.build_reveal_generation_targets(24)
	var neighbor_complete := true
	for coord in targets:
		for offset in [Vector3i.ZERO, Vector3i.LEFT, Vector3i.RIGHT, Vector3i.UP, Vector3i.DOWN, Vector3i.FORWARD, Vector3i.BACK]:
			var neighbor: Vector3i = coord + offset
			if world.is_chunk_coord_valid(neighbor) and not generation.has(neighbor):
				neighbor_complete = false
	_check(neighbor_complete, "Reveal generation omits a mesh's boundary neighbor")
	var unique := {}
	for coord in generation:
		unique[coord] = true
	_check(unique.size() == generation.size(), "Generation targets contain duplicates")
	world.renderer._stop_mesh_worker()
	world.free()


func _test_camera_footprints() -> void:
	var world := _make_world()
	var viewport := SubViewport.new()
	viewport.size = Vector2i(640, 360)
	root.add_child(viewport)
	var camera := Camera3D.new()
	viewport.add_child(camera)
	var camera_controller := MainCameraController.new()
	camera_controller.initialize(camera, viewport)
	camera_controller.setup_camera(world)
	var builder := MainRenderLevelTargetBuilder.new()
	builder.initialize(world, Callable(camera_controller, "get_stream_view_rect"))
	for yaw in [45.0, 135.0, 225.0, 315.0]:
		camera.rotation_degrees.y = yaw
		var volume := builder.get_stream_volume_view_rect(16).grow(0.01)
		var targets := builder.build_reveal_chunk_targets(16)
		for y in [0, 7, 8, 15, 16]:
			for screen_point in [Vector2.ZERO, Vector2(639, 0), Vector2(639, 359), Vector2(0, 359), Vector2(320, 180)]:
				var point := camera_controller.raycast_to_plane(screen_point, y)
				_check(volume.has_point(Vector2(point.x, point.z)), "Stream volume misses a deep camera ray")
				var coord := world.world_to_chunk_coords(int(floor(point.x)), y, int(floor(point.z)))
				if world.is_chunk_coord_valid(coord):
					_check(targets.has(coord), "Reveal gate misses a camera corner at deep band")
	viewport.free()
	world.renderer._stop_mesh_worker()
	world.free()


func _test_cached_reveal_gate() -> void:
	var world := _make_world()
	var controller := MainRenderLevelController.new()
	controller.world = world
	controller.target_builder.initialize(world, func(_y: int) -> Rect2: return Rect2(0, 0, 8, 8))
	var targets := controller._build_reveal_chunk_targets(16)
	for coord in controller._build_reveal_generation_targets(16):
		var chunk := world.ensure_chunk(coord)
		chunk.generated = true
		chunk.blocks[WorldChunkSpace.chunk_index(2, 7, 2)] = World.BLOCK_ID_GRANITE
	for coord in targets:
		world.renderer.queue_chunk_mesh_build(coord)
		var chunk := world.get_chunk(coord)
		# Model loaded raw cache data with no scene instance yet. The actual gate
		# must instantiate lower meshes, not declare ready from the cut band alone.
		world.renderer.chunk_cache.remove_chunk(coord)
		chunk.mesh_state = ChunkData.MESH_STATE_NONE
	_check(controller._count_ready_startup_chunks(targets) == 0, "Raw caches count as scene-ready before application")
	var build_ms_before := float(world.renderer.get_mesh_cache_metrics().get("mesh_build_ms", 0.0))
	var profile: Dictionary = await controller._ensure_render_y_ready(16, "Cave fixture")
	_check(int(profile.get("mesh_ready_after", 0)) == targets.size(), "Actual reveal gate failed to prepare every cave band")
	_check(world.renderer.chunk_cache.get_chunk(Vector3i.ZERO) != null, "Actual reveal gate never applied deep floor cache")
	_check(is_equal_approx(build_ms_before, float(world.renderer.get_mesh_cache_metrics().get("mesh_build_ms", 0.0))),
		"Reveal gate rebuilt valid full-chunk cache geometry")
	world.renderer._stop_mesh_worker()
	world.free()


func _test_streaming_depth_policy() -> void:
	var world := _make_world() as LimitedWorld
	var streaming := world.streaming
	world.render_floor = 9
	_check(streaming.get_render_chunk_y_bounds(24).x == 1, "Render policy ignores minimum visible depth")
	var builder := MainRenderLevelTargetBuilder.new()
	builder.initialize(world, func(_y: int) -> Rect2: return Rect2(0, 0, 8, 8))
	var targets := builder.build_reveal_chunk_targets(24)
	_check(not targets.has(Vector3i.ZERO), "Readiness includes bands below minimum depth")
	world.render_floor = 0
	streaming.stream_vertical_margin_blocks = 0
	streaming.update_streaming(Rect2(0, 0, 8, 8), 7, 0.1)
	_check(streaming.stream_max_y >= streaming.current_render_max_cy, "Zero stream buffer omits upper player-stair band")
	# Default offscreen buffer spans the finite map. Deep rendering must not
	# turn that buffer into whole-world meshing all the way to bedrock.
	streaming.update_streaming(Rect2(0, 0, 8, 8), 32, 0.1)
	streaming.stream_layer_y = 0
	streaming.stream_plane_index = 0
	streaming.render_plane_index = 0
	streaming.buffer_plane_index = 0
	streaming.stream_layer_remaining = streaming.deep_render_plane_size
	streaming.stream_pending = true
	streaming.stream_queue_budget = 10000
	streaming.enqueue_stream_chunks()
	_check(streaming.chunk_build_set.has(Vector3i.ZERO), "Deep render column was not queued")
	_check(not streaming.chunk_build_set.has(Vector3i(-12, 0, -12)), "Deep offscreen buffer was queued for meshing")
	_check(streaming.stream_plane_index == streaming.deep_render_plane_size, "Deep layer budget spent walking unused offscreen buffer")
	var old_anchor := streaming.last_stream_chunk
	streaming.stream_queue_budget = 0
	streaming.update_streaming(Rect2(-16, -16, 40, 40), 32, 0.1)
	_check(streaming.last_stream_chunk == old_anchor, "Fixture should preserve full-map streaming anchor")
	var offsets_include_new_column := false
	for offset: Vector2i in streaming.render_spiral_offsets:
		if streaming.stream_min_x + offset.x == 3 and streaming.stream_min_z + offset.y == 0:
			offsets_include_new_column = true
	_check(offsets_include_new_column, "Moving render footprint with fixed anchor did not repartition priority columns")
	streaming.reset_state()
	_check(streaming.deep_render_spiral_offsets.is_empty(), "Reset retains previous deep render footprint")
	world.renderer._stop_mesh_worker()
	world.free()


func _test_surface_stream_footprint() -> void:
	var world := _make_world()
	world.top_render_y = world.world_size_y - World.SEA_LEVEL_DEPTH
	var viewport := SubViewport.new()
	viewport.size = Vector2i(1152, 648)
	root.add_child(viewport)
	var camera := Camera3D.new()
	viewport.add_child(camera)
	var camera_controller := MainCameraController.new()
	camera_controller.initialize(camera, viewport)
	camera_controller.setup_camera(world)
	var builder := MainRenderLevelTargetBuilder.new()
	builder.initialize(world, Callable(camera_controller, "get_stream_view_rect"))
	var active_rect := camera_controller.get_stream_view_rect(world.top_render_y)
	var band_rects := builder.get_render_band_view_rects(world.top_render_y)
	world.update_streaming(active_rect, world.top_render_y, 0.1, camera, band_rects)
	var focus := world.clamp_block_xz(Vector3(active_rect.get_center().x, world.top_render_y, active_rect.get_center().y))
	_check(world.streaming.last_stream_target.is_equal_approx(focus), "Deep coverage shifts active-slice camera focus")
	var deep_target_count := 0
	for cy: int in world.streaming.deep_render_offsets_by_band:
		if cy < world.streaming.near_level_min_cy:
			deep_target_count += world.streaming.deep_render_offsets_by_band[cy].size()
	var ready_count := builder.build_reveal_chunk_targets(world.top_render_y).size()
	_check(deep_target_count > 0, "Surface fixture did not exercise deep streaming")
	_check(deep_target_count <= ready_count * 3, "Deep streaming expands each band to the entire swept volume")
	print("Cave surface footprint: readiness=%d deep_stream_with_halo=%d" % [ready_count, deep_target_count])
	# Coverage can move while the camera focus and streaming anchor do not.
	var old_anchor := world.streaming.last_stream_chunk
	var moved_bands := band_rects.duplicate()
	var moved_rect: Rect2 = moved_bands[0]
	moved_rect.position += Vector2(32, 0)
	moved_bands[0] = moved_rect
	world.update_streaming(active_rect, world.top_render_y, 0.1, camera, moved_bands)
	_check(world.streaming.last_stream_target.is_equal_approx(focus), "Coverage-only movement changes camera focus")
	_check(world.streaming.last_stream_chunk == old_anchor, "Coverage-only movement changes streaming anchor")
	_check(is_zero_approx(world.streaming.speed_chunks_per_sec), "Coverage-only movement produces camera velocity")
	world.streaming.reset_state()
	_check(world.streaming.deep_render_offsets_by_band.is_empty(), "Reset retains per-band deep target arrays")
	viewport.free()
	world.renderer._stop_mesh_worker()
	world.free()


func _test_zero_buffer_coverage() -> void:
	var world := _make_world()
	var streaming := world.streaming
	streaming.stream_base_buffer_chunks = 0
	streaming.stream_buffer_view_scale = 0.0
	streaming.stream_lead_time = 0.0
	streaming.stream_vertical_margin_blocks = 0
	var rects := {0: Rect2(64, 0, 8, 8), 1: Rect2(32, 0, 8, 8), 2: Rect2(0, 0, 8, 8)}
	world.update_streaming(Rect2(0, 0, 8, 8), 16, 0.1, null, rects)
	_check(streaming.stream_max_x >= 9, "Zero buffer fails to load shifted deep footprint plus neighbors")
	_check(streaming.last_stream_chunk == Vector2i.ZERO, "Shifted deep footprint moves active camera chunk")
	var offsets: Array = streaming.deep_render_offsets_by_band.get(0, [])
	_check(offsets.has(Vector2i(8 - streaming.stream_min_x, -streaming.stream_min_z)),
		"Deep band does not load its own shifted cave floor")
	_check(not offsets.has(Vector2i(-streaming.stream_min_x, -streaming.stream_min_z)),
		"Deep band loads unrelated columns from the upper slice")
	world.renderer._stop_mesh_worker()
	world.free()
