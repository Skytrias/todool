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

panel_top: ^Panel
panel_info: ^Panel
panel_temp: ^Panel
mode_button: ^Button
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
TAB_WIDTH :: 50
TASK_DATA_GAP :: 5
TASK_TEXT_OFFSET :: 2
TASK_DATA_MARGIN :: 2

TAB_TEMP :: 0.5

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
		scale := element.window.scale

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

			case .Paint_Recursive: {
				// NOTE: copy paste from original
				pressed := element.window.pressed == element
				hovered := element.window.hovered == element
				target := element.window.target

				text_color := theme.text[.Normal]
				// render_element_background(target, element.bounds, theme.background, &text_color, hovered, pressed)

				icon_size := style.icon_size * scale
				render_icon_aligned(target, font_icon, button.icon, element.bounds, text_color, .Middle, .Middle, icon_size)

				if element.window.focused == element {
					render_rect_outline(target, element.bounds, RED, style.roundness)
				}

				return 1
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
		size * box.window.scale,
		strings.to_string(box.builder),
		max(300 * box.window.scale, width),
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

	scale := mode_panel.window.scale
	tab := TAB_TEMP * TAB_WIDTH * scale
	p := tasks_visible[task_head]
	color := theme.text[.Normal]

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
			bound_rect.r = bound_rect.l + 2
			render_rect(target, bound_rect, color)

			if color.a == 255 {
				color.a = 100
			}
		}

		p = p.visible_parent
	}
}

task_box_mouse_selection :: proc(task: ^Task, clicks: int, dragging: bool) -> (res: int) {
	// log.info("relative clicks", clicks)
	text := strings.to_string(task.box.builder)
	font, size := element_retrieve_font_options(task)
	scaled_size := size * task.window.scale
	scale := fontstash.scale_for_pixel_height(font, scaled_size)

	// state used in word / single mouse selection
	Mouse_Character_Selection :: struct {
		relative_x, relative_y: f32,
		old_x, x: f32,
		old_y, y: f32,	
		codepoint_offset: int, // offset after a text line ended in rune codepoints ofset
		width_codepoint: f32, // global to store width
	}
	mcs: Mouse_Character_Selection

	// single character collision
	mcs_check_single :: proc(
		using mcs: ^Mouse_Character_Selection,
		b: ^Box,
		codepoint_index: int,
		dragging: bool,
	) -> bool {
		if old_x < relative_x && 
			relative_x < x && 
			old_y < relative_y && 
			relative_y < y {
			if !dragging {
				codepoint_index := codepoint_index
				box_set_caret(b, 0, &codepoint_index)
			} else {
				b.head = codepoint_index
			}

			return true
		}

		return false
	}

	// check word collision
	// 
	// old_x is word_start_x
	// x is word_end_x
	mcs_check_word :: proc(
		using mcs: ^Mouse_Character_Selection,
		b: ^Box,
		word_start: int,
		word_end: int,
	) -> bool {
		if old_x < relative_x && 
			relative_x < x && 
			old_y < relative_y && 
			relative_y < y {
			// set first result of word selection, further selection extends range
			if !b.word_selection_started {
				b.word_selection_started = true
				b.word_start = word_start
				b.word_end = word_end
			}

			// get result
			low := min(word_start, b.word_start)
			high := max(word_end, b.word_end)

			// visually position the caret left / right when selecting the first word
			if word_start == b.word_start && word_end == b.word_end {
				diff := x - old_x
				
				// middle of word crossed, swap
				if old_x < relative_x && relative_x < old_x + diff / 2 {
					low, high = high, low
				}
			}

			// invert head
			if word_start < b.word_start {
				b.head = low
				b.tail = high
			} else {
				b.head = high
				b.tail = low
			}

			return true
		}

		return false
	}

	// clamp to left when x is below 0 and y above 
	mcs_check_line_last :: proc(using mcs: ^Mouse_Character_Selection, b: ^Box) {
		if relative_y > y {
			b.head = codepoint_offset
		}
	}

	using mcs
	relative_x = task.window.cursor_x - task.box.bounds.l
	relative_y = task.window.cursor_y - task.box.bounds.t

	ds := &task.box.ds
	b := task.box
	clicks := clicks % 3

	// reset on new click start
	if clicks == 0 && !dragging {
		b.word_selection_started = false
		b.line_selection_started = false
	}

	// NOTE single line clicks
	if clicks == 0 {
		// loop through lines
		search_line: for text in b.wrapped_lines {
			// set state
			y += scaled_size
			x = 0
			old_x = 0

			// clamp to left when x is below 0 and y above 
			if relative_x < 0 && relative_y < old_y {
				b.head = codepoint_offset
				break
			}

			// loop through codepoints
			ds^ = {}
			for codepoint, i in cutf8.ds_iter(ds, text) {
				width_codepoint = fontstash.codepoint_xadvance(font, codepoint, scale)
				x += width_codepoint

				// check mouse collision
				if mcs_check_single(&mcs, b, i + codepoint_offset, dragging) {
					break search_line
				}
			}

			x += scaled_size
			mcs_check_single(&mcs, b, ds.codepoint_count + codepoint_offset, dragging)

			codepoint_offset += ds.codepoint_count
			old_y = y
		}

		mcs_check_line_last(&mcs, b)
	} else {
		if clicks == 1 {
			// NOTE WORD selection
			// loop through lines
			search_line_word: for text in b.wrapped_lines {
				// set state
				old_x = 0 
				x = 0
				y += scaled_size

				// temp
				index_word_start: int = -1
				codepoint_last: rune
				index_whitespace_start: int = -1
				x_word_start: f32
				x_whitespace_start: f32 = -1

				// clamp to left
				if relative_x < 0 && relative_y < old_y && b.word_selection_started {
					b.head = codepoint_offset
					break
				}

				// loop through codepoints
				ds^ = {}
				for codepoint, i in cutf8.ds_iter(ds, text) {
					width_codepoint := fontstash.codepoint_xadvance(font, codepoint, scale)
					
					// check for word completion
					if index_word_start != -1 && codepoint == ' ' {
						old_x = x_word_start
						mcs_check_word(&mcs, b, codepoint_offset + index_word_start, codepoint_offset + i)
						index_word_start = -1
					}
					
					// check for starting codepoint being letter
					if index_word_start == -1 && unicode.is_letter(codepoint) {
						index_word_start = i
						x_word_start = x
					}

					// check for space word completion
					if index_whitespace_start != -1 && unicode.is_letter(codepoint) {
						old_x = x_whitespace_start
						mcs_check_word(&mcs, b, codepoint_offset + index_whitespace_start, codepoint_offset + i)
						index_whitespace_start = -1
					}

					// check for starting whitespace being letter
					if index_whitespace_start == -1 && codepoint == ' ' {
						index_whitespace_start = i
						x_whitespace_start = x
					}

					// set new position
					x += width_codepoint
					codepoint_last = codepoint
				}

				// finish whitespace and end letter
				if index_whitespace_start != -1 && codepoint_last == ' ' {
					old_x = x_whitespace_start
					mcs_check_word(&mcs, b, codepoint_offset + index_whitespace_start, codepoint_offset + ds.codepoint_count)
				}

				// finish end word
				if index_word_start != -1 && unicode.is_letter(codepoint_last) {
					old_x = x_word_start
					mcs_check_word(&mcs, b, codepoint_offset + index_word_start, codepoint_offset + ds.codepoint_count)
				}

				old_y = y
				codepoint_offset += ds.codepoint_count
			}

			mcs_check_line_last(&mcs, b)
		} else {
			// LINE
			for text, line_index in b.wrapped_lines {
				y += scaled_size
				codepoints := cutf8.count(text)

				if old_y < relative_y && relative_y < y {
					if !b.line_selection_started {
						b.line_selection_start = codepoint_offset
						b.line_selection_end = codepoint_offset + codepoints
						b.line_selection_start_y = y
						b.line_selection_started = true
					} 

					goal_left := codepoint_offset
					goal_right := codepoint_offset + codepoints

					low := min(goal_left, b.line_selection_start)
					high := max(goal_right, b.line_selection_end)

					if relative_y > b.line_selection_start_y {
						low, high = high, low
					}

					b.head = low
					b.tail = high
					break
				}

				codepoint_offset += codepoints
				old_y = y
			}
		}
	}

	return
}

//////////////////////////////////////////////
// messages
//////////////////////////////////////////////

mode_panel_message :: proc(element: ^Element, msg: Message, di: int, dp: rawptr) -> int {
	panel := cast(^Mode_Panel) element
	scale := element.window.scale
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
			gap_vertical_scaled := math.round(panel.gap_vertical * scale)

			switch panel.mode {
				case .List: {
					cut := bounds

					for child in element.children {
						task := cast(^Task) child
						
						if !task.visible {
							continue
						}

						// format before taking height
						tab_size := f32(task.indentation) * TAB_TEMP * TAB_WIDTH * scale
						fold_size := task.has_children ? math.round(DEFAULT_FONT_SIZE * scale) : 0
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

							kanban_width := KANBAN_WIDTH * scale
							kanban_width += f32(max_indentations) * TAB_TEMP * TAB_WIDTH * scale
							kanban_current = rect_cut_left(&cut, kanban_width)
							cut.l += panel.gap_horizontal * scale + KANBAN_MARGIN * 2 * scale
						}

						// format before taking height, predict width
						tab_size := f32(task.indentation) * TAB_TEMP * TAB_WIDTH * scale
						fold_size := task.has_children ? math.round(DEFAULT_FONT_SIZE * scale) : 0
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
			render_rect(target, bounds, theme.background)
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
						rect := rect_margin(outline, -KANBAN_MARGIN * scale)
						render_rect(target, rect, color, style.roundness)
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
						render_rect_outline(target, rect, color, style.roundness)
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
	scale := element.window.scale

	#partial switch msg {
		case .Box_Text_Color: {
			color := cast(^Color) dp
			// color^ = theme.text[.Normal]
			color^ = theme.text[task.state]
			return 1
		}

		case .Paint_Recursive: {
			target := element.window.target
			box.bounds.l += TASK_TEXT_OFFSET
			
			// if task.state != .Normal {
			// 	scaled_size := math.round(DEFAULT_FONT_SIZE / 2 * scale)
			// 	icon_rect := rect_cut_left(&box.bounds, scaled_size + 10)
			// 	icon_rect.t += 1
			// 	icon_rect.b -= 1
			// 	icon: Icon = task.state == .Done ? .Check : .Close
			// 	color := theme.text[task.state]
			// 	render_rect(target, icon_rect, theme.text[.Normal], style.roundness)
			// 	render_icon_aligned(target, font_icon, icon, icon_rect, color, .Middle, .Middle, scaled_size)
			// 	box.bounds.l += 5
			// }

			if task.has_children {
				box.bounds.l += math.round(DEFAULT_FONT_SIZE * scale)
			}

			if task.visible_index == task_head {
				font, size := element_retrieve_font_options(box)
				scaled_size := size * scale
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
				task_box_mouse_selection(task, di, false)

				if element.window.shift && di == 0 {
					box.tail = old_tail
				}
			}
		}

		case .Mouse_Drag: {
			if task_head != task_tail {
				return 0
			}

			if element.window.pressed_button == MOUSE_LEFT {
				task_box_mouse_selection(task, di, true)
				// task.box.head = res
				element_repaint(task)
			}
		}

		case .Value_Changed: {
			// editor_set_unsaved_changes_title(&element.window.manager)
		}
	}

	return 0
}

task_message :: proc(element: ^Element, msg: Message, di: int, dp: rawptr) -> int {
	task := cast(^Task) element
	scale := element.window.scale
	tab := TAB_TEMP * TAB_WIDTH * scale

	#partial switch msg {
		case .Get_Width: {
			return int(scale * 200)
		}

		case .Get_Height: {
			task.font_options = task.has_children ? &font_options_bold : nil
			line_size := efont_size(element) * f32(len(task.box.wrapped_lines))

			if task.tags != 0x00 {
				line_size += DEFAULT_FONT_SIZE * scale + TASK_DATA_MARGIN * 2 * scale
			}

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
				left.r = left.l + math.round(DEFAULT_FONT_SIZE * scale)
				scaled_size := task.font_options.size * scale
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
				render_rect(target, rect, color, style.roundness)
			}

			// draw tags at an offset
			if task.tags != 0x00 {
				rect := task.box.bounds
				rect = rect_margin(rect, math.round(TASK_DATA_MARGIN * scale))

				// offset
				{
					font, size := element_retrieve_font_options(task.box)
					scaled_size := size * scale
					rect.t += scaled_size
				}

				rect.b = rect.t + math.round(20 * scale)

				font := font_regular
				scaled_size := DEFAULT_FONT_SIZE * scale
				text_margin := math.round(10 * scale)
				gap := math.round(TASK_DATA_GAP * scale)

				// go through each existing tag, draw each one
				for i in 0..<u8(8) {
					value := u8(1 << i)
					if task.tags & value == value {
						tag := &tags_data[i]
						width := fontstash.string_width(font, scaled_size, tag.text)
						r := rect_cut_left(&rect, width + text_margin)
						render_rect(target, r, tag.color, style.roundness)
						render_string_aligned(target, font, tag.text, r, theme.panel_front, .Middle, .Middle, scaled_size)
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

			if task.indentation_animating {
				handled |= animate_to(&task.indentation_smooth, f32(task.indentation), 2, 0.01)
			}

			if task.top_animating {
				handled |= animate_to(&task.top_offset, 0, 1, 1)
			}

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