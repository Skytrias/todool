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

TRACK_MEMORY :: true
TODOOL_RELEASE :: false
ALLOW_SCALE :: true

//~~~~~VISUAL STYLING~~~~~
//allow doing a single white background -> issue with wrapped content, maybe dotted outline
//visual highlight parents only

//~~~~~TODO~~~~~
//scrollbar or minimap on mode_panel
//better link detection, maybe scan words once, then on text insertion or undo
//always on top option, needs SDL 2.0.16
//left sidebar doesnt scale nicely
//image display options
//better image zoom/control mode

//system to force push new keybindings for a patch
//keymap setting window
//changelog generator output window
//options animation speed slider
//options autosave should save or in general changing things on the sidebar should be automatic or seperate?
//while search typing set camera to focus atleast search result found
//save automatic state setting by offsetting undo in place, instead of everywhere
//text based format

//~~~~~DONE~~~~~
//shift_right opens folded content
//Commands
//	"select_children" ctrl+h -> selects children, opens folded task, rotates head / tail
//	"paste_from_clipboard" now extracts tab information
//task allocation strategy changed -> fixed leaks
//refactored search internals to be more memory effecient
//save files get written to a temp file again in case of errors, then renamed
//theme editor has foldable header panels
//task dragging 
//	visuals polished + animations
//	floating icons
//	camera scrolls in mouse direction
//	circle outline visualized when pulling tasks out

//~~~~~FIXES~~~~~
//wrapping option only applies to List mode again
//wrapping words corretly that are bigger than the width limit itself
//menus automatically close when dialogs (exit) start
//theme editor color "button" preview crash fixed
//theme editor color picker value dragging and hue slider
//multi-selection not including folded content
//	task dragging
//	delete selection
//	shift right/left
//	state setting
//OOB backspace on empty file crash fixed 
//shift content up / down refactored, keeps indentation & folded, skips folded content
//task dragging end isnt offset by folded content
//task dragging onto empty file works now
//task paste tasks replacing existing tasks till empty crash fixed
//task paste into empty file
//camera crash on empty file
//camera works with global scale now -> no jiggle when scaled in kanban
//camera offsetting on animations-disabled fixed to end directly
//option "invert_y" scroll direction works again

//~~~~~TWEAKS~~~~~
//text strike-through y position adjusted
//shadow offset slightly

main2 :: proc() {
	gs_init()
	context.logger = gs.logger
	context.allocator = gs_allocator()
	window := window_init(nil, {}, "Todool", 900, 900)
	window_main = window

	panel := panel_init(&window.element, {}, 5)

	for i in 0..<3 {
		tp := toggle_panel_init(panel, { .HF }, {}, "Testing")
		tp.panel.color = i == 0 ? BLUE : GREEN

		for i in 0..<10 {
			text := fmt.tprintf("Text %d", i)
			button_init(tp.panel, { .HF }, text)
		}
	}

	gs_update_after_load()
	gs_message_loop()
}

main :: proc() {
	gs_init()
	context.logger = gs.logger
	context.allocator = gs_allocator()

	task_data_init()

	window := window_init(nil, {}, "Todool", 900, 900)
	window.on_resize = proc(window: ^Window) {
		cam := mode_panel_cam()
		cam.freehand = true
	}
	window_main = window
	window.element.message_user = proc(element: ^Element, msg: Message, di: int, dp: rawptr) -> int {
		window := cast(^Window) element

		#partial switch msg {
			case .Key_Combination: {
				handled := true
				combo := (cast(^string) dp)^

				when ALLOW_SCALE {
					if combo == "ctrl++" {
						scaling_set(SCALE + 0.1)
						element_repaint(element)
						return 1
					}

					if combo == "ctrl+-" {
						scaling_set(SCALE - 0.1)
						element_repaint(element)
						return 1
					}
				}

				if window_focused_shown(window) {
					return 0
				}

				s := &window.shortcut_state

				task_head_tail_clamp()
				if task_head != -1 && !task_has_selection() && len(tasks_visible) > 0 {
					box := tasks_visible[task_head].box
					
					if element_message(box, msg, di, dp) == 1 {
						cam := mode_panel_cam()
						cam.freehand = false
						mode_panel_cam_bounds_check_x(caret_rect.l, caret_rect.r, false, false)
						mode_panel_cam_bounds_check_y(caret_rect.t, caret_rect.b, true)
						return 1
					}
				}

				if command, ok := s.general[combo]; ok {
					if shortcuts_command_execute_todool(command) {
						return 1
					}
				}

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
						cam := mode_panel_cam()
						cam.freehand = false
						mode_panel_cam_bounds_check_x(caret_rect.l, caret_rect.r, false, true)
						mode_panel_cam_bounds_check_y(caret_rect.t, caret_rect.b, true)
						task_tail = task_head
					}
					return res
				}
			}

			case .Window_Close: {
				handled := int(todool_check_for_saving(window_main))
		
				// on non handle just destroy all windows
				if handled == 0 {
					gs_windows_iter_init()
					for w in gs_windows_iter_step() {
						window_destroy(w)
					}
				}

				return handled
			}

			case .Dropped_Files: {
				old_indice: int
				manager := mode_panel_manager_begin()
				had_imports := false

				for indice in element.window.drop_indices {
					file_path := string(element.window.drop_file_name_builder.buf[old_indice:indice])

					// image dropping
					if strings.has_suffix(file_path, ".png") {
						if task_head != -1 {
							task := tasks_visible[task_head]
							handle := image_load_push(file_path)
							task_set_img(task, handle)
						}
					} else {
						if !had_imports {
							task_head_tail_push(manager)
						}
						had_imports = true

						// import from code
						content, ok := os.read_entire_file(file_path)
						defer delete(content)

						if ok {
							pattern_load_content(manager, string(content))
						}
					}

					old_indice = indice
				}

				if had_imports {
					undo_group_end(manager)
				}

				element_repaint(mode_panel)
			}

			case .Deallocate: {
				tasks_clear_left_over()
			}
		}

		return 0
	} 

	window.update = proc(window: ^Window) {
		task_set_children_info()
		task_set_visible_tasks()
		task_check_parent_states(nil)

		// just set the font options once here
		for task in tasks_visible {
			task.font_options = task.has_children ? &font_options_bold : nil
		}
		
		// find dragging index at
		if drag_running {
			if !window_mouse_inside(window) {
				// set index to invalid
				drag_index_at = -1
			} else {
				for task, i in tasks_visible {
					if rect_contains(task.bounds, window.cursor_x, window.cursor_y) {
						drag_index_at = task.visible_index
						break
					}
				}
			}

			window_set_cursor(window, .Hand_Drag)
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

		// title building
		{
			b := &window.title_builder
			strings.builder_reset(b)
			strings.write_string(b, "Todool: ")
			strings.write_string(b, last_save_location)
			strings.write_string(b, dirty != dirty_saved ? " * " : " ")
			window_title_push_builder(window, b)
		}

		task_head_tail_clamp()

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

		// shadow animation
		{
			// animate up
			if 
				task_head != task_tail &&
				!task_shadow_alpha_animating && 
				task_shadow_alpha == 0 {
				// task_shadow_alpha 
				task_shadow_alpha_animating = true
				element_animation_start(mode_panel)
			}

			// animate down
			if 
				task_head == task_tail &&
				!task_shadow_alpha_animating && 
				task_shadow_alpha != 0 {
				task_shadow_alpha_animating = true
				element_animation_start(mode_panel)
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

	// keymap loading
	if loaded := keymap_load("save.keymap"); !loaded {
		shortcuts_push_todool_default(window)
		shortcuts_push_box_default(window)
		log.info("KEYMAP: Load failed -> Loading default")
	} else {
		log.info("KEYMAP: Load successful")
	}

	// add_shortcuts(window)
	panel := panel_init(&window.element, { .Panel_Horizontal, .Tab_Movement_Allowed })
	sidebar_panel_init(panel)

	{
		rect := window_rect(window)
		split := split_pane_init(panel, { .Split_Pane_Hidable, .VF, .HF, .Tab_Movement_Allowed }, 300, 300)
		split.pixel_based = true
		sb.split = split
	}	

	sidebar_enum_panel_init(sb.split)
	task_panel_init(sb.split)

	goto_init(window) 

	if loaded := json_load_misc("save.sjson"); loaded {
		log.info("JSON: Load Successful")
	} else {
		log.info("JSON: Load failed -> Using default")
	}

	// tasks_load_reset()
	// tasks_load_tutorial()
	// tasks_load_default()
	tasks_load_file()

	// do actual loading later because options might change the path
	gs_update_after_load()
	
	gs_message_loop()
}
