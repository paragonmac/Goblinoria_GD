extends SceneTree
## Several mesh worker threads must produce exactly the geometry a synchronous
## build produces, lose no jobs, and survive a thread-count change mid-queue.

const WAIT_TIMEOUT_MS := 60000
const CHUNK_COORDS_X := 6
const CHUNK_COORDS_Z := 6

var checks := 0
var failures := 0


func _init() -> void:
	_test_default_worker_count()
	var reference := _build_reference()
	var most: int = WorldRenderer.MESH_WORKER_THREADS_MAX
	_test_parallel_matches_reference(reference, most, -1)
	_test_parallel_matches_reference(reference, most, 1)
	_test_parallel_matches_reference(reference, 1, most)
	print("Mesh workers: %d checks, %d failures" % [checks, failures])
	quit(1 if failures else 0)


func _check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures += 1
		push_error(message)


func _coords() -> Array[Vector3i]:
	var coords: Array[Vector3i] = []
	for cx in CHUNK_COORDS_X:
		for cz in CHUNK_COORDS_Z:
			coords.append(Vector3i(cx, 2, cz))
	return coords


## Deterministic mixed terrain: rock, air pockets, ramps and a second material,
## so neighbouring chunks differ and face culling across borders matters.
func _make_world() -> World:
	var world := World.new()
	world._init_ramp_lookup()
	world.block_registry.load_from_csv(World.BLOCK_DATA_PATH)
	world.top_render_y = 200
	var renderer := WorldRenderer.new()
	renderer.use_async_meshing = false
	world.add_child(renderer)
	world.renderer = renderer
	renderer.initialize(world)
	var size: int = World.CHUNK_SIZE
	var rng := RandomNumberGenerator.new()
	rng.seed = 20261111
	var palette := [World.BLOCK_ID_AIR, World.BLOCK_ID_AIR, World.BLOCK_ID_GRANITE, World.BLOCK_ID_GRANITE,
		World.BLOCK_ID_DIRT, World.BLOCK_ID_CLAY, World.RAMP_NORTH_ID, World.RAMP_EAST_ID]
	for coord: Vector3i in _coords():
		var chunk: ChunkData = world.ensure_chunk(coord)
		for lx in size:
			for ly in size:
				for lz in size:
					chunk.blocks[renderer.mesher.chunk_index(size, lx, ly, lz)] = palette[rng.randi_range(0, palette.size() - 1)]
		chunk.generated = true
		chunk.dirty = true
	return world


func _dispose(world: World) -> void:
	world.renderer._stop_mesh_worker()
	world.free()


func _export(world: World) -> Dictionary:
	var entries := {}
	for coord: Vector3i in _coords():
		entries[coord] = world.renderer.export_persistent_mesh_cache_entry(coord, World.CHUNK_SIZE - 1)
	return entries


func _build_reference() -> Dictionary:
	var world := _make_world()
	for coord: Vector3i in _coords():
		world.renderer.queue_chunk_mesh_build(coord)
	var entries := _export(world)
	var with_geometry := 0
	for coord: Vector3i in entries:
		if bool(entries[coord].get("has_geometry", false)) and entries[coord].vertices.size() > 0:
			with_geometry += 1
	_check(with_geometry == _coords().size(), "setup: synchronous reference built %d of %d meshes" % [with_geometry, _coords().size()])
	_dispose(world)
	return entries


func _test_default_worker_count() -> void:
	var count: int = WorldRenderer.default_mesh_worker_count()
	_check(count >= 1 and count <= WorldRenderer.MESH_WORKER_THREADS_MAX,
		"default mesh worker count %d is outside 1..%d" % [count, WorldRenderer.MESH_WORKER_THREADS_MAX])


## change_to >= 0 switches the thread count while jobs are still queued.
func _test_parallel_matches_reference(reference: Dictionary, workers: int, change_to: int) -> void:
	var label := "workers=%d%s" % [workers, "" if change_to < 0 else " then %d" % change_to]
	var world := _make_world()
	var renderer: WorldRenderer = world.renderer
	renderer.use_async_meshing = true
	renderer.set_mesh_worker_count(workers)
	_check(renderer.mesh_scheduler.worker_count == workers, "%s: scheduler configured for %d threads" % [label, renderer.mesh_scheduler.worker_count])
	for coord: Vector3i in _coords():
		renderer.queue_chunk_mesh_build(coord)
	_check(renderer.mesh_scheduler.mesh_threads.size() == workers, "%s: %d threads started" % [label, renderer.mesh_scheduler.mesh_threads.size()])
	if change_to >= 0:
		renderer.set_mesh_worker_count(change_to)
		_check(renderer.mesh_scheduler.mesh_threads.size() == change_to, "%s: thread count did not change" % label)
	var deadline := Time.get_ticks_msec() + WAIT_TIMEOUT_MS
	var ready := 0
	while Time.get_ticks_msec() < deadline:
		renderer.process_mesh_results(64)
		ready = 0
		for coord: Vector3i in _coords():
			if world.get_chunk(coord).mesh_state == ChunkData.MESH_STATE_READY:
				ready += 1
		if ready == _coords().size():
			break
		OS.delay_usec(500)
	_check(ready == _coords().size(), "%s: only %d of %d chunks became ready" % [label, ready, _coords().size()])
	var snapshot: Dictionary = renderer.mesh_scheduler.get_performance_snapshot()
	_check(int(snapshot.in_flight) == 0 and int(snapshot.queued) == 0 and int(snapshot.results_pending) == 0,
		"%s: scheduler not idle after all chunks were ready: %s" % [label, snapshot])
	var entries := _export(world)
	var mismatched := 0
	for coord: Vector3i in reference:
		var expected: Dictionary = reference[coord]
		var actual: Dictionary = entries.get(coord, {})
		for key in ["vertices", "normals", "colors", "uv", "uv2"]:
			if actual.get(key) != expected.get(key):
				mismatched += 1
				break
	_check(mismatched == 0, "%s: %d chunks differ from the synchronous build" % [label, mismatched])
	renderer._stop_mesh_worker()
	_check(renderer.mesh_scheduler.mesh_threads.is_empty() and not renderer.mesh_scheduler.is_running(), "%s: workers did not stop" % label)
	world.free()
