package src

import "core:fmt"
import "core:strings"
import "core:mem"
import "core:time"

// helper call to build strings linearly
string_list_push_indices :: proc(builder: ^strings.Builder, text: string) -> (start, end: int) {
	start = len(builder.buf)
	strings.write_string(builder, text)
	end = len(builder.buf)
	return
}

string_list_push_ptr :: proc(builder: ^strings.Builder, text: string) -> (res: string) {
	old := len(builder.buf)
	strings.write_string(builder, text)
	res = string(builder.buf[old:])
	return
}

inv_lerp :: proc(a, b, v: f32) -> f32 {
	return (v - a) / (b - a)
}

// Bare data to copy task from
Copy_Task :: struct #packed {
	text_start: u32, // offset into text_list
	text_end: u32, // offset into text_list
	indentation: u8,
	state: Task_State,
	tags: u8,
	bookmarked: bool,
	timestamp: time.Time,
	highlight: bool,
	separator: bool,
	stored_image: ^Stored_Image,
	link_start: u32,
	link_end: u32,
	fold_count: u32,
	fold_parent: int,
}

// whats necessary to produce valid copies that can persist or are temporary
Copy_State :: struct {
	stored_text: strings.Builder,
	stored_links: strings.Builder,
	stored_tasks: [dynamic]Copy_Task,
	parent_count: int,
}

// allow to create temporary copy states
copy_state_init :: proc(
	text_cap: int,
	task_cap: int,
	allocator := context.allocator,
) -> (res: Copy_State) {
	res.stored_text = strings.builder_make(0, text_cap, allocator)
	res.stored_links = strings.builder_make(0, mem.Kilobyte, allocator)
	res.stored_tasks = make([dynamic]Copy_Task, 0, task_cap, allocator)
	// res.stored_folded = make([dynamic]int, 0, 128, allocator)
	return
}

copy_state_destroy :: proc(state: Copy_State) {
	delete(state.stored_text.buf)
	delete(state.stored_links.buf)
	delete(state.stored_tasks)
	// delete(state.stored_folded)
}

// reset copy data
copy_state_reset :: proc(state: ^Copy_State) {
	strings.builder_reset(&state.stored_text)
	clear(&state.stored_tasks)
	state.parent_count = 0
}

// just push text, e.g. from archive
copy_state_push_empty :: proc(state: ^Copy_State, text: string) {
	start, end := string_list_push_indices(&state.stored_text, text)

	// copy crucial info of task
	append(&state.stored_tasks, Copy_Task {
		text_start = u32(start),
		text_end = u32(end),
		fold_parent = -1,
	})
}

// push a task to copy list
copy_state_push_task :: proc(state: ^Copy_State, task: ^Task, fold_parent: int) {
	// NOTE works with utf8 :) copies task text
	text_start, text_end := string_list_push_indices(&state.stored_text, ss_string(&task.box.ss))
	link_start, link_end: int

	if task_link_is_valid(task) {
		link_start, link_end = string_list_push_indices(
			&state.stored_links, 
			strings.to_string(task.button_link.builder),
		)
	}

	// store that the next tasks are children
	fold_count: int
	if task.filter_folded {
		fold_count = len(task.filter_children)
	}

	// copy crucial info of task
	append(&state.stored_tasks, Copy_Task {
		u32(text_start),
		u32(text_end),
		u8(task.indentation),
		task.state,
		task.tags,
		task_bookmark_is_valid(task),
		task_time_date_is_valid(task) ? task.time_date.stamp : {},
		task.highlight,
		task_separator_is_valid(task),
		task.image_display == nil ? nil : task.image_display.img,
		u32(link_start),
		u32(link_end),
		u32(fold_count),
		fold_parent,
	})

	// have to copy folded content
	if task.filter_folded {
		parent := state.parent_count
		state.parent_count += 1
		
		for list_index in task.filter_children {
			child := app_task_list(list_index)
			copy_state_push_task(state, child, parent)
		}
	}
}

copy_state_empty :: proc(state: Copy_State) -> bool {
	return len(state.stored_tasks) == 0
}

copy_state_paste_at :: proc(
	state: ^Copy_State,
	manager: ^Undo_Manager, 
	real_index: int, 
	indentation: int,
) -> (insert_count: int) {
	index_at := real_index

	// find lowest indentation
	lowest_indentation := max(int)
	for t, i in state.stored_tasks {
		lowest_indentation = min(lowest_indentation, int(t.indentation))
	}

	// temp data
	parents := make([dynamic]^Task, 0, 32, context.temp_allocator)

	// copy into index range
	for t, i in state.stored_tasks {
		text := state.stored_text.buf[t.text_start:t.text_end]
		relative_indentation := indentation + int(t.indentation) - lowest_indentation
		
		task := task_init(relative_indentation, string(text), true)
		task.state = t.state
		task_set_bookmark(task, t.bookmarked)
		task.tags = t.tags
		task.highlight = t.highlight
		
		if t.separator {
			task_set_separator(task, true)
		}

		if t.timestamp != {} {
			task_set_time_date(task)
			task.time_date.stamp = t.timestamp
		}

		if t.stored_image != nil {
			task_set_img(task, t.stored_image)
		}

		if t.link_end != 0 {
			link := state.stored_links.buf[t.link_start:t.link_end]
			task_set_link(task, string(link))
		}

		if t.fold_count != 0 {
			append(&parents, task)
			task.filter_folded = true
			reserve(&task.filter_children, int(t.fold_count))
		}

		if t.fold_parent == -1 {
			task_insert_at(manager, index_at + insert_count, task)
			insert_count += 1
		} else {
			// get the parent at the expected relative index
			parent := parents[t.fold_parent]
			// dont insert but append to the parent
			append(&parent.filter_children, task.list_index)
		}
	}

	return
}

// copy selected task region
copy_state_copy_selection :: proc(state: ^Copy_State, low, high: int) -> bool {
	if low != -1 && high != -1 {
		copy_state_reset(state)

		// copy each line
		for i in low..<high + 1 {
			task := app_task_filter(i)
			copy_state_push_task(state, task, -1)
		}

		return true
	}

	return false
}
