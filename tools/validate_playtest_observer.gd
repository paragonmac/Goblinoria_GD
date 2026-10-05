extends SceneTree
## Headless observer contracts. This does not launch the game or advance a world.

const ObserverScript = preload("res://scripts/playtest/playtest_observer.gd")

class FakeNode:
	extends RefCounted
	var visible := true
	var mesh = {"surfaces": 1}

	func _init() -> void:
		set_meta("diagnostics_mesh_revision", 1)

	func is_inside_tree() -> bool:
		return true


class FakeCache:
	extends RefCounted
	var node

	func get_chunk(_coord: Vector3i):
		return node


class FakeChunk:
	extends RefCounted
	var generated := true
	var mesh_revision := 1


class FakeRenderer:
	extends RefCounted
	var chunk_cache := FakeCache.new()
	var overlay_renderer = null
	var mesh_scheduler = null
	var visibility := {"requested_sequence": 1, "accepted_sequence": 1, "applied_sequence": 1,
		"application_pending": false, "requested_view_pending": false, "epoch": 1,
		"applied_epoch": 1, "mixed_view": false}

	func get_visibility_snapshot() -> Dictionary:
		return visibility.duplicate(true)


class FakeWorld:
	extends RefCounted
	var renderer := FakeRenderer.new()
	var chunk = FakeChunk.new()
	var chunks_available := true

	func get_chunk(_coord: Vector3i):
		return chunk if chunks_available else null

	func world_to_chunk_coords(x: int, y: int, z: int) -> Vector3i:
		return Vector3i(floori(float(x) / 8.0), floori(float(y) / 8.0), floori(float(z) / 8.0))


class FakeService:
	extends RefCounted
	var world_epoch := 1


class FakeInspector:
	extends RefCounted
	var service
	var frame := 10
	var view := "stable-view"

	func capture_snapshot() -> Dictionary:
		return {"metadata": {"world_epoch": service.world_epoch, "frame_id": frame, "view_id": view},
			"world_data": {"fixture": true}}

	func view_id() -> String:
		return view

	func query(operation: String, args: Dictionary) -> Dictionary:
		return {"operation": operation, "epoch": args.get("world_epoch", -1), "pos": args.get("pos"), "id": args.get("id")}


class FakeDiagnostics:
	var service := FakeService.new()
	var inspector := FakeInspector.new()
	var _focused := true

	func _init() -> void:
		inspector.service = service


class FakeMain:
	extends RefCounted
	var diagnostics_controller := FakeDiagnostics.new()
	var world := FakeWorld.new()
	var menu_open := false
	var loading_active := false
	var input_state = null


class FakeControl:
	extends RefCounted
	var ready := true
	var simulation_steps := 42
	var scenario := {}
	var run_id := "fixture-run"
	var session_id := "fixture-session"

	func snapshot() -> Dictionary:
		return {"ready": ready, "simulation_steps": simulation_steps, "scenario": scenario,
			"run_id": run_id, "session_id": session_id}


var failures: Array[String] = []
var checks := 0
var root_path := ""


func _init() -> void:
	_run.call_deferred()


func _run() -> void:
	var temporary := OS.get_environment("TEMP")
	if temporary.is_empty():
		temporary = OS.get_cache_dir()
	root_path = temporary.path_join("goblinoria-playtest-observer-validation-%s" % Time.get_ticks_usec())
	DirAccess.make_dir_recursive_absolute(root_path)
	var main := FakeMain.new()
	var control := FakeControl.new()
	var observer = ObserverScript.new()
	observer.initialize(main, control, root_path)
	_expect(observer.writer.root_path == root_path.path_join("observations"), "default run root configures observations writer")
	var receipt: Dictionary = observer.request({"label": "default readiness"})
	_expect(receipt.has("operation_id") and receipt.state == "pending" and not receipt.has("error"), "default request has stable receipt fields")
	var steps := control.simulation_steps
	observer.tick()
	_expect(control.simulation_steps == steps, "observation tick does not advance simulation")
	var pending := observer.get_pending()
	_expect(pending.operation_id == receipt.operation_id, "pending operation is addressable")
	observer.cancel(receipt.operation_id)
	_expect(observer.status(receipt.operation_id).state == "cancelled", "pending operation can be cancelled")

	var stale := ObserverScript.new()
	stale.initialize(main, control, root_path.path_join("stale"))
	var stale_receipt: Dictionary = stale.request({"label": "stale epoch"})
	main.diagnostics_controller.service.world_epoch = 2
	stale.tick()
	var stale_status := stale.status(stale_receipt.operation_id)
	_expect(stale_status.readiness.unmet.has("world_epoch_stable"), "stale epoch remains an unmet readiness check")
	stale.cancel(stale_receipt.operation_id)
	stale.shutdown()
	main.diagnostics_controller.service.world_epoch = 1

	var mesh := ObserverScript.new()
	mesh.initialize(main, control, root_path.path_join("mesh"))
	var mesh_receipt: Dictionary = mesh.request({"label": "stale mesh", "chunks": [[0, 0, 0]]})
	main.world.chunk.mesh_revision = 2
	mesh.tick()
	var mesh_status := mesh.status(mesh_receipt.operation_id)
	_expect(mesh_status.readiness.unmet.has("geometry_ready"), "relevant mesh revision change remains unmet")
	mesh.cancel(mesh_receipt.operation_id)
	mesh.shutdown()

	var unrelated := ObserverScript.new()
	unrelated.initialize(main, control, root_path.path_join("unrelated"))
	var unrelated_receipt: Dictionary = unrelated.request({"label": "unrelated mesh"})
	main.world.chunk.mesh_revision = 3
	unrelated.tick()
	var unrelated_status := unrelated.status(unrelated_receipt.operation_id)
	_expect(bool(unrelated_status.readiness.get("geometry", {}).get("ready", false)), "unrequested mesh revision does not block observation")
	unrelated.cancel(unrelated_receipt.operation_id)
	unrelated.shutdown()
	main.world.chunk.mesh_revision = 1

	var cancel_write := ObserverScript.new()
	cancel_write.initialize(main, control, root_path.path_join("cancel-write"))
	var cancel_receipt: Dictionary = cancel_write.request({"label": "cancel writer"})
	cancel_write.tick()
	cancel_write.tick()
	var cancel_pending := cancel_write.status(cancel_receipt.operation_id)
	_expect(cancel_pending.state == "writing", "ready observation enters one writer state")
	cancel_write.cancel(cancel_receipt.operation_id)
	for _i in range(60):
		cancel_write.tick()
		await process_frame
		if cancel_write.status(cancel_receipt.operation_id).get("state", "") in ["complete", "failed", "cancelled"]:
			break
	var cancel_status := cancel_write.status(cancel_receipt.operation_id)
	_expect(cancel_status.state == "cancelled" and bool(cancel_status.get("artifacts_complete", false)), "writer cancellation finishes its owned artifacts")
	cancel_write.shutdown()

	var no_geometry := ObserverScript.new()
	no_geometry.initialize(main, control, root_path.path_join("geometry"))
	main.world.chunks_available = false
	var geometry_receipt: Dictionary = no_geometry.request({"label": "missing geometry", "chunks": [[0, 0, 0]]})
	no_geometry.tick()
	var geometry_status := no_geometry.status(geometry_receipt.operation_id)
	_expect(geometry_status.readiness.unmet.has("geometry_ready"), "missing relevant geometry stays unmet")
	no_geometry.cancel(geometry_receipt.operation_id)
	no_geometry.shutdown()
	main.world.chunks_available = true

	var timed := ObserverScript.new()
	timed.initialize(main, control, root_path.path_join("timeout"))
	var timeout_receipt: Dictionary = timed.request({"label": "timeout evidence", "chunks": [[0, 0, 0]]})
	timed._active.deadline_usec = Time.get_ticks_usec() - 1
	for _i in range(60):
		timed.tick()
		await process_frame
		if timed.status(timeout_receipt.operation_id).get("state", "") in ["complete", "failed", "cancelled"]:
			break
	var timeout_status := timed.status(timeout_receipt.operation_id)
	_expect(timeout_status.state == "failed" and timeout_status.error == "render_readiness_timeout", "readiness timeout preserves evidence while reporting an acceptance failure")
	_expect(timeout_status.readiness.label == "notready" and timeout_status.readiness.unmet.has("geometry_ready"), "timeout preserves notready label and unmet checks")
	_expect(bool(timeout_status.get("artifacts_complete", false)), "readiness timeout finalizes the evidence bundle")
	_expect(timeout_status.paths.has("manifest") and timeout_status.paths.has("snapshot"), "completed observer exposes bundle paths")
	timed.shutdown()

	if failures.is_empty():
		print("Playtest observer contracts OK (%d checks); fixtures: %s" % [checks, root_path])
		quit(0)
	else:
		for failure in failures:
			push_error(failure)
		quit(1)


func _expect(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)
