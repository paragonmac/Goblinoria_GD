extends SceneTree
## Headless contract for the bounded playtest fixtures.
## It uses a real World and real camera/render-level adapters, but no production
## Main and no save/load paths, so the test never uses ordinary user data.

const Scenarios = preload("res://scripts/playtest/playtest_scenarios.gd")
const CameraController = preload("res://scripts/main_camera_controller.gd")
const RenderLevelController = preload("res://scripts/main_render_level_controller.gd")


class FixtureMain extends Node3D:
	var world: World
	var camera: Camera3D
	var camera_controller: MainCameraController
	var render_level_controller: MainRenderLevelController
	var world_started := false
	var loading_active := false

	func _ready() -> void:
		world = World.new()
		add_child(world)
		camera = Camera3D.new()
		camera.current = true
		add_child(camera)
		camera_controller = CameraController.new()
		camera_controller.initialize(camera, get_viewport())
		render_level_controller = RenderLevelController.new()
		render_level_controller.initialize(
			world,
			get_tree(),
			camera,
			Callable(self, "get_stream_view_rect_for_y"),
			{}
		)

	func get_stream_view_rect_for_y(render_y: int) -> Rect2:
		return camera_controller.get_stream_view_rect(float(render_y))

	func _set_render_level_base() -> void:
		if world != null:
			world.set_top_render_y(world.top_render_y)

	func _set_world_draw_enabled(enabled: bool) -> void:
		if world != null:
			world.visible = enabled

	func close_menu() -> void:
		pass


var checks := 0
var failures := 0


func _init() -> void:
	call_deferred("_run")


func _check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures += 1
		push_error(message)


func _run() -> void:
	var main := FixtureMain.new()
	root.add_child(main)
	await process_frame
	for name in Scenarios.VALID_SCENARIOS:
		await _check_scenario(main, str(name))
	main.queue_free()
	await process_frame
	if failures == 0:
		print("Playtest scenarios OK (%d checks)" % checks)
		quit(0)
	else:
		push_error("Playtest scenarios failed (%d/%d checks)" % [failures, checks])
		quit(1)


func _check_scenario(main: FixtureMain, name: String) -> void:
	var scenario = Scenarios.make(name)
	var first: Dictionary = await scenario.prepare(main)
	_check(not first.is_empty(), "%s fixture did not prepare" % name)
	if first.is_empty():
		return
	var world: World = main.world
	var named: Dictionary = first["named_positions"]
	var expected: Dictionary = first["expectations"]
	_check(int(first["seed"]) == scenario.world_seed, "%s seed is not reported" % name)
	_check(first["affected_chunks"].size() <= 4, "%s affected chunk set expanded beyond local patch" % name)
	_check(world.chunks.size() < 160, "%s generated a giant world during setup" % name)
	_check(world.workers.size() == 1 and world.workers[0].worker_id == 1, "%s worker identity/index changed" % name)
	_check(world.workers[0].get_work_priority("building") == 2, "%s worker building priority missing" % name)
	_check(world.workers[0].get_work_priority("mining") == 2, "%s worker mining priority missing" % name)
	_check(world.pathfinder.is_walkable(world, world.workers[0].get_block_coord().x, world.workers[0].get_block_coord().y, world.workers[0].get_block_coord().z), "%s worker start is not walkable" % name)
	_check(world.player_mode == World.PlayerMode.DOWN_STAIRS, "%s did not select stair preview mode" % name)
	_check(world.top_render_y == int(first["camera"]["render_y"]), "%s render level differs from camera fixture" % name)
	if name == Scenarios.STAIR_PREVIEW:
		var anchor := _position(named["lower"])
		_check(world.can_place_stair_flight(anchor, 0, false), "preview fixture is not a valid down flight")
		_check(bool(expected["preview_should_be_valid"]), "preview expectation accidentally invalid")
	else:
		var old_lower := _position(named["lower"])
		var old_upper := _position(named["upper"])
		_check(world.get_block_no_generate(old_lower.x, old_lower.y, old_lower.z) == Flight.lower_id(0), "continuation lower flight identity changed")
		_check(world.get_block_no_generate(old_upper.x, old_upper.y, old_upper.z) == Flight.upper_id(0), "continuation upper flight identity changed")
		var attempt := _position(named["attempt_anchor"])
		_check(not world.can_place_stair_flight(attempt, 0, false), "continuation headroom rejection disappeared")
		var obstruction := _position(named["headroom_obstruction"])
		_check(world.get_block_no_generate(obstruction.x, obstruction.y, obstruction.z) == World.BLOCK_ID_GRASS, "continuation headroom grass fixture changed")

	# Rebuild the same scenario on the same real World and require the recorded
	# terrain/worker fingerprint to remain byte-for-byte stable.
	var second_scenario = Scenarios.make(name)
	var second: Dictionary = await second_scenario.prepare(main)
	_check(JSON.stringify(first["initial_fingerprint"]) == JSON.stringify(second["initial_fingerprint"]), "%s fingerprint is not deterministic" % name)


func _position(value: Variant) -> Vector3i:
	if value is Vector3i:
		return value
	return Vector3i(int(value[0]), int(value[1]), int(value[2]))


const Flight = preload("res://scripts/stair_flight.gd")
