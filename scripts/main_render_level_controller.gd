extends RefCounted
class_name MainRenderLevelController

const MainYTransitionProfilerScript = preload("res://scripts/main_y_transition_profiler.gd")
const MainRenderLevelTargetBuilderScript = preload("res://scripts/main_render_level_target_builder.gd")

const STARTUP_GENERATION_RESULT_BUDGET := 128
const STARTUP_MESH_RESULT_BUDGET := 128
const STARTUP_MESH_QUEUE_BUDGET := 128
const Y_DIRECTIONAL_PREWARM_BLOCKS_AHEAD := 8
const Y_DIRECTIONAL_PREWARM_GENERATION_RESULT_BUDGET := 8
const Y_DIRECTIONAL_PREWARM_MESH_RESULT_BUDGET := 4
const Y_DIRECTIONAL_PREWARM_MESH_QUEUE_BUDGET := 32
const BACKGROUND_WARMUP_GENERATION_RESULT_BUDGET := 2
const BACKGROUND_WARMUP_MESH_RESULT_BUDGET := 2
const BACKGROUND_WARMUP_MESH_RESULT_TIME_BUDGET_MS := 2.0
const BACKGROUND_WARMUP_MESH_QUEUE_BUDGET := 4

var world: World
var scene_tree: SceneTree
var camera: Camera3D
var debug_overlay: DebugOverlay
var loading_progress_callback: Callable
var loading_status_callback: Callable
var show_loading_callback: Callable
var hide_loading_callback: Callable
var world_draw_callback: Callable
var prepared_chunk_bands: Dictionary = {}
var background_warmup_queue: Array[int] = []
var background_warmup_generation_targets: Array[Vector3i] = []
var background_warmup_mesh_targets: Array[Vector3i] = []
var background_warmup_mesh_index: int = 0
var background_warmup_band: int = -1
var background_warmup_meshes_queued := false
var y_prewarm_generation_targets: Array[Vector3i] = []
var y_prewarm_mesh_targets: Array[Vector3i] = []
var y_prewarm_mesh_index: int = 0
var y_prewarm_render_y: int = -1
var y_prewarm_direction: int = 0
var y_prewarm_meshes_queued := false
var last_startup_load_metrics: Dictionary = {}
var last_render_y_ready_profile: Dictionary = {}
var y_transition_profiler = MainYTransitionProfilerScript.new()
var target_builder = MainRenderLevelTargetBuilderScript.new()


func initialize(
	world_ref: World,
	scene_tree_ref: SceneTree,
	camera_ref: Camera3D,
	stream_view_rect_provider: Callable,
	callbacks: Dictionary
) -> void:
	world = world_ref
	scene_tree = scene_tree_ref
	camera = camera_ref
	loading_progress_callback = callbacks.get("set_progress", Callable())
	loading_status_callback = callbacks.get("set_status", Callable())
	show_loading_callback = callbacks.get("show", Callable())
	hide_loading_callback = callbacks.get("hide", Callable())
	world_draw_callback = callbacks.get("set_world_draw_enabled", Callable())
	target_builder.initialize(world_ref, stream_view_rect_provider)
	y_transition_profiler.initialize(world_ref)


func update_world(world_ref: World) -> void:
	world = world_ref
	target_builder.update_world(world_ref)
	y_transition_profiler.update_world(world_ref)


func set_debug_overlay(debug_overlay_ref: DebugOverlay) -> void:
	debug_overlay = debug_overlay_ref
	y_transition_profiler.set_debug_overlay(debug_overlay_ref)


func get_last_startup_load_metrics() -> Dictionary:
	return last_startup_load_metrics.duplicate()


func reset_loading_state() -> void:
	_reset_level_loading_state()


func chunk_y_for_render_y(render_y: int) -> int:
	return _chunk_y_for_render_y(render_y)


func schedule_background_warmup(center_cy: int) -> void:
	_schedule_background_level_warmup(center_cy)


func pump_directional_prewarm(world_started: bool) -> void:
	_pump_directional_y_prewarm(world_started)


func pump_background_warmup(world_started: bool) -> void:
	_pump_background_level_warmup(world_started)


func build_all_world_chunk_targets() -> Array[Vector3i]:
	return _build_all_world_chunk_targets()


func request_startup_generation(
	targets: Array[Vector3i],
	queue_mesh_on_complete: bool,
	high_priority: bool = true
) -> void:
	_request_startup_chunk_generation(targets, queue_mesh_on_complete, high_priority)


func pump_startup_loading_work() -> int:
	return _pump_startup_loading_work()


func count_generated_chunks(targets: Array[Vector3i]) -> int:
	return _count_generated_startup_chunks(targets)


func handle_render_layer_change(delta: int) -> void:
	if world == null:
		return
	var from_y: int = world.top_render_y
	var target_y: int = clampi(from_y + delta, 0, world.world_size_y - 1)
	if target_y == from_y:
		return
	var snapshot_before: Dictionary = y_transition_profiler.capture_snapshot()
	var mesh_targets: Array[Vector3i] = _build_reveal_chunk_targets(target_y)
	var mesh_ready_before: int = _count_ready_startup_chunks(mesh_targets)
	if mesh_targets.is_empty() or mesh_ready_before < mesh_targets.size():
		_change_render_layer_with_loading(delta, from_y, target_y, snapshot_before, mesh_targets, mesh_ready_before)
		return
	var overlay := _debug_overlay()
	if overlay != null:
		overlay.run_timed("World.set_top_render_y", Callable(self, "_apply_render_y").bind(target_y))
	else:
		_apply_render_y(target_y)
	_refresh_streaming_after_render_level_change(target_y)
	_log_render_height_change(delta)
	_record_instant_y_transition(from_y, target_y, delta, snapshot_before, mesh_targets, mesh_ready_before)
	_schedule_directional_y_prewarm(delta, target_y)


func _apply_render_y(target_y: int) -> void:
	if world != null:
		world.set_top_render_y(target_y)


func _refresh_streaming_after_render_level_change(render_y: int) -> void:
	if world == null:
		return
	var view_rect: Rect2 = _get_stream_view_rect_for_y(render_y)
	var active_camera := _active_camera()
	world.update_streaming(view_rect, float(render_y), 0.0, active_camera)
	if world.streaming != null:
		world.streaming.refresh_render_zone(active_camera)


func _change_render_layer_with_loading(delta: int, from_y: int, target_y: int, snapshot_before: Dictionary, mesh_targets_before: Array[Vector3i], mesh_ready_before: int) -> void:
	var blocked_start_usec: int = Time.get_ticks_usec()
	var generation_targets_before: Array[Vector3i] = _build_reveal_generation_targets(target_y)
	var generation_ready_before: int = _count_generated_startup_chunks(generation_targets_before)
	_show_loading_screen("Building level...")
	if scene_tree != null:
		await scene_tree.process_frame
	var ready_profile: Dictionary = await _ensure_render_y_ready(target_y, "Building level %d" % target_y)
	var overlay := _debug_overlay()
	if overlay != null:
		overlay.run_timed("World.set_top_render_y", Callable(self, "_apply_render_y").bind(target_y))
	else:
		_apply_render_y(target_y)
	_log_render_height_change(delta)
	_refresh_streaming_after_render_level_change(target_y)
	var snapshot_after: Dictionary = y_transition_profiler.capture_snapshot()
	ready_profile["mesh_total"] = mesh_targets_before.size()
	ready_profile["mesh_ready_before"] = mesh_ready_before
	ready_profile["generation_total"] = generation_targets_before.size()
	ready_profile["generation_ready_before"] = generation_ready_before
	ready_profile["total_blocked_ms"] = float(Time.get_ticks_usec() - blocked_start_usec) / 1000.0
	ready_profile["frames_waited"] = int(ready_profile.get("frames_waited", 0)) + 1
	y_transition_profiler.record_transition(from_y, target_y, delta, true, ready_profile, snapshot_before, snapshot_after)
	_set_world_draw_enabled(true)
	_hide_loading_screen()
	_schedule_directional_y_prewarm(delta, target_y)


func _log_render_height_change(delta: int) -> void:
	var overlay := _debug_overlay()
	if overlay == null or not overlay.show_debug_timings:
		return
	var direction := "down" if delta < 0 else "up"
	print("Render height %s: y=%d" % [direction, world.top_render_y])


func _record_instant_y_transition(from_y: int, target_y: int, delta: int, snapshot_before: Dictionary, mesh_targets: Array[Vector3i], mesh_ready_before: int) -> void:
	var generation_targets: Array[Vector3i] = _build_reveal_generation_targets(target_y)
	var generated: int = _count_generated_startup_chunks(generation_targets)
	var profile := {
		"target_chunk_y": _chunk_y_for_render_y(target_y),
		"mesh_total": mesh_targets.size(),
		"mesh_ready_before": mesh_ready_before,
		"mesh_ready_after": _count_ready_startup_chunks(mesh_targets),
		"generation_total": generation_targets.size(),
		"generation_ready_before": generated,
		"generation_ready_after": generated,
		"request_ms": 0.0,
		"generation_load_ms": 0.0,
		"mesh_wait_ms": 0.0,
		"total_blocked_ms": 0.0,
		"frames_waited": 0,
	}
	y_transition_profiler.record_transition(from_y, target_y, delta, false, profile, snapshot_before, y_transition_profiler.capture_snapshot())


func prepare_world_for_reveal(status_prefix: String) -> void:
	if world == null:
		return
	var view_rect: Rect2 = _get_stream_view_rect_for_y(world.top_render_y)
	var plane_y: float = float(world.top_render_y)
	await _ensure_render_y_ready(world.top_render_y, status_prefix)
	world.update_streaming(view_rect, plane_y, 0.0, _active_camera())


func _ensure_render_y_ready(render_y: int, status_prefix: String) -> Dictionary:
	var startup_start_usec: int = Time.get_ticks_usec()
	var mesh_targets: Array[Vector3i] = _build_reveal_chunk_targets(render_y)
	var profile := {
		"target_chunk_y": _chunk_y_for_render_y(render_y),
		"mesh_total": mesh_targets.size(),
		"mesh_ready_before": _count_ready_startup_chunks(mesh_targets),
		"mesh_ready_after": 0,
		"generation_total": 0,
		"generation_ready_before": 0,
		"generation_ready_after": 0,
		"request_ms": 0.0,
		"generation_load_ms": 0.0,
		"mesh_wait_ms": 0.0,
		"total_blocked_ms": 0.0,
		"frames_waited": 0,
	}
	if mesh_targets.is_empty():
		_set_loading_progress(1, 1)
		profile["mesh_ready_after"] = 0
		last_startup_load_metrics = {
			"startup_request_ms": 0.0,
			"startup_generation_load_ms": 0.0,
			"startup_ready_ms": float(Time.get_ticks_usec() - startup_start_usec) / 1000.0,
		}
		last_render_y_ready_profile = profile
		return profile

	var generation_targets: Array[Vector3i] = _build_reveal_generation_targets(render_y)
	var generation_total: int = generation_targets.size()
	var mesh_total: int = mesh_targets.size()
	profile["generation_total"] = generation_total
	profile["generation_ready_before"] = _count_generated_startup_chunks(generation_targets)
	var request_start_usec: int = Time.get_ticks_usec()
	_request_startup_chunk_generation(generation_targets, false)
	var request_ms: float = float(Time.get_ticks_usec() - request_start_usec) / 1000.0
	profile["request_ms"] = request_ms
	var meshes_queued := false
	var mesh_queue_index: int = 0
	var generation_load_ms := 0.0
	var frames_waited := 0
	while true:
		_pump_startup_loading_work()
		var ready: int = _count_ready_startup_chunks(mesh_targets)
		var generated: int = _count_generated_startup_chunks(generation_targets)
		if not meshes_queued and generated >= generation_total:
			if generation_load_ms <= 0.0:
				generation_load_ms = float(Time.get_ticks_usec() - startup_start_usec) / 1000.0
			var processed: int = 0
			while mesh_queue_index < mesh_targets.size() and processed < STARTUP_MESH_QUEUE_BUDGET:
				var coord: Vector3i = mesh_targets[mesh_queue_index]
				_queue_startup_chunk_mesh(coord, true)
				mesh_queue_index += 1
				processed += 1
			if mesh_queue_index >= mesh_targets.size():
				meshes_queued = true
		_set_loading_progress(generated + ready, generation_total + mesh_total)
		_set_loading_status(_format_startup_loading_status(status_prefix, ready, mesh_total, generated, generation_total))
		if ready >= mesh_total:
			profile["mesh_ready_after"] = ready
			profile["generation_ready_after"] = generated
			break
		frames_waited += 1
		if scene_tree != null:
			await scene_tree.process_frame
	if generation_load_ms <= 0.0:
		generation_load_ms = float(Time.get_ticks_usec() - startup_start_usec) / 1000.0
	var total_ready_ms: float = float(Time.get_ticks_usec() - startup_start_usec) / 1000.0
	profile["generation_load_ms"] = generation_load_ms
	profile["mesh_wait_ms"] = maxf(total_ready_ms - generation_load_ms, 0.0)
	profile["total_blocked_ms"] = total_ready_ms
	profile["frames_waited"] = frames_waited
	last_startup_load_metrics = {
		"startup_request_ms": request_ms,
		"startup_generation_load_ms": generation_load_ms,
		"startup_ready_ms": total_ready_ms,
	}
	last_render_y_ready_profile = profile
	return profile


func _build_reveal_chunk_targets(render_y: int) -> Array[Vector3i]:
	return target_builder.build_reveal_chunk_targets(render_y)


func _build_reveal_generation_targets(render_y: int) -> Array[Vector3i]:
	return target_builder.build_reveal_generation_targets(render_y)


func _build_directional_y_prewarm_mesh_targets(render_y: int) -> Array[Vector3i]:
	return target_builder.build_directional_y_prewarm_mesh_targets(render_y)


func _build_directional_y_prewarm_generation_targets(render_y: int) -> Array[Vector3i]:
	return target_builder.build_directional_y_prewarm_generation_targets(render_y)


func _build_generation_bands_for_mesh_bands(mesh_bands: Array[int]) -> Array[int]:
	return target_builder.build_generation_bands_for_mesh_bands(mesh_bands)


func _chunk_y_for_render_y(render_y: int) -> int:
	return target_builder.chunk_y_for_render_y(render_y)


func _build_chunk_targets_for_bands(bands: Array[int]) -> Array[Vector3i]:
	return target_builder.build_chunk_targets_for_bands(bands)


func _build_all_world_chunk_targets() -> Array[Vector3i]:
	return target_builder.build_all_world_chunk_targets()

func _pump_startup_loading_work() -> int:
	if world == null:
		return 0
	var generated: int = 0
	if world.generator != null:
		generated = world.generator.process_generation_results(STARTUP_GENERATION_RESULT_BUDGET)
	if world.renderer != null:
		world.renderer.process_mesh_results(STARTUP_MESH_RESULT_BUDGET)
	return generated


func _request_startup_chunk_generation(targets: Array[Vector3i], queue_mesh_on_complete: bool, high_priority: bool = true) -> void:
	if world == null:
		return
	for coord in targets:
		var chunk: ChunkData = world.ensure_chunk(coord)
		if chunk == null:
			continue
		if not chunk.generated:
			world.request_chunk_generation_async(coord, high_priority, queue_mesh_on_complete)


func _queue_startup_chunk_mesh(coord: Vector3i, high_priority: bool) -> bool:
	if world == null or world.renderer == null:
		return false
	var chunk: ChunkData = world.get_chunk(coord)
	if chunk == null or not chunk.generated:
		return false
	if chunk.mesh_state == ChunkData.MESH_STATE_READY:
		return false
	if chunk.mesh_state == ChunkData.MESH_STATE_PENDING:
		if high_priority:
			world.renderer.queue_chunk_mesh_build(coord, _chunk_full_top_y(coord), false, true)
		return false
	world.renderer.queue_chunk_mesh_build(coord, _chunk_full_top_y(coord), false, high_priority)
	return true


func _queue_startup_chunk_mesh_cache(coord: Vector3i, high_priority: bool) -> bool:
	if world == null or world.renderer == null:
		return false
	var chunk: ChunkData = world.get_chunk(coord)
	if chunk == null or not chunk.generated:
		return false
	return world.renderer.queue_chunk_mesh_cache_build(coord, World.CHUNK_SIZE - 1, high_priority)


func _chunk_full_top_y(coord: Vector3i) -> int:
	return target_builder.chunk_full_top_y(coord)


func _count_cached_full_mesh_chunks(targets: Array[Vector3i]) -> int:
	if world == null or world.renderer == null:
		return 0
	var count := 0
	for coord in targets:
		var chunk: ChunkData = world.get_chunk(coord)
		if chunk != null and chunk.generated and world.renderer.has_cached_chunk_mesh(coord, World.CHUNK_SIZE - 1):
			count += 1
	return count


func _count_ready_startup_chunks(targets: Array[Vector3i]) -> int:
	if world == null:
		return 0
	var count := 0
	for coord in targets:
		var chunk: ChunkData = world.get_chunk(coord)
		if chunk != null and chunk.generated and chunk.mesh_state == ChunkData.MESH_STATE_READY:
			count += 1
	return count


func _count_generated_startup_chunks(targets: Array[Vector3i]) -> int:
	if world == null:
		return 0
	var count := 0
	for coord in targets:
		var chunk: ChunkData = world.get_chunk(coord)
		if chunk != null and chunk.generated:
			count += 1
	return count


func _is_render_y_ready(render_y: int) -> bool:
	var targets: Array[Vector3i] = _build_reveal_chunk_targets(render_y)
	return not targets.is_empty() and _count_ready_startup_chunks(targets) >= targets.size()


func _mark_prepared_bands(bands: Array[int]) -> void:
	for cy_value in bands:
		prepared_chunk_bands[int(cy_value)] = true


func _format_startup_loading_status(status_prefix: String, ready: int, mesh_total: int, generated: int, generation_total: int) -> String:
	var generation_left: int = maxi(generation_total - generated, 0)
	var draw_left: int = maxi(mesh_total - ready, 0)
	var percent := 0.0
	var total_work: int = generation_total + mesh_total
	if total_work > 0:
		percent = float(generated + ready) / float(total_work) * 100.0
	return "%s\nReady: %d / %d (%.0f%%)\nGeneration left: %d | Draw left: %d" % [
		status_prefix,
		ready,
		mesh_total,
		percent,
		generation_left,
		draw_left,
	]


func _schedule_directional_y_prewarm(delta: int, current_y: int) -> void:
	if world == null or delta == 0:
		return
	var direction: int = 1 if delta > 0 else -1
	var prewarm_y: int = clampi(
		current_y + direction * Y_DIRECTIONAL_PREWARM_BLOCKS_AHEAD,
		0,
		world.world_size_y - 1
	)
	if prewarm_y == current_y:
		_clear_directional_y_prewarm()
		return
	if prewarm_y == y_prewarm_render_y and direction == y_prewarm_direction:
		return
	y_prewarm_render_y = prewarm_y
	y_prewarm_direction = direction
	y_prewarm_generation_targets = _build_directional_y_prewarm_generation_targets(prewarm_y)
	y_prewarm_mesh_targets = _build_directional_y_prewarm_mesh_targets(prewarm_y)
	y_prewarm_mesh_index = 0
	y_prewarm_meshes_queued = false
	if y_prewarm_mesh_targets.is_empty():
		_clear_directional_y_prewarm()
		return
	_request_startup_chunk_generation(y_prewarm_generation_targets, false, false)


func _pump_directional_y_prewarm(world_started: bool) -> void:
	if world == null or not world_started:
		return
	if y_prewarm_mesh_targets.is_empty():
		return
	if world.generator != null:
		world.generator.process_generation_results(Y_DIRECTIONAL_PREWARM_GENERATION_RESULT_BUDGET)
	if world.renderer != null:
		world.renderer.process_mesh_results(Y_DIRECTIONAL_PREWARM_MESH_RESULT_BUDGET)
	var generated: int = _count_generated_startup_chunks(y_prewarm_generation_targets)
	if generated < y_prewarm_generation_targets.size():
		return
	if not y_prewarm_meshes_queued:
		var processed: int = 0
		while y_prewarm_mesh_index < y_prewarm_mesh_targets.size() and processed < Y_DIRECTIONAL_PREWARM_MESH_QUEUE_BUDGET:
			var coord: Vector3i = y_prewarm_mesh_targets[y_prewarm_mesh_index]
			_queue_startup_chunk_mesh(coord, false)
			y_prewarm_mesh_index += 1
			processed += 1
		if y_prewarm_mesh_index >= y_prewarm_mesh_targets.size():
			y_prewarm_meshes_queued = true
	if y_prewarm_meshes_queued:
		var ready: int = _count_ready_startup_chunks(y_prewarm_mesh_targets)
		if ready >= y_prewarm_mesh_targets.size():
			_clear_directional_y_prewarm()


func _clear_directional_y_prewarm() -> void:
	y_prewarm_generation_targets.clear()
	y_prewarm_mesh_targets.clear()
	y_prewarm_mesh_index = 0
	y_prewarm_render_y = -1
	y_prewarm_direction = 0
	y_prewarm_meshes_queued = false


func _reset_level_loading_state() -> void:
	prepared_chunk_bands.clear()
	background_warmup_queue.clear()
	last_startup_load_metrics.clear()
	last_render_y_ready_profile.clear()
	_clear_directional_y_prewarm()
	_clear_background_warmup_active()


func _schedule_background_level_warmup(center_cy: int) -> void:
	background_warmup_queue.clear()
	_clear_background_warmup_active()
	var seen: Dictionary = {}
	for distance: int in range(0, World.WORLD_CHUNKS_Y):
		var lower_cy: int = center_cy - distance
		var upper_cy: int = center_cy + distance
		for cy_value in [lower_cy, upper_cy]:
			var cy: int = int(cy_value)
			if cy < 0 or cy >= World.WORLD_CHUNKS_Y:
				continue
			if seen.has(cy):
				continue
			seen[cy] = true
			if prepared_chunk_bands.has(cy):
				continue
			background_warmup_queue.append(cy)


func _pump_background_level_warmup(world_started: bool) -> void:
	if world == null or not world_started:
		return
	if background_warmup_queue.is_empty() and background_warmup_mesh_targets.is_empty():
		return
	if world.generator != null:
		world.generator.process_generation_results(BACKGROUND_WARMUP_GENERATION_RESULT_BUDGET)
	if world.renderer != null:
		world.renderer.process_mesh_results_time_budget(
			BACKGROUND_WARMUP_MESH_RESULT_TIME_BUDGET_MS,
			BACKGROUND_WARMUP_MESH_RESULT_BUDGET
		)
	if background_warmup_mesh_targets.is_empty():
		_begin_next_background_warmup_band()
		if background_warmup_mesh_targets.is_empty():
			return
	var generated: int = _count_generated_startup_chunks(background_warmup_generation_targets)
	if generated < background_warmup_generation_targets.size():
		return
	if not background_warmup_meshes_queued:
		var processed: int = 0
		while background_warmup_mesh_index < background_warmup_mesh_targets.size() and processed < BACKGROUND_WARMUP_MESH_QUEUE_BUDGET:
			var coord: Vector3i = background_warmup_mesh_targets[background_warmup_mesh_index]
			_queue_startup_chunk_mesh_cache(coord, false)
			background_warmup_mesh_index += 1
			processed += 1
		if background_warmup_mesh_index >= background_warmup_mesh_targets.size():
			background_warmup_meshes_queued = true
	if background_warmup_meshes_queued:
		var ready: int = _count_cached_full_mesh_chunks(background_warmup_mesh_targets)
		if ready >= background_warmup_mesh_targets.size():
			prepared_chunk_bands[background_warmup_band] = true
			_clear_background_warmup_active()


func _begin_next_background_warmup_band() -> void:
	while not background_warmup_queue.is_empty():
		var cy: int = int(background_warmup_queue.pop_front())
		if cy < 0 or cy >= World.WORLD_CHUNKS_Y:
			continue
		if _is_chunk_band_cached(cy):
			prepared_chunk_bands[cy] = true
			continue
		var mesh_bands: Array[int] = []
		mesh_bands.append(cy)
		var generation_bands: Array[int] = _build_generation_bands_for_mesh_bands(mesh_bands)
		background_warmup_generation_targets = _build_chunk_targets_for_bands(generation_bands)
		background_warmup_mesh_targets = _build_chunk_targets_for_bands(mesh_bands)
		background_warmup_mesh_index = 0
		background_warmup_band = cy
		background_warmup_meshes_queued = false
		_request_startup_chunk_generation(background_warmup_generation_targets, false)
		return


func _clear_background_warmup_active() -> void:
	background_warmup_generation_targets.clear()
	background_warmup_mesh_targets.clear()
	background_warmup_mesh_index = 0
	background_warmup_band = -1
	background_warmup_meshes_queued = false


func _is_chunk_band_cached(cy: int) -> bool:
	var bands: Array[int] = []
	bands.append(cy)
	var targets: Array[Vector3i] = _build_chunk_targets_for_bands(bands)
	return not targets.is_empty() and _count_cached_full_mesh_chunks(targets) >= targets.size()


func _debug_overlay() -> DebugOverlay:
	return debug_overlay


func _active_camera() -> Camera3D:
	return camera


func _get_stream_view_rect_for_y(render_y: int) -> Rect2:
	return target_builder.get_stream_view_rect_for_y(render_y)


func _set_loading_progress(ready: int, total: int) -> void:
	if loading_progress_callback.is_valid():
		loading_progress_callback.call(ready, total)


func _set_loading_status(text: String) -> void:
	if loading_status_callback.is_valid():
		loading_status_callback.call(text)


func _show_loading_screen(text: String) -> void:
	if show_loading_callback.is_valid():
		show_loading_callback.call(text)


func _hide_loading_screen() -> void:
	if hide_loading_callback.is_valid():
		hide_loading_callback.call()


func _set_world_draw_enabled(enabled: bool) -> void:
	if world_draw_callback.is_valid():
		world_draw_callback.call(enabled)
