package src

import "core:fmt"
import "core:strings"
import "../fontstash"
import "../spall"
import "../cutf8"

// THOUGHTS
// check task validity? or update search results based on validity
// what if the task is now invisible due to folding and search result still includes that

// goals
// space effefciency
// linearity(?) loop through the results from index to another forward/backward
// easy clearing
// fast task lookup

Search_Entry :: struct #packed {
	ptr: ^Task,
	length: u16,
	result_offset: int,
}

Search_State :: struct {
	results: [dynamic]u16,
	entries: [dynamic]Search_Entry,

	// pointers from backing data
	result_count: ^u16, // current entry

	// task and box position saved
	saved_task_head: int,
	saved_task_tail: int,
	saved_box_head: int,
	saved_box_tail: int,

	// current index for searching
	current_index: int,
	pattern_rune_count: int,
}
ss: Search_State
panel_search: ^Panel

// init to cap
ss_init :: proc() {
	ss.entries = make([dynamic]Search_Entry, 0, 128)
	ss.results = make([dynamic]u16, 0, 1028)
	ss_clear()
}

ss_destroy :: proc() {
	using ss
	delete(entries)
	delete(results)
	result_count = nil
}

// clear count and reset write slice
ss_clear :: proc() {
	using ss
	clear(&entries)
	clear(&results)
	result_count = nil
	current_index = -1
}

// push a ptr and set current counter
ss_push_task :: proc(task: ^Task) {
	using ss
	append(&entries, Search_Entry {
		task,
		0,
		len(results),
	})
	entry := &entries[len(entries) - 1]
	result_count = &entry.length
}

ss_pop_task :: proc() {
	pop(&ss.entries)
}

// push a search result
ss_push_result :: proc(index: int) {
	ss.result_count^ += 1
	append(&ss.results, u16(index))
}

// update serach state and find new results
ss_update :: proc(pattern: string) {
	spall.fscoped("search update: %s", pattern)
	ss.pattern_rune_count = cutf8.count(pattern)
	ss_clear()

	if len(pattern) == 0 {
		return
	}

	sf := string_finder_init(pattern)

	// find results
	for i in 0..<len(tasks_visible) {
		task := tasks_visible[i]
		text := strings.to_string(task.box.builder)
		task_pushed: bool
		index: int

		for {
			res := string_finder_next(&sf, text)
			if res == -1 {
				break
			}
			if !task_pushed {
				ss_push_task(task)
				task_pushed = true
			}

			index += res
			ss_push_result(index)
			text = text[res + len(pattern):]
		}
	}

	ss_find_next()
}

ss_find :: proc(backwards: bool) {
	using ss

	if len(results) == 0 {
		return
	}

	range_advance_index(&current_index, len(results) - 1, backwards)

	task: ^Task
	result_index: int
	length_sum: int
	for entry, i in entries {
		// in correct space
		if length_sum + int(entry.length) > current_index {
			task = entry.ptr
			result_index = entry.result_offset + (current_index - length_sum)
			break
		}

		length_sum += int(entry.length)
	}

	task_head = task.visible_index
	task_tail = task.visible_index
	res := results[result_index]
	task.box.head = int(res) + ss.pattern_rune_count
	task.box.tail = int(res)

	element_repaint(mode_panel)
}

ss_find_next :: proc() {
	ss_find(false)
}

ss_find_prev :: proc() {
	ss_find(true)
}

// draw the search results outline
ss_draw_highlights :: proc(target: ^Render_Target, panel: ^Mode_Panel) {
	if (.Hide in panel_search.flags) {
		return
	}

	render_push_clip(target, panel.clip)
	ds: cutf8.Decode_State
	color := theme.text_good
	fmt.eprintln("DRAW SERCH")

	for entry in ss.entries {
		task := entry.ptr
		length := entry.length
		// fcs_task(task)

		if task.box.info.target != nil {
			fmt.eprintln("DRAW TASKSERCH")
			
			for i in 0..<int(length) {
				res := int(ss.results[entry.result_offset + i])
				text := strings.to_string(task.box.builder)
				ds = {}

				for codepoint, codepoint_offset in cutf8.ds_iter(&ds, text) {
					if res <= ds.byte_offset_old && ds.byte_offset_old < res + ss.pattern_rune_count {
						rect := rendered_glyph_rect(&task.box.info, codepoint_offset)
						fmt.eprintln(codepoint, rect)

						// color := search_index == search_draw_index ? theme.text_good : theme.text_bad
						render_rect_outline(target, rect_ftoi(rect), color, 0)
					}
				}
			}
		}

		// for i in 0..<int(length) {
		// 	res := ss.results[entry.result_offset + i]
		// 	state := fontstash.wrap_state_init(&gs.fc, task.box.wrapped_lines[:], int(res.low), int(res.high))
		// 	scaled_size := f32(state.isize / 10)

		// 	for fontstash.wrap_state_iter(&gs.fc, &state) {
		// 		rect := RectI {
		// 			task.box.bounds.l + int(state.x_from),
		// 			task.box.bounds.l + int(state.x_to),
		// 			task.box.bounds.t + int(f32(state.y - 1) * scaled_size),
		// 			task.box.bounds.t + int(f32(state.y) * scaled_size),
		// 		}
				
		// 		color := theme.text_good
		// 		// color := search_index == search_draw_index ? theme.text_good : theme.text_bad
		// 		render_rect_outline(target, rect, color, 0)
		// 	}
		// }
	}
}

search_init :: proc(parent: ^Element) {
	margin_scaled := int(5 * SCALE)
	height := int(DEFAULT_FONT_SIZE * SCALE) + margin_scaled * 2
	p := panel_init(parent, { .Panel_Default_Background, .Panel_Horizontal }, margin_scaled, 5)
	p.background_index = 2
	// p.shadow = true
	p.z_index = 2

	label_init(p, {}, "Search")

	box := text_box_init(p, { .HF })
	box.um = &um_search
	box.message_user = proc(element: ^Element, msg: Message, di: int, dp: rawptr) -> int {
		box := cast(^Text_Box) element

		#partial switch msg {
			case .Value_Changed: {
				query := strings.to_string(box.builder)
				ss_update(query)
			}

			case .Key_Combination: {
				combo := (cast(^string) dp)^
				handled := true

				switch combo {
					case "escape": {
						element_hide(panel_search, true)
						element_repaint(panel_search)
						task_head = ss.saved_task_head
						task_tail = ss.saved_task_tail
					}

					case "return": {
						element_hide(panel_search, true)
						element_repaint(panel_search)
					}

					// next
					case "f3", "ctrl n": {
						ss_find_next()
					}

					// prev 
					case "shift f3", "ctrl shift n": {
						ss_find_prev()
					}

					case: {
						handled = false
					}
				}

				return int(handled)
			}

			case .Update: {
				if di == UPDATE_FOCUS_LOST {
					element_hide(panel_search, true)
				}
			}
		}

		return 0
	}

	b1 := button_init(p, {}, "Find Next")
	b1.invoke = proc(button: ^Button, data: rawptr) {
		ss_find_next()
	}
	b2 := button_init(p, {}, "Find Prev")
	b2.invoke = proc(button: ^Button, data: rawptr) {
		ss_find_prev()
	}

	panel_search = p
	element_hide(panel_search, true)
}

// taken from <https://go.dev/src/strings/search.go>
String_Finder :: struct {
	pattern: string,
	bad_char_skip: [256]int,
	good_suffix_skip: []int,
}

string_finder_init :: proc(pattern: string) -> (res: String_Finder) {
	res.pattern = pattern
	res.good_suffix_skip = make([]int, len(pattern))

	for i in 0..<len(res.bad_char_skip) {
		res.bad_char_skip[i] = len(pattern)
	}

	last := len(pattern) - 1
	for i in 0..<last {
		res.bad_char_skip[pattern[i]] = last - i
	}

	last_prefix := last
	for i := last; i >= 0; i -= 1 {
		if strings.has_prefix(pattern, pattern[i + 1:]) {
			last_prefix = i + 1
		}

		res.good_suffix_skip[i] = last_prefix + last - i
	}

	for i in 0..<last {
		len_suffix := string_finder_longest_common_suffix(pattern, pattern[i:i + 1])

		if pattern[i - len_suffix] != pattern[last-len_suffix] {
			res.good_suffix_skip[last - len_suffix] = len_suffix + last - i
		}
	}

	return
}

string_finder_longest_common_suffix :: proc(a, b: string) -> int {
	for i := 0; i < len(a) && i < len(b); i += 1 {
		if a[len(a) - 1 - i] != b[len(b) - 1 - i] {
			return i
		}
	}

	return 0
}

string_finder_next :: proc(sf: ^String_Finder, text: string) -> int {
	i := len(sf.pattern) - 1

	for i < len(text) {
		j := len(sf.pattern) - 1

		for j >= 0 && text[i] == sf.pattern[j] {
			i -= 1
			j -= 1
		}

		if j < 0 {
			return i + 1
		}

		i += max(sf.bad_char_skip[text[i]], sf.good_suffix_skip[j])
	}

	return -1
}

// import "core:hash"
// main :: proc() {
// 	file_path := "/home/skytrias/Downloads/essence-master/desktop/gui.cpp"
// 	content, ok := os.read_entire_file(file_path)
// 	defer delete(content)

// 	if !ok {
// 		return
// 	}

// 	test_search_rabin :: proc(content: []byte) -> (diff: time.Duration) {
// 		tick_start := time.tick_now()
// 		pattern := "// TODO"
// 		pattern_hash, pattern_pow := hash_str_rabin_karp(pattern)
// 		text := string(content)

// 		for {
// 			res := index_hash_pow(text, pattern, pattern_hash, pattern_pow)
// 			if res == -1 {
// 				break
// 			}
// 			text = text[res + len(pattern):]
// 		}

// 		diff = time.tick_since(tick_start)
// 		return
// 	}

// 	test_search_linear :: proc(content: []byte) -> (diff: time.Duration) {
// 		tick_start := time.tick_now()

// 		temp := content
// 		temp_length := len(temp)
// 		pattern := "// TODO"
// 		pattern_length := len(pattern)
// 		pattern_hash := hash.fnv32(transmute([]byte) pattern)
// 		b: u8

// 		// for line in strings.split_lines_iterator(&temp) {
// 		for i := 0; i < temp_length; i += 1 {
// 			b = temp[i]

// 			if b == '/' {
// 				// TODO safety
// 				if temp[i + 1] == '/' {
// 					if i + pattern_length < temp_length {
// 						h := hash.fnv32(temp[i:i + pattern_length])

// 						if h == pattern_hash {
// 						// if temp[i:i + pattern_length] == pattern {
// 							// find end
// 							end_index := -1
// 							for j in i..<temp_length {
// 								if temp[j] == '\n' {
// 									end_index = j
// 									break
// 								}
// 							}

// 							if end_index != -1 {
// 								// fmt.eprintln(string(temp[i:end_index]))
// 								// task_push_undoable(manager, indentation, string(temp[i:end_index]), index_at^)
// 								// index_at^ += 1
// 								// i = end_index
// 							}
// 						}
// 					}
// 				}
// 			}
// 		}

// 		diff = time.tick_since(tick_start)
// 		return
// 	}

// 	test_search_finder :: proc(content: []byte) -> (diff: time.Duration) {
// 		tick_start := time.tick_now()

// 		sf := string_finder_init("// TODO")
// 		text := string(content)
//  		// accum: int

// 		for {
// 			res := string_finder_next(&sf, text)
// 			if res == -1 {
// 				break
// 			}

// 			// accum += res
// 			// fmt.eprintln(accum, text[res:res + len(sf.pattern)])
// 			text = text[res + len(sf.pattern):]
// 		}

// 		diff = time.tick_since(tick_start)
// 		return
			
// 	}

// 	iterations := 100
// 	sum: time.Duration

// 	for i in 0..<iterations {
// 		// sum += test_search_linear(content)
// 		// sum += test_search_rabin(content)
// 		// sum += test_search_finder(content)
// 	}

// 	sum_milli := f32(time.duration_milliseconds(sum)) / f32(iterations)
// 	sum_micro := f32(time.duration_microseconds(sum)) / f32(iterations)
// 	fmt.eprintf("avg %fms %fmys\n", sum_milli, sum_micro)
// }