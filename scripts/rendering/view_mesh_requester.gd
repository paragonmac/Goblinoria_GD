extends RefCounted
## View-driven mesh requests (SEE-ADR-015, 2026-11-11).
##
## The visibility view knows exactly which chunks should be on screen. This
## walks the accepted coordinates of the newest adopted view, top layer first,
## and asks for the mesh of every chunk that can show something and has none.
## The streaming queue still fills the wider buffer; it restarts whenever the
## camera moves and works through off-screen chunks too, so on ground that was
## never meshed it left the screen empty while the camera kept moving.
##
## A chunk can show something only at or above its column's visible floor: the
## lowest block seen from above through the cut at top_render_y, in that column
## or in a face neighbour (which exposes this column's side faces). Chunks below
## that are buried and are never requested here. Chunks with no blocks yet are
## skipped: a view never creates or generates terrain. The walk stops at the first
## layer below every floor it has met: a deeper chunk could only be seen through
## an opening in a column the walk would have met higher up. Both rules sample
## (every second cell; chunk-sized sight lines), so a one-block shaft can be
## missed here; the streaming queue still meshes it.
##
## When every needed chunk of a view is built the view is reported as meshed;
## the pan limiter keeps the camera within reach of the last such view.

const ChunkDataScript = preload("res://scripts/chunk_data.gd")

## Needed chunks waiting for a mesh at once. New requests go to the front of the
## mesh queue, so a small backlog keeps the newest view's chunks first.
const MAX_OUTSTANDING := 192
## Cells sampled per column edge when finding the visible floor (every 2nd cell).
const FLOOR_SAMPLE_STEP := 2
## A view whose needed chunks make no progress for this long is reported meshed
## anyway, so a chunk that can never be built cannot trap the camera.
const STALL_USEC := 750_000
## Floors found while part of a column was not generated yet are kept this long.
const PROVISIONAL_USEC := 250_000
const KEY_OFFSET := 1 << 20
const KEY_STRIDE := 1 << 21

var renderer
var world
var view_id := -1
var meshed_view_id := -1
var requested_total := 0
var meshed_views := 0
var stalled_views := 0
var last_needed := 0
var last_walked := 0

var _coords: Array = []
var _cursor := -1
var _walk_done := true
var _walk_started := false
var _walk_floor := 0
var _needed := 0
var _walked := 0
var _outstanding: Array[Vector3i] = []
var _floors: Dictionary = {}
# Column key -> lowest layer needed there (its floor and its face neighbours').
var _needed_floors: Dictionary = {}
var _provisional: Array[int] = []
var _provisional_usec := 0
var _floor_top_y := -1
var _progress_usec := 0


func configure(owner) -> void:
	renderer = owner
	reset()


## Forget the view and everything derived from the terrain.
func reset() -> void:
	clear_view()
	_clear_floors()
	_floor_top_y = -1
	meshed_view_id = -1


## Forget the view being served; cached column floors stay.
func clear_view() -> void:
	view_id = -1
	_coords = []
	_cursor = -1
	_walk_done = true
	_outstanding.clear()


## Terrain in this chunk changed: its column's floor must be found again.
func forget_column(cx: int, cz: int) -> void:
	if _floors.is_empty():
		return
	_floors.erase(_column_key(cx, cz))
	_needed_floors.erase(_column_key(cx, cz))
	_needed_floors.erase(_column_key(cx - 1, cz))
	_needed_floors.erase(_column_key(cx + 1, cz))
	_needed_floors.erase(_column_key(cx, cz - 1))
	_needed_floors.erase(_column_key(cx, cz + 1))


func _clear_floors() -> void:
	_floors.clear()
	_needed_floors.clear()
	_provisional.clear()


## A visibility result was adopted. Its coordinates are listed bottom layer
## first, so the walk runs from the end of the list.
func begin_view(result: Dictionary) -> void:
	view_id = int(result.get("request_id", -1))
	_coords = result.get("accepted_coords", [])
	_cursor = _coords.size() - 1
	_walk_done = _cursor < 0
	_walk_started = false
	_needed = 0
	_walked = 0
	_outstanding.clear()
	_progress_usec = Time.get_ticks_usec()


## Spends up to budget_usec asking for meshes. Returns true when the view being
## served has just become fully meshed.
func pump(budget_usec: int) -> bool:
	if view_id < 0 or renderer == null:
		return false
	world = renderer.world
	if world == null:
		return false
	if _floor_top_y != world.top_render_y:
		_clear_floors()
		_floor_top_y = world.top_render_y
	if view_id == meshed_view_id:
		return false
	var now := Time.get_ticks_usec()
	var deadline := now + budget_usec
	if not _provisional.is_empty() and now - _provisional_usec > PROVISIONAL_USEC:
		for key: int in _provisional:
			_floors.erase(key)
		_provisional.clear()
		_needed_floors.clear()
	_settle_outstanding()
	var top_cy := floori(float(world.top_render_y) / World.CHUNK_SIZE)
	if not _walk_started and not _walk_done:
		# Nothing above the cut is drawn: start at the top layer that is.
		_walk_started = true
		_walk_floor = top_cy
		_cursor = _last_index_at_or_below(top_cy)
		_walk_done = _cursor < 0
	var chunks: Dictionary = world.chunks
	var steps := 0
	# Finding a floor or queueing a mesh costs far more than a remembered answer,
	# so the clock is read after each of those and otherwise every 32 steps.
	var costly := false
	while not _walk_done and _outstanding.size() < MAX_OUTSTANDING:
		steps += 1
		if (costly or (steps & 31) == 0) and Time.get_ticks_usec() >= deadline:
			break
		costly = false
		var coord: Vector3i = _coords[_cursor]
		if coord.y < _walk_floor:
			# Below every floor met so far: the rest of the list is buried.
			_walk_done = true
			break
		_cursor -= 1
		_walked += 1
		if _cursor < 0:
			_walk_done = true
		var key: int = (coord.x + KEY_OFFSET) * KEY_STRIDE + coord.z + KEY_OFFSET
		var floor_value: Variant = _needed_floors.get(key)
		var needed_floor: int
		if floor_value != null:
			needed_floor = floor_value
		else:
			needed_floor = _needed_floor(coord.x, coord.z, key)
			costly = true
		if needed_floor < _walk_floor:
			_walk_floor = needed_floor
		if coord.y < needed_floor:
			continue
		_needed += 1
		var chunk: ChunkData = chunks.get(coord)
		if chunk != null and chunk.mesh_state == ChunkDataScript.MESH_STATE_READY:
			continue
		costly = true
		if not _ensure_mesh(coord):
			_outstanding.append(coord)
	if steps > 0:
		_progress_usec = Time.get_ticks_usec()
	var finished := _walk_done and _outstanding.is_empty()
	if not finished and Time.get_ticks_usec() - _progress_usec > STALL_USEC:
		finished = true
		stalled_views += 1
	if not finished:
		return false
	meshed_view_id = view_id
	meshed_views += 1
	last_needed = _needed
	last_walked = _walked
	_coords = []
	_outstanding.clear()
	return true


func snapshot() -> Dictionary:
	return {"view_id": view_id, "meshed_view_id": meshed_view_id, "outstanding": _outstanding.size(),
		"walk_done": _walk_done, "requested_total": requested_total, "meshed_views": meshed_views,
		"stalled_views": stalled_views, "last_needed": last_needed, "last_walked": last_walked,
		"cached_columns": _floors.size()}


func _settle_outstanding() -> void:
	var kept := 0
	for index in _outstanding.size():
		var coord: Vector3i = _outstanding[index]
		if _ensure_mesh(coord):
			_progress_usec = Time.get_ticks_usec()
			continue
		_outstanding[kept] = coord
		kept += 1
	_outstanding.resize(kept)


## True when there is nothing to wait for: the chunk's mesh is built, or the
## chunk has no blocks yet. Otherwise queues its mesh ahead of other work.
## A view never creates or generates terrain (the streaming and generation
## paths own that and mesh a chunk when it arrives), so such chunks are skipped.
func _ensure_mesh(coord: Vector3i) -> bool:
	var chunk: ChunkData = world.get_chunk(coord)
	if chunk == null or not chunk.generated:
		return true
	if chunk.mesh_state == ChunkDataScript.MESH_STATE_READY:
		return true
	if chunk.mesh_state == ChunkDataScript.MESH_STATE_NONE \
			or renderer.mesh_scheduler.get_job_revision(coord) < chunk.mesh_revision:
		renderer.queue_chunk_mesh_build(coord, -1, false, true)
		requested_total += 1
	return chunk.mesh_state == ChunkDataScript.MESH_STATE_READY


func _column_key(cx: int, cz: int) -> int:
	return (cx + KEY_OFFSET) * KEY_STRIDE + cz + KEY_OFFSET


## Index of the last accepted coordinate at or below layer cy, or -1. The list is
## sorted by layer, lowest first.
func _last_index_at_or_below(cy: int) -> int:
	var low := 0
	var high := _coords.size()
	while low < high:
		var mid := (low + high) / 2
		if _coords[mid].y <= cy:
			low = mid + 1
		else:
			high = mid
	return low - 1


## Lowest chunk layer of column (cx, cz) that can show something: its own floor
## or a face neighbour's. Remembered until one of the five columns changes.
func _needed_floor(cx: int, cz: int, key: int) -> int:
	var lowest: int = _column_floor(cx, cz)
	lowest = mini(lowest, _column_floor(cx - 1, cz))
	lowest = mini(lowest, _column_floor(cx + 1, cz))
	lowest = mini(lowest, _column_floor(cx, cz - 1))
	lowest = mini(lowest, _column_floor(cx, cz + 1))
	_needed_floors[key] = lowest
	return lowest


## Chunk layer holding the lowest block of this column seen from above through
## the cut. Found by walking sampled cells down from top_render_y to the first
## solid block. Cached until the column's terrain or the cut changes.
func _column_floor(cx: int, cz: int) -> int:
	var key := _column_key(cx, cz)
	var cached: Variant = _floors.get(key)
	if cached != null:
		return cached
	var n: int = World.CHUNK_SIZE
	var top_y: int = clampi(world.top_render_y, 0, world.world_size_y - 1)
	var top_cy: int = top_y / n
	if not world.is_chunk_coord_valid(Vector3i(cx, top_cy, cz)):
		# Outside the world: nothing to see, and no limit on the neighbours.
		_floors[key] = top_cy + 1
		return top_cy + 1
	var solid: PackedByteArray = renderer.block_solid_table
	if solid.is_empty():
		renderer._ensure_block_tables()
		solid = renderer.block_solid_table
	var cells: int = n * n * n
	var chunks: Dictionary = world.chunks
	# Block arrays of this column, fetched once per layer as the scan reaches it.
	var layers: Array = []
	layers.resize(top_cy + 1)
	var lowest_cy := top_cy
	var complete := true
	for lz in range(0, n, FLOOR_SAMPLE_STEP):
		for lx in range(0, n, FLOOR_SAMPLE_STEP):
			var column: int = lz * n * n + lx
			var cy := top_cy
			var ly := top_y - top_cy * n
			var found := false
			while cy >= 0 and not found:
				var blocks: Variant = layers[cy]
				if blocks == null:
					var chunk: ChunkData = chunks.get(Vector3i(cx, cy, cz))
					if chunk == null or not chunk.generated or chunk.blocks.size() != cells:
						# Not known yet: this layer is needed, and the answer is not final.
						complete = false
						break
					blocks = chunk.blocks
					layers[cy] = blocks
				var data: PackedByteArray = blocks
				while ly >= 0:
					if solid[data[column + ly * n]] != 0:
						found = true
						break
					ly -= 1
				if not found:
					cy -= 1
					ly = n - 1
			lowest_cy = mini(lowest_cy, maxi(cy, 0))
	_floors[key] = lowest_cy
	if not complete:
		# Part of the column is not generated yet: look again shortly.
		if _provisional.is_empty():
			_provisional_usec = Time.get_ticks_usec()
		_provisional.append(key)
	return lowest_cy
