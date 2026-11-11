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
##   --pan-pattern=NAME      square (default): four long legs; shuttle: short bursts
##                           that reverse direction, like quick mouse drags
##   --burst-seconds=N       length of one shuttle burst, default 0.4
##   --seconds=N             length of each timed phase, default 10
##   --level-steps=N         levels to step down and back up, default 16
##   --mesh-threads=N        override the mesh worker thread count for comparisons
##   --visibility-mode=NAME  async (default), area (show the whole render box, engine
##                           culling only) or sync; the renderer's debug comparison modes
##   --depth-layers=N        0 (all) or 1, 2, 4, 8: show only the top N chunk layers
##   --look-ahead=0|1        turn the pan look-ahead off or on
##   --render-radius=N       render box padding in chunks (default 1); 64 covers a 512 world
##   --pan-limit=0|1         turn the pan limiter off or on (default on)
##   --view-meshes=0|1       turn view-driven mesh requests off or on (default on)
##   --void-pixels=1         panvoid also reads the rendered frame: the background is
##                           set to magenta and every sample counts magenta pixels,
##                           so anything missing on screen is seen whatever the cause.
##                           The worst frame is saved next to --out as *_void_worst.png
##   --pan-pattern=tour      like square but heading into the world first (-x, -z, +x, +z)
##   --pan-pattern=tourstop  pan -x, stand still, pan -z, stand still
##   --label=TEXT            copied into the result
##   --out=FILE              result path, default user://diagnostics/perf_capture/<time>/result.json

const EngineMetrics = preload("res://scripts/diagnostics/engine_metrics.gd")
const PLAYER_SLOT := "world"
const PAN_SPEED := 60.0
const SETTLE_TIMEOUT_SEC := 60.0
const LEVEL_STEP_INTERVAL_SEC := 0.3
const TOP_SPAN_COUNT := 10

var main
var options := {
	"slot": "perf_capture", "copy-save-from": "", "new-world": "", "phases": "idle,pan,levels,zoom",
	"seconds": "10", "level-steps": "16", "label": "", "out": "", "mesh-threads": "", "pan-speed": "", "pan-pattern": "square", "burst-seconds": "0.4", "visibility-mode": "", "depth-layers": "", "look-ahead": "", "render-radius": "", "pan-limit": "", "void-pixels": "", "view-meshes": "",
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
	# Render comparison switches. These are the renderer's own debug options.
	if not str(options["render-radius"]).is_empty():
		world.streaming.render_radius_chunks = int(str(options["render-radius"]))
	if not str(options["look-ahead"]).is_empty():
		world.renderer.set_render_debug("look_ahead", str(options["look-ahead"]) != "0")
	if not str(options["depth-layers"]).is_empty():
		world.renderer.set_render_debug("depth_layers", int(str(options["depth-layers"])))
	if not str(options["pan-limit"]).is_empty():
		world.renderer.set_render_debug("pan_limit", str(options["pan-limit"]) != "0")
	if not str(options["view-meshes"]).is_empty():
		world.renderer.set_render_debug("view_meshes", str(options["view-meshes"]) != "0")
	if not str(options["visibility-mode"]).is_empty():
		world.renderer.set_render_debug("visibility_mode", str(options["visibility-mode"]))
	result["render_settings"] = {"debug": world.renderer.get_render_debug(), "render_radius_chunks": world.streaming.render_radius_chunks}
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
		if phase == "panvoid" or phase == "pan":
			entry["void"] = _void_stats.duplicate()
		entry["wall_sec"] = float(Time.get_ticks_usec() - phase_started) / 1000000.0
		entry["state"] = _state_snapshot()
		result.phases.append(entry)
		_print_phase(entry)
		await _settle()
	_finish(0 if result.errors.is_empty() else 1)


## Memory, node and visibility totals at the end of a phase.
func _state_snapshot() -> Dictionary:
	var world = main.world
	var state: Dictionary = EngineMetrics.memory_snapshot()
	var view: Dictionary = world.renderer.visibility_state.snapshot()
	state["memory_static_bytes"] = int(Performance.get_monitor(Performance.MEMORY_STATIC))
	state["chunk_nodes"] = world.renderer.chunk_cache.coordinate_slots.members.size()
	state["shown_nodes"] = view.get("shown_nodes")
	state["eligible_coords"] = view.get("effective_eligible")
	state["slice_caps"] = world.renderer._slice_cap_coords.size()
	return state


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
## of the top two layers that have geometry but are not shown yet. Each meter
## sample is also kept in a timeline with the visibility state at that moment.
func _phase_pan(seconds: float, measure_void: bool = false) -> void:
	var renderer = main.world.renderer
	var speed := PAN_SPEED if str(options["pan-speed"]).is_empty() else float(str(options["pan-speed"]))
	var meter_was: bool = renderer.void_meter_enabled
	renderer.void_meter_enabled = measure_void or meter_was
	_void_stats = {"samples": 0, "samples_with_void": 0, "hidden_max": 0, "hidden_sum": 0, "checked_sum": 0,
		"longest_void_ms": 0.0, "pattern": str(options["pan-pattern"]), "speed": speed, "timeline": [], "details": []}
	var last_sample_usec: int = renderer._void_last_usec
	var legs: Array = [Vector3(1, 0, 0), Vector3(0, 0, 1), Vector3(-1, 0, 0), Vector3(0, 0, -1)]
	var leg_usec := int(seconds * 1000000.0 / legs.size())
	if str(options["pan-pattern"]) == "shuttle":
		leg_usec = int(maxf(0.05, float(str(options["burst-seconds"]))) * 1000000.0)
		legs = []
		var pattern := [Vector3(1, 0, 0), Vector3(-1, 0, 0), Vector3(0, 0, 1), Vector3(0, 0, -1),
			Vector3(1, 0, 1).normalized(), Vector3(-1, 0, -1).normalized()]
		for index in int(seconds * 1000000.0 / leg_usec):
			legs.append(pattern[index % pattern.size()])
	if str(options["pan-pattern"]) == "tour":
		legs = [Vector3(-1, 0, 0), Vector3(0, 0, -1), Vector3(1, 0, 0), Vector3(0, 0, 1)]
	if str(options["pan-pattern"]) == "tourstop":
		# Pan into the world, stand still, pan on, stand still: does missing terrain fill in at rest?
		legs = [Vector3(-1, 0, 0), Vector3.ZERO, Vector3(0, 0, -1), Vector3.ZERO]
	# Pixel probe: what the player sees, whatever the cause.
	var pixel_probe: bool = measure_void and str(options["void-pixels"]) == "1"
	var pixel_restore: Array = [main.default_bg_mode, main.default_bg_color]
	var pixel_streak_usec := 0
	if pixel_probe:
		main.default_bg_mode = Environment.BG_COLOR
		main.default_bg_color = Color(1.0, 0.0, 1.0)
		for frame in 6:
			await process_frame
		_void_stats["pixels"] = {"baseline": _void_pixel_sample().fraction, "max": 0.0, "samples": 0, "samples_over": 0,
			"longest_ms": 0.0, "worst": {}, "timeline": []}
	var phase_started := Time.get_ticks_usec()
	var view_before: Dictionary = renderer.visibility_state.snapshot()
	var limited_before: int = renderer.visibility_state.pan_limited_count
	var requested_blocks := 0.0
	var travelled_blocks := 0.0
	for leg_index in legs.size():
		var direction: Vector3 = legs[leg_index]
		var leg_started := Time.get_ticks_usec()
		var previous := leg_started
		while Time.get_ticks_usec() - leg_started < leg_usec:
			await process_frame
			var now := Time.get_ticks_usec()
			var step: Vector3 = direction * speed * float(now - previous) / 1000000.0
			var before: Vector3 = main.camera.global_position
			main.camera_controller.pan_by(step)
			requested_blocks += step.length()
			travelled_blocks += main.camera.global_position.distance_to(before)
			previous = now
			if measure_void and renderer._void_last_usec != last_sample_usec:
				last_sample_usec = renderer._void_last_usec
				var meter: Dictionary = renderer.void_meter
				var hidden := int(meter.get("hidden", 0))
				_void_stats.samples += 1
				_void_stats.hidden_sum += hidden
				_void_stats.checked_sum += int(meter.get("checked", 0))
				_void_stats.hidden_max = maxi(_void_stats.hidden_max, hidden)
				_void_stats.longest_void_ms = maxf(_void_stats.longest_void_ms, float(meter.get("void_ms", 0.0)))
				if hidden > 0:
					_void_stats.samples_with_void += 1
				if pixel_probe:
					var pixels: Dictionary = _void_stats.pixels
					var sample: Dictionary = _void_pixel_sample()
					var over: bool = sample.fraction > float(pixels.baseline) + 0.001
					pixels.samples += 1
					if over:
						pixels.samples_over += 1
						if pixel_streak_usec == 0:
							pixel_streak_usec = now
						pixels.longest_ms = maxf(pixels.longest_ms, float(now - pixel_streak_usec) / 1000.0)
					else:
						pixel_streak_usec = 0
					pixels.timeline.append([snappedf(float(now - phase_started) / 1000.0, 1.0), leg_index, snappedf(sample.fraction, 0.0001), hidden])
					pixels.outside_max = maxf(float(pixels.get("outside_max", 0.0)), float(sample.outside))
					if sample.fraction > float(pixels.max):
						pixels.max = sample.fraction
						pixels.worst = {"t_ms": float(now - phase_started) / 1000.0, "leg": leg_index, "box": sample.box,
							"mesh_queued": renderer.mesh_scheduler.get_performance_snapshot().get("queued"),
							"stream_queue": main.world.streaming.chunk_build_queue.size() - main.world.streaming.queue_head,
							"census": _onscreen_census(), "view_meshes": renderer.view_meshes.snapshot(),
							"camera": [main.camera.position.x, main.camera.position.y, main.camera.position.z], "size": main.camera.size}
						# Saved after the pan: writing a PNG here would stall the frame.
						_worst_image = _probe_image
				if _void_stats.timeline.size() < 600:
					var view: Dictionary = renderer.visibility_state.snapshot()
					_void_stats.timeline.append({
						"t_ms": float(now - phase_started) / 1000.0, "leg": leg_index,
						"leg_ms": float(now - leg_started) / 1000.0, "hidden": hidden, "checked": int(meter.get("checked", 0)),
						"view_age_ms": view.get("result_age_ms"), "apply_remaining": view.get("application_remaining"),
						"mode": view.get("last_application_mode"), "eligible": view.get("effective_eligible"),
						"shown": view.get("shown_nodes"), "requested": view.get("requested_sequence"),
						"applied": view.get("applied_sequence"),
						"mesh_queued": main.world.renderer.mesh_scheduler.get_performance_snapshot().get("queued"),
						"camera": [main.camera.position.x, main.camera.position.z],
					})
					if hidden > 0 and _void_stats.details.size() < 40:
						_void_stats.details.append_array(_hidden_chunk_details())
	var view_after: Dictionary = renderer.visibility_state.snapshot()
	_void_stats["delta_applications"] = int(view_after.get("delta_applications", 0)) - int(view_before.get("delta_applications", 0))
	_void_stats["full_applications"] = int(view_after.get("full_applications", 0)) - int(view_before.get("full_applications", 0))
	# How much of the requested pan the limiter let through.
	_void_stats["pan_requested_blocks"] = requested_blocks
	_void_stats["pan_travelled_blocks"] = travelled_blocks
	_void_stats["pan_limited_steps"] = renderer.visibility_state.pan_limited_count - limited_before
	_void_stats["view_meshes"] = renderer.view_meshes.snapshot()
	renderer.void_meter_enabled = meter_was
	if pixel_probe:
		main.default_bg_mode = pixel_restore[0]
		main.default_bg_color = pixel_restore[1]
		if _worst_image != null and not str(options.out).is_empty():
			_worst_image.save_png(str(options.out).get_basename() + "_void_worst.png")
		_worst_image = null


## What state is every on-screen chunk of the top four layers in? Counts per
## layer, to explain background pixels the void meter does not count.
func _onscreen_census() -> Dictionary:
	var renderer = main.world.renderer
	var state = renderer.visibility_state
	var planes: Array = renderer.frustum_culler.build_planes(main.camera, renderer.NEAR_SAMPLE_OFFSET, renderer.NEAR_SAMPLE_MIN)
	var top_cy := floori(float(main.world.top_render_y) / World.CHUNK_SIZE)
	var args: Array = renderer._last_zone_args
	var census := {}
	for cy in range(top_cy, maxi(top_cy - 4, -1), -1):
		var row := {"on_screen": 0, "no_chunk": 0, "state_none": 0, "state_pending": 0, "state_ready": 0, "no_node": 0,
			"node_empty": 0, "node_hidden": 0, "node_shown": 0, "eligible": 0, "has_cap": 0}
		for cx in range(args[0], args[1] + 1):
			for cz in range(args[2], args[3] + 1):
				var coord := Vector3i(cx, cy, cz)
				if not renderer.is_drawn_part_in_view(planes, coord):
					continue
				row.on_screen += 1
				if state.eligible.members.has(coord):
					row.eligible += 1
				if renderer.has_slice_cap(coord):
					row.has_cap += 1
				var chunk: ChunkData = main.world.get_chunk(coord)
				if chunk == null:
					row.no_chunk += 1
				else:
					row[["state_none", "state_pending", "state_ready"][chunk.mesh_state]] += 1
				var node: MeshInstance3D = renderer.chunk_cache.get_chunk(coord)
				if node == null:
					row.no_node += 1
				elif (node.mesh == null or node.mesh.get_surface_count() == 0) and not renderer.has_slice_cap(coord):
					row.node_empty += 1
				elif node.visible:
					row.node_shown += 1
				else:
					row.node_hidden += 1
		census[str(cy)] = row
	return census


var _probe_image: Image
var _worst_image: Image


## Fraction of the rendered frame that is background (magenta during the probe)
## where terrain should be, read on a 192x108 grid, with the bounding box of
## those cells. Cells that look past the edge of the world are background by
## right and are counted separately as "outside".
func _void_pixel_sample() -> Dictionary:
	_probe_image = root.get_texture().get_image()
	var small: Image = _probe_image.duplicate()
	small.resize(192, 108, Image.INTERPOLATE_NEAREST)
	small.convert(Image.FORMAT_RGB8)
	var data: PackedByteArray = small.get_data()
	var count := 0
	var outside := 0
	var box := [192, 108, -1, -1]
	var screen: Vector2 = root.get_visible_rect().size
	var cut_y := float(main.world.top_render_y) + 1.0
	for index in range(0, data.size(), 3):
		if data[index] > 150 and data[index + 2] > 150 and data[index + 1] < 90:
			var cell := index / 3
			var x := cell % 192
			var y := cell / 192
			var point := Vector2((float(x) + 0.5) / 192.0 * screen.x, (float(y) + 0.5) / 108.0 * screen.y)
			if not (_ray_inside_world(point, cut_y) and _ray_inside_world(point, cut_y - 24.0)):
				outside += 1
				continue
			count += 1
			box = [mini(box[0], x), mini(box[1], y), maxi(box[2], x), maxi(box[3], y)]
	return {"fraction": float(count) / float(data.size() / 3), "outside": float(outside) / float(data.size() / 3), "box": box}


## Does the view ray through this screen point cross height y well inside the
## world? The frame read back is one frame old, hence the margin.
func _ray_inside_world(screen_point: Vector2, y: float) -> bool:
	var origin: Vector3 = main.camera.project_ray_origin(screen_point)
	var normal: Vector3 = main.camera.project_ray_normal(screen_point)
	if absf(normal.y) < 0.0001:
		return false
	var hit: Vector3 = origin + normal * ((y - origin.y) / normal.y)
	var margin := 10.0
	return hit.x >= World.WORLD_MIN_BLOCK_X + margin and hit.x <= World.WORLD_MAX_BLOCK_X - margin \
		and hit.z >= World.WORLD_MIN_BLOCK_Z + margin and hit.z <= World.WORLD_MAX_BLOCK_Z - margin


## Why is a chunk on screen but hidden? Repeats the void meter's test and records
## the state of up to three hidden chunks: eligibility, mesh, and where the
## camera is relative to the views that decide what is shown.
func _hidden_chunk_details() -> Array:
	var renderer = main.world.renderer
	var state = renderer.visibility_state
	var camera: Camera3D = main.camera
	var planes: Array = renderer.frustum_culler.build_planes(camera, renderer.NEAR_SAMPLE_OFFSET, renderer.NEAR_SAMPLE_MIN)
	var top_cy := floori(float(main.world.top_render_y) / World.CHUNK_SIZE)
	var args: Array = renderer._last_zone_args
	var found: Array = []
	var origin: Vector3 = camera.global_position
	for cy in [top_cy, top_cy - 1]:
		for cx in range(args[0], args[1] + 1):
			for cz in range(args[2], args[3] + 1):
				var coord := Vector3i(cx, cy, cz)
				if not renderer.is_drawn_part_in_view(planes, coord):
					continue
				var node: MeshInstance3D = renderer.chunk_cache.get_chunk(coord)
				if node == null or node.visible:
					continue
				var has_mesh: bool = node.mesh != null and node.mesh.get_surface_count() > 0
				if not has_mesh and not renderer.has_slice_cap(coord):
					continue
				var applied_bounds: Dictionary = renderer.diagnostics_render_bounds
				var at_applied: Variant = null
				if state._applied_origin_valid:
					var back: Array = state._translated_planes(planes, state._applied_origin - origin)
					at_applied = renderer.frustum_culler.is_chunk_in_view(back, coord, World.CHUNK_SIZE, 8.0)
				found.append({
					"applied_box": [applied_bounds.get("min_x"), applied_bounds.get("max_x"), applied_bounds.get("min_y"), applied_bounds.get("max_y"), applied_bounds.get("min_z"), applied_bounds.get("max_z")],
					"current_box": args.duplicate(), "accepted_by_applied_frustum": at_applied,
					"node_in_tree": node.is_inside_tree(),
					"coord": [cx, cy, cz], "eligible": state.eligible.members.has(coord), "has_mesh": has_mesh,
					"has_cap": renderer.has_slice_cap(coord),
					"in_batch_accepted": (not state._batch.is_empty()) and state._batch.accepted.has(coord),
					"batch_phase": state._phase if not state._batch.is_empty() else -1,
					"batch_mode": state._batch_mode if not state._batch.is_empty() else "",
					"from_applied": [origin.x - state._applied_origin.x, origin.y - state._applied_origin.y, origin.z - state._applied_origin.z] if state._applied_origin_valid else null,
					"from_batch": [origin.x - state._batch_origin.x, origin.z - state._batch_origin.z] if state._batch_origin_valid else null,
					"in_play": Array(state.scheduler.in_play_request_ids()), "requested": state.requested_sequence,
					"accepted": state.accepted_sequence, "applied": state.applied_sequence,
					"in_frustum_padded_now": renderer.frustum_culler.is_chunk_in_view(planes, coord, World.CHUNK_SIZE, 8.0),
				})
				if found.size() >= 3:
					return found
	return found


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
