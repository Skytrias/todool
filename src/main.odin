package src

import "core:mem"
import "core:math"
import "core:time"
import "core:strings"
import "core:fmt"
import "core:log"
import "core:math/rand"
import sdl "vendor:sdl2"
import "../fontstash"

// TODO UI
// scrollbar horizontal
// scaling looks off for rectangle outlines -> maybe round
// window title setting

// TODO ELEMENT DATA
// allow custom allocator

// TODO
// save file -> export to json too
// task sorting
// images on top of cards
// breadcrumbs?
// edit & navigation mode? would help immensly for easier navigation
// unsaved/saved tracking
// font size for tasks

// ADDED
// line selection now head + tail based, similar to text box selections
// all actions should work with line selections
// up / down shift dont change indentation
// indentation highlights
// mouse selection with shift is only moving head now
// mouse click counts in software per element, not native

// CHANGED
// popup windows to change settings or toggle things
// popup windows for options or show / render inline?
// reworked UNDO / REDO internals - more memory efficient

// WEBSITE 
// work on a proper website

// DEVLOG
// FREITAG FRÜH
//	more detail with task head & tail movement
// SAMSTAG 
//	UI redesigning -> heavy ui like theme editor in separate window
//	color picker for theme editor
//	clipboard message
//	hovered element support

// elements that can appear as task data
// folding: bool -> as icon button
// duration spent: time.Duration -> as string
// assigned date: time.Time -> as string

// bookmarks could be display differently as LINE HIGHLIGHT
// recording this -> LINE HIGHLIGHT NOW

Mode_Based_Button :: struct {
	index: int,
}

mode_based_button_message :: proc(element: ^Element, msg: Message, di: int, dp: rawptr) -> int {
	button := cast(^Button) element
	info := cast(^Mode_Based_Button) element.data

	#partial switch msg {
		case .Button_Highlight: {
			color := cast(^Color) dp
			selected := info.index == int(mode_panel.mode)
			color^ = selected ? theme.text_default : theme.text_blank
			return selected ? 1 : 2
		}

		case .Clicked: {
			set := cast(^int) &mode_panel.mode
			if set^ != info.index {
				set^ = info.index
				element_repaint(element)
			}
		}

		case .Deallocate_Recursive: {
			free(element.data)
		}
	}

	return 0
}

main :: proc() {
	gs_init()
	context.logger = gs.logger

	font_options_header = {
		font = font_bold,
		size = 30,
	}
	font_options_bold = {
		font = font_bold,
		size = DEFAULT_FONT_SIZE + 5,
	}

	// init global state
	tasks_visible = make([dynamic]^Task, 0, 128)
	defer delete(tasks_visible)

	window := window_init("Todool", 900, 900)
	window.scale = 1.

	window.element.message_user = proc(element: ^Element, msg: Message, di: int, dp: rawptr) -> int {
		window := cast(^Window) element

		#partial switch msg {
			case .Key_Combination: {
				handled := true
				combo := (cast(^string) dp)^

				if window_focused_shown(window) {
					return 0
				}

				if task_head != -1 && !task_has_selection() && len(tasks_visible) > 0 {
					box := tasks_visible[task_head].box
					
					if element_message(box, msg, di, dp) == 1 {
						return 1
					}
				}

				return int(shortcuts_run_multi(combo))
			}

			case .Unicode_Insertion: {
				if window_focused_shown(window) {
					return 0
				}

				if task_head != -1 {
					task_focused := tasks_visible[task_head]
					res := element_message(task_focused.box, msg, di, dp)
					if res == 1 {
						task_tail = task_head
					}
					return res
				}
			}
		}

		return 0
	} 

	window.update = proc() {
		clear(&tasks_visible)

		// set parental info
		task_parent_stack[0] = nil
		prev: ^Task
		for child, i in mode_panel.children {
			task := cast(^Task) child
			task.index = i
			task.has_children = false

			if prev != nil {
				if prev.indentation < task.indentation {
					prev.has_children = true
					task_parent_stack[task.indentation] = prev
				} 
			}

			prev = task
			task.visible_parent = task_parent_stack[task.indentation]
		}

		// set visible lines based on fold of parents
		for child in mode_panel.children {
			task := cast(^Task) child
			p := task.visible_parent
			task.visible = true

			// unset folded 
			if !task.has_children {
				task.folded = false
			}

			// recurse up 
			for p != nil {
				if p.folded {
					task.visible = false
				}

				p = p.visible_parent
			}
			
			if task.visible {
				// just update icon & hide each
				element_message(task.button_fold, .Update)
				element_hide(task.button_fold, !task.has_children)
				task.visible_index = len(tasks_visible)
				append(&tasks_visible, task)
			}
		}

		// just clamp for safety here instead of everywhere
		task_head = clamp(task_head, 0, len(tasks_visible) - 1)
		task_tail = clamp(task_tail, 0, len(tasks_visible) - 1)

		if old_task_head != task_head || old_task_tail != task_tail {
			if len(tasks_visible) != 0 && old_task_head != -1 && old_task_head < len(tasks_visible) {
				task := tasks_visible[old_task_head]
				manager := mode_panel_manager_begin()
				box_force_changes(manager, task.box)
			}
		}

		old_task_head = task_head
		old_task_tail = task_tail
	}

	add_shortcuts(window)
	sidebar_init(window)

	mode_panel = mode_panel_init(&window.element, {})
	mode_panel.gap_vertical = 5
	mode_panel.gap_horizontal = 10

	{
		task_push(0, "one")
		task_push(0, "two")
		task_push(1, "three")
		task_push(2, "four")
		task_push(2, "four")
		task_push(2, "four")
		task_push(1, "four")
		task_push(1, "long word to test out mouse selection")
		task_push(0, "long word to test out word wrapping on this particular piece of text even longer to test out moreeeeeeeeeeeee")
		task_push(0, "five")
		task_head = 4
		task_tail = 4
	}

	gs_message_loop()
}

// table_test :: proc() {
// 	window := window_init("table", 500, 500)
// 	panel := panel_init(&window.element, { .CF })
// 	panel.color = theme.background[0]
// 	panel.margin = 10
// 	panel.gap = 5

// 	button_init(panel, { .CT, .CF }, "testing")
// 	// button_init(panel, { .CF }, "testing")
// 	table := table_init(panel, { .CF }, "ABC\tXYZ\tTEST")
// 	table.column_count = 3
// 	table.message_user = proc(element: ^Element, msg: Message, di: int, dp: rawptr) -> int {
// 		table := cast(^Table) element

// 		#partial switch msg {
// 			case .Table_Get_Item: {
// 				item := cast(^Table_Get_Item) dp
// 				item.output = fmt.bprint(item.buffer, "test############")
// 				// log.info(item.output)
// 			}
// 		}

// 		return 0
// 	}

// 	table.item_count = 10
// 	table_resize_columns(table)
// }
