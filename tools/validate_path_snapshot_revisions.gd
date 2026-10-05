extends SceneTree
## Path bids must survive render-only churn (remeshing, neighbor streaming,
## eviction) and go stale only when terrain they searched is edited.

class TestWorld extends World:
	func ensure_chunk_generated(coord: Vector3i) -> ChunkData:
		var chunk := ensure_chunk(coord)
		if chunk != null:
			chunk.generated = true
		return chunk

var checks := 0
var failures := 0


func _init() -> void:
	var world := TestWorld.new()
	world.world_size_y = 16
	world._init_ramp_lookup()
	world.block_registry.load_from_csv(World.BLOCK_DATA_PATH)
	for x in range(0, 8):
		for z in range(0, 8):
			world.set_block_raw(x, 3, z, World.BLOCK_ID_GRANITE, true)
	var start := Vector3i(1, 4, 1)
	var goal := Vector3i(6, 4, 6)
	var home := world.world_to_chunk_coords(start.x, start.y, start.z)

	var snapshot := PathWorldSnapshot.new()
	snapshot.capture_from_world(world, start, [goal], 32, 8)
	_check(snapshot.chunk_revisions.has(home) and int(snapshot.chunk_revisions[home]) >= 0, "Snapshot records the searched chunk")
	_check(snapshot.revisions_match(world), "Fresh snapshot matches")

	var chunk: ChunkData = world.get_chunk(home)
	chunk.mesh_revision += 5
	chunk.mesh_state = ChunkData.MESH_STATE_NONE
	_check(snapshot.revisions_match(world), "Remeshing alone keeps the bid valid")

	var absent := Vector3i(home.x + 1, home.y, home.z)
	_check(int(snapshot.chunk_revisions.get(absent, -1)) == -1, "Neighbor chunk was absent from the snapshot")
	world.ensure_chunk_generated(absent)
	_check(snapshot.revisions_match(world), "A chunk streaming in after capture keeps the bid valid")

	world.chunks.erase(home)
	_check(snapshot.revisions_match(world), "Evicting a searched chunk is not an edit")
	world.chunks[home] = chunk

	world.set_block_raw(3, 4, 3, World.BLOCK_ID_GRANITE, true)
	_check(not snapshot.revisions_match(world), "Editing searched terrain makes the bid stale")

	var unchanged := PathWorldSnapshot.new()
	unchanged.capture_from_world(world, start, [goal], 32, 8)
	world.set_block_raw(3, 4, 3, World.BLOCK_ID_GRANITE, true)
	_check(unchanged.revisions_match(world), "Writing an identical block is not an edit")

	world.free()
	print("Path snapshot revisions: %d checks, %d failures" % [checks, failures])
	quit(1 if failures else 0)


func _check(value: bool, message: String) -> void:
	checks += 1
	if not value:
		failures += 1
		push_error(message)
