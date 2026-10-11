extends Node3D
## Draws TreeStore trees as MultiMeshes, one per (kind, height, variant bucket)
## mesh. A tree is drawn whole while its base is at or below the render level
## and hidden when the view is sliced below it. Rebuilds only when the store
## revision or the render range changes.

const Trees = preload("res://scripts/rendering/tree_mesh_builder.gd")
const Util = preload("res://scripts/rendering/prop_mesh_util.gd")
const SWAY := 0.05

var world
var material: ShaderMaterial
var trees_drawn := 0
var rebuild_count := 0
var _meshes: Dictionary = {}     # mesh key -> ArrayMesh
var _instances: Dictionary = {}  # mesh key -> MultiMeshInstance3D
var _revision := -1
var _top := -1
var _min := -1


func initialize(world_ref) -> void:
	world = world_ref
	if material == null:
		material = Util.make_prop_material(SWAY)
	_revision = -1
	sync()


func _process(_delta: float) -> void:
	sync()


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
	for base: Vector3i in store.trees.keys():
		if base.y > top or base.y < min_y:
			continue
		var tree: Dictionary = store.trees[base]
		var kind := int(tree.get("kind", Trees.KIND_OAK))
		var variant := int(tree.get("variant", 0))
		var height := int(tree.get("height", 5))
		var key := Vector3i(kind, height, variant % Trees.VARIANT_BUCKETS)
		if not groups.has(key):
			groups[key] = []
		var turn := Basis(Vector3.UP, PI * 0.5 * float((variant >> 2) & 3))
		groups[key].append(Transform3D(turn, Vector3(base)))
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
			multimesh.mesh = _mesh_for(key)
			instance.multimesh = multimesh
			instance.material_override = material
			add_child(instance)
			_instances[key] = instance
		var mm := instance.multimesh
		mm.instance_count = transforms.size()
		for index in range(transforms.size()):
			mm.set_instance_transform(index, transforms[index])


func _mesh_for(key: Vector3i) -> ArrayMesh:
	if not _meshes.has(key):
		_meshes[key] = Trees.build(key.x, key.y, key.z)
	return _meshes[key]
