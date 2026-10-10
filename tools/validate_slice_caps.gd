extends SceneTree
## Slice caps (SEE-ADR-020): the hatched cut floor exists only at the render
## level. Real generated world, headless; no pixels are inspected.

const LoaderScript = preload("res://scripts/world_mesh_cache_save_load.gd")

var checks := 0
var failures := 0


func _init() -> void:
	var world := World.new()
	root.add_child(world)
	_run.call_deferred(world)


func _check(ok: bool, message: String) -> void:
	checks += 1
	if not ok:
		failures += 1
		push_error(message)


func _run(world: World) -> void:
	await process_frame
	world.start_new_world(1107091669)
	var renderer = world.renderer
	renderer.use_async_meshing = false
	renderer.set_render_debug("visibility_mode", "sync")
	for cx in range(-4, 4):
		for cz in range(-4, 4):
			for cy in range(0, 29):
				world.ensure_chunk_generated(Vector3i(cx, cy, cz))
	# Deep enough that the slice layer is solid ground (buried chunks).
	var level := world.sea_level - 60
	var slice_cy := floori(float(level) / World.CHUNK_SIZE)
	renderer.update_render_zone(-2, 1, -2, 1, 0, 28)
	world.set_top_render_y(level)

	# Caps: only the render zone's slice-layer columns, exactly at the level.
	var in_zone := true
	var level_ok := true
	for coord: Vector3i in renderer._slice_cap_coords:
		in_zone = in_zone and coord.y == slice_cy and coord.x >= -2 and coord.x <= 1 and coord.z >= -2 and coord.z <= 1
		var cap: MeshInstance3D = renderer.chunk_cache.get_chunk(coord).get_node_or_null(renderer.SLICE_CAP_NODE)
		for uv2: Vector2 in cap.mesh.surface_get_arrays(0)[Mesh.ARRAY_TEX_UV2]:
			level_ok = level_ok and is_equal_approx(uv2.x, float(level))
	_check(renderer._slice_cap_coords.size() == 16, "Underground level caps every column of the render zone")
	_check(in_zone, "Caps exist only in the zone's slice-layer columns")
	_check(level_ok, "Cap faces sit exactly at the render level")
	print("Slice cap rebuild for one level: %.1f ms, %d caps" % [renderer.slice_cap_build_usec / 1000.0, renderer._slice_cap_coords.size()])

	# Moving the zone fills in caps for columns that enter it.
	renderer.update_render_zone(0, 3, -2, 1, 0, 28)
	_check(renderer.has_slice_cap(Vector3i(3, slice_cy, 0)), "Columns entering the zone get caps")

	# A buried chunk (no chunk-mesh geometry) is shown through its cap alone,
	# through the normal eligibility path.
	var buried := Vector3i(0, slice_cy, 0)
	renderer.queue_chunk_mesh_build(buried, -1, false, false, true)
	var node: MeshInstance3D = renderer.chunk_cache.get_chunk(buried)
	_check(node.mesh == null or node.mesh.get_surface_count() == 0, "Fixture chunk is fully buried (no chunk-mesh geometry)")
	renderer.update_render_zone(-2, 1, -2, 1, 0, 28)
	_check(renderer.has_slice_cap(buried) and node.visible, "A cap-only chunk in the zone is visible")

	# Digging at the level through the world API rebuilds the cap.
	var before := _cap_quads(renderer, buried)
	var wx := buried.x * World.CHUNK_SIZE + 3
	var wz := buried.z * World.CHUNK_SIZE + 3
	world.set_block(wx, level, wz, World.BLOCK_ID_AIR)
	for i in range(3):
		await process_frame
		renderer.process_mesh_results(64)
	_check(before == 1 and _cap_quads(renderer, buried) > 1, "Digging at the level splits the cap around the hole")
	# The covering block for the chunk's top layer lives in the chunk above.
	world.set_top_render_y(slice_cy * World.CHUNK_SIZE + World.CHUNK_SIZE - 1)
	var top_before := _cap_quads(renderer, buried)
	world.set_block(wx + 1, slice_cy * World.CHUNK_SIZE + World.CHUNK_SIZE, wz, World.BLOCK_ID_AIR)
	for i in range(3):
		await process_frame
		renderer.process_mesh_results(64)
	_check(top_before > 0 and _cap_quads(renderer, buried) != top_before, "Removing a covering block in the chunk above updates the cap")

	# Changing level removes every cap of the old layer.
	world.set_top_render_y(level)
	var old_caps: Array = renderer._slice_cap_coords.keys()
	world.set_top_render_y(level - World.CHUNK_SIZE)
	var moved := true
	for coord: Vector3i in old_caps:
		var old_node: MeshInstance3D = renderer.chunk_cache.get_chunk(coord)
		moved = moved and (old_node == null or old_node.get_node_or_null(renderer.SLICE_CAP_NODE) == null)
	_check(moved and not renderer._slice_cap_coords.is_empty(), "Changing level replaces the caps")

	# Saving a never-imported legacy (v9) entry strips its baked cut faces.
	world.set_top_render_y(level)
	var loader = LoaderScript.new()
	var coord := Vector3i(1, slice_cy - 1, 1)
	renderer.queue_chunk_mesh_build(coord, -1, false, false, true)
	var chunk: ChunkData = world.get_chunk(coord)
	var current: Dictionary = loader._persistent_mesh_cache_entry_for_coord(world, {}, coord, chunk.blocks)
	var cut: Dictionary = renderer.mesher.build_cap_arrays(chunk.blocks, chunk.blocks, World.CHUNK_SIZE, coord.x, coord.y, coord.z, 3,
		World.BLOCK_ID_AIR, renderer.block_solid_table, renderer.block_ramp_table, renderer.block_color_table)
	var legacy: Dictionary = current.duplicate()
	for key in ["vertices", "normals", "colors", "uv", "uv2"]:
		var merged = current[key].duplicate()
		merged.append_array(cut[key])
		legacy[key] = merged
	renderer.mesh_cache_store.erase(coord)
	loader.pending_mesh_cache_entries[coord] = legacy
	loader._legacy_cut_faces = true
	var saved: Dictionary = loader._persistent_mesh_cache_entry_for_coord(world, {}, coord, chunk.blocks)
	_check(not PackedVector3Array(cut.vertices).is_empty() and PackedVector3Array(saved.get("vertices", PackedVector3Array())).size()
		== PackedVector3Array(current.vertices).size(), "Saving a legacy pending entry writes it without cut faces")

	# Pooled chunk nodes never carry a cap into another chunk.
	var recycled: MeshInstance3D = renderer.chunk_cache.get_chunk(buried)
	renderer.chunk_cache.remove_chunk(buried)
	_check(recycled.get_node_or_null(renderer.SLICE_CAP_NODE) == null, "A pooled chunk node drops its cap")

	# Clearing chunks forgets caps; above all terrain there is nothing to cap.
	renderer.clear_chunks()
	_check(renderer._slice_cap_coords.is_empty(), "clear_chunks forgets caps")
	world.set_top_render_y(world.world_size_y - 1)
	_check(renderer._slice_cap_coords.is_empty(), "No caps when the level is above all terrain")

	print("Slice caps: %d checks, %d failures" % [checks, failures])
	world.task_manager.shutdown()
	quit(1 if failures > 0 else 0)


func _cap_quads(renderer, coord: Vector3i) -> int:
	var node: MeshInstance3D = renderer.chunk_cache.get_chunk(coord)
	if node == null:
		return 0
	var cap: MeshInstance3D = node.get_node_or_null(renderer.SLICE_CAP_NODE)
	if cap == null or cap.mesh == null:
		return 0
	return cap.mesh.surface_get_array_len(0) / 6
