extends SceneTree
## Differential and property contract for the dense navigation grid.

const StairFlightScript = preload("res://scripts/stair_flight.gd")
const TaskWorkPositionRules = preload("res://scripts/task_work_position_rules.gd")
const NavGridScript = preload("res://scripts/pathfinding/nav_grid.gd")
const ProbeSurfaceY := 227
const ProbeRoomY := 223
const ProbeHalf := 40

var checks := 0
var failures := 0
var failure_messages: Array[String] = []


func _init() -> void:
	_run.call_deferred()


func _run() -> void:
	var fixture := _make_fixture()
	var pf := Pathfinder.new()
	var grid = NavGridScript.new()
	grid.build(fixture, Vector3i(-8, 0, -8), Vector3i(7, 15, 7), pf)
	_compare_all_cells(fixture, grid, pf, "mixed fixture")
	_check_touched_box_edge(fixture, grid, pf, "mixed fixture")
	_check_ramps_and_flights(fixture, grid)
	_check_fixture_searches(fixture, grid, pf)
	_check_node_cap(fixture, grid)
	var probe := _make_probe()
	var probe_grid = NavGridScript.new()
	# The probe snapshot remains the original 80 x 24 x 80 volume. Its evaluated
	# navigation box encloses every sampled worker, work position and flight.
	var probe_box_min := Vector3i(-20, ProbeRoomY, -8)
	var probe_box_max := Vector3i(20, ProbeSurfaceY, 25)
	var probe_build_ms := 1.0e30
	for _run_index in 3:
		var build_start := Time.get_ticks_usec()
		probe_grid.build(probe, probe_box_min, probe_box_max, pf)
		probe_build_ms = minf(probe_build_ms, float(Time.get_ticks_usec() - build_start) / 1000.0)
	_compare_all_cells(probe, probe_grid, pf, "four-flight probe")
	_check_touched_box_edge(probe, probe_grid, pf, "four-flight probe")
	_check_probe_distances(probe, probe_grid, pf)
	var probe_tasks := _probe_tasks()
	var probe_goals: Array = TaskWorkPositionRules.task_work_positions(
		probe, pf, probe_tasks[0], TaskQueue.TaskType.DIG
	)
	var bfs_start := Time.get_ticks_usec()
	var probe_result: Dictionary = probe_grid.reverse_distances(probe_goals, _probe_workers())
	var reverse_ms := float(Time.get_ticks_usec() - bfs_start) / 1000.0
	print("Nav grid probe timing (best of 3): build %.2f ms, reverse BFS %.2f ms (%d nodes)" % [
		probe_build_ms, reverse_ms, int(probe_result["nodes"])
	])
	var big_snapshot := _make_performance_snapshot()
	var big_min := Vector3i(0, 1, 0)
	var big_max := Vector3i(63, 25, 95)
	var big_cells := 64 * 25 * 96
	var big_build_ms := 1.0e30
	var big_grid = NavGridScript.new()
	for _run_index in 3:
		var big_start := Time.get_ticks_usec()
		big_grid.build(big_snapshot, big_min, big_max, pf)
		big_build_ms = minf(big_build_ms, float(Time.get_ticks_usec() - big_start) / 1000.0)
	var big_goals: Array[Vector3i] = [Vector3i(32, 1, 48)]
	var big_starts: Array[Vector3i] = [Vector3i(2, 1, 2), Vector3i(60, 1, 90)]
	var big_bfs_start := Time.get_ticks_usec()
	var big_result: Dictionary = big_grid.reverse_distances(big_goals, big_starts)
	var big_bfs_ms := float(Time.get_ticks_usec() - big_bfs_start) / 1000.0
	print("Nav grid 153,600-cell timing (best of 3): build %.2f ms, reverse BFS %.2f ms (%d nodes)" % [
		big_build_ms, big_bfs_ms, int(big_result["nodes"])
	])
	if big_build_ms > 50.0:
		print("WARN: 153,600-cell NavGrid build exceeded 50 ms")
	if failures == 0:
		print("Nav grid: %d checks, %d failures" % [checks, failures])
		quit(0)
	else:
		for message in failure_messages:
			push_error(message)
		print("Nav grid: %d checks, %d failures" % [checks, failures])
		quit(1)


func _check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures += 1
		if failure_messages.size() < 20:
			failure_messages.append(message)


func _check_touched_box_edge(snapshot: PathWorldSnapshot, grid, pf: Pathfinder, label: String) -> void:
	var expected := false
	for y in range(grid.box_min.y, grid.box_max.y + 1):
		for z in range(grid.box_min.z, grid.box_max.z + 1):
			for x in range(grid.box_min.x, grid.box_max.x + 1):
				if x != grid.box_min.x and x != grid.box_max.x \
					and y != grid.box_min.y and y != grid.box_max.y \
					and z != grid.box_min.z and z != grid.box_max.z:
					continue
				if not pf.is_walkable(snapshot, x, y, z):
					continue
				var p := Vector3i(x, y, z)
				for neighbor: Vector3i in pf.get_neighbors(snapshot, p):
					if not _inside(grid, neighbor):
						expected = true
						break
				if expected:
					break
			if expected:
				break
	_check(not expected or grid._flood_touched_box_edge, "%s touched_box_edge covers every walkable boundary escape" % label)


func _make_empty_snapshot(min_pos: Vector3i, max_pos: Vector3i, world_height: int) -> PathWorldSnapshot:
	var world := World.new()
	world.world_size_y = world_height
	world._init_ramp_lookup()
	world.block_registry.load_from_csv(World.BLOCK_DATA_PATH)
	var snap := PathWorldSnapshot.new()
	snap.world_size_y = world_height
	snap.chunk_size = World.CHUNK_SIZE
	snap.air_id = World.BLOCK_ID_AIR
	snap.min_block = min_pos
	snap.max_block = max_pos
	snap.solid_table = world.block_registry.solid.duplicate()
	snap.ramp_table.resize(BlockRegistry.TABLE_SIZE)
	for id in range(BlockRegistry.TABLE_SIZE):
		snap.ramp_table[id] = 1 if world.is_ramp_block_id(id) else 0
	var min_chunk := Vector3i(_floor_div(min_pos.x, snap.chunk_size), _floor_div(min_pos.y, snap.chunk_size), _floor_div(min_pos.z, snap.chunk_size))
	var max_chunk := Vector3i(_floor_div(max_pos.x, snap.chunk_size), _floor_div(max_pos.y, snap.chunk_size), _floor_div(max_pos.z, snap.chunk_size))
	for cx in range(min_chunk.x, max_chunk.x + 1):
		for cy in range(min_chunk.y, max_chunk.y + 1):
			for cz in range(min_chunk.z, max_chunk.z + 1):
				var blocks := PackedByteArray()
				blocks.resize(World.CHUNK_VOLUME)
				snap.chunks[Vector3i(cx, cy, cz)] = blocks
	world.free()
	return snap


func _put(snap: PathWorldSnapshot, p: Vector3i, id: int) -> void:
	var cs := snap.chunk_size
	var chunk := Vector3i(_floor_div(p.x, cs), _floor_div(p.y, cs), _floor_div(p.z, cs))
	var blocks: PackedByteArray = snap.chunks[chunk]
	blocks[(_positive_mod(p.z, cs) * cs + _positive_mod(p.y, cs)) * cs + _positive_mod(p.x, cs)] = id
	snap.chunks[chunk] = blocks


func _make_fixture() -> PathWorldSnapshot:
	var snap := _make_empty_snapshot(Vector3i(-9, 0, -9), Vector3i(8, 15, 8), 16)
	for x in range(-9, 9):
		for z in range(-9, 9):
			_put(snap, Vector3i(x, 0, z), World.BLOCK_ID_GRANITE)
	# A cliff, a roof over a walkable tunnel, and a water cell.
	for x in range(-7, -3):
		for z in range(2, 6):
			_put(snap, Vector3i(x, 1, z), World.BLOCK_ID_GRANITE)
	for x in range(-2, 3):
		_put(snap, Vector3i(x, 3, -7), World.BLOCK_ID_GRANITE)
	_put(snap, Vector3i(0, 1, 6), World.BLOCK_ID_WATER)
	# Every legacy/player and generated terrain ramp identity, including all
	# outer and inner corners, gets a supported placement in the same fixture.
	var ramp_ids := World.RAMP_BLOCK_IDS
	for i in range(ramp_ids.size()):
		var p := Vector3i(-7 + i % 6, 1, -5 + int(i / 6))
		_put(snap, p, ramp_ids[i])
	# All rotations with both lower and upper cells, plus a second set representing
	# descending flights. Geometry is identical; the vertical approach differs.
	var station := 0
	for _up in [true, false]:
		for rotation in 4:
			var x := 2 + (station % 2) * 3
			var z := -4 + int(station / 2) * 3
			var lower := Vector3i(x, 1, z)
			var upper := lower + StairFlightScript.direction(rotation)
			_put(snap, lower, StairFlightScript.lower_id(rotation))
			_put(snap, upper, StairFlightScript.upper_id(rotation))
			station += 1
	return snap


func _compare_all_cells(snapshot: PathWorldSnapshot, grid, pf: Pathfinder, label: String) -> void:
	for y in range(grid.box_min.y, grid.box_max.y + 1):
		for z in range(grid.box_min.z, grid.box_max.z + 1):
			for x in range(grid.box_min.x, grid.box_max.x + 1):
				var p := Vector3i(x, y, z)
				var expected := {}
				for neighbor: Vector3i in pf.get_neighbors(snapshot, p):
					if _inside(grid, neighbor):
						expected[neighbor] = true
				var actual := {}
				for neighbor: Vector3i in grid.forward_neighbors(p):
					actual[neighbor] = true
				_check(actual.size() == expected.size(), "%s neighbor count differs at %s" % [label, p])
				if actual.size() == expected.size():
					for neighbor in expected:
						_check(actual.has(neighbor), "%s missing forward edge %s -> %s" % [label, p, neighbor])


func _check_ramps_and_flights(snapshot: PathWorldSnapshot, grid) -> void:
	for id in World.RAMP_BLOCK_IDS:
		_check(snapshot.is_ramp_block_id(id), "fixture ramp ID %d is absent from registry" % id)
	_check(World.RAMP_BLOCK_IDS.size() >= 24, "fixture registry includes ramp/slope/corner identities")
	var pf := Pathfinder.new()
	var station := 0
	for _up in [true, false]:
		for rotation in 4:
			var x := 2 + (station % 2) * 3
			var z := -4 + int(station / 2) * 3
			var lower := Vector3i(x, 1, z)
			var upper := lower + StairFlightScript.direction(rotation)
			_check(snapshot.get_block_no_generate(x, 1, z) == StairFlightScript.lower_id(rotation), "flight lower identity is present for rotation %d" % rotation)
			_check(snapshot.get_block_no_generate(upper.x, upper.y, upper.z) == StairFlightScript.upper_id(rotation), "flight upper identity is present for rotation %d" % rotation)
			_check(pf.is_valid_flight_cell(snapshot, lower) and pf.is_valid_flight_cell(snapshot, upper), "flight pair is valid for rotation %d" % rotation)
			station += 1
	_check(snapshot.get_block_no_generate(0, 1, 6) == World.BLOCK_ID_WATER, "water fixture is present")
	_check(not snapshot.is_block_solid_id(World.BLOCK_ID_AIR), "non-solid air fixture is present")
	_check(snapshot.get_block_no_generate(0, 3, -7) == World.BLOCK_ID_GRANITE, "dug tunnel roof fixture is present")
	_check(grid._flood_touched_box_edge, "fixture records real outgoing neighbors dropped at box boundary")


func _check_fixture_searches(snapshot: PathWorldSnapshot, grid, pf: Pathfinder) -> void:
	var goals: Array[Vector3i] = [Vector3i(0, 1, 0), Vector3i(-5, 1, 1), Vector3i(4, 1, 5)]
	var starts: Array[Vector3i] = [
		Vector3i(-7, 1, -7), Vector3i(0, 1, 0), Vector3i(2, 1, -4), Vector3i(-7, 1, -5),
		Vector3i(-5, 1, 1), Vector3i(7, 1, 7), Vector3i(0, 1, 6),
	]
	var result: Dictionary = grid.reverse_distances(goals, starts)
	_check(bool(result["complete"]), "uncapped fixture flood completes")
	for start: Vector3i in starts:
		var forward := _forward_distances(snapshot, pf, start)
		var expected := -1
		for goal: Vector3i in goals:
			if forward.has(goal):
				var length := int(forward[goal]) + 1
				if expected < 0 or length < expected:
					expected = length
		_check(int(result["distances"].get(start, -999)) == expected, "reverse distance matches forward BFS from %s" % start)
		var path_a: Array = grid.path_from(start)
		var path_b: Array = grid.path_from(start)
		_check(path_a == path_b, "path_from is deterministic for %s" % start)
		if expected < 0:
			_check(path_a.is_empty(), "unreachable start has no path")
		else:
			_check(path_a.size() == expected and path_a[0] == start and goals.has(path_a[path_a.size() - 1]), "path format/length/end match for %s" % start)
			for i in range(path_a.size() - 1):
				_check(pf.get_neighbors(snapshot, path_a[i]).has(path_a[i + 1]), "path step is a real forward edge")
	# Repeat random deterministic start/goal subsets, including a blocked start.
	var rng := RandomNumberGenerator.new()
	rng.seed = 85173
	var walkable_cells: Array[Vector3i] = []
	for y in range(1, 5):
		for z in range(-7, 7):
			for x in range(-7, 7):
				if pf.is_walkable(snapshot, x, y, z):
					walkable_cells.append(Vector3i(x, y, z))
	for sample in 12:
		var random_goals: Array[Vector3i] = []
		for _goal in 3:
			random_goals.append(walkable_cells[rng.randi_range(0, walkable_cells.size() - 1)])
		var random_starts: Array[Vector3i] = [Vector3i(-8, 1, -8)]
		for _start in 5:
			random_starts.append(walkable_cells[rng.randi_range(0, walkable_cells.size() - 1)])
		var reverse: Dictionary = grid.reverse_distances(random_goals, random_starts)
		for start: Vector3i in random_starts:
			var forward := _forward_distances(snapshot, pf, start)
			var expected := -1
			for goal: Vector3i in random_goals:
				if forward.has(goal):
					var length := int(forward[goal]) + 1
					if expected < 0 or length < expected:
						expected = length
			_check(int(reverse["distances"].get(start, -999)) == expected, "random goal-set distance matches forward BFS")


func _check_node_cap(snapshot: PathWorldSnapshot, grid) -> void:
	var start := Vector3i(-7, 1, -7)
	var capped: Dictionary = grid.reverse_distances([Vector3i(6, 1, 6)], [start], 1)
	_check(not bool(capped["complete"]), "node cap reports an incomplete flood")
	if capped["distances"].has(start):
		_check(int(capped["distances"][start]) >= 0, "capped flood never labels an unsettled start unreachable")
	else:
		_check(not capped["complete"], "missing capped result is distinguished by complete=false")
	var full: Dictionary = grid.reverse_distances([Vector3i(6, 1, 6)], [start])
	if int(full["distances"].get(start, -1)) == -1:
		_check(bool(full["complete"]), "-1 is only returned after exhaustive proof")
	_check(snapshot.is_block_coord_valid(start.x, start.y, start.z), "cap test start is valid")


func _make_performance_snapshot() -> PathWorldSnapshot:
	var snap := _make_empty_snapshot(Vector3i(-1, 0, -1), Vector3i(64, 26, 96), 27)
	for x in range(-1, 65):
		for z in range(-1, 97):
			_put(snap, Vector3i(x, 0, z), World.BLOCK_ID_GRANITE)
	for cell in [Vector3i(12, 1, 12), Vector3i(13, 1, 12), Vector3i(45, 1, 70), Vector3i(46, 1, 70)]:
		_put(snap, cell, World.RAMP_BLOCK_IDS[0])
	var directions := [0, 1, 2]
	for flight_index in directions.size():
		var rotation: int = directions[flight_index]
		var lower := Vector3i(18 + flight_index * 12, 3, 24 + flight_index * 20)
		for dx in range(-2, 3):
			for dz in range(-2, 3):
				_put(snap, Vector3i(lower.x + dx, 2, lower.z + dz), World.BLOCK_ID_GRANITE)
		var upper := lower + StairFlightScript.direction(rotation)
		_put(snap, lower, StairFlightScript.lower_id(rotation))
		_put(snap, upper, StairFlightScript.upper_id(rotation))
	return snap


func _forward_distances(snapshot: PathWorldSnapshot, pf: Pathfinder, start: Vector3i) -> Dictionary:
	var distance := {start: 0}
	var queue: Array[Vector3i] = [start]
	var head := 0
	while head < queue.size():
		var current := queue[head]
		head += 1
		for next: Vector3i in pf.get_neighbors(snapshot, current):
			if distance.has(next):
				continue
			distance[next] = int(distance[current]) + 1
			queue.append(next)
	return distance


func _inside(grid, p: Vector3i) -> bool:
	return p.x >= grid.box_min.x and p.x <= grid.box_max.x \
		and p.y >= grid.box_min.y and p.y <= grid.box_max.y \
		and p.z >= grid.box_min.z and p.z <= grid.box_max.z


func _make_probe() -> PathWorldSnapshot:
	var snap := _make_empty_snapshot(
		Vector3i(-ProbeHalf, 216, -ProbeHalf),
		Vector3i(ProbeHalf - 1, 239, ProbeHalf - 1),
		256
	)
	for y in range(216, 240):
		for z in range(-ProbeHalf, ProbeHalf):
			for x in range(-ProbeHalf, ProbeHalf):
				if y <= ProbeSurfaceY - 1:
					_put(snap, Vector3i(x, y, z), World.BLOCK_ID_GRANITE)
	var lower_id := StairFlightScript.lower_id(0)
	var upper_id := StairFlightScript.upper_id(0)
	for k in 4:
		var level := 226 - k
		for z in range(3 * k - 1, 3 * k + 2):
			for y in range(level, ProbeSurfaceY + 1):
				_put(snap, Vector3i(0, y, z), World.BLOCK_ID_AIR)
		_put(snap, Vector3i(0, level, 3 * k - 1), upper_id)
		_put(snap, Vector3i(0, level, 3 * k), lower_id)
	for x in range(-12, 13):
		for z in range(10, 23):
			_put(snap, Vector3i(x, ProbeRoomY, z), World.BLOCK_ID_AIR)
			_put(snap, Vector3i(x, ProbeRoomY + 1, z), World.BLOCK_ID_AIR)
	return snap


func _probe_tasks() -> Array[Vector3i]:
	var tasks: Array[Vector3i] = []
	for x in range(-12, 13):
		tasks.append(Vector3i(x, ProbeRoomY, 23))
	for z in range(12, 23):
		tasks.append(Vector3i(-13, ProbeRoomY, z))
		tasks.append(Vector3i(13, ProbeRoomY, z))
	return tasks


func _probe_workers() -> Array[Vector3i]:
	var workers: Array[Vector3i] = []
	for i in 36:
		workers.append(Vector3i(-15 + (i % 6) * 6, ProbeSurfaceY, 4 + int(i / 6) * 4))
	return workers


func _check_probe_distances(snapshot: PathWorldSnapshot, grid, pf: Pathfinder) -> void:
	var workers := _probe_workers()
	var tasks := _probe_tasks()
	var selected := [tasks[0], tasks[12], tasks[24], tasks[30]]
	for task in selected:
		var goals := TaskWorkPositionRules.task_work_positions(snapshot, pf, task, TaskQueue.TaskType.DIG)
		var result: Dictionary = grid.reverse_distances(goals, workers)
		_check(bool(result["complete"]), "probe reverse BFS completes for task %s" % task)
		for worker: Vector3i in workers:
			var path := pf._find_path_to_goals(snapshot, worker, goals, false, false, 8192)
			var expected := path.size() if not path.is_empty() else -1
			_check(int(result["distances"].get(worker, -999)) == expected, "surface worker distance matches uncapped A* for %s" % task)
			if not path.is_empty():
				_check(grid.path_from(worker).size() == expected, "probe path length matches A* for %s" % worker)


func _floor_div(value: int, divisor: int) -> int:
	return floori(float(value) / float(divisor))


func _positive_mod(value: int, divisor: int) -> int:
	var result := value % divisor
	return result + divisor if result < 0 else result
