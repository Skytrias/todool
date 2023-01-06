package src

import "core:os"
import "core:runtime"
import "core:c/libc"
import "core:io"
import "core:mem"
import "core:strconv"
import "core:fmt"
import "core:unicode"
import "core:strings"
import "core:log"
import "core:math"
import "core:math/ease"
import "core:intrinsics"
import "core:slice"
import "core:reflect"
import "core:time"
import "core:thread"
import "../cutf8"
import "heimdall:fontstash"
import "../spall"

Task_State_Progression :: enum {
	Idle,
	Update_Instant,
	Update_Animated,
}

Vim_State :: struct {
	insert_mode: bool,
	
	// return to same task if still waiting for move break
	// left /right
	rep_task: ^Task,
	rep_direction: int, // direction -1 = left, 1 = right
	rep_cam_x: f32,
	rep_cam_y: f32,
}
vim: Vim_State

TAB_WIDTH :: 200
TASK_DRAG_SIZE :: 80
TASK_SHADOW_ALPHA :: 0.5
DRAG_CIRCLE :: 30
SEPARATOR_SIZE :: 20

Caret_State :: struct {
	rect: RectI,

	lerp_speed_y: f32,
	lerp_speed_x: f32,

	// last frames to render
	motion_last_x: f32,
	motion_last_y: f32,
	motion_count: int,
	motion_skip: bool,
	motion_last_frame: bool,

	// outline follow
	outline_current: RectF,
	outline_goal: RectF,

	alpha_forwards: bool,
	alpha: f32,
}

App :: struct {
	pool: Task_Pool,
	copy_state: Copy_State,
	last_was_task_copy: bool,
	caret: Caret_State,

	// progress bars
	task_state_progression: Task_State_Progression,
	progressbars_alpha: f32, // animation
	main_thread_running: bool,

	// keymap special
	keymap_vim_normal: Keymap,
	keymap_vim_insert: Keymap,

	// last save
	last_save_location: strings.Builder,
	um_task: Undo_Manager,
	um_search: Undo_Manager,
	um_goto: Undo_Manager,
	um_sidebar_tags: Undo_Manager,

	// ui state
	task_menu_bar: ^Menu_Bar,
	panel_info: ^Panel,
	mmpp: ^Mode_Panel,
	custom_split: ^Custom_Split,
	window_main: ^Window,

	// goto state
	panel_goto: ^Panel_Floaty,
	goto_saved_task_head: int,
	goto_saved_task_tail: int,
	goto_transition_animating: bool,
	goto_transition_unit: f32,
	goto_transition_hide: bool,

	// font options used
	font_options_header: Font_Options,
	font_options_bold: Font_Options,

	// works in visible line space!
	// gets used in key combs
	task_head: int,
	task_tail: int,
	old_task_head: int,
	old_task_tail: int,
	keep_task_position: Maybe(^Task),

	// shadowing
	task_shadow_alpha: f32,

	// drag state
	drag_list: [dynamic]^Task,
	drag_running: bool,
	drag_index_at: int,
	drag_goals: [3][2]f32,
	drag_rect_lerp: RectF,
	drag_circle: bool,
	drag_circle_pos: [2]int,

	// dirty file
	dirty: int,
	dirty_saved: int,

	// line numbering
	builder_line_number: strings.Builder,

	// global storage instead of per task/box
	rendered_glyphs: [dynamic]Rendered_Glyph,
	rendered_glyphs_start: int,
	wrapped_lines: [dynamic]string,

	// pattern loading options
	pattern_load_pattern: strings.Builder,

	// saving state
	save_callback: proc(),
	save_string: string,

	// focus
	focus: struct {
		root: ^Task, // hard set ptr
		start, end: int, // latest bounds
		alpha: f32,
	},
}
app: ^App

app_init :: proc() -> (res: ^App) {
	res = new(App)

	res.caret.motion_count = 50
	res.caret.outline_goal = RECT_LERP_INIT

	res.pool = task_pool_init()

	res.task_state_progression = .Update_Instant
	res.copy_state = copy_state_init(mem.Kilobyte * 4, 128, context.allocator)
	res.main_thread_running = true
	res.caret.lerp_speed_y = 1
	res.caret.lerp_speed_x = 1
	res.drag_rect_lerp = RECT_LERP_INIT
	
	strings.builder_init(&res.last_save_location, 0, 128)

	keymap_init(&res.keymap_vim_normal, 64, 256)
	keymap_init(&res.keymap_vim_insert, 32, 32)

	power_mode_init()
	bookmark_state_init()

	undo_manager_init(&res.um_task)
	undo_manager_init(&res.um_search)
	undo_manager_init(&res.um_goto)
	undo_manager_init(&res.um_sidebar_tags)

	search_state_init()

	res.font_options_header = {
		font = font_bold,
		size = 30,
	}
	res.font_options_bold = {
		font = font_bold,
		size = DEFAULT_FONT_SIZE + 5,
	}

	res.drag_list = make([dynamic]^Task, 0, 64)

	pomodoro_init()
	spell_check_init()

	strings.builder_init(&res.builder_line_number, 0, 32)

	res.rendered_glyphs = make([dynamic]Rendered_Glyph, 0, 1028 * 2)
	res.wrapped_lines = make([dynamic]string, 0, 1028)

	strings.builder_init(&res.pattern_load_pattern, 0, 128)
	strings.write_string(&res.pattern_load_pattern, "// TODO(.+)")

	return
}

app_destroy :: proc(a: ^App) {
	keymap_destroy(&a.keymap_vim_normal)
	keymap_destroy(&a.keymap_vim_insert)

	power_mode_destroy()
	pomodoro_destroy()
	search_state_destroy()
	bookmark_state_destroy()
	// delete(a.tasks_visible)
	delete(a.drag_list)

	undo_manager_destroy(&a.um_task)
	undo_manager_destroy(&a.um_search)
	undo_manager_destroy(&a.um_goto)
	undo_manager_destroy(&a.um_sidebar_tags)

	spell_check_destroy()

	delete(a.builder_line_number.buf)
	delete(a.rendered_glyphs)
	delete(a.wrapped_lines)

	delete(a.last_save_location.buf)
	copy_state_destroy(a.copy_state)

	task_pool_destroy(&a.pool)

	delete(a.pattern_load_pattern.buf)

	free(a)
}

// helper call to get a task
app_task_list :: proc(list_index: int, loc := #caller_location) -> ^Task #no_bounds_check {
	runtime.bounds_check_error_loc(loc, list_index, len(app.pool.list))
	return &app.pool.list[list_index]
}

app_task_filter :: proc(filter_index: int, loc := #caller_location) -> ^Task #no_bounds_check {
	runtime.bounds_check_error_loc(loc, filter_index, len(app.pool.filter))
	list_index := app.pool.filter[filter_index]
	runtime.bounds_check_error_loc(loc, list_index, len(app.pool.list))
	return &app.pool.list[list_index]
}

app_task_head :: #force_inline proc() -> ^Task {
	return app_task_filter(app.task_head)
}

app_task_tail :: #force_inline proc() -> ^Task {
	return app_task_filter(app.task_tail)
}

app_filter_not_empty :: #force_inline proc() -> bool {
	return len(app.pool.filter) != 0
}

app_filter_empty :: #force_inline proc() -> bool {
	return len(app.pool.filter) == 0
}

// simple split from mode_panel to search bar
Custom_Split :: struct {
	using element: Element,
	
	image_display: ^Image_Display, // fullscreen display
	vscrollbar: ^Scrollbar,
	hscrollbar: ^Scrollbar,
}

// simply write task text with indentation into a builder
task_write_text_indentation :: proc(b: ^strings.Builder, task: ^Task, indentation: int) {
	for i in 0..<indentation {
		strings.write_byte(b, '\t')
	}

	strings.write_string(b, ss_string(&task.box.ss))
	strings.write_byte(b, '\n')
}

task_head_tail_call_all :: proc(
	data: rawptr,
	call: proc(task: ^Task, data: rawptr), 
) {
	// empty
	if app.task_head == -1 {
		return
	}

	low, high := task_low_and_high()
	for i in low..<high + 1 {
		task := app_task_filter(i)
		call(task, data)
	}
}

// just clamp for safety here instead of everywhere
task_head_tail_clamp :: proc() {
	app.task_head = clamp(app.task_head, 0, len(app.pool.filter) - 1)
	app.task_tail = clamp(app.task_tail, 0, len(app.pool.filter) - 1)
}

task_head_tail_call :: proc(
	data: rawptr,
	call: proc(task: ^Task, data: rawptr), 
) {
	// empty
	if app.task_head == -1 || app.task_head == app.task_tail {
		return
	}

	low, high := task_low_and_high()
	for i in low..<high + 1 {
		task := app_task_filter(i)
		call(task, data)
	}
}

last_save_set :: proc(next: string = "") {
	strings.builder_reset(&app.last_save_location)
	strings.write_string(&app.last_save_location, next)
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

Task_State :: enum u8 {
	Normal,
	Done,
	Canceled,
} 

Task :: struct {
	element: Element,
	
	list_index: int, // NOTE set once
	filter_index: int, // NOTE set in update
	visible_parent: ^Task, // NOTE set in update

	// elements
	box: ^Task_Box,
	button_fold: ^Icon_Button,
	
	// optional elements
	button_bookmark: ^Element,
	button_link: ^Button,
	image_display: ^Image_Display,
	seperator: ^Task_Seperator,
	time_date: ^Time_Date,

	// state
	indentation: int,
	indentation_smooth: f32,
	indentation_animating: bool,
	state: Task_State,
	state_unit: f32,
	state_last: Task_State,
	
	// tags state
	tags: u8,
	tags_rect: [8]RectI,
	tag_hovered: int,

	// top animation
	top_offset: f32, 
	top_old: int,
	top_animation_start: bool,
	top_animating: bool,

	filter_folded: bool, // toggle to freeze children
	filter_children: [dynamic]int, // set every frame except when folded
	state_count: [Task_State]int,
	progress_animation: [Task_State]f32,

	// visible kanban outline - used for bounds check by kanban 
	kanban_rect: RectI,

	// flags
	removed: bool,
	highlight: bool,

	keep_in_frame: bool,
}

Mode :: enum {
	List,
	Kanban,
	// Agenda,
}	

// element to custom layout based on internal mode
Mode_Panel :: struct {
	using element: Element,
	mode: Mode,
	cam: [Mode]Pan_Camera,
	zoom_highlight: f32,
}

// scoped version so you dont forget to call
@(deferred_out=mode_panel_manager_end)
mode_panel_manager_scoped :: #force_inline proc() -> ^Undo_Manager {
	return mode_panel_manager_begin()
}

mode_panel_manager_begin :: #force_inline proc() -> ^Undo_Manager {
	return &app.um_task
}

mode_panel_manager_end :: #force_inline proc(manager: ^Undo_Manager) {
	undo_group_end(manager)
}

mode_panel_zoom_animate :: proc() {
	if app.mmpp != nil {
		app.mmpp.zoom_highlight = 2
		window_animate(app.window_main, &app.mmpp.zoom_highlight, 0, .Quadratic_Out, time.Second)
	} 
	
	power_mode_clear()
}

// line has selection
app_has_selection :: #force_inline proc() -> bool {
	return app.task_head != app.task_tail
}

// no selection
app_has_no_selection :: #force_inline proc() -> bool {
	return app.task_head == app.task_tail
}

// flatten head/tail and keep position the same across changes
task_head_tail_flatten_keep :: proc() -> (task: ^Task) {
	app.task_tail = app.task_head
	task = app_task_head()
	app.keep_task_position = task
	return
}

task_has_children :: #force_inline proc(task: ^Task) -> bool {
	return len(task.filter_children) != 0
}

// low and high from selection
task_low_and_high :: #force_inline proc() -> (low, high: int) {
	low = min(app.task_head, app.task_tail)
	high = max(app.task_head, app.task_tail)
	return
}

// LOW / HIGH iter for simple iteration
LH_Iter :: struct {
	low, high: int,
	range: int,
	index: int,
}

lh_iter_init :: proc() -> (res: LH_Iter) {
	res.low, res.high = task_low_and_high()
	res.range = res.high - res.low + 1
	return
}

lh_iter_step :: proc(iter: ^LH_Iter) -> (task: ^Task, linear_index: int, ok: bool) {
	if iter.index < iter.range {
		linear_index = iter.index
		task = app_task_filter(iter.index + iter.low)
		ok = true
		iter.index += 1
	}

	return
}

// returns index / indentation if possible from head
task_head_safe_index_indentation :: proc(init := -1) -> (index, indentation: int) {
	index = init
	if app.task_head != -1 {
		task := app_task_head()
		index = task.filter_index
		indentation = task.indentation
	}
	return
}

// find lowest indentation in range
tasks_lowest_indentation :: proc(low, high: int) -> (res: int) {
	res = max(int)

	for i in low..<high + 1 {
		res = min(res, app_task_filter(i).indentation)
	}
	
	return
}

task_head_tail_check_begin :: proc(shift: bool) ->  bool {
	if !shift && app.task_head != app.task_tail {
		app.task_tail = app.task_head
		return false
	}

	return true
}

// set line selection to head when no shift
task_head_tail_check_end :: #force_inline proc(shift: bool) {
	if !shift {
		app.task_tail = app.task_head
	}
}

bookmark_message :: proc(element: ^Element, msg: Message, di: int, dp: rawptr) -> int {
	#partial switch msg {
		case .Paint_Recursive: {
			render_rect(element.window.target, element.bounds, theme.text_default, ROUNDNESS)
		}

		case .Get_Cursor: {
			return int(Cursor.Hand)
		}

		case .Clicked: {
			element_hide_toggle(element)
		}
	}

	return 0
}

task_image_display_message :: proc(element: ^Element, msg: Message, di: int, dp: rawptr) -> int {
	display := cast(^Image_Display) element

	#partial switch msg {
		case .Right_Down: {
			display.img = nil
			display.clip = {}
			display.bounds = {}
			element_repaint(display)
			return 1
		}

		case .Clicked: {
			app.custom_split.image_display.img = display.img
			element_repaint(display)
		}

		case .Get_Cursor: {
			return int(Cursor.Hand)
		}
	}

	return 0
}

// set img or init display element
task_set_img :: proc(task: ^Task, handle: ^Stored_Image) {
	if task.image_display == nil {
		task.image_display = image_display_init(&task.element, {}, handle, task_image_display_message, context.allocator)
	} else {
		task.image_display.img = handle
	}
}

task_button_fold_message :: proc(element: ^Element, msg: Message, di: int, dp: rawptr) -> int {
	button := cast(^Icon_Button) element
	task := cast(^Task) button.parent

	#partial switch msg {
		case .Clicked: {
			manager := mode_panel_manager_scoped()
			task_head_tail_push(manager)

			task_toggle_folding(manager, task)
			app.task_head = task.filter_index
			app.task_tail = task.filter_index

			element_repaint(element)
		}

		case .Paint_Recursive: {
			// NOTE only change
			button.icon = task.filter_folded ? .RIGHT_OPEN : .DOWN_OPEN

			pressed := button.window.pressed == button
			hovered := button.window.hovered == button
			target := button.window.target

			text_color := hovered || pressed ? theme.text_default : theme.text_blank

			if element_message(button, .Button_Highlight, 0, &text_color) == 1 {
				rect := button.bounds
				rect.r = rect.l + int(4 * TASK_SCALE)
				render_rect(target, rect, text_color, 0)
			}

			if hovered || pressed {
				render_rect_outline(target, button.bounds, text_color)
				render_hovered_highlight(target, button.bounds)
			}

			fcs_icon(TASK_SCALE)
			fcs_ahv()
			fcs_color(text_color)
			render_icon_rect(target, button.bounds, button.icon)

			return 1
		}

		case .Get_Width: {
			w := icon_width(button.icon, TASK_SCALE)
			return int(w + TEXT_MARGIN_HORIZONTAL * TASK_SCALE)
		}

		case .Get_Height: {
			return task_font_size(element) + int(TEXT_MARGIN_VERTICAL * TASK_SCALE)
		}
	}

	return 0
}

// button with link text
task_button_link_message :: proc(element: ^Element, msg: Message, di: int, dp: rawptr) -> int {
	button := cast(^Button) element

	#partial switch msg {
		case .Left_Up: {
			open_link(strings.to_string(button.builder))
			element_repaint(element)
		}

		case .Right_Up: {
			strings.builder_reset(&button.builder)
			element_repaint(element)
			return 1
		}

		case .Get_Width: {
			fcs_task(element)
			text := strings.to_string(button.builder)
			width := max(int(50 * TASK_SCALE), string_width(text) + int(TEXT_MARGIN_HORIZONTAL * TASK_SCALE))
			return int(width)
		}

		case .Get_Height: {
			return task_font_size(element) + int(TEXT_MARGIN_VERTICAL * TASK_SCALE)
		}

		case .Paint_Recursive: {
			target := element.window.target
			pressed := element.window.pressed == element
			hovered := element.window.hovered == element
			color := theme.text_link

			fcs_color(color)
			fcs_task(button)
			fcs_ahv(.LEFT, .MIDDLE)
			text := strings.to_string(button.builder)
			text_render := text

			// cut of string text
			if app.mmpp.mode == .Kanban {
				task := cast(^Task) element.parent
				actual_width := rect_width(task.element.bounds) - 30
				iter := fontstash.TextIterInit(&gs.fc, 0, 0, text)
				q: fontstash.Quad

				for fontstash.TextIterNext(&gs.fc, &iter, &q) {
					if actual_width < int(iter.x) {
						text_render = fmt.tprintf("%s...", text[:iter.str])
						break
					}
				}
			}

			xadv := render_string_rect(target, element.bounds, text_render)
			if hovered || pressed {
				rect := element.bounds
				rect.r = int(xadv)
				render_underline(target, rect, color)
			}

			return 1
		}
	}

	return 0
}

// set link text or init link button
task_set_link :: proc(task: ^Task, link: string) {
	if task.button_link == nil {
		task.button_link = button_init(&task.element, {}, link, task_button_link_message, context.allocator)
	} else {
		b := &task.button_link.builder
		strings.builder_reset(b)
		strings.write_string(b, link)
	}
}

// valid link 
task_link_is_valid :: proc(task: ^Task) -> bool {
	return task.button_link != nil && (.Hide not_in task.button_link.flags) && len(task.button_link.builder.buf) > 0
}

task_set_time_date :: proc(task: ^Task) {
	if task.time_date == nil {
		task.time_date = time_date_init(&task.element, {}, true)
	} else {
		if .Hide in task.time_date.flags {
			task.time_date.spawn_particles = true
			excl(&task.time_date.flags, Element_Flag.Hide)
		} else {
			if !time_date_update(task.time_date) {
				task.time_date.spawn_particles = true
			} else {
				incl(&task.time_date.flags, Element_Flag.Hide)
			}
		}
	}
}

task_time_date_is_valid :: proc(task: ^Task) -> bool {
	return task.time_date != nil && (.Hide not_in task.time_date.flags)
}

// init bookmark if not yet
task_bookmark_init_check :: proc(task: ^Task) {
	if task.button_bookmark == nil {
		task.button_bookmark = element_init(Element, &task.element, {}, bookmark_message, context.allocator)
	} 
}

// init the bookmark and set hide flag
task_set_bookmark :: proc(task: ^Task, show: bool) {
	task_bookmark_init_check(task)
	element_hide(task.button_bookmark, !show)
}

// check validity
task_bookmark_is_valid :: proc(task: ^Task) -> bool {
	return task.button_bookmark != nil && (.Hide not_in task.button_bookmark.flags)
}

// TODO speedup or cache?
task_total_bounds :: proc() -> (bounds: RectI) {
	bounds = RECT_INF
	for index in app.pool.filter {
		task := app_task_list(index)
		rect_inf_push(&bounds, task.element.bounds)
	}
	return
}

Task_Seperator :: struct {
	using element: Element,
}

task_separator_message :: proc(element: ^Element, msg: Message, di: int, dp: rawptr) -> int {
	sep := cast(^Task_Seperator) element

	#partial switch msg {
		case .Paint_Recursive: {
			target := element.window.target

			rect := element.bounds
			line_width := int(max(2 * TASK_SCALE, 2))
			rect.t += int(rect_heightf_halfed(rect))
			rect.b = rect.t + line_width

			render_rect(target, rect, theme.text_default, ROUNDNESS)
		}

		case .Get_Cursor: {
			return int(Cursor.Hand)
		}

		case .Right_Up, .Left_Up: {
			task := cast(^Task) sep.parent
			task_set_separator(task, false)
			element_repaint(&task.element)
			return 1
		}
	}

	return 0
}

task_set_separator :: proc(task: ^Task, show: bool) {
	if task.seperator == nil {
		task.seperator = element_init(Task_Seperator, &task.element, {}, task_separator_message, context.allocator)
	} 

	element_hide(task.seperator, !show)
}

task_separator_is_valid :: proc(task: ^Task) -> bool {
	return task.seperator != nil && (.Hide not_in task.seperator.flags)
}

// raw creationg of a task
// NOTE: need to set the parent afterward!
task_init :: proc(
	indentation: int,
	text: string,
	check_freed: bool,
) -> (res: ^Task) { 
	res = task_pool_push_new(&app.pool, check_freed)

	allocator := context.allocator
	element := cast(^Element) res
	element.message_class = task_message

	// just assign parent already
	parent := app.mmpp
	element.window = parent.window
	element.parent = parent

	// insert task results
	res.indentation = indentation
	res.indentation_smooth = f32(indentation)

	res.button_fold = icon_button_init(&res.element, {}, .DOWN_OPEN, task_button_fold_message, allocator)
	res.box = task_box_init(&res.element, {}, text, allocator)
	res.box.message_user = task_box_message_custom

	return res
}

// push line element to panel middle with indentation
task_push :: proc(
	indentation: int, 
	text := "", 
	index_at := -1,
) -> (res: ^Task) {
	res = task_init(indentation, text, true)

	if index_at == -1 || index_at >= len(app.pool.filter) {
		append(&app.pool.filter, res.list_index)
	} else {
		inject_at(&app.pool.filter, index_at, res.list_index)
	}	

	return
}

task_insert_at :: proc(manager: ^Undo_Manager, index_at: int, res: ^Task) {
	if index_at == -1 || index_at >= len(app.pool.filter) {
		item := Undo_Item_Task_Append { res.list_index }
		undo_task_append(manager, &item)
	} else {
		item := Undo_Item_Task_Insert_At { index_at, res.list_index }
		undo_task_insert_at(manager, &item)
	}			
}

// push line element to panel middle with indentation
task_push_undoable :: proc(
	manager: ^Undo_Manager,
	indentation: int, 
	text: string, 
	index_at: int,
) -> (res: ^Task) {
	res = task_init(indentation, text, true)
	task_insert_at(manager, index_at, res)
	return
}

// format to lines or append a single line only
task_box_format_to_lines :: proc(box: ^Task_Box, width: int) {
	fcs_task(box)
	fcs_ahv(.LEFT, .TOP)
	wrapped_lines_push(ss_string(&box.ss), max(f32(width), 200), &box.wrapped_lines)
}

// init panel with data
mode_panel_init :: proc(
	parent: ^Element, 
	flags: Element_Flags,
	allocator := context.allocator,
) -> (res: ^Mode_Panel) {
	res = element_init(Mode_Panel, parent, flags, mode_panel_message, allocator)

	cam_init(&res.cam[.List], 25, 50)
	cam_init(&res.cam[.Kanban], 25, 50)

	return
}

mode_panel_draw_verticals :: proc(target: ^Render_Target) {
	if app.task_head < 1 {
		return
	}

	tab := int(visuals_tab() * TAB_WIDTH * TASK_SCALE)
	p := app_task_head()
	color := theme.text_default

	for p != nil && p != app.focus.root {
		if p.visible_parent != nil {
			bound_rect := RECT_INF

			for list_index in p.visible_parent.filter_children {
				task := app_task_list(list_index)
				rect_inf_push(&bound_rect, task.element.bounds)
			}

			bound_rect.l -= tab
			bound_rect.r = bound_rect.l + int(max(2 * TASK_SCALE, 2))
			render_rect(target, bound_rect, color, 0)

			if color.a == 255 {
				color.a = 100
			}

			// stop after focus match
			if p.visible_parent == app.focus.root {
				break
			}
		}

		p = p.visible_parent
	}
}

// set has children, index, and visible parent per each task
task_set_children_info :: proc() {
	// reset data
	for list_index, linear_index in app.pool.filter {
		task := app_task_list(list_index)
		task.filter_index = linear_index
		
		if !task.filter_folded {
			clear(&task.filter_children)
		}

		task.visible_parent = nil
	}

	// insert children, pop previously folded task and move selection automatically
	folded_insert_from_to :: proc(manager: ^Undo_Manager, root: ^Task, from: int) -> (unfolded: bool) {
		for j := from; j < len(app.pool.filter); j += 1 {
			child := app_task_filter(j)

			if root.indentation < child.indentation {
				// new info popped up, unfold this task
				if root.filter_folded && !unfolded {
					unfolded = true
					undo_group_continue(manager)
					task_check_unfold(manager, root)
					app.task_head += len(root.filter_children)
					app.task_tail += len(root.filter_children)
					j -= 1
					continue
				}

				append(&root.filter_children, child.list_index)
				child.visible_parent = root
			} else {
				break
			}
		}

		return
	}

	manager := mode_panel_manager_begin()
	unfolds: bool
	previous: ^Task
	for i in 0..<len(app.pool.filter) {
		task := app_task_filter(i)

		if previous != nil && previous.indentation < task.indentation {
			unfolds |= folded_insert_from_to(manager, previous, i)
		}

		previous = task
	}

	if unfolds {
		undo_group_end(manager)
	}
}

// automatically set task state of parents based on children counts
// manager = nil will not push changes to undo
task_check_parent_states :: proc(manager: ^Undo_Manager) {
	// reset all counts
	for i in 0..<len(app.pool.filter) {
		task := app_task_filter(i)

		if !task.filter_folded && task_has_children(task) {
			task.state_count = {}
			// task.children_count = 0
		}
	}

	changed_any: bool
	undo_pushed: bool

	// count up states
	task_count: int
	for i := len(app.pool.filter) - 1; i >= 0; i -= 1 {
		task := app_task_filter(i)

		// when has children - set state based on counted result
		if !task.filter_folded && task_has_children(task) {
			if task.state_count[.Normal] == 0 {
				goal: Task_State = task.state_count[.Done] >= task.state_count[.Canceled] ? .Done : .Canceled
				
				// set parent
				if task.state != goal {
					if !undo_pushed {
						undo_group_continue(manager)
					}

					undo_pushed = true
					task_set_state_undoable(manager, task, goal, task_count)
					changed_any = true
					task_count += 1

					color: Color = pm_particle_colored() ? {} : theme_task_text(task.state)
					power_mode_spawn_rect(task.element.bounds, 50, color)
				}
			} else if task.state != .Normal {
				if !undo_pushed {
					undo_group_continue(manager)
				}

				undo_pushed = true
				task_set_state_undoable(manager, task, .Normal, task_count)
				task_count += 1
				changed_any = true
			}
		}

		// count parent up based on this state		
		if task.visible_parent != nil {
			task.visible_parent.state_count[task.state] += 1
			// task.visible_parent.children_count += 1
		}
	}	

	if undo_pushed {
		undo_group_end(manager)
	}
}

// find same indentation with optional lower barier
find_same_indentation_backwards :: proc(visible_index: int, allow_lower: bool) -> (res: int) {
	res = -1
	task_current := app_task_filter(visible_index)

	for i := visible_index - 1; i >= 0; i -= 1 {
		task := app_task_filter(i)
		
		if task.indentation == task_current.indentation {
			res = i
			return
		} else if task.indentation < task_current.indentation {
			if !allow_lower {
				return
			}
		}
	}

	return
}

// find same indentation with optional lower barier
find_same_indentation_forwards :: proc(visible_index: int, allow_lower: bool) -> (res: int) {
	res = -1
	task_current := app_task_filter(visible_index)

	for i := visible_index + 1; i < len(app.pool.filter); i += 1 {
		task := app_task_filter(i)
		
		if task.indentation == task_current.indentation {
			res = i
			return
		} else if task.indentation < task_current.indentation {
			if !allow_lower {
				return
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
	cam := &panel.cam[panel.mode]

	#partial switch msg {
		case .Find_By_Point_Recursive: {
			p := cast(^Find_By_Point) dp

			if image_display_has_content_now(app.custom_split.image_display) {
				child := app.custom_split.image_display

				if (.Hide not_in child.flags) && rect_contains(child.bounds, p.x, p.y) {
					p.res = child
					return 1
				}
			}

			list := app_focus_list()
			for i := len(list) - 1; i >= 0; i -= 1 {
				task := app_task_list(list[i])

				if element_message(&task.element, .Find_By_Point_Recursive, 0, dp) == 1 {
					return 1
				}
			}

			return 1
		}

		// NOTE custom layout based on mode
		case .Layout: {
			bounds := element.bounds

			cam_update_screenshake(cam, power_mode_running())
			camx, camy := cam_offsets(cam)
			bounds.l += int(camx)
			bounds.r += int(camx)
			bounds.t += int(camy)
			bounds.b += int(camy)
			gap_vertical_scaled := int(visuals_gap_vertical() * TASK_SCALE)
			gap_horizontal_scaled := int(visuals_gap_horizontal() * TASK_SCALE)
			kanban_width_scaled := int(visuals_kanban_width() * TASK_SCALE)
			tab_scaled := int(visuals_tab() * TAB_WIDTH * TASK_SCALE)
			task_min_width := int(max(300, (rect_widthf(panel.bounds) - 50) * TASK_SCALE))
			margin_scaled := int(visuals_task_margin() * TASK_SCALE)
			// fmt.eprintln("GAPS", gap_vertical_scaled)

			switch panel.mode {
				case .List: {
					cut := bounds

					for list_index in app.pool.filter {
						task := app_task_list(list_index)

						pseudo_rect := cut
						pseudo_rect.l += int(task.indentation) * tab_scaled
						pseudo_rect.r = pseudo_rect.l + task_min_width
						box_rect := task_layout(task, pseudo_rect, false, tab_scaled, margin_scaled)
						task_box_format_to_lines(task.box, rect_width(box_rect))

						h := element_message(&task.element, .Get_Height)
						r := rect_cut_top(&cut, h)
						r.l = r.l + int(task.indentation_smooth * f32(tab_scaled))
						r.r = r.l + task_min_width

						old := task.element.bounds
						element_move(&task.element, r)

						if task.keep_in_frame {
							difft := old.t - task.element.bounds.t
							diffb := old.b - task.element.bounds.b
							fmt.eprintln("DIFF", difft, diffb)
							task.keep_in_frame = false
						}

						cut.t += gap_vertical_scaled
					}
				}

				case .Kanban: {
					cut := bounds

					// cutoff a rect left
					kanban_current: RectI
					kanban_children_count: int
					kanban_children_start: int
					root: ^Task

					for list_index, linear_index in app.pool.filter {
						task := app_task_list(list_index)
						
						if task.indentation == 0 {
							// get max indentations till same line is found
							max_indentations: int
							kanban_children_start = linear_index
							kanban_children_count = 1

							for j in linear_index + 1..<len(app.pool.filter) {
								other := app_task_filter(j)
								max_indentations = max(max_indentations, other.indentation)
								
								if other.indentation == 0 {
									break
								} else {
									kanban_children_count += 1
								}
							}

							kanban_width := kanban_width_scaled
							// TODO check this
							kanban_width += int(f32(max_indentations) * visuals_tab() * TAB_WIDTH * TASK_SCALE)
							kanban_current = rect_cut_left(&cut, kanban_width)
							task.kanban_rect = kanban_current
							cut.l += gap_horizontal_scaled
						}

						// pseudo layout for correct witdth
						pseudo_rect := kanban_current
						box_rect := task_layout(task, pseudo_rect, false, tab_scaled, margin_scaled)
						box_rect.l += int(f32(task.indentation) * visuals_tab() * TAB_WIDTH * TASK_SCALE)
						task_box_format_to_lines(task.box, rect_width(box_rect))

						h := element_message(&task.element, .Get_Height)
						r := rect_cut_top(&kanban_current, h)
						r.l += int(task.indentation_smooth * f32(tab_scaled))
						element_move(&task.element, r)

						if linear_index - kanban_children_start < kanban_children_count - 1 {
							kanban_current.t += gap_vertical_scaled
						}
					}
				}
			}

			// update caret
			if app.task_head != -1 {
				task := app_task_head()
				scaled_size := fcs_task(&task.element)
				x := task.box.bounds.l
				y := task.box.bounds.t
				app.caret.rect = box_layout_caret(task.box, scaled_size, TASK_SCALE, x, y,)
				power_mode_check_spawn()
			}

			// check on change
			if app.task_head != -1 {
				mode_panel_cam_bounds_check_x(cam, app.caret.rect.r, app.caret.rect.r, false, true)
				mode_panel_cam_bounds_check_y(cam, app.caret.rect.t, app.caret.rect.b, true)
			}
		}

		case .Paint_Recursive: {
			target := element.window.target 

			bounds := element.bounds
			render_rect(target, bounds, theme.background[0], 0)

			if app.task_head == -1 {
				fcs_ahv()
				fcs_font(font_regular)
				fcs_color(theme.text_default)
				render_string_rect(target, panel.bounds, "press \"return\" to insert a new task")
				// return 0
			}

			camx, camy := cam_offsets(cam)
			bounds.l -= int(camx)
			bounds.r -= int(camx)
			bounds.t -= int(camy)
			bounds.b -= int(camy)

			mode_panel_draw_verticals(target)

			// custom draw loop!
			// if app.focus.root == nil {
			// 	for list_index in app.pool.filter {
			// 		task := app_task_list(list_index)
			// 		render_element_clipped(target, &task.element)
			// 	}
			// } else {
				// list := app_focus_list()
			
			alpha_animate := app_focus_alpha_animate()
			if alpha_animate != 0 {
				start := app.pool.filter[:app.focus.start]
				shadow_color := color_alpha(theme.background[0], clamp(app.focus.alpha, 0, 1))

				// inside focus
				for list_index in start {
					task := app_task_list(list_index)
					render_element_clipped(target, &task.element)

					render_push_clip(target, task.element.clip)
					render_rect(target, task.element.bounds, shadow_color)
				}

				// NOTE! hard set
				list := app.pool.filter[app.focus.start:app.focus.end]

				// inside focus
				for list_index in list {
					task := app_task_list(list_index)
					render_element_clipped(target, &task.element)
				}

				end := app.pool.filter[app.focus.end:]

				// inside focus
				for list_index in end {
					task := app_task_list(list_index)
					render_element_clipped(target, &task.element)

					render_push_clip(target, task.element.clip)
					render_rect(target, task.element.bounds, shadow_color)
				}
			} else {
				list := app_focus_list()

				// inside focus
				for list_index in list {
					task := app_task_list(list_index)
					render_element_clipped(target, &task.element)
				}
			}

			render_caret_and_outlines(target, panel.clip)
			search_draw_highlights(target, panel)

			// word error highlight
			when !PRESENTATION_MODE {
				if options_spell_checking() && app.task_head != -1 && app.task_head == app.task_tail {
					render_push_clip(target, panel.clip)
					task := app_task_head() 
					spell_check_render_missing_words(target, task)
				}
			}

			when !PRESENTATION_MODE {
				task_render_progressbars(target)
			}

			// drag visualizing circle
			if !app.drag_running && app.drag_circle {
				render_push_clip(target, panel.clip)
				circle_size := DRAG_CIRCLE * TASK_SCALE
				x := f32(app.drag_circle_pos.x)
				y := f32(app.drag_circle_pos.y)
				render_circle_outline(target, x, y, circle_size, 2, theme.text_default, true)
				diff_x := abs(app.drag_circle_pos.x - element.window.cursor_x)
				diff_y := abs(app.drag_circle_pos.y - element.window.cursor_y)
				diff := max(diff_x, diff_y)
				render_circle(target, x, y, f32(diff), theme.text_bad, true)
			}

			// drag visualizer line
			if app.task_head != -1 && app.drag_running && app.drag_index_at != -1 {
				render_push_clip(target, panel.clip)
				
				drag_task := app_task_filter(app.drag_index_at)
				bounds := drag_task.element.bounds
				margin := int(4 * TASK_SCALE)
				bounds.t = bounds.b - margin
				rect_lerp(&app.drag_rect_lerp, bounds, 0.5)
				bounds = rect_ftoi(app.drag_rect_lerp)

				// inner
				{
					b := bounds
					b.t += margin / 2
					b.b += margin / 2
					render_rect(target, b, theme.text_default, ROUNDNESS)
				}

				bounds.b += margin
				bounds.l -= margin / 2
				bounds.r += margin / 2
				render_rect(target, bounds, color_alpha(theme.text_default, .5), ROUNDNESS)
			}

			// render dragged tasks
			if app.drag_running {
				render_push_clip(target, panel.clip)

				// NOTE also have to change init positioning call :)
				width := int(TASK_DRAG_SIZE * TASK_SCALE)
				height := int(TASK_DRAG_SIZE * TASK_SCALE)
				x := element.window.cursor_x - int(f32(width) / 2)
				y := element.window.cursor_y - int(f32(height) / 2)

				for i := len(app.drag_goals) - 1; i >= 0; i -= 1 {
					pos := &app.drag_goals[i]
					goal_x := x + int(f32(i) * 5 * TASK_SCALE)
					goal_y := y + int(f32(i) * 5 * TASK_SCALE)
					animate_to(&pos.x, f32(goal_x), 1 - f32(i) * 0.1)
					animate_to(&pos.y, f32(goal_y), 1 - f32(i) * 0.1)
					r := rect_wh(int(pos.x), int(pos.y), width, height)
					render_texture_from_kind(target, .Drag, r, theme_panel(.Front))
				}
			}

			if power_mode_running() {
				render_push_clip(target, panel.clip)
				power_mode_update()
				power_mode_render(target)
			}

			bookmarks_render_connections(target, panel.clip)
			render_line_highlights(target, panel.clip)
			render_zoom_highlight(target, panel.clip)
			time_date_render_highlight_on_pressed(target, panel.clip)

			// draw the fullscreen image on top
			if image_display_has_content_now(app.custom_split.image_display) {
				render_push_clip(target, panel.clip)
				element_message(app.custom_split.image_display, .Paint_Recursive)
			}

			return 1
		}

		case .Middle_Down: {
			cam.start_x = int(cam.offset_x)
			cam.start_y = int(cam.offset_y)
		}

		case .Mouse_Drag: {
			mouse := (cast(^Mouse_Coordinates) dp)^

			if element.window.pressed_button == MOUSE_MIDDLE {
				diff_x := element.window.cursor_x - mouse.x
				diff_y := element.window.cursor_y - mouse.y

				cam_set_x(cam, cam.start_x + diff_x)
				cam_set_y(cam, cam.start_y + diff_y)
				mode_panel_cam_freehand_on(cam)

				window_set_cursor(element.window, .Crosshair)
				element_repaint(element)
				return 1
			}
		}

		case .Right_Up: {
			app.drag_circle = false
			
			if app.task_head == -1 {
				if task_dragging_end() {
					return 1
				}
			}

			if app.task_head != app.task_tail && app.task_head != -1 {
				task_context_menu_spawn(nil)
				return 1
			}

			mode_panel_context_menu_spawn()
			return 1
		}

		case .Left_Up: {
			if element_hide(panel_search, true) {
				return 1
			}

			if app.task_head != app.task_tail {
				app.task_tail = app.task_head
				return 1
			}
		}

		case .Mouse_Scroll_Y: {
			if element.window.ctrl {

				inc := f32(di) * 0.01
				scaling_set(SCALE, TASK_SCALE + inc)

				task := app_task_head()
				task.keep_in_frame = true

				// old_scale := TASK_SCALE
				// old_off := cam.offset_y
				// cam.freehand = true

				// task := app_task_head()
				// height_before := element_message(&task.element, .Get_Height)

				// inc := f32(di) * 0.01
				// scaling_set(SCALE, TASK_SCALE + inc)
				// fmt.eprintln("SCALING", TASK_SCALE)
				
				// if old_scale != TASK_SCALE {
				// 	my := f32(element.window.cursor_y) - f32(element.bounds.t)
					
				// 	height_after := element_message(&task.element, .Get_Height)
				// 	height_diff := (height_after - height_before)

				// 	fmt.eprintln("height diff", height_diff, height_before, height_after)

				// 	// height_off := f32(task.filter_index) * height_diff * 0.95
				// 	height_off := (task.filter_index) * height_diff
				// 	fmt.eprintln("\theight off", height_off)
				// 	cam.offset_y -= f32(height_off)

				// 	// off := old_scale * TASK_SCALE / DEFAULT_FONT_SIZE
				// 	// cam.offset_y += off
				// 	// diff := TASK_SCALE - old_scale
				// 	// off := my / TASK_SCALE * diff
				// 	// height_off := f32(task.filter_index) * height * inc
				// 	// gap_off := f32(0)
				// 	// fmt.eprintln("TRY", height_off, gap_off)
				// 	// cam.offset_y -= (height_off + gap_off)
				// }

				// fmt.eprintln("TRY")
			} else {
				cam_inc_y(cam, f32(di) * 20)
				mode_panel_cam_freehand_on(cam)
			}

			element_repaint(element)
			return 1
		}

		case .Mouse_Scroll_X: {
			if element.window.ctrl {
			} else {
				cam_inc_x(cam, f32(di) * 20)
				mode_panel_cam_freehand_on(cam)
			}

			element_repaint(element)
			return 1
		}

		case .Update: {
			for list_index in app.pool.filter {
				task := app_task_list(list_index)
				element_message(&task.element, .Update, di, dp)
			}
		}

		case .Left_Down: {
			element_reset_focus(element.window)

			// add task on double click
			clicks := di % 2
			if clicks == 1 {
				if app.task_head != -1 {
					task := app_task_head()
					diff_y := element.window.cursor_y - (task.element.bounds.t + rect_height_halfed(task.element.bounds))
					todool_insert_sibling(diff_y < 0 ? COMBO_SHIFT : COMBO_EMPTY)
					cam_check(cam, .Bounds)
					return 1
				}
			}
		}

		case .Animate: {
			handled := false

			// drag animation and camera panning
			// NOTE clamps to the task bounds
			if app.drag_running {
				// just check for bounds
				x := element.window.cursor_x
				y := element.window.cursor_y
				ygoal, ydirection := cam_bounds_check_y(cam, panel.bounds, y, y)
				xgoal, xdirection := cam_bounds_check_x(cam, panel.bounds, x, x)
				task_bounds := task_total_bounds()

				top := task_bounds.t - panel.bounds.t
				bottom := task_bounds.b - panel.bounds.t

				if ydirection != 0 && 
					(ydirection == 1 && top < cam.margin_y * 2) ||
					(ydirection == -1 && bottom > panel.bounds.b - cam.margin_y * 4) { 
					cam_inc_y(cam, f32(ygoal) * 0.1 * f32(ydirection))
					mode_panel_cam_freehand_on(cam)
				}

				// need to offset by mode panel
				left := task_bounds.l - panel.bounds.l
				right := task_bounds.r - panel.bounds.l

				if xdirection != 0 && 
					(xdirection == 1 && left < cam.margin_x * 2) ||
					(xdirection == -1 && right > panel.bounds.r - cam.margin_x * 4) {
					mode_panel_cam_freehand_on(cam)
					cam_inc_x(cam, f32(xgoal) * 0.1 * f32(xdirection))
				}

				handled = true
			}

			y_handled := cam_animate(cam, false)
			handled |= y_handled

			// check y afterwards
			goal_y, direction_y := cam_bounds_check_y(cam, panel.bounds, app.caret.rect.t, app.caret.rect.b)

			if cam.ay.direction != CAM_CENTER && direction_y == 0 {
				cam.ay.animating = false
			}

			x_handled := cam_animate(cam, true)
			handled |= x_handled

			// check x afterwards
			// NOTE just check this everytime due to inconsistency
			mode_panel_cam_bounds_check_x(cam,app.caret.rect.l, app.caret.rect.r, true, true)

			// fmt.eprintln("animating!", handled, cam.offset_y, cam.offset_x)
			return int(handled)
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

			if task.state_unit > 0 {
				a := theme_task_text(task.state_last)
				b := theme_task_text(task.state)
				color^ = color_blend_amount(a, b, task.state_unit)
			}

			return 1
		}

		case .Paint_Recursive: {
			target := element.window.target
			draw_search_results := (.Hide not_in panel_search.flags)

			x := box.bounds.l
			y := box.bounds.t

			// strike through line
			if task.state == .Canceled {
				fcs_task(&task.element)
				state := fontstash.__getState(&gs.fc)
				font := fontstash.__getFont(&gs.fc, state.font)
				isize := i16(state.size * 10)
				scaled_size := f32(isize / 10)
				offset := f32(font.ascender * 3 / 4) * scaled_size

				for line_text, line_y in box.wrapped_lines {
					text_width := string_width(line_text)
					real_y := f32(y) + f32(line_y) * scaled_size + offset

					rect := RectI {
						x,
						x + text_width,
						int(real_y),
						int(real_y) + LINE_WIDTH,
					}
					
					render_rect(target, rect, theme.text_bad, 0)
				}
			}

 			// paint selection before text
			scaled_size := fcs_task(&task.element)
			if app.task_head == app.task_tail && task.filter_index == app.task_head {
				real_alpha := caret_state_real_alpha(&app.caret)
				box_render_selection(target, box, x, y, theme.caret_selection, real_alpha)
				
				task_box_paint_default_selection(box, scaled_size, real_alpha)
				// task_box_paint_default(box)
			} else {
				task_box_paint_default(box, scaled_size)
			}

			return 1
		}

		case .Left_Down: {
			task_or_box_left_down(task, di, true)
			return 1
		}

		case .Mouse_Drag: {
			mouse := (cast(^Mouse_Coordinates) dp)^

			if element.window.pressed_button == MOUSE_LEFT {
				// drag select tasks
				if element.window.shift {
					repaint: bool

					// find hovered task and set till
					for index in app.pool.filter {
						t := app_task_list(index)
						if rect_contains(t.element.bounds, element.window.cursor_x, element.window.cursor_y) {
							if app.task_head != t.filter_index {
								repaint = true
							}

							app.task_head = t.filter_index
							break
						}
					}

					if repaint {
						element_repaint(&task.element)
					}
				} else {
					if app.task_head == app.task_tail {
						scaled_size := fcs_task(&task.element)
						fcs_ahv(.LEFT, .TOP)
						element_box_mouse_selection(task.box, task.box, di, true, 0, scaled_size)
						element_repaint(&task.element)
						return 1
					}
				}
			} else if element.window.pressed_button == MOUSE_RIGHT {
				element_repaint(element)
				app.drag_circle = true
				app.drag_circle_pos = mouse

				if task_dragging_check_start(task, mouse) {
					return 1
				}
			}

			return 0
		}

		case .Right_Up: {
			app.drag_circle = false

			if task_dragging_end() {
				return 1
			}

			task_context_menu_spawn(task)
			return 1
		}

		case .Value_Changed: {
			dirty_push(&app.um_task)
		}
	}

	return 0
}

task_indentation_width :: proc(indentation: f32) -> f32 {
	return indentation * visuals_tab() * TAB_WIDTH * TASK_SCALE
}

fcs_task_tags :: proc() -> int {
	// text state
	fcs_font(font_regular)
	fcs_size(DEFAULT_FONT_SIZE * TASK_SCALE)
	fcs_ahv()		
	return int(10 * TASK_SCALE)
}

// layout tags position
task_tags_layout :: proc(task: ^Task, rect: RectI) {
	field := task.tags
	rect := rect
	tag_mode := options_tag_mode()

	fcs_push()
	defer fcs_pop()

	text_margin := fcs_task_tags()
	gap := int(5 * TASK_SCALE)
	res: RectI
	cam := mode_panel_cam()
	halfed := int(DEFAULT_FONT_SIZE * TASK_SCALE * 0.5)
	// task.tags_rect = {}

	// layout tag structs and spawn particles when now ones exist
	for i in 0..<u8(8) {
		res = {}

		if field & 1 == 1 {
			text := ss_string(sb.tags.names[i])
			
			switch tag_mode {
				case TAG_SHOW_TEXT_AND_COLOR: {
					width := string_width(text)
					res = rect_cut_left(&rect, width + text_margin)
				}

				case TAG_SHOW_COLOR: {
					res = rect_cut_left(&rect, int(50 * TASK_SCALE))
				}
			}

			rect.l += gap
			
			// spawn partciles in power mode when changed
			if task.tags_rect[i] == {} {
				x := res.l
				y := res.t + halfed
				power_mode_spawn_along_text(text, f32(x + text_margin / 2), f32(y), theme.tags[i])
			}
		} 
		
		task.tags_rect[i] = res
		field >>= 1
	}
}

// manual layout call so we can predict the proper positioning
task_layout :: proc(
	task: ^Task, 
	bounds: RectI, 
	move: bool,
	tab_scaled: int,
	margin_scaled: int,
) -> RectI {
	offset_indentation := int(task.indentation_smooth * f32(tab_scaled))
	
	// manually offset the line rectangle in total while retaining parent clip
	bounds := bounds
	bounds.t += int(task.top_offset)
	bounds.b += int(task.top_offset)

	// seperator
	cut := bounds
	if task_separator_is_valid(task) {
		rect := rect_cut_top(&cut, int(20 * TASK_SCALE))

		if move {
			element_move(task.seperator, rect)
		}
	}

	task.element.clip = rect_intersection(task.element.parent.clip, cut)
	task.element.bounds = cut

	// bookmark
	if task_bookmark_is_valid(task) {
		rect := rect_cut_left(&cut, int(15 * TASK_SCALE))

		if move {
			if task.button_bookmark.bounds == {} {
				x, y := rect_center(rect)
				cam := mode_panel_cam()
				cam_screenshake_reset(cam)
				power_mode_spawn_at(x, y, cam.offset_x, cam.offset_y, P_SPAWN_HIGH, theme.text_default)
			}

			element_move(task.button_bookmark, rect)
		}
	} else {
		if task.button_bookmark != nil {
			task.button_bookmark.bounds = {}
		}
	}

	// margin after bookmark
	cut = rect_margin(cut, margin_scaled)

	// image
	if image_display_has_content_soon(task.image_display) {
		top := rect_cut_top(&cut, int(IMAGE_DISPLAY_HEIGHT * TASK_SCALE))
		top.b -= int(5 * TASK_SCALE)

		if move {
			if task.image_display.bounds == {} {
				x, y := rect_center(top)
				power_mode_spawn_rect(top, 10, theme.text_default)
			}

			element_move(task.image_display, top)
		}
	} else {
		if task.image_display != nil {
			task.image_display.bounds = {}
		}
	}

	// link button
	if task_link_is_valid(task) {
		height := element_message(task.button_link, .Get_Height)
		width := element_message(task.button_link, .Get_Width)
		rect := rect_cut_bottom(&cut, height)
		rect.r = rect.l + width
		
		if move {
			element_move(task.button_link, rect)
		}
	} else {
		if task.button_link != nil {
			task.button_link.bounds = {}
		}
	}

	// tags place
	tag_mode := options_tag_mode()
	if tag_mode != TAG_SHOW_NONE && task.tags != 0x00 {
		rect := rect_cut_bottom(&cut, tag_mode_size(tag_mode))
		cut.b -= int(5 * TASK_SCALE)  // gap

		if move {
			task_tags_layout(task, rect)
		}
	}

	// fold button
	element_hide(task.button_fold, !task_has_children(task))
	if task_has_children(task) {
		rect := rect_cut_left(&cut, int(DEFAULT_FONT_SIZE * TASK_SCALE))
		cut.l += int(5 * TASK_SCALE)

		if move {
			element_move(task.button_fold, rect)
		}
	}

	// time date
	if task_time_date_is_valid(task) {
		// width := element_message(task.time_date)
		rect := rect_cut_left(&cut, int(100 * TASK_SCALE))
		cut.l += int(5 * TASK_SCALE)

		if move {
			element_move(task.time_date, rect)
		}		
	} else {
		if task.time_date != nil {
			task.time_date.bounds = {}
		}
	}
	
	task.box.font_options = task.element.font_options
	if move {
		task.box.rendered_glyphs = nil
		element_move(task.box, cut)
	}

	return cut
}

tag_mode_size :: proc(tag_mode: int) -> (res: int) {
	if tag_mode == TAG_SHOW_TEXT_AND_COLOR {
		res = int(DEFAULT_FONT_SIZE * TASK_SCALE)
	} else if tag_mode == TAG_SHOW_COLOR {
		res = int(10 * TASK_SCALE)
	} 

	return
}

task_or_box_left_down :: proc(task: ^Task, clicks: int, only_box: bool) {
	// set line to the head
	shift := app.window_main.shift
	task_head_tail_check_begin(shift)
	app.task_head = task.filter_index
	task_head_tail_check_end(shift)

	if only_box {
		if app.task_head != app.task_tail {
			box_set_caret_dp(task.box, BOX_END, nil)
		} else {
			old_tail := task.box.tail
			scaled_size := fcs_task(&task.element)
			fcs_ahv(.LEFT, .TOP)
			element_box_mouse_selection(task.box, task.box, clicks, false, 0, scaled_size)

			if task.element.window.shift && clicks == 0 {
				task.box.tail = old_tail
			}
		}
	}
}

task_message :: proc(element: ^Element, msg: Message, di: int, dp: rawptr) -> int {
	task := cast(^Task) element
	tag_mode := options_tag_mode()
	draw_tags := tag_mode != TAG_SHOW_NONE && task.tags != 0x0

	#partial switch msg {
		case .Get_Width: {
			return int(TASK_SCALE * 200)
		}

		case .Get_Height: {
			line_size := task_font_size(element) * len(task.box.wrapped_lines)
			// line_size += int(f32(task.has_children ? DEFAULT_FONT_SIZE + TEXT_MARGIN_VERTICAL : 0) * TASK_SCALE)

			line_size += draw_tags ? tag_mode_size(tag_mode) + int(5 * TASK_SCALE) : 0
			line_size += image_display_has_content_soon(task.image_display) ? int(IMAGE_DISPLAY_HEIGHT * TASK_SCALE) : 0
			line_size += task_link_is_valid(task) ? element_message(task.button_link, .Get_Height) : 0
			line_size += task_separator_is_valid(task) ? int(SEPARATOR_SIZE * TASK_SCALE) : 0
			margin_scaled := int(visuals_task_margin() * TASK_SCALE * 2)
			line_size += margin_scaled

			return int(line_size)
		}

		case .Layout: {
			if task.top_animation_start {
				task.top_offset = f32(task.top_old - task.element.bounds.t)
				task.top_animation_start = false
			}

			tab_scaled := int(visuals_tab() * TAB_WIDTH * TASK_SCALE)
			margin_scaled := int(visuals_task_margin() * TASK_SCALE)
			task_layout(task, element.bounds, true, tab_scaled, margin_scaled)
		}

		case .Paint_Recursive: {
			target := element.window.target
			rect := task.element.bounds

			// render panel front color
			task_color := theme_task_panel_color(task)
			render_rect(target, rect, task_color, ROUNDNESS)

			// draw tags at an offset
			if draw_tags {
				fcs_task_tags()
				field := task.tags

				// go through each existing tag, draw each one
				for i in 0..<u8(8) {
					if field & 1 == 1 {
						tag := sb.tags.names[i]
						tag_color := theme.tags[i]
						r := task.tags_rect[i]

						switch tag_mode {
							case TAG_SHOW_TEXT_AND_COLOR: {
								render_rect(target, r, tag_color, ROUNDNESS)
								fcs_color(color_to_bw(tag_color))
								render_string_rect(target, r, ss_string(tag))
							}

							case TAG_SHOW_COLOR: {
								render_rect(target, r, tag_color, ROUNDNESS)
							}

							case: {
								unimplemented("shouldnt get here")
							}
						}
					}

					field >>= 1
				}
			}

			// render sub elements
			for child in element.children {
				render_element_clipped(target, child)
			}

			return 1
		}

		case .Middle_Down: {
			window_set_pressed(element.window, app.mmpp, MOUSE_MIDDLE)
		}

		case .Find_By_Point_Recursive: {
			p := cast(^Find_By_Point) dp
			task.tag_hovered = -1

			// find tags first
			field := task.tags
			for i in 0..<8 {
				if field & 1 == 1 {
					r := task.tags_rect[i]
					
					if rect_contains(r, p.x, p.y) {
						p.res = &task.element
						task.tag_hovered = i
						return 1
					}
				}

				field >>= 1
			}

			handled := element_find_by_point_custom(element, p)

			if handled == 0 {
				if rect_contains(task.element.bounds, p.x, p.y) {
					p.res = &task.element
					handled = 1
				}
			}

			return handled
		}

		case .Get_Cursor: {
			return int(task.tag_hovered != -1 ? Cursor.Hand : Cursor.Arrow)
		}

		case .Left_Down: {
			if task.tag_hovered != -1 {
				bit := u8(1 << u8(task.tag_hovered))
				manager := mode_panel_manager_scoped()
				task_head_tail_push(manager)
				u8_xor_push(manager, &task.tags, bit)
			} else {
				task_or_box_left_down(task, di, false)
			}

			return 1
		}

		case .Animate: {
			handled := false

			handled |= animate_to_state(
				&task.indentation_animating,
				&task.indentation_smooth, 
				f32(task.indentation),
				2, 
				0.01,
			)
			
			handled |= animate_to_state(
				&task.top_animating,
				&task.top_offset, 
				0, 
				1, 
				1,
			)

			// progress animation on parent
			if task_has_children(task) && progressbar_show() {
				for count, i in task.state_count {
					always := true
					state := Task_State(i)
					// in case this gets run too early to avoid divide by 0
					value := f32(count) / max(f32(len(task.filter_children)), 1)

					handled |= animate_to_state(
						&always,
						&task.progress_animation[state],
						value,
						1,
						0.01,
					)
				}
			}

			return int(handled)
		}

		case .Update: {
			for child in element.children {
				element_message(child, msg, di, dp)
			}
		}

		case .Destroy: {
			delete(task.filter_children)
		}
	}

	return 0
}

task_progress_state_set :: proc(task: ^Task) {
	for count, i in task.state_count {
		state := Task_State(i)
		value := f32(count) / f32(len(task.filter_children))
		task.progress_animation[state] = value
	}
}

//////////////////////////////////////////////
// init calls
//////////////////////////////////////////////

goto_init :: proc(window: ^Window) {
	p := panel_floaty_init(&window.element, {})
	app.panel_goto = p
	p.panel.background_index = 2
	p.width = 200
	// p.height = DEFAULT_FONT_SIZE * 2 * SCALE + p.panel.margin * 2
	p.panel.flags |= {}
	p.panel.margin = 5
	p.panel.shadow = true

	p.message_user = proc(element: ^Element, msg: Message, di: int, dp: rawptr) -> int {
		floaty := cast(^Panel_Floaty) element

		#partial switch msg {
			case .Animate: {
				handled := animate_to_state(
					&app.goto_transition_animating,
					&app.goto_transition_unit,
					app.goto_transition_hide ? 1 : 0,
					4,
					0.01,
				)

				if !handled && app.goto_transition_hide {
					element_hide(floaty, true)
				}

				return int(handled)
			}

			case .Layout: {
				floaty.height = 0
				for c in element.children {
					floaty.height += element_message(c, .Get_Height)
				}

				w := int(f32(floaty.width) * SCALE)

				floaty.x = 
					app.mmpp.bounds.l + rect_width_halfed(app.mmpp.bounds) - w / 2
				
				off := int(10 * SCALE)
				floaty.y = 
					(app.mmpp.bounds.t + off) + int(app.goto_transition_unit * -f32(floaty.height + off))

				// NOTE already taking scale into account from children
				h := floaty.height
				rect := rect_wh(floaty.x, floaty.y, w, h)
				element_move(floaty.panel, rect)
				return 1
			}

			case .Key_Combination: {
				combo := (cast(^string) dp)^
				handled := true

				switch combo {
					// case "escape": {
					// 	goto_transition_unit = 0
					// 	goto_transition_hide = true
					// 	goto_transition_animating = true
					// 	element_animation_start(floaty)

					// 	// reset to origin 
					// 	task_head = goto_saved_task_head
					// 	app.task_tail = goto_saved_task_tail
					// }

					case "return": {
						app.goto_transition_unit = 0
						app.goto_transition_hide = true
						app.goto_transition_animating = true
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

	label_init(p.panel, { .Label_Center, .HF }, "Goto Line")
	spacer_init(p.panel, { .HF }, 0, 10)
	box := text_box_init(p.panel, { .HF })
	box.codepoint_numbers_only = true
	box.um = &app.um_goto
	box.message_user = proc(element: ^Element, msg: Message, di: int, dp: rawptr) -> int {
		box := cast(^Text_Box) element

		#partial switch msg {
			case .Value_Changed: {
				value := strconv.atoi(ss_string(&box.ss))
				old_head := app.task_head
				old_tail := app.task_tail

				// NOTE kinda bad because it changes on reparse
				// if options_vim_use() {
				// 	temp := task_head
				// 	task_head = temp + value
				// 	app.task_tail = temp + value
				// 	fmt.eprintln(task_head, task_tail)
				// } else {
					value -= 1
					app.task_head = value
					app.task_tail = value
				// }

				if old_head != app.task_head && old_tail != app.task_tail {
					element_repaint(box)
				}
			}

			case .Update: {
				if di == UPDATE_FOCUS_LOST {
					element_hide(app.panel_goto, true)
					element_focus(element.window, nil)
				}
			}
		}

		return 0
	}

	element_hide(p, true)
}

custom_split_set_scrollbars :: proc(split: ^Custom_Split) {
	cam := mode_panel_cam()
	scrollbar_position_set(split.vscrollbar, f32(-cam.offset_y))
	scrollbar_position_set(split.hscrollbar, f32(-cam.offset_x))
}

custom_split_message :: proc(element: ^Element, msg: Message, di: int, dp: rawptr) -> int {
	split := cast(^Custom_Split) element

	#partial switch msg {
		case .Layout: {
			bounds := element.bounds
			// log.info("BOUNDS", element.bounds, window_rect(window_main))

			// if .Hide not_in split.statusbar.stat.flags {
			// 	bot := rect_cut_bottom(&bounds, int(DEFAULT_FONT_SIZE * SCALE + TEXT_MARGIN_VERTICAL * SCALE * 2))
			// 	element_move(split.statusbar.stat, bot)
			// }

			if .Hide not_in panel_search.flags {
				bot := rect_cut_bottom(&bounds, int(50 * SCALE))
				element_move(panel_search, bot)
			}

			if image_display_has_content_now(split.image_display) {
				element_move(split.image_display, rect_margin(bounds, int(20 * SCALE)))
			} else {
				split.image_display.bounds = {}
				split.image_display.clip = {}
			}

			// avoid layouting twice
			element_move(app.mmpp, bounds)

			// scrollbar depends on result after mode panel layouting
			{
				task_bounds := task_total_bounds()
		
				scrollbar_layout_help(
					split.hscrollbar,
					split.vscrollbar,
					bounds,
					rect_width(task_bounds),
					rect_height(task_bounds),
				)
			}
		}

		case .Scrolled_X: {
			cam := &app.mmpp.cam[app.mmpp.mode]
			if split.hscrollbar != nil {
				cam.offset_x = math.round(-split.hscrollbar.position)
			}
			mode_panel_cam_freehand_on(cam)
		}

		case .Scrolled_Y: {
			cam := &app.mmpp.cam[app.mmpp.mode]
			if split.vscrollbar != nil {
				cam.offset_y = math.round(-split.vscrollbar.position)
			}	
			mode_panel_cam_freehand_on(cam)
		}
	}

	return 0  	
}

task_panel_init :: proc(split: ^Split_Pane) -> (element: ^Element) {
	rect := split.window.rect

	app.custom_split = element_init(Custom_Split, split, {}, custom_split_message, context.allocator)
	app.custom_split.flags |= { .Sort_By_Z_Index }

	when !PRESENTATION_MODE {
		app.custom_split.vscrollbar = scrollbar_init(app.custom_split, {}, false, context.allocator)
		app.custom_split.vscrollbar.force_visible = true	
		app.custom_split.hscrollbar = scrollbar_init(app.custom_split, {}, true, context.allocator)
		app.custom_split.hscrollbar.force_visible = true	
	}

	app.custom_split.image_display = image_display_init(app.custom_split, {}, nil)
	app.custom_split.image_display.aspect = .Mix
	app.custom_split.image_display.message_user = proc(element: ^Element, msg: Message, di: int, dp: rawptr) -> int {
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

	app.mmpp = mode_panel_init(app.custom_split, {})
	search_init(app.custom_split)
	
	return app.mmpp
}

tasks_load_file :: proc() {
	spall.scoped("load tasks")
	err: Save_Error = nil
	
	if len(app.last_save_location.buf) != 0 {
		file_path := strings.to_string(app.last_save_location)
		file_data, ok := os.read_entire_file(file_path)
		defer delete(file_data)

		if !ok {
			log.infof("LOAD: File not found %s\n", file_path)
			return
		}

		err = load_all(file_data)
		
		if err != nil {
			log.info("LOAD: FAILED =", err, save_loc)
		}
	} else {
		log.info("TODOOL: no default save path set")
	}
	
	// on error reset and load default
	if err != nil {
		log.info("TODOOL: Loading failed -> Loading default")
		last_save_set()
		tasks_load_reset()
		tasks_load_tutorial()
	} else {
		log.info("TODOOL: Loading success")
	}
}

tasks_load_reset :: proc() {
	app.mmpp.mode = .List

	task_pool_clear(&app.pool)
	spell_check_clear_user()
	archive_reset(&sb.archive)

	undo_manager_reset(&app.um_task)
	app.dirty = 0
	app.dirty_saved = 0
}

tasks_load_tutorial :: proc() {
	scaling_set(SCALE, 1)
	cam := mode_panel_cam()
	cam_check(cam, .Bounds)

	// TODO add these to spell checker
	@static load_indent := 0

	@(deferred_none=pop)
	push_scoped_task :: #force_inline proc(text: string) {
		spell_check_mapping_words_add(text)
		task_push(max(load_indent, 0), text)
		load_indent	+= 1
	}

	pop :: #force_inline proc() {
	  load_indent -= 1
	}

	t :: #force_inline proc(text: string) {
		task_push(max(load_indent, 0), text)
	}

	{
		push_scoped_task("Thank You For Trying Todool!")
		t("if you have any issues, please post them on the discord or the itch comments")
		t("tutorial shortcut explanations are based on default key bindings")
	}

	{
		push_scoped_task("Task Keyboard Movement")

		t("up / down -> move to upper / lower task")
		t("shift + movement -> shift select till the new destination")
		t("ctrl+up / ctrl+down -> move to same upper/ lower task with the same indentation")
		t("ctrl+m -> moves to the last task in scope, then shuffles between the start of the scope")
		t("ctrl+, / ctrl+. -> moves to the previous / next task at indentation 0")
		t("alt+up / alt+down -> shift the selected tasks up / down")
		t("ctrl+home / ctrl+end -> move up/down a stack")
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
		push_scoped_task("Task Properties")
		t("tab -> increase the selected tasks indentation")
		t("shift+tab -> decrease the selected tasks indentation")
		t("ctrl+q -> cycle through the selected tasks state")
		t("ctrl+j -> toggle the current task folding level")
	}

	{
		push_scoped_task("Tags")
		t("ctrl+(1-8) -> toggle the selected tasks tag (1-8)")
	}

	{
		push_scoped_task("Text Manipulation")
		t("ctrl+shift+j -> uppercase the starting words of the selected tasks")
		t("ctrl+shift+l -> lowercase all letters of the selected tasks")
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
		t("ctrl+s -> save to a file or last saved location")
		t("ctrl+shift+s -> save to a file")
		t("ctrl+o -> load from a file")
		t("ctrl+n -> new file")
		t("ctrl+z -> undo")
		t("ctrl+y -> redo")
		t("ctrl+e -> center the view vertically")
	}

	{
		push_scoped_task("Context Menus")
		t("rightclick task -> Task Context Menu opens")
		t("rightclick multi-selection -> Multi-Selection Prompt opens")
		t("rightclick empty -> Default Context Menu Opens")
	}

	app.task_head = 0
	app.task_tail = 0

	// TODO add ctrl+shift+return to insert at prev
}

task_context_menu_spawn :: proc(task: ^Task) {
	menu := menu_init(app.mmpp.window, { .Panel_Expand })
	defer menu_show(menu)

	task_multi_context := app.task_head != app.task_tail
	
	// select this task on single right click
	if app.task_head == app.task_tail {
		app.task_tail = task.filter_index
		app.task_head = task.filter_index
	}

	p := menu.panel
	p.shadow = true
	p.background_index = 2

	// deletion
	mbl(p, "Completion", "change_task_state", COMBO_EMPTY, .PLUS)
	mbl(p, "Completion", "change_task_state", COMBO_SHIFT, .MINUS)
	mbs(p)
	mbl(p, "Cut", "cut_tasks")
	mbl(p, "Copy", "copy_tasks")
	mbl(p, "Paste", "paste_tasks")
	mbl(p, "Delete", "delete_tasks")
	mbs(p)
	mbl(p, "Copy To Clipboard", "copy_tasks_to_clipboard")
	mbl(p, "Paste From Clipboard", "paste_tasks_from_clipboard")
	mbs(p)
	mbl(p, "Bookmark", "toggle_bookmark")
	mbl(p, "Timestamp", "toggle_timestamp")

	// if false && task != nil {
	// 	b1_text := task_separator_is_valid(task) ? "Remove Seperator" : "Add Seperator"
	// 	b1 := button_init(p, {}, b1_text)
	// 	b1.invoke = proc(button: ^Button, data: rawptr) {
	// 		task := app_task_head()
	// 		valid := task_separator_is_valid(task)
	// 		task_set_separator(task, !valid)
			
	// 		menu_close(button.window)
	// 	}

	// 	b2_text := app.task_highlight == task ? "Remove Highlight" : "Set Highlight"
	// 	b2 := button_init(p, {}, b2_text)

	// 	b2.invoke = proc(button: ^Button, data: rawptr) {
	// 		task := app_task_head()
	// 		if task == app.task_highlight {
	// 			app.task_highlight = nil
	// 		} else {
	// 			app.task_highlight = task
	// 		}

	// 		menu_close(button.window)
	// 	}
	// }
}

// Check if point is inside circle
check_collision_point_circle :: proc(point, center: [2]f32, radius: f32) -> bool {
	return check_collision_point_circles(point, 0, center, radius)
}

// Check collision between two circles
check_collision_point_circles :: proc(
	center1: [2]f32, 
	radius1: f32, 
	center2: [2]f32, 
	radius2: f32,
) -> (collision: bool) {
	dx := center2.x - center1.x	// X distance between centers
	dy := center2.y - center1.y	// Y distance between centers
	distance := math.sqrt(dx * dx + dy * dy) // Distance between centers

	if distance <= (radius1 + radius2) {
		collision = true
	}

	return
}

task_dragging_check_start :: proc(task: ^Task, mouse: Mouse_Coordinates) -> bool {
	if app.task_head == -1 || app.drag_running {
		return true
	}

	mouse: [2]f32 = { f32(mouse.x), f32(mouse.y) }
	pos := [2]f32 { f32(task.element.window.cursor_x), f32(task.element.window.cursor_y) }
	circle_size := DRAG_CIRCLE * TASK_SCALE
	if check_collision_point_circle(mouse, pos, circle_size) {
		return false
	}

	low, high := task_low_and_high()
	selected := low <= task.filter_index && task.filter_index <= high

	// on not task != selection just select this one
	if !selected {
		app.task_head = task.filter_index
		app.task_tail = task.filter_index
		low, high = task_low_and_high()
	}

	clear(&app.drag_list)
	manager := mode_panel_manager_scoped()
	task_head_tail_push(manager)

	// push removal tasks to array before
	iter := lh_iter_init()
	for task in lh_iter_step(&iter) {
		append(&app.drag_list, task)
	}

	task_head_tail_push(manager)
	task_remove_selection(manager, false)

	if low != high {
		app.task_head = low
		app.task_tail = low
	}

	app.drag_running = true
	app.drag_index_at = -1
	element_animation_start(app.mmpp)

	// init animation positions
	{
		width := int(TASK_DRAG_SIZE * TASK_SCALE)
		height := int(TASK_DRAG_SIZE * TASK_SCALE)
		x := app.window_main.cursor_x - int(f32(width) / 2)
		y := app.window_main.cursor_y - int(f32(height) / 2)

		for i := len(app.drag_goals) - 1; i >= 0; i -= 1 {
			pos := &app.drag_goals[i]
			pos.x = f32(x) + f32(i) * 5 * TASK_SCALE
			pos.y = f32(y) + f32(i) * 5 * TASK_SCALE
		}
	}

	return true
}

task_dragging_end :: proc() -> bool {
	if !app.drag_running {
		return false
	}

	app.drag_circle = false
	app.drag_running = false
	element_animation_stop(app.mmpp)
	force_push := app.task_head == -1

	// remove task on invalid
	if app.drag_index_at == -1 && !force_push {
		return true
	}

	// find lowest indentation 
	lowest_indentation := max(int)
	for i in 0..<len(app.drag_list) {
		task := app.drag_list[i]
		lowest_indentation = min(lowest_indentation, task.indentation)
	}

	drag_indentation: int
	drag_index := -1

	if app.drag_index_at != -1 {
		task_drag_at := app_task_filter(app.drag_index_at)
		drag_index = task_drag_at.filter_index

		if app.task_head != -1 {
			drag_indentation = task_drag_at.indentation

			if task_has_children(task_drag_at) {
				drag_indentation += 1
			}
		}
	}

	manager := mode_panel_manager_scoped()
	task_head_tail_push(manager)
	app.task_state_progression = .Update_Animated	
	
	// paste lines with indentation change saved
	for i in 0..<len(app.drag_list) {
		t := app.drag_list[i]
		relative_indentation := drag_indentation + int(t.indentation) - lowest_indentation
		
		item := Undo_Item_Task_Indentation_Set {
			task = t,
			set = t.indentation,
		}	
		undo_push(manager, undo_task_indentation_set, &item, size_of(Undo_Item_Task_Indentation_Set))

		t.indentation = relative_indentation
		t.indentation_smooth = f32(t.indentation)
		task_insert_at(manager, drag_index + i + 1, t)
	}

	app.task_tail = app.drag_index_at + 1
	app.task_head = app.drag_index_at + len(app.drag_list)

	element_repaint(app.mmpp)
	window_set_cursor(app.mmpp.window, .Arrow)
	return true
}

mode_panel_context_menu_spawn :: proc() {
	menu := menu_init(app.mmpp.window, { .Panel_Expand })
	defer menu_show(menu)

	p := menu.panel
	p.shadow = true
	p.background_index = 2

	mbl(p, "Theme Editor", "theme_editor")
	mbl(p, "Keymap Editor", "keymap_editor")
	mbl(p, "Changelog Generator", "changelog")
	mbc(p, "Load Tutorial", proc() { 
		app_save_maybe(
				app.window_main, 
				proc() {
					tasks_load_reset()
					last_save_set("")
				  tasks_load_tutorial()
				}, 
			)
	 })
}

// make sure cam is forced and skips trail
mode_panel_cam_freehand_on :: proc(cam: ^Pan_Camera) {
	cam.freehand = true
	app.caret.motion_skip = true
}

mode_panel_cam_freehand_off :: proc(cam: ^Pan_Camera) {
	cam.freehand = false
	app.caret.alpha = 0
}

task_render_progressbars :: proc(target: ^Render_Target) {
	if app.progressbars_alpha == 0 {
		return
	}

	render_push_clip(target, app.mmpp.clip)
	builder := strings.builder_make(16, context.temp_allocator)

	fcs_ahv()
	fcs_font(font_regular)
	fcs_size(DEFAULT_FONT_SIZE * TASK_SCALE)
	fcs_color(theme_panel(.Parent))

	w := int(100 * TASK_SCALE)
	h := int((DEFAULT_FONT_SIZE + TEXT_MARGIN_VERTICAL) * TASK_SCALE)
	off := int(-10 * TASK_SCALE)
	// off := int(visuals_task_margin() / 2)
	default_rect := rect_wh(0, 0, w, h)
	low, high := task_low_and_high()
	hovered := app.mmpp.window.hovered
	use_percentage := progressbar_percentage()
	hover_only := progressbar_hover_only()

	for index in app.pool.filter {
		task := app_task_list(index)
		
		if hover_only && hovered != &task.element && hovered.parent != &task.element {
			continue
		}

		if task_has_children(task) {
			rect := rect_translate(
				default_rect,
				rect_xxyy(task.element.bounds.r - w + off, task.element.bounds.t + off),
			)

			prect := rect
			progress_size := rect_widthf(rect)
			alpha: f32 = low <= task.filter_index && task.filter_index <= high ? 0.25 : 1
			alpha = min(app.progressbars_alpha, alpha)

			for state, i in Task_State {
				if task.progress_animation[state] != 0 {
					roundness := ROUNDNESS + (i == 0 ? 1 : 0)
					render_rect(target, prect, color_alpha(theme_task_text(state), alpha), roundness)
				}

				prect.l += int(task.progress_animation[state] * progress_size)
				// prect.r += i * 2
			}

			strings.builder_reset(&builder)
			non_normal := len(task.filter_children) - task.state_count[.Normal]
			if use_percentage {
				fmt.sbprintf(&builder, "%.0f%%", f32(non_normal) / f32(len(task.filter_children)) * 100)
			} else {
				fmt.sbprintf(&builder, "%d / %d", non_normal, len(task.filter_children))
			}
			render_string_rect(target, rect, strings.to_string(builder))
		}
	}
}

todool_menu_bar :: proc(parent: ^Element) -> (split: ^Menu_Split, menu: ^Menu_Bar) {
	split = menu_split_init(parent)
	menu = menu_bar_init(split)
	
	quit :: proc() {
		window_try_quit(app.window_main)
	}

	locals :: proc() {
		open_folder(gs.pref_path)
	}

	menu_bar_field_init(menu, "File", 1).invoke = proc(p: ^Panel) {
		mbl(p, "New File", "new_file", COMBO_EMPTY, .DOC)
		mbl(p, "Open File", "load", COMBO_EMPTY, .DOC_INV)
		mbl(p, "Save", "save", COMBO_EMPTY, .FLOPPY)
		mbl(p, "Save As...", "save", COMBO_TRUE, .FLOPPY)
		mbc(p, "Locals", locals, .FOLDER)
		mbs(p)
		mbc(p, "Quit", quit)
	}
	menu_bar_field_init(menu, "View", 2).invoke = proc(p: ^Panel) {
		mbl(p, "Mode List", "mode_list")
		mbl(p, "Mode Kanban", "mode_kanban")
		mbs(p)
		mbl(p, "Theme Editor", "theme_editor")
		mbl(p, "Changelog", "changelog")
		mbl(p, "Keymap Editor", "keymap_editor")
		mbs(p)
		mbl(p, "Goto", "goto")
		mbl(p, "Search", "search")
		mbs(p)
		mbl(p, "Scale Tasks Up", "scale_tasks", COMBO_POSITIVE)
		mbl(p, "Scale Tasks Down", "scale_tasks", COMBO_NEGATIVE)
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
		mbl(p, "Completion", "change_task_state", COMBO_EMPTY, .PLUS)
		mbl(p, "Completion", "change_task_state", COMBO_SHIFT, .MINUS)
		mbs(p)
		mbl(p, "Folding", "toggle_folding")
		mbl(p, "Bookmark", "toggle_bookmark")
		mbl(p, "Timestamp", "toggle_timestamp")
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
		mbl(p, "Move Start", "move_start")
		mbl(p, "Move End", "move_end")
		mbs(p)
		mbl(p, "Select All", "select_all")
		mbl(p, "Select Children", "select_children")
	}
	// p2 := panel_init(split, { .Panel_Default_Background })
	// p2.background_index = 1
	return
}

task_string :: #force_inline proc(task: ^Task) -> string {
	return ss_string(&task.box.ss)
}

// render number highlights
render_line_highlights :: proc(target: ^Render_Target, clip: RectI) {
	render := visuals_line_highlight_use()
	alpha := visuals_line_highlight_alpha()

	// force in goto
	if app.panel_goto != nil && (.Hide not_in app.panel_goto.flags) && !app.goto_transition_hide {
		render = true
	}
	
	// skip non rendering and forced on non alpha
	if !render || alpha == 0 {
		return
	}

	render_push_clip(target, clip)
	
	b := &app.builder_line_number
	fcs_ahv(.RIGHT, .MIDDLE)
	fcs_font(font_regular)
	fcs_size(DEFAULT_FONT_SIZE * TASK_SCALE)
	fcs_color(color_alpha(theme.text_default, alpha))
	gap := int(4 * TASK_SCALE)

	// line_offset := options_vim_use() ? -task_head : 1
	list := app_focus_list()
	app_focus_bounds()
	line_offset := TODOOL_RELEASE ? 1 : 0
	line_offset += app.focus.root != nil ? app.focus.start : 0

	for list_index, linear_index in list { 
		t := app_task_list(list_index)

		// NOTE necessary as the modes could have the tasks at different positions
		if !rect_overlap(t.element.bounds, clip) {
			continue
		}

		r := RectI {
			t.element.bounds.l - 50 - gap,
			t.element.bounds.l - gap,
			t.element.bounds.t,
			t.element.bounds.b,
		}

		if !rect_overlap(r, clip) {
			continue
		}

		strings.builder_reset(b)

		when POOL_DEBUG {
			strings.write_int(b, list_index)
			strings.write_string(b, " | ")
		}

		strings.write_int(b, linear_index + line_offset)
		text := strings.to_string(app.builder_line_number)
		width := string_width(text) + TEXT_MARGIN_HORIZONTAL
		render_string_rect(target, r, text)
	}
}

// render top right zoom highlight 
render_zoom_highlight :: proc(target: ^Render_Target, clip: RectI) {
	if app.mmpp.zoom_highlight == 0 {
		return
	}

	render_push_clip(target, clip)
	alpha := min(app.mmpp.zoom_highlight, 1)
	color := color_alpha(theme.text_default, alpha)
	rect := app.mmpp.bounds
	rect.l = rect.r - 100
	rect.b = rect.t + 100
	zoom := fmt.tprintf("%.2f", TASK_SCALE)
	render_drop_shadow(
		target, 
		rect_margin(rect, 20), 
		color_alpha(theme_panel(.Front), alpha), 
		ROUNDNESS,
	)
	fcs_ahv()
	fcs_color(color)
	fcs_font(font_regular)
	fcs_size(DEFAULT_FONT_SIZE * SCALE)
	render_string_rect(target, rect, zoom)
}

// rendered glyphs system to store previously rendered glyphs 

rendered_glyphs_clear :: proc() {
	clear(&app.rendered_glyphs)	
}

rendered_glyph_start :: #force_inline proc() {
	app.rendered_glyphs_start = len(app.rendered_glyphs)
}

rendered_glyph_gather :: #force_inline proc(output: ^[]Rendered_Glyph) {
	output^ = app.rendered_glyphs[app.rendered_glyphs_start:]
}

rendered_glyph_push :: proc(x, y: f32, codepoint: rune) -> ^Rendered_Glyph {
	append(&app.rendered_glyphs, Rendered_Glyph { 
		x = x, 
		y = y, 
		codepoint = codepoint,
	})
	return &app.rendered_glyphs[len(app.rendered_glyphs) - 1]
}

// wrapped lines equivalent

wrapped_lines_clear :: proc() {
	clear(&app.wrapped_lines)	
}

wrapped_lines_push :: proc(
	text: string, 
	width: f32,
	output: ^[]string,
) {
	start := len(app.wrapped_lines)
	wrap_format_to_lines(
		&gs.fc,
		text,
		width,
		&app.wrapped_lines,
	)
	output^ = app.wrapped_lines[start:len(app.wrapped_lines)]
}

wrapped_lines_push_forced :: proc(text: string, output: ^[]string) {
	start := len(app.wrapped_lines)
	append(&app.wrapped_lines, text)		
	output^ = app.wrapped_lines[start:len(app.wrapped_lines)]
}

// opens a link via libc.system
open_link :: proc(url: string) {
	b := &gs.cstring_builder
	strings.builder_reset(b)

	when ODIN_OS == .Linux {
		strings.write_string(b, "xdg-open")
	} else when ODIN_OS == .Windows {
		strings.write_string(b, "start")
	}

	strings.write_byte(b, ' ')
	strings.write_string(b, url)
	strings.write_byte(b, '\x00')
	libc.system(cstring(raw_data(b.buf)))
}

// TODO check on windows
open_folder :: proc(path: string) {
	b := &gs.cstring_builder
	strings.builder_reset(b)

	when ODIN_OS == .Linux {
		strings.write_string(b, "xdg-open")
	} else when ODIN_OS == .Windows {
		strings.write_string(b, "explorer.exe")
	}

	strings.write_byte(b, ' ')
	strings.write_string(b, path)
	strings.write_byte(b, '\x00')
	libc.system(cstring(raw_data(b.buf)))		
}

caret_state_update_motion :: proc(using state: ^Caret_State, allow_last: bool) -> bool {
	return caret_animate() && 
		caret_motion() && 
		!motion_skip && 
		(int(motion_last_x) != rect.l || int(motion_last_y) != rect.t || (allow_last && motion_last_frame))
}

caret_state_update_alpha :: proc(using state: ^Caret_State) -> bool {
	return caret_animate() && caret_alpha()
}

caret_state_real_alpha :: proc(state: ^Caret_State) -> f32 {
	return caret_state_update_alpha(state) ? 1 - clamp(state.alpha * state.alpha * state.alpha, 0, 1) : 1
}

caret_state_update_outline :: proc(using state: ^Caret_State) -> bool {
	return caret_animate() && 
		caret_motion() && 
		!motion_skip && 
		outline_goal != outline_current
}

caret_state_update_multi :: proc(using state: ^Caret_State) -> bool {
	return caret_animate()
}

Motion_Rect_Iter :: struct {
	x, y: f32,
	width, height: f32,
	
	last_x, last_y: f32,
	previous_x: f32,
	
	count: int,
	index: int,
	step_unit: f32,
}

motion_rect_init :: proc(rect: RectI, last_x, last_y: f32, count: int) -> (res: Motion_Rect_Iter) {
	res.last_x = last_x
	res.last_y = last_y
	res.count = count
	res.x = f32(rect.l)
	res.y = f32(rect.t)
	res.height = rect_heightf(rect)
	res.width = rect_widthf(rect)
	return
}

motion_rect_iter :: proc(iter: ^Motion_Rect_Iter) -> (res: RectF, step: f32, ok: bool) {
	if iter.index < iter.count {
		step = iter.step_unit
		iter.index += 1
		iter.step_unit = f32(iter.index) / f32(iter.count)

		x := math.lerp(iter.x, iter.last_x, iter.step_unit)
		y := math.lerp(iter.y, iter.last_y, iter.step_unit)
		z := max(iter.width, math.ceil(math.abs(x - iter.previous_x)))
		res = { x, x + z, y, y + iter.height }
		iter.previous_x = x
		ok = true
	}

	return
}

// draw an animated caret rect
caret_state_render :: proc(target: ^Render_Target, using state: ^Caret_State) {
	real_alpha := caret_state_real_alpha(state)
	motion_last_frame = false

	if caret_state_update_motion(state, false) {
		iter := motion_rect_init(rect, motion_last_x, motion_last_y, motion_count)

		for rect, step in motion_rect_iter(&iter) {
			r := rect_ftoi(rect)
			color := color_alpha(theme.caret, step * 0.25 * real_alpha)
			render_rect(target, r, color, 0)
		}

		// if pm_show() {
		// 	task := app_task_head()
		// 	xoff, yoff := cam_offsets(mode_panel_cam())
		// 	color := theme_task_text(task.state)
		// 	vert_off := DEFAULT_FONT_SIZE * TASK_SCALE / 2
		// 	power_mode_spawn_at(motion_last_x, motion_last_y + vert_off, xoff, yoff, 1, color)
		// }

		motion_last_frame = true
	} else {
		motion_last_x = f32(rect.l)
		motion_last_y = f32(rect.t)

		color := color_alpha(theme.caret, real_alpha)
		render_rect(target, rect, color, 0)
	}

	// skip trail rendering
	if motion_skip {
		motion_last_x = f32(rect.l)
		motion_last_y = f32(rect.t)
		motion_skip = false
	} else {
		animate_to(&motion_last_x, f32(rect.l), 4, 0.1)
		animate_to(&motion_last_y, f32(rect.t), 4, 0.1)
	}

	caret_state_increase_alpha(state)
}

caret_state_increase_alpha :: proc(using state: ^Caret_State) {
	if caret_state_update_alpha(state) {
		speed := visuals_animation_speed()

		if alpha_forwards {
			if alpha <= 1 {
				alpha += gs.dt * speed
			} else {
				alpha_forwards = false
			}
		} else {
			if alpha >= 0 {
				alpha -= gs.dt * speed
			} else {
				alpha_forwards = true
			}
		}
	}
}

render_caret_and_outlines :: proc(target: ^Render_Target, clip: RectI) {
	if app_filter_empty() {
		app.caret.outline_goal = RECT_LERP_INIT
		app.caret.motion_skip = true
		return
	}

	// render carets / task outlines
	low, high := task_low_and_high()
	if low == high {
		task := app_task_head()
		render_push_clip(target, clip)
		real_alpha := caret_state_real_alpha(&app.caret)

		// render the caret
		skip := app.caret.motion_skip
		caret_state_render(target, &app.caret)

		task_rect := task.element.bounds
		app.caret.outline_current = rect_itof(task_rect)
		
		if skip {
			app.caret.outline_goal = rect_itof(task_rect)
		} else {
			rect_animate_to(&app.caret.outline_goal, task_rect, 4, 0.1)
		}

		if caret_state_update_outline(&app.caret) {
			rect := rect_ftoi(app.caret.outline_goal)
			color := color_alpha(theme.caret, real_alpha)
			render_rect_outline(target, rect, color)
		} else {
			// single outline
			render_rect_outline(target, task.element.bounds, color_alpha(theme.caret, real_alpha))
		}
	} else {
		render_push_clip(target, clip)
		shadow_color := color_alpha(theme.background[0], app.task_shadow_alpha)

		app.caret.outline_goal = RECT_LERP_INIT
		app.caret.motion_skip = true

		// shadow first
		for i in 0..<low {
			task := app_task_filter(i)
			render_rect(target, task.element.bounds, shadow_color)
		}

		// no shadow inbetween
		range := f32(high - low + 1)
		sign: f32 = app.task_head > app.task_tail ? 1 : -1
		count := range if sign == -1 else 0
		real_alpha := caret_state_real_alpha(&app.caret)
		caret_state_increase_alpha(&app.caret)

		// outline selected region
		for i in low..<high + 1 {
			task := app_task_filter(i)
			count += sign
			value := count / range
			color := i == app.task_head ? theme.caret : theme.text_default
			// value offset slightly + fade with lower fading more
			color.a = u8(min((value + 0.25) * ((real_alpha + value) * 0.5) * 255, 255))
			render_rect_outline(target, task.element.bounds, color)
		}

		// shadow last
		for i in high + 1..<len(app.pool.filter) {
			task := app_task_filter(i)
			render_rect(target, task.element.bounds, shadow_color)
		}
	}
}

// wether or not to update the focus alpha
app_focus_alpha_animate :: proc() -> int {
	if app.focus.root != nil {
		return app.focus.alpha <= 1 ? 1 : 0
	} else {
		return app.focus.alpha >= 0 ? -1 : 0
	}
}

app_focus_alpha_update :: proc() {
	direction := app_focus_alpha_animate()
	
	if direction != 0 {
		if visuals_use_animations() {
			speed := visuals_animation_speed()
			app.focus.alpha += f32(direction) * gs.dt * speed * 8
		} else {
			// quickly set the alpha manually
			if direction == 1 {
				app.focus.alpha = 1
			} else {
				app.focus.alpha = 0
			}
		}
	}
}

// get focus slice or 
app_focus_list :: proc() -> (res: []int) {
	if app.focus.root != nil {
		start := app.focus.root.filter_index
		end := app.focus.root.filter_index + 1

		if !app.focus.root.filter_folded {
			end += len(app.focus.root.filter_children)
		}

		res = app.pool.filter[start:end]
	} else {
		res = app.pool.filter[:]
	}

	return
}

// get start/end of the focus range
app_focus_bounds :: proc(){
	if app.focus.root != nil {
		app.focus.start = app.focus.root.filter_index
		app.focus.end = app.focus.root.filter_index + 1

		if !app.focus.root.filter_folded {
			app.focus.end += len(app.focus.root.filter_children)
		}
	}
}