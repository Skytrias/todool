package src

import "core:mem"
import "core:intrinsics"
import "core:os"
import "core:fmt"
import "core:thread"
import "core:unicode"
import "core:strings"
import "../cutf8"
import "../spall"
import "../fontstash"
import "../art"

word_results: [dynamic]Word_Result

Word_Result :: struct {
	text: string,
	index_codepoint_start: int,
	index_codepoint_end: int,
}

words_extract :: proc(words: ^[dynamic]Word_Result, text: string) -> []Word_Result {
	clear(words)
	ds: cutf8.Decode_State
	index_codepoint_start := -1
	index_byte_start := -1

	word_push_check :: proc(
		words: ^[dynamic]Word_Result, 
		text: string, 
		ds: cutf8.Decode_State,
		index_codepoint_current: int, 
		index_codepoint_start: ^int, 
		index_byte_start: int,
	) {
		if index_codepoint_start^ != -1 {
			append(words, Word_Result {
				text = text[index_byte_start:ds.byte_offset_old],
				index_codepoint_start = index_codepoint_start^,
				index_codepoint_end = index_codepoint_current,
			})

			index_codepoint_start^ = -1
		}		
	}

	for codepoint, index in cutf8.ds_iter(&ds, text) {
		if unicode.is_alpha(codepoint) {
			if index_codepoint_start == -1 {
				index_codepoint_start = index
				index_byte_start = ds.byte_offset_old
			}
		} else {
			word_push_check(words, text, ds, index, &index_codepoint_start, index_byte_start)
		}
	}

	word_push_check(words, text, ds, ds.codepoint_count, &index_codepoint_start, index_byte_start)
	return words[:]
}

words_extract_test :: proc() {
	words := make([dynamic]Word_Result, 0, 32)
	w1 := "testing this out man"
	words_extract(&words, w1)
	fmt.eprintln(words[:], "\n")
	w2 := "test"
	words_extract(&words, w2)
	fmt.eprintln(words[:], "\n")
}

words_highlight_missing :: proc(target: ^Render_Target, task: ^Task) {
	spall.scoped("highlight missing")
	text := strings.to_string(task.box.builder)
	words := words_extract(&word_results, text)

	builder := strings.builder_make(0, 256, context.temp_allocator)
	ds: cutf8.Decode_State

	for word in words {
		// lower case each word
		strings.builder_reset(&builder)
		ds = {}
		for codepoint in cutf8.ds_iter(&ds, word.text) {
			// TODO CHECK UTF8 WORD HERE?
			strings.write_rune(&builder, unicode.to_lower(codepoint))
		}
		// res := rax.CustomFind(rt, raw_data(builder.buf), len(builder.buf))
		exists := art.comp_search(strings.to_string(builder))

		// render the result when not found
		if !exists {
			fcs_task(task)
			state := fontstash.wrap_state_init(
				&gs.fc, 
				task.box.wrapped_lines[:], 
				word.index_codepoint_start, 
				word.index_codepoint_end,
			)
			scaled_size := f32(state.isize / 10)
			line_width := LINE_WIDTH + int(4 * TASK_SCALE)

			for fontstash.wrap_state_iter(&gs.fc, &state) {
				y := task.box.bounds.t + int(f32(state.y) * scaled_size) - line_width / 2
				
				rect := RectI {
					task.box.bounds.l + int(state.x_from),
					task.box.bounds.l + int(state.x_to),
					y,
					y + line_width,
				}
				
				render_sine(target, rect, RED)
			}
		}
	}
}

// build the ebook to a compressed format
compressed_trie_build :: proc() {
	art.ctrie_init(80000)
	defer art.ctrie_destroy()

	bytes, ok := os.read_entire_file("../assets/big.txt", context.allocator)
	defer delete(bytes)

	// NOTE ASSUMING ASCII ENCODING
	// check for words in file, to lower all
	word: [256]u8
	word_index: uint
	for i in 0..<len(bytes) {
		b := bytes[i]

		// lowercase valid alpha
		if 'A' <= b && b <= 'Z' {
			old := b
			b += 32
		}

		if 'a' <= b && b <= 'z' {
			word[word_index] = b
			word_index += 1
		} else {
			if word_index != 0 {
				w := transmute(string) word[:word_index]
				art.ctrie_insert(w)
			}

			word_index = 0
		}
	}
	
	art.ctrie_print_size()

	// init compressed tree
	art.comp_init(mem.Megabyte * 2)
	art.comp_push_ctrie(art.ctrie_root(), nil)
	art.comp_print_size()

	art.comp_write_to_file("../assets/comp_trie.bin")
	art.comp_destroy()
}

spell_check_init :: proc() {
	art.comp_read_from_file("../assets/comp_trie.bin")
	word_results = make([dynamic]Word_Result, 0, 32)
}

spell_check_destroy :: proc() {
	art.comp_destroy()
	delete(word_results)
}

