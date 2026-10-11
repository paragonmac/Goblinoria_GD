extends Node3D
## Draws TreeStore trees as MultiMeshes, one per (kind, height, variant bucket)
## mesh. A tree is drawn whole while the ground it stands on is in view (base
## cell visible like a standing worker) and hidden when sliced below it.
## Rebuilds only when the store revision or the render range changes.
##
## Trees that stand between the camera and a goblin, stockpile cell or pending
## job fade (stippled see-through, INSTANCE_CUSTOM.r) so the colony stays
## visible. The test runs a few times a second, not every frame.

const Trees = preload("res://scripts/rendering/tree_mesh_builder.gd")
const Util = preload("res://scripts/rendering/prop_mesh_util.gd")
const SWAY := 0.05
const FADE_INTERVAL_SEC := 0.2
const BUCKET := 4
## Occlusion cylinders per kind: canopy radius (cells). Height comes from the tree.
const RADIUS_BY_KIND := {Trees.KIND_OAK: 1.6, Trees.KIND_PINE: 1.35, Trees.KIND_BUSH: 0.5}
## Horizontal reach (cells) toward the camera within which a tree can cover a target.
const MAX_REACH := 18.0

var world
var material: ShaderMaterial
var trees_drawn := 0
var rebuild_count := 0
var faded_count := 0
var fade_updates := 0
var _meshes: Dictionary = {}     # mesh key -> ArrayMesh
var _instances: Dictionary = {}  # mesh key -> MultiMeshInstance3D
var _slots: Dictionary = {}      # base -> [mesh key, instance index]
var _buckets: Dictionary = {}    # Vector2i bucket -> Array[Vector3i] bases (drawn trees)
var _faded: Dictionary = {}      # base -> true
var _revision := -1
var _top := -1
var _min := -1
var _fade_timer := 0.0
var _fade_view_dir := Vector3.ZERO


func initialize(world_ref) -> void:
	world = world_ref
	if material == null:
		material = Util.make_prop_material(SWAY, true)
	_revision = -1
	sync()


func _process(delta: float) -> void:
	sync()
	_fade_timer -= delta
	var camera := get_viewport().get_camera_3d() if is_inside_tree() else null
	var view_dir := camera.global_transform.basis.z if camera != null else Vector3.ZERO
	if _fade_timer <= 0.0 or not view_dir.is_equal_approx(_fade_view_dir):
		_fade_timer = FADE_INTERVAL_SEC
		_fade_view_dir = view_dir
		update_fades(view_dir)


func sync() -> void:
	if world == null:
		return
	var store = world.get("tree_store")
	if store == null:
		return
	var top: int = world.top_render_y
	var min_y: int = world.get_min_render_y()
	if store.revision == _revision and top == _top and min_y == _min:
		return
	_revision = store.revision
	_top = top
	_min = min_y
	rebuild_count += 1
	var groups: Dictionary = {}
	trees_drawn = 0
	_slots.clear()
	_buckets.clear()
	_faded.clear()
	for base: Vector3i in store.trees.keys():
		# The base is the air cell above the ground, visible like a standing worker.
		if not world.is_visible_at_level(base.y) or base.y < min_y:
			continue
		var tree: Dictionary = store.trees[base]
		var kind := int(tree.get("kind", Trees.KIND_OAK))
		var variant := int(tree.get("variant", 0))
		var height := int(tree.get("height", 5))
		var key := Vector3i(kind, height, variant % Trees.VARIANT_BUCKETS)
		if not groups.has(key):
			groups[key] = []
		var turn := Basis(Vector3.UP, PI * 0.5 * float((variant >> 2) & 3))
		_slots[base] = [key, groups[key].size()]
		groups[key].append(Transform3D(turn, Vector3(base)))
		var bucket := Vector2i(floori(float(base.x) / BUCKET), floori(float(base.z) / BUCKET))
		if not _buckets.has(bucket):
			_buckets[bucket] = []
		_buckets[bucket].append(base)
		trees_drawn += 1
	for key: Vector3i in _instances.keys():
		if not groups.has(key):
			_instances[key].multimesh.instance_count = 0
	for key: Vector3i in groups.keys():
		var transforms: Array = groups[key]
		var instance: MultiMeshInstance3D = _instances.get(key)
		if instance == null:
			instance = MultiMeshInstance3D.new()
			instance.name = "Trees_%d_%d_%d" % [key.x, key.y, key.z]
			var multimesh := MultiMesh.new()
			multimesh.transform_format = MultiMesh.TRANSFORM_3D
			multimesh.use_custom_data = true
			multimesh.mesh = _mesh_for(key)
			instance.multimesh = multimesh
			instance.material_override = material
			add_child(instance)
			_instances[key] = instance
		var mm := instance.multimesh
		mm.instance_count = transforms.size()
		for index in range(transforms.size()):
			mm.set_instance_transform(index, transforms[index])
			mm.set_instance_custom_data(index, Color(0, 0, 0, 0))
	# Fades were reset with the instances; recompute on the next tick.
	_fade_timer = 0.0


## Recomputes which drawn trees cover a colony target as seen along `view_dir`
## (unit vector pointing from the scene toward the camera).
func update_fades(view_dir: Vector3) -> void:
	if world == null or _slots.is_empty():
		return
	fade_updates += 1
	var next: Dictionary = {}
	if view_dir.y > 0.05:
		var store = world.tree_store
		for target: Vector3 in _fade_targets():
			_collect_covering(target, view_dir, store, next)
	for base: Vector3i in _faded.keys():
		if not next.has(base):
			_set_fade(base, 0.0)
	for base: Vector3i in next.keys():
		if not _faded.has(base):
			_set_fade(base, 1.0)
	_faded = next
	faded_count = _faded.size()


## Points the player must be able to see: goblins, stockpile cells, pending jobs
## (visible levels only).
func _fade_targets() -> Array[Vector3]:
	var targets: Array[Vector3] = []
	for worker in world.workers:
		if is_instance_valid(worker) and world.is_visible_at_level(worker.position.y):
			targets.append(worker.position + Vector3(0, 0.3, 0))
	if world.stockpile_store != null:
		for stockpile: Dictionary in world.stockpile_store.stockpiles.values():
			for cell in stockpile.get("cells", []):
				if typeof(cell) == TYPE_VECTOR3I and world.is_visible_at_level(cell.y):
					targets.append(Vector3(cell) + Vector3(0, -0.3, 0))
	if world.task_queue != null:
		for task in world.task_queue.tasks:
			if task != null and task.status == TaskQueue.TaskStatus.PENDING and world.is_visible_at_level(task.pos.y):
				targets.append(Vector3(task.pos))
	return targets


## Adds every drawn tree whose occlusion cylinder the ray target + t * view_dir
## (t > 0) passes through.
func _collect_covering(target: Vector3, view_dir: Vector3, store, out: Dictionary) -> void:
	var flat := Vector2(view_dir.x, view_dir.z)
	var flat_len := flat.length()
	var reach_cells := MAX_REACH
	var bx0 := floori(minf(target.x, target.x + flat.x / maxf(flat_len, 0.001) * reach_cells) / BUCKET) - 1
	var bx1 := floori(maxf(target.x, target.x + flat.x / maxf(flat_len, 0.001) * reach_cells) / BUCKET) + 1
	var bz0 := floori(minf(target.z, target.z + flat.y / maxf(flat_len, 0.001) * reach_cells) / BUCKET) - 1
	var bz1 := floori(maxf(target.z, target.z + flat.y / maxf(flat_len, 0.001) * reach_cells) / BUCKET) + 1
	var a := flat.dot(flat)
	for bx in range(bx0, bx1 + 1):
		for bz in range(bz0, bz1 + 1):
			var bases: Array = _buckets.get(Vector2i(bx, bz), [])
			for base: Vector3i in bases:
				if out.has(base):
					continue
				var tree: Dictionary = store.trees.get(base, {})
				if tree.is_empty():
					continue
				var radius: float = RADIUS_BY_KIND.get(int(tree.get("kind", 0)), 1.5)
				var w := Vector2(target.x - base.x, target.z - base.z)
				# |w + t * flat|^2 < r^2  ->  a t^2 + 2 (w . flat) t + (w . w - r^2) < 0
				var b := w.dot(flat)
				var c := w.dot(w) - radius * radius
				var t1 := 0.0
				var t2 := 0.0
				if a < 0.000001:
					if c >= 0.0:
						continue
					t1 = 0.0
					t2 = 1000.0
				else:
					var disc := b * b - a * c
					if disc <= 0.0:
						continue
					var root := sqrt(disc)
					t1 = (-b - root) / a
					t2 = (-b + root) / a
				if t2 <= 0.0:
					continue
				t1 = maxf(t1, 0.0)
				# Height span of the ray inside the column vs the tree's height span.
				var y_a := target.y + t1 * view_dir.y
				var y_b := target.y + t2 * view_dir.y
				var tree_bottom := float(base.y) - 0.5
				var tree_top := tree_bottom + float(int(tree.get("height", 5))) + 0.3
				if minf(y_a, y_b) <= tree_top and maxf(y_a, y_b) >= tree_bottom:
					out[base] = true


func _set_fade(base: Vector3i, value: float) -> void:
	var slot: Array = _slots.get(base, [])
	if slot.is_empty():
		return
	var instance: MultiMeshInstance3D = _instances.get(slot[0])
	if instance == null or int(slot[1]) >= instance.multimesh.instance_count:
		return
	instance.multimesh.set_instance_custom_data(int(slot[1]), Color(value, 0, 0, 0))


func _mesh_for(key: Vector3i) -> ArrayMesh:
	if not _meshes.has(key):
		_meshes[key] = Trees.build(key.x, key.y, key.z)
	return _meshes[key]
