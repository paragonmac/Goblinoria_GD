extends SceneTree

const TransactionScript = preload("res://scripts/world_save_transaction.gd")
const WorkerRolesScript = preload("res://scripts/worker_roles.gd")


class TestWorld:
	extends World

	func _start_worker_trace_for_spawned_workers() -> void:
		pass # Keep writes inside this contract's isolated test directory.


class FaultTransaction:
	extends "res://scripts/world_save_transaction.gd"
	var failed_renames: Array[int] = []
	var rename_count := 0
	var fail_copy := false

	func _rename_directory(source: String, destination: String) -> Error:
		rename_count += 1
		if failed_renames.has(rename_count):
			return ERR_FILE_CANT_WRITE
		return super._rename_directory(source, destination)

	func _copy_tree(source: String, destination: String, skip_files: Array = []) -> bool:
		return super._copy_tree(source, destination, skip_files) and not fail_copy


class FaultSaveLoad:
	extends WorldSaveLoad
	var failed_writer := ""
	var visited: Array[String] = []

	func _write_world_meta(destination: String) -> bool:
		visited.append("meta")
		if failed_writer == "meta":
			_block_file(destination.path_join(WorldMetadataSaveLoad.META_FILE_NAME))
		return super._write_world_meta(destination)

	func _save_bulk_chunks(destination: String) -> bool:
		visited.append("bulk")
		if failed_writer == "bulk":
			_block_file(destination.path_join(WorldBulkChunkSaveLoad.BULK_CHUNKS_FILE_NAME))
		return super._save_bulk_chunks(destination)

	func _save_items_and_stockpiles(destination: String) -> bool:
		visited.append("items")
		if failed_writer == "items":
			_block_file(destination.path_join(WorldItemStockpileSaveLoad.ITEM_STOCKPILE_FILE_NAME))
		return super._save_items_and_stockpiles(destination)

	func _save_workers(destination: String) -> bool:
		visited.append("workers")
		if failed_writer == "workers":
			_block_file(destination.path_join(WorldWorkerSaveLoad.WORKER_FILE_NAME))
		return super._save_workers(destination)

	func _save_mesh_cache(destination: String) -> bool:
		if failed_writer == "mesh":
			var file := FileAccess.open(destination.path_join(WorldMeshCacheSaveLoad.MESH_CACHE_FILE_NAME), FileAccess.WRITE)
			if file != null:
				file.store_8(0)
				file.close()
			mesh_cache_save_load.mesh_cache_stats["entries_saved"] = 999
			return false
		return super._save_mesh_cache(destination)

	func _block_file(path: String) -> void:
		if FileAccess.file_exists(path):
			assert(DirAccess.remove_absolute(path) == OK)
		assert(DirAccess.make_dir_absolute(path) == OK)


var test_root := ""
var failures: Array[String] = []
var checks := 0


func _init() -> void:
	_run.call_deferred()


func _run() -> void:
	test_root = ProjectSettings.globalize_path("res://.local-save-transaction-%d-%d" % [OS.get_process_id(), Time.get_ticks_usec()])
	if not _check(DirAccess.make_dir_absolute(test_root) == OK, "create isolated test directory"):
		quit(1)
		return
	_test_save_failures()
	_test_failed_loads()
	_test_invalid_item_records()
	_test_legacy_chunks()
	_test_short_write()
	for path in ["", "/", "C:/", "C:", "res://", "user://", "res://scripts/..", "//server/share"]:
		_check(not TransactionScript.new().begin(path), "unsafe slot root rejected: %s" % path)
	_check(_remove_test_tree(test_root), "remove isolated test artifacts")
	await process_frame
	if failures.is_empty():
		print("Save/load transaction contract OK (%d checks)" % checks)
		quit(0)
	else:
		for message in failures:
			push_error(message)
		quit(1)


func _new_world() -> TestWorld:
	# Detached nodes avoid renderer jobs and simulation ticks during comparisons.
	var world := TestWorld.new()
	world._init_ramp_lookup()
	world.save_load = FaultSaveLoad.new(world)
	world.world_seed = 111
	world.top_render_y = 10
	world.sea_level = 12
	world.spawn_coord = Vector3i(0, 3, 0)
	world.spawn_initial_workers()
	var chunk := ChunkData.new(World.CHUNK_SIZE, World.BLOCK_ID_DIRT)
	chunk.generated = true
	chunk.dirty = true
	world.chunks[Vector3i.ZERO] = chunk
	world.item_store.add_stack(World.BLOCK_ID_DIRT, 1, Vector3i(0, 1, 0))
	return world


func _test_save_failures() -> void:
	var world := _new_world()
	# A real empty renderer cache exercises entries_saved changes during staging.
	world.renderer = WorldRenderer.new()
	world.renderer.add_child(world.renderer.chunk_cache)
	world.renderer.add_child(world.renderer.overlay_renderer)
	world.add_child(world.renderer)
	var persistence: FaultSaveLoad = world.save_load
	var path := test_root.path_join("slot.save")
	var slot := path.get_basename()
	if not _check(world.save_world(path), "create baseline save"):
		world.free()
		return
	var legacy_chunk := ChunkData.new(World.CHUNK_SIZE, World.BLOCK_ID_IRON_ORE)
	_check(persistence.save_chunk(slot, Vector3i(2, 0, 0), legacy_chunk), "baseline extra chunk")
	_write_bytes(slot.path_join("keep.dat"), PackedByteArray([1, 2, 3]))
	var old_bytes := _slot_bytes(slot)
	# Save-as failures must keep the active source, not adopt the destination.
	_check(world.save_world(test_root.path_join("active.save")), "create active source slot")
	world.world_seed = 222
	world.top_render_y = 20
	world.chunks[Vector3i.ZERO].blocks[0] = World.BLOCK_ID_GRANITE
	world.chunks[Vector3i.ZERO].dirty = true
	var clean_chunk := ChunkData.new(World.CHUNK_SIZE, World.BLOCK_ID_CLAY)
	clean_chunk.generated = true
	world.chunks[Vector3i(1, 0, 0)] = clean_chunk
	world.item_store.add_stack(World.BLOCK_ID_GRANITE, 3, Vector3i(1, 1, 0))
	world.workers[0].role_id = WorkerRolesScript.Role.HAULER
	world.task_queue.add_dig_task(Vector3i(3, 1, 0))
	persistence.warned_missing_world_dir = true
	persistence.last_load_metrics = {"sentinel": 27}
	persistence.bulk_chunk_save_load.last_load_stats = {"sentinel": 28}
	persistence.mesh_cache_save_load.mesh_cache_stats = {"entries_saved": 29, "entries_imported": 7}
	persistence.mesh_cache_save_load.pending_mesh_cache_entries = {Vector3i.ZERO: {"sentinel": PackedByteArray([4, 5])}}
	var live := _live_state(world)
	for writer in ["meta", "bulk", "items", "workers"]:
		persistence.failed_writer = writer
		persistence.visited.clear()
		_check(not world.save_world(path), "%s write failure rejected" % writer)
		_check(persistence.visited.has(writer), "%s reached intended writer" % writer)
		_check(_slot_bytes(slot) == old_bytes, "%s failure preserved prior-slot bytes" % writer)
		_check(_live_state(world) == live, "%s failure preserved all live state" % writer)
		_check_no_transaction_artifacts(slot, writer)
	persistence.failed_writer = ""
	for rename_index in [1, 2]:
		var transaction := FaultTransaction.new()
		transaction.failed_renames.assign([rename_index])
		persistence.save_transaction = transaction
		_check(not world.save_world(path), "promotion %d failure rejected" % rename_index)
		_check(transaction.rename_count == (1 if rename_index == 1 else 3), "promotion/rollback calls")
		_check(_slot_bytes(slot) == old_bytes, "promotion failure preserved prior-slot bytes")
		_check(_live_state(world) == live, "promotion failure restored live state")
		_check_no_transaction_artifacts(slot, "promotion")
	var copy_failure := FaultTransaction.new()
	copy_failure.fail_copy = true
	persistence.save_transaction = copy_failure
	_check(not world.save_world(path), "staging copy failure rejected")
	_check(_slot_bytes(slot) == old_bytes and _live_state(world) == live, "copy failure preserved slot and live state")
	_check_no_transaction_artifacts(slot, "copy")
	var first_promotion := FaultTransaction.new()
	first_promotion.failed_renames.assign([1])
	persistence.save_transaction = first_promotion
	var new_path := test_root.path_join("never_saved.save")
	_check(not world.save_world(new_path), "new slot promotion failure rejected")
	_check(not DirAccess.dir_exists_absolute(new_path.get_basename()), "failed first save left no partial slot")
	_check(_live_state(world) == live, "failed first save restored live state")
	_check_no_transaction_artifacts(new_path.get_basename(), "first save")
	# Retain the backup if even rollback is denied; the next load recovers it.
	var rollback_failure := FaultTransaction.new()
	rollback_failure.failed_renames.assign([2, 3])
	persistence.save_transaction = rollback_failure
	_check(not world.save_world(path), "rollback failure rejected")
	_check(_slot_bytes(slot + TransactionScript.BACKUP_SUFFIX) == old_bytes, "rollback failure retained prior-slot bytes")
	_check(_live_state(world) == live, "rollback failure restored live state")
	var reader := _new_world()
	_check(reader.load_world(path), "interrupted promotion recovered on load")
	_check(_slot_bytes(slot) == old_bytes and reader.world_seed == 111, "recovery restored original slot")
	reader.free()
	persistence.save_transaction = TransactionScript.new()
	persistence.failed_writer = "mesh"
	_check(world.save_world(path), "optional cache failure allowed required save")
	_check(not FileAccess.file_exists(slot.path_join(WorldMeshCacheSaveLoad.MESH_CACHE_FILE_NAME)), "partial optional cache discarded")
	_check(persistence.mesh_cache_save_load.snapshot_state() == live["mesh"], "optional cache failure restored cache state")
	_check(persistence.current_world_dir == slot and not world.chunks[Vector3i.ZERO].dirty, "commit updates directory and dirty flags")
	_check(FileAccess.get_file_as_bytes(slot.path_join("keep.dat")) == PackedByteArray([1, 2, 3]), "promotion preserved ancillary files")
	# Legacy chunk files are folded into bulk data, and loads ignore them once
	# bulk data exists; promotion no longer carries them forward.
	_check(not FileAccess.file_exists(persistence._chunk_path(slot, Vector3i(2, 0, 0))), "promotion drops redundant legacy chunk files")
	reader = _new_world()
	_check(reader.load_world(path), "successful replacement loads")
	_check(reader.world_seed == 222 and reader.top_render_y == 20, "replacement metadata round trip")
	var loaded := ChunkData.new(World.CHUNK_SIZE, 0)
	_check(reader.save_load.load_chunk_into(Vector3i.ZERO, loaded) and loaded.blocks[0] == World.BLOCK_ID_GRANITE, "replacement terrain round trip")
	_check(reader.item_store.as_save_array().size() == 2 and reader.workers[0].role_id == WorkerRolesScript.Role.HAULER, "replacement items and roles round trip")
	reader.free()
	world.free()


func _test_failed_loads() -> void:
	var world := _new_world()
	var path := test_root.path_join("incomplete.save")
	var slot := path.get_basename()
	_check(world.save_world(path), "create load-failure baseline")
	var baseline := _slot_bytes(slot)
	world.world_seed = 333
	world.top_render_y = 30
	world.chunks[Vector3i.ZERO].dirty = true
	world.item_store.add_stack(World.BLOCK_ID_GRANITE, 3, Vector3i(1, 1, 0))
	world.task_queue.add_dig_task(Vector3i(2, 1, 0))
	world.save_load.current_world_dir = test_root.path_join("different_live_slot")
	world.save_load.legacy_terrain_slope_migration = true
	world.save_load.last_load_metrics = {"sentinel": 41}
	world.save_load.mesh_cache_save_load.mesh_cache_stats = {"entries_pending": 42}
	world.save_load.mesh_cache_save_load.pending_mesh_cache_entries = {Vector3i.ZERO: {"sentinel": 43}}
	var live := _live_state(world)
	for filename in [WorldItemStockpileSaveLoad.ITEM_STOCKPILE_FILE_NAME, WorldWorkerSaveLoad.WORKER_FILE_NAME, WorldBulkChunkSaveLoad.BULK_CHUNKS_FILE_NAME]:
		_write_bytes(slot.path_join(filename), PackedByteArray([0, 0, 0, 0]))
		_check(not world.load_world(path), "corrupt %s rejected" % filename)
		_check(_live_state(world) == live, "corrupt %s preserved live state" % filename)
		_write_bytes(slot.path_join(filename), baseline[filename])
	_check(DirAccess.remove_absolute(slot.path_join(WorldBulkChunkSaveLoad.BULK_CHUNKS_FILE_NAME)) == OK, "remove terrain fixture")
	_check(not world.load_world(path), "current metadata with empty chunks directory rejected")
	_check(_live_state(world) == live, "missing terrain preserved all live state")
	_write_bytes(slot.path_join("chunks/0_0_0.chunk"), PackedByteArray([0]))
	_check(not world.load_world(path), "invalid chunk marker did not enable legacy fallback")
	_check(_live_state(world) == live, "invalid chunk fallback preserved all live state")
	_check(DirAccess.remove_absolute(slot.path_join("chunks/0_0_0.chunk")) == OK, "remove invalid chunk fixture")
	_check(DirAccess.remove_absolute(slot.path_join("chunks")) == OK, "remove empty chunks directory")
	_check(not world.load_world(path), "current metadata without terrain directory rejected")
	_check(_live_state(world) == live, "absent terrain directory preserved all live state")
	world.free()


func _test_legacy_chunks() -> void:
	for version in [4, 5, 6, 7, 8, 9]:
		var world := _new_world()
		var path := test_root.path_join("legacy_%d.save" % version)
		var slot := path.get_basename()
		_check(DirAccess.make_dir_recursive_absolute(slot.path_join("chunks")) == OK, "create legacy chunk directory")
		_check(world.save_load.metadata_save_load.write_world_meta(world, slot, version, world.save_load._get_block_table_hash()), "create legacy metadata")
		var unloaded_coord := Vector3i(5, 1, 5)
		var blocks := ChunkData.new(World.CHUNK_SIZE, World.BLOCK_ID_IRON_ORE)
		_check(world.save_load.save_chunk(slot, unloaded_coord, blocks), "create unloaded legacy terrain")
		var chunk_path := world.save_load._chunk_path(slot, unloaded_coord)
		var file := FileAccess.open(chunk_path, FileAccess.READ_WRITE)
		file.seek(4)
		file.store_16(version)
		file.close()
		_check(world.load_world(path), "V%d chunk-only legacy save loads" % version)
		_check(not world.chunks.has(unloaded_coord) and not world.save_load.bulk_chunk_save_load.has_chunk(unloaded_coord), "legacy edit remains unloaded before save")
		_check(world.workers[0].role_id == WorkerRolesScript.Role.MINER, "legacy missing workers default roster")
		var live := _live_state(world)
		var prior_bytes := _slot_bytes(slot)
		world.save_load.failed_writer = "workers"
		_check(not world.save_world(path), "legacy conversion write failure rejected")
		_check(_slot_bytes(slot) == prior_bytes and _live_state(world) == live, "failed legacy conversion restored bytes and cache")
		world.save_load.failed_writer = ""
		var destination := path if version != 5 else test_root.path_join("legacy_save_as.save")
		_check(world.save_world(destination), "legacy conversion commits")
		var reader := _new_world()
		_check(reader.load_world(destination), "converted legacy save loads")
		var loaded := ChunkData.new(World.CHUNK_SIZE, 0)
		_check(reader.save_load.bulk_chunk_save_load.is_loaded() and reader.save_load.load_chunk_into(unloaded_coord, loaded) and loaded.blocks == blocks.blocks, "unloaded legacy edit folded into authoritative bulk map")
		reader.free()
		world.free()
	# V5 bulk saves without workers.dat remain compatible (ADR-012).
	var world := _new_world()
	var path := test_root.path_join("v5_bulk.save")
	_check(world.save_world(path), "create V5 bulk fixture")
	_check(world.save_load.metadata_save_load.write_world_meta(world, path.get_basename(), 5, world.save_load._get_block_table_hash()), "set V5 metadata")
	_check(DirAccess.remove_absolute(path.get_basename().path_join(WorldWorkerSaveLoad.WORKER_FILE_NAME)) == OK, "remove V5 workers fixture")
	_check(world.load_world(path) and world.workers[0].role_id == WorkerRolesScript.Role.MINER, "V5 bulk without workers loads default roster")
	world.free()


func _test_invalid_item_records() -> void:
	var world := _new_world()
	var path := test_root.path_join("invalid_items.save")
	var slot := path.get_basename()
	_check(world.save_world(path), "create invalid-item fixture")
	var item := world.item_store.as_save_array()[0] as Dictionary
	var duplicate := item.duplicate(true)
	duplicate["count"] = 7
	var stockpile := {"id": 1, "cells": [Vector3i(0, 1, 0)]}
	var cases := [{"label": "duplicate item IDs", "items": [item, duplicate], "stockpiles": []}]
	for field in ["id", "material_id", "count"]:
		for invalid in [0, -1, "2", 1.5]:
			var malformed := item.duplicate(true)
			malformed[field] = invalid
			cases.append({"label": "invalid item %s=%s" % [field, invalid], "items": [malformed], "stockpiles": []})
	for invalid in [null, "0,1,0", Vector3(0, 1, 0)]:
		var malformed := item.duplicate(true)
		malformed["pos"] = invalid
		cases.append({"label": "invalid item position %s" % invalid, "items": [malformed], "stockpiles": []})
	for field in ["reserved_by_task_id", "stored_stockpile_id"]:
		var malformed := item.duplicate(true)
		malformed[field] = []
		cases.append({"label": "invalid item " + field, "items": [malformed], "stockpiles": []})
	var stale_reservation := item.duplicate(true)
	stale_reservation["reserved_by_task_id"] = 1
	cases.append({"label": "stale saved task reservation", "items": [stale_reservation], "stockpiles": []})
	cases.append({"label": "duplicate stockpile IDs", "items": [item], "stockpiles": [stockpile, stockpile.duplicate(true)]})
	var overlapping := stockpile.duplicate(true)
	overlapping["id"] = 2
	cases.append({"label": "overlapping stockpile cells", "items": [item], "stockpiles": [stockpile, overlapping]})
	for field in ["id", "cells", "material_overrides", "allowed_categories"]:
		var malformed := stockpile.duplicate(true)
		malformed[field] = "invalid"
		cases.append({"label": "invalid stockpile " + field, "items": [item], "stockpiles": [malformed]})
	for field in ["material_overrides", "allowed_categories"]:
		var malformed := stockpile.duplicate(true)
		malformed[field] = {"soil": []}
		cases.append({"label": "invalid stockpile flag " + field, "items": [item], "stockpiles": [malformed]})
	var malformed := stockpile.duplicate(true)
	malformed["cells"] = ["invalid"]
	cases.append({"label": "invalid stockpile cell", "items": [item], "stockpiles": [malformed]})
	world.world_seed = 9876
	var live := _live_state(world)
	var epoch := world.runtime_epoch
	for definition: Dictionary in cases:
		_write_item_snapshot(slot, definition)
		var label: String = definition["label"]
		_check(not world.load_world(path), label + " rejected before replacing live state")
		_check(_live_state(world) == live and world.runtime_epoch == epoch, label + " preserved the live world")
	# Older records may omit display names, filters, carry and reservation fields.
	var legacy_item := {"id": 1, "material_id": World.BLOCK_ID_DIRT, "count": 3, "pos": Vector3i(0, 1, 0)}
	_write_item_snapshot(slot, {"items": [legacy_item], "stockpiles": [stockpile]})
	_check(world.load_world(path), "legacy item and stockpile defaults remain readable")
	_check(world.item_store.get_item(1)["count"] == 3 and world.stockpile_store.display_name(1) == "Stockpile 1", "legacy defaults preserve material and zone identity")
	world.free()


func _write_item_snapshot(slot: String, data: Dictionary) -> void:
	var file := FileAccess.open(slot.path_join(WorldItemStockpileSaveLoad.ITEM_STOCKPILE_FILE_NAME), FileAccess.WRITE)
	file.store_32(WorldItemStockpileSaveLoad.ITEM_STOCKPILE_MAGIC)
	file.store_var({"items": data["items"], "stockpiles": data["stockpiles"]})
	file.close()


func _test_short_write() -> void:
	var file := FileAccess.open(test_root.path_join("short_write.dat"), FileAccess.WRITE)
	file.store_8(1)
	file.seek(100)
	_check(not TransactionScript.finish_write(file), "writer rejects file shorter than expected end position")
	_check(not file.is_open(), "writer closes file before promotion")


func _live_state(world: World) -> Dictionary:
	var chunks := {}
	for coord in world.chunks:
		var chunk: ChunkData = world.chunks[coord]
		chunks[coord] = [chunk.get_instance_id(), chunk.blocks.duplicate(), chunk.dirty, chunk.generated, chunk.last_access_tick, chunk.mesh_revision]
	var workers := []
	for worker: Worker in world.workers:
		workers.append([worker.get_instance_id(), worker.role_id, worker.position, worker.current_task_id, worker.carried_source_item_id])
	return {
		"seed": world.world_seed, "top": world.top_render_y, "sea": world.sea_level,
		"spawn": world.spawn_coord, "chunks": chunks, "tick": world.chunk_access_tick,
		"items": world.item_store.as_save_array(), "stockpiles": world.stockpile_store.as_save_array(),
		"inventory": world.inventory.duplicate(true), "workers": workers,
		"tasks": world.task_queue.tasks.duplicate(), "selection": world.selected_blocks.duplicate(true),
		"dir": world.save_load.current_world_dir, "warning": world.save_load.warned_missing_world_dir,
		"bulk": world.save_load.bulk_chunk_save_load.snapshot_state(),
		"mesh": world.save_load.mesh_cache_save_load.snapshot_state(),
		"metrics": world.save_load.last_load_metrics.duplicate(true),
		"migration": world.save_load.legacy_terrain_slope_migration,
	}


func _slot_bytes(path: String, prefix: String = "") -> Dictionary:
	var result := {}
	var dir := DirAccess.open(path)
	if dir == null:
		return result
	for name in dir.get_files():
		result[prefix + name] = FileAccess.get_file_as_bytes(path.path_join(name))
	for name in dir.get_directories():
		result[prefix + name + "/"] = null
		result.merge(_slot_bytes(path.path_join(name), prefix + name + "/"))
	return result


func _write_bytes(path: String, bytes: PackedByteArray) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	_check(file != null and file.store_buffer(bytes) and TransactionScript.finish_write(file), "write fixture %s" % path.get_file())


func _check_no_transaction_artifacts(slot: String, label: String) -> void:
	_check(not DirAccess.dir_exists_absolute(slot + TransactionScript.STAGE_SUFFIX) and not DirAccess.dir_exists_absolute(slot + TransactionScript.BACKUP_SUFFIX), "%s cleaned transaction artifacts" % label)


func _remove_test_tree(path: String) -> bool:
	var absolute := ProjectSettings.globalize_path(path).simplify_path()
	if absolute != test_root and not absolute.begins_with(test_root + "/"):
		return false
	var dir := DirAccess.open(absolute)
	if dir == null:
		return false
	for name in dir.get_directories():
		if dir.is_link(name) or not _remove_test_tree(absolute.path_join(name)):
			return false
	for name in dir.get_files():
		if DirAccess.remove_absolute(absolute.path_join(name)) != OK:
			return false
	dir = null
	return DirAccess.remove_absolute(absolute) == OK


func _check(ok: bool, message: String) -> bool:
	checks += 1
	if not ok:
		failures.append(message)
	return ok
