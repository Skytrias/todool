package src

import "core:fmt"
import "core:strings"
import "../fontstash"

// THOUGHTS
// check task validity? or update search results based on validity
// what if the task is now invisible due to folding and search result still includes that

// goals
// space effefciency
// linearity(?) loop through the results from index to another forward/backward
// easy clearing
// fast task lookup

Search_Result :: struct #packed {
	low, high: u16,
}

Search_Entry :: struct #packed {
	ptr: ^Task,
	length: u16,
	result_offset: int,
}

Search_State :: struct {
	results: [dynamic]Search_Result,
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
}
ss: Search_State
panel_search: ^Panel

// init to cap
ss_init :: proc() {
	ss.entries = make([dynamic]Search_Entry, 0, 128)
	ss.results = make([dynamic]Search_Result, 0, 1028)
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
ss_push_result :: proc(low, high: u16) {
	ss.result_count^ += 1
	append(&ss.results, Search_Result { low, high })
}

// update serach state and find new results
ss_update :: proc(query: string) {
	ss_clear()

	if query == "" {
		return
	}

	// find results
	for i in 0..<len(tasks_visible) {
		task := tasks_visible[i]
		text := strings.to_string(task.box.builder)
		index: int

		ss_push_task(task)

		for rune_start, rune_end in contains_multiple_iterator(text, query, &index) {
			ss_push_result(rune_start, rune_end)
		}

		// check for popping
		if ss.result_count^ == 0 {
			ss_pop_task()	
		}
	}

	ss_find_next()
}

// iterator approach to finding a subtr
contains_multiple_iterator :: proc(s, substr: string, index: ^int) -> (rune_start, rune_end: u16, ok: bool) {
	for {
		if index^ > len(s) {
			break
		}

		search := s[index^:]
		
		// TODO could maybe be optimized by using cutf8!
		if res := strings.index(search, substr); res >= 0 {
			// NOTE: start & end are in rune offsets!
			start := strings.rune_count(s[:index^ + res])

			ok = true
			rune_start = u16(start)
			rune_end = u16(start + strings.rune_count(substr))

			// index moves by bytes
			index^ += res + len(substr)
			return
		} else {
			break
		}
	}

	ok = false
	return
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

	res := results[result_index]
	task_head = task.visible_index
	task_tail = task.visible_index
	task.box.head = int(res.high)
	task.box.tail = int(res.low)

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
	
	for entry in ss.entries {
		task := entry.ptr
		length := entry.length
		fcs_task(task)

		for i in 0..<int(length) {
			res := ss.results[entry.result_offset + i]
			state := fontstash.wrap_state_init(&gs.fc, task.box.wrapped_lines[:], int(res.low), int(res.high))
			scaled_size := f32(state.isize / 10)

			for fontstash.wrap_state_iter(&gs.fc, &state) {
				rect := RectI {
					task.box.bounds.l + int(state.x_from),
					task.box.bounds.l + int(state.x_to),
					task.box.bounds.t + int(f32(state.y - 1) * scaled_size),
					task.box.bounds.t + int(f32(state.y) * scaled_size),
				}
				
				color := theme.text_good
				// color := search_index == search_draw_index ? theme.text_good : theme.text_bad
				render_rect_outline(target, rect, color, 0)
			}
		}
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
					case "f3", "ctrl+n": {
						ss_find_next()
					}

					// prev 
					case "shift+f3", "ctrl+shift+n": {
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
	b1.invoke = proc(data: rawptr) {
		ss_find_next()
	}
	b2 := button_init(p, {}, "Find Prev")
	b2.invoke = proc(data: rawptr) {
		ss_find_prev()
	}

	panel_search = p
	element_hide(panel_search, true)
}
