extends SceneTree
## Display metadata contracts. No files, renderer, diagnostics, or gameplay updates.

const Model = preload("res://scripts/ui/colony_presentation_model.gd")
var failures: Array[String] = []
var checks := 0


func _init() -> void:
	_run.call_deferred()


func _run() -> void:
	_test_names_and_signals()
	_test_save_records()
	_test_presentation()
	_test_worker_assignment_presentation()
	if failures.is_empty():
		print("Stockpile names contract OK (%d checks)" % checks)
		quit(0)
	else:
		for message in failures:
			push_error(message)
		quit(1)


func _expect(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)


func _test_names_and_signals() -> void:
	var store := StockpileStore.new()
	var first := store.create_stockpile([Vector3i(1, 1, 0)])
	var second := store.create_stockpile([Vector3i(2, 1, 0)])
	store.set_category_allowed(first, "ore", false)
	store.set_material_override(first, 8, true)
	var record: Dictionary = store.stockpiles[first]
	var before := record.duplicate(true)
	var neighbor: Dictionary = store.stockpiles[second].duplicate(true)
	var cells := store.cells.duplicate()
	var events: Array[String] = []
	var hauling: Array[String] = []
	store.visual_state_changed.connect(func(reason: String): events.append(reason))
	store.haul_state_changed.connect(func(reason: String): hauling.append(reason))
	_expect(store.display_name(first) == "Stockpile %d" % first, "Default display name missing")
	_expect(store.rename_stockpile(first, "  East Ore  "), "Trimmed rename failed")
	_expect(store.display_name(first) == "East Ore" and record.name == "East Ore", "Trimmed name not stored")
	_expect(is_same(record, store.stockpiles[first]), "Rename replaced zone identity")
	before.name = "East Ore"
	_expect(record == before and store.stockpiles[second] == neighbor and store.cells == cells,
		"Rename altered cells, filters, or another stockpile")
	_expect(events == ["stockpile_renamed"] and hauling.is_empty(), "Rename must emit visual-only refresh")
	_expect(store.rename_stockpile(first, " East Ore ") and events.size() == 1,
		"Unchanged valid name must succeed without notification")
	_expect(store.rename_stockpile(second, "East Ore"), "Duplicate names must be allowed")
	_expect(store.stockpile_at(Vector3i(1, 1, 0)) == first \
		and store.stockpile_at(Vector3i(2, 1, 0)) == second, "Names became zone identities")
	var bad_names: Array[String] = ["", "   ", "two\nlines", "edge\r", "\ttab", "a".repeat(65),
		"x" + String.chr(1) + "y", "x" + String.chr(127), "x" + String.chr(159),
		"x" + String.chr(0x2028), "x" + String.chr(0x2029)]
	var signal_count := events.size()
	for value in bad_names:
		_expect(not store.rename_stockpile(first, value), "Invalid name accepted: %s" % var_to_str(value))
		_expect(store.display_name(first) == "East Ore", "Invalid name changed existing name")
	_expect(not store.rename_stockpile(999, "Missing"), "Missing zone rename accepted")
	_expect(events.size() == signal_count and hauling.is_empty(), "Rejected names emitted mutation signals")
	_expect(store.rename_stockpile(first, "x".repeat(64)), "64-character boundary rejected")
	_expect(not store.rename_stockpile(first, "x".repeat(65)), "65-character name accepted")
	var unicode_name := String.chr(0x00E9).repeat(64)
	_expect(store.rename_stockpile(first, unicode_name) and store.display_name(first) == unicode_name,
		"Name limit must count characters, not UTF-8 bytes")


func _test_save_records() -> void:
	var store := StockpileStore.new()
	var id := store.create_stockpile([Vector3i(1, 2, 3)])
	store.rename_stockpile(id, "North Vault")
	var saved := store.as_save_array()
	_expect(saved.size() == 1 and saved[0].name == "North Vault", "Save array lost name")
	var restored := StockpileStore.new()
	restored.restore_stockpile(saved[0])
	_expect(restored.display_name(id) == "North Vault" and restored.as_save_array() == saved,
		"Name/zone save-array round trip changed data")
	saved[0].name = "Detached"
	_expect(store.display_name(id) == "North Vault" and restored.display_name(id) == "North Vault",
		"Saved records alias live name data")
	var old_record := {"id": 40, "cells": [Vector3i(4, 2, 3)]}
	var original := old_record.duplicate(true)
	restored.restore_stockpile(old_record)
	_expect(restored.display_name(40) == "Stockpile 40" \
		and restored.stockpiles[40].name == "Stockpile 40", "Older absent name did not receive default")
	_expect(old_record == original and not old_record.has("name"), "Restore mutated input record")
	for invalid in ["", "invalid\nname", "x".repeat(65), 9, null]:
		restored.restore_stockpile({"id": 50, "name": invalid})
		_expect(restored.display_name(50) == "Stockpile 50", "Invalid restored name did not fall back")
	restored.restore_stockpile({"id": 51, "name": "  Trimmed  "})
	_expect(restored.display_name(51) == "Trimmed", "Restored name was not normalized")
	# Legacy in-memory records are also safe to inspect without mutating them.
	restored.stockpiles[52] = {"id": 52}
	_expect(restored.display_name(52) == "Stockpile 52" and not restored.stockpiles[52].has("name"),
		"Legacy display lookup mutated data")


func _drain(model) -> void:
	for _step in range(1000):
		if not model.updating:
			return
		model.pump(128, 1.0)
		_expect(model.last_pump_steps <= 128, "Name refresh exceeded model step limit")
	_expect(false, "Name refresh failed to converge")


func _test_presentation() -> void:
	var world := World.new()
	world.block_registry.load_from_csv(World.BLOCK_DATA_PATH)
	world.task_manager = TaskManager.new(world, world.task_queue)
	var first := world.stockpile_store.create_stockpile([Vector3i(1, 1, 0)])
	var second := world.stockpile_store.create_stockpile([Vector3i(2, 1, 0)])
	world.item_store.add_stack(2, 3, Vector3i(1, 1, 0), first)
	world.task_manager.haul_rebuild_requested = false
	world.task_manager.haul_rebuild_reasons.clear()
	var model := Model.new()
	model.bind_world(world)
	_drain(model)
	var old_row: Dictionary = model.get_row("stockpile", first)
	var old_revision: int = model.revision
	var old_counts: Dictionary = model.snapshot().counts
	_expect(old_row.title == "Stockpile %d" % first and old_row.name == old_row.title,
		"Presentation default name is inconsistent")
	world.stockpile_store.rename_stockpile(first, "Bronze Vault")
	_expect(model.updating, "Rename did not dirty presentation through visual signal")
	var before := _domain_state(world)
	_drain(model)
	var row: Dictionary = model.get_row("stockpile", first)
	_expect(model.revision > old_revision and row.title == "Bronze Vault" and row.name == row.title,
		"Refreshed title/name missing")
	_expect(row.id == first and old_row.title == "Stockpile %d" % first,
		"Rename changed stable ID or previously published snapshot")
	_expect(row.is_read_only() and model.list_rows("stockpile").is_read_only(), "Name snapshots are mutable")
	var matches: Array[int] = []
	for candidate: Dictionary in model.list_rows("stockpile"):
		# The panel searches title/description/id; custom names must be in title.
		if str(candidate.title).to_lower().contains("bronze"):
			matches.append(candidate.id)
	_expect(matches == [first] and model.get_row("stockpile", second).name == "Stockpile %d" % second,
		"Presentation search does not isolate renamed stockpile")
	_expect(model.snapshot().counts == old_counts, "Rename changed resource or colony counts")
	for _frame in range(20):
		model.snapshot()
		model.list_rows("stockpile")
		model.pump()
	_expect(before == _domain_state(world), "Read-only rename presentation changed gameplay")
	_expect(not world.task_manager.haul_rebuild_requested and world.task_manager.haul_rebuild_count == 0,
		"Display-only rename requested hauling reconstruction")
	model.clear()
	world.task_manager.shutdown()
	world.free()


func _domain_state(world: World) -> Dictionary:
	return {"items": world.item_store.items.duplicate(true), "zones": world.stockpile_store.stockpiles.duplicate(true),
		"inventory": world.inventory.duplicate(), "chunks": world.chunks.size(), "access_tick": world.chunk_access_tick,
		"tasks": world.task_queue.tasks.duplicate(), "checks": world.task_manager.accessibility_check_count,
		"retry": world.task_manager.path_retry_due_by_task.duplicate(),
		"haul_requested": world.task_manager.haul_rebuild_requested,
		"haul_rebuilds": world.task_manager.haul_rebuild_count}


func _test_worker_assignment_presentation() -> void:
	var world := World.new()
	var worker := Worker.new()
	worker.worker_id = 4
	worker.role_id = WorkerRoles.Role.FIGHTER
	world.add_child(worker)
	world.workers.append(worker)
	var model := Model.new()
	model.bind_world(world)
	_drain(model)
	var original: Dictionary = model.get_row("worker", 4)
	_expect(original.description == "Reserve; combat not implemented yet" and original.activity == "reserve",
		"Default Fighter reserve wording changed")
	_expect(original.work_priorities == {"hauling": 0, "mining": 0, "building": 0} \
		and original.work_priorities.is_read_only(), "Effective priorities missing or mutable")
	worker.work_priorities = {"hauling": 2}
	model.refresh_workers()
	_drain(model)
	var enabled: Dictionary = model.get_row("worker", 4)
	_expect(enabled.activity == "waiting" and enabled.title.contains("Custom work priorities") \
		and enabled.description.contains("hauling (2)") and not enabled.description.contains("Reserve"),
		"Enabled Fighter still presented as reserve or role-only assignment")
	_expect(enabled.role_id == WorkerRoles.Role.FIGHTER and enabled.role == "Fighter" \
		and enabled.has_custom_assignments, "Compatibility role/template identity lost")
	_expect(model.snapshot().counts.waiting == 1 and model.snapshot().counts.reserve == 0,
		"Custom Fighter is counted as idle reserve")
	worker.work_priorities["hauling"] = 1
	_expect(enabled.work_priorities.hauling == 2 and original.work_priorities.hauling == 0,
		"Published priorities alias mutable worker configuration")
	worker.role_id = WorkerRoles.Role.MINER
	worker.work_priorities = {"mining": 0, "building": 0}
	model.refresh_workers()
	_drain(model)
	_expect(model.get_row("worker", 4).activity == "reserve" \
		and model.get_row("worker", 4).description == "Reserve; no work enabled",
		"All-off non-Fighter did not report reserve with reason")
	worker.work_priorities = {"hauling": 2, "mining": 1}
	model.refresh_workers()
	_drain(model)
	_expect(model.get_row("worker", 4).work_priorities == {"hauling": 2, "mining": 1, "building": 2},
		"Effective priorities did not retain unspecified role defaults")
	worker.state = Worker.WorkerState.WORKING
	worker.work_priorities = {"hauling": 0, "mining": 0, "building": 0}
	model.refresh_workers()
	_drain(model)
	_expect(model.get_row("worker", 4).activity == "working", "All-off configuration hid ongoing work")
	_expect(worker.work_priorities == {"hauling": 0, "mining": 0, "building": 0} \
		and worker.role_id == WorkerRoles.Role.MINER and worker.state == Worker.WorkerState.WORKING,
		"Presentation changed worker assignments or state")
	model.clear()
	world.free()
