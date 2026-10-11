extends SceneTree

const WorldScript = preload("res://scripts/world.gd")
const ChunkDataScript = preload("res://scripts/chunk_data.gd")

var checks := 0
var failures := 0


class TestWorld extends World:
	func bump_runtime_epoch() -> void:
		runtime_epoch += 1


func _init() -> void:
	_run.call_deferred()


func _check(ok: bool, message: String) -> void:
	checks += 1
	if not ok:
		failures += 1
		push_error(message)


func _run() -> void:
	_check(WorldScript.configure_dimensions(32, 32), "Configure async light fixture dimensions")
	var world := TestWorld.new()
	root.add_child(world)
	await process_frame
	for cy in range(WorldScript.WORLD_CHUNKS_Y):
		var chunk = world.ensure_chunk(Vector3i(0, cy, 0))
		chunk.generated = true
		chunk.blocks.fill(WorldScript.BLOCK_ID_GRANITE)
	for y in range(80, 256):
		world.set_block_raw(0, y, 0, WorldScript.BLOCK_ID_AIR, false)
	world.torch_store.add_torch(Vector3i(0, 90, 0), Vector3i.RIGHT)
	world.rebuild_light_field()
	var sync_light: PackedByteArray = world.light_field.light.duplicate()
	var sync_explored: PackedByteArray = world.light_field.explored.duplicate()
	var sync_mirror: PackedByteArray = world.light_field.block_mirror.duplicate()
	var sync_count: int = world.light_field.explored_count
	var cache_coord := Vector3i(0, 10, 0)
	var cache_chunk = world.chunks[cache_coord]
	cache_chunk.mesh_state = ChunkDataScript.MESH_STATE_READY
	world.renderer.mesh_cache_store.chunk_mesh_cache[cache_coord] = {"fixture": true}
	var cached_entry: Dictionary = world.renderer.mesh_cache_store.chunk_mesh_cache[cache_coord].duplicate(true)
	_check(await world.rebuild_light_field_async(), "Async light build completes for current epoch")
	var async_total_ms: float = world.light_field_async_total_ms
	var async_max_frame_ms: float = world.light_field_async_max_frame_ms
	print("Async light 256 fixture: total %.2f ms, build %.2f ms, longest main-thread frame %.2f ms" % [
		async_total_ms, world.light_field.last_build_ms, async_max_frame_ms])
	_check(async_max_frame_ms <= 100.0, "256 async light build keeps main-thread frames under 100 ms")
	_check(world.light_field.light == sync_light and world.light_field.explored == sync_explored \
		and world.light_field.block_mirror == sync_mirror and world.light_field.explored_count == sync_count,
		"Async build with a registered torch is identical to synchronous build")
	_check(cache_chunk.mesh_state == ChunkDataScript.MESH_STATE_READY \
		and world.renderer.mesh_cache_store.chunk_mesh_cache.get(cache_coord, {}) == cached_entry,
		"Async rebuild preserves raw mesh cache entries and chunk mesh state")
	var reveal_start_usec := Time.get_ticks_usec()
	world.renderer.pump_visibility(world.renderer.VISIBILITY_PUMP_MS, world.renderer.VISIBILITY_PUMP_STEPS)
	var reveal_pump_ms := float(Time.get_ticks_usec() - reveal_start_usec) / 1000.0
	world.light_field_reveal_pump_ms = reveal_pump_ms
	world.visible = true
	var first_revealed_frame_start_usec := Time.get_ticks_usec()
	world.renderer.pump_visibility(world.renderer.VISIBILITY_PUMP_MS, world.renderer.VISIBILITY_PUMP_STEPS)
	var first_revealed_frame_ms := float(Time.get_ticks_usec() - first_revealed_frame_start_usec) / 1000.0
	print("Light pre-reveal pump, 256 fixture: %.2f ms; first frame after reveal: %.2f ms" % [
		reveal_pump_ms, first_revealed_frame_ms])
	var original_field = world.light_field
	world.call_deferred("bump_runtime_epoch")
	var accepted := await world.rebuild_light_field_async()
	_check(not accepted and world.light_field == original_field,
		"World replacement epoch prevents stale async field binding")
	if world.generator != null:
		world.generator.shutdown_generation_thread()
	if world.renderer != null:
		world.renderer._stop_mesh_worker()
	world.queue_free()
	await process_frame
	_check(WorldScript.configure_dimensions(32, 32), "Restore default async validator dimensions")
	print("Async light build: %d checks, %d failures" % [checks, failures])
	quit(1 if failures > 0 else 0)
