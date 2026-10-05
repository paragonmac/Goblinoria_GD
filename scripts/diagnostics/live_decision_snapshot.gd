extends RefCounted
## Live field snapshots, not inferred decisions. Never expire exclusions, prune
## waiters, evaluate routes/filters, or generate terrain while inspecting state.

const MAX_ENTRIES := 32


static func worker_snapshot(worker) -> Dictionary:
	if not is_instance_valid(worker):
		return {}
	var data := {
		"worker_id": worker.worker_id,
		"instance_id": worker.get_instance_id(),
		"inside_tree": worker.is_inside_tree(),
		"visible": worker.visible,
		"visible_in_tree": worker.is_visible_in_tree(),
		"role_id": worker.role_id,
		"work_priorities": worker.get_work_configuration(),
		"state": worker.state,
		"current_task_id": worker.current_task_id,
		"position": worker.position,
		"block_coord": worker.get_block_coord() if worker.position.is_finite() else null,
		"fall_target_y": worker.fall_target_y,
		"target_pos": worker.target_pos,
		"movement_intent": worker.movement_intent,
		"path_length": worker.path.size(),
		"path_index": worker.path_index,
		"path_segment_validated": worker.path_segment_validated,
		"assist_task_id": worker.assist_task_id,
		"assist_goal": worker.assist_goal,
		"work_timer": worker.work_timer,
		"idle_timer": worker.idle_timer,
		"task_search_timer": worker.task_search_timer,
		"waiting_repath_timer": worker.waiting_repath_timer,
		"carried_material_id": worker.carried_material_id,
		"carried_count": worker.carried_count,
		"carried_source_item_id": worker.carried_source_item_id,
	}
	var world = worker.get_parent()
	if world is World and data.block_coord != null:
		data["terrain_support"] = {
			"cell": _loaded_cell(world, data.block_coord),
			"below": _loaded_cell(world, data.block_coord + Vector3i.DOWN),
			"render_level": world.top_render_y,
			"level_visible": world.is_visible_at_level(worker.position.y),
		}
	var manager = world.get("task_manager") if world != null else null
	if manager != null:
		data["auction"] = _auction_snapshot(manager)
		data["pending_assist_path"] = _request_snapshot(manager.assist_requests_by_worker.get(worker.worker_id, {}))
		data["pending_haul_path"] = _request_snapshot(manager.haul_path_requests_by_worker.get(worker.worker_id, {}))
	return data


static func _loaded_cell(world: World, pos: Vector3i) -> Dictionary:
	# Raw evidence only: do not generate terrain or re-run movement decisions.
	var chunk := world.get_chunk(world.world_to_chunk_coords(pos.x, pos.y, pos.z))
	var known := chunk != null and chunk.generated
	var data := {"pos": pos, "loaded": chunk != null, "generated": known, "block_id": null}
	if known and world.is_block_coord_valid(pos.x, pos.y, pos.z):
		var local := world.chunk_to_local_coords(pos.x, pos.y, pos.z)
		data.block_id = int(chunk.blocks[world.chunk_index(local.x, local.y, local.z)])
	return data


static func task_snapshot(task) -> Dictionary:
	if task == null:
		return {}
	var exclusions: Array = []
	for worker_id in task.unreachable_workers:
		if exclusions.size() >= MAX_ENTRIES:
			break
		exclusions.append({"worker_id": int(worker_id), "marked_msec": int(task.unreachable_workers[worker_id])})
	var haul: Dictionary = {}
	for key in ["item_id", "stockpile_id"]:
		if task.data.has(key):
			haul[key] = int(task.data[key])
	if task.data.has("stage"):
		haul["stage"] = str(task.data["stage"]).left(64)
	if typeof(task.data.get("destination")) == TYPE_VECTOR3I:
		haul["destination"] = task.data["destination"]
	var data := {
		"task_id": task.id,
		"pos": task.pos,
		"type": task.type,
		"status": task.status,
		"accessibility": task.accessibility,
		"accessibility_updated_msec": task.accessibility_updated_msec,
		"block_reason": task.block_reason,
		"retry_due_msec": task.retry_due_msec,
		"material": task.material,
		"assigned_worker_id": task.assigned_worker.worker_id if is_instance_valid(task.assigned_worker) else -1,
		"unreachable_workers": exclusions,
		"unreachable_worker_count": task.unreachable_workers.size(),
		"unreachable_workers_truncated": task.unreachable_workers.size() > exclusions.size(),
		"data": haul,
	}
	var world = task.diagnostics_world.get_ref() if task.diagnostics_world != null else null
	var manager = world.get("task_manager") if world != null else null
	if manager != null:
		data["accessibility_check_pending"] = manager.pending_accessibility_set.has(task.id)
		data["path_retry_scheduled_msec"] = int(manager.path_retry_due_by_task.get(task.id, 0))
		data["auction"] = _auction_snapshot(manager) if manager.assignment_task_id == task.id else {}
	return data


static func item_snapshot(item: Dictionary) -> Dictionary:
	if item.is_empty():
		return {}
	return {
		"id": int(item.get("id", -1)),
		"material_id": int(item.get("material_id", 0)),
		"count": int(item.get("count", 0)),
		"pos": item.get("pos", Vector3i.ZERO),
		"reserved_by_task_id": int(item.get("reserved_by_task_id", -1)),
		"stored_stockpile_id": int(item.get("stored_stockpile_id", -1)),
		"is_carried": bool(item.get("is_carried", false)),
	}


static func stockpile_snapshot(store, pos: Vector3i) -> Dictionary:
	if store == null:
		return {}
	var stockpile_id := int(store.cells.get(pos, -1))
	var stockpile: Dictionary = store.stockpiles.get(stockpile_id, {})
	var allowed: Dictionary = {}
	var overrides: Dictionary = {}
	var source_categories: Dictionary = stockpile.get("allowed_categories", {})
	for category in source_categories:
		if allowed.size() >= MAX_ENTRIES:
			break
		allowed[str(category)] = bool(source_categories[category])
	var source_overrides: Dictionary = stockpile.get("material_overrides", {})
	for material_id in source_overrides:
		if overrides.size() >= MAX_ENTRIES:
			break
		overrides[str(material_id)] = bool(source_overrides[material_id])
	return {
		"pos": pos,
		"stockpile_id": stockpile_id,
		"name": store.display_name(stockpile_id),
		"exists": not stockpile.is_empty(),
		"cell_capacity": store.BASE_CELL_CAPACITY,
		"cell_count": stockpile.get("cells", []).size(),
		"allowed_categories": allowed,
		"allowed_categories_truncated": source_categories.size() > allowed.size(),
		"material_overrides": overrides,
		"material_override_count": source_overrides.size(),
		"material_overrides_truncated": source_overrides.size() > overrides.size(),
	}


static func _auction_snapshot(manager) -> Dictionary:
	if manager.assignment_task_id < 0:
		return {}
	var bids: Array = []
	for bid: Dictionary in manager.assignment_bids:
		if bids.size() >= MAX_ENTRIES:
			break
		bids.append({"worker_id": int(bid.get("worker_id", -1)), "path_length": int(bid.get("path_length", 0))})
	var pending: Array = []
	for job_id in manager.assignment_pending_jobs:
		if pending.size() >= MAX_ENTRIES:
			break
		var worker = manager.assignment_pending_jobs[job_id]
		pending.append({"job_id": int(job_id), "worker_id": worker.worker_id if is_instance_valid(worker) else -1})
	return {
		"task_id": manager.assignment_task_id,
		"auction_id": manager.assignment_auction_id,
		"candidate_count": manager.assignment_workers.size(),
		"next_candidate_index": manager.assignment_worker_index,
		"bid_count": manager.assignment_bids.size(),
		"bids": bids,
		"bids_truncated": manager.assignment_bids.size() > bids.size(),
		"pending_job_count": manager.assignment_pending_jobs.size(),
		"pending_jobs": pending,
		"pending_jobs_truncated": manager.assignment_pending_jobs.size() > pending.size(),
	}


static func _request_snapshot(request: Dictionary) -> Dictionary:
	if request.is_empty():
		return {}
	var data := {
		"request_id": int(request.get("request_id", -1)),
		"job_id": int(request.get("job_id", -1)),
		"task_id": int(request.get("task_id", -1)),
		"goal_count": request.get("goal_task_ids", {}).size(),
	}
	if typeof(request.get("destination")) == TYPE_VECTOR3I:
		data["destination"] = request["destination"]
	return data
