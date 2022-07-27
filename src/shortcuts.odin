package src

import "core:strings"
import "core:log"
import "core:mem"

// Undo_Item_Bool_Saved :: struct {
// 	to: bool,
// }

// undo_bool_saved :: proc(manager: ^Undo_Manager, item: rawptr) {
// 	data := cast(^Undo_Item_Bool_Saved) item

// 	title := data.to ? "Todool*" : "Todool"
// 	window_title_build(mode_panel.window, title)

// 	editor_pushed_unsaved = false

// 	data.to = !data.to
// 	undo_push(manager, undo_bool_saved, item, size_of(Undo_Item_Bool_Saved))
// }

// editor_set_unsaved_changes_title :: proc(manager: ^Undo_Manager) {
// 	if !editor_pushed_unsaved {
// 		item := Undo_Item_Bool_Saved { true }
// 		undo_bool_saved(manager, &item)
// 		editor_pushed_unsaved = true
// 	}
// }

Undo_Item_Int_Increase :: struct {
	value: ^int,
}

Undo_Item_Int_Set :: struct {
	value: ^int,
	to: int,
}

undo_int_increase :: proc(manager: ^Undo_Manager, item: rawptr) {
	data := cast(^Undo_Item_Int_Increase) item
	output := Undo_Item_Int_Set { data.value, data.value^ }
	data.value^ += 1
	undo_push(manager, undo_int_set, &output, size_of(Undo_Item_Int_Set))
}

undo_int_set :: proc(manager: ^Undo_Manager, item: rawptr) {
	data := cast(^Undo_Item_Int_Set) item
	data.value^ = data.to
	output := Undo_Item_Int_Increase { data.value }
	undo_push(manager, undo_int_increase, &output, size_of(Undo_Item_Int_Increase))
}

dirty_push :: proc(manager: ^Undo_Manager) {
	if dirty == dirty_saved {
		item := Undo_Item_Int_Increase { &dirty }
		undo_int_increase(manager, &item)
	}
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

undo_task_swap :: proc(manager: ^Undo_Manager, item: rawptr) {
	data := cast(^Undo_Item_Task_Swap) item
	data.a^, data.b^ = data.b^, data.a^
	undo_push(manager, undo_task_swap, item, size_of(Undo_Item_Task_Swap))	
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
	undo_task_swap(manager, &item)

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
}

Undo_Item_Task_Insert_At :: struct {
	index: int,
	task: ^Task, // the task you want to insert
}

undo_task_remove_at :: proc(manager: ^Undo_Manager, item: rawptr) {
	data := cast(^Undo_Item_Task_Remove_At) item

	output := Undo_Item_Task_Insert_At {
		data.index, 
		cast(^Task) mode_panel.children[data.index],
	} 

	// TODO maybe speedup somehow?
	ordered_remove(&mode_panel.children, data.index)
	undo_push(manager, undo_task_insert_at, &output, size_of(Undo_Item_Task_Insert_At))
}

undo_task_insert_at :: proc(manager: ^Undo_Manager, item: rawptr) {
	data := cast(^Undo_Item_Task_Insert_At) item
	insert_at(&mode_panel.children, data.index, data.task)

	output := Undo_Item_Task_Remove_At { data.index }
	undo_push(manager, undo_task_remove_at, &output, size_of(Undo_Item_Task_Remove_At))
}

Undo_Item_Task_Append :: struct {
	task: ^Task,
}

Undo_Item_Task_Pop :: struct {}

undo_task_append :: proc(manager: ^Undo_Manager, item: rawptr) {
	data := cast(^Undo_Item_Task_Append) item
	append(&mode_panel.children, data.task)
	output := Undo_Item_Task_Pop {}
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

shortcuts_run_multi :: proc(combo: string) -> (handled: bool) {
	handled = true

	switch combo {
		case "ctrl+backspace", "backspace": {
			task := tasks_visible[task_head]
			
			if len(task.box.builder.buf) == 0 {
				manager := mode_panel_manager_scoped()
				task_head_tail_push(manager)
				index := task.index
				
				if index == len(mode_panel.children) {
					item := Undo_Item_Task_Pop {}
					undo_task_pop(manager, &item)
				} else {
					item := Undo_Item_Task_Remove_At { index }
					undo_task_remove_at(manager, &item)
				}

				element_repaint(task)
				task_head -= 1
				task_tail -= 1
			}
		}

		case "shift+up", "up": {
			if task_head == -1 {
				return
			}

			task_head -= 1
			task_tail_check()
			bookmark_index = -1
			task := tasks_visible[max(task_head, 0)]
			element_repaint(mode_panel)
			element_message(task.box, .Box_Set_Caret, BOX_END)
		}

		case "shift+down", "down": {
			if task_head == -1 {
				return 
			}

			task_head += 1
			task_tail_check()
			bookmark_index = -1

			task := tasks_visible[min(task_head, len(tasks_visible) - 1)]
			element_message(task.box, .Box_Set_Caret, BOX_END)
			element_repaint(mode_panel)
		}

		// move to indentation 0 next
		case "ctrl+,", "ctrl+shift+,": {
			if task_head != -1 {
				task_current := tasks_visible[task_head]

				for i := task_current.index - 1; i >= 0; i -= 1 {
					task := cast(^Task) mode_panel.children[i]

					if task.indentation == 0 && task.visible {
						task_head = task.visible_index
						task_tail_check()
						element_message(task.box, .Box_Set_Caret, BOX_END)
						element_repaint(task)
						break
					}
				}
			}
		}

		// move to indentation 0 next
		case "ctrl+.", "ctrl+shift+.": {
			if task_head != -1 {
				task_current := tasks_visible[task_head]

				for i in task_current.index + 1..<len(mode_panel.children) {
					task := cast(^Task) mode_panel.children[i]

					if task.indentation == 0 && task.visible {
						task_head = task.visible_index
						task_tail_check()
						element_repaint(task)
						element_message(task.box, .Box_Set_Caret, BOX_END)
						break
					}
				}
			}
		}

		// move down to same indentation
		case "ctrl+up", "ctrl+shift+up": {
			if task_head == -1 {
				return
			}

			task_current := tasks_visible[task_head]

			for i := task_head - 1; i >= 0; i -= 1 {
				task := tasks_visible[i]
				
				if task.indentation == task_current.indentation {
					task_head = i
					task_tail_check()
					element_repaint(mode_panel)
					element_message(task.box, .Box_Set_Caret, BOX_END)
					break
				}
			} 
		}

		// move up to same indentation
		case "ctrl+down", "ctrl+shift+down": {
			if task_head == -1 {
				return false
			}

			task_current := tasks_visible[task_head]

			for i := task_head + 1; i < len(tasks_visible); i += 1 {
				task := tasks_visible[i]
				
				if task.indentation == task_current.indentation {
					task_head = i
					task_tail_check()
					element_repaint(mode_panel)
					element_message(task.box, .Box_Set_Caret, BOX_END)
					break
				}
			} 
		}

		// move up a parent, optional shift
		case "ctrl+home", "ctrl+shift+home": {
			if task_head == -1 {
				return false
			}

			task_current := tasks_visible[task_head]

			for i := task_head - 1; i >= 0; i -= 1 {
				task := tasks_visible[i]
				
				if task.indentation < task_current.indentation {
					task_head = i
					task_tail_check()
					element_repaint(mode_panel)
					element_message(task.box, .Box_Set_Caret, BOX_END)
					break
				}
			} 
		}

		// jump from tag to tag
		case "ctrl+tab", "ctrl+shift+tab": {
			if len(bookmarks) != 0 {
				bookmark_advance(mode_panel.window.shift)
				index := bookmarks[bookmark_index]
				task := tasks_visible[index]
				task_head = task.visible_index
				task_tail = task.visible_index
				element_repaint(mode_panel)
			}
		}

		case: {
			handled = false
		}
	}

	return handled
}

add_shortcuts :: proc(window: ^Window) {
	window_add_shortcut(window, "escape", proc() -> bool {
		if sb.mode != .None {
			sidebar_mode_toggle(.None)
			element_repaint(mode_panel)
		}

		return true
	})

	window_add_shortcut(window, "ctrl+1", proc() -> bool {
		tag_toggle(0x01)
		return true
	})

	window_add_shortcut(window, "ctrl+2", proc() -> bool {
		tag_toggle(0x02)
		return true
	})

	window_add_shortcut(window, "ctrl+3", proc() -> bool {
		tag_toggle(0x04)
		return true
	})

	window_add_shortcut(window, "ctrl+4", proc() -> bool {
		tag_toggle(0x08)
		return true
	})

	window_add_shortcut(window, "ctrl+5", proc() -> bool {
		tag_toggle(0x10)
		return true
	})

	window_add_shortcut(window, "ctrl+6", proc() -> bool {
		tag_toggle(0x20)
		return true
	})

	window_add_shortcut(window, "ctrl+7", proc() -> bool {
		tag_toggle(0x40)
		return true
	})

	window_add_shortcut(window, "ctrl+8", proc() -> bool {
		tag_toggle(0x80)
		return true
	})

	// toggle folding
	window_add_shortcut(window, "ctrl+j", proc() -> bool {
		if task_head != -1 {
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

		return true
	})

	// task state change
	window_add_shortcut(window, "ctrl+q", proc() -> bool {
		if task_head == -1 {
			return true
		}

		manager := mode_panel_manager_scoped()
		task_head_tail_push(manager)
			
		selection := task_has_selection()
		low, high := task_low_and_high()

		// modify all states
		for i in low..<high + 1 {
			task := tasks_visible[i]

			if task.has_children {
				continue
			}

			goal := u8(task.state)
			if goal < len(Task_State) - 1 {
				goal += 1
			} else {
				goal = 0
			}

			// save old set
			task_set_state_undoable(manager, task, Task_State(goal))
		}

		element_repaint(mode_panel)
		return true
	})

	task_indentation_move :: proc(amt: int) -> bool {
		if task_head == -1 {
			return false
		}

		low, high := task_low_and_high()
		manager := mode_panel_manager_scoped()
		task_head_tail_push(manager)

		for i in low..<high + 1 {
			task := tasks_visible[i]

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
		return true
	}

	window_add_shortcut(window, "tab", proc() -> bool {
		return task_indentation_move(1)
	})

	window_add_shortcut(window, "shift+tab", proc() -> bool {
		return task_indentation_move(-1)
	})

	window_add_shortcut(window, "return", proc() -> bool {
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
		task_tail_check()
		element_repaint(mode_panel)

		return true
	})

	window_add_shortcut(window, "ctrl+return", proc() -> bool {
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

			// uppercase word
			if !current_task.has_children && options_uppercase_word() {
				item := Undo_Builder_Uppercased_Content { &current_task.box.builder }
				undo_box_uppercased_content(manager, &item)
			}
		}

		task_push_undoable(manager, indentation, "", goal)
		task_head += 1
		task_tail_check()
		element_repaint(mode_panel)

		return true
	})

	window_add_shortcut(window, "ctrl+d", proc() -> bool {
		if task_head == -1 {
			return true
		}

		manager := mode_panel_manager_scoped()
		task_head_tail_push(manager)

		low, high := task_low_and_high()
		remove_count: int
		for i := low; i < high + 1; i += 1 {
			item := Undo_Item_Task_Remove_At {
				tasks_visible[i].index - remove_count,
			}
			undo_task_remove_at(manager, &item)
			remove_count += 1
		}

		task_head = low - 1
		task_tail = low - 1
		element_repaint(mode_panel)
		return true
	})

	window_add_shortcut(window, "alt+q", proc() -> bool {
		if mode_panel.mode != .List {
			mode_panel.mode = .List
			element_repaint(mode_panel)
		}	

		return true
	})

	window_add_shortcut(window, "alt+w", proc() -> bool {
		if mode_panel.mode != .Kanban {
			mode_panel.mode = .Kanban
			element_repaint(mode_panel)
		}	

		return true
	})

	window_add_shortcut(window, "alt+down", proc() -> bool {
		selection := task_has_selection()
		low, high := task_low_and_high()

		if high + 1 >= len(tasks_visible) {
			return false
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
		return true
	}) 

	window_add_shortcut(window, "alt+up", proc() -> bool {
		selection := task_has_selection()
		low, high := task_low_and_high()

		if low - 1 < 0 {
			return false
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
		return true
	}) 

	window_add_shortcut(window, "ctrl+shift+a", proc() -> bool {
		task_tail = 0
		task_head = len(tasks_visible)
		element_repaint(mode_panel)
		return true
	})

	window_add_shortcut(window, "alt+1", proc() -> bool {
		theme_editor_spawn()
		return true
	})

	window_add_shortcut(window, "ctrl+z", proc() -> bool {
		manager := &mode_panel.window.manager
		if !undo_is_empty(manager, false) {
			// reset bookmark index
			bookmark_index = -1

			undo_invoke(manager, false)
			element_repaint(mode_panel)
		}
		return true
	})

	window_add_shortcut(window, "ctrl+y", proc() -> bool {
		manager := &mode_panel.window.manager
		if !undo_is_empty(manager, true) {
			// reset bookmark index
			bookmark_index = -1

			undo_invoke(manager, true)
			element_repaint(mode_panel)
		}

		return true
	})

	window_add_shortcut(window, "ctrl+s", proc() -> bool {
		err := editor_save("save.bin")
		if err != .None {
			log.info("SAVE: FAILED =", err)
		}

		// when anything was pushed - set to false
		if dirty != dirty_saved {
			dirty_saved = dirty
		}
	
		element_repaint(mode_panel)
		// log.info("saved")
		return true
	})

	window_add_shortcut(window, "ctrl+o", proc() -> bool {
		// {
		// 	manager := mode_panel_manager_scoped()
		// 	item := Undo_Item_Task_Clear {}
		// 	undo_task_clear(manager, &item)
		// }

		err := editor_load("save.bin")
		if err != .None {
			log.info("LOAD: FAILED =", err)
		}

		element_repaint(mode_panel)
		return true
	})

	// set tags to selected lines
	window_add_shortcut(window, "ctrl+b", proc() -> bool {
		if task_head != -1 {
			low, high := task_low_and_high()
			manager := mode_panel_manager_scoped()
			task_head_tail_push(manager)

			for i in low..<high + 1 {
				task := tasks_visible[i]
				item := Undo_Item_Bool_Toggle { &task.bookmarked }
				undo_bool_toggle(manager, &item)
			}

			element_repaint(mode_panel)
		}

		return true	
	})
}
