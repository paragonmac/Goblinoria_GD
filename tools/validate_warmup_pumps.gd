extends SceneTree
## The level warmup pumps run every frame while they have targets. They must do
## a bounded amount of work per frame and must finish once nothing is pending.
## Before 2026-11 they recounted every target on every frame (6-20 ms per frame
## on a 512 world) and never finished if a built chunk was invalidated again.


class CountingWorld extends World:
	var chunk_lookups := 0

	func get_chunk(coord: Vector3i) -> ChunkData:
		chunk_lookups += 1
		return super.get_chunk(coord)


var checks := 0
var failures := 0


func _init() -> void:
	_test_generation_cursor_is_budgeted()
	_test_prewarm_pump_cost_is_bounded()
	_test_prewarm_finishes_after_invalidation()
	_test_prewarm_waits_for_pending_builds()
	_test_background_warmup_finishes_and_waits()
	print("Warmup pumps: %d checks, %d failures" % [checks, failures])
	quit(1 if failures else 0)


func _check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures += 1
		push_error(message)


func _world() -> CountingWorld:
	var world := CountingWorld.new()
	world._init_ramp_lookup()
	world.block_registry.load_from_csv(World.BLOCK_DATA_PATH)
	return world


func _controller(world: World) -> MainRenderLevelController:
	var controller := MainRenderLevelController.new()
	controller.world = world
	return controller


## Row of chunks along X, all generated, each with the given mesh state.
func _targets(world: World, count: int, mesh_state: int) -> Array[Vector3i]:
	var targets: Array[Vector3i] = []
	for index in count:
		var coord := Vector3i(World.WORLD_MIN_CHUNK_X + index % 30, 1 + index / 900, World.WORLD_MIN_CHUNK_Z + (index / 30) % 30)
		var chunk: ChunkData = world.ensure_chunk(coord)
		chunk.generated = true
		chunk.mesh_state = mesh_state
		targets.append(coord)
	return targets


func _test_generation_cursor_is_budgeted() -> void:
	var world := _world()
	var controller := _controller(world)
	var budget: int = MainRenderLevelController.WARMUP_POLL_BUDGET
	var targets := _targets(world, budget * 2 + 50, ChunkData.MESH_STATE_NONE)
	var cursor: int = controller._advance_generated_cursor(targets, 0)
	_check(cursor == budget, "generation cursor advanced %d, expected one budget of %d" % [cursor, budget])
	cursor = controller._advance_generated_cursor(targets, cursor)
	cursor = controller._advance_generated_cursor(targets, cursor)
	_check(cursor == targets.size(), "generation cursor did not reach the end in three calls")
	world.get_chunk(targets[10]).generated = false
	_check(controller._advance_generated_cursor(targets, 0) == 10, "generation cursor passed a chunk that is not generated")
	world.free()


func _test_prewarm_pump_cost_is_bounded() -> void:
	var world := _world()
	var controller := _controller(world)
	var targets := _targets(world, 12000, ChunkData.MESH_STATE_PENDING)
	controller.y_prewarm_generation_targets = targets.duplicate()
	controller.y_prewarm_mesh_targets = targets.duplicate()
	controller.y_prewarm_mesh_index = targets.size()
	controller.y_prewarm_meshes_queued = true
	var limit: int = MainRenderLevelController.WARMUP_POLL_BUDGET * 2 + 8
	for _frame in 4:
		world.chunk_lookups = 0
		controller.pump_directional_prewarm(true)
		_check(world.chunk_lookups <= limit,
			"prewarm pump looked up %d chunks in one frame for %d targets (limit %d)" % [world.chunk_lookups, targets.size(), limit])
	world.free()


func _test_prewarm_finishes_after_invalidation() -> void:
	var world := _world()
	var controller := _controller(world)
	var targets := _targets(world, 3, ChunkData.MESH_STATE_READY)
	# Built once, then invalidated or released: nothing is pending for it.
	world.get_chunk(targets[1]).mesh_state = ChunkData.MESH_STATE_NONE
	controller.y_prewarm_generation_targets = targets.duplicate()
	controller.y_prewarm_mesh_targets = targets.duplicate()
	controller.y_prewarm_mesh_index = targets.size()
	controller.y_prewarm_meshes_queued = true
	controller.y_prewarm_render_y = 40
	for _frame in 3:
		controller.pump_directional_prewarm(true)
	_check(controller.y_prewarm_mesh_targets.is_empty() and controller.y_prewarm_render_y == -1,
		"prewarm never finished after one built chunk was invalidated")
	world.free()


func _test_prewarm_waits_for_pending_builds() -> void:
	var world := _world()
	var controller := _controller(world)
	var targets := _targets(world, 3, ChunkData.MESH_STATE_READY)
	world.get_chunk(targets[2]).mesh_state = ChunkData.MESH_STATE_PENDING
	controller.y_prewarm_generation_targets = targets.duplicate()
	controller.y_prewarm_mesh_targets = targets.duplicate()
	controller.y_prewarm_mesh_index = targets.size()
	controller.y_prewarm_meshes_queued = true
	for _frame in 3:
		controller.pump_directional_prewarm(true)
	_check(controller.y_prewarm_mesh_targets.size() == 3, "prewarm finished while a build was still pending")
	world.get_chunk(targets[2]).mesh_state = ChunkData.MESH_STATE_READY
	controller.pump_directional_prewarm(true)
	_check(controller.y_prewarm_mesh_targets.is_empty(), "prewarm did not finish once the pending build completed")
	world.free()


func _test_background_warmup_finishes_and_waits() -> void:
	var world := _world()
	var renderer := WorldRenderer.new()
	renderer.use_async_meshing = false
	world.add_child(renderer)
	world.renderer = renderer
	renderer.initialize(world)
	var controller := _controller(world)
	var targets := _targets(world, 4, ChunkData.MESH_STATE_NONE)
	var top: int = World.CHUNK_SIZE - 1
	controller.background_warmup_generation_targets = targets.duplicate()
	controller.background_warmup_mesh_targets = targets.duplicate()
	controller.background_warmup_mesh_index = targets.size()
	controller.background_warmup_meshes_queued = true
	controller.background_warmup_band = 5
	# A cache-only build for one chunk is still queued.
	var pending_key: String = renderer.mesh_scheduler.prefetch_key(targets[3], top)
	renderer.mesh_scheduler.mesh_prefetch_set[pending_key] = 0
	_check(renderer.is_chunk_mesh_cache_build_pending(targets[3], top), "setup: cache build is not reported pending")
	for _frame in 3:
		controller.pump_background_warmup(true)
	_check(controller.background_warmup_mesh_targets.size() == 4 and not controller.prepared_chunk_bands.has(5),
		"background warmup finished while a cache build was still queued")
	# It completes (or is cancelled): nothing is pending any more.
	renderer.mesh_scheduler.mesh_prefetch_set.erase(pending_key)
	controller.pump_background_warmup(true)
	_check(controller.background_warmup_mesh_targets.is_empty() and controller.prepared_chunk_bands.has(5),
		"background warmup never finished once no cache build was pending")
	world.free()
