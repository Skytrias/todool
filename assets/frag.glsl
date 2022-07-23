#version 330

// input from vertex
in vec2 v_pos;
in vec2 v_uv;
in vec4 v_color;
in vec2 v_adjusted_half_dimensions;
in float v_roundness;
in float v_thickness;
flat in uint v_kind;

// uniforms
uniform mat4 u_projection;
uniform sampler2D u_sampler_font;
uniform sampler2D u_sampler_sv;
uniform sampler2D u_sampler_hue;
uniform sampler2D u_sampler_test;
uniform vec4 u_shadow_color;

// output
out vec4 o_color;

// distance from a rectangle 
// doesnt do rounding
float rectangle_sd(vec2 p, vec2 b) {
	vec2 d = abs(p) - b;
	return(length(max(d, vec2(0.0, 0.0))) + min(max(d.x, d.y), 0.0));
}

float sigmoid(float t) {
	return 1.0 / (1.0 + exp(-t));
}

#define RK_Invalid uint(0)
#define RK_Rect uint(1)
#define RK_Glyph uint(2)
#define RK_Drop_Shadow uint(3)
#define RK_SV uint(4)
#define RK_HUE uint(5)
#define RK_TEST uint(6)

void main(void) {
	vec4 color_goal = v_color;

	if (v_kind == RK_Invalid) {

	} else if (v_kind == RK_Rect) {
		// calculate distance from center and dimensions
		vec2 center = v_uv;
		float distance = rectangle_sd(v_pos - center, v_adjusted_half_dimensions);
		distance -= v_roundness;

		// add thickness if exists	
		if (v_thickness >= 1) {
			distance = (abs(distance + v_thickness) - v_thickness);
		}
		
		float alpha = 1.0 - smoothstep(-1.0, 0.0, distance);
		color_goal.a *= alpha;
	} else if (v_kind == RK_Glyph) {
		float alpha = texture(u_sampler_font, v_uv).r;
		color_goal.a *= alpha;
	} else if (v_kind == RK_Drop_Shadow) {
		vec2 center = v_uv;
		vec2 drop_size = vec2(20, 20);

		float drop_distance = rectangle_sd(v_pos - center, v_adjusted_half_dimensions - drop_size);
		drop_distance -= v_roundness;
		drop_distance = sigmoid(drop_distance * 0.25);
		float drop_alpha = 1 - smoothstep(0, 1, drop_distance);

		float rect_distance = rectangle_sd(v_pos - center, v_adjusted_half_dimensions - drop_size);
		rect_distance -= v_roundness;
		float rect_alpha = 1 - smoothstep(-1, 1, rect_distance);

		color_goal = u_shadow_color;
		color_goal.a = drop_alpha;
		color_goal = mix(color_goal, v_color, rect_alpha);
	} else if (v_kind == RK_SV) {
		vec4 texture_color = texture(u_sampler_sv, v_uv);
		color_goal = mix(color_goal, texture_color, texture_color.a);
		color_goal.a = 1;
	} else if (v_kind == RK_HUE) {
		vec4 texture_color = texture(u_sampler_hue, v_uv);
		color_goal = texture_color;
	} else if (v_kind == RK_TEST) {
		vec2 uv = v_uv;
		vec2 texture_size = vec2(32, 32);
		vec2 size = vec2(v_roundness, v_thickness);
		uv *= (size / texture_size);
		vec4 texture_color = texture(u_sampler_test, uv);
		color_goal *= texture_color;
	}

	o_color = color_goal;
}