extends Node3D
class_name WorldRenderer
## Main renderer for voxel world chunks, overlays, and stats tracking.

#region Preloads
const ChunkMesherScript = preload("res://scripts/rendering/chunk_mesher.gd")
const ChunkCacheScript = preload("res://scripts/rendering/chunk_cache.gd")
const WorldRendererMeshSchedulerScript = preload("res://scripts/rendering/world_renderer_mesh_scheduler.gd")
const WorldRendererRenderLevelScript = preload("res://scripts/rendering/world_renderer_render_level.gd")
const WorldRendererMaterialsScript = preload("res://scripts/rendering/world_renderer_materials.gd")
const WorldRendererStatsScript = preload("res://scripts/rendering/world_renderer_stats.gd")
const OverlayRendererScript = preload("res://scripts/rendering/overlay_renderer.gd")
const StairExcavationMeshScript = preload("res://scripts/rendering/stair_excavation_mesh.gd")
const FrustumCullerScript = preload("res://scripts/rendering/frustum_culler.gd")
const ChunkMeshJobBuilderScript = preload("res://scripts/rendering/chunk_mesh_job_builder.gd")
const WorldRendererMeshCacheStoreScript = preload("res://scripts/rendering/world_renderer_mesh_cache_store.gd")
const VisibilityScript = preload("res://scripts/rendering/world_renderer_visibility.gd")
#endregion

#region Constants
const NEAR_SAMPLE_OFFSET := 0.1
const NEAR_SAMPLE_MIN := 0.1
const MESH_BUILD_LOG_THRESHOLD_MS := 5.0
const MESH_APPLY_BUDGET := 8
const MESH_WORK_BUDGET_MS := 40.0
const MESH_RESULT_BACKLOG_MAX := 32
const MESH_RESULT_BACKLOG_SLEEP_USEC := 500
const MESH_CACHE_RADIUS := 0
const MESH_PREFETCH_BELOW_ONLY := true
# 10: covered tops left chunk meshes for per-level slice caps; 9 is migrated.
const MESHER_CACHE_VERSION := 10
const MESHER_CACHE_VERSION_LEGACY_CUT_FACES := 9
const RENDER_FRUSTUM_PADDING_CHUNKS := 1.0
# While panning, visibility also accepts chunks in a copy of the frustum shifted
# by the smoothed pan velocity times this lead (covers request-to-applied lag).
# Directional, so the accepted set grows only toward where the camera is going.
const RENDER_FRUSTUM_MOTION_LEAD_SEC := 0.15
const RENDER_FRUSTUM_MAX_LEAD_DISTANCE := 48.0
# Per-frame visibility application. The 1 ms deadline bounds cost; the step cap
# is high enough that a full view batch (~3.5k mostly no-op scans) lands in
# one or two frames instead of ~14, which showed as void while panning.
const VISIBILITY_PUMP_MS := 1.0
const VISIBILITY_PUMP_STEPS := 2048
#endregion

#region State
var motion_lead_offset := Vector3.ZERO
# Live rendering switches for the F7 Rendering debug panel. Runtime only; every
# restart returns to the defaults. Written through set_render_debug().
const RENDER_DEBUG_OPTIONS := {
	"visibility_mode": ["async", "area", "sync"],
	"depth_layers": [0, 1, 2, 4, 8],
}
const VOID_METER_INTERVAL_USEC := 50000
const VOID_METER_WINDOW_USEC := 2000000
var render_debug := {
	"visibility_mode": "async", # async worker cull | area: whole loaded box, Godot culls | sync: main-thread cull
	"depth_layers": 0, # 0 = all chunk layers; N = top render chunk layer and N-1 below
	"look_ahead": true,
	"look_ahead_sec": RENDER_FRUSTUM_MOTION_LEAD_SEC,
	"refresh_every_frame": true, # while moving; otherwise the 50 ms cadence
	"freeze": false, # stop visibility requests; shown chunks stay as they are
}
var void_meter_enabled := false
var void_meter := {"hidden": 0, "checked": 0, "max_recent": 0, "void_ms": 0.0, "void_pct_recent": 0.0}
var _void_samples: Array = []
var _void_last_usec := 0
var _void_streak_start_usec := 0
var _last_zone_args: Array = []
var _stats_prev := {}
var _stats_rates := {"delta_per_sec": 0.0, "full_per_sec": 0.0, "cull_job_ms": 0.0}
var world: World
var mesher = ChunkMesherScript.new()
var mesher_thread = ChunkMesherScript.new()
var chunk_cache = ChunkCacheScript.new()
var mesh_scheduler = WorldRendererMeshSchedulerScript.new()
var render_level_helper = WorldRendererRenderLevelScript.new()
var material_helper = WorldRendererMaterialsScript.new()
var render_stats = WorldRendererStatsScript.new()
var overlay_renderer = OverlayRendererScript.new()
var excavation_preview_lining: MeshInstance3D
var frustum_culler = FrustumCullerScript.new()
var mesh_job_builder = ChunkMeshJobBuilderScript.new()
var mesh_cache_store = WorldRendererMeshCacheStoreScript.new()
var use_async_meshing: bool = true
var visibility_state = VisibilityScript.new()
var visibility_scheduler = visibility_state.scheduler
var render_zone_visible: Dictionary = visibility_state.eligible.members
var diagnostics_render_bounds: Dictionary = {}
var block_solid_table := PackedByteArray()
var block_color_table := PackedColorArray()
var block_ramp_table := PackedByteArray()
var pending_neighbor_remesh: Dictionary = {}
var chunk_missing_neighbors: Dictionary = {}
var neighbor_remesh_queued_total: int = 0
#endregion


#region Initialization
func initialize(world_ref: World) -> void:
	world = world_ref
	visibility_state.configure(self)
	if chunk_cache.get_parent() == null:
		add_child(chunk_cache)
	if overlay_renderer.get_parent() == null:
		add_child(overlay_renderer)
	overlay_renderer.initialize(world_ref)
	material_helper.initialize(world_ref)
	if not overlay_renderer.excavation_preview_changed.is_connected(_set_excavation_preview):
		overlay_renderer.excavation_preview_changed.connect(_set_excavation_preview)
	_ensure_block_tables()
	mesh_job_builder.configure(world_ref, mesher)
	mesh_scheduler.configure(Callable(self, "_build_mesh_result_on_worker"), MESH_RESULT_BACKLOG_MAX, MESH_RESULT_BACKLOG_SLEEP_USEC)
	render_level_helper.configure(self, chunk_cache, mesh_scheduler)
	_start_mesh_worker()
#endregion


func _exit_tree() -> void:
	_stop_mesh_worker()
	visibility_state.stop()


func _notification(what: int) -> void:
	# Isolated headless fixtures can free a renderer that never entered a tree.
	if what == NOTIFICATION_PREDELETE:
		visibility_state.stop()


#region Reset and Clear
func reset_stats() -> void:
	_clear_all_chunk_render_stats()
	neighbor_remesh_queued_total = 0
	reset_mesh_cache_metrics()
	clear_drag_preview()
	overlay_renderer.clear_task_overlays()

func clear_chunks() -> void:
	clear_drag_preview()
	_slice_cap_coords.clear()
	_slice_cap_checked.clear()
	visibility_state.clear()
	diagnostics_render_bounds = {}
	chunk_cache.clear()
	_clear_all_chunk_render_stats()
	pending_neighbor_remesh.clear()
	chunk_missing_neighbors.clear()
	render_level_helper.clear()
	mesh_cache_store.clear()
	_clear_mesh_jobs()
	overlay_renderer.clear_item_and_stockpile_overlays()
	if world == null:
		return
	for chunk in world.chunks.values():
		var entry: ChunkData = chunk
		entry.mesh_state = ChunkData.MESH_STATE_NONE
#endregion


func clear_chunk(coord: Vector3i) -> void:
	visibility_state.remove_node(coord)
	_cancel_chunk_jobs(coord)
	render_level_helper.remove_coord(coord)
	_clear_chunk_render_stats(coord)
	_clear_neighbor_remesh_dependencies(coord)
	mesh_cache_store.erase(coord)
	if chunk_cache != null:
		chunk_cache.remove_chunk(coord)


func _clear_all_chunk_render_stats() -> void:
	render_stats.clear_all()


func _clear_chunk_render_stats(coord: Vector3i) -> void:
	render_stats.clear_chunk(coord)

func _clear_neighbor_remesh_dependencies(coord: Vector3i) -> void:
	if chunk_missing_neighbors.has(coord):
		var missing_map_value: Variant = chunk_missing_neighbors[coord]
		if typeof(missing_map_value) == TYPE_DICTIONARY:
			var missing_map: Dictionary = missing_map_value
			for neighbor_coord in missing_map.keys():
				if pending_neighbor_remesh.has(neighbor_coord):
					var dependents_value: Variant = pending_neighbor_remesh[neighbor_coord]
					if typeof(dependents_value) == TYPE_DICTIONARY:
						var dependents: Dictionary = dependents_value
						dependents.erase(coord)
						if dependents.is_empty():
							pending_neighbor_remesh.erase(neighbor_coord)
		chunk_missing_neighbors.erase(coord)
	for neighbor_coord in pending_neighbor_remesh.keys():
		var dependents_value: Variant = pending_neighbor_remesh[neighbor_coord]
		if typeof(dependents_value) != TYPE_DICTIONARY:
			continue
		var dependents: Dictionary = dependents_value
		if dependents.has(coord):
			dependents.erase(coord)
			if dependents.is_empty():
				pending_neighbor_remesh.erase(neighbor_coord)


func _update_neighbor_remesh_dependencies(coord: Vector3i, missing_neighbors: Array) -> void:
	_clear_neighbor_remesh_dependencies(coord)
	if missing_neighbors.is_empty():
		return
	var unique_missing: Dictionary = {}
	for neighbor_coord in missing_neighbors:
		if typeof(neighbor_coord) != TYPE_VECTOR3I:
			continue
		if world != null and not world.is_chunk_coord_valid(neighbor_coord):
			continue
		unique_missing[neighbor_coord] = true
	if unique_missing.is_empty():
		return
	chunk_missing_neighbors[coord] = unique_missing
	for neighbor_coord in unique_missing.keys():
		var dependents: Dictionary = {}
		if pending_neighbor_remesh.has(neighbor_coord):
			var dependents_value: Variant = pending_neighbor_remesh[neighbor_coord]
			if typeof(dependents_value) == TYPE_DICTIONARY:
				dependents = dependents_value
		dependents[coord] = true
		pending_neighbor_remesh[neighbor_coord] = dependents


func notify_chunk_loaded(coord: Vector3i) -> void:
	if not pending_neighbor_remesh.has(coord):
		return
	var dependents_value: Variant = pending_neighbor_remesh[coord]
	pending_neighbor_remesh.erase(coord)
	if typeof(dependents_value) != TYPE_DICTIONARY:
		return
	var dependents: Dictionary = dependents_value
	for dependent_coord in dependents.keys():
		if chunk_missing_neighbors.has(dependent_coord):
			var missing_map_value: Variant = chunk_missing_neighbors[dependent_coord]
			if typeof(missing_map_value) == TYPE_DICTIONARY:
				var missing_map: Dictionary = missing_map_value
				missing_map.erase(coord)
				if missing_map.is_empty():
					chunk_missing_neighbors.erase(dependent_coord)
		if world == null or not world.is_chunk_coord_valid(dependent_coord):
			continue
		var chunk: ChunkData = world.get_chunk(dependent_coord)
		if chunk == null or not chunk.generated:
			continue
		chunk.mesh_state = ChunkData.MESH_STATE_NONE
		chunk.mesh_revision += 1
		invalidate_chunk_mesh_cache(dependent_coord)
		queue_chunk_mesh_build(dependent_coord, -1, false, true)
		neighbor_remesh_queued_total += 1


func _count_pending_neighbor_remesh_dependents() -> int:
	var total := 0
	for dependents_value in pending_neighbor_remesh.values():
		if typeof(dependents_value) == TYPE_DICTIONARY:
			var dependents: Dictionary = dependents_value
			total += dependents.size()
	return total


func _missing_neighbors_from_value(value: Variant) -> Array:
	var missing: Array = []
	if typeof(value) != TYPE_ARRAY:
		return missing
	var values: Array = value
	for coord in values:
		if typeof(coord) == TYPE_VECTOR3I:
			missing.append(coord)
	return missing


func _record_chunk_render_stats(coord: Vector3i, visible_faces: int, occluded_faces: int, mesh_metrics: Dictionary) -> void:
	render_stats.record_chunk_render_stats(coord, visible_faces, occluded_faces, mesh_metrics)


func _mesh_metrics_from_result(result: Dictionary, mesh_value: Variant) -> Dictionary:
	return render_stats.mesh_metrics_from_result(result, mesh_value)


func _mesh_metrics_from_entry(entry: Dictionary, mesh_value: Variant) -> Dictionary:
	return render_stats.mesh_metrics_from_entry(entry, mesh_value)

#region Chunk Building
func regenerate_chunk(cx: int, cy: int, cz: int) -> void:
	if world == null:
		return
	var key := Vector3i(cx, cy, cz)
	if not world.is_chunk_coord_valid(key):
		return
	var chunk_size: int = World.CHUNK_SIZE
	var mesh_instance: MeshInstance3D = chunk_cache.ensure_chunk(key, chunk_size)

	var profiler: DebugProfiler = world.debug_profiler
	var build_start := 0
	var log_build_time := profiler != null and profiler.enabled
	var recording := _performance_recording()
	if log_build_time or recording:
		build_start = Time.get_ticks_usec()
	var result: Dictionary = mesher.build_chunk_mesh(world, cx, cy, cz)
	if log_build_time or recording:
		var build_ms := float(Time.get_ticks_usec() - build_start) / 1000.0
		if log_build_time:
			profiler.add_sample("Renderer.build_chunk_mesh", build_ms)
		if recording:
			world.performance_recorder.add_timing("Mesh.sync_build_ms", build_ms)
			world.performance_recorder.add_counter("Mesh.sync_built")
		if log_build_time and build_ms >= MESH_BUILD_LOG_THRESHOLD_MS:
			print("Chunk mesh build %d,%d,%d: %.2f ms" % [cx, cy, cz, build_ms])
	var apply_start_usec := Time.get_ticks_usec() if recording else 0
	var mesh: ArrayMesh = result["mesh"]
	var vertices: PackedVector3Array = result.get("vertices", PackedVector3Array())
	var normals: PackedVector3Array = result.get("normals", PackedVector3Array())
	var colors: PackedColorArray = result.get("colors", PackedColorArray())
	var uvs: PackedVector2Array = result.get("uv", PackedVector2Array())
	var uv2s: PackedVector2Array = result.get("uv2", PackedVector2Array())
	var visible_faces: int = result["visible_faces"]
	var occluded_faces: int = result["occluded_faces"]
	var has_geometry: bool = result["has_geometry"]
	var missing_neighbors: Array = _missing_neighbors_from_value(result.get("missing_neighbors", []))
	var mesh_metrics := _mesh_metrics_from_result(result, mesh)

	_record_chunk_render_stats(key, visible_faces, occluded_faces, mesh_metrics)
	mesh_instance.mesh = mesh
	_after_chunk_mesh_applied(key)
	if has_geometry:
		mesh_instance.material_override = get_block_material()
	var chunk: ChunkData = world.get_chunk(key)
	if chunk != null:
		chunk.mesh_state = ChunkData.MESH_STATE_READY
		mesh_instance.set_meta("diagnostics_mesh_revision", chunk.mesh_revision)
		chunk.dirty = false
		_store_mesh_cache_from_arrays(key, chunk_size - 1, vertices, normals, colors, uvs, uv2s, visible_faces, occluded_faces, has_geometry, chunk.mesh_revision, mesh_metrics, missing_neighbors)
	_update_neighbor_remesh_dependencies(key, missing_neighbors)
	if world.live_diagnostics != null and world.live_diagnostics.enabled:
		world.live_diagnostics.observe("chunk", key, "sync_applied", {"revision": chunk.mesh_revision if chunk != null else null, "has_geometry": has_geometry})
	if recording:
		world.performance_recorder.add_timing("Mesh.apply_ms", float(Time.get_ticks_usec() - apply_start_usec) / 1000.0)
		world.performance_recorder.add_counter("Mesh.scene_applied")
#endregion


#region Async Meshing
func queue_chunk_mesh_build(coord: Vector3i, top_render_y: int = -1, respect_top: bool = false, high_priority: bool = false, force_sync: bool = false) -> void:
	if world == null:
		return
	if not world.is_chunk_coord_valid(coord):
		return
	_ensure_block_tables()
	var chunk: ChunkData = world.get_chunk(coord)
	if chunk == null or not chunk.generated:
		return
	var requested_local_top: int = _mesh_request_local_top(coord, top_render_y)
	if _apply_cached_mesh(coord, requested_local_top):
		_cancel_chunk_jobs(coord)
		return
	if not use_async_meshing or force_sync:
		regenerate_chunk(coord.x, coord.y, coord.z)
		return
	if not mesh_scheduler.is_running():
		_start_mesh_worker()
	var revision: int = chunk.mesh_revision
	var queued_rev: int = mesh_scheduler.get_job_revision(coord)
	if queued_rev >= revision and chunk.mesh_state == ChunkData.MESH_STATE_PENDING:
		if high_priority:
			_reprioritize_mesh_job(coord)
		return
	if queued_rev >= 0 and queued_rev < revision:
		_cancel_chunk_jobs(coord)
	chunk.mesh_state = ChunkData.MESH_STATE_PENDING
	var job := _build_mesh_job(coord, revision, top_render_y, false, respect_top)
	if job.is_empty():
		chunk.mesh_state = ChunkData.MESH_STATE_NONE
		return
	mesh_scheduler.enqueue_visible_job(job, revision, high_priority)
	if world.live_diagnostics != null and world.live_diagnostics.enabled:
		world.live_diagnostics.observe("chunk", coord, "mesh_queued", {"revision": revision, "high_priority": high_priority})


func _reprioritize_mesh_job(coord: Vector3i) -> void:
	mesh_scheduler.reprioritize_job(coord)


func _queue_prefetch_layers(coord: Vector3i, local_top: int) -> void:
	if MESH_CACHE_RADIUS <= 0:
		return
	if local_top < 0:
		return
	if not _is_chunk_in_current_render_zone(coord):
		return
	for offset in range(1, MESH_CACHE_RADIUS + 1):
		if not MESH_PREFETCH_BELOW_ONLY:
			_queue_prefetch_job(coord, local_top + offset)
		_queue_prefetch_job(coord, local_top - offset)


func _queue_prefetch_job(coord: Vector3i, local_top: int) -> void:
	if world == null:
		return
	if not use_async_meshing:
		return
	if not mesh_scheduler.is_running():
		_start_mesh_worker()
	_ensure_block_tables()
	var chunk_size: int = World.CHUNK_SIZE
	if local_top < 0 or local_top >= chunk_size:
		return
	if _has_cached_mesh(coord, local_top):
		return
	var chunk: ChunkData = world.get_chunk(coord)
	if chunk == null:
		return
	var revision: int = chunk.mesh_revision
	var key := _prefetch_key(coord, local_top)
	var queued_rev: int = mesh_scheduler.get_prefetch_revision(key)
	if queued_rev >= revision:
		return
	var chunk_base_y: int = coord.y * chunk_size
	var top_render_y := chunk_base_y + local_top
	var job := _build_mesh_job(coord, revision, top_render_y, true, false)
	if job.is_empty():
		return
	mesh_scheduler.enqueue_prefetch_job(key, job, revision)


func queue_chunk_mesh_cache_build(coord: Vector3i, local_top: int, high_priority: bool = false) -> bool:
	if world == null:
		return false
	if not use_async_meshing:
		return false
	if not world.is_chunk_coord_valid(coord):
		return false
	if local_top < 0 or local_top >= World.CHUNK_SIZE:
		return false
	if _has_cached_mesh(coord, local_top):
		return false
	if not mesh_scheduler.is_running():
		_start_mesh_worker()
	_ensure_block_tables()
	var chunk: ChunkData = world.get_chunk(coord)
	if chunk == null or not chunk.generated:
		return false
	var revision: int = chunk.mesh_revision
	var key := _prefetch_key(coord, local_top)
	var queued_rev: int = mesh_scheduler.get_prefetch_revision(key)
	if queued_rev >= revision:
		return false
	var top_render_y: int = coord.y * World.CHUNK_SIZE + local_top
	var job := _build_mesh_job(coord, revision, top_render_y, true, false)
	if job.is_empty():
		return false
	job["cache_only"] = true
	mesh_scheduler.enqueue_prefetch_job(key, job, revision, high_priority)
	return true


func process_mesh_results(budget: int) -> int:
	if budget <= 0:
		return 0
	var applied := 0
	while applied < budget:
		var result: Dictionary = mesh_scheduler.pop_result()
		if result.is_empty():
			break
		if _apply_mesh_result(result):
			applied += 1
	return applied


func process_mesh_results_time_budget(max_ms: float, max_count: int = -1) -> int:
	if max_ms <= 0.0:
		return 0
	var start_usec := Time.get_ticks_usec()
	var applied := 0
	var build_ms_sum := 0.0
	while true:
		if max_count >= 0 and applied >= max_count:
			break
		var elapsed_ms := float(Time.get_ticks_usec() - start_usec) / 1000.0
		if elapsed_ms >= max_ms:
			break
		if build_ms_sum >= max_ms:
			break
		var next_build_ms := mesh_scheduler.peek_next_result_build_ms()
		if next_build_ms < 0.0:
			break
		if build_ms_sum > 0.0 and build_ms_sum + next_build_ms > max_ms:
			break
		var result: Dictionary = mesh_scheduler.pop_result()
		if result.is_empty():
			break
		build_ms_sum += next_build_ms
		if _apply_mesh_result(result):
			applied += 1
	return applied


func flush_mesh_jobs(include_prefetch: bool = true, max_ms: float = -1.0) -> void:
	var start_usec := Time.get_ticks_usec()
	var safety := 0
	while has_pending_mesh_work(include_prefetch):
		var applied := 0
		if max_ms > 0.0:
			var elapsed_ms := float(Time.get_ticks_usec() - start_usec) / 1000.0
			var remaining_ms := max_ms - elapsed_ms
			if remaining_ms <= 0.0:
				break
			applied = process_mesh_results_time_budget(remaining_ms)
		else:
			applied = process_mesh_results(MESH_APPLY_BUDGET * 8)
		if applied <= 0:
			OS.delay_usec(500)
		safety += 1
		if safety > 100000:
			break


func _apply_mesh_result(result: Dictionary) -> bool:
	if world == null:
		return false
	# Returned builds are charged once even when rejected below. Completed-job
	# wall time must not be summed into Main's measured update cost.
	var recording := _performance_recording()
	if recording:
		world.performance_recorder.add_counter("Mesh.results")
		# Real scheduler results carry a capture epoch. Old pending/in-flight
		# builds must not leak costs into a newly started capture/world segment.
		# Unstamped direct results remain supported by synchronous test callers.
		var capture_current: bool = not result.has("performance_capture_epoch") or mesh_scheduler.is_result_in_performance_capture(result)
		if result.has("build_ms") and capture_current:
			world.performance_recorder.add_counter("Mesh.built")
			world.performance_recorder.add_timing("Mesh.completed.build_ms", float(result["build_ms"]))
	# Check lifetime before touching readiness, caches, or replacement job records.
	if not mesh_scheduler.is_result_current(result):
		_diagnostics_mesh(result, "stale_epoch")
		_record_mesh_counter("Mesh.stale")
		return false
	var apply_start_usec: int = Time.get_ticks_usec()
	var coord: Vector3i = result["coord"]
	var chunk: ChunkData = world.get_chunk(coord)
	var local_top: int = int(result.get("local_top", -1))
	var revision: int = int(result.get("mesh_revision", -1))
	var prefetch: bool = bool(result.get("prefetch", false))
	var respect_top: bool = bool(result.get("respect_top", false))
	var cache_only: bool = bool(result.get("cache_only", false))
	if chunk == null:
		_record_mesh_counter("Mesh.discarded")
		_diagnostics_mesh(result, "chunk_unloaded")
		if prefetch:
			_clear_prefetch_job_record(coord, local_top, revision)
		else:
			_clear_mesh_job_record(coord, revision)
		return false
	if revision != chunk.mesh_revision:
		_diagnostics_mesh(result, "stale_revision")
		_record_mesh_counter("Mesh.stale")
		if chunk.mesh_state == ChunkData.MESH_STATE_PENDING:
			chunk.mesh_state = ChunkData.MESH_STATE_NONE
		if prefetch:
			_clear_prefetch_job_record(coord, local_top, revision)
		else:
			_clear_mesh_job_record(coord, revision)
		return false
	var vertices: PackedVector3Array = result["vertices"]
	var normals: PackedVector3Array = result["normals"]
	var colors: PackedColorArray = result["colors"]
	var uvs: PackedVector2Array = result["uv"]
	var uv2s: PackedVector2Array = result["uv2"]
	var visible_faces: int = int(result["visible_faces"])
	var occluded_faces: int = int(result["occluded_faces"])
	var has_geometry: bool = bool(result["has_geometry"])
	var missing_neighbors: Array = _missing_neighbors_from_value(result.get("missing_neighbors", []))
	var mesh_metrics := _mesh_metrics_from_result(result, null)


	var chunk_size: int = World.CHUNK_SIZE
	var current_local_top := world.top_render_y - coord.y * chunk_size
	if current_local_top >= 0:
		current_local_top = min(current_local_top, chunk_size - 1)
	else:
		current_local_top = -1
	var should_apply := not prefetch and not cache_only
	# Full-chunk geometry remains valid when a queued slice request changes.
	if not cache_only and (prefetch or (respect_top and local_top != chunk_size - 1)):
		should_apply = current_local_top == local_top
	if should_apply:
		var mesh := ArrayMesh.new()
		if has_geometry:
			var arrays := []
			arrays.resize(Mesh.ARRAY_MAX)
			arrays[Mesh.ARRAY_VERTEX] = vertices
			arrays[Mesh.ARRAY_NORMAL] = normals
			arrays[Mesh.ARRAY_COLOR] = colors
			arrays[Mesh.ARRAY_TEX_UV] = uvs
			arrays[Mesh.ARRAY_TEX_UV2] = uv2s
			mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		var mesh_instance: MeshInstance3D = chunk_cache.ensure_chunk(coord, chunk_size)
		_record_chunk_render_stats(coord, visible_faces, occluded_faces, mesh_metrics)
		mesh_instance.mesh = mesh
		mesh_instance.set_meta("diagnostics_mesh_revision", revision)
		_after_chunk_mesh_applied(coord)
		if has_geometry:
			mesh_instance.material_override = get_block_material()
		chunk.mesh_state = ChunkData.MESH_STATE_READY
		chunk.dirty = false
	_store_mesh_cache_from_arrays(coord, local_top, vertices, normals, colors, uvs, uv2s, visible_faces, occluded_faces, has_geometry, revision, mesh_metrics, missing_neighbors)
	_update_neighbor_remesh_dependencies(coord, missing_neighbors)
	if should_apply:
		_queue_prefetch_layers(coord, local_top)
	_diagnostics_mesh(result, "applied" if should_apply else "cached_only")

	var build_ms := float(result.get("build_ms", 0.0))
	mesh_cache_store.record_build_ms(build_ms)
	if build_ms > 0.0 and world.debug_profiler != null:
		world.debug_profiler.add_sample("Renderer.build_chunk_mesh", build_ms)
		if build_ms >= MESH_BUILD_LOG_THRESHOLD_MS:
			print("Chunk mesh build %d,%d,%d: %.2f ms" % [coord.x, coord.y, coord.z, build_ms])
	mesh_cache_store.record_upload_ms(float(Time.get_ticks_usec() - apply_start_usec) / 1000.0)
	if recording:
		world.performance_recorder.add_timing("Mesh.apply_ms", float(Time.get_ticks_usec() - apply_start_usec) / 1000.0)
		world.performance_recorder.add_counter("Mesh.results_applied")
		world.performance_recorder.add_counter("Mesh.scene_applied" if should_apply else "Mesh.cache_only_applied")
	if prefetch:
		_clear_prefetch_job_record(coord, local_top, revision)
	else:
		_clear_mesh_job_record(coord, revision)
	return true


func _performance_recording() -> bool:
	return world != null and world.performance_recorder != null and world.performance_recorder.enabled


## Main-thread only. Call after recorder.start(), and BEFORE recorder.stop()
## or begin_world(). Repeated true resets the epoch for a new world boundary.
## Atomic reset returns any final old totals, which are emitted before return.
func set_performance_capture_enabled(enabled: bool) -> void:
	_emit_performance_capture_totals(mesh_scheduler.set_performance_capture_enabled(enabled))
	_emit_visibility_capture_totals(visibility_scheduler.set_performance_capture(enabled))


## Explicit main-thread drain, once per frame before recorder.end_frame().
## Snapshot getters never drain. Bounded: four categories, never per lost job.
func drain_performance_capture() -> void:
	_emit_performance_capture_totals(mesh_scheduler.drain_performance_capture())
	_emit_visibility_capture_totals(visibility_scheduler.drain_performance_capture())


func _emit_visibility_capture_totals(totals: Dictionary) -> void:
	if not _performance_recording():
		return
	for kind in ["completed", "cancelled", "replaced_result", "replaced_pending"]:
		var count := int(totals.get(kind + "_count", 0))
		if count > 0:
			world.performance_recorder.add_counter("RenderZone.scheduler." + kind, count)
	for kind in ["completed", "cancelled"]:
		if int(totals.get(kind + "_count", 0)) > 0:
			world.performance_recorder.add_timing("RenderZone.completed." + kind + "_ms_sum", float(totals.get(kind + "_ms", 0.0)))
	if int(totals.get("completed_count", 0)) > 0:
		world.performance_recorder.add_timing("RenderZone.completed.queue_wait_ms_sum", float(totals.get("queue_wait_ms", 0.0)))


func _emit_performance_capture_totals(totals: Dictionary) -> void:
	if not _performance_recording():
		return
	for kind in ["completed", "delivered", "lost_before_publication", "discarded_pending"]:
		var count := int(totals.get(kind + "_count", 0))
		if count <= 0:
			continue
		world.performance_recorder.add_counter("Mesh.scheduler." + kind, count)
		# One observation is a drain's elapsed SUM, not an individual build.
		# The paired counter is the denominator; these lifecycle categories
		# overlap (completed includes delivered/lost), and are not additive.
		world.performance_recorder.add_timing("Mesh.scheduler." + kind + "_build_ms_sum", float(totals.get(kind + "_ms", 0.0)))


func _record_mesh_counter(label: String) -> void:
	if _performance_recording():
		world.performance_recorder.add_counter(label)


func _clear_mesh_job_record(coord: Vector3i, revision: int) -> void:
	mesh_scheduler.clear_job_record(coord, revision)


func _clear_prefetch_job_record(coord: Vector3i, local_top: int, revision: int) -> void:
	mesh_scheduler.clear_prefetch_job_record(coord, local_top, revision)


func _cancel_chunk_jobs(coord: Vector3i) -> void:
	mesh_scheduler.cancel_coord(coord)


func _purge_prefetch_for_coord(coord: Vector3i) -> void:
	mesh_scheduler.purge_prefetch_for_coord(coord)


func _prefetch_key(coord: Vector3i, local_top: int) -> String:
	return mesh_scheduler.prefetch_key(coord, local_top)


func _build_mesh_job(coord: Vector3i, revision: int, top_render_y: int, prefetch: bool, respect_top: bool) -> Dictionary:
	var job: Dictionary = mesh_job_builder.build_mesh_job(
		coord,
		revision,
		top_render_y,
		prefetch,
		respect_top,
		block_solid_table,
		block_ramp_table,
		block_color_table
	)
	if not job.is_empty():
		mesh_scheduler.stamp_job(job)
	return job


func _build_mesh_result_on_worker(job: Dictionary) -> Dictionary:
	var build_start := Time.get_ticks_usec()
	var result: Dictionary = mesher_thread.build_chunk_arrays_from_data(job)
	result["coord"] = job["coord"]
	result["mesh_epoch"] = job.get("mesh_epoch", -1)
	result["coord_epoch"] = job.get("coord_epoch", -1)
	result["mesh_revision"] = job.get("mesh_revision", -1)
	result["local_top"] = job.get("local_top", -1)
	result["prefetch"] = job.get("prefetch", false)
	result["respect_top"] = job.get("respect_top", false)
	result["cache_only"] = job.get("cache_only", false)
	result["missing_neighbors"] = job.get("missing_neighbors", [])
	result["build_ms"] = float(Time.get_ticks_usec() - build_start) / 1000.0
	return result


func _start_mesh_worker() -> void:
	mesh_scheduler.start(use_async_meshing)


func _stop_mesh_worker() -> void:
	mesh_scheduler.stop()


func _ensure_block_tables() -> void:
	if world == null:
		return
	mesher._ensure_block_tables(world)
	block_solid_table = mesher.block_solid_table
	block_color_table = mesher.block_color_table
	block_ramp_table = mesher.block_ramp_table


func _clear_mesh_jobs() -> void:
	mesh_scheduler.clear()
#endregion


#region Render Height Queue
func queue_render_height_update(old_y: int, new_y: int, anchor: Vector3, min_x: int, max_x: int, min_z: int, max_z: int) -> int:
	if world == null:
		return 0
	return render_level_helper.queue_update(world, old_y, new_y, anchor, min_x, max_x, min_z, max_z)


func process_render_height_queue(budget: int) -> int:
	return render_level_helper.process_queue(budget)


func clear_render_height_queue() -> void:
	render_level_helper.clear()


func has_pending_render_height_work() -> bool:
	return render_level_helper.has_pending_work()


func has_pending_mesh_work(include_prefetch: bool) -> bool:
	if mesh_scheduler.has_visible_records():
		return true
	if include_prefetch and mesh_scheduler.has_prefetch_records():
		return true
	if include_prefetch:
		if _has_any_jobs():
			return true
		if _has_any_results():
			return true
		return false
	if _has_non_prefetch_jobs():
		return true
	if _has_non_prefetch_results():
		return true
	return false


func _has_non_prefetch_jobs() -> bool:
	return mesh_scheduler.has_non_prefetch_jobs()


func _has_non_prefetch_results() -> bool:
	return mesh_scheduler.has_non_prefetch_results()


func _has_any_jobs() -> bool:
	return mesh_scheduler.has_any_jobs()


func _has_any_results() -> bool:
	return mesh_scheduler.has_any_results()


func update_render_height_anchor(anchor: Vector3) -> void:
	render_level_helper.update_anchor(anchor)
#endregion


#region Mesh Cache
func invalidate_chunk_mesh_cache(coord: Vector3i) -> void:
	mesh_cache_store.erase(coord)


func reset_mesh_cache_metrics() -> void:
	mesh_cache_store.reset_metrics()


func get_mesh_cache_metrics() -> Dictionary:
	return mesh_cache_store.get_metrics()

func get_mesher_table_snapshot() -> Dictionary:
	_ensure_block_tables()
	return {
		"solid_table": block_solid_table.duplicate(),
		"color_table": block_color_table.duplicate(),
		"ramp_table": block_ramp_table.duplicate(),
	}

func _store_mesh_cache_from_arrays(
	coord: Vector3i,
	local_top: int,
	vertices: PackedVector3Array,
	normals: PackedVector3Array,
	colors: PackedColorArray,
	uvs: PackedVector2Array,
	uv2s: PackedVector2Array,
	visible_faces: int,
	occluded_faces: int,
	has_geometry: bool,
	revision: int,
	mesh_metrics: Dictionary = {},
	missing_neighbors: Array = []
) -> void:
	mesh_cache_store.store_from_arrays(
		coord,
		local_top,
		vertices,
		normals,
		colors,
		uvs,
		uv2s,
		visible_faces,
		occluded_faces,
		has_geometry,
		revision,
		mesh_metrics,
		missing_neighbors
	)


func export_persistent_mesh_cache_entry(coord: Vector3i, local_top: int) -> Dictionary:
	return mesh_cache_store.export_persistent_entry(coord, local_top)

func import_persistent_mesh_cache_entry(coord: Vector3i, entry: Dictionary) -> bool:
	return mesh_cache_store.import_persistent_entry(world, coord, entry)

func _validate_mesh_cache_arrays(entry: Dictionary) -> bool:
	return mesh_cache_store.validate_arrays(entry)

func _array_mesh_from_entry(entry: Dictionary) -> ArrayMesh:
	return mesh_cache_store.array_mesh_from_entry(entry)

func has_cached_chunk_mesh(coord: Vector3i, local_top: int) -> bool:
	return _has_cached_mesh(coord, local_top)


func _has_cached_mesh(coord: Vector3i, local_top: int) -> bool:
	return mesh_cache_store.has_cached_mesh(world, coord, local_top)


func _apply_cached_mesh(coord: Vector3i, local_top: int) -> bool:
	var cached := mesh_cache_store.get_valid_entry_for_apply(world, coord, local_top)
	if cached.is_empty():
		return false
	var entry: Dictionary = cached["entry"]
	var cache_local_top: int = int(cached["local_top"])
	var chunk: ChunkData = world.get_chunk(coord)
	if chunk == null:
		return false
	var recording := _performance_recording()
	var apply_start_usec := Time.get_ticks_usec() if recording else 0
	_apply_mesh_entry(coord, entry, chunk)
	if recording:
		world.performance_recorder.add_timing("Mesh.apply_ms", float(Time.get_ticks_usec() - apply_start_usec) / 1000.0)
		world.performance_recorder.add_counter("Mesh.cache_applied")
		world.performance_recorder.add_counter("Mesh.scene_applied")
	_queue_prefetch_layers(coord, cache_local_top)
	return true


func _mesh_request_local_top(coord: Vector3i, top_render_y: int) -> int:
	if top_render_y < 0:
		top_render_y = world.top_render_y
	var local_top: int = top_render_y - coord.y * World.CHUNK_SIZE
	if local_top < 0:
		# Above-slice requests still need a real full mesh before becoming READY.
		return World.CHUNK_SIZE - 1
	return mini(local_top, World.CHUNK_SIZE - 1)


func _apply_mesh_entry(coord: Vector3i, entry: Dictionary, chunk: ChunkData) -> void:
	var visible_faces: int = int(entry["visible_faces"])
	var occluded_faces: int = int(entry["occluded_faces"])
	var has_geometry: bool = bool(entry["has_geometry"])
	var missing_neighbors: Array = _missing_neighbors_from_value(entry.get("missing_neighbors", []))
	var mesh: ArrayMesh = _array_mesh_from_entry(entry)
	var mesh_instance: MeshInstance3D = chunk_cache.ensure_chunk(coord, World.CHUNK_SIZE)
	_record_chunk_render_stats(coord, visible_faces, occluded_faces, _mesh_metrics_from_entry(entry, null))
	mesh_instance.mesh = mesh if has_geometry else null
	mesh_instance.set_meta("diagnostics_mesh_revision", chunk.mesh_revision)
	if has_geometry:
		mesh_instance.material_override = get_block_material()
	_after_chunk_mesh_applied(coord)
	chunk.mesh_state = ChunkData.MESH_STATE_READY
	chunk.dirty = false
	_update_neighbor_remesh_dependencies(coord, missing_neighbors)
	if world.live_diagnostics != null and world.live_diagnostics.enabled:
		world.live_diagnostics.observe("chunk", coord, "cache_applied", {"revision": entry.get("revision"), "has_geometry": has_geometry})

func _apply_empty_mesh(coord: Vector3i) -> void:
	# Legacy render-height callers must retain full geometry, including the
	# upper-band player stairs visible one level below their cells (SEE-ADR-011).
	queue_chunk_mesh_build(coord)


func _hide_chunk_mesh(coord: Vector3i) -> void:
	var mesh_instance: MeshInstance3D = chunk_cache.get_chunk(coord)
	if mesh_instance != null:
		visibility_state.set_node_visibility(coord, false)
		# Legacy render-height hides can affect a coordinate that remains in
		# the accepted set. Reconcile it on the next refresh as before.
		if not visibility_state.initialized or render_zone_visible.has(coord):
			visibility_state.reconcile[coord] = true
	var chunk: ChunkData = world.get_chunk(coord)
	if chunk != null:
		chunk.mesh_state = ChunkData.MESH_STATE_NONE
#endregion


#region Render Zone
## A small value snapshot, never a scan of chunks or mesh data. Check it at
## the existing refresh cadence, not for every candidate or mesh arrival.
func _render_zone_key(min_cx: int, max_cx: int, min_cz: int, max_cz: int, min_cy: int, max_cy: int, camera: Camera3D) -> Array:
	# Lead presence is part of the view: when panning stops and the lead decays to
	# zero, one more request trims the look-ahead chunks.
	var key: Array = [min_cx, max_cx, min_cz, max_cz, min_cy, max_cy, world.top_render_y, motion_lead_offset.is_zero_approx()]
	if camera != null:
		key.append_array([camera.get_instance_id(), camera.global_transform,
			camera.get_camera_transform(), camera.get_camera_projection(),
			camera.get_viewport().get_instance_id(), camera.get_viewport().get_visible_rect()])
	return key


func needs_render_zone_update(min_cx: int, max_cx: int, min_cz: int, max_cz: int, min_cy: int, max_cy: int, camera: Camera3D = null) -> bool:
	visibility_state.observe(camera)
	if render_debug.freeze:
		return false
	return visibility_state.needs_request(_render_zone_key(min_cx, max_cx, min_cz, max_cz, _debug_min_cy(min_cy), max_cy, _key_camera(camera)))


func invalidate_render_zone() -> void:
	visibility_state.invalidate()


func is_render_zone_initialized() -> bool:
	return visibility_state.initialized


func update_render_zone(
	min_cx: int,
	max_cx: int,
	min_cz: int,
	max_cz: int,
	min_cy: int,
	max_cy: int,
	camera: Camera3D = null
) -> void:
	_last_zone_args = [min_cx, max_cx, min_cz, max_cz, min_cy, max_cy]
	_fill_slice_caps_in_zone()
	if render_debug.freeze:
		return
	min_cy = _debug_min_cy(min_cy)
	var key := _render_zone_key(min_cx, max_cx, min_cz, max_cz, min_cy, max_cy, _key_camera(camera))
	# Intersect rather than clamp: an entirely outside request must stay empty.
	var minimum := Vector3i(maxi(min_cx, world.WORLD_MIN_CHUNK_X), maxi(min_cy, 0), maxi(min_cz, world.WORLD_MIN_CHUNK_Z))
	var maximum := Vector3i(mini(max_cx, world.WORLD_MAX_CHUNK_X), mini(max_cy, ceili(float(world.world_size_y) / World.CHUNK_SIZE) - 1), mini(max_cz, world.WORLD_MAX_CHUNK_Z))
	visibility_state.request(minimum, maximum, camera, key, str(render_debug.visibility_mode))


func pump_visibility(max_ms: float = 1.0, max_steps: int = 256) -> int:
	var steps: int = visibility_state.pump(max_ms, max_steps)
	if void_meter_enabled:
		_tick_void_meter()
	return steps


func observe_visibility_view(camera: Camera3D) -> void:
	visibility_state.observe(camera)


func get_visibility_snapshot() -> Dictionary:
	var state: Dictionary = visibility_state.snapshot()
	state["render_debug"] = render_debug.duplicate()
	state["void_meter"] = void_meter.duplicate() if void_meter_enabled else {"enabled": false}
	return state


#region Slice caps
## SEE-ADR-020. The hatched cut floor at the render level. Chunk meshes hold only exposed
## faces; each chunk in the render level's chunk layer gets a small child mesh
## with the covered tops of that one block layer, rebuilt on level change and
## when the chunk (or the chunk above) is remeshed.
const SLICE_CAP_NODE := "SliceCap"
var _slice_cap_coords: Dictionary = {}
var slice_cap_build_usec := 0
# Columns checked for a cap at the current level (with or without one).
var _slice_cap_checked: Dictionary = {}
var _cap_cell_table := PackedByteArray()


func _slice_cap_layer() -> int:
	if world == null:
		return -1
	return floori(float(world.top_render_y) / World.CHUNK_SIZE)


## Level change: drop every cap, then build the columns of the current render
## zone. Columns entering the zone later are filled in by _fill_slice_caps_in_zone.
func refresh_slice_caps() -> void:
	if world == null:
		return
	var started := Time.get_ticks_usec()
	for coord: Vector3i in _slice_cap_coords.keys():
		_remove_slice_cap(coord)
	_slice_cap_checked.clear()
	_fill_slice_caps_in_zone()
	slice_cap_build_usec = Time.get_ticks_usec() - started


## Builds caps for slice-layer columns of the last render-zone box not yet
## checked at this level (each column is checked once per level; remeshes
## rebuild through _after_chunk_mesh_applied). Cheap when nothing is new.
func _fill_slice_caps_in_zone() -> void:
	var slice_cy := _slice_cap_layer()
	if slice_cy < 0 or _last_zone_args.is_empty():
		return
	var args: Array = _last_zone_args
	if slice_cy < int(args[4]) or slice_cy > int(args[5]):
		return
	for cx in range(maxi(args[0], world.WORLD_MIN_CHUNK_X), mini(args[1], world.WORLD_MAX_CHUNK_X) + 1):
		for cz in range(maxi(args[2], world.WORLD_MIN_CHUNK_Z), mini(args[3], world.WORLD_MAX_CHUNK_Z) + 1):
			var coord := Vector3i(cx, slice_cy, cz)
			if _slice_cap_checked.has(coord):
				continue
			_slice_cap_checked[coord] = true
			_build_slice_cap(coord)


## Every mesh apply path (sync, async result, cache) ends here: a remesh of the
## slice chunk or the chunk above it changes that column's cap; a chunk with
## only a cap is still visible.
func _after_chunk_mesh_applied(coord: Vector3i) -> void:
	var slice_cy := _slice_cap_layer()
	if coord.y == slice_cy:
		_slice_cap_checked[coord] = true
		_build_slice_cap(coord)
	elif coord.y == slice_cy + 1:
		var below := Vector3i(coord.x, slice_cy, coord.z)
		_slice_cap_checked[below] = true
		_build_slice_cap(below)
	visibility_state.set_node_visibility(coord, _is_chunk_in_current_render_zone(coord))


func has_slice_cap(coord: Vector3i) -> bool:
	return _slice_cap_coords.has(coord)


func _build_slice_cap(coord: Vector3i) -> void:
	var chunk: ChunkData = world.get_chunk(coord) if world.is_chunk_coord_valid(coord) else null
	var ly: int = world.top_render_y - coord.y * World.CHUNK_SIZE
	if chunk == null or not chunk.generated or ly < 0 or ly >= World.CHUNK_SIZE or chunk.blocks.is_empty():
		_remove_slice_cap(coord)
		return
	_ensure_block_tables()
	var above_blocks := chunk.blocks
	if ly == World.CHUNK_SIZE - 1:
		var above_coord := coord + Vector3i.UP
		var above: ChunkData = world.get_chunk(above_coord) if world.is_chunk_coord_valid(above_coord) else null
		above_blocks = above.blocks if above != null and above.generated else PackedByteArray()
	if _cap_cell_table.size() != block_solid_table.size():
		_cap_cell_table = mesher.cap_cell_table(World.BLOCK_ID_AIR, block_ramp_table, block_solid_table.size())
	var arrays: Dictionary = mesher.build_cap_arrays_tabled(chunk.blocks, above_blocks, World.CHUNK_SIZE, coord.x, coord.y, coord.z, ly,
		_cap_cell_table, block_solid_table, block_color_table)
	var vertices: PackedVector3Array = arrays.vertices
	if vertices.is_empty():
		_remove_slice_cap(coord)
		return
	var mesh_arrays := []
	mesh_arrays.resize(Mesh.ARRAY_MAX)
	mesh_arrays[Mesh.ARRAY_VERTEX] = vertices
	mesh_arrays[Mesh.ARRAY_NORMAL] = arrays.normals
	mesh_arrays[Mesh.ARRAY_COLOR] = arrays.colors
	mesh_arrays[Mesh.ARRAY_TEX_UV] = arrays.uv
	mesh_arrays[Mesh.ARRAY_TEX_UV2] = arrays.uv2
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, mesh_arrays)
	var node: MeshInstance3D = chunk_cache.ensure_chunk(coord, World.CHUNK_SIZE)
	var cap: MeshInstance3D = node.get_node_or_null(SLICE_CAP_NODE)
	if cap == null:
		cap = MeshInstance3D.new()
		cap.name = SLICE_CAP_NODE
		node.add_child(cap)
	cap.mesh = mesh
	cap.material_override = get_block_material()
	_slice_cap_coords[coord] = true
	# A buried chunk can now be visible through its cap alone.
	visibility_state.set_node_visibility(coord, _is_chunk_in_current_render_zone(coord))


func _remove_slice_cap(coord: Vector3i) -> void:
	if not _slice_cap_coords.has(coord):
		return
	_slice_cap_coords.erase(coord)
	var node: MeshInstance3D = chunk_cache.get_chunk(coord)
	if node == null:
		return
	var cap := node.get_node_or_null(SLICE_CAP_NODE)
	if cap != null:
		node.remove_child(cap)
		cap.queue_free()
	visibility_state.set_node_visibility(coord, _is_chunk_in_current_render_zone(coord))
#endregion


#region Rendering debug switches (F7 panel)
## Returns false (and changes nothing) for an unknown key or disallowed value.
func set_render_debug(key: String, value: Variant) -> bool:
	if not render_debug.has(key):
		return false
	match key:
		"visibility_mode":
			if not RENDER_DEBUG_OPTIONS.visibility_mode.has(value):
				return false
		"depth_layers":
			if typeof(value) not in [TYPE_INT, TYPE_FLOAT] or not RENDER_DEBUG_OPTIONS.depth_layers.has(int(value)):
				return false
			value = int(value)
		"look_ahead_sec":
			if typeof(value) not in [TYPE_INT, TYPE_FLOAT]:
				return false
			value = clampf(float(value), 0.0, 0.5)
		_:
			if typeof(value) != TYPE_BOOL:
				return false
	if render_debug[key] == value:
		return true
	render_debug[key] = value
	if key == "look_ahead" and not value:
		motion_lead_offset = Vector3.ZERO
	# Mode/depth changes and unfreezing need a fresh full view; epoch bump drops
	# in-flight work for the old settings.
	if key in ["visibility_mode", "depth_layers"] or (key == "freeze" and not value):
		invalidate_render_zone()
		if not _last_zone_args.is_empty():
			var args: Array = _last_zone_args
			update_render_zone(args[0], args[1], args[2], args[3], args[4], args[5], visibility_state.get_camera())
	return true


func get_render_debug() -> Dictionary:
	return render_debug.duplicate()


## Look-ahead lead in seconds, 0 when disabled.
func get_look_ahead_sec() -> float:
	return float(render_debug.look_ahead_sec) if render_debug.look_ahead else 0.0


func get_render_debug_stats() -> Dictionary:
	var vis: Dictionary = visibility_state.snapshot()
	var now := Time.get_ticks_usec()
	if _stats_prev.is_empty() or now - int(_stats_prev.usec) >= 1000000:
		if not _stats_prev.is_empty():
			var seconds := float(now - int(_stats_prev.usec)) / 1000000.0
			var jobs := float(vis.get("completed_count", 0)) - float(_stats_prev.completed_count)
			_stats_rates = {
				"delta_per_sec": (int(vis.delta_applications) - int(_stats_prev.delta)) / seconds,
				"full_per_sec": (int(vis.full_applications) - int(_stats_prev.full)) / seconds,
				"cull_job_ms": (float(vis.get("completed_ms", 0.0)) - float(_stats_prev.completed_ms)) / jobs if jobs > 0.0 else 0.0,
			}
		_stats_prev = {"usec": now, "delta": int(vis.delta_applications), "full": int(vis.full_applications),
			"completed_count": float(vis.get("completed_count", 0)), "completed_ms": float(vis.get("completed_ms", 0.0))}
	return {
		"fps": Engine.get_frames_per_second(),
		"frame_ms": Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0,
		"draw_calls": RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME),
		"shown_nodes": int(vis.shown_nodes),
		"eligible": int(vis.effective_eligible),
		"vis_lag_ms": vis.result_age_ms,
		"last_application_mode": vis.last_application_mode,
		"delta_per_sec": _stats_rates.delta_per_sec,
		"full_per_sec": _stats_rates.full_per_sec,
		"cull_job_ms": _stats_rates.cull_job_ms,
		"void": void_meter.duplicate(),
		"settings": render_debug.duplicate(),
	}


func _debug_min_cy(min_cy: int) -> int:
	var layers := int(render_debug.depth_layers)
	if layers <= 0:
		return min_cy
	var top_cy := floori(float(world.top_render_y) / World.CHUNK_SIZE)
	return maxi(min_cy, top_cy - layers + 1)


## Area mode shows the whole box regardless of camera, so camera motion alone
## must not trigger requests.
func _key_camera(camera: Camera3D) -> Camera3D:
	return null if render_debug.visibility_mode == "area" else camera


## Void = on-screen chunks in the top two render chunk layers that have geometry
## but are hidden: visibility lag the player sees as missing terrain.
func _tick_void_meter() -> void:
	var now := Time.get_ticks_usec()
	if now - _void_last_usec < VOID_METER_INTERVAL_USEC or _last_zone_args.is_empty() or world == null:
		return
	_void_last_usec = now
	var camera: Camera3D = visibility_state.get_camera()
	if camera == null or not camera.is_inside_tree():
		return
	var planes: Array = frustum_culler.build_planes(camera, NEAR_SAMPLE_OFFSET, NEAR_SAMPLE_MIN)
	var top_cy := floori(float(world.top_render_y) / World.CHUNK_SIZE)
	var args: Array = _last_zone_args
	var hidden := 0
	var checked := 0
	for cy in [top_cy, top_cy - 1]:
		for cx in range(maxi(args[0], world.WORLD_MIN_CHUNK_X), mini(args[1], world.WORLD_MAX_CHUNK_X) + 1):
			for cz in range(maxi(args[2], world.WORLD_MIN_CHUNK_Z), mini(args[3], world.WORLD_MAX_CHUNK_Z) + 1):
				var coord := Vector3i(cx, cy, cz)
				if not frustum_culler.is_chunk_in_view(planes, coord, World.CHUNK_SIZE, 0.0):
					continue
				var node: MeshInstance3D = chunk_cache.get_chunk(coord)
				if node == null or ((node.mesh == null or node.mesh.get_surface_count() == 0) and not has_slice_cap(coord)):
					continue
				checked += 1
				if not node.visible:
					hidden += 1
	if hidden > 0 and _void_streak_start_usec == 0:
		_void_streak_start_usec = now
	elif hidden == 0:
		_void_streak_start_usec = 0
	_void_samples.append([now, hidden])
	while not _void_samples.is_empty() and now - int(_void_samples[0][0]) > VOID_METER_WINDOW_USEC:
		_void_samples.pop_front()
	var max_recent := 0
	var void_count := 0
	for sample: Array in _void_samples:
		max_recent = maxi(max_recent, int(sample[1]))
		if int(sample[1]) > 0:
			void_count += 1
	void_meter = {"hidden": hidden, "checked": checked, "max_recent": max_recent,
		"void_ms": float(now - _void_streak_start_usec) / 1000.0 if _void_streak_start_usec > 0 else 0.0,
		"void_pct_recent": 100.0 * void_count / maxf(1.0, _void_samples.size())}
#endregion


func _is_chunk_in_current_render_zone(coord: Vector3i) -> bool:
	return visibility_state.is_eligible(coord)


func _set_chunk_visibility(coord: Vector3i, is_visible: bool) -> void:
	visibility_state.set_node_visibility(coord, is_visible)


func _diagnostics_mesh(result: Dictionary, reason: String) -> void:
	if world.live_diagnostics != null and world.live_diagnostics.enabled:
		world.live_diagnostics.observe("chunk", result.get("coord", Vector3i.ZERO), reason,
			{"revision": result.get("mesh_revision"), "build_ms": result.get("build_ms"),
			"completed_job": true, "local_top": result.get("local_top"), "has_geometry": result.get("has_geometry")})
#endregion


#region Materials
func get_block_material() -> Material:
	return material_helper.get_block_material()


func set_top_render_y(value: int) -> void:
	material_helper.set_top_render_y(value)
	refresh_slice_caps()
	if overlay_renderer != null:
		overlay_renderer.set_top_render_y(value)


func set_min_render_y(value: int) -> void:
	material_helper.set_min_render_y(value)


func toggle_debug_normals() -> void:
	material_helper.toggle_debug_normals()


func set_poly_debug_enabled(enabled: bool) -> void:
	material_helper.set_poly_debug_enabled(enabled)
#endregion


#region Stats
func get_draw_burden_stats() -> Dictionary:
	return render_stats.get_draw_burden_stats()


func get_chunk_draw_stats() -> Dictionary:
	var loaded := 0
	if world != null:
		loaded = world.chunks.size()
	var keys: Array = chunk_cache.get_keys()
	var meshed: int = keys.size()
	var visible_count: int = 0
	for key in keys:
		var mesh_instance: MeshInstance3D = chunk_cache.get_chunk(key)
		if mesh_instance == null:
			continue
		if mesh_instance.mesh == null:
			continue
		if mesh_instance.visible:
			visible_count += 1
	var zone: int = render_zone_visible.size()
	var pool_stats := chunk_cache.get_pool_stats()
	return {
		"loaded": loaded,
		"meshed": meshed,
		"visible": visible_count,
		"zone": zone,
		"chunk_node_active": int(pool_stats.get("active", 0)),
		"chunk_node_pooled": int(pool_stats.get("pooled", 0)),
		"chunk_node_pool_max": int(pool_stats.get("pool_max", 0)),
		"chunk_node_created": int(pool_stats.get("created", 0)),
		"chunk_node_reused": int(pool_stats.get("reused", 0)),
		"chunk_node_freed": int(pool_stats.get("freed", 0)),
	}


func get_mesh_work_stats() -> Dictionary:
	var scheduler_stats := mesh_scheduler.get_stats()
	var cache_metrics := mesh_cache_store.get_metrics()
	var stats: Dictionary = render_stats.get_mesh_work_stats()
	stats["job_queue"] = int(scheduler_stats.get("job_queue", 0))
	stats["result_queue"] = int(scheduler_stats.get("result_queue", 0))
	stats["job_set"] = int(scheduler_stats.get("job_set", 0))
	stats["prefetch_set"] = int(scheduler_stats.get("prefetch_set", 0))
	stats["cache_hits"] = int(cache_metrics.get("hits", 0))
	stats["cache_misses"] = int(cache_metrics.get("misses", 0))
	stats["cache_imports"] = int(cache_metrics.get("imports", 0))
	stats["mesh_build_ms"] = float(cache_metrics.get("mesh_build_ms", 0.0))
	stats["mesh_upload_ms"] = float(cache_metrics.get("mesh_upload_ms", 0.0))
	stats["pending_neighbor_remesh_chunks"] = pending_neighbor_remesh.size()
	stats["pending_neighbor_remesh_dependents"] = _count_pending_neighbor_remesh_dependents()
	stats["neighbor_remesh_queued"] = neighbor_remesh_queued_total
	return stats


## O(1) main-thread snapshot; do not use get_mesh_work_stats(), which scans
## neighbor-remesh dependencies. Record counts are not executing job counts.
func get_performance_snapshot() -> Dictionary:
	var snapshot := mesh_scheduler.get_performance_snapshot()
	var metrics := mesh_cache_store.get_metrics()
	snapshot["cache_hits_total"] = metrics.get("hits")
	snapshot["cache_misses_total"] = metrics.get("misses")
	snapshot["cache_imports_total"] = metrics.get("imports")
	snapshot["build_ms_total"] = metrics.get("mesh_build_ms")
	snapshot["upload_ms_total"] = metrics.get("mesh_upload_ms")
	snapshot["pending_neighbor_remesh_chunks"] = pending_neighbor_remesh.size()
	return snapshot


func get_camera_tris_rendered(camera: Camera3D) -> Dictionary:
	if camera == null:
		return {"rendered": 0, "total": 0, "percent": 0.0}
	var planes: Array = frustum_culler.build_planes(camera, NEAR_SAMPLE_OFFSET, NEAR_SAMPLE_MIN)
	var rendered_faces := 0
	var total_faces := 0
	for key in chunk_cache.get_keys():
		var coord: Vector3i = key
		var mesh_instance: MeshInstance3D = chunk_cache.get_chunk(coord)
		if mesh_instance == null or not mesh_instance.visible or mesh_instance.mesh == null:
			continue
		var faces: int = render_stats.get_chunk_visible_faces(coord)
		if faces <= 0:
			continue
		total_faces += faces
		if frustum_culler.is_chunk_in_view(planes, coord, World.CHUNK_SIZE):
			rendered_faces += faces
	var rendered_tris: int = rendered_faces * 2
	var total_tris: int = total_faces * 2
	var percent := 0.0
	if total_tris > 0:
		percent = float(rendered_tris) / float(total_tris) * 100.0
	return {"rendered": rendered_tris, "total": total_tris, "percent": percent}
#endregion


#region Overlay Management
func update_task_overlays(tasks: Array) -> void:
	if overlay_renderer == null:
		return
	overlay_renderer.update_task_overlays(tasks)


func update_item_overlays(items: Dictionary) -> void:
	if overlay_renderer == null:
		return
	overlay_renderer.update_item_overlays(items)


func update_stockpile_overlays(stockpiles: Dictionary) -> void:
	if overlay_renderer == null:
		return
	overlay_renderer.update_stockpile_overlays(stockpiles)


func set_drag_preview(rect: Dictionary, mode: int) -> void:
	if overlay_renderer == null:
		return
	overlay_renderer.set_drag_preview(rect, mode)


func _set_excavation_preview(cells: Array[Vector3i]) -> void:
	material_helper.set_excavation_preview(cells)
	if cells.is_empty():
		if excavation_preview_lining != null:
			excavation_preview_lining.visible = false
			excavation_preview_lining.mesh = null
		return
	if excavation_preview_lining == null:
		excavation_preview_lining = MeshInstance3D.new()
		excavation_preview_lining.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		excavation_preview_lining.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
		add_child(excavation_preview_lining)
	# Greedy terrain meshes omit buried faces. Supply only the newly exposed
	# neighbors so the cutout shows a cavity, not a hole through the world.
	excavation_preview_lining.mesh = StairExcavationMeshScript.build(world, cells)
	excavation_preview_lining.material_override = get_block_material()
	excavation_preview_lining.visible = true


func set_drag_preview_entries(entries: Array, mode: int) -> void:
	if overlay_renderer == null:
		return
	overlay_renderer.set_drag_preview_entries(entries, mode)


func clear_drag_preview() -> void:
	if overlay_renderer == null:
		return
	overlay_renderer.clear_drag_preview()
#endregion


#region Render Height
func update_render_height(old_y: int, new_y: int) -> int:
	if world == null:
		return 0
	var bounds := world.get_render_height_bounds()
	var anchor := world.get_render_height_anchor()
	return queue_render_height_update(old_y, new_y, anchor, bounds["min_x"], bounds["max_x"], bounds["min_z"], bounds["max_z"])

func update_render_height_in_range(old_y: int, new_y: int, min_x: int, max_x: int, min_z: int, max_z: int) -> int:
	if world == null:
		return 0
	if min_x > max_x or min_z > max_z:
		return 0
	var anchor := world.get_render_height_anchor()
	return queue_render_height_update(old_y, new_y, anchor, min_x, max_x, min_z, max_z)
#endregion


#region Chunk Queries
func is_chunk_built(coord: Vector3i) -> bool:
	return chunk_cache.is_chunk_built(coord)
#endregion


#region Debug Stats
func get_overlay_debug_stats() -> Dictionary:
	if overlay_renderer == null:
		return {}
	return overlay_renderer.get_overlay_debug_stats()
#endregion
