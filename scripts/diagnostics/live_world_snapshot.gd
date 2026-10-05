extends RefCounted
## Queries use existing records only, never ensure/get-or-create/cache application.
const Data = preload("res://scripts/diagnostics/live_diagnostics_service.gd")
const Decisions = preload("res://scripts/diagnostics/live_decision_snapshot.gd")
var main
var service

func query(operation: String, args: Dictionary) -> Dictionary:
	if operation == "status":
		return metadata()
	if main.loading_active or not main.world_started:
		return {"error": "world_unavailable", "loading": main.loading_active}
	var world: World = main.world
	match operation:
		"inspect_cell", "inspect_chunk", "inspect_stockpile":
			if not valid_coord(args.get("pos")):
				return {"error": "integer_pos_required"}
			var p: Array = args.pos
			var pos := Vector3i(int(p[0]), int(p[1]), int(p[2]))
			if operation == "inspect_chunk":
				return chunk(pos)
			if not world.is_block_coord_valid(pos.x, pos.y, pos.z):
				return {"error": "out_of_bounds"}
			return cell(pos) if operation == "inspect_cell" else Data.plain(Decisions.stockpile_snapshot(world.stockpile_store, pos))
		"inspect_screen":
			if args.get("view_id") != view_id():
				return {"error": "stale_view", "view_id": view_id()}
			var p = args.get("point")
			if not p is Array or p.size() != 2 or not _number(p[0]) or not _number(p[1]):
				return {"error": "point_required"}
			var point := Vector2(p[0], p[1])
			if not main.get_viewport().get_visible_rect().has_point(point):
				return {"error": "outside_viewport"}
			var hit := screen_hit(point)
			return {"hit": Data.plain(hit), "cell": cell(hit.pos) if hit.get("hit", false) else null}
		"list_tasks", "list_workers":
			return _list(operation, args)
		"inspect_task", "inspect_worker", "inspect_item":
			if not _number(args.get("id")) or abs(float(args.id)) > 9007199254740991 or float(args.id) != floor(float(args.id)):
				return {"error": "integer_id_required"}
			var id := int(args.id)
			if operation == "inspect_task":
				var task = world.task_queue.get_task(id)
				return {"error": "target_missing"} if task == null else _task(task)
			if operation == "inspect_item":
				var item: Dictionary = world.item_store.items.get(id, {})
				return {"error": "target_missing"} if item.is_empty() else {"state": Data.plain(Decisions.item_snapshot(item)), "decision": service.explain("item", id), "destination_decision": service.explain("item_destination", id)}
			# Worker IDs are indexed by World, not a diagnostic scan.
			var worker = world.diagnostics_workers_by_id.get(id)
			return {"error": "target_missing"} if not is_instance_valid(worker) else _worker(worker)
	return {"error": "unknown_operation"}

func metadata() -> Dictionary:
	var world: World = main.world
	var camera: Camera3D = main.camera
	return {"enabled": service.enabled, "history_started_usec": service.history_started_usec,
		"loading": main.loading_active, "menu": main.menu_open, "world_started": main.world_started,
		"focused": main.diagnostics_controller._focused,
		"segment": main.diagnostics_controller.current_segment(),
		"engine": Engine.get_version_info(), "build": "debug" if OS.is_debug_build() else "release",
		"revision": ProjectSettings.get_setting("application/config/build_revision", "unknown"),
		"os": OS.get_name(), "cpu": OS.get_processor_name(), "display_driver": DisplayServer.get_name(),
		"renderer": ProjectSettings.get_setting("rendering/renderer/rendering_method", "unknown"),
		"gpu": RenderingServer.get_video_adapter_name() if DisplayServer.get_name() != "headless" else null,
		"viewport": Data.plain(main.get_viewport().get_visible_rect().size), "max_fps": Engine.max_fps,
		"vsync": DisplayServer.window_get_vsync_mode() if DisplayServer.get_name() != "headless" else null,
		"view_id": view_id(), "seed": world.world_seed,
		"render_level": world.top_render_y, "hud_render_level": world.top_render_y - main.hud_controller.render_level_base_y,
		"camera": {"position": Data.plain(camera.position), "rotation": Data.plain(camera.rotation), "size": camera.size},
		"performance": Data.plain(world.get_performance_snapshot()) if not main.loading_active else {"unavailable": "loading"},
		"visibility": Data.plain(world.renderer.get_visibility_snapshot()) if world.renderer != null else {"unavailable": "renderer_missing"},
		"diagnostics": main.performance_controller._diagnostics() if main.performance_controller != null else {},
		"performance_recording": main.performance_controller.recorder.output_path if main.performance_controller != null and main.performance_controller.recorder.enabled else null,
		"live_diagnostics_overhead": {"capture_collection_usec_total": main.diagnostics_controller.collection_usec,
			"service_usec_total": main.diagnostics_controller.service_usec, "capture_write_usec": main.diagnostics_controller.writer.status.get("write_usec")}}

func view_id() -> String:
	# Exact view fingerprint; no scene mutation or expensive geometry query.
	return str([main.camera.global_transform, main.camera.size, main.camera.projection,
		main.get_viewport().get_visible_rect(), main.world.top_render_y]).sha256_text()

func screen_hit(point: Vector2) -> Dictionary:
	return main.world.raycast_block(main.camera.project_ray_origin(point), main.camera.project_ray_normal(point), 2048.0, false)

func cell(pos: Vector3i) -> Dictionary:
	var world: World = main.world
	if not world.is_block_coord_valid(pos.x, pos.y, pos.z):
		return {"error": "out_of_bounds"}
	var coord := world.world_to_chunk_coords(pos.x, pos.y, pos.z)
	var loaded := world.get_chunk(coord)
	var result := {"pos": Data.plain(pos), "chunk": Data.plain(coord), "loaded": loaded != null,
		"generated": loaded != null and loaded.generated}
	if loaded == null or not loaded.generated:
		result["block"] = null
		return result
	var local := world.chunk_to_local_coords(pos.x, pos.y, pos.z)
	var block := int(loaded.blocks[world.chunk_index(local.x, local.y, local.z)])
	var visibility_y := pos.y - 1 if block in World.PLAYER_STAIR_BLOCK_IDS else pos.y
	result["block"] = {"id": block, "name": world.get_block_name(block)}
	result["mesh_revision"] = loaded.mesh_revision
	result["slice"] = {"visibility_y": visibility_y, "upper_eligible": visibility_y <= world.top_render_y,
		"lower_eligible": visibility_y >= world.get_min_render_y(), "actual_pixels": "not_measured",
		"covered_sides": "eligible", "synthetic_internal_tops": "cut_surface_only"}
	return result

func chunk(coord: Vector3i, include_blocks := false) -> Dictionary:
	var world: World = main.world
	if not world.is_chunk_coord_valid(coord):
		return {"error": "out_of_bounds", "coord": Data.plain(coord)}
	var entry := world.get_chunk(coord)
	var result := {"coord": Data.plain(coord), "loaded": entry != null, "generated": entry != null and entry.generated}
	if entry != null:
		result.merge({"dirty": entry.dirty, "mesh_state": entry.mesh_state, "mesh_revision": entry.mesh_revision})
		if include_blocks and entry.generated:
			result["blocks_xyz_index_order"] = Array(entry.blocks)
	var renderer: WorldRenderer = world.renderer
	if renderer == null:
		result["rendering"] = {"unavailable": "no_renderer"}
		return result
	var node: MeshInstance3D = renderer.chunk_cache.get_chunk(coord)
	var cached: Dictionary = renderer.mesh_cache_store.chunk_mesh_cache.get(coord, {})
	var cache_entries: Array = []
	for top in cached:
		var cache: Dictionary = cached[top]
		cache_entries.append({"local_top": top, "revision": cache.get("revision"), "has_geometry": cache.get("has_geometry"),
			"vertices": cache.get("vertices", PackedVector3Array()).size()})
	var bounds: Dictionary = renderer.diagnostics_render_bounds
	var visibility: Dictionary = renderer.get_visibility_snapshot()
	var inside: bool = not bounds.is_empty() and coord.x >= bounds.min_x and coord.x <= bounds.max_x and coord.y >= bounds.min_y and coord.y <= bounds.max_y and coord.z >= bounds.min_z and coord.z <= bounds.max_z
	var material = renderer.material_helper.block_material
	result["rendering"] = {"node_exists": node != null, "node_visible": node.visible if node != null else null,
		"visible_in_tree": node.is_visible_in_tree() if node != null else null,
		"has_mesh": node != null and node.mesh != null, "cache_entries": cache_entries,
		"visible_job_revision": renderer.mesh_scheduler.mesh_job_set.get(coord),
		"job_detail": "queued_or_in_flight_until_handoff", "queues": Data.plain(renderer.get_performance_snapshot()),
		"missing_neighbors": Data.plain(renderer.chunk_missing_neighbors.get(coord, {})),
		"last_render_bounds": bounds.duplicate(true), "inside_last_bounds": inside if not bounds.is_empty() else null,
		"last_frustum_accepted": renderer.render_zone_visible.has(coord) if inside and not visibility.mixed_view else null,
		"zone_empty_fallback": not renderer.is_render_zone_initialized(),
		"visibility_state": Data.plain(visibility),
		"effective_eligible": renderer.render_zone_visible.has(coord) if renderer.is_render_zone_initialized() else null,
		"applied_mesh_revision": node.get_meta("diagnostics_mesh_revision") if node != null and node.mesh != null and node.has_meta("diagnostics_mesh_revision") else null,
		"shader_top": material.get_shader_parameter("top_render_y") if material is ShaderMaterial else null,
		"shader_min": material.get_shader_parameter("min_render_y") if material is ShaderMaterial else null,
		"actual_pixels": "not_measured", "last_mesh_decision": service.explain("chunk", coord)}
	return result

func capture_snapshot() -> Dictionary:
	var result: Dictionary = service.stamp()
	result["metadata"] = metadata()
	if main.loading_active or not main.world_started:
		result["world_data"] = {"unavailable": "world_reconstruction_or_not_started"}
		return result
	var hit := screen_hit(main.input_state.mouse_position(main.get_viewport()))
	var focus: Vector3i = hit.pos if hit.get("hit", false) else Vector3i(main.get_stream_target().round())
	result["focus"] = {"source": "cursor_hit" if hit.get("hit", false) else "camera_active_plane", "cell": cell(focus)}
	var coord: Vector3i = main.world.world_to_chunk_coords(focus.x, focus.y, focus.z)
	var chunks: Array = []
	for offset in [Vector3i.ZERO, Vector3i.LEFT, Vector3i.RIGHT, Vector3i.UP, Vector3i.DOWN, Vector3i.FORWARD, Vector3i.BACK]:
		chunks.append(chunk(coord + offset, true))
	result["chunks"] = chunks
	# Capture-only bounded search; never a per-frame or full-world scan.
	var nearby_workers: Array = []
	var nearby_tasks: Array = []
	var scanned_workers := 0
	var scanned_tasks := 0
	var referenced: Dictionary = {}
	for worker in main.world.workers:
		if scanned_workers >= 512 or nearby_workers.size() >= 32:
			break
		scanned_workers += 1
		if worker.position.distance_squared_to(Vector3(focus)) <= 32.0 * 32.0:
			nearby_workers.append(_worker(worker))
			if worker.current_task_id >= 0:
				referenced[worker.current_task_id] = true
	for task in main.world.task_queue.tasks:
		if scanned_tasks >= 512 or nearby_tasks.size() >= 32:
			break
		scanned_tasks += 1
		if Vector3(task.pos).distance_squared_to(Vector3(focus)) <= 32.0 * 32.0:
			nearby_tasks.append(_task(task))
	var related: Array = []
	for id in referenced:
		var task = main.world.task_queue.get_task(id)
		if task != null:
			related.append(_task(task))
	result["workers"] = nearby_workers
	result["tasks"] = nearby_tasks
	result["referenced_tasks"] = related
	result["entity_selection"] = {"radius_blocks": 32, "max_subjects_per_kind": 32, "max_scanned_per_kind": 512,
		"workers_truncated": scanned_workers < main.world.workers.size(), "tasks_truncated": scanned_tasks < main.world.task_queue.tasks.size()}
	return result

func _list(operation: String, args: Dictionary) -> Dictionary:
	var world: World = main.world
	var tasks := operation == "list_tasks"
	var revision: int = world.task_queue.diagnostics_membership_revision if tasks else world.diagnostics_workers_revision
	var offset := 0
	if args.has("cursor"):
		var cursor = args.cursor
		if not cursor is Dictionary or cursor.get("revision") != revision or cursor.get("world_epoch") != service.world_epoch or cursor.get("kind") != operation:
			return {"error": "stale_cursor"}
		if not _number(cursor.get("offset")) or float(cursor.offset) < 0 or float(cursor.offset) > 10000000 or float(cursor.offset) != floor(float(cursor.offset)):
			return {"error": "invalid_cursor"}
		offset = maxi(0, int(cursor.offset))
	var limit := int(clampf(float(args.get("limit", 32)), 1, 128)) if _number(args.get("limit", 32)) else 32
	var collection: Array = world.task_queue.tasks if tasks else world.workers
	var rows: Array = []
	var bytes := 0
	for i in range(offset, mini(offset + limit, collection.size())):
		var row := _task(collection[i]) if tasks else _worker(collection[i])
		bytes += JSON.stringify(row).to_utf8_buffer().size()
		if bytes > 192 * 1024:
			break
		rows.append(row)
	var next_offset := offset + rows.size()
	return {"rows": rows, "total": collection.size(), "truncated": next_offset < collection.size(),
		"cursor": {"offset": next_offset, "revision": revision, "world_epoch": service.world_epoch, "kind": operation} if next_offset < collection.size() else null}

func _worker(worker) -> Dictionary:
	return {"state": Data.plain(Decisions.worker_snapshot(worker)), "decision": service.explain("worker", worker.worker_id)}

func _task(task) -> Dictionary:
	var result := {"state": Data.plain(Decisions.task_snapshot(task)), "decision": service.explain("task", task.id)}
	var item_id := int(task.data.get("item_id", -1))
	if item_id >= 0:
		result["item"] = Data.plain(Decisions.item_snapshot(main.world.item_store.items.get(item_id, {})))
		result["destination_decision"] = service.explain("item_destination", item_id)
		var destination = task.data.get("destination")
		if destination is Vector3i:
			result["stockpile"] = Data.plain(Decisions.stockpile_snapshot(main.world.stockpile_store, destination))
	return result

static func valid_coord(value: Variant) -> bool:
	if not value is Array or value.size() != 3:
		return false
	for part in value:
		if not _number(part) or abs(float(part)) > 1048576 or float(part) != floor(float(part)):
			return false
	return true

static func _number(value: Variant) -> bool:
	return (value is int or value is float) and is_finite(float(value))
