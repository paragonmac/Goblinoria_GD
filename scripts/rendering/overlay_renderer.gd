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
const DRAG_UP_STAIRS_COLOR := Color(1.0, 0.7, 0.2)
const DRAG_DOWN_STAIRS_COLOR := Color(0.75, 0.45, 1.0)
const DRAG_ERASE_COLOR := Color(0.95, 0.95, 0.95)
const DRAG_STOCKPILE_COLOR := Color(0.15, 0.85, 0.85)
const DRAG_DEFAULT_COLOR := Color(0.8, 0.8, 0.8)
const DRAG_INVALID_COLOR := Color(1.0, 0.15, 0.15)
const ITEM_OVERLAY_SIZE := Vector3(0.35, 0.35, 0.35)
const ITEM_SPRITE_SIZE := Vector2(0.46, 0.46)
const ITEM_GROUND_OFFSET := -0.5 + ITEM_SPRITE_SIZE.y * 0.5 + 0.02
const STORAGE_RENDER_MARGIN := 0.55
const ITEM_ATLAS_PATH := "res://assets/textures/fantasy_resource_icons_6x6_real_alpha.png"
const ITEM_ATLAS_COLUMNS := 6
const ITEM_ATLAS_ROWS := 6
const ITEM_ATLAS_TILES := {
	1: 7,   # granite
	2: 1,   # dirt
	3: 1,   # clay
	4: 2,   # sandstone
	5: 6,   # limestone
	6: 13,  # basalt
	7: 8,   # slate
	8: 26,  # iron ore
	9: 8,   # coal
	10: 0,  # grass
	15: 6,  # gravel
	16: 3,  # moss
}
const STOCKPILE_OVERLAY_SIZE := Vector3(1.0, 0.06, 1.0)
const STOCKPILE_GROUND_OFFSET := -0.5 + STOCKPILE_OVERLAY_SIZE.y * 0.5 + 0.01
const STOCKPILE_OVERLAY_COLOR := Color(0.15, 0.85, 0.85, 0.25)
const DRAG_INVALID_MATERIAL_OFFSET := 1000
const ASSIGNED_OVERLAY_SCALE := Vector3(1.08, 1.0, 1.08)
const ROUND_HALF := 0.5
const OVERLAY_Y_OFFSET := 0.0  # 3D box centered at block position (use 0.52 for flat overlays)
const OVERLAY_SHADER_CODE := """shader_type spatial;
render_mode unshaded, cull_back, depth_draw_never;

uniform vec4 albedo_color : source_color = vec4(1.0, 1.0, 1.0, 0.5);
uniform float top_render_y = 1000.0;
uniform float top_render_margin = 0.0;
uniform float emission_strength = 0.18;
uniform float pulse_strength = 0.0;
uniform float pulse_speed = 4.0;

varying float world_y;

void vertex() {
	world_y = (MODEL_MATRIX * vec4(VERTEX, 1.0)).y;
	VERTEX += NORMAL * 0.001;  // Small offset to avoid z-fighting
}

void fragment() {
	if (world_y > top_render_y + 0.5 + top_render_margin) {
		discard;
	}
	float pulse = 1.0 + pulse_strength * (0.5 + 0.5 * sin(TIME * pulse_speed));
	vec3 display_color = min(albedo_color.rgb * pulse, vec3(1.0));
	ALBEDO = display_color;
	EMISSION = display_color * emission_strength;
	ALPHA = albedo_color.a;
}
"""
const ITEM_ATLAS_SHADER_CODE := """shader_type spatial;
render_mode unshaded, cull_disabled, depth_prepass_alpha;

uniform sampler2D atlas_texture : source_color, filter_linear_mipmap_anisotropic;
uniform vec2 atlas_cell = vec2(0.0);
uniform vec2 atlas_grid = vec2(6.0);
uniform float top_render_y = 1000.0;
uniform float top_render_margin = 0.55;

varying float world_y;

void vertex() {
	world_y = (MODEL_MATRIX * vec4(VERTEX, 1.0)).y;
	MODELVIEW_MATRIX = VIEW_MATRIX * mat4(
		INV_VIEW_MATRIX[0],
		INV_VIEW_MATRIX[1],
		INV_VIEW_MATRIX[2],
		MODEL_MATRIX[3]
	);
	MODELVIEW_NORMAL_MATRIX = mat3(MODELVIEW_MATRIX);
}

void fragment() {
	if (world_y > top_render_y + 0.5 + top_render_margin) {
		discard;
	}
	vec2 atlas_uv = (UV + atlas_cell) / atlas_grid;
	vec4 sampled = texture(atlas_texture, atlas_uv);
	ALBEDO = sampled.rgb;
	ALPHA = sampled.a;
	ALPHA_SCISSOR_THRESHOLD = 0.1;
}
"""
var overlay_shader: Shader = null
var item_atlas_shader: Shader = null
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
var drag_preview_mode := -1
var item_overlays: Dictionary = {}
var stockpile_overlays: Dictionary = {}
var item_materials: Dictionary = {}
var item_atlas_texture: Texture2D
var stockpile_material: ShaderMaterial
#endregion


#region Initialization
func initialize(world_ref: World) -> void:
	world = world_ref
	_ensure_shader()
	item_atlas_texture = _load_item_atlas_texture()
	if item_atlas_texture == null:
		push_warning("Item drop atlas failed to load: %s" % ITEM_ATLAS_PATH)


func _ensure_shader() -> void:
	if overlay_shader == null:
		overlay_shader = Shader.new()
		overlay_shader.code = OVERLAY_SHADER_CODE
	if item_atlas_shader == null:
		item_atlas_shader = Shader.new()
		item_atlas_shader.code = ITEM_ATLAS_SHADER_CODE


func _load_item_atlas_texture() -> Texture2D:
	if ResourceLoader.exists(ITEM_ATLAS_PATH):
		var imported_texture := load(ITEM_ATLAS_PATH) as Texture2D
		if imported_texture != null:
			return imported_texture
	var image := Image.new()
	var err := image.load(ITEM_ATLAS_PATH)
	if err != OK:
		return null
	return ImageTexture.create_from_image(image)


func _create_overlay_shader_material(
	color: Color,
	emission_strength: float = 0.0,
	top_render_margin: float = 0.0
) -> ShaderMaterial:
	_ensure_shader()
	var mat := ShaderMaterial.new()
	mat.shader = overlay_shader
	mat.set_shader_parameter("albedo_color", color)
	mat.set_shader_parameter("emission_strength", emission_strength)
	mat.set_shader_parameter("top_render_margin", top_render_margin)
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


func clear_item_and_stockpile_overlays() -> void:
	for key in item_overlays.keys():
		item_overlays[key].queue_free()
	item_overlays.clear()
	for key in stockpile_overlays.keys():
		stockpile_overlays[key].queue_free()
	stockpile_overlays.clear()


func update_task_overlays(tasks: Array) -> void:
	if world == null:
		return
	_sync_task_trace_session()
	var live_ids: Dictionary = {}
	for task in tasks:
		if task.status == TaskQueue.TaskStatus.COMPLETED:
			continue
		if task.type == TaskQueue.TaskType.HAUL:
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

	for task_id in task_overlays.keys():
		if not live_ids.has(task_id):
			_trace_task_overlay_removed(task_id)
			task_overlays[task_id].queue_free()
			task_overlays.erase(task_id)
#endregion


#region Overlay Helpers
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
		World.PlayerMode.UP_STAIRS:
			return Color(DRAG_UP_STAIRS_COLOR.r, DRAG_UP_STAIRS_COLOR.g, DRAG_UP_STAIRS_COLOR.b, DRAG_OVERLAY_ALPHA)
		World.PlayerMode.DOWN_STAIRS:
			return Color(DRAG_DOWN_STAIRS_COLOR.r, DRAG_DOWN_STAIRS_COLOR.g, DRAG_DOWN_STAIRS_COLOR.b, DRAG_OVERLAY_ALPHA)
		World.PlayerMode.ERASE:
			return Color(DRAG_ERASE_COLOR.r, DRAG_ERASE_COLOR.g, DRAG_ERASE_COLOR.b, DRAG_OVERLAY_ALPHA)
		World.PlayerMode.STOCKPILE:
			return Color(DRAG_STOCKPILE_COLOR.r, DRAG_STOCKPILE_COLOR.g, DRAG_STOCKPILE_COLOR.b, DRAG_OVERLAY_ALPHA)
	return Color(DRAG_DEFAULT_COLOR.r, DRAG_DEFAULT_COLOR.g, DRAG_DEFAULT_COLOR.b, DRAG_DEFAULT_ALPHA)


func get_drag_material(mode: int, valid: bool = true) -> ShaderMaterial:
	var key: int = mode if valid else mode + DRAG_INVALID_MATERIAL_OFFSET
	if drag_materials.has(key):
		return drag_materials[key]
	var color := drag_preview_color(mode) if valid else Color(DRAG_INVALID_COLOR.r, DRAG_INVALID_COLOR.g, DRAG_INVALID_COLOR.b, DRAG_OVERLAY_ALPHA)
	var render_margin := STORAGE_RENDER_MARGIN if mode == World.PlayerMode.STOCKPILE else 0.0
	var material := _create_overlay_shader_material(color, 0.0, render_margin)
	drag_materials[key] = material
	return material


func _apply_overlay_instance_settings(mesh_instance: MeshInstance3D) -> void:
	mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mesh_instance.extra_cull_margin = 1000.0  # Prevent frustum culling issues
	mesh_instance.gi_mode = GeometryInstance3D.GI_MODE_DISABLED


func create_drag_preview_overlay(mode: int) -> MeshInstance3D:
	var mesh_instance := MeshInstance3D.new()
	if mode == World.PlayerMode.STOCKPILE:
		var stockpile_box := BoxMesh.new()
		stockpile_box.size = STOCKPILE_OVERLAY_SIZE
		mesh_instance.mesh = stockpile_box
	elif USE_FLAT_OVERLAYS:
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
	var entries: Array[Dictionary] = []
	for pos: Vector3i in positions:
		entries.append({"pos": pos, "valid": true})
	set_drag_preview_entries(entries, mode)


func set_drag_preview_entries(entries: Array, mode: int) -> void:
	if drag_preview_mode != mode:
		clear_drag_preview()
		drag_preview_mode = mode
	var live_ids: Dictionary = {}
	for entry in entries:
		var pos: Vector3i = entry["pos"]
		var valid: bool = bool(entry.get("valid", true))
		var key := drag_preview_key(pos.x, pos.y, pos.z)
		live_ids[key] = true
		var overlay: MeshInstance3D
		if not drag_previews.has(key):
			overlay = create_drag_preview_overlay(mode)
			drag_previews[key] = overlay
		else:
			overlay = drag_previews[key]
		var desired := get_drag_material(mode, valid)
		if overlay.material_override != desired:
			overlay.material_override = desired
		if mode == World.PlayerMode.STOCKPILE:
			overlay.position = Vector3(pos.x, pos.y + STOCKPILE_GROUND_OFFSET, pos.z)
			overlay.visible = world.is_visible_at_level(pos.y - 1)
		else:
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
	drag_preview_mode = -1
#endregion


#region Items And Stockpiles
func update_item_overlays(items: Dictionary) -> void:
	_update_item_overlays(items)


func update_stockpile_overlays(stockpiles: Dictionary) -> void:
	_update_stockpile_overlays(stockpiles)


func _update_item_overlays(items: Dictionary) -> void:
	var live_ids: Dictionary = {}
	for item_id in items.keys():
		var item: Dictionary = items[item_id]
		if bool(item.get("is_carried", false)):
			continue
		var pos: Vector3i = item.get("pos", Vector3i.ZERO)
		live_ids[item_id] = true
		var overlay: MeshInstance3D
		if not item_overlays.has(item_id):
			overlay = _create_item_overlay(int(item.get("material_id", 0)))
			item_overlays[item_id] = overlay
		else:
			overlay = item_overlays[item_id]
		overlay.position = Vector3(pos.x, pos.y + ITEM_GROUND_OFFSET, pos.z)
		overlay.visible = world.is_visible_at_level(pos.y - 1)
		overlay.material_override = _get_item_material(int(item.get("material_id", 0)))
	for key in item_overlays.keys():
		if not live_ids.has(key):
			item_overlays[key].queue_free()
			item_overlays.erase(key)


func _update_stockpile_overlays(stockpiles: Dictionary) -> void:
	var live_ids: Dictionary = {}
	for stockpile_id in stockpiles.keys():
		var stockpile: Dictionary = stockpiles[stockpile_id]
		for cell in stockpile.get("cells", []):
			if typeof(cell) != TYPE_VECTOR3I:
				continue
			var pos: Vector3i = cell
			var key := "%d:%d:%d" % [pos.x, pos.y, pos.z]
			live_ids[key] = true
			var overlay: MeshInstance3D
			if not stockpile_overlays.has(key):
				overlay = _create_stockpile_overlay()
				stockpile_overlays[key] = overlay
			else:
				overlay = stockpile_overlays[key]
			overlay.position = Vector3(pos.x, pos.y + STOCKPILE_GROUND_OFFSET, pos.z)
			overlay.visible = world.is_visible_at_level(pos.y - 1)
	for key in stockpile_overlays.keys():
		if not live_ids.has(key):
			stockpile_overlays[key].queue_free()
			stockpile_overlays.erase(key)


func _create_item_overlay(material_id: int) -> MeshInstance3D:
	var mesh_instance := MeshInstance3D.new()
	if item_atlas_texture != null and ITEM_ATLAS_TILES.has(material_id):
		var quad := QuadMesh.new()
		quad.size = ITEM_SPRITE_SIZE
		mesh_instance.mesh = quad
	else:
		var box := BoxMesh.new()
		box.size = ITEM_OVERLAY_SIZE
		mesh_instance.mesh = box
	_apply_overlay_instance_settings(mesh_instance)
	add_child(mesh_instance)
	return mesh_instance


func _create_stockpile_overlay() -> MeshInstance3D:
	var mesh_instance := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = STOCKPILE_OVERLAY_SIZE
	mesh_instance.mesh = box
	mesh_instance.material_override = _get_stockpile_material()
	_apply_overlay_instance_settings(mesh_instance)
	add_child(mesh_instance)
	return mesh_instance


func _get_item_material(material_id: int) -> ShaderMaterial:
	if item_materials.has(material_id):
		return item_materials[material_id]
	if item_atlas_texture != null and ITEM_ATLAS_TILES.has(material_id):
		var tile_index: int = int(ITEM_ATLAS_TILES[material_id])
		var atlas_material := ShaderMaterial.new()
		atlas_material.shader = item_atlas_shader
		atlas_material.set_shader_parameter("atlas_texture", item_atlas_texture)
		atlas_material.set_shader_parameter(
			"atlas_cell",
			Vector2(tile_index % ITEM_ATLAS_COLUMNS, floori(float(tile_index) / ITEM_ATLAS_COLUMNS))
		)
		atlas_material.set_shader_parameter(
			"atlas_grid",
			Vector2(ITEM_ATLAS_COLUMNS, ITEM_ATLAS_ROWS)
		)
		if world != null:
			atlas_material.set_shader_parameter("top_render_y", float(world.top_render_y))
		atlas_material.set_shader_parameter("top_render_margin", STORAGE_RENDER_MARGIN)
		atlas_material.render_priority = 100
		all_overlay_materials.append(atlas_material)
		item_materials[material_id] = atlas_material
		return atlas_material
	var color := world.get_block_color(material_id)
	color.a = 0.95
	var material := _create_overlay_shader_material(color, 0.05, STORAGE_RENDER_MARGIN)
	item_materials[material_id] = material
	return material


func _get_stockpile_material() -> ShaderMaterial:
	if stockpile_material != null:
		return stockpile_material
	stockpile_material = _create_overlay_shader_material(
		STOCKPILE_OVERLAY_COLOR,
		0.04,
		STORAGE_RENDER_MARGIN
	)
	return stockpile_material
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
