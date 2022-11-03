package src

import "core:intrinsics"
import "core:fmt"
import "core:strings"
import "core:math/rand"
import "core:math/noise"
import "core:math/ease"
import "../fontstash"
import "../cutf8"

// NOTE noise return -1 to 1 range

PM_State :: struct {
	particles: [dynamic]PM_Particle,
	spawn_next: bool,

	color_seed: i64,
	color_count: f64,
}
pm_state: PM_State

PM_Particle :: struct {
	lifetime: f32,
	lifetime_count: f32,
	x, y: f32,
	xoff, yoff: f32, // camera offset at the spawn time
	radius: f32,
	color: Color,
	seed: i64,
}

power_mode_init :: proc() {
	using pm_state
	particles = make([dynamic]PM_Particle, 0, 256)
	color_seed = intrinsics.read_cycle_counter()
}

power_mode_destroy :: proc() {
	using pm_state
	delete(particles)
}

power_mode_clear :: proc() {
	using pm_state
	clear(&particles)
	color_count = 0
}

power_mode_check_spawn :: proc() {
	using pm_state

	if spawn_next {
		power_mode_spawn_at_caret()
		spawn_next = false
	}
}

// simple line
power_mode_spawn_along_text :: proc(text: string, x, y: f32, color: Color) {
	fcs_ahv(.Left, .Top)
	fcs_size(DEFAULT_FONT_SIZE * TASK_SCALE)
	fcs_font(font_regular)
	iter := fontstash.text_iter_init(&gs.fc, text, x, y)
	q: fontstash.Quad

	cam := mode_panel_cam()
	for fontstash.text_iter_step(&gs.fc, &iter, &q) {
		power_mode_spawn_at(iter.x, iter.y, cam.offset_x, cam.offset_y, 4, color)
	}
}

// NOTE using rendered glyphs only
power_mode_spawn_along_task_text :: proc(task: ^Task) {
	if len(task.box.rendered_glyphs) != 0 {
		text := strings.to_string(task.box.builder)
		color := theme_task_text(task.state)
		cam := mode_panel_cam()
		ds: cutf8.Decode_State

		for codepoint, i in cutf8.ds_iter(&ds, text) {
			glyph := task.box.rendered_glyphs[i] 
			power_mode_spawn_at(glyph.x, glyph.y, cam.offset_x, cam.offset_y, 4, color)
		}
	}
}

power_mode_spawn_at_caret :: proc() {
	cam := mode_panel_cam()
	x := f32(caret_rect.l)
	y := f32(caret_rect.t) + rect_heightf_halfed(caret_rect)
	power_mode_spawn_at(x, y, cam.offset_x, cam.offset_y, 10, theme.text_default)
}

power_mode_spawn_at :: proc(
	x, y: f32, 
	xoff, yoff: f32, 
	count: int,
	color := Color {},
) {
	using pm_state

	width := 20 * TASK_SCALE
	height := DEFAULT_FONT_SIZE * TASK_SCALE * 2
	size := 2 * TASK_SCALE

	// NOTE could resize upfront?

	for i in 0..<count {
		life := rand.float32() * 0.5 + 0.5 // min is 0.5

		// color
		c := color 
		if c == {} {
			// normalize to 0 -> 1
			value := (noise.noise_2d(color_seed, { color_count / 16, 0 }) + 1) / 2
			c = color_hsv_to_rgb(value, 1, 1)
		}

		append(&particles, PM_Particle {
			lifetime = life,
			lifetime_count = life,
			x = x + rand.float32() * width - width / 2,
			y = y + rand.float32() * height - height / 2,
			radius = 2 + rand.float32() * size,
			color = c,
			xoff = -xoff,
			yoff = -yoff,

			// random seed
			seed = intrinsics.read_cycle_counter(),
		})

		color_count += 1
	}
}

power_mode_update :: proc() {
	using pm_state
	
	for i := len(particles) - 1; i >= 0; i -= 1 {
		p := &particles[i]

		if p.lifetime_count > 0 {
			p.lifetime_count -= gs.dt
			x_dir := noise.noise_2d(p.seed, { f64(p.lifetime_count) / 2, 0 })
			y_dir := noise.noise_2d(p.seed, { f64(p.lifetime_count) / 2, 1 })
			p.x += x_dir * TASK_SCALE * TASK_SCALE
			p.y += y_dir * TASK_SCALE * TASK_SCALE
		} else {
			unordered_remove(&particles, i)
		}
	}
}

power_mode_render :: proc(target: ^Render_Target) {
	using pm_state
	
	cam := mode_panel_cam()
	xoff, yoff: f32

	for p in &particles {
		xoff = p.xoff + cam.offset_x
		yoff = p.yoff + cam.offset_y

		alpha := max(p.lifetime_count / p.lifetime, 0)
		color := color_alpha(p.color, alpha)
		// color := color_alpha(theme.text_default, alpha)
		render_circle(target, p.x + xoff, p.y + yoff, p.radius, color, true)
	}		
}

power_mode_running :: #force_inline proc() -> bool {
	return len(pm_state.particles) != 0 
}

power_mode_issue_spawn :: #force_inline proc() {
	pm_state.spawn_next = true
}