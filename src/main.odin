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

menu_bar_push :: proc(window: ^Window, menu_info: int) -> (res: ^Panel_Floaty) {
	res = menu_init_or_replace_new(window, { .Panel_Expand }, menu_info)
	if res != nil {
		res.panel.margin = 0
		res.panel.rounded = false
	}
	return 
}

menu_bar_show :: proc(menu: ^Panel_Floaty, element: ^Element) {
	menu_show(menu)
	menu.x = element.bounds.l
	menu.y = element.bounds.b
}

main :: proc() {
	gs_init()
	context.logger = gs.logger
	context.allocator = gs_allocator()

	window := window_init(nil, {}, "Todool", 900, 900, 256, 256)
	window_main = window
	keymap_push_todool_commands(&window_main.keymap_custom)
	keymap_push_todool_combos(&window_main.keymap_custom)

	split := menu_split_init(&window.element)
	menu := menu_bar_init(split)
	menu_bar_field_init(menu, "File", 1).invoke = proc(p: ^Panel) {
		mbl(p, "New File", "new_file")
		mbl(p, "Open File", "load")
		mbl(p, "Save", "save")
		mbl(p, "Save As...", "save", COMBO_TRUE)
		// mbs(p)
		// mbl(p, "Quit").command_custom
	}
	menu_bar_field_init(menu, "View", 2).invoke = proc(p: ^Panel) {
		mbl(p, "Mode List", "mode_list")
		mbl(p, "Mode Kanban", "mode_kanban")
		mbs(p)
		mbl(p, "Theme Editor", "theme_editor")
		mbl(p, "Changelog", "changelog")
		mbs(p)
		mbl(p, "Goto", "goto")
		mbl(p, "Search", "search")
		mbs(p)
		mbl(p, "Scale Tasks Up", "scale_tasks", COMBO_NEGATIVE)
		mbl(p, "Scale Tasks Down", "scale_tasks", COMBO_POSITIVE)
		mbl(p, "Center View", "center")
		mbl(p, "Toggle Progressbars", "toggle_progressbars")
	}
	menu_bar_field_init(menu, "Edit", 3).invoke = proc(p: ^Panel) {
		mbl(p, "Undo", "undo")
		mbl(p, "Redo", "redo")
		mbs(p)
		mbl(p, "Cut", "cut_tasks")
		mbl(p, "Copy", "copy_tasks")
		mbl(p, "Copy To Clipboard", "copy_tasks_to_clipboard")
		mbl(p, "Paste", "paste_tasks")
		mbl(p, "Paste From Clipboard", "paste_tasks_from_clipboard")
		mbs(p)
		mbl(p, "Shift Left", "indentation_shift", COMBO_NEGATIVE)
		mbl(p, "Shift Right", "indentation_shift", COMBO_POSITIVE)
		mbl(p, "Shift Up", "shift_up")
		mbl(p, "Shift Down", "shift_down")
		mbs(p)
		mbl(p, "Sort Locals", "sort_locals")
		mbl(p, "To Uppercase", "tasks_to_uppercase")
		mbl(p, "To Lowercase", "tasks_to_lowercase")
	}
	menu_bar_field_init(menu, "Task-State", 4).invoke = proc(p: ^Panel) {
		mbl(p, "Completion Forward", "change_task_state")
		mbl(p, "Completion Backward", "change_task_state", COMBO_SHIFT)
		mbs(p)
		mbl(p, "Folding", "toggle_folding")
		mbl(p, "Bookmark", "toggle_bookmark")
		mbs(p)
		mbl(p, "Tag 1", "toggle_tag", COMBO_VALUE + 0x01)
		mbl(p, "Tag 2", "toggle_tag", COMBO_VALUE + 0x02)
		mbl(p, "Tag 3", "toggle_tag", COMBO_VALUE + 0x04)
		mbl(p, "Tag 4", "toggle_tag", COMBO_VALUE + 0x08)
		mbl(p, "Tag 5", "toggle_tag", COMBO_VALUE + 0x10)
		mbl(p, "Tag 6", "toggle_tag", COMBO_VALUE + 0x20)
		mbl(p, "Tag 7", "toggle_tag", COMBO_VALUE + 0x40)
		mbl(p, "Tag 8", "toggle_tag", COMBO_VALUE + 0x80)
	}
	menu_bar_field_init(menu, "Movement", 5).invoke = proc(p: ^Panel) {
		mbl(p, "Move Up", "move_up")
		mbl(p, "Move Down", "move_down")
		mbs(p)
		mbl(p, "Jump Low Indentation Up", "indent_jump_low_prev")
		mbl(p, "Jump Low Indentation Down", "indent_jump_low_next")
		mbl(p, "Jump Same Indentation Up", "indent_jump_same_prev")
		mbl(p, "Jump Same Indentation Down", "indent_jump_same_next")
		mbl(p, "Jump Scoped", "indent_jump_scope")
		mbs(p)
		mbl(p, "Jump Nearby Different State Forward", "jump_nearby")
		mbl(p, "Jump Nearby Different State Backward", "jump_nearby", COMBO_SHIFT)
		mbs(p)
		mbl(p, "Move Up Stack", "move_up_stack")
		mbl(p, "Move Down Stack", "move_down_stack")
		mbs(p)
		mbl(p, "Select All", "select_all")
		mbl(p, "Select Children", "select_children")
	}
	p2 := panel_init(split, { .Panel_Default_Background })
	p2.background_index = 1

	gs_update_after_load()
	gs_message_loop()			
}

main4 :: proc() {
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
