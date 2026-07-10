extends RefCounted
class_name MainYTransitionProfiler
## Records Y-level transition diagnostics for render-level changes.

const WorldChunkSpaceScript = preload("res://scripts/world/world_chunk_space.gd")

#region State
var world: World
var debug_overlay: DebugOverlay
#endregion


#region Setup
func initialize(world_ref: World, debug_overlay_ref: DebugOverlay = null) -> void:
	world = world_ref
	debug_overlay = debug_overlay_ref


func update_world(world_ref: World) -> void:
	world = world_ref


func set_debug_overlay(debug_overlay_ref: DebugOverlay) -> void:
	debug_overlay = debug_overlay_ref
#endregion


#region Recording
func record_transition(from_y: int, target_y: int, delta: int, blocked: bool, profile: Dictionary, snapshot_before: Dictionary, snapshot_after: Dictionary) -> void:
	var overlay := _debug_overlay()
	if overlay == null:
		return
	var row := {
		"t_ms": Time.get_ticks_msec(),
		"from_y": from_y,
		"target_y": target_y,
		"delta": delta,
		"target_chunk_y": int(profile.get("target_chunk_y", _chunk_y_for_render_y(target_y))),
		"blocked": 1 if blocked else 0,
		"mesh_total": int(profile.get("mesh_total", 0)),
		"mesh_ready_before": int(profile.get("mesh_ready_before", 0)),
		"mesh_ready_after": int(profile.get("mesh_ready_after", 0)),
		"generation_total": int(profile.get("generation_total", 0)),
		"generation_ready_before": int(profile.get("generation_ready_before", 0)),
		"generation_ready_after": int(profile.get("generation_ready_after", 0)),
		"request_ms": "%.3f" % float(profile.get("request_ms", 0.0)),
		"generation_load_ms": "%.3f" % float(profile.get("generation_load_ms", 0.0)),
		"mesh_wait_ms": "%.3f" % float(profile.get("mesh_wait_ms", 0.0)),
		"total_blocked_ms": "%.3f" % float(profile.get("total_blocked_ms", 0.0)),
		"frames_waited": int(profile.get("frames_waited", 0)),
	}
	_add_snapshot_fields(row, snapshot_before, "before")
	_add_snapshot_fields(row, snapshot_after, "after")
	row["mesh_cache_hits_delta"] = _snapshot_int(snapshot_after, "mesh_cache_hits") - _snapshot_int(snapshot_before, "mesh_cache_hits")
	row["mesh_cache_misses_delta"] = _snapshot_int(snapshot_after, "mesh_cache_misses") - _snapshot_int(snapshot_before, "mesh_cache_misses")
	row["mesh_cache_imports_delta"] = _snapshot_int(snapshot_after, "mesh_cache_imports") - _snapshot_int(snapshot_before, "mesh_cache_imports")
	row["mesh_build_ms_delta"] = "%.3f" % (_snapshot_float(snapshot_after, "mesh_build_ms") - _snapshot_float(snapshot_before, "mesh_build_ms"))
	row["mesh_upload_ms_delta"] = "%.3f" % (_snapshot_float(snapshot_after, "mesh_upload_ms") - _snapshot_float(snapshot_before, "mesh_upload_ms"))
	overlay.record_y_transition(row)
#endregion


#region Snapshots
func capture_snapshot() -> Dictionary:
	var snapshot := {
		"generator_queued": 0,
		"generator_results": 0,
		"generator_active": 0,
		"stream_build_queue": 0,
		"stream_pending": 0,
		"stream_min_y": 0,
		"stream_max_y": 0,
		"mesh_job_queue": 0,
		"mesh_result_queue": 0,
		"mesh_job_set": 0,
		"mesh_prefetch_set": 0,
		"mesh_cache_hits": 0,
		"mesh_cache_misses": 0,
		"mesh_cache_imports": 0,
		"mesh_build_ms": 0.0,
		"mesh_upload_ms": 0.0,
		"loaded_chunks": 0,
		"mem_static_mb": float(Performance.get_monitor(Performance.MEMORY_STATIC)) / 1048576.0,
	}
	if world == null:
		return snapshot
	snapshot["loaded_chunks"] = world.chunks.size()
	if world.generator != null:
		var generation_stats: Dictionary = world.generator.get_generation_stats()
		snapshot["generator_queued"] = int(generation_stats.get("queued", 0))
		snapshot["generator_results"] = int(generation_stats.get("results", 0))
		snapshot["generator_active"] = int(generation_stats.get("active", 0))
	if world.streaming != null:
		var streaming: WorldStreaming = world.streaming
		snapshot["stream_build_queue"] = streaming.chunk_build_queue.size()
		snapshot["stream_pending"] = 1 if streaming.stream_pending else 0
		if streaming.stream_min_y != streaming.DUMMY_INT:
			snapshot["stream_min_y"] = streaming.stream_min_y * World.CHUNK_SIZE
			snapshot["stream_max_y"] = ((streaming.stream_max_y + 1) * World.CHUNK_SIZE) - 1
	if world.renderer != null:
		var mesh_stats: Dictionary = world.renderer.get_mesh_work_stats()
		snapshot["mesh_job_queue"] = int(mesh_stats.get("job_queue", 0))
		snapshot["mesh_result_queue"] = int(mesh_stats.get("result_queue", 0))
		snapshot["mesh_job_set"] = int(mesh_stats.get("job_set", 0))
		snapshot["mesh_prefetch_set"] = int(mesh_stats.get("prefetch_set", 0))
		snapshot["mesh_cache_hits"] = int(mesh_stats.get("cache_hits", 0))
		snapshot["mesh_cache_misses"] = int(mesh_stats.get("cache_misses", 0))
		snapshot["mesh_cache_imports"] = int(mesh_stats.get("cache_imports", 0))
		snapshot["mesh_build_ms"] = float(mesh_stats.get("mesh_build_ms", 0.0))
		snapshot["mesh_upload_ms"] = float(mesh_stats.get("mesh_upload_ms", 0.0))
	return snapshot


func _add_snapshot_fields(row: Dictionary, snapshot: Dictionary, suffix: String) -> void:
	row["generator_queued_%s" % [suffix]] = _snapshot_int(snapshot, "generator_queued")
	row["generator_results_%s" % [suffix]] = _snapshot_int(snapshot, "generator_results")
	row["generator_active_%s" % [suffix]] = _snapshot_int(snapshot, "generator_active")
	row["stream_build_queue_%s" % [suffix]] = _snapshot_int(snapshot, "stream_build_queue")
	row["stream_pending_%s" % [suffix]] = _snapshot_int(snapshot, "stream_pending")
	row["stream_min_y_%s" % [suffix]] = _snapshot_int(snapshot, "stream_min_y")
	row["stream_max_y_%s" % [suffix]] = _snapshot_int(snapshot, "stream_max_y")
	row["mesh_job_queue_%s" % [suffix]] = _snapshot_int(snapshot, "mesh_job_queue")
	row["mesh_result_queue_%s" % [suffix]] = _snapshot_int(snapshot, "mesh_result_queue")
	row["mesh_job_set_%s" % [suffix]] = _snapshot_int(snapshot, "mesh_job_set")
	row["mesh_prefetch_set_%s" % [suffix]] = _snapshot_int(snapshot, "mesh_prefetch_set")
	row["loaded_chunks_%s" % [suffix]] = _snapshot_int(snapshot, "loaded_chunks")
	row["mem_static_mb_%s" % [suffix]] = "%.3f" % _snapshot_float(snapshot, "mem_static_mb")
#endregion


#region Helpers
func _snapshot_int(snapshot: Dictionary, key: String) -> int:
	return int(snapshot.get(key, 0))


func _snapshot_float(snapshot: Dictionary, key: String) -> float:
	return float(snapshot.get(key, 0.0))


func _chunk_y_for_render_y(render_y: int) -> int:
	if world == null:
		return 0
	return WorldChunkSpaceScript.chunk_y_for_render_y(render_y, world.world_size_y)


func _debug_overlay() -> DebugOverlay:
	return debug_overlay
#endregion
