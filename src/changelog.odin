package src

import "core:reflect"
import "core:fmt"
import "core:mem"
import "core:math"
import "core:strings"
import "core:slice"

//changelog generator output window
//	descritiption what this window does
//	button to update to task tree content (in case the window is kept alive)
//	display supposed generated output
//	checkboxes to decide where to output (Terminal, File, Clipboard)
//	checkbox to remove content from task tree or not
//	allow changing numbering scheme or inserting stars at the start of each textual line

//LATER
//	skip folded

Changelog_Task :: struct {
	task: ^Task,
	remove: bool,
}

Changelog_Indexing :: enum {
	None,
	Numbers,
	Stars_Non_Zero,
	Stars_All,
}

Changelog :: struct {
	window: ^Window,
	panel: ^Panel,
	td: ^Changelog_Text_Display,

	checkbox_skip_folded: ^Checkbox,
	checkbox_include_canceled: ^Checkbox,
	checkbox_pop_tasks: ^Checkbox,

	check_next: bool,

	qlist: [dynamic]Changelog_Task,
	qparents: map[^Task]u8,
	indexing: Changelog_Indexing,
}
changelog: Changelog

changelog_window_message :: proc(element: ^Element, msg: Message, di: int, dp: rawptr) -> int {
	window := cast(^Window) element

	#partial switch msg {
		case .Destroy: {
			delete(changelog.qparents)
			delete(changelog.qlist)
			changelog = {}
		}
	}

	return 0
}

Changelog_Text_Display :: struct {
	using element: Element,
	builder: strings.Builder,
	vscrollbar: ^Scrollbar,
	hscrollbar: ^Scrollbar,
}

changelog_text_display_message :: proc(element: ^Element, msg: Message, di: int, dp: rawptr) -> int {
	td := cast(^Changelog_Text_Display) element
	margin_scaled := int(TEXT_PADDING * SCALE)
	tab_scaled := int(50 * SCALE)

	#partial switch msg {
		case .Layout: {
			bounds := element.bounds
			// measure max string width and lines
			iter := strings.to_string(td.builder)
			width: int
			line_count := 1
			scaled_size := fcs_element(element)
			for line in strings.split_lines_iterator(&iter) {
				tabs := tabs_count(line)
				width = max(width, string_width(line) + tabs * tab_scaled)
				line_count += 1
			}

			scrollbar_layout_help(
				td.hscrollbar,
				td.vscrollbar, 
				element.bounds,
				width,
				line_count * scaled_size,
			)
		}

		case .Paint_Recursive: {
			target := element.window.target
			render_rect(target, element.bounds, theme.background[1], ROUNDNESS)
			bounds := rect_margin(element.bounds, margin_scaled)
			
			text := strings.to_string(td.builder)
			scaled_size := fcs_element(element)

			if len(text) == 0 {
				fcs_color(theme.text_blank)
				fcs_ahv()
				render_string_rect(target, bounds, "no changes found")
			} else {
				// render each line, increasingly
				fcs_color(theme.text_default)
				fcs_ahv(.LEFT, .TOP)
				x := bounds.l - int(td.hscrollbar.position)
				y := bounds.t - int(td.vscrollbar.position)

				iter := text
				for line in strings.split_lines_iterator(&iter) {
					tabs := tabs_count(line)

					render_string(
						target,
						x + tabs * tab_scaled, y,
						line[tabs:],
					)

					y += scaled_size
				}
			}
		}

		case .Mouse_Scroll_X: {
			if scrollbar_valid(td.hscrollbar) {
				return element_message(td.hscrollbar, msg, di, dp)
			}
		}

		case .Mouse_Scroll_Y: {
			if scrollbar_valid(td.vscrollbar) {
				return element_message(td.vscrollbar, msg, di, dp)
			}
		}

		case .Destroy: {
			delete(td.builder.buf)
		}
	}

	return 0	
}

changelog_text_display_init :: proc(
	parent: ^Element,
	flags: Element_Flags,
) -> (res: ^Changelog_Text_Display) {
	res = element_init(Changelog_Text_Display, parent, flags, changelog_text_display_message, context.allocator)
	res.builder = strings.builder_make(0, mem.Kilobyte)
	res.hscrollbar = scrollbar_init(res, {}, true, context.allocator)
	res.vscrollbar = scrollbar_init(res, {}, false, context.allocator)
	return
}

changelog_text_display_set :: proc(td: ^Changelog_Text_Display) {
	b := &td.builder
	strings.builder_reset(b)

	write :: proc(b: ^strings.Builder, task: ^Task, indentation: int, count: int) {
		for i in 0..<indentation {
			strings.write_byte(b, '\t')
		}

		switch changelog.indexing {
			case .None: {}
			case .Numbers: {
				strings.write_int(b, count)
				strings.write_byte(b, '.')
				strings.write_byte(b, ' ')
			}
			case .Stars_Non_Zero: {
				if indentation != 0 {
					strings.write_string(b, "* ")
				}
			}
			case .Stars_All: strings.write_string(b, "* ")
		}

		strings.write_string(b, task_string(task))
		strings.write_byte(b, '\n')
	}

	changelog_find()

	count := 1
	for qtask in changelog.qlist {
		write(b, qtask.task, qtask.task.indentation, count)
		count += 1
	}
}

// pop the wanted changelog tasks
changelog_result_pop_tasks :: proc() {
	if !changelog.checkbox_pop_tasks.state || len(changelog.qlist) == 0 {
		return
	}

	manager := mode_panel_manager_scoped()
	task_head_tail_push(manager)
	task_head_tail_flatten_keep()

	offset: int
	for qtask in changelog.qlist {
		task := qtask.task

		if qtask.remove {
			archive_push(&sb.archive, task_string(task))

			goal := task.filter_index - offset
			// fmt.eprintln("~~~", task_string(task), task.filter_index, goal)
			item := Undo_Item_Task_Remove_At { goal, task.list_index }
			undo_task_remove_at(manager, &item)
			offset += 1
		}
	}

	window_repaint(app.window_main)
	changelog_update_safe()
}

changelog_result :: proc() -> string {
	return strings.to_string(changelog.td.builder)
}

changelog_update_safe :: proc() {
	if changelog.window == nil {
		return
	}	

	changelog.check_next = true
	changelog.window.update_next = true
}

changelog_update_invoke :: proc(box: ^Checkbox) {
	changelog.check_next = true
	changelog.window.update_next = true
}

changelog_spawn :: proc(du: u32 = COMBO_EMPTY) {
	if changelog.window != nil {
		window_raise(changelog.window)
		return
	}

	changelog.qlist = make([dynamic]Changelog_Task, 0, 64)
	changelog.qparents = make(map[^Task]u8, 32)

	changelog.window = window_init(nil, {}, "Changelog Genrator", 700, 700, 8, 8)
	changelog.window.element.message_user = changelog_window_message
	changelog.window.update_before = proc(window: ^Window) {
		// only check once when window is updating
		if changelog.check_next {
			task_check_parent_states(nil)
			changelog_text_display_set(changelog.td)
			changelog.check_next = false
		}
	}
	changelog.window.on_focus_gained = proc(window: ^Window) {
		if changelog.td != nil {
			changelog_text_display_set(changelog.td)
		}
		window.update_next = true
	}

	changelog.panel = panel_init(
		&changelog.window.element,
		{ .HF, .VF, .Panel_Default_Background },
		5,
		5,
	)
	changelog.panel.background_index = 0
	p := changelog.panel
	
	{
		p1 := panel_init(p, { .HF, .Panel_Default_Background }, 5, 5)
		p1.background_index = 1
		p1.rounded = true
		label_init(p1, { .HF, .Label_Center }, "Generates a Changelog from your Done/Canceled Tasks")

		{
			p2 := panel_init(p1, { .HF, .Panel_Horizontal }, 5, 5)
			label_init(p2, { .Label_Center }, "Generate to")
			p3 := panel_init(p2, { .HF, .Panel_Horizontal, .Panel_Default_Background })
			p3.background_index = 2
			p3.rounded = true
			button_init(p3, { .HF }, "Clipboard").invoke = proc(button: ^Button, data: rawptr) {
				text := changelog_result()
				clipboard_set_with_builder(text)
				changelog_result_pop_tasks()
			}
			button_init(p3, { .HF }, "Terminal").invoke = proc(button: ^Button, data: rawptr) {
				fmt.println(changelog_result())
				changelog_result_pop_tasks()
			}
			button_init(p3, { .HF }, "File").invoke = proc(button: ^Button, data: rawptr) {
				path := bpath_temp("changelog.txt")
				gs_write_safely(path, changelog.td.builder.buf[:])
				changelog_result_pop_tasks()
			}
		}

		{
			toggle := toggle_panel_init(p1, { .HF }, { .Panel_Default_Background }, "Options", true)
			p2 := toggle.panel
			// p2 := panel_init(p1, { .HF, .Panel_Default_Background, .Panel_Horizontal })
			
			p2.background_index = 2
			p2.margin = 5
			p2.rounded = true
			p2.gap = 5
			changelog.checkbox_skip_folded = checkbox_init(p2, { .HF }, "Skip Folded", true)
			changelog.checkbox_skip_folded.invoke = changelog_update_invoke
			changelog.checkbox_include_canceled = checkbox_init(p2, { .HF }, "Include Canceled Tasks", true)
			changelog.checkbox_include_canceled.invoke = changelog_update_invoke
			changelog.checkbox_pop_tasks = checkbox_init(p2, { .HF }, "Pop Tasks", true)
	
			indexing_names := reflect.enum_field_names(Changelog_Indexing)
			t := toggle_selector_init(p2, { .HF }, 0, len(Changelog_Indexing), indexing_names)
			t.changed = proc(toggle: ^Toggle_Selector) {
				changelog.indexing = Changelog_Indexing(toggle.value)
				changelog_text_display_set(changelog.td)
			}
		}
	}

	changelog.td = changelog_text_display_init(p, { .HF, .VF })
	changelog_text_display_set(changelog.td)
}

changelog_find :: proc() {
	clear(&changelog.qlist)
	clear(&changelog.qparents)

	include := changelog.checkbox_include_canceled.state
	skip := changelog.checkbox_skip_folded.state

	for filter_index in 0..<len(app.pool.filter) {
		task := app_task_filter(filter_index)

		// skip individual task
		if skip && task_has_children(task) && task.filter_folded {
			continue
		}

		state_matched := include ? task.state != .Normal : task.state == .Done 

		if state_matched {
			// TODO could also just push to temp array instead instantly to array
			// to save up on having to sort

			// search for unpushed parents
			p := task.visible_parent
			parent_search: for p != nil {
				if p in changelog.qparents {
					break parent_search
				}

				append(&changelog.qlist, Changelog_Task { p, false })
				changelog.qparents[p] = 1
				p = p.visible_parent
			}

			// push actual task that will be marked as remove candidate
			append(&changelog.qlist, Changelog_Task { task, true })

			// push task if its a parent too to avoid duplicates
			if task_has_children(task) {
				changelog.qparents[task] = 2
			}
		}
	}

	// just sort the unsorted parents that were inserted at some point
	sort_by :: proc(a, b: Changelog_Task) -> bool {
		return a.task.filter_index < b.task.filter_index
	}
	slice.sort_by(changelog.qlist[:], sort_by)
}