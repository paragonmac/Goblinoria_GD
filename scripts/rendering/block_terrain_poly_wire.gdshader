shader_type spatial;
render_mode unshaded, wireframe, cull_back, depth_draw_opaque;

uniform float top_render_y = 0.0;
uniform float min_render_y = -1e20;

const float GREEDY_UV2_FLAG = 2.0;
const float COVERED_FROM_ABOVE_FLAG = 256.0;

void fragment() {
	float encoded_uv2_y = UV2.y;
	bool covered_from_above = encoded_uv2_y >= COVERED_FROM_ABOVE_FLAG;
	if (covered_from_above) {
		encoded_uv2_y -= COVERED_FROM_ABOVE_FLAG;
	}
	if (UV2.x < min_render_y) {
		discard;
	}
	if (UV2.x > top_render_y) {
		discard;
	}
	if (covered_from_above && NORMAL.y < 0.5) {
		discard;
	}
	bool greedy_uv = encoded_uv2_y >= GREEDY_UV2_FLAG;
	float top_flag = encoded_uv2_y;
	if (greedy_uv) {
		float encoded = encoded_uv2_y - GREEDY_UV2_FLAG;
		top_flag = mod(encoded, 2.0);
	}
	if (top_flag > 0.5 && top_render_y >= UV2.x + 1.0) {
		discard;
	}
	ALBEDO = vec3(0.02, 0.025, 0.03);
}
