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
import "core:unicode"
import "core:thread"
import "core:intrinsics"
import sdl "vendor:sdl2"
import "../fontstash"
import "../spall"
import "../rax"
import "../cutf8"

TRACK_MEMORY :: false
TODOOL_RELEASE :: false

// KEYMAP REWORK
// add super key
// keymap load newer combos per version by default
// keymap editor GUI

// rework scrollbar to just float and take and be less intrusive
// have spall push threaded content based on ids or sdl timers

// 	if true {
// 		it: rax.Iterator
// 		rax.Start(&it, rt)
// 		defer rax.Stop(&it)
		
// 		res := rax.seek_string(&it, ">", "test")
// 		if res {
// 			for rax.next(&it) {
// 				if rax.compare_string(&it, "==", "wow") {
// 					break
// 				}

// 				text := strings.string_from_ptr(it.key, int(it.key_len))
// 				fmt.eprintln("Key:", it.key, text)
// 			}
// 		}
// 		fmt.eprintln("res", res)
// 	}

// 	// fmt.eprintln()

// 	// fmt.eprintln("yo")
// }

main_box_key_combination :: proc(window: ^Window, msg: Message, di: int, dp: rawptr) -> int {
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

	return 0
}

main_update :: proc(window: ^Window) {
	// animate progressbars 
	{
		state := progressbar_show()
		if state && progressbars_alpha == 0 {
			gs_animate(&progressbars_alpha, 1, .Quadratic_In, time.Millisecond * 200)
		}
		if !state && progressbars_alpha == 1 {
			gs_animate(&progressbars_alpha, 0, .Quadratic_In, time.Millisecond * 100)
		}
	}

	task_set_children_info()
	task_set_visible_tasks()
	task_check_parent_states(&um_task)

	switch task_state_progression {
		case .Idle: {}
		case .Update_Instant: {
			for i in 0..<len(mode_panel.children) {
				task := cast(^Task) mode_panel.children[i]

				if task.has_children {
					task_progress_state_set(task)
				}
			}
		}
		case .Update_Animated: {
			for i in 0..<len(mode_panel.children) {
				task := cast(^Task) mode_panel.children[i]

				if task.has_children {
					element_animation_start(task)
				} else {
					task.progress_animation = {}
				}
			}
		}
	}
	task_state_progression = .Idle

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
			task_shadow_alpha == 0 {
			gs_animate_forced(&task_shadow_alpha, TASK_SHADOW_ALPHA, .Quadratic_Out, time.Millisecond * 100)
		}

		// animate down
		if 
			task_head == task_tail &&
			task_shadow_alpha != 0 {
			gs_animate_forced(&task_shadow_alpha, 0, .Exponential_Out, time.Millisecond * 50)
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

	statusbar_update()
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
					if keymap_combo_execute(&keymap_vim_insert, combo) {
						return 1
					}
				} else {
					// ignore unicode insertion always
					keymap_combo_execute(&keymap_vim_normal, combo)
					return 1
				}
			} else {
				if main_box_key_combination(window, msg, di, dp) == 1 {
					return 1
				}

				{
					spall.scoped("keymap general execute")
					if keymap_combo_execute(&window.keymap_custom, combo) {
						return 1
					}
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

			if task_head == -1 {
				return 0
			}

			task := tasks_visible[task_head]
			task_insert_offset := task.index + 1
			task_indentation := task.indentation

			spall.scoped("Load Dropped Files")
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
					// if !had_imports {
					// 	task_head_tail_push(manager)
					// }
					// had_imports = true

					// import from code
					content, ok := os.read_entire_file(file_path)
					defer delete(content)

					if ok {
						spall.fscoped("%s", file_path)
						had_imports |= pattern_load_content_simple(manager, content, task_indentation, &task_insert_offset)
					}
				}

				old_indice = indice
			}

			if had_imports {
				task_head_tail_push(manager)
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

Word_Result :: struct {
	text: string,
	index_codepoint_start: int,
	index_codepoint_end: int,
}

words_extract :: proc(words: ^[dynamic]Word_Result, text: string) -> []Word_Result {
	clear(words)
	ds: cutf8.Decode_State
	index_codepoint_start := -1
	index_byte_start := -1

	word_push_check :: proc(
		words: ^[dynamic]Word_Result, 
		text: string, 
		ds: cutf8.Decode_State,
		index_codepoint_current: int, 
		index_codepoint_start: ^int, 
		index_byte_start: int,
	) {
		if index_codepoint_start^ != -1 {
			append(words, Word_Result {
				text = text[index_byte_start:ds.byte_offset_old],
				index_codepoint_start = index_codepoint_start^,
				index_codepoint_end = index_codepoint_current,
			})

			index_codepoint_start^ = -1
		}		
	}

	for codepoint, index in cutf8.ds_iter(&ds, text) {
		if unicode.is_alpha(codepoint) {
			if index_codepoint_start == -1 {
				index_codepoint_start = index
				index_byte_start = ds.byte_offset_old
			}
		} else {
			word_push_check(words, text, ds, index, &index_codepoint_start, index_byte_start)
		}
	}

	word_push_check(words, text, ds, ds.codepoint_count, &index_codepoint_start, index_byte_start)
	return words[:]
}

words_extract_test :: proc() {
	words := make([dynamic]Word_Result, 0, 32)
	w1 := "testing this out man"
	words_extract(&words, w1)
	fmt.eprintln(words[:], "\n")
	w2 := "test"
	words_extract(&words, w2)
	fmt.eprintln(words[:], "\n")
}

words_highlight_missing :: proc(target: ^Render_Target, task: ^Task) {
	text := strings.to_string(task.box.builder)
	words := words_extract(&rt_words, text)

	builder := strings.builder_make(0, 256, context.temp_allocator)
	ds: cutf8.Decode_State

	for word in words {
		// lower case each word
		strings.builder_reset(&builder)
		ds = {}
		for codepoint in cutf8.ds_iter(&ds, word.text) {
			strings.write_rune(&builder, unicode.to_lower(codepoint))
		}
		res := rax.CustomFind(rt, raw_data(builder.buf), len(builder.buf))

		// render the result when not found
		if !res.valid {
			fcs_task(task)
			state := fontstash.wrap_state_init(
				&gs.fc, 
				task.box.wrapped_lines[:], 
				word.index_codepoint_start, 
				word.index_codepoint_end,
			)
			scaled_size := f32(state.isize / 10)
			line_width := LINE_WIDTH + int(4 * TASK_SCALE)

			for fontstash.wrap_state_iter(&gs.fc, &state) {
				y := task.box.bounds.t + int(f32(state.y) * scaled_size) - line_width / 2
				
				rect := RectI {
					task.box.bounds.l + int(state.x_from),
					task.box.bounds.l + int(state.x_to),
					y,
					y + line_width,
				}
				
				render_sine(target, rect, RED)
			}
		}
	}
}

thread_rax_init :: proc(t: ^thread.Thread) {
	spall.scoped("rax load", u32(t.id))

	bytes, ok := os.read_entire_file("big.txt", context.allocator)
	defer delete(bytes)

	// NOTE ASSUMING ASCII ENCODING
	// check for words in file, to lower all
	word: [256]u8
	word_index: uint
	for i in 0..<len(bytes) {
		b := rune(bytes[i])

		if !unicode.is_alpha(b) {
			if word_index != 0 {
				main_running := intrinsics.atomic_load(&main_thread_running)
				if !main_running {
					break
				}
				
				rax.Insert(rt, &word[0], word_index, nil, nil)
			}

			word_index = 0
		} else {
			word[word_index] = u8(unicode.to_lower(b))
			word_index += 1
		}
	}

	intrinsics.atomic_store(&rt_loaded, true)
	if t != nil {
		thread.destroy(t)
	}
}

main :: proc() {
	spall.init("test.spall", mem.Megabyte)
	spall.begin("init all", 0)	
	defer spall.destroy()

	gs_init()
	context.logger = gs.logger
	context.allocator = gs_allocator()
	
	rt = rax.New()
	defer rax.Free(rt)

	// feed data to
	t := thread.create(thread_rax_init)
	thread.start(t)

	task_data_init()

	window := window_init(nil, {}, "Todool", 900, 900, 256, 256)
	window.on_resize = proc(window: ^Window) {
		cam := mode_panel_cam()
		cam.freehand = true
	}
	window_main = window
	window.element.message_user = window_main_message
	window.update = main_update

	{
		spall.scoped("load keymap")
		// keymap loading

		keymap_push_todool_commands(&window_main.keymap_custom)
		keymap_push_box_commands(&window_main.keymap_box)
		// NOTE push default todool to vim too
		keymap_push_todool_commands(&keymap_vim_normal)
		keymap_push_vim_normal_commands(&keymap_vim_normal)
		keymap_push_vim_insert_commands(&keymap_vim_insert)

		if loaded := keymap_load("save.keymap"); !loaded {
			// just clear since data could be loaded
			keymap_clear_combos(&window_main.keymap_custom)
			keymap_clear_combos(&window_main.keymap_box)
			keymap_clear_combos(&keymap_vim_normal)
			keymap_clear_combos(&keymap_vim_insert)
			
			keymap_push_todool_combos(&window_main.keymap_custom)
			keymap_push_box_combos(&window_main.keymap_box)
			keymap_push_vim_normal_combos(&keymap_vim_normal)
			keymap_push_vim_insert_combos(&keymap_vim_insert)
			log.info("KEYMAP: Load failed -> Loading default")
		} else {
			log.info("KEYMAP: Load successful")
		}
	}

	{
		spall.scoped("gen elements")
		// add_shortcuts(window)
		panel := panel_init(&window.element, { .Panel_Horizontal, .Tab_Movement_Allowed })
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

	// tasks_load_reset()
	// tasks_load_tutorial()
	// tasks_load_default()
	tasks_load_file()

	// do actual loading later because options might change the path
	gs_update_after_load()
	spall.end(0)
	
	defer {
		intrinsics.atomic_store(&main_thread_running, false)
	}
	gs_message_loop()
}
