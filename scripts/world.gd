extends Node3D
class_name World

const CHUNK_SIZE := 8
const WORLD_CHUNKS_X := 8
const WORLD_CHUNKS_Y := 8
const WORLD_CHUNKS_Z := 8
const STAIR_BLOCK_ID := 100
const DEFAULT_MATERIAL := 1

var world_size_x := CHUNK_SIZE * WORLD_CHUNKS_X
var world_size_y := CHUNK_SIZE * WORLD_CHUNKS_Y
var world_size_z := CHUNK_SIZE * WORLD_CHUNKS_Z

var sea_level := 0
var top_render_y := 0
var vertical_scroll := 0

var blocks := PackedByteArray()
var chunk_nodes: Dictionary = {}
var task_overlays: Dictionary = {}

var task_queue := TaskQueue.new()
var pathfinder := Pathfinder.new()
var workers: Array = []

enum PlayerMode { INFORMATION, DIG, PLACE, STAIRS }
var player_mode := PlayerMode.DIG

var selected_blocks: Dictionary = {}

func _ready() -> void:
    init_world()

func init_world() -> void:
    blocks.resize(world_size_x * world_size_y * world_size_z)
    blocks.fill(0)
    sea_level = max(world_size_y - 30, 8)
    top_render_y = sea_level

    seed_world()
    build_all_chunks()
    spawn_initial_workers()

func world_index(x: int, y: int, z: int) -> int:
    return (z * world_size_y + y) * world_size_x + x

func get_block(x: int, y: int, z: int) -> int:
    if x < 0 or y < 0 or z < 0:
        return 0
    if x >= world_size_x or y >= world_size_y or z >= world_size_z:
        return 0
    return blocks[world_index(x, y, z)]

func set_block(x: int, y: int, z: int, value: int) -> void:
    if x < 0 or y < 0 or z < 0:
        return
    if x >= world_size_x or y >= world_size_y or z >= world_size_z:
        return
    blocks[world_index(x, y, z)] = value
    regenerate_chunk(int(x / float(CHUNK_SIZE)), int(y / float(CHUNK_SIZE)), int(z / float(CHUNK_SIZE)))

func is_solid(x: int, y: int, z: int) -> bool:
    return get_block(x, y, z) != 0

func seed_world() -> void:
    blocks.fill(0)
    var max_y: int = min(sea_level + 1, world_size_y)
    for y in range(max_y):
        for x in range(world_size_x):
            for z in range(world_size_z):
                blocks[world_index(x, y, z)] = DEFAULT_MATERIAL

func build_all_chunks() -> void:
    for cx in range(WORLD_CHUNKS_X):
        for cy in range(WORLD_CHUNKS_Y):
            for cz in range(WORLD_CHUNKS_Z):
                regenerate_chunk(cx, cy, cz)

func regenerate_chunk(cx: int, cy: int, cz: int) -> void:
    var key := Vector3i(cx, cy, cz)
    var mesh_instance: MeshInstance3D
    if not chunk_nodes.has(key):
        mesh_instance = MeshInstance3D.new()
        mesh_instance.position = Vector3(cx * CHUNK_SIZE, cy * CHUNK_SIZE, cz * CHUNK_SIZE)
        add_child(mesh_instance)
        chunk_nodes[key] = mesh_instance
    else:
        mesh_instance = chunk_nodes[key]

    var vertices := PackedVector3Array()
    var normals := PackedVector3Array()
    var colors := PackedColorArray()

    for lx in range(CHUNK_SIZE):
        var wx := cx * CHUNK_SIZE + lx
        for ly in range(CHUNK_SIZE):
            var wy := cy * CHUNK_SIZE + ly
            if wy > top_render_y:
                continue
            for lz in range(CHUNK_SIZE):
                var wz := cz * CHUNK_SIZE + lz
                var block_id := get_block(wx, wy, wz)
                if block_id == 0:
                    continue

                var base := Vector3(lx, ly, lz)
                var color := block_color(block_id)

                if not is_solid(wx, wy + 1, wz) or wy + 1 > top_render_y:
                    add_face(vertices, normals, colors, base, Vector3.UP, color)
                if not is_solid(wx, wy - 1, wz):
                    add_face(vertices, normals, colors, base, Vector3.DOWN, color)
                if not is_solid(wx, wy, wz + 1):
                    add_face(vertices, normals, colors, base, Vector3.FORWARD, color)
                if not is_solid(wx, wy, wz - 1):
                    add_face(vertices, normals, colors, base, Vector3.BACK, color)
                if not is_solid(wx + 1, wy, wz):
                    add_face(vertices, normals, colors, base, Vector3.RIGHT, color)
                if not is_solid(wx - 1, wy, wz):
                    add_face(vertices, normals, colors, base, Vector3.LEFT, color)

    var mesh := ArrayMesh.new()
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

func block_color(block_id: int) -> Color:
    if block_id == STAIR_BLOCK_ID:
        return Color(0.7, 0.6, 0.35)
    match block_id:
        1:
            return Color(0.82, 0.71, 0.55)
        2:
            return Color(0.78, 0.67, 0.5)
        3:
            return Color(0.72, 0.6, 0.42)
        4:
            return Color(0.66, 0.52, 0.33)
        5:
            return Color(0.6, 0.42, 0.28)
        6:
            return Color(0.55, 0.35, 0.17)
        7:
            return Color(0.44, 0.29, 0.15)
        8:
            return Color(0.49, 0.49, 0.49)
        9:
            return Color(0.33, 0.33, 0.33)
        _:
            return Color(0.5, 0.5, 0.5)

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

    vertices.append_array([v1, v2, v3, v1, v3, v4])
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

func update_world(dt: float) -> void:
    for worker in workers:
        worker.update_worker(dt, self, task_queue, pathfinder)
        worker.visible = is_visible_at_level(worker.position.y)
    task_queue.cleanup_completed()
    update_task_overlays()

func spawn_initial_workers() -> void:
    var center_x: int = int(world_size_x / 2.0)
    var center_z: int = int(world_size_z / 2.0)
    var offsets: Array[Vector2i] = [Vector2i(-10, -10), Vector2i(10, -10), Vector2i(-10, 10), Vector2i(10, 10)]
    for offset in offsets:
        var spawn_x: int = clampi(center_x + offset.x, 0, world_size_x - 1)
        var spawn_z: int = clampi(center_z + offset.y, 0, world_size_z - 1)
        var surface_y := find_surface_y(spawn_x, spawn_z)
        var worker := Worker.new()
        worker.position = Vector3(spawn_x, surface_y + 1, spawn_z)
        add_child(worker)
        workers.append(worker)

func find_surface_y(x: int, z: int) -> int:
    for y in range(world_size_y - 1, -1, -1):
        if get_block(x, y, z) != 0:
            return y
    return 0

func update_task_overlays() -> void:
    var live_ids: Dictionary = {}
    for task in task_queue.tasks:
        if task.status == TaskQueue.TaskStatus.COMPLETED:
            continue
        live_ids[task.id] = true
        if not task_overlays.has(task.id):
            task_overlays[task.id] = create_task_overlay(task)
        var overlay: MeshInstance3D = task_overlays[task.id]
        overlay.position = Vector3(task.pos.x, task.pos.y, task.pos.z)
        overlay.visible = is_visible_at_level(task.pos.y)

    for task_id in task_overlays.keys():
        if not live_ids.has(task_id):
            task_overlays[task_id].queue_free()
            task_overlays.erase(task_id)

func create_task_overlay(task) -> MeshInstance3D:
    var mesh_instance := MeshInstance3D.new()
    var box := BoxMesh.new()
    box.size = Vector3(1.05, 1.05, 1.05)
    mesh_instance.mesh = box

    var material := StandardMaterial3D.new()
    match task.type:
        TaskQueue.TaskType.DIG:
            material.albedo_color = Color(1.0, 0.2, 0.2, 0.7)
        TaskQueue.TaskType.PLACE:
            material.albedo_color = Color(0.2, 0.2, 1.0, 0.7)
        TaskQueue.TaskType.STAIRS:
            material.albedo_color = Color(0.7, 0.5, 0.2, 0.7)
    material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
    mesh_instance.material_override = material
    add_child(mesh_instance)
    return mesh_instance

func set_top_render_y(new_y: int) -> void:
    top_render_y = clamp(new_y, 0, world_size_y - 1)
    build_all_chunks()

func is_visible_at_level(y_value: float) -> bool:
    return y_value <= top_render_y

func raycast_block(ray_origin: Vector3, ray_dir: Vector3, max_distance: float) -> Dictionary:
    var pos := ray_origin
    var dir := ray_dir

    pos += Vector3(0.5, 0.5, 0.5)

    var voxel := Vector3i(int(floor(pos.x)), int(floor(pos.y)), int(floor(pos.z)))
    var step_x: int = 1 if dir.x >= 0.0 else -1
    var step_y: int = 1 if dir.y >= 0.0 else -1
    var step_z: int = 1 if dir.z >= 0.0 else -1
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
        if voxel.x >= 0 and voxel.y >= 0 and voxel.z >= 0 and voxel.x < world_size_x and voxel.y < world_size_y and voxel.z < world_size_z:
            if voxel.y <= top_render_y and get_block(voxel.x, voxel.y, voxel.z) != 0:
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
