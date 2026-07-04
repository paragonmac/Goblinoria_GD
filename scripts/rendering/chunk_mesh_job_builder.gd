extends RefCounted
class_name ChunkMeshJobBuilder
## Builds immutable chunk meshing jobs for the renderer worker thread.

var world: World
var mesher: ChunkMesher


func configure(world_ref: World, mesher_ref: ChunkMesher) -> void:
	world = world_ref
	mesher = mesher_ref


func update_world(world_ref: World) -> void:
	world = world_ref


func build_mesh_job(
	coord: Vector3i,
	revision: int,
	top_render_y: int,
	prefetch: bool,
	respect_top: bool,
	solid_table: PackedByteArray,
	ramp_table: PackedByteArray,
	color_table: PackedColorArray
) -> Dictionary:
	if world == null or mesher == null:
		return {}
	if not world.is_chunk_coord_valid(coord):
		return {}
	var chunk: ChunkData = world.get_chunk(coord)
	if chunk == null:
		return {}
	if top_render_y < 0:
		top_render_y = world.top_render_y
	var chunk_base_y: int = coord.y * World.CHUNK_SIZE
	if top_render_y < chunk_base_y:
		return {}
	var local_top: int = World.CHUNK_SIZE - 1
	var missing_neighbors: Array = []
	var neighbors: Dictionary = {
		"x_neg": _copy_neighbor_blocks(Vector3i(coord.x - 1, coord.y, coord.z), missing_neighbors),
		"x_pos": _copy_neighbor_blocks(Vector3i(coord.x + 1, coord.y, coord.z), missing_neighbors),
		"y_neg": _copy_neighbor_blocks(Vector3i(coord.x, coord.y - 1, coord.z), missing_neighbors),
		"y_pos": _copy_neighbor_blocks(Vector3i(coord.x, coord.y + 1, coord.z), missing_neighbors),
		"z_neg": _copy_neighbor_blocks(Vector3i(coord.x, coord.y, coord.z - 1), missing_neighbors),
		"z_pos": _copy_neighbor_blocks(Vector3i(coord.x, coord.y, coord.z + 1), missing_neighbors),
	}
	var padded_blocks := mesher.build_padded_block_buffer(World.CHUNK_SIZE, chunk.blocks, neighbors, World.BLOCK_ID_AIR)
	return {
		"coord": coord,
		"cx": coord.x,
		"cy": coord.y,
		"cz": coord.z,
		"chunk_size": World.CHUNK_SIZE,
		"top_render_y": top_render_y,
		"air_id": World.BLOCK_ID_AIR,
		"blocks": chunk.blocks.duplicate(),
		"padded_blocks": padded_blocks,
		"solid_table": solid_table,
		"ramp_table": ramp_table,
		"color_table": color_table,
		"mesh_revision": revision,
		"local_top": local_top,
		"prefetch": prefetch,
		"respect_top": respect_top,
		"missing_neighbors": missing_neighbors,
	}


func _copy_neighbor_blocks(coord: Vector3i, missing_neighbors: Array) -> Variant:
	if world == null:
		return null
	if not world.is_chunk_coord_valid(coord):
		return null
	var chunk: ChunkData = world.get_chunk(coord)
	if chunk == null or not chunk.generated:
		missing_neighbors.append(coord)
		return null
	return chunk.blocks.duplicate()
