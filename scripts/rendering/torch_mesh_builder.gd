extends RefCounted
## Blocky torch meshes (SEE-ADR-021): a standing torch and a wall torch, both
## built in cell space (cell centre at the origin, floor at y = -0.5). The wall
## torch hangs on the wall at -Z; renderers rotate it to the torch's facing.
## Vertex colours carry the albedo; UV.x = 1 marks flame vertices, with the
## flame pivot in (UV2.x, UV2.y, UV.y) so the shader can flicker them in place.

const STICK := 0.125
const STICK_HEIGHT := 0.6
const WALL_TILT_DEG := 22.5
const WOOD := Color(0.36, 0.23, 0.11)
const WOOD_DARK := Color(0.24, 0.15, 0.07)
const WRAP := Color(0.24, 0.16, 0.1)
const IRON := Color(0.22, 0.22, 0.24)
const FLAME_OUTER := Color(1.0, 0.42, 0.05)
const FLAME_MID := Color(1.0, 0.66, 0.14)
const FLAME_TIP := Color(1.0, 0.9, 0.5)
const HALO_SIZE := 0.55

const SHADER_CODE := """
shader_type spatial;
render_mode unshaded, cull_disabled;

void vertex() {
	if (UV.x > 0.5) {
		vec3 pivot = vec3(UV2.x, UV2.y, UV.y);
		float seed = float(INSTANCE_ID) * 1.618;
		float flick = sin(TIME * 9.0 + seed) * 0.5 + sin(TIME * 13.7 + seed * 2.3) * 0.35 + sin(TIME * 4.1 + seed * 0.7) * 0.15;
		vec3 offset = VERTEX - pivot;
		offset.y *= 1.0 + 0.16 * flick;
		offset.xz *= 1.0 - 0.06 * flick;
		VERTEX = pivot + offset;
		COLOR.rgb *= 1.0 + 0.12 * flick;
	}
}

void fragment() {
	ALBEDO = COLOR.rgb;
}
"""


const HALO_SHADER_CODE := """
shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never, cull_disabled, skip_vertex_transform;

uniform float halo_size = 0.55;

varying float flick;

void vertex() {
	float seed = float(INSTANCE_ID) * 1.618;
	flick = sin(TIME * 9.0 + seed) * 0.5 + sin(TIME * 13.7 + seed * 2.3) * 0.35 + sin(TIME * 4.1 + seed * 0.7) * 0.15;
	vec3 view_centre = (MODELVIEW_MATRIX * vec4(VERTEX, 1.0)).xyz;
	// Nudge toward the camera so the glow is not swallowed by the wall behind.
	VERTEX = view_centre + vec3(UV * halo_size * (1.0 + 0.08 * flick), 0.35);
	NORMAL = vec3(0.0, 0.0, 1.0);
}

void fragment() {
	float d = length(UV);
	float a = pow(max(0.0, 1.0 - d), 2.2) * (0.42 + 0.06 * flick);
	ALBEDO = vec3(1.0, 0.55, 0.15) * a;
	ALPHA = 1.0;
}
"""


static func standing_mesh() -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var xform := Transform3D(Basis(), Vector3(0.0, -0.5, 0.0))
	_add_torch(st, xform)
	return _finish(st, xform)


static func wall_mesh() -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	# The stick base touches the wall face (z = -0.5) a little below mid-height
	# and leans out into the cell.
	var basis := Basis(Vector3.RIGHT, deg_to_rad(WALL_TILT_DEG))
	var base := Vector3(0.0, -0.38, -0.5 + STICK * 0.5)
	_add_torch(st, Transform3D(basis, base))
	# Iron bracket: a plate on the wall and a collar around the stick.
	_add_box(st, Transform3D(), Vector3(0.0, -0.22, -0.5 + 0.025), Vector3(0.2, 0.22, 0.05), IRON, false)
	_add_box(st, Transform3D(basis, base), Vector3(0.0, 0.2, 0.0), Vector3(STICK + 0.05, 0.05, STICK + 0.05), IRON, false)
	_add_box(st, Transform3D(), Vector3(0.0, -0.17, -0.5 + 0.07), Vector3(0.05, 0.05, 0.06), IRON, false)
	return _finish(st, Transform3D(basis, base))


## Rotation for a wall torch whose wall lies in direction `facing` from its cell
## (the wall mesh is modelled against -Z).
static func facing_basis(facing: Vector3i) -> Basis:
	if facing == Vector3i(-1, 0, 0):
		return Basis(Vector3.UP, PI * 0.5)
	if facing == Vector3i(1, 0, 0):
		return Basis(Vector3.UP, -PI * 0.5)
	if facing == Vector3i(0, 0, 1):
		return Basis(Vector3.UP, PI)
	return Basis()


## Commits the torch surface and adds the halo surface, each with its material.
static func _finish(st: SurfaceTool, torch_xform: Transform3D) -> ArrayMesh:
	var mesh := st.commit()
	mesh.surface_set_material(0, _material(SHADER_CODE))
	var halo := SurfaceTool.new()
	halo.begin(Mesh.PRIMITIVE_TRIANGLES)
	_add_halo(halo, torch_xform)
	halo.commit(mesh)
	var halo_material := _material(HALO_SHADER_CODE)
	halo_material.set_shader_parameter("halo_size", HALO_SIZE)
	mesh.surface_set_material(1, halo_material)
	return mesh


static func _material(code: String) -> ShaderMaterial:
	var shader := Shader.new()
	shader.code = code
	var material := ShaderMaterial.new()
	material.shader = shader
	return material


## One torch: stick, darker charred tip and cloth wrap, flame head on top.
## `xform` places the stick base (bottom centre) in cell space.
static func _add_torch(st: SurfaceTool, xform: Transform3D) -> void:
	var half_h := STICK_HEIGHT * 0.5
	_add_box(st, xform, Vector3(0.0, half_h - 0.04, 0.0), Vector3(STICK, STICK_HEIGHT - 0.08, STICK), WOOD, false)
	_add_box(st, xform, Vector3(0.0, STICK_HEIGHT - 0.04, 0.0), Vector3(STICK, 0.08, STICK), WOOD_DARK, false)
	_add_box(st, xform, Vector3(0.0, STICK_HEIGHT - 0.15, 0.0), Vector3(STICK + 0.03, 0.07, STICK + 0.03), WRAP, false)
	var flame_base := STICK_HEIGHT
	var pivot := xform * Vector3(0.0, flame_base, 0.0)
	_add_box(st, xform, Vector3(0.0, flame_base + 0.05, 0.0), Vector3(0.17, 0.1, 0.17), FLAME_OUTER, true, pivot)
	_add_box(st, xform, Vector3(0.0, flame_base + 0.13, 0.0), Vector3(0.12, 0.1, 0.12), FLAME_MID, true, pivot)
	_add_box(st, xform, Vector3(0.0, flame_base + 0.21, 0.0), Vector3(0.06, 0.08, 0.06), FLAME_TIP, true, pivot)


## Camera-facing glow quad around the flame (separate surface, additive).
## All four vertices sit at the flame centre; UV holds the corner (-1..1).
static func _add_halo(st: SurfaceTool, xform: Transform3D) -> void:
	var centre := xform * Vector3(0.0, STICK_HEIGHT + 0.1, 0.0)
	for corner: Vector2 in [Vector2(-1, -1), Vector2(-1, 1), Vector2(1, 1), Vector2(-1, -1), Vector2(1, 1), Vector2(1, -1)]:
		st.set_uv(corner)
		st.set_normal(Vector3.BACK)
		st.add_vertex(centre)


static func _add_box(st: SurfaceTool, xform: Transform3D, center: Vector3, size: Vector3, color: Color,
		flame: bool, pivot: Vector3 = Vector3.ZERO) -> void:
	var h := size * 0.5
	# Faces as (normal, four corners counter-clockwise seen from outside).
	var faces := [
		[Vector3.UP, [Vector3(-h.x, h.y, -h.z), Vector3(h.x, h.y, -h.z), Vector3(h.x, h.y, h.z), Vector3(-h.x, h.y, h.z)]],
		[Vector3.DOWN, [Vector3(-h.x, -h.y, h.z), Vector3(h.x, -h.y, h.z), Vector3(h.x, -h.y, -h.z), Vector3(-h.x, -h.y, -h.z)]],
		[Vector3.RIGHT, [Vector3(h.x, -h.y, h.z), Vector3(h.x, h.y, h.z), Vector3(h.x, h.y, -h.z), Vector3(h.x, -h.y, -h.z)]],
		[Vector3.LEFT, [Vector3(-h.x, -h.y, -h.z), Vector3(-h.x, h.y, -h.z), Vector3(-h.x, h.y, h.z), Vector3(-h.x, -h.y, h.z)]],
		[Vector3.BACK, [Vector3(-h.x, -h.y, h.z), Vector3(-h.x, h.y, h.z), Vector3(h.x, h.y, h.z), Vector3(h.x, -h.y, h.z)]],
		[Vector3.FORWARD, [Vector3(h.x, -h.y, -h.z), Vector3(h.x, h.y, -h.z), Vector3(-h.x, h.y, -h.z), Vector3(-h.x, -h.y, -h.z)]],
	]
	# Simple fixed face shading so the shape reads under the unshaded material.
	var shade := {Vector3.UP: 1.0, Vector3.DOWN: 0.55, Vector3.RIGHT: 0.8, Vector3.LEFT: 0.7, Vector3.BACK: 0.9, Vector3.FORWARD: 0.65}
	for face: Array in faces:
		var normal: Vector3 = face[0]
		var corners: Array = face[1]
		var face_color := color if flame else Color(color.r * shade[normal], color.g * shade[normal], color.b * shade[normal])
		var world_normal := (xform.basis * normal).normalized()
		for index: int in [0, 1, 2, 0, 2, 3]:
			st.set_color(face_color)
			st.set_normal(world_normal)
			st.set_uv(Vector2(1.0 if flame else 0.0, pivot.z))
			st.set_uv2(Vector2(pivot.x, pivot.y))
			st.add_vertex(xform * (center + corners[index]))
