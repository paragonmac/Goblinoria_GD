extends Node3D
class_name OverlayRenderer
## Renders task overlays and drag preview boxes for block operations.

#region Constants
const TASK_OVERLAY_SIZE := Vector3(1.0, 1.0, 1.0)
const DRAG_PREVIEW_SIZE := Vector3(1.0, 1.0, 1.0)
const USE_FLAT_OVERLAYS := false
const FLAT_OVERLAY_SIZE := Vector2(1.0, 1.0)
const UNKNOWN_OVERLAY_ALPHA := 0.25
const PATHABLE_OVERLAY_ALPHA := 0.25
const BLOCKED_OVERLAY_ALPHA := 0.25
const ASSIGNED_OVERLAY_ALPHA := 0.25
const DRAG_OVERLAY_ALPHA := 0.5
const DRAG_DEFAULT_ALPHA := 0.5
const UNKNOWN_TASK_COLOR := Color(0.2, 1.0, 0.2)
const PATHABLE_TASK_COLOR := Color(0.15, 0.55, 1.0)
const BLOCKED_TASK_COLOR := Color(1.0, 0.15, 0.15)
const ASSIGNED_TASK_COLOR := Color(1.0, 0.75, 0.08)
const TASK_EMISSION_STRENGTH := 0.18
const ASSIGNED_PULSE_STRENGTH := 0.16
const ASSIGNED_PULSE_SPEED := 4.0
const DRAG_DIG_COLOR := Color(0.2, 1.0, 0.2)
const DRAG_PLACE_COLOR := Color(0.2, 0.6, 1.0)
const DRAG_STAIRS_COLOR := Color(1.0, 0.7, 0.2)
const DRAG_DEFAULT_COLOR := Color(0.8, 0.8, 0.8)
const ASSIGNED_OVERLAY_SCALE := Vector3(1.08, 1.0, 1.08)
const ROUND_HALF := 0.5
const OVERLAY_Y_OFFSET := 0.0  # 3D box centered at block position (use 0.52 for flat overlays)
const OVERLAY_SHADER_CODE := """shader_type spatial;
render_mode unshaded, cull_back, depth_draw_never;

uniform vec4 albedo_color : source_color = vec4(1.0, 1.0, 1.0, 0.5);
uniform float top_render_y = 1000.0;
uniform float emission_strength = 0.18;
uniform float pulse_strength = 0.0;
uniform float pulse_speed = 4.0;

varying float world_y;

void vertex() {
	world_y = (MODEL_MATRIX * vec4(VERTEX, 1.0)).y;
	VERTEX += NORMAL * 0.001;  // Small offset to avoid z-fighting
}

void fragment() {
	if (world_y > top_render_y + 0.5) {
		discard;
	}
	float pulse = 1.0 + pulse_strength * (0.5 + 0.5 * sin(TIME * pulse_speed));
	vec3 display_color = min(albedo_color.rgb * pulse, vec3(1.0));
	ALBEDO = display_color;
	EMISSION = display_color * emission_strength;
	ALPHA = albedo_color.a;
}
"""
var overlay_shader: Shader = null
var all_overlay_materials: Array = []
#endregion

#region State
var world: World
var task_overlays: Dictionary = {}
var task_materials: Dictionary = {}
var task_trace_records: Dictionary = {}
var task_trace_enabled_last := false
var drag_previews: Dictionary = {}
var drag_materials: Dictionary = {}
#endregion


#region Initialization
func initialize(world_ref: World) -> void:
	world = world_ref
	_ensure_shader()


func _ensure_shader() -> void:
	if overlay_shader == null:
		overlay_shader = Shader.new()
		overlay_shader.code = OVERLAY_SHADER_CODE


func _create_overlay_shader_material(color: Color, emission_strength: float = 0.0) -> ShaderMaterial:
	_ensure_shader()
	var mat := ShaderMaterial.new()
	mat.shader = overlay_shader
	mat.set_shader_parameter("albedo_color", color)
	mat.set_shader_parameter("emission_strength", emission_strength)
	mat.set_shader_parameter("pulse_speed", ASSIGNED_PULSE_SPEED)
	if world != null:
		mat.set_shader_parameter("top_render_y", float(world.top_render_y))
	mat.render_priority = 100  # Render after terrain
	all_overlay_materials.append(mat)
	return mat


func set_top_render_y(value: int) -> void:
	for mat in all_overlay_materials:
		if mat != null and is_instance_valid(mat):
			mat.set_shader_parameter("top_render_y", float(value))
#endregion


#region Task Overlays
func clear_task_overlays() -> void:
	for key in task_overlays.keys():
		task_overlays[key].queue_free()
	task_overlays.clear()
	task_trace_records.clear()


func update_task_overlays(tasks: Array, blocked_tasks: Array) -> void:
	if world == null:
		return
	_sync_task_trace_session()
	var live_ids: Dictionary = {}
	for task in tasks:
		if task.status == TaskQueue.TaskStatus.COMPLETED:
			continue
		live_ids[task.id] = true
		if not task_overlays.has(task.id):
			task_overlays[task.id] = create_task_overlay(task)
		var overlay: MeshInstance3D = task_overlays[task.id]
		var visual_state := task_overlay_state(task)
		var desired_material := get_task_material(visual_state)
		if overlay.material_override != desired_material:
			overlay.material_override = desired_material
		overlay.scale = ASSIGNED_OVERLAY_SCALE if visual_state == TaskOverlayState.ASSIGNED else Vector3.ONE
		overlay.position = Vector3(task.pos.x, task.pos.y + OVERLAY_Y_OFFSET, task.pos.z)
		overlay.visible = world.is_visible_at_level(task.pos.y)
		_trace_task_overlay(task, overlay, visual_state)

	for blocked in blocked_tasks:
		var key := blocked_task_key(blocked)
		live_ids[key] = true
		if not task_overlays.has(key):
			task_overlays[key] = create_blocked_task_overlay(blocked["type"])
		var blocked_overlay: MeshInstance3D = task_overlays[key]
		var blocked_pos: Vector3i = blocked["pos"]
		blocked_overlay.position = Vector3(blocked_pos.x, blocked_pos.y + OVERLAY_Y_OFFSET, blocked_pos.z)
		blocked_overlay.visible = world.is_visible_at_level(blocked_pos.y)

	for task_id in task_overlays.keys():
		if not live_ids.has(task_id):
			_trace_task_overlay_removed(task_id)
			task_overlays[task_id].queue_free()
			task_overlays.erase(task_id)
#endregion


#region Overlay Helpers
func blocked_task_key(task: Dictionary) -> String:
	var pos: Vector3i = task["pos"]
	return "blocked:%s:%s:%s:%s" % [task["type"], pos.x, pos.y, pos.z]


enum TaskOverlayState {
	# SEE-ADR-004: These states are player-facing task meanings, not arbitrary colors.
	UNKNOWN,
	BLOCKED,
	PATHABLE,
	ASSIGNED,
}


func task_overlay_state(task) -> int:
	if task.status == TaskQueue.TaskStatus.IN_PROGRESS and task.assigned_worker != null:
		return TaskOverlayState.ASSIGNED
	if task.accessibility == TaskQueue.TaskAccessibility.REACHABLE:
		return TaskOverlayState.PATHABLE
	if task.accessibility == TaskQueue.TaskAccessibility.UNREACHABLE:
		return TaskOverlayState.BLOCKED
	return TaskOverlayState.UNKNOWN


func task_state_color(state: int) -> Color:
	match state:
		TaskOverlayState.UNKNOWN:
			return Color(UNKNOWN_TASK_COLOR.r, UNKNOWN_TASK_COLOR.g, UNKNOWN_TASK_COLOR.b, UNKNOWN_OVERLAY_ALPHA)
		TaskOverlayState.PATHABLE:
			return Color(PATHABLE_TASK_COLOR.r, PATHABLE_TASK_COLOR.g, PATHABLE_TASK_COLOR.b, PATHABLE_OVERLAY_ALPHA)
		TaskOverlayState.ASSIGNED:
			return Color(ASSIGNED_TASK_COLOR.r, ASSIGNED_TASK_COLOR.g, ASSIGNED_TASK_COLOR.b, ASSIGNED_OVERLAY_ALPHA)
	return Color(BLOCKED_TASK_COLOR.r, BLOCKED_TASK_COLOR.g, BLOCKED_TASK_COLOR.b, BLOCKED_OVERLAY_ALPHA)


func task_state_name(state: int) -> String:
	match state:
		TaskOverlayState.UNKNOWN:
			return "GREEN_UNKNOWN"
		TaskOverlayState.PATHABLE:
			return "BLUE_PATHABLE"
		TaskOverlayState.ASSIGNED:
			return "AMBER_ASSIGNED"
	return "RED_BLOCKED"


func get_task_material(state: int) -> ShaderMaterial:
	if task_materials.has(state):
		return task_materials[state]
	var material := _create_overlay_shader_material(task_state_color(state), TASK_EMISSION_STRENGTH)
	if state == TaskOverlayState.ASSIGNED:
		material.set_shader_parameter("pulse_strength", ASSIGNED_PULSE_STRENGTH)
	task_materials[state] = material
	return material


func create_task_overlay(task) -> MeshInstance3D:
	var mesh_instance := MeshInstance3D.new()
	if USE_FLAT_OVERLAYS:
		var quad := QuadMesh.new()
		quad.size = FLAT_OVERLAY_SIZE
		mesh_instance.mesh = quad
		mesh_instance.rotation_degrees.x = -90  # Face up
	else:
		var box := BoxMesh.new()
		box.size = TASK_OVERLAY_SIZE
		mesh_instance.mesh = box

	mesh_instance.material_override = get_task_material(task_overlay_state(task))
	_apply_overlay_instance_settings(mesh_instance)
	add_child(mesh_instance)
	return mesh_instance


func create_blocked_task_overlay(_task_type: int) -> MeshInstance3D:
	var mesh_instance := MeshInstance3D.new()
	if USE_FLAT_OVERLAYS:
		var quad := QuadMesh.new()
		quad.size = FLAT_OVERLAY_SIZE
		mesh_instance.mesh = quad
		mesh_instance.rotation_degrees.x = -90  # Face up
	else:
		var box := BoxMesh.new()
		box.size = TASK_OVERLAY_SIZE
		mesh_instance.mesh = box

	mesh_instance.material_override = get_task_material(TaskOverlayState.BLOCKED)
	_apply_overlay_instance_settings(mesh_instance)
	add_child(mesh_instance)
	return mesh_instance
#endregion


#region Task Overlay Trace
func _sync_task_trace_session() -> void:
	var trace_enabled: bool = world.worker_trace != null and world.worker_trace.enabled
	if trace_enabled and not task_trace_enabled_last:
		task_trace_records.clear()
	elif not trace_enabled:
		task_trace_records.clear()
	task_trace_enabled_last = trace_enabled


func _trace_task_overlay(task, overlay: MeshInstance3D, visual_state: int) -> void:
	if not task_trace_enabled_last:
		return
	var color := task_state_color(visual_state)
	var signature := "%d|%s|%s|%s|%s|%s" % [
		visual_state,
		overlay.visible,
		overlay.is_visible_in_tree(),
		overlay.mesh != null,
		overlay.material_override != null,
		overlay.scale,
	]
	var previous: Dictionary = task_trace_records.get(task.id, {})
	if previous.get("signature", "") == signature:
		return
	var assigned_worker_id := -1
	if task.assigned_worker != null:
		assigned_worker_id = task.assigned_worker.worker_id
	var details := "color_state=%s rgba=%.3f|%.3f|%.3f|%.3f status=%s accessibility=%s assigned_worker=%d node_visible=%s visible_in_tree=%s mesh_valid=%s material_valid=%s scale=%s top_render_y=%d" % [
		task_state_name(visual_state),
		color.r,
		color.g,
		color.b,
		color.a,
		TaskQueue.TaskStatus.keys()[task.status],
		TaskQueue.TaskAccessibility.keys()[task.accessibility],
		assigned_worker_id,
		overlay.visible,
		overlay.is_visible_in_tree(),
		overlay.mesh != null,
		overlay.material_override != null,
		overlay.scale,
		world.top_render_y,
	]
	world.trace_task_event(task, "block_color_changed", details)
	task_trace_records[task.id] = {
		"signature": signature,
		"task": task,
		"color_state": task_state_name(visual_state),
	}


func _trace_task_overlay_removed(task_id) -> void:
	if not task_trace_enabled_last or not task_trace_records.has(task_id):
		return
	var record: Dictionary = task_trace_records[task_id]
	var task = record.get("task")
	if task != null:
		world.trace_task_event(
			task,
			"block_color_removed",
			"previous_color_state=%s reason=task completed or removed" % record.get("color_state", "UNKNOWN")
		)
	task_trace_records.erase(task_id)
#endregion


#region Drag Preview
func drag_preview_key(x: int, y: int, z: int) -> String:
	return "preview:%s:%s:%s" % [x, y, z]


func drag_preview_color(mode: int) -> Color:
	match mode:
		World.PlayerMode.DIG:
			return Color(DRAG_DIG_COLOR.r, DRAG_DIG_COLOR.g, DRAG_DIG_COLOR.b, DRAG_OVERLAY_ALPHA)
		World.PlayerMode.PLACE:
			return Color(DRAG_PLACE_COLOR.r, DRAG_PLACE_COLOR.g, DRAG_PLACE_COLOR.b, DRAG_OVERLAY_ALPHA)
		World.PlayerMode.STAIRS:
			return Color(DRAG_STAIRS_COLOR.r, DRAG_STAIRS_COLOR.g, DRAG_STAIRS_COLOR.b, DRAG_OVERLAY_ALPHA)
	return Color(DRAG_DEFAULT_COLOR.r, DRAG_DEFAULT_COLOR.g, DRAG_DEFAULT_COLOR.b, DRAG_DEFAULT_ALPHA)


func get_drag_material(mode: int) -> ShaderMaterial:
	if drag_materials.has(mode):
		return drag_materials[mode]
	var color := drag_preview_color(mode)
	var material := _create_overlay_shader_material(color)
	drag_materials[mode] = material
	return material


func _apply_overlay_instance_settings(mesh_instance: MeshInstance3D) -> void:
	mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mesh_instance.extra_cull_margin = 1000.0  # Prevent frustum culling issues
	mesh_instance.gi_mode = GeometryInstance3D.GI_MODE_DISABLED


func create_drag_preview_overlay(mode: int) -> MeshInstance3D:
	var mesh_instance := MeshInstance3D.new()
	if USE_FLAT_OVERLAYS:
		var quad := QuadMesh.new()
		quad.size = FLAT_OVERLAY_SIZE
		mesh_instance.mesh = quad
		mesh_instance.rotation_degrees.x = -90  # Face up
	else:
		var box := BoxMesh.new()
		box.size = DRAG_PREVIEW_SIZE
		mesh_instance.mesh = box
	mesh_instance.material_override = get_drag_material(mode)
	_apply_overlay_instance_settings(mesh_instance)
	add_child(mesh_instance)
	return mesh_instance


func set_drag_preview(rect: Dictionary, mode: int) -> void:
	if rect.is_empty():
		clear_drag_preview()
		return
	var min_x: int = int(floor(float(rect["min_x"]) + ROUND_HALF))
	var max_x: int = int(floor(float(rect["max_x"]) + ROUND_HALF))
	var min_z: int = int(floor(float(rect["min_z"]) + ROUND_HALF))
	var max_z: int = int(floor(float(rect["max_z"]) + ROUND_HALF))
	var y: int = int(rect["y"])
	var positions: Array[Vector3i] = []
	for x in range(min_x, max_x + 1):
		for z in range(min_z, max_z + 1):
			positions.append(Vector3i(x, y, z))
	set_drag_preview_positions(positions, mode)


func set_drag_preview_positions(positions: Array[Vector3i], mode: int) -> void:
	var live_ids: Dictionary = {}
	for pos: Vector3i in positions:
		var key := drag_preview_key(pos.x, pos.y, pos.z)
		live_ids[key] = true
		var overlay: MeshInstance3D
		if not drag_previews.has(key):
			overlay = create_drag_preview_overlay(mode)
			drag_previews[key] = overlay
		else:
			overlay = drag_previews[key]
			var desired := get_drag_material(mode)
			if overlay.material_override != desired:
				overlay.material_override = desired
		overlay.position = Vector3(pos.x, pos.y + OVERLAY_Y_OFFSET, pos.z)
		overlay.visible = world.is_visible_at_level(pos.y)

	for key in drag_previews.keys():
		if not live_ids.has(key):
			drag_previews[key].queue_free()
			drag_previews.erase(key)


func clear_drag_preview() -> void:
	for key in drag_previews.keys():
		drag_previews[key].queue_free()
	drag_previews.clear()
#endregion


#region Debug Stats
const CHUNK_SIZE := 8

func get_overlay_debug_stats() -> Dictionary:
	var stats := {
		"drag_count": drag_previews.size(),
		"task_count": task_overlays.size(),
		"drag_positions": [],
		"task_positions": [],
		"drag_visible_count": 0,
		"task_visible_count": 0,
		"sample_material_info": "",
		"parent_global_pos": Vector3.ZERO,
		"sample_global_pos": Vector3.ZERO,
		"sample_mesh_valid": false,
		"sample_in_tree": false,
		"overlay_renderer_visible": visible,
		"chunk_origin_count": 0,
		"non_origin_count": 0,
	}
	stats["parent_global_pos"] = global_position
	for key in drag_previews.keys():
		var overlay: MeshInstance3D = drag_previews[key]
		var pos := overlay.position
		var px := int(pos.x)
		var pz := int(pos.z)
		stats["drag_positions"].append(Vector3i(px, int(pos.y), pz))
		if overlay.visible:
			stats["drag_visible_count"] += 1
		# Check if this is a chunk origin position
		if posmod(px, CHUNK_SIZE) == 0 and posmod(pz, CHUNK_SIZE) == 0:
			stats["chunk_origin_count"] += 1
		else:
			stats["non_origin_count"] += 1
		if stats["sample_material_info"].is_empty():
			stats["sample_material_info"] = _get_material_debug_info(overlay, "drag")
			stats["sample_global_pos"] = overlay.global_position
			stats["sample_mesh_valid"] = overlay.mesh != null
			stats["sample_in_tree"] = overlay.is_inside_tree()
	for key in task_overlays.keys():
		var overlay: MeshInstance3D = task_overlays[key]
		var pos := overlay.position
		var px := int(pos.x)
		var pz := int(pos.z)
		stats["task_positions"].append(Vector3i(px, int(pos.y), pz))
		if overlay.visible:
			stats["task_visible_count"] += 1
		if posmod(px, CHUNK_SIZE) == 0 and posmod(pz, CHUNK_SIZE) == 0:
			stats["chunk_origin_count"] += 1
		else:
			stats["non_origin_count"] += 1
	return stats


func _get_material_debug_info(mesh_instance: MeshInstance3D, label: String) -> String:
	var info_parts: Array = [label]
	info_parts.append("layer:%d" % mesh_instance.layers)
	info_parts.append("shadow:%d" % mesh_instance.cast_shadow)
	var mat := mesh_instance.material_override
	if mat == null:
		info_parts.append("mat:null")
	elif mat is ShaderMaterial:
		info_parts.append("mat:shader")
		info_parts.append("depth_test:disabled_by_shader")
	elif mat is StandardMaterial3D:
		var std := mat as StandardMaterial3D
		info_parts.append("depth_test:%s" % ("off" if std.no_depth_test else "on"))
		info_parts.append("depth_draw:%d" % std.depth_draw_mode)
		info_parts.append("cull:%d" % std.cull_mode)
		info_parts.append("trans:%d" % std.transparency)
		info_parts.append("shading:%d" % std.shading_mode)
	else:
		info_parts.append("mat:other")
	return ";".join(info_parts)
#endregion
