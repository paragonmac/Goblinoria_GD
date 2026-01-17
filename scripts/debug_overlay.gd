class_name DebugOverlay
extends CanvasLayer
## Debug overlay for profiler, draw stats, and timing information.

#region Preloads
const CPUProfilerUIScript = preload("res://addons/proprofiler/cpu_profiler/ui/cpu_profiler_ui.gd")
#endregion

#region References
var world: World
var camera: Camera3D
var debug_profiler: DebugProfiler
#endregion

#region Visibility State
var show_profiler: bool = false
var show_draw_burden: bool = false
var show_debug_timings: bool = false
var show_streaming_stats: bool = false
var streaming_capture_enabled: bool = false
#endregion

#region UI Elements
var profiler_panel: PanelContainer
var profiler_ui: CPUProfilerUI
var draw_burden_label: Label
var draw_rendered_label: Label
var draw_memory_label: Label
var debug_timings_label: RichTextLabel
var streaming_stats_label: Label
#endregion

#region Constants
const DEBUG_TIMING_LINES := 12
const STREAMING_CAPTURE_INTERVAL := 0.25
const DEBUG_POLL_INTERVAL_SEC := 0.25
const MAP_EXPORT_RADIUS := 64
#endregion

#region Capture State
var streaming_capture_timer: float = 0.0
var streaming_capture_start_ms: int = 0
var streaming_capture_path := ""
var streaming_capture_lines: Array = []
var last_draw_burden_ms: int = 0
var last_streaming_stats_ms: int = 0
var last_debug_timings_ms: int = 0
#endregion


#region Lifecycle
func _ready() -> void:
	setup_profiler_ui()
	setup_draw_burden_label()
	setup_streaming_stats_label()
	setup_debug_timings_label()
#endregion


#region Initialization
func initialize(world_ref: World, camera_ref: Camera3D) -> void:
	world = world_ref
	camera = camera_ref
	debug_profiler = DebugProfiler.new()
	if world != null:
		world.debug_profiler = debug_profiler
	if world != null and world.pathfinder != null:
		world.pathfinder.debug_profiler = debug_profiler
#endregion


#region Toggle Functions
func toggle_profiler() -> void:
	show_profiler = not show_profiler
	if profiler_panel != null:
		profiler_panel.visible = show_profiler
	if profiler_ui != null:
		if show_profiler:
			profiler_ui.profiler.reset()
			profiler_ui.profiler.set_active(true)
		else:
			profiler_ui.profiler.set_active(false)


func toggle_draw_burden() -> void:
	show_draw_burden = not show_draw_burden
	if draw_burden_label != null:
		draw_burden_label.visible = show_draw_burden
	if draw_rendered_label != null:
		draw_rendered_label.visible = show_draw_burden
	if draw_memory_label != null:
		draw_memory_label.visible = show_draw_burden


func toggle_debug_timings() -> void:
	show_debug_timings = not show_debug_timings
	if debug_timings_label != null:
		debug_timings_label.visible = show_debug_timings
	if debug_profiler == null:
		return
	if show_debug_timings:
		debug_profiler.reset()
		debug_profiler.enabled = true
	else:
		debug_profiler.enabled = false


func toggle_streaming_stats() -> void:
	show_streaming_stats = not show_streaming_stats
	if streaming_stats_label != null:
		streaming_stats_label.visible = show_streaming_stats


func toggle_streaming_capture() -> void:
	streaming_capture_enabled = not streaming_capture_enabled
	if streaming_capture_enabled:
		_start_streaming_capture()
	else:
		_stop_streaming_capture()
#endregion


#region Timed Execution
func run_timed(label: String, callable: Callable) -> void:
	if show_debug_timings and debug_profiler != null and debug_profiler.enabled:
		debug_profiler.begin(label)
		callable.call()
		debug_profiler.end(label)
	else:
		callable.call()
#endregion


#region World Update
func step_world(dt: float) -> void:
	if world == null:
		return
	if show_debug_timings and debug_profiler != null and debug_profiler.enabled:
		debug_profiler.begin("World.process_generation_results")
		world.process_generation_results()
		debug_profiler.end("World.process_generation_results")

		debug_profiler.begin("World.update_render_height_queue")
		world.update_render_height_queue()
		debug_profiler.end("World.update_render_height_queue")

		debug_profiler.begin("World.update_workers")
		world.update_workers(dt)
		debug_profiler.end("World.update_workers")

		debug_profiler.begin("World.update_task_queue")
		world.update_task_queue()
		debug_profiler.end("World.update_task_queue")

		debug_profiler.begin("World.update_task_overlays")
		world.update_task_overlays_phase()
		debug_profiler.end("World.update_task_overlays")

		debug_profiler.begin("World.update_blocked_tasks")
		world.update_blocked_tasks(dt)
		debug_profiler.end("World.update_blocked_tasks")

		debug_profiler.finish_frame()
		update_debug_timings_label()
	else:
		world.update_world(dt)
#endregion


#region Draw Burden Updates
func update_draw_burden() -> void:
	if not show_draw_burden:
		return
	if world == null or camera == null:
		return
	if not _poll_due(last_draw_burden_ms):
		return
	last_draw_burden_ms = Time.get_ticks_msec()
	var stats: Dictionary = world.get_chunk_draw_stats()
	var loaded: int = int(stats.get("loaded", 0))
	var meshed: int = int(stats.get("meshed", 0))
	var visible: int = int(stats.get("visible", 0))
	var zone: int = int(stats.get("zone", 0))
	draw_burden_label.text = "Chunks Loaded/Meshed: %d/%d" % [loaded, meshed]
	draw_rendered_label.text = "Chunks Visible/Zone: %d/%d" % [visible, zone]

	var static_mem: float = float(Performance.get_monitor(Performance.MEMORY_STATIC))
	draw_memory_label.text = "Memory: static %.1f MB" % [
		static_mem / 1048576.0,
	]
#endregion


func update_streaming_stats() -> void:
	if not show_streaming_stats:
		return
	if streaming_stats_label == null or world == null:
		return
	if not _poll_due(last_streaming_stats_ms):
		return
	last_streaming_stats_ms = Time.get_ticks_msec()
	var stats := _collect_streaming_stats()
	streaming_stats_label.text = "Streaming chunks:%d build:%d pending:%s\nMesh q:%d res:%d act:%d pre:%d\nRadii s:%d r:%d u:%d\nBuffer %d (base %d max %d)" % [
		int(stats["loaded_chunks"]),
		int(stats["build_queue"]),
		"true" if int(stats["stream_pending"]) != 0 else "false",
		int(stats["mesh_job_queue"]),
		int(stats["mesh_result_queue"]),
		int(stats["mesh_job_set"]),
		int(stats["mesh_prefetch_set"]),
		int(stats["stream_radius"]),
		int(stats["render_radius"]),
		int(stats["unload_radius"]),
		int(stats["buffer_last"]),
		int(stats["buffer_base"]),
		int(stats["buffer_max"]),
	]


func update_streaming_capture(dt: float) -> void:
	if not streaming_capture_enabled:
		return
	if world == null:
		return
	streaming_capture_timer += dt
	if streaming_capture_timer < STREAMING_CAPTURE_INTERVAL:
		return
	streaming_capture_timer -= STREAMING_CAPTURE_INTERVAL
	var stats := _collect_streaming_stats()
	var overlay_stats := _collect_overlay_stats()
	var cam_pos := Vector3.ZERO
	if camera != null:
		cam_pos = camera.global_transform.origin
	var mem_static: float = float(Performance.get_monitor(Performance.MEMORY_STATIC)) / 1048576.0
	var now_ms: int = Time.get_ticks_msec() - streaming_capture_start_ms
	var overlay_positions_str := _format_overlay_positions(overlay_stats)
	var line := "%d,%.2f,%.2f,%.2f,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%.2f,%d,%d,%d,%d,\"%s\"" % [
		now_ms,
		cam_pos.x,
		cam_pos.y,
		cam_pos.z,
		int(stats["top_render_y"]),
		int(stats["loaded_chunks"]),
		int(stats["build_queue"]),
		int(stats["stream_pending"]),
		int(stats["stream_radius"]),
		int(stats["render_radius"]),
		int(stats["unload_radius"]),
		int(stats["buffer_last"]),
		int(stats["buffer_base"]),
		int(stats["buffer_max"]),
		int(stats["mesh_job_queue"]),
		int(stats["mesh_result_queue"]),
		int(stats["mesh_job_set"]),
		int(stats["mesh_prefetch_set"]),
		mem_static,
		int(overlay_stats.get("drag_count", 0)),
		int(overlay_stats.get("drag_visible_count", 0)),
		int(overlay_stats.get("task_count", 0)),
		int(overlay_stats.get("task_visible_count", 0)),
		overlay_positions_str,
	]
	streaming_capture_lines.append(line)


func _start_streaming_capture() -> void:
	streaming_capture_timer = 0.0
	streaming_capture_start_ms = Time.get_ticks_msec()
	streaming_capture_lines.clear()
	streaming_capture_path = "user://streaming_capture_%d.csv" % streaming_capture_start_ms
	streaming_capture_lines.append("t_ms,cam_x,cam_y,cam_z,top_render_y,loaded_chunks,build_queue,stream_pending,stream_radius,render_radius,unload_radius,buffer_last,buffer_base,buffer_max,mesh_job_queue,mesh_result_queue,mesh_job_set,mesh_prefetch_set,mem_static_mb,drag_count,drag_visible,task_count,task_visible,overlay_positions")
	print("Streaming capture started: %s" % streaming_capture_path)


func _stop_streaming_capture() -> void:
	if streaming_capture_path.is_empty():
		return
	var file := FileAccess.open(streaming_capture_path, FileAccess.WRITE)
	if file == null:
		push_warning("Streaming capture failed: %s" % streaming_capture_path)
		return
	file.store_string("\n".join(streaming_capture_lines))
	file.flush()
	print("Streaming capture saved: %s" % streaming_capture_path)
	streaming_capture_lines.clear()
	streaming_capture_path = ""


func _collect_overlay_stats() -> Dictionary:
	if world == null or world.renderer == null:
		return {}
	return world.renderer.get_overlay_debug_stats()


func _format_overlay_positions(overlay_stats: Dictionary) -> String:
	var parts: Array = []
	# Add parent/sample debug info
	var parent_pos: Vector3 = overlay_stats.get("parent_global_pos", Vector3.ZERO)
	var sample_pos: Vector3 = overlay_stats.get("sample_global_pos", Vector3.ZERO)
	var mesh_valid: bool = overlay_stats.get("sample_mesh_valid", false)
	var in_tree: bool = overlay_stats.get("sample_in_tree", false)
	var renderer_vis: bool = overlay_stats.get("overlay_renderer_visible", true)
	var chunk_origins: int = overlay_stats.get("chunk_origin_count", 0)
	var non_origins: int = overlay_stats.get("non_origin_count", 0)
	parts.append("PARENT[%.1f;%.1f;%.1f]" % [parent_pos.x, parent_pos.y, parent_pos.z])
	parts.append("SAMPLE[gpos:%.1f;%.1f;%.1f|mesh:%s|tree:%s|rvis:%s]" % [
		sample_pos.x, sample_pos.y, sample_pos.z,
		"y" if mesh_valid else "n",
		"y" if in_tree else "n",
		"y" if renderer_vis else "n"
	])
	parts.append("CHUNKS[origins:%d|non:%d]" % [chunk_origins, non_origins])
	# Add material debug info
	var mat_info: String = overlay_stats.get("sample_material_info", "")
	if not mat_info.is_empty():
		parts.append("MAT[%s]" % mat_info)
	var drag_positions: Array = overlay_stats.get("drag_positions", [])
	var task_positions: Array = overlay_stats.get("task_positions", [])
	# Limit to first 10 positions each to keep CSV manageable
	var max_positions := 10
	for i in range(min(drag_positions.size(), max_positions)):
		var pos: Vector3i = drag_positions[i]
		parts.append("d:%d;%d;%d" % [pos.x, pos.y, pos.z])
	if drag_positions.size() > max_positions:
		parts.append("d:+%d more" % (drag_positions.size() - max_positions))
	for i in range(min(task_positions.size(), max_positions)):
		var pos: Vector3i = task_positions[i]
		parts.append("t:%d;%d;%d" % [pos.x, pos.y, pos.z])
	if task_positions.size() > max_positions:
		parts.append("t:+%d more" % (task_positions.size() - max_positions))
	return "|".join(parts)


func _collect_streaming_stats() -> Dictionary:
	var stats := {
		"top_render_y": 0,
		"loaded_chunks": 0,
		"build_queue": 0,
		"stream_pending": 0,
		"stream_radius": 0,
		"render_radius": 0,
		"unload_radius": 0,
		"buffer_base": 0,
		"buffer_max": 0,
		"buffer_last": 0,
		"mesh_job_queue": 0,
		"mesh_result_queue": 0,
		"mesh_job_set": 0,
		"mesh_prefetch_set": 0,
	}
	if world == null:
		return stats
	stats["top_render_y"] = world.top_render_y
	stats["loaded_chunks"] = world.chunks.size()
	if world.streaming != null:
		var streaming: WorldStreaming = world.streaming
		stats["build_queue"] = streaming.chunk_build_queue.size()
		stats["stream_pending"] = 1 if streaming.stream_pending else 0
		stats["stream_radius"] = streaming.stream_radius_chunks
		stats["render_radius"] = streaming.render_radius_chunks
		stats["unload_radius"] = streaming.unload_radius_chunks
		stats["buffer_base"] = streaming.stream_base_buffer_chunks
		stats["buffer_max"] = streaming.stream_max_buffer_chunks
		stats["buffer_last"] = streaming.last_buffer_chunks
	if world.renderer != null:
		var mesh_stats: Dictionary = world.renderer.get_mesh_work_stats()
		stats["mesh_job_queue"] = int(mesh_stats.get("job_queue", 0))
		stats["mesh_result_queue"] = int(mesh_stats.get("result_queue", 0))
		stats["mesh_job_set"] = int(mesh_stats.get("job_set", 0))
		stats["mesh_prefetch_set"] = int(mesh_stats.get("prefetch_set", 0))
	return stats


#region UI Setup
func setup_profiler_ui() -> void:
	profiler_panel = PanelContainer.new()
	profiler_panel.name = "RuntimeProfiler"
	profiler_panel.offset_left = 10.0
	profiler_panel.offset_top = 60.0
	profiler_panel.offset_right = 760.0
	profiler_panel.offset_bottom = 560.0
	profiler_panel.visible = show_profiler

	profiler_ui = CPUProfilerUIScript.new()
	profiler_ui.profiler.set_active(false)
	profiler_panel.add_child(profiler_ui)
	add_child(profiler_panel)


func setup_draw_burden_label() -> void:
	draw_burden_label = Label.new()
	draw_burden_label.name = "DrawBurdenLabel"
	draw_burden_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	draw_burden_label.vertical_alignment = VERTICAL_ALIGNMENT_TOP
	draw_burden_label.anchor_left = 1.0
	draw_burden_label.anchor_right = 1.0
	draw_burden_label.offset_left = -420.0
	draw_burden_label.offset_top = 10.0
	draw_burden_label.offset_right = -10.0
	draw_burden_label.offset_bottom = 34.0
	draw_burden_label.text = ""
	draw_burden_label.visible = show_draw_burden
	add_child(draw_burden_label)

	draw_rendered_label = Label.new()
	draw_rendered_label.name = "DrawRenderedLabel"
	draw_rendered_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	draw_rendered_label.vertical_alignment = VERTICAL_ALIGNMENT_TOP
	draw_rendered_label.anchor_left = 1.0
	draw_rendered_label.anchor_right = 1.0
	draw_rendered_label.offset_left = -420.0
	draw_rendered_label.offset_top = 34.0
	draw_rendered_label.offset_right = -10.0
	draw_rendered_label.offset_bottom = 58.0
	draw_rendered_label.text = ""
	draw_rendered_label.visible = show_draw_burden
	add_child(draw_rendered_label)

	draw_memory_label = Label.new()
	draw_memory_label.name = "DrawMemoryLabel"
	draw_memory_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	draw_memory_label.vertical_alignment = VERTICAL_ALIGNMENT_TOP
	draw_memory_label.anchor_left = 1.0
	draw_memory_label.anchor_right = 1.0
	draw_memory_label.offset_left = -420.0
	draw_memory_label.offset_top = 58.0
	draw_memory_label.offset_right = -10.0
	draw_memory_label.offset_bottom = 82.0
	draw_memory_label.text = ""
	draw_memory_label.visible = show_draw_burden
	add_child(draw_memory_label)


func setup_streaming_stats_label() -> void:
	streaming_stats_label = Label.new()
	streaming_stats_label.name = "StreamingStatsLabel"
	streaming_stats_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	streaming_stats_label.vertical_alignment = VERTICAL_ALIGNMENT_TOP
	streaming_stats_label.anchor_left = 0.0
	streaming_stats_label.anchor_right = 0.0
	streaming_stats_label.offset_left = 10.0
	streaming_stats_label.offset_top = 10.0
	streaming_stats_label.offset_right = 380.0
	streaming_stats_label.offset_bottom = 86.0
	streaming_stats_label.text = ""
	streaming_stats_label.visible = show_streaming_stats
	add_child(streaming_stats_label)


func setup_debug_timings_label() -> void:
	debug_timings_label = RichTextLabel.new()
	debug_timings_label.name = "DebugTimingsLabel"
	debug_timings_label.bbcode_enabled = true
	debug_timings_label.anchor_top = 0.0
	debug_timings_label.anchor_bottom = 1.0
	debug_timings_label.offset_left = 10.0
	debug_timings_label.offset_top = 90.0
	debug_timings_label.offset_right = 520.0
	debug_timings_label.offset_bottom = -10.0
	debug_timings_label.text = ""
	debug_timings_label.visible = show_debug_timings
	add_child(debug_timings_label)
#endregion


#region Debug Timings
func update_debug_timings_label() -> void:
	if debug_timings_label == null:
		return
	if not show_debug_timings:
		return
	if not _poll_due(last_debug_timings_ms):
		return
	last_debug_timings_ms = Time.get_ticks_msec()
	var lines: Array = debug_profiler.get_report_lines(DEBUG_TIMING_LINES)
	debug_timings_label.text = "Debug Timings (ms)\n" + "\n".join(lines)
#endregion


func _poll_due(last_ms: int) -> bool:
	var now_ms: int = Time.get_ticks_msec()
	return float(now_ms - last_ms) >= DEBUG_POLL_INTERVAL_SEC * 1000.0


func dump_ramp_counts() -> void:
	if world == null:
		return
	var counts := {
		World.INNER_SOUTHWEST_ID: 0,
		World.INNER_SOUTHEAST_ID: 0,
		World.INNER_NORTHWEST_ID: 0,
		World.INNER_NORTHEAST_ID: 0,
	}
	var samples := {
		World.INNER_SOUTHWEST_ID: [],
		World.INNER_SOUTHEAST_ID: [],
		World.INNER_NORTHWEST_ID: [],
		World.INNER_NORTHEAST_ID: [],
	}
	var chunk_size: int = World.CHUNK_SIZE
	for coord_key in world.chunks.keys():
		var coord: Vector3i = coord_key
		var chunk: ChunkData = world.chunks[coord]
		if chunk == null or not chunk.generated:
			continue
		var blocks: PackedByteArray = chunk.blocks
		for idx in range(blocks.size()):
			var block_id: int = blocks[idx]
			if not counts.has(block_id):
				continue
			counts[block_id] += 1
			var list: Array = samples[block_id]
			if list.size() < 3:
				var lx: int = idx % chunk_size
				var ly: int = floori(float(idx) / float(chunk_size)) % chunk_size
				var lz: int = floori(float(idx) / float(chunk_size * chunk_size))
				var wx: int = coord.x * chunk_size + lx
				var wy: int = coord.y * chunk_size + ly
				var wz: int = coord.z * chunk_size + lz
				list.append(Vector3i(wx, wy, wz))
				samples[block_id] = list
	print("Inner ramps: sw=%d se=%d nw=%d ne=%d" % [
		counts[World.INNER_SOUTHWEST_ID],
		counts[World.INNER_SOUTHEAST_ID],
		counts[World.INNER_NORTHWEST_ID],
		counts[World.INNER_NORTHEAST_ID],
	])
	print("Inner ramp samples: sw=%s se=%s nw=%s ne=%s" % [
		samples[World.INNER_SOUTHWEST_ID],
		samples[World.INNER_SOUTHEAST_ID],
		samples[World.INNER_NORTHWEST_ID],
		samples[World.INNER_NORTHEAST_ID],
	])


func export_map_snapshot(radius: int = MAP_EXPORT_RADIUS, loaded_only: bool = true) -> void:
	if world == null:
		return
	var center: Vector3i = world.spawn_coord
	var stamp: int = Time.get_ticks_msec()
	var base_path := "user://map_export_%d" % stamp
	var height_path := "%s_height.csv" % base_path
	var ramp_path := "%s_ramps.csv" % base_path

	var height_file := FileAccess.open(height_path, FileAccess.WRITE)
	if height_file == null:
		push_warning("Map export failed: %s" % height_path)
		return
	height_file.store_line("x,z,loaded,surface_y,top_block_id")

	var ramp_file := FileAccess.open(ramp_path, FileAccess.WRITE)
	if ramp_file == null:
		push_warning("Map export failed: %s" % ramp_path)
		ramp_path = ""

	var loaded_columns := {}
	if loaded_only:
		for coord_key in world.chunks.keys():
			var coord: Vector3i = coord_key
			loaded_columns[Vector2i(coord.x, coord.z)] = true

	var chunk_size: int = World.CHUNK_SIZE
	var min_x: int = center.x - radius
	var max_x: int = center.x + radius
	var min_z: int = center.z - radius
	var max_z: int = center.z + radius
	for x in range(min_x, max_x + 1):
		var cx: int = world.floor_div(x, chunk_size)
		for z in range(min_z, max_z + 1):
			var cz: int = world.floor_div(z, chunk_size)
			var loaded := true
			if loaded_only:
				loaded = loaded_columns.has(Vector2i(cx, cz))
			var surface_y := -1
			var top_id := World.BLOCK_ID_AIR
			if loaded:
				for y in range(world.world_size_y - 1, -1, -1):
					var block_id: int = world.get_block_no_generate(x, y, z)
					if block_id != World.BLOCK_ID_AIR:
						surface_y = y
						top_id = block_id
						break
			height_file.store_line("%d,%d,%d,%d,%d" % [x, z, 1 if loaded else 0, surface_y, top_id])

	if ramp_file != null:
		ramp_file.store_line("x,y,z,ramp_id")
		for coord_key in world.chunks.keys():
			var coord: Vector3i = coord_key
			var chunk: ChunkData = world.chunks[coord]
			if chunk == null or not chunk.generated:
				continue
			var blocks: PackedByteArray = chunk.blocks
			for idx in range(blocks.size()):
				var block_id: int = blocks[idx]
				if not world.is_ramp_block_id(block_id):
					continue
				var lx: int = idx % chunk_size
				var ly: int = floori(float(idx) / float(chunk_size)) % chunk_size
				var lz: int = floori(float(idx) / float(chunk_size * chunk_size))
				var wx: int = coord.x * chunk_size + lx
				var wy: int = coord.y * chunk_size + ly
				var wz: int = coord.z * chunk_size + lz
				ramp_file.store_line("%d,%d,%d,%d" % [wx, wy, wz, block_id])
		ramp_file.flush()

	height_file.flush()
	print("Map export saved: %s%s" % [
		height_path,
		"" if ramp_path.is_empty() else " | " + ramp_path,
	])
