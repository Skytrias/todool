package src

import "core:fmt"
import "core:math"
import "core:unicode"
import "core:unicode/utf8"
import "core:mem"
import "core:log"
import "core:strings"
import "core:intrinsics"
import "core:time"
import "../cutf8"
import "heimdall:fontstash"

//////////////////////////////////////////////
// normal text box
//////////////////////////////////////////////

// box undo grouping
// 		if we leave the box or task_head it will force group the changes
// 		if timeout of 500ms happens
// 		if shortcut by undo / redo invoke

// NOTE: undo / redo storage of box items could be optimized in memory storage
// e.g. store only one item box header, store commands that happen internally in the byte array

// TODO use continuation bytes info to advance/backwards through string?

BOX_CHANGE_TIMEOUT :: time.Millisecond * 300
BOX_START :: 1
BOX_END :: 2
BOX_SELECT_ALL :: 3

Box :: struct {
	ss: Small_String, // actual data
	head, tail: int,
	
	// word selection state
	word_selection_started: bool,
	word_start: int,
	word_end: int,

	// line selection state
	line_selection_started: bool,
	line_selection_start: int,
	line_selection_end: int,
	line_selection_start_y: int,

	// when the latest change happened
	change_start: time.Tick,
	last_was_space: bool,

	// rendered glyph start & end
	rendered_glyphs: []Rendered_Glyph,
	// wrappped lines start / end
	wrapped_lines: []string,
}

Text_Box :: struct {
	using element: Element,
	using box: Box,
	scroll: f32,
	codepoint_numbers_only: bool,
	um: ^Undo_Manager,
}

Task_Box :: struct {
	using element: Element,
	using box: Box,
	text_color: Color,
}

//////////////////////////////////////////////
// Task Box
//////////////////////////////////////////////

text_box_message :: proc(element: ^Element, msg: Message, di: int, dp: rawptr) -> int {
	box := cast(^Text_Box) element

	#partial switch msg {
		case .Layout: {
			wrapped_lines_push_forced(ss_string(&box.ss), &box.wrapped_lines)
		}

		case .Get_Cursor: {
			return int(Cursor.IBeam)
		}

		case .Box_Text_Color: {
			color := cast(^Color) dp
			focused := element.window.focused == element
			hovered := element.window.hovered == element
			pressed := element.window.pressed == element
			color^ = hovered || pressed || focused ? theme.text_default : theme.text_blank
		}

		case .Paint_Recursive: {
			focused := element.window.focused == element

			target := element.window.target
			text := ss_string(&box.ss)
			scaled_size := fcs_element(element)
			color: Color
			element_message(element, .Box_Text_Color, 0, &color)
			fcs_color(color)
			fcs_ahv(.LEFT, .MIDDLE)
			caret_x: int
			text_bounds := element.bounds
			text_bounds.l += int(TEXT_PADDING * SCALE)
			text_bounds.r -= int(TEXT_PADDING * SCALE)
			text_width := string_width(text)

			// handle scrolling
			{
				// clamp scroll(?)
				if box.scroll > f32(text_width - rect_width(text_bounds)) {
					box.scroll = f32(text_width - rect_width(text_bounds))
				}

				if box.scroll < 0 {
					box.scroll = 0
				}

				caret_x, _ = wrap_layout_caret(&gs.fc, box.wrapped_lines[:], box.head)
				caret_x -= int(box.scroll)

				// check caret x
				if caret_x < 0 {
					box.scroll = f32(caret_x) + box.scroll
				} else if caret_x > rect_width(text_bounds) {
					box.scroll = f32(caret_x - rect_width(text_bounds)) + box.scroll + 1
				}

				caret_x, _ = wrap_layout_caret(&gs.fc, box.wrapped_lines[:], box.head)
			}

			if focused {
				render_rect(target, element.bounds, theme_panel(.Front), ROUNDNESS)
				// selection & caret
				x := text_bounds.l - int(box.scroll)
				y := text_bounds.t + rect_height_halfed(text_bounds) - scaled_size / 2
				box_render_selection(target, box, x, y, theme.caret_selection)
			}

			render_rect_outline(target, element.bounds, color)
			text_bounds.l -= int(box.scroll)

			// draw each wrapped line
			render_string_rect_store(target, text_bounds, text, &box.rendered_glyphs)

			if focused && box.head != box.tail {
				// recolor selected glyphs
				ds: cutf8.Decode_State
				text := ss_string(&box.ss)
				low, high := box_low_and_high(box)
				back_color := theme_panel(.Front)

				for codepoint, i in cutf8.ds_iter(&ds, text) {
					if (low <= i && i < high) {
						glyph := box.rendered_glyphs[i]
						
						for v in &glyph.vertices {
							v.color = back_color
						}
					}
				}
			}

			if focused {
				// selection := 

				x := text_bounds.l
				y := text_bounds.t + rect_height_halfed(text_bounds) - scaled_size / 2
				caret := rect_wh(
					x + caret_x,
					y,
					int(2 * SCALE),
					scaled_size,
				)
				render_rect(target, caret, theme.caret, 0)
			}
		}

		case .Key_Combination: {
			combo := (cast(^string) dp)^
			assert(box.um != nil)
			kbox = { box, box.um, element, false, false }
			handled := false

			if keymap_combo_execute(&box.window.keymap_box, combo) {
				handled = !kbox.failed
			}

			if handled {
				element_repaint(element)
			}

			return int(handled)
		}

		case .Update: {
			if di == UPDATE_FOCUS_GAINED {
				box_move_end_simple(box)
			}

			element_repaint(element)	
		}

		case .Unicode_Insertion: {
			codepoint := (cast(^rune) dp)^

			// skip non numbers or -
			if box.codepoint_numbers_only && !(codepoint == '-' || unicode.is_number(codepoint)) {
				return 1
			} 

			assert(box.um != nil)
			if box_insert(box.um, element, box, codepoint, false) {
				element_repaint(element)
				return 1
			}

			return 0
		}

		case .Box_Set_Caret: {
			box_set_caret_dp(box, di, dp)
		}

		case .Left_Down: {
			element_focus(element.window, element)

			old_tail := box.tail
			scaled_size := efont_size(element)
			fcs_ahv(.LEFT, .TOP)
			element_box_mouse_selection(box, box, di, false, box.scroll, scaled_size)

			if element.window.shift && di == 0 {
				box.tail = old_tail
			}

			return 1
		}

		case .Mouse_Drag: {
			if element.window.pressed_button == MOUSE_LEFT {
				scaled_size := efont_size(element)
				fcs_ahv(.LEFT, .TOP)
				element_box_mouse_selection(box, box, di, true, box.scroll, scaled_size)
				element_repaint(box)
			}
		}

		case .Get_Width: {
			return int(SCALE * 100)
		}

		case .Get_Height: {
			return efont_size(element) + int(TEXT_MARGIN_VERTICAL * SCALE)
		}
	}

	return 0
}

text_box_init :: proc(
	parent: ^Element, 
	flags: Element_Flags, 
	text := "",
	index_at := -1,
	allocator := context.allocator,
) -> (res: ^Text_Box) {
	flags := flags
	flags |= { .Tab_Stop }
	res = element_init(Text_Box, parent, flags, text_box_message, allocator, index_at)
	ss_set_string(&res.box.ss, text)
	box_move_end_simple(&res.box)
	return	
}

//////////////////////////////////////////////
// Task Box
//////////////////////////////////////////////

// just paints the text based on text color
task_box_paint_default_selection :: proc(box: ^Task_Box, scaled_size: int) {
	focused := box.window.focused == box
	target := box.window.target

	color: Color
	element_message(box, .Box_Text_Color, 0, &color)

	fcs_ahv(.LEFT, .TOP)
	fcs_color(color)

	group := &target.groups[len(target.groups) - 1]
	state := fontstash.__getState(&gs.fc)
	q: fontstash.Quad
	codepoint_index: int
	back_color := color_alpha(theme_panel(.Front), 1)
	low, high := box_low_and_high(box)

	// draw each wrapped line
	y_offset: int
	rendered_glyph_start()
	for wrap_line, i in box.wrapped_lines {
		iter := fontstash.TextIterInit(&gs.fc, f32(box.bounds.l), f32(box.bounds.t + y_offset), wrap_line)

		for fontstash.TextIterNext(&gs.fc, &iter, &q) {
			rglyph := rendered_glyph_push(iter.x, iter.y, iter.codepoint)
			state.color = low <= codepoint_index && codepoint_index < high ? back_color : color
			render_glyph_quad_store(target, group, state, &q, rglyph)
			codepoint_index += 1 
		}

		y_offset += scaled_size
	}
	rendered_glyph_gather(&box.rendered_glyphs)

	fcs_color(color)
}

// just paints the text based on text color
task_box_paint_default :: proc(box: ^Task_Box, scaled_size: int) {
	focused := box.window.focused == box
	target := box.window.target

	color: Color
	element_message(box, .Box_Text_Color, 0, &color)

	fcs_ahv(.LEFT, .TOP)
	fcs_color(color)

	// draw each wrapped line
	rendered_glyph_start()
	y: int
	for wrap_line, i in box.wrapped_lines {
		render_string_store(target, box.bounds.l, box.bounds.t + y, wrap_line)
		y += scaled_size
	}
	rendered_glyph_gather(&box.rendered_glyphs)
}

// test sosososo test

task_box_message :: proc(element: ^Element, msg: Message, di: int, dp: rawptr) -> int {
	task_box := cast(^Task_Box) element

	#partial switch msg {
		case .Get_Cursor: {
			return int(Cursor.IBeam)
		}

		case .Box_Text_Color: {
			color := cast(^Color) dp
			color^ = theme_task_text(.Normal)
		}

		case .Key_Combination: {
			combo := (cast(^string) dp)^
			handled := false
			kbox = { task_box, &app.um_task, element, true, false }

			if keymap_combo_execute(&task_box.window.keymap_box, combo) {
				handled = !kbox.failed
			}

			if handled {
				element_repaint(element)
			}

			return int(handled)
		}

		case .Update: {
			element_repaint(element)	
		}

		case .Unicode_Insertion: {
			codepoint := (cast(^rune) dp)^

			if box_insert(&app.um_task, element, task_box, codepoint, true) {
				power_mode_issue_spawn()
				element_repaint(element)
				return 1
			}

			return 0
		}

		case .Box_Set_Caret: {
			box_set_caret_dp(task_box, di, dp)
		}
	}

	return 0
}

task_box_init :: proc(
	parent: ^Element, 
	flags: Element_Flags, 
	text := "", 
	allocator := context.allocator,
	index_at := -1,
) -> (res: ^Task_Box) {
	res = element_init(Task_Box, parent, flags, task_box_message, allocator, index_at)
	// box_init(&res.box)
	ss_set_string(&res.box.ss, text)
	box_move_end_simple(&res.box)
	return
}

//////////////////////////////////////////////
// Box input
//////////////////////////////////////////////

// copy selection to window storage
box_copy_selection :: proc(window: ^Window, box: ^Box) -> (found: bool) {
	if box.head == box.tail {
		return
	}

	ds: cutf8.Decode_State
	low, high := box_low_and_high(box)
	selection, ok := cutf8.ds_string_selection(&ds, ss_string(&box.ss), low, high)
	
	if ok {
		clipboard_set_with_builder(selection)
		found = true
	}

	return
}

box_paste :: proc(
	manager: ^Undo_Manager,
	element: ^Element, 
	box: ^Box,
	msg_by_task: bool,
) -> (found: bool) {
	if clipboard_has_content() {
		text := clipboard_get_with_builder_till_newline()

		// only when from task, accept pngs/links
		if msg_by_task {
			if strings.has_suffix(text, ".png") {
				task := app_task_head()
				handle := image_load_push(text)
				
				if handle != nil {
					task_set_img(task, handle)
					found = true
					return
				}
			}

			// TODO could be sped up probably
			if strings.has_prefix(text, "https://") || strings.has_prefix(text, "http://") {
				task := app_task_head()
				task_set_link(task, text)
				found = true
				return
			}
		}

		box_replace(manager, element, box, text, 0, true, msg_by_task)
		found = true
	}

	return
}

// commit and reset changes if any
box_force_changes :: proc(manager: ^Undo_Manager, box: ^Box) -> bool {
	if box.change_start != {} {
		box.change_start = {}
		undo_group_end(manager)
		return true
	}

	return false
}

// check if changes are above timeout limit and commit 
box_check_changes :: proc(manager: ^Undo_Manager, box: ^Box) {
	if box.change_start != {} {
		diff := time.tick_since(box.change_start)

		if diff > BOX_CHANGE_TIMEOUT {
			undo_group_end(manager)
		}
	} 

	box.change_start = time.tick_now()
}

// insert a single rune with undoable
box_insert :: proc(
	manager: ^Undo_Manager,
	element: ^Element,
	box: ^Box, 
	codepoint: rune,
	msg_by_task: bool,
) -> bool {
	if box.head != box.tail {
		box_replace(manager, element, box, "", 0, true, msg_by_task)
	}
	
	if ss_full(&box.ss) {
		return false
	}

	count := cutf8.count(ss_string(&box.ss))
	skip_check: bool
	was_space := codepoint == ' '

	// set undo state to break at first whitespace
	if was_space || box.last_was_space {
		diff := codepoint != ' '

		if !box.last_was_space || diff {
			skip_check = box_force_changes(manager, box)
		}
	}
	box.last_was_space = was_space

	if !skip_check {
		box_check_changes(manager, box)
	}

	if msg_by_task {
		task_head_tail_push(manager)
	}

	// push at end
	if box.head == count {
		item := Undo_Item_Box_Rune_Append {
			box = box,
			codepoint = codepoint,
		}
		undo_box_rune_append(manager, &item)
	} else {
		item := Undo_Item_Box_Rune_Insert_At {
			box = box,
			codepoint = codepoint,
			index = box.head,
		}
		undo_box_rune_insert_at(manager, &item)
	}

	element_message(element, .Value_Changed)
	return true
}

// utf8 based removal of selection & replacing selection with text
box_replace :: proc(
	manager: ^Undo_Manager,
	element: ^Element,
	box: ^Box, 
	text: string, 
	forced_selection: int, 
	send_changed_message: bool,
	msg_by_task: bool,
) {
	box_check_changes(manager, box)
	
	if msg_by_task {
		task_head_tail_push(manager)
	}

	// remove selection
	if box.head != box.tail {
		low, high := box_low_and_high(box)

		// on single removal just do remove at
		if high - low == 1 {
			item := Undo_Item_Box_Rune_Remove_At { 
				box,
				low,
			}

			undo_box_rune_remove_at(manager, &item)
			// log.info("remove selection ONE")
		} else {
			item := Undo_Item_Box_Remove_Selection { 
				box,
				box.head,
				box.tail,
				forced_selection,
			}
			undo_box_remove_selection(manager, &item)
		}
	
		if send_changed_message {
			element_message(element, .Value_Changed)
		}
	} 

	if len(text) != 0 && !ss_full(&box.ss) {
		ds: cutf8.Decode_State
		insert_count: int

		for codepoint, i in cutf8.ds_iter(&ds, text) {
			if ss_insert_at(&box.ss, box.head + i, codepoint) {
				insert_count += 1
			} else {
				break
			}
		}

		old_head := box.head
		box.head += insert_count
		box.tail = box.head

		item := Undo_Item_Box_Remove_Selection { 
			box,
			old_head,
			old_head + insert_count,
			0,
		}
		undo_push(manager, undo_box_remove_selection, &item, size_of(Undo_Item_Box_Remove_Selection))
	}
}

box_clear :: proc(box: ^Box, send_changed_message: bool) {
	ss_clear(&box.ss)
	box.head = 0
	box.tail = 0
}

box_check_shift :: proc(box: ^Box, shift: bool) {
	if !shift {
		box.tail = box.head
	}
}

Caret_Translation :: enum {
	Start,	
	End,	
	Character_Left,	
	Character_Right,	
	Word_Left,	
	Word_Right,	
}

box_translate_caret :: proc(box: ^Box, translation: Caret_Translation, shift: bool) {
	translation_backwards :: proc(translation: Caret_Translation) -> bool {
		#partial switch translation {
			case .Start, .Character_Left, .Word_Left: return true
			case: return false
		}
	}
	
	backwards := translation_backwards(translation)

	// on non shift & selection, stop selection
	if !shift && box.head != box.tail {
		if box.head < box.tail {
			if backwards {
				box.tail = box.head
			} else {
				box.head = box.tail
			}
		} else {
			if backwards {
				box.head = box.tail
			} else {
				box.tail = box.head
			}
		}

		return
	}

	runes := ss_to_runes_temp(&box.ss)
	pos := box.head

	switch translation {
		case .Start: {
			pos = 0
		}

		case .End: {
			pos = len(runes)
		}

		case .Character_Left: {
			pos -= 1
		}

		case .Character_Right: {
			pos += 1
		}

		case .Word_Left: {
			for pos > 0 && runes[pos - 1] == ' ' {
				pos -= 1
			}

			for pos > 0 && runes[pos - 1] != ' ' {
				pos -= 1
			}
		}

		case .Word_Right: {
			for pos < len(runes) && runes[pos] == ' ' {
				pos += 1
			}

			for pos < len(runes) && runes[pos] != ' ' {
				pos += 1
			}
		}
	}

	box.head = clamp(pos, 0, len(runes))
}

box_set_caret_dp :: proc(box: ^Box, di: int, dp: rawptr) {
	switch di {
		case 0: {
			goal := cast(^int) dp
			box.head = goal^
			box.tail = goal^
		}

		case BOX_START: {
			box.head = 0
			box.tail = 0
		}

		case BOX_END: {
			length := cutf8.count(ss_string(&box.ss))
			box.head = length
			box.tail = box.head
		}

		case BOX_SELECT_ALL: {
			length := cutf8.count(ss_string(&box.ss))
			box.tail = 0
			box.head = length
		}

		case: {
			log.info("UI: text box unsupported caret setting")
		}
	}
}

box_low_and_high :: proc(box: ^Box) -> (low, high: int) {
	low = min(box.head, box.tail)
	high = max(box.head, box.tail)
	return
}

//////////////////////////////////////////////
// Box render
//////////////////////////////////////////////

// layout textual caret
box_layout_caret :: proc(
	box: ^Box,
	scaled_size: int,
	scaling: f32,
	x, y: int,
) -> RectI {
	caret_x, line := wrap_layout_caret(&gs.fc, box.wrapped_lines, box.head)
	width := int(2 * scaling)
	return rect_wh(
		x + caret_x,
		y + line * scaled_size,
		width,
		scaled_size,
	)
}

box_render_selection :: proc(
	target: ^Render_Target, 
	box: ^Box,
	x, y: int,
	color: Color,
) {
	if box.head == box.tail {
		return
	}

	// back_color := color_alpha(theme_panel(.Front), 1)
	state := wrap_state_init(&gs.fc, box.wrapped_lines, box.head, box.tail)
	scaled_size := f32(state.isize / 10)

	for wrap_state_iter(&gs.fc, &state) {
		translated := RectI {
			x + int(state.x_from),
			x + int(state.x_to),
			y + int(f32(state.y - 1) * scaled_size),
			y + int(f32(state.y) * scaled_size),
		}

		render_rect(target, translated, color, 0)
	}
}

// NOTE careful with font AH/AV alignment
// mouse selection
element_box_mouse_selection :: proc(
	element: ^Element,
	b: ^Box,
	clicks: int,
	dragging: bool,
	x_offset: f32,
	scaled_size: int,
) -> (found: bool) {
	// state used in word / single mouse selection
	Mouse_Character_Selection :: struct {
		relative_x, relative_y: int,
		old_x, x: int,
		old_y, y: int,	
		codepoint_offset: int, // offset after a text line ended in rune codepoints ofset
		width_codepoint: int, // global to store width
	}
	mcs: Mouse_Character_Selection

	// single character collision
	mcs_check_single :: proc(
		using mcs: ^Mouse_Character_Selection,
		b: ^Box,
		codepoint_index: int,
		dragging: bool,
	) -> bool {
		if relative_x < x && 
			old_y < relative_y && 
			relative_y < y {
			goal := ((x - old_x) / 2 + old_x)
			comp := relative_x > goal
			off := int(comp)

			if !dragging {
				b.head = codepoint_index + off
				b.tail = codepoint_index + off
			} else {
				b.head = codepoint_index + off
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
	relative_x = element.window.cursor_x - element.bounds.l + int(x_offset)
	relative_y = element.window.cursor_y - element.bounds.t
	// fmt.eprintln(relative_x, element.window.cursor_x, element.bounds.l, x_offset)

	ctx := &gs.fc
	clicks := clicks % 3
	// clicks = 0

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

			iter := fontstash.TextIterInit(ctx, 0, 0, text)

			// loop through codepoints
			index: int
			quad: fontstash.Quad
			for fontstash.TextIterNext(ctx, &iter, &quad) {
				old_x = x
				x = int(iter.nextx)

				// check mouse collision
				if mcs_check_single(&mcs, b, index + codepoint_offset, dragging) {
					codepoint_offset += iter.codepointCount
					break search_line
				}

				index += 1
			}

			x += scaled_size
			mcs_check_single(&mcs, b, iter.codepointCount + codepoint_offset, dragging)
			codepoint_offset += iter.codepointCount

			// do line end?
			if relative_x > x && !dragging {
				b.head = codepoint_offset
				b.tail = codepoint_offset
				break search_line
			}

			old_y = y
		}

		mcs_check_line_last(&mcs, b)

		// NOTE safety clamp in case we extended too far
		b.head = min(b.head, codepoint_offset)
		if !dragging {
			b.tail = min(b.tail, codepoint_offset)
		}
	} else {
		if clicks == 1 {
			// TODO misses the first character if its not proper alpha

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
				x_word_start: int
				x_whitespace_start: int = -1

				// clamp to left
				if relative_x < 0 && relative_y < old_y && b.word_selection_started {
					b.head = codepoint_offset
					break
				}

				// loop through codepoints
				iter := fontstash.TextIterInit(ctx, 0, 0, text)
				index: int
				quad: fontstash.Quad
				for fontstash.TextIterNext(ctx, &iter, &quad) {
					// check for word completion
					if index_word_start != -1 && iter.codepoint == ' ' {
						old_x = x_word_start
						mcs_check_word(&mcs, b, codepoint_offset + index_word_start, codepoint_offset + index)
						index_word_start = -1
					}
					
					// check for starting codepoint being letter
					if index_word_start == -1 && !unicode.is_space(iter.codepoint) {
						index_word_start = index
						x_word_start = x
					}

					// check for space word completion
					if index_whitespace_start != -1 && !unicode.is_space(iter.codepoint) {
						old_x = x_whitespace_start
						mcs_check_word(&mcs, b, codepoint_offset + index_whitespace_start, codepoint_offset + index)
						index_whitespace_start = -1
					}

					// check for starting whitespace being letter
					if index_whitespace_start == -1 && iter.codepoint == ' ' {
						index_whitespace_start = index
						x_whitespace_start = x
					}

					// set new position
					x = int(iter.nextx)
					codepoint_last = iter.codepoint
					index += 1
				}

				// finish whitespace and end letter
				if index_whitespace_start != -1 && codepoint_last == ' ' {
					old_x = x_whitespace_start
					mcs_check_word(&mcs, b, codepoint_offset + index_whitespace_start, codepoint_offset + iter.codepointCount)
				}

				// finish end word
				if index_word_start != -1 && !unicode.is_space(codepoint_last) {
					old_x = x_word_start
					mcs_check_word(&mcs, b, codepoint_offset + index_word_start, codepoint_offset + iter.codepointCount)
				}

				old_y = y
				codepoint_offset += iter.codepointCount
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
// undo/redo box edits
//////////////////////////////////////////////

Undo_Item_Box_Rune_Append :: struct {
	box: ^Box,
	codepoint: rune,
}

Undo_Item_Box_Rune_Pop :: struct {
	box: ^Box,
	// just jump back to saved pos instead of calc rune size
	head: int,
	tail: int,
}

undo_box_rune_append :: proc(manager: ^Undo_Manager, item: rawptr) {
	data := cast(^Undo_Item_Box_Rune_Append) item
	ss_append(&data.box.ss, data.codepoint)
	item := Undo_Item_Box_Rune_Pop { data.box, data.box.head, data.box.head }
	data.box.head += 1
	data.box.tail += 1
	undo_push(manager, undo_box_rune_pop, &item, size_of(Undo_Item_Box_Rune_Pop))
}

undo_box_rune_pop :: proc(manager: ^Undo_Manager, item: rawptr) {
	data := cast(^Undo_Item_Box_Rune_Pop) item
	// codepoint, codepoint_width := strings.pop_rune(&data.box.builder)
	codepoint, _ := ss_pop(&data.box.ss)
	data.box.head = data.head
	data.box.tail = data.tail
	item := Undo_Item_Box_Rune_Append {
		box = data.box,
		codepoint = codepoint,
	}
	undo_push(manager, undo_box_rune_append, &item, size_of(Undo_Item_Box_Rune_Append))
}

Undo_Item_Box_Rune_Insert_At :: struct {
	box: ^Box,
	index: int,
	codepoint: rune,
}

Undo_Item_Box_Rune_Remove_At :: struct {
	box: ^Box,
	index: int,
}

undo_box_rune_insert_at :: proc(manager: ^Undo_Manager, item: rawptr) {
	data := cast(^Undo_Item_Box_Rune_Insert_At) item
	ss_insert_at(&data.box.ss, data.index, data.codepoint)

	// increase head & tail always
	data.box.head += 1
	data.box.tail += 1

	// create reversal remove at
	item := Undo_Item_Box_Rune_Remove_At {
		box = data.box,
		index = data.index,
	}
	undo_push(manager, undo_box_rune_remove_at, &item, size_of(Undo_Item_Box_Rune_Remove_At))
}

undo_box_rune_remove_at :: proc(manager: ^Undo_Manager, item: rawptr) {
	data := cast(^Undo_Item_Box_Rune_Remove_At) item

	removed_codepoint, _ := ss_remove_at(&data.box.ss, data.index)

	// set the head and tail to the removed location
	data.box.head = data.index
	data.box.tail = data.index

	// create reversal to insert at
	item := Undo_Item_Box_Rune_Insert_At {
		box = data.box,
		index = data.index,
		codepoint = removed_codepoint,
	}
	undo_push(manager, undo_box_rune_insert_at, &item, size_of(Undo_Item_Box_Rune_Insert_At))
}

Undo_Item_Box_Remove_Selection :: struct {
	box: ^Box,
	head: int,
	tail: int,
	forced_selection: int, // determines how head & tail are set
}

undo_box_remove_selection :: proc(manager: ^Undo_Manager, item: rawptr) {
	data := cast(^Undo_Item_Box_Remove_Selection) item

	ss := &data.box.ss
	temp: [SS_SIZE]u8
	low := min(data.head, data.tail)
	high := max(data.head, data.tail)
	temp_size, _ := ss_remove_selection(ss, low, high, temp[:])

	// create insert already	
	item := Undo_Item_Box_Insert_String {
		data.box,
		data.head,
		data.tail,
		data.forced_selection,
		temp_size,
	}

	// push upfront to instantly write to the popped runes section
	bytes := undo_push(
		manager, 
		undo_box_insert_string, 
		&item,
		size_of(Undo_Item_Box_Insert_String) + temp_size,
	)

	// copy into the byte space
	temp_root := cast(^u8) &bytes[size_of(Undo_Item_Box_Insert_String)]
	mem.copy(temp_root, &temp[0], temp_size)

	// set to new location
	data.box.head = low
	data.box.tail = low
}

Undo_Item_Box_Insert_String :: struct {
	box: ^Box,
	head: int,
	tail: int,
	// determines how head & tail are set
	// 0 = not forced
	// 1 = forced from right
	// -1 = forced from left
	forced_selection: int,
	text_size: int, // upcoming text to read
}

undo_box_insert_string :: proc(manager: ^Undo_Manager, item: rawptr) {
	data := cast(^Undo_Item_Box_Insert_String) item
	ss := &data.box.ss

	low := min(data.head, data.tail)
	high := max(data.head, data.tail)

	// set based on forced selection 
	if data.forced_selection != 0 {
		set := data.forced_selection == 1 ? low : high
		data.box.head = clamp(set, 0, 255)
		data.box.tail = clamp(set, 0, 255)
	} else {
		data.box.head = data.head
		data.box.tail = data.tail
	}

	text_root := cast(^u8) (uintptr(item) + size_of(Undo_Item_Box_Insert_String))
	popped_text := strings.string_from_ptr(text_root, data.text_size)
	ss_insert_string_at(ss, low, popped_text)

	item := Undo_Item_Box_Remove_Selection { 
		data.box,
		data.head,
		data.tail,
		data.forced_selection,
	}
	undo_push(manager, undo_box_remove_selection, &item, size_of(Undo_Item_Box_Remove_Selection))
}

// Undo_Item_Box_Replace_String :: struct {
// 	// box: ^Box,
// 	ss: ^Small_String,
// 	head: int,
// 	tail: int,
// 	text_length: int,
// }

// undo_box_replace_string :: proc(manager: ^Undo_Manager, item: rawptr) {
// 	data := cast(^Undo_Item_Box_Replace_String) item

// 	fmt.eprintln("data", data)
// 	before_size, ok := ss_remove_selection(data.ss, data.head, data.tail, ss_temp_chars[:])
// 	assert(ok)

// 	out := Undo_Item_Box_Replace_String { 
// 		data.ss,
// 		data.head,
// 		data.tail,
// 		before_size,
// 	}
	
// 	fmt.eprintln("1", string(ss_temp_chars[:before_size]), before_size)
// 	output := undo_push(
// 		manager, 
// 		undo_box_replace_string, 
// 		&out, 
// 		size_of(Undo_Item_Box_Replace_String) + before_size,
// 	)
// 	text_root := cast(^u8) &output[size_of(Undo_Item_Box_Replace_String)]
// 	// text_root := cast(^u8) (uintptr(&output) + size_of(Undo_Item_Box_Replace_String))
// 	mem.copy(text_root, &ss_temp_chars[0], before_size)
// 	fmt.eprintln("~~~")

// 	item := item
// 	text_root = cast(^u8) (uintptr(item) + size_of(Undo_Item_Box_Replace_String))
// 	popped_text := strings.string_from_ptr(text_root, data.text_length)
// 	ss_insert_string_at(data.ss, data.head, popped_text)
// 	fmt.eprintln("2", popped_text)
// }

Undo_String_Uppercased_Content :: struct {
	ss: ^Small_String,
}

Undo_String_Uppercased_Content_Reset :: struct {
	ss: ^Small_String,
	byte_count: int, // content coming in the next bytes
}

Undo_String_Lowercased_Content :: struct {
	ss: ^Small_String,
}

Undo_String_Lowercased_Content_Reset :: struct {
	ss: ^Small_String,
	byte_count: int, // content coming in the next bytes
}

undo_box_uppercased_content_reset :: proc(manager: ^Undo_Manager, item: rawptr) {
	data := cast(^Undo_String_Uppercased_Content_Reset) item

	// reset and write old content
	text_root := cast(^u8) (uintptr(item) + size_of(Undo_String_Uppercased_Content_Reset))
	text_content := strings.string_from_ptr(text_root, data.byte_count)
	ss_set_string(data.ss, text_content)

	output := Undo_String_Uppercased_Content {
		ss = data.ss,
	}
	undo_push(manager, undo_box_uppercased_content, &output, size_of(Undo_String_Uppercased_Content))
}

undo_box_uppercased_content :: proc(manager: ^Undo_Manager, item: rawptr) {
	data := cast(^Undo_String_Uppercased_Content) item

	// generate output before mods
	output := Undo_String_Uppercased_Content_Reset {
		ss = data.ss,
		byte_count = int(data.ss.length),
	}
	bytes := undo_push(
		manager, 
		undo_box_uppercased_content_reset, 
		&output, 
		size_of(Undo_String_Uppercased_Content_Reset) + output.byte_count,
	)

	// write actual text content
	text_root := cast(^u8) &bytes[size_of(Undo_String_Uppercased_Content_Reset)]
	mem.copy(text_root, &data.ss.buf[0], output.byte_count)

	// write uppercased
	ss_uppercased_string(data.ss)
}

undo_box_lowercased_content_reset :: proc(manager: ^Undo_Manager, item: rawptr) {
	data := cast(^Undo_String_Lowercased_Content_Reset) item

	// reset and write old content
	text_root := cast(^u8) (uintptr(item) + size_of(Undo_String_Lowercased_Content_Reset))
	text_content := strings.string_from_ptr(text_root, data.byte_count)
	ss_set_string(data.ss, text_content)

	output := Undo_String_Lowercased_Content {
		ss = data.ss,
	}
	undo_push(manager, undo_box_lowercased_content, &output, size_of(Undo_String_Lowercased_Content))
}

undo_box_lowercased_content :: proc(manager: ^Undo_Manager, item: rawptr) {
	data := cast(^Undo_String_Lowercased_Content) item

	// generate output before mods
	output := Undo_String_Lowercased_Content_Reset {
		ss = data.ss,
		byte_count = int(data.ss.length),
	}
	bytes := undo_push(
		manager, 
		undo_box_lowercased_content_reset, 
		&output, 
		size_of(Undo_String_Lowercased_Content_Reset) + output.byte_count,
	)

	// write actual text content
	text_root := cast(^u8) &bytes[size_of(Undo_String_Lowercased_Content_Reset)]
	mem.copy(text_root, &data.ss.buf[0], output.byte_count)

	// write lowercased
	ss_lowercased_string(data.ss)
}

Undo_Item_Box_Head_Tail :: struct {
	box: ^Box,
	head: int,
	tail: int,
}

undo_box_head_tail :: proc(manager: ^Undo_Manager, item: rawptr) {
	data := cast(^Undo_Item_Box_Head_Tail) item
	old_head := data.box.head
	old_tail := data.box.tail
	data.box.head = data.head
	data.box.tail = data.tail
	data.head = old_head
	data.tail = old_tail
	undo_push(manager, undo_box_head_tail, item, size_of(Undo_Item_Box_Head_Tail))
}

box_head_tail_push :: proc(manager: ^Undo_Manager, box: ^Box) {
	item := Undo_Item_Box_Head_Tail {
		box,
		box.head,
		box.tail,
	}
	undo_push(manager, undo_box_head_tail, &item, size_of(Undo_Item_Box_Head_Tail))
}

// state to pass
KBox :: struct {
	box: ^Box,
	um: ^Undo_Manager,
	element: ^Element,
	by_task: bool,
	failed: bool, // result that can be checked
}

// local state used by kbox commands since they need a bit of state
kbox: KBox

// moves the caret to the left | SHIFT for selection | CTRL for extended moves
comment_kbox_move_left :: "moves the caret to the left | SHIFT for selection | CTRL for extended moves"
kbox_move_left :: proc(du: u32) {
	ctrl, shift := du_ctrl_shift(du)
	move: Caret_Translation = ctrl ? .Word_Left : .Character_Left
	box_translate_caret(kbox.box, move, shift)
	box_check_shift(kbox.box, shift)
}

comment_kbox_move_right :: "moves the caret to the right | SHIFT for selection | CTRL for extended moves"
kbox_move_right :: proc(du: u32) {
	ctrl, shift := du_ctrl_shift(du)
	move: Caret_Translation = ctrl ? .Word_Right : .Character_Right
	box_translate_caret(kbox.box, move, shift)
	box_check_shift(kbox.box, shift)		
}

comment_kbox_move_home :: "moves the caret to the start | SHIFT for selection"
kbox_move_home :: proc(du: u32) {
	shift := du_shift(du)
	kbox.box.head = 0
	box_check_shift(kbox.box, shift)
}

box_move_end_simple :: proc(box: ^Box) {
	length := cutf8.count(ss_string(&box.ss))
	box.head = length
	box_check_shift(box, false)
}

comment_kbox_move_end :: "moves the caret to the end | SHIFT for selection"
kbox_move_end :: proc(du: u32) {
	shift := du_shift(du)
	length := cutf8.count(ss_string(&kbox.box.ss))
	kbox.box.head = length
	box_check_shift(kbox.box, shift)
}

comment_kbox_select_all :: "selects all characters"
kbox_select_all :: proc(du: u32) {
	length := cutf8.count(ss_string(&kbox.box.ss))
	kbox.box.head = length
	kbox.box.tail = 0
}

comment_kbox_backspace :: "deletes the character to the left | CTRL for word based"
kbox_backspace :: proc(du: u32) {
	old_head := kbox.box.head
	old_tail := kbox.box.tail
	ctrl, shift := du_ctrl_shift(du)

	// skip none
	if kbox.box.head == 0 && kbox.box.tail == 0 {
		kbox.failed = true
		return
	}

	forced_selection: int
	if kbox.box.head == kbox.box.tail {
		move: Caret_Translation = ctrl ? .Word_Left : .Character_Left
		box_translate_caret(kbox.box, move, shift)
		forced_selection = -1
	}

	box_replace(kbox.um, kbox.element, kbox.box, "", forced_selection, true, kbox.by_task)

	// if nothing changes, dont handle
	if kbox.box.head == old_head && kbox.box.tail == old_tail {
		kbox.failed = true
		return
	} 

	if kbox.by_task {
		power_mode_issue_spawn()
	}
}

comment_kbox_delete :: "deletes the character to the right | CTRL for word based"
kbox_delete :: proc(du: u32) {
	ctrl, shift := du_ctrl_shift(du)

	forced_selection: int
	if kbox.box.head == kbox.box.tail {
		move: Caret_Translation = ctrl ? .Word_Right : .Character_Right
		box_translate_caret(kbox.box, move, shift)
		forced_selection = 1
	}

	old_length := int(kbox.box.ss.length)
	box_replace(kbox.um, kbox.element, kbox.box, "", forced_selection, true, kbox.by_task)

	// no change in length
	if old_length == int(kbox.box.ss.length) {
		kbox.failed = true
		return
	}

	if kbox.by_task {
		power_mode_issue_spawn()	
	}
}

comment_kbox_copy :: "pushes selection to the copy buffer"
kbox_copy :: proc(du: u32) {
	kbox.failed = !box_copy_selection(kbox.element.window, kbox.box)
	app.last_was_task_copy = false
}

comment_kbox_cut :: "cuts selection and pushes to the copy buffer"
kbox_cut :: proc(du: u32) {
	if kbox.box.tail != kbox.box.head {
		kbox.failed = !box_copy_selection(kbox.element.window, kbox.box)
		kbox_delete(0x00)
		app.last_was_task_copy = false
	} else {
		kbox.failed = true
	}
}

comment_kbox_paste :: "pastes text from copy buffer"
kbox_paste :: proc(du: u32) {
	if clipboard_check_changes() {
		app.last_was_task_copy = false
	}

	if !app.last_was_task_copy {
		kbox.failed = !box_paste(kbox.um, kbox.element, kbox.box, kbox.by_task)
	} else {
		kbox.failed = true
	}
}

kbox_undo_redo :: proc(du: u32, do_redo: bool) {
	if kbox.by_task {
		kbox.failed = true
		return
	}

	if !undo_is_empty(kbox.um, do_redo) {
		undo_invoke(kbox.um, do_redo)
		element_message(kbox.element, .Value_Changed)
		kbox.box.change_start = time.tick_now()
	} else {
		kbox.failed = true
	}
}

comment_kbox_undo :: "undos local changes"
kbox_undo :: proc(du: u32) { kbox_undo_redo(du, false) }
comment_kbox_redo :: "redos local changes"
kbox_redo :: proc(du: u32) { kbox_undo_redo(du, true) }