package src

import "core:strconv"
import "core:strings"
import "core:fmt"
import "core:mem"

Keymap_Editor :: struct {
	window: ^Window,
	panel: ^Panel,

	// record_panel: ^Panel,
	// record_label: ^Label,
	// record_accept: ^Button,
	grids: [4]^Static_Grid,

	combo_edit: ^Combo_Node, // for menu setting
	issue_removal: ^Static_Grid,
}
ke: Keymap_Editor

keymap_editor_window_message :: proc(element: ^Element, msg: Message, di: int, dp: rawptr) -> int {
	window := cast(^Window) element

	#partial switch msg {
		case .Destroy: {
			ke = {}
		}

		case .Layout: {
			bounds := element.bounds

			// if .Hide not_in ke.record_panel.flags {
			// 	rect := rect_cut_top(&bounds, 50)
			// 	element_move(ke.record_panel, rect)
			// }

			element_move(ke.panel, bounds)

			if ke.window.menu != nil {
				// rect := rect_wh(
				// 	ke.window.menu.x,
				// 	ke.window.menu.y,
				// 	ke.window.menu.width,
				// 	ke.window.menu.height,
				// )
				element_move(ke.window.menu, bounds)
			}

			return 1
		}

		case .Key_Combination: {
			combo := (cast(^string) dp)^

			switch combo {
				case "1"..<"5": {
					value := strconv.atoi(combo)
					state := ke.grids[value - 1].hide_cells
					state^ = !state^
					window_repaint(window)
				}
			}

			// if .Hide not_in ke.record_panel.flags {
			// 	defer window_repaint(window)

			// 	if combo == "escape" {
			// 		keymap_editor_reset_display()
			// 		return 1
			// 	}

			// 	if combo == "return" {
			// 		if keymap_editor_accept_display() {
			// 			return 1
			// 		}
			// 	}

			// 	b := &ke.record_label.builder
			// 	strings.builder_reset(b)
			// 	strings.write_string(b, combo)
			// }

			return 1
		}
	}

	return 0
}

// keymap_editor_reset_display :: proc() {
// 	// b := &ke.record_label.builder
// 	// ke.record_label.data = nil

// 	// if len(b.buf) != 0 {
// 	// 	strings.builder_reset(b)
// 	// 	window_repaint(ke.window)
// 	// }
// }

// keymap_editor_accept_display :: proc() -> bool {
// 	b := &ke.record_label.builder

// 	if len(b.buf) != 0 && ke.record_label.data != nil {
// 		button := cast(^KE_Button) ke.record_label.data
// 		n := button.node

// 		// copy text content over
// 		index := min(len(n.combo), len(b.buf))
// 		mem.copy(&n.combo[0], &b.buf[0], index)
// 		n.combo_index = u8(index)

// 		keymap_editor_reset_display()
// 		return true
// 	}

// 	return false
// }

keymap_editor_spawn :: proc() {
	if ke.window != nil {
		window_raise(ke.window)
		return
	}

	ke.window = window_init(nil, {}, "Keymap Editor", 700, 700, 8, 8)
	ke.window.name = "KEYMAP"
	ke.window.element.message_user = keymap_editor_window_message
	ke.window.update = proc(window: ^Window) {
		// b := &ke.record_label.builder
		// element_hide(ke.record_accept, len(b.buf) == 0)

		// reset node pointers
		if ke.issue_removal != nil {
			children := ke.issue_removal.children
			keymap := cast(^Keymap) ke.issue_removal.data

			// TODO this feels dirty
			for c, i in children {
				line := cast(^Static_Line) c
				line.index = i
				keymap_editor_update_combo_data(line, &keymap.combos[i])
			}

			window_repaint(ke.window)
			ke.issue_removal = nil
		}
	}

	// ke.record_panel = panel_init(
	// 	&ke.window.element,
	// 	{ .HF, .Panel_Default_Background, .Panel_Horizontal },
	// 	5,
	// 	5,
	// )
	// ke.record_panel.background_index = 1
	// label_init(ke.record_panel, {}, "Recording:")
	// ke.record_label = label_init(ke.record_panel, { .HF, .Label_Center }, "")
	// ke.record_accept = button_init(ke.record_panel, {}, "Accept")
	// ke.record_accept.invoke = proc(button: ^Button, data: rawptr) {
	// 	keymap_editor_accept_display()
	// }
	// b1 := button_init(ke.record_panel, {}, "Reset")
	// b1.invoke = proc(button: ^Button, data: rawptr) {
	// 	keymap_editor_reset_display()
	// }

	ke.panel = panel_init(
		&ke.window.element,
		{ .Panel_Default_Background, .Panel_Scroll_Vertical },
		5,
		5,
	)
	ke.panel.background_index = 0

	ke.grids[0] = keymap_editor_push_keymap(&app.window_main.keymap_box, "Box", true)
	ke.grids[1] = keymap_editor_push_keymap(&app.window_main.keymap_custom, "Todool", false)
	ke.grids[2] = keymap_editor_push_keymap(&app.keymap_vim_normal, "Vim Normal", true)
	ke.grids[3] = keymap_editor_push_keymap(&app.keymap_vim_insert, "Vim Insert", true)
}

KE_Button :: struct {
	using element: Element,
	node: ^Combo_Node,
	show_command: bool,
}

ke_button_init :: proc(
	parent: ^Element, 
	flags: Element_Flags, 
	node: ^Combo_Node,
	show_command: bool,
) -> (res: ^KE_Button) {
	res = element_init(KE_Button, parent, flags, ke_button_message, context.allocator)
	res.node = node
	res.show_command = show_command
	return	
}

// get text per mode
ke_button_text :: proc(button: ^KE_Button) -> string {
	if button.show_command {
		return transmute(string) button.node.command[:button.node.command_index]
	} else {
		return transmute(string) button.node.combo[:button.node.combo_index]
	}
}

ke_button_message :: proc(element: ^Element, msg: Message, di: int, dp: rawptr) -> int {
	button := cast(^KE_Button) element

	#partial switch msg {
		case .Paint_Recursive: {
			target := element.window.target
			pressed := element.window.pressed == element
			hovered := element.window.hovered == element
			text_color := hovered || pressed ? theme.text_default : theme.text_blank

			if hovered || pressed {
				render_rect_outline(target, element.bounds, text_color)
				render_hovered_highlight(target, element.bounds)
			}

			fcs_element(button)
			horizontal: Align_Horizontal = button.show_command ? .Left : .Right
			fcs_ahv(horizontal, .Middle)
			fcs_color(text_color)

			// if ke.record_label.data != nil {
			// 	if ke.record_label.data == element {
			// 		render_rect_outline(target, element.bounds, theme.text_good)
			// 	}
			// }

			bounds := element.bounds

			// offset left words
			if button.show_command {
				bounds.l += int(5 * SCALE)
			}

			text := ke_button_text(button)
			render_string_rect(target, bounds, text)
		}

		case .Update: {
			element_repaint(element)
		}

		case .Clicked: {
			if button.show_command {
				keymap := cast(^Keymap) element.data
				keymap_editor_spawn_floaty_command(keymap, button.node)
			} else {
				// TODO
				// // select button
				// if ke.record_label.data != element {
				// 	b := &ke.record_label.builder
				// 	strings.builder_reset(b)
				// 	ke.record_label.data = element
				// } else {
				// 	keymap_editor_reset_display()
				// }
			}
		}

		case .Get_Cursor: {
			return int(Cursor.Hand)
		}

		case .Get_Width: {
			fcs_element(element)
			text := ke_button_text(button)
			width := max(int(50 * SCALE), string_width(text) + int(TEXT_MARGIN_HORIZONTAL * SCALE))
			return int(width)
		}

		case .Get_Height: {
			return efont_size(element) + int(TEXT_MARGIN_VERTICAL * SCALE)
		}

		case .Key_Combination: {
			key_combination_check_click(element, dp)
		}
	}	

	return 0
}

// NOTE this has to be the same as the init code
keymap_editor_update_combo_data :: proc(line: ^Static_Line, combo: ^Combo_Node) {
	b1 := cast(^KE_Button) line.children[0]
	b1.node = combo
	b2 := cast(^KE_Button) line.children[1]
	b2.node = combo
	b3 := cast(^Button) line.children[2]
	strings.builder_reset(&b3.builder)
	fmt.sbprintf(&b3.builder, "0x%2x", combo.du)
	b4 := cast(^Button) line.children[3]
}

keymap_editor_remove_call :: proc(button: ^Icon_Button, data: rawptr) {
	children := &button.parent.parent.children
	keymap := cast(^Keymap) button.parent.parent.data

	// NOTE find linearly... could be done better
	// find this node in children
	combo_index := -1
	for line, i in children {
		if line == button.parent {
			combo_index = i
			break
		} 
	}

	if combo_index != -1 {
		ordered_remove(&keymap.combos, combo_index)
		
		ke.issue_removal = cast(^Static_Grid) button.parent.parent

		element_repaint(button)
		element_destroy(button.parent)
	} 
}

keymap_editor_push_keymap :: proc(keymap: ^Keymap, header: string, folded: bool) -> (grid: ^Static_Grid) {
	cell_sizes := [?]int { 220, 220, 100, 40 }
	grid = static_grid_init(ke.panel, {}, cell_sizes[:], DEFAULT_FONT_SIZE + TEXT_MARGIN_VERTICAL)
	grid.data = keymap
	grid.message_user = proc(element: ^Element, msg: Message, di: int, dp: rawptr) -> int {
		grid := cast(^Static_Grid) element

		if msg == .Paint_Recursive {
			target := element.window.target
			shadow := theme_shadow()
			render_rect_outline(target, element.bounds, shadow, ROUNDNESS)

			height := element_message(element, .Get_Height)
			r := rect_wh(
				element.bounds.l, 
				element.bounds.t + LINE_WIDTH + grid.cell_height, 
				LINE_WIDTH, 
				height - LINE_WIDTH * 2,
			)

			for size in grid.cell_sizes {
				render_rect(target, r, shadow)
				r.l += size
				r.r = r.l + LINE_WIDTH
			}
		}

		return 0
	}

	// fold cell with cell setting
	fold := button_fold_init(grid, {}, header, folded)
	grid.hide_cells = &fold.state

	// line description
	{
		p := static_line_init(grid, &grid.cell_sizes, -1)
		label_init(p, { .Label_Center }, "Combination")
		label_init(p, { .Label_Center }, "Command")
		label_init(p, { .Label_Center }, "Modifiers")
		label_init(p, { .Label_Center }, "Pop")
	}

	line_count: int
	for node in &keymap.combos {
		p := static_line_init(grid, &grid.cell_sizes, line_count)
		p.message_user = proc(element: ^Element, msg: Message, di: int, dp: rawptr) -> int {
			sl := cast(^Static_Line) element

			if msg == .Paint_Recursive {
				// highlight second lines
				if sl.index % 2 == 1 {
					render_hovered_highlight(element.window.target, element.bounds, 1)
				}
			}

			return 0
		} 
		line_count += 1

		c1 := strings.string_from_ptr(&node.combo[0], int(node.combo_index))
		b1 := ke_button_init(p, {}, &node, false)
		b2 := ke_button_init(p, {}, &node, true)
		b2.data = keymap

		b3 := button_init(p, {}, "")
		fmt.sbprintf(&b3.builder, "0x%2x", node.du)

		b4 := icon_button_init(p, {}, .Close)
		b4.invoke = keymap_editor_remove_call
	}

	return
}

keymap_editor_spawn_floaty_command :: proc(
	keymap: ^Keymap,
	combo: ^Combo_Node,
) {
	menu_close(ke.window)

	menu := menu_init(ke.window, { .Panel_Expand, .Panel_Scroll_Vertical })
	menu.x = ke.window.cursor_x
	menu.y = ke.window.cursor_y
	menu.width = 200
	menu.height = 300
	p := menu.panel
	p.background_index = 2
	ke.combo_edit = combo

	for key, value in keymap.commands {
		b := button_init(p, {}, key)
		// b.hover_info = keymap_comments[value]
		// fmt.eprintln(b.hover_info)
		b.invoke = proc(button: ^Button, data: rawptr) {
			n := ke.combo_edit

			index := min(len(n.command), len(button.builder.buf))
			mem.copy(&n.command[0], &button.builder.buf[0], index)
			n.command_index = u8(index)
			
			menu_close(button.window)
		}
	}

	window_repaint(ke.window)
}