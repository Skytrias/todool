package src

import "core:runtime"
import "core:math/bits"
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
import "core:unicode"
import "core:thread"
import "core:intrinsics"
import sdl "vendor:sdl2"
import "heimdall:fontstash"
import "../spall"
import "../cutf8"
import "../btrie"

SHOW_FPS :: false
POOL_DEBUG :: false
TRACK_MEMORY :: false
TODOOL_RELEASE :: false
PRESENTATION_MODE :: false
DEMO_MODE :: false // wether or not save&load are enabled
VERSION :: "0.4.0"

main :: proc() {
	spall.init("test.spall")
	spall.begin("init all", 0)
	defer spall.destroy()

	gs_init()
	context.logger = gs.logger
	context.allocator = gs_allocator()

	theme_presets_init()
	app = app_init()

	window := window_init(nil, {}, "Todool", 900, 900, 256, 256)
	window.on_resize = proc(window: ^Window) {
		cam := mode_panel_cam()
		mode_panel_cam_freehand_on(cam)
	}
	app.window_main = window
	window.element.message_user = window_main_message
	window.update_before = main_update
	window.update_check = proc(window: ^Window) -> (handled: bool) {
		handled |= power_mode_running()
		handled |= caret_state_update_motion(&app.caret, true)
		handled |= caret_state_update_alpha(&app.caret)
		handled |= caret_state_update_outline(&app.caret)
		handled |= mode_panel_zoom_running()
		handled |= app_focus_alpha_animate() != 0
		handled |= progressbars_animate()
		handled |= app_shadow_animate()
		handled |= bookmark_alpha_animate()
		return
	}
	window.name = "MAIN"

	{
		spall.scoped("load keymap")
		// keymap loading

		keymap_push_todool_commands(&app.window_main.keymap_custom)
		keymap_push_box_commands(&app.window_main.keymap_box)
		// NOTE push default todool to vim too
		keymap_push_todool_commands(&app.keymap_vim_normal)
		keymap_push_vim_normal_commands(&app.keymap_vim_normal)
		keymap_push_vim_insert_commands(&app.keymap_vim_insert)

		if loaded := keymap_load("save.keymap"); !loaded {
			// just clear since data could be loaded
			keymap_clear_combos(&app.window_main.keymap_custom)
			keymap_clear_combos(&app.window_main.keymap_box)
			keymap_clear_combos(&app.keymap_vim_normal)
			keymap_clear_combos(&app.keymap_vim_insert)
			
			keymap_push_todool_combos(&app.window_main.keymap_custom)
			keymap_push_box_combos(&app.window_main.keymap_box)
			keymap_push_vim_normal_combos(&app.keymap_vim_normal)
			keymap_push_vim_insert_combos(&app.keymap_vim_insert)

			keymap_force_push_latest(&app.window_main.keymap_custom)
			keymap_force_push_latest(&app.keymap_vim_normal)

			log.info("KEYMAP: Load failed -> Loading default")
		} else {
			log.info("KEYMAP: Load successful")
		}
	}

	{
		spall.scoped("gen elements")

		// add_shortcuts(window)
		menu_split, menu_bar := todool_menu_bar(&window.element)
		app.task_menu_bar = menu_bar
		panel := panel_init(menu_split, { .Panel_Horizontal, .Tab_Movement_Allowed })
		statusbar_init(&statusbar, menu_split)
		sidebar_panel_init(panel)

		{
			rect := window.rect
			split := split_pane_init(panel, { .Split_Pane_Hidable, .VF, .HF, .Tab_Movement_Allowed }, 300, 300)
			split.pixel_based = true
			sb.split = split
		}	

		sidebar_enum_panel_init(sb.split)
		task_panel_init(sb.split)

		goto_init(window) 
	}

	{
		spall.scoped("load sjson")
		if loaded := json_load_misc("save.sjson"); loaded {
			log.info("JSON: Load Successful")
		} else {
			log.info("JSON: Load failed -> Using default")
		}
	}

	// tasks_load_tutorial()
	tasks_load_file()

	// do actual loading later because options might change the path
	gs_update_after_load()
	spall.end(0)

	when PRESENTATION_MODE {
		window_border_set(window_main, false)
	}

	defer {
		intrinsics.atomic_store(&app.main_thread_running, false)
	}

	gs_message_loop()
}

main_box_key_combination :: proc(window: ^Window, msg: Message, di: int, dp: rawptr) -> int {
	task_head_tail_clamp()
	if app.task_head != -1 && app_has_no_selection() && app_filter_not_empty() {
		box := app_task_filter(app.task_head).box

		if element_message(box, msg, di, dp) == 1 {
			cam := mode_panel_cam()
			mode_panel_cam_freehand_off(cam)
			mode_panel_cam_bounds_check_x(cam, app.caret.rect.l, app.caret.rect.r, false, false)
			mode_panel_cam_bounds_check_y(cam, app.caret.rect.t, app.caret.rect.b, true)
			return 1
		}
	}

	return 0
}

main_update :: proc(window: ^Window) {
	// fmt.eprintln(font_regular, font_bold, font_icon)

	rendered_glyphs_clear()
	wrapped_lines_clear()

	task_set_children_info()
	task_check_parent_states(&app.um_task)

	switch app.task_state_progression {
		case .Idle: {}
		case .Update_Instant: {
			for index in app.pool.filter {
				task := app_task_list(index)

				if task_has_children(task) {
					task_progress_state_set(task)
				}
			}
		}
		case .Update_Animated: {
			for index in app.pool.filter {
				task := app_task_list(index)

				if task_has_children(task) {
					element_animation_start(&task.element)
				} else {
					task.progress_animation = {}
				}
			}
		}
	}
	app.task_state_progression = .Idle

	// just set the font options once here
	for index in app.pool.filter {
		task := app_task_list(index)
		task.element.font_options = task_has_children(task) ? &app.font_options_bold : nil
	}

	task_dragging_check_find(window)
	bookmarks_clear_and_set()

	// title building
	{
		b := &window.title_builder
		strings.builder_reset(b)
		strings.write_string(b, "Todool: ")
		strings.write_string(b, strings.to_string(app.last_save_location))
		strings.write_string(b, app.dirty != app.dirty_saved ? " * " : " ")
		// fmt.sbprintf(b, "| acc %.3f | dt %.3f ", gs.accumulator, gs.dt)
		window_title_push_builder(window, b)
	}

	task_head_tail_clamp()

	// keep the head / tail at the position of the task you set it to at some point
	if task, ok := app.keep_task_position.?; ok {
		if app_filter_not_empty() && !task.removed {
			app.task_head = task.filter_index
			app.task_tail = app.task_head
		}

		app.keep_task_position = nil
	}

	// line changed
	if app.old_task_head != app.task_head || app.old_task_tail != app.task_tail {
		// call box changes immediatly when leaving task head / tail 
		if app_filter_not_empty() && app.old_task_head != -1 && app.old_task_head < len(app.pool.filter) {
			cam := mode_panel_cam()

			mode_panel_cam_freehand_off(cam)
			task := app_task_filter(app.old_task_head)
			box_force_changes(&app.um_task, task.box)

			// add spell checking results to user dictionary
			spell_check_mapping_words_add(ss_string(&task.box.ss))

			// save last state
			// app.caret.last_state = task.state
		}
	}

	app.old_task_head = app.task_head
	app.old_task_tail = app.task_tail

	pomodoro_update()
	image_load_process_texture_handles(window)

	statusbar_update(&statusbar)
	power_mode_set_caret_color()

	for cam in &app.mmpp.cam {
		cam_update_check(&cam)
	}

	// check focus outside
	if app_filter_not_empty() && app.focus.root != nil {
		app_focus_bounds()

		if !(app.focus.start <= app.task_head && app.task_head < app.focus.end) || !task_has_children(app.focus.root) {
			app.focus.root = nil
		}
	}

	app_focus_alpha_update()
	mode_panel_zoom_update()
	progressbars_update()
	app_shadow_update()
	bookmark_alpha_update()
}

window_main_message :: proc(element: ^Element, msg: Message, di: int, dp: rawptr) -> int {
	window := cast(^Window) element

	#partial switch msg {
		case .Key_Combination: {
			handled := true
			combo := (cast(^string) dp)^
	
			if window_focused_shown(window) || window.dialog != nil {
				return 0
			}

			if options_vim_use() {
				if vim.insert_mode {
					if main_box_key_combination(window, msg, di, dp) == 1 {
						return 1
					}
	
					// allow unicode insertion
					if keymap_combo_execute(&app.keymap_vim_insert, combo) {
						return 1
					}
				} else {
					// ignore unicode insertion always
					keymap_combo_execute(&app.keymap_vim_normal, combo)
					return 1
				}
			} else {
				if main_box_key_combination(window, msg, di, dp) == 1 {
					return 1
				}

				{
					spall.fscoped("keymap general execute %s", combo)
					if keymap_combo_execute(&window.keymap_custom, combo) {
						return 1
					}
				}
			}

			return 0
		}

		case .Unicode_Insertion: {
			if window_focused_shown(window) || window.dialog != nil {
				return 0
			}

			if app_filter_not_empty() {
				task_focused := app_task_head()
				res := element_message(task_focused.box, msg, di, dp)

				if res == 1 {
					cam := mode_panel_cam()
					mode_panel_cam_freehand_off(cam)
					mode_panel_cam_bounds_check_x(cam, app.caret.rect.l, app.caret.rect.r, false, true)
					mode_panel_cam_bounds_check_y(cam, app.caret.rect.t, app.caret.rect.b, true)
					app.task_tail = app.task_head
				}
				return res
			}
		}

		case .Window_Close_Interrupt: {
			return int(app_save_close())
		}

		case .Window_Close: {
			gs_destroy_all_windows()
		}

		case .Dropped_Files: {
			if app_filter_empty() {
				return 0
			}

			// check the content to load
			load_images: bool
			window_drop_init(window)
			for file_path in window_drop_iter(window) {
				// image dropping
				if strings.has_suffix(file_path, ".png") {
					load_images = true
					break
				}
			}

			// load images only
			if load_images {
				window_drop_init(window)
				for file_path in window_drop_iter(window) {
					handle := image_load_push(file_path)
					
					if handle != nil {
						// find task by mouse intersection
						task := app_task_head()
						x, y := global_mouse_position()
						window_x, window_y := window_get_position(window)
						x -= window_x
						y -= window_y

						list := app_focus_list()
						for index in list {
							t := app_task_list(index)

							if rect_contains(t.element.bounds, x, y) {
								task = t
								break
							}
						}

						task_set_img(task, handle)
					}
				}
			} else {
				// spawn dialog with pattern question
				dialog_spawn(
					window,
					proc(dialog: ^Dialog, result: string) {
						// on success load with result string
						if dialog.result == .Default && result != "" {
							// save last result
							strings.builder_reset(&app.pattern_load_pattern)
							strings.write_string(&app.pattern_load_pattern, result)

							task := app_task_head()
							task_insert_offset := task.filter_index + 1
							task_indentation := task.indentation
							had_imports: bool
							manager := mode_panel_manager_begin()

							// read all files
							window_drop_init(app.window_main)
							for file_path in window_drop_iter(app.window_main) {
								// import from code
								content, ok := os.read_entire_file(file_path)
								defer delete(content)

								if ok {
									spall.fscoped("%s", file_path)
									had_imports |= pattern_load_content_simple(manager, string(content), result, task_indentation, &task_insert_offset)
								}
							}
				
							if had_imports {
								task_head_tail_push(manager)
								undo_group_end(manager)
							}
						}
					},
					300,
					"Code Import: Lua Pattern\n%l\n%f\n%t\n%f\n%C%B",
					strings.to_string(app.pattern_load_pattern),
					"Cancel",
					"Import",
				)
			}

			window_repaint(app.window_main)
		}
	}

	return 0
} 
