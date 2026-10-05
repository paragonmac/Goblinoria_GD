// Render-only cutout: never edits terrain or invalidates cached chunk meshes.
uniform bool excavation_preview_enabled = false;
uniform vec3 excavation_preview_min = vec3(0.0);
uniform vec3 excavation_preview_max = vec3(0.0);
varying vec3 preview_world_position;
varying vec3 preview_world_normal;

void vertex() {
	preview_world_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	preview_world_normal = normalize(mat3(MODEL_MATRIX) * NORMAL);
}

bool inside_excavation_preview() {
	// Sample inside the face's owning block, preserving neighboring boundary faces.
	vec3 inside_position = preview_world_position - preview_world_normal * 0.001;
	return excavation_preview_enabled
		&& all(greaterThan(inside_position, excavation_preview_min))
		&& all(lessThan(inside_position, excavation_preview_max));
}
