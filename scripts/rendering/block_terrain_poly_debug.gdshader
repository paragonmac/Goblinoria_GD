shader_type spatial;
render_mode unshaded, cull_back, depth_draw_opaque;

uniform float top_render_y = 0.0;
uniform float min_render_y = -1e20;

const float GREEDY_UV2_FLAG = 2.0;
const float DEBUG_BUCKET_COUNT = 16.0;
const vec3 LIGHT_DIR = normalize(vec3(-0.45, 0.85, 0.25));

vec3 debug_palette(float bucket) {
	float i = mod(bucket, DEBUG_BUCKET_COUNT);
	if (i < 0.5) { return vec3(0.95, 0.20, 0.20); }
	if (i < 1.5) { return vec3(0.15, 0.55, 1.00); }
	if (i < 2.5) { return vec3(0.20, 0.85, 0.35); }
	if (i < 3.5) { return vec3(1.00, 0.78, 0.10); }
	if (i < 4.5) { return vec3(0.75, 0.35, 1.00); }
	if (i < 5.5) { return vec3(0.10, 0.90, 0.90); }
	if (i < 6.5) { return vec3(1.00, 0.45, 0.15); }
	if (i < 7.5) { return vec3(0.55, 0.90, 0.15); }
	if (i < 8.5) { return vec3(0.95, 0.35, 0.70); }
	if (i < 9.5) { return vec3(0.35, 0.75, 1.00); }
	if (i < 10.5) { return vec3(0.70, 0.95, 0.40); }
	if (i < 11.5) { return vec3(1.00, 0.60, 0.35); }
	if (i < 12.5) { return vec3(0.55, 0.55, 1.00); }
	if (i < 13.5) { return vec3(0.20, 1.00, 0.65); }
	if (i < 14.5) { return vec3(1.00, 0.95, 0.25); }
	return vec3(0.95, 0.95, 0.95);
}

void fragment() {
	if (UV2.x < min_render_y) {
		discard;
	}
	if (UV2.x > top_render_y) {
		discard;
	}
	bool greedy_uv = UV2.y >= GREEDY_UV2_FLAG;
	float top_flag = UV2.y;
	if (greedy_uv) {
		float encoded = UV2.y - GREEDY_UV2_FLAG;
		top_flag = mod(encoded, 2.0);
	}
	if (top_flag > 0.5 && top_render_y >= UV2.x + 1.0) {
		discard;
	}
	float encoded = UV2.y;
	if (greedy_uv) {
		encoded = UV2.y - GREEDY_UV2_FLAG;
	}
	float vertex_bucket = floor(clamp(COLOR.a, 0.0, 0.999) * DEBUG_BUCKET_COUNT);
	float fallback_bucket = floor(mod(
		floor(UV.x * 0.37)
		+ floor(UV.y * 0.61)
		+ floor(UV2.x * 1.73)
		+ floor(encoded * 2.11)
		+ floor((NORMAL.x + 1.0) * 3.0)
		+ floor((NORMAL.y + 1.0) * 5.0)
		+ floor((NORMAL.z + 1.0) * 7.0),
		DEBUG_BUCKET_COUNT
	));
	float bucket = vertex_bucket;
	if (COLOR.a > 0.99) {
		bucket = fallback_bucket;
	}
	float shade = clamp(dot(normalize(NORMAL), LIGHT_DIR) * 0.45 + 0.65, 0.35, 1.0);
	ALBEDO = debug_palette(bucket) * shade;
}
