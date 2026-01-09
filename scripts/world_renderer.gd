extends Node3D
class_name WorldRenderer

var world: World
var block_material: StandardMaterial3D
var chunk_nodes: Dictionary = {}
var task_overlays: Dictionary = {}
var drag_previews: Dictionary = {}
var drag_materials: Dictionary = {}
var chunk_face_stats: Dictionary = {}
var total_visible_faces: int = 0
var total_occluded_faces: int = 0


func initialize(world_ref: World) -> void:
	world = world_ref


func reset_stats() -> void:
	chunk_face_stats.clear()
	total_visible_faces = 0
	total_occluded_faces = 0
	clear_drag_preview()
	clear_task_overlays()


func clear_task_overlays() -> void:
	for key in task_overlays.keys():
		task_overlays[key].queue_free()
	task_overlays.clear()


func build_all_chunks() -> void:
	if world == null:
		return
	var chunk_size: int = World.CHUNK_SIZE
	var chunks_x: int = int(floor(float(world.world_size_x) / float(chunk_size)))
	var chunks_y: int = int(floor(float(world.world_size_y) / float(chunk_size)))
	var chunks_z: int = int(floor(float(world.world_size_z) / float(chunk_size)))
	for cx in range(chunks_x):
		for cy in range(chunks_y):
			for cz in range(chunks_z):
				regenerate_chunk(cx, cy, cz)


func regenerate_chunk(cx: int, cy: int, cz: int) -> void:
	if world == null:
		return
	var chunk_size: int = World.CHUNK_SIZE
	var key := Vector3i(cx, cy, cz)
	var mesh_instance: MeshInstance3D
	if not chunk_nodes.has(key):
		mesh_instance = MeshInstance3D.new()
		mesh_instance.position = Vector3(cx * chunk_size, cy * chunk_size, cz * chunk_size)
		add_child(mesh_instance)
		chunk_nodes[key] = mesh_instance
	else:
		mesh_instance = chunk_nodes[key]

	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	var colors := PackedColorArray()
	var visible_faces := 0
	var occluded_faces := 0

	for lx in range(chunk_size):
		var wx := cx * chunk_size + lx
		for ly in range(chunk_size):
			var wy := cy * chunk_size + ly
			if wy > world.top_render_y:
				continue
			for lz in range(chunk_size):
				var wz := cz * chunk_size + lz
				var block_id := world.get_block(wx, wy, wz)
				if block_id == 0:
					continue

				var base := Vector3(lx, ly, lz)
				var color := block_color(block_id, wx, wy, wz)

				if not world.is_solid(wx, wy + 1, wz) or wy + 1 > world.top_render_y:
					add_face(vertices, normals, colors, base, Vector3.UP, color)
					visible_faces += 1
				else:
					occluded_faces += 1
				if not world.is_solid(wx, wy - 1, wz):
					add_face(vertices, normals, colors, base, Vector3.DOWN, color)
					visible_faces += 1
				else:
					occluded_faces += 1
				if not world.is_solid(wx, wy, wz + 1):
					add_face(vertices, normals, colors, base, Vector3.FORWARD, color)
					visible_faces += 1
				else:
					occluded_faces += 1
				if not world.is_solid(wx, wy, wz - 1):
					add_face(vertices, normals, colors, base, Vector3.BACK, color)
					visible_faces += 1
				else:
					occluded_faces += 1
				if not world.is_solid(wx + 1, wy, wz):
					add_face(vertices, normals, colors, base, Vector3.RIGHT, color)
					visible_faces += 1
				else:
					occluded_faces += 1
				if not world.is_solid(wx - 1, wy, wz):
					add_face(vertices, normals, colors, base, Vector3.LEFT, color)
					visible_faces += 1
				else:
					occluded_faces += 1

	var mesh := ArrayMesh.new()
	var prev_counts: Vector2i = chunk_face_stats.get(key, Vector2i(0, 0))
	total_visible_faces += visible_faces - prev_counts.x
	total_occluded_faces += occluded_faces - prev_counts.y
	chunk_face_stats[key] = Vector2i(visible_faces, occluded_faces)
	if vertices.size() == 0:
		mesh_instance.mesh = mesh
		return

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_COLOR] = colors
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	mesh_instance.mesh = mesh
	mesh_instance.material_override = get_block_material()


func get_block_material() -> StandardMaterial3D:
	if block_material == null:
		block_material = StandardMaterial3D.new()
		block_material.vertex_color_use_as_albedo = true
	return block_material


func block_color(block_id: int, wx: int, wy: int, wz: int) -> Color:
	if block_id == World.STAIR_BLOCK_ID:
		return Color(0.7, 0.6, 0.35)
	var base: Color
	match block_id:
		1:
			base = Color(0.82, 0.71, 0.55)
		2:
			base = Color(0.78, 0.67, 0.5)
		3:
			base = Color(0.72, 0.6, 0.42)
		4:
			base = Color(0.66, 0.52, 0.33)
		5:
			base = Color(0.6, 0.42, 0.28)
		6:
			base = Color(0.55, 0.35, 0.17)
		7:
			base = Color(0.44, 0.29, 0.15)
		8:
			base = Color(0.49, 0.49, 0.49)
		9:
			base = Color(0.33, 0.33, 0.33)
		_:
			base = Color(0.5, 0.5, 0.5)

	var n1 := block_noise(wx, wy, wz)
	var n2 := block_noise(wx + 17, wy + 31, wz + 47)
	var n3 := block_noise(wx + 59, wy + 73, wz + 101)
	var jitter := 0.08
	return Color(
		clamp(base.r + (n1 - 0.5) * jitter, 0.0, 1.0),
		clamp(base.g + (n2 - 0.5) * jitter, 0.0, 1.0),
		clamp(base.b + (n3 - 0.5) * jitter, 0.0, 1.0),
		base.a
	)


func block_noise(wx: int, wy: int, wz: int) -> float:
	var h: int = wx * 73856093 ^ wy * 19349663 ^ wz * 83492791
	h = (h ^ (h >> 13)) & 0x7fffffff
	return float(h % 1024) / 1023.0


func add_face(vertices: PackedVector3Array, normals: PackedVector3Array, colors: PackedColorArray, base: Vector3, normal: Vector3, color: Color) -> void:
	var h := 0.5
	var v1: Vector3
	var v2: Vector3
	var v3: Vector3
	var v4: Vector3

	if normal == Vector3.UP:
		v1 = base + Vector3(-h, h, -h)
		v2 = base + Vector3(-h, h, h)
		v3 = base + Vector3(h, h, h)
		v4 = base + Vector3(h, h, -h)
	elif normal == Vector3.DOWN:
		v1 = base + Vector3(-h, -h, -h)
		v2 = base + Vector3(h, -h, -h)
		v3 = base + Vector3(h, -h, h)
		v4 = base + Vector3(-h, -h, h)
	elif normal == Vector3.FORWARD:
		v1 = base + Vector3(-h, -h, h)
		v2 = base + Vector3(h, -h, h)
		v3 = base + Vector3(h, h, h)
		v4 = base + Vector3(-h, h, h)
	elif normal == Vector3.BACK:
		v1 = base + Vector3(-h, -h, -h)
		v2 = base + Vector3(-h, h, -h)
		v3 = base + Vector3(h, h, -h)
		v4 = base + Vector3(h, -h, -h)
	elif normal == Vector3.RIGHT:
		v1 = base + Vector3(h, -h, -h)
		v2 = base + Vector3(h, h, -h)
		v3 = base + Vector3(h, h, h)
		v4 = base + Vector3(h, -h, h)
	else:
		v1 = base + Vector3(-h, -h, -h)
		v2 = base + Vector3(-h, -h, h)
		v3 = base + Vector3(-h, h, h)
		v4 = base + Vector3(-h, h, -h)

	var shade := face_shade(normal)
	var shaded := Color(color.r * shade, color.g * shade, color.b * shade, 1.0)

	vertices.append_array([v1, v3, v2, v1, v4, v3])
	normals.append_array([normal, normal, normal, normal, normal, normal])
	colors.append_array([shaded, shaded, shaded, shaded, shaded, shaded])


func face_shade(normal: Vector3) -> float:
	if normal.y > 0.5:
		return 1.0
	if normal.y < -0.5:
		return 0.6
	if abs(normal.x) > 0.5:
		return 0.75
	return 0.82


func get_draw_burden_stats() -> Dictionary:
	var drawn_tris: int = total_visible_faces * 2
	var culled_tris: int = total_occluded_faces * 2
	var total_tris: int = drawn_tris + culled_tris
	var percent: float = 0.0
	if total_tris > 0:
		percent = float(drawn_tris) / float(total_tris) * 100.0
	return {"drawn": drawn_tris, "culled": culled_tris, "percent": percent}


func get_camera_tris_rendered(camera: Camera3D) -> Dictionary:
	if camera == null:
		return {"rendered": 0, "total": 0, "percent": 0.0}
	var frustum: Array = camera.get_frustum()
	var near_sample: float = max(camera.near + 0.1, 0.1)
	var inside_point: Vector3 = camera.global_transform.origin + (-camera.global_transform.basis.z) * near_sample
	var planes: Array = []
	for plane in frustum:
		var p: Plane = plane
		var inside_positive: bool = p.distance_to(inside_point) >= 0.0
		planes.append({"plane": p, "inside_positive": inside_positive})
	var rendered_faces := 0
	for key in chunk_face_stats.keys():
		var counts: Vector2i = chunk_face_stats[key]
		if counts.x == 0:
			continue
		if is_chunk_in_view(planes, key):
			rendered_faces += counts.x
	var rendered_tris: int = rendered_faces * 2
	var total_tris: int = total_visible_faces * 2
	var percent := 0.0
	if total_tris > 0:
		percent = float(rendered_tris) / float(total_tris) * 100.0
	return {"rendered": rendered_tris, "total": total_tris, "percent": percent}


func is_chunk_in_view(planes: Array, key: Vector3i) -> bool:
	var chunk_size: int = World.CHUNK_SIZE
	var min_corner := Vector3(
		key.x * chunk_size,
		key.y * chunk_size,
		key.z * chunk_size
	)
	var max_corner := min_corner + Vector3(chunk_size, chunk_size, chunk_size)
	for entry in planes:
		var p: Plane = entry["plane"]
		var inside_positive: bool = entry["inside_positive"]
		var v: Vector3
		if inside_positive:
			v = Vector3(
				max_corner.x if p.normal.x >= 0.0 else min_corner.x,
				max_corner.y if p.normal.y >= 0.0 else min_corner.y,
				max_corner.z if p.normal.z >= 0.0 else min_corner.z
			)
			if p.distance_to(v) < 0.0:
				return false
		else:
			v = Vector3(
				min_corner.x if p.normal.x >= 0.0 else max_corner.x,
				min_corner.y if p.normal.y >= 0.0 else max_corner.y,
				min_corner.z if p.normal.z >= 0.0 else max_corner.z
			)
			if p.distance_to(v) > 0.0:
				return false
	return true


func update_task_overlays(tasks: Array, blocked_tasks: Array) -> void:
	if world == null:
		return
	var live_ids: Dictionary = {}
	for task in tasks:
		if task.status == TaskQueue.TaskStatus.COMPLETED:
			continue
		live_ids[task.id] = true
		if not task_overlays.has(task.id):
			task_overlays[task.id] = create_task_overlay(task)
		var overlay: MeshInstance3D = task_overlays[task.id]
		overlay.position = Vector3(task.pos.x, task.pos.y, task.pos.z)
		overlay.visible = world.is_visible_at_level(task.pos.y)

	for blocked in blocked_tasks:
		var key := blocked_task_key(blocked)
		live_ids[key] = true
		if not task_overlays.has(key):
			task_overlays[key] = create_blocked_task_overlay(blocked["type"])
		var blocked_overlay: MeshInstance3D = task_overlays[key]
		var blocked_pos: Vector3i = blocked["pos"]
		blocked_overlay.position = Vector3(blocked_pos.x, blocked_pos.y, blocked_pos.z)
		blocked_overlay.visible = world.is_visible_at_level(blocked_pos.y)

	for task_id in task_overlays.keys():
		if not live_ids.has(task_id):
			task_overlays[task_id].queue_free()
			task_overlays.erase(task_id)


func blocked_task_key(task: Dictionary) -> String:
	var pos: Vector3i = task["pos"]
	return "blocked:%s:%s:%s:%s" % [task["type"], pos.x, pos.y, pos.z]


func task_type_color(task_type: int, alpha: float) -> Color:
	match task_type:
		TaskQueue.TaskType.DIG:
			return Color(1.0, 0.2, 0.2, alpha)
		TaskQueue.TaskType.PLACE:
			return Color(0.2, 0.2, 1.0, alpha)
		TaskQueue.TaskType.STAIRS:
			return Color(0.7, 0.5, 0.2, alpha)
	return Color(1.0, 1.0, 1.0, alpha)


func create_task_overlay(task) -> MeshInstance3D:
	var mesh_instance := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(1.05, 1.05, 1.05)
	mesh_instance.mesh = box

	var material := StandardMaterial3D.new()
	material.albedo_color = task_type_color(task.type, 0.7)
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mesh_instance.material_override = material
	add_child(mesh_instance)
	return mesh_instance


func create_blocked_task_overlay(task_type: int) -> MeshInstance3D:
	var mesh_instance := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(1.05, 1.05, 1.05)
	mesh_instance.mesh = box

	var material := StandardMaterial3D.new()
	material.albedo_color = task_type_color(task_type, 0.35)
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mesh_instance.material_override = material
	add_child(mesh_instance)
	return mesh_instance


func drag_preview_key(x: int, y: int, z: int) -> String:
	return "preview:%s:%s:%s" % [x, y, z]


func drag_preview_color(mode: int) -> Color:
	match mode:
		World.PlayerMode.DIG:
			return Color(0.2, 1.0, 0.2, 0.45)
		World.PlayerMode.PLACE:
			return Color(0.2, 0.6, 1.0, 0.45)
		World.PlayerMode.STAIRS:
			return Color(1.0, 0.7, 0.2, 0.45)
	return Color(0.8, 0.8, 0.8, 0.35)


func get_drag_material(mode: int) -> StandardMaterial3D:
	if drag_materials.has(mode):
		return drag_materials[mode]
	var material := StandardMaterial3D.new()
	material.albedo_color = drag_preview_color(mode)
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	drag_materials[mode] = material
	return material


func create_drag_preview_overlay(mode: int) -> MeshInstance3D:
	var mesh_instance := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(1.02, 1.02, 1.02)
	mesh_instance.mesh = box
	mesh_instance.material_override = get_drag_material(mode)
	add_child(mesh_instance)
	return mesh_instance


func set_drag_preview(rect: Dictionary, mode: int) -> void:
	if rect.is_empty():
		clear_drag_preview()
		return
	var min_x: int = int(floor(float(rect["min_x"]) + 0.5))
	var max_x: int = int(floor(float(rect["max_x"]) + 0.5))
	var min_z: int = int(floor(float(rect["min_z"]) + 0.5))
	var max_z: int = int(floor(float(rect["max_z"]) + 0.5))
	var y: int = int(rect["y"])
	var live_ids: Dictionary = {}
	for x in range(min_x, max_x + 1):
		for z in range(min_z, max_z + 1):
			var key := drag_preview_key(x, y, z)
			live_ids[key] = true
			var overlay: MeshInstance3D
			if not drag_previews.has(key):
				overlay = create_drag_preview_overlay(mode)
				drag_previews[key] = overlay
			else:
				overlay = drag_previews[key]
				var desired := get_drag_material(mode)
				if overlay.material_override != desired:
					overlay.material_override = desired
			overlay.position = Vector3(x, y, z)
			overlay.visible = world.is_visible_at_level(y)

	for key in drag_previews.keys():
		if not live_ids.has(key):
			drag_previews[key].queue_free()
			drag_previews.erase(key)


func clear_drag_preview() -> void:
	for key in drag_previews.keys():
		drag_previews[key].queue_free()
	drag_previews.clear()


func update_render_height(old_y: int, new_y: int) -> void:
	if world == null:
		return
	var chunk_size: int = World.CHUNK_SIZE
	var min_y: int = min(old_y, new_y)
	var max_y: int = max(old_y, new_y)
	var max_cy: int = int(floor(float(world.world_size_y) / float(chunk_size))) - 1
	var min_cy: int = clampi(int(floor(float(min_y) / float(chunk_size))), 0, max_cy)
	var max_cy_clamped: int = clampi(int(floor(float(max_y) / float(chunk_size))), 0, max_cy)
	var chunks_x: int = int(floor(float(world.world_size_x) / float(chunk_size)))
	var chunks_z: int = int(floor(float(world.world_size_z) / float(chunk_size)))
	for cx in range(chunks_x):
		for cy in range(min_cy, max_cy_clamped + 1):
			for cz in range(chunks_z):
				regenerate_chunk(cx, cy, cz)
