class_name PassivePerformanceRecorder
extends RefCounted

## Passive main-thread measurements only. Explicit timestamps make the core
## deterministic in tests; they never change the simulation's clock or workload.
# SEE-ADR-013: Recorder state, segment boundaries and output are main-thread owned.
const WriterScript = preload("res://scripts/diagnostics/passive_performance_writer.gd")
const FORMAT_VERSION := 1
const SEGMENTS := ["gameplay", "menu", "saving", "loading", "unfocused"]
const MAX_METRICS := 128
const MAX_WORKLOAD := 64
const MAX_WORLDS := 128
const SAMPLE_HEADER := "segment_id,world_id,start_usec,end_usec,segment,kind,metric,count,sum,mean,max,value\n"
const SPIKE_HEADER := "window_id,segment_id,world_id,timestamp_usec,frame_interval_ms,simulation_delta_ms,main_update_ms,timings_json\n"

var enabled: bool = false
var segment: String = "gameplay"
var last_error: String = ""
var output_path: String = ""

# Test-only overrides, read at start. Defaults are the production limits.
var test_limits: Dictionary = {}
var test_fail_open := false
var test_fail_after_bytes := -1:
	set(value):
		test_fail_after_bytes = value
		if _writer != null:
			_writer.fail_after_bytes = value

var _writer: RefCounted
var _metadata: Dictionary = {}
var _started := 0
var _stopped := 0
var _segment_started := 0
var _segment_id := 0
var _world_id := 0
var _worlds: Array = []
var _worlds_omitted := 0
var _world_started := 0
var _world_durations: Dictionary = {}
var _world_duration_omitted_usec := 0
var _durations: Dictionary = {}
var _bucket_started := 0
var _bucket_timings: Dictionary = {}
var _bucket_counters: Dictionary = {}
var _workload: Dictionary = {}
var _last_workload := -1
var _timing_labels: Dictionary = {}
var _counter_labels: Dictionary = {}
var _workload_labels: Dictionary = {}
var _session_timings: Dictionary = {}
var _session_counters: Dictionary = {}
var _unknown_metrics := 0
var _frame_started := -1
var _previous_frame := -1
var _frame_segment := -1
var _frame_world := -1
var _frame_interval := -1.0
var _frame_dt := 0.0
var _frame_timings: Dictionary = {}
var _histogram := PackedInt64Array()
var _frame_count := 0
var _frame_sum := 0.0
var _frame_max := 0.0
var _slow := {"over_33_3_ms": 0, "over_50_ms": 0, "over_100_ms": 0}
var _ring: Array = []
var _ring_head := 0
var _ring_size := 0
var _ring_limit := 4096
var _history_shortened := 0
var _window_id := 0
var _window_open := false
var _window_started := 0
var _window_until := 0
var _window_automatic := false
var _auto_ready := 0
var _last_detail_timestamp := -1
var _collection_usec := 0
var _write_usec := 0
var _pump_count := 0
var _last_flush := 0
var _finishing := false
var _summary: Dictionary = {}


func _now(value: int) -> int:
	return Time.get_ticks_usec() if value < 0 else value


func start(metadata: Dictionary, now_usec: int = -1, output_root: String = "user://diagnostics/gameplay") -> bool:
	if enabled:
		return false
	_reset()
	_started = _now(now_usec)
	_segment_started = _started
	_bucket_started = _started
	_last_flush = _started
	_world_started = _started
	_metadata = _bounded(metadata, 8192)
	if not _metadata.has("revision"):
		_metadata["revision"] = "unknown"
	for label in ["Main.update_ms", "simulation_delta_ms", "frame_interval_ms"]:
		_timing_labels[label] = true
	_writer = WriterScript.new()
	_writer.pending_limit = maxi(256, int(test_limits.get("pending_bytes", 4 * 1024 * 1024)))
	_writer.pump_limit = maxi(1, int(test_limits.get("pump_bytes", 64 * 1024)))
	_writer.capture_limit = maxi(2048, int(test_limits.get("capture_bytes", 128 * 1024 * 1024)))
	_writer.summary_reserve = maxi(1024, int(test_limits.get("summary_bytes", 1024 * 1024)))
	_writer.fail_open = test_fail_open
	_writer.fail_after_bytes = test_fail_after_bytes
	_ring_limit = clampi(int(test_limits.get("ring_frames", 4096)), 1, 4096)
	_ring.resize(_ring_limit)
	if not _writer.open_reports(output_root):
		last_error = _writer.last_error
		output_path = _writer.output_path
		return false
	output_path = _writer.output_path
	# Persist an incomplete manifest before any capture data. A crash must not
	# accidentally inherit a completed summary from another recording.
	if not _writer.write_summary(_make_summary(false, "recording", _started), _markdown(false, "recording")):
		last_error = _writer.last_error
		_writer.close()
		return false
	enabled = true
	_enqueue("samples.csv", SAMPLE_HEADER)
	_enqueue("spike_frames.csv", SPIKE_HEADER)
	mark_event("capture_started", {"metadata": _metadata}, _started)
	return enabled


func stop(reason: String = "manual", now_usec: int = -1) -> void:
	if not enabled or _finishing:
		return
	_finishing = true
	var now := _now(now_usec)
	_close_window(now)
	_flush_bucket(now)
	_add_duration(now)
	_add_world_duration(now)
	mark_event("capture_stopped", {"reason": reason}, now)
	enabled = false
	_stopped = now
	var write_start := Time.get_ticks_usec()
	_writer.pump(_writer.pending_bytes)
	_writer.flush()
	_write_usec += Time.get_ticks_usec() - write_start
	if not _writer.last_error.is_empty():
		last_error = _writer.last_error
	var complete := last_error.is_empty()
	_summary = _make_summary(complete, reason, now)
	if not _writer.write_summary(_summary, _markdown(complete, reason)):
		last_error = _writer.last_error
	_writer.close()
	_ring.clear()
	_ring_size = 0
	_finishing = false


func set_segment(name: String, now_usec: int = -1) -> void:
	if not enabled or name == segment:
		return
	if name not in SEGMENTS:
		mark_event("invalid_segment", {"requested": name}, now_usec)
		return
	var overhead := Time.get_ticks_usec()
	var now := _now(now_usec)
	_transition(now)
	segment = name
	_segment_id += 1
	_emit_event("segment_changed", {"segment": segment}, now)
	_collection_usec += Time.get_ticks_usec() - overhead
	_check_writer(now)


func begin_world(metadata: Dictionary, now_usec: int = -1) -> void:
	if not enabled:
		return
	var overhead := Time.get_ticks_usec()
	var now := _now(now_usec)
	_transition(now)
	_add_world_duration(now)
	_world_id += 1
	_segment_id += 1
	var entry := {"world_id": _world_id, "timestamp_usec": now, "metadata": _bounded(metadata)}
	if _worlds.size() < MAX_WORLDS:
		_worlds.append(entry)
	else:
		_worlds_omitted += 1
	_emit_event("world_started", entry, now)
	_collection_usec += Time.get_ticks_usec() - overhead
	_check_writer(now)


func begin_frame(dt: float, now_usec: int = -1) -> void:
	if not enabled:
		return
	var overhead := Time.get_ticks_usec()
	var now := _now(now_usec)
	_poll_bucket(now)
	_frame_interval = -1.0
	if _previous_frame >= 0 and now >= _previous_frame:
		_frame_interval = float(now - _previous_frame) / 1000.0
	_previous_frame = now
	_frame_started = now
	_frame_segment = _segment_id
	_frame_world = _world_id
	_frame_dt = maxf(0.0, dt * 1000.0) if is_finite(dt) else 0.0
	_frame_timings.clear()
	_collection_usec += Time.get_ticks_usec() - overhead
	_check_writer(now)


func end_frame(main_update_ms: float, now_usec: int = -1) -> void:
	if not enabled or _frame_started < 0:
		return
	var overhead := Time.get_ticks_usec()
	var now := _now(now_usec)
	if _frame_segment == _segment_id and _frame_world == _world_id:
		_record_timing("Main.update_ms", main_update_ms)
		_record_timing("simulation_delta_ms", _frame_dt)
		if segment == "gameplay" and _frame_interval >= 0:
			_record_interval(_frame_interval)
		var row := {
			"timestamp_usec": _frame_started, "segment_id": _segment_id,
			"world_id": _world_id, "frame_interval_ms": _frame_interval,
			"simulation_delta_ms": _frame_dt,
			"main_update_ms": maxf(0.0, main_update_ms) if is_finite(main_update_ms) else 0.0,
			"timings": _frame_timings.duplicate(),
		}
		if _window_open and _frame_started > _window_until:
			_close_window(_frame_started)
		_ring_push(row)
		if segment == "gameplay" and _frame_interval >= 50.0 and _frame_started >= _auto_ready:
			_trigger_window(_frame_started, true)
		if _window_open:
			_write_detail(row)
	_frame_started = -1
	_collection_usec += Time.get_ticks_usec() - overhead
	# Intentionally no pump here: Main calls pump_output after its bookkeeping.
	_check_writer(now)


func add_timing(label: String, ms: float) -> void:
	var overhead := Time.get_ticks_usec()
	_record_timing(label, ms)
	if enabled:
		_collection_usec += Time.get_ticks_usec() - overhead


func _record_timing(label: String, ms: float) -> void:
	if not enabled or not is_finite(ms) or ms < 0.0:
		return
	if not _register(_timing_labels, label):
		return
	_add_stat(_bucket_timings, label, ms)
	_add_stat(_session_timings, segment + "/" + label, ms)
	if _frame_started >= 0:
		_frame_timings[label] = float(_frame_timings.get(label, 0.0)) + ms


func add_counter(label: String, amount: int = 1) -> void:
	var overhead := Time.get_ticks_usec()
	_record_counter(label, amount)
	if enabled:
		_collection_usec += Time.get_ticks_usec() - overhead


func _record_counter(label: String, amount: int = 1) -> void:
	if not enabled or not _register(_counter_labels, label):
		return
	_bucket_counters[label] = int(_bucket_counters.get(label, 0)) + amount
	var key := segment + "/" + label
	_session_counters[key] = int(_session_counters.get(key, 0)) + amount


func sample_workload(values: Dictionary, now_usec: int = -1) -> void:
	if not enabled:
		return
	var overhead := Time.get_ticks_usec()
	_last_workload = _now(now_usec)
	_workload.clear()
	for key in values:
		var label := str(key)
		if not _register(_workload_labels, label, MAX_WORKLOAD):
			continue
		# Null means unavailable, not zero. Numeric vectors are supplied by Main
		# as separate camera axes; no live object references enter the recorder.
		var value: Variant = values[key]
		if value == null or value is int or value is bool:
			_workload[label] = value
		elif value is float and is_finite(value):
			_workload[label] = value
		elif value is String:
			_workload[label] = value.left(256)
		else:
			_workload[label] = null
	_collection_usec += Time.get_ticks_usec() - overhead


func wants_workload_sample(now_usec: int = -1) -> bool:
	return enabled and (_last_workload < 0 or _now(now_usec) - _last_workload >= 1000000)


func mark_event(name: String, details: Dictionary = {}, now_usec: int = -1) -> void:
	if not enabled:
		return
	var overhead := Time.get_ticks_usec()
	var now := _now(now_usec)
	_emit_event(name, details, now)
	_collection_usec += Time.get_ticks_usec() - overhead
	_check_writer(now)


func _emit_event(name: String, details: Dictionary, now: int) -> void:
	var data := {
		"timestamp_usec": now, "segment_id": _segment_id, "world_id": _world_id,
		"segment": segment, "name": name.left(128), "details": _bounded(details),
	}
	_enqueue("events.jsonl", JSON.stringify(data) + "\n")


func mark_moment(now_usec: int = -1) -> void:
	if not enabled:
		return
	var overhead := Time.get_ticks_usec()
	var now := _now(now_usec)
	_emit_event("manual_marker", {}, now)
	_trigger_window(now, false)
	_collection_usec += Time.get_ticks_usec() - overhead
	_check_writer(now)


func pump_output(now_usec: int = -1) -> void:
	if not enabled:
		return
	var now := _now(now_usec)
	var overhead := Time.get_ticks_usec()
	_writer.pump()
	if now - _last_flush >= 1000000:
		_writer.flush()
		_last_flush = now
	_write_usec += Time.get_ticks_usec() - overhead
	_pump_count += 1
	_check_writer(now)


func get_status(now_usec: int = -1) -> Dictionary:
	var end := _now(now_usec) if enabled else _stopped
	return {
		"enabled": enabled, "segment": segment,
		"elapsed_sec": maxf(0.0, float(end - _started) / 1000000.0),
		"last_error": last_error, "output_path": output_path,
		"reason": _summary.get("reason", "recording" if enabled else ""),
	}


func get_collection_usec() -> int:
	return _collection_usec


func _reset() -> void:
	enabled = false
	segment = "gameplay"
	last_error = ""
	output_path = ""
	_started = 0
	_stopped = 0
	_segment_id = 0
	_world_id = 0
	_worlds.clear()
	_worlds_omitted = 0
	_world_durations.clear()
	_world_duration_omitted_usec = 0
	_durations.clear()
	_bucket_timings.clear()
	_bucket_counters.clear()
	_workload.clear()
	_last_workload = -1
	_timing_labels.clear()
	_counter_labels.clear()
	_workload_labels.clear()
	_session_timings.clear()
	_session_counters.clear()
	_unknown_metrics = 0
	_frame_started = -1
	_previous_frame = -1
	_frame_segment = -1
	_frame_world = -1
	_frame_timings.clear()
	_histogram.resize(1002)
	_histogram.fill(0)
	_frame_count = 0
	_frame_sum = 0.0
	_frame_max = 0.0
	_slow = {"over_33_3_ms": 0, "over_50_ms": 0, "over_100_ms": 0}
	_ring.clear()
	_ring_head = 0
	_ring_size = 0
	_history_shortened = 0
	_window_id = 0
	_window_open = false
	_auto_ready = 0
	_last_detail_timestamp = -1
	_collection_usec = 0
	_write_usec = 0
	_pump_count = 0
	_finishing = false
	_summary.clear()


func _transition(now: int) -> void:
	_close_window(now)
	_flush_bucket(now)
	_add_duration(now)
	_segment_started = now
	_bucket_started = now
	_previous_frame = -1
	_frame_started = -1
	_ring_head = 0
	_ring_size = 0
	_ring.fill(null)
	_workload.clear()
	_last_workload = -1
	_auto_ready = 0


func _add_duration(now: int) -> void:
	_durations[segment] = int(_durations.get(segment, 0)) + maxi(0, now - _segment_started)
	_segment_started = now


func _add_world_duration(now: int) -> void:
	var elapsed := maxi(0, now - _world_started)
	if _world_id <= MAX_WORLDS:
		_world_durations[str(_world_id)] = int(_world_durations.get(str(_world_id), 0)) + elapsed
	else:
		_world_duration_omitted_usec += elapsed
	_world_started = now


func _register(registry: Dictionary, label: String, maximum: int = MAX_METRICS) -> bool:
	if registry.has(label):
		return true
	if label.is_empty() or label.length() > 96 or registry.size() >= maximum:
		_unknown_metrics += 1
		return false
	registry[label] = true
	return true


func _add_stat(destination: Dictionary, label: String, value: float) -> void:
	if not destination.has(label):
		destination[label] = {"count": 0, "sum": 0.0, "max": 0.0}
	var stat: Dictionary = destination[label]
	stat.count += 1
	stat.sum += value
	stat.max = maxf(stat.max, value)


func _record_interval(ms: float) -> void:
	_frame_count += 1
	_frame_sum += ms
	_frame_max = maxf(_frame_max, ms)
	var bin := 1001 if ms > 1000.0 else clampi(int(ceil(ms)), 0, 1000)
	_histogram[bin] += 1
	_record_timing("frame_interval_ms", ms)
	for pair in [[33.3, "over_33_3_ms"], [50.0, "over_50_ms"], [100.0, "over_100_ms"]]:
		if ms > float(pair[0]):
			_slow[pair[1]] += 1
			_record_counter(pair[1])


func _poll_bucket(now: int) -> void:
	if now - _bucket_started >= 1000000:
		_flush_bucket(now)


func _flush_bucket(now: int) -> void:
	if _writer == null:
		return
	for label in _bucket_timings:
		var stat: Dictionary = _bucket_timings[label]
		_sample_row(now, "timing_ms", label, stat.count, stat.sum, float(stat.sum) / int(stat.count), stat.max, null)
	for label in _bucket_counters:
		_sample_row(now, "counter", label, 1, _bucket_counters[label], null, null, _bucket_counters[label])
	for label in _workload:
		_sample_row(now, "workload", label, 1, null, null, null, _workload[label])
	if _bucket_timings.is_empty() and _bucket_counters.is_empty() and _workload.is_empty():
		_sample_row(now, "period", "elapsed_ms", 1, null, null, null, float(maxi(0, now - _bucket_started)) / 1000.0)
	_bucket_timings.clear()
	_bucket_counters.clear()
	_bucket_started = now


func _sample_row(now: int, kind: String, label: String, count: int, total: Variant, mean: Variant, maximum: Variant, value: Variant) -> void:
	_enqueue("samples.csv", _csv([_segment_id, _world_id, _bucket_started, now, segment, kind, label, count, total, mean, maximum, value]))


func _ring_push(row: Dictionary) -> void:
	while _ring_size > 0:
		var oldest: Dictionary = _ring[_ring_head]
		if int(row.timestamp_usec) - int(oldest.timestamp_usec) <= 5000000:
			break
		_ring[_ring_head] = null
		_ring_head = (_ring_head + 1) % _ring_limit
		_ring_size -= 1
	if _ring_size == _ring_limit:
		_history_shortened += 1
		_ring[_ring_head] = row
		_ring_head = (_ring_head + 1) % _ring_limit
	else:
		_ring[(_ring_head + _ring_size) % _ring_limit] = row
		_ring_size += 1


func _trigger_window(now: int, automatic: bool) -> void:
	if not enabled:
		return
	if _window_open and now > _window_until:
		_close_window(now)
	if _window_open:
		_window_until = mini(_window_started + 10000000, maxi(_window_until, now + 2000000))
		_window_automatic = _window_automatic or automatic
		return
	if automatic and now < _auto_ready:
		return
	_window_id += 1
	_window_open = true
	_window_started = now
	if _ring_size > 0:
		_window_started = maxi(now - 5000000, int(_ring[_ring_head].timestamp_usec))
	_window_until = mini(_window_started + 10000000, now + 2000000)
	_window_automatic = automatic
	_last_detail_timestamp = -1
	_emit_event("window_started", {"window_id": _window_id, "automatic": automatic, "history_start_usec": _window_started}, now)
	for i in range(_ring_size):
		var row: Dictionary = _ring[(_ring_head + i) % _ring_limit]
		if int(row.timestamp_usec) >= now - 5000000:
			_write_detail(row)


func _close_window(now: int) -> void:
	if not _window_open:
		return
	var ended := mini(now, _window_until)
	_window_open = false
	if _window_automatic:
		_auto_ready = ended + 10000000
	_emit_event("window_finished", {"window_id": _window_id, "history_start_usec": _window_started, "end_usec": ended}, now)


func _write_detail(row: Dictionary) -> void:
	if int(row.timestamp_usec) <= _last_detail_timestamp or int(row.timestamp_usec) > _window_until:
		return
	_last_detail_timestamp = int(row.timestamp_usec)
	_enqueue("spike_frames.csv", _csv([
		_window_id, row.segment_id, row.world_id, row.timestamp_usec,
		null if float(row.frame_interval_ms) < 0.0 else row.frame_interval_ms,
		row.simulation_delta_ms, row.main_update_ms, JSON.stringify(row.timings),
	]), true)


func _enqueue(file: String, line: String, detail := false) -> void:
	if _writer != null:
		_writer.enqueue(file, line, detail)


func _check_writer(now: int) -> void:
	if not enabled or _finishing:
		return
	if not _writer.last_error.is_empty():
		last_error = _writer.last_error
		stop("output_error", now)
	elif _writer.limit_reached:
		stop("size_limit", now)


func _percentile(fraction: float) -> Variant:
	if _frame_count == 0:
		return null
	var target := maxi(1, int(ceil(_frame_count * fraction)))
	var total := 0
	for i in range(_histogram.size()):
		total += _histogram[i]
		if total >= target:
			return null if i == 1001 else i
	return null


func _make_summary(completed: bool, reason: String, now: int) -> Dictionary:
	var durations := _durations.duplicate()
	if enabled:
		durations[segment] = int(durations.get(segment, 0)) + maxi(0, now - _segment_started)
	return {
		"format_version": FORMAT_VERSION, "completed": completed, "reason": reason,
		"started_usec": _started, "ended_usec": now, "elapsed_sec": float(maxi(0, now - _started)) / 1000000.0,
		"metadata": _metadata, "worlds": _worlds, "world_metadata_omitted": _worlds_omitted,
		"world_durations_usec": _world_durations, "world_duration_omitted_usec": _world_duration_omitted_usec,
		"segment_durations_usec": durations,
		"settings": {"aggregate_period_usec": 1000000, "pre_trigger_usec": 5000000, "post_trigger_usec": 2000000, "window_cap_usec": 10000000, "automatic_cooldown_usec": 10000000, "spike_threshold_ms": 50, "ring_frames": _ring_limit, "pending_bytes": _writer.pending_limit, "pump_bytes": _writer.pump_limit, "capture_bytes": _writer.capture_limit, "summary_reserve_bytes": _writer.summary_reserve},
		"gameplay_frames": {"count": _frame_count, "mean_ms": null if _frame_count == 0 else _frame_sum / _frame_count, "max_ms": _frame_max, "median_ms": _percentile(0.5), "p95_ms": _percentile(0.95), "p99_ms": _percentile(0.99), "histogram_1ms_upper_bounds": Array(_histogram), "histogram_overflow_count": _histogram[1001], "percentile_precision": "1 ms upper bounds; null when unavailable or above 1000 ms (see count and overflow)", "slow_frames": _slow},
		"timings_ms_by_segment": _session_timings, "counters_by_segment": _session_counters,
		"detail_windows": _window_id, "history_shortened_frames": _history_shortened,
		"dropped_detail_records": _writer.dropped_detail_records, "rejected_metric_samples": _unknown_metrics,
		"output_data_bytes": _writer.bytes_written, "pending_output_bytes": _writer.pending_bytes,
		"overhead": {"collection_usec": _collection_usec, "write_usec": _write_usec, "pump_count": _pump_count},
		"last_error": last_error,
		"measurement_notes": "Frame intervals are monotonic callback intervals, not GPU time. Only same-segment gameplay intervals enter the histogram. Asynchronous timings are completed-job wall measurements, not additive main-thread costs. No missing metric is substituted with zero.",
	}


func _markdown(completed: bool, reason: String) -> String:
	var lines := PackedStringArray([
		"# Passive Gameplay Capture", "",
		"Status: %s (%s)." % ["complete" if completed else "incomplete", reason], "",
		"Output: `%s`" % output_path.replace("`", "'"), "",
		"## Gameplay frame intervals", "",
		"Observed intervals: %d. Mean: %s ms; exact maximum: %.3f ms." % [_frame_count, "unavailable" if _frame_count == 0 else "%.3f" % (_frame_sum / _frame_count), _frame_max], "",
		"Median / p95 / p99: %s / %s / %s ms." % [str(_percentile(0.5)), str(_percentile(0.95)), str(_percentile(0.99))], "",
		"Percentiles use 1 ms upper-bound bins. Null means no samples or a percentile above 1000 ms. Overflow intervals: %d." % _histogram[1001], "",
		"Slow intervals: >33.3 ms: %d; >50 ms: %d; >100 ms: %d." % [_slow.over_33_3_ms, _slow.over_50_ms, _slow.over_100_ms], "",
		"Only same-segment gameplay intervals count here. Callback intervals, simulation delta, and measured Main work are distinct; this is not GPU timing.", "",
		"## Segment durations", "",
		"| Segment | Seconds |", "| --- | ---: |",
	])
	for name in SEGMENTS:
		lines.append("| %s | %.3f |" % [name, float(_durations.get(name, 0)) / 1000000.0])
	lines.append_array(["", "## Observed timing contributors", "", "Largest recorded wall-time totals across all segments. Nested spans overlap and must not be added together. Async results below describe completed jobs, not current-frame CPU cost.", ""])
	lines.append_array(_timing_table(false))
	lines.append_array(["", "### Completed asynchronous jobs", ""])
	lines.append_array(_timing_table(true))
	lines.append_array(["", "## Activity counters", "", "Explicit increments, grouped by segment (not cumulative workload snapshots).", ""])
	if _session_counters.is_empty():
		lines.append("No activity counters recorded.")
	else:
		lines.append_array(["| Counter | Count |", "| --- | ---: |"])
		var keys := _session_counters.keys()
		keys.sort()
		for i in range(mini(keys.size(), 20)):
			lines.append("| %s | %s |" % [str(keys[i]).replace("|", "/"), str(_session_counters[keys[i]])])
		if keys.size() > 20:
			lines.append("Additional counters are retained in summary.json.")
	lines.append_array([
		"", "## Capture quality and overhead", "",
		"Detailed windows: %d. Dropped detail rows: %d. Ring truncations: %d." % [_window_id, _writer.dropped_detail_records, _history_shortened], "",
		"Recorder collection: %.3f ms; output writes/flushes: %.3f ms (%d normal pumps)." % [_collection_usec / 1000.0, _write_usec / 1000.0, _pump_count], "",
		"Data written: %d bytes. Pending: %d bytes. Rejected metric samples: %d." % [_writer.bytes_written, _writer.pending_bytes, _unknown_metrics], "",
	])
	if not completed:
		lines.append("WARNING: This capture is incomplete; buffered data may be missing.")
	if reason == "size_limit":
		lines.append("Recording stopped at its configured size limit; no older captures were deleted.")
	if not last_error.is_empty():
		lines.append("Output warning: " + last_error.left(512))
	if _writer.dropped_detail_records > 0 or _history_shortened > 0:
		lines.append("Some detailed history was omitted by bounded capture limits; inspect the counts above.")
	lines.append_array(["", "## Capture conditions", "", "```json", JSON.stringify(_metadata, "  "), "```", "", "### World segments", ""])
	lines.append("Initial world 0: %.3f s (including its menu/loading periods)." % (float(_world_durations.get("0", 0)) / 1000000.0))
	lines.append("")
	if _worlds.is_empty():
		lines.append("No replacement world was recorded; initial world context is in capture metadata.")
	for i in range(mini(_worlds.size(), 8)):
		var world: Dictionary = _worlds[i]
		lines.append("- World %d at %.3f s, duration %.3f s: `%s`" % [world.world_id, float(int(world.timestamp_usec) - _started) / 1000000.0, float(_world_durations.get(str(world.world_id), 0)) / 1000000.0, JSON.stringify(world.metadata).replace("`", "'")])
	if _worlds.size() > 8 or _worlds_omitted > 0:
		lines.append("Further worlds are recorded in summary.json/events.jsonl; %d world metadata entries exceeded the summary bound." % _worlds_omitted)
	lines.append_array(["", "## Detailed reports", "", "samples.csv contains one-second aggregates, with actual shorter segment/delayed-frame durations. Workload rows are snapshots; unavailable values are explicit. events.jsonl contains lifecycle/manual markers. spike_frames.csv contains bounded detail windows. summary.json retains the complete bounded metric registry and histogram.", "", "No controlled benchmark comparison, performance pass/fail result, GPU measurement, or per-worker trace is implied.", ""])
	return "\n".join(lines)


func _timing_table(async_only: bool) -> PackedStringArray:
	var keys: Array = []
	for key in _session_timings:
		# Mesh application and synchronous builds are main-thread work, even
		# though the same subsystem also returns background build measurements.
		var is_async := "/Path.completed." in str(key) or "/Mesh.completed." in str(key) or "/Mesh.scheduler." in str(key) or "/RenderZone.completed." in str(key)
		if str(key).ends_with("/frame_interval_ms") or str(key).ends_with("/simulation_delta_ms") or str(key).ends_with("/RenderZone.result_age_ms"):
			continue
		if is_async == async_only:
			keys.append(key)
	keys.sort_custom(func(a: Variant, b: Variant) -> bool: return float(_session_timings[a].sum) > float(_session_timings[b].sum))
	if keys.is_empty():
		return PackedStringArray(["No samples recorded."])
	var lines := PackedStringArray(["| Segment / metric | Samples | Total ms | Mean ms | Max ms |", "| --- | ---: | ---: | ---: | ---: |"])
	for i in range(mini(keys.size(), 10)):
		var stat: Dictionary = _session_timings[keys[i]]
		lines.append("| %s | %d | %.3f | %.3f | %.3f |" % [str(keys[i]).replace("|", "/"), stat.count, stat.sum, float(stat.sum) / int(stat.count), stat.max])
	return lines


func _csv(values: Array) -> String:
	var fields := PackedStringArray()
	for value in values:
		var field := "unavailable" if value == null else str(value)
		fields.append("\"" + field.replace("\"", "\"\"") + "\"")
	return ",".join(fields) + "\n"


func _bounded(value: Variant, budget_bytes: int = 2048) -> Variant:
	# A shared byte budget bounds the whole payload, not just each leaf. This
	# also keeps 128 world summaries plus metric registries below the reserve.
	return _sanitize(value, 0, [budget_bytes])


func _sanitize(value: Variant, depth: int, budget: Array) -> Variant:
	if depth > 3 or int(budget[0]) <= 0:
		return "[depth limit]"
	if value is Dictionary:
		var result := {}
		var count := 0
		for key in value:
			if count >= 32 or int(budget[0]) <= 0:
				break
			var label := str(key).left(96)
			budget[0] -= label.to_utf8_buffer().size() + 8
			result[label] = _sanitize(value[key], depth + 1, budget)
			count += 1
		return result
	if value is Array:
		var result: Array = []
		for i in range(mini(value.size(), 32)):
			if int(budget[0]) <= 0:
				break
			result.append(_sanitize(value[i], depth + 1, budget))
		return result
	budget[0] -= 24
	if value == null or value is int or value is bool:
		return value
	if value is float:
		return value if is_finite(value) else null
	var text := str(value).left(mini(512, maxi(0, int(budget[0]))))
	budget[0] -= text.to_utf8_buffer().size()
	return text
