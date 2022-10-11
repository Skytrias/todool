package src

import "core:reflect"
import "core:strings"
import "core:fmt"

Statusbar :: struct {
	stat: ^Element,
	label_info: ^Label,

	task_panel: ^Panel,
	label_task_state: [Task_State]^Label,

	label_task_count: ^Label,

	vim_panel: ^Panel,
	vim_mode_label: ^Vim_Label,
	// label_vim_buffer: ^Label,
}

Vim_Label :: struct {
	using element: Element,
}

vim_label_init :: proc(
	parent: ^Element,
	flags: Element_Flags,
) -> (res: ^Vim_Label) {
	res = element_init(Vim_Label, parent, flags, vim_label_message, context.allocator)
	return
}

vim_label_message :: proc(element: ^Element, msg: Message, di: int, dp: rawptr) -> int {
	v := cast(^Vim_Label)	element
	text := vim_insert_mode ? "-- INSERT --" : "NORMAL"
	
	#partial switch msg {
		case .Paint_Recursive: {
			target := element.window.target
			fcs_element(element)
			fcs_ahv()
			fcs_color(theme.text_default)
			render_string_rect(target, element.bounds, text)
		}

		case .Get_Width: {
			fcs_element(element)
			return int(string_width(text))
		}

		case .Get_Height: {
			return efont_size(element)
		}
	}

	return 0
}

statusbar_init :: proc(split: ^Custom_Split) {
	s := &split.statusbar
	using s
	stat = element_init(Element, split, {}, statusbar_message, context.allocator)
	label_info = label_init(stat, { .Label_Center })

	task_panel = panel_init(stat, { .HF, .Panel_Horizontal }, 5, 5)
	task_panel.color = &theme.panel[1]
	task_panel.rounded = true
	
	for i in 0..<len(Task_State) {
		label_task_state[Task_State(i)] = label_init(task_panel, {})
	}
	
	label_task_state[.Normal].color = &theme.text_default
	label_task_state[.Done].color = &theme.text_good
	label_task_state[.Canceled].color = &theme.text_bad

	spacer_init(task_panel, {}, 2, DEFAULT_FONT_SIZE, .Full, true)

	label_task_count = label_init(task_panel, {})

	vim_panel = panel_init(stat, { .HF, .Panel_Horizontal }, 5, 5)
	vim_panel.color = &theme.text_good
	vim_panel.rounded = true
	vim_mode_label = vim_label_init(vim_panel, {})
}

statusbar_message :: proc(element: ^Element, msg: Message, di: int, dp: rawptr) -> int {
	#partial switch msg {
		case .Paint_Recursive: {
			target := element.window.target
			render_rect(target, element.bounds, theme.background[2])
		}

		case .Layout: {
			bounds := element.bounds
			bounds = rect_margin(bounds, int(5 * SCALE))

			// custom layout based on data
			for child in element.children {
				w := element_message(child, .Get_Width)
				
				if .HF in child.flags {
					// right
					element_move(child, rect_cut_right(&bounds, w))
					bounds.r -= int(5 * SCALE)
				} else {
					element_move(child, rect_cut_left(&bounds, w))
					bounds.l += int(5 * SCALE)
				} 
			}
		}
	}

	return 0
}

statusbar_update :: proc() {
	s := &custom_split.statusbar

	// update checkbox if hidden by key command
	// {
	// 	checkbox := &sb.options.checkbox_hide_statusbar
	// 	if checkbox.state != (.Hide in s.state.flags) {
	// 		checkbox_set(checkbox, (.Hide not_in s.state.flags))
	// 	}
	// }

	if .Hide in s.stat.flags {
		return
	}

	element_hide(s.vim_panel, !options_vim_use())

	// info
	{
		b := &s.label_info.builder
		strings.builder_reset(b)

		if task_head == -1 {
			fmt.sbprintf(b, "~")
		} else {
			if task_head != task_tail {
				low, high := task_low_and_high()
				fmt.sbprintf(b, "Lines %d - %d selected", low + 1, high + 1)
			} else {
				task := tasks_visible[task_head]

				if .Hide not_in panel_search.flags {
					index := ss.current_index
					amt := len(ss.results)

					if amt == 0 {
						fmt.sbprintf(b, "No matches found")
					} else if amt == 1 {
						fmt.sbprintf(b, "1 match")
					} else {
						fmt.sbprintf(b, "%d of %d matches", index + 1, amt)
					}
				} else {
					if task.box.head != task.box.tail {
						low, high := box_low_and_high(task.box)
						fmt.sbprintf(b, "%d characters selected", high - low)
					} else {
						// default
						fmt.sbprintf(b, "Line %d, Column %d", task_head + 1, task.box.head + 1)
					}
				}
			}
		}
	}

	// count states
	count: [Task_State]int
	for task in tasks_visible {
		count[task.state] += 1
	}
	task_names := reflect.enum_field_names(Task_State)

	// tasks
	for state, i in Task_State {
		label := s.label_task_state[state]
		b := &label.builder
		strings.builder_reset(b)
		strings.write_string(b, task_names[i])
		strings.write_byte(b, ' ')
		strings.write_int(b, count[state])
	}

	{
		total := len(mode_panel.children)
		shown := len(tasks_visible)
		hidden := total - len(tasks_visible)
		deleted := len(task_clear_checking)

		// run through list and decrease clear count
		for task in tasks_visible {
			if task in task_clear_checking {
				deleted -= 1
			}
		}
		
		b := &s.label_task_count.builder
		strings.builder_reset(b)

		strings.write_string(b, "Total ")
		strings.write_int(b, total)
		strings.write_string(b, ", ")

		if hidden != 0 {
			strings.write_string(b, "Shown ")
			strings.write_int(b, shown)
			strings.write_string(b, ", ")

			strings.write_string(b, "Hidden ")
			strings.write_int(b, hidden)
			strings.write_string(b, ", ")
		}

		strings.write_string(b, "Deleted ")
		strings.write_int(b, deleted)
	}
}
