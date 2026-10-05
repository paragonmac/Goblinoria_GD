extends RefCounted
class_name WorldRaycaster
## DDA-based voxel raycasting for block selection.

#region Constants
const RAYCAST_VOXEL_OFFSET := Vector3(0.5, 0.5, 0.5)
const RAYCAST_STEP_POSITIVE := 1
const RAYCAST_STEP_NEGATIVE := -1
const WEDGE_SAMPLES := 8
const StairFlightScript = preload("res://scripts/stair_flight.gd")
#endregion

#region State
var world: World
#endregion


#region Initialization
func _init(world_ref: World) -> void:
	world = world_ref
#endregion


#region Raycasting
func raycast_block(ray_origin: Vector3, ray_dir: Vector3, max_distance: float, generate_missing: bool = true) -> Dictionary:
	# SEE-ADR-006: Click selection raycasts visible world voxels at or below top_render_y.
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
		if world.is_block_coord_valid(voxel.x, voxel.y, voxel.z) and voxel.y <= world.top_render_y:
			var block_id := world.get_block(voxel.x, voxel.y, voxel.z) if generate_missing \
				else world.get_block_no_generate(voxel.x, voxel.y, voxel.z)
			if not world.is_block_empty_id(block_id):
				# Slopes and stairs are drawn as wedges: only count a hit where the
				# ray actually passes under the sloped surface, so clicks over the
				# empty part reach the floor or wall the player sees behind it.
				if not world.is_ramp_block_id(block_id) \
						or _ray_hits_wedge(pos, dir, distance, minf(t_max_x, minf(t_max_y, t_max_z)), voxel, block_id):
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


## Samples the ray's path through a slope/stair cell (t_enter..t_exit, in the
## offset space used above) against the same corner heights the mesher and
## pathfinder use, bilinearly interpolated across the cell.
func _ray_hits_wedge(origin: Vector3, dir: Vector3, t_enter: float, t_exit: float, voxel: Vector3i, block_id: int) -> bool:
	var heights := _wedge_corner_heights(block_id)
	if heights.is_empty():
		return true
	var span := maxf(t_exit - t_enter, 0.0)
	for i in WEDGE_SAMPLES:
		var t := t_enter + span * (float(i) + 0.5) / float(WEDGE_SAMPLES)
		var local := origin + dir * t - Vector3(voxel) - Vector3(0.5, 0.5, 0.5)
		var u := clampf(local.x + 0.5, 0.0, 1.0)
		var v := clampf(local.z + 0.5, 0.0, 1.0)
		var north := lerpf(float(heights.nw), float(heights.ne), u)
		var south := lerpf(float(heights.sw), float(heights.se), u)
		if local.y <= lerpf(north, south, v):
			return true
	return false


func _wedge_corner_heights(block_id: int) -> Dictionary:
	if StairFlightScript.is_flight(block_id):
		return StairFlightScript.corner_heights(block_id)
	var pathfinder = world.get("pathfinder")
	if pathfinder == null:
		return {}
	# Pathfinder heights are +/-1 for high/low corners; cells span +/-0.5.
	var raw: Dictionary = pathfinder._ramp_corner_heights(block_id)
	var scaled := {}
	for key in raw:
		scaled[key] = float(raw[key]) * 0.5
	return scaled
#endregion
