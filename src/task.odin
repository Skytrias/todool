package src

import "core:unicode"
import "core:strings"
import "core:log"
import "core:math"
import "core:intrinsics"
import "core:slice"
import "core:reflect"
import "../cutf8"
import "../fontstash"

panel_info: ^Panel
mode_panel: ^Mode_Panel

slider_tab: ^Slider
font_options_header: Font_Options
font_options_bold: Font_Options

// works in visible line space!
// gets used in key combs
task_head := 0
task_tail := 0
old_task_head := 0
old_task_tail := 0
tasks_visible: [dynamic]^Task
task_parent_stack: [128]^Task
// editor_pushed_unsaved: bool
TAB_WIDTH :: 100
TASK_DATA_GAP :: 5
TASK_TEXT_OFFSET :: 2
TASK_DATA_MARGIN :: 2

Task_State :: enum u8 {
	Normal,
	Done,
	Canceled,
} 

Task :: struct {
	using element: Element,
	
	// NOTE set in update
	index: int, 
	visible_index: int, 
	visible_parent: ^Task,
	visible: bool,

	// elements
	button_fold: ^Icon_Button,
	box: ^Task_Box,

	// state
	indentation: int,
	indentation_smooth: f32,
	indentation_animating: bool,
	state: Task_State,
	tags: u8,

	// top animation
	top_offset: f32,
	top_old: f32,
	top_animation_start: bool,
	top_animating: bool,

	folded: bool,
	has_children: bool,
}

Mode :: enum {
	List,
	Kanban,
	// Agenda,
}
KANBAN_WIDTH :: 300
KANBAN_MARGIN :: 10

Drag_Panning :: struct {
	start_x: f32,
	start_y: f32,
	offset_x: f32,
	offset_y: f32,
}

// element to custom layout based on internal mode
Mode_Panel :: struct {
	using element: Element,
	mode: Mode,

	kanban_left: f32, // layout seperation
	gap_vertical: f32,
	gap_horizontal: f32,

	drag: [Mode]Drag_Panning,
	kanban_outlines: [dynamic]Rect,
}

// scoped version so you dont forget to call
@(deferred_out=mode_panel_manager_end)
mode_panel_manager_scoped :: #force_inline proc() -> ^Undo_Manager {
	return mode_panel_manager_begin()
}

mode_panel_manager_begin :: #force_inline proc() -> ^Undo_Manager {
	return &mode_panel.window.manager
}

mode_panel_manager_end :: #force_inline proc(manager: ^Undo_Manager) {
	undo_group_end(manager)
}

// line has selection
task_has_selection :: #force_inline proc() -> bool {
	return task_head != task_tail
}

// low and high from selection
task_low_and_high :: #force_inline proc() -> (low, high: int) {
	low = min(task_head, task_tail)
	high = max(task_head, task_tail)
	return
}

// set line selection to head when no shift
task_tail_check :: proc() {
	if !mode_panel.window.shift {
		task_tail = task_head
	}
}

// call procedure on all lines selected
task_call_selection :: proc(call: proc(^Task, bool)) {
	if task_head == -1 {
		return
	}

	selection := task_has_selection()
	low, high := task_low_and_high()

	for i in low..<high + 1 {
		call(tasks_visible[i], selection)
	}
}

// find a line linearly in the panel children
task_find_linear :: proc(element: ^Element, start := 0) -> (res: int) {
	res = -1

	for i in start..<len(mode_panel.children) {
		child := mode_panel.children[i]

		if element == child {
			res = i
			return
		}
	}

	return 
}

// raw creationg of a task
// NOTE: need to set the parent afterward!
task_init :: proc(
	indentation: int,
	text: string,
) -> (res: ^Task) { 
	res = new(Task)
	element := cast(^Element) res
	element.message_class = task_message

	// just assign parent already
	parent := mode_panel	
	element.window = parent.window
	element.parent = parent

	// insert task results
	res.indentation = indentation
	res.indentation_smooth = f32(indentation)
	
	res.button_fold = icon_button_init(res, {}, .Simple_Down)
	res.button_fold.message_user = proc(element: ^Element, msg: Message, di: int, dp: rawptr) -> int {
		button := cast(^Icon_Button) element
		task := cast(^Task) button.parent

		#partial switch msg {
			case .Clicked: {
				manager := mode_panel_manager_scoped()
				task_head_tail_push(manager)
				item := Undo_Item_Bool_Toggle { &task.folded }
				undo_bool_toggle(manager, &item)
				element_message(element, .Update)
			}

			case .Update: {
				button.icon = task.folded ? .Simple_Right : .Simple_Down
			}
 		}

		return 0
	}

	res.box = task_box_init(res, {}, text)
	res.box.message_user = task_box_message_custom

	return
}

// push line element to panel middle with indentation
task_push :: proc(
	indentation: int, 
	text := "", 
	index_at := -1,
) -> (res: ^Task) {
	res = task_init(indentation, text)

	parent := res.parent
	if index_at == -1 || index_at == len(parent.children) {
		append(&parent.children, res)
	} else {
		insert_at(&parent.children, index_at, res)
	}	

	return
}

// push line element to panel middle with indentation
task_push_undoable :: proc(
	manager: ^Undo_Manager,
	indentation: int, 
	text := "", 
	index_at := -1,
) -> (res: ^Task) {
	res = task_init(indentation, text)
	parent := res.parent

	if index_at == -1 || index_at == len(parent.children) {
		item := Undo_Item_Task_Append { res }
		undo_task_append(manager, &item)
	} else {
		item := Undo_Item_Task_Insert_At { index_at, res }
		undo_task_insert_at(manager, &item)
	}	

	return
}

task_box_format_to_lines :: proc(box: ^Task_Box, width: f32) {
	font, size := element_retrieve_font_options(box)
	fontstash.format_to_lines(
		font,
		size * SCALE,
		strings.to_string(box.builder),
		max(300 * SCALE, width),
		&box.wrapped_lines,
	)
}

// iter through visible children
task_children_iter :: proc(
	indentation: int,
	index: ^int,
) -> (res: ^Task, ok: bool) {
	if index^ > len(tasks_visible) - 1 {
		return
	}

	res = tasks_visible[index^]
	ok = indentation <= res.indentation
	index^ += 1
	return
}

// init panel with data
mode_panel_init :: proc(parent: ^Element, flags: Element_Flags) -> (res: ^Mode_Panel) {
	res = element_init(Mode_Panel, parent, flags, mode_panel_message)
	res.kanban_outlines = make([dynamic]Rect, 0, 64)

	res.drag = {
		.List = {
			offset_x = 100,	
			offset_y = 100,	
		},

		.Kanban = {
			offset_x = 100,	
			offset_y = 100,	
		},
	}

	return
}

mode_panel_draw_verticals :: proc(target: ^Render_Target) {
	if task_head < 1 {
		return
	}

	tab := options_tab() * TAB_WIDTH * SCALE
	p := tasks_visible[task_head]
	color := theme.text_default

	for p != nil {
		if p.visible_parent != nil {
			index := p.visible_parent.visible_index + 1
			bound_rect: Rect

			for child in task_children_iter(p.indentation, &index) {
				if bound_rect == {} {
					bound_rect = child.box.bounds
				} else {
					bound_rect = rect_bounding(bound_rect, child.box.bounds)
				}
			}

			bound_rect.l -= tab
			bound_rect.r = bound_rect.l + 2 * SCALE
			render_rect(target, bound_rect, color, 0)

			if color.a == 255 {
				color.a = 100
			}
		}

		p = p.visible_parent
	}
}

//////////////////////////////////////////////
// messages
//////////////////////////////////////////////

mode_panel_message :: proc(element: ^Element, msg: Message, di: int, dp: rawptr) -> int {
	panel := cast(^Mode_Panel) element
	drag := &panel.drag[panel.mode]

	#partial switch msg {
		case .Find_By_Point_Recursive: {
			p := cast(^Find_By_Point) dp

			for i := len(element.children) - 1; i >= 0; i -= 1 {
				task := cast(^Task) element.children[i]

				if !task.visible {
					continue
				}

				if element_message(task, .Find_By_Point_Recursive, 0, dp) == 1 {
					// return p.res != nil ? p.res : element
					return 1
				}
			}

			return 1
		}

		// NOTE custom layout based on mode
		case .Layout: {
			element.bounds = element.window.modifiable_bounds
			element.clip = element.bounds
			
			bounds := element.bounds
			bounds.l += drag.offset_x
			bounds.t += drag.offset_y
			gap_vertical_scaled := math.round(panel.gap_vertical * SCALE)

			switch panel.mode {
				case .List: {
					cut := bounds

					for child in element.children {
						task := cast(^Task) child
						
						if !task.visible {
							continue
						}

						// format before taking height
						tab_size := f32(task.indentation) * options_tab() * TAB_WIDTH * SCALE
						fold_size := task.has_children ? math.round(DEFAULT_FONT_SIZE * SCALE) : 0
						width_limit := rect_width(element.bounds) - tab_size - fold_size
						width_limit -= drag.offset_x
						task_box_format_to_lines(task.box, width_limit)
						h := element_message(task, .Get_Height)
						r := rect_cut_top(&cut, f32(h))
						element_move(task, r)
						cut.t += gap_vertical_scaled
					}
				}

				case .Kanban: {
					cut := bounds
					clear(&panel.kanban_outlines)
					// cutoff a rect left
					kanban_current: Rect
					kanban_children_count: int
					kanban_children_start: int

					for child, i in element.children {
						task := cast(^Task) child
						
						if !task.visible {
							continue
						}

						if task.indentation == 0 {
							if kanban_current != {} {
								rect := kanban_current
								rect.b = rect.t
								rect.t = bounds.t
								append(&panel.kanban_outlines, rect)
							}

							// get max indentations till same line is found
							max_indentations: int
							kanban_children_start = i
							kanban_children_count = 1

							for j in i + 1..<len(element.children) {
								other := cast(^Task) element.children[j]

								if .Hide in other.flags || !other.visible {
									continue
								}

								max_indentations = max(max_indentations, other.indentation)
								
								if other.indentation == 0 {
									break
								} else {
									kanban_children_count += 1
								}
							}

							kanban_width := KANBAN_WIDTH * SCALE
							kanban_width += f32(max_indentations) * options_tab() * TAB_WIDTH * SCALE
							kanban_current = rect_cut_left(&cut, kanban_width)
							cut.l += panel.gap_horizontal * SCALE + KANBAN_MARGIN * 2 * SCALE
						}

						// format before taking height, predict width
						tab_size := f32(task.indentation) * options_tab() * TAB_WIDTH * SCALE
						fold_size := task.has_children ? math.round(DEFAULT_FONT_SIZE * SCALE) : 0
						task_box_format_to_lines(task.box, rect_width(kanban_current) - tab_size - fold_size)
						h := element_message(task, .Get_Height)
						r := rect_cut_top(&kanban_current, f32(h))
						element_move(task, r)

						if i - kanban_children_start < kanban_children_count - 1 {
							kanban_current.t += gap_vertical_scaled
						}
					}

					if kanban_current != {} {
						rect := kanban_current
						rect.b = rect.t
						rect.t = bounds.t
						append(&panel.kanban_outlines, rect)
					}
				}
			}
		}

		case .Paint_Recursive: {
			target := element.window.target 

			bounds := element.bounds
			render_rect(target, bounds, theme.background[0], 0)
			bounds.l -= drag.offset_x
			bounds.t -= drag.offset_y

			switch panel.mode {
				case .List: {

				}

				case .Kanban: {
					// draw outlines
					color := theme.panel_back
					// color := color_blend(mix, BLACK, 0.9, false)
					for outline in panel.kanban_outlines {
						rect := rect_margin(outline, -KANBAN_MARGIN * SCALE)
						render_rect(target, rect, color, ROUNDNESS)
					}
				}
			}

			mode_panel_draw_verticals(target)

			// custom draw loop!
			for child in element.children {
				task := cast(^Task) child

				if !task.visible {
					continue
				}

				render_element_clipped(target, child)
			}

			// render selection outlines
			if task_head != -1 {
				render_push_clip(target, panel.clip)
				low, high := task_low_and_high()

				for i in low..<high + 1 {
					task := tasks_visible[i]
					rect := task.box.clip
					
					if low <= task.visible_index && task.visible_index <= high {
						is_head := task.visible_index == task_head
						color := is_head ? theme.caret : theme.caret_highlight
						render_rect_outline(target, rect, color)
					} 
				}
			}

			return 1
		}

		case .Deallocate_Recursive: {
			delete(panel.kanban_outlines)
		}

		case .Middle_Down: {
			drag.start_x = drag.offset_x
			drag.start_y = drag.offset_y
		}

		case .Mouse_Drag: {
			mouse := (cast(^Mouse_Coordinates) dp)^

			if element.window.pressed_button == MOUSE_MIDDLE {
				diff_x := element.window.cursor_x - mouse.x
				diff_y := element.window.cursor_y - mouse.y

				drag.offset_x = drag.start_x + diff_x
				drag.offset_y = drag.start_y + diff_y

				window_set_cursor(element.window, .Crosshair)
				element_repaint(element)
				return 1
			}
		}

		case .Mouse_Scroll_Y: {
			drag.offset_y += f32(di) * 20
			element_repaint(element)
			return 1
		}

		case .Mouse_Scroll_X: {
			drag.offset_x += f32(di) * 20
			element_repaint(element)
			return 1
		}

		case .Update: {
			for child in element.children {
				element_message(child, .Update, di, dp)
			}
		}
	}

	return 0
}

task_box_message_custom :: proc(element: ^Element, msg: Message, di: int, dp: rawptr) -> int {
	box := cast(^Task_Box) element
	task := cast(^Task) element.parent

	#partial switch msg {
		case .Box_Text_Color: {
			color := cast(^Color) dp
			color^ = theme_task_text(task.state)
			return 1
		}

		case .Paint_Recursive: {
			target := element.window.target
			box.bounds.l += TASK_TEXT_OFFSET
			
			if task.has_children {
				box.bounds.l += math.round(DEFAULT_FONT_SIZE * SCALE)
			}

			if task.visible_index == task_head {
				font, size := element_retrieve_font_options(box)
				scaled_size := size * SCALE
				x := box.bounds.l
				y := box.bounds.t
				box_render_selection(target, box, font, scaled_size, x, y)
				box_render_caret(target, box, font, scaled_size, x, y)
			}
		}

		case .Left_Down: {
			// set line to the head
			if task_head != task.visible_index {
				task_head = task.visible_index
				task_tail_check()
			} 

			if task_head != task_tail {
				box_set_caret(task.box, BOX_END, nil)
			} else {
				old_tail := box.tail
				element_box_mouse_selection(task.box, task.box, di, false)

				if element.window.shift && di == 0 {
					box.tail = old_tail
				}
			}

			return 1
		}

		case .Mouse_Drag: {
			if task_head != task_tail {
				return 0
			}

			if element.window.pressed_button == MOUSE_LEFT {
				element_box_mouse_selection(task.box, task.box, di, true)
				element_repaint(task)
			}

			return 1
		}

		case .Value_Changed: {
			// editor_set_unsaved_changes_title(&element.window.manager)
		}
	}

	return 0
}

task_message :: proc(element: ^Element, msg: Message, di: int, dp: rawptr) -> int {
	task := cast(^Task) element
	tab := options_tab() * TAB_WIDTH * SCALE
	tag_mode := options_tag_mode()
	draw_tags := tag_mode != TAG_SHOW_NONE && task.tags != 0x00
	TAG_COLOR_ONLY :: 10

	additional_size :: proc(task: ^Task, draw_tags: bool) -> (res: f32) {
		if draw_tags {
			tag_mode := options_tag_mode()
			if tag_mode == TAG_SHOW_TEXT_AND_COLOR {
				res = DEFAULT_FONT_SIZE * SCALE + TASK_DATA_MARGIN * 2 * SCALE
			} else if tag_mode == TAG_SHOW_COLOR {
				res = TAG_COLOR_ONLY * SCALE + TASK_DATA_MARGIN * 2 * SCALE
			}
		}

		return
	}

	#partial switch msg {
		case .Get_Width: {
			return int(SCALE * 200)
		}

		case .Get_Height: {
			task.font_options = task.has_children ? &font_options_bold : nil
			line_size := efont_size(element) * f32(len(task.box.wrapped_lines))

			line_size_addition := additional_size(task, draw_tags)

			line_size += line_size_addition
			return int(line_size)
		}

		case .Layout: {
			offset_indentation := math.round(task.indentation_smooth * tab)
			if task.top_animation_start {
				task.top_offset = task.top_old - task.bounds.t	
				task.top_animation_start = false
			}
			offset_top := task.top_offset

			// manually offset the line rectangle in total while retaining parent clip
			element.bounds.t += math.round(offset_top)
			element.bounds.b += math.round(offset_top)
			element.clip = rect_intersection(element.parent.clip, element.bounds)

			cut := element.bounds
			cut.l += offset_indentation

			if task.has_children {
				left := cut
				left.r = left.l + math.round(DEFAULT_FONT_SIZE * SCALE)
				scaled_size := task.font_options.size * SCALE
				left.b = left.t + scaled_size
				element_move(task.button_fold, left)
			}
			
			task.box.font_options = task.font_options
			element_move(task.box, cut)
		}

		case .Paint_Recursive: {
			target := element.window.target

			// render panel front color
			{
				rect := task.box.bounds
				color := color_blend_amount(GREEN, theme.panel_front, task.has_children ? 0.05 : 0)
				render_rect(target, rect, color, ROUNDNESS)
			}

			// draw tags at an offset
			if draw_tags {
				rect := task.box.clip
				rect = rect_margin(rect, math.round(TASK_DATA_MARGIN * SCALE))

				// offset
				{
					add := additional_size(task, true)
					rect.t = rect.b - add + math.round(TASK_DATA_GAP * SCALE)
				}

				switch tag_mode {
					case TAG_SHOW_TEXT_AND_COLOR: {
						rect.b = rect.t + math.round(DEFAULT_FONT_SIZE * SCALE)
					}

					case TAG_SHOW_COLOR: {
						rect.b = rect.t + TAG_COLOR_ONLY * SCALE
					}
				}

				font := font_regular
				scaled_size := DEFAULT_FONT_SIZE * SCALE
				text_margin := math.round(10 * SCALE)
				gap := math.round(TASK_DATA_GAP * SCALE)

				// go through each existing tag, draw each one
				for i in 0..<u8(8) {
					value := u8(1 << i)

					if task.tags & value == value {
						tag := &sb.tags.tag_data[i]

						switch tag_mode {
							case TAG_SHOW_TEXT_AND_COLOR: {
								text := strings.to_string(tag.builder^)
								width := fontstash.string_width(font, scaled_size, text)
								r := rect_cut_left_hard(&rect, width + text_margin)

								if rect_valid(r) {
									render_rect(target, r, tag.color, ROUNDNESS)
									render_string_aligned(target, font, text, r, theme.panel_front, .Middle, .Middle, scaled_size)
								}
							}

							case TAG_SHOW_COLOR: {
								r := rect_cut_left_hard(&rect, 50 * SCALE)
								if rect_valid(r) {
									render_rect(target, r, tag.color, ROUNDNESS)
								}
							}

							case: {
								unimplemented("shouldnt get here")
							}
						}

						rect.l += gap
					}
				}
			}
		}

		case .Middle_Down: {
			window_set_pressed(element.window, mode_panel, MOUSE_MIDDLE)
		}

		case .Find_By_Point_Recursive: {
			p := cast(^Find_By_Point) dp

			// NOTE we ignore the line intersection here
			for i := len(element.children) - 1; i >= 0; i -= 1 {
				child := element.children[i]

				if child.bounds == {} {
					continue
				}

				if (.Hide not_in child.flags) && rect_contains(child.bounds, p.x, p.y) {
					p.res = child
					return 1
				}
			}

			return 0
		}

		case .Animate: {
			handled := false

			handled |= animate_to(
				&task.indentation_animating,
				&task.indentation_smooth, 
				f32(task.indentation),
				2, 
				0.01,
			)
			
			handled |= animate_to(
				&task.top_animating,
				&task.top_offset, 
				0, 
				1, 
				1,
			)

			return int(handled)
		}

		case .Update: {
			for child in element.children {
				element_message(child, msg, di, dp)
			}
		}
	}

	return 0
}