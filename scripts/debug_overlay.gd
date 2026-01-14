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
#endregion

#region UI Elements
var profiler_panel: PanelContainer
var profiler_ui: CPUProfilerUI
var draw_burden_label: Label
var draw_rendered_label: Label
var draw_memory_label: Label
var debug_timings_label: RichTextLabel
#endregion

#region Constants
const DEBUG_TIMING_LINES := 12
#endregion


#region Lifecycle
func _ready() -> void:
	setup_profiler_ui()
	setup_draw_burden_label()
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
	var stats: Dictionary = world.get_draw_burden_stats()
	var drawn: int = int(stats.get("drawn", 0))
	var culled: int = int(stats.get("culled", 0))
	var percent: float = float(stats.get("percent", 0.0))
	draw_burden_label.text = "Tris Drawn/Culled: %d/%d (%.1f%%)" % [drawn, culled, percent]

	var rendered_stats: Dictionary = world.get_camera_tris_rendered(camera)
	var rendered: int = int(rendered_stats.get("rendered", 0))
	var total: int = int(rendered_stats.get("total", 0))
	var render_percent: float = float(rendered_stats.get("percent", 0.0))
	draw_rendered_label.text = "Tris Rendered: %d/%d (%.1f%%)" % [rendered, total, render_percent]

	var static_mem: float = float(Performance.get_monitor(Performance.MEMORY_STATIC))
	draw_memory_label.text = "Memory: static %.1f MB" % [
		static_mem / 1048576.0,
	]
#endregion


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
	var lines: Array = debug_profiler.get_report_lines(DEBUG_TIMING_LINES)
	debug_timings_label.text = "Debug Timings (ms)\n" + "\n".join(lines)
#endregion
