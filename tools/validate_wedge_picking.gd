extends SceneTree
## Selection rays must respect the drawn wedge shape of slopes and stairs: a ray
## over a wedge's empty part reaches what is behind it; a ray into the solid
## part hits the wedge; full cubes are unchanged.

const Flight = preload("res://scripts/stair_flight.gd")

class TestWorld extends World:
	func ensure_chunk_generated(coord: Vector3i) -> ChunkData:
		var chunk := ensure_chunk(coord)
		if chunk != null:
			chunk.generated = true
		return chunk

var checks := 0
var failures := 0


func _init() -> void:
	# A ray entering cell (0,4,0) through its top near the south edge and leaving
	# through the south face high up, then reaching a granite block at (0,4,1).
	var dir := Vector3(0.0, -0.3, 1.0).normalized()
	var entry := Vector3(0.0, 4.5, 0.4)
	var skim_origin := entry - dir * 2.0
	var down_origin := Vector3(0.0, 8.0, 0.0)

	# North-high slope: low (empty above) along its south edge.
	var world := _world()
	_put(world, Vector3i(0, 4, 0), World.TERRAIN_SLOPE_NORTH_ID)
	_check(_hit(world, skim_origin, dir) == Vector3i(0, 4, 1), "Ray over a slope's low side reaches the block behind it")
	_check(_hit(world, down_origin, Vector3.DOWN) == Vector3i(0, 4, 0), "Ray into a slope's solid part hits the slope")
	world.free()

	# Same layout with a full cube is unchanged.
	world = _world()
	_put(world, Vector3i(0, 4, 0), World.BLOCK_ID_GRANITE)
	_check(_hit(world, skim_origin, dir) == Vector3i(0, 4, 0), "Full cubes still stop the ray at the first cell")
	world.free()

	# Lower half of a north-rising flight is at most 0 high along its south edge.
	world = _world()
	_put(world, Vector3i(0, 4, 0), Flight.lower_id(0))
	_put(world, Vector3i(0, 4, -1), Flight.upper_id(0))
	_check(_hit(world, skim_origin, dir) == Vector3i(0, 4, 1), "Ray over a stair's low half reaches the block behind it")
	_check(_hit(world, down_origin, Vector3.DOWN) == Vector3i(0, 4, 0), "Ray into a stair half hits the stair")
	world.free()

	print("Wedge picking: %d checks, %d failures" % [checks, failures])
	quit(1 if failures else 0)


func _world() -> World:
	var world := TestWorld.new()
	world.world_size_y = 16
	world._init_ramp_lookup()
	world.block_registry.load_from_csv(World.BLOCK_DATA_PATH)
	world.raycaster = WorldRaycaster.new(world)
	world.top_render_y = 10
	for x in range(-2, 3):
		for z in range(-2, 3):
			_put(world, Vector3i(x, 3, z), World.BLOCK_ID_GRANITE)
	_put(world, Vector3i(0, 4, 1), World.BLOCK_ID_GRANITE)
	return world


func _put(world: World, cell: Vector3i, id: int) -> void:
	world.set_block_raw(cell.x, cell.y, cell.z, id, true)


func _hit(world: World, origin: Vector3, dir: Vector3) -> Variant:
	var hit := world.raycast_block(origin, dir, 50.0, false)
	return hit.pos if hit.get("hit", false) else null


func _check(value: bool, message: String) -> void:
	checks += 1
	if not value:
		failures += 1
		push_error(message)
