extends RefCounted
## Engine-side frame measurements for diagnostics. Read-only queries: nothing
## here changes scheduling or rendering except the opt-in render-time flag.
##
## Values describe the most recently rendered frame, so they trail the script
## frame that reads them by one frame. The headless display server has no
## renderer; render values are then omitted, never reported as zero.

const GAUGES := {
	"Engine.draw_calls": RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME,
	"Engine.primitives": RenderingServer.RENDERING_INFO_TOTAL_PRIMITIVES_IN_FRAME,
	"Engine.objects": RenderingServer.RENDERING_INFO_TOTAL_OBJECTS_IN_FRAME,
}
## Per-pass split of the totals above for one viewport.
const PASS_GAUGES := [
	["Engine.visible_draw_calls", RenderingServer.VIEWPORT_RENDER_INFO_TYPE_VISIBLE, RenderingServer.VIEWPORT_RENDER_INFO_DRAW_CALLS_IN_FRAME],
	["Engine.visible_primitives", RenderingServer.VIEWPORT_RENDER_INFO_TYPE_VISIBLE, RenderingServer.VIEWPORT_RENDER_INFO_PRIMITIVES_IN_FRAME],
	["Engine.visible_objects", RenderingServer.VIEWPORT_RENDER_INFO_TYPE_VISIBLE, RenderingServer.VIEWPORT_RENDER_INFO_OBJECTS_IN_FRAME],
	["Engine.shadow_draw_calls", RenderingServer.VIEWPORT_RENDER_INFO_TYPE_SHADOW, RenderingServer.VIEWPORT_RENDER_INFO_DRAW_CALLS_IN_FRAME],
	["Engine.shadow_primitives", RenderingServer.VIEWPORT_RENDER_INFO_TYPE_SHADOW, RenderingServer.VIEWPORT_RENDER_INFO_PRIMITIVES_IN_FRAME],
	["Engine.shadow_objects", RenderingServer.VIEWPORT_RENDER_INFO_TYPE_SHADOW, RenderingServer.VIEWPORT_RENDER_INFO_OBJECTS_IN_FRAME],
]
const MEMORY_INFO := {
	"engine_video_mem_bytes": RenderingServer.RENDERING_INFO_VIDEO_MEM_USED,
	"engine_texture_mem_bytes": RenderingServer.RENDERING_INFO_TEXTURE_MEM_USED,
	"engine_buffer_mem_bytes": RenderingServer.RENDERING_INFO_BUFFER_MEM_USED,
}
const OBJECT_MONITORS := {
	"engine_object_count": Performance.OBJECT_COUNT,
	"engine_node_count": Performance.OBJECT_NODE_COUNT,
	"engine_orphan_node_count": Performance.OBJECT_ORPHAN_NODE_COUNT,
	"engine_resource_count": Performance.OBJECT_RESOURCE_COUNT,
}

## Viewports whose render time is being measured, keyed by RID.
static var _measuring: Dictionary = {}


static func has_renderer() -> bool:
	return DisplayServer.get_name() != "headless"


## Render CPU/GPU time costs the engine a pair of timestamp queries per frame,
## so it is only measured on request.
static func set_measuring(viewport: RID, enabled: bool) -> void:
	if not viewport.is_valid() or not has_renderer() or _measuring.has(viewport) == enabled:
		return
	RenderingServer.viewport_set_measure_render_time(viewport, enabled)
	if enabled:
		_measuring[viewport] = true
	else:
		_measuring.erase(viewport)


static func is_measuring(viewport: RID) -> bool:
	return _measuring.has(viewport)


## Millisecond values for one frame. Render times appear only while measured.
static func frame_timings(viewport: RID) -> Dictionary:
	var timings := {}
	if has_renderer() and _measuring.has(viewport):
		timings["Engine.render_cpu_ms"] = RenderingServer.viewport_get_measured_render_time_cpu(viewport)
		timings["Engine.render_gpu_ms"] = RenderingServer.viewport_get_measured_render_time_gpu(viewport)
		timings["Engine.frame_setup_cpu_ms"] = RenderingServer.get_frame_setup_time_cpu()
	return timings


## Unitless per-frame counts. Empty without a renderer.
static func frame_gauges(viewport: RID) -> Dictionary:
	var gauges := {}
	if not has_renderer():
		return gauges
	for label: String in GAUGES:
		gauges[label] = RenderingServer.get_rendering_info(GAUGES[label])
	if viewport.is_valid():
		for entry: Array in PASS_GAUGES:
			gauges[entry[0]] = RenderingServer.viewport_get_render_info(viewport, entry[1], entry[2])
	return gauges


## Slow-moving totals for once-per-second workload rows. Null means unavailable.
static func memory_snapshot() -> Dictionary:
	var values := {}
	for label: String in MEMORY_INFO:
		values[label] = RenderingServer.get_rendering_info(MEMORY_INFO[label]) if has_renderer() else null
	for label: String in OBJECT_MONITORS:
		values[label] = int(Performance.get_monitor(OBJECT_MONITORS[label]))
	values["memory_static_max_bytes"] = int(Performance.get_monitor(Performance.MEMORY_STATIC_MAX)) if OS.is_debug_build() else null
	# The engine publishes these once a second as the slowest frame of that
	# second, not as a per-frame value.
	values["engine_process_max_ms_last_second"] = Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0
	values["engine_physics_max_ms_last_second"] = Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0
	return values


## One read of everything, for on-demand inspection.
static func snapshot(viewport: RID) -> Dictionary:
	return {
		"renderer_available": has_renderer(),
		"render_time_measured": is_measuring(viewport),
		"timings_ms": frame_timings(viewport),
		"gauges": frame_gauges(viewport),
		"memory": memory_snapshot(),
	}
