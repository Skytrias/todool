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
uniform sampler2D u_sampler_kanban;
uniform sampler2D u_sampler_list;
uniform sampler2D u_sampler_drag;
uniform sampler2D u_sampler_search;
uniform sampler2D u_sampler_custom;
uniform vec4 u_shadow_color;

// output
out vec4 o_color;

// distance from a rectangle 
// doesnt do rounding
float sdBox(vec2 p, vec2 b) {
	vec2 d = abs(p) - b;
	return(length(max(d, vec2(0.0, 0.0))) + min(max(d.x, d.y), 0.0));
}

float sdArc(in vec2 p, in vec2 sc, in float ra, float rb) {
	p.x = abs(p.x);
	// return ((sc.y*p.x>sc.x*p.y) ? length(p-sc*ra) : abs(length(p)-ra)) - rb;
	return (sc.y*p.x > sc.x*p.y) ? length(p - ra*sc) - rb : abs(length(p) - ra) - rb;
}

float sdCircle(vec2 p, float r) {
	return length(p)-r;
}

float opOnion(float distance, float r) {
  return abs(distance) - r;
}

float sigmoid(float t) {
	return 1.0 / (1.0 + exp(-t));
}

float sdCircleWave(vec2 p, float tb, float ra) {
	tb = 3.1415927*5.0/6.0 * max(tb,0.0001);
	vec2 co = ra*vec2(sin(tb),cos(tb));

	p.x = abs(mod(p.x,co.x*4.0)-co.x*2.0);

	vec2 p1 = p;
	vec2 p2 = vec2(abs(p.x-2.0*co.x),-p.y+2.0*co.y);
	float d1 = ((co.y*p1.x>co.x*p1.y) ? length(p1-co) : abs(length(p1)-ra));
	float d2 = ((co.y*p2.x>co.x*p2.y) ? length(p2-co) : abs(length(p2)-ra));

	return min(d1, d2); 
}

float dot2( in vec2 v ) { return dot(v,v); }
float cro( in vec2 a, in vec2 b ) { return a.x*b.y - a.y*b.x; }

float sdBezier(vec2 p, vec2 v0, vec2 v1, vec2 v2) {
	vec2 i = v0 - v2;
	vec2 j = v2 - v1;
	vec2 k = v1 - v0;
	vec2 w = j-k;

	v0-= p; v1-= p; v2-= p;
	  
	float x = cro(v0, v2);
	float y = cro(v1, v0);
	float z = cro(v2, v1);

	vec2 s = 2.0*(y*j+z*k)-x*i;

	float r =  (y*z-x*x*0.25)/dot2(s);
	float t = clamp( (0.5*x+y+r*dot(s,w))/(x+y+z),0.0,1.0);
	  
	return length( v0+t*(k+k+t*w) );
}

#define RK_Invalid uint(0)
#define RK_Rect uint(1)
#define RK_Glyph uint(2)
#define RK_Drop_Shadow uint(3)
#define RK_Circle uint(4)
#define RK_Circle_Outline uint(5)
#define RK_Sine uint(6)
#define RK_QBezier uint(7)

#define RK_SV uint(8)
#define RK_HUE uint(9)
#define RK_Kanban uint(10)
#define RK_List uint(11)
#define RK_Drag uint(12)
#define RK_TEXTURE uint(13)

void main(void) {
	vec4 color_goal = v_color;

	if (v_kind == RK_Invalid) {

	} else if (v_kind == RK_Rect) {
		// calculate distance from center and dimensions
		vec2 center = v_uv;
		float distance = sdBox(v_pos - center, v_adjusted_half_dimensions);
		distance -= v_roundness;

		// add thickness if exists	
		if (v_thickness >= 1) {
			distance = (abs(distance + v_thickness) - v_thickness);
		}
		
		float alpha = 1.0 - smoothstep(-1, 0, distance);
		color_goal.a *= alpha;
	} else if (v_kind == RK_Glyph) {
		float alpha = texture(u_sampler_font, v_uv).r;
		color_goal.a *= alpha;
	} else if (v_kind == RK_Drop_Shadow) {
		vec2 center = v_uv;
		vec2 drop_size = vec2(20, 20);

		float drop_distance = sdBox(v_pos - center - vec2(2, 2), v_adjusted_half_dimensions - drop_size);
		drop_distance -= v_roundness;
		drop_distance = sigmoid(drop_distance * 0.25);
		float drop_alpha = 1 - smoothstep(0, 1, drop_distance);

		float rect_distance = sdBox(v_pos - center, v_adjusted_half_dimensions - drop_size);
		rect_distance -= v_roundness;
		float rect_alpha = 1 - smoothstep(-1, 1, rect_distance);

		color_goal = u_shadow_color;
		color_goal.a = drop_alpha;
		color_goal = mix(color_goal, v_color, rect_alpha);
		color_goal.a *= v_color.a; // keep v_color alpha for transition
	} else if (v_kind == RK_Circle) {
		float distance = sdCircle(v_pos - v_uv, v_roundness / 2);
		float alpha = 1.0 - smoothstep(-1.0, 0.0, distance);
		color_goal.a *= alpha;
	} else if (v_kind == RK_Circle_Outline) {
		float thickness = v_thickness;
		float distance = opOnion(sdCircle(v_pos - v_uv, v_roundness / 2) + thickness, thickness);

		float alpha = 1.0 - smoothstep(-1.0, 0.0, distance);
		color_goal.a *= alpha;
	} else if (v_kind == RK_Sine) {
		// basic sine wave, inverted for only wave coloring
		float distance = sdCircleWave(v_pos - v_uv, 0.4, 2);
		// float alpha = 1.0 - smoothstep(0, 0.5, distance);
		// float alpha = distance;
		float alpha = 1 - distance;
		color_goal.a *= alpha;
	} else if (v_kind == RK_QBezier) {
		// float alpha = 1 - distance;
		// color_goal.a *= alpha;
		color_goal = vec4(1, 0, 0, 1);
		// color_goal ;
	} else if (v_kind == RK_SV) {
		vec4 texture_color = texture(u_sampler_sv, v_uv);
		color_goal = mix(color_goal, texture_color, texture_color.a);
		color_goal.a = 1;
	} else if (v_kind == RK_HUE) {
		vec4 texture_color = texture(u_sampler_hue, v_uv);
		color_goal = texture_color;
	} else if (v_kind == RK_TEXTURE) {
		vec4 texture_color = texture(u_sampler_custom, v_uv);
		color_goal = texture_color;
	} else if (v_kind == RK_Kanban) {
		vec4 texture_color = texture(u_sampler_kanban, v_uv);
		color_goal *= texture_color;
	} else if (v_kind == RK_List) {
		vec4 texture_color = texture(u_sampler_list, v_uv);
		color_goal *= texture_color;
	} else if (v_kind == RK_Drag) {
		vec4 texture_color = texture(u_sampler_drag, v_uv);
		color_goal *= texture_color;
	}

	o_color = color_goal;
}