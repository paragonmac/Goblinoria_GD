extends RefCounted
class_name WorkerVisuals
## Owns worker model/debug-box/shadow setup and animation playback.

enum VisualState {IDLE, MOVING, WORKING}

const MOVE_SPEED_ANIM_REFERENCE := 1.3
const WORKER_BOX_SIZE := Vector3(0.5, 0.8, 0.5)
const WORKER_BOX_Y_OFFSET := -0.1
const WORKER_MODEL_DEFAULT_PATH := "res://assets/models/GoblinAnims.fbx"
const MODEL_TARGET_HEIGHT := 0.8
const MODEL_GROUND_Y := -0.5
const ANIM_BLEND_TIME := 0.12
const SHADOW_SIZE := Vector2(0.9, 0.9)
const SHADOW_Y_OFFSET := -0.48
const SHADOW_COLOR := Color(0.0, 0.0, 0.0, 0.35)
const IDLE_COLOR := Color(0.2, 0.8, 0.2)
const MOVING_COLOR := Color(1.0, 0.8, 0.2)
const WORKING_COLOR := Color(1.0, 0.5, 0.0)

var owner: Node3D
var use_animated_model: bool = true
var model_path: String = WORKER_MODEL_DEFAULT_PATH
var model_import_scale: float = 0.01
var show_debug_box: bool = false
var move_anim_hint: String = "003"
var dig_anim_hint: String = "002"
var work_anim_hint: String = ""
var model_yaw_offset_degrees: float = 180.0
var debug_print_animations: bool = false
var animation_speed_multiplier: float = 1.5
var moving_animation_speed_multiplier: float = 3.0
var working_animation_speed_multiplier: float = 1.5

var model_instance: Node3D
var animation_player: AnimationPlayer
var anim_idle: StringName = &""
var anim_move: StringName = &""
var anim_dig: StringName = &""
var anim_work: StringName = &""
var anim_reset: StringName = &""

var mesh_instance: MeshInstance3D
var mat_idle: StandardMaterial3D
var mat_moving: StandardMaterial3D
var mat_working: StandardMaterial3D
var shadow_instance: MeshInstance3D
var shadow_material: StandardMaterial3D


func setup(owner_ref: Node3D, config: Dictionary) -> void:
	owner = owner_ref
	_apply_config(config)
	if use_animated_model:
		_setup_animated_model()
	if show_debug_box or model_instance == null:
		_setup_debug_box()
	_setup_shadow()
	_setup_debug_materials()


func apply_state(visual_state: int, active_work_anim: StringName, move_speed: float, force_restart: bool) -> void:
	if mesh_instance != null:
		match visual_state:
			VisualState.IDLE:
				mesh_instance.material_override = mat_idle
			VisualState.MOVING:
				mesh_instance.material_override = mat_moving
			VisualState.WORKING:
				mesh_instance.material_override = mat_working

	if animation_player == null:
		return

	match visual_state:
		VisualState.IDLE:
			_apply_rest_pose()
			animation_player.speed_scale = 1.0 * animation_speed_multiplier
		VisualState.MOVING:
			_play_anim(anim_move, force_restart)
			animation_player.speed_scale = max(0.1, move_speed / MOVE_SPEED_ANIM_REFERENCE) * moving_animation_speed_multiplier
		VisualState.WORKING:
			var work_anim: StringName = active_work_anim if active_work_anim != &"" else anim_work
			_play_anim(work_anim, force_restart)
			animation_player.speed_scale = 1.0 * working_animation_speed_multiplier


func ensure_moving_animation() -> void:
	if animation_player == null:
		return
	if anim_move == &"":
		return
	if animation_player.is_playing():
		return
	_play_anim(anim_move, true)


func ensure_working_animation(active_work_anim: StringName) -> void:
	if animation_player == null:
		return
	var work_anim: StringName = active_work_anim if active_work_anim != &"" else anim_work
	if work_anim == &"":
		return
	if animation_player.is_playing():
		return
	_play_anim(work_anim, true)


func get_work_anim_for_task(task) -> StringName:
	if task == null:
		return anim_work
	if task.type == TaskQueue.TaskType.DIG:
		return anim_dig
	return anim_work


func update_facing_from_delta(delta: Vector3) -> void:
	if owner == null or model_instance == null:
		return
	var dir := Vector3(delta.x, 0.0, delta.z)
	if dir.length_squared() < 0.0001:
		return
	var target := owner.global_position + dir
	target.y = owner.global_position.y
	owner.look_at(target, Vector3.UP)


func _apply_config(config: Dictionary) -> void:
	use_animated_model = bool(config.get("use_animated_model", use_animated_model))
	model_path = str(config.get("model_path", model_path))
	model_import_scale = float(config.get("model_import_scale", model_import_scale))
	show_debug_box = bool(config.get("show_debug_box", show_debug_box))
	move_anim_hint = str(config.get("move_anim_hint", move_anim_hint))
	dig_anim_hint = str(config.get("dig_anim_hint", dig_anim_hint))
	work_anim_hint = str(config.get("work_anim_hint", work_anim_hint))
	model_yaw_offset_degrees = float(config.get("model_yaw_offset_degrees", model_yaw_offset_degrees))
	debug_print_animations = bool(config.get("debug_print_animations", debug_print_animations))
	animation_speed_multiplier = float(config.get("animation_speed_multiplier", animation_speed_multiplier))
	moving_animation_speed_multiplier = float(config.get("moving_animation_speed_multiplier", moving_animation_speed_multiplier))
	working_animation_speed_multiplier = float(config.get("working_animation_speed_multiplier", working_animation_speed_multiplier))


func _setup_debug_box() -> void:
	if owner == null:
		return
	mesh_instance = MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = WORKER_BOX_SIZE
	mesh_instance.mesh = box
	mesh_instance.position.y = WORKER_BOX_Y_OFFSET
	owner.add_child(mesh_instance)


func _setup_animated_model() -> void:
	if owner == null:
		return
	var scene_res: Resource = load(model_path)
	if scene_res == null or not (scene_res is PackedScene):
		return

	var inst: Node = (scene_res as PackedScene).instantiate()
	if inst == null:
		return

	if inst is Node3D:
		model_instance = inst as Node3D
	else:
		model_instance = Node3D.new()
		model_instance.add_child(inst)

	model_instance.name = "Model"
	owner.add_child(model_instance)

	model_instance.rotation_degrees.y = model_yaw_offset_degrees
	model_instance.scale *= model_import_scale
	_autoscale_and_ground_model(model_instance)
	_setup_animation_player(model_instance)


func _setup_shadow() -> void:
	if owner == null:
		return
	shadow_instance = MeshInstance3D.new()
	var shadow_mesh := PlaneMesh.new()
	shadow_mesh.size = SHADOW_SIZE
	shadow_instance.mesh = shadow_mesh
	shadow_instance.position = Vector3(0.0, SHADOW_Y_OFFSET, 0.0)
	shadow_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	shadow_material = StandardMaterial3D.new()
	shadow_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	shadow_material.cull_mode = BaseMaterial3D.CULL_DISABLED
	shadow_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	shadow_material.albedo_color = SHADOW_COLOR
	shadow_instance.material_override = shadow_material
	owner.add_child(shadow_instance)


func _setup_debug_materials() -> void:
	if mesh_instance == null:
		return
	mat_idle = StandardMaterial3D.new()
	mat_idle.albedo_color = IDLE_COLOR
	mat_moving = StandardMaterial3D.new()
	mat_moving.albedo_color = MOVING_COLOR
	mat_working = StandardMaterial3D.new()
	mat_working.albedo_color = WORKING_COLOR
	mesh_instance.material_override = mat_idle


func _setup_animation_player(root: Node) -> void:
	var players := root.find_children("*", "AnimationPlayer", true, false)
	if players.is_empty():
		return

	animation_player = players[0] as AnimationPlayer
	if animation_player == null:
		return

	var anims: PackedStringArray = animation_player.get_animation_list()
	if anims.is_empty():
		return

	anim_reset = _pick_animation(anims, ["reset"])
	anim_idle = _pick_animation(anims, ["idle"])
	anim_move = _pick_animation(anims, [move_anim_hint, "walk", "run", "move"])
	anim_dig = _pick_animation(anims, [dig_anim_hint, "dig", "mine", "chop", "swing"])
	anim_work = _pick_animation(anims, [work_anim_hint, "work", "dig", "mine", "chop", "swing"])

	var fallback := _first_non_reset_animation(anims)
	if anim_move == &"":
		anim_move = fallback
	if anim_dig == &"":
		anim_dig = fallback
	if anim_work == &"":
		anim_work = fallback

	_set_animation_loop(anim_move, true)
	_set_animation_loop(anim_dig, true)
	_set_animation_loop(anim_work, true)

	if debug_print_animations:
		print("Worker AnimationPlayer animations: ", anims)
		print("Worker anim_pick reset=", anim_reset, " idle=", anim_idle, " move=", anim_move, " dig=", anim_dig, " work=", anim_work)


func _apply_rest_pose() -> void:
	if animation_player == null:
		return

	if anim_reset != &"" and animation_player.has_animation(anim_reset):
		animation_player.play(anim_reset, 0.0)
		animation_player.seek(0.0, true)
		animation_player.stop()
		return

	if animation_player.current_animation != &"":
		animation_player.stop()


func _set_animation_loop(anim_name: StringName, should_loop: bool) -> void:
	if animation_player == null:
		return
	if anim_name == &"":
		return
	if not animation_player.has_animation(anim_name):
		return
	var anim: Animation = animation_player.get_animation(anim_name)
	if should_loop:
		anim.loop_mode = Animation.LOOP_LINEAR
	else:
		anim.loop_mode = Animation.LOOP_NONE


func _play_anim(anim_name: StringName, force_restart: bool) -> void:
	if animation_player == null:
		return
	if anim_name == &"":
		return
	if not animation_player.has_animation(anim_name):
		return
	if not force_restart and animation_player.current_animation == anim_name:
		return
	animation_player.play(anim_name, ANIM_BLEND_TIME)


func _pick_animation(anims: PackedStringArray, hints: Array[String]) -> StringName:
	for hint in hints:
		var hint_l := hint.to_lower()
		for anim in anims:
			var anim_s := String(anim)
			if anim_s.to_lower().find(hint_l) != -1:
				return StringName(anim_s)
	return &""


func _first_non_reset_animation(anims: PackedStringArray) -> StringName:
	for anim in anims:
		var anim_s := String(anim)
		if anim_s.to_lower().find("reset") != -1:
			continue
		return StringName(anim_s)
	return &""


func _autoscale_and_ground_model(root: Node3D) -> void:
	var bounds := _compute_visual_bounds(root)
	if bounds.size.y <= 0.0001:
		return

	var scale_factor := MODEL_TARGET_HEIGHT / bounds.size.y
	scale_factor = clampf(scale_factor, 0.001, 100.0)
	root.scale *= scale_factor

	var scaled_bounds := _compute_visual_bounds(root)
	if scaled_bounds.size.y <= 0.0001:
		return

	var min_y := scaled_bounds.position.y
	root.position.y += MODEL_GROUND_Y - min_y


func _compute_visual_bounds(root: Node3D) -> AABB:
	var min_v := Vector3(INF, INF, INF)
	var max_v := Vector3(-INF, -INF, -INF)
	var any := false

	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var node: Node = stack.pop_back() as Node
		for child: Node in node.get_children():
			stack.append(child)

		if not (node is Node3D):
			continue
		var node3d := node as Node3D

		var aabb: AABB
		var has_aabb := false

		if node3d.has_method("get_aabb"):
			aabb = node3d.call("get_aabb")
			has_aabb = aabb.size.length_squared() > 0.0
		elif node3d.has_method("get"):
			var mesh = node3d.get("mesh")
			if mesh != null and mesh.has_method("get_aabb"):
				aabb = mesh.get_aabb()
				has_aabb = aabb.size.length_squared() > 0.0

		if not has_aabb:
			continue

		var to_root := root.global_transform.affine_inverse() * node3d.global_transform
		for corner in _aabb_corners(aabb):
			var p := to_root * corner
			min_v = min_v.min(p)
			max_v = max_v.max(p)
			any = true

	if not any:
		return AABB(Vector3.ZERO, Vector3.ZERO)

	return AABB(min_v, max_v - min_v)


func _aabb_corners(aabb: AABB) -> Array[Vector3]:
	var p := aabb.position
	var s := aabb.size
	return [
		p,
		p + Vector3(s.x, 0.0, 0.0),
		p + Vector3(0.0, s.y, 0.0),
		p + Vector3(0.0, 0.0, s.z),
		p + Vector3(s.x, s.y, 0.0),
		p + Vector3(s.x, 0.0, s.z),
		p + Vector3(0.0, s.y, s.z),
		p + Vector3(s.x, s.y, s.z),
	]
