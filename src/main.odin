package src

import "core:image"
import "core:image/png"
import "core:os"
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

main :: proc() {
	gs_init()
	context.logger = gs.logger

	task_data_init()
	defer task_data_destroy()

	window := window_init("Todool", 900, 900, mem.Megabyte * 10)
	window.name = "main"
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

			case .Dropped_Files: {
				old_indice: int
				for indice in element.window.drop_indices {
					file_path := string(element.window.drop_file_name_builder.buf[old_indice:indice])

					if strings.has_suffix(file_path, ".png") {
						if task_head != -1 {
							task := tasks_visible[task_head]
							handle := image_load_push(file_path)
							task.image_display.img = handle
						}
						// p := sb.tags.panel
						// handle := image_load_push(file_path)
						// image_display_init(p, { .HF }, handle)
					}

					old_indice = indice
				}

				element_repaint(mode_panel)

				// manager := mode_panel_manager_scoped()
				// task_head_tail_push(manager)

				// old_indice: int
				// for indice in element.window.drop_indices {
				// 	file_name := string(element.window.drop_file_name_builder.buf[old_indice:indice])

				// 	content, ok := os.read_entire_file(file_name)
				// 	defer delete(content)

				// 	if ok {
				// 		pattern_load_content(manager, string(content))
				// 	}

				// 	old_indice = indice
				// }

				// element_repaint(mode_panel)
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
		
		// NOTE forces the first task to indentation == 0
		{
			if len(tasks_visible) != 0 {
				task := tasks_visible[0]

				if task.indentation != 0 {
					manager := mode_panel_manager_scoped()
					// NOTE continue the first group
					undo_group_continue(manager) 

					item := Undo_Item_Task_Indentation_Set {
						task = task,
						set = task.indentation,
					}	
					undo_push(manager, undo_task_indentation_set, &item, size_of(Undo_Item_Task_Indentation_Set))

					task.indentation = 0
					task.indentation_animating = true
					element_animation_start(task)
				}
			}
		}

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
		image_load_process_texture_handles(window)

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
