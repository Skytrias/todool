package src

import "core:os"
import "core:fmt"
import "core:strings"
import "core:log"
import "core:mem"
import "../cutf8"
import "../tfd"

// shortcut state that holds all shortcuts
// key_combo -> command -> command execution
Shortcut_State :: struct {
	arena: mem.Arena,
	arena_backing: []byte,
	
	box: map[string]string,
	general: map[string]string,
}

shortcut_state_init :: proc(s: ^Shortcut_State, arena_cap: int) {
	s.arena_backing = make([]byte, arena_cap)
	mem.arena_init(&s.arena, s.arena_backing)
	s.box = make(map[string]string, 32)
	s.general = make(map[string]string, 128)
}

shortcut_state_destroy :: proc(s: ^Shortcut_State) {
	delete(s.box)
	delete(s.general)
	free_all(mem.arena_allocator(&s.arena))
	delete(s.arena_backing)
}

// push box command with N combos
shortcuts_push_box :: proc(s: ^Shortcut_State, command: string, combos: ..string) {
	for combo in combos {
		s.box[strings.clone(combo)] = strings.clone(command)
	}
}

// push general command with N combos
shortcuts_push_general :: proc(s: ^Shortcut_State, command: string, combos: ..string) {
	for combo in combos {
		s.general[strings.clone(combo)] = strings.clone(command)
	}
}

// clear all shortcuts
shortcuts_clear :: proc(window: ^Window) {
	s := &window.shortcut_state
	clear(&s.box)
	clear(&s.general)
	free_all(mem.arena_allocator(&s.arena))
}

// push default box shortcuts
shortcuts_push_box_default :: proc(window: ^Window) {
	s := &window.shortcut_state
	context.allocator = mem.arena_allocator(&s.arena)
	shortcuts_push_box(s, "move_left", "ctrl+shift+left", "ctrl+left", "shift+left", "left")
	shortcuts_push_box(s, "move_right", "ctrl+shift+right", "ctrl+right", "shift+right", "right")
	shortcuts_push_box(s, "home", "shift+home", "home")
	shortcuts_push_box(s, "end", "shift+end", "end")
	shortcuts_push_box(s, "backspace", "ctrl+backspace", "shift+backspace", "backspace")
	shortcuts_push_box(s, "delete", "shift+delete", "delete")
	shortcuts_push_box(s, "select_all", "ctrl+a")
	shortcuts_push_box(s, "copy", "ctrl+c")
	shortcuts_push_box(s, "cut", "ctrl+x")
	shortcuts_push_box(s, "paste", "ctrl+v")
}

shortcuts_command_execute_todool :: proc(command: string) -> (handled: bool) {
	ctrl := mode_panel.window.ctrl
	shift := mode_panel.window.shift
	handled = true

	switch command {
		case "move_up": todool_move_up()
		case "move_down": todool_move_down()
		case "move_up_parent": todool_move_up_parent()
		
		case "indent_jump_low_prev": todool_indent_jump_low_prev()
		case "indent_jump_low_next": todool_indent_jump_low_next()
		case "indent_jump_same_prev": todool_indent_jump_same_prev()
		case "indent_jump_same_next": todool_indent_jump_same_next()
		case "indent_jump_scope": todool_indent_jump_scope()
	
		case "bookmark_jump_prev": todool_bookmark_jump(true)
		case "bookmark_jump_next": todool_bookmark_jump(false)
		
		case "tag_toggle1": tag_toggle(0x01)
		case "tag_toggle2": tag_toggle(0x02)
		case "tag_toggle3": tag_toggle(0x04)
		case "tag_toggle4": tag_toggle(0x08)
		case "tag_toggle5": tag_toggle(0x10)
		case "tag_toggle6": tag_toggle(0x20)
		case "tag_toggle7": tag_toggle(0x40)
		case "tag_toggle8": tag_toggle(0x80)

		case "delete_tasks": todool_delete_tasks()
		case "delete_on_empty": todool_delete_on_empty()
		
		case "copy_tasks_to_clipboard": todool_copy_tasks_to_clipboard()
		case "copy_tasks": todool_copy_tasks()
		case "cut_tasks": todool_cut_tasks()
		case "paste_tasks": todool_paste_tasks()
		case "paste_tasks_from_clipboard": todool_paste_tasks_from_clipboard()
		case "center": todool_center()
		
		case "tasks_to_lowercase": todool_tasks_to_lowercase()
		case "tasks_to_uppercase": todool_tasks_to_uppercase()
		
		case "change_task_state": todool_change_task_state(shift)
		case "changelog_generate": todool_changelog_generate(false)

		case "selection_stop": todool_selection_stop()
		
		case "toggle_folding": todool_toggle_folding()
		case "toggle_bookmark": todool_toggle_bookmark()

		case "indentation_shift_right": todool_indentation_shift(1)
		case "indentation_shift_left": todool_indentation_shift(-1)

		case "pomodoro_toggle1": pomodoro_stopwatch_hot_toggle(0)
		case "pomodoro_toggle2": pomodoro_stopwatch_hot_toggle(1)
		case "pomodoro_toggle3": pomodoro_stopwatch_hot_toggle(2)

		case "mode_list": todool_mode_list()
		case "mode_kanban": todool_mode_kanban()
		case "theme_editor": theme_editor_spawn()

		case "insert_sibling": todool_insert_sibling()
		case "insert_child": todool_insert_child()

		case "shift_up": todool_shift_up()
		case "shift_down": todool_shift_down()

		case "select_all": todool_select_all()

		case "undo": todool_undo()
		case "redo": todool_redo()
		case "save": todool_save(false)
		case "save_as": todool_save(true)
		case "new_file": todool_new_file()
		case "load": todool_load()

		case "goto": todool_goto()
		case "search": todool_search()
		case "escape": todool_escape()

		case "select_children": todool_select_children()

		case: {
			handled = false
		}
	}

	return
}

shortcuts_push_todool_default :: proc(window: ^Window) {
	s := &window.shortcut_state
	context.allocator = mem.arena_allocator(&s.arena)
	shortcuts_push_general(s, "move_up", "shift+up", "ctrl+up", "up")
	shortcuts_push_general(s, "move_down", "shift+down", "ctrl+down", "down")
	shortcuts_push_general(s, "move_up_parent", "ctrl+shift+home", "ctrl+home")
	
	shortcuts_push_general(s, "indent_jump_low_prev", "ctrl+shift+,", "ctrl+,")
	shortcuts_push_general(s, "indent_jump_low_next", "ctrl+shift+.", "ctrl+.")
	shortcuts_push_general(s, "indent_jump_same_prev", "ctrl+shift+up", "ctrl+up")
	shortcuts_push_general(s, "indent_jump_same_next", "ctrl+shift+down", "ctrl+down")
	shortcuts_push_general(s, "indent_jump_scope", "ctrl+shift+m", "ctrl+m")
	
	shortcuts_push_general(s, "bookmark_jump_prev", "ctrl+shift+tab")
	shortcuts_push_general(s, "bookmark_jump_next", "ctrl+tab")

	shortcuts_push_general(s, "tasks_to_uppercase", "ctrl+shift+j")
	shortcuts_push_general(s, "tasks_to_lowercase", "ctrl+shift+l")

	shortcuts_push_general(s, "delete_on_empty", "ctrl+backspace", "backspace")
	shortcuts_push_general(s, "delete_tasks", "ctrl+d", "ctrl+shift+k")
	
	shortcuts_push_general(s, "copy_tasks_to_clipboard", "ctrl+shift+c", "ctrl+alt+c", "ctrl+shift+alt+c", "alt+c")
	shortcuts_push_general(s, "copy_tasks", "ctrl+c")
	shortcuts_push_general(s, "cut_tasks", "ctrl+x")
	shortcuts_push_general(s, "paste_tasks", "ctrl+v")
	shortcuts_push_general(s, "paste_tasks_from_clipboard", "ctrl+shift+v")
	shortcuts_push_general(s, "center", "ctrl+e")
	
	shortcuts_push_general(s, "change_task_state", "ctrl+shift+q", "ctrl+q")
	
	shortcuts_push_general(s, "selection_stop", "left", "right")
	shortcuts_push_general(s, "toggle_folding", "ctrl+j")
	shortcuts_push_general(s, "toggle_bookmark", "ctrl+b")

	shortcuts_push_general(s, "tag_toggle1", "ctrl+1")
	shortcuts_push_general(s, "tag_toggle2", "ctrl+2")
	shortcuts_push_general(s, "tag_toggle3", "ctrl+3")
	shortcuts_push_general(s, "tag_toggle4", "ctrl+4")
	shortcuts_push_general(s, "tag_toggle5", "ctrl+5")
	shortcuts_push_general(s, "tag_toggle6", "ctrl+6")
	shortcuts_push_general(s, "tag_toggle7", "ctrl+7")
	shortcuts_push_general(s, "tag_toggle8", "ctrl+8")
	
	shortcuts_push_general(s, "changelog_generate", "alt+x")
	
	shortcuts_push_general(s, "indentation_shift_right", "tab", "alt+right")
	shortcuts_push_general(s, "indentation_shift_left", "shift+tab", "alt+left")

	shortcuts_push_general(s, "pomodoro_toggle1", "alt+1")
	shortcuts_push_general(s, "pomodoro_toggle2", "alt+2")
	shortcuts_push_general(s, "pomodoro_toggle3", "alt+3")
	
	shortcuts_push_general(s, "mode_list", "alt+q")
	shortcuts_push_general(s, "mode_kanban", "alt+w")
	shortcuts_push_general(s, "theme_editor", "alt+e")

	shortcuts_push_general(s, "insert_sibling", "return")
	shortcuts_push_general(s, "insert_child", "ctrl+return")

	shortcuts_push_general(s, "shift_down", "alt+down")
	shortcuts_push_general(s, "shift_up", "alt+up")
	shortcuts_push_general(s, "select_all", "ctrl+shift+a")

	shortcuts_push_general(s, "undo", "ctrl+z")
	shortcuts_push_general(s, "redo", "ctrl+y")
	shortcuts_push_general(s, "save", "ctrl+s")
	shortcuts_push_general(s, "save_as", "ctrl+shift+s")
	shortcuts_push_general(s, "new_file", "ctrl+n")
	shortcuts_push_general(s, "load", "ctrl+o")

	shortcuts_push_general(s, "goto", "ctrl+g")
	shortcuts_push_general(s, "search", "ctrl+f")
	shortcuts_push_general(s, "escape", "escape")

	// new ones
	shortcuts_push_general(s, "select_children", "ctrl+j")
}

todool_delete_on_empty :: proc() {
	task := tasks_visible[task_head]
	
	if len(task.box.builder.buf) == 0 {
		manager := mode_panel_manager_scoped()
		task_head_tail_push(manager)
		index := task.index
		
		if index == len(mode_panel.children) {
			item := Undo_Item_Task_Pop {}
			undo_task_pop(manager, &item, false)
		} else {
			task_remove_at_index(manager, index)
		}

		element_repaint(task)
		task_head -= 1
		task_tail -= 1
	}
}

todool_move_up :: proc() {
	if task_head == -1 {
		return
	}

	if task_head_tail_check_begin() {
		task_head -= 1
	}
	task_head_tail_check_end()
	bookmark_index = -1
	task := tasks_visible[max(task_head, 0)]
	element_repaint(mode_panel)
	element_message(task.box, .Box_Set_Caret, BOX_END)
}

todool_move_down :: proc() {
	if task_head == -1 {
		return 
	}

	if task_head_tail_check_begin() {
		task_head += 1
	}
	task_head_tail_check_end()
	bookmark_index = -1

	task := tasks_visible[min(task_head, len(tasks_visible) - 1)]
	element_message(task.box, .Box_Set_Caret, BOX_END)
	element_repaint(mode_panel)
}

todool_move_up_parent :: proc() {
	if task_head == -1 {
		return
	}

	task_current := tasks_visible[task_head]

	for i := task_head - 1; i >= 0; i -= 1 {
		task := tasks_visible[i]
		
		if task.indentation < task_current.indentation {
			if task_head_tail_check_begin() {
				task_head = i
			}
			task_head_tail_check_end()
			element_repaint(mode_panel)
			element_message(task.box, .Box_Set_Caret, BOX_END)
			break
		}
	} 
}

todool_indent_jump_low_prev :: proc() {
	if task_head == -1 {
		return
	}

	task_current := tasks_visible[task_head]

	for i := task_current.index - 1; i >= 0; i -= 1 {
		task := cast(^Task) mode_panel.children[i]

		if task.indentation == 0 && task.visible {
			if task_head_tail_check_begin() {
				task_head = task.visible_index
			}
			task_head_tail_check_end()
			element_message(task.box, .Box_Set_Caret, BOX_END)
			element_repaint(task)
			break
		}
	}
}

todool_indent_jump_low_next :: proc() {
	if task_head == -1 {
		return
	}

	task_current := tasks_visible[task_head]

	for i in task_current.index + 1..<len(mode_panel.children) {
		task := cast(^Task) mode_panel.children[i]

		if task.indentation == 0 && task.visible {
			if task_head_tail_check_begin() {
				task_head = task.visible_index
			}
			task_head_tail_check_end()
			element_repaint(task)
			element_message(task.box, .Box_Set_Caret, BOX_END)
			break
		}
	}
}

todool_indent_jump_same_prev :: proc() {
	if task_head == -1 {
		return
	}

	task_current := tasks_visible[task_head]

	for i := task_head - 1; i >= 0; i -= 1 {
		task := tasks_visible[i]
		
		if task.indentation == task_current.indentation {
			if task_head_tail_check_begin() {
				task_head = i
			}
			task_head_tail_check_end()
			element_repaint(mode_panel)
			element_message(task.box, .Box_Set_Caret, BOX_END)
			break
		}
	} 
}

todool_indent_jump_same_next :: proc() {
	if task_head == -1 {
		return
	}

	task_current := tasks_visible[task_head]

	for i := task_head + 1; i < len(tasks_visible); i += 1 {
		task := tasks_visible[i]
		
		if task.indentation == task_current.indentation {
			if task_head_tail_check_begin() {
				task_head = i
			}
			task_head_tail_check_end()
			element_repaint(mode_panel)
			element_message(task.box, .Box_Set_Caret, BOX_END)
			break
		}
	} 
}

todool_bookmark_jump :: proc(shift: bool) {
	if len(bookmarks) != 0 && len(tasks_visible) != 0 {
		bookmark_advance(shift)
		index := bookmarks[bookmark_index]
		task := tasks_visible[index]
		task_head = task.visible_index
		task_tail = task.visible_index
		element_repaint(mode_panel)
	}
}

todool_delete_tasks :: proc() {
	if task_head == -1 {
		return
	}

	manager := mode_panel_manager_scoped()
	task_head_tail_push(manager)
	task_remove_selection(manager, true)
	element_repaint(mode_panel)
}

todool_copy_tasks_to_clipboard :: proc() {
	if task_head == -1 {
		return
	}

	b := &gs.copy_builder
	strings.builder_reset(b)
	low, high := task_low_and_high()

	// get lowest
	lowest_indentation := 255
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
	low, high := task_low_and_high()

	for i in low..<high + 1 {
		task := tasks_visible[i]
		task_set_state_undoable(manager, task, state)
	}
}

todool_change_task_state :: proc(shift: bool) {
	if task_head == -1 {
		return
	}

	manager := mode_panel_manager_scoped()
	task_head_tail_push(manager)
	low, high := task_low_and_high()

	// modify all states
	index: int
	for i in low..<high + 1 {
		task := tasks_visible[i]

		if task.has_children {
			continue
		}

		index = int(task.state)
		range_advance_index(&index, len(Task_State) - 1, shift)

		// save old set
		task_set_state_undoable(manager, task, Task_State(index))
	}

	element_repaint(mode_panel)
}

todool_indent_jump_scope :: proc() {
	if task_head == -1 {
		return
	}

	task_current := tasks_visible[task_head]
	defer element_repaint(mode_panel)

	// skip indent search at higher levels, just check for 0
	if task_current.indentation == 0 {
		// search for first indent 0 at end
		for i := len(tasks_visible) - 1; i >= 0; i -= 1 {
			current := tasks_visible[i]

			if current.indentation == 0 {
				if i == task_head {
					break
				}

				task_head_tail_check_begin()
				task_head = i
				task_head_tail_check_end()
				return
			}
		}

		// search for first indent at 0 
		for i in 0..<len(tasks_visible) {
			current := tasks_visible[i]

			if current.indentation == 0 {
				task_head_tail_check_begin()
				task_head = i
				task_head_tail_check_end()
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

				task_head_tail_check_begin()
				task_head = last_good
				task_head_tail_check_end()
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
				task_head_tail_check_begin()
				task_head = last_good
				task_head_tail_check_end()
				break
			}
		}
	}
}

todool_selection_stop :: proc() {
	if task_has_selection() {
		task_tail = task_head
		element_repaint(mode_panel)
	}	
}

todool_changelog_generate :: proc(check_only: bool) {
	// TODO checked only

	if task_head == -1 {
		return
	}

	b := clipboard_set_prepare()
	removed_count: int
	
	manager := mode_panel_manager_scoped()
	task_head_tail_push(manager)

	// write tasks out 
	for i := 0; i < len(mode_panel.children); i += 1 {
		task := cast(^Task) mode_panel.children[i]

		if task.state != .Normal {
			task_write_text_indentation(b, task, task.indentation)
			archive_push(strings.to_string(task.box.builder))
			task_remove_at_index(manager, i)
			
			i -= 1
			removed_count += 1
		} else if task.has_children {
			if task.state_count[.Done] != 0 || task.state_count[.Canceled] != 0 {
				task_write_text_indentation(b, task, task.indentation)
			}
		}
	}

	if removed_count != 0 {
		clipboard_set_with_builder_prefilled()
		element_repaint(mode_panel)
	}
}

todool_escape :: proc() {
	if image_display_has_content(mode_panel.image_display) {
		mode_panel.image_display.img = nil
		element_repaint(mode_panel)
		return
	}

	if element_hide(panel_search, true) {
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

todool_toggle_folding :: proc() {
	if task_head == -1 {
		return
	}

	task := tasks_visible[task_head]
	manager := mode_panel_manager_scoped()

	if task.has_children {
		task_head_tail_push(manager)
		item := Undo_Item_Bool_Toggle { &task.folded }
		undo_bool_toggle(manager, &item, false)
		
		task_tail = task_head
		element_repaint(mode_panel)
	}
}

todool_insert_sibling :: proc() {
	indentation: int
	manager := mode_panel_manager_scoped()
	task_head_tail_push(manager)

	// NOTE next line
	goal := len(mode_panel.children) // default append
	if task_head < len(tasks_visible) - 1 {
		goal = tasks_visible[task_head + 1].index
	}

	if task_head != -1 {
		indentation = tasks_visible[task_head].indentation
	}

	// // same line
	// goal := 0 // default append
	// if task_head != -1 && task_head > 0 {
	// 	goal = tasks_visible[task_head].index
	// 	indentation = tasks_visible[task_head - 1].indentation
	// }

	task_push_undoable(manager, indentation, "", goal)
	task_head += 1
	task_head_tail_check_end()
	element_repaint(mode_panel)
}

todool_insert_child :: proc() {
	indentation: int
	goal := len(mode_panel.children) // default append
	manager := mode_panel_manager_scoped()
	task_head_tail_push(manager)

	if task_head < len(tasks_visible) - 1 {
		goal = tasks_visible[task_head + 1].index
	}

	if task_head != -1 {
		current_task := tasks_visible[task_head]
		indentation = current_task.indentation + 1
		builder := &current_task.box.builder

		// uppercase word
		if !current_task.has_children && options_uppercase_word() && len(builder.buf) != 0 {
			item := Undo_Builder_Uppercased_Content { builder }
			undo_box_uppercased_content(manager, &item, false)
		}
	}

	task_push_undoable(manager, indentation, "", goal)
	task_head += 1
	task_head_tail_check_end()
	element_repaint(mode_panel)
}

todool_mode_list :: proc() {
	if mode_panel.mode != .List {
		mode_panel.mode = .List
		element_repaint(mode_panel)
	}
}

todool_mode_kanban :: proc() {
	if mode_panel.mode != .Kanban {
		mode_panel.mode = .Kanban
		element_repaint(mode_panel)
	}
}

todool_shift_down :: proc() {
	selection := task_has_selection()
	low, high := task_low_and_high()

	if high + 1 >= len(tasks_visible) {
		return
	}

	manager := mode_panel_manager_scoped()
	task_head_tail_push(manager)

	for i := high + 1; i > low; i -= 1 {
		a := tasks_visible[i]
		b := tasks_visible[i - 1]
		task_swap(manager, a.index, b.index)
	}

	task_head += 1
	task_tail += 1
}

todool_shift_up :: proc() {
	selection := task_has_selection()
	low, high := task_low_and_high()

	if low - 1 < 0 {
		return
	}

	manager := mode_panel_manager_scoped()
	task_head_tail_push(manager)

	for i := low - 1; i < high; i += 1 {
		a := tasks_visible[i]
		b := tasks_visible[i + 1]
		task_swap(manager, a.index, b.index)
	}

	task_head -= 1
	task_tail -= 1
}

todool_select_all :: proc() {
	task_tail = 0
	task_head = len(tasks_visible)
	element_repaint(mode_panel)
}

Undo_Item_Int_Set :: struct {
	value: ^int,
	to: int,
}

undo_int_set :: proc(manager: ^Undo_Manager, item: rawptr, clear: bool) {
	if !clear {
		data := cast(^Undo_Item_Int_Set) item
		output := Undo_Item_Int_Set { data.value, data.value^ }
		data.value^ = data.to
		undo_push(manager, undo_int_set, &output, size_of(Undo_Item_Int_Set))
	}
}

Undo_Item_Dirty_Increase :: struct {}

Undo_Item_Dirty_Decrease :: struct {}

undo_dirty_increase :: proc(manager: ^Undo_Manager, item: rawptr, clear: bool) {
	if !clear {
		dirty += 1
		output := Undo_Item_Dirty_Decrease {}
		undo_push(manager, undo_dirty_decrease, &output, size_of(Undo_Item_Dirty_Decrease))
	}
}

undo_dirty_decrease :: proc(manager: ^Undo_Manager, item: rawptr, clear: bool) {
	if !clear {
		dirty -= 1
		output := Undo_Item_Dirty_Increase {}
		undo_push(manager, undo_dirty_increase, &output, size_of(Undo_Item_Dirty_Increase))
	}
}

dirty_push :: proc(manager: ^Undo_Manager) {
	item := Undo_Item_Dirty_Increase {}
	undo_dirty_increase(manager, &item, false)
}

Undo_Item_Task_Head_Tail :: struct {
	head: int,
	tail: int,
}

undo_task_head_tail :: proc(manager: ^Undo_Manager, item: rawptr, clear: bool) {
	if !clear {
		data := cast(^Undo_Item_Task_Head_Tail) item
		old_head := task_head
		old_tail := task_tail
		task_head = data.head
		task_tail = data.tail
		data.head = old_head
		data.tail = old_tail

		undo_push(manager, undo_task_head_tail, item, size_of(Undo_Item_Task_Head_Tail))
	}
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

undo_u8_xor :: proc(manager: ^Undo_Manager, item: rawptr, clear: bool) {
	if !clear {
		data := cast(^Undo_Item_U8_XOR) item
		data.value^ ~= data.bit
		undo_push(manager, undo_u8_xor, item, size_of(Undo_Item_U8_XOR))
	}
}

u8_xor_push :: proc(manager: ^Undo_Manager, value: ^u8, bit: u8) {
	item := Undo_Item_U8_XOR {
		value = value,
		bit = bit,
	}
	undo_u8_xor(manager, &item, false)
}

tag_toggle :: proc(bit: u8) {
	if task_head == -1 {
		return
	}

	low, high := task_low_and_high()
	manager := mode_panel_manager_scoped()
	task_head_tail_push(manager)

	for i in low..<high + 1 {
		task := tasks_visible[i]
		u8_xor_push(manager, &task.tags, bit)
	}

	element_repaint(mode_panel)
}

Undo_Item_Task_Swap :: struct {
	a, b: ^^Task,
}

undo_task_swap :: proc(manager: ^Undo_Manager, item: rawptr, clear: bool) {
	if !clear {
		data := cast(^Undo_Item_Task_Swap) item
		data.a^, data.b^ = data.b^, data.a^
		undo_push(manager, undo_task_swap, item, size_of(Undo_Item_Task_Swap))	
	}
}

// swap with +1 / -1 offset 
task_swap :: proc(manager: ^Undo_Manager, a, b: int) {
	save :: proc(task: ^Task) {
		task.top_offset = 0
		task.top_animation_start = true
		task.top_animating = true
		task.top_old = task.bounds.t
	}

	aa := cast(^^Task) &mode_panel.children[a]
	bb := cast(^^Task) &mode_panel.children[b]
	item := Undo_Item_Task_Swap {
		a = aa,
		b = bb,
	}
	undo_task_swap(manager, &item, false)

	save(aa^)
	save(bb^)
	element_animation_start(aa^)
	element_animation_start(bb^)

	element_repaint(mode_panel)
}

Undo_Item_Bool_Toggle :: struct {
	value: ^bool,
}

// inverse bool set
undo_bool_toggle :: proc(manager: ^Undo_Manager, item: rawptr, clear: bool) {
	if !clear {	
		data := cast(^Undo_Item_Bool_Toggle) item
		data.value^ = !data.value^
		undo_push(manager, undo_bool_toggle, item, size_of(Undo_Item_Bool_Toggle))
	}
}

Undo_Item_U8_Set :: struct {
	value: ^u8,
	to: u8,
}

undo_u8_set :: proc(manager: ^Undo_Manager, item: rawptr, clear: bool) {
	if !clear {
		data := cast(^Undo_Item_U8_Set) item
		old := data.value^
		data.value^ = data.to
		data.to = old
		undo_push(manager, undo_u8_set, item, size_of(Undo_Item_U8_Set))
	}
}

task_set_state_undoable :: proc(manager: ^Undo_Manager, task: ^Task, goal: Task_State) {
	if manager == nil {
		task.state = goal
	} else {
		item := Undo_Item_U8_Set {
			cast(^u8) &task.state,
			cast(u8) task.state,
		}
		undo_push(manager, undo_u8_set, &item, size_of(Undo_Item_U8_Set))
		task.state = goal
	}
}

Undo_Item_Task_Indentation_Set :: struct {
	task: ^Task,
	set: int,
}

undo_task_indentation_set :: proc(manager: ^Undo_Manager, item: rawptr, clear: bool) {
	if !clear {
		data := cast(^Undo_Item_Task_Indentation_Set) item
		old_indentation := data.task.indentation
		data.task.indentation = data.set
		data.task.indentation_smooth = f32(data.set)
		data.set = old_indentation
		undo_push(manager, undo_task_indentation_set, item, size_of(Undo_Item_Task_Indentation_Set))
	}
}

Undo_Item_Task_Remove_At :: struct {
	index: int,
	backup: ^Element,
}

Undo_Item_Task_Insert_At :: struct {
	index: int,
	task: ^Task, // the task you want to insert
}

task_remove_at_index :: proc(manager: ^Undo_Manager, index: int) {
	item := Undo_Item_Task_Remove_At { index, mode_panel.children[index] }
	undo_task_remove_at(manager, &item, false)
}

undo_task_remove_at :: proc(manager: ^Undo_Manager, item: rawptr, clear: bool) {
	data := cast(^Undo_Item_Task_Remove_At) item
	
	if !clear {
		output := Undo_Item_Task_Insert_At {
			data.index, 
			cast(^Task) mode_panel.children[data.index],
		} 

		// TODO maybe speedup somehow?
		ordered_remove(&mode_panel.children, data.index)
		undo_push(manager, undo_task_insert_at, &output, size_of(Undo_Item_Task_Insert_At))
	} else {
		// log.info("CLEAR", data.index)
		// element_destroy(data.backup)
	}
}

undo_task_insert_at :: proc(manager: ^Undo_Manager, item: rawptr, clear: bool) {
	if !clear {
		data := cast(^Undo_Item_Task_Insert_At) item
		inject_at(&mode_panel.children, data.index, data.task)

		output := Undo_Item_Task_Remove_At { data.index, mode_panel.children[data.index] }
		undo_push(manager, undo_task_remove_at, &output, size_of(Undo_Item_Task_Remove_At))
	}
}

Undo_Item_Task_Append :: struct {
	task: ^Task,
}

Undo_Item_Task_Pop :: struct {}

undo_task_append :: proc(manager: ^Undo_Manager, item: rawptr, clear: bool) {
	if !clear {
		data := cast(^Undo_Item_Task_Append) item
		append(&mode_panel.children, data.task)
		output := Undo_Item_Task_Pop {}
		undo_push(manager, undo_task_pop, &output, size_of(Undo_Item_Task_Pop))
	}
}

undo_task_pop :: proc(manager: ^Undo_Manager, item: rawptr, clear: bool) {
	if !clear {
		data := cast(^Undo_Item_Task_Pop) item
		// gather the popped element before
		output := Undo_Item_Task_Append { 
			cast(^Task) mode_panel.children[len(mode_panel.children) - 1],
		}
		pop(&mode_panel.children)
		undo_push(manager, undo_task_append, &output, size_of(Undo_Item_Task_Append))
	}
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

// removes selected region and pushes them to the undo stack
task_remove_selection :: proc(manager: ^Undo_Manager, move: bool) {
	low, high := task_low_and_high()
	remove_count: int
	
	for i := low; i < high + 1; i += 1 {
		task := tasks_visible[i]

		// only valid
		archive_push(strings.to_string(task.box.builder))
		
		task_remove_at_index(manager, task.index - remove_count)
		remove_count += 1
	}

	if move {
		task_head = low - 1
		task_tail = low - 1
	}
}

// copy selected tasks
copy_selection :: proc() {
	if task_head != -1 {
		copy_reset()
		low, high := task_low_and_high()

		// copy each line
		for i in low..<high + 1 {
			task := tasks_visible[i]
			copy_push_task(task)
		}
	}
}

todool_indentation_shift :: proc(amt: int) {
	if task_head == -1 {
		return
	}

	// skip first
	if task_head == task_tail && task_head == 0 {
		return
	}

	low, high := task_low_and_high()
	manager := mode_panel_manager_scoped()
	task_head_tail_push(manager)

	for i in low..<high + 1 {
		task := tasks_visible[i]

		if i == 0 {
			continue
		}

		if task.indentation + amt >= 0 {
			item := Undo_Item_Task_Indentation_Set {
				task = task,
				set = task.indentation,
			}	
			undo_push(manager, undo_task_indentation_set, &item, size_of(Undo_Item_Task_Indentation_Set))

			task.indentation += amt
			task.indentation_animating = true
			element_animation_start(task)
		}
	}		

	// set new indentation based task info and push state changes
	task_set_children_info()
	task_check_parent_states(manager)

	element_repaint(mode_panel)
}

todool_undo :: proc() {
	manager := &mode_panel.window.manager
	if !undo_is_empty(manager, false) {
		// reset bookmark index
		bookmark_index = -1

		undo_invoke(manager, false)
		element_repaint(mode_panel)
	}
}

todool_redo :: proc() {
	manager := &mode_panel.window.manager
	if !undo_is_empty(manager, true) {
		// reset bookmark index
		bookmark_index = -1

		undo_invoke(manager, true)
		element_repaint(mode_panel)
	}
}

todool_save :: proc(force_dialog: bool) {
	if force_dialog || last_save_location == "" {
		// output: cstring
		default_path := gs_string_to_cstring(gs.pref_path)
		file_patterns := [?]cstring { "*.todool" }
		output := tfd.save_file_dialog("Save", default_path, file_patterns[:], "")

		if output != nil {
			last_save_location = strings.clone(string(output))
		} else {
			return
		}
	}

	err := editor_save(last_save_location)
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

// load
todool_load :: proc() {
	// check for canceling loading
	if todool_check_for_saving(window_main) {
		return
	}

	default_path: cstring

	if last_save_location == "" {
		default_path = gs_string_to_cstring(gs.base_path)
		// log.info("----")
	} else {
		trimmed_path := last_save_location

		for i := len(trimmed_path) - 1; i >= 0; i -= 1 {
			b := trimmed_path[i]
			if b == '/' {
				trimmed_path = trimmed_path[:i]
				break
			}
		}

		default_path = gs_string_to_cstring(trimmed_path)
		// log.info("++++", last_save_location, trimmed_path)
	}

	file_patterns := [?]cstring { "*.todool" }
	output := tfd.open_file_dialog("Open", default_path, file_patterns[:])
	
	if output == nil {
		return
	}

	if string(output) != last_save_location {
		last_save_location = strings.clone(string(output))
	} 

	err := editor_load(last_save_location)

	if err != .None {
		log.info("LOAD: FAILED =", err)
	}

	element_repaint(mode_panel)
}

todool_toggle_bookmark :: proc() {
	if task_head == -1 {
		return
	}

	low, high := task_low_and_high()
	manager := mode_panel_manager_scoped()
	task_head_tail_push(manager)

	for i in low..<high + 1 {
		task := tasks_visible[i]
		item := Undo_Item_Bool_Toggle { &task.bookmarked }
		undo_bool_toggle(manager, &item, false)
	}

	element_repaint(mode_panel)
}

todool_goto :: proc() {
	p := panel_goto

	element_hide(p, false)
	goto_transition_unit = 1
	goto_transition_hide = false
	goto_transition_animating = true
	element_animation_start(p)

	box := cast(^Text_Box) p.panel.children[1]
	element_focus(box)

	goto_saved_task_head = task_head
	goto_saved_task_tail = task_tail

	// reset text
	strings.builder_reset(&box.builder)
	box.head = 0
	box.tail = 0
}

todool_search :: proc() {
	p := panel_search
	element_hide(p, false)

	// save info
	search_saved_task_head = task_head
	search_saved_task_tail = task_tail

	box := cast(^Text_Box) p.children[1]
	element_focus(box)

	if task_head != -1 {
		task := tasks_visible[task_head]

		// set word to search instantly
		if task.box.head != task.box.tail {
			// cut out selected word
			ds: cutf8.Decode_State
			low, high := box_low_and_high(task.box)
			text, ok := cutf8.ds_string_selection(
				&ds, 
				strings.to_string(task.box.builder), 
				low, 
				high,
			)

			strings.builder_reset(&box.builder)
			strings.write_string(&box.builder, text)

			search_update_results(text)
		}

		search_saved_box_head = task.box.head
		search_saved_box_tail = task.box.tail
	}		

	element_message(box, .Box_Set_Caret, BOX_SELECT_ALL)
}

todool_copy_tasks :: proc() {
	if !last_was_task_copy {
		element_repaint(mode_panel) // required to make redraw and copy 
	}
	last_was_task_copy = true
	copy_selection()
}

todool_cut_tasks :: proc() {
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

todool_paste_tasks :: proc() {
	if task_head == -1 || copy_empty() {
		return
	}

	manager := mode_panel_manager_scoped()
	task_head_tail_push(manager)

	// no selection
	if task_head == task_tail {
		task := tasks_visible[task_head]
		copy_paste_at(manager, task.index + 1, task.indentation)
		
		task_head += len(copy_task_data)
		task_tail = task_head
	} else {
		indentation := 255

		// get lowest indentation of removal selection
		{
			low, high := task_low_and_high()
			for i in low..<high + 1 {
				task := tasks_visible[i]
				indentation = min(indentation, task.indentation)
			}
		}

		task_remove_selection(manager, true)

		task := tasks_visible[task_head]
		index := task.index + 1
		copy_paste_at(manager, index, indentation)
		
		task_head += len(copy_task_data)
		task_tail = task_head
	}

	element_repaint(mode_panel)
}

todool_paste_tasks_from_clipboard :: proc() {
	if clipboard_has_content() {
		text := clipboard_get_with_builder()
		manager := mode_panel_manager_scoped()
		task_head_tail_push(manager)

		low, high := task_low_and_high()
		index := high + 1

		indentation: int
		if task_head != -1 {
			indentation = tasks_visible[task_head].indentation
		}

		// TODO could interpret \t or spaces as indentation but could lead to unexpected results
		// e.g. when mixing spaces and tabs
		for line in strings.split_lines_iterator(&text) {
			task_push_undoable(manager, indentation, strings.trim_space(line), index)
			index += 1
		}

		task_tail = high + 1
		task_head = index - 1
		element_repaint(mode_panel)
	}
}

todool_center :: proc() {
	if task_head != -1 {
		cam := mode_panel_cam()
		cam.freehand = false
		cam_center_by_height_state(cam, mode_panel.bounds, caret_rect.t)
	}
}

todool_tasks_to_uppercase :: proc() {
	if task_head != -1 {
		low, high := task_low_and_high()
		manager := mode_panel_manager_scoped()
		task_head_tail_push(manager)

		for i in low..<high + 1 {
			task := tasks_visible[i]
			builder := &task.box.builder
	
			if len(builder.buf) != 0 {
				item := Undo_Builder_Uppercased_Content { builder }
				undo_box_uppercased_content(manager, &item, false)
			}
		}

		element_repaint(mode_panel)
	}
}

todool_tasks_to_lowercase :: proc() {
	if task_head != -1 {
		low, high := task_low_and_high()
		manager := mode_panel_manager_scoped()
		task_head_tail_push(manager)

		for i in low..<high + 1 {
			task := tasks_visible[i]
			builder := &task.box.builder
	
			if len(builder.buf) != 0 {
				item := Undo_Builder_Lowercased_Content { builder }
				undo_box_lowercased_content(manager, &item, false)
			}
		}

		element_repaint(mode_panel)
	}
}

todool_new_file :: proc() {
  if !todool_check_for_saving(window_main) {
	  tasks_load_reset()
	  last_save_location = ""
  }
}

todool_check_for_saving :: proc(window: ^Window) -> (canceled: bool) {
	if options_autosave() {
		todool_save(false)
	} else if dirty != dirty_saved {
		res := dialog_spawn(
			window, 
			"Save progress?\n%l\n%f%B%b%C",
			"Yes",
			"No",
			"Cancel",
		)
		
		switch res {
			case "Yes": {
				todool_save(false)
			}

			case "Cancel": {
				canceled = true
			}

			case "No": {}
		}
	}

	return
}

todool_select_children :: proc() {
	if task_head == -1 {
		return
	}

	if task_head == task_tail {
		task := tasks_visible[task_head]
		length := cutf8.count(strings.to_string(task.box.builder))

		if task.box.head == task.box.tail && task.box.head == length - 1 {
			log.info("try")
		}
	}
}