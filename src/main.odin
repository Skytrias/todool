package src

import "core:encoding/json"
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
// images on top of cards
// breadcrumbs? could do a prompt
// font size for tasks specifically so you could zoom in / out
// notifications -> libnotify on linux works, winrt on windows?

// major
// changelog gen
// import from files

// WEBSITE 
// work on a proper website

// elements that can appear as task data
// folding: bool -> as icon button
// duration spent: time.Duration -> as string
// assigned date: time.Time -> as string
// recording this -> LINE HIGHLIGHT NOW

// REST
// SHOCO string compression option
// Changelog options?
// indentation focus prompt?
// progress bar on kanban?

// DONE
// text box copy & paste
// slider formatting better, shift for varying clamps
// timers functionality
// statistics
// timer sounds
// volume slider
// add autosave timer & exit scheme
// copy tree as raw text

// import "../notify"

// main :: proc() {
// 	notify.init("todool")
// 	defer notify.uninit()

// 	notify.run("Todool Pomodoro Timer Finished", "", "dialog-information")
// }

// import "../nfd"
// main2 :: proc() {
// 	fmt.eprintln("start")
// 	defer fmt.eprintln("end")

// 	out_path: cstring = "*.c"
// 	res := nfd.OpenDialog("", "", &out_path)
// 	fmt.eprintln(res, out_path)

// 	// res := nfd.SaveDialog("", "", &out_path)
// 	// fmt.eprintln(res, out_path)
// }

// T_Event :: struct {
// 	data: rawptr,
// }

import "core:intrinsics"

// rawptr should be enough since you know what you'll pass to the procedures
// entry = proc(data: rawptr) {
//   your_data := cast(^Your_Data_Type) data	
// }
Finite_State_Calls :: struct {
	entry: proc(data: rawptr),
	exit: proc(data: rawptr),
	remain: proc(data: rawptr),

	data: rawptr, // passed to calls?
}

Finite_State :: enum {
	One,
	Two,
	Three,
}

Finite_State_Machine :: struct($A: typeid, $B: typeid) 
	where intrinsics.type_is_enum(A), intrinsics.type_is_enum(B)
{
	name: string,
	// transition_table: [A][B]A, // whats this?
	call_table: [A]Finite_State_Calls,
	current_state: A,
}

Test_A :: enum {
	One,
	Two,
	Three,
}

Test_B :: enum {
	One,
	Two,
	Three,
}

main :: proc() {
	fsm: Finite_State_Machine(Test_A, Test_B) 
}

main2 :: proc() {
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
				if options_autosave() {
					editor_save("save.todool")
				} else if dirty != dirty_saved {
					res := dialog_spawn(
						window, 
						"Leave without saving progress?\n%l\n%f%b%C%B",
						"Close Without Saving",
						"Cancel",
						"Save",
					)
					
					switch res {
						case "Save": {
							editor_save("save.todool")
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

		pomodoro_update()
	}

	add_shortcuts(window)
	panel := panel_init(&window.element, { .Panel_Horizontal, .Tab_Movement_Allowed })
	split := sidebar_init(panel)

	task_panel_init(split)

	goto_init(window) 
	drag_init(window)

	tasks_load_file()
	json_load_misc("save.sjson")

	gs_message_loop()
}
