package src

import "core:strconv"
import "core:strings"
import "core:fmt"
import "core:mem"

Keymap_Editor :: struct {
	window: ^Window,
	panel: ^Panel,

	record_panel: ^Panel,
	record_label: ^Label,
	record_accept: ^Button,

	combo_edit: ^Combo_Node, // for menu setting
	issue_removal: bool,
	issue_removal_panel: ^Panel,
}
ke: Keymap_Editor
keymap_color_pattern := Color { 255, 255, 255, 50 }

keymap_editor_window_message :: proc(element: ^Element, msg: Message, di: int, dp: rawptr) -> int {
	window := cast(^Window) element

	#partial switch msg {
		case .Destroy: {
			ke = {}
		}

		case .Layout: {
			bounds := element.bounds

			if .Hide not_in ke.record_panel.flags {
				rect := rect_cut_top(&bounds, 50)
				element_move(ke.record_panel, rect)
			}

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

			if .Hide not_in ke.record_panel.flags {
				defer window_repaint(window)

				if combo == "escape" {
					keymap_editor_reset_display()
					return 1
				}

				if combo == "return" {
					if keymap_editor_accept_display() {
						return 1
					}
				}

				b := &ke.record_label.builder
				strings.builder_reset(b)
				strings.write_string(b, combo)
			}

			return 1
		}
	}

	return 0
}

keymap_editor_reset_display :: proc() {
	b := &ke.record_label.builder
	ke.record_label.data = nil

	if len(b.buf) != 0 {
		strings.builder_reset(b)
		window_repaint(ke.window)
	}
}

keymap_editor_accept_display :: proc() -> bool {
	b := &ke.record_label.builder

	if len(b.buf) != 0 && ke.record_label.data != nil {
		button := cast(^KE_Button) ke.record_label.data
		n := button.node

		// copy text content over
		index := min(len(n.combo), len(b.buf))
		mem.copy(&n.combo[0], &b.buf[0], index)
		n.combo_index = u8(index)

		keymap_editor_reset_display()
		return true
	}

	return false
}

keymap_editor_spawn :: proc() {
	if ke.window != nil {
		window_raise(ke.window)
		return
	}

	ke.window = window_init(nil, {}, "Keymap Editor", 700, 700, 8, 8)
	ke.window.element.message_user = keymap_editor_window_message
	ke.window.update = proc(window: ^Window) {
		b := &ke.record_label.builder
		element_hide(ke.record_accept, len(b.buf) == 0)

		// reset node pointers
		if ke.issue_removal {
			ke.issue_removal = false
			children := panel_children(ke.issue_removal_panel)
			keymap := cast(^Keymap) ke.issue_removal_panel.data

			// TODO this feels dirty
			for c, i in children {
				keymap_editor_update_combo_data(cast(^Panel) c, &keymap.combos[i])
			}

			window_repaint(ke.window)
		}
	}

	ke.record_panel = panel_init(
		&ke.window.element,
		{ .HF, .Panel_Default_Background, .Panel_Horizontal },
		5,
		5,
	)
	ke.record_panel.background_index = 1
	label_init(ke.record_panel, {}, "Recording:")
	ke.record_label = label_init(ke.record_panel, { .HF, .Label_Center }, "")
	ke.record_accept = button_init(ke.record_panel, {}, "Accept")
	ke.record_accept.invoke = proc(button: ^Button, data: rawptr) {
		keymap_editor_accept_display()
	}
	b1 := button_init(ke.record_panel, {}, "Reset")
	b1.invoke = proc(button: ^Button, data: rawptr) {
		keymap_editor_reset_display()
	}

	ke.panel = panel_init(
		&ke.window.element,
		{ .Panel_Default_Background, .Panel_Scroll_Vertical },
		5,
		5,
	)
	ke.panel.background_index = 0

	keymap_editor_push_keymap(&window_main.keymap_box, "Box")
	keymap_editor_push_keymap(&window_main.keymap_custom, "Todool")
	keymap_editor_push_keymap(&keymap_vim_normal, "Vim Normal")
	keymap_editor_push_keymap(&keymap_vim_insert, "Vim Insert")
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
			fcs_ahv()
			fcs_color(text_color)

			if ke.record_label.data != nil {
				if ke.record_label.data == element {
					render_rect_outline(target, element.bounds, theme.text_good)
				}
			}

			text := ke_button_text(button)
			render_string_rect(target, element.bounds, text)
		}

		case .Update: {
			element_repaint(element)
		}

		case .Clicked: {
			if button.show_command {
				keymap := cast(^Keymap) element.data
				keymap_editor_spawn_floaty_command(keymap, button.node)
			} else {
				// select button
				if ke.record_label.data != element {
					b := &ke.record_label.builder
					strings.builder_reset(b)
					ke.record_label.data = element
				} else {
					keymap_editor_reset_display()
				}
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
keymap_editor_update_combo_data :: proc(panel: ^Panel, combo: ^Combo_Node) {
	b1 := cast(^KE_Button) panel.children[0]
	b1.node = combo
	b2 := cast(^KE_Button) panel.children[1]
	b2.node = combo
	b3 := cast(^Button) panel.children[2]
	strings.builder_reset(&b3.builder)
	fmt.sbprintf(&b3.builder, "0x%2x", combo.du)
	b4 := cast(^Button) panel.children[3]
}

keymap_editor_push_keymap :: proc(keymap: ^Keymap, header: string) {
	toggle := toggle_panel_init(ke.panel, { .HF }, {}, header, false)
	toggle.message_user = proc(element: ^Element, msg: Message, di: int, dp: rawptr) -> int {
		toggle := cast(^Toggle_Panel) element

		#partial switch msg {
			case .Layout: {
				// NOTE expecting each to be a panel
				for child, i in toggle.panel.children {
					if child.message_class == panel_message {
						panel := cast(^Panel) child
						panel.color = (i % 2) == 0 ? nil : &keymap_color_pattern
					}
				}
			}
		}

		return 0
	}
	panel := toggle.panel
	panel.data = keymap

	for node in &keymap.combos {
		p := panel_init(panel, { .HF, .Panel_Horizontal }, 5, 5)
		p.rounded = true

		c1 := strings.string_from_ptr(&node.combo[0], int(node.combo_index))
		b1 := ke_button_init(p, { .HF }, &node, false)
		b2 := ke_button_init(p, { .HF }, &node, true)
		b2.data = keymap

		b3 := button_init(p, { .HF }, "")
		fmt.sbprintf(&b3.builder, "0x%2x", node.du)

		b4 := button_init(p, {}, "x")
		b4.invoke = proc(button: ^Button, data: rawptr) {
			children := panel_children(cast(^Panel) button.parent.parent)
			keymap := cast(^Keymap) button.parent.parent.data

			// NOTE find linearly... could be done better
			// find this node in children
			combo_index := -1
			for e, i in children {
				if e == button.parent {
					combo_index = i
					break
				}
			}

			if combo_index != -1 {
				ordered_remove(&keymap.combos, combo_index)
				
				ke.issue_removal = true
				ke.issue_removal_panel = cast(^Panel) button.parent.parent

				element_repaint(button)
				element_destroy(button.parent)
			} 
		}
	}
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
		b.invoke = proc(button: ^Button, data: rawptr) {
			n := ke.combo_edit

			index := min(len(n.command), len(button.builder.buf))
			mem.copy(&n.command[0], &button.builder.buf[0], index)
			n.command_index = u8(index)
			
			menu_close(button.window)
		}
	}

	// button_init(p, { .HF }, "testing")
	// button_init(p, { .HF }, "testing")
	window_repaint(ke.window)
}