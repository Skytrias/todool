#version 330

// input from vertex
in vec2 i_pos;
in vec2 i_uv;
in uint i_color;
in vec4 i_add;
in uint i_roundness_and_thickness;
in vec2 i_additional;
in uint i_kind;

// uniforms
uniform mat4 u_projection;

// output
out vec2 v_pos;
out vec2 v_uv;
out vec4 v_color;
out vec2 v_adjusted_half_dimensions;
out vec4 v_add;
out float v_roundness;
out float v_thickness;
out vec2 v_additional;
flat out uint v_kind;

// get u16 information out
uint uint_get_lower(uint val) { return val & uint(0xFFFF); }
uint uint_get_upper(uint val) { return val >> 16 & uint(0xFFFF); }

void main(void) {
	gl_Position = u_projection * vec4(i_pos, 0, 1);
	v_additional = i_additional;
	v_pos = i_pos;
	v_uv = i_uv;

	// only available since glsl 4.0
	// v_color = unpackUnorm4x8(i_color);
	// unwrap color from uint
	v_color = vec4(
		float((i_color       ) & 0xFFu) / 255.0, 
		float((i_color >> 8u ) & 0xFFu) / 255.0,
		float((i_color >> 16u) & 0xFFu) / 255.0,
		float((i_color >> 24u) & 0xFFu) / 255.0  // alpha
	);

	v_roundness = float(uint_get_lower(i_roundness_and_thickness));
	v_thickness = float(uint_get_upper(i_roundness_and_thickness)) / 1.5;

	// calculate dimensions per vertex
	vec2 center = i_uv;
	// center = round(center);
	vec2 half_dimensions = abs(v_pos - center);
	v_adjusted_half_dimensions = half_dimensions - v_roundness + vec2(0.5, 0.5);

	v_kind = i_kind;
	v_add = i_add;
}