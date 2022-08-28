package src

import "core:io"
import "core:mem"
import "core:strconv"
import "core:fmt"
import "core:unicode"
import "core:strings"
import "core:log"
import "core:math"
import "core:intrinsics"
import "core:slice"
import "core:reflect"
import "../cutf8"
import "../fontstash"

// last save
last_save_location: string

panel_info: ^Panel
mode_panel: ^Mode_Panel
window_main: ^Window
caret_rect: Rect
caret_lerp_speed_y := f32(1)
caret_lerp_speed_x := f32(1)
last_was_task_copy := false

// goto state
panel_goto: ^Panel_Floaty
goto_saved_task_head: int
goto_saved_task_tail: int
goto_transition_animating: bool
goto_transition_unit: f32
goto_transition_hide: bool

// search state
panel_search: ^Panel
search_index := -1
search_saved_task_head: int
search_saved_task_tail: int
search_saved_box_head: int
search_saved_box_tail: int
search_draw_index: int // gets reset & used to highlight search index current

// copy state
copy_text_data: strings.Builder
copy_task_data: [dynamic]Copy_Task

Search_Result :: struct #packed {
	low, high: u16,
}

Search_Result_Mixed :: struct #packed {
	task: ^Task,
	low, high: u16,
}

search_results_mixed: [dynamic]Search_Result_Mixed

// font options used
font_options_header: Font_Options
font_options_bold: Font_Options

// works in visible line space!
// gets used in key combs
task_head := 0
task_tail := 0
old_task_head := 0
old_task_tail := 0
tasks_visible: [dynamic]^Task

// drag state
drag_list: [dynamic]^Task
drag_panel: ^Panel_Floaty
drag_label: ^Label
dragging: bool
drag_index_at: int

// dirty file
dirty := 0
dirty_saved := 0

// bookmark data
bookmark_index := -1
bookmarks: [dynamic]int

// simple split from mode_panel to search bar
Custom_Split :: struct {
	using element: Element
}

drag_init :: proc(window: ^Window) {
	floaty := panel_floaty_init(&window.element, { .Panel_Default_Background })
	floaty.x = 0
	floaty.y = 0
	floaty.width = 50
	floaty.height = DEFAULT_FONT_SIZE * SCALE + TEXT_MARGIN_VERTICAL * SCALE
	floaty.z_index = 200
	p := floaty.panel
	p.flags |= { .Panel_Expand }
	p.margin = 10
	p.background_index = 2
	p.rounded = true
	p.shadow = true
	floaty.message_user = proc(element: ^Element, msg: Message, di: int, dp: rawptr) -> int {
		floaty := cast(^Panel_Floaty) element

		#partial switch msg {
			case .Layout: {
				floaty.x = element.window.cursor_x - 10
				floaty.y = element.window.cursor_y - 10
			}

			case .Animate: {
				return int(dragging)
			}
		}

		return 0
	}
	
	drag_label = label_init(p, { .Label_Center }, "3x")
	drag_panel = floaty
	element_hide(floaty, true)
}

// simply write task text with indentation into a builder
task_write_text_indentation :: proc(b: ^strings.Builder, task: ^Task, indentation: int) {
	for i in 0..<indentation {
		strings.write_byte(b, '\t')
	}

	strings.write_string(b, strings.to_string(task.box.builder))
	strings.write_byte(b, '\n')
}

task_head_tail_call_all :: proc(
	data: rawptr,
	call: proc(task: ^Task, data: rawptr), 
) {
	// empty
	if task_head == -1 {
		return
	}

	low, high := task_low_and_high()
	for i in low..<high + 1 {
		task := tasks_visible[i]
		call(task, data)
	}
}

// just clamp for safety here instead of everywhere
task_head_tail_clamp :: proc() {
	task_head = clamp(task_head, 0, len(tasks_visible) - 1)
	task_tail = clamp(task_tail, 0, len(tasks_visible) - 1)
}

task_head_tail_call :: proc(
	data: rawptr,
	call: proc(task: ^Task, data: rawptr), 
) {
	// empty
	if task_head == -1 || task_head == task_tail {
		return
	}

	low, high := task_low_and_high()
	for i in low..<high + 1 {
		task := tasks_visible[i]
		call(task, data)
	}
}

task_data_init :: proc() {
	tasks_visible = make([dynamic]^Task, 0, 128)
	bookmarks = make([dynamic]int, 0, 32)
	search_results_mixed = make([dynamic]Search_Result_Mixed, 0, 32)

	font_options_header = {
		font = font_bold,
		size = 30,
	}
	font_options_bold = {
		font = font_bold,
		size = DEFAULT_FONT_SIZE + 5,
	}

	strings.builder_init(&copy_text_data, 0, mem.Kilobyte * 10)
	copy_task_data = make([dynamic]Copy_Task, 0, 128)

	drag_list = make([dynamic]^Task, 0, 64)

	pomodoro_init()
}

task_data_destroy :: proc() {
	pomodoro_destroy()
	delete(tasks_visible)
	delete(bookmarks)
	delete(search_results_mixed)
	delete(copy_text_data.buf)
	delete(copy_task_data)
	delete(drag_list)
	delete(last_save_location)
}

// reset copy data
copy_reset :: proc() {
	strings.builder_reset(&copy_text_data)
	clear(&copy_task_data)
}

// just push text, e.g. from archive
copy_push_empty :: proc(text: string) {
	text_byte_start := len(copy_text_data.buf)
	strings.write_string(&copy_text_data, text)
	text_byte_end := len(copy_text_data.buf)

	// copy crucial info of task
	append(&copy_task_data, Copy_Task {
		text_byte_start = u32(text_byte_start),
		text_byte_end = u32(text_byte_end),
	})
}

// push a task to copy list
copy_push_task :: proc(task: ^Task) {
	// NOTE works with utf8 :) copies task text
	text_byte_start := len(copy_text_data.buf)
	strings.write_string(&copy_text_data, strings.to_string(task.box.builder))
	text_byte_end := len(copy_text_data.buf)

	// copy crucial info of task
	append(&copy_task_data, Copy_Task {
		u32(text_byte_start),
		u32(text_byte_end),
		u8(task.indentation),
		task.state,
		task.tags,
		task.folded,
		task.bookmarked,
		task.image_display.img,
	})
}

copy_empty :: proc() -> bool {
	return len(copy_task_data) == 0
}

copy_paste_at :: proc(
	manager: ^Undo_Manager, 
	real_index: int, 
	indentation: int,
) {
	full_text := strings.to_string(copy_text_data)
	index_at := real_index

	// find lowest indentation
	lowest_indentation := 255
	for t, i in copy_task_data {
		lowest_indentation = min(lowest_indentation, int(t.indentation))
	}

	// copy into index range
	for t, i in copy_task_data {
		text := full_text[t.text_byte_start:t.text_byte_end]
		relative_indentation := indentation + int(t.indentation) - lowest_indentation
		
		task := task_push_undoable(manager, relative_indentation, text, index_at + i)
		task.folded = t.folded
		task.state = t.state
		task.bookmarked = t.bookmarked
		task.tags = t.tags
		task.image_display.img = t.stored_image
	}
}

// advance bookmark or jump to closest on reset
bookmark_advance :: proc(backward: bool) {
	// on reset set to closest from current
	if bookmark_index == -1 && task_head != -1 {
		// look for anything higher than the current index
		visible_index := tasks_visible[task_head].visible_index
		found: bool

		if backward {
			// backward
			for i := len(bookmarks) - 1; i >= 0; i -= 1 {
				index := bookmarks[i]

				if index < visible_index {
					bookmark_index = i
					found = true
					break
				}
			}
		} else {
			// forward
			for index, i in bookmarks {
				if index > visible_index {
					bookmark_index = i
					found = true
					break
				}
			}
		}

		if found {
			return
		}
	}

	// just normally set
	range_advance_index(&bookmark_index, len(bookmarks) - 1, backward)
}

// advance index in a looping fashion, backwards can be easily used
range_advance_index :: proc(index: ^int, high: int, backwards := false) {
	if backwards {
		if index^ > 0 {
			index^ -= 1
		} else {
			index^ = high
		}
	} else {
		if index^ < high {
			index^ += 1
		} else {
			index^ = 0
		}
	}
}

// editor_pushed_unsaved: bool
TAB_WIDTH :: 100
TASK_DATA_GAP :: 5
TASK_TEXT_OFFSET :: 2
TASK_DATA_MARGIN :: 2
TASK_BOOKMARK_WIDTH :: 10

Task_State :: enum u8 {
	Normal,
	Done,
	Canceled,
} 

// Bare data to copy task from
Copy_Task :: struct #packed {
	text_byte_start: u32, // offset into text_list
	text_byte_end: u32, // offset into text_list
	indentation: u8,
	state: Task_State,
	tags: u8,
	folded: bool,
	bookmarked: bool,
	stored_image: ^Stored_Image,
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
	image_display: ^Image_Display,

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
	state_count: [Task_State]int,
	search_results: [dynamic]Search_Result,

	// visible kanban outline - used for bounds check by kanban 
	kanban_rect: Rect,

	// wether we want to be able to jump to this task
	bookmarked: bool,
}

Mode :: enum {
	List,
	Kanban,
	// Agenda,
}
KANBAN_WIDTH :: 300
KANBAN_MARGIN :: 10

// element to custom layout based on internal mode
Mode_Panel :: struct {
	using element: Element,
	mode: Mode,

	image_display: ^Image_Display,

	kanban_left: f32, // layout seperation
	gap_vertical: f32,
	gap_horizontal: f32,
	margin_vertical: f32, // task text spacing

	cam: [Mode]Pan_Camera,
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

task_head_tail_check_begin :: proc() ->  bool {
	if !mode_panel.window.shift && task_head != task_tail {
		task_tail = task_head
		return false
	}

	return true
}

// set line selection to head when no shift
task_head_tail_check_end :: proc() {
	if !mode_panel.window.shift {
		task_tail = task_head
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
	allocator := window_allocator(window_main)
	res = new(Task, allocator)
	element := cast(^Element) res
	element.message_class = task_message
	element.allocator = allocator

	// just assign parent already
	parent := mode_panel	
	element.window = parent.window
	element.parent = parent

	// insert task results
	res.indentation = indentation
	res.indentation_smooth = f32(indentation)
	
	res.button_fold = icon_button_init(res, {}, .Simple_Down, nil, allocator)
	res.button_fold.message_user = proc(element: ^Element, msg: Message, di: int, dp: rawptr) -> int {
		button := cast(^Icon_Button) element
		task := cast(^Task) button.parent

		#partial switch msg {
			case .Clicked: {
				manager := mode_panel_manager_scoped()
				task_head_tail_push(manager)
				item := Undo_Item_Bool_Toggle { &task.folded }
				undo_bool_toggle(manager, &item)

				task_head = task.index
				task_tail = task.index

				element_message(element, .Update)
			}

			case .Update: {
				button.icon = task.folded ? .Simple_Right : .Simple_Down
			}
 		}

		return 0
	}

	res.image_display = image_display_init(res, {}, nil, allocator)
	res.image_display.message_user = proc(element: ^Element, msg: Message, di: int, dp: rawptr) -> int {
		display := cast(^Image_Display) element

		#partial switch msg {
			case .Right_Down: {
				display.img = nil
				display.clip = {}
				display.bounds = {}
				element_repaint(display)
			}

			case .Clicked: {
				mode_panel.image_display.img = display.img
				element_repaint(display)
			}

			case .Get_Cursor: {
				return int(Cursor.Hand)
			}
		}

		return 0
	}

	res.box = task_box_init(res, {}, text, allocator)
	res.box.message_user = task_box_message_custom
	res.search_results = make([dynamic]Search_Result, 0, 8)

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
		inject_at(&parent.children, index_at, res)
	}	

	return
}

// insert a task undoable to a region
task_insert_at :: proc(manager: ^Undo_Manager, index_at: int, res: ^Task) {
	if index_at == -1 || index_at == len(mode_panel.children) {
		item := Undo_Item_Task_Append { res }
		undo_task_append(manager, &item)
	} else {
		item := Undo_Item_Task_Insert_At { index_at, res }
		undo_task_insert_at(manager, &item)
	}	
}

// push line element to panel middle with indentation
task_push_undoable :: proc(
	manager: ^Undo_Manager,
	indentation: int, 
	text := "", 
	index_at := -1,
) -> (res: ^Task) {
	res = task_init(indentation, text)
	task_insert_at(manager, index_at, res)
	return
}

task_box_format_to_lines :: proc(box: ^Task_Box, width: f32) {
	font, size := element_retrieve_font_options(box)
	fontstash.format_to_lines(
		font,
		i16(f32(size) * SCALE),
		strings.to_string(box.builder),
		max(300 * SCALE, width),
		&box.wrapped_lines,
	)
}

// iter through visible children
task_all_children_iter :: proc(
	indentation: int,
	index: ^int,
) -> (res: ^Task, ok: bool) {
	if index^ > len(mode_panel.children) - 1 {
		return
	}

	res = cast(^Task) mode_panel.children[index^]
	ok = indentation <= res.indentation
	index^ += 1
	return
}

// iter through visible children
task_visible_children_iter :: proc(
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
mode_panel_init :: proc(
	parent: ^Element, 
	flags: Element_Flags,
	allocator := context.allocator,
) -> (res: ^Mode_Panel) {
	res = element_init(Mode_Panel, parent, flags, mode_panel_message, allocator)
	res.kanban_outlines = make([dynamic]Rect, 0, 64)
	res.image_display = image_display_init(res, {}, nil, allocator)
	res.image_display.aspect = .Mix
	res.image_display.message_user = proc(element: ^Element, msg: Message, di: int, dp: rawptr) -> int {
		display := cast(^Image_Display) element

		#partial switch msg {
			case .Clicked: {
				display.img = nil
				element_repaint(display)
			}

			case .Get_Cursor: {
				return int(Cursor.Hand)
			}
		}

		return 0
	}

	cam_init(&res.cam[.List], 100, 100)
	cam_init(&res.cam[.Kanban], 100, 100)

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

			for child in task_visible_children_iter(p.indentation, &index) {
				rect := task_rect_indented(child)

				if bound_rect == {} {
					bound_rect = rect
				} else {
					bound_rect = rect_bounding(bound_rect, rect)
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

// set has children, index, and visible parent per each task
task_set_children_info :: proc() {
	// reset
	for child, i in mode_panel.children {
		task := cast(^Task) child
		task.index = i
		task.has_children = false
		task.visible_parent = nil
	}

	// simple check for indentation
	for i := 0; i < len(mode_panel.children) - 1; i += 1 {
		a := cast(^Task) mode_panel.children[i]
		b := cast(^Task) mode_panel.children[i + 1]

		if a.indentation < b.indentation {
			a.has_children = true
		}
	}

	// dumb set visible parent to everything coming after
	// each upcoming has_children will set correctly
	for i in 0..<len(mode_panel.children) {
		a := cast(^Task) mode_panel.children[i]

		if a.has_children {
			for j in i + 1..<len(mode_panel.children) {
				b := cast(^Task) mode_panel.children[j]

				if a.indentation < b.indentation {
					b.visible_parent = a
				} else {
					break
				}
			}
		}
	}
}

// set visible flags on task based on folding
task_set_visible_tasks :: proc() {
	clear(&tasks_visible)
	manager := mode_panel_manager_begin()

	// set visible lines based on fold of parents
	for child in mode_panel.children {
		task := cast(^Task) child
		p := task.visible_parent
		task.visible = true

		// unset folded 
		if !task.has_children && task.folded {
			item := Undo_Item_U8_Set {
				cast(^u8) (&task.folded),
				0,
			}

			// continue last undo because this happens manually
			undo_group_continue(manager)
			undo_u8_set(manager, &item)
			undo_group_end(manager)
		}

		// recurse up 
		for p != nil {
			if p.folded {
				task.visible = false
			}

			p = p.visible_parent
		}
		
		// just update icon & hide each
		if task.visible {
			element_message(task.button_fold, .Update)
			element_hide(task.button_fold, !task.has_children)
			task.visible_index = len(tasks_visible)
			append(&tasks_visible, task)
		}
	}
}

// automatically set task state of parents based on children counts
// manager = nil will not push changes to undo
task_check_parent_states :: proc(manager: ^Undo_Manager) {
	// reset all counts
	for i in 0..<len(mode_panel.children) {
		task := cast(^Task) mode_panel.children[i]
		if task.has_children {
			task.state_count = {}
		}
	}

	changed_any: bool

	// count up states
	for i := len(mode_panel.children) - 1; i >= 0; i -= 1 {
		task := cast(^Task) mode_panel.children[i]

		// when has children - set state based on counted result
		if task.has_children {
			if task.state_count[.Normal] == 0 {
				goal: Task_State = task.state_count[.Done] >= task.state_count[.Canceled] ? .Done : .Canceled
				
				if task.state != goal {
					task_set_state_undoable(manager, task, goal)
					changed_any = true
				}
			} else if task.state != .Normal {
				task_set_state_undoable(manager, task, .Normal)
				changed_any = true
			}
		}

		// count parent up based on this state		
		if task.visible_parent != nil {
			task.visible_parent.state_count[task.state] += 1
		}
	}	

	// log.info("CHECK", changed_any)
}

task_children_range :: proc(parent: ^Task) -> (low, high: int) {
	low = -1
	high = -1

	for i in parent.index + 1..<len(mode_panel.children) {
		task := cast(^Task) mode_panel.children[i]

		if task.indentation == parent.indentation + 1 {
			if low == -1 {
				low = i
			}

			high = i
		} else if task.indentation < parent.indentation {
			break
		}
	}

	return
}

task_gather_children_strict :: proc(
	parent: ^Task, 
	allocator := context.temp_allocator,
) -> (res: [dynamic]^Task) {
	res = make([dynamic]^Task, 0, 32)

	for i in parent.index + 1..<len(mode_panel.children) {
		task := cast(^Task) mode_panel.children[i]

		if task.indentation == parent.indentation + 1 {
			append(&res, task)
		} else if task.indentation < parent.indentation {
			break
		}
	}

	return
}

//////////////////////////////////////////////
// messages
//////////////////////////////////////////////

mode_panel_message :: proc(element: ^Element, msg: Message, di: int, dp: rawptr) -> int {
	panel := cast(^Mode_Panel) element
	cam := &panel.cam[panel.mode]

	#partial switch msg {
		case .Find_By_Point_Recursive: {
			p := cast(^Find_By_Point) dp

			if image_display_has_content(panel.image_display) {
				child := panel.image_display

				if (.Hide not_in child.flags) && rect_contains(child.bounds, p.x, p.y) {
					p.res = child
					return 1
				}
			}

			for i := len(element.children) - 1; i >= 0; i -= 1 {
				task := cast(^Task) element.children[i]

				if !task.visible {
					continue
				}

				if element_message(task, .Find_By_Point_Recursive, 0, dp) == 1 {
					return 1
				}
			}

			return 1
		}

		// NOTE custom layout based on mode
		case .Layout: {
			// element.bounds = window_rect(window)
			// element.clip = element.bounds
			
			bounds := element.bounds

			if image_display_has_content(panel.image_display) {
				rect := rect_margin(panel.bounds, 20 * SCALE)
				element_move(panel.image_display, rect)
			}

			bounds.l += cam.offset_x
			bounds.t += cam.offset_y
			gap_vertical_scaled := math.round(panel.gap_vertical * SCALE)

			switch panel.mode {
				case .List: {
					cut := bounds
					cut.b = 100_000

					for child in element.children {
						task := cast(^Task) child
						
						if !task.visible {
							continue
						}

						// format before taking height
						tab_size := f32(task.indentation) * options_tab() * TAB_WIDTH * SCALE
						fold_size := task.has_children ? math.round(DEFAULT_FONT_SIZE * SCALE) : 0
						width_limit := rect_width(element.bounds) - tab_size - fold_size
						width_limit -= cam.offset_x
						
						// disable wrap limit
						if !options_wrapping() {
							width_limit = max(f32)
						}

						task_box_format_to_lines(task.box, width_limit)
						h := element_message(task, .Get_Height)
						r := rect_cut_top_hard(&cut, f32(h))
						// element_move(task, r)
						task.clip = r
						task.bounds = r
						element_message(task, .Layout)
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
					root: ^Task

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
							// NOTE has to be hard cut because of panning
							kanban_current = rect_cut_left_hard(&cut, kanban_width)
							task.kanban_rect = kanban_current
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
						// TODO maybe need to append this to the last 0 indentation?
					}
				}
			}

			// check on change
			if task_head != -1 {
				mode_panel_cam_bounds_check_x(false)
				mode_panel_cam_bounds_check_y()
			}
		}

		case .Paint_Recursive: {
			target := element.window.target 

			bounds := element.bounds
			render_rect(target, bounds, theme.background[0], 0)
			bounds.l -= cam.offset_x
			bounds.t -= cam.offset_y

			search_draw_index = 0

			switch panel.mode {
				case .List: {

				}

				case .Kanban: {
					// draw outlines
					color := theme_panel(.Parent)
					// color := color_blend(mix, BLACK, 0.9, false)
					for outline in panel.kanban_outlines {
						rect := rect_margin(outline, -KANBAN_MARGIN * SCALE)
						// render_rect(target, rect, color, ROUNDNESS)
						render_rect_outline(target, rect, color, ROUNDNESS)
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

				task_head_tail_call_all(target, proc(task: ^Task, data: rawptr) {
					target := cast(^Render_Target) data
					color := theme.caret_highlight
					if task_head != task_tail && task.visible_index == task_head {
						color = theme.caret
					}

					rect := task_rect_indented(task)
					render_rect_outline(target, rect, color)
				})
			}

			// visual line for dragging
			if task_head != -1 && dragging && drag_index_at != -1 {
				render_push_clip(target, panel.clip)
				
				drag_task := tasks_visible[drag_index_at]
				render_underline(target, drag_task.bounds, theme.text_good)
			}

			// highlight selection
			if task_head != -1 && task_head != task_tail {
				render_push_clip(target, panel.clip)
				a := tasks_visible[task_head]
				b := tasks_visible[task_tail]
				bounds := rect_bounding(a.bounds, b.bounds)

				rects := rect_cut_out_rect(panel.bounds, bounds)
				color := color_alpha(theme.background[0], 0.5)
				render_rect(target, rects[0], color)
				render_rect(target, rects[1], color)
				render_rect(target, rects[2], color)
				render_rect(target, rects[3], color)
			}

			if image_display_has_content(panel.image_display) {
				element_message(panel.image_display, .Paint_Recursive)
			}

			return 1
		}

		case .Destroy: {
			delete(panel.kanban_outlines)
		}

		case .Right_Down: {
			menu := menu_init(panel, {  })
			menu_add_item(menu, {}, "abc", nil)
			menu_add_item(menu, {}, "def", nil)
			menu_add_item(menu, {}, "ghi", nil)
			menu_add_item(menu, {}, "jkl", nil)
			menu_show(menu)
			return 1
		}

		case .Middle_Down: {
			cam.start_x = cam.offset_x
			cam.start_y = cam.offset_y
		}

		case .Mouse_Drag: {
			mouse := (cast(^Mouse_Coordinates) dp)^

			if element.window.pressed_button == MOUSE_MIDDLE {
				diff_x := element.window.cursor_x - mouse.x
				diff_y := element.window.cursor_y - mouse.y

				cam.offset_x = cam.start_x + diff_x
				cam.offset_y = cam.start_y + diff_y
				cam.freehand = true

				window_set_cursor(element.window, .Crosshair)
				element_repaint(element)
				return 1
			}
		}

		case .Mouse_Scroll_Y: {
			cam.offset_y += f32(di) * 20
			cam.freehand = true
			element_repaint(element)
			return 1
		}

		case .Mouse_Scroll_X: {
			cam.freehand = true
			cam.offset_x += f32(di) * 20
			element_repaint(element)
			return 1
		}

		case .Update: {
			for child in element.children {
				element_message(child, .Update, di, dp)
			}
		}

		case .Left_Down: {
			element_reset_focus(element.window)
		}

		case .Animate: {
			handled := false

			y_handled := cam_animate(cam, false)
			handled |= y_handled

			// check y afterwards
			if y_handled {
				goal_y, direction_y := cam_bounds_check_y(cam, mode_panel.bounds, caret_rect.t, caret_rect.b)

				if cam.ay.direction != CAM_CENTER && direction_y == 0 {
					cam.ay.animating = false
				}
			}

			x_handled := cam_animate(cam, true)
			handled |= x_handled

			// check x afterwards
			if x_handled {
				mode_panel_cam_bounds_check_x(true)
			}

			// if !handled {
			// 	log.info("-----------------------")
			// }

			// log.info("animating!", handled, cam.offset_y, cam.animation_y_goal, cam.animation_y_direction)
			return int(handled)
		}
	}

	return 0
}

task_box_message_custom :: proc(element: ^Element, msg: Message, di: int, dp: rawptr) -> int {
	box := cast(^Task_Box) element
	task := cast(^Task) element.parent

	// x offset of the task box
	x_offset :: proc(task: ^Task, box: ^Task_Box) -> (res: f32) {
		res += TASK_TEXT_OFFSET

		if task.bookmarked {
			res += math.round(TASK_BOOKMARK_WIDTH * SCALE)
		}
		
		if task.has_children {
			res += math.round(DEFAULT_FONT_SIZE * SCALE)
		}

		return
	}

	#partial switch msg {
		case .Box_Text_Color: {
			color := cast(^Color) dp
			color^ = theme_task_text(task.state)
			return 1
		}

		case .Layout: {
			if task_head == task_tail && task.visible_index == task_head {
				offset := x_offset(task, box)
				font, size := element_retrieve_font_options(box)
				scaled_size := i16(f32(size) * SCALE)
				x := box.bounds.l + offset
				y := box.bounds.t + math.round(mode_panel.margin_vertical / 2 * SCALE)
				caret_rect = box_layout_caret(box, font, scaled_size * 10, x, y)
			}
		}

		case .Paint_Recursive: {
			target := element.window.target
			draw_search_results := (.Hide not_in panel_search.flags)

			box.bounds.t += math.round(mode_panel.margin_vertical / 2 * SCALE)
			box.bounds.l += x_offset(task, box)
			font, size := element_retrieve_font_options(box)
			scaled_size := i16(f32(size) * SCALE)

			// draw the search results outline
			if draw_search_results && len(task.search_results) != 0 {
				x := box.bounds.l
				y := box.bounds.t

				for res in task.search_results {
					color := search_index == search_draw_index ? theme.text_good : theme.text_bad
					state := wrap_state_init(box.wrapped_lines[:], font, scaled_size)

					for wrap_state_iter(&state, int(res.low), int(res.high)) {
						if state.rect_valid {
							rect := state.rect
							translated := rect_add(rect, rect_xxyy(x, y))
							render_rect_outline(target, translated, color, 0)
						}
					}

					search_draw_index += 1
				}
			}

			if task.state == .Canceled {
				state := wrap_state_init(box.wrapped_lines[:], font, scaled_size)
				font_ascent_scaled := fontstash.ascent_pixel_size(font, f32(scaled_size))
				
				x := box.bounds.l
				y := box.bounds.t
				for wrap_line, i in box.wrapped_lines {
					// TODO could be bad with new centering
					width := fontstash.string_width(font, scaled_size, wrap_line)
					rect := rect_wh(x, y, width, f32(scaled_size))
					render_text_strike_through(target, font_ascent_scaled, rect, theme.text_bad)
					y += f32(scaled_size)
				}
			}

 			// paint selection before text
			if task_head == task_tail && task.visible_index == task_head {
				x := box.bounds.l
				y := box.bounds.t
				low, high := box_low_and_high(box)
				box_render_selection(target, box, font, scaled_size, x, y, theme.caret_selection)
			}

			task_box_paint_default(box)

			// outline visible selected one
			if task_head == task_tail && task.visible_index == task_head {
				render_rect(target, caret_rect, theme.caret, 0)
			}

			return 1
		}

		case .Left_Down: {
			// set line to the head
			if task_head != task.visible_index {
				element_hide(panel_goto, true)

				task_head_tail_check_begin()
				task_head = task.visible_index
				task_head_tail_check_end()
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

		case .Right_Up: {
			if dragging {
				dragging = false
				element_hide(drag_panel, true)

				// find lowest indentation 
				lowest_indentation := 255
				for i in 0..<len(drag_list) {
					task := drag_list[i]
					lowest_indentation = min(lowest_indentation, task.indentation)
				}

				drag_indentation: int

				if task_head != -1 && drag_index_at != -1 {
					drag_indentation = tasks_visible[drag_index_at].indentation
				}

				manager := mode_panel_manager_scoped()
				task_head_tail_push(manager)

				// paste lines with indentation change saved
				for i in 0..<len(drag_list) {
					t := drag_list[i]
					relative_indentation := drag_indentation + int(t.indentation) - lowest_indentation
					
					item := Undo_Item_Task_Indentation_Set {
						task = t,
						set = t.indentation,
					}	
					undo_push(manager, undo_task_indentation_set, &item, size_of(Undo_Item_Task_Indentation_Set))

					t.indentation = relative_indentation
					t.indentation_smooth = f32(t.indentation)
					task_insert_at(manager, drag_index_at + i + 1, t)
				}

				task_tail = drag_index_at + 1
				task_head = drag_index_at + len(drag_list)

				element_repaint(mode_panel)
			}
		}

		case .Right_Down: {
			if task_head == -1 {
				return 0
			}

			low, high := task_low_and_high()
			selected := low <= task.visible_index && task.visible_index <= high

			// on not task != selection just select this one
			if !selected {
				task_head = task.visible_index
				task_tail = task.visible_index
				low, high = task_low_and_high()
			}

			clear(&drag_list)
			manager := mode_panel_manager_scoped()
			task_head_tail_push(manager)

			// push removal tasks to array before
			for i in low..<high + 1 {
				task := tasks_visible[i]
				append(&drag_list, task)
			}

			task_head_tail_push(manager)
			task_remove_selection(manager, false)

			if low != high {
				task_head = low
				task_tail = low
			}

			{
				b := &drag_label.builder
				strings.builder_reset(b)
				fmt.sbprintf(b, "%dx", len(drag_list))

				dragging = true
				drag_index_at = -1
				element_hide(drag_panel, false)
				element_animation_start(drag_panel)
			}
		}

		case .Value_Changed: {
			dirty_push(&element.window.manager)
			// editor_set_unsaved_changes_title(&element.window.manager)
		}
	}

	return 0
}

task_rect_indented :: proc(task: ^Task) -> (res: Rect) {
	res = task.bounds
	res.l += math.round(task.indentation_smooth * options_tab() * TAB_WIDTH * SCALE)
	return
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
		case .Destroy: {
			delete(task.search_results)
		}

		case .Get_Width: {
			return int(SCALE * 200)
		}

		case .Get_Height: {
			task.font_options = task.has_children ? &font_options_bold : nil
			line_size := efont_size(element) * f32(len(task.box.wrapped_lines))

			line_size_addition := additional_size(task, draw_tags)
			line_size += line_size_addition
			line_size += math.round(mode_panel.margin_vertical * SCALE)
			line_size += image_display_has_content(task.image_display) ? (IMAGE_DISPLAY_HEIGHT * SCALE) : 0

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

			if image_display_has_content(task.image_display) {
				top := rect_cut_top_hard(&cut, IMAGE_DISPLAY_HEIGHT * SCALE)
				element_move(task.image_display, top)
			}

			// fold button
			if task.has_children {
				left := cut
				if task.bookmarked {
					left.l += math.round(TASK_BOOKMARK_WIDTH * SCALE)
				}
				left.r = left.l + math.round(DEFAULT_FONT_SIZE * SCALE)
				scaled_size := i16(f32(task.font_options.size) * SCALE)
				left.b = left.t + f32(scaled_size)
				off := math.round(mode_panel.margin_vertical / 2 * SCALE)
				left.t += off
				left.b += off
				element_move(task.button_fold, left)
			}
			
			task.box.font_options = task.font_options
			element_move(task.box, cut)
		}

		case .Paint_Recursive: {
			target := element.window.target
			rect := task_rect_indented(task)

			// render panel front color
			{
				color := theme_panel(task.has_children ? .Parent : .Front)
				render_rect(target, rect, color, ROUNDNESS)
			}

			if task.bookmarked {
				rect := rect
				rect.r = rect.l + math.round(TASK_BOOKMARK_WIDTH * SCALE)
				color := theme.text_default
				render_rect(target, rect, color, ROUNDNESS)
			}

			// draw tags at an offset
			if draw_tags {
				rect := rect

				if task.bookmarked {
					rect.l += math.round(TASK_BOOKMARK_WIDTH * SCALE)
				}

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
				scaled_size := i16(DEFAULT_FONT_SIZE * SCALE)
				text_margin := math.round(10 * SCALE)
				gap := math.round(TASK_DATA_GAP * SCALE)

				// go through each existing tag, draw each one
				for i in 0..<u8(8) {
					value := u8(1 << i)

					if task.tags & value == value {
						tag := sb.tags.names[i]
						tag_color := theme.tags[i]

						switch tag_mode {
							case TAG_SHOW_TEXT_AND_COLOR: {
								text := strings.to_string(tag^)
								width := fontstash.string_width(font, scaled_size, text)
								r := rect_cut_left_hard(&rect, width + text_margin)

								if rect_valid(r) {
									render_rect(target, r, tag_color, ROUNDNESS)
									render_string_aligned(target, font, text, r, theme_panel(.Front), .Middle, .Middle, scaled_size)
								}
							}

							case TAG_SHOW_COLOR: {
								r := rect_cut_left_hard(&rect, 50 * SCALE)
								if rect_valid(r) {
									render_rect(target, r, tag_color, ROUNDNESS)
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
			element_find_by_point_custom(element, p)
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

//////////////////////////////////////////////
// init calls
//////////////////////////////////////////////

goto_init :: proc(window: ^Window) {
	p := panel_floaty_init(&window.element, {})
	panel_goto = p
	p.panel.background_index = 2
	p.width = 200
	p.height = DEFAULT_FONT_SIZE * SCALE + p.panel.margin * 2
	p.panel.flags |= { .Panel_Expand }

	p.message_user = proc(element: ^Element, msg: Message, di: int, dp: rawptr) -> int {
		floaty := cast(^Panel_Floaty) element

		#partial switch msg {
			case .Animate: {
				handled := animate_to(
					&goto_transition_animating,
					&goto_transition_unit,
					goto_transition_hide ? 1 : 0,
					4,
					0.01,
				)

				if !handled && goto_transition_hide {
					element_hide(floaty, true)
				}

				return int(handled)
			}

			case .Layout: {
				floaty.x = 
					mode_panel.bounds.l + rect_width_halfed(mode_panel.bounds) - floaty.width / 2
				
				off := math.round(10 * SCALE)
				floaty.y = 
					(mode_panel.bounds.t + off) + (goto_transition_unit * -(floaty.height + off))
			}

			case .Key_Combination: {
				combo := (cast(^string) dp)^
				handled := true

				switch combo {
					case "escape": {
						goto_transition_unit = 0
						goto_transition_hide = true
						goto_transition_animating = true
						element_animation_start(floaty)

						// reset to origin 
						task_head = goto_saved_task_head
						task_tail = goto_saved_task_tail
					}

					case "return": {
						goto_transition_unit = 0
						goto_transition_hide = true
						goto_transition_animating = true
						element_animation_start(floaty)
					}

					case: {
						handled = false
					}
				}

				return int(handled)
			}
		}

		return 0
	}

	box := text_box_init(p.panel, {})
	box.codepoint_numbers_only = true
	box.message_user = proc(element: ^Element, msg: Message, di: int, dp: rawptr) -> int {
		box := cast(^Text_Box) element

		#partial switch msg {
			case .Value_Changed: {
				value := strconv.atoi(strings.to_string(box.builder)) - 1
				task_head = value
				task_tail = value
				element_repaint(box)
			}
		}

		return 0
	}

	element_hide(p, true)
}

search_init :: proc(parent: ^Element) {
	MARGIN :: 5
	margin_scaled := math.round(MARGIN * SCALE)
	height := DEFAULT_FONT_SIZE * SCALE + margin_scaled * 2
	p := panel_init(parent, { .Panel_Default_Background, .Panel_Horizontal }, margin_scaled, 5)
	p.background_index = 2
	// p.shadow = true
	p.z_index = 2

	box := text_box_init(p, { .HF })
	box.message_user = proc(element: ^Element, msg: Message, di: int, dp: rawptr) -> int {
		box := cast(^Text_Box) element

		#partial switch msg {
			case .Value_Changed: {
				query := strings.to_string(box.builder)
				search_update_results(query)
			}

			case .Key_Combination: {
				combo := (cast(^string) dp)^
				handled := true

				switch combo {
					case "escape": {
						element_hide(panel_search, true)
						element_repaint(panel_search)
						task_head = search_saved_task_head
						task_tail = search_saved_task_tail
					}

					case "return": {
						element_hide(panel_search, true)
						element_repaint(panel_search)
					}

					// next
					case "f3", "ctrl+n": {
						search_find_next()
					}

					// prev 
					case "shift+f3", "ctrl+shift+n": {
						search_find_prev()
					}

					case: {
						handled = false
					}
				}

				return int(handled)
			}
		}

		return 0
	}

	b1 := button_init(p, {}, "Find Next")
	b1.invoke = proc(data: rawptr) {
		search_find_next()
	}
	b2 := button_init(p, {}, "Find Prev")
	b2.invoke = proc(data: rawptr) {
		search_find_prev()
	}

	panel_search = p
	element_hide(panel_search, true)
}

search_update_results :: proc(query: string) {
	// clear all panel based search results, even hidden
	for i in 0..<len(mode_panel.children) {
		task := cast(^Task) mode_panel.children[i]
		clear(&task.search_results)
	}
	search_index = -1

	// skip empty query
	if query == "" {
		return
	}

	// find results
	for i in 0..<len(tasks_visible) {
		task := tasks_visible[i]
		text := strings.to_string(task.box.builder)
		index: int

		// find results and insert
		for rune_start, rune_end in contains_multiple_iterator(text, query, &index) {
			append(&task.search_results, Search_Result {
				rune_start,
				rune_end,
			})
		}
	}
}

search_find_next :: proc() {
	// fill mixed results
	clear(&search_results_mixed)
	for i in 0..<len(tasks_visible) {
		task := tasks_visible[i]

		if len(task.search_results) != 0 {
			for res in task.search_results {
				append(&search_results_mixed, Search_Result_Mixed {
					task,
					res.low,
					res.high,
				})
			}
		}
	}

	if len(search_results_mixed) == 0 {
		return
	}

	range_advance_index(&search_index, len(search_results_mixed) - 1, false)
	res := search_results_mixed[search_index]
	task_head = res.task.visible_index
	task_tail = res.task.visible_index
	res.task.box.head = int(res.high)
	res.task.box.tail = int(res.low)

	element_repaint(mode_panel)
}

search_find_prev :: proc() {
	// fill mixed results
	clear(&search_results_mixed)
	for i in 0..<len(tasks_visible) {
		task := tasks_visible[i]

		if len(task.search_results) != 0 {
			for res in task.search_results {
				append(&search_results_mixed, Search_Result_Mixed {
					task,
					res.low,
					res.high,
				})
			}
		}
	}

	if len(search_results_mixed) == 0 {
		return
	}

	range_advance_index(&search_index, len(search_results_mixed) - 1, true)
	res := search_results_mixed[search_index]
	task_head = res.task.visible_index
	task_tail = res.task.visible_index
	res.task.box.head = int(res.high)
	res.task.box.tail = int(res.low)

	element_repaint(mode_panel)
}

// iterator approach to finding a subtr
contains_multiple_iterator :: proc(s, substr: string, index: ^int) -> (rune_start, rune_end: u16, ok: bool) {
	for {
		if index^ > len(s) {
			break
		}

		search := s[index^:]
		
		// TODO could maybe be optimized by using cutf8!
		if res := strings.index(search, substr); res >= 0 {
			// NOTE: start & end are in rune offsets!
			start := strings.rune_count(s[:index^ + res])

			ok = true
			rune_start = u16(start)
			rune_end = u16(start + strings.rune_count(substr))

			// index moves by bytes
			index^ += res + len(substr)
			return
		} else {
			break
		}
	}

	ok = false
	return
}

custom_split_message :: proc(element: ^Element, msg: Message, di: int, dp: rawptr) -> int {
	split := cast(^Custom_Split) element

	if msg == .Layout {
		bounds := element.bounds
		log.info("BOUNDS", element.bounds, window_rect(window_main))

		if .Hide not_in panel_search.flags {
			bot := rect_cut_bottom(&bounds, math.round(50 * SCALE))
			element_move(panel_search, bot)
		}

		element_move(mode_panel, bounds)
	}

	return 0  	
}

task_panel_init :: proc(split: ^Split_Pane) -> (element: ^Element) {
	rect := window_rect(split.window)

	custom_split := element_init(Custom_Split, split, {}, custom_split_message, context.allocator,)

	mode_panel = mode_panel_init(custom_split, {}, window_allocator(window_main))
	mode_panel.gap_vertical = 1
	mode_panel.gap_horizontal = 10
	mode_panel.margin_vertical = 10
	search_init(custom_split)
	
	return mode_panel
}

tasks_load_file :: proc() {
	err: io.Error = .Empty

	if last_save_location != "" {
		err = editor_load(last_save_location)
	} 
	
	// on error reset and load default
	if err != nil {
		log.info("TODOOL: Loading failed -> Loading default")
		tasks_load_reset()
		tasks_load_default()
	} else {
		log.info("TODOOL: Loading success")
	}
}

tasks_load_reset :: proc() {
	// NOTE TEMP
	// TODO need to cleanup node data
	clear(&mode_panel.children)
	undo_manager_reset(&mode_panel.window.manager)
	dirty = 0
	dirty_saved = 0
}

tasks_load_default :: proc() {
	task_push(0, "one")
	task_push(1, "two")
	task_push(2, "three")
	task_head = 0
	task_tail = 0
}

tasks_load_tutorial :: proc() {
	@static load_indent := 0

	@(deferred_none=pop)
	push_scoped_task :: #force_inline proc(text: string) {
		task_push(max(load_indent, 0), text)
		load_indent	+= 1
	}

	push_scoped :: #force_inline proc(text: string) {
		load_indent	+= 1
	}

	pop :: #force_inline proc() {
	  load_indent -= 1
	}

	t :: #force_inline proc(text: string) {
		task_push(max(load_indent, 0), text)
	}

	push_scoped_task("Tutorial")

	{
		push_scoped_task("Tutorial")
		t("thank you for alpha testing todool")
		t("if you have any issues, please post them on the discord")
		t("tutorial shortcut explanations are based on default key bindings")
	}

	{
		push_scoped_task("Task Keyboard Movement")

		t("up / down -> move to upper / lower task")
		t("ctrl+up / ctrl+down -> move to same upper/ lower task with the same indentation")
		t("ctrl+m -> moves to the last task in scope, then shuffles between the start of the scope")
		t("ctrl+, / ctrl+. -> moves to the previous / next task at indentation 0")
		t("shift + movement -> shift select till the new destination")
		t("alt+up / alt+down -> shift the selected tasks up / down")
	}

	{
		push_scoped_task("Text Box Keyboard Movement")
		t("same as normal text editors")
		t("up / down are used for task based movement")
		t("copying text switches to text paste mode")
	}

	{
		push_scoped_task("Task Addition / Deletion")
		t("return -> insert a new task at the same indentation as the current task")
		t("ctrl+return -> insert a a task as a child with indentation + 1")
		t("backspace -> removes the task when it has no text")
		t("ctrl+d -> removes the selected tasks")
	}

	{
		push_scoped_task("Bookmarks")
		t("ctrl+b -> toggle the current selected tasks bookmark flag")
		t("ctrl+shift+tab -> cycle jump through the previous bookmark")
		t("ctrl+tab -> cycle jump through the next bookmark")
	}

	{
		push_scoped_task("Text Manipulation")
		t("ctrl+shift+j -> uppercase the starting words of the selected tasks")
		t("ctrl+shift+l -> lowercase all letters of the selected tasks")
	}

	{
		push_scoped_task("Task Properties")
		t("tab -> increase the selected tasks indentation")
		t("shift+tab -> decrease the selected tasks indentation")
		t("ctrl+q -> cycle through the selected tasks state")
		t("ctrl+j -> toggle the current task folding level")
	}

	{
		push_scoped_task("Tags")
		t("ctrl+(1-8) -> toggle the selected tasks tag (1-8)")
		t("ctrl+(1-8) -> toggle the selected tasks tag (1-8)")
		t("ctrl+(1-8) -> toggle the selected tasks tag (1-8)")
	}

	{
		push_scoped_task("Task & Text | Copy & Paste")
		t("ctrl+c -> copy the selected tasks - when no text is selected")
		t("ctrl+x -> cut the selected tasks - when no text is selected")
		t("ctrl+shift+c -> copy the selected tasks to the clipboard with basic indentation")
		t("ctrl+v -> paste the previously copied tasks relative to the current position")
		t("ctrl+shift+v -> paste text from the clipboard based on newlines - text is left/right trimmed")
	}

	{
		push_scoped_task("Pomodoro")
		t("alt+1 -> toggle the pomodoro work time")
		t("alt+2 -> toggle the pomodoro short break time")
		t("alt+3 -> toggle the pomodoro long break time")
	}

	{
		push_scoped_task("Modes")
		t("alt+q -> enter the List mode")
		t("alt+w -> enter the Kanban mode")
		t("alt+e -> TEMP spawn the theme editor")
	}

	{
		push_scoped_task("Miscellaneous")
		t("ctrl+s -> save to a file")
		t("ctrl+o -> load from a file")
		t("ctrl+n -> new file")
		t("ctrl+z -> undo")
		t("ctrl+y -> redo")
		t("ctrl+e -> center the view vertically")
	}

	task_head = 0
	task_tail = 0

	// TODO add ctrl+shift+return to insert at prev
}
