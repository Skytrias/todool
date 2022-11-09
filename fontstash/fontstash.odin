package fontstash

import "core:runtime"
import "core:fmt"
import "core:log"
import "core:os"
import "core:mem"
import "core:math"
import "core:unicode"
import stbtt "vendor:stb/truetype"
import "../cutf8"
import "../spall"

// This is a port from Fontstash into odin

// Notable features of Fontstash:
// Contains a *single* channel texture atlas for multiple fonts
// Manages a lookup table for frequent glyphs
// Allows blurred font glyphs
// Atlas can resize

// Changes from the original:
// stb truetype only 
// no scratch allocation -> parts use odins dynamic arrays
// different procedure naming as this will be used as a package, renaming Fons -> Font
// leaves GPU vertex creation & texture management up to the user
// texture atlas expands by default

// other:
// immediate mode is "optional" - store the state global yourself
// wrapped text for wrapped text & caret layouting
// utf8 traversal done with utf8 table instead of odin's

STATE_MAX :: 20
LUT_SIZE :: 256
INIT_GLYPHS :: 256
ATLAS_NODES :: 256
Glyph_Index :: i32

Align_Horizontal :: enum {
	Left,
	Middle,
	Right,
}

Align_Vertical :: enum {
	Top,
	Middle,
	Baseline,
	Bottom,
}

Font :: struct {
	info: stbtt.fontinfo,
	free_loaded_data: bool,
	loaded_data: []byte,

	ascender: f32,
	descender: f32,
	line_height: f32,

	glyphs: [dynamic]Glyph,
	lut: [LUT_SIZE]int,
}

Glyph :: struct {
	codepoint: rune,
	index: Glyph_Index,
	next: int,
	isize: i16,
	blur_size: i16,
	x0, y0, x1, y1: i16,
	xoff, yoff: i16,
	xadvance: i16,
}

Atlas_Node :: struct {
	x, y, width: i16,
}

Vertex :: struct #packed {
	x, y: f32,
	u, v: f32,
	color: [4]u8,
}

Font_Context :: struct {
	fonts: [dynamic]Font, // allocated using context.allocator

	// always assuming user wants to resize
	nodes: [dynamic]Atlas_Node,

	// actual pixels
	texture_data: []byte, // allocated using context.allocator
	width, height: int,
	// 1 / texture_atlas_width, 1 / texture_atlas_height
	itw, ith: f32,

	// state 
	states: []State,
 	state_count: int, // used states
 	
 	// dirty rectangle of the texture region that was updated
 	dirty_rect: [4]f32,

 	// callbacks with user_data passed
 	user_data: rawptr, // by default set to the context
 	// called when a texture is expanded and needs handling
 	callback_resize: proc(data: rawptr, w, h: int), 
 	// called in state_end to update the texture region that changed
 	callback_update: proc(data: rawptr, dirty_rect: [4]f32, texture_data: rawptr), 
}

init :: proc(using ctx: ^Font_Context, w, h: int) {
	spall.scoped("fontstash init")
	
	user_data = ctx
	fonts = make([dynamic]Font, 0, 8)

	itw = f32(1) / f32(w)
	ith = f32(1) / f32(h)
	texture_data = make([]byte, w * h)
	
	width = w
	height = h
	nodes = make([dynamic]Atlas_Node, 0, ATLAS_NODES)
	dirty_rect_reset(ctx)

	states = make([]State, STATE_MAX)

	// NOTE NECESSARY
	append(&nodes, Atlas_Node {
		width = i16(w),
	})

	font_atlas_add_white_rect(ctx, 2, 2)

	state_push(ctx)
	state_clear(ctx)
}

destroy :: proc(using ctx: ^Font_Context) {
	for font in &fonts {
		if font.free_loaded_data {
			delete(font.loaded_data)
		}

		delete(font.glyphs)
	}

	delete(states)
	delete(texture_data)
	delete(fonts)
	delete(nodes)
}

reset :: proc(using ctx: ^Font_Context) {
	font_atlas_reset(ctx, width, height)
	dirty_rect_reset(ctx)
	mem.zero_slice(texture_data)

	for font in &fonts {
		font_reset(&font)
	}

	font_atlas_add_white_rect(ctx, 2, 2)
	state_push(ctx)
	state_clear(ctx)
}

font_atlas_insert_node :: proc(using ctx: ^Font_Context, idx, x, y, w: int) {
	// resize is alright here
	resize(&nodes, len(nodes) + 1)

	// shift nodes up once to leave space at idx
	for i := len(nodes) - 1; i > idx; i -= 1 {
		nodes[i] = nodes[i - 1]
	}

	// set new inserted one to properties
	nodes[idx].x = i16(x)
	nodes[idx].y = i16(y)
	nodes[idx].width = i16(w)
}

font_atlas_remove_node :: proc(using ctx: ^Font_Context, idx: int) {
	if len(nodes) == 0 {
		return
	}

	// remove node at index, shift elements down
	for i in idx..<len(nodes) - 1 {
		nodes[i] = nodes[i + 1]
	}

	// reduce size of array
	raw := transmute(^mem.Raw_Dynamic_Array) &nodes
	raw.len -= 1
}

font_atlas_expand :: proc(using ctx: ^Font_Context, w, h: int) {
	if w > width {
		font_atlas_insert_node(ctx, len(nodes), width, 0, w - width)
	}

	width = w
	height = h
}

font_atlas_reset :: proc(using ctx: ^Font_Context, w, h: int) {
	width = w
	height = h
	clear(&nodes)

	// init root node
	append(&nodes, Atlas_Node {
		width = i16(w),
	})
}

font_atlas_add_skyline_level :: proc(using ctx: ^Font_Context, idx, x, y, w, h: int) {
	// insert new node
	font_atlas_insert_node(ctx, idx, x, y + h, w)

	// Delete skyline segments that fall under the shadow of the new segment.
	for i := idx + 1; i < len(nodes); i += 1 {
		if nodes[i].x < nodes[i - 1].x + nodes[i - 1].width {
			shrink := nodes[i-1].x + nodes[i-1].width - nodes[i].x
			nodes[i].x += i16(shrink)
			nodes[i].width -= i16(shrink)
			
			if nodes[i].width <= 0 {
				font_atlas_remove_node(ctx, i)
				i -= 1
			} else {
				break
			}
		} else {
			break
		}
	}

	// Merge same height skyline segments that are next to each other.
	for i := 0; i < len(nodes) - 1; i += 1 {
		if nodes[i].y == nodes[i + 1].y {
			nodes[i].width += nodes[i + 1].width
			font_atlas_remove_node(ctx, i + 1)
			i -= 1
		}
	}
}

font_atlas_rect_fits :: proc(using ctx: ^Font_Context, i, w, h: int) -> int {
	// Checks if there is enough space at the location of skyline span 'i',
	// and return the max height of all skyline spans under that at that location,
	// (think tetris block being dropped at that position). Or -1 if no space found.
	x := int(nodes[i].x)
	y := int(nodes[i].y)
	
	if x + w > width {
		return -1
	}

	i := i
	space_left := w
	for space_left > 0 {
		if i == len(nodes) {
			return -1
		}

		y = max(y, int(nodes[i].y))
		if y + h > height {
			return -1
		}

		space_left -= int(nodes[i].width)
		i += 1
	}

	return y
}

font_atlas_add_rect :: proc(using ctx: ^Font_Context, rw, rh: int) -> (rx, ry: int, ok: bool) {
	besth := height
	bestw := width
	besti, bestx, besty := -1, -1, -1

	// Bottom left fit heuristic.
	for i in 0..<len(nodes) {
		y := font_atlas_rect_fits(ctx, i, rw, rh)
		
		if y != -1 {
			if y + rh < besth || (y + rh == besth && int(nodes[i].width) < bestw) {
				besti = i
				bestw = int(nodes[i].width)
				besth = y + rh
				bestx = int(nodes[i].x)
				besty = y
			}
		}
	}

	if besti == -1 {
		return
	}

	// Perform the actual packing.
	font_atlas_add_skyline_level(ctx, besti, bestx, besty, rw, rh) 
	ok = true
	rx = bestx
	ry = besty
	return
}

font_atlas_add_white_rect :: proc(ctx: ^Font_Context, w, h: int) {
	gx, gy, ok := font_atlas_add_rect(ctx, w, h)

	if !ok {
		return
	}

	// Rasterize
	dst := ctx.texture_data[gx + gy * ctx.width:]
	for y in 0..<h {
		for x in 0..<w {
			dst[x] = 0xff
		}

		dst = dst[ctx.width:]
	}

	ctx.dirty_rect[0] = cast(f32) min(int(ctx.dirty_rect[0]), gx)
	ctx.dirty_rect[1] = cast(f32) min(int(ctx.dirty_rect[1]), gy)
	ctx.dirty_rect[2] = cast(f32) max(int(ctx.dirty_rect[2]), gx + w)
	ctx.dirty_rect[3] = cast(f32) max(int(ctx.dirty_rect[3]), gy + h)
}

font_push_file :: proc(
	ctx: ^Font_Context,
	path: string,
	init_default_ascii := false,
	pixel_size := f32(0),
) -> (res: ^Font) {
	spall.fscoped("font push %s", path)
	data, ok := os.read_entire_file(path)

	if !ok {
		log.panicf("FONT: failed to read font at %s", path)
	}

	res = font_push_slice(ctx, data, init_default_ascii, pixel_size)
	res.free_loaded_data = true
	return
}

// push a font to the font stack
// optionally init with ascii characters at a wanted size
font_push_slice :: proc(
	ctx: ^Font_Context,
	data: []u8, 
	init_default_ascii := false,
	pixel_size := f32(0),
) -> (res: ^Font) {
	spall.scoped("font slice read")

	append(&ctx.fonts, Font {})
	res = &ctx.fonts[len(ctx.fonts) - 1]
	res.loaded_data = data

	stbtt.InitFont(&res.info, &res.loaded_data[0], 0)
	ascent, descent, line_gap: i32
	stbtt.GetFontVMetrics(&res.info, &ascent, &descent, &line_gap)
	fh := f32(ascent - descent)
	res.ascender = f32(ascent) / fh
	res.descender = f32(descent) / fh
	res.line_height = (fh + f32(line_gap)) / fh
	res.glyphs = make([dynamic]Glyph, 0, INIT_GLYPHS)

	font_reset(res)

	if init_default_ascii {
		spall.scoped("font load ascii")
		isize := i16(pixel_size * 10)
		scale := scale_for_pixel_height(res, f32(isize / 10))

		for i in 0..<95 {
			get_glyph(ctx, res, rune(32 + i), isize)
		}
	}

	return res
}

font_push :: proc { font_push_file, font_push_slice }

font_reset :: proc(font: ^Font) {
	// set lookup table
	for i in 0..<LUT_SIZE {
		font.lut[i] = -1
	}
}

hash_value :: proc(a: u32) -> u32 {
	a := a
	a += ~(a << 15)
	a ~=  (a >> 10)
	a +=  (a << 3)
	a ~=  (a >> 6)
	a +=  (a << 11)
	a ~=  (a >> 16)
	return a
}

font_render_glyph_bitmap :: proc(
	font: ^Font,
	output: []u8,
	out_width: i32,
	out_height: i32,
	out_stride: i32,
	scale_x: f32,
	scale_y: f32,
	glyph_index: Glyph_Index,
) {
	stbtt.MakeGlyphBitmap(&font.info, raw_data(output), out_width, out_height, out_stride, scale_x, scale_y, glyph_index)
}

font_build_glyph_bitmap :: proc(
	font: ^Font, 
	glyph_index: Glyph_Index,
	pixel_size: f32,
	scale: f32,
) -> (advance, lsb, x0, y0, x1, y1: i32) {
	stbtt.GetGlyphHMetrics(&font.info, glyph_index, &advance, &lsb)
	stbtt.GetGlyphBitmapBox(&font.info, glyph_index, scale, scale, &x0, &y0, &x1, &y1)
	return
}

// get glyph and push to atlas if not exists
get_glyph :: proc(
	ctx: ^Font_Context,
	font: ^Font,
	codepoint: rune,
	isize: i16,
	blur_size: i16 = 0,
) -> (res: ^Glyph) #no_bounds_check {
	if isize < 2 {
		return
	}

	// find code point and size
	h := hash_value(u32(codepoint)) & (LUT_SIZE - 1)
	i := font.lut[h]
	for i != -1 {
		glyph := &font.glyphs[i]
		
		if 
			glyph.codepoint == codepoint && 
			glyph.isize == isize &&
			glyph.blur_size == blur_size 
		{
			res = glyph
			return
		}

		i = glyph.next
	}

	// could not find glyph, create it.
	glyph_index := get_glyph_index(font, codepoint)
	if glyph_index == 0 {
		// NOTE could store missed codepoints and message once
		// log.infof("FONTSTASH: glyph index not found for %v %v", codepoint, Icon(codepoint))
		// return
	}

	pixel_size := f32(isize) / 10
	blur_size := min(blur_size, 20)
	padding := i16(blur_size + 2) // 2 minimum padding
	scale := scale_for_pixel_height(font, pixel_size)
	advance, lsb, x0, y0, x1, y1 := font_build_glyph_bitmap(font, glyph_index, pixel_size, scale)
	gw := (x1 - x0) + i32(padding) * 2
	gh := (y1 - y0) + i32(padding) * 2 

	// Find free spot for the rect in the atlas
	gx, gy, ok := font_atlas_add_rect(ctx, int(gw), int(gh))
	if !ok {
		// try again with expanded
		expand_atlas(ctx, ctx.width * 2, ctx.height * 2)
		gx, gy, ok = font_atlas_add_rect(ctx, int(gw), int(gh))
	}

	// still not ok?
	if !ok {
		return
	}
	
	// Init glyph.
	append(&font.glyphs, Glyph {
		codepoint = codepoint,
		isize = isize,
		blur_size = blur_size,
		index = glyph_index,
		x0 = i16(gx),
		y0 = i16(gy),
		x1 = i16(i32(gx) + gw),
		y1 = i16(i32(gy) + gh),
		xadvance = i16(scale * f32(advance) * 10),
		xoff = i16(x0 - i32(padding)),
		yoff = i16(y0 - i32(padding)),

		// insert char to hash lookup.
		next = font.lut[h],
	})
	font.lut[h] = len(font.glyphs) - 1
	res = &font.glyphs[len(font.glyphs) - 1]

	// rasterize
	dst := ctx.texture_data[int(res.x0 + padding) + int(res.y0 + padding) * ctx.width:]
	font_render_glyph_bitmap(
		font,
		dst,
		gw - i32(padding) * 2, 
		gh - i32(padding) * 2, 
		i32(ctx.width), 
		scale,
		scale,
		glyph_index,
	)

	// make sure there is one pixel empty border.
	dst = ctx.texture_data[int(res.x0) + int(res.y0) * ctx.width:]
	// y direction
	for y in 0..<int(gh) {
		dst[y * ctx.width] = 0
		dst[int(gw - 1) + y * ctx.width] = 0
	}
	// x direction
	for x in 0..<int(gw) {
		dst[x] = 0
		dst[x + int(gh - 1) * ctx.width] = 0
	}

	if blur_size > 0 {
		font_blur(dst, int(gw), int(gh), ctx.width, blur_size)
	}

	ctx.dirty_rect[0] = cast(f32) min(int(ctx.dirty_rect[0]), int(res.x0))
	ctx.dirty_rect[1] = cast(f32) min(int(ctx.dirty_rect[1]), int(res.y0))
	ctx.dirty_rect[2] = cast(f32) max(int(ctx.dirty_rect[2]), int(res.x1))
	ctx.dirty_rect[3] = cast(f32) max(int(ctx.dirty_rect[3]), int(res.y1))

	// pushed = true
	return
}

/////////////////////////////////
// blur
/////////////////////////////////

// Based on Exponential blur, Jani Huhtanen, 2006

BLUR_APREC :: 16
BLUR_ZPREC :: 7

font_blur_cols :: proc(dst: []u8, w, h, dst_stride, alpha: int) {
	dst := dst

	for y in 0..<h {
		z := 0 // force zero border

		for x in 1..<w {
			z += (alpha * ((int(dst[x]) << BLUR_ZPREC) - z)) >> BLUR_APREC
			dst[x] = u8(z >> BLUR_ZPREC)
		}

		dst[w - 1] = 0 // force zero border
		z = 0

		for x := w - 2; x >= 0; x -= 1 {
			z += (alpha * ((int(dst[x]) << BLUR_ZPREC) - z)) >> BLUR_APREC
			dst[x] = u8(z >> BLUR_ZPREC)
		}

		dst[0] = 0 // force zero border
		dst = dst[dst_stride:] // advance slice
	}
}

font_blur_rows :: proc(dst: []u8, w, h, dst_stride, alpha: int) {
	dst := dst

	for x in 0..<w {
		z := 0 // force zero border
		for y := dst_stride; y < h * dst_stride; y += dst_stride {
			z += (alpha * ((int(dst[y]) << BLUR_ZPREC) - z)) >> BLUR_APREC
			dst[y] = u8(z >> BLUR_ZPREC)
		}

		dst[(h - 1) * dst_stride] = 0 // force zero border
		z = 0

		for y := (h - 2) * dst_stride; y >= 0; y -= dst_stride {
			z += (alpha * ((int(dst[y]) << BLUR_ZPREC) - z)) >> BLUR_APREC
			dst[y] = u8(z >> BLUR_ZPREC)
		}

		dst[0] = 0 // force zero border
		dst = dst[1:] // advance
	}
}

font_blur :: proc(dst: []u8, w, h, dst_stride: int, blur_size: i16) {
	assert(blur_size != 0)

	// Calculate the alpha such that 90% of the kernel is within the radius. (Kernel extends to infinity)
	sigma := f32(blur_size) * 0.57735 // 1 / sqrt(3)
	alpha := int((1 << BLUR_APREC) * (1 - math.exp(-2.3 / (sigma + 1))))
	font_blur_rows(dst, w, h, dst_stride, alpha)
	font_blur_cols(dst, w, h, dst_stride, alpha)
	font_blur_rows(dst, w, h, dst_stride, alpha)
	font_blur_cols(dst, w, h, dst_stride, alpha)
}

/////////////////////////////////
// Texture expansion
/////////////////////////////////

expand_atlas :: proc(ctx: ^Font_Context, width, height: int, allocator := context.allocator) -> bool {
	width := max(ctx.width, width)
	height := max(ctx.height, height)

	if width == ctx.width && height == ctx.height {
		return true
	}

	if ctx.callback_resize != nil {
		ctx.callback_resize(ctx.user_data, width, height)
	}

	data := make([]byte, width * height, allocator)

	for i in 0..<ctx.height {
		dst := &data[i * width]
		src := &ctx.texture_data[i * ctx.width]
		mem.copy(dst, src, ctx.width)

		if width > ctx.width {
			mem.set(&data[i * width + ctx.width], 0, width - ctx.width)
		}
	}

	if height > ctx.height {
		mem.set(&data[ctx.height * width], 0, (height - ctx.height) * width)
	}

	delete(ctx.texture_data)
	ctx.texture_data = data

	// increase atlas size
	font_atlas_expand(ctx, width, height)

	// add existing data as dirty
	maxy := i16(0)
	for node in ctx.nodes {
		maxy = max(maxy, node.y)
	}
	ctx.dirty_rect[0] = 0
	ctx.dirty_rect[1] = 0
	ctx.dirty_rect[2] = f32(ctx.width)
	ctx.dirty_rect[3] = f32(maxy)

	ctx.width = width
	ctx.height = height
	ctx.itw = 1.0 / f32(width)
	ctx.ith = 1.0 / f32(height)

	return true
}

reset_atlas :: proc(ctx: ^Font_Context, width, height: int, allocator := context.allocator) -> bool {
	if width == ctx.width && height == ctx.height {
		// just clear
		mem.zero_slice(ctx.texture_data)
	} else {
		// realloc
		ctx.texture_data = make([]byte, width * height, allocator)
	}

	ctx.dirty_rect[0] = f32(width)
	ctx.dirty_rect[1] = f32(height)
	ctx.dirty_rect[2] = 0
	ctx.dirty_rect[3] = 0

	// reset fonts
	for font in &ctx.fonts {
		clear(&font.glyphs)

		for i in 0..<LUT_SIZE {
			font.lut[i] = -1
		}
	}

	ctx.width = width
	ctx.height = height
	ctx.itw = 1.0 / f32(width)
	ctx.ith = 1.0 / f32(height)

	font_atlas_add_white_rect(ctx, 2, 2)
	return true
}

get_glyph_index :: proc(font: ^Font, codepoint: rune) -> Glyph_Index {
	return stbtt.FindGlyphIndex(&font.info, codepoint)
}

scale_for_pixel_height :: proc(font: ^Font, pixel_height: f32) -> f32 {
	return stbtt.ScaleForPixelHeight(&font.info, pixel_height)
}

// codepoint xadvance polling
codepoint_xadvance :: proc(font: ^Font, codepoint: rune, scale: f32) -> f32 {
	glyph_index := get_glyph_index(font, codepoint)
	return math.round(glyph_xadvance(font, glyph_index) * scale)
}

// glyph based xadvance polling
glyph_xadvance :: proc(font: ^Font, glyph_index: Glyph_Index) -> f32 {
	xadvance, lsb: i32
	stbtt.GetGlyphHMetrics(&font.info, glyph_index, &xadvance, &lsb)
	return f32(xadvance)
}

glyph_kern_advance :: proc(font: ^Font, glyph1, glyph2: Glyph_Index) -> i32 {
	return stbtt.GetGlyphKernAdvance(&font.info, glyph1, glyph2)
}

// get a font with bounds checking
font_get :: proc(ctx: ^Font_Context, index: int, loc := #caller_location) -> ^Font #no_bounds_check {
	runtime.bounds_check_error_loc(loc, index, len(ctx.fonts))
	return &ctx.fonts[index]
}

// only useful for single glyphs where you quickly want the width
codepoint_width :: proc(
	font: ^Font,
	codepoint: rune,
	scale: f32,
) -> f32 {
	glyph_index := get_glyph_index(font, codepoint)
	xadvance, lsb: i32
	stbtt.GetGlyphHMetrics(&font.info, glyph_index, &xadvance, &lsb)
	return f32(xadvance) * scale
}

// get top and bottom line boundary
line_bounds :: proc(ctx: ^Font_Context, y: f32) -> (miny, maxy: f32) {
	state := state_get(ctx)
	font := font_get(ctx, state.font)
	isize := i16(state.size * 10)
	y := y
	y += get_vertical_align(font, isize, state.av)
	miny = y - font.ascender * f32(isize / 10)
	maxy = miny + font.line_height * f32(isize / 10)
	return
}

// reset dirty rect
dirty_rect_reset :: proc(using ctx: ^Font_Context) {
	dirty_rect[0] = f32(width)
	dirty_rect[1] = f32(height)
	dirty_rect[2] = 0
	dirty_rect[3] = 0
}

// true when the dirty rectangle is valid and needs a texture update on the gpu
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

// get alignment based on font
get_vertical_align :: proc(
	font: ^Font,
	pixel_size: i16,
	av: Align_Vertical,
) -> (res: f32) {
	switch av {
		case .Top: {
			res = (font.ascender) * f32(pixel_size / 10)
		}

		case .Middle: {
			res = (font.ascender + font.descender) / 2 * f32(pixel_size / 10)
		}

		case .Baseline: {
			res = 0
		}

		case .Bottom: {
			res = (font.descender) * f32(pixel_size / 10)
		}
	}

	// res = math.round(res)
	return
}

valign :: proc(ctx: ^Font_Context) -> f32 {
	state := state_get(ctx)
	font := font_get(ctx, state.font)
	isize := i16(state.size * 10)
	return math.round(get_vertical_align(font, isize, state.av))
}

//////////////////////////////////////////////
// line wrapping helpers
//////////////////////////////////////////////

// wrap a string to a width limit where the result are the strings seperated to the width limit
wrap_format_to_lines :: proc(
	ctx: ^Font_Context,
	text: string,
	width_limit: f32,
	lines: ^[dynamic]string,
) {
	// clear(lines)
	iter := text_iter_init(ctx, text, 0, 0)
	q: Quad
	last_byte_offset: int

	index_last: int
	index_line_start: int
	index_word_start: int = -1

	// widths
	width_codepoint: f32
	width_word: f32
	width_line: f32

	for text_iter_step(ctx, &iter, &q) {
		width_codepoint = iter.nextx - iter.x

		// set first valid index
		if index_word_start == -1 {
			index_word_start = last_byte_offset
		}

		// set the word index, reset width
		if index_word_start != -1 && iter.codepoint == ' ' {
			index_word_start = -1
			width_word = 0
		}

		// add widths
		width_line += width_codepoint
		width_word += width_codepoint
		
		if width_line > width_limit {
			if !unicode.is_space(iter.codepoint) {
				// when full word is longer than limit, just seperate like whitespace
				if width_word > width_limit {
					append(lines, text[index_line_start:iter.byte_offset])
					index_line_start = iter.byte_offset
					width_line = 0
				} else {
					append(lines, text[index_line_start:index_word_start])
					index_line_start = index_word_start
					width_line = width_word
				}
			} else {
				append(lines, text[index_line_start:iter.byte_offset])
				index_line_start = iter.byte_offset
				width_line = width_word
			}
		}

		index_last = last_byte_offset
		last_byte_offset = iter.byte_offset
	}

	if width_line <= width_limit {
		append(lines, text[index_line_start:])
	}
}

// getting the right index into the now cut lines of strings
wrap_codepoint_index_to_line :: proc(
	lines: []string, 
	codepoint_index: int, 
	loc := #caller_location,
) -> (
	y: int, 
	line_byte_offset: int,
	line_codepoint_index: int,
) {
	assert(len(lines) > 0, "Lines should have valid content of lines > 0", loc)

	if codepoint_index == 0 || len(lines) <= 1 {
		return
	}

	// need to care about utf8 sized codepoints
	total_byte_offset: int
	last_byte_offset: int
	total_codepoint_count: int
	last_codepoint_count: int

	for line, i in lines {
		codepoint_count := cutf8.count(line)

		if codepoint_index < total_codepoint_count + codepoint_count {
			y = i
			line_byte_offset = total_byte_offset
			line_codepoint_index = total_codepoint_count
			return
		}

		last_codepoint_count = total_codepoint_count
		total_codepoint_count += codepoint_count
		last_byte_offset = total_byte_offset
		total_byte_offset += len(line)
	}

	// last line
	line_byte_offset = last_byte_offset
	line_codepoint_index = last_codepoint_count
	y = len(lines) - 1

	return
}

// returns the logical position of a caret without offsetting
// can be used on single lines of text or wrapped lines of text
wrap_layout_caret :: proc(
	ctx: ^Font_Context,
	wrapped_lines: []string, // using the resultant lines
	codepoint_index: int, // in codepoint_index, not byte_offset
	loc := #caller_location,
) -> (x_offset: int, line: int) {
	assert(len(wrapped_lines) > 0, "Lines should have valid content of lines > 0", loc)

	// get wanted line and byte index offset
	y, byte_offset, codepoint_offset := wrap_codepoint_index_to_line(
		wrapped_lines, 
		codepoint_index,
	)
	line = y

	q: Quad
	text := wrapped_lines[line]
	goal := codepoint_index - codepoint_offset
	iter := text_iter_init(ctx, text)

	// still till the goal position is reached and use x position
	for text_iter_step(ctx, &iter, &q) {
		if iter.codepoint_count >= goal {
			break
		}
	}

	// anything hitting the count
	if goal == iter.codepoint_count {
		x_offset = int(iter.nextx)
	} else {
		// get the first index
		x_offset = int(iter.x)
	}

	return
}

// line wrapping iteration when you want to do things like selection highlighting
// which could span across multiple lines
Wrap_State :: struct {
	// font options
	font: ^Font,
	isize: i16,
	iblur: i16,
	scale: f32,
	spacing: f32,

	// formatted lines
	lines: []string,

	// wanted from / to
	codepoint_offset: int,
	codepoint_index_low: int,
	codepoint_index_high: int,

	// output used
	x_from: f32,
	x_to: f32,
	y: int, // always +1 in lines
}

wrap_state_init :: proc(
	ctx: ^Font_Context,
	lines: []string, 
	codepoint_index_from: int,
	codepoint_index_to: int,
) -> (res: Wrap_State) {
	state := state_get(ctx)
	res.font = font_get(ctx, state.font)
	res.isize = i16(state.size * 10)
	res.iblur = i16(state.blur)
	res.scale = scale_for_pixel_height(res.font, f32(res.isize / 10))
	res.lines = lines
	res.spacing = state.spacing

	// do min / max here for safety instead of reyling on the user
	res.codepoint_index_low = min(codepoint_index_from, codepoint_index_to)
	res.codepoint_index_high = max(codepoint_index_from, codepoint_index_to)
	
	return
}

wrap_state_iter :: proc(
	ctx: ^Font_Context,
	w: ^Wrap_State,
) -> bool {
	w.x_from = -1
	q: Quad

	// NOTE could be optimized to only search the wanted lines
	// would need to count the glyphs anyway though hmm

	for w.x_from == -1 && w.y < len(w.lines) {
		line := w.lines[w.y]
		ds: cutf8.Decode_State
		previous_glyph_index: Glyph_Index = -1
		temp_x: f32
		temp_y: f32

		// step through each line to find selection area
		for codepoint, codepoint_index in cutf8.ds_iter(&ds, line) {
			glyph := get_glyph(ctx, w.font, codepoint, w.isize, w.iblur)
			index := w.codepoint_offset + codepoint_index

			if w.codepoint_index_low <= index && index <= w.codepoint_index_high {
				w.x_to = temp_x

				if w.x_from == -1 {
					w.x_from = w.x_to
				}
			}

			if glyph != nil {
				get_quad(ctx, w.font, previous_glyph_index, glyph, w.scale, w.spacing, &temp_x, &temp_y, &q)
			}

			previous_glyph_index = glyph == nil ? -1 : glyph.index
		}

		w.y += 1
		w.codepoint_offset += ds.codepoint_count

		// include last glyph
		if w.codepoint_offset == w.codepoint_index_high {
			w.x_to = temp_x
		}
	}

	return w.x_from != -1
}