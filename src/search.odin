package src

import "core:math"
import "core:mem"
import "core:fmt"
import "core:strings"
import "heimdall:fontstash"
import "../spall"
import "../cutf8"

// THOUGHTS
// check task search_updateidity? or update search results based on validity
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

Search_Result :: struct {
	start, end: u16,
}

Search_State :: struct {
	results: [dynamic]Search_Result,
	entries: [dynamic]Search_Entry,

	// pointers from backing data
	result_count: ^u16, // current entry
	pattern_length: int,

	// task and box position saved
	saved_task_head: int,
	saved_task_tail: int,
	saved_box_head: int,
	saved_box_tail: int,

	// current index for searching
	current_index: int,

	// ui related
	text_box: ^Text_Box,
	
	// persistent state
	case_insensitive: bool,
}
search: Search_State
panel_search: ^Panel

// init to cap
search_state_init :: proc() {
	search.entries = make([dynamic]Search_Entry, 0, 128)
	search.results = make([dynamic]Search_Result, 0, 1028)
	search_clear()
}

search_state_destroy :: proc() {
	using search
	delete(entries)
	delete(results)
	result_count = nil
}

// clear count and reset write slice
search_clear :: proc() {
	using search
	clear(&entries)
	clear(&results)
	result_count = nil
	current_index = -1
}

search_has_results :: proc() -> bool {
	return len(search.entries) != 0
}

// push a ptr and set current counter
search_push_task :: proc(task: ^Task) {
	using search
	append(&entries, Search_Entry {
		task,
		0,
		len(results),
	})
	entry := &entries[len(entries) - 1]
	result_count = &entry.length
}

search_pop_task :: proc() {
	pop(&search.entries)
}

// push a search result
search_push_result :: proc(start, end: int) {
	search.result_count^ += 1
	append(&search.results, Search_Result { u16(start), u16(end) })
}

// update serach state and find new results
search_update :: proc(pattern: string) {
	spall.fscoped("search update: %s", pattern)
	search_clear()
	search.pattern_length = cutf8.count(pattern)

	if len(pattern) == 0 {
		return
	}

	if search.case_insensitive {
		// TODO any kind of optimization?
		builder := strings.builder_make(0, 256, context.temp_allocator)
		sf := string_finder_init(cutf8.to_lower(&builder, pattern))
		defer string_finder_destroy(sf)

		// find results
		for index in app.pool.filter {
			task := app_task_list(index)
			text := ss_string(&task.box.ss)
			task_pushed: bool
			index: int
			strings.builder_reset(&builder)
			text_lowered := cutf8.to_lower(&builder, text)

			for {
				res := string_finder_next(&sf, text_lowered[index:])

				if res == -1 {
					break
				}

				if !task_pushed {
					search_push_task(task)
					task_pushed = true
				}

				index += res
				count := cutf8.count(text_lowered[:index])
				search_push_result(count, count + search.pattern_length)
				index += len(pattern)
			}
		}
	} else {
		sf := string_finder_init(pattern)
		defer string_finder_destroy(sf)
		
		// find results
		for index in app.pool.filter {
			task := app_task_list(index)
			text := ss_string(&task.box.ss)
			task_pushed: bool
			index: int

			for {
				res := string_finder_next(&sf, text[index:])
				if res == -1 {
					break
				}

				if !task_pushed {
					search_push_task(task)
					task_pushed = true
				}

				index += res
				count := cutf8.count(text[:index])
				search_push_result(count, count + search.pattern_length)
				index += len(pattern)
			}
		}
	}

	search_find_next()
}

search_find :: proc(backwards: bool) {
	using search

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

	app.task_head = task.filter_index
	app.task_tail = task.filter_index

	result := results[result_index]
	text := task_string(task)
	task.box.head = int(result.end)
	task.box.tail = int(result.start)

	element_repaint(app.mmpp)
}

search_find_next :: proc() {
	search_find(false)
}

search_find_prev :: proc() {
	search_find(true)
}

// draw the search results outline
search_draw_highlights :: proc(target: ^Render_Target, panel: ^Mode_Panel) {
	if (.Hide in panel_search.flags) || !search_has_results() {
		return
	}

	render_push_clip(target, panel.clip)
	ds: cutf8.Decode_State
	color := theme.text_good
	search_draw_index: int
	GRAY :: Color { 100, 100, 100, 255 }

	for entry in search.entries {
		task := entry.ptr
		length := entry.length
		top := task.box.bounds.t
		height := rect_heightf(task.box.bounds)
		scaled_size := f32(fcs_task(&task.element))

		for i in 0..<int(length) {
			result := search.results[entry.result_offset + i]
			state := wrap_state_init(&gs.fc, task.box.wrapped_lines, int(result.start), int(result.end))
			scaled_size := f32(state.isize / 10)

			for wrap_state_iter(&gs.fc, &state) {
				rect := RectI {
					task.box.bounds.l + int(state.x_from),
					task.box.bounds.l + int(state.x_to),
					task.box.bounds.t + int(f32(state.y - 1) * scaled_size),
					task.box.bounds.t + int(f32(state.y) * scaled_size),
				}
				
				// color := theme.text_good
				color := search.current_index == search_draw_index ? GRAY : theme.caret
				render_rect_outline(target, rect, color, 0, 2)
			}

			search_draw_index += 1
		}
	}
}

button_state_message :: proc(element: ^Element, msg: Message, di: int, dp: rawptr) -> int {
	button := cast(^Button) element

	#partial switch msg{
		case .Paint_Recursive: {
			assert(button.data != nil)
			enabled := cast(^bool) button.data

			target := element.window.target
			pressed := element.window.pressed == element
			hovered := element.window.hovered == element
			text_color := hovered || pressed ? theme.text_default : theme.text_blank

			if enabled^ {
				render_hovered_highlight(target, element.bounds)
			}

			fcs_element(button)
			fcs_ahv()
			fcs_color(text_color)
			text := strings.to_string(button.builder)
			render_string_rect(target, element.bounds, text)
			return 1
		}

		case .Clicked: {
			assert(button.data != nil)
			enabled := cast(^bool) button.data
			enabled^ = !enabled^
			element_message(search.text_box, .Value_Changed)
			return 1
		}
	}

	return 0		
}

search_init :: proc(parent: ^Element) {
	margin_scaled := int(TEXT_PADDING * SCALE)
	height := int(DEFAULT_FONT_SIZE * SCALE) + margin_scaled * 2
	p := panel_init(parent, { .Panel_Default_Background, .Panel_Horizontal }, margin_scaled, 5)
	p.background_index = 2
	// p.shadow = true
	p.z_index = 2

	{
		button := button_init(p, {}, "aA", button_state_message)
		button.hover_info = "Case Insensitive Search"
		button.data = &search.case_insensitive
	}

	box := text_box_init(p, { .HF })
	search.text_box = box
	box.um = &app.um_search
	box.message_user = proc(element: ^Element, msg: Message, di: int, dp: rawptr) -> int {
		box := cast(^Text_Box) element

		#partial switch msg {
			case .Value_Changed: {
				query := ss_string(&box.ss)
				search_update(query)
			}

			case .Key_Combination: {
				combo := (cast(^string) dp)^
				handled := true

				switch combo {
					case "escape": {
						element_hide(panel_search, true)
						element_repaint(panel_search)
						app.task_head = search.saved_task_head
						app.task_tail = search.saved_task_tail
					}

					case "return": {
						element_hide(panel_search, true)
						element_repaint(panel_search)
					}

					// next
					case "f3", "ctrl n": {
						search_find_next()
					}

					// prev 
					case "shift f3", "ctrl shift n": {
						search_find_prev()
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
		search_find_next()
	}
	b2 := button_init(p, {}, "Find Prev")
	b2.invoke = proc(button: ^Button, data: rawptr) {
		search_find_prev()
	}

	panel_search = p
	element_hide(panel_search, true)
}

String_Finder :: struct {
	pattern: string,
	pattern_hash: u32,
	pattern_pow: u32,
}

string_finder_init :: proc(pattern: string) -> (res: String_Finder) {
	res.pattern = strings.clone(pattern)

	hash_str_rabin_karp :: proc(s: string) -> (hash: u32 = 0, pow: u32 = 1) {
		for i := 0; i < len(s); i += 1 {
			hash = hash*PRIME_RABIN_KARP + u32(s[i])
		}
		sq := u32(PRIME_RABIN_KARP)
		for i := len(s); i > 0; i >>= 1 {
			if (i & 1) != 0 {
				pow *= sq
			}
			sq *= sq
		}
		return
	}

	res.pattern_hash, res.pattern_pow = hash_str_rabin_karp(pattern)
	return
}

string_finder_destroy :: proc(sf: String_Finder) {
	delete(sf.pattern)
}

@private PRIME_RABIN_KARP :: 16777619

string_finder_next :: proc(sf: ^String_Finder, text: string) -> int {
	n := len(sf.pattern)
	switch {
	case n == 0:
		return 0
	case n == 1:
		return strings.index_byte(text, sf.pattern[0])
	case n == len(text):
		if text == sf.pattern {
			return 0
		}
		return -1
	case n > len(text):
		return -1
	}

	hash, pow := sf.pattern_hash, sf.pattern_pow
	h: u32
	for i := 0; i < n; i += 1 {
		h = h*PRIME_RABIN_KARP + u32(text[i])
	}
	if h == hash && text[:n] == sf.pattern {
		return 0
	}
	for i := n; i < len(text); /**/ {
		h *= PRIME_RABIN_KARP
		h += u32(text[i])
		h -= pow * u32(text[i-n])
		i += 1
		if h == hash && text[i-n:i] == sf.pattern {
			return i - n
		}
	}
	return -1
}