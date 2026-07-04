extends RefCounted
class_name WorldRendererMeshCacheStore
## Stores runtime mesh-cache entries and tracks cache/timing metrics.

const WorldRendererMeshCacheScript = preload("res://scripts/rendering/world_renderer_mesh_cache.gd")

var helper = WorldRendererMeshCacheScript.new()
var chunk_mesh_cache: Dictionary = {}
var mesh_cache_hits: int = 0
var mesh_cache_misses: int = 0
var mesh_cache_imports: int = 0
var mesh_build_ms_total: float = 0.0
var mesh_upload_ms_total: float = 0.0


func clear() -> void:
	chunk_mesh_cache.clear()


func erase(coord: Vector3i) -> void:
	if chunk_mesh_cache.has(coord):
		chunk_mesh_cache.erase(coord)


func reset_metrics() -> void:
	mesh_cache_hits = 0
	mesh_cache_misses = 0
	mesh_cache_imports = 0
	mesh_build_ms_total = 0.0
	mesh_upload_ms_total = 0.0


func record_build_ms(value: float) -> void:
	mesh_build_ms_total += value


func record_upload_ms(value: float) -> void:
	mesh_upload_ms_total += value


func get_metrics() -> Dictionary:
	return {
		"hits": mesh_cache_hits,
		"misses": mesh_cache_misses,
		"imports": mesh_cache_imports,
		"mesh_build_ms": mesh_build_ms_total,
		"mesh_upload_ms": mesh_upload_ms_total,
	}


func store_from_arrays(
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
	if local_top < 0:
		return
	var entry: Dictionary = helper.entry_from_arrays(
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
	store_entry(coord, local_top, entry)


func store_entry(coord: Vector3i, local_top: int, entry: Dictionary) -> void:
	if local_top < 0:
		return
	var cache := _get_chunk_mesh_cache(coord)
	cache[local_top] = entry


func export_persistent_entry(coord: Vector3i, local_top: int) -> Dictionary:
	if local_top < 0:
		return {}
	if not chunk_mesh_cache.has(coord):
		return {}
	var cache = chunk_mesh_cache[coord]
	if typeof(cache) != TYPE_DICTIONARY:
		return {}
	if not cache.has(local_top):
		return {}
	var entry = cache[local_top]
	if typeof(entry) != TYPE_DICTIONARY:
		return {}
	var typed_entry: Dictionary = entry
	return helper.export_persistent_entry(typed_entry, local_top)


func import_persistent_entry(world: World, coord: Vector3i, entry: Dictionary) -> bool:
	if world == null:
		return false
	if not world.is_chunk_coord_valid(coord):
		return false
	var chunk: ChunkData = world.get_chunk(coord)
	if chunk == null:
		return false
	var local_top: int = int(entry.get("local_top", -1))
	if local_top < 0 or local_top >= World.CHUNK_SIZE:
		return false
	if not helper.validate_arrays(entry):
		return false
	var stored_entry: Dictionary = helper.entry_from_persistent(entry, chunk.mesh_revision)
	store_entry(coord, local_top, stored_entry)
	mesh_cache_imports += 1
	return true


func validate_arrays(entry: Dictionary) -> bool:
	return helper.validate_arrays(entry)


func array_mesh_from_entry(entry: Dictionary) -> ArrayMesh:
	return helper.array_mesh_from_entry(entry)


func has_cached_mesh(world: World, coord: Vector3i, local_top: int) -> bool:
	var cached := get_valid_entry(world, coord, local_top, false)
	return not cached.is_empty()


func get_valid_entry_for_apply(world: World, coord: Vector3i, local_top: int) -> Dictionary:
	return get_valid_entry(world, coord, local_top, true)


func get_valid_entry(world: World, coord: Vector3i, local_top: int, count_miss: bool) -> Dictionary:
	if world == null:
		return _miss(count_miss)
	if local_top < 0:
		return {}
	if not chunk_mesh_cache.has(coord):
		return _miss(count_miss)
	var cache = chunk_mesh_cache[coord]
	if typeof(cache) != TYPE_DICTIONARY:
		return _miss(count_miss)
	var cache_local_top: int = _resolve_cached_local_top(cache, local_top)
	if cache_local_top < 0:
		return _miss(count_miss)
	var entry = cache[cache_local_top]
	if typeof(entry) != TYPE_DICTIONARY:
		return _miss(count_miss)
	var chunk: ChunkData = world.get_chunk(coord)
	if chunk == null:
		return _miss(count_miss)
	if int(entry.get("revision", -1)) != chunk.mesh_revision:
		cache.erase(cache_local_top)
		return _miss(count_miss)
	if count_miss:
		mesh_cache_hits += 1
	return {
		"entry": entry,
		"local_top": cache_local_top,
	}


func _get_chunk_mesh_cache(coord: Vector3i) -> Dictionary:
	if chunk_mesh_cache.has(coord):
		return chunk_mesh_cache[coord]
	var entry: Dictionary = {}
	chunk_mesh_cache[coord] = entry
	return entry


func _resolve_cached_local_top(cache: Dictionary, local_top: int) -> int:
	if cache.has(local_top):
		return local_top
	var full_local_top: int = World.CHUNK_SIZE - 1
	if local_top != full_local_top and cache.has(full_local_top):
		return full_local_top
	return -1


func _miss(count_miss: bool) -> Dictionary:
	if count_miss:
		mesh_cache_misses += 1
	return {}
