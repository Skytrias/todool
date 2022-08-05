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

// SHOWCASE TODO 
// changed layouting to nakst one Row / Column
// nfd showcase
// dragging
// dialog polish
// camera bound checked

// REST
// SHOCO string compression option
// Changelog options?
// indentation focus prompt?
// timers functionality
// progress bar on kanban?
// camera
// text box copy & paste

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

			case .Window_Close: {
				if dirty != dirty_saved {
					res := dialog_spawn(
						window, 
						"Leave without saving progress?\n%l\n%f%b%C%B",
						"Close Without Saving",
						"Cancel",
						"Save",
					)
					
					switch res {
						case "Save": {
							editor_save("save.bin")
						}

						case "Cancel": {
							return 1
						}

						case "Close Without Saving": {}
					}
				}
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
				cam := mode_panel_cam()
				cam.freehand = false

				task := tasks_visible[old_task_head]
				manager := mode_panel_manager_begin()
				box_force_changes(manager, task.box)
			}
		}

		old_task_head = task_head
		old_task_tail = task_tail
	}

	add_shortcuts(window)
	panel := panel_init(&window.element, { .Panel_Horizontal, .Tab_Movement_Allowed })
	split := sidebar_init(panel)

	task_panel_init(split)

	goto_init(window) 
	drag_init(window)

	gs_message_loop()
}
