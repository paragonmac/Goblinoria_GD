extends SceneTree
## Synthetic fixtures exercise production Main callbacks and read-only queries.
const Fixture = preload("res://tools/validate_passive_gameplay_profiling.gd")
const MenuFixture = preload("res://tools/validate_context_menu.gd")
const Service = preload("res://scripts/diagnostics/live_diagnostics_service.gd")
const Writer = preload("res://scripts/diagnostics/bug_capture_writer.gd")
const LoggerScript = preload("res://scripts/diagnostics/live_diagnostics_logger.gd")
const SaveFixture = preload("res://tools/validate_save_load_transaction.gd")
class DiagnosticMain:
	extends Fixture.CaptureMain
	func _ready() -> void:
		super._ready()
		_setup_live_diagnostics()
class DiagnosticWorld:
	extends Fixture.PhaseWorld
	var simulation_steps := 0
	var generation_requests := 0
	func update_world(dt: float) -> void:
		simulation_steps += 1
		super.update_world(dt)
	func ensure_chunk_generated(coord: Vector3i) -> ChunkData:
		generation_requests += 1
		return super.ensure_chunk_generated(coord)
class KeyOwner:
	extends Control
	func _gui_input(event: InputEvent) -> void:
		if event is InputEventKey and event.keycode == KEY_F1:
			accept_event()
var failures: Array[String] = []
var checks := 0
var main
var world
var controller
var test_root: String

func _init() -> void:
	_run.call_deferred()

func _run() -> void:
	test_root = OS.get_environment("TEMP").path_join("goblinoria-live-%s-%s" % [OS.get_process_id(), Time.get_ticks_usec()])
	_core()
	root.size = Vector2i(1000, 800)
	root.gui_embed_subwindows = true
	var scene = load("res://scenes/Main.tscn").instantiate()
	scene.set_script(DiagnosticMain)
	scene.get_node("World").set_script(DiagnosticWorld)
	main = scene
	root.add_child(scene)
	world = main.world
	controller = main.diagnostics_controller
	controller.writer.root_path = test_root.path_join("bugs")
	controller.transport.descriptor_root = test_root.path_join("bridge")
	await process_frame
	await _input_and_capture()
	_queries()
	_rendering()
	_phases()
	await _lifecycle()
	await _writer_failures()
	_real_load_lifecycle()
	controller._last_capture_usec = -controller.CAPTURE_COOLDOWN_USEC
	controller.request_capture({"note": "quit while pending"})
	world.task_manager.shutdown()
	main.free()
	await process_frame
	_check(not controller.transport.enabled and controller.main == null, "tree exit cleans listener and ownership")
	_check(controller.writer.status.state == "complete", "normal exit finalizes pending metadata-only capture")
	# Keep isolated fixtures as inspectable evidence; they are under TEMP, not real captures.
	if failures.is_empty():
		print("Live diagnostics integration OK (%d checks); fixtures: %s" % [checks, test_root])
		quit(0)
	else:
		for failure in failures:
			push_error(failure)
		quit(1)

func _core() -> void:
	var recorder = Service.new()
	recorder.tick(100)
	recorder.observe("task", 1, "ignored")
	_check(recorder.events.is_empty(), "disabled hooks have no history")
	recorder.set_enabled(true, 100)
	recorder.observe("task", 1, "waiting", {"count": 2})
	var before: int = recorder.events.size()
	recorder.tick(200)
	recorder.observe("task", 1, "waiting", {"count": 2})
	_check(recorder.events.size() == before, "identical decisions coalesce")
	_check(recorder.explain("task", 1).monotonic_usec == 200, "coalescing updates last evaluation time")
	recorder.invalidate("task", 1, "changed")
	_check(not recorder.explain("task", 1).valid, "invalidated reasons not asserted current")
	for i in range(4200):
		recorder.observe("task", i, "waiting", {"i": i})
	_check(recorder.events.size() <= 4096 and recorder.decisions.size() <= 4096, "bounded event and decision counts")
	_check(recorder.dropped_events > 0 and recorder.dropped_decisions > 0, "evictions disclosed")
	recorder.tick(31000000)
	_check(recorder.events.is_empty(), "thirty second history expires")
	var epoch: int = recorder.world_epoch
	recorder.begin_world("test")
	_check(recorder.world_epoch == epoch + 1 and recorder.decisions.is_empty(), "world replacement clears old reasons")
	_check(recorder.dispatch("inspect_cell", {"world_epoch": epoch}).get("error") == "stale_world", "stale world rejected")
	_check(recorder.dispatch("inspect_cell", {}).get("error") == "world_epoch_required", "epoch required for world inspection")
	var large := {}
	for i in range(64):
		large[str(i)] = "x".repeat(1024)
	recorder.observe("task", 1, "large", large)
	_check(recorder.explain("task", 1).data.get("truncated", false), "individual producer payload bound")
	recorder.set_enabled(false, 32000000)
	_check(recorder.events.is_empty() and recorder.decisions.is_empty(), "disable clears volatile data")
	var logger = LoggerScript.new()
	for i in range(300):
		logger._log_error("test", "fixture", i, "code", "message", false, 0, [])
	var batch: Dictionary = logger.drain()
	_check(batch.rows.size() == 256 and batch.dropped == 44, "error callback queue bounded")
	_check(logger.drain().rows.is_empty(), "logger drain transfers owned rows")

func _input_and_capture() -> void:
	_check(not controller.service.enabled, "bridge off by default")
	var count: int = world.simulation_steps
	_key(true)
	_key(false)
	await _finish_capture()
	_check(controller.capture.state == "complete", "F1 creates metadata-only capture")
	_check(not controller.service.enabled and not main.performance_controller.recorder.enabled, "one-off enables neither history nor profiler")
	var path: String = controller.capture.path
	var snapshot = JSON.parse_string(FileAccess.get_file_as_string(path.path_join("snapshot.json")))
	_check(snapshot is Dictionary and snapshot.screenshot.reason == "headless", "valid snapshot with explicit headless reason")
	var manifest = JSON.parse_string(FileAccess.get_file_as_string(path.path_join("manifest.json")))
	_check(manifest.complete and manifest.format_version == 1, "manifest finalizes successfully")
	_check(world.simulation_steps > count, "capture does not stop gameplay")
	_check(FileAccess.get_file_as_string(path.path_join("report.md")).contains("History available: false"), "missing history disclosed")
	controller._last_capture_usec = -controller.CAPTURE_COOLDOWN_USEC
	var old_id: String = controller.capture.capture_id
	_key(true, true)
	await process_frame
	_check(controller.capture.capture_id == old_id, "echo F1 suppressed")
	_key(false)
	var owner := KeyOwner.new()
	owner.focus_mode = Control.FOCUS_ALL
	owner.size = Vector2(100, 100)
	main.hud_layer.add_child(owner)
	owner.grab_focus()
	_key(true)
	_key(false)
	await process_frame
	_check(controller.capture.capture_id == old_id, "GUI-owned F1 not captured or replayed")
	owner.queue_free()
	await process_frame
	controller.set_enabled(true)
	_check(controller.service.enabled and controller.transport.enabled, "manual enable starts bridge")
	_check(FileAccess.file_exists(controller.transport.descriptor_path), "discovery descriptor exists")
	main.open_menu()
	await process_frame
	await process_frame
	_key(true)
	_key(false)
	await _finish_capture()
	_check(controller.capture.capture_id != old_id and controller.capture.state == "complete", "F1 available in menu")
	main.close_menu()

func _queries() -> void:
	var service = controller.service
	var epoch: int = service.world_epoch
	var baseline := [world.chunks.size(), world.chunk_access_tick, world.generation_requests, world.task_queue.tasks.size(), world.item_store.items.size()]
	var missing: Dictionary = service.dispatch("inspect_cell", {"world_epoch": epoch, "pos": [100, 200, 100]}).data
	_check(not missing.loaded and missing.block == null, "unloaded cell not confused with air")
	var cell: Dictionary = service.dispatch("inspect_cell", {"world_epoch": epoch, "pos": [0, 0, 0]}).data
	_check(cell.block.id == World.BLOCK_ID_GRANITE, "loaded cell exact block snapshot")
	_check(service.dispatch("inspect_cell", {"world_epoch": epoch, "pos": [1.5, 0, 0]}).data.error == "integer_pos_required", "fractional coordinate rejected")
	_check(service.dispatch("inspect_cell", {"world_epoch": epoch, "pos": [0, -1, 0]}).data.error == "out_of_bounds", "finite boundaries checked")
	var view: String = controller.inspector.view_id()
	_check(service.dispatch("inspect_screen", {"world_epoch": epoch, "view_id": "old", "point": [500, 400]}).data.error == "stale_view", "stale screen view rejected")
	service.dispatch("inspect_screen", {"world_epoch": epoch, "view_id": view, "point": [500, 400]})
	_check(baseline == [world.chunks.size(), world.chunk_access_tick, world.generation_requests, world.task_queue.tasks.size(), world.item_store.items.size()], "inspection creates no terrain, accesses, tasks or items")
	var a: int = world.task_queue.add_task(Vector3i(0, 0, 0), TaskQueue.TaskType.DIG, 0)
	world.task_queue.add_task(Vector3i(1, 0, 0), TaskQueue.TaskType.DIG, 0)
	var task = world.task_queue.get_task(a)
	task.unreachable_workers[9] = 1
	var copy: Dictionary = task.unreachable_workers.duplicate()
	service.dispatch("inspect_task", {"world_epoch": epoch, "id": a})
	_check(task.unreachable_workers == copy, "task inspection does not expire exclusions")
	var page: Dictionary = service.dispatch("list_tasks", {"world_epoch": epoch, "limit": 1}).data
	_check(page.rows.size() == 1 and page.truncated, "bounded task page")
	world.task_queue.add_task(Vector3i(2, 0, 0), TaskQueue.TaskType.DIG, 0)
	_check(service.dispatch("list_tasks", {"world_epoch": epoch, "cursor": page.cursor}).data.error == "stale_cursor", "membership changes invalidate pagination")
	_check(service.dispatch("inspect_worker", {"world_epoch": epoch, "id": 999}).data.error == "target_missing", "missing worker no silent retarget")
	world.clear_tasks()
	main.loading_active = true
	_check(service.dispatch("inspect_cell", {"world_epoch": epoch, "pos": [0, 0, 0]}).data.error == "world_unavailable", "partial loading world unavailable")
	_check(service.dispatch("status", {}).data.loading, "status available during loading")
	main.loading_active = false

func _lifecycle() -> void:
	var service = controller.service
	var epoch: int = service.world_epoch
	controller.begin_operation("loading")
	controller.finish_operation("loading", false)
	_check(service.world_epoch == epoch, "failed noncommitting operation preserves epoch")
	controller.set_focused(false)
	controller.set_focused(true)
	service.begin_world("test_commit")
	_check(service.world_epoch == epoch + 1 and service.enabled, "recording survives new world")
	var kinds: Array = []
	for event in service.recent_events().events:
		kinds.append(event.kind)
	_check("loading_finished" in kinds and "focus_changed" in kinds and "world_replaced" in kinds, "lifecycle journal")
	controller._last_capture_usec = -controller.CAPTURE_COOLDOWN_USEC
	var first: Dictionary = controller.request_capture({"request_key": "retry"})
	_check(controller.request_capture({"request_key": "retry"}).capture_id == first.capture_id, "idempotent capture retry")
	_check(controller.request_capture({}).error == "capture_busy", "single capture in flight")
	service.begin_world("mid_capture")
	await _finish_capture()
	var snapshot = JSON.parse_string(FileAccess.get_file_as_string(str(controller.capture.path).path_join("snapshot.json")))
	_check(snapshot.screenshot.reason == "world_changed", "capture labels replaced target")
	_check(controller.request_capture({}).error == "capture_cooldown", "capture cooldown enforced")
	var descriptor: String = controller.transport.descriptor_path
	controller.set_enabled(false)
	_check(not FileAccess.file_exists(descriptor) and service.events.is_empty(), "disable removes discovery and history")

func _rendering() -> void:
	var renderer := WorldRenderer.new()
	renderer.use_async_meshing = false
	world.add_child(renderer)
	renderer.initialize(world)
	world.renderer = renderer
	var coord := Vector3i.ZERO
	var loaded: ChunkData = world.get_chunk(coord)
	loaded.generated = true
	loaded.mesh_state = ChunkData.MESH_STATE_READY
	var node := renderer.chunk_cache.ensure_chunk(coord, World.CHUNK_SIZE)
	node.mesh = ArrayMesh.new()
	node.visible = false
	renderer.update_render_zone(-1, 1, -1, 1, 1, 2)
	_check(preload("res://tools/visibility_test_helpers.gd").settle(renderer), "upper view converges")
	var before := [world.chunks.size(), world.chunk_access_tick, loaded.mesh_revision, renderer.mesh_cache_store.get_metrics(), renderer.chunk_cache.created_node_count]
	var state: Dictionary = controller.inspector.chunk(coord)
	_check(state.mesh_state == ChunkData.MESH_STATE_READY and not state.rendering.node_visible and not state.rendering.inside_last_bounds, "ready mesh hidden by higher vertical band explained")
	_check(state.rendering.actual_pixels == "not_measured", "render eligibility does not claim GPU pixels")
	renderer.update_render_zone(-1, 1, -1, 1, 0, 2)
	_check(preload("res://tools/visibility_test_helpers.gd").settle(renderer), "expanded cave view converges")
	state = controller.inspector.chunk(coord)
	_check(state.rendering.inside_last_bounds and state.rendering.last_frustum_accepted, "lower band accepted after expanded zone")
	_check(before == [world.chunks.size(), world.chunk_access_tick, loaded.mesh_revision, renderer.mesh_cache_store.get_metrics(), renderer.chunk_cache.created_node_count], "render inspection does not touch chunk/cache/mesh state")
	world.set_block_raw(3, 1, 3, World.BLOCK_ID_GRANITE, true)
	world.set_block_raw(3, 2, 3, World.BLOCK_ID_GRANITE, true)
	var cave: Dictionary = controller.inspector.cell(Vector3i(3, 1, 3))
	_check(cave.slice.covered_sides == "eligible" and cave.slice.synthetic_internal_tops == "cut_surface_only", "covered cave wall eligibility distinguished from internal cap")
	world.top_render_y = 0
	_check(not controller.inspector.cell(Vector3i(3, 1, 3)).slice.upper_eligible, "render-level upper limit")
	world.top_render_y = 8
	var view: String = controller.inspector.view_id()
	root.size = Vector2i(640, 400)
	_check(view != controller.inspector.view_id(), "resize invalidates view identity")
	root.size = Vector2i(1000, 800)
	renderer.free()
	world.renderer = null

func _phases() -> void:
	var expected := ["generation", "render_height", "assignments", "workers", "tasks", "accessibility", "reassignment", "overlays"]
	for observing in [false, true]:
		controller.set_enabled(observing)
		for timings in [false, true]:
			main.debug_overlay.show_debug_timings = timings
			world.phases.clear()
			main._process(0.016)
			_check(world.phases == expected, "each canonical Main world phase once diagnostics=%s timings=%s" % [observing, timings])
	main.debug_overlay.show_debug_timings = false

func _writer_failures() -> void:
	var writer = Writer.new()
	writer.root_path = test_root.path_join("quota")
	writer.quota_bytes = 1
	writer.start("quota", {}, {}, {})
	await _writer_done(writer)
	_check(writer.status.state == "failed" and writer.status.error == "capture_quota_or_directory_limit", "quota failure explicit")
	writer.root_path = test_root.path_join("small")
	writer.quota_bytes = Writer.QUOTA
	writer.bundle_limit_bytes = 32
	writer.start("small", {}, {}, {})
	await _writer_done(writer)
	_check(writer.status.error == "bundle_limit", "bundle limit enforced")
	var partial = JSON.parse_string(FileAccess.get_file_as_string(str(writer.status.path).path_join("manifest.json")))
	_check(not partial.complete, "failure retains incomplete manifest")
	var file := FileAccess.open(test_root.path_join("not_directory"), FileAccess.WRITE)
	file.store_string("fixture")
	file.close()
	writer.root_path = test_root.path_join("not_directory/child")
	writer.start("blocked", {}, {}, {})
	await _writer_done(writer)
	_check(writer.status.error == "capture_root_unwritable", "creation failure contained")
	writer.shutdown()
	writer.shutdown()

func _real_load_lifecycle() -> void:
	var live = Service.new()
	live.tick()
	live.set_enabled(true)
	var target := SaveFixture.TestWorld.new()
	target._init_ramp_lookup()
	target.save_load = WorldSaveLoad.new(target)
	target.world_seed = 111
	target.top_render_y = 10
	target.sea_level = 12
	target.spawn_coord = Vector3i(0, 3, 0)
	target.spawn_initial_workers()
	var block := ChunkData.new(World.CHUNK_SIZE, World.BLOCK_ID_DIRT)
	block.generated = true
	block.dirty = true
	target.chunks[Vector3i.ZERO] = block
	target.live_diagnostics = live
	var path := test_root.path_join("save-lifecycle/world.save")
	_check(target.save_world(path), "actual World save succeeds with observation")
	var epoch: int = live.world_epoch
	_check(target.load_world(path), "actual World load succeeds with observation")
	_check(live.world_epoch == epoch + 1, "successful same-node load advances epoch once")
	_check(target.diagnostics_workers_by_id.size() == target.workers.size(), "worker index rebuilt on load")
	epoch = live.world_epoch
	_check(not target.load_world(test_root.path_join("missing.save")), "actual missing load fails")
	_check(live.world_epoch == epoch, "failed World load does not advance epoch")
	var success_seen := false
	var failure_seen := false
	for event in live.recent_events().events:
		if event.kind == "loading_finished":
			success_seen = success_seen or bool(event.data.success)
			failure_seen = failure_seen or not bool(event.data.success)
	_check(success_seen and failure_seen, "actual save/load outcomes in journal")
	target.init_world(false)
	_check(live.world_epoch == epoch + 1, "runtime clear advances epoch even without enable transition")
	target.live_diagnostics = null
	target.free()

func _finish_capture() -> void:
	for i in range(600):
		await process_frame
		if controller.capture.state not in ["pending", "writing"]:
			return
	_check(false, "capture completed within test deadline")

func _writer_done(writer) -> void:
	for i in range(600):
		await process_frame
		writer.poll()
		if writer.thread == null:
			return
	_check(false, "writer completed within test deadline")

func _key(pressed: bool, echo := false) -> void:
	var event := InputEventKey.new()
	event.keycode = KEY_F1
	event.physical_keycode = KEY_F1
	event.pressed = pressed
	event.echo = echo
	root.push_input(event, true)

func _check(ok: bool, message: String) -> void:
	checks += 1
	if not ok:
		failures.append(message)
