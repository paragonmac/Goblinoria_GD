extends SceneTree
## Torch attachment, designation, lighting and V10 persistence contract.

const SelectionScript = preload("res://scripts/main_selection_controller.gd")
const OverlayRendererScript = preload("res://scripts/rendering/overlay_renderer.gd")
const TaskSaveLoadScript = preload("res://scripts/world_task_save_load.gd")
const WorkPrioritiesScript = preload("res://scripts/worker_work_priorities.gd")
const WorkerRolesScript = preload("res://scripts/worker_roles.gd")
const IDLE_PAUSE := 0.5

class TestWorld extends World:
	func _ready() -> void:
		_init_ramp_lookup()
		block_registry.load_from_csv(BLOCK_DATA_PATH)
		sea_level = 40
		top_render_y = 40
		deepest_structure_y = 0
		task_manager = TaskManager.new(self, task_queue)

	func ensure_chunk_generated(coord: Vector3i) -> ChunkData:
		var chunk := ensure_chunk(coord)
		chunk.generated = true
		return chunk

var checks := 0
var failures := 0


func _init() -> void:
	_run.call_deferred()


func _check(value: bool, message: String) -> void:
	checks += 1
	if not value:
		failures += 1
		push_error(message)


func _run() -> void:
	var world := TestWorld.new()
	root.add_child(world)
	world.torch_store.bind_world(world)
	for cy in range(World.WORLD_CHUNKS_Y):
		world.ensure_chunk_generated(Vector3i(0, cy, 0))
	for x in range(-1, 8):
		for z in range(-1, 4):
			world.set_block_raw(x, 19, z, World.BLOCK_ID_GRANITE, false)
			for y in range(20, 30):
				world.set_block_raw(x, y, z, World.BLOCK_ID_AIR, false)
		for y in range(20, 31):
			for boundary in [Vector3i(-1, y, 0), Vector3i(7, y, 0), Vector3i(0, y, -1), Vector3i(0, y, 3)]:
				world.set_block_raw(boundary.x, boundary.y, boundary.z, World.BLOCK_ID_GRANITE, false)
	for x in range(-1, 8):
		for z in range(-1, 4):
			world.set_block_raw(x, 30, z, World.BLOCK_ID_GRANITE, false)
	for chunk in world.chunks.values():
		chunk.generated = true
	world.light_field.build(world)
	world.light_field_built = true
	world.torch_store.register_light_sources()
	world.light_field.process_events(100000)
	var baseline_light: PackedByteArray = world.light_field.light.duplicate()

	var selector = SelectionScript.new()
	selector.world = world
	world.player_mode = World.PlayerMode.TORCH
	var target := Vector3i(2, 20, 1)
	world.light_field.explored[world.light_field._world_index(target.x, target.y, target.z)] = 0
	var result: Dictionary = selector._enqueue_task_at(target.x, target.y, target.z)
	_check(result.reason == "unexplored", "unexplored floor rejects torch designation")
	world.light_field.mark_explored(target.x, target.y, target.z)
	world.light_field.mark_explored(target.x, target.y - 1, target.z)
	result = selector._enqueue_task_at(target.x, target.y, target.z)
	_check(bool(result.queued) and world.task_queue.has_active_task_at(target, TaskQueue.TaskType.TORCH), "valid floor queues a TORCH task")
	var unsupported := Vector3i(2, 20, 4)
	world.set_block_raw(unsupported.x, unsupported.y, unsupported.z, World.BLOCK_ID_AIR, false)
	world.set_block_raw(unsupported.x, unsupported.y - 1, unsupported.z, World.BLOCK_ID_AIR, false)
	_check(selector._torch_reject_reason(unsupported) == "unsupported", "unsupported cell is rejected")
	_check(selector._torch_reject_reason(Vector3i(2, 19, 1)) == "not_empty", "solid cell is rejected")
	_check(selector._torch_reject_reason(target) == "duplicate", "duplicate pending task is rejected")
	_check(not WorkerRolesScript.allowed_task_types(WorkerRolesScript.Role.HAULER).has(TaskQueue.TaskType.TORCH), "hauler role remains ineligible for torch work")
	_check(WorkerRolesScript.allowed_task_types(WorkerRolesScript.Role.MINER).has(TaskQueue.TaskType.TORCH), "miner template includes torch work")
	_check(WorkPrioritiesScript.task_work_id(TaskQueue.TaskType.TORCH) == "building" and WorkPrioritiesScript.effective_priority(WorkerRolesScript.Role.MINER, {}, "building") == 2, "V9 building priority defaults make torch work eligible")

	var task := world.task_queue.get_task(_active_torch_task_id(world, target))
	var work_rules = preload("res://scripts/task_work_position_rules.gd")
	var adjacent_positions: Array[Vector3i] = work_rules.task_work_positions(world, world.pathfinder, target, TaskQueue.TaskType.TORCH)
	_check(adjacent_positions.has(Vector3i(1, 20, 1)), "torch jobs use a reachable cardinal work position")
	var worker := Worker.new()
	worker.worker_id = 77
	worker.role_id = WorkerRolesScript.Role.MINER
	worker.work_priorities = {"mining": 1, "hauling": 1, "building": 1}
	worker.use_animated_model = false
	worker.position = Vector3(1, 20, 1)
	world.add_child(worker)
	world.workers.append(worker)
	var placed_end_to_end := await _advance_until(world, func(): return world.torch_store.has_torch(target))
	_check(placed_end_to_end and world.task_queue.get_task(task.id) == null, "real assignment and world updates complete the torch job")
	_check(world.torch_store.facing(target) == Vector3i.ZERO, "torch placed on open floor stands upright")
	world.light_field.process_events(100000)
	_check(world.light_field.get_block_light(target.x, target.y, target.z) == 15, "torch cell receives block light 15")
	for distance in range(1, 5):
		_check(world.light_field.get_block_light(target.x + distance, target.y, target.z) == 15 - distance, "torch falloff is one level per cell at distance %d" % distance)

	world.player_mode = World.PlayerMode.ERASE
	var erased: Dictionary = selector._enqueue_task_at(target.x, target.y, target.z)
	_check(bool(erased.queued) and not world.torch_store.has_torch(target), "Erase removes torch instantly")
	world.light_field.process_events(100000)
	_check(world.light_field.light == baseline_light, "removing torch restores the pre-torch light bytes")
	var pending_erase_pos := Vector3i(5, 20, 1)
	world.player_mode = World.PlayerMode.TORCH
	var pending_erase: Dictionary = selector._enqueue_task_at(pending_erase_pos.x, pending_erase_pos.y, pending_erase_pos.z)
	_check(bool(pending_erase.queued), "second torch designation queues for erase test")
	world.player_mode = World.PlayerMode.ERASE
	var pending_erased: Dictionary = selector._enqueue_task_at(pending_erase_pos.x, pending_erase_pos.y, pending_erase_pos.z)
	_check(bool(pending_erased.queued) and not world.task_queue.has_active_task_at(pending_erase_pos, TaskQueue.TaskType.TORCH), "Erase cancels a pending torch designation")
	world.player_mode = World.PlayerMode.TORCH
	world.torch_store.add_torch(target)
	world.light_field.process_events(100000)
	world.light_field.build(world)
	world.light_field_built = true
	world.torch_store.register_light_sources()
	_check(world.light_field.pending_events() == 0, "registering already-known torch sources after rebuild queues no duplicate events")
	world.light_field.process_events(100000)
	_check(world.light_field.get_block_light(target.x, target.y, target.z) == 15, "light-field rebuild retains torch light")
	world.set_block_raw(target.x, target.y - 1, target.z, World.BLOCK_ID_AIR, true)
	world.light_field.process_events(100000)
	_check(not world.torch_store.has_torch(target), "removing support removes torch attachment")
	_check(world.light_field.get_block_light(target.x, target.y, target.z) == 0, "support loss removes torch light")

	var priority_pos := Vector3i(4, 20, 1)
	world.set_block_raw(priority_pos.x - 1, priority_pos.y, priority_pos.z, World.BLOCK_ID_GRANITE, false)
	world.set_block_raw(priority_pos.x + 1, priority_pos.y, priority_pos.z, World.BLOCK_ID_GRANITE, false)
	world.set_block_raw(priority_pos.x, priority_pos.y, priority_pos.z - 1, World.BLOCK_ID_GRANITE, false)
	world.set_block_raw(priority_pos.x, priority_pos.y, priority_pos.z + 1, World.BLOCK_ID_GRANITE, false)
	_check(world.torch_mount_facing(priority_pos) == Vector3i.LEFT, "wall mount priority chooses -X before other solid neighbours")
	world.set_block_raw(priority_pos.x - 1, priority_pos.y, priority_pos.z, World.BLOCK_ID_AIR, false)
	_check(world.torch_mount_facing(priority_pos) == Vector3i.RIGHT, "wall mount priority chooses +X before -Z and +Z")
	world.set_block_raw(priority_pos.x + 1, priority_pos.y, priority_pos.z, World.BLOCK_ID_AIR, false)
	_check(world.torch_mount_facing(priority_pos) == Vector3i.FORWARD, "wall mount priority chooses -Z before +Z")
	world.set_block_raw(priority_pos.x, priority_pos.y, priority_pos.z - 1, World.BLOCK_ID_AIR, false)
	_check(world.torch_mount_facing(priority_pos) == Vector3i.BACK, "last wall mount candidate is +Z")
	world.set_block_raw(priority_pos.x, priority_pos.y, priority_pos.z + 1, World.BLOCK_ID_AIR, false)
	_check(world.torch_mount_facing(priority_pos) == Vector3i.ZERO, "open floor has no wall facing")

	var mount_pos := Vector3i(5, 20, 1)
	var revision_before_remount: int = world.torch_store.revision
	world.torch_store.add_torch(mount_pos)
	world.set_block_raw(mount_pos.x + 1, mount_pos.y, mount_pos.z, World.BLOCK_ID_GRANITE, false)
	_check(world.torch_store.facing(mount_pos) == Vector3i.ZERO, "building next to a standing torch leaves its mount unchanged")
	world.set_block_raw(mount_pos.x, mount_pos.y - 1, mount_pos.z, World.BLOCK_ID_AIR, false)
	_check(world.torch_store.has_torch(mount_pos) and world.torch_store.facing(mount_pos) == Vector3i.RIGHT,
		"losing floor support remounts on the first available wall")
	_check(world.torch_store.revision > revision_before_remount, "remount increments torch visual revision")
	world.set_block_raw(mount_pos.x, mount_pos.y, mount_pos.z + 1, World.BLOCK_ID_GRANITE, false)
	world.set_block_raw(mount_pos.x + 1, mount_pos.y, mount_pos.z, World.BLOCK_ID_AIR, false)
	_check(world.torch_store.facing(mount_pos) == Vector3i.BACK, "digging a wall remounts on another wall")
	world.set_block_raw(mount_pos.x, mount_pos.y - 1, mount_pos.z, World.BLOCK_ID_GRANITE, false)
	world.set_block_raw(mount_pos.x, mount_pos.y, mount_pos.z + 1, World.BLOCK_ID_AIR, false)
	_check(world.torch_store.has_torch(mount_pos) and world.torch_store.facing(mount_pos) == Vector3i.ZERO,
		"wall support loss falls back to a solid floor")
	world.set_block_raw(mount_pos.x, mount_pos.y - 1, mount_pos.z, World.BLOCK_ID_AIR, false)
	_check(not world.torch_store.has_torch(mount_pos), "torch is removed when wall and floor support are gone")
	world.set_block_raw(mount_pos.x, mount_pos.y - 1, mount_pos.z, World.BLOCK_ID_GRANITE, false)

	var wall_floor_pos := Vector3i(6, 20, 1)
	world.set_block_raw(wall_floor_pos.x + 1, wall_floor_pos.y, wall_floor_pos.z, World.BLOCK_ID_GRANITE, false)
	world.torch_store.add_torch(wall_floor_pos, Vector3i.RIGHT)
	world.set_block_raw(wall_floor_pos.x, wall_floor_pos.y - 1, wall_floor_pos.z, World.BLOCK_ID_AIR, false)
	_check(world.torch_store.has_torch(wall_floor_pos) and world.torch_store.facing(wall_floor_pos) == Vector3i.RIGHT,
		"digging the floor under a wall torch keeps its wall support")
	world.torch_store.remove_torch(wall_floor_pos)
	world.set_block_raw(wall_floor_pos.x + 1, wall_floor_pos.y, wall_floor_pos.z, World.BLOCK_ID_AIR, false)
	world.set_block_raw(wall_floor_pos.x, wall_floor_pos.y - 1, wall_floor_pos.z, World.BLOCK_ID_GRANITE, false)
	world.light_field.process_events(100000)

	world.torch_store.add_torch(target)
	# Visible like a standing worker: cell y shows while y <= render level + 1.
	var high_torch := Vector3i(3, 42, 1)
	world.torch_store.add_torch(high_torch)
	var overlay := OverlayRendererScript.new()
	root.add_child(overlay)
	overlay.initialize(world)
	overlay._sync_torch_multimesh()
	_check(overlay.torch_multimesh_instance.multimesh.instance_count == 1, "MultiMesh hides torches standing above the render level")
	var torch_mesh: Mesh = overlay.torch_multimesh_instance.multimesh.mesh
	_check(is_equal_approx(torch_mesh.get_aabb().position.y, -0.5), "torch mesh rests on the floor of its cell")
	world.top_render_y = 41
	overlay._sync_torch_multimesh()
	_check(overlay.torch_multimesh_instance.multimesh.instance_count == 2, "MultiMesh includes torches when render level rises")
	world.torch_store.remove_torch(target)
	world.light_field.process_events(100000)

	var support_loss_pos := Vector3i(5, 20, 1)
	_check(world.queue_task_request(TaskQueue.TaskType.TORCH, support_loss_pos, 0), "torch support-loss scenario is designated")
	var support_task := _active_torch_task_id(world, support_loss_pos)
	var support_assigned := await _advance_until(world, func():
		var active = world.task_queue.get_task(support_task)
		return active != null and active.status == TaskQueue.TaskStatus.IN_PROGRESS
	)
	_check(support_assigned, "support-loss torch job is assigned through the normal update loop")
	world.set_block_raw(support_loss_pos.x, support_loss_pos.y - 1, support_loss_pos.z, World.BLOCK_ID_AIR, true)
	var support_cancelled := await _advance_until(world, func(): return world.task_queue.get_task(support_task) == null)
	world.light_field.process_events(100000)
	_check(support_cancelled and not world.torch_store.has_torch(support_loss_pos), "support removed after assignment cancels without placing a torch")
	_check(world.light_field.get_block_light(support_loss_pos.x, support_loss_pos.y, support_loss_pos.z) == 0, "invalid support-loss job contributes no light")
	_check(worker.state == Worker.WorkerState.IDLE and worker.idle_timer >= IDLE_PAUSE, "worker idles with pause after invalid support cancels torch job")

	var filled_pos := Vector3i(6, 20, 1)
	_check(world.queue_task_request(TaskQueue.TaskType.TORCH, filled_pos, 0), "torch fill scenario is designated")
	var filled_task := _active_torch_task_id(world, filled_pos)
	var filled_assigned := await _advance_until(world, func():
		var active = world.task_queue.get_task(filled_task)
		return active != null and active.status == TaskQueue.TaskStatus.IN_PROGRESS
	)
	_check(filled_assigned, "filled-cell torch job is assigned through the normal update loop")
	world.set_block_raw(filled_pos.x, filled_pos.y, filled_pos.z, World.BLOCK_ID_GRANITE, true)
	var filled_cancelled := await _advance_until(world, func(): return world.task_queue.get_task(filled_task) == null)
	_check(filled_cancelled and not world.torch_store.has_torch(filled_pos), "cell filled after assignment cancels without placing a torch")
	_check(worker.state == Worker.WorkerState.IDLE and worker.idle_timer >= IDLE_PAUSE, "worker idles with pause after filled-cell cancellation")

	var torch_first_pos := Vector3i(4, 20, 2)
	_check(world.queue_task_request(TaskQueue.TaskType.TORCH, torch_first_pos, 0), "torch-first conflict designation queues")
	_check(not world.queue_task_request(TaskQueue.TaskType.PLACE, torch_first_pos, World.BLOCK_ID_GRANITE), "PLACE is rejected over active TORCH designation")
	world.cancel_pending_task_requests_at(torch_first_pos)
	var place_first_pos := Vector3i(5, 20, 2)
	_check(world.queue_task_request(TaskQueue.TaskType.PLACE, place_first_pos, World.BLOCK_ID_GRANITE), "place-first conflict designation queues")
	_check(not world.queue_task_request(TaskQueue.TaskType.TORCH, place_first_pos, 0), "TORCH is rejected over any active task")
	world.cancel_pending_task_requests_at(place_first_pos)

	var opaque_pos := Vector3i(0, 21, 0)
	world.set_block_raw(opaque_pos.x, opaque_pos.y, opaque_pos.z, World.BLOCK_ID_GRANITE, true)
	world.light_field.add_light_source(opaque_pos, 15)
	world.light_field.process_events(100000)
	_check(world.light_field.get_block_light(opaque_pos.x, opaque_pos.y, opaque_pos.z) == 0 \
		and world.light_field.get_block_light(opaque_pos.x + 1, opaque_pos.y, opaque_pos.z) == 0,
		"opaque source cell emits no block light")

	var task_save := TaskSaveLoadScript.new()
	var save_dir := "user://torch_task_%d" % OS.get_process_id()
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(save_dir))
	world.queue_task_request(TaskQueue.TaskType.TORCH, Vector3i(4, 20, 1), 0)
	_check(task_save.save_tasks(world, ProjectSettings.globalize_path(save_dir)), "saving tasks with pending TORCH task succeeds")
	var saved_tasks: Dictionary = task_save.read_snapshot(world, ProjectSettings.globalize_path(save_dir))
	_check(bool(saved_tasks.get("ok", false)) and saved_tasks.get("tasks", []).size() == 1 \
		and saved_tasks.get("tasks", [])[0].get("type") == TaskQueue.TaskType.TORCH, "tasks.dat restores the pending TORCH designation")

	print("Torch task: %d checks, %d failures" % [checks, failures])
	world.task_manager.shutdown()
	world.queue_free()
	quit(1 if failures else 0)


func _active_torch_task_id(world: World, pos: Vector3i) -> int:
	for task in world.task_queue.get_active_tasks_at(pos):
		if task.type == TaskQueue.TaskType.TORCH:
			return task.id
	return -1


func _advance_until(world: TestWorld, condition: Callable, max_steps: int = 1800) -> bool:
	var deadline := Time.get_ticks_msec() + 30000
	for _step in max_steps:
		world.update_world(1.0 / 60.0)
		if condition.call():
			return true
		if Time.get_ticks_msec() >= deadline:
			return false
		await process_frame
	return condition.call()
