package src

import "core:unicode"
import "core:fmt"
import "vendor:fontstash"
import "../cutf8"

//////////////////////////////////////////////
// line wrapping helpers
//////////////////////////////////////////////

// wrap a string to a width limit where the result are the strings seperated to the width limit
wrap_format_to_lines :: proc(
	ctx: ^fontstash.FontContext,
	text: string,
	width_limit: f32,
	lines: ^[dynamic]string,
) {
	// clear(lines)
	iter := fontstash.TextIterInit(ctx, 0, 0, text)
	q: fontstash.Quad
	last_byte_offset: int

	index_last: int
	index_line_start: int
	index_word_start: int = -1

	// widths
	width_codepoint: f32
	width_word: f32
	width_line: f32

	for fontstash.TextIterNext(ctx, &iter, &q) {
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
					append(lines, text[index_line_start:iter.str])
					index_line_start = iter.str
					width_line = 0
				} else {
					append(lines, text[index_line_start:index_word_start])
					index_line_start = index_word_start
					width_line = width_word
				}
			} else {
				append(lines, text[index_line_start:iter.str])
				index_line_start = iter.str
				width_line = width_word
			}
		}

		index_last = last_byte_offset
		last_byte_offset = iter.str
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
	ctx: ^fontstash.FontContext,
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

	q: fontstash.Quad
	text := wrapped_lines[line]
	goal := codepoint_index - codepoint_offset
	iter := fontstash.TextIterInit(ctx, 0, 0, text)

	// still till the goal position is reached and use x position
	for fontstash.TextIterNext(ctx, &iter, &q) {
		if iter.codepointCount >= goal {
			break
		}
	}

	// anything hitting the count
	if goal == iter.codepointCount {
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
	ctx: ^fontstash.FontContext,
	lines: []string, 
	codepoint_index_from: int,
	codepoint_index_to: int,
) -> (res: Wrap_State) {
	state := fontstash.__getState(ctx)
	res.font = fontstash.__getFont(ctx, state.font)
	res.isize = i16(state.size * 10)
	res.iblur = i16(state.blur)
	res.scale = fontstash.__getPixelHeightScale(res.font, f32(res.isize / 10))
	res.lines = lines
	res.spacing = state.spacing

	// do min / max here for safety instead of reyling on the user
	res.codepoint_index_low = min(codepoint_index_from, codepoint_index_to)
	res.codepoint_index_high = max(codepoint_index_from, codepoint_index_to)
	
	return
}

wrap_state_iter :: proc(
	ctx: ^fontstash.FontContext,
	w: ^Wrap_State,
) -> bool {
	w.x_from = -1
	q: fontstash.Quad

	// NOTE could be optimized to only search the wanted lines
	// would need to count the glyphs anyway though hmm

	for w.x_from == -1 && w.y < len(w.lines) {
		line := w.lines[w.y]
		ds: cutf8.Decode_State
		previous_glyph_index: fontstash.Glyph_Index = -1
		temp_x: f32
		temp_y: f32

		// step through each line to find selection area
		for codepoint, codepoint_index in cutf8.ds_iter(&ds, line) {
			glyph, ok := fontstash.__getGlyph(ctx, w.font, codepoint, w.isize, w.iblur)
			index := w.codepoint_offset + codepoint_index
			old := temp_x

			if glyph != nil {
				fontstash.__getQuad(ctx, w.font, previous_glyph_index, glyph, w.scale, w.spacing, &temp_x, &temp_y, &q)
			}

			if w.codepoint_index_low <= index && index < w.codepoint_index_high  {
				w.x_to = temp_x
				
				if w.x_from == -1 {
					w.x_from = old
				}
			}

			previous_glyph_index = glyph == nil ? -1 : glyph.index
		}

		w.y += 1
		w.codepoint_offset += ds.codepoint_count
	}

	return w.x_from != -1
}