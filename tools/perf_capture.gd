extends SceneTree
## Scripted performance capture: loads or creates a world, runs fixed phases
## (idle, fast pan, level steps, zoomed out) and records each with the passive
## gameplay recorder (SEE-ADR-013). Writes one result.json that summarises frame
## times, Main spans and engine render measurements per phase.
##
## Needs a real window for render numbers; under --headless only script timings
## are produced. Always run with APPDATA pointed at a scratch folder:
##
##   godot --path <repo> --script res://tools/perf_capture.gd --resolution 1920x1080 -- \
##       --copy-save-from=<dir of a saved world> --label=baseline
##
## Options (after "--"):
##   --slot=NAME             save slot to use, default perf_capture (never "world")
##   --copy-save-from=DIR    copy a saved world directory into the slot, then load it
##   --new-world=256|512|128 create a world instead (128 is the on-demand test size)
##   --phases=a,b,...        default idle,pan,levels,zoom; panvoid repeats the pan with
##                           the renderer's void meter on (its sampling costs frame
##                           time, so it is a separate phase from the timed pan)
##   --pan-speed=N           blocks per second for pan phases, default 60
##   --seconds=N             length of each timed phase, default 10
##   --level-steps=N         levels to step down and back up, default 16
##   --mesh-threads=N        override the mesh worker thread count for comparisons
##   --label=TEXT            copied into the result
##   --out=FILE              result path, default user://diagnostics/perf_capture/<time>/result.json

const PLAYER_SLOT := "world"
const PAN_SPEED := 60.0
const SETTLE_TIMEOUT_SEC := 60.0
const LEVEL_STEP_INTERVAL_SEC := 0.3
const TOP_SPAN_COUNT := 10

var main
var options := {
	"slot": "perf_capture", "copy-save-from": "", "new-world": "", "phases": "idle,pan,levels,zoom",
	"seconds": "10", "level-steps": "16", "label": "", "out": "", "mesh-threads": "", "pan-speed": "",
}
var result := {"format_version": 1, "phases": [], "errors": []}
var _void_stats := {}


func _init() -> void:
	for argument: String in OS.get_cmdline_user_args():
		if not argument.begins_with("--"):
			continue
		var parts := argument.trim_prefix("--").split("=", true, 1)
		if options.has(parts[0]):
			options[parts[0]] = parts[1] if parts.size() > 1 else "1"
		else:
			push_warning("perf_capture: unknown option %s" % argument)
	_run.call_deferred()


func _fail(message: String) -> void:
	push_error("perf_capture: " + message)
	result.errors.append(message)
	_finish(1)


func _wait(seconds: float) -> void:
	var until := Time.get_ticks_usec() + int(seconds * 1000000.0)
	while Time.get_ticks_usec() < until:
		await process_frame


func _run() -> void:
	var slot := str(options.slot).validate_filename()
	if slot.is_empty() or slot == PLAYER_SLOT:
		_fail("slot must be a name other than the player's save slot")
		return
	main = load("res://scenes/Main.tscn").instantiate()
	root.add_child(main)
	await process_frame
	# Never touch the player's save: this run loads, and New Game saves.
	main.save_path = "user://saves/%s.save" % slot
	if ProjectSettings.globalize_path(main.save_path) == ProjectSettings.globalize_path(main.SAVE_PATH):
		_fail("refusing to use the player save path")
		return
	main.performance_controller.ignore_focus = true
	main.performance_controller.set_focused(true)
	var started_usec := Time.get_ticks_usec()
	if not str(options["copy-save-from"]).is_empty():
		var destination := ProjectSettings.globalize_path("user://saves/%s" % slot)
		if not _copy_directory(str(options["copy-save-from"]), destination):
			_fail("could not copy the saved world from %s" % options["copy-save-from"])
			return
		if not main._has_save_game():
			_fail("copied directory is not a saved world")
			return
		main.load_button.pressed.emit()
	else:
		var size := str(options["new-world"])
		if size == "128":
			main.force_on_demand_meshing_for_tests = true
			main.generate_full_map_on_startup = false
			main.world_size_option_button.clear()
			main.world_size_option_button.add_item("128 x 128 (test)", 16)
			main.world_size_option_button.select(0)
		elif size == "512":
			main.world_size_option_button.select(1)
		main.resume_button.pressed.emit()
	await process_frame
	while (main.loading_active or not main.world_started) and Time.get_ticks_usec() - started_usec < 900_000_000:
		await process_frame
	if not main.world_started or main.loading_active:
		_fail("world did not start within 15 minutes")
		return
	var world = main.world
	if not str(options["mesh-threads"]).is_empty():
		world.renderer.set_mesh_worker_count(int(str(options["mesh-threads"])))
	result["mesh_threads"] = world.renderer.mesh_scheduler.worker_count
	result["label"] = str(options.label)
	result["world_ready_sec"] = float(Time.get_ticks_usec() - started_usec) / 1000000.0
	result["settle_sec"] = await _settle()
	result["world"] = {
		"size": [world.world_size_x, world.world_size_y, world.world_size_z],
		"chunks": world.chunks.size(), "workers": world.workers.size(),
		"render_level": world.top_render_y, "seed": world.world_seed,
		"source": "copied_save" if not str(options["copy-save-from"]).is_empty() else "new_world",
	}
	result["conditions"] = main.performance_controller._metadata()
	var seconds := maxf(1.0, float(str(options.seconds)))
	for phase: String in str(options.phases).split(",", false):
		if not ["idle", "pan", "panvoid", "levels", "zoom"].has(phase):
			result.errors.append("unknown phase %s" % phase)
			continue
		if not main.performance_controller.start_capture():
			result.errors.append("capture did not start for %s: %s" % [phase, main.performance_controller.recorder.last_error])
			continue
		var phase_started := Time.get_ticks_usec()
		match phase:
			"idle":
				await _wait(seconds)
			"pan":
				await _phase_pan(seconds)
			"panvoid":
				await _phase_pan(seconds, true)
			"levels":
				await _phase_levels(int(str(options["level-steps"])))
			"zoom":
				await _phase_zoom(seconds)
		var capture_dir: String = main.performance_controller.stop_capture("perf_capture")
		var entry := _summarise(phase, capture_dir)
		if phase == "panvoid":
			entry["void"] = _void_stats.duplicate()
		entry["wall_sec"] = float(Time.get_ticks_usec() - phase_started) / 1000000.0
		result.phases.append(entry)
		_print_phase(entry)
		await _settle()
	_finish(0 if result.errors.is_empty() else 1)


## Waits for meshing and generation to drain so one phase does not bill the next.
func _settle() -> float:
	var started := Time.get_ticks_usec()
	var quiet_frames := 0
	while float(Time.get_ticks_usec() - started) / 1000000.0 < SETTLE_TIMEOUT_SEC:
		await process_frame
		var snapshot: Dictionary = main.world.get_performance_snapshot()
		var busy: bool = main.loading_active
		for key in ["generation_queued", "generation_results_pending", "generation_executing", "mesh_queued", "mesh_results_pending", "mesh_in_flight"]:
			busy = busy or int(snapshot.get(key, 0) if snapshot.get(key) != null else 0) > 0
		quiet_frames = 0 if busy else quiet_frames + 1
		if quiet_frames >= 30:
			break
	return float(Time.get_ticks_usec() - started) / 1000000.0


## measure_void turns on the renderer's void meter for the pan: on-screen chunks
## of the top two layers that have geometry but are not shown yet.
func _phase_pan(seconds: float, measure_void: bool = false) -> void:
	var renderer = main.world.renderer
	var speed := PAN_SPEED if str(options["pan-speed"]).is_empty() else float(str(options["pan-speed"]))
	var meter_was: bool = renderer.void_meter_enabled
	renderer.void_meter_enabled = measure_void or meter_was
	_void_stats = {"samples": 0, "samples_with_void": 0, "hidden_max": 0, "hidden_sum": 0, "checked_sum": 0, "longest_void_ms": 0.0}
	var last_sample_usec: int = renderer._void_last_usec
	var legs := [Vector3(1, 0, 0), Vector3(0, 0, 1), Vector3(-1, 0, 0), Vector3(0, 0, -1)]
	var leg_usec := int(seconds * 1000000.0 / legs.size())
	for direction: Vector3 in legs:
		var leg_started := Time.get_ticks_usec()
		var previous := leg_started
		while Time.get_ticks_usec() - leg_started < leg_usec:
			await process_frame
			var now := Time.get_ticks_usec()
			main.camera.position += direction * speed * float(now - previous) / 1000000.0
			previous = now
			if measure_void and renderer._void_last_usec != last_sample_usec:
				last_sample_usec = renderer._void_last_usec
				var meter: Dictionary = renderer.void_meter
				_void_stats.samples += 1
				_void_stats.hidden_sum += int(meter.get("hidden", 0))
				_void_stats.checked_sum += int(meter.get("checked", 0))
				_void_stats.hidden_max = maxi(_void_stats.hidden_max, int(meter.get("hidden", 0)))
				_void_stats.longest_void_ms = maxf(_void_stats.longest_void_ms, float(meter.get("void_ms", 0.0)))
				if int(meter.get("hidden", 0)) > 0:
					_void_stats.samples_with_void += 1
	renderer.void_meter_enabled = meter_was


func _phase_levels(steps: int) -> void:
	for delta: int in [-1, 1]:
		for _step in maxi(steps, 1):
			main.render_level_controller.handle_render_layer_change(delta)
			await process_frame
			var guard := Time.get_ticks_usec()
			while main.loading_active and Time.get_ticks_usec() - guard < 120_000_000:
				await process_frame
			await _wait(LEVEL_STEP_INTERVAL_SEC)


func _phase_zoom(seconds: float) -> void:
	var previous_size: float = main.camera.size
	main.camera.size = main.camera_controller.cam_zoom_max
	await _wait(seconds)
	main.camera.size = previous_size


func _summarise(phase: String, capture_dir: String) -> Dictionary:
	var entry := {"name": phase, "capture_dir": ProjectSettings.globalize_path(capture_dir)}
	var text := FileAccess.get_file_as_string(capture_dir.path_join("summary.json"))
	var summary: Variant = JSON.parse_string(text) if not text.is_empty() else null
	if not summary is Dictionary:
		result.errors.append("no summary for %s" % phase)
		return entry
	var frames: Dictionary = summary.get("gameplay_frames", {})
	entry["completed"] = summary.get("completed", false)
	entry["frames"] = {
		"count": frames.get("count"), "mean_ms": frames.get("mean_ms"), "median_ms": frames.get("median_ms"),
		"p95_ms": frames.get("p95_ms"), "p99_ms": frames.get("p99_ms"), "max_ms": frames.get("max_ms"),
		"slow": frames.get("slow_frames"),
	}
	entry["segment_seconds"] = {}
	for segment: String in summary.get("segment_durations_usec", {}):
		entry.segment_seconds[segment] = float(summary.segment_durations_usec[segment]) / 1000000.0
	var spans: Array = []
	var engine := {}
	var async_jobs := {}
	var timings: Dictionary = summary.get("timings_ms_by_segment", {})
	for key: String in timings:
		if not key.begins_with("gameplay/"):
			continue
		var label := key.trim_prefix("gameplay/")
		var stat: Dictionary = timings[key]
		var row := {"label": label, "samples": stat.count, "total_ms": stat.sum,
			"mean_ms": float(stat.sum) / maxf(1.0, float(stat.count)), "max_ms": stat.max}
		if label.begins_with("Engine."):
			engine[label] = {"mean": row.mean_ms, "max": row.max_ms}
		elif label.contains(".completed.") or label.begins_with("Mesh.scheduler."):
			async_jobs[label] = row
		elif label == "RenderZone.result_age_ms":
			# Request-to-shown latency of the visibility view, not CPU work.
			entry["visibility_latency_ms"] = {"samples": row.samples, "mean": row.mean_ms, "max": row.max_ms}
		elif not ["frame_interval_ms", "simulation_delta_ms", "RenderZone.result_age_ms"].has(label):
			spans.append(row)
	spans.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return float(a.total_ms) > float(b.total_ms))
	entry["main_spans"] = spans.slice(0, TOP_SPAN_COUNT)
	entry["engine_ms"] = engine
	entry["async_jobs"] = async_jobs
	var gauges := {}
	var gauge_stats: Dictionary = summary.get("gauges_by_segment", {})
	for key: String in gauge_stats:
		if key.begins_with("gameplay/"):
			var gauge: Dictionary = gauge_stats[key]
			gauges[key.trim_prefix("gameplay/")] = {"mean": float(gauge.sum) / maxf(1.0, float(gauge.count)), "max": gauge.max}
	entry["gauges"] = gauges
	var counters := {}
	var counter_stats: Dictionary = summary.get("counters_by_segment", {})
	for key: String in counter_stats:
		if key.begins_with("gameplay/"):
			counters[key.trim_prefix("gameplay/")] = counter_stats[key]
	entry["counters"] = counters
	return entry


func _print_phase(entry: Dictionary) -> void:
	var frames: Dictionary = entry.get("frames", {})
	var engine: Dictionary = entry.get("engine_ms", {})
	var gauges: Dictionary = entry.get("gauges", {})
	print("[perf %s] frames=%s median=%s p95=%s p99=%s max=%s ms | render cpu=%s gpu=%s ms | draws=%s prims=%s" % [
		entry.name, frames.get("count"), frames.get("median_ms"), frames.get("p95_ms"), frames.get("p99_ms"),
		_fmt(frames.get("max_ms")), _fmt(engine.get("Engine.render_cpu_ms", {}).get("mean")),
		_fmt(engine.get("Engine.render_gpu_ms", {}).get("mean")), _fmt(gauges.get("Engine.draw_calls", {}).get("mean")),
		_fmt(gauges.get("Engine.primitives", {}).get("mean")),
	])
	for row: Dictionary in entry.get("main_spans", []).slice(0, 5):
		print("    %-40s mean %.3f ms  max %.3f ms  (%d samples)" % [row.label, row.mean_ms, row.max_ms, row.samples])


func _fmt(value: Variant) -> String:
	return "n/a" if value == null else "%.2f" % float(value)


func _copy_directory(source: String, destination: String) -> bool:
	var reader := DirAccess.open(source)
	if reader == null or DirAccess.make_dir_recursive_absolute(destination) != OK:
		return false
	for file in reader.get_files():
		if reader.copy(source.path_join(file), destination.path_join(file)) != OK:
			return false
	for directory in reader.get_directories():
		if not _copy_directory(source.path_join(directory), destination.path_join(directory)):
			return false
	return true


func _finish(code: int) -> void:
	var out := str(options.out)
	if out.is_empty():
		var stamp := Time.get_datetime_string_from_system().replace(":", "-")
		out = "user://diagnostics/perf_capture/%s-%d/result.json" % [stamp, OS.get_process_id()]
	out = ProjectSettings.globalize_path(out)
	DirAccess.make_dir_recursive_absolute(out.get_base_dir())
	var file := FileAccess.open(out, FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(result, "\t"))
		file.close()
		print("perf_capture result: %s" % out)
	else:
		push_error("perf_capture: could not write %s" % out)
		code = 1
	if main != null and main.world != null and main.world.task_manager != null:
		main.world.task_manager.shutdown()
	quit(code)
