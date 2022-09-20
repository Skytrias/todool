package src

import "core:math"
import "core:unicode"
import "core:unicode/utf8"
import "core:mem"
import "core:log"
import "core:strings"
import "core:intrinsics"
import "core:time"
import "../cutf8"
import "../fontstash"

//////////////////////////////////////////////
// normal text box
//////////////////////////////////////////////

// box undo grouping
// 		if we leave the box or task_head it will force group the changes
// 		if timeout of 500ms happens
// 		if shortcut by undo / redo invoke

// NOTE: undo / redo storage of box items could be optimized in memory storage
// e.g. store only one item box header, store commands that happen internally in the byte array

BOX_CHANGE_TIMEOUT :: time.Millisecond * 300
BOX_START :: 1
BOX_END :: 2
BOX_SELECT_ALL :: 3

Box :: struct {
	builder: strings.Builder, // actual data
	wrapped_lines: [dynamic]string, // wrapped content
	head, tail: int,
	ds: cutf8.Decode_State,
	
	// word selection state
	word_selection_started: bool,
	word_start: int,
	word_end: int,

	// line selection state
	line_selection_started: bool,
	line_selection_start: int,
	line_selection_end: int,
	line_selection_start_y: f32,

	// when the latest change happened
	change_start: time.Tick,
}

box_init :: proc(box: ^Box, cap: int) {
	box.builder = strings.builder_make(0, cap)
	box.wrapped_lines = make([dynamic]string, 0, 4)
}

box_destroy :: proc(box: Box) {
	delete(box.wrapped_lines)
	delete(box.builder.buf)
}

Text_Box :: struct {
	using element: Element,
	using box: Box,
	scroll: f32,
	codepoint_numbers_only: bool,
}

Task_Box :: struct {
	using element: Element,
	using box: Box,
	text_color: Color,
}

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
	strings.write_rune(&data.box.builder, data.codepoint)
	item := Undo_Item_Box_Rune_Pop { data.box, data.box.head, data.box.head }
	data.box.head += 1
	data.box.tail += 1
	undo_push(manager, undo_box_rune_pop, &item, size_of(Undo_Item_Box_Rune_Pop))
}

undo_box_rune_pop :: proc(manager: ^Undo_Manager, item: rawptr) {
	data := cast(^Undo_Item_Box_Rune_Pop) item
	r, width := strings.pop_rune(&data.box.builder)
	data.box.head = data.head
	data.box.tail = data.tail
	item := Undo_Item_Box_Rune_Append {
		box = data.box,
		codepoint = r,
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

	// reset and convert to runes for ease
	runes := cutf8.ds_to_runes(&data.box.ds, strings.to_string(data.box.builder))
	b := &data.box.builder
	strings.builder_reset(b)
	
	// step through runes 1 by 1 and insert wanted one
	for i in 0..<len(runes) {
		if i == data.index {
			builder_append_rune(b, data.codepoint)
		}

		builder_append_rune(b, runes[i])
	}
	
	if data.index >= len(runes) {
		builder_append_rune(b, data.codepoint)
	}

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

	// reset and convert to runes for ease
	runes := cutf8.ds_to_runes(&data.box.ds, strings.to_string(data.box.builder))
	b := &data.box.builder
	strings.builder_reset(b)
	removed_codepoint: rune

	// step through runes 1 by 1 and remove the wanted index
	for i in 0..<len(runes) {
		if i == data.index {
			removed_codepoint = runes[i]
		} else {
			builder_append_rune(b, runes[i])
		}
	}

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

	b := &data.box.builder
	runes := cutf8.ds_to_runes(&data.box.ds, strings.to_string(b^))
	strings.builder_reset(b)

	low := min(data.head, data.tail)
	high := max(data.head, data.tail)
	removed_rune_amount := high - low

	// create insert already	
	item := Undo_Item_Box_Insert_Runes {
		data.box,
		data.head,
		data.tail,
		data.forced_selection,
		removed_rune_amount,
	}

	// push upfront to instantly write to the popped runes section
	bytes := undo_push(
		manager, 
		undo_box_insert_runes, 
		&item,
		size_of(Undo_Item_Box_Insert_Runes) + removed_rune_amount * size_of(rune),
	)

	// get runes byte location
	runes_root := cast(^rune) &bytes[size_of(Undo_Item_Box_Insert_Runes)]
	popped_runes := mem.slice_ptr(runes_root, removed_rune_amount)
	pop_index: int

	// pop of runes that are not wanted
	for i in 0..<len(runes) {
		if low <= i && i < high {
			popped_runes[pop_index] = runes[i]
			pop_index += 1
		} else {
			builder_append_rune(b, runes[i])
		}
	}	

	// set to new location
	data.box.head = low
	data.box.tail = low
}

Undo_Item_Box_Insert_Runes :: struct {
	box: ^Box,
	head: int,
	tail: int,
	// determines how head & tail are set
	// 0 = not forced
	// 1 = forced from right
	// 0 = forced from left
	forced_selection: int,
	rune_amount: int, // upcoming runes to read
}

undo_box_insert_runes :: proc(manager: ^Undo_Manager, item: rawptr) {
	data := cast(^Undo_Item_Box_Insert_Runes) item

	b := &data.box.builder
	runes := cutf8.ds_to_runes(&data.box.ds, strings.to_string(b^))
	strings.builder_reset(b)

	low := min(data.head, data.tail)
	high := max(data.head, data.tail)

	// set based on forced selection 
	if data.forced_selection != 0 {
		set := data.forced_selection == 1 ? low : high
		data.box.head = set
		data.box.tail = set
	} else {
		data.box.head = data.head
		data.box.tail = data.tail
	}

	runes_root := cast(^rune) (uintptr(item) + size_of(Undo_Item_Box_Insert_Runes))
	popped_runes := mem.slice_ptr(runes_root, data.rune_amount)
	// log.info("popped rune", runes_root, popped_runes, data.rune_amount, data.head, data.tail)

	for i in 0..<len(runes) {
		// insert popped content back to head location
		if i == low {
			for j in 0..<data.rune_amount {
				builder_append_rune(b, popped_runes[j])
			}
		}

		builder_append_rune(b, runes[i])
	}

	// append to end of string
	if low >= len(runes) {
		for j in 0..<data.rune_amount {
			builder_append_rune(b, popped_runes[j])
		}
	}

	item := Undo_Item_Box_Remove_Selection { 
		data.box,
		data.head,
		data.tail,
		data.forced_selection,
	}
	undo_push(manager, undo_box_remove_selection, &item, size_of(Undo_Item_Box_Remove_Selection))
}

Undo_Builder_Uppercased_Content :: struct {
	builder: ^strings.Builder,
}

Undo_Builder_Uppercased_Content_Reset :: struct {
	builder: ^strings.Builder,
	byte_count: int, // content coming in the next bytes
}

Undo_Builder_Lowercased_Content :: struct {
	builder: ^strings.Builder,
}

Undo_Builder_Lowercased_Content_Reset :: struct {
	builder: ^strings.Builder,
	byte_count: int, // content coming in the next bytes
}

undo_box_uppercased_content_reset :: proc(manager: ^Undo_Manager, item: rawptr) {
	data := cast(^Undo_Builder_Uppercased_Content_Reset) item

	// reset and write old content
	text_root := cast(^u8) (uintptr(item) + size_of(Undo_Builder_Uppercased_Content_Reset))
	text_content := strings.string_from_ptr(text_root, data.byte_count)
	strings.builder_reset(data.builder)
	strings.write_string(data.builder, text_content)

	output := Undo_Builder_Uppercased_Content {
		builder = data.builder,
	}
	undo_push(manager, undo_box_uppercased_content, &output, size_of(Undo_Builder_Uppercased_Content))
}

undo_box_uppercased_content :: proc(manager: ^Undo_Manager, item: rawptr) {
	data := cast(^Undo_Builder_Uppercased_Content) item

	// generate output before mods
	output := Undo_Builder_Uppercased_Content_Reset {
		builder = data.builder,
		byte_count = len(data.builder.buf),
	}
	bytes := undo_push(
		manager, 
		undo_box_uppercased_content_reset, 
		&output, 
		size_of(Undo_Builder_Uppercased_Content_Reset) + output.byte_count,
	)

	// write actual text content
	text_root := cast(^u8) &bytes[size_of(Undo_Builder_Uppercased_Content_Reset)]
	mem.copy(text_root, raw_data(data.builder.buf), output.byte_count)

	// write uppercased
	text := strings.to_string(data.builder^)
	builder_write_uppercased_string(data.builder, text)
}

undo_box_lowercased_content_reset :: proc(manager: ^Undo_Manager, item: rawptr) {
	data := cast(^Undo_Builder_Lowercased_Content_Reset) item

	// reset and write old content
	text_root := cast(^u8) (uintptr(item) + size_of(Undo_Builder_Lowercased_Content_Reset))
	text_content := strings.string_from_ptr(text_root, data.byte_count)
	strings.builder_reset(data.builder)
	strings.write_string(data.builder, text_content)

	output := Undo_Builder_Lowercased_Content {
		builder = data.builder,
	}
	undo_push(manager, undo_box_lowercased_content, &output, size_of(Undo_Builder_Lowercased_Content))
}

undo_box_lowercased_content :: proc(manager: ^Undo_Manager, item: rawptr) {
	data := cast(^Undo_Builder_Lowercased_Content) item

	// generate output before mods
	output := Undo_Builder_Lowercased_Content_Reset {
		builder = data.builder,
		byte_count = len(data.builder.buf),
	}
	bytes := undo_push(
		manager, 
		undo_box_lowercased_content_reset, 
		&output, 
		size_of(Undo_Builder_Lowercased_Content_Reset) + output.byte_count,
	)

	// write actual text content
	text_root := cast(^u8) &bytes[size_of(Undo_Builder_Lowercased_Content_Reset)]
	mem.copy(text_root, raw_data(data.builder.buf), output.byte_count)

	// write lowercased
	text := strings.to_string(data.builder^)
	builder_write_lowercased_string(data.builder, text)
}

//////////////////////////////////////////////
// Task Box
//////////////////////////////////////////////

text_box_message :: proc(element: ^Element, msg: Message, di: int, dp: rawptr) -> int {
	box := cast(^Text_Box) element

	#partial switch msg {
		case .Layout: {
			clear(&box.wrapped_lines)
			append(&box.wrapped_lines, strings.to_string(box.builder))
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
			text := strings.to_string(box.builder)
			scaled_size := fcs_element(element)
			color: Color
			element_message(element, .Box_Text_Color, 0, &color)
			fcs_color(color)
			fcs_ahv(.Left, .Middle)
			caret_x: f32
			text_bounds := element.bounds
			text_bounds.l += 5 * SCALE
			text_bounds.r -= 5 * SCALE
			text_width := string_width(text)

			// handle scrolling
			{
				// clamp scroll(?)
				if box.scroll > text_width - rect_width(text_bounds) {
					box.scroll = text_width - rect_width(text_bounds)
				}

				if box.scroll < 0 {
					box.scroll = 0
				}

				// TODO probably will fail?
				caret_x, _ = fontstash.wrap_layout_caret(&gs.fc, box.wrapped_lines[:], box.head)
				caret_x -= box.scroll

				// check caret x
				if caret_x < 0 {
					box.scroll = caret_x + box.scroll
				} else if caret_x > rect_width(text_bounds) {
					box.scroll = caret_x - rect_width(text_bounds) + box.scroll + 1
				}

				caret_x, _ = fontstash.wrap_layout_caret(&gs.fc, box.wrapped_lines[:], box.head)
			}

			// selection & caret
			if focused {
				render_rect(target, element.bounds, theme_panel(.Front), ROUNDNESS)
				x := text_bounds.l - box.scroll
				y := text_bounds.t + rect_height_halfed(text_bounds) - scaled_size / 2
				box_render_selection(target, box, x, y, theme.caret_selection)
			}

			render_rect_outline(target, element.bounds, color)

			// draw each wrapped line
			render_string_rect(target, text_bounds, text)

			if focused {
				x := text_bounds.l - box.scroll
				y := text_bounds.t + rect_height_halfed(text_bounds) - scaled_size / 2
				caret := rect_wh(
					x + caret_x,
					y,
					math.round(2 * SCALE),
					scaled_size,
				)
				render_rect(target, caret, theme.caret, 0)
			}
		}

		case .Key_Combination: {
			combo := (cast(^string) dp)^
			shift := element.window.shift
			ctrl := element.window.ctrl
			handled := false

			if command, ok := element.window.shortcut_state.box[combo]; ok {
				handled = shortcuts_command_execute_box(box, &box.box, command, ctrl, shift)
			}

			if handled {
				element_repaint(element)
			}

			return int(handled)
		}

		case .Destroy: {
			box_destroy(box.box)
		}

		case .Update: {
			element_repaint(element)	
		}

		case .Unicode_Insertion: {
			codepoint := (cast(^rune) dp)^

			if box.codepoint_numbers_only {
				if unicode.is_number(codepoint) {
					box_insert(element, box, codepoint)
					element_repaint(element)
				}
			} else {
				box_insert(element, box, codepoint)
				element_repaint(element)
			}

			return 1
		}

		case .Box_Set_Caret: {
			box_set_caret(box, di, dp)
		}

		case .Left_Down: {
			element_focus(element)

			old_tail := box.tail
			element_box_mouse_selection(box, box, di, false, box.scroll)

			if element.window.shift && di == 0 {
				box.tail = old_tail
			}
		}

		case .Mouse_Drag: {
			if element.window.pressed_button == MOUSE_LEFT {
				element_box_mouse_selection(box, box, di, true, box.scroll)
				element_repaint(box)
			}
		}

		case .Get_Width: {
			return int(SCALE * 100)
		}

		case .Get_Height: {
			return int(efont_size(element) + TEXT_MARGIN_VERTICAL * SCALE)
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
	box_init(&res.box, 32)
	strings.write_string(&res.builder, text)
	box_move_end(&res.box, false)
	return	
}

//////////////////////////////////////////////
// Task Box
//////////////////////////////////////////////

// just paints the text based on text color
task_box_paint_default_selection :: proc(box: ^Task_Box) {
	focused := box.window.focused == box
	target := box.window.target
	scaled_size := fcs_element(box)

	color: Color
	element_message(box, .Box_Text_Color, 0, &color)

	fcs_ahv(.Left, .Top)
	fcs_color(color)

	group := &target.groups[len(target.groups) - 1]
	state := fontstash.state_get(&gs.fc)
	q: fontstash.Quad
	codepoint_index: int
	back_color := theme_panel(.Front)
	low, high := box_low_and_high(box)

	// draw each wrapped line
	y_offset: f32
	for wrap_line, i in box.wrapped_lines {
		iter := fontstash.text_iter_init(&gs.fc, wrap_line, box.bounds.l, box.bounds.t + y_offset)

		for fontstash.text_iter_step(&gs.fc, &iter, &q) {
			state.color = low <= codepoint_index && codepoint_index < high ? back_color : color
			render_glyph_quad(target, group, state, &q)
			codepoint_index += 1 
		}

		y_offset += f32(scaled_size)
	}

	fcs_color(color)
}

// just paints the text based on text color
task_box_paint_default :: proc(box: ^Task_Box) {
	focused := box.window.focused == box
	target := box.window.target
	scaled_size := fcs_element(box)

	color: Color
	element_message(box, .Box_Text_Color, 0, &color)

	fcs_ahv(.Left, .Top)
	fcs_color(color)

	// draw each wrapped line
	y: f32
	for wrap_line, i in box.wrapped_lines {
		render_string(target, box.bounds.l, box.bounds.t + y, wrap_line)
		y += f32(scaled_size)
	}

	fcs_color(color)
}

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

		case .Paint_Recursive: {
			task_box_paint_default(task_box)
		}

		case .Key_Combination: {
			combo := (cast(^string) dp)^
			shift := element.window.shift
			ctrl := element.window.ctrl
			handled := false

			if command, ok := element.window.shortcut_state.box[combo]; ok {
				handled = shortcuts_command_execute_box(task_box, &task_box.box, command, ctrl, shift)
			}

			if handled {
				element_repaint(element)
			}

			return int(handled)
		}

		case .Destroy: {
			box_destroy(task_box.box)
		}

		case .Update: {
			element_repaint(element)	
		}

		case .Unicode_Insertion: {
			codepoint := (cast(^rune) dp)^
			box_insert(element, task_box, codepoint)
			element_repaint(element)
			return 1
		}

		case .Box_Set_Caret: {
			box_set_caret(task_box, di, dp)
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
	box_init(&res.box, 32)
	strings.write_string(&res.builder, text)
	box_move_end(&res.box, false)
	return
}

//////////////////////////////////////////////
// Box input
//////////////////////////////////////////////

// evaluate command text to actual execution of command
shortcuts_command_execute_box :: proc(
	element: ^Element,
	box: ^Box,
	command: string,
	ctrl: bool,
	shift: bool,
) -> (handled: bool) {
	handled = true

	switch command {
		case "move_left": box_move_left(box, ctrl, shift)
		case "move_right": box_move_right(box, ctrl, shift)
		case "home": box_move_home(box, shift)
		case "end": box_move_end(box, shift)
		case "backspace": handled = box_backspace(element, box, ctrl, shift)
		case "delete": handled = box_delete(element, box, ctrl, shift)
		case "select_all": box_select_all(box)

		case "copy": {
			handled = box_copy_selection(element.window, box)
			last_was_task_copy = false
		}

		case "cut": {
			if box.tail != box.head {
				handled = box_copy_selection(element.window, box)
				box_delete(element, box, ctrl, shift)
				last_was_task_copy = false
			} else {
				handled = false
			}
		}

		case "paste": {
			if !last_was_task_copy {
				handled = box_paste(element, box)
			} else {
				handled = false
			}
		}

		case: {
			handled = false
		}
	}

	return
}

// copy selection to window storage
box_copy_selection :: proc(window: ^Window, box: ^Box) -> (found: bool) {
	if box.head == box.tail {
		return
	}

	box.ds = {}
	low, high := box_low_and_high(box)
	selection, ok := cutf8.ds_string_selection(&box.ds, strings.to_string(box.builder), low, high)
	
	if ok {
		clipboard_set_with_builder(selection)
		found = true
	}

	return
}

box_paste :: proc(element: ^Element, box: ^Box) -> (found: bool) {
	if clipboard_has_content() {
		text := clipboard_get_with_builder_till_newline()

		if strings.has_suffix(text, ".png") {
			task := tasks_visible[task_head]
			handle := image_load_push(text)
			task.image_display.img = handle
			found = true
			return
		}

		box_replace(element, box, text, 0, true)
		found = true
	}

	return
}

box_move_left :: proc(box: ^Box, ctrl, shift: bool) {
	box_move_caret(box, true, ctrl, shift)
	box_check_shift(box, shift)
}

box_move_right :: proc(box: ^Box, ctrl, shift: bool) {
	box_move_caret(box, false, ctrl, shift)
	box_check_shift(box, shift)
}

box_move_home :: proc(box: ^Box, shift: bool) {
	box.head = 0
	box_check_shift(box, shift)
}

box_move_end :: proc(box: ^Box, shift: bool) {
	length := cutf8.ds_recount(&box.ds, strings.to_string(box.builder))
	box.head = length
	box_check_shift(box, shift)
}

box_backspace :: proc(element: ^Element, box: ^Box, ctrl, shift: bool) -> bool {
	old_head := box.head
	old_tail := box.tail

	// skip none
	if box.head == 0 && box.tail == 0 {
		return false
	}

	forced_selection: int
	if box.head == box.tail {
		box_move_caret(box, true, ctrl, shift)
		forced_selection = -1
	}

	box_replace(element, box, "", forced_selection, true)

	// if nothing changes, dont handle
	if box.head == old_head && box.tail == old_tail {
		return false
	}

	return true
}

box_delete :: proc(element: ^Element, box: ^Box, ctrl, shift: bool) -> bool {
	forced_selection: int
	if box.head == box.tail {
		box_move_caret(box, false, ctrl, shift)
		forced_selection = 1
	}

	box_replace(element, box, "", forced_selection, true)
	return true
}

box_select_all :: proc(box: ^Box) {
	length := cutf8.ds_recount(&box.ds, strings.to_string(box.builder))
	box.head = length
	box.tail = 0
}

// commit and reset changes if any
box_force_changes :: proc(manager: ^Undo_Manager, box: ^Box) {
	if box.change_start != {} {
		box.change_start = {}
		undo_group_end(manager)
	}
}

//  check if changes are above timeout limit and commit 
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
box_insert :: proc(element: ^Element, box: ^Box, codepoint: rune) {
	if box.head != box.tail {
		box_replace(element, box, "", 0, true)
	}
	
	builder := &box.builder
	count := cutf8.ds_recount(&box.ds, strings.to_string(box.builder))
	manager := mode_panel_manager_begin()

	box_check_changes(manager, box)
	task_head_tail_push(manager)

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
}

// utf8 based removal of selection & replacing selection with text
box_replace :: proc(
	element: ^Element,
	box: ^Box, 
	text: string, 
	forced_selection: int, 
	send_changed_message: bool,
) {
	manager := mode_panel_manager_begin()
	box_check_changes(manager, box)
	task_head_tail_push(manager)

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
			// log.info("remove selection", high - low)
		}
	
		if send_changed_message {
			element_message(element, .Value_Changed)
		}
	} 

	if len(text) != 0 {
		box.ds = {}
		for codepoint, i in cutf8.ds_iter(&box.ds, text) {
			builder_insert_rune_at(&box.builder, codepoint, box.head + i)
		}

		old_head := box.head
		box.head += box.ds.codepoint_count
		box.tail = box.head

		item := Undo_Item_Box_Remove_Selection { 
			box,
			old_head,
			old_head + box.ds.codepoint_count,
			0,
		}
		undo_push(manager, undo_box_remove_selection, &item, size_of(Undo_Item_Box_Remove_Selection))
	}
}

box_clear :: proc(box: ^Box, send_changed_message: bool) {
	strings.builder_reset(&box.builder)
	box.head = 0
	box.tail = 0
}

box_check_shift :: proc(box: ^Box, shift: bool) {
	if !shift {
		box.tail = box.head
	}
}

box_move_caret :: proc(box: ^Box, backward: bool, word: bool, shift: bool) {
	// TODO unicode handling
	if !shift && box.head != box.tail {
		if box.head < box.tail {
			if backward {
				box.tail = box.head
			} else {
				box.head = box.tail
			}
		} else {
			if backward {
				box.head = box.tail
			} else {
				box.tail = box.head
			}
		}

		return
	}

	runes := cutf8.ds_to_runes(&box.ds, strings.to_string(box.builder))
	
	for {
		// box ahead of 0 and backward allowed
		if box.head > 0 && backward {
			box.head -= 1
		} else if box.head < len(runes) && !backward {
			// box not in the end and forward 
			box.head += 1
		} else {
			return
		}

		if !word {
			return
		} else if box.head != len(runes) && box.head != 0 {
			c1 := runes[box.head - 1]
			c2 := runes[box.head]
			
			if unicode.is_alpha(c1) != unicode.is_alpha(c2) {
				return
			}
		}
	}
}

box_set_caret :: proc(box: ^Box, di: int, dp: rawptr) {
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
			length := cutf8.ds_recount(&box.ds, strings.to_string(box.builder))
			box.head = length
			box.tail = box.head
		}

		case BOX_SELECT_ALL: {
			length := cutf8.ds_recount(&box.ds, strings.to_string(box.builder))
			box.tail = 0
			box.head = length
		}

		case: {
			log.info("UI: text box unsupported caret setting")
		}
	}
}

// write uppercased version of the string
builder_write_uppercased_string :: proc(b: ^strings.Builder, s: string) {
	prev: rune
	ds: cutf8.Decode_State
	strings.builder_reset(b)

	for codepoint, i in cutf8.ds_iter(&ds, s) {
		codepoint := codepoint

		if i == 0 || (prev != 0 && prev == ' ') {
			codepoint = unicode.to_upper(codepoint)
		}

		builder_append_rune(b, codepoint)
		prev = codepoint
	}
}

// write uppercased version of the string
builder_write_lowercased_string :: proc(b: ^strings.Builder, s: string) {
	ds: cutf8.Decode_State
	strings.builder_reset(b)

	for codepoint, i in cutf8.ds_iter(&ds, s) {
		builder_append_rune(b, unicode.to_lower(codepoint))
	}
}

// append a rune to a builder
builder_append_rune :: proc(builder: ^strings.Builder, r: rune) {
	bytes, size := utf8.encode_rune(r)
	
	if size == 1 {
		append(&builder.buf, bytes[0])
	} else {
		for i in 0..<size {
			append(&builder.buf, bytes[i])
		}
	}
}

//
builder_insert_rune_at :: proc(builder: ^strings.Builder, r: rune, rune_index: int) {
	ds: cutf8.Decode_State
	runes := cutf8.ds_to_runes(&ds, strings.to_string(builder^))

	if rune_index == len(runes) {
		builder_append_rune(builder, r)
	} else {
		strings.builder_reset(builder)
		
		for i in 0..<len(runes) {
			if i == rune_index {
				builder_append_rune(builder, r)
			}

			builder_append_rune(builder, runes[i])
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
	scaled_size: f32,
	x, y: f32,
) -> Rect {
	caret_x, line := fontstash.wrap_layout_caret(&gs.fc, box.wrapped_lines[:], box.head)
	return rect_wh(
		x + caret_x,
		y + f32(line) * scaled_size,
		math.round(2 * SCALE),
		scaled_size,
	)
}

box_render_selection :: proc(
	target: ^Render_Target, 
	box: ^Box,
	x, y: f32,
	color: Color,
) {
	if box.head == box.tail {
		return
	}

	state := fontstash.wrap_state_init(&gs.fc, box.wrapped_lines[:], box.head, box.tail)
	scaled_size := f32(state.isize / 10)

	for fontstash.wrap_state_iter(&gs.fc, &state) {
		translated := Rect {
			x + state.x_from,
			x + state.x_to,
			y + f32(state.y - 1) * scaled_size,
			y + f32(state.y) * scaled_size,
		}

		render_rect(target, translated, color, 0)
	}
}

// mouse selection
element_box_mouse_selection :: proc(
	element: ^Element,
	b: ^Box,
	clicks: int,
	dragging: bool,
	x_offset: f32,
) -> (found: bool) {
	scaled_size := fcs_element(element)

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
	relative_x = element.window.cursor_x - element.bounds.l + x_offset
	relative_y = element.window.cursor_y - element.bounds.t

	ctx := &gs.fc
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
			y += f32(scaled_size)
			x = 0
			old_x = 0

			// clamp to left when x is below 0 and y above 
			if relative_x < 0 && relative_y < old_y {
				b.head = codepoint_offset
				break
			}

			iter := fontstash.text_iter_init(ctx, text)

			// loop through codepoints
			index: int
			quad: fontstash.Quad
			for fontstash.text_iter_step(ctx, &iter, &quad) {
				x = iter.nextx

				// check mouse collision
				if mcs_check_single(&mcs, b, index + codepoint_offset, dragging) {
					break search_line
				}

				index += 1
			}

			x += f32(scaled_size)
			mcs_check_single(&mcs, b, iter.codepoint_count + codepoint_offset, dragging)

			codepoint_offset += iter.codepoint_count

			// do line end?
			if relative_x > x && !dragging {
				index := codepoint_offset
				box_set_caret(b, 0, &index)
				break search_line
			}

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
				y += f32(scaled_size)

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
				iter := fontstash.text_iter_init(ctx, text)
				index: int
				quad: fontstash.Quad
				for fontstash.text_iter_step(ctx, &iter, &quad) {
					// check for word completion
					if index_word_start != -1 && iter.codepoint == ' ' {
						old_x = x_word_start
						mcs_check_word(&mcs, b, codepoint_offset + index_word_start, codepoint_offset + index)
						index_word_start = -1
					}
					
					// check for starting codepoint being letter
					if index_word_start == -1 && unicode.is_letter(iter.codepoint) {
						index_word_start = index
						x_word_start = x
					}

					// check for space word completion
					if index_whitespace_start != -1 && unicode.is_letter(iter.codepoint) {
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
					x = iter.nextx
					codepoint_last = iter.codepoint
					index += 1
				}

				// finish whitespace and end letter
				if index_whitespace_start != -1 && codepoint_last == ' ' {
					old_x = x_whitespace_start
					mcs_check_word(&mcs, b, codepoint_offset + index_whitespace_start, codepoint_offset + iter.codepoint_count)
				}

				// finish end word
				if index_word_start != -1 && unicode.is_letter(codepoint_last) {
					old_x = x_word_start
					mcs_check_word(&mcs, b, codepoint_offset + index_word_start, codepoint_offset + iter.codepoint_count)
				}

				old_y = y
				codepoint_offset += iter.codepoint_count
			}

			mcs_check_line_last(&mcs, b)
		} else {
			// LINE
			for text, line_index in b.wrapped_lines {
				y += f32(scaled_size)
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
