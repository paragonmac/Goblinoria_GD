extends SceneTree
## Headless contract for the down-stair excavation preview cutout.

const Flight = preload("res://scripts/stair_flight.gd")
const ExcavationMesh = preload("res://scripts/rendering/stair_excavation_mesh.gd")

var failures := 0
var checks := 0
var world: World
var renderer: WorldRenderer
var overlay: OverlayRenderer
var signal_cells: Array = []


func _init() -> void:
	_run.call_deferred()


func _check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures += 1
		push_error(message)


func _run() -> void:
	_setup()
	_test_excavation_lining_mesh()
	_test_valid_preview_signal_and_bounds()
	_test_move_replaces_old_footprint()
	_test_invalid_and_up_modes_clear_cutout_but_keep_ghost_state()
	_test_clear_and_slice_reset()
	_test_debug_shader_toggles_preserve_mask()
	_test_queued_flight_keeps_xray_without_cutout()
	_test_preview_does_not_mutate_world()
	_cleanup()
	if failures > 0:
		push_error("Stair excavation preview failed: %d/%d checks" % [failures, checks])
		quit(1)
		return
	print("Stair excavation preview OK (%d checks)" % checks)
	quit(0)


func _setup() -> void:
	world = World.new()
	world.sea_level = 0
	world.top_render_y = 3
	world._init_ramp_lookup()
	world.block_registry.load_from_csv(World.BLOCK_DATA_PATH)
	renderer = WorldRenderer.new()
	renderer.use_async_meshing = false
	world.add_child(renderer)
	world.renderer = renderer
	renderer.initialize(world)
	overlay = renderer.overlay_renderer
	overlay.excavation_preview_changed.connect(_on_excavation_preview_changed)


func _on_excavation_preview_changed(cells: Array) -> void:
	signal_cells = cells.duplicate()


func _material() -> ShaderMaterial:
	return renderer.material_helper.get_block_material() as ShaderMaterial


func _entries(cells: Array[Vector3i], rotation: int, valid: bool = true) -> Array:
	var result: Array = []
	for index in cells.size():
		result.append({
			"pos": cells[index],
			"valid": valid,
			"stair_material": Flight.lower_id(rotation) if index == 0 else Flight.upper_id(rotation),
		})
	return result


func _test_excavation_lining_mesh() -> void:
	var cells: Array[Vector3i] = [Vector3i(3, 2, 3), Vector3i(4, 2, 3)]
	var touched: Array[Vector3i] = []
	for cell: Vector3i in cells:
		for direction: Vector3i in [Vector3i.LEFT, Vector3i.RIGHT, Vector3i.FORWARD, Vector3i.BACK, Vector3i.DOWN, Vector3i.UP]:
			var neighbor := cell + direction
			if not touched.has(neighbor):
				touched.append(neighbor)
	for cell: Vector3i in touched:
		world.set_block_raw(cell.x, cell.y, cell.z, World.BLOCK_ID_GRANITE, true)
	var before_chunks := world.chunks.size()
	var before_blocks: Dictionary = {}
	for cell: Vector3i in touched:
		before_blocks[cell] = world.get_block_no_generate(cell.x, cell.y, cell.z)
	var mesh := ExcavationMesh.build(world, cells)
	_check(mesh.get_surface_count() == 1, "lining mesh did not create one surface")
	var arrays: Array = mesh.surface_get_arrays(0) if mesh.get_surface_count() > 0 else []
	var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX] if not arrays.is_empty() else PackedVector3Array()
	var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL] if not arrays.is_empty() else PackedVector3Array()
	_check(vertices.size() == 60, "solid two-cell lining emitted %d vertices instead of 60" % vertices.size())
	_check(normals.size() == vertices.size(), "lining normals do not match vertices")
	var join_x := 3.5
	var join_triangles := 0
	for index in range(0, vertices.size(), 3):
		if index + 2 >= normals.size():
			break
		var normal := (normals[index] + normals[index + 1] + normals[index + 2]) / 3.0
		var center := (vertices[index] + vertices[index + 1] + vertices[index + 2]) / 3.0
		if absf(normal.x) > 0.9 and is_equal_approx(center.x, join_x):
			join_triangles += 1
	_check(join_triangles == 0, "lining mesh emitted %d internal join triangles" % join_triangles)
	_check(is_equal_approx(mesh.get_aabb().size.x, 2.0), "lining mesh footprint width changed")
	_check(is_equal_approx(mesh.get_aabb().size.y, 1.0) and is_equal_approx(mesh.get_aabb().size.z, 1.0), "lining mesh bounds changed")
	_check(world.chunks.size() == before_chunks, "lining mesh generated a missing chunk")
	for cell: Vector3i in touched:
		_check(world.get_block_no_generate(cell.x, cell.y, cell.z) == before_blocks[cell], "lining mesh mutated terrain")


func _assert_cutout(cells: Array[Vector3i], label: String) -> void:
	var material := _material()
	var min_cell := cells[0]
	var max_cell := cells[0]
	for cell: Vector3i in cells:
		min_cell = Vector3i(
			mini(min_cell.x, cell.x), mini(min_cell.y, cell.y), mini(min_cell.z, cell.z)
		)
		max_cell = Vector3i(
			maxi(max_cell.x, cell.x), maxi(max_cell.y, cell.y), maxi(max_cell.z, cell.z)
		)
	_check(bool(material.get_shader_parameter("excavation_preview_enabled")), label + ": cutout is disabled")
	_check(renderer.material_helper.excavation_preview_cells == cells, label + ": helper footprint differs")
	var min_bound: Vector3 = material.get_shader_parameter("excavation_preview_min")
	var max_bound: Vector3 = material.get_shader_parameter("excavation_preview_max")
	_check(min_bound.is_equal_approx(Vector3(min_cell) - Vector3.ONE * 0.5), label + ": min bound differs")
	_check(max_bound.is_equal_approx(Vector3(max_cell) + Vector3.ONE * 0.5), label + ": max bound differs")


func _assert_cutout_cleared(label: String) -> void:
	var material := _material()
	_check(not bool(material.get_shader_parameter("excavation_preview_enabled")), label + ": cutout remains enabled")
	_check(renderer.material_helper.excavation_preview_cells.is_empty(), label + ": helper footprint remains")
	if renderer.excavation_preview_lining != null:
		_check(not renderer.excavation_preview_lining.visible and renderer.excavation_preview_lining.mesh == null, label + ": cavity lining remains")


func _test_valid_preview_signal_and_bounds() -> void:
	for rotation in Flight.ROTATION_COUNT:
		var anchor := Vector3i(-1 + rotation * 3, 2, World.CHUNK_SIZE - 2)
		var cells := Flight.cells(anchor, rotation)
		signal_cells.clear()
		overlay.set_drag_preview_entries(_entries(cells, rotation), World.PlayerMode.DOWN_STAIRS)
		_check(signal_cells == cells, "rotation %d valid preview signal lost footprint" % rotation)
		_assert_cutout(cells, "rotation %d valid preview" % rotation)
		var material := overlay.drag_previews.values()[0].material_override as ShaderMaterial
		_check(not material.shader.get_code().contains("depth_test_disabled"), "rotation %d valid down ghost still uses x-ray depth" % rotation)
		_check(overlay.drag_previews.size() == 2, "rotation %d valid preview lost a stair half" % rotation)


func _test_move_replaces_old_footprint() -> void:
	var cells: Array[Vector3i] = [Vector3i(World.CHUNK_SIZE - 1, 2, -1), Vector3i(World.CHUNK_SIZE, 2, -1)]
	signal_cells.clear()
	overlay.set_drag_preview_entries(_entries(cells, 1), World.PlayerMode.DOWN_STAIRS)
	_check(signal_cells == cells, "moved preview signal did not replace footprint")
	_assert_cutout(cells, "moved preview")
	_check(not renderer.material_helper.excavation_preview_cells.has(Vector3i(-1, 2, World.CHUNK_SIZE - 1)), "moved preview retained old cell")


func _test_invalid_and_up_modes_clear_cutout_but_keep_ghost_state() -> void:
	var cells: Array[Vector3i] = [Vector3i(1, 2, 1), Vector3i(2, 2, 1)]
	signal_cells.clear()
	overlay.set_drag_preview_entries(_entries(cells, 0, false), World.PlayerMode.DOWN_STAIRS)
	_check(signal_cells.is_empty(), "invalid down preview signaled a terrain cutout")
	_assert_cutout_cleared("invalid down preview")
	var invalid_material := overlay.drag_previews.values()[0].material_override as ShaderMaterial
	_check(invalid_material.shader.get_code().contains("depth_test_disabled"), "invalid down ghost lost x-ray depth")
	overlay.set_drag_preview_entries(_entries(cells, 0), World.PlayerMode.DOWN_STAIRS)
	overlay.set_drag_preview_entries(_entries(cells, 0), World.PlayerMode.UP_STAIRS)
	_check(signal_cells.is_empty(), "up preview signaled a terrain cutout")
	_assert_cutout_cleared("up preview")
	_check(not (overlay.drag_previews.values()[0].material_override as ShaderMaterial).shader.get_code().contains("depth_test_disabled"), "up ghost unexpectedly uses x-ray depth")


func _test_clear_and_slice_reset() -> void:
	var cells: Array[Vector3i] = [Vector3i(3, 2, 3), Vector3i(4, 2, 3)]
	overlay.set_drag_preview_entries(_entries(cells, 1), World.PlayerMode.DOWN_STAIRS)
	signal_cells.clear()
	world.set_top_render_y(1)
	_check(signal_cells.is_empty(), "render-slice change did not clear preview signal")
	_assert_cutout_cleared("render-slice change")
	world.set_top_render_y(3)
	overlay.set_drag_preview_entries(_entries(cells, 1), World.PlayerMode.DOWN_STAIRS)
	_assert_cutout(cells, "restored slice before explicit clear")
	signal_cells.clear()
	overlay.clear_drag_preview()
	_check(signal_cells.is_empty(), "explicit clear did not clear preview signal")
	_assert_cutout_cleared("explicit clear")
	_check(overlay.drag_previews.is_empty(), "explicit clear retained ghost nodes")
	world.set_top_render_y(3)
	renderer.set_drag_preview_entries(_entries(cells, 1), World.PlayerMode.DOWN_STAIRS)
	renderer.clear_chunks()
	_assert_cutout_cleared("world renderer reset")


func _test_debug_shader_toggles_preserve_mask() -> void:
	var cells: Array[Vector3i] = [Vector3i(3, 2, 3), Vector3i(4, 2, 3)]
	overlay.set_drag_preview_entries(_entries(cells, 1), World.PlayerMode.DOWN_STAIRS)
	renderer.set_poly_debug_enabled(true)
	_assert_cutout(cells, "poly debug toggle")
	var wire: ShaderMaterial = renderer.material_helper.poly_wire_material
	_check(wire != null and bool(wire.get_shader_parameter("excavation_preview_enabled")), "wire pass lost cutout")
	renderer.toggle_debug_normals()
	_assert_cutout(cells, "normal debug toggle")
	renderer.toggle_debug_normals()
	renderer.set_poly_debug_enabled(false)
	overlay.clear_drag_preview()
	_assert_cutout_cleared("debug toggle clear")
	_check(not bool(wire.get_shader_parameter("excavation_preview_enabled")), "inactive wire pass retained cutout")


func _test_queued_flight_keeps_xray_without_cutout() -> void:
	var anchor := Vector3i(5, 2, 5)
	var cells := Flight.cells(anchor, 0)
	var task := TaskQueue.Task.new(77, anchor, TaskQueue.TaskType.STAIRS, Flight.lower_id(0))
	task.data = {"flight": true, "up": false, "rotation": 0, "footprint": cells}
	overlay.update_task_overlays([task])
	_assert_cutout_cleared("queued flight")
	var task_material := overlay.task_overlays[task.id].material_override as ShaderMaterial
	_check(task_material.shader.get_code().contains("depth_test_disabled"), "queued down designation lost x-ray depth")
	overlay.clear_task_overlays()


func _test_preview_does_not_mutate_world() -> void:
	var cells: Array[Vector3i] = [Vector3i(-2, 2, 2), Vector3i(-1, 2, 2)]
	for cell: Vector3i in cells:
		world.set_block_raw(cell.x, cell.y, cell.z, World.BLOCK_ID_GRANITE, true)
	var before: Array[int] = []
	for cell: Vector3i in cells:
		before.append(world.get_block_no_generate(cell.x, cell.y, cell.z))
	overlay.set_drag_preview_entries(_entries(cells, 1), World.PlayerMode.DOWN_STAIRS)
	var after: Array[int] = []
	for cell: Vector3i in cells:
		after.append(world.get_block_no_generate(cell.x, cell.y, cell.z))
	_check(before == after, "preview changed world block data")


func _cleanup() -> void:
	if renderer != null and is_instance_valid(renderer):
		renderer._stop_mesh_worker()
	if world != null and is_instance_valid(world):
		world.free()
