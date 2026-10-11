extends RefCounted
## Blocky ground piles for item stacks, built in cell space (ground y = -0.5).
## Each material has a piece style and palette; a pile holds 1-4 pieces chosen
## from the stack count, so bigger stacks read bigger.

const Util = preload("res://scripts/rendering/prop_mesh_util.gd")

const STYLE_ROCK := 0
const STYLE_CLOD := 1
const STYLE_SOD := 2
const STYLE_SLAB := 3
const STYLE_PEBBLES := 4
const STYLE_LOG := 5
const STYLE_MOSS := 6

## material id -> [style, base colour, accent colour (flecks/top)]
const LOOKS := {
	1: [STYLE_ROCK, Color(0.56, 0.54, 0.53), Color(0.7, 0.62, 0.6)],     # granite
	2: [STYLE_CLOD, Color(0.43, 0.29, 0.18), Color(0.36, 0.24, 0.15)],   # dirt
	3: [STYLE_CLOD, Color(0.66, 0.41, 0.29), Color(0.58, 0.35, 0.25)],   # clay
	4: [STYLE_ROCK, Color(0.8, 0.67, 0.45), Color(0.72, 0.58, 0.37)],    # sandstone
	5: [STYLE_ROCK, Color(0.82, 0.8, 0.72), Color(0.72, 0.7, 0.62)],     # limestone
	6: [STYLE_ROCK, Color(0.24, 0.24, 0.27), Color(0.32, 0.32, 0.36)],   # basalt
	7: [STYLE_SLAB, Color(0.36, 0.4, 0.46), Color(0.3, 0.33, 0.39)],     # slate
	8: [STYLE_ROCK, Color(0.48, 0.44, 0.42), Color(0.8, 0.45, 0.2)],     # iron ore
	9: [STYLE_ROCK, Color(0.12, 0.12, 0.13), Color(0.3, 0.3, 0.33)],     # coal
	10: [STYLE_SOD, Color(0.43, 0.29, 0.18), Color(0.29, 0.56, 0.18)],   # grass
	12: [STYLE_LOG, Color(0.36, 0.25, 0.15), Color(0.72, 0.56, 0.36)],   # log
	15: [STYLE_PEBBLES, Color(0.5, 0.48, 0.45), Color(0.38, 0.36, 0.34)], # gravel
	16: [STYLE_MOSS, Color(0.2, 0.42, 0.18), Color(0.28, 0.5, 0.22)],    # moss
}
const DEFAULT_LOOK := [STYLE_ROCK, Color(0.5, 0.5, 0.5), Color(0.6, 0.6, 0.6)]
## Rock materials that show accent flecks (ore veins, coal sheen).
const FLECKED := [8, 9]
## Piece slots inside the cell (x, z, scale), filled in order.
const SLOTS := [Vector3(0.0, 0.0, 1.0), Vector3(-0.2, 0.17, 0.85), Vector3(0.21, 0.12, 0.8), Vector3(0.04, -0.2, 0.75)]


static func pieces_for_count(count: int) -> int:
	if count >= 10:
		return 4
	if count >= 5:
		return 3
	if count >= 2:
		return 2
	return 1


static func build(material_id: int, pieces: int) -> ArrayMesh:
	var look: Array = LOOKS.get(material_id, DEFAULT_LOOK)
	var rng := RandomNumberGenerator.new()
	rng.seed = hash([material_id, pieces])
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for i in clampi(pieces, 1, SLOTS.size()):
		var slot: Vector3 = SLOTS[i]
		var turn := Basis(Vector3.UP, rng.randf_range(-0.6, 0.6))
		var xform := Transform3D(turn.scaled(Vector3.ONE * slot.z), Vector3(slot.x, -0.5, slot.y))
		_piece(st, int(look[0]), look[1], look[2], xform, rng, FLECKED.has(material_id))
	return st.commit()


## One piece in piece space: ground at y = 0, roughly 0.36 wide.
static func _piece(st: SurfaceTool, style: int, base: Color, accent: Color, x: Transform3D, rng: RandomNumberGenerator,
		flecked: bool = false) -> void:
	match style:
		STYLE_CLOD:
			Util.add_box(st, x, Vector3(0, 0.1, 0), Vector3(0.34, 0.2, 0.3), base)
			Util.add_box(st, x, Vector3(0.03, 0.22, -0.01), Vector3(0.24, 0.1, 0.22), accent)
			Util.add_box(st, x, Vector3(-0.12, 0.06, 0.1), Vector3(0.14, 0.12, 0.14), base.lightened(0.06))
		STYLE_SOD:
			Util.add_box(st, x, Vector3(0, 0.08, 0), Vector3(0.36, 0.16, 0.32), base)
			Util.add_box(st, x, Vector3(0, 0.18, 0), Vector3(0.38, 0.06, 0.34), accent)
			for b in 3:
				var p := Vector3(rng.randf_range(-0.13, 0.13), 0.27, rng.randf_range(-0.11, 0.11))
				Util.add_box(st, x, p, Vector3(0.03, rng.randf_range(0.1, 0.16), 0.03), accent.lightened(0.12))
		STYLE_SLAB:
			Util.add_box(st, x, Vector3(0, 0.04, 0), Vector3(0.4, 0.08, 0.3), base)
			Util.add_box(st, Transform3D(x.basis * Basis(Vector3.UP, 0.4), x.origin), Vector3(0.02, 0.11, 0.0),
				Vector3(0.34, 0.07, 0.26), accent)
		STYLE_PEBBLES:
			for p in 5:
				var s := rng.randf_range(0.08, 0.13)
				var c := base if p % 2 == 0 else accent
				Util.add_box(st, x, Vector3(rng.randf_range(-0.15, 0.15), s * 0.5, rng.randf_range(-0.13, 0.13)),
					Vector3(s, s * 0.8, s), c)
		STYLE_LOG:
			# Bark body lying on its side with lighter cut ends.
			Util.add_box(st, x, Vector3(0, 0.1, 0), Vector3(0.44, 0.2, 0.2), base)
			Util.add_box(st, x, Vector3(0.225, 0.1, 0), Vector3(0.012, 0.16, 0.16), accent)
			Util.add_box(st, x, Vector3(-0.225, 0.1, 0), Vector3(0.012, 0.16, 0.16), accent)
			Util.add_box(st, x, Vector3(0.05, 0.205, 0.0), Vector3(0.2, 0.012, 0.12), base.darkened(0.2))
		STYLE_MOSS:
			Util.add_box(st, x, Vector3(0, 0.07, 0), Vector3(0.34, 0.14, 0.3), base)
			Util.add_box(st, x, Vector3(0.06, 0.16, -0.03), Vector3(0.18, 0.08, 0.16), accent)
		_:
			# Chunky rock: offset blocks; ores and coal add accent flecks.
			Util.add_box(st, x, Vector3(0, 0.12, 0), Vector3(0.32, 0.24, 0.28), base)
			Util.add_box(st, x, Vector3(0.05, 0.27, -0.03), Vector3(0.2, 0.1, 0.18), base.lightened(0.07))
			Util.add_box(st, x, Vector3(-0.13, 0.08, 0.1), Vector3(0.14, 0.16, 0.14), base.darkened(0.08))
			if flecked:
				for f in 3:
					var fp := Vector3(rng.randf_range(-0.12, 0.12), rng.randf_range(0.08, 0.2), 0.142)
					Util.add_box(st, x, fp, Vector3(0.05, 0.05, 0.012), accent)
				Util.add_box(st, x, Vector3(0.162, rng.randf_range(0.08, 0.18), rng.randf_range(-0.08, 0.08)),
					Vector3(0.012, 0.05, 0.05), accent)
