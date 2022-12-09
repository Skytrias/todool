package src

import "core:strings"
import "core:mem"
import "core:time"

// helper call to build strings linearly
string_list_push :: proc(builder: ^strings.Builder, text: string) -> (start, end: int) {
	start = len(builder.buf)
	strings.write_string(builder, text)
	end = len(builder.buf)
	return
}

// Bare data to copy task from
Copy_Task :: struct #packed {
	text_start: u32, // offset into text_list
	text_end: u32, // offset into text_list
	indentation: u8,
	state: Task_State,
	tags: u8,
	folded: bool,
	bookmarked: bool,
	timestamp: time.Time,
	stored_image: ^Stored_Image,
	link_start: u32,
	link_end: u32,
}

// whats necessary to produce valid copies that can persist or are temporary
Copy_State :: struct {
	stored_text: strings.Builder,
	stored_links: strings.Builder,
	stored_tasks: [dynamic]Copy_Task,
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
	return
}

copy_state_destroy :: proc(state: Copy_State) {
	delete(state.stored_text.buf)
	delete(state.stored_links.buf)
	delete(state.stored_tasks)
}

// reset copy data
copy_state_reset :: proc(state: ^Copy_State) {
	strings.builder_reset(&state.stored_text)
	clear(&state.stored_tasks)
}

// just push text, e.g. from archive
copy_state_push_empty :: proc(state: ^Copy_State, text: string) {
	start, end := string_list_push(&state.stored_text, text)

	// copy crucial info of task
	append(&state.stored_tasks, Copy_Task {
		text_start = u32(start),
		text_end = u32(end),
	})
}

// push a task to copy list
copy_state_push_task :: proc(state: ^Copy_State, task: ^Task) {
	// NOTE works with utf8 :) copies task text
	text_start, text_end := string_list_push(&state.stored_text, ss_string(&task.box.ss))
	link_start, link_end: int

	if task_link_is_valid(task) {
		link_start, link_end = string_list_push(
			&state.stored_links, 
			strings.to_string(task.button_link.builder),
		)
	}

	// copy crucial info of task
	append(&state.stored_tasks, Copy_Task {
		u32(text_start),
		u32(text_end),
		u8(task.indentation),
		task.state,
		task.tags,
		task.folded,
		task_bookmark_is_valid(task),
		task_time_date_is_valid(task) ? task.time_date.stamp : {},
		task.image_display == nil ? nil : task.image_display.img,
		u32(link_start),
		u32(link_end),
	})
}

copy_state_empty :: proc(state: Copy_State) -> bool {
	return len(state.stored_tasks) == 0
}

copy_state_paste_at :: proc(
	state: ^Copy_State,
	manager: ^Undo_Manager, 
	real_index: int, 
	indentation: int,
) {
	index_at := real_index

	// find lowest indentation
	lowest_indentation := max(int)
	for t, i in state.stored_tasks {
		lowest_indentation = min(lowest_indentation, int(t.indentation))
	}

	// copy into index range
	for t, i in state.stored_tasks {
		text := state.stored_text.buf[t.text_start:t.text_end]
		relative_indentation := indentation + int(t.indentation) - lowest_indentation
		
		task := task_push_undoable(manager, relative_indentation, string(text), index_at + i)
		task.folded = t.folded
		task.state = t.state
		task_set_bookmark(task, t.bookmarked)
		task.tags = t.tags

		if t.timestamp != {} {
			task_set_time_date(task)
			task.time_date.stamp = t.timestamp
		}

		if t.stored_image != nil {
			task_set_img(task, t.stored_image)
		}

		if t.link_start != 0 || t.link_end != 0 {
			link := state.stored_links.buf[t.link_start:t.link_end]
			task_set_link(task, string(link))
		}
	}
}

// copy selected task region
copy_state_copy_selection :: proc(state: ^Copy_State, low, high: int) -> bool {
	if low != -1 && high != -1 {
		copy_state_reset(state)

		// copy each line
		for i in low..<high + 1 {
			task := app_task(i)
			copy_state_push_task(state, task)
		}

		return true
	}

	return false
}
