package fontstash

import "core:log"
import "core:os"
import "core:mem"
import "core:math"
import "core:unicode"
import stbtt "vendor:stb/truetype"
import "../cutf8"

Icon :: enum {
	Simple_Down = 0xeab2,
	Simple_Right = 0xeab8,
	Simple_Left = 0xeab5,
		
	Clock = 0xec3f,
	Close = 0xec4f,
	Check = 0xec4b,

	Search = 0xed1b,
	Search_Document = 0xed13,
	Search_Map = 0xed16,

	List = 0xef76,
	UI_Calendar = 0xec45,
	Stopwatch = 0xedcd,

	Exclamation_Mark_Rounded = 0xef19,
	Trash = 0xee09,

	Bookmark = 0xeec0,
	Tomato = 0xeb9a,
	Clock_Time = 0xeedc,
	Tag = 0xf004,

	Caret_Right = 0xeac4,
	Home = 0xef47,

	Simple_Up = 0xeab9,

	Arrow_Up = 0xea5e,
	Arrow_Down = 0xea5b,

	Locked = 0xef7a,
	Unlocked = 0xf01b,

	Cog = 0xefb0,
	Sort = 0xefee,
	Reply = 0xec7f,
}

LUT_SIZE :: 256
INIT_GLYPHS :: 256
ATLAS_NODES :: 256
// GLYPH_TYPE :: u16
Glyph_Index_Type :: i32

Align_Horizontal :: enum {
	Left,
	Middle,
	Right,
}

Align_Vertical :: enum {
	Top,
	Middle,
	Bottom,
}

Font :: struct {
	info: stbtt.fontinfo,
	loaded_data: []byte,

	ascent: i32,
	descent: i32,
	line_height: i32,

	glyphs: [dynamic]Glyph,
	lut: [LUT_SIZE]int,
}

Glyph :: struct #packed {
	codepoint: rune,
	glyph_index: Glyph_Index_Type,
	next: int,
	pixel_size: f32,
	x0, y0, x1, y1: i16,
	xoff, yoff: i16,
	xadvance: f32,
}

Atlas_Node :: struct {
	x, y, width: i16,
}

Font_Atlas :: struct {
	width, height: int,

	// always assuming user wants to resize
	nodes: [dynamic]Atlas_Node,

	// actual pixels
	texture_data: []byte,

	// 1 / w, 1 / h
	itw, ith: f32,
}
fa: Font_Atlas

init :: proc(w, h: int) {
	fa.itw = f32(1) / f32(w)
	fa.ith = f32(1) / f32(h)
	fa.texture_data = make([]byte, w * h)

	font_atlas_init(&fa, w, h, ATLAS_NODES)
}

destroy :: proc() {
	font_atlas_destroy(fa)
	delete(fa.texture_data)
}

@(private)
font_atlas_init :: proc(atlas: ^Font_Atlas, w, h, nodes: int) {
	atlas.width = w
	atlas.height = h
	atlas.nodes = make([dynamic]Atlas_Node, 0, nodes)

	append(&atlas.nodes, Atlas_Node {
		width = i16(w),
	})
}

@(private)
font_atlas_destroy :: proc(atlas: Font_Atlas) {
	delete(atlas.nodes)
}

@(private)
font_atlas_insert_node :: proc(atlas: ^Font_Atlas, idx, x, y, w: int) {
	// resize is alright here
	resize(&atlas.nodes, len(atlas.nodes) + 1)

	// shift nodes up once to leave space at idx
	for i := len(atlas.nodes) - 1; i > idx; i -= 1 {
		atlas.nodes[i] = atlas.nodes[i - 1]
	}

	// set new inserted one to properties
	atlas.nodes[idx].x = i16(x)
	atlas.nodes[idx].y = i16(y)
	atlas.nodes[idx].width = i16(w)
}

@(private)
font_atlas_remove_node :: proc(atlas: ^Font_Atlas, idx: int) {
	if len(atlas.nodes) == 0 {
		return
	}

	// remove node at index, shift elements down
	for i in idx..<len(atlas.nodes) - 1 {
		atlas.nodes[i] = atlas.nodes[i + 1]
	}

	// reduce size of array
	raw := transmute(^mem.Raw_Dynamic_Array) &atlas.nodes
	raw.len -= 1
}

// TODO look into resizing atlas when exceeded
// @(private)
// font_atlas_expand :: proc(atlas: ^Font_Atlas, w, h: int) {
// 	if w > atlas.width {
// 		// TODO could just be append
// 		font_atlas_insert_node(atlas, len(atlas.nodes), atlas.width, 0, w - atlas.width)
// 	}

// 	atlas.width = w
// 	atlas.height = h
// }

@(private)
font_atlas_reset :: proc(atlas: ^Font_Atlas, w, h: int) {
	atlas.width = w
	atlas.height = h
	clear(&atlas.nodes)

	// init root node
	append(&atlas.nodes, Atlas_Node {
		width = i16(w),
	})
}

@(private)
font_atlas_add_skyline_level :: proc(atlas: ^Font_Atlas, idx, x, y, w, h: int) {
	// insert new node
	font_atlas_insert_node(atlas, idx, x, y + h, w)

	// Delete skyline segments that fall under the shadow of the new segment.
	for i := idx + 1; i < len(atlas.nodes); i += 1 {
		if atlas.nodes[i].x < atlas.nodes[i - 1].x + atlas.nodes[i - 1].width {
			shrink := atlas.nodes[i-1].x + atlas.nodes[i-1].width - atlas.nodes[i].x
			atlas.nodes[i].x += i16(shrink)
			atlas.nodes[i].width -= i16(shrink)
			
			if atlas.nodes[i].width <= 0 {
				font_atlas_remove_node(atlas, i)
				i -= 1
			} else {
				break
			}
		} else {
			break
		}
	}

	// Merge same height skyline segments that are next to each other.
	for i := 0; i < len(atlas.nodes) - 1; i += 1 {
		if atlas.nodes[i].y == atlas.nodes[i + 1].y {
			atlas.nodes[i].width += atlas.nodes[i + 1].width
			font_atlas_remove_node(atlas, i + 1)
			i -= 1
		}
	}
}

@(private)
font_atlas_rect_fits :: proc(atlas: ^Font_Atlas, i, w, h: int) -> int {
	// Checks if there is enough space at the location of skyline span 'i',
	// and return the max height of all skyline spans under that at that location,
	// (think tetris block being dropped at that position). Or -1 if no space found.
	x := int(atlas.nodes[i].x)
	y := int(atlas.nodes[i].y)
	
	if x + w > atlas.width {
		return -1
	}

	i := i
	space_left := w
	for space_left > 0 {
		if i == len(atlas.nodes) {
			return -1
		}

		y = max(y, int(atlas.nodes[i].y))
		if y + h > atlas.height {
			return -1
		}

		space_left -= int(atlas.nodes[i].width)
		i += 1
	}

	return y
}

@(private)
font_atlas_add_rect :: proc(atlas: ^Font_Atlas, rw, rh: int) -> (rx, ry: int, ok: bool) {
	besth := atlas.height
	bestw := atlas.width
	besti, bestx, besty := -1, -1, -1

	// Bottom left fit heuristic.
	for i in 0..<len(atlas.nodes) {
		y := font_atlas_rect_fits(atlas, i, rw, rh)
		
		if y != -1 {
			if y + rh < besth || (y + rh == besth && int(atlas.nodes[i].width) < bestw) {
				besti = i
				bestw = int(atlas.nodes[i].width)
				besth = y + rh
				bestx = int(atlas.nodes[i].x)
				besty = y
			}
		}
	}

	if besti == -1 {
		return
	}

	// Perform the actual packing.
	font_atlas_add_skyline_level(atlas, besti, bestx, besty, rw, rh) 
	ok = true
	rx = bestx
	ry = besty
	return
}

@(private)
font_atlas_add_white_rect :: proc(atlas: ^Font_Atlas, w, h: int) {
	gx, gy, ok := font_atlas_add_rect(atlas, w, h)

	if !ok {
		return
	}

	// Rasterize
	dst := atlas.texture_data[gx + gy * atlas.width:]
	for y in 0..<h {
		for x in 0..<w {
			dst[x] = 0xff
		}

		dst = dst[atlas.width:]
	}
}

font_init :: proc(
	path: string, 
	init_default_ascii := false,
	pixel_size := f32(0),
) -> (res: ^Font) {
	ok: bool
	res = new(Font)
	res.loaded_data, ok = os.read_entire_file(path)

	if !ok {
		log.panicf("FONT: failed to read font at %s", path)
	}

	stbtt.InitFont(&res.info, &res.loaded_data[0], 0)
	stbtt.GetFontVMetrics(&res.info, &res.ascent, &res.descent, &res.line_height)
	res.glyphs = make([dynamic]Glyph, 0, INIT_GLYPHS)

	for i in 0..<LUT_SIZE {
		res.lut[i] = -1
	}

	if init_default_ascii {
		font_init_ascii(res, pixel_size)
	}

	return
}

@(private)
font_init_ascii :: proc(font: ^Font, pixel_size: f32) {
	scale := scale_for_pixel_height(font, pixel_size)

	// init default ascii codepoints 
	for i in 0..<95 {
		get_glyph(font, pixel_size, scale, rune(32 + i))
	}
}

font_destroy :: proc(font: ^Font) {
	delete(font.loaded_data)
	delete(font.glyphs)
	free(font)
}

@(private)
font_hash :: proc(a: u32) -> u32 {
	a := a
	a += ~(a << 15)
	a ~=  (a >> 10)
	a +=  (a << 3)
	a ~=  (a >> 6)
	a +=  (a << 11)
	a ~=  (a >> 16)
	return a
}

@(private)
font_render_glyph_bitmap :: proc(
	font: ^Font,
	output: []u8,
	out_width: i32,
	out_height: i32,
	out_stride: i32,
	scale_x: f32,
	scale_y: f32,
	glyph_index: Glyph_Index_Type,
) {
	stbtt.MakeGlyphBitmap(&font.info, raw_data(output), out_width, out_height, out_stride, scale_x, scale_y, glyph_index)
}

@(private)
font_build_glyph_bitmap :: proc(
	font: ^Font, 
	glyph_index: Glyph_Index_Type,
	pixel_size: f32,
	scale: f32,
) -> (advance, lsb, x0, y0, x1, y1: i32) {
	stbtt.GetGlyphHMetrics(&font.info, glyph_index, &advance, &lsb)
	stbtt.GetGlyphBitmapBox(&font.info, glyph_index, scale, scale, &x0, &y0, &x1, &y1)
	return
}

// get glyph and push to atlas if not exists
get_glyph :: proc(
	font: ^Font,
	pixel_size: f32,
	scale: f32,
	codepoint: rune,
) -> (res: ^Glyph, pushed: bool) #optional_ok {
	// find code point and size
	h := font_hash(u32(codepoint)) & (LUT_SIZE - 1)
	i := font.lut[h]
	for i != -1 {
		glyph := &font.glyphs[i]
		
		if 
			glyph.codepoint == codepoint && 
			glyph.pixel_size == pixel_size 
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

	padding := i16(2) // 2 minimum padding
	advance, lsb, x0, y0, x1, y1 := font_build_glyph_bitmap(font, glyph_index, f32(pixel_size), scale)
	gw := (x1 - x0) + i32(padding) * 2
	gh := (y1 - y0) + i32(padding) * 2 

	// Find free spot for the rect in the atlas
	gx, gy, ok := font_atlas_add_rect(&fa, int(gw), int(gh))
	if !ok {
		// TODO resize automaticalaly
		log.info("FONTSTASH: no free spot in atlas", gx, gy)
	}
	
	// Init glyph.
	append(&font.glyphs, Glyph {
		codepoint = codepoint,
		pixel_size = pixel_size,
		glyph_index = glyph_index,
		x0 = i16(gx),
		y0 = i16(gy),
		x1 = i16(i32(gx) + gw),
		y1 = i16(i32(gy) + gh),
		xadvance = math.round(scale * f32(advance)),
		xoff = i16(x0 - i32(padding)),
		yoff = i16(y0 - i32(padding)),

		// insert char to hash lookup.
		next = font.lut[h],
	})
	font.lut[h] = len(font.glyphs) - 1
	res = &font.glyphs[len(font.glyphs) - 1]

	// rasterize
	dst := fa.texture_data[int(res.x0 + padding) + int(res.y0 + padding) * fa.width:]
	font_render_glyph_bitmap(
		font,
		dst,
		gw - i32(padding) * 2, 
		gh - i32(padding) * 2, 
		i32(fa.width), 
		scale,
		scale,
		glyph_index,
	)

	// make sure there is one pixel empty border.
	dst = fa.texture_data[int(res.x0) + int(res.y0) * fa.width:]
	// y direction
	for y in 0..<int(gh) {
		dst[y * fa.width] = 0
		dst[int(gw - 1) + y * fa.width] = 0
	}
	// x direction
	for x in 0..<int(gw) {
		dst[x] = 0
		dst[x + int(gh - 1) * fa.width] = 0
	}

	pushed = true
	return
}

// Based on Exponential blur, Jani Huhtanen, 2006

BLUR_APREC :: 16
BLUR_ZPREC :: 7

@(private)
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

@(private)
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

@(private)
font_blur :: proc(dst: []u8, w, h, dst_stride: int, blur_size: u8) {
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
// USER LEVEL CODE
/////////////////////////////////

ascent_scaled :: #force_inline proc(font: ^Font, scale: f32) -> f32 {
	return f32(font.ascent) * scale
}

ascent_pixel_size :: proc(font: ^Font, pixel_size: f32) -> f32 {
	scale := stbtt.ScaleForPixelHeight(&font.info, pixel_size)
	return f32(font.ascent) * scale
}

// font_codepoint_kern_advance :: proc(font: ^Font, a, b: rune) -> f32 {
// 	kerning: ft.Vector
// 	// ft.Get_Kerning(font.face, a, b, ft.KERNING_DEFAULT, &kerning)
// 	// return f32((kerning.x + 32) >> 6)  // Round up and convert to integer
// 	return {}
// }

get_glyph_index :: #force_inline proc(font: ^Font, codepoint: rune) -> Glyph_Index_Type {
	return stbtt.FindGlyphIndex(&font.info, codepoint)
}

scale_for_pixel_height :: #force_inline proc(font: ^Font, pixel_height: f32) -> f32 {
	return stbtt.ScaleForPixelHeight(&font.info, pixel_height)
}

// codepoint xadvance polling
codepoint_xadvance :: proc(font: ^Font, codepoint: rune, scale: f32) -> f32 {
	glyph_index := get_glyph_index(font, codepoint)
	return math.round(glyph_xadvance(font, glyph_index) * scale)
}

// glyph based xadvance polling
glyph_xadvance :: proc(font: ^Font, glyph_index: Glyph_Index_Type) -> f32 {
	xadvance, lsb: i32
	stbtt.GetGlyphHMetrics(&font.info, glyph_index, &xadvance, &lsb)
	return f32(xadvance)
}

string_width :: proc(font: ^Font, pixel_size: f32, text: string) -> (offset: f32) {
	scale := scale_for_pixel_height(font, pixel_size)
	xadvance, lsb: i32

	state, codepoint: rune
	for i in 0..<len(text) {
		if cutf8.decode(&state, &codepoint, text[i]) {
			glyph_index := get_glyph_index(font, codepoint)
			stbtt.GetGlyphHMetrics(&font.info, glyph_index, &xadvance, &lsb)
			offset += math.round(f32(xadvance) * scale)
		}
	}

	return
}

runes_width :: proc(font: ^Font, pixel_size: f32, runes: []rune) -> (offset: f32) {
	scale := scale_for_pixel_height(font, pixel_size)
	xadvance, lsb: i32

	for codepoint in runes {
		glyph_index := get_glyph_index(font, codepoint)
		stbtt.GetGlyphHMetrics(&font.info, glyph_index, &xadvance, &lsb)
		offset += math.round(f32(xadvance) * scale)
	}

	return
}

icon_width :: proc(font: ^Font, pixel_size: f32, icon: Icon) -> f32 {
	scale := scale_for_pixel_height(font, pixel_size)
	glyph_index := get_glyph_index(font, rune(icon))
	xadvance, lsb: i32
	stbtt.GetGlyphHMetrics(&font.info, glyph_index, &xadvance, &lsb)
	return math.round(f32(xadvance) * scale)
}

// wrap a string to a width limit where the result are the strings seperated to the visual limit
format_to_lines :: proc(
	font: ^Font, 
	pixel_size: f32,
	text: string,
	width_limit: f32,
	lines: ^[dynamic]string,
) {
	clear(lines)
	scale := scale_for_pixel_height(font, f32(pixel_size))
	
	// normal data
	index_last: int
	index_line_start: int
	codepoint_count: int
	width_codepoint: f32

	// word data
	index_word_start: int = -1
	width_word: f32
	width_line: f32
	ds: cutf8.Decode_State

	for codepoint, i in cutf8.ds_iter(&ds, text) {
		width_codepoint = codepoint_xadvance(font, codepoint, scale)

		// set first valid index
		if index_word_start == -1 {
			index_word_start = i
		}

		// set the word index, reset width
		if index_word_start != -1 && codepoint == ' ' {
			index_word_start = -1
			width_word = 0
		}

		// add widths
		width_line += width_codepoint
		width_word += width_codepoint
		
		if width_line > width_limit {
			if unicode.is_letter(codepoint) {
				append(lines, text[index_line_start:index_word_start])
				index_line_start = index_word_start
				width_line = width_word
			} else if codepoint == ' ' {
				append(lines, text[index_line_start:codepoint_count])
				index_line_start = codepoint_count
				width_line = width_word
			}
		}

		index_last = i
		codepoint_count += 1
	}

	// get rest in
	if width_line <= width_limit {
		append(lines, text[index_line_start:])
	}

	// log.info(len(lines), width_line, width_word, index_line_start)
}

codepoint_index_to_line :: proc(lines: []string, head: int, loc := #caller_location) -> (y: int, index: int) {
	total_size: int

	assert(len(lines) != 0, "", loc)
	if head == 0 || len(lines) == 1 {
		return
	}
	
	for line, i in lines {
		codepoint_count := cutf8.count(line)

		if head <= total_size + codepoint_count {
			y = i
			index = total_size
			return
		}

		total_size += codepoint_count
	}

	y = -1
	return
}
