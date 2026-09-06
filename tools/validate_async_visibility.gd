extends SceneTree
## Real visibility-worker integration and forced fallback; no graphical playtest.
## Work counts are deterministic. The 1 ms budget is not a wall-clock benchmark.

const MenuFixture = preload("res://tools/validate_context_menu.gd")
const PhaseFixture = preload("res://tools/validate_passive_gameplay_profiling.gd")
const WAIT_MS := 5000


class ProbeRenderer extends WorldRenderer:
	var visibility_events: Array = []
	var pump_calls := 0
	var stepped_total := 0
	var last_pump: Array = []

	func _set_chunk_visibility(coord: Vector3i, value: bool) -> void:
		visibility_events.append([coord, value])
		super._set_chunk_visibility(coord, value)

	func pump_visibility(max_ms: float = 1.0, max_steps: int = 256) -> int:
		pump_calls += 1
		var stepped: int = super.pump_visibility(max_ms, max_steps)
		stepped_total += stepped
		last_pump = [max_ms, max_steps, stepped]
		return stepped


class BareWorld extends World:
	func _ready() -> void:
		pass


class VisibilityMain extends MenuFixture.MenuMain:
	func _ready() -> void:
		super._ready()
		var probe := ProbeRenderer.new()
		probe.use_async_meshing = false
		world.add_child(probe)
		world.renderer = probe
		probe.initialize(world)
		probe.visibility_scheduler.force_start_failure = true
		_setup_debug_overlay()
		debug_overlay.hide()
		set_process(false)


var checks := 0
var failures: Array[String] = []


func _init() -> void:
	_run.call_deferred()


func _check(ok: bool, message: String) -> void:
	checks += 1
	if not ok:
		failures.append(message)
		push_error(message)


func _world(fallback: bool) -> BareWorld:
	var world := BareWorld.new()
	root.add_child(world)
	world._init_ramp_lookup()
	world.block_registry.load_from_csv(World.BLOCK_DATA_PATH)
	world.top_render_y = 8
	var renderer := ProbeRenderer.new()
	renderer.use_async_meshing = false
	world.add_child(renderer)
	world.renderer = renderer
	renderer.initialize(world)
	# Must be set before the first request: visibility starts lazily.
	renderer.visibility_scheduler.force_start_failure = fallback
	return world


func _pump(renderer: ProbeRenderer, limit: int = 256) -> int:
	var before: Dictionary = renderer.get_visibility_snapshot()
	var calls := renderer.visibility_events.size()
	var stepped := renderer.pump_visibility(1.0, limit)
	var after: Dictionary = renderer.get_visibility_snapshot()
	_check(stepped >= 0 and stepped <= limit, "Pump respects inclusive step cap %d" % limit)
	_check(renderer.visibility_events.size() - calls <= stepped,
		"Every visibility application is charged to the pump")
	if before.application_pending and before.epoch == after.epoch \
			and before.accepted_sequence == after.accepted_sequence:
		_check(before.application_remaining - after.application_remaining <= stepped,
			"Remaining application scans cannot advance beyond charged steps")
	if after.fallback:
		_check(after.processed_steps - before.processed_steps <= stepped,
			"Fallback candidate scans share the pump step budget")
	for key in ["pending", "in_flight", "result_pending"]:
		_check(after[key] >= 0 and after[key] <= 1, "Scheduler " + key + " stays bounded")
	return stepped


func _settle(renderer: ProbeRenderer, label: String) -> bool:
	var deadline := Time.get_ticks_msec() + WAIT_MS
	while Time.get_ticks_msec() < deadline:
		_pump(renderer)
		var state: Dictionary = renderer.get_visibility_snapshot()
		if state.initialized and not state.application_pending \
				and state.applied_sequence == state.requested_sequence:
			_check(state.accepted_sequence == state.applied_sequence,
				label + ": accepted and applied sequence converge")
			_check(state.application_remaining == 0 and not state.mixed_view,
				label + ": convergence leaves no mixed application")
			return true
		OS.delay_msec(1)
	_check(false, label + ": timed out: " + str(renderer.get_visibility_snapshot()))
	return false


func _range_set(min_x: int, max_x: int, min_z: int, max_z: int) -> Dictionary:
	var result := {}
	for x in range(min_x, max_x + 1):
		for z in range(min_z, max_z + 1):
			result[Vector3i(x, 0, z)] = true
	return result


func _same_members(a: Dictionary, b: Dictionary) -> bool:
	if a.size() != b.size():
		return false
	for coord in a:
		if not b.has(coord):
			return false
	return true


func _run() -> void:
	for fallback in [false, true]:
		print("Async visibility mode: ", "forced fallback" if fallback else "worker")
		_test_enqueue_and_stationary(fallback)
		_test_soft_motion(fallback)
		_test_initial_reconcile_cancel(fallback)
		_test_partial_cancel_and_clear(fallback)
		_test_hard_view_changes(fallback)
		_test_mesh_handoffs(fallback)
	_test_main_pump()
	await process_frame
	if failures.is_empty():
		print("Async visibility integration OK (%d checks)" % checks)
		quit(0)
	else:
		push_error("Async visibility integration FAILED (%d/%d)" % [failures.size(), checks])
		quit(1)


func _test_enqueue_and_stationary(fallback: bool) -> void:
	var world := _world(fallback)
	var renderer: ProbeRenderer = world.renderer
	var before: Dictionary = renderer.get_visibility_snapshot()
	for key in ["epoch", "requested_sequence", "accepted_sequence", "applied_sequence",
			"application_pending", "application_remaining", "initialized", "mixed_view"]:
		_check(before.has(key), "Visibility snapshot exposes " + key)
	renderer.update_render_zone(-16, 15, -16, 15, 0, 0)
	# Even if the worker finishes immediately, acceptance/application requires a pump.
	if not fallback:
		var deadline := Time.get_ticks_msec() + WAIT_MS
		while renderer.get_visibility_snapshot().result_pending == 0 and Time.get_ticks_msec() < deadline:
			OS.delay_msec(1)
	var queued: Dictionary = renderer.get_visibility_snapshot()
	_check(queued.fallback == fallback, "Requested worker/fallback execution mode is active")
	_check(queued.started_count == 0 if fallback else queued.started_count > 0,
		"Only the real worker can start culling before the first pump")
	_check(fallback or queued.result_pending == 1, "Real worker publishes without main-thread culling")
	_check(queued.requested_sequence > before.requested_sequence, "Request allocates a sequence")
	_check(queued.accepted_sequence == before.accepted_sequence
		and queued.applied_sequence == before.applied_sequence,
		"Enqueue does not synchronously accept or apply")
	_check(renderer.visibility_events.is_empty() and renderer.render_zone_visible.is_empty(),
		"Enqueue leaves effective membership and scene untouched")
	_check(_pump(renderer, 0) == 0, "Zero steps performs no work")
	_check(renderer.pump_visibility(0.0, 256) == 0, "Zero time performs no work")
	if _settle(renderer, "Initial large view"):
		_check(_same_members(renderer.render_zone_visible, _range_set(-16, 15, -16, 15)),
			"Stationary large view converges exactly")
		var calls := renderer.visibility_events.size()
		var sequence: int = renderer.get_visibility_snapshot().applied_sequence
		for i in range(12):
			_check(_pump(renderer) == 0, "Stationary pump is idle")
		_check(renderer.visibility_events.size() == calls, "Stationary pump makes no scene calls")
		_check(renderer.get_visibility_snapshot().applied_sequence == sequence,
			"Stationary pump does not invent requests")
		# Most members are unchanged; both those scans and exits consume steps.
		var steps := renderer.stepped_total
		renderer.update_render_zone(-16, 14, -16, 15, 0, 0)
		if _settle(renderer, "Mostly unchanged membership scan"):
			_check(renderer.stepped_total - steps >= 1024,
				"Unchanged membership scans count toward max_steps")
			_check(_same_members(renderer.render_zone_visible, _range_set(-16, 14, -16, 15)),
				"Budgeted scan retains overlapping members and removes exits")
	_check(world.chunks.is_empty(), "Visibility does not generate terrain")
	world.free()


func _test_soft_motion(fallback: bool) -> void:
	var world := _world(fallback)
	var renderer: ProbeRenderer = world.renderer
	renderer.update_render_zone(-16, 15, -16, 15, 0, 0)
	var epoch: int = renderer.get_visibility_snapshot().epoch
	var accepted_while_newer := false
	var applied_while_newer := false
	var deadline := Time.get_ticks_msec() + WAIT_MS
	var iteration := 0
	while Time.get_ticks_msec() < deadline and not applied_while_newer:
		# Different bounds, same epoch, including updates while an application is pending.
		renderer.update_render_zone(-16 + iteration % 2, 15, -16, 15, 0, 0)
		_pump(renderer)
		var state: Dictionary = renderer.get_visibility_snapshot()
		accepted_while_newer = accepted_while_newer or (state.accepted_sequence > 0
			and state.accepted_sequence < state.requested_sequence)
		applied_while_newer = state.applied_sequence > 0 and state.applied_sequence < state.requested_sequence
		iteration += 1
		OS.delay_msec(1)
	_check(accepted_while_newer, "Soft motion accepts completed work despite newer requests")
	_check(applied_while_newer, "Soft motion does not starve an accepted application")
	_check(renderer.get_visibility_snapshot().epoch == epoch, "Soft bounds motion preserves epoch")
	renderer.update_render_zone(2, 4, 3, 5, 0, 0)
	if _settle(renderer, "Motion stops"):
		_check(_same_members(renderer.render_zone_visible, _range_set(2, 4, 3, 5)),
			"Stopping converges to the latest request")
	world.free()


func _test_initial_reconcile_cancel(fallback: bool) -> void:
	var world := _world(fallback)
	var renderer: ProbeRenderer = world.renderer
	# Real cache nodes predate the first accepted view. Shared geometry keeps
	# this reconciliation fixture independent of terrain generation/meshing cost.
	var mesh := BoxMesh.new()
	var startup := _range_set(-16, 15, 0, 15)
	for coord in startup:
		var node: MeshInstance3D = renderer.chunk_cache.ensure_chunk(coord, World.CHUNK_SIZE)
		node.mesh = mesh
		node.visible = true
	# Leave stable-slot tombstones; these scans must consume the same budget.
	for x in range(-16, -12):
		var coord := Vector3i(x, 0, 0)
		renderer.clear_chunk(coord)
		startup.erase(coord)
	renderer.update_render_zone(0, 0, -1, -1, 0, 0)
	var initial_visible := true
	for coord in startup:
		initial_visible = initial_visible and renderer.chunk_cache.get_chunk(coord).visible
	_check(initial_visible, "First request leaves all preexisting meshes untouched")
	var hidden: Array = []
	var deadline := Time.get_ticks_msec() + WAIT_MS
	while Time.get_ticks_msec() < deadline:
		var calls := renderer.visibility_events.size()
		_pump(renderer, 1)
		for index in range(calls, renderer.visibility_events.size()):
			var event: Array = renderer.visibility_events[index]
			if not event[1] and startup.has(event[0]):
				hidden.append(event[0])
		if not hidden.is_empty():
			break
		OS.delay_msec(1)
	_check(not hidden.is_empty() and hidden.size() < startup.size(),
		"One-step first reconciliation hides only part of preexisting nodes")
	var partial: Dictionary = renderer.get_visibility_snapshot()
	_check(partial.application_pending and partial.application_remaining > 0,
		"First reconciliation remains pending after a bounded partial hide")
	var effective := renderer.render_zone_visible.duplicate()
	var node_visibility := {}
	for coord in startup:
		node_visibility[coord] = renderer.chunk_cache.get_chunk(coord).visible
	renderer.invalidate_render_zone()
	_check(renderer.get_visibility_snapshot().epoch > partial.epoch
		and not renderer.get_visibility_snapshot().application_pending,
		"Hard cancellation interrupts first reconciliation")
	var preserved := _same_members(effective, renderer.render_zone_visible)
	for coord in startup:
		preserved = preserved and renderer.chunk_cache.get_chunk(coord).visible == node_visibility[coord]
	_check(preserved, "First-reconcile cancellation preserves actual partial node state")
	if not hidden.is_empty():
		var target: Vector3i = hidden[0]
		renderer.update_render_zone(target.x, target.x, target.z, target.z, 0, 0)
		if _settle(renderer, "Rebase interrupted first reconciliation"):
			var correct := renderer.render_zone_visible.size() == 1 and renderer.render_zone_visible.has(target)
			for coord in startup:
				correct = correct and renderer.chunk_cache.get_chunk(coord).visible == (coord == target)
			_check(correct, "Rebase restores a hidden target and finishes all startup-node reconciliation")
	# clear_chunk() detached pooled nodes above; explicitly release those too.
	renderer.chunk_cache.clear()
	world.free()


func _test_partial_cancel_and_clear(fallback: bool) -> void:
	var world := _world(fallback)
	var renderer: ProbeRenderer = world.renderer
	var old_set := _range_set(-8, -1, 0, 7)
	renderer.update_render_zone(-8, -1, 0, 7, 0, 0)
	if not _settle(renderer, "Before partial application"):
		world.free()
		return
	renderer.visibility_events.clear()
	renderer.update_render_zone(0, 7, 0, 7, 0, 0)
	var partial := false
	var deadline := Time.get_ticks_msec() + WAIT_MS
	while Time.get_ticks_msec() < deadline:
		_pump(renderer, 1)
		if renderer.render_zone_visible.size() > old_set.size():
			partial = true
			break
		OS.delay_msec(1)
	_check(partial, "One-step pumping exposes partial application")
	var effective := renderer.render_zone_visible.duplicate()
	for coord in old_set:
		_check(effective.has(coord), "Shows precede hides of old membership")
	var state: Dictionary = renderer.get_visibility_snapshot()
	_check(state.application_pending and state.mixed_view and state.application_remaining > 0,
		"Partial application is visible in the snapshot")
	# Handoffs during a mixed view must use the incrementally effective set.
	var partial_coords: Array = [Vector3i(-1, 0, 0)]
	for coord in _range_set(0, 7, 0, 7):
		if effective.has(coord) and partial_coords.size() == 1:
			partial_coords.append(coord)
	for coord in _range_set(0, 7, 0, 7):
		if not effective.has(coord):
			partial_coords.append(coord)
			break
	_check(partial_coords.size() == 3, "Partial fixture includes old, newly shown, and not-yet-shown coords")
	for coord in partial_coords:
		var chunk := world.ensure_chunk(coord)
		chunk.generated = true
		chunk.blocks[WorldChunkSpace.chunk_index(1, 1, 1)] = World.BLOCK_ID_GRANITE
		renderer.regenerate_chunk(coord.x, coord.y, coord.z)
		_check(renderer.chunk_cache.get_chunk(coord).visible == effective.has(coord),
			"Mid-application sync handoff follows effective membership")
	var calls := renderer.visibility_events.size()
	renderer.invalidate_render_zone()
	var cancelled: Dictionary = renderer.get_visibility_snapshot()
	_check(cancelled.epoch > state.epoch and not cancelled.application_pending,
		"Hard invalidation advances epoch and cancels application")
	_check(_same_members(renderer.render_zone_visible, effective)
		and renderer.visibility_events.size() == calls, "Cancellation preserves effective partial state")
	for coord in effective:
		_check(renderer._is_chunk_in_current_render_zone(coord), "Handoff membership retains partial state")
	for coord in partial_coords:
		var chunk := world.get_chunk(coord)
		var entry := renderer.export_persistent_mesh_cache_entry(coord, World.CHUNK_SIZE - 1)
		renderer.clear_chunk(coord)
		renderer._apply_mesh_entry(coord, entry, chunk)
		_check(renderer.chunk_cache.get_chunk(coord).visible == effective.has(coord),
			"Post-cancel cache handoff preserves effective partial visibility")
	renderer.visibility_events.clear()
	renderer.update_render_zone(10, 11, 0, 1, 0, 0)
	if _settle(renderer, "Rebase from partial state"):
		_check(_same_members(renderer.render_zone_visible, _range_set(10, 11, 0, 1)),
			"Rebase removes both old members and cancelled partial additions")
		var hiding := false
		for event in renderer.visibility_events:
			if not event[1]:
				hiding = true
			else:
				_check(not hiding, "Entire show phase precedes the first hide")
	# Leave a real old-world result queued or in flight when clearing.
	renderer.update_render_zone(-16, 15, -16, 15, 0, 0)
	var clear_epoch: int = renderer.get_visibility_snapshot().epoch
	renderer.clear_chunks()
	world.chunks.clear()
	var cleared: Dictionary = renderer.get_visibility_snapshot()
	_check(cleared.epoch > clear_epoch and not cleared.initialized
		and not cleared.application_pending and renderer.render_zone_visible.is_empty(),
		"World clear resets membership and invalidates old work")
	_check(renderer.diagnostics_render_bounds.is_empty(), "World clear resets applied diagnostics bounds")
	_check(renderer.chunk_cache.get_keys().is_empty(), "World clear removes partial-state mesh nodes")
	for i in range(20):
		_pump(renderer)
		OS.delay_msec(1)
	_check(renderer.render_zone_visible.is_empty() and not renderer.get_visibility_snapshot().initialized,
		"Late old-world results cannot initialize the cleared renderer")
	renderer.update_render_zone(1, 0, 0, 0, 0, 0)
	if _settle(renderer, "Empty replacement world"):
		_check(not renderer._is_chunk_in_current_render_zone(Vector3i.ZERO),
			"Initialized empty view does not fall back to startup visibility")
	world.free()


func _test_hard_view_changes(fallback: bool) -> void:
	var world := _world(fallback)
	var renderer: ProbeRenderer = world.renderer
	var viewport := SubViewport.new()
	viewport.size = Vector2i(800, 600)
	root.add_child(viewport)
	var camera := Camera3D.new()
	viewport.add_child(camera)
	camera.position = Vector3(0, 30, 40)
	camera.look_at(Vector3.ZERO)
	renderer.update_render_zone(-4, 4, -4, 4, 0, 0, camera)
	_settle(renderer, "Camera initial view")
	var epoch: int = renderer.get_visibility_snapshot().epoch
	camera.position.x += 0.1
	renderer.update_render_zone(-4, 4, -4, 4, 0, 0, camera)
	_check(renderer.get_visibility_snapshot().epoch == epoch, "Camera translation is soft motion")
	world.top_render_y += 1
	_pump(renderer)
	_check(renderer.get_visibility_snapshot().epoch > epoch, "Pump detects render-level hard change")
	renderer.update_render_zone(-4, 4, -4, 4, 0, 0, camera)
	_settle(renderer, "Changed render level")
	epoch = renderer.get_visibility_snapshot().epoch
	viewport.size = Vector2i(960, 600)
	_pump(renderer)
	_check(renderer.get_visibility_snapshot().epoch > epoch, "Pump detects viewport resize without a request")
	var replacement := Camera3D.new()
	viewport.add_child(replacement)
	replacement.transform = camera.transform
	epoch = renderer.get_visibility_snapshot().epoch
	renderer.update_render_zone(-4, 4, -4, 4, 0, 0, replacement)
	_check(renderer.get_visibility_snapshot().epoch > epoch, "Observation detects camera identity change")
	_settle(renderer, "Replacement camera")
	world.free()
	viewport.free()


func _test_mesh_handoffs(fallback: bool) -> void:
	var world := _world(fallback)
	var renderer: ProbeRenderer = world.renderer
	var inside := Vector3i.ZERO
	var outside := Vector3i(2, 0, 0)
	for coord in [inside, outside]:
		var chunk := world.ensure_chunk(coord)
		chunk.generated = true
		chunk.blocks[WorldChunkSpace.chunk_index(1, 1, 1)] = World.BLOCK_ID_GRANITE
		renderer.regenerate_chunk(coord.x, coord.y, coord.z)
	_check(renderer.chunk_cache.get_chunk(outside).visible, "Pre-view mesh starts visible")
	renderer.update_render_zone(0, 0, 0, 0, 0, 0)
	_check(renderer.chunk_cache.get_chunk(outside).visible, "Enqueue does not hide preexisting meshes")
	_settle(renderer, "Mesh initial view")
	_check(renderer.chunk_cache.get_chunk(inside).visible and not renderer.chunk_cache.get_chunk(outside).visible,
		"First application reconciles preexisting meshes")
	for empty_view in [false, true]:
		if empty_view:
			renderer.update_render_zone(1, 0, 0, 0, 0, 0)
			_settle(renderer, "Empty mesh view")
		for coord in [inside, outside]:
			var expected: bool = not empty_view and coord == inside
			var chunk := world.get_chunk(coord)
			var entry := renderer.export_persistent_mesh_cache_entry(coord, World.CHUNK_SIZE - 1)
			var sequence: int = renderer.get_visibility_snapshot().requested_sequence
			var pooled: MeshInstance3D = renderer.chunk_cache.get_chunk(coord)
			renderer.clear_chunk(coord)
			renderer.regenerate_chunk(coord.x, coord.y, coord.z)
			_check(renderer.chunk_cache.get_chunk(coord) == pooled, "Sync handoff reuses pooled node")
			_check(pooled.visible == expected, "Sync handoff honors effective visibility")
			renderer.clear_chunk(coord)
			renderer._apply_mesh_entry(coord, entry, chunk)
			_check(renderer.chunk_cache.get_chunk(coord) == pooled and pooled.visible == expected,
				"Cached handoff resets pooled visibility")
			# Build actual worker-format arrays; do not synthesize a mesh result dictionary.
			var job := renderer._build_mesh_job(coord, chunk.mesh_revision, 8, false, false)
			var result := renderer._build_mesh_result_on_worker(job)
			_check(renderer._apply_mesh_result(result), "Actual async-format result is accepted")
			_check(pooled.visible == expected, "Async-format handoff honors effective visibility")
			# Also exercise the real mesh thread and public queue/result path.
			renderer.clear_chunk(coord)
			renderer.use_async_meshing = true
			renderer.queue_chunk_mesh_build(coord)
			var deadline := Time.get_ticks_msec() + WAIT_MS
			while renderer.has_pending_mesh_work(true) and Time.get_ticks_msec() < deadline:
				renderer.process_mesh_results(8)
				OS.delay_msec(1)
			var node: MeshInstance3D = renderer.chunk_cache.get_chunk(coord)
			_check(not renderer.has_pending_mesh_work(true) and node != null, "Real mesh worker completes")
			_check(node != null and node.visible == expected, "Real mesh worker handoff honors visibility")
			renderer.use_async_meshing = false
			_check(renderer.get_visibility_snapshot().requested_sequence == sequence,
				"Mesh handoffs do not enqueue global reculls")
	world.get_chunk(inside).blocks.fill(World.BLOCK_ID_AIR)
	renderer.regenerate_chunk(0, 0, 0)
	renderer.update_render_zone(0, 0, 0, 0, 0, 0)
	_settle(renderer, "Empty geometry enters")
	_check(not renderer.chunk_cache.get_chunk(inside).visible, "Empty mesh stays hidden inside membership")
	world.get_chunk(inside).blocks[WorldChunkSpace.chunk_index(1, 1, 1)] = World.BLOCK_ID_GRANITE
	renderer.regenerate_chunk(0, 0, 0)
	_check(renderer.chunk_cache.get_chunk(inside).visible, "New geometry appears in stationary membership")
	world.free()


func _test_main_pump() -> void:
	root.gui_embed_subwindows = true
	var scene = load("res://scenes/Main.tscn").instantiate()
	scene.set_script(VisibilityMain)
	scene.get_node("World").set_script(PhaseFixture.PhaseWorld)
	root.add_child(scene)
	var renderer: ProbeRenderer = scene.world.renderer
	for mode in ["gameplay", "menu", "loading"]:
		scene.menu_open = mode == "menu"
		scene.loading_active = mode == "loading"
		renderer.invalidate_render_zone()
		renderer.update_render_zone(-16, 15, -16, 15, 0, 0, scene.camera)
		var deadline := Time.get_ticks_msec() + WAIT_MS
		var converged := false
		while Time.get_ticks_msec() < deadline:
			var calls := renderer.pump_calls
			scene._process(0.016)
			_check(renderer.pump_calls == calls + 1,
				"Main pumps visibility exactly once with hidden overlay: " + mode)
			if renderer.pump_calls != calls + 1:
				break
			_check(renderer.last_pump[0] == 1.0 and renderer.last_pump[1] == 256
				and renderer.last_pump[2] >= 0 and renderer.last_pump[2] <= 256,
				"Main uses the bounded 1 ms / 256-step visibility pump")
			var state: Dictionary = renderer.get_visibility_snapshot()
			if state.initialized and not state.application_pending and state.applied_sequence == state.requested_sequence:
				converged = true
				break
			OS.delay_msec(1)
		_check(converged, "Actual Main frame pump converges during " + mode)
		_check(not scene.debug_overlay.visible, "Visibility work leaves debug overlay hidden")
	scene.world.task_manager.shutdown()
	scene.free()
