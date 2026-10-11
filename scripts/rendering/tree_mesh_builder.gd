extends RefCounted
## Blocky tree props (oak, pine, bush). Meshes are built in base-cell space:
## origin at the base cell centre, ground at y = -0.5. A variant (0..255)
## seeds trunk lean, canopy clusters and colours; renderers cache one mesh per
## (kind, height, variant bucket). Canopy vertices carry a sway weight in UV.x.

const Util = preload("res://scripts/rendering/prop_mesh_util.gd")

const KIND_OAK := 0
const KIND_PINE := 1
const KIND_BUSH := 2
## Distinct shapes per kind and height; variants fold into these buckets.
const VARIANT_BUCKETS := 4

const BARK := Color(0.36, 0.25, 0.15)
const BARK_DARK := Color(0.27, 0.18, 0.1)
const OAK_LEAVES := [Color(0.22, 0.5, 0.13), Color(0.28, 0.57, 0.16), Color(0.18, 0.43, 0.11), Color(0.33, 0.6, 0.18)]
const PINE_LEAVES := [Color(0.1, 0.34, 0.19), Color(0.13, 0.39, 0.21), Color(0.08, 0.3, 0.17)]
const BUSH_LEAVES := [Color(0.25, 0.52, 0.14), Color(0.3, 0.57, 0.17), Color(0.21, 0.45, 0.12)]
const BERRY := Color(0.72, 0.13, 0.16)


static func build(kind: int, height: int, variant: int) -> ArrayMesh:
	var rng := RandomNumberGenerator.new()
	rng.seed = hash([kind, height, variant % VARIANT_BUCKETS])
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	match kind:
		KIND_PINE:
			_pine(st, rng, maxi(height, 4))
		KIND_BUSH:
			_bush(st, rng)
		_:
			_oak(st, rng, maxi(height, 4))
	return st.commit()


static func _oak(st: SurfaceTool, rng: RandomNumberGenerator, height: int) -> void:
	var ground := -0.5
	var trunk_top := ground + float(height) - 2.6
	var trunk_w := 0.46
	var id := Transform3D()
	Util.add_box(st, id, Vector3(0.0, (ground + trunk_top) * 0.5, 0.0), Vector3(trunk_w, trunk_top - ground, trunk_w), BARK)
	# Root flare and a bark band.
	Util.add_box(st, id, Vector3(0.0, ground + 0.12, 0.0), Vector3(trunk_w + 0.18, 0.24, trunk_w + 0.18), BARK_DARK)
	Util.add_box(st, id, Vector3(0.0, ground + 1.1, 0.0), Vector3(trunk_w + 0.04, 0.12, trunk_w + 0.04), BARK_DARK)
	# One or two side branches reaching into the canopy.
	var branch_dirs := [Vector3(1, 0, 0), Vector3(-1, 0, 0), Vector3(0, 0, 1), Vector3(0, 0, -1)]
	for i in rng.randi_range(1, 2):
		var dir: Vector3 = branch_dirs[rng.randi_range(0, 3)]
		var by := trunk_top - rng.randf_range(0.5, 1.1)
		Util.add_box(st, id, dir * 0.42 + Vector3(0, by, 0), Vector3(0.18, 0.18, 0.18) + dir.abs() * 0.5, BARK)
	# Canopy: a big core block plus offset clusters around and above it.
	var core_y := trunk_top + 1.0
	var core := Vector3(rng.randf_range(1.9, 2.2), rng.randf_range(1.6, 1.9), rng.randf_range(1.9, 2.2))
	_leaf_box(st, Vector3(0, core_y, 0), core, OAK_LEAVES, rng, core_y)
	var clusters := rng.randi_range(7, 9)
	for i in clusters:
		var angle := TAU * float(i) / float(clusters) + rng.randf_range(-0.35, 0.35)
		var reach := rng.randf_range(0.95, 1.4)
		var size := rng.randf_range(0.95, 1.35)
		var c := Vector3(cos(angle) * reach, core_y + rng.randf_range(-0.6, 0.75), sin(angle) * reach)
		_leaf_box(st, c, Vector3(size, size * rng.randf_range(0.7, 0.95), size), OAK_LEAVES, rng, core_y)
	_leaf_box(st, Vector3(rng.randf_range(-0.3, 0.3), core_y + core.y * 0.5 + 0.3, rng.randf_range(-0.3, 0.3)),
		Vector3(1.2, 0.6, 1.2), OAK_LEAVES, rng, core_y)


static func _pine(st: SurfaceTool, rng: RandomNumberGenerator, height: int) -> void:
	var ground := -0.5
	var top := ground + float(height)
	var id := Transform3D()
	Util.add_box(st, id, Vector3(0.0, (ground + top - 0.6) * 0.5, 0.0), Vector3(0.3, top - 0.6 - ground, 0.3), BARK)
	Util.add_box(st, id, Vector3(0.0, ground + 0.1, 0.0), Vector3(0.46, 0.2, 0.46), BARK_DARK)
	# Overlapping tiers from wide to narrow, alternating 45 degree twists.
	var first := ground + 1.1
	var tiers := maxi(4, height)
	var span := top - 0.5 - first
	for i in tiers:
		var t := float(i) / float(tiers - 1)
		var y := first + span * t
		var w := lerpf(2.6, 0.5, pow(t, 0.9)) * rng.randf_range(0.94, 1.04)
		var twist := Basis(Vector3.UP, PI * 0.25 if i % 2 == 1 else rng.randf_range(-0.1, 0.1))
		var color: Color = PINE_LEAVES[rng.randi_range(0, PINE_LEAVES.size() - 1)]
		var sway := 0.3 + t
		Util.add_box(st, Transform3D(twist, Vector3(0, y, 0)), Vector3.ZERO, Vector3(w, 0.85, w), color, Vector2(sway, 0))
		# Narrower upper step so each tier reads as a sloped layer.
		Util.add_box(st, Transform3D(twist, Vector3(0, y + 0.42, 0)), Vector3.ZERO, Vector3(w * 0.7, 0.3, w * 0.7),
			color.lightened(0.08), Vector2(sway, 0))
	Util.add_box(st, id, Vector3(0, top - 0.05, 0), Vector3(0.24, 0.6, 0.24), PINE_LEAVES[1], Vector2(1.3, 0))


static func _bush(st: SurfaceTool, rng: RandomNumberGenerator) -> void:
	var ground := -0.5
	var clumps := rng.randi_range(3, 5)
	for i in clumps:
		var angle := rng.randf_range(0.0, TAU)
		var reach := rng.randf_range(0.0, 0.28)
		var size := rng.randf_range(0.55, 0.85)
		var c := Vector3(cos(angle) * reach, ground + size * 0.5 + rng.randf_range(0.0, 0.18), sin(angle) * reach)
		var color: Color = BUSH_LEAVES[rng.randi_range(0, BUSH_LEAVES.size() - 1)]
		Util.add_box(st, Transform3D(), c, Vector3(size, size * 0.85, size), color, Vector2(0.35, 0))
	if rng.randf() < 0.5:
		for i in rng.randi_range(3, 5):
			var p := Vector3(rng.randf_range(-0.32, 0.32), ground + rng.randf_range(0.3, 0.62), rng.randf_range(-0.32, 0.32))
			Util.add_box(st, Transform3D(), p, Vector3(0.09, 0.09, 0.09), BERRY, Vector2(0.35, 0))


static func _leaf_box(st: SurfaceTool, center: Vector3, size: Vector3, palette: Array, rng: RandomNumberGenerator, sway_base: float) -> void:
	var color: Color = palette[rng.randi_range(0, palette.size() - 1)]
	var sway := 0.6 + clampf((center.y - sway_base) * 0.4, 0.0, 0.6)
	Util.add_box(st, Transform3D(), center, size, color, Vector2(sway, 0))
