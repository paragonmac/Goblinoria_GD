extends RefCounted
class_name WorldRaycaster
## DDA-based voxel raycasting for block selection.

#region Constants
const RAYCAST_VOXEL_OFFSET := Vector3(0.5, 0.5, 0.5)
const RAYCAST_STEP_POSITIVE := 1
const RAYCAST_STEP_NEGATIVE := -1
#endregion

#region State
var world: World
#endregion


#region Initialization
func _init(world_ref: World) -> void:
	world = world_ref
#endregion


#region Raycasting
func raycast_block(ray_origin: Vector3, ray_dir: Vector3, max_distance: float) -> Dictionary:
	var pos := ray_origin
	var dir := ray_dir

	pos += RAYCAST_VOXEL_OFFSET

	var voxel := Vector3i(int(floor(pos.x)), int(floor(pos.y)), int(floor(pos.z)))
	var step_x: int = RAYCAST_STEP_POSITIVE if dir.x >= 0.0 else RAYCAST_STEP_NEGATIVE
	var step_y: int = RAYCAST_STEP_POSITIVE if dir.y >= 0.0 else RAYCAST_STEP_NEGATIVE
	var step_z: int = RAYCAST_STEP_POSITIVE if dir.z >= 0.0 else RAYCAST_STEP_NEGATIVE
	var step := Vector3i(step_x, step_y, step_z)

	var next_x: float = floor(pos.x) + (1.0 if dir.x >= 0.0 else 0.0)
	var next_y: float = floor(pos.y) + (1.0 if dir.y >= 0.0 else 0.0)
	var next_z: float = floor(pos.z) + (1.0 if dir.z >= 0.0 else 0.0)

	var t_max_x: float = INF if dir.x == 0.0 else (next_x - pos.x) / dir.x
	var t_max_y: float = INF if dir.y == 0.0 else (next_y - pos.y) / dir.y
	var t_max_z: float = INF if dir.z == 0.0 else (next_z - pos.z) / dir.z

	var t_delta_x: float = INF if dir.x == 0.0 else abs(1.0 / dir.x)
	var t_delta_y: float = INF if dir.y == 0.0 else abs(1.0 / dir.y)
	var t_delta_z: float = INF if dir.z == 0.0 else abs(1.0 / dir.z)

	var distance := 0.0

	while distance < max_distance:
		if voxel.y >= 0 and voxel.y < world.world_size_y:
			if voxel.y <= world.top_render_y and not world.is_block_empty_id(world.get_block(voxel.x, voxel.y, voxel.z)):
				return {"hit": true, "pos": voxel}

		if t_max_x < t_max_y:
			if t_max_x < t_max_z:
				voxel.x += step.x
				distance = t_max_x
				t_max_x += t_delta_x
			else:
				voxel.z += step.z
				distance = t_max_z
				t_max_z += t_delta_z
		else:
			if t_max_y < t_max_z:
				voxel.y += step.y
				distance = t_max_y
				t_max_y += t_delta_y
			else:
				voxel.z += step.z
				distance = t_max_z
				t_max_z += t_delta_z

	return {"hit": false}
#endregion
