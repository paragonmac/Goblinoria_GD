extends Node3D
class_name ChunkCache
## Caches MeshInstance3D nodes for each chunk coordinate.

#region State
const MAX_POOLED_CHUNK_NODES := 128

var chunk_nodes: Dictionary = {}
var pooled_nodes: Array = []
var created_node_count: int = 0
var reused_node_count: int = 0
var freed_node_count: int = 0
#endregion


#region Cache Management
func clear() -> void:
	for key in chunk_nodes.keys():
		var mesh_instance: MeshInstance3D = chunk_nodes[key]
		mesh_instance.queue_free()
		freed_node_count += 1
	chunk_nodes.clear()
	for node in pooled_nodes:
		var mesh_instance: MeshInstance3D = node
		mesh_instance.queue_free()
		freed_node_count += 1
	pooled_nodes.clear()


func ensure_chunk(coord: Vector3i, chunk_size: int) -> MeshInstance3D:
	if chunk_nodes.has(coord):
		return chunk_nodes[coord]
	var mesh_instance := _take_pooled_node()
	if mesh_instance == null:
		mesh_instance = MeshInstance3D.new()
		created_node_count += 1
	else:
		reused_node_count += 1
	mesh_instance.name = "Chunk_%d_%d_%d" % [coord.x, coord.y, coord.z]
	mesh_instance.position = Vector3(coord.x * chunk_size, coord.y * chunk_size, coord.z * chunk_size)
	add_child(mesh_instance)
	chunk_nodes[coord] = mesh_instance
	return mesh_instance


func remove_chunk(coord: Vector3i) -> void:
	if not chunk_nodes.has(coord):
		return
	var mesh_instance: MeshInstance3D = chunk_nodes[coord]
	chunk_nodes.erase(coord)
	_pool_or_free_node(mesh_instance)
#endregion


#region Pooling
func _take_pooled_node() -> MeshInstance3D:
	while pooled_nodes.size() > 0:
		var node: MeshInstance3D = pooled_nodes.pop_back()
		if is_instance_valid(node):
			return node
	return null


func _pool_or_free_node(mesh_instance: MeshInstance3D) -> void:
	if mesh_instance == null:
		return
	_reset_chunk_node(mesh_instance)
	if mesh_instance.get_parent() == self:
		remove_child(mesh_instance)
	if pooled_nodes.size() >= MAX_POOLED_CHUNK_NODES:
		mesh_instance.queue_free()
		freed_node_count += 1
		return
	pooled_nodes.append(mesh_instance)


func _reset_chunk_node(mesh_instance: MeshInstance3D) -> void:
	mesh_instance.name = "PooledChunk"
	mesh_instance.mesh = null
	mesh_instance.material_override = null
	mesh_instance.visible = false
	mesh_instance.position = Vector3.ZERO
#endregion


#region Queries
func is_chunk_built(coord: Vector3i) -> bool:
	return chunk_nodes.has(coord)


func get_chunk(coord: Vector3i) -> MeshInstance3D:
	if not chunk_nodes.has(coord):
		return null
	return chunk_nodes[coord]


func get_keys() -> Array:
	return chunk_nodes.keys()


func get_pool_stats() -> Dictionary:
	return {
		"active": chunk_nodes.size(),
		"pooled": pooled_nodes.size(),
		"pool_max": MAX_POOLED_CHUNK_NODES,
		"created": created_node_count,
		"reused": reused_node_count,
		"freed": freed_node_count,
	}
#endregion
