extends SceneTree

const MainScript = preload("res://scripts/Main.gd")
const WorldScript = preload("res://scripts/world.gd")

var checks := 0
var failures: Array[String] = []
var main
var benchmark := false


func _init() -> void:
	benchmark = OS.get_environment("GOB_LARGE_WORLD_BENCH") == "1"
	_run.call_deferred()


func _check(value: bool, message: String) -> void:
	checks += 1
	if not value:
		failures.append(message)
		push_error(message)


func _run() -> void:
	root.size = Vector2i(1280, 800)
	root.gui_embed_subwindows = true
	main = load("res://scenes/Main.tscn").instantiate()
	root.add_child(main)
	await process_frame
	_check(main.world_size_option_button != null, "New Game size selector is created in code")
	if main.world_size_option_button != null:
		main.world_size_option_button.select(1)
		_check(main._selected_world_chunk_dimensions() == Vector2i(64, 64), "512 option selects 64 x 64 chunks")
		main.world_size_option_button.select(0)
		_check(main._selected_world_chunk_dimensions() == Vector2i(32, 32), "256 option is selected by default")
	_check(main.world_size_option_button.visible, "Size selector is visible before starting a world")
	# Never touch the player's save: this test drives New Game, which saves.
	main.save_path = "user://large_world_flow_%d/world.save" % OS.get_process_id()
	if ProjectSettings.globalize_path(main.save_path) == ProjectSettings.globalize_path(main.SAVE_PATH):
		_check(false, "Test save path must not be the player save")
		_finish()
		return
	main.force_on_demand_meshing_for_tests = not benchmark
	if benchmark:
		main.world_size_option_button.select(1)
	else:
		main.generate_full_map_on_startup = false
		main.world_size_option_button.clear()
		main.world_size_option_button.add_item("128 x 128 (test)", 16)
		main.world_size_option_button.select(0)
	main.resume_button.pressed.emit()
	var start_usec := Time.get_ticks_usec()
	while not main.world_started and Time.get_ticks_usec() - start_usec < 120_000_000:
		await process_frame
	if not main.world_started:
		_check(false, "New Game flow completes before its 120 second test timeout")
		_finish()
		return
	_check(not main.world_size_option_button.visible, "Size selector hides after world start")
	var world = main.world
	_check(main.last_new_world_chunk_dimensions == (Vector2i(64, 64) if benchmark else Vector2i(16, 16)),
		"New Game passes the selected chunk dimensions to start_new_world")
	var large_chunks: bool = WorldScript.WORLD_CHUNKS_X > 32 or WorldScript.WORLD_CHUNKS_Z > 32
	_check(main.is_wide_world() and main.render_level_controller._is_wide_world(), "shared wide-world predicate activates render test path")
	_check(world.arena_cooker.stage == world.arena_cooker.Stage.DONE, "block cook completes without starting mesh stage")
	_check(world.arena_cooker.meshes_built == 0 and world.arena_cooker.meshes_merged == 0,
		"full-map mesh pre-cook is skipped")
	_check(int(world.save_load.mesh_cache_save_load.mesh_cache_stats.get("entries_saved", -1)) == 0,
		"new world save accepts an empty partial mesh cache")
	var reveal_profile: Dictionary = main.render_level_controller.last_render_y_ready_profile
	_check(int(reveal_profile.get("mesh_total", 0)) > 0
		and int(reveal_profile.get("mesh_ready_after", 0)) == int(reveal_profile.get("mesh_total", -1)),
		"on-demand meshing prepares every chunk required for reveal")
	_check(main._has_save_game(), "new-world flow writes its save")
	var surface_pos: Vector3i = _find_surface_air_cell(world)
	_check(surface_pos.y > 0, "test world has a valid surface air cell")
	if surface_pos.y > 0:
		world.torch_store.add_torch(surface_pos)
		world.light_field.mark_explored(surface_pos.x, surface_pos.y, surface_pos.z)
	var trees_before_save: int = world.tree_store.count()
	var explored_before_save: bool = world.light_field.is_explored(surface_pos.x, surface_pos.y, surface_pos.z)
	_check(trees_before_save > 0, "generated world contains tree attachments")
	_check(world.light_field.get_sky(surface_pos.x, surface_pos.y, surface_pos.z) == 15,
		"surface air cell has full sky light before save")
	_check(explored_before_save, "test explored cell is marked before save")
	_check(world.save_world(main.save_path), "post-reveal save writes mesh and attachment snapshots")
	var saved_mesh_entries: int = int(world.save_load.mesh_cache_save_load.mesh_cache_stats.get("entries_saved", 0))
	_check(saved_mesh_entries > 0, "post-reveal save contains a genuinely partial mesh cache")
	if benchmark:
		var cook: Dictionary = world.arena_cooker.get_diagnostics()
		print("Large world stages: generation=%.1fms block_merge=%.1fms mesh=%.1fms save=%.1fms" % [
			float(cook.get("generation_wall_ms", 0.0)),
			float(cook.get("merge_blocks_ms", 0.0)),
			float(cook.get("mesh_wall_ms", 0.0)),
			float(cook.get("save_ms", 0.0)),
		])
		print("Large world chunks meshed at reveal: %d/%d; memory_static=%.1fMiB" % [
			int(reveal_profile.get("mesh_ready_after", 0)),
			int(reveal_profile.get("mesh_total", 0)),
			float(Performance.get_monitor(Performance.MEMORY_STATIC)) / (1024.0 * 1024.0),
		])
		_check(float(Time.get_ticks_usec() - start_usec) / 1_000_000.0 < 60.0,
			"512 new world reaches reveal in under 60 seconds")
	else:
		var bands: Array[int] = [main.render_level_controller.chunk_y_for_render_y(world.top_render_y)]
		var bounded: Array[Vector3i] = main.render_level_controller._build_bounded_warmup_targets(bands)
		var expected_center: Vector2i = main.render_level_controller._warmup_center_chunk(bands[0])
		var warmup_radius: int = maxi(world.streaming.stream_radius_base + 2, 2)
		var in_bounds := true
		for coord: Vector3i in bounded:
			in_bounds = in_bounds and world.is_chunk_coord_valid(coord)
		var expected_min_x: int = maxi(expected_center.x - warmup_radius, WorldScript.WORLD_MIN_CHUNK_X)
		var expected_max_x: int = mini(expected_center.x + warmup_radius, WorldScript.WORLD_MAX_CHUNK_X)
		var expected_min_z: int = maxi(expected_center.y - warmup_radius, WorldScript.WORLD_MIN_CHUNK_Z)
		var expected_max_z: int = mini(expected_center.y + warmup_radius, WorldScript.WORLD_MAX_CHUNK_Z)
		var expected_count: int = maxi(expected_max_x - expected_min_x + 1, 0) \
			* maxi(expected_max_z - expected_min_z + 1, 0)
		_check(not bounded.is_empty() and in_bounds and bounded.size() == expected_count,
			"warmup targets are built around the live band's stream-view center and stay bounded")
	main.open_menu()
	var load_start_usec := Time.get_ticks_usec()
	main.load_button.pressed.emit()
	while main.loading_active and Time.get_ticks_usec() - load_start_usec < 120_000_000:
		await process_frame
	if not main.world_started:
		_check(false, "saved world reloads through the menu flow")
	else:
		_check(int(world.save_load.mesh_cache_save_load.mesh_cache_stats.get("entries_read", 0)) == saved_mesh_entries
			and int(world.save_load.mesh_cache_save_load.mesh_cache_stats.get("entries_imported", 0)) > 0,
			"load imports available partial mesh entries without a full-cache wait")
		_check(not main.world_size_option_button.visible, "size selector remains hidden after load")
		var loaded_profile: Dictionary = main.render_level_controller.last_render_y_ready_profile
		_check(int(loaded_profile.get("mesh_total", 0)) > 0
			and int(loaded_profile.get("mesh_ready_after", 0)) == int(loaded_profile.get("mesh_total", -1)),
			"loaded chunks without mesh entries mesh on demand before reveal")
		_check(world.tree_store.count() == trees_before_save, "tree attachments survive wide-world load")
		_check(world.chunks.size() == WorldScript.WORLD_CHUNKS_X * WorldScript.WORLD_CHUNKS_Y * WorldScript.WORLD_CHUNKS_Z,
			"wide-world load installs every saved bulk chunk before lighting")
		_check(world.torch_store.has_torch(surface_pos), "torch attachment survives wide-world load")
		_check(world.light_field.get_sky(surface_pos.x, surface_pos.y, surface_pos.z) == 15,
			"loaded surface cell retains full sky light")
		_check(world.light_field.is_explored(surface_pos.x, surface_pos.y, surface_pos.z) == explored_before_save,
			"explored state survives wide-world load")
		if benchmark:
			var load_usec: int = Time.get_ticks_usec() - load_start_usec
			print("Large world load: total=%.2fs view_meshes=%d/%d initial_view_mesh_ms=%.1f memory_static=%.1fMiB" % [
				float(load_usec) / 1_000_000.0,
				int(loaded_profile.get("mesh_ready_after", 0)),
				int(loaded_profile.get("mesh_total", 0)),
				float(loaded_profile.get("total_blocked_ms", 0.0)),
				float(Performance.get_monitor(Performance.MEMORY_STATIC)) / (1024.0 * 1024.0),
			])
	if main.world.task_manager != null:
		main.world.task_manager.shutdown()
	_finish()


func _find_surface_air_cell(world) -> Vector3i:
	var x: int = clampi(int(world.spawn_coord.x), WorldScript.WORLD_MIN_BLOCK_X, WorldScript.WORLD_MAX_BLOCK_X)
	var z: int = clampi(int(world.spawn_coord.z), WorldScript.WORLD_MIN_BLOCK_Z, WorldScript.WORLD_MAX_BLOCK_Z)
	for y: int in range(world.world_size_y - 1, 0, -1):
		if world.is_block_solid_id(world.get_block_no_generate(x, y - 1, z)) \
			and world.get_block_no_generate(x, y, z) == WorldScript.BLOCK_ID_AIR:
			return Vector3i(x, y, z)
	return Vector3i.ZERO


func _finish() -> void:
	print("Large world flow: %d checks, %d failures" % [checks, failures.size()])
	quit(1 if not failures.is_empty() else 0)
