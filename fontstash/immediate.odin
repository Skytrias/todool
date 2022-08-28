package fontstash

import "core:mem"
import "core:log"
import "../cutf8"

State :: struct {
	font: int,
	size: f32,
	color: [4]u8,
	spacing: f32,
	blur: f32,

	ah: Align_Horizontal,
	av: Align_Vertical,
}

state_push :: proc(using ctx: ^Font_Context) {
	if state_count >= STATE_MAX {
		log.error("FONTSTASH: state max exceeded")
	}

	if state_count > 0 {
		mem.copy(&states[state_count], &states[state_count - 1], size_of(State))
	}

	state_count += 1
}

state_pop :: proc(using ctx: ^Font_Context) {
	if state_count <= 1 {
		log.error("FONTSTASH: state underflow! to many pops were called")
	}

	state_count -= 1
}

state_clear :: proc(ctx: ^Font_Context) {
	state := state_get(ctx)
	state.size = 12
	state.color = 255
	state.blur = 0
	state.spacing = 0
	state.font = 0
	state.ah = .Left
	state.av = .Top
}

state_get :: #force_inline proc(ctx: ^Font_Context) -> ^State {
	return &ctx.states[ctx.state_count - 1]
}

state_set_size :: proc(ctx: ^Font_Context, size: f32) {
	state_get(ctx).size  = size
}

state_set_color :: proc(ctx: ^Font_Context, color: [4]u8) {
	state_get(ctx).color = color
}

state_set_spacing :: proc(ctx: ^Font_Context, spacing: f32) {
	state_get(ctx).spacing = spacing
}

state_set_blur :: proc(ctx: ^Font_Context, blur: f32) {
	state_get(ctx).blur = blur
}

state_set_font :: proc(ctx: ^Font_Context, font: int) {
	state_get(ctx).font = font
}

state_set_align_horizontal :: proc(ctx: ^Font_Context, ah: Align_Horizontal) {
	state_get(ctx).ah = ah
}

state_set_align_vertical :: proc(ctx: ^Font_Context, av: Align_Vertical) {
	state_get(ctx).av = av
}

// text iteration with custom settings

Text_Iter :: struct {
	x, y, nextx, nexty, scale, spacing: f32,

	codepoint: rune,
	isize, iblur: i16,

	font: ^Font,
	previous_glyph_index: Glyph_Index,

	text: string,
	state: rune, // utf8
}

text_iter_init :: proc(
	ctx: ^Font_Context,
	x, y: f32,
	text: string,
) -> (res: Text_Iter) {
	state := state_get(ctx)

	// font 
	// assert(!(state.font < 0 || state.font >= len(ctx.fonts)))
	res.font = &ctx.fonts[state.font]
	res.isize = i16(state.size * 10)
	res.iblur = i16(state.blur)
	res.scale = scale_for_pixel_height(res.font, f32(res.isize / 10))

	// align horizontally
	x := x
	y := y
	switch state.ah {
		case .Left: {}
		case .Middle: {
			width := text_bounds(ctx, x, y, text, nil)
			x -= width
		}
		case .Right: {
			width := text_bounds(ctx, x, y, text, nil)
			x -= width * 0.5
		}
	}

	// align vertically
	y += get_vertical_align(res.font, res.isize, state.av)

	// set positions
	res.x = x
	res.nextx = x
	res.y = y
	res.nexty = y
	res.previous_glyph_index = -1
	res.spacing = state.spacing
	res.text = text
	return
}

text_iter_step :: proc(
	ctx: ^Font_Context, 
	iter: ^Text_Iter, 
	quad: ^Quad,
) -> (ok: bool) {
	for len(iter.text) > 0 {
		b := iter.text[0]
		iter.text = iter.text[1:]

		if cutf8.decode(&iter.state, &iter.codepoint, b) {
			iter.x = iter.nextx
			iter.y = iter.nexty
			glyph := get_glyph(ctx, iter.font, iter.codepoint, iter.isize, u8(iter.iblur))
			
			if glyph != nil {
				get_quad(ctx, iter.font, iter.previous_glyph_index, glyph, iter.scale, iter.spacing, &iter.nextx, &iter.nexty, quad)
			}

			iter.previous_glyph_index = glyph == nil ? -1 : glyph.index
			ok = true
			break
		}
	}

	return
}

// rendering using immediate style state

Quad :: struct {
	x0, y0, s0, t0: f32,
	x1, y1, s1, t1: f32,
}

get_vertical_align :: align_vertical

get_quad :: proc(
	ctx: ^Font_Context,
	font: ^Font,
	
	previous_glyph_index: i32,
	glyph: ^Glyph,

	scale: f32,
	spacing: f32,
	
	x, y: ^f32,
	quad: ^Quad,
) {
	if previous_glyph_index != -1 {
		adv := f32(glyph_kern_advance(font, previous_glyph_index, glyph.index)) * scale
		x^ += f32(int(adv + spacing + 0.5))
	}

	// fill props right
	rx, ry, x0, y0, x1, y1, xoff, yoff, glyph_width, glyph_height: f32
	xoff = f32(glyph.xoff + 1)
	yoff = f32(glyph.yoff + 1)
	x0 = f32(glyph.x0 + 1)
	y0 = f32(glyph.y0 + 1)
	x1 = f32(glyph.x1 - 1)
	y1 = f32(glyph.y1 - 1)
	rx = f32(int(x^) + int(xoff))
	ry = f32(int(y^) + int(yoff))

	// fill quad
	quad.x0 = rx
	quad.y0 = ry
	quad.x1 = rx + x1 - x0
	quad.y1 = ry + y1 - y0

	// texture info
	quad.s0 = x0 * ctx.itw
	quad.t0 = y0 * ctx.ith
	quad.s1 = x1 * ctx.itw
	quad.t1 = y1 * ctx.ith

	x^ += f32(int(glyph.xadvance / 10)) + 0.5
}

// width of a text line
text_bounds :: proc(
	ctx: ^Font_Context,
	x, y: f32,
	text: string,
	bounds: ^[4]f32,
) -> f32 {
	state := state_get(ctx)
	isize := i16(state.size * 10)
	iblur := i16(state.blur)

	// font 
	if state.font < 0 || state.font >= len(ctx.fonts) {
		return 0
	}
	font := &ctx.fonts[state.font]

	// bunch of state
	x := x
	y := y
	minx := x
	maxx := x
	miny := y 
	maxy := y
	start_x := x

	// iterate	
	scale := scale_for_pixel_height(font, f32(isize / 10))
	ds: cutf8.Decode_State
	previous_glyph_index: Glyph_Index = -1
	quad: Quad
	for codepoint in cutf8.ds_iter(&ds, text) {
		glyph := get_glyph(ctx, font, codepoint, isize, u8(iblur))

		if glyph != nil {
			get_quad(ctx, font, previous_glyph_index, glyph, scale, state.spacing, &x, &y, &quad)

			if quad.x0 < minx {
				minx = quad.x0
			}
			if quad.x1 > maxx {
				maxx = quad.x1
			}
			if quad.y1 < miny {
				miny = quad.y1
			}
			if quad.y0 > maxy {
				maxy = quad.y0
			}
		}

		previous_glyph_index = glyph == nil ? -1 : glyph.index
	}

	// alignment
	advance := x - start_x
	switch state.ah {
		case .Left: {}
		case .Middle: {
			minx -= advance
			maxx -= advance
		}
		case .Right: {
			minx -= advance * 0.5
			maxx -= advance * 0.5
		}
	}

	if bounds != nil {
		bounds[0] = minx
		bounds[1] = miny
		bounds[2] = maxx
		bounds[3] = maxy
	}

	return advance
}

// state_draw_text :: proc(ctx: ^Font_Context, x, y: f32, text: string) -> (output: f32) {
// 	state := state_get(ctx)
// 	isize := i16(state.size * 10)
// 	iblur := i16(state.blur)
// 	x := x
// 	y := y
// 	output = x

// 	// get font
// 	if state.font < 0 || state.font >= len(ctx.fonts) {
// 		return
// 	}
// 	font := &ctx.fonts[state.font]

// 	// align horizontally 
// 	switch state.ah {
// 		case .Left: {}
// 		case .Middle: {
// 			width := text_bounds(ctx, x, y, text, nil)
// 			x -= width
// 		}
// 		case .Right: {
// 			width := text_bounds(ctx, x, y, text, nil)
// 			x -= width * 0.5
// 		}
// 	}

// 	// align vertically
// 	y += get_vertical_align(font, isize, state.av)

// 	// iterate codepoints
// 	scale := scale_for_pixel_height(font, f32(isize / 10))
// 	ds: cutf8.Decode_State
// 	quad: Quad
// 	previous_glyph_index: Glyph_Index = -1
// 	for codepoint in cutf8.ds_iter(&ds, text) {
// 		glyph, _ := get_glyph(ctx, font, codepoint, isize, u8(iblur))

// 		// push quad
// 		if glyph != nil {
// 			get_quad(ctx, font, previous_glyph_index, glyph, scale, state.spacing, &x, &y, &quad)

// 			push_vertex(ctx, { quad.x0, quad.y0, quad.s0, quad.t0, state.color })
// 			push_vertex(ctx, { quad.x1, quad.y1, quad.s1, quad.t1, state.color })
// 			push_vertex(ctx, { quad.x1, quad.y0, quad.s1, quad.t0, state.color })
			
// 			push_vertex(ctx, { quad.x0, quad.y0, quad.s0, quad.t0, state.color })
// 			push_vertex(ctx, { quad.x0, quad.y1, quad.s0, quad.t1, state.color })
// 			push_vertex(ctx, { quad.x1, quad.y1, quad.s1, quad.t1, state.color })
// 		}

// 		previous_glyph_index = glyph == nil ? -1 : glyph.index
// 	}

// 	output = x
// 	return 
// }

state_vertical_metrics :: proc(
	ctx: ^Font_Context,
) -> (ascender, descender, line_height: f32) {
	state := state_get(ctx)
	isize := i16(state.size * 10)

	// get font
	if state.font < 0 || state.font >= len(ctx.fonts) {
		return
	}
	font := &ctx.fonts[state.font]

	ascender = font.ascender * f32(isize / 10)
	descender = font.descender * f32(isize / 10)
	line_height = font.line_height * f32(isize / 10)
	return
}

// vertice pushing

flush :: proc(using ctx: ^Font_Context) {
	// flush texture
	if dirty_rect[0] < dirty_rect[2] && dirty_rect[1] < dirty_rect[3] {
		// if (params.renderUpdate != NULL)
		// 	params.renderUpdate(params.userPtr, dirty_rect, texData);

		dirty_rect_reset(ctx)
	}

	// // flush triangles
	// if nverts > 0 {
	// 	// if params.renderDraw != NULL
	// 	// 	params.renderDraw(params.userPtr, verts, tcoords, colors, nverts);
		
	// 	nverts = 0
	// }
}

dirty_rect_reset :: proc(using ctx: ^Font_Context) {
	dirty_rect[0] = f32(width)
	dirty_rect[1] = f32(height)
	dirty_rect[2] = 0
	dirty_rect[3] = 0
}

// guessing this is for validating texture update based on dirty rect?
validate_texture :: proc(using ctx: ^Font_Context, dirty: ^[4]f32) -> bool {
	if dirty_rect[0] < dirty_rect[2] && dirty_rect[1] < dirty_rect[3] {
		dirty[0] = dirty_rect[0]
		dirty[1] = dirty_rect[1]
		dirty[2] = dirty_rect[2]
		dirty[3] = dirty_rect[3]
		dirty_rect_reset(ctx)
		return true
	}

	return false
}
