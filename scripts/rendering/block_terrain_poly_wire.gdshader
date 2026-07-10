shader_type spatial;
render_mode unshaded, wireframe, cull_back, depth_draw_opaque;

uniform float top_render_y = 0.0;
uniform float min_render_y = -1e20;

const float GREEDY_UV2_FLAG = 2.0;

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
	ALBEDO = vec3(0.02, 0.025, 0.03);
}
