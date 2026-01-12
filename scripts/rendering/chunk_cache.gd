extends Node3D
class_name ChunkCache
## Caches MeshInstance3D nodes for each chunk coordinate.

#region State
var chunk_nodes: Dictionary = {}
#endregion


#region Cache Management
func clear() -> void:
	for key in chunk_nodes.keys():
		chunk_nodes[key].queue_free()
	chunk_nodes.clear()


func ensure_chunk(coord: Vector3i, chunk_size: int) -> MeshInstance3D:
	if chunk_nodes.has(coord):
		return chunk_nodes[coord]
	var mesh_instance := MeshInstance3D.new()
	mesh_instance.position = Vector3(coord.x * chunk_size, coord.y * chunk_size, coord.z * chunk_size)
	add_child(mesh_instance)
	chunk_nodes[coord] = mesh_instance
	return mesh_instance


func remove_chunk(coord: Vector3i) -> void:
	if not chunk_nodes.has(coord):
		return
	chunk_nodes[coord].queue_free()
	chunk_nodes.erase(coord)
#endregion


#region Queries
func is_chunk_built(coord: Vector3i) -> bool:
	return chunk_nodes.has(coord)


func get_keys() -> Array:
	return chunk_nodes.keys()
#endregion
