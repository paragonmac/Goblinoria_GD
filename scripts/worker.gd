extends Node3D
class_name Worker
## Worker entity that performs tasks (dig, place, stairs) and wanders when idle.

#region Enums
enum WorkerState {IDLE, MOVING, WORKING, WAITING}
#endregion

#region Constants
const WORK_DURATION := 0.5
const IDLE_PAUSE := 0.5
const DEFAULT_SPEED := 1.3
const MOVE_SPEED_ANIM_REFERENCE := 1.3
const WANDER_WAIT_MIN := 3.0
const WANDER_WAIT_MAX := 5.0
const WORKER_BOX_SIZE := Vector3(0.5, 0.8, 0.5)
const WORKER_BOX_Y_OFFSET := -0.1
const WORKER_MODEL_DEFAULT_PATH := "res://assets/models/GoblinAnims.fbx"
const MODEL_TARGET_HEIGHT := 0.8
const MODEL_GROUND_Y := -0.5
const ANIM_BLEND_TIME := 0.12
const BUILD_DURATION := 0.6
const DIG_DURATION_DEFAULT := 8.0
const DIG_DURATION_GRASS := 1.0
const DIG_DURATION_DIRT := 1.0
const DIG_DURATION_CLAY := 2.0
const DIG_DURATION_SANDSTONE := 6.0
const DIG_DURATION_LIMESTONE := 7.0
const DIG_DURATION_GRANITE := 10.0
const DIG_DURATION_SLATE := 10.0
const DIG_DURATION_BASALT := 12.0
const DIG_DURATION_COAL := 15.0
const DIG_DURATION_IRON_ORE := 20.0
const SHADOW_SIZE := Vector2(0.9, 0.9)
const SHADOW_Y_OFFSET := -0.48
const SHADOW_COLOR := Color(0.0, 0.0, 0.0, 0.35)
const IDLE_COLOR := Color(0.2, 0.8, 0.2)
const MOVING_COLOR := Color(1.0, 0.8, 0.2)
const WORKING_COLOR := Color(1.0, 0.5, 0.0)
const MOVE_TARGET_EPSILON := 0.01
const ADJACENT_MANHATTAN_DISTANCE := 1
const WANDER_ATTEMPTS := 8
const WANDER_DIST_MIN := 1
const WANDER_DIST_MAX := 10
#endregion

#region State
var state: WorkerState = WorkerState.IDLE
var current_task_id := -1
var target_pos := Vector3.ZERO
var move_speed := DEFAULT_SPEED
var path: Array = []
var path_index := 0
var work_timer := 0.0
var idle_timer := 0.0
var wander_wait := 0.0
var rng := RandomNumberGenerator.new()
#endregion

#region Visual Components
@export var use_animated_model := true
@export var model_path: String = WORKER_MODEL_DEFAULT_PATH
@export var model_import_scale := 0.01
@export var show_debug_box := false
@export var move_anim_hint := "003"
@export var dig_anim_hint := "002"
@export var work_anim_hint := ""
@export var model_yaw_offset_degrees := 180.0
@export var debug_print_animations := false
@export var animation_speed_multiplier := 1.5
@export var moving_animation_speed_multiplier := 3.0
@export var working_animation_speed_multiplier := 1.5
@export var move_speed_multiplier := 1.0
@export var dig_duration_multiplier := 1.0

var model_instance: Node3D
var animation_player: AnimationPlayer
var anim_idle: StringName = &""
var anim_move: StringName = &""
var anim_dig: StringName = &""
var anim_work: StringName = &""
var anim_reset: StringName = &""
var active_work_anim: StringName = &""

var mesh_instance: MeshInstance3D
var mat_idle: StandardMaterial3D
var mat_moving: StandardMaterial3D
var mat_working: StandardMaterial3D
var shadow_instance: MeshInstance3D
var shadow_material: StandardMaterial3D
#endregion


#region Lifecycle
func _ready() -> void:
	rng.seed = hash(Vector3(position.x, position.y, position.z))
	wander_wait = rng.randf_range(WANDER_WAIT_MIN, WANDER_WAIT_MAX)
	move_speed = DEFAULT_SPEED * move_speed_multiplier

	if use_animated_model:
		_setup_animated_model()
	if show_debug_box or model_instance == null:
		_setup_debug_box()

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
	add_child(shadow_instance)

	if mesh_instance != null:
		mat_idle = StandardMaterial3D.new()
		mat_idle.albedo_color = IDLE_COLOR
		mat_moving = StandardMaterial3D.new()
		mat_moving.albedo_color = MOVING_COLOR
		mat_working = StandardMaterial3D.new()
		mat_working.albedo_color = WORKING_COLOR
		mesh_instance.material_override = mat_idle

	_apply_visual_state(true)
#endregion


#region State Management
func set_state(new_state: WorkerState) -> void:
	if state == new_state:
		return
	state = new_state
	_apply_visual_state(true)


func get_block_coord() -> Vector3i:
	return Vector3i(int(round(position.x)), int(floor(position.y)), int(round(position.z)))
#endregion


#region Update Loop
func update_worker(dt: float, world, task_queue, pathfinder) -> void:
	if idle_timer > 0.0:
		idle_timer -= dt
		return

	match state:
		WorkerState.IDLE:
			update_idle(dt, world, task_queue, pathfinder)
		WorkerState.MOVING:
			update_moving(dt, world, task_queue)
		WorkerState.WORKING:
			update_working(dt, world, task_queue)
		WorkerState.WAITING:
			update_waiting(dt, world, task_queue, pathfinder)
#endregion


#region Idle State
func update_idle(dt: float, world, task_queue, pathfinder) -> void:
	var result: Dictionary = find_pathable_task(TaskQueue.TaskType.DIG, world, task_queue, pathfinder)
	if result.is_empty():
		result = find_pathable_task(TaskQueue.TaskType.STAIRS, world, task_queue, pathfinder)
	if result.is_empty():
		result = find_pathable_task(TaskQueue.TaskType.PLACE, world, task_queue, pathfinder)

	if not result.is_empty():
		var task = result["task"]
		var maybe_path: Array = result["path"]
		task.status = TaskQueue.TaskStatus.IN_PROGRESS
		task.assigned_worker = self
		current_task_id = task.id
		path = maybe_path
		path_index = 0
		set_target_from_path(world)
		set_state(WorkerState.MOVING)
		return

	update_wander(dt, world, pathfinder)
#endregion


#region Task Discovery
func find_pathable_task(task_type: int, world, task_queue, pathfinder) -> Dictionary:
	var candidates: Array = []
	for task in task_queue.tasks:
		if task.status != TaskQueue.TaskStatus.PENDING:
			continue
		if task.type != task_type:
			continue
		var dx: float = float(task.pos.x) - position.x
		var dy: float = float(task.pos.y) - position.y
		var dz: float = float(task.pos.z) - position.z
		var dist_sq: float = dx * dx + dy * dy + dz * dz
		candidates.append({"task": task, "dist": dist_sq})

	candidates.sort_custom(func(a, b):
		return a["dist"] < b["dist"]
	)

	var start: Vector3i = get_block_coord()
	for entry in candidates:
		var task = entry["task"]
		var maybe_path: Array = []
		if task.type == TaskQueue.TaskType.STAIRS:
			maybe_path = find_path_to_stairs(world, start, task.pos, pathfinder)
		elif task.type == TaskQueue.TaskType.DIG:
			maybe_path = pathfinder.find_path_to_adjacent_on_level(world, start, task.pos, task.pos.y)
			if maybe_path.is_empty() and task.pos.y == start.y:
				maybe_path = pathfinder.find_path(world, start, task.pos, false, true)
		else:
			maybe_path = pathfinder.find_path_to_adjacent_on_level(world, start, task.pos, task.pos.y)
		if maybe_path.size() > 0:
			return {"task": task, "path": maybe_path}

	return {}


func can_work_task(task) -> bool:
	if task.type == TaskQueue.TaskType.DIG or task.type == TaskQueue.TaskType.PLACE:
		var worker_pos := get_block_coord()
		if worker_pos.y != task.pos.y:
			return false
		var dx: int = abs(worker_pos.x - task.pos.x)
		var dz: int = abs(worker_pos.z - task.pos.z)
		return dx + dz == ADJACENT_MANHATTAN_DISTANCE
	return true
#endregion


#region Movement
func set_target_from_path(world) -> void:
	if path_index < path.size():
		var node: Vector3i = path[path_index]
		target_pos = Vector3(node.x, node.y, node.z)
		if world != null:
			var block_id: int = world.get_block(node.x, node.y, node.z)
			if world.is_ramp_block_id(block_id):
				target_pos.y += _ramp_center_offset(block_id)


func update_moving(dt: float, world, task_queue) -> void:
	var delta := target_pos - position
	var dist := delta.length()
	_update_facing_from_delta(delta)
	_ensure_anim_playing_while_moving()
	var move_dist := move_speed * dt
	if dist <= move_dist + MOVE_TARGET_EPSILON:
		position = target_pos
		path_index += 1
		if path_index >= path.size():
			path.clear()
			if current_task_id >= 0:
				var task = task_queue.get_task(current_task_id)
				if task != null and can_work_task(task):
					active_work_anim = _get_work_anim_for_task(task)
					set_state(WorkerState.WORKING)
					work_timer = _get_work_duration(world, task)
				else:
					set_state(WorkerState.WAITING)
					idle_timer = IDLE_PAUSE
			else:
				set_state(WorkerState.IDLE)
				wander_wait = rng.randf_range(WANDER_WAIT_MIN, WANDER_WAIT_MAX)
			return
		set_target_from_path(world)
		return

	if dist > 0.000001:
		position += (delta / dist) * move_dist

func _ramp_center_offset(block_id: int) -> float:
	match block_id:
		World.RAMP_NORTHEAST_ID, World.RAMP_NORTHWEST_ID, World.RAMP_SOUTHEAST_ID, World.RAMP_SOUTHWEST_ID:
			return 0.25
		World.INNER_SOUTHWEST_ID, World.INNER_SOUTHEAST_ID, World.INNER_NORTHWEST_ID, World.INNER_NORTHEAST_ID:
			return 0.75
		_:
			return 0.5
#endregion


#region Visuals
func _setup_debug_box() -> void:
	mesh_instance = MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = WORKER_BOX_SIZE
	mesh_instance.mesh = box
	mesh_instance.position.y = WORKER_BOX_Y_OFFSET
	add_child(mesh_instance)


func _setup_animated_model() -> void:
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
	add_child(model_instance)

	model_instance.rotation_degrees.y = model_yaw_offset_degrees
	model_instance.scale *= model_import_scale
	_autoscale_and_ground_model(model_instance)
	_setup_animation_player(model_instance)


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


func _apply_visual_state(force_restart: bool) -> void:
	if mesh_instance != null:
		match state:
			WorkerState.IDLE, WorkerState.WAITING:
				mesh_instance.material_override = mat_idle
			WorkerState.MOVING:
				mesh_instance.material_override = mat_moving
			WorkerState.WORKING:
				mesh_instance.material_override = mat_working

	if animation_player == null:
		return

	match state:
		WorkerState.IDLE, WorkerState.WAITING:
			_apply_rest_pose()
			animation_player.speed_scale = 1.0 * animation_speed_multiplier
		WorkerState.MOVING:
			_play_anim(anim_move, force_restart)
			animation_player.speed_scale = max(0.1, move_speed / MOVE_SPEED_ANIM_REFERENCE) * moving_animation_speed_multiplier
		WorkerState.WORKING:
			var work_anim: StringName = active_work_anim if active_work_anim != &"" else anim_work
			_play_anim(work_anim, force_restart)
			animation_player.speed_scale = 1.0 * working_animation_speed_multiplier


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


func _ensure_anim_playing_while_moving() -> void:
	if animation_player == null:
		return
	if state != WorkerState.MOVING:
		return
	if anim_move == &"":
		return
	if animation_player.is_playing():
		return
	_play_anim(anim_move, true)


func _ensure_anim_playing_while_working() -> void:
	if animation_player == null:
		return
	if state != WorkerState.WORKING:
		return
	var work_anim: StringName = active_work_anim if active_work_anim != &"" else anim_work
	if work_anim == &"":
		return
	if animation_player.is_playing():
		return
	_play_anim(work_anim, true)


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


func _get_work_anim_for_task(task) -> StringName:
	if task == null:
		return anim_work
	if task.type == TaskQueue.TaskType.DIG:
		return anim_dig
	return anim_work


func _get_work_duration(world, task) -> float:
	if task == null:
		return WORK_DURATION
	match task.type:
		TaskQueue.TaskType.DIG:
			if world == null:
				return DIG_DURATION_DEFAULT * dig_duration_multiplier
			var block_id: int = world.get_block(task.pos.x, task.pos.y, task.pos.z)
			return _get_dig_duration_for_block_id(block_id) * dig_duration_multiplier
		TaskQueue.TaskType.PLACE, TaskQueue.TaskType.STAIRS:
			return BUILD_DURATION
		_:
			return WORK_DURATION


func _get_dig_duration_for_block_id(block_id: int) -> float:
	if World.RAMP_BLOCK_IDS.has(block_id):
		return DIG_DURATION_SANDSTONE
	match block_id:
		World.BLOCK_ID_GRASS:
			return DIG_DURATION_GRASS
		World.BLOCK_ID_DIRT:
			return DIG_DURATION_DIRT
		World.BLOCK_ID_CLAY:
			return DIG_DURATION_CLAY
		World.BLOCK_ID_SANDSTONE:
			return DIG_DURATION_SANDSTONE
		World.BLOCK_ID_LIMESTONE:
			return DIG_DURATION_LIMESTONE
		World.BLOCK_ID_BASALT:
			return DIG_DURATION_BASALT
		World.BLOCK_ID_SLATE:
			return DIG_DURATION_SLATE
		World.BLOCK_ID_IRON_ORE:
			return DIG_DURATION_IRON_ORE
		World.BLOCK_ID_COAL:
			return DIG_DURATION_COAL
		World.BLOCK_ID_GRANITE:
			return DIG_DURATION_GRANITE
		_:
			return DIG_DURATION_DEFAULT


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


func _update_facing_from_delta(delta: Vector3) -> void:
	if model_instance == null:
		return
	var dir := Vector3(delta.x, 0.0, delta.z)
	if dir.length_squared() < 0.0001:
		return
	var target := global_position + dir
	target.y = global_position.y
	look_at(target, Vector3.UP)


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
#endregion


#region Working State
func update_working(dt: float, world, task_queue) -> void:
	_ensure_anim_playing_while_working()
	work_timer -= dt
	if work_timer > 0.0:
		return

	if current_task_id >= 0:
		var task = task_queue.get_task(current_task_id)
		if task != null:
			match task.type:
				TaskQueue.TaskType.DIG:
					world.set_block(task.pos.x, task.pos.y, task.pos.z, World.BLOCK_ID_AIR)
				TaskQueue.TaskType.PLACE:
					world.set_block(task.pos.x, task.pos.y, task.pos.z, task.material)
				TaskQueue.TaskType.STAIRS:
					world.set_block(task.pos.x, task.pos.y, task.pos.z, task.material)
			task.status = TaskQueue.TaskStatus.COMPLETED
			if task.type == TaskQueue.TaskType.DIG:
				world.reassess_waiting_tasks()

	current_task_id = -1
	active_work_anim = &""
	idle_timer = IDLE_PAUSE
	set_state(WorkerState.IDLE)
#endregion


#region Waiting State
func update_waiting(_dt: float, world, task_queue, pathfinder) -> void:
	if current_task_id < 0:
		set_state(WorkerState.IDLE)
		return

	var task = task_queue.get_task(current_task_id)
	if task == null or task.status == TaskQueue.TaskStatus.COMPLETED:
		current_task_id = -1
		set_state(WorkerState.IDLE)
		return

	var start: Vector3i = get_block_coord()
	var maybe_path: Array = []
	if task.type == TaskQueue.TaskType.STAIRS:
		maybe_path = find_path_to_stairs(world, start, task.pos, pathfinder)
	elif task.type == TaskQueue.TaskType.DIG:
		maybe_path = pathfinder.find_path_to_adjacent_on_level(world, start, task.pos, task.pos.y)
		if maybe_path.is_empty() and task.pos.y == start.y:
			maybe_path = pathfinder.find_path(world, start, task.pos, false, true)
	else:
		maybe_path = pathfinder.find_path_to_adjacent_on_level(world, start, task.pos, task.pos.y)

	if maybe_path.size() > 0:
		path = maybe_path
		path_index = 0
		set_target_from_path(world)
		set_state(WorkerState.MOVING)
		return

	idle_timer = IDLE_PAUSE
#endregion


#region Wandering
func update_wander(dt: float, world, pathfinder) -> void:
	if wander_wait > 0.0:
		wander_wait -= dt
		return

	var start: Vector3i = get_block_coord()
	for _i in range(WANDER_ATTEMPTS):
		var dist: int = rng.randi_range(WANDER_DIST_MIN, WANDER_DIST_MAX)
		var dx: int = rng.randi_range(-dist, dist)
		var dz: int = rng.randi_range(-dist, dist)
		if dx == 0 and dz == 0:
			continue
		var x: int = start.x + dx
		var y: int = start.y
		var z: int = start.z + dz
		if not pathfinder.is_walkable(world, x, y, z):
			continue
		var goal: Vector3i = Vector3i(x, y, z)
		var found: Array = pathfinder.find_path(world, start, goal)
		if found.size() > 0:
			path = found
			path_index = 0
			set_target_from_path(world)
			set_state(WorkerState.MOVING)
			return

	wander_wait = rng.randf_range(WANDER_WAIT_MIN, WANDER_WAIT_MAX)
#endregion


#region Pathfinding Helpers
func find_path_to_stairs(world, start: Vector3i, target: Vector3i, pathfinder) -> Array:
	var candidates: Array[Vector3i] = []
	for dy in range(0, 3):
		for dx in range(-1, 2):
			for dz in range(-1, 2):
				var x: int = target.x + dx
				var y: int = target.y + dy
				var z: int = target.z + dz
				if pathfinder.is_walkable(world, x, y, z):
					candidates.append(Vector3i(x, y, z))

	candidates.sort_custom(func(a, b):
		var da: float = a.distance_squared_to(start)
		var db: float = b.distance_squared_to(start)
		return da < db
	)

	for goal in candidates:
		var found: Array = pathfinder.find_path(world, start, goal)
		if found.size() > 0:
			return found

	return []
#endregion
