extends SceneTree
## Real streaming/visibility paths with deterministic fixtures, not a benchmark.

const RecorderScript = preload("res://scripts/diagnostics/passive_performance_recorder.gd")
const SPANS := ["Streaming.bounds_ms", "Streaming.reset_ms", "Streaming.partition_ms",
	"Streaming.enqueue_ms", "Streaming.process_queue_ms", "Streaming.render_zone_ms",
	"Streaming.height_anchor_ms", "RenderZone.snapshot_ms", "RenderZone.apply_ms", "RenderZone.adopt_ms"]
var failures := 0
var checks := 0


func _init() -> void:
	_run.call_deferred()


func _check(ok: bool, message: String) -> void:
	checks += 1
	if not ok:
		failures += 1
		push_error(message)


func _run() -> void:
	var baseline: Array = []
	for debug_enabled in [false, true]:
		for recording in [false, true]:
			var state := _exercise(debug_enabled, recording)
			if baseline.is_empty():
				baseline = state
			_check(state == baseline, "Timing sinks do not change queue/visibility state")
	if failures:
		push_error("Streaming timings failed: %d/%d" % [failures, checks])
		quit(1)
	else:
		print("Streaming timings OK (%d checks)" % checks)
		quit(0)


func _exercise(debug_enabled: bool, recording: bool) -> Array:
	var world := World.new()
	world.top_render_y = 0
	world.debug_profiler = DebugProfiler.new()
	world.debug_profiler.enabled = debug_enabled
	var recorder = RecorderScript.new()
	world.performance_recorder = recorder
	var test_root := OS.get_environment("TEMP").path_join("goblinoria-stream-timings-%d-%d" % [OS.get_process_id(), Time.get_ticks_usec()])
	if recording:
		_check(recorder.start({}, -1, test_root), "Recorder opens isolated reports")
		if not recorder.enabled:
			world.free()
			return []
		recorder.begin_frame(0.016)
	var renderer := WorldRenderer.new()
	renderer.use_async_meshing = false
	world.add_child(renderer)
	world.renderer = renderer
	renderer.initialize(world)
	var streaming := WorldStreaming.new(world)
	world.streaming = streaming
	streaming.stream_base_buffer_chunks = 0
	streaming.stream_buffer_view_scale = 0
	streaming.stream_vertical_margin_blocks = 0
	streaming.stream_lead_time = 0
	streaming.render_radius_chunks = 0
	streaming.stream_queue_budget = 3
	streaming.chunks_per_frame = 1
	_check(world.begin_performance_timing() >= 0 if debug_enabled or recording else world.begin_performance_timing() == -1,
		"Disabled timing returns sentinel")
	var rect := Rect2(0, 0, 7, 7)
	world.update_streaming(rect, 0, 0.1)
	_check(preload("res://tools/visibility_test_helpers.gd").settle(renderer), "First visibility request converges")
	_check(not streaming.chunk_build_queue.is_empty() and streaming.queue_head == 1, "Nonempty enqueue/process budgets execute")
	if debug_enabled:
		for label in SPANS:
			_check(world.debug_profiler.frame_data.has(label), "F4 receives " + label)
	world.debug_profiler.finish_frame()
	var before: Dictionary = recorder._session_timings.duplicate(true)
	world.update_streaming(rect, 0, 0.001)
	if recording:
		for label in ["Streaming.reset_ms", "Streaming.partition_ms", "Streaming.render_zone_ms"]:
			_check(recorder._session_timings["gameplay/" + label].count == before["gameplay/" + label].count, "Unchanged bounds skip " + label)
	# Same anchor but changed deep-band footprint must still reset traversal.
	world.update_streaming(rect, 0, 0.1, null, {0: Rect2(8, 0, 7, 7)})
	_check(preload("res://tools/visibility_test_helpers.gd").settle(renderer), "Band visibility request converges")
	streaming.throttle_idle_sec = 2
	streaming.throttle_stream_step_accum = 0
	streaming.render_plane_index = streaming._stream_render_plane_size()
	before = recorder._session_timings.duplicate(true)
	world.update_streaming(rect, 0, 0.001, null, {0: Rect2(8, 0, 7, 7)})
	if recording:
		_check(recorder._session_timings["gameplay/Streaming.enqueue_ms"].count == before["gameplay/Streaming.enqueue_ms"].count, "Throttled skip is not a zero sample")
	# Existing-node hide pass, including an already-hidden node and an
	# accepted coordinate with no node. No terrain/mesh generation required.
	var node := renderer.chunk_cache.ensure_chunk(Vector3i(9, 0, 9), World.CHUNK_SIZE)
	node.visible = false
	var chunk_count := world.chunks.size()
	var counts: Dictionary = recorder._session_counters.duplicate()
	var expected_hide_candidates := renderer.render_zone_visible.size() + 4
	renderer.update_render_zone(0, 1, 0, 1, 0, 0)
	_check(preload("res://tools/visibility_test_helpers.gd").settle(renderer), "Explicit view converges")
	renderer.update_render_zone(1, 0, 0, 1, 0, 0)
	_check(preload("res://tools/visibility_test_helpers.gd").settle(renderer), "Empty view converges")
	_check(world.chunks.size() == chunk_count and not node.visible, "Instrumented inspection loops do not generate terrain")
	_check(renderer.render_zone_visible.is_empty(), "Invalid bounds still hide cached nodes")
	if recording:
		for pair in [["refreshes", 2], ["candidates", 4], ["accepted_coords", 4], ["hide_candidates", expected_hide_candidates]]:
			var key: String = "gameplay/RenderZone." + pair[0]
			_check(int(recorder._session_counters.get(key, 0)) - int(counts.get(key, 0)) == pair[1], "Exact counter semantics: " + key)
	var camera := Camera3D.new()
	root.add_child(camera)
	camera.position = Vector3(0, 10, 20)
	camera.look_at(Vector3.ZERO)
	before = recorder._session_timings.duplicate(true)
	world.update_streaming(rect, 0, 0.1, camera, {0: Rect2(8, 0, 7, 7)})
	if recording:
		_check(recorder._session_timings["gameplay/Streaming.render_zone_ms"].count == before["gameplay/Streaming.render_zone_ms"].count + 1,
			"New camera triggers a refresh")
	before = recorder._session_timings.duplicate(true)
	world.update_streaming(rect, 0, 0.1, camera, {0: Rect2(8, 0, 7, 7)})
	if recording:
		_check(recorder._session_timings["gameplay/Streaming.render_zone_ms"].count == before["gameplay/Streaming.render_zone_ms"].count,
			"Unchanged camera skips visibility work")
	renderer.update_render_zone(100, 101, 100, 101, 0, 0, camera)
	_check(preload("res://tools/visibility_test_helpers.gd").settle(renderer), "Outside view converges")
	_check(renderer.render_zone_visible.is_empty(), "Instrumented camera culling rejects outside-frustum candidates")
	camera.free()
	var state: Array = [streaming.chunk_build_queue.duplicate(), streaming.queue_head,
		streaming.stream_plane_index, streaming.stream_layer_remaining, streaming.stream_pending,
		world.chunks.keys(), renderer.render_zone_visible.duplicate()]
	world.renderer = null
	before = recorder._session_timings.duplicate(true)
	world.update_streaming(rect, 0, 0.1)
	_check(before == recorder._session_timings, "Null renderer produces no spans")
	if recording:
		recorder.end_frame(1.0)
		recorder.stop()
		var summary: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(recorder.output_path.path_join("summary.json")))
		for label in SPANS:
			var stat: Dictionary = summary.timings_ms_by_segment.get("gameplay/" + label, {})
			_check(not stat.is_empty(), "Report retains " + label)
			if not stat.is_empty():
				_check(stat.count > 0 and is_finite(stat.sum) and stat.sum >= 0 and stat.max >= 0, "Finite nonnegative timing " + label)
		_check(summary.timings_ms_by_segment["gameplay/Streaming.reset_ms"].count == 2, "Initial and band-change resets recorded once")
		_check(FileAccess.get_file_as_string(recorder.output_path.path_join("samples.csv")).contains("RenderZone.apply_ms"), "Detailed labels reach periodic CSV")
		# Only remove this fixture's explicitly created files and directories.
		for name in ["summary.json", "summary.md", "samples.csv", "events.jsonl", "spike_frames.csv"]:
			DirAccess.remove_absolute(recorder.output_path.path_join(name))
		DirAccess.remove_absolute(recorder.output_path)
		DirAccess.remove_absolute(test_root)
	else:
		_check(recorder._session_timings.is_empty() and recorder._session_counters.is_empty(), "Disabled recorder receives no metrics")
	if not debug_enabled:
		_check(world.debug_profiler.frame_data.is_empty(), "Hidden profiler receives no metrics")
	renderer._stop_mesh_worker()
	world.free()
	return state
