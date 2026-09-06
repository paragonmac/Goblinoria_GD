extends SceneTree

const Recorder = preload("res://scripts/diagnostics/passive_performance_recorder.gd")
const Writer = preload("res://scripts/diagnostics/passive_performance_writer.gd")
var _checks := 0
var _errors: Array[String] = []
var _root := ""
var _outputs: Array[String] = []


func _init() -> void:
	_root = ProjectSettings.globalize_path("res://.local-passive-recorder-test-%d-%d" % [OS.get_process_id(), Time.get_ticks_usec()])
	_test_reports_and_statistics()
	_test_segments_and_worlds()
	_test_windows()
	_test_ring_and_registry_bounds()
	_test_writer_limits()
	_test_errors_and_restart()
	_test_incomplete_capture()
	_test_metadata_and_overhead()
	_cleanup()
	if _errors.is_empty():
		print("PASSIVE_RECORDER_CORE_OK: %d checks" % _checks)
		quit(0)
	else:
		for error in _errors:
			push_error(error)
		quit(1)


func _check(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_errors.append(message)


func _start(limits: Dictionary = {}) -> RefCounted:
	var recorder = Recorder.new()
	recorder.test_limits = limits
	_check(recorder.start({"seed": 42, "revision": "core-test"}, 0, _root), "capture starts")
	if not recorder.output_path.is_empty():
		_outputs.append(recorder.output_path)
	return recorder


func _frame(recorder: RefCounted, now: int, update_ms: float = 2.0) -> void:
	recorder.begin_frame(0.016, now)
	recorder.end_frame(update_ms, now + 100)
	recorder.pump_output(now + 200)


func _json(path: String) -> Dictionary:
	var file := FileAccess.open(path, FileAccess.READ)
	_check(file != null, "report is readable: " + path.get_file())
	if file == null:
		return {}
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	file.close()
	_check(parsed is Dictionary, "summary is valid JSON")
	return parsed if parsed is Dictionary else {}


func _events(path: String) -> Array:
	var result: Array = []
	var file := FileAccess.open(path.path_join("events.jsonl"), FileAccess.READ)
	_check(file != null, "event file opens")
	if file == null:
		return result
	while not file.eof_reached():
		var line := file.get_line()
		if line.is_empty():
			continue
		var value: Variant = JSON.parse_string(line)
		_check(value is Dictionary, "event line is valid JSON")
		if value is Dictionary:
			result.append(value)
	file.close()
	return result


func _csv(path: String) -> Array:
	var result: Array = []
	var file := FileAccess.open(path, FileAccess.READ)
	_check(file != null, "CSV opens: " + path.get_file())
	if file == null:
		return result
	var header := file.get_csv_line()
	while not file.eof_reached():
		var fields := file.get_csv_line()
		if fields.size() == 1 and fields[0].is_empty():
			continue
		_check(fields.size() == header.size(), "CSV row has header field count")
		if fields.size() != header.size():
			continue
		var row := {}
		for i in range(header.size()):
			row[header[i]] = fields[i]
		result.append(row)
	file.close()
	return result


func _test_reports_and_statistics() -> void:
	var recorder = _start()
	_check(not recorder.start({}, 0, _root), "second start cannot overwrite active capture")
	_check(not _json(recorder.output_path.path_join("summary.json")).completed, "initial summary explicitly incomplete")
	for name in ["summary.md", "summary.json", "samples.csv", "events.jsonl", "spike_frames.csv"]:
		_check(FileAccess.file_exists(recorder.output_path.path_join(name)), "all five reports created: " + name)
	_check(recorder.wants_workload_sample(0), "initial workload sample wanted")
	recorder.sample_workload({"workers": 4, "path_queue": null, "camera_x": 1.25}, 0)
	_check(not recorder.wants_workload_sample(999999), "workload sample rate limited")
	_check(recorder.wants_workload_sample(1000000), "one-second workload sample due")
	recorder.begin_frame(0.016, 0)
	recorder.add_timing("World.workers", 3.0)
	recorder.add_timing("World.workers", 5.0)
	recorder.add_timing("Path.search_ms", 7.0)
	recorder.add_counter("Path.success", 2)
	recorder.end_frame(10.0, 100)
	_check(recorder._writer.bytes_written == 0, "end_frame does not pump output")
	recorder.pump_output(200)
	var times := [1000, 34300, 84300, 184300, 1184300, 2184400]
	for now in times:
		_frame(recorder, now)
	recorder.mark_event("quoted", {"text": "comma, quote\" newline\n"}, 2200000)
	recorder.stop("manual", 2300000)
	var summary := _json(recorder.output_path.path_join("summary.json"))
	_check(summary.completed, "normal stop finalizes capture")
	_check(summary.format_version == 1, "versioned report")
	_check(summary.gameplay_frames.count == 6, "only intervals, not first frame, counted")
	_check(is_equal_approx(float(summary.gameplay_frames.mean_ms), 2184.4 / 6.0), "exact interval mean")
	_check(is_equal_approx(float(summary.gameplay_frames.max_ms), 1000.1), "exact maximum preserves overflow")
	_check(summary.gameplay_frames.histogram_1ms_upper_bounds[34] == 1, "fractional histogram uses upper-bound bin")
	_check(summary.gameplay_frames.histogram_1ms_upper_bounds[1000] == 1, "1000 ms is not overflow")
	_check(summary.gameplay_frames.histogram_overflow_count == 1, "greater than 1000 ms is overflow")
	_check(summary.gameplay_frames.median_ms == 50, "median rank correct")
	_check(summary.gameplay_frames.p95_ms == null, "overflow percentile is unavailable, not clipped")
	_check(summary.gameplay_frames.slow_frames.over_33_3_ms == 4, "strict 33.3 ms threshold")
	_check(summary.gameplay_frames.slow_frames.over_50_ms == 3, "strict 50 ms threshold")
	_check(summary.gameplay_frames.slow_frames.over_100_ms == 2, "strict 100 ms threshold")
	_check(summary.timings_ms_by_segment["gameplay/World.workers"].count == 2, "timing denominator retained")
	_check(summary.timings_ms_by_segment["gameplay/World.workers"].sum == 8, "timing sums correct")
	_check(summary.counters_by_segment["gameplay/Path.success"] == 2, "async outcome counts retained")
	_check(summary.timings_ms_by_segment["gameplay/Main.update_ms"].max == 10, "async search not added to measured Main time")
	_check(summary.segment_durations_usec.gameplay == 2300000, "segment duration exact")
	_check(summary.overhead.collection_usec >= 0 and summary.overhead.write_usec >= 0, "overhead separately reported")
	var samples := _csv(recorder.output_path.path_join("samples.csv"))
	var missing_found := false
	var workers_found := false
	for row in samples:
		if row.metric == "path_queue":
			missing_found = row.value == "unavailable"
		if row.metric == "World.workers":
			workers_found = row.mean == "4.0" or row.mean == "4"
	_check(missing_found, "missing workload never converted to zero")
	_check(workers_found, "aggregate CSV contains count-weighted mean")
	var events := _events(recorder.output_path)
	_check(events[-1].name == "capture_stopped", "normal stop event recorded")
	var original := FileAccess.get_file_as_string(recorder.output_path.path_join("summary.json"))
	recorder.stop("second stop", 99999999)
	_check(FileAccess.get_file_as_string(recorder.output_path.path_join("summary.json")) == original, "stop is idempotent")
	_check(is_equal_approx(recorder.get_status(99999999).elapsed_sec, 2.3), "elapsed freezes after stop")


func _test_segments_and_worlds() -> void:
	var recorder = _start()
	_frame(recorder, 0)
	_frame(recorder, 16000)
	recorder.begin_frame(0.016, 32000)
	recorder.set_segment("menu", 33000)
	recorder.end_frame(1.0, 34000)
	recorder.mark_moment(35000)
	_frame(recorder, 100000)
	_frame(recorder, 300000)
	recorder.set_segment("saving", 400000)
	recorder.mark_event("save_finished", {"success": true}, 500000)
	recorder.set_segment("loading", 600000)
	recorder.mark_event("load_finished", {"success": false}, 700000)
	recorder.set_segment("unfocused", 800000)
	recorder.set_segment("loading", 900000)
	recorder.set_segment("gameplay", 1000000)
	_frame(recorder, 1100000)
	_frame(recorder, 1116000)
	recorder.sample_workload({"mesh_cache_hits": 90}, 1117000)
	recorder.begin_world({"seed": 99}, 1200000)
	_check(recorder.wants_workload_sample(1200000), "world change resets workload sampling baseline")
	_check(recorder._workload.is_empty(), "world change clears previous counters snapshot")
	recorder.sample_workload({"mesh_cache_hits": 0}, 1200000)
	_frame(recorder, 2000000)
	_frame(recorder, 2016000)
	recorder.stop("manual", 2100000)
	var summary := _json(recorder.output_path.path_join("summary.json"))
	_check(summary.gameplay_frames.count == 3, "cross-segment/cross-world/menu intervals excluded")
	_check(summary.gameplay_frames.max_ms == 16, "menu stalls never become gameplay stalls")
	_check(summary.segment_durations_usec.unfocused == 100000, "focus duration separated")
	_check(summary.worlds.size() == 1 and summary.worlds[0].world_id == 1, "world metadata and ID retained")
	_check(summary.world_durations_usec["0"] == 1200000 and summary.world_durations_usec["1"] == 900000, "world durations include their segments without cross-world carryover")
	var rows := _csv(recorder.output_path.path_join("spike_frames.csv"))
	_check(rows.size() == 2, "manual menu window captures real menu frames only")
	for row in rows:
		_check(int(row.segment_id) == 1, "spike history does not cross segment boundary")
		_check(int(row.timestamp_usec) >= 100000, "manual marker does not fabricate frame")
	var events := _events(recorder.output_path)
	var save_ok := false
	var load_failed := false
	for event in events:
		if event.name == "save_finished":
			save_ok = event.details.success
		if event.name == "load_finished":
			load_failed = not event.details.success
	_check(save_ok and load_failed, "success/failure event payloads survive output")


func _test_windows() -> void:
	var recorder = _start()
	for i in range(101):
		_frame(recorder, i * 50000)
	# Continuous threshold hits merge but cannot extend a window beyond ten s.
	for i in range(101, 205):
		_frame(recorder, i * 50000)
	_check(recorder._window_id == 1, "automatic windows obey cooldown after cap")
	_check(not recorder._window_open, "continuous spikes close at ten-second cap")
	recorder.mark_moment(10300000)
	_check(recorder._window_id == 2, "manual marker bypasses automatic cooldown")
	recorder.mark_moment(10400000)
	_check(recorder._window_id == 2, "overlapping manual windows merge")
	_frame(recorder, 12500000)
	recorder.stop("manual", 12600000)
	var events := _events(recorder.output_path)
	var manual_count := 0
	for event in events:
		if event.name == "manual_marker":
			manual_count += 1
		if event.name == "window_finished":
			_check(event.details.end_usec - event.details.history_start_usec <= 10000000, "window duration is bounded")
	_check(manual_count == 2, "all manual markers survive merging/cooldown")
	var rows := _csv(recorder.output_path.path_join("spike_frames.csv"))
	var seen := {}
	for row in rows:
		var key: String = row.window_id + "/" + row.timestamp_usec
		_check(not seen.has(key), "each frame appears at most once per window")
		seen[key] = true
		_check(JSON.parse_string(row.timings_json) is Dictionary, "frame timings JSON embedded in CSV parses")
	var summary := _json(recorder.output_path.path_join("summary.json"))
	_check(summary.gameplay_frames.count == 205, "all spikes counted even while detail capture is cooling down")


func _test_ring_and_registry_bounds() -> void:
	var recorder = _start({"ring_frames": 4})
	for i in range(12):
		_frame(recorder, i * 1000)
	_check(recorder._ring_size == 4 and recorder._ring.size() == 4, "ring storage fixed at limit")
	recorder.mark_moment(12000)
	for i in range(180):
		recorder.add_timing("metric_%d" % i, 1)
		recorder.add_counter("counter_%d" % i)
	var workload := {}
	for i in range(100):
		workload["field_%d" % i] = i
	recorder.sample_workload(workload, 13000)
	_check(recorder._timing_labels.size() == 128, "timing registry bounded")
	_check(recorder._counter_labels.size() == 128, "counter registry bounded")
	_check(recorder._workload.size() == 64, "workload registry bounded")
	recorder.mark_event("bounded", {"large": "x".repeat(100000)}, 14000)
	recorder.stop("manual", 15000)
	var summary := _json(recorder.output_path.path_join("summary.json"))
	_check(summary.history_shortened_frames == 8, "shortened history disclosed")
	_check(summary.rejected_metric_samples > 0, "registry omissions disclosed")
	var rows := _csv(recorder.output_path.path_join("spike_frames.csv"))
	_check(rows.size() == 4, "manual window exports only retained frames")


func _test_writer_limits() -> void:
	var writer = Writer.new()
	writer.pending_limit = 256
	writer.pump_limit = 64
	_check(writer.open_reports(_root), "writer fixture opens")
	_outputs.append(writer.output_path)
	_check(writer.enqueue("spike_frames.csv", "d".repeat(200) + "\n", true), "detail enqueued")
	_check(writer.enqueue("events.jsonl", "e".repeat(100) + "\n"), "essential displaces detail")
	_check(writer.dropped_detail_records == 1, "detail eviction counted")
	writer.pump()
	_check(writer.bytes_written == 64 and writer.pending_bytes == 37, "pump writes no more than byte budget")
	writer.pump()
	writer.flush()
	_check(FileAccess.get_file_as_string(writer.output_path.path_join("events.jsonl")) == "e".repeat(100) + "\n", "partial byte writes reconstruct record")
	writer.enqueue("spike_frames.csv", "z".repeat(200), true)
	writer.pump(10)
	_check(not writer.enqueue("events.jsonl", "q".repeat(200)), "partially written detail cannot be silently truncated")
	_check(not writer.last_error.is_empty(), "essential overflow is fatal and explicit")
	writer.close()
	var recorder = _start({"capture_bytes": 40000, "summary_bytes": 32768})
	for i in range(100):
		if not recorder.enabled:
			break
		recorder.mark_event("large", {"text": "x".repeat(400)}, i * 1000)
		recorder.pump_output(i * 1000)
	_check(not recorder.enabled, "capture stops automatically at file limit")
	var summary := _json(recorder.output_path.path_join("summary.json"))
	_check(summary.reason == "size_limit" and summary.completed, "size-limit stop is finalized with explicit reason")
	var bytes := 0
	for name in ["summary.json", "summary.md", "samples.csv", "events.jsonl", "spike_frames.csv"]:
		var file := FileAccess.open(recorder.output_path.path_join(name), FileAccess.READ)
		bytes += file.get_length()
		file.close()
	_check(bytes <= 40000, "all five files respect total capture size including reserve")


func _test_errors_and_restart() -> void:
	var failed = Recorder.new()
	failed.test_fail_open = true
	_check(not failed.start({}, 0, _root), "injected open failure returns false")
	_check(not failed.enabled and not failed.last_error.is_empty(), "open failure is visible without exception")
	var recorder = _start()
	recorder.test_fail_after_bytes = 0
	recorder.pump_output(100)
	_check(not recorder.enabled and not recorder.last_error.is_empty(), "mid-recording write failure disables capture")
	_check(not _json(recorder.output_path.path_join("summary.json")).completed, "write failure leaves incomplete manifest")
	var previous: String = recorder.output_path
	recorder.test_fail_after_bytes = -1
	_check(recorder.start({}, 1000, _root), "capture can restart after failure")
	_outputs.append(recorder.output_path)
	_check(recorder.output_path != previous and recorder.last_error.is_empty(), "restart uses unique directory and clears error")
	_check(recorder._frame_count == 0 and recorder._world_id == 0, "restart resets session state")
	recorder.stop("manual", 2000)
	var backlog = _start({"pending_bytes": 2048})
	for i in range(100):
		backlog.mark_event("essential", {"text": "x".repeat(400)}, i)
	_check(not backlog.enabled and not backlog.last_error.is_empty(), "essential backlog stops recorder")
	var state := _json(backlog.output_path.path_join("summary.json"))
	_check(not state.completed, "backlog failure cannot claim a complete capture")


func _test_incomplete_capture() -> void:
	var recorder = _start()
	_frame(recorder, 0)
	_frame(recorder, 16000)
	recorder._writer.flush()
	var path: String = recorder.output_path
	recorder._writer.close()
	recorder = null
	_check(not _json(path.path_join("summary.json")).completed, "abandoned capture remains explicitly incomplete")


func _test_metadata_and_overhead() -> void:
	var recorder = Recorder.new()
	var metadata := {
		"engine": {"version": "4.7.2", "build": "x".repeat(400)},
		"hardware": {"cpu": "c".repeat(400), "gpu": "g".repeat(400), "driver": "d".repeat(400)},
		"description": "r".repeat(400), "viewport": {"width": 1920, "height": 1080},
		"world": {"seed": 73, "size": 256}, "diagnostics": {"overlay": false, "worker_trace": false},
	}
	_check(recorder.start(metadata, 0, _root), "metadata fixture starts")
	_outputs.append(recorder.output_path)
	var initial := _json(recorder.output_path.path_join("summary.json"))
	_check(initial.metadata.world.seed == 73 and not initial.metadata.diagnostics.overlay, "late world/diagnostics metadata survives hardware data")
	_check(initial.metadata.revision == "unknown", "revision never fabricated")
	var before: int = recorder.get_collection_usec()
	for i in range(100):
		recorder.add_timing("World.update_streaming", 1.0)
		recorder.add_counter("generation_applied")
	_check(recorder.get_collection_usec() >= before, "collection accessor is monotonic and available for Main subtraction")
	for label in ["Main.update_camera", "Main.handle_mouse", "Main.update_hover_preview", "Main.update_info_hover", "Main.pump_directional_y_prewarm", "Main.pump_background_level_warmup"]:
		recorder.add_timing(label, 2.0)
		_check(recorder._timing_labels.has(label), "shared Main label accepted: " + label)
	recorder.add_timing("Path.completed.search_ms", 3.0)
	recorder.add_timing("Mesh.completed.build_ms", 4.0)
	recorder.add_timing("Mesh.apply_ms", 1.0)
	recorder.add_timing("Mesh.sync_build_ms", 2.0)
	var async_table: String = "\n".join(recorder._timing_table(true))
	var main_table: String = "\n".join(recorder._timing_table(false))
	_check("Mesh.completed.build_ms" in async_table and "Path.completed.search_ms" in async_table, "background work appears in asynchronous table")
	_check(not "Mesh.apply_ms" in async_table and not "Mesh.sync_build_ms" in async_table, "synchronous mesh work is never labeled background work")
	_check("Mesh.apply_ms" in main_table and "Mesh.sync_build_ms" in main_table, "synchronous mesh costs remain visible")
	recorder.stop("manual", 1000000)
	var markdown := FileAccess.get_file_as_string(recorder.output_path.path_join("summary.md"))
	for text in ["Segment durations", "Observed timing contributors", "World.update_streaming", "Slow intervals", "world", "Capture quality", "revision", "Initial world 0: 1.000"]:
		_check(text in markdown, "readable report includes measured context: " + text)
	var summary := _json(recorder.output_path.path_join("summary.json"))
	_check(summary.gameplay_frames.count == 0 and summary.gameplay_frames.median_ms == null, "no frames yields unavailable percentile, not fake frames")


func _cleanup() -> void:
	# Only known report files in unique directories created by this test.
	for path in _outputs:
		if not path.begins_with(_root + "/") and not path.begins_with(_root + "\\"):
			_check(false, "refusing cleanup outside unique test root")
			continue
		for name in ["summary.json", "summary.md", "samples.csv", "events.jsonl", "spike_frames.csv"]:
			var file_path: String = path.path_join(name)
			if FileAccess.file_exists(file_path):
				DirAccess.remove_absolute(file_path)
		DirAccess.remove_absolute(path)
	if DirAccess.dir_exists_absolute(_root):
		DirAccess.remove_absolute(_root)
