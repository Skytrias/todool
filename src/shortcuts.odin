package src

import "core:os"
import "core:fmt"
import "core:slice"
import "core:strings"
import "core:log"
import "core:mem"
import "core:time"
import "core:math/bits"
import "../cutf8"
import "../tfd"

// iterate by whitespace, utf8 conform
combo_iterate :: proc(text: ^string) -> (res: string, ok: bool) {
	temp := text^
	state: rune
	codepoint: rune
	start := -1
	index: int
	set: bool

	for len(text) > 0 {
		if cutf8.decode(&state, &codepoint, text[0]) {
			if codepoint != ' ' {
				if start == -1 {
					start = index
				}
			} else {
				if start != -1 {
					res = temp[start:index]
					set = true
				}
			}
		}

		index += 1
		text^ = text^[1:]

		// check inbetween
		if set {
			ok = true
			return
		}
	}

	// add last one
	if start != -1 {
		res = temp[start:]
		ok = true
	}

	return
}

// combo_iterate_test :: proc() {
// 	text := "ctrl+up         ctrl+down"
// 	fmt.eprintln(text)
// 	for combo in combo_iterate(&text) {
// 		fmt.eprintf("\tres: %s\n", combo)
// 	}
// }

todool_delete_on_empty :: proc(du: u32) {
	if app_filter_empty() {
		return
	}

	task := app_task_head()
	
	if int(task.box.ss.length) == 0 {
		manager := mode_panel_manager_scoped()
		task_head_tail_push(manager)
		app.task_state_progression = .Update_Animated
		
		if task.filter_index == len(app.pool.filter) {
			item := Undo_Item_Task_Pop {}
			undo_task_pop(manager, &item)
		} else {
			task_remove_at_index(manager, task)
		}

		element_repaint(task)
		app.task_head -= 1
		app.task_tail -= 1
	}
}

todool_move_up :: proc(du: u32) {
	if app_filter_empty() {
		return
	}

	shift := du_shift(du)
	if task_head_tail_check_begin(shift) {
		app.task_head -= 1
	}
	task_head_tail_check_end(shift)
	bs.current_index = -1
	task := app_task_filter(max(app.task_head, 0))
	window_repaint(app.window_main)
	element_message(task.box, .Box_Set_Caret, BOX_END)

	vim.rep_task = nil
}

todool_move_down :: proc(du: u32) {
	if app_filter_empty() {
		return 
	}

	shift := du_shift(du)
	if task_head_tail_check_begin(shift) {
		app.task_head += 1
	}
	task_head_tail_check_end(shift)
	bs.current_index = -1

	task := app_task_filter(min(app.task_head, len(app.pool.filter) - 1))
	element_message(task.box, .Box_Set_Caret, BOX_END)
	window_repaint(app.window_main)

	vim.rep_task = nil
}

todool_move_up_stack :: proc(du: u32) {
	if app_filter_empty() {
		return
	}

	// fill stack when jumping out
	task := app_task_head()
	p := task
	for p != nil {
		app.task_move_stack[p.indentation] = p
		p = p.visible_parent
	}

	if task.indentation > 0 {
		goal := app.task_move_stack[task.indentation - 1]
		shift := du_shift(du)
		if task_head_tail_check_begin(shift) {
			app.task_head = goal.filter_index
		}
		task_head_tail_check_end(shift)

		task = app_task_head()
		element_message(task.box, .Box_Set_Caret, BOX_END)
		window_repaint(app.window_main)

		vim.rep_task = nil
	}
}

todool_move_down_stack :: proc(du: u32) {
	if app_filter_empty() {
		return
	}

	task := app_task_head()
	goal := app.task_move_stack[task.indentation + 1]

	if goal != nil {
		shift := du_shift(du)
		if task_head_tail_check_begin(shift) {
			if goal.filter_index < len(app.pool.filter) {
				app.task_head = goal.filter_index
			}
		}
		task_head_tail_check_end(shift)

		task = app_task_head()
		element_message(task.box, .Box_Set_Caret, BOX_END)
		window_repaint(app.window_main)		

		vim.rep_task = nil
	}
}

todool_indent_jump_low_prev :: proc(du: u32) {
	if app_filter_empty() {
		return
	}

	task_current := app_task_head()
	shift := du_shift(du)
	
	for i := task_current.filter_index - 1; i >= 0; i -= 1 {
		task := app_task_filter(i)

		if task.indentation == 0 {
			if task_head_tail_check_begin(shift) {
				app.task_head = task.filter_index
			}
			task_head_tail_check_end(shift)
			element_message(task.box, .Box_Set_Caret, BOX_END)
			element_repaint(task)
			break
		}
	}

	vim.rep_task = nil
}

todool_indent_jump_low_next :: proc(du: u32) {
	if app_filter_empty() {
		return
	}

	task_current := app_task_head()
	shift := du_shift(du)

	for i in task_current.filter_index + 1..<len(app.pool.filter) {
		task := app_task_filter(i)

		if task.indentation == 0 {
			if task_head_tail_check_begin(shift) {
				app.task_head = task.filter_index
			}
			task_head_tail_check_end(shift)
			element_repaint(task)
			element_message(task.box, .Box_Set_Caret, BOX_END)
			break
		}
	}

	vim.rep_task = nil
}

// -1 means nothing found
find_same_indentation_backwards :: proc(visible_index: int) -> (res: int) {
	res = -1
	task_current := app_task_filter(visible_index)

	for i := visible_index - 1; i >= 0; i -= 1 {
		task := app_task_filter(i)
		
		if task.indentation == task_current.indentation {
			res = i
			return
		}
	}

	return
}

find_same_indentation_forwards :: proc(visible_index: int) -> (res: int) {
	res = -1
	task_current := app_task_filter(visible_index)

	for i := visible_index + 1; i < len(app.pool.filter); i += 1 {
		task := app_task_filter(i)
		
		if task.indentation == task_current.indentation {
			res = i
			return
		}
	}

	return
}

todool_indent_jump_same_prev :: proc(du: u32) {
	if app_filter_empty() {
		return
	}

	task_current := app_task_head()
	shift := du_shift(du)
	goal := find_same_indentation_backwards(app.task_head)
	
	if goal != -1 {
		if task_head_tail_check_begin(shift) {
			app.task_head = goal
		}
		task_head_tail_check_end(shift)
		window_repaint(app.window_main)
		element_message(app_task_head().box, .Box_Set_Caret, BOX_END)		
	}

	vim.rep_task = nil
}

todool_indent_jump_same_next :: proc(du: u32) {
	if app_filter_empty() {
		return
	}

	task_current := app_task_head()
	shift := du_shift(du)
	goal := find_same_indentation_forwards(app.task_head)

	if goal != -1 {
		if task_head_tail_check_begin(shift) {
			app.task_head = goal
		}
		task_head_tail_check_end(shift)
		window_repaint(app.window_main)
		element_message(app_task_filter(goal).box, .Box_Set_Caret, BOX_END)
	} 

	vim.rep_task = nil
}

todool_bookmark_jump :: proc(du: u32) {
	shift := du_shift(du)
	
	if len(bs.rows) != 0 && app_filter_not_empty() {
		bookmark_advance(shift)
		task := bs.rows[bs.current_index]
		app.task_head = task.filter_index
		app.task_tail = task.filter_index
		window_repaint(app.window_main)
		vim.rep_task = nil

		bs.alpha = 1
		window_animate(app.window_main, &bs.alpha, 0, .Quadratic_Out, time.Second * 2)
	}
}

todool_delete_tasks :: proc(du: u32 = 0) {
	if app_filter_empty() {
		return
	}

	manager := mode_panel_manager_scoped()
	app.task_state_progression = .Update_Animated
	task_head_tail_push(manager)
	task_remove_selection(manager, true)
	window_repaint(app.window_main)
}

todool_copy_tasks_to_clipboard :: proc(du: u32) {
	if app_filter_empty() {
		return
	}

	b := &gs.copy_builder
	strings.builder_reset(b)

	// get lowest
	iter := lh_iter_init()
	lowest_indentation := tasks_lowest_indentation(iter.low, iter.high)

	// write text into buffer
 	for task in lh_iter_step(&iter) {
		relative_indentation := task.indentation - lowest_indentation
		task_write_text_indentation(b, task, relative_indentation)
	}

	app.last_was_task_copy = false
	clipboard_set_with_builder_prefilled()
	window_repaint(app.window_main)
}

todool_change_task_selection_state_to :: proc(state: Task_State) {
	if app_filter_empty() {
		return
	}

	manager := mode_panel_manager_scoped()
	task_head_tail_push(manager)

	app.task_state_progression = .Update_Animated
	task_count: int

	iter := lh_iter_init()
	for task in lh_iter_step(&iter) {
		task_set_state_undoable(manager, task, state, task_count)
		task_count += 1
	}
}

todool_change_task_state :: proc(du: u32) {
	if app_filter_empty() {
		return
	}

	shift := du_shift(du)
	manager := mode_panel_manager_scoped()
	task_head_tail_push(manager)
	temp_state: int

	// modify all states
	app.task_state_progression = .Update_Animated
	task_count: int
	iter := lh_iter_init()
	for task in lh_iter_step(&iter) {
		temp_state = int(task.state)
		range_advance_index(&temp_state, len(Task_State) - 1, shift)
		// save old set
		task_set_state_undoable(manager, task, Task_State(temp_state), task_count)
		task_count += 1
	}

	window_repaint(app.window_main)
}

todool_indent_jump_scope :: proc(du: u32) {
	if app_filter_empty() {
		return
	}

	task_current := app_task_head()
	defer window_repaint(app.window_main)
	shift := du_shift(du)

	// skip indent search at higher levels, just check for 0
	if task_current.indentation == 0 {
		// search for first indent 0 at end
		for i := len(app.pool.filter) - 1; i >= 0; i -= 1 {
			current := app_task_filter(i)

			if current.indentation == 0 {
				if i == app.task_head {
					break
				}

				task_head_tail_check_begin(shift)
				app.task_head = i
				task_head_tail_check_end(shift)
				return
			}
		}

		// search for first indent at 0 
		for i in 0..<len(app.pool.filter) {
			current := app_task_filter(i)

			if current.indentation == 0 {
				task_head_tail_check_begin(shift)
				app.task_head = i
				task_head_tail_check_end(shift)
				break
			}
		}
	} else {
		// check for end first
		last_good := app.task_head
		for i in app.task_head + 1..<len(app.pool.filter) {
			next := app_task_filter(i)

			if next.indentation == task_current.indentation {
				last_good = i
			}

			if next.indentation < task_current.indentation || i + 1 == len(app.pool.filter) {
				if last_good == app.task_head {
					break
				}

				task_head_tail_check_begin(shift)
				app.task_head = last_good
				task_head_tail_check_end(shift)
				return
			}
		}

		// move backwards
		last_good = -1
		for i := app.task_head - 1; i >= 0; i -= 1 {
			prev := app_task_filter(i)

			if prev.indentation == task_current.indentation {
				last_good = i
			}

			if prev.indentation < task_current.indentation {
				task_head_tail_check_begin(shift)
				app.task_head = last_good
				task_head_tail_check_end(shift)
				break
			}
		}
	}
}

todool_selection_stop :: proc(du: u32) {
	if task_has_selection() {
		app.task_tail = app.task_head
		window_repaint(app.window_main)
	}	
}

todool_escape :: proc(du: u32) {
	if image_display_has_content_now(app.custom_split.image_display) {
		app.custom_split.image_display.img = nil
		window_repaint(app.window_main)
		return
	}

	if element_hide(sb.enum_panel, true) {
		window_repaint(app.window_main)
		return
	}

	// reset selection
	if app.task_head != app.task_tail {
		app.task_tail = app.task_head
		window_repaint(app.window_main)
		return
	}
}

todool_toggle_folding :: proc(du: u32 = 0) {
	if app_filter_empty() {
		return
	}

	task := app_task_head()
	// if task.has_children {
		manager := mode_panel_manager_scoped()
		task_head_tail_push(manager)
		
		if len(task.folded) == 0 {
			task.folded = make([]int, task.children_count)
			idx := task.filter_index + 1
			count := int(task.children_count)
			copy(task.folded, app.pool.filter[idx:idx + count])
			copy(app.pool.filter[idx:], app.pool.filter[idx + count:])
			resize(&app.pool.filter, len(app.pool.filter) - count)
		} else {
			fmt.eprintln("TRY")
			count := len(task.folded)
			idx := task.filter_index + 1
			resize(&app.pool.filter, len(app.pool.filter) + count)
			copy(app.pool.filter[idx:], app.pool.filter[idx + count:])
			copy(app.pool.filter[idx:], task.folded[:])
			
			delete(task.folded)
			task.folded = nil
		}

		// item := Undo_Item_Bool_Toggle { &task.folded }
		// undo_bool_toggle(manager, &item)
		
		app.task_tail = app.task_head
		window_repaint(app.window_main)
	// }
}

todool_insert_sibling :: proc(du: u32) {
	manager := mode_panel_manager_scoped()
	task_head_tail_push(manager)
	shift := du_shift(du)
	
	app.task_state_progression = .Update_Animated
	indentation: int
	goal: int
	if shift {
		// above / same line
		if app.task_head != -1 && app.task_head > 0 {
			goal = app_task_head().filter_index
			indentation = app_task_head().indentation
		}

		app.task_tail = app.task_head
	} else {
		// next line
		goal = len(app.pool.filter) // default append
		if app.task_head < len(app.pool.filter) - 1 {
			goal = app_task_filter(app.task_head + 1).filter_index
		}

		if app_filter_not_empty() {
			indentation = app_task_head().indentation
		}
	
		app.task_head += 1
	}

	task_push_undoable(manager, indentation, "", goal)
	task_head_tail_check_end(shift)
	window_repaint(app.window_main)
}

todool_insert_child :: proc(du: u32) {
	indentation: int
	goal := len(app.pool.filter) // default append
	manager := mode_panel_manager_scoped()
	task_head_tail_push(manager)
	shift := du_shift(du)
	app.task_state_progression = .Update_Animated

	if app.task_head < len(app.pool.filter) - 1 {
		goal = app_task_filter(app.task_head + 1).filter_index
	}
	jump := 1

	if app_filter_not_empty() {
		current_task := app_task_head()
		indentation = current_task.indentation + 1
		ss := &current_task.box.ss

		// uppercase word
		if !current_task.has_children && options_uppercase_word() && ss_has_content(ss) {
			item := Undo_String_Uppercased_Content { ss }
			undo_box_uppercased_content(manager, &item)
		}

		// TODO
		// // unfold current task if its folded 
		// if current_task.folded {
		// 	count := task_children_count(current_task)
		// 	item := Undo_Item_Bool_Toggle { &current_task.folded }
		// 	undo_bool_toggle(manager, &item)
		// 	goal = current_task.filter_index + 1
		// }
	}

	task_push_undoable(manager, indentation, "", goal)
	app.task_head += jump
	task_head_tail_check_end(shift)
	window_repaint(app.window_main)
}

todool_mode_list :: proc(du: u32) {
	if app.mmpp.mode != .List {
		app.mmpp.mode = .List
		custom_split_set_scrollbars(app.custom_split)
		window_repaint(app.window_main)
		power_mode_clear()
	}
}

todool_mode_kanban :: proc(du: u32) {
	if app.mmpp.mode != .Kanban {
		app.mmpp.mode = .Kanban
		custom_split_set_scrollbars(app.custom_split)
		window_repaint(app.window_main)
		power_mode_clear()
	}
}

// Undo_Item_Shift_Slice :: struct {
// 	total_low: int,
// 	total_high: int,
// 	// data following with pointers that should be reset to
// }

// // store the total region in undo
// undo_push_shift_slice :: proc(manager: ^Undo_Manager, low, high: int) {
// 	output := Undo_Item_Shift_Slice { low, high }
// 	count := high - low
// 	bytes := undo_push(manager, undo_shift_slice, &output, size_of(Undo_Item_Shift_Slice) + count * size_of(^Element))

// 	bytes_root := cast(^^Element) &bytes[size_of(Undo_Item_Shift_Slice)]
// 	storage := mem.slice_ptr(bytes_root, count)
// 	copy(storage, app.mode_panel.children[low:high])
// }

// // undo element slice region to something stored prior
// undo_shift_slice :: proc(manager: ^Undo_Manager, item: rawptr) {
// 	data := cast(^Undo_Item_Shift_Slice) item
// 	count := data.total_high - data.total_low

// 	// push before actually resetting data to a previous state
// 	output := data^
// 	bytes := undo_push(manager, undo_shift_slice, &output, size_of(Undo_Item_Shift_Slice) + count * size_of(^Element))
	
// 	// save current data
// 	{
// 		bytes_root := cast(^^Element) &bytes[size_of(Undo_Item_Shift_Slice)]
// 		storage := mem.slice_ptr(bytes_root, count)
// 		copy(storage, app.mode_panel.children[data.total_low:data.total_high])
// 	}

// 	// set to pushed data
// 	{
// 		bytes_root := uintptr(item) + size_of(Undo_Item_Shift_Slice)
// 		storage := mem.slice_ptr(cast(^^Element) bytes_root, count)
// 		copy(app.mode_panel.children[data.total_low:data.total_high], storage)
// 	}
// }

// shift_tasks_complex :: proc(backwards: bool) {
// 	goal_visible_index: int

// 	if backwards { 
// 		goal_visible_index = find_same_indentation_backwards(app.task_head)
// 	} else {
// 		goal_visible_index = find_same_indentation_forwards(app.task_head)
// 	}

// 	if goal_visible_index == -1 {
// 		return
// 	}

// 	// save highest index before pops
// 	task_current := app_task_filter(backwards ? app.task_head : goal_visible_index)
// 	current_count := 1
// 	if task_current.has_children {
// 		current_count += task_children_count(task_current)
// 	}

// 	// gather lowest nodes
// 	task_goal := app_task_filter(backwards ? goal_visible_index : app.task_head)
// 	goal_count := 1
// 	if task_goal.has_children {
// 		goal_count += task_children_count(task_goal)
// 	}

// 	manager := mode_panel_manager_scoped()
// 	task_head_tail_push(manager)

// 	// simplified version when only 2 tasks are pushed
// 	if goal_count == 1 && current_count == 1 {
// 		if backwards {
// 			x, y := task_xy_to_real(app.task_head - 1, app.task_head)
// 			task_swap(manager, x, y)
// 			app.task_head -= 1
// 			app.task_tail -= 1
// 		} else {
// 			x, y := task_xy_to_real(app.task_head, app.task_head + 1)
// 			task_swap(manager, x, y)
// 			app.task_head += 1
// 			app.task_tail += 1
// 		}

// 		return
// 	}

// 	total_low := task_goal.index
// 	total_high := task_current.index + current_count
// 	undo_push_shift_slice(manager, total_low, total_high)

// 	// copy all to the slice
// 	temp := make([]^Element, goal_count, context.temp_allocator)
// 	copy(temp, app.mode_panel.children[task_goal.index:task_goal.index + goal_count])

// 	// copy selection to goal index
// 	copy(
// 		app.mode_panel.children[task_goal.index:], 
// 		app.mode_panel.children[task_current.index:task_current.index + current_count],
// 	)

// 	// copy temp to proper region
// 	copy(
// 		app.mode_panel.children[task_goal.index + current_count:], 
// 		temp,
// 	)

// 	// animate tasks that have a changed index
// 	for i in task_goal.index..<task_current.index + current_count {
// 		task := app_task_filter(i)

// 		if task.filter_index != i {
// 			task_swap_animation(task)
// 		}
// 	}

// 	if backwards {
// 		app.task_head -= task_goal.folded ? 1 : goal_count
// 		app.task_tail -= task_goal.folded ? 1 : goal_count
// 	} else {
// 		app.task_head += task_current.folded ? 1 : current_count
// 		app.task_tail += task_current.folded ? 1 : current_count
// 	}
// }

todool_shift_up :: proc(du: u32) {
	x := app.task_head
	y := app.task_head - 1
	f := app.pool.filter
	f[x], f[y] = f[y], f[x]
	window_repaint(app.window_main)


	// if len(app.pool.filter) < 2 {
	// 	return
	// }

	// if app.task_head == app.task_tail {
	// 	shift_tasks_complex(true)
	// } else {
	// 	low, high := task_low_and_high()
	// 	goal_visible_index := low - 1

	// 	if goal_visible_index < 0 {
	// 		return
	// 	}

	// 	manager := mode_panel_manager_scoped()
	// 	task_head_tail_push(manager)

	// 	task_current := app.tasks_visible[low]
	// 	task_goal := app.tasks_visible[goal_visible_index]
	// 	goal_count := 1
	// 	weird_jump: bool
	// 	weird_count: int

	// 	if task_goal.has_children {
	// 		// find lowest indentation to determine unfolding since we could be hidden
	// 		lowest_indentation := tasks_lowest_indentation(low, high)

	// 		if goal_visible_index - 1 >= 0 {
	// 			prev := app.tasks_visible[goal_visible_index - 1]

	// 			if prev.folded && prev.indentation < lowest_indentation {
	// 				item := Undo_Item_Bool_Toggle { &prev.folded }
	// 				undo_bool_toggle(manager, &item)

	// 				weird_jump = true
	// 				weird_count = task_children_count(prev)
	// 			}
	// 		}

	// 		count := task_children_count(task_goal)

	// 		// disallow our current to be inside this
	// 		if !(task_goal.index <= task_current.index && task_current.index <= task_goal.index + goal_count) {
	// 			goal_count += count
	// 		} 
	// 	}

	// 	// save current region
	// 	current_count := 1 + app.tasks_visible[high].index - app.tasks_visible[low].index // TODO maybe real indices?
	// 	total_low := task_goal.index
	// 	total_high := task_current.index + current_count
	// 	undo_push_shift_slice(manager, total_low, total_high)

	// 	// fmt.eprintln("current", current_count, goal_count)
	// 	// fmt.eprintln("totals", total_low, total_high)
	// 	// fmt.eprintln("indices", task_goal.index, task_current.index)

	// 	// copy to temp
	// 	c := app.mode_panel.children
	// 	temp := make([]^Element, goal_count, context.temp_allocator)
	// 	copy(temp, c[task_goal.index:task_goal.index + goal_count])

	// 	// copy selection to goal index
	// 	copy(c[task_goal.index:], c[task_current.index:task_current.index + current_count])

	// 	// copy temp to proper region
	// 	copy(c[task_goal.index + current_count:], temp)

	// 	// animate tasks that have a changed index
	// 	for i in total_low..<total_high {
	// 		task := app_task_filter(i)

	// 		if task.filter_index != i {
	// 			task_swap_animation(task)
	// 		}
	// 	}

	// 	app.task_head = weird_jump ? app.task_head + weird_count - 1 : app.task_head - 1
	// 	app.task_tail = weird_jump ? app.task_tail + weird_count - 1 : app.task_tail - 1
	// 	window_repaint(app.window_main)
	// }
}

todool_shift_down :: proc(du: u32) {
	// manager := mode_panel_manager_scoped()
	// task_head_tail_push(manager)
	// task_swap(manager, app.task_head, app.task_head + 1)
	x := app.task_head
	y := app.task_head + 1
	f := app.pool.filter
	f[x], f[y] = f[y], f[x]
	window_repaint(app.window_main)

	// if len(app.pool.filter) < 2 {
	// 	return
	// }

	// if app.task_head == app.task_tail {
	// 	shift_tasks_complex(false)
	// } else {
	// 	low, high := task_low_and_high()
	// 	goal_visible_index := high + 1

	// 	if goal_visible_index > len(app.pool.filter) - 1 {
	// 		return
	// 	}

	// 	manager := mode_panel_manager_scoped()
	// 	task_head_tail_push(manager)

	// 	task_goal := app.tasks_visible[goal_visible_index]
	// 	goal_count := 1
	// 	if task_goal.has_children && task_goal.folded {
	// 		// find lowest indentation to determine unfolding since we could be hidden
	// 		lowest_indentation := tasks_lowest_indentation(low, high)

	// 		// if item is higher indentation it means its a parent so we need to unfold
	// 		// and put not increase the goal count
	// 		if task_goal.indentation < lowest_indentation {
	// 			item := Undo_Item_Bool_Toggle { &task_goal.folded }
	// 			undo_bool_toggle(manager, &item)
	// 		} else {
	// 			goal_count += task_children_count(task_goal)
	// 		}
	// 	}

	// 	task_current := app.tasks_visible[low]

	// 	// save current region
	// 	current_count := 1 + app.tasks_visible[high].index - app.tasks_visible[low].index // TODO maybe real indices?
	// 	total_low := task_current.index
	// 	total_high := task_goal.index + goal_count
	// 	undo_push_shift_slice(manager, total_low, total_high)

	// 	// copy to temp
	// 	c := app.mode_panel.children
	// 	temp := make([]^Element, goal_count, context.temp_allocator)
	// 	copy(temp, c[task_goal.index:task_goal.index + goal_count])

	// 	// copy selection to goal index
	// 	copy(c[task_current.index + goal_count:], c[task_current.index:task_current.index + current_count])

	// 	// copy temp to proper region
	// 	copy(c[task_current.index:], temp)

	// 	// animate tasks that have a changed index
	// 	for i in total_low..<total_high {
	// 		task := app_task_filter(i)

	// 		if task.filter_index != i {
	// 			task_swap_animation(task)
	// 		}
	// 	}

	// 	app.task_head += task_goal.folded ? 1 : goal_count
	// 	app.task_tail += task_goal.folded ? 1 : goal_count
	// 	window_repaint(app.window_main)
	// }
}

todool_select_all :: proc(du: u32) {
	app.task_tail = 0
	app.task_head = len(app.pool.filter)
	window_repaint(app.window_main)
}

Undo_Item_Int_Set :: struct {
	value: ^int,
	to: int,
}

undo_int_set :: proc(manager: ^Undo_Manager, item: rawptr) {
	data := cast(^Undo_Item_Int_Set) item
	output := Undo_Item_Int_Set { data.value, data.value^ }
	data.value^ = data.to
	undo_push(manager, undo_int_set, &output, size_of(Undo_Item_Int_Set))
}

Undo_Item_Dirty_Increase :: struct {}

Undo_Item_Dirty_Decrease :: struct {}

undo_dirty_increase :: proc(manager: ^Undo_Manager, item: rawptr) {
	app.dirty += 1
	output := Undo_Item_Dirty_Decrease {}
	undo_push(manager, undo_dirty_decrease, &output, size_of(Undo_Item_Dirty_Decrease))
}

undo_dirty_decrease :: proc(manager: ^Undo_Manager, item: rawptr) {
	app.dirty -= 1
	output := Undo_Item_Dirty_Increase {}
	undo_push(manager, undo_dirty_increase, &output, size_of(Undo_Item_Dirty_Increase))
}

dirty_push :: proc(manager: ^Undo_Manager) {
	item := Undo_Item_Dirty_Increase {}
	undo_dirty_increase(manager, &item)
}

Undo_Item_Task_Head_Tail :: struct {
	head: int,
	tail: int,
}

undo_task_head_tail :: proc(manager: ^Undo_Manager, item: rawptr) {
	data := cast(^Undo_Item_Task_Head_Tail) item
	old_head := app.task_head
	old_tail := app.task_tail
	app.task_head = data.head
	app.task_tail = data.tail
	data.head = old_head
	data.tail = old_tail

	undo_push(manager, undo_task_head_tail, item, size_of(Undo_Item_Task_Head_Tail))
}

task_head_tail_push :: proc(manager: ^Undo_Manager) {
	item := Undo_Item_Task_Head_Tail {
		head = app.task_head,
		tail = app.task_tail,
	}
	undo_push(manager, undo_task_head_tail, &item, size_of(Undo_Item_Task_Head_Tail))
	dirty_push(manager)
}

Undo_Item_U8_XOR :: struct {
	value: ^u8,
	bit: u8,
}

undo_u8_xor :: proc(manager: ^Undo_Manager, item: rawptr) {
	data := cast(^Undo_Item_U8_XOR) item
	data.value^ ~= data.bit
	undo_push(manager, undo_u8_xor, item, size_of(Undo_Item_U8_XOR))
}

u8_xor_push :: proc(manager: ^Undo_Manager, value: ^u8, bit: u8) {
	item := Undo_Item_U8_XOR {
		value = value,
		bit = bit,
	}
	undo_u8_xor(manager, &item)
}

todool_toggle_tag :: proc(du: u32) {
	if app_filter_empty() {
		return
	}

	// check value
	value, ok := du_value(du)
	if !ok {
		return
	}
	bit := u8(value)
	
	manager := mode_panel_manager_scoped()
	task_head_tail_push(manager)

	iter := lh_iter_init()
	for task in lh_iter_step(&iter) {
		u8_xor_push(manager, &task.tags, bit)
	}

	window_repaint(app.window_main)
}

Undo_Item_Task_Swap :: struct {
	a, b: ^^Task,
}

task_indentation_set_animate :: proc(manager: ^Undo_Manager, task: ^Task, set: int) {
	item := Undo_Item_Task_Indentation_Set {
		task = task,
		set = task.indentation,
	}	
	undo_push(manager, undo_task_indentation_set, &item, size_of(Undo_Item_Task_Indentation_Set))

	task.indentation = set
	task.indentation_animating = true
	
	// TODO
	// task.folded = folded

	element_animation_start(task)
}

undo_task_swap :: proc(manager: ^Undo_Manager, item: rawptr) {
	data := cast(^Undo_Item_Task_Swap) item
	// a_folded := data.a^.folded
	// b_folded := data.b^.folded
	data.a^, data.b^ = data.b^, data.a^
	// data.a^.folded = a_folded
	// data.b^.folded = a_folded
	undo_push(manager, undo_task_swap, item, size_of(Undo_Item_Task_Swap))	
}

task_swap_animation :: proc(task: ^Task) {
	// if task.visible {
		task.top_offset = 0
		task.top_animation_start = true
		task.top_animating = true
		task.top_old = task.bounds.t
		element_animation_start(task)
	// }
}

// swap with +1 / -1 offset 
task_swap :: proc(manager: ^Undo_Manager, a, b: int) {
	aa := cast(^^Task) &app.pool.filter[a]
	bb := cast(^^Task) &app.pool.filter[b]
	item := Undo_Item_Task_Swap {
		a = aa,
		b = bb,
	}
	undo_task_swap(manager, &item)

	// or dont swap indentation? could be optional
	// animate the thing when visible
	task_swap_animation(aa^)
	task_swap_animation(bb^)

	window_repaint(app.window_main)
}

Undo_Item_Bool_Toggle :: struct {
	value: ^bool,
}

// inverse bool set
undo_bool_toggle :: proc(manager: ^Undo_Manager, item: rawptr) {
	data := cast(^Undo_Item_Bool_Toggle) item
	data.value^ = !data.value^
	undo_push(manager, undo_bool_toggle, item, size_of(Undo_Item_Bool_Toggle))
}

Undo_Item_U8_Set :: struct {
	value: ^u8,
	to: u8,
}

undo_u8_set :: proc(manager: ^Undo_Manager, item: rawptr) {
	data := cast(^Undo_Item_U8_Set) item
	old := data.value^
	data.value^ = data.to
	data.to = old
	undo_push(manager, undo_u8_set, item, size_of(Undo_Item_U8_Set))
	changelog_update_safe()
}

task_set_state_undoable :: proc(
	manager: ^Undo_Manager, 
	task: ^Task, 
	goal: Task_State,
	task_count: int,
) {
	if manager == nil {
		task.state = goal
	} else {
		item := Undo_Item_U8_Set {
			cast(^u8) &task.state,
			cast(u8) task.state,
		}
		undo_push(manager, undo_u8_set, &item, size_of(Undo_Item_U8_Set))
		task.state_last = task.state
		task.state = goal
		changelog_update_safe()

		// power mode spawn
		power_mode_spawn_along_task_text(task, task_count)

		task.state_unit = 1
		window_animate_forced(app.window_main, &task.state_unit, 0, .Quadratic_Out, time.Millisecond * 100)
	}
}

Undo_Item_Task_Indentation_Set :: struct {
	task: ^Task,
	set: int,
}

undo_task_indentation_set :: proc(manager: ^Undo_Manager, item: rawptr) {
	data := cast(^Undo_Item_Task_Indentation_Set) item
	old_indentation := data.task.indentation
	data.task.indentation = data.set
	data.task.indentation_smooth = f32(data.set)
	data.set = old_indentation
	undo_push(manager, undo_task_indentation_set, item, size_of(Undo_Item_Task_Indentation_Set))
}

Undo_Item_Task_Remove_At :: struct {
	filter_index: int,
	list_index: int,
}

Undo_Item_Task_Insert_At :: struct {
	filter_index: int,
	list_index: int,
	check_remove: bool,
}

task_remove_at_index :: proc(manager: ^Undo_Manager, task: ^Task) {
	item := Undo_Item_Task_Remove_At { task.filter_index, task.list_index }
	undo_task_remove_at(manager, &item)
}

undo_task_remove_at :: proc(manager: ^Undo_Manager, item: rawptr) {
	data := cast(^Undo_Item_Task_Remove_At) item
	
	output := Undo_Item_Task_Insert_At {
		data.filter_index,
		data.list_index,
		true,
	}
	
	task_pool_push_remove(&app.pool, data.list_index)
	ordered_remove(&app.pool.filter, data.filter_index)
	
	undo_push(manager, undo_task_insert_at, &output, size_of(Undo_Item_Task_Insert_At))
}

undo_task_insert_at :: proc(manager: ^Undo_Manager, item: rawptr) {
	data := cast(^Undo_Item_Task_Insert_At) item

	if data.check_remove {
		list_index := task_pool_pop_remove(&app.pool)
		assert(list_index == data.list_index)
	}
	inject_at(&app.pool.filter, data.filter_index, data.list_index)

	output := Undo_Item_Task_Remove_At {
		data.filter_index,
		data.list_index,
	}

	undo_push(manager, undo_task_remove_at, &output, size_of(Undo_Item_Task_Remove_At))
}

Undo_Item_Task_Append :: struct {
	list_index: int,
	check_remove: bool,
}

Undo_Item_Task_Pop :: struct {
	filler: bool,
}

undo_task_append :: proc(manager: ^Undo_Manager, item: rawptr) {
	data := cast(^Undo_Item_Task_Append) item

	if data.check_remove {
		list_index := task_pool_pop_remove(&app.pool)
		assert(list_index == data.list_index)
	}
	append(&app.pool.filter, data.list_index)

	output := Undo_Item_Task_Pop {}
	undo_push(manager, undo_task_pop, &output, size_of(Undo_Item_Task_Pop))
}

undo_task_pop :: proc(manager: ^Undo_Manager, item: rawptr) {
	task := app_task_filter(len(app.pool.filter) - 1)
	
	// gather the popped element before
	task_pool_push_remove(&app.pool, task.list_index)
	output := Undo_Item_Task_Append {
		task.list_index,
		true,
	}
	
	pop(&app.pool.filter)
	undo_push(manager, undo_task_append, &output, size_of(Undo_Item_Task_Append))
}

// Undo_Item_Task_Clear :: struct {
// 	old_length: int,
// }

// undo_task_clear :: proc(manager: ^Undo_Manager, item: rawptr) {
// 	data := cast(^Undo_Item_Task_Clear) item
// 	log.info("manager.state", manager.state, data.old_length)

// 	if manager.state == .Undoing {
// 		raw := cast(^mem.Raw_Dynamic_Array) &app.mode_panel.children
// 		raw.len = data.old_length
// 	} else {
// 		data.old_length = len(app.pool.filter)
// 		clear(&app.mode_panel.children)
// 	}

// 	undo_push(manager, undo_task_clear, item, size_of(Undo_Item_Task_Clear))
// }

Undo_Item_Task_Timestamp :: struct {
	task: ^Task,
}

undo_task_timestamp :: proc(manager: ^Undo_Manager, item: rawptr) {
	data := cast(^Undo_Item_Task_Timestamp) item
	defer undo_push(manager, undo_task_timestamp, item, size_of(Undo_Item_Task_Timestamp))

	task := data.task
	ss := &data.task.box.ss

	// check for existance
	if timing_timestamp_check(task_string(task)) != -1 {
		stamp, ok := timing_timestamp_extract(ss.buf[:TIMESTAMP_LENGTH])

		// if its already today, dont insert, otherwhise rewrite
		if timing_timestamp_is_today(stamp) && ok {
			// REMOVE on existing day
			copy(ss.buf[:], ss.buf[TIMESTAMP_LENGTH + 1:])
			ss.length -= TIMESTAMP_LENGTH + 1
			task.box.head = max(task.box.head - TIMESTAMP_LENGTH - 1, 0)
			task.box.tail = max(task.box.tail - TIMESTAMP_LENGTH - 1, 0)
			window_repaint(app.window_main)
			return
		} 
	} else {
		if int(ss.length) + TIMESTAMP_LENGTH + 1 < SS_SIZE {
			copy(ss.buf[TIMESTAMP_LENGTH + 1:], ss.buf[:])
			ss.length += TIMESTAMP_LENGTH + 1
		} else {
			// stop when out of bounds
			return
		}
	}

	task.box.head += TIMESTAMP_LENGTH + 1
	task.box.tail += TIMESTAMP_LENGTH + 1
	timing_bprint_timestamp(ss.buf[:TIMESTAMP_LENGTH + 1])
}

// removes selected region and pushes them to the undo stack
task_remove_selection :: proc(manager: ^Undo_Manager, move: bool) {
	iter := lh_iter_init()
	app.task_state_progression = .Update_Animated
	
	for i in 0..<iter.range {
		task := app_task_filter(iter.low)
		archive_push(ss_string(&task.box.ss)) // only valid

		item := Undo_Item_Task_Remove_At { task.filter_index - i, task.list_index }
		undo_task_remove_at(manager, &item)
	}

	if move {
		app.task_head = iter.low - 1
		app.task_tail = iter.low - 1
	}
}

todool_indentation_shift :: proc(du: u32) {
	amt := du_pos_neg(du)

	if app_filter_empty() || amt == 0 {
		return
	}

	// skip first
	if app.task_head == app.task_tail && app.task_head == 0 {
		return
	}

	manager := mode_panel_manager_scoped()
	task_head_tail_push(manager)

	iter := lh_iter_init()
	lowest := app_task_filter(max(iter.low - 1, 0))
	unfolded: bool
	app.task_state_progression = .Update_Animated

	for task in lh_iter_step(&iter) {
		if task.filter_index == 0 {
			continue
		}

		// TODO 
		// // unfold lowest parent
		// if amt > 0 && lowest.folded {
		// 	item := Undo_Item_Bool_Toggle { &lowest.folded }
		// 	undo_bool_toggle(manager, &item)
		// 	unfolded = true
		// }

		if task.indentation + amt >= 0 {
			task_indentation_set_animate(manager, task, task.indentation + amt)
		}
	}

	// hacky way to offset selection by unfolded content
	if unfolded {
		l, h := task_children_range(lowest)
		size := h - l
		range := iter.high - iter.low
		app.task_head += size - range + 1
		app.task_tail += size - range + 1
	}

	// set new indentation based task info and push state changes
	task_set_children_info()
	task_check_parent_states(manager)

	window_repaint(app.window_main)
}

todool_undo :: proc(du: u32) {
	manager := &app.um_task
	if !undo_is_empty(manager, false) {
		// reset bookmark index
		bs.current_index = -1

		undo_invoke(manager, false)
		app.task_state_progression = .Update_Instant
		window_repaint(app.window_main)
	}
}

todool_redo :: proc(du: u32) {
	manager := &app.um_task
	if !undo_is_empty(manager, true) {
		// reset bookmark index
		bs.current_index = -1

		undo_invoke(manager, true)
		app.task_state_progression = .Update_Instant
		window_repaint(app.window_main)
	}
}

todool_save :: proc(du: u32) {
	when DEMO_MODE {
		res := dialog_spawn(
			app.window_main, 
			350,
			"Saving is disabled in Demo Mode\n%l\n%f\n%C%B",
			"Okay",
			"Buy Now",
		)
		
		switch res {
			case "Okay": {}
			case "Buy Now": {
				open_link("https://skytrias.itch.io/todool")
			}
		}
	} else {
		force_dialog := du_bool(du)
		
		if force_dialog || len(app.last_save_location.buf) == 0 {
			// output: cstring
			default_path := gs_string_to_cstring(gs.pref_path)
			file_patterns := [?]cstring { "*.todool" }
			output := tfd.save_file_dialog("Save", default_path, file_patterns[:], "")
			app.window_main.raise_next = true

			if output != nil {
				last_save_set(string(output))
			} else {
				return
			}
		}

		err := editor_save(strings.to_string(app.last_save_location))
		if err != .None {
			log.info("SAVE: save.todool failed saving =", err)
		}

		// when anything was pushed - set to false
		if app.dirty != app.dirty_saved {
			app.dirty_saved = app.dirty
		}

		if !json_save_misc("save.sjson") {
			log.info("SAVE: save.sjson failed saving")
		}

		if !keymap_save("save.keymap") {
			log.info("SAVE: save.keymap failed saving")
		}

		window_repaint(app.window_main)
	}
}

// load
todool_load :: proc(du: u32) {
	default_path: cstring

	if len(app.last_save_location.buf) == 0 {
		default_path = gs_string_to_cstring(gs.base_path)
		// log.info("----")
	} else {
		trimmed_path := strings.to_string(app.last_save_location)

		for i := len(trimmed_path) - 1; i >= 0; i -= 1 {
			b := trimmed_path[i]
			if b == '/' {
				trimmed_path = trimmed_path[:i]
				break
			}
		}

		default_path = gs_string_to_cstring(strings.to_string(app.last_save_location))
	}

	file_patterns := [?]cstring { "*.todool" }
	output := tfd.open_file_dialog("Open", default_path, file_patterns[:])
	
	if app.window_main.fullscreened {
		window_hide(app.window_main)
		app.window_main.raise_next = true
	}

	if output == nil {
		return
	}

	// ask for save path after choosing the next "open" location
	// check for canceling loading
	if todool_check_for_saving(app.window_main) {
		return
	}

	last_save_set(string(output))
	err := editor_load(strings.to_string(app.last_save_location))

	if err != .None {
		log.info("LOAD: FAILED =", err)
	}

	window_repaint(app.window_main)
}

todool_toggle_bookmark :: proc(du: u32) {
	if app_filter_empty() {
		return
	}

	iter := lh_iter_init()
	for task in lh_iter_step(&iter) {
		if task.button_bookmark == nil {
			task_bookmark_init_check(task)
		} else {
			element_hide_toggle(task.button_bookmark)
		}
	}

	window_repaint(app.window_main)
}

// use this for simple panels instead of manually indexing for the text box
// which could lead to errors when rearranging or adding new elements
// could return nil
element_find_first_text_box :: proc(parent: ^Element) -> ^Text_Box {
	for child in parent.children {
		if child.message_class == text_box_message {
			return cast(^Text_Box) child
		}
	}

	return nil
}

todool_goto :: proc(du: u32) {
	p := app.panel_goto

	element_hide(p, false)
	app.goto_transition_unit = 1
	app.goto_transition_hide = false
	app.goto_transition_animating = true
	element_animation_start(p)

	box := element_find_first_text_box(p.panel)
	assert(box != nil)
	element_focus(app.window_main, box)

	app.goto_saved_task_head = app.task_head
	app.goto_saved_task_tail = app.task_tail

	// reset text
	ss_clear(&box.ss)
	box.head = 0
	box.tail = 0
}

todool_search :: proc(du: u32) {
	p := panel_search
	element_hide(p, false)

	// save info
	search.saved_task_head = app.task_head
	search.saved_task_tail = app.task_tail

	box := element_find_first_text_box(p)
	assert(box != nil)
	element_focus(app.window_main, box)

	if app_filter_not_empty() {
		task := app_task_head()

		// set word to search instantly
		if task.box.head != task.box.tail {
			// cut out selected word
			ds: cutf8.Decode_State
			low, high := box_low_and_high(task.box)
			text, ok := cutf8.ds_string_selection(
				&ds,
				ss_string(&task.box.ss),
				low, 
				high,
			)

			ss_set_string(&box.ss, text)
			search_update(text)
		}

		search.saved_box_head = task.box.head
		search.saved_box_tail = task.box.tail
	}		

	element_message(box, .Box_Set_Caret, BOX_SELECT_ALL)
}

issue_copy :: proc() {
	if !app.last_was_task_copy {
		window_repaint(app.window_main) // required to make redraw and copy 
	}
	app.last_was_task_copy = true
}

todool_duplicate_line :: proc(du: u32) {
	if app_filter_empty() {
		return
	}

	manager := mode_panel_manager_scoped()
	task_head_tail_push(manager)

	app.task_state_progression = .Update_Animated

	low, high := task_low_and_high()
	task := app_task_filter(high)
	diff := high - low + 1
	lowest_indentation := tasks_lowest_indentation(low, high)

	// temporarily copy and paste at the current location
	copy_temp := copy_state_init(mem.Kilobyte, diff + 1, context.temp_allocator)
	copy_state_copy_selection(&copy_temp, low, high)
	copy_state_paste_at(&copy_temp, manager, task.filter_index + 1, lowest_indentation)

	window_repaint(app.window_main)

	app.task_head += len(copy_temp.stored_tasks)
	app.task_tail += len(copy_temp.stored_tasks)
}

todool_copy_tasks :: proc(du: u32 = 0) {
	low, high := task_low_and_high()
	if copy_state_copy_selection(&app.copy_state, low, high) {
		issue_copy()
	}
}

todool_cut_tasks :: proc(du: u32 = 0) {
	if app_filter_empty() {
		return 
	}

	app.last_was_task_copy = true
	manager := mode_panel_manager_scoped()
	task_head_tail_push(manager)

	low, high := task_low_and_high()
	copy_state_copy_selection(&app.copy_state, low, high)
	task_remove_selection(manager, true)
	window_repaint(app.window_main)
}

todool_paste_tasks :: proc(du: u32 = 0) {
	if copy_state_empty(app.copy_state) {
		return
	}

	manager := mode_panel_manager_scoped()
	task_head_tail_push(manager)
	app.task_state_progression = .Update_Animated

	// no selection
	if app.task_head == -1 || app.task_head == app.task_tail {
		index, indentation := task_head_safe_index_indentation()
		copy_state_paste_at(&app.copy_state, manager, index + 1, indentation)
		
		app.task_head = max(app.task_head, 0) + len(app.copy_state.stored_tasks)
		app.task_tail = max(app.task_head, 0)
	} else {
		indentation := max(int)

		// get lowest indentation of removal selection
		{
			iter := lh_iter_init()
			for task in lh_iter_step(&iter) {
				indentation = min(indentation, task.indentation)
			}
		}

		task_remove_selection(manager, true)

		index, _ := task_head_safe_index_indentation()
		index += 1
		copy_state_paste_at(&app.copy_state, manager, index, indentation)
		
		app.task_head += len(app.copy_state.stored_tasks)
		app.task_tail = app.task_head
	}

	window_repaint(app.window_main)
}

todool_paste_tasks_from_clipboard :: proc(du: u32) {
	if clipboard_has_content() {
		clipboard_text := clipboard_get_with_builder()
		
		// indentation
		indentation_per_line := make([dynamic]u16, 0, 256, context.temp_allocator)

		// find indentation per line
		{
			text := clipboard_text
			for line in strings.split_lines_iterator(&text) {
				append(&indentation_per_line, u16(tabs_count(line)))
			}
		}

		manager := mode_panel_manager_scoped()
		task_head_tail_push(manager)

		// have to make this work for non task case
		task_index: int
		indentation: int
		
		if app_filter_not_empty() {
			low, high := task_low_and_high()
			highest_task := app_task_filter(high)
			task_index = highest_task.filter_index + 1
			indentation = highest_task.indentation
		}

		// insert line at correct index
		line_index: int
		text := clipboard_text
		for line in strings.split_lines_iterator(&text) {
			off := indentation_per_line[line_index]
			task_push_undoable(manager, indentation + int(off), strings.trim_space(line), task_index)
			task_index += 1
			line_index += 1
		}

		app.task_tail = app.task_head + 1
		app.task_head = app.task_head + line_index
		window_repaint(app.window_main)
	}
}

todool_center :: proc(du: u32) {
	if app_filter_not_empty() {
		cam := mode_panel_cam()
		cam.freehand = false
		cam_center_by_height_state(cam, app.mmpp.bounds, app.caret_rect.t)
	}
}

todool_tasks_to_uppercase :: proc(du: u32) {
	if app_filter_not_empty() {
		manager := mode_panel_manager_scoped()
		task_head_tail_push(manager)
		iter := lh_iter_init()

		for task in lh_iter_step(&iter) {
			ss := &task.box.ss
	
			if ss_has_content(ss) {
				item := Undo_String_Uppercased_Content { ss }
				undo_box_uppercased_content(manager, &item)
			}
		}

		window_repaint(app.window_main)
	}
}

todool_tasks_to_lowercase :: proc(du: u32) {
	if app_filter_not_empty() {
		manager := mode_panel_manager_scoped()
		task_head_tail_push(manager)
		iter := lh_iter_init()

		for task in lh_iter_step(&iter) {
			ss := &task.box.ss
	
			if ss_has_content(ss) {
				item := Undo_String_Lowercased_Content { ss }
				undo_box_lowercased_content(manager, &item)
			}
		}

		window_repaint(app.window_main)
	}
}

todool_new_file :: proc(du: u32) {
  if !todool_check_for_saving(app.window_main) {
	  tasks_load_reset()
	  last_save_set("")
  }
}

todool_check_for_saving :: proc(window: ^Window) -> (canceled: bool) {
	// ignore empty file saving
	if app_filter_empty() {
		return
	}

	when DEMO_MODE {
		return
	}

	if options_autosave() {
		todool_save(COMBO_FALSE)
	} else if app.dirty != app.dirty_saved {
		res := dialog_spawn(
			window, 
			300,
			"Save progress?\n%l\n%B%b%C",
			"Yes",
			"No",
			"Cancel",
		)
		
		switch res {
			case "Yes": {
				todool_save(COMBO_FALSE)
			}

			case "Cancel": {
				canceled = true
			}

			case "No": {}
		}
	}

	return
}

todool_select_children :: proc(du: u32) {
	if app_filter_empty() {
		return
	}

	if app.task_head == app.task_tail {
		task := app_task_head()

		if task.has_children {
			// TODO
			// if task.folded {
			// 	todool_toggle_folding()
			// 	// task_set_visible_tasks()
			// 	task_check_parent_states(nil)
			// }

			app.task_tail = app.task_head

			index := task.filter_index + 1
			for index < len(app.pool.filter) {
				t := app_task_filter(index)

				if t.indentation <= task.indentation {
					break
				}

				index += 1
			}

			app.task_head = index - 1
		}		
	} else {
		app.task_head, app.task_tail = app.task_tail, app.task_head
	}

	window_repaint(app.window_main)
}

// jumps to nearby state changes
todool_jump_nearby :: proc(du: u32) {
	shift := du_shift(du)

	if app_filter_empty() {
		return
	}

	task_current := app_task_head()

	for i in 0..<len(app.pool.filter) {
		index := shift ? (app.task_head - i - 1) : (i + app.task_head + 1)
		// wrap negative
		if index < 0 {
			index = len(app.pool.filter) + index
		}
		task := app_task_filter(index % len(app.pool.filter))
		
		if task.state != task_current.state {
			if task_head_tail_check_begin(shift) {
				app.task_head = task.filter_index
			}
			task_head_tail_check_end(shift)
			window_repaint(app.window_main)
			break
		}
	}
}

Undo_Item_Task_Sort :: struct {
	task_current: ^Task,
	from, to: int,
}

undo_task_sort :: proc(manager: ^Undo_Manager, item: rawptr) {
	// TODO
	// data := cast(^Undo_Item_Task_Sort) item
	
	// Task_Line :: struct {
	// 	task: ^Task,
	// 	children_from, children_to: i32,
	// }

	// sort_list := make([dynamic]Task_Line, 0, 64, context.temp_allocator)
	// children := make([dynamic]^Task, 0, 64, context.temp_allocator)

	// for i in data.from..<data.to + 1 {
	// 	task := app_task_filter(i)

	// 	// if the task has the same parent push to sort list
	// 	if task.visible_parent == data.task_current.visible_parent {
	// 		append(&sort_list, Task_Line {
	// 			task,
	// 			-1, 
	// 			0,
	// 		})
	// 	} else {
	// 		// set child location info per pushed child on the last task
	// 		last := &sort_list[len(sort_list) - 1]
	// 		child_index := i32(len(children))
	// 		if last.children_from == -1 {
	// 			last.children_from = child_index
	// 		}
	// 		last.children_to = child_index
	// 		append(&children, task)
	// 	}
	// }

	// cmp1 :: proc(a, b: Task_Line) -> bool {
	// 	return a.children_from == -1
	// }

	// cmp2 :: proc(a, b: Task_Line) -> bool {
	// 	return a.task.state < b.task.state
	// }

	// slice.stable_sort_by(sort_list[:], cmp1)
	// slice.stable_sort_by(sort_list[:], cmp2)

	// // prepare reversal
	// out := Undo_Item_Task_Sort_Original {
	// 	data.task_current,
	// 	data.from, 
	// 	data.to,
	// }
	// count := (data.to - data.from) + 1
	// bytes := undo_push(
	// 	manager, 
	// 	undo_task_sort_original, 
	// 	&out, 
	// 	size_of(Undo_Item_Task_Sort_Original) + count * size_of(^Task),
	// )
	// // actually save the data
	// bytes_root := cast(^^Task) &bytes[size_of(Undo_Item_Task_Sort_Original)]
	// storage := mem.slice_ptr(bytes_root, count)
	// // TODO just slice copy?
	// for i in 0..<count {
	// 	storage[i] = cast(^Task) app.mode_panel.children[i + data.from]
	// }

	// insert_offset: int
	// for i in 0..<len(sort_list) {
	// 	line := sort_list[i]
	// 	index := data.from + i + insert_offset
	// 	app.mode_panel.children[index] = line.task

	// 	if line.children_from != -1 {
	// 		local_index := index + 1
	// 		// fmt.eprintln("line", line.children_from, line.children_to)

	// 		for j in line.children_from..<line.children_to + 1 {
	// 			app.mode_panel.children[local_index] = children[j]
	// 			local_index += 1
	// 			insert_offset += 1
	// 			// fmt.eprintln("jjj", j)
	// 		}
	// 	}
	// }

	// window_repaint(app.window_main)
}

Undo_Item_Task_Sort_Original :: struct {
	task_current: ^Task,
	from, to: int,
	// ^Task data upcoming
}

undo_task_sort_original :: proc(manager: ^Undo_Manager, item: rawptr) {
	// TODO
	// data := cast(^Undo_Item_Task_Sort_Original) item

	// bytes_root := cast(^^Task) (uintptr(item) + size_of(Undo_Item_Task_Sort_Original))
	// count := data.to - data.from + 1
	// storage := mem.slice_ptr(bytes_root, count)	

	// // revert to unsorted data
	// for i in 0..<count {
	// 	app.mode_panel.children[i + data.from] = storage[i]
	// }

	// out := Undo_Item_Task_Sort {
	// 	data.task_current,
	// 	data.from,
	// 	data.to,
	// }
	// undo_push(manager, undo_task_sort, &out, size_of(Undo_Item_Task_Sort))
}

// idea:
// gather all children to be sorted [from:to] without sub children
// sort based on wanted properties
// replace existing tasks by new result + offset by sub children
todool_sort_locals :: proc(du: u32) {
	if app_filter_empty() {
		return
	}

	app.task_tail = app.task_head
	task_current := app_task_head()

	// skip high level
	from, to: int
	if task_current.visible_parent == nil {
		from = 0
		to = len(app.pool.filter) - 1
		// return
	} else {
		from, to = task_children_range(task_current.visible_parent)

		// skip invalid 
		if from == -1 || to == -1 {
			return
		}
	}

	manager := mode_panel_manager_scoped()
	task_head_tail_push(manager)
	
	item := Undo_Item_Task_Sort {
		task_current,
		from,
		to,
	}
	undo_task_sort(manager, &item)

	// update info and reset to last position
	task_set_children_info()
	// task_set_visible_tasks()
	app.task_head = task_current.filter_index
	app.task_tail = app.task_head
}

todool_scale :: proc(du: u32) {
	amt := f32(du_pos_neg(du)) * 0.1
	scaling_inc(amt)
	window_repaint(app.window_main)
}

todool_fullscreen_toggle :: proc(du: u32) {
	window_fullscreen_toggle(app.window_main)
}

// set mode and issue repaint on change
VIM :: proc(insert: bool) {
	old := vim.insert_mode
	vim.insert_mode = insert

	if old != insert {
		statusbar.vim_panel.color = insert ? &theme.text_bad : &theme.text_good
		window_repaint(app.window_main)
	}
}

vim_insert_mode_set :: proc(du: u32) {
	VIM(true)
}

vim_normal_mode_set :: proc(du: u32) {
	VIM(false)
}

// I, insert mode & box to beginning
vim_insert_mode_beginning :: proc(du: u32) {
	VIM(true)
	kbox.box.head = 0
	box_check_shift(kbox.box, false)
}

vim_insert_below :: proc(du: u32) {
	VIM(true)
	todool_insert_sibling(COMBO_EMPTY)
}

vim_insert_above :: proc(du: u32) {
	VIM(true)
	todool_insert_sibling(COMBO_SHIFT)
}

vim_move_up :: proc(du: u32) {
	todool_move_up(du)
}

vim_move_down :: proc(du: u32) {
	todool_move_down(du)
}

vim_visual_move_left :: proc(du: u32) {
	if app_filter_empty() {
		return
	}

	switch app.mmpp.mode {
		case .Kanban: {
			current := app_task_head()
			b := current.bounds
			closest_task: ^Task
			closest_distance := max(f32)
			middle := b.t + rect_height_halfed(b)

			if vim_visual_reptition_check(current, -1) {
				return
			}

			// find closest distance
			for index in app.pool.filter {
				task := app_task_list(index)
				if task.bounds.r < b.l {
					dist_x := task.bounds.r - b.l 
					dist_y := (task.bounds.t + rect_height_halfed(task.bounds)) - middle
					temp := f32(dist_x * dist_x) + f32(dist_y * dist_y)

					if temp < closest_distance {
						closest_distance = temp
						closest_task = task
					}
				}
			}

			if closest_task != nil {
				app.task_head = closest_task.filter_index
				app.task_tail = closest_task.filter_index
				window_repaint(app.window_main)
				
				vim_visual_reptition_set(current, 1)
			}
		}

		case .List: {
			todool_move_down(COMBO_EMPTY)
		}
	}
}

vim_visual_move_right :: proc(du: u32) {
	if app_filter_empty() {
		return
	}

	switch app.mmpp.mode {
		case .Kanban: {
			current := app_task_head()
			b := current.bounds
			closest_task: ^Task
			closest_distance := max(f32)
			middle := b.t + rect_height_halfed(b)

			if vim_visual_reptition_check(current, 1) {
				return
			}

			// find closest distance
			for index in app.pool.filter {
				task := app_task_list(index)
				if b.r < task.bounds.r {
					dist_x := task.bounds.l - b.r 
					dist_y := (task.bounds.t + rect_height_halfed(task.bounds)) - middle
					temp := f32(dist_x * dist_x) + f32(dist_y * dist_y)

					if temp < closest_distance {
						closest_distance = temp
						closest_task = task
					}
				}
			}

			if closest_task != nil {
				app.task_head = closest_task.filter_index
				app.task_tail = closest_task.filter_index
				window_repaint(app.window_main)

				vim_visual_reptition_set(current, -1)
			}
		}

		case .List: {
			todool_move_up(COMBO_EMPTY)
		}
	}
}

vim_visual_reptition_set :: proc(task: ^Task, direction: int) {
	vim.rep_task = task
	vim.rep_direction = direction
	cam := mode_panel_cam()
	vim.rep_cam_x = cam.offset_x
	vim.rep_cam_y = cam.offset_y
}

// NOTE this is for speedup & sane traversal
// repition will break once you move around the tasks 
// moves to the last repeated task when we keep reversing back and forth
vim_visual_reptition_check :: proc(task: ^Task, direction: int) -> bool {
	// fmt.eprintln(vim.rep_direction, direction)

	// TODO clear checked
	// if vim.rep_task != nil || vim.rep_direction == 0 {
	// 	if direction == vim.rep_direction {
	// 		// need to check if the task is still inside the tasks visible, in case it was deleted
	// 		if vim.rep_task in app.task_clear_checking {
	// 			found: bool
	// 			for task in app.tasks_visible {
	// 				if task == vim.rep_task {
	// 					found = true
	// 					break
	// 				}
	// 			}

	// 			if !found {
	// 				return false
	// 			}
	// 		}

	// 		vim.rep_direction *= -1
	// 		app.task_head = vim.rep_task.filter_index
	// 		app.task_tail = vim.rep_task.filter_index
	// 		vim.rep_task = task

	// 		// cam := mode_panel_cam()
	// 		// if visuals_use_animations() {
	// 		// 	element_animation_start(app.mode_panel)
	// 		// 	cam.ax.animating = true
	// 		// 	cam.ax.direction = CAM_CENTER
	// 		// 	cam.ax.goal = int(vim.rep_cam_x)
				
	// 		// 	cam.ay.animating = true
	// 		// 	cam.ay.direction = CAM_CENTER
	// 		// 	cam.ay.goal = int(vim.rep_cam_y)
	// 		// } else {
	// 		// 	cam.offset_x = vim.rep_cam_x
	// 		// 	cam.offset_y = vim.rep_cam_y
	// 		// }
	// 		// cam.freehand = false

	// 		window_repaint(app.window_main)
	// 		return true
	// 	}
	// }

	return false
}

todool_toggle_progressbars :: proc(du: u32) {
	check := sb.options.checkbox_progressbar_show
	
	if check != nil {
		checkbox_set(check, !check.state)
		element_repaint(check)
	}
}

todool_toggle_timestamp :: proc(du: u32) {
	if app_filter_empty() {
		return
	}

	iter := lh_iter_init()
	for task in lh_iter_step(&iter) {
		task_set_time_date(task)
	}

	window_repaint(app.window_main)
}
