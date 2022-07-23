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
//   more detail with task head & tail movement

Tag_Data :: struct {
	text: string,
	color: Color,
}

tags_data := [8]Tag_Data {
	{ "one", RED },
	{ "two", BLUE },
	{ "three", GREEN },
	{ "four", RED },
	{ "five", RED },
	{ "six", RED },
	{ "seven", RED },
	{ "eight", RED },
}

// elements that can appear as task data
// folding: bool -> as icon button
// duration spent: time.Duration -> as string
// assigned date: time.Time -> as string

// bookmarks could be display differently as LINE HIGHLIGHT
// recording this -> LINE HIGHLIGHT NOW

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
	window.scale = 1

	window.element.message_user = proc(element: ^Element, msg: Message, di: int, dp: rawptr) -> int {
		window := cast(^Window) element

		#partial switch msg {
			case .Key_Combination: {
				handled := true
				combo := (cast(^string) dp)^

				if task_head != -1 && !task_has_selection() && len(tasks_visible) > 0 {
					box := tasks_visible[task_head].box
					
					if element_message(box, msg, di, dp) == 1 {
						return 1
					}
				}

				return int(shortcuts_run_multi(combo))
			}

			case .Unicode_Insertion: {
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

	if false {
		panel_top = panel_init(&window.element, { .CT, .Panel_Default_Background }, 40, 5, 10)
		panel_top.shadow = true
		
		mode_button = button_init(panel_top, { .CL, .CF }, "List")
		mode_button.message_user = proc(element: ^Element, msg: Message, di: int, dp: rawptr) -> int {
			if msg == .Clicked {
				mode := cast(^int) &mode_panel.mode
				
				if mode^ < len(Mode) -1 {
					mode^ += 1
				} else {
					mode^ = 0
				}

				element_message(element, .Update)
			} else if msg == .Update {
				button := cast(^Button) element
				b := &button.builder
				strings.builder_reset(b)
				fmt.sbprintf(b, "%v", mode_panel.mode)
				element_repaint(element)
			}

			return 0
		}
		button_init(panel_top, { .CR, .CF }, "None")
		button_init(panel_top, { .CF }, "TEST")
	}

	if true {
		panel_info = panel_init(&window.element, { .CL, .Panel_Default_Background }, 40, 5, 10)
		panel_info.shadow = true
		panel_info.z_index = 3
		icon_button_init(panel_info, { .CT, .CF }, .Stopwatch)
		// label_init(panel_info, { .CT, .CF, .Label_Center }, "00:00:00")
		spacer_init(panel_info, { .CT, .CF }, 0, 2, .Thin, false)
		icon_button_init(panel_info, { .CT, .CF }, .Clock)
		// label_init(panel_info, { .CT, .CF, .Label_Center }, "00:00:00")
		spacer_init(panel_info, { .CT, .CF }, 0, 2, .Thin, false)
		icon_button_init(panel_info, { .CT, .CF }, .Tomato)
		// label_init(panel_info, { .CT, .CF, .Label_Center }, "00:00:00")

		b := button_init(panel_info, { .CB, .Hover_Has_Info }, "b")
		b.invoke = proc(data: rawptr) {
			element := cast(^Element) data
			window_border_toggle(element.window)
			element_repaint(element)
		}
		b.hover_info = "border"

		button_init(panel_info, { .CB }, "b").invoke = proc(data: rawptr) {
			element := cast(^Element) data
			element_hide_toggle(panel_temp)
			element_repaint(element)
		}

		// // tab slider up.date panel	
		// slider_tab = slider_init(panel_info, { .CR, .Hover_Has_Info }, 0.5)
		// slider_tab.format = "tab: %f"
		// slider_tab.hover_info = "testing this out"
	}

	if true {
		panel_temp = panel_init(&window.element, { .CL, .Panel_Default_Background }, 300, 5, 10)
		panel_temp.shadow = true
		panel_temp.z_index = 2
		element_hide(panel_temp, true)
	}

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

	// fmt.eprintln(size_of(Theme), size_of(Color) * 4 + size_of(Color) * 3)

	// log.info("save", editor_save())
	// log.info("load", editor_load())

	gs_message_loop()
}

theme_editor :: proc() {
	window := window_init("Todool Theme Editor", 600, 800)

	panel := panel_init(&window.element, { .CF, .Panel_Scrollable, .Panel_Default_Background })
	panel.margin = 10
	
	label := label_init(panel, { .CT }, "Theme Editor")
	label.font_options = &font_options_header

	SPACER_WIDTH :: 20
	spacer_init(panel, { .CT, .CF }, 0, SPACER_WIDTH, .Thin)
	
	Color_Pair :: struct {
		color: ^Color,
		index: int,
	}

	color_slider :: proc(parent: ^Element, color_mod: ^Color, name: string) {
		slider_panel := panel_init(parent, { .CT }, 40, 5, 5)
		label_init(slider_panel, { .CL }, name)

		for i in 0..<4 {
			value := &color_mod[3 - i]
			s := slider_init(slider_panel, { .CR }, f32(value^) / 255)
			
			s.data = new_clone(Color_Pair { color_mod, 3 - i })
			s.message_user = proc(element: ^Element, msg: Message, di: int, dp: rawptr) -> int {
				slider := cast(^Slider) element

				#partial switch msg {
					case .Value_Changed: {
						pair := cast(^Color_Pair) element.data
						pair.color[pair.index] = u8(slider.position * 255)
						
						picker := cast(^Color_Picker) slider.parent.parent.data
						picker.color_mod = pair.color

						for w in gs.windows {
							w.update_next = true
						}
					}

					case .Reformat: {
						strings.builder_reset(&slider.builder)
						fmt.sbprintf(&slider.builder, "%d", u8(slider.position * 255))
					}

					case .Deallocate_Recursive: {
						free(slider.data)
					}
				} 

				return 0
			}
		}
	}

	color_slider(panel, &theme.background, "background")
	color_slider(panel, &theme.shadow, "shadow")
	spacer_init(panel, { .CT, .CF }, 0, SPACER_WIDTH, .Thin)
	color_slider(panel, &theme.text[.Normal], "text normal")
	color_slider(panel, &theme.text[.Done], "text good")
	color_slider(panel, &theme.text[.Canceled], "text bad")
	spacer_init(panel, { .CT, .CF }, 0, SPACER_WIDTH, .Thin)
	color_slider(panel, &theme.caret, "caret")
	color_slider(panel, &theme.caret_highlight, "caret highlight")
	color_slider(panel, &theme.caret_selection, "caret selection")
	spacer_init(panel, { .CT, .CF }, 0, SPACER_WIDTH, .Thin)
	color_slider(panel, &theme.panel_back, "panel back")
	color_slider(panel, &theme.panel_front, "panel front")

	spacer_init(panel, { .CT, .CF }, 0, SPACER_WIDTH, .Thin)
	picker := color_picker_init(panel, { .CT }, 0)
	panel.data = picker

	// button_init(panel, { .CT, .CF }, "Randomize").invoke = proc(data: rawptr) {
	// 	total_size := size_of(Theme) / size_of(Color)
		
	// 	for i in 0..<total_size {
	// 		root := uintptr(&theme) + uintptr(i * size_of(Color))
	// 		color := cast(^Color) root
	// 		color.r = u8(rand.float32() * 255)
	// 		color.g = u8(rand.float32() * 255)
	// 		color.b = u8(rand.float32() * 255)
	// 	}

	// 	// button := cast(^Button) data
	// 	// for child in button.parent.children {
	// 	// 	log.info("yo")
	// 	// 	if child.message_class == slider_message {
	// 	// 		log.info("tried")
	// 	// 		value := cast(^u8) child.data
	// 	// 		slider := cast(^Slider) child
	// 	// 		slider.position = f32(value^) / 255
	// 	// 		element_message(child, .Reformat)
	// 	// 	}
	// 	// }

	// 	for w in gs.windows {
	// 		w.update_next = true
	// 	}
	// }
}

table_test :: proc() {
	window := window_init("table", 500, 500)
	panel := panel_init(&window.element, { .CF })
	panel.color = theme.background
	panel.margin = 10
	panel.gap = 5

	button_init(panel, { .CT, .CF }, "testing")
	// button_init(panel, { .CF }, "testing")
	table := table_init(panel, { .CF }, "ABC\tXYZ\tTEST")
	table.column_count = 3
	table.message_user = proc(element: ^Element, msg: Message, di: int, dp: rawptr) -> int {
		table := cast(^Table) element

		#partial switch msg {
			case .Table_Get_Item: {
				item := cast(^Table_Get_Item) dp
				item.output = fmt.bprint(item.buffer, "test############")
				// log.info(item.output)
			}
		}

		return 0
	}

	table.item_count = 10
	table_resize_columns(table)
}
