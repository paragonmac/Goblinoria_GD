extends Node3D
class_name OverlayRenderer
## Renders task overlays and drag preview boxes for block operations.

#region Constants
const TASK_OVERLAY_SIZE := Vector3(1.05, 1.05, 1.05)
const DRAG_PREVIEW_SIZE := Vector3(1.02, 1.02, 1.02)
const USE_FLAT_OVERLAYS := true
const FLAT_OVERLAY_SIZE := Vector2(1.0, 1.0)
const TASK_OVERLAY_ALPHA := 0.7
const BLOCKED_OVERLAY_ALPHA := 0.35
const DRAG_OVERLAY_ALPHA := 0.45
const DRAG_DEFAULT_ALPHA := 0.35
const DIG_TASK_COLOR := Color(1.0, 0.2, 0.2)
const PLACE_TASK_COLOR := Color(0.2, 0.2, 1.0)
const STAIRS_TASK_COLOR := Color(0.7, 0.5, 0.2)
const DRAG_DIG_COLOR := Color(0.2, 1.0, 0.2)
const DRAG_PLACE_COLOR := Color(0.2, 0.6, 1.0)
const DRAG_STAIRS_COLOR := Color(1.0, 0.7, 0.2)
const DRAG_DEFAULT_COLOR := Color(0.8, 0.8, 0.8)
const ROUND_HALF := 0.5
const COLOR_MAX := 1.0
const OVERLAY_Y_OFFSET := 0.52  # Place flat quad just above block top face (0.5 + small margin)
const OVERLAY_SHADER_CODE := """shader_type spatial;
render_mode unshaded, cull_disabled, depth_test_disabled;

uniform vec4 albedo_color : source_color = vec4(1.0, 1.0, 1.0, 0.5);

void fragment() {
	ALBEDO = albedo_color.rgb;
	ALPHA = albedo_color.a;
}
"""
var overlay_shader: Shader = null
#endregion

#region State
var world: World
var task_overlays: Dictionary = {}
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


func _create_overlay_shader_material(color: Color) -> ShaderMaterial:
	_ensure_shader()
	var mat := ShaderMaterial.new()
	mat.shader = overlay_shader
	mat.set_shader_parameter("albedo_color", color)
	mat.render_priority = 100  # Render after terrain
	return mat
#endregion


#region Task Overlays
func clear_task_overlays() -> void:
	for key in task_overlays.keys():
		task_overlays[key].queue_free()
	task_overlays.clear()


func update_task_overlays(tasks: Array, blocked_tasks: Array) -> void:
	if world == null:
		return
	var live_ids: Dictionary = {}
	for task in tasks:
		if task.status == TaskQueue.TaskStatus.COMPLETED:
			continue
		live_ids[task.id] = true
		if not task_overlays.has(task.id):
			task_overlays[task.id] = create_task_overlay(task)
		var overlay: MeshInstance3D = task_overlays[task.id]
		overlay.position = Vector3(task.pos.x, task.pos.y + OVERLAY_Y_OFFSET, task.pos.z)
		overlay.visible = world.is_visible_at_level(task.pos.y)

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
			task_overlays[task_id].queue_free()
			task_overlays.erase(task_id)
#endregion


#region Overlay Helpers
func blocked_task_key(task: Dictionary) -> String:
	var pos: Vector3i = task["pos"]
	return "blocked:%s:%s:%s:%s" % [task["type"], pos.x, pos.y, pos.z]


func task_type_color(task_type: int, alpha: float) -> Color:
	match task_type:
		TaskQueue.TaskType.DIG:
			return Color(DIG_TASK_COLOR.r, DIG_TASK_COLOR.g, DIG_TASK_COLOR.b, alpha)
		TaskQueue.TaskType.PLACE:
			return Color(PLACE_TASK_COLOR.r, PLACE_TASK_COLOR.g, PLACE_TASK_COLOR.b, alpha)
		TaskQueue.TaskType.STAIRS:
			return Color(STAIRS_TASK_COLOR.r, STAIRS_TASK_COLOR.g, STAIRS_TASK_COLOR.b, alpha)
	return Color(COLOR_MAX, COLOR_MAX, COLOR_MAX, alpha)


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

	var color := task_type_color(task.type, TASK_OVERLAY_ALPHA)
	mesh_instance.material_override = _create_overlay_shader_material(color)
	_apply_overlay_instance_settings(mesh_instance)
	add_child(mesh_instance)
	return mesh_instance


func create_blocked_task_overlay(task_type: int) -> MeshInstance3D:
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

	var color := task_type_color(task_type, BLOCKED_OVERLAY_ALPHA)
	mesh_instance.material_override = _create_overlay_shader_material(color)
	_apply_overlay_instance_settings(mesh_instance)
	add_child(mesh_instance)
	return mesh_instance
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
	var live_ids: Dictionary = {}
	for x in range(min_x, max_x + 1):
		for z in range(min_z, max_z + 1):
			var key := drag_preview_key(x, y, z)
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
			overlay.position = Vector3(x, y + OVERLAY_Y_OFFSET, z)
			overlay.visible = world.is_visible_at_level(y)

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
