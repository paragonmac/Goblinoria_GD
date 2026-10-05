extends SceneTree
## With the real isometric camera angle, the cell a drag rectangle resolves to
## at the press point must be the block whose top face is under the cursor
## (the same block a click raycast picks). Projecting onto the block's center
## height shifted rectangles about 0.7 tiles away from the camera.

class TestWorld extends World:
	func ensure_chunk_generated(coord: Vector3i) -> ChunkData:
		var chunk := ensure_chunk(coord)
		if chunk != null:
			chunk.generated = true
		return chunk

var checks := 0
var failures := 0


func _init() -> void:
	_run.call_deferred()


func _run() -> void:
	var world := TestWorld.new()
	world.world_size_y = 16
	world._init_ramp_lookup()
	world.block_registry.load_from_csv(World.BLOCK_DATA_PATH)
	world.raycaster = WorldRaycaster.new(world)
	world.top_render_y = 4
	for x in range(-12, 13):
		for z in range(-12, 13):
			world.set_block_raw(x, 3, z, World.BLOCK_ID_GRANITE, true)
	var camera := Camera3D.new()
	root.add_child(camera)
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = 12.0
	camera.rotation = Vector3(deg_to_rad(-35.0), deg_to_rad(45.0), 0.0)
	camera.position = Vector3(0, 3.5, 0) - camera.global_transform.basis.z * -40.0
	var camera_controller := MainCameraController.new()
	camera_controller.initialize(camera, root.get_viewport())
	var selection := MainSelectionController.new()
	selection.initialize(world, camera, root.get_viewport(), camera_controller)
	world.player_mode = World.PlayerMode.DIG
	await process_frame

	var picked_ok := 0
	var rect_ok := 0
	var total := 0
	for x in range(-2, 3):
		for z in range(-2, 3):
			var cell := Vector3i(x, 3, z)
			var screen := camera.unproject_position(Vector3(x, 3.5, z))
			total += 1
			var hit: Dictionary = selection._raycast_block_from_screen_pos(screen)
			if hit.get("hit", false) and hit.pos == cell:
				picked_ok += 1
			selection.drag_plane_y = selection._get_drag_plane_y(screen)
			selection.drag_projection_y = selection._get_drag_projection_y(screen)
			var rect: Dictionary = selection._get_drag_rect(screen, screen, selection.drag_plane_y)
			if not rect.is_empty() and int(round(rect.min_x)) == x and int(round(rect.min_z)) == z \
					and int(rect.y) == 3:
				rect_ok += 1
	_check(picked_ok == total, "Click raycast picks the block under the cursor (%d/%d)" % [picked_ok, total])
	_check(rect_ok == total, "Drag rectangle starts on the block under the cursor (%d/%d)" % [rect_ok, total])

	camera.queue_free()
	world.free()
	print("Drag projection: %d checks, %d failures" % [checks, failures])
	quit(1 if failures else 0)


func _check(value: bool, message: String) -> void:
	checks += 1
	if not value:
		failures += 1
		push_error(message)
