extends SceneTree
## View-driven mesh requests (ADR-015): the adopted visibility view asks for the
## meshes it needs, top layer first, and reports when they are all built.
##
## Uses stand-in world and renderer objects with real ChunkData, so the rules are
## checked without a scene:
## 1. Flat ground cut at the surface needs only the top layer.
## 2. Ground below the cut needs every layer from the surface up to the cut.
## 3. A pit needs its own column and its face neighbours down to its floor, and
##    nothing else deeper.
## 4. A view is reported meshed only when every needed chunk is built; built
##    chunks are not asked for again.
## 5. A terrain change is seen once the column is forgotten.
## 6. A view never creates or generates terrain: chunks with no blocks are
##    skipped, and asked for once they exist.
## 7. The backlog of waiting chunks is capped.
## 8. A chunk that never builds cannot hold the view forever.

const Requester = preload("res://scripts/rendering/view_mesh_requester.gd")
const N := 8
const LOW_LAYER := 22
const HIGH_LAYER := 31
const BIG_BUDGET := 2_000_000

var checks := 0
var failures := 0
var next_view := 1


class StubScheduler extends RefCounted:
	var jobs := {}

	func get_job_revision(coord: Vector3i) -> int:
		return int(jobs.get(coord, -1))


class StubWorld extends RefCounted:
	var chunks := {}
	var top_render_y := 226
	var world_size_y := 256
	var radius := 3
	var generation_requests: Array[Vector3i] = []

	func is_chunk_coord_valid(coord: Vector3i) -> bool:
		return absi(coord.x) <= radius and absi(coord.z) <= radius and coord.y >= 0 and coord.y < 32

	func get_chunk(coord: Vector3i) -> ChunkData:
		return chunks.get(coord)

	func request_chunk_generation_async(coord: Vector3i, _high_priority: bool = false, _queue_mesh: bool = true) -> bool:
		generation_requests.append(coord)
		var chunk: ChunkData = chunks.get(coord)
		return chunk != null and chunk.generated


class StubRenderer extends RefCounted:
	var world
	var block_solid_table := PackedByteArray()
	var mesh_scheduler := StubScheduler.new()
	var queued: Array[Vector3i] = []

	func _ensure_block_tables() -> void:
		block_solid_table.resize(256)
		block_solid_table.fill(1)
		block_solid_table[0] = 0

	func queue_chunk_mesh_build(coord: Vector3i, _top: int = -1, _respect: bool = false, _high: bool = false) -> void:
		var chunk: ChunkData = world.get_chunk(coord)
		queued.append(coord)
		chunk.mesh_state = ChunkData.MESH_STATE_PENDING
		mesh_scheduler.jobs[coord] = chunk.mesh_revision

	## Stands in for the mesh workers: everything queued is now built.
	func build_all() -> void:
		for coord: Vector3i in queued:
			world.get_chunk(coord).mesh_state = ChunkData.MESH_STATE_READY


func _init() -> void:
	_test_flat_ground()
	_test_ground_below_cut()
	_test_pit()
	_test_terrain_change()
	_test_not_generated()
	_test_backlog_cap()
	_test_stall()
	print("View mesh requester: %d checks, %d failures" % [checks, failures])
	quit(1 if failures else 0)


func _check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures += 1
		if failures <= 16:
			push_error(message)


## A world of generated chunks whose columns are solid up to and including
## surface_y, in layers LOW_LAYER..HIGH_LAYER.
func _make(surface_y: int, top_render_y: int, radius: int = 3) -> Array:
	var world := StubWorld.new()
	world.top_render_y = top_render_y
	world.radius = radius
	for cx in range(-radius, radius + 1):
		for cz in range(-radius, radius + 1):
			for cy in range(LOW_LAYER, HIGH_LAYER + 1):
				var chunk := ChunkData.new(N, 0)
				chunk.generated = true
				world.chunks[Vector3i(cx, cy, cz)] = chunk
			_fill_column(world, cx, cz, surface_y)
	var renderer := StubRenderer.new()
	renderer.world = world
	var requester = Requester.new()
	requester.configure(renderer)
	return [world, renderer, requester]


## Makes column (cx, cz) solid up to and including surface_y and air above.
func _fill_column(world: StubWorld, cx: int, cz: int, surface_y: int) -> void:
	for cy in range(LOW_LAYER, HIGH_LAYER + 1):
		var chunk: ChunkData = world.chunks[Vector3i(cx, cy, cz)]
		for ly in N:
			var value := 1 if cy * N + ly <= surface_y else 0
			for lz in N:
				for lx in N:
					chunk.blocks[lx + ly * N + lz * N * N] = value


## An adopted view of the whole stand-in world, listed as the cull kernel lists
## it: layer by layer from the bottom, then X, then Z.
func _view(world: StubWorld) -> Dictionary:
	var coords: Array[Vector3i] = []
	for cy in range(LOW_LAYER, HIGH_LAYER + 1):
		for cx in range(-world.radius, world.radius + 1):
			for cz in range(-world.radius, world.radius + 1):
				coords.append(Vector3i(cx, cy, cz))
	next_view += 1
	return {"request_id": next_view, "accepted_coords": coords}


func _as_set(coords: Array) -> Dictionary:
	var result := {}
	for coord: Vector3i in coords:
		result[coord] = true
	return result


## Every chunk of the stand-in world in the given layers, for the given columns
## (all columns when columns is empty).
func _expect(world: StubWorld, layers: Array, columns: Array = []) -> Dictionary:
	var result := {}
	for cy: int in layers:
		for cx in range(-world.radius, world.radius + 1):
			for cz in range(-world.radius, world.radius + 1):
				if columns.is_empty() or columns.has(Vector2i(cx, cz)):
					result[Vector3i(cx, cy, cz)] = true
	return result


func _same(actual: Dictionary, expected: Dictionary) -> bool:
	if actual.size() != expected.size():
		return false
	for coord: Vector3i in expected:
		if not actual.has(coord):
			return false
	return true


func _test_flat_ground() -> void:
	var made := _make(226, 226)
	var world: StubWorld = made[0]
	var renderer: StubRenderer = made[1]
	var requester = made[2]
	requester.begin_view(_view(world))
	var done: bool = requester.pump(BIG_BUDGET)
	_check(not done, "flat: the view was reported meshed before anything was built")
	_check(_same(_as_set(renderer.queued), _expect(world, [28])),
		"flat: asked for %d chunks, expected the 49 of the top layer only" % renderer.queued.size())
	_check(renderer.queued.size() == _as_set(renderer.queued).size(), "flat: a chunk was asked for twice")
	_check(not requester.pump(BIG_BUDGET), "flat: reported meshed while the meshes were still building")
	renderer.build_all()
	_check(requester.pump(BIG_BUDGET), "flat: not reported meshed after every needed chunk was built")
	_check(requester.meshed_view_id == next_view, "flat: the wrong view was reported meshed")
	_check(not requester.pump(BIG_BUDGET), "flat: the same view was reported meshed twice")
	# A new view of built ground asks for nothing and is meshed at once.
	var before: int = renderer.queued.size()
	requester.begin_view(_view(world))
	_check(requester.pump(BIG_BUDGET) and renderer.queued.size() == before,
		"flat: a view of built ground was not meshed at once, or asked again")
	# The walk stopped at the first buried layer instead of visiting all 490 coords.
	_check(requester.last_walked <= 60, "flat: walked %d coordinates for a 49-chunk surface" % requester.last_walked)


func _test_ground_below_cut() -> void:
	# Cut at y 240 (layer 30), surface at y 226 (layer 28).
	var made := _make(226, 240)
	var world: StubWorld = made[0]
	var renderer: StubRenderer = made[1]
	var requester = made[2]
	requester.begin_view(_view(world))
	requester.pump(BIG_BUDGET)
	_check(_same(_as_set(renderer.queued), _expect(world, [28, 29, 30])),
		"below cut: asked for %d chunks, expected layers 28 to 30 (147)" % renderer.queued.size())


func _test_pit() -> void:
	var made := _make(226, 226)
	var world: StubWorld = made[0]
	var renderer: StubRenderer = made[1]
	var requester = made[2]
	# Column (0, 0) is dug out down to y 204: its floor is in layer 25.
	_fill_column(world, 0, 0, 204)
	requester.begin_view(_view(world))
	requester.pump(BIG_BUDGET)
	var expected := _expect(world, [28])
	var open_columns := [Vector2i(0, 0), Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]
	expected.merge(_expect(world, [25, 26, 27], open_columns))
	var asked := _as_set(renderer.queued)
	_check(_same(asked, expected), "pit: asked for %d chunks, expected %d (top layer plus the pit column and its four face neighbours down to layer 25)" % [asked.size(), expected.size()])
	_check(not asked.has(Vector3i(1, 27, 1)), "pit: a diagonal neighbour's buried chunk was asked for")
	_check(not asked.has(Vector3i(0, 24, 0)), "pit: a chunk below the pit floor was asked for")


func _test_terrain_change() -> void:
	var made := _make(226, 226)
	var world: StubWorld = made[0]
	var renderer: StubRenderer = made[1]
	var requester = made[2]
	requester.begin_view(_view(world))
	requester.pump(BIG_BUDGET)
	renderer.build_all()
	requester.pump(BIG_BUDGET)
	# Dig column (2, 2) down to y 212 (layer 26), as a terrain change would.
	_fill_column(world, 2, 2, 212)
	world.chunks[Vector3i(2, 28, 2)].mesh_state = ChunkData.MESH_STATE_NONE
	world.chunks[Vector3i(2, 28, 2)].mesh_revision += 1
	requester.forget_column(2, 2)
	renderer.queued.clear()
	requester.begin_view(_view(world))
	_check(not requester.pump(BIG_BUDGET), "change: reported meshed while the dug column was unbuilt")
	var asked := _as_set(renderer.queued)
	_check(asked.has(Vector3i(2, 26, 2)) and asked.has(Vector3i(2, 27, 2)) and asked.has(Vector3i(2, 28, 2)),
		"change: the dug column was not asked for down to its new floor")
	_check(asked.has(Vector3i(1, 26, 2)) and asked.has(Vector3i(2, 26, 3)), "change: the dug column's neighbours were not asked for")
	_check(not asked.has(Vector3i(0, 27, 0)), "change: an untouched column was asked for below its surface")


func _test_not_generated() -> void:
	var made := _make(226, 226)
	var world: StubWorld = made[0]
	var renderer: StubRenderer = made[1]
	var requester = made[2]
	var missing := Vector3i(-2, 28, -2)
	var absent := Vector3i(2, 28, -2)
	world.chunks[missing].generated = false
	world.chunks.erase(absent)
	var chunk_count: int = world.chunks.size()
	requester.begin_view(_view(world))
	requester.pump(BIG_BUDGET)
	_check(world.generation_requests.is_empty(), "ungenerated: a view asked for terrain to be generated")
	_check(world.chunks.size() == chunk_count, "ungenerated: a view created a chunk")
	_check(not renderer.queued.has(missing) and not renderer.queued.has(absent),
		"ungenerated: a mesh was queued for a chunk with no blocks")
	renderer.build_all()
	_check(requester.pump(BIG_BUDGET), "ungenerated: chunks with no blocks held the view")
	# Generation delivers the chunk; the next view asks for its mesh.
	world.chunks[missing].generated = true
	requester.begin_view(_view(world))
	requester.pump(BIG_BUDGET)
	_check(renderer.queued.has(missing), "ungenerated: the chunk was not asked for once it had blocks")


func _test_backlog_cap() -> void:
	# 15 x 15 columns: 225 top-layer chunks, more than the backlog allows at once.
	var made := _make(226, 226, 7)
	var world: StubWorld = made[0]
	var renderer: StubRenderer = made[1]
	var requester = made[2]
	requester.begin_view(_view(world))
	requester.pump(BIG_BUDGET)
	_check(renderer.queued.size() == Requester.MAX_OUTSTANDING,
		"backlog: %d chunks were asked for at once, the cap is %d" % [renderer.queued.size(), Requester.MAX_OUTSTANDING])
	renderer.build_all()
	requester.pump(BIG_BUDGET)
	_check(renderer.queued.size() == 225, "backlog: %d of 225 chunks were asked for after the first batch was built" % renderer.queued.size())
	renderer.build_all()
	_check(requester.pump(BIG_BUDGET) or requester.meshed_view_id == next_view, "backlog: the view never finished")


func _test_stall() -> void:
	var made := _make(226, 226)
	var world: StubWorld = made[0]
	var renderer: StubRenderer = made[1]
	var requester = made[2]
	requester.begin_view(_view(world))
	requester.pump(BIG_BUDGET)
	# Nothing is ever built.
	_check(not requester.pump(BIG_BUDGET), "stall: reported meshed at once with nothing built")
	OS.delay_usec(Requester.STALL_USEC + 100_000)
	_check(requester.pump(BIG_BUDGET), "stall: a view whose chunks never build held on past the stall limit")
	_check(requester.stalled_views == 1, "stall: the stalled view was not counted")
