package src

import "core:mem"
import "base:intrinsics"
import "core:os"
import "core:fmt"
import "core:thread"
import "core:unicode"
import "core:strings"
import "cutf8"
import "btrie"
import "vendor:fontstash"

DISABLE_USER :: false

spell_check_bin := #load("assets/comp_trie.bin")

// TODO changes for strings interning
// clear interned content?
// custom cap for init call? instead of 16
// call to check 

Spell_Check :: struct {
	word_results: [dynamic]Word_Result,
	
	// user dictionary
	user_intern: strings.Intern,
	user_backing: []byte,
	user_arena: mem.Arena,
}
sc: Spell_Check

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

spell_check_render_missing_words :: proc(target: ^Render_Target, task: ^Task) {
	text := ss_string(&task.box.ss)
	words := words_extract(&sc.word_results, text)

	builder := strings.builder_make(0, 256, context.temp_allocator)
	ds: cutf8.Decode_State

	for word in words {
		// lower case each word
		strings.builder_reset(&builder)
		ds = {}
		for codepoint in cutf8.ds_iter(&ds, word.text) {
			// TODO CHECK UTF8 WORD HERE?
			strings.write_rune(&builder, codepoint)
		}
		// res := rax.CustomFind(rt, raw_data(builder.buf), len(builder.buf))
		exists := spell_check_mapping(strings.to_string(builder))

		// render the result when not found
		if !exists {
			fcs_task(&task.element)
			state := wrap_state_init(
				&gs.fc, 
				task.box.wrapped_lines, 
				word.index_codepoint_start, 
				word.index_codepoint_end,
			)
			scaled_size := f32(state.isize / 10)
			line_width := LINE_WIDTH + int(4 * TASK_SCALE)

			for wrap_state_iter(&gs.fc, &state) {
				y := task.box.bounds.t + int(f32(state.y) * scaled_size) - line_width / 2
				
				rect := RectI {
					task.box.bounds.l + int(state.x_from),
					task.box.bounds.l + int(state.x_to),
					y,
					y + line_width,
				}
				
				render_sine(target, rect, theme.text_bad)
			}
		}
	}
}

// build the ebook to a compressed format
compressed_trie_build :: proc() {
	btrie.ctrie_init(80000)
	defer btrie.ctrie_destroy()

	bytes, ok := os.read_entire_file("assets/big.txt", context.allocator)
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
				btrie.ctrie_insert(w)
			}

			word_index = 0
		}
	}
	
	btrie.ctrie_print_size()

	// init compressed tree
	btrie.comp_init(mem.Megabyte * 2)
	btrie.comp_push_ctrie(btrie.ctrie_root(), nil)
	btrie.comp_print_size()
	btrie.comp_print()

	btrie.comp_write_to_file("assets/comp_trie.bin")
	btrie.comp_destroy()
}

spell_check_init :: proc() {
	// btrie.comp_read_from_file("assets/comp_trie.bin")
	btrie.comp_read_from_data(spell_check_bin)
	sc.word_results = make([dynamic]Word_Result, 0, 32)
	
	// backing string data for the dict
	sc.user_backing = make([]byte, mem.Megabyte * 2)
	mem.arena_init(&sc.user_arena, sc.user_backing)

	// custom init of user dict
	sc.user_intern.allocator = mem.arena_allocator(&sc.user_arena)
	sc.user_intern.entries = make(map[string]^strings.Intern_Entry, 256, context.allocator)
}

spell_check_clear_user :: proc() {
	clear(&sc.user_intern.entries)
	free_all(mem.arena_allocator(&sc.user_arena))
}

spell_check_destroy :: proc() {
	delete(sc.word_results)
	delete(sc.user_backing)
	strings.intern_destroy(&sc.user_intern)
}

// check if the word exists in the english dictionary 
// or in the user dictionary
spell_check_mapping :: proc(key: string) -> (res: bool) {
	res = btrie.comp_search(key)

	if !res {
		when !DISABLE_USER {
			_, found := sc.user_intern.entries[key]
			res = found
		}
	}

	return
}

// check to add non existent words to the spell checker user dictionary
spell_check_mapping_words_add :: proc(word: string) {
	words := words_extract(&sc.word_results, word)

	for word_result in words {
		spell_check_mapping_add(word_result.text)
	}
}

spell_check_mapping_add :: proc(key: string) -> bool {
	// only if the key doesnt exist in the compressed trie
	if !btrie.comp_search(key) {
		_, err := strings.intern_get(&sc.user_intern, key)
		// fmt.eprintln("added --->", key)
		return err == nil
	}

	return false
}