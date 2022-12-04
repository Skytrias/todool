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
	if task_head == -1 {
		return
	}

	task := tasks_visible[task_head]
	
	if int(task.box.ss.length) == 0 {
		manager := mode_panel_manager_scoped()
		task_head_tail_push(manager)
		task_state_progression = .Update_Animated
		index := task.index
		
		if index == len(mode_panel.children) {
			item := Undo_Item_Task_Pop {}
			undo_task_pop(manager, &item)
		} else {
			task_remove_at_index(manager, index)
		}

		element_repaint(task)
		task_head -= 1
		task_tail -= 1
	}
}

todool_move_up :: proc(du: u32) {
	if task_head == -1 {
		return
	}

	shift := du_shift(du)
	if task_head_tail_check_begin(shift) {
		task_head -= 1
	}
	task_head_tail_check_end(shift)
	bs.current_index = -1
	task := tasks_visible[max(task_head, 0)]
	element_repaint(mode_panel)
	element_message(task.box, .Box_Set_Caret, BOX_END)

	vim.rep_task = nil
}

todool_move_down :: proc(du: u32) {
	if task_head == -1 {
		return 
	}

	shift := du_shift(du)
	if task_head_tail_check_begin(shift) {
		task_head += 1
	}
	task_head_tail_check_end(shift)
	bs.current_index = -1

	task := tasks_visible[min(task_head, len(tasks_visible) - 1)]
	element_message(task.box, .Box_Set_Caret, BOX_END)
	element_repaint(mode_panel)

	vim.rep_task = nil
}

todool_move_up_stack :: proc(du: u32) {
	if task_head == -1 {
		return
	}

	// fill stack when jumping out
	task := tasks_visible[task_head]
	p := task
	for p != nil {
		task_move_stack[p.indentation] = p
		p = p.visible_parent
	}

	if task.indentation > 0 {
		goal := task_move_stack[task.indentation - 1]
		shift := du_shift(du)
		if task_head_tail_check_begin(shift) {
			task_head = goal.visible_index
		}
		task_head_tail_check_end(shift)

		task = tasks_visible[task_head]
		element_message(task.box, .Box_Set_Caret, BOX_END)
		element_repaint(mode_panel)

		vim.rep_task = nil
	}
}

todool_move_down_stack :: proc(du: u32) {
	if task_head == -1 {
		return
	}

	task := tasks_visible[task_head]
	goal := task_move_stack[task.indentation + 1]

	if goal != nil {
		shift := du_shift(du)
		if task_head_tail_check_begin(shift) {
			if goal.visible_index < len(tasks_visible) {
				task_head = goal.visible_index
			}
		}
		task_head_tail_check_end(shift)

		task = tasks_visible[task_head]
		element_message(task.box, .Box_Set_Caret, BOX_END)
		element_repaint(mode_panel)		

		vim.rep_task = nil
	}
}

todool_indent_jump_low_prev :: proc(du: u32) {
	if task_head == -1 {
		return
	}

	task_current := tasks_visible[task_head]
	shift := du_shift(du)
	
	for i := task_current.index - 1; i >= 0; i -= 1 {
		task := cast(^Task) mode_panel.children[i]

		if task.indentation == 0 && task.visible {
			if task_head_tail_check_begin(shift) {
				task_head = task.visible_index
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
	if task_head == -1 {
		return
	}

	task_current := tasks_visible[task_head]
	shift := du_shift(du)

	for i in task_current.index + 1..<len(mode_panel.children) {
		task := cast(^Task) mode_panel.children[i]

		if task.indentation == 0 && task.visible {
			if task_head_tail_check_begin(shift) {
				task_head = task.visible_index
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
	task_current := tasks_visible[visible_index]

	for i := visible_index - 1; i >= 0; i -= 1 {
		task := tasks_visible[i]
		
		if task.indentation == task_current.indentation {
			res = i
			return
		}
	}

	return
}

todool_indent_jump_same_prev :: proc(du: u32) {
	if task_head == -1 {
		return
	}

	task_current := tasks_visible[task_head]
	shift := du_shift(du)
	goal := find_same_indentation_backwards(task_head)
	
	if goal != -1 {
		if task_head_tail_check_begin(shift) {
			task_head = goal
		}
		task_head_tail_check_end(shift)
		element_repaint(mode_panel)
		element_message(tasks_visible[task_head].box, .Box_Set_Caret, BOX_END)		
	}

	vim.rep_task = nil
}

todool_indent_jump_same_next :: proc(du: u32) {
	if task_head == -1 {
		return
	}

	task_current := tasks_visible[task_head]
	shift := du_shift(du)

	for i := task_head + 1; i < len(tasks_visible); i += 1 {
		task := tasks_visible[i]
		
		if task.indentation == task_current.indentation {
			if task_head_tail_check_begin(shift) {
				task_head = i
			}
			task_head_tail_check_end(shift)
			element_repaint(mode_panel)
			element_message(task.box, .Box_Set_Caret, BOX_END)
			break
		}
	} 

	vim.rep_task = nil
}

todool_bookmark_jump :: proc(du: u32) {
	shift := du_shift(du)
	
	if len(bs.rows) != 0 && len(tasks_visible) != 0 {
		bookmark_advance(shift)
		task := bs.rows[bs.current_index]
		task_head = task.visible_index
		task_tail = task.visible_index
		element_repaint(mode_panel)
		vim.rep_task = nil

		bs.alpha = 1
		window_animate(window_main, &bs.alpha, 0, .Quadratic_Out, time.Second * 2)
	}
}

todool_delete_tasks :: proc(du: u32 = 0) {
	if task_head == -1 {
		return
	}

	manager := mode_panel_manager_scoped()
	task_state_progression = .Update_Animated
	task_head_tail_push(manager)
	task_remove_selection(manager, true)
	element_repaint(mode_panel)
}

todool_copy_tasks_to_clipboard :: proc(du: u32) {
	if task_head == -1 {
		return
	}

	b := &gs.copy_builder
	strings.builder_reset(b)
	low, high := task_low_and_high()

	// get lowest
	lowest_indentation := max(int)
	for i in low..<high + 1 {
		task := tasks_visible[i]
		lowest_indentation = min(lowest_indentation, task.indentation)
	}

	// write text into buffer
	for i in low..<high + 1 {
		task := tasks_visible[i]
		relative_indentation := task.indentation - lowest_indentation
		task_write_text_indentation(b, task, relative_indentation)
	}

	last_was_task_copy = false
	clipboard_set_with_builder_prefilled()
	element_repaint(mode_panel)
	// fmt.eprint(strings.to_string(b))
}

todool_change_task_selection_state_to :: proc(state: Task_State) {
	if task_head == -1 {
		return
	}

	manager := mode_panel_manager_scoped()
	task_head_tail_push(manager)
	iter := ti_init()

	task_state_progression = .Update_Animated
	task_count: int

	for task in ti_step(&iter) {
		task_set_state_undoable(manager, task, state, task_count)
		task_count += 1
	}
}

todool_change_task_state :: proc(du: u32) {
	if false {}

	if task_head == -1 {
		return
	}

	shift := du_shift(du)
	manager := mode_panel_manager_scoped()
	task_head_tail_push(manager)
	iter := ti_init()
	index: int

	// modify all states
	task_state_progression = .Update_Animated
	task_count: int
	for task in ti_step(&iter) {
		index = int(task.state)
		range_advance_index(&index, len(Task_State) - 1, shift)
		// save old set
		task_set_state_undoable(manager, task, Task_State(index), task_count)
		task_count += 1
	}

	element_repaint(mode_panel)
}

todool_indent_jump_scope :: proc(du: u32) {
	if task_head == -1 {
		return
	}

	task_current := tasks_visible[task_head]
	defer element_repaint(mode_panel)
	shift := du_shift(du)

	// skip indent search at higher levels, just check for 0
	if task_current.indentation == 0 {
		// search for first indent 0 at end
		for i := len(tasks_visible) - 1; i >= 0; i -= 1 {
			current := tasks_visible[i]

			if current.indentation == 0 {
				if i == task_head {
					break
				}

				task_head_tail_check_begin(shift)
				task_head = i
				task_head_tail_check_end(shift)
				return
			}
		}

		// search for first indent at 0 
		for i in 0..<len(tasks_visible) {
			current := tasks_visible[i]

			if current.indentation == 0 {
				task_head_tail_check_begin(shift)
				task_head = i
				task_head_tail_check_end(shift)
				break
			}
		}
	} else {
		// check for end first
		last_good := task_head
		for i in task_head + 1..<len(tasks_visible) {
			next := tasks_visible[i]

			if next.indentation == task_current.indentation {
				last_good = i
			}

			if next.indentation < task_current.indentation || i + 1 == len(tasks_visible) {
				if last_good == task_head {
					break
				}

				task_head_tail_check_begin(shift)
				task_head = last_good
				task_head_tail_check_end(shift)
				return
			}
		}

		// move backwards
		last_good = -1
		for i := task_head - 1; i >= 0; i -= 1 {
			prev := tasks_visible[i]

			if prev.indentation == task_current.indentation {
				last_good = i
			}

			if prev.indentation < task_current.indentation {
				task_head_tail_check_begin(shift)
				task_head = last_good
				task_head_tail_check_end(shift)
				break
			}
		}
	}
}

todool_selection_stop :: proc(du: u32) {
	if task_has_selection() {
		task_tail = task_head
		element_repaint(mode_panel)
	}	
}

todool_escape :: proc(du: u32) {
	if image_display_has_content_now(custom_split.image_display) {
		custom_split.image_display.img = nil
		element_repaint(mode_panel)
		return
	}

	if element_hide(sb.enum_panel, true) {
		element_repaint(mode_panel)
		return
	}

	// reset selection
	if task_head != task_tail {
		task_tail = task_head
		element_repaint(mode_panel)
		return
	}
}

todool_toggle_folding :: proc(du: u32 = 0) {
	if task_head == -1 {
		return
	}

	task := tasks_visible[task_head]
	manager := mode_panel_manager_scoped()

	if task.has_children {
		task_head_tail_push(manager)
		item := Undo_Item_Bool_Toggle { &task.folded }
		undo_bool_toggle(manager, &item)
		
		task_tail = task_head
		element_repaint(mode_panel)
	}
}

todool_insert_sibling :: proc(du: u32) {
	manager := mode_panel_manager_scoped()
	task_head_tail_push(manager)
	shift := du_shift(du)
	
	task_state_progression = .Update_Animated
	indentation: int
	goal: int
	if shift {
		// above / same line
		if task_head != -1 && task_head > 0 {
			goal = tasks_visible[task_head].index
			indentation = tasks_visible[task_head].indentation
		}

		task_tail = task_head
	} else {
		// next line
		goal = len(mode_panel.children) // default append
		if task_head < len(tasks_visible) - 1 {
			goal = tasks_visible[task_head + 1].index
		}

		if task_head != -1 {
			indentation = tasks_visible[task_head].indentation
		}
	
		task_head += 1
	}

	task_push_undoable(manager, indentation, "", goal)
	task_head_tail_check_end(shift)
	element_repaint(mode_panel)
}

todool_insert_child :: proc(du: u32) {
	indentation: int
	goal := len(mode_panel.children) // default append
	manager := mode_panel_manager_scoped()
	task_head_tail_push(manager)
	shift := du_shift(du)
	task_state_progression = .Update_Animated

	if task_head < len(tasks_visible) - 1 {
		goal = tasks_visible[task_head + 1].index
	}
	jump := 1

	if task_head != -1 {
		current_task := tasks_visible[task_head]
		indentation = current_task.indentation + 1
		ss := &current_task.box.ss

		// uppercase word
		if !current_task.has_children && options_uppercase_word() && ss_has_content(ss) {
			item := Undo_String_Uppercased_Content { ss }
			undo_box_uppercased_content(manager, &item)
		}

		// unfold current task if its folded 
		if current_task.folded {
			count := task_children_count(current_task)
			item := Undo_Item_Bool_Toggle { &current_task.folded }
			undo_bool_toggle(manager, &item)
			goal = current_task.index + 1
		}
	}

	task_push_undoable(manager, indentation, "", goal)
	task_head += jump
	task_head_tail_check_end(shift)
	element_repaint(mode_panel)
}

todool_mode_list :: proc(du: u32) {
	if mode_panel.mode != .List {
		mode_panel.mode = .List
		custom_split_set_scrollbars(custom_split)
		element_repaint(mode_panel)
		power_mode_clear()
	}
}

todool_mode_kanban :: proc(du: u32) {
	if mode_panel.mode != .Kanban {
		mode_panel.mode = .Kanban
		custom_split_set_scrollbars(custom_split)
		element_repaint(mode_panel)
		power_mode_clear()
	}
}

todool_shift_down :: proc(du: u32) {
	low, high := task_low_and_high()
	if task_head == -1 || high + 1 >= len(tasks_visible) {
		return
	}

	fmt.eprintln("UNIMPLEMENTED")

	// manager := mode_panel_manager_scoped()
	// task_head_tail_push(manager)

	// task_state_progression = .Update_Animated
	// for i := high + 1; i > low; i -= 1 {
	// 	x, y := task_xy_to_real(i, i - 1)
	// 	task_swap(manager, x, y)
	// }

	// task_head += 1
	// task_tail += 1
	// element_repaint(mode_panel)
}

todool_shift_up :: proc(du: u32) {
	if len(tasks_visible) < 2 {
		return
	}

	low, high := task_low_and_high()

	// save highest index before pops
	highest_count := 1
	{
		highest := tasks_visible[high]
		if highest.has_children {
			count := task_children_count(highest)
			highest_count += count
		}
	}

	goal_visible_index := find_same_indentation_backwards(low)
	if goal_visible_index == -1 {
		return
	}

	// gather lowest nodes
	goal := tasks_visible[goal_visible_index]
	goal_count := 1
	if goal.has_children {
		goal_count += task_children_count(goal)
	}
	
	// TODO better memory allocation technique? scratch buffer
	temp := make([]^Element, goal_count)
	defer delete(temp)

	// copy all to the slice
	fmt.eprintln("LOW", goal.index, goal.index + goal_count)
	copy(temp, mode_panel.children[goal.index:goal.index + goal_count])

	// find selection count
	selection_count: int
	{
		a := tasks_visible[low].index
		b := tasks_visible[high].index
		selection_count = b - a + highest_count
	}
	fmt.eprintln(selection_count)

	// copy selection to goal index
	{
		lowest_index := tasks_visible[low].index
		copy(
			mode_panel.children[goal.index:], 
			mode_panel.children[lowest_index:lowest_index + selection_count],
		)
	}

	// copy temp to proper region
	{
		copy(
			mode_panel.children[goal.index + selection_count:], 
			temp,
		)
	}

	// manager := mode_panel_manager_scoped()
	// task_head_tail_push(manager)

	for i in 0..<len(mode_panel.children) {
		task := cast(^Task) mode_panel.children[i]

		if task.index != i {
			task_swap_animation(task)
		}
	}

	fmt.eprintln("DONE")

	task_head -= goal.folded ? 1 : goal_count
	task_tail -= goal.folded ? 1 : goal_count
}

todool_select_all :: proc(du: u32) {
	task_tail = 0
	task_head = len(tasks_visible)
	element_repaint(mode_panel)
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
	dirty += 1
	output := Undo_Item_Dirty_Decrease {}
	undo_push(manager, undo_dirty_decrease, &output, size_of(Undo_Item_Dirty_Decrease))
}

undo_dirty_decrease :: proc(manager: ^Undo_Manager, item: rawptr) {
	dirty -= 1
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
	old_head := task_head
	old_tail := task_tail
	task_head = data.head
	task_tail = data.tail
	data.head = old_head
	data.tail = old_tail

	undo_push(manager, undo_task_head_tail, item, size_of(Undo_Item_Task_Head_Tail))
}

task_head_tail_push :: proc(manager: ^Undo_Manager) {
	item := Undo_Item_Task_Head_Tail {
		head = task_head,
		tail = task_tail,
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
	if task_head == -1 {
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

	iter := ti_init()
	for task in ti_step(&iter) {
		u8_xor_push(manager, &task.tags, bit)
	}

	element_repaint(mode_panel)
}

Undo_Item_Task_Swap :: struct {
	a, b: ^^Task,
}

task_indentation_set_animate :: proc(manager: ^Undo_Manager, task: ^Task, set: int, folded: bool) {
	item := Undo_Item_Task_Indentation_Set {
		task = task,
		set = task.indentation,
	}	
	undo_push(manager, undo_task_indentation_set, &item, size_of(Undo_Item_Task_Indentation_Set))

	task.indentation = set
	task.indentation_animating = true
	task.folded = folded
	element_animation_start(task)
}

undo_task_swap :: proc(manager: ^Undo_Manager, item: rawptr) {
	data := cast(^Undo_Item_Task_Swap) item
	a_folded := data.a^.folded
	b_folded := data.b^.folded
	data.a^, data.b^ = data.b^, data.a^
	data.a^.folded = a_folded
	data.b^.folded = a_folded
	undo_push(manager, undo_task_swap, item, size_of(Undo_Item_Task_Swap))	
}

task_swap_animation :: proc(task: ^Task) {
	if task.visible {
		task.top_offset = 0
		task.top_animation_start = true
		task.top_animating = true
		task.top_old = task.bounds.t
		element_animation_start(task)
	}
}

// swap with +1 / -1 offset 
task_swap :: proc(manager: ^Undo_Manager, a, b: int) {
	aa := cast(^^Task) &mode_panel.children[a]
	bb := cast(^^Task) &mode_panel.children[b]
	item := Undo_Item_Task_Swap {
		a = aa,
		b = bb,
	}
	undo_task_swap(manager, &item)

	// or dont swap indentation? could be optional
	// animate the thing when visible
	task_swap_animation(aa^)
	task_swap_animation(bb^)

	element_repaint(mode_panel)
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
		window_animate_forced(window_main, &task.state_unit, 0, .Quadratic_Out, time.Millisecond * 100)
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
	index: int,
	task: ^Task,
}

Undo_Item_Task_Insert_At :: struct {
	index: int,
	task: ^Task, // the task you want to insert
}

task_remove_at_index :: proc(manager: ^Undo_Manager, index: int) {
	item := Undo_Item_Task_Remove_At { index, cast(^Task) mode_panel.children[index] }
	undo_task_remove_at(manager, &item)
}

undo_task_remove_at :: proc(manager: ^Undo_Manager, item: rawptr) {
	data := cast(^Undo_Item_Task_Remove_At) item
	
	output := Undo_Item_Task_Insert_At {
		data.index, 
		data.task,
	} 

	// TODO maybe speedup somehow?
	ordered_remove(&mode_panel.children, data.index)
	undo_push(manager, undo_task_insert_at, &output, size_of(Undo_Item_Task_Insert_At))
	task_clear_checking[data.task] = 1
}

undo_task_insert_at :: proc(manager: ^Undo_Manager, item: rawptr) {
	data := cast(^Undo_Item_Task_Insert_At) item
	inject_at(&mode_panel.children, data.index, data.task)

	output := Undo_Item_Task_Remove_At { data.index, data.task }
	undo_push(manager, undo_task_remove_at, &output, size_of(Undo_Item_Task_Remove_At))
}

Undo_Item_Task_Append :: struct {
	task: ^Task,
}

Undo_Item_Task_Pop :: struct {
	task: ^Task,
}

undo_task_append :: proc(manager: ^Undo_Manager, item: rawptr) {
	data := cast(^Undo_Item_Task_Append) item
	append(&mode_panel.children, data.task)
	output := Undo_Item_Task_Pop { data.task }
	undo_push(manager, undo_task_pop, &output, size_of(Undo_Item_Task_Pop))
}

undo_task_pop :: proc(manager: ^Undo_Manager, item: rawptr) {
	data := cast(^Undo_Item_Task_Pop) item
	// gather the popped element before
	output := Undo_Item_Task_Append { 
		cast(^Task) mode_panel.children[len(mode_panel.children) - 1],
	}
	pop(&mode_panel.children)
	undo_push(manager, undo_task_append, &output, size_of(Undo_Item_Task_Append))
}

// Undo_Item_Task_Clear :: struct {
// 	old_length: int,
// }

// undo_task_clear :: proc(manager: ^Undo_Manager, item: rawptr) {
// 	data := cast(^Undo_Item_Task_Clear) item
// 	log.info("manager.state", manager.state, data.old_length)

// 	if manager.state == .Undoing {
// 		raw := cast(^mem.Raw_Dynamic_Array) &mode_panel.children
// 		raw.len = data.old_length
// 	} else {
// 		data.old_length = len(mode_panel.children)
// 		clear(&mode_panel.children)
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
			window_repaint(window_main)
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
	iter := ti_init()
	
	task_state_progression = .Update_Animated
	for i in 0..<iter.range {
		task := cast(^Task) mode_panel.children[iter.offset]
		archive_push(ss_string(&task.box.ss)) // only valid
		task_remove_at_index(manager, iter.offset)
	}

	if move {
		task_head = iter.low - 1
		task_tail = iter.low - 1
	}
}

// copy selected tasks
copy_selection :: proc() -> bool {
	if task_head != -1 {
		copy_reset()
		low, high := task_low_and_high()

		// copy each line
		for i in low..<high + 1 {
			task := tasks_visible[i]
			copy_push_task(task)
		}

		return true
	}

	return false
}

todool_indentation_shift :: proc(du: u32) {
	amt := du_pos_neg(du)

	if task_head == -1 || amt == 0 {
		return
	}

	// skip first
	if task_head == task_tail && task_head == 0 {
		return
	}

	manager := mode_panel_manager_scoped()
	task_head_tail_push(manager)
	iter := ti_init()

	lowest := tasks_visible[max(iter.low - 1, 0)]
	unfolded: bool
	task_state_progression = .Update_Animated

	for task in ti_step(&iter) {
		if task.index == 0 {
			continue
		}

		// unfold lowest parent
		if amt > 0 && lowest.folded {
			item := Undo_Item_Bool_Toggle { &lowest.folded }
			undo_bool_toggle(manager, &item)
			unfolded = true
		}

		if task.indentation + amt >= 0 {
			task_indentation_set_animate(manager, task, task.indentation + amt, task.folded)
		}
	}

	// hacky way to offset selection by unfolded content
	if unfolded {
		l, h := task_children_range(lowest)
		size := h - l
		task_head += size - iter.range + 1
		task_tail += size - iter.range + 1
	}

	// set new indentation based task info and push state changes
	task_set_children_info()
	task_check_parent_states(manager)

	element_repaint(mode_panel)
}

todool_undo :: proc(du: u32) {
	manager := &um_task
	if !undo_is_empty(manager, false) {
		// reset bookmark index
		bs.current_index = -1

		undo_invoke(manager, false)
		task_state_progression = .Update_Instant
		element_repaint(mode_panel)
	}
}

todool_redo :: proc(du: u32) {
	manager := &um_task
	if !undo_is_empty(manager, true) {
		// reset bookmark index
		bs.current_index = -1

		undo_invoke(manager, true)
		task_state_progression = .Update_Instant
		element_repaint(mode_panel)
	}
}

todool_save :: proc(du: u32) {
	when DEMO_MODE {
		res := dialog_spawn(
			window_main, 
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
		
		if force_dialog || len(last_save_location.buf) == 0 {
			// output: cstring
			default_path := gs_string_to_cstring(gs.pref_path)
			file_patterns := [?]cstring { "*.todool" }
			output := tfd.save_file_dialog("Save", default_path, file_patterns[:], "")
			window_main.raise_next = true

			if output != nil {
				last_save_set(string(output))
			} else {
				return
			}
		}

		err := editor_save(strings.to_string(last_save_location))
		if err != .None {
			log.info("SAVE: save.todool failed saving =", err)
		}

		// when anything was pushed - set to false
		if dirty != dirty_saved {
			dirty_saved = dirty
		}

		if !json_save_misc("save.sjson") {
			log.info("SAVE: save.sjson failed saving")
		}

		if !keymap_save("save.keymap") {
			log.info("SAVE: save.keymap failed saving")
		}

		element_repaint(mode_panel)
	}
}

// load
todool_load :: proc(du: u32) {
	default_path: cstring

	if len(last_save_location.buf) == 0 {
		default_path = gs_string_to_cstring(gs.base_path)
		// log.info("----")
	} else {
		trimmed_path := strings.to_string(last_save_location)

		for i := len(trimmed_path) - 1; i >= 0; i -= 1 {
			b := trimmed_path[i]
			if b == '/' {
				trimmed_path = trimmed_path[:i]
				break
			}
		}

		default_path = gs_string_to_cstring(strings.to_string(last_save_location))
	}

	file_patterns := [?]cstring { "*.todool" }
	output := tfd.open_file_dialog("Open", default_path, file_patterns[:])
	
	if window_main.fullscreened {
		window_hide(window_main)
		window_main.raise_next = true
	}

	if output == nil {
		return
	}

	// ask for save path after choosing the next "open" location
	// check for canceling loading
	if todool_check_for_saving(window_main) {
		return
	}

	last_save_set(string(output))
	err := editor_load(strings.to_string(last_save_location))

	if err != .None {
		log.info("LOAD: FAILED =", err)
	}

	element_repaint(mode_panel)
}

todool_toggle_bookmark :: proc(du: u32) {
	if task_head == -1 {
		return
	}

	low, high := task_low_and_high()

	for i in low..<high + 1 {
		task := tasks_visible[i]

		if task.button_bookmark == nil {
			task_bookmark_init_check(task)
		} else {
			element_hide_toggle(task.button_bookmark)
		}
	}

	window_repaint(window_main)
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
	p := panel_goto

	element_hide(p, false)
	goto_transition_unit = 1
	goto_transition_hide = false
	goto_transition_animating = true
	element_animation_start(p)

	box := element_find_first_text_box(p.panel)
	assert(box != nil)
	element_focus(window_main, box)

	goto_saved_task_head = task_head
	goto_saved_task_tail = task_tail

	// reset text
	ss_clear(&box.ss)
	box.head = 0
	box.tail = 0
}

todool_search :: proc(du: u32) {
	p := panel_search
	element_hide(p, false)

	// save info
	search.saved_task_head = task_head
	search.saved_task_tail = task_tail

	box := element_find_first_text_box(p)
	assert(box != nil)
	element_focus(window_main, box)

	if task_head != -1 {
		task := tasks_visible[task_head]

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
	if !last_was_task_copy {
		element_repaint(mode_panel) // required to make redraw and copy 
	}
	last_was_task_copy = true
}

todool_duplicate_line :: proc(du: u32) {
	if task_head == -1 {
		return
	}

	shift := du_shift(du)
	manager := mode_panel_manager_scoped()
	task_head_tail_push(manager)
	task_state_progression = .Update_Animated
	task_current := tasks_visible[task_head]
	index, indentation := task_head_safe_index_indentation()
	task_push_undoable(manager, indentation, ss_string(&task_current.box.ss), index)
	element_repaint(mode_panel)

	task_head += 1
	task_head_tail_check_end(shift)
}

todool_copy_tasks :: proc(du: u32 = 0) {
	if copy_selection() {
		issue_copy()
	}
}

todool_cut_tasks :: proc(du: u32 = 0) {
	if task_head == -1 {
		return 
	}

	last_was_task_copy = true
	manager := mode_panel_manager_scoped()
	task_head_tail_push(manager)

	copy_selection()
	task_remove_selection(manager, true)
	element_repaint(mode_panel)
}

todool_paste_tasks :: proc(du: u32 = 0) {
	if copy_empty() {
		return
	}

	manager := mode_panel_manager_scoped()
	task_head_tail_push(manager)
	task_state_progression = .Update_Animated

	// no selection
	if task_head == -1 || task_head == task_tail {
		index, indentation := task_head_safe_index_indentation()
		copy_paste_at(manager, index + 1, indentation)
		
		task_head = max(task_head, 0) + len(copy_task_data)
		task_tail = max(task_head, 0)
	} else {
		indentation := max(int)

		// get lowest indentation of removal selection
		{
			low, high := task_low_and_high()
			for i in low..<high + 1 {
				task := tasks_visible[i]
				indentation = min(indentation, task.indentation)
			}
		}

		task_remove_selection(manager, true)

		index, _ := task_head_safe_index_indentation()
		index += 1
		copy_paste_at(manager, index, indentation)
		
		task_head += len(copy_task_data)
		task_tail = task_head
	}

	element_repaint(mode_panel)
}

todool_paste_tasks_from_clipboard :: proc(du: u32) {
	if clipboard_has_content() {
		clipboard_text := clipboard_get_with_builder()
		
		// indentation
		indentation_per_line := make([dynamic]u16, 0, 256)
		defer delete(indentation_per_line)

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
		
		if task_head != -1 {
			low, high := task_low_and_high()
			highest_task := tasks_visible[high]
			task_index = highest_task.index + 1
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

		task_tail = task_head + 1
		task_head = task_head + line_index
		element_repaint(mode_panel)
	}
}

todool_center :: proc(du: u32) {
	if task_head != -1 {
		cam := mode_panel_cam()
		cam.freehand = false
		cam_center_by_height_state(cam, mode_panel.bounds, caret_rect.t)
	}
}

todool_tasks_to_uppercase :: proc(du: u32) {
	if task_head != -1 {
		manager := mode_panel_manager_scoped()
		task_head_tail_push(manager)
		iter := ti_init()

		for task in ti_step(&iter) {
			ss := &task.box.ss
	
			if ss_has_content(ss) {
				item := Undo_String_Uppercased_Content { ss }
				undo_box_uppercased_content(manager, &item)
			}
		}

		element_repaint(mode_panel)
	}
}

todool_tasks_to_lowercase :: proc(du: u32) {
	if task_head != -1 {
		manager := mode_panel_manager_scoped()
		task_head_tail_push(manager)
		iter := ti_init()

		for task in ti_step(&iter) {
			ss := &task.box.ss
	
			if ss_has_content(ss) {
				item := Undo_String_Lowercased_Content { ss }
				undo_box_lowercased_content(manager, &item)
			}
		}

		element_repaint(mode_panel)
	}
}

todool_new_file :: proc(du: u32) {
  if !todool_check_for_saving(window_main) {
	  tasks_load_reset()
	  last_save_set("")
  }
}

todool_check_for_saving :: proc(window: ^Window) -> (canceled: bool) {
	// ignore empty file saving
	if task_head == -1 {
		return
	}

	when DEMO_MODE {
		return
	}

	if options_autosave() {
		todool_save(COMBO_FALSE)
	} else if dirty != dirty_saved {
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
	if task_head == -1 {
		return
	}

	if task_head == task_tail {
		task := tasks_visible[task_head]

		if task.has_children {
			if task.folded {
				todool_toggle_folding()
				task_set_visible_tasks()
				task_check_parent_states(nil)
			}

			task_tail = task_head

			index := task.visible_index + 1
			for index < len(tasks_visible) {
				t := tasks_visible[index]

				if t.indentation <= task.indentation {
					break
				}

				index += 1
			}

			task_head = index - 1
		}		
	} else {
		task_head, task_tail = task_tail, task_head
	}

	element_repaint(mode_panel)
}

// jumps to nearby state changes
todool_jump_nearby :: proc(du: u32) {
	shift := du_shift(du)

	if task_head == -1 {
		return
	}

	task_current := tasks_visible[task_head]

	for i in 0..<len(tasks_visible) {
		index := shift ? (task_head - i - 1) : (i + task_head + 1)
		// wrap negative
		if index < 0 {
			index = len(tasks_visible) + index
		}
		task := tasks_visible[index % len(tasks_visible)]
		
		if task.state != task_current.state {
			if task_head_tail_check_begin(shift) {
				task_head = task.visible_index
			}
			task_head_tail_check_end(shift)
			element_repaint(mode_panel)
			break
		}
	}
}

Undo_Item_Task_Sort :: struct {
	task_current: ^Task,
	from, to: int,
}

undo_task_sort :: proc(manager: ^Undo_Manager, item: rawptr) {
	data := cast(^Undo_Item_Task_Sort) item
	
	Task_Line :: struct {
		task: ^Task,
		children_from, children_to: i32,
	}

	sort_list := make([dynamic]Task_Line, 0, 64)
	defer delete(sort_list)
	
	children := make([dynamic]^Task, 0, 64)
	defer delete(children)

	for i in data.from..<data.to + 1 {
		task := cast(^Task) mode_panel.children[i]

		// if the task has the same parent push to sort list
		if task.visible_parent == data.task_current.visible_parent {
			append(&sort_list, Task_Line {
				task,
				-1, 
				0,
			})
		} else {
			// set child location info per pushed child on the last task
			last := &sort_list[len(sort_list) - 1]
			child_index := i32(len(children))
			if last.children_from == -1 {
				last.children_from = child_index
			}
			last.children_to = child_index
			append(&children, task)
		}
	}

	cmp1 :: proc(a, b: Task_Line) -> bool {
		return a.children_from == -1
	}

	cmp2 :: proc(a, b: Task_Line) -> bool {
		return a.task.state < b.task.state
	}

	slice.stable_sort_by(sort_list[:], cmp1)
	slice.stable_sort_by(sort_list[:], cmp2)

	// prepare reversal
	out := Undo_Item_Task_Sort_Original {
		data.task_current,
		data.from, 
		data.to,
	}
	count := (data.to - data.from) + 1
	bytes := undo_push(
		manager, 
		undo_task_sort_original, 
		&out, 
		size_of(Undo_Item_Task_Sort_Original) + count * size_of(^Task),
	)
	// actually save the data
	bytes_root := cast(^^Task) &bytes[size_of(Undo_Item_Task_Sort_Original)]
	storage := mem.slice_ptr(bytes_root, count)
	for i in 0..<count {
		storage[i] = cast(^Task) mode_panel.children[i + data.from]
	}

	insert_offset: int
	for i in 0..<len(sort_list) {
		line := sort_list[i]
		index := data.from + i + insert_offset
		mode_panel.children[index] = line.task

		if line.children_from != -1 {
			local_index := index + 1
			// fmt.eprintln("line", line.children_from, line.children_to)

			for j in line.children_from..<line.children_to + 1 {
				mode_panel.children[local_index] = children[j]
				local_index += 1
				insert_offset += 1
				// fmt.eprintln("jjj", j)
			}
		}
	}

	element_repaint(mode_panel)
}

Undo_Item_Task_Sort_Original :: struct {
	task_current: ^Task,
	from, to: int,
	// ^Task data upcoming
}

undo_task_sort_original :: proc(manager: ^Undo_Manager, item: rawptr) {
	data := cast(^Undo_Item_Task_Sort_Original) item

	bytes_root := cast(^^Task) (uintptr(item) + size_of(Undo_Item_Task_Sort_Original))
	count := data.to - data.from + 1
	storage := mem.slice_ptr(bytes_root, count)	

	// revert to unsorted data
	for i in 0..<count {
		mode_panel.children[i + data.from] = storage[i]
	}

	out := Undo_Item_Task_Sort {
		data.task_current,
		data.from,
		data.to,
	}
	undo_push(manager, undo_task_sort, &out, size_of(Undo_Item_Task_Sort))
}

// idea:
// gather all children to be sorted [from:to] without sub children
// sort based on wanted properties
// replace existing tasks by new result + offset by sub children
todool_sort_locals :: proc(du: u32) {
	if task_head == -1 {
		return
	}

	task_tail = task_head
	task_current := tasks_visible[task_head]

	// skip high level
	from, to: int
	if task_current.visible_parent == nil {
		from = 0
		to = len(mode_panel.children) - 1
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
	task_set_visible_tasks()
	task_head = task_current.visible_index
	task_tail = task_head
}

todool_scale :: proc(du: u32) {
	amt := f32(du_pos_neg(du)) * 0.1
	scaling_inc(amt)
	element_repaint(mode_panel)
}

todool_fullscreen_toggle :: proc(du: u32) {
	window_fullscreen_toggle(window_main)
}

// set mode and issue repaint on change
VIM :: proc(insert: bool) {
	old := vim.insert_mode
	vim.insert_mode = insert

	if old != insert {
		statusbar.vim_panel.color = insert ? &theme.text_bad : &theme.text_good
		window_repaint(window_main)
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
	if task_head == -1 {
		return
	}

	switch mode_panel.mode {
		case .Kanban: {
			current := tasks_visible[task_head]
			b := current.bounds
			closest_task: ^Task
			closest_distance := max(f32)
			middle := b.t + rect_height_halfed(b)

			if vim_visual_reptition_check(current, -1) {
				return
			}

			// find closest distance
			for task in tasks_visible {
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
				task_head = closest_task.visible_index
				task_tail = closest_task.visible_index
				window_repaint(window_main)
				
				vim_visual_reptition_set(current, 1)
			}
		}

		case .List: {
			todool_move_down(COMBO_EMPTY)
		}
	}
}

vim_visual_move_right :: proc(du: u32) {
	if task_head == -1 {
		return
	}

	switch mode_panel.mode {
		case .Kanban: {
			current := tasks_visible[task_head]
			b := current.bounds
			closest_task: ^Task
			closest_distance := max(f32)
			middle := b.t + rect_height_halfed(b)

			if vim_visual_reptition_check(current, 1) {
				return
			}

			// find closest distance
			for task in tasks_visible {
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
				task_head = closest_task.visible_index
				task_tail = closest_task.visible_index
				window_repaint(window_main)

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

	if vim.rep_task != nil || vim.rep_direction == 0 {
		if direction == vim.rep_direction {
			// need to check if the task is still inside the tasks visible, in case it was deleted
			if vim.rep_task in task_clear_checking {
				found: bool
				for task in tasks_visible {
					if task == vim.rep_task {
						found = true
						break
					}
				}

				if !found {
					return false
				}
			}

			vim.rep_direction *= -1
			task_head = vim.rep_task.visible_index
			task_tail = vim.rep_task.visible_index
			vim.rep_task = task

			// cam := mode_panel_cam()
			// if visuals_use_animations() {
			// 	element_animation_start(mode_panel)
			// 	cam.ax.animating = true
			// 	cam.ax.direction = CAM_CENTER
			// 	cam.ax.goal = int(vim.rep_cam_x)
				
			// 	cam.ay.animating = true
			// 	cam.ay.direction = CAM_CENTER
			// 	cam.ay.goal = int(vim.rep_cam_y)
			// } else {
			// 	cam.offset_x = vim.rep_cam_x
			// 	cam.offset_y = vim.rep_cam_y
			// }
			// cam.freehand = false

			window_repaint(window_main)
			return true
		}
	}

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
	if task_head == -1 {
		return
	}

	iter := ti_init()
	for task in ti_step(&iter) {
		task_set_time_date(task)
	}

	window_repaint(window_main)
}
