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

//////////////////////////////////////////////
// Task Box
//////////////////////////////////////////////

text_box_message :: proc(element: ^Element, msg: Message, di: int, dp: rawptr) -> int {
	box := cast(^Text_Box) element

	#partial switch msg {
		case .Layout: {
			font, size := element_retrieve_font_options(box)
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
			font, size := element_retrieve_font_options(element)
			scaled_size := size * SCALE
			OFF :: 5
			offset := 5 * SCALE
			text := strings.to_string(box.builder)
			text_width := estring_width(element, text) - offset
			caret_x: f32

			// handle scrolling
			{
				// TODO review with scaling
				// clamp scroll(?)
				if box.scroll > text_width - rect_width(element.bounds) {
					box.scroll = text_width - rect_width(element.bounds)
				}

				if box.scroll < 0 {
					box.scroll = 0
				}

				caret_x = estring_width(element, text[:box.head]) - box.scroll

				// check caret x
				if caret_x < 0 {
					box.scroll = caret_x + box.scroll
				} else if caret_x > rect_width(element.bounds) {
					box.scroll = caret_x - rect_width(element.bounds) + box.scroll + 1
				}
			}

			old_bounds := element.bounds
			element.bounds.l += offset

			color: Color
			element_message(element, .Box_Text_Color, 0, &color)

			// selection & caret
			if focused {
				render_rect(target, old_bounds, theme_panel(.Front), ROUNDNESS)
				font, size := element_retrieve_font_options(box)
				scaled_size := size * SCALE
				x := box.bounds.l - box.scroll
				y := box.bounds.t
				low, high := box_low_and_high(box)
				box_render_selection(target, box, font, scaled_size, x, y, theme.caret_selection)
				box_render_caret(target, box, font, scaled_size, x, y)
			}

			render_rect_outline(target, old_bounds, color)

			// if element.window.focused == element {
			// 	// log.info("rendering outline")
			// 	render_rect_outline(target, old_bounds, RED)
			// }


			// draw each wrapped line
			y: f32
			for wrap_line, i in box.wrapped_lines {
				render_string(
					target,
					font,
					wrap_line,
					element.bounds.l - box.scroll,
					element.bounds.t + y,
					color,
					scaled_size,
				)
				y += scaled_size
			}
		}

		case .Key_Combination: {
			combo := (cast(^string) dp)^
			shift := element.window.shift
			ctrl := element.window.ctrl
			handled := box_evaluate_combo(box, &box.box, combo, ctrl, shift)

			if handled {
				element_repaint(element)
			}

			return int(handled)
		}

		case .Deallocate_Recursive: {
			delete(box.builder.buf)
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
			// element.window.focused = element

			old_tail := box.tail
			element_box_mouse_selection(box, box, di, false)

			if element.window.shift && di == 0 {
				box.tail = old_tail
			}
		}

		case .Mouse_Drag: {
			if element.window.pressed_button == MOUSE_LEFT {
				element_box_mouse_selection(box, box, di, true)
				element_repaint(box)
			}
		}

		case .Get_Width: {
			return int(SCALE * 200)
		}

		case .Get_Height: {
			return int(efont_size(element))
		}
	}

	return 0
}

text_box_init :: proc(
	parent: ^Element, 
	flags: Element_Flags, 
	text := "",
	index_at := -1,
) -> (res: ^Text_Box) {
	flags := flags
	flags |= { .Tab_Stop }
	res = element_init(Text_Box, parent, flags, text_box_message, index_at)
	res.builder = strings.builder_make(0, 32)
	strings.write_string(&res.builder, text)
	box_move_end(&res.box, false)
	return	
}

//////////////////////////////////////////////
// Task Box
//////////////////////////////////////////////

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
			focused := element.window.focused == element
			target := element.window.target
			font, size := element_retrieve_font_options(element)
			scaled_size := size * SCALE

			color: Color
			element_message(element, .Box_Text_Color, 0, &color)

			// draw each wrapped line
			y: f32
			for wrap_line, i in task_box.wrapped_lines {
				render_string(
					target,
					font,
					wrap_line,
					element.bounds.l,
					element.bounds.t + y,
					color,
					scaled_size,
				)
				y += scaled_size
			}
		}

		case .Key_Combination: {
			combo := (cast(^string) dp)^
			shift := element.window.shift
			ctrl := element.window.ctrl
			handled := box_evaluate_combo(task_box, &task_box.box, combo, ctrl, shift)

			if handled {
				element_repaint(element)
			}

			return int(handled)
		}

		case .Deallocate_Recursive: {
			delete(task_box.builder.buf)
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
	index_at := -1,
) -> (res: ^Task_Box) {
	res = element_init(Task_Box, parent, flags, task_box_message, index_at)
	res.builder = strings.builder_make(0, 32)
	strings.write_string(&res.builder, text)
	box_move_end(&res.box, false)
	return
}

//////////////////////////////////////////////
// Box input
//////////////////////////////////////////////

box_evaluate_combo :: proc(
	element: ^Element,
	box: ^Box,
	combo: string, 
	ctrl, shift: bool,
) -> (handled: bool) {
	handled = true

	// TODO could use some form of mapping
	switch combo {
		case "ctrl+shift+left", "ctrl+left", "shift+left", "left": {
			box_move_left(box, ctrl, shift)
		}

		case "ctrl+shift+right", "ctrl+right", "shift+right", "right": {
			box_move_right(box, ctrl, shift)
		}

		case "shift+home", "home": {
			box_move_home(box, shift)
		}
		
		case "shift+end", "end": {
			box_move_end(box, shift)
		}

		case "ctrl+backspace", "shift+backspace", "backspace": {
			handled = box_backspace(element, box, ctrl, shift)
		}

		case "ctrl+delete", "delete": {
			handled = box_delete(element, box, ctrl, shift)
		}

		case "ctrl+a": {
			box_select_all(box)
		}

		case: {
			handled = false
		}
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
	} else {
		if len(text) != 0 {
			log.info("INSERT RUNES")
			// item := Undo_Item_Box_Insert_Runes {
			// 	box = box,
			// 	head = box.head,
			// 	tail = box.head,
			// 	rune_amount = len()
			// }
		} 
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

box_low_and_high :: proc(box: ^Box) -> (low, high: int) {
	low = min(box.head, box.tail)
	high = max(box.head, box.tail)
	return
}

//////////////////////////////////////////////
// Box render
//////////////////////////////////////////////

box_render_caret :: proc(
	target: ^Render_Target, 
	box: ^Box,
	font: ^Font,
	scaled_size: f32,
	x, y: f32,
) {
	// wrapped line based caret
	wanted_line, index_start := fontstash.codepoint_index_to_line(
		box.wrapped_lines[:], 
		box.head,
	)

	goal := box.head - index_start
	text := box.wrapped_lines[wanted_line]
	low_width: f32
	scale := fontstash.scale_for_pixel_height(font, scaled_size)
	xadvance, lsb: i32

	// iter tilloin
	ds: cutf8.Decode_State
	for codepoint, i in cutf8.ds_iter(&ds, text) {
		if i >= goal {
			break
		}

		low_width += fontstash.codepoint_xadvance(font, codepoint, scale)
	}

	caret_rect := rect_wh(
		x + low_width,
		y + f32(wanted_line) * scaled_size,
		math.round(2 * SCALE),
		scaled_size,
	)

	render_rect(target, caret_rect, theme.caret, 0)
}

Wrap_State :: struct {
	// font option
	font: ^Font,
	scaled_size: f32,
	
	// text lines
	lines: []string,

	// result
	rect_valid: bool,
	rect: Rect,

	// increasing state
	line_index: int,
	codepoint_offset: int,
	y_offset: f32,
}

wrap_state_init :: proc(lines: []string, font: ^Font, scaled_size: f32) -> Wrap_State {
	return Wrap_State {
		lines = lines,
		font = font,
		scaled_size = scaled_size,
	}
}

wrap_state_iter :: proc(
	using wrap_state: ^Wrap_State,
	index_from: int,
	index_to: int,
) -> bool {
	if line_index > len(lines) - 1 {
		return false
	}

	text := lines[line_index]
	line_index += 1
	rect_valid = false
	
	text_width: f32
	x_from_start: f32 = -1
	x_from_end: f32
	ds: cutf8.Decode_State
	scale := fontstash.scale_for_pixel_height(font, scaled_size)

	// iterate string line
	for codepoint, i in cutf8.ds_iter(&ds, text) {
		width_codepoint := fontstash.codepoint_xadvance(font, codepoint, scale)

		if index_from <= i + codepoint_offset && i + codepoint_offset <= index_to {
			if x_from_start == -1 {
				x_from_start = text_width
			}

			x_from_end = text_width
		}

		text_width += width_codepoint
	}

	// last character
	if index_to == codepoint_offset + ds.codepoint_count {
		x_from_end = text_width
	}

	codepoint_offset += ds.codepoint_count

	if x_from_start != -1 {
		y := y_offset * scaled_size

		rect = Rect {
			x_from_start,
			x_from_end,
			y,
			y + scaled_size,
		}

		rect_valid = true
	}

	y_offset += 1
	return true
}

box_render_selection :: proc(
	target: ^Render_Target, 
	box: ^Box,
	font: ^Font,
	scaled_size: f32,
	x, y: f32,
	color: Color,
) {
	low, high := box_low_and_high(box)

	if low == high {
		return
	}

	state := wrap_state_init(box.wrapped_lines[:], font, scaled_size)

	for wrap_state_iter(&state, low, high) {
		if state.rect_valid {
			rect := state.rect
			translated := rect_add(rect, rect_xxyy(x, y))
			render_rect(target, translated, color, 0)
		}
	}
}

// mouse selection
element_box_mouse_selection :: proc(
	element: ^Element,
	b: ^Box,
	clicks: int,
	dragging: bool,
) -> (res: int) {
	// log.info("relative clicks", clicks)
	text := strings.to_string(b.builder)
	font, size := element_retrieve_font_options(element)
	scaled_size := size * SCALE
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
	relative_x = element.window.cursor_x - element.bounds.l
	relative_y = element.window.cursor_y - element.bounds.t

	ds := &b.ds
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
