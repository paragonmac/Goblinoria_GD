extends SceneTree
## Main input/lifecycle integration. Synthetic fixtures, not a performance benchmark.

const MenuFixture = preload("res://tools/validate_context_menu.gd")
const SelectionFixture = preload("res://tools/validate_selection_input.gd")
const RecorderScript = preload("res://scripts/diagnostics/passive_performance_recorder.gd")


class PhaseWorld:
	extends SelectionFixture.SelectionWorld
	var phases: Array[String] = []
	var save_result := true
	var load_result := true

	func update_streaming(_rect: Rect2, _plane: float, _dt: float, _camera: Camera3D = null, _render_band_rects: Dictionary = {}) -> void:
		pass

	func process_generation_results() -> void:
		phases.append("generation")
	func update_render_height_queue() -> void:
		phases.append("render_height")
	func update_task_assignments() -> void:
		phases.append("assignments")
	func update_workers(_dt: float) -> void:
		phases.append("workers")
	func update_task_queue() -> void:
		phases.append("tasks")
	func update_task_accessibility() -> void:
		phases.append("accessibility")
	func update_reassign_tasks(_dt: float) -> void:
		phases.append("reassignment")
	func update_task_overlays_phase() -> void:
		phases.append("overlays")
	func save_world(_path: String) -> bool:
		return save_result
	func load_world(_path: String) -> bool:
		return load_result


class CaptureMain:
	extends MenuFixture.MenuMain

	func _ready() -> void:
		super._ready()
		_setup_debug_overlay()
		_setup_performance_capture()
		generate_full_map_on_startup = false

	func _has_save_game() -> bool:
		return true
	func _show_loading_screen(_message: String) -> void:
		loading_active = true
	func _hide_loading_screen() -> void:
		loading_active = false
	func _finish_world_start_or_load(_prefix: String, _warmup: bool) -> void:
		world_started = true
	func _report_load_metrics(_label: String, _start: int) -> void:
		pass


class KeyOwner:
	extends Control
	var received := 0
	func _gui_input(event: InputEvent) -> void:
		if event is InputEventKey and event.keycode == KEY_F12:
			received += 1
			accept_event()


var main: CaptureMain
var world: PhaseWorld
var checks := 0
var errors: Array[String] = []
var test_root := ""


func _init() -> void:
	_run.call_deferred()


func _run() -> void:
	test_root = OS.get_environment("TEMP").path_join("goblinoria-passive-input-%d-%d" % [OS.get_process_id(), Time.get_ticks_usec()])
	root.size = Vector2i(1000, 800)
	root.gui_embed_subwindows = true
	var scene = load("res://scenes/Main.tscn").instantiate()
	scene.set_script(CaptureMain)
	scene.get_node("World").set_script(PhaseWorld)
	main = scene
	root.add_child(main)
	world = main.world
	main.performance_controller.capture_root = test_root
	await _settle()
	await _test_input()
	await _test_lifecycle()
	await _test_phases()
	_test_handoff_metrics()
	await _test_exit()
	_remove_fixture(test_root)
	if errors.is_empty():
		print("Passive gameplay profiling integration OK (%d checks)" % checks)
		quit(0)
	else:
		for error in errors:
			push_error(error)
		quit(1)


func _test_input() -> void:
	_check(not _recorder().enabled, "capture is opt-in")
	main.world_started = false
	_key(KEY_F12)
	_check(not _recorder().enabled, "cannot start before a world exists")
	main.world_started = true
	_key(KEY_F12)
	_check(_recorder().enabled, "real Main F12 starts capture")
	_check(not main.debug_overlay.show_debug_timings, "capture does not expose timing HUD")
	_key(KEY_F12, true, false, true)
	_check(_recorder().enabled, "key echo cannot toggle capture")
	_key(KEY_F12, true, true)
	_check(_recorder().enabled, "Shift F12 marks without stopping")
	main.debug_overlay.hide()
	await _settle()
	_check(_recorder().enabled, "hidden overlay does not stop capture")
	_check(main.performance_controller.indicator.mouse_filter == Control.MOUSE_FILTER_IGNORE, "status never owns mouse input")
	_key(KEY_F12)
	_check(not _recorder().enabled, "F12 stops")
	var first_path: String = _recorder().output_path
	_check(FileAccess.file_exists(first_path.path_join("summary.json")), "stop leaves JSON summary")
	var events := FileAccess.get_file_as_string(first_path.path_join("events.jsonl"))
	_check(events.contains("manual"), "manual marker recorded")
	var owner := KeyOwner.new()
	owner.focus_mode = Control.FOCUS_ALL
	owner.size = Vector2(120, 40)
	main.hud_layer.add_child(owner)
	owner.grab_focus()
	_key(KEY_F12)
	_check(owner.received > 0 and not _recorder().enabled, "GUI-owned F12 does not record")
	owner.release_focus()
	owner.free()
	await _settle()
	_check(not _recorder().enabled, "GUI-consumed shortcut does not replay")
	main.context_menu_controller.open_at(Vector2(400, 300))
	await _settle()
	_key(KEY_F12)
	_check(not _recorder().enabled, "context popup owns shortcut")
	main.context_menu_controller.cancel()
	await _settle()
	_check(not _recorder().enabled, "popup shortcut does not replay on dismissal")
	var dropdown := OptionButton.new()
	dropdown.add_item("one")
	main.hud_layer.add_child(dropdown)
	dropdown.get_popup().popup(Rect2i(30, 30, 140, 80))
	await _settle()
	_key(KEY_F12)
	_check(not _recorder().enabled, "dropdown owns shortcut")
	dropdown.get_popup().hide()
	dropdown.free()
	await _settle()
	_check(not _recorder().enabled, "dropdown shortcut never replays")
	main.open_menu()
	await _settle()
	_key(KEY_F12)
	_check(_recorder().enabled and _recorder().segment == "menu", "can start capture from menu")
	main.close_menu()
	_check(_recorder().segment == "gameplay", "resume returns capture to gameplay")


func _test_lifecycle() -> void:
	main._notification(MainLoop.NOTIFICATION_APPLICATION_FOCUS_OUT)
	_check(_recorder().segment == "unfocused", "focus loss creates separate segment")
	main.open_menu()
	_check(_recorder().segment == "unfocused", "focus overrides menu")
	main._notification(MainLoop.NOTIFICATION_APPLICATION_FOCUS_IN)
	_check(_recorder().segment == "menu", "focus return restores menu")
	for success in [false, true]:
		world.save_result = success
		await main._on_save_pressed()
		_check(_recorder().enabled and _recorder().segment == "menu", "save outcome retains menu recording")
		world.load_result = success
		await main._load_world_with_loading()
		_check(_recorder().enabled, "load outcome preserves capture")
		_check(world.performance_recorder == _recorder(), "world keeps shared recorder")
		_check(_recorder().segment == ("gameplay" if success else "menu"), "load outcome restores correct segment")
	main.loading_active = true
	_check(_recorder().segment == "loading", "loading property labels capture")
	await _settle()
	_key(KEY_F12)
	_check(not _recorder().enabled, "can stop during loading frames")
	var events := FileAccess.get_file_as_string(_recorder().output_path.path_join("events.jsonl"))
	_check(events.contains("saving_started") and events.contains("saving_finished"), "save markers reach report")
	_check(events.contains("loading_finished") and events.contains("false") and events.contains("true"), "load outcomes reach report")
	main.loading_active = false
	main.close_menu()
	await _settle()
	_key(KEY_F12)
	var path: String = _recorder().output_path
	main.performance_controller.world_replaced("new_world")
	_check(_recorder().output_path == path and _recorder().enabled, "replacement keeps same recording")
	_key(KEY_F12)


func _test_phases() -> void:
	main.set_process(false)
	var expected: Array[String] = ["generation", "render_height", "assignments", "workers", "tasks", "accessibility", "reassignment", "overlays"]
	for recording in [false, true]:
		for show_timings in [false, true]:
			if main.debug_overlay.show_debug_timings != show_timings:
				main.debug_overlay.toggle_debug_timings()
			if recording:
				_recorder().start({"test": true}, -1, test_root)
			world.phases.clear()
			main._process(0.016)
			_check(world.phases == expected, "each phase exactly once; capture=%s HUD=%s" % [recording, show_timings])
			if recording:
				_recorder().stop()
	main.set_process(true)


func _test_exit() -> void:
	_recorder().start({"test": "exit"}, -1, test_root)
	var recorder = _recorder()
	var path: String = recorder.output_path
	world.task_manager.shutdown()
	main.free()
	await process_frame
	_check(not recorder.enabled, "tree exit stops recorder")
	_check(FileAccess.file_exists(path.path_join("summary.md")), "exit finalizes readable summary")
	recorder.stop()
	_check(not recorder.enabled, "stop is idempotent")


func _test_handoff_metrics() -> void:
	main.set_process(false)
	_recorder().start({"test": "handoffs"}, -1, test_root)
	var scheduler = world.task_manager.path_search_scheduler
	scheduler.result_mutex.lock()
	for kind in ["assignment", "goals", "haul_delivery"]:
		scheduler.result_queue.append({"kind": kind, "auction_id": -999,
			"request_id": -999, "snapshot_ms": 1.0, "queue_wait_ms": 2.0,
			"search_ms": 3.0, "path": []})
	scheduler.result_mutex.unlock()
	_check(scheduler.get_performance_snapshot().results_pending == 3, "path pending queue snapshot")
	world.task_manager._process_path_results()
	world.task_manager._process_path_results()
	_check(scheduler.get_performance_snapshot().results_pending == 0, "path handoff drains queue")
	var renderer := WorldRenderer.new()
	renderer.add_child(renderer.chunk_cache)
	renderer.add_child(renderer.overlay_renderer)
	renderer.world = world
	_check(not renderer._apply_mesh_result({"mesh_epoch": -999, "coord_epoch": -999, "build_ms": 4.0}), "stale mesh rejected with capture enabled")
	var generator := WorldGenerator.new(world)
	generator.generation_queue.mutex.lock()
	generator.generation_queue.results.append({"epoch": -999})
	generator.generation_queue.mutex.unlock()
	_check(generator.process_generation_results(1) == 0, "stale generation result not applied")
	var unavailable := world.get_performance_snapshot()
	_check(unavailable.mesh_queued == null and unavailable.generation_queued == null, "absent subsystems stay unavailable")
	world.set_block(14, 0, 10, World.BLOCK_ID_AIR)
	world.set_block(14, 0, 10, World.BLOCK_ID_AIR)
	_recorder().stop()
	var summary: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(_recorder().output_path.path_join("summary.json")))
	var counts: Dictionary = summary.counters_by_segment
	_check(counts.get("gameplay/Path.results") == 3, "each completed path counted once")
	_check(counts.get("gameplay/Path.assignment.cancelled") == 1 \
		and counts.get("gameplay/Path.goals.cancelled") == 1 \
		and counts.get("gameplay/Path.haul_delivery.cancelled") == 1, "cancelled outcomes distinguished by path kind")
	_check(counts.get("gameplay/Mesh.results") == 1 and counts.get("gameplay/Mesh.stale") == 1, "stale mesh build still has completed-work denominator")
	_check(counts.get("gameplay/Generation.results") == 1 and counts.get("gameplay/Generation.stale") == 1, "stale generation is counted not applied")
	_check(counts.get("gameplay/terrain_change") == 1, "only a real block change increments terrain activity")
	var timings: Dictionary = summary.timings_ms_by_segment
	_check(timings["gameplay/Path.completed.search_ms"].count == 3 \
		and timings["gameplay/Path.completed.search_ms"].sum == 9, "completed path costs do not disappear on cancellation")
	_check(timings["gameplay/Mesh.completed.build_ms"].sum == 4, "completed mesh timing survives stale rejection")
	renderer.free()
	main.set_process(true)


func _recorder():
	return main.performance_controller.recorder


func _key(code: int, pressed := true, shift := false, echo_event := false) -> void:
	var event := InputEventKey.new()
	event.keycode = code
	event.physical_keycode = code
	event.pressed = pressed
	event.shift_pressed = shift
	event.echo = echo_event
	Input.parse_input_event(event)
	Input.flush_buffered_events()
	if pressed and not echo_event:
		_key(code, false, shift)


func _settle() -> void:
	await process_frame
	await process_frame


func _check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		errors.append(message)


func _remove_fixture(path: String) -> void:
	# Delete only the unique directory created by this test, never a user save.
	if test_root.is_empty() or (path != test_root and not path.begins_with(test_root + "/")):
		return
	if not DirAccess.dir_exists_absolute(path):
		return
	for filename in DirAccess.get_files_at(path):
		DirAccess.remove_absolute(path.path_join(filename))
	for dirname in DirAccess.get_directories_at(path):
		_remove_fixture(path.path_join(dirname))
	DirAccess.remove_absolute(path)
