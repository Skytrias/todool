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
// element allow custom allocator

// TODO
// save file -> export to json too, TRY ONE SAVE FILE FOR ALL
// images on top of cards
// breadcrumbs? could do a prompt
// font size for tasks specifically so you could zoom in / out
// add autosave timer & exit scheme

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

// elements that can appear as task data
// folding: bool -> as icon button
// duration spent: time.Duration -> as string
// assigned date: time.Time -> as string
// bookmarks could be display differently as LINE HIGHLIGHT
// recording this -> LINE HIGHLIGHT NOW

// TODAY
// nice copy & paste
// theme editor copy & paste
// mouse dragging tasks

// REST
// SHOCO string compression option
// Changelog options?
// indentation focus prompt?
// timers functionality
// save leaving prompt
// progress bar on kanban?
// camera
// text box copy & paste
// Tab based movement & left / right in dialog panel

// IDEAS
// change alpha of lesser indentations

// import "../nfd"

// main :: proc() {
// 	fmt.eprintln("start")
// 	defer fmt.eprintln("end")

// 	out_path: cstring = "*.c"
// 	// res := nfd.OpenDialog("", "", &out_path)
// 	// fmt.eprintln(res, out_path)

// 	res := nfd.SaveDialog("", "", &out_path)
// 	fmt.eprintln(res, out_path)
// }

main :: proc() {
	gs_init()
	context.logger = gs.logger

	task_data_init()
	defer task_data_destroy()

	window := window_init("Todool", 900, 900)
	window_main = window
	window.element.message_user = proc(element: ^Element, msg: Message, di: int, dp: rawptr) -> int {
		window := cast(^Window) element

		#partial switch msg {
			case .Key_Combination: {
				handled := true
				combo := (cast(^string) dp)^

				if window_focused_shown(window) {
					return 0
				}

				// // if task_head != -1 && !task_has_selection() && len(tasks_visible) > 0 {
				// // 	box := tasks_visible[task_head].box
					
				// // 	if element_message(box, msg, di, dp) == 1 {
				// // 		return 1
				// // 	}
				// // }

				// return int(shortcuts_run_multi(combo))
				return 0
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

			case .Window_Close: {
				if dirty != dirty_saved {
					res := dialog_spawn(
						window, 
						"Leave without saving progress?",
						"%bSave",
						"%bCancel",
						"%bClose Without Saving",
					)
					
					switch res {
						case "Save": {
							log.info("saved")
							editor_save("save.bin")
						}

						case "Cancel": {
							log.info("canceled")
							return 1
						}

						case "Close Without Saving": {
							log.info("close without saving")
						}
					}

					// log.info("res", res)
				}

				log.info("close window", dirty != dirty_saved)
			}
		}

		return 0
	} 

	window.update = proc(window: ^Window) {
		task_set_children_info()
		task_set_visible_tasks()
		task_check_parent_states(nil)
		
		// find dragging index at
		if dragging {
			for task, i in tasks_visible {
				if task.bounds.t < task.window.cursor_y && task.window.cursor_y < task.bounds.b {
					drag_index_at = task.visible_index
					break
				}
			}
		}

		// set bookmarks
		{
			clear(&bookmarks)
			for task, i in tasks_visible {
				if task.bookmarked {
					append(&bookmarks, i)
				}
			}
		}

		// log.info("dirty", dirty, dirty_saved)
		window_title_build(window, dirty != dirty_saved ? "Todool*" : "Todool")

		// just clamp for safety here instead of everywhere
		task_head = clamp(task_head, 0, len(tasks_visible) - 1)
		task_tail = clamp(task_tail, 0, len(tasks_visible) - 1)

		// line changed
		if old_task_head != task_head || old_task_tail != task_tail {
			// call box changes immediatly when leaving task head / tail 
			if len(tasks_visible) != 0 && old_task_head != -1 && old_task_head < len(tasks_visible) {
				task := tasks_visible[old_task_head]
				manager := mode_panel_manager_begin()
				box_force_changes(manager, task.box)
			}
		}

		old_task_head = task_head
		old_task_tail = task_tail
	}

	// add_shortcuts(window)
	sidebar_init(window)
	search_init(window)

	mode_panel = mode_panel_init(&window.element, {})
	mode_panel.gap_vertical = 5
	mode_panel.gap_horizontal = 10

	{
		// task_push(0, "one")
		task_push(0, "two")
		task_push(1, "three")
		// task_push(2, "four")
		// task_push(2, "four")
		// task_push(2, "four")
		task_push(1, "four")
		task_push(1, "five")
		task_push(1, "six")
		task_push(1, "long word to test out mouse selection")
		task_push(0, "long  word to test out word wrapping on this word particular piece of text even longer to test out moreeeeeeeeeeeee")
		task_push(0, "five")
		task_head = 4
		task_tail = 4
	}

	goto_init(window) 
	drag_init(window)

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
