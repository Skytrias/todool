package src

// import "core:strconv"
// import "core:strings"
// import "core:fmt"
// import "core:mem"

// Button_Combo :: struct {
// 	button: ^Button,
// 	combo: ^Combo_Node,	
// }

// Keymap_Editor :: struct {
// 	window: ^Window,
// 	panel: ^Panel,

// 	record_panel: ^Panel,
// 	record_label: ^Label,
// 	record_accept: ^Button,

// 	// no need to free content
// 	temp: Button_Combo,
// }
// ke: Keymap_Editor
// keymap_color_pattern := Color { 255, 255, 255, 50 }

// keymap_editor_window_message :: proc(element: ^Element, msg: Message, di: int, dp: rawptr) -> int {
// 	window := cast(^Window) element

// 	#partial switch msg {
// 		case .Destroy: {
// 			ke = {}
// 		}

// 		case .Layout: {
// 			bounds := element.bounds

// 			if .Hide not_in ke.record_panel.flags {
// 				rect := rect_cut_top(&bounds, 50)
// 				element_move(ke.record_panel, rect)
// 			}

// 			element_move(ke.panel, bounds)

// 			if ke.window.menu != nil {
// 				// rect := rect_wh(
// 				// 	ke.window.menu.x,
// 				// 	ke.window.menu.y,
// 				// 	ke.window.menu.width,
// 				// 	ke.window.menu.height,
// 				// )
// 				element_move(ke.window.menu, bounds)
// 			}

// 			return 1
// 		}

// 		case .Key_Combination: {
// 			combo := (cast(^string) dp)^

// 			if .Hide not_in ke.record_panel.flags {
// 				defer window_repaint(window)

// 				if combo == "escape" {
// 					keymap_editor_reset_display()
// 					return 1
// 				}

// 				if combo == "return" {
// 					if keymap_editor_accept_display() {
// 						return 1
// 					}
// 				}

// 				b := &ke.record_label.builder
// 				strings.builder_reset(b)
// 				strings.write_string(b, combo)
// 			}

// 			return 1
// 		}
// 	}

// 	return 0
// }

// keymap_editor_reset_display :: proc() {
// 	b := &ke.record_label.builder
// 	ke.record_label.data = nil

// 	if len(b.buf) != 0 {
// 		strings.builder_reset(b)
// 		window_repaint(ke.window)
// 	}
// }

// keymap_editor_accept_display :: proc() -> bool {
// 	b := &ke.record_label.builder

// 	if len(b.buf) != 0 && ke.record_label.data != nil {
// 		button := cast(^Button) ke.record_label.data
// 		push := cast(^string) button.data
// 		delete(push^)
// 		push^ = strings.clone(strings.to_string(b^))

// 		strings.builder_reset(&button.builder)
// 		strings.write_string(&button.builder, strings.to_string(b^))

// 		keymap_editor_reset_display()
// 		return true
// 	}

// 	return false
// }

// keymap_editor_spawn :: proc() {
// 	if ke.window != nil {
// 		return
// 	}

// 	ke.window = window_init(nil, {}, "Keymap Editor", 700, 700, mem.Kilobyte)
// 	ke.window.element.message_user = keymap_editor_window_message
// 	ke.window.update = proc(window: ^Window) {
// 		b := &ke.record_label.builder
// 		element_hide(ke.record_accept, len(b.buf) == 0)
// 	}

// 	ke.record_panel = panel_init(
// 		&ke.window.element,
// 		{ .HF, .Panel_Default_Background, .Panel_Horizontal },
// 		5,
// 		5,
// 	)
// 	ke.record_panel.background_index = 1
// 	label_init(ke.record_panel, {}, "Recording:")
// 	ke.record_label = label_init(ke.record_panel, { .HF, .Label_Center }, "")
// 	ke.record_accept = button_init(ke.record_panel, {}, "Accept")
// 	ke.record_accept.invoke = proc(button: ^Button, data: rawptr) {
// 		keymap_editor_accept_display()
// 	}
// 	b1 := button_init(ke.record_panel, {}, "Reset")
// 	b1.invoke = proc(button: ^Button, data: rawptr) {
// 		keymap_editor_reset_display()
// 	}

// 	ke.panel = panel_init(
// 		&ke.window.element,
// 		{ .Panel_Default_Background, .Panel_Scroll_Vertical },
// 		5,
// 		5,
// 	)
// 	ke.panel.background_index = 0

// 	keymap_editor_push_keymap(&window_main.keymap_box, "Box")
// 	keymap_editor_push_keymap(&window_main.keymap_custom, "Todool")
// }

// keymap_editor_push_keymap :: proc(keymap: ^Keymap, header: string) {
// 	toggle := toggle_panel_init(ke.panel, { .HF }, {}, header, false)
// 	toggle.message_user = proc(element: ^Element, msg: Message, di: int, dp: rawptr) -> int {
// 		toggle := cast(^Toggle_Panel) element

// 		#partial switch msg {
// 			case .Layout: {
// 				// NOTE expecting each to be a panel
// 				for child, i in toggle.panel.children {
// 					if child.message_class == panel_message {
// 						panel := cast(^Panel) child
// 						panel.color = (i % 2) == 0 ? nil : &keymap_color_pattern
// 					}
// 				}
// 			}
// 		}

// 		return 0
// 	}
// 	panel := toggle.panel
// 	panel.data = keymap

// 	for node := keymap.combo_start; node != nil; node = node.next {
// 		p := panel_init(panel, { .HF, .Panel_Horizontal }, 5, 5)
// 		p.rounded = true
// 		b1 := button_init(p, { .HF }, node.combo)
// 		b1.data = &node.combo
// 		b1.message_user = proc(element: ^Element, msg: Message, di: int, dp: rawptr) -> int {
// 			button := cast(^Button) element

// 			#partial switch msg {
// 				case .Clicked: {
// 					if ke.record_label.data != element {
// 						b := &ke.record_label.builder
// 						strings.builder_reset(b)
// 						ke.record_label.data = element
// 					} else {
// 						keymap_editor_reset_display()
// 					}
// 				}

// 				case .Paint_Recursive: {
// 					target := element.window.target
// 					pressed := element.window.pressed == element
// 					hovered := element.window.hovered == element
// 					text_color := hovered || pressed ? theme.text_default : theme.text_blank

// 					if hovered || pressed {
// 						render_rect_outline(target, element.bounds, text_color)
// 						render_hovered_highlight(target, element.bounds)
// 					}

// 					if ke.record_label.data != nil {
// 						if ke.record_label.data == element {
// 							render_rect_outline(target, element.bounds, theme.text_good)
// 						}
// 					}

// 					fcs_element(button)
// 					fcs_ahv()
// 					fcs_color(text_color)
// 					text := strings.to_string(button.builder)
// 					render_string_rect(target, element.bounds, text)

// 					return 1
// 				}
// 			}

// 			return 0
// 		}

// 		b2 := button_init(p, { .HF }, node.command)
// 		b2.data = node
// 		b2.invoke = proc(button: ^Button, data: rawptr) {
// 			// spawn lister with selectable & info per key command maybe with text box
// 			combo := cast(^Combo_Node) data
// 			// NOTE dangerous!!!
// 			keymap := cast(^Keymap) button.parent.parent.data
// 			keymap_editor_spawn_floaty_command(keymap, button, combo)
// 		}

// 		b3 := button_init(p, { .HF }, "")
// 		fmt.sbprintf(&b3.builder, "0x%2x", node.du)

// 		b4 := button_init(p, {}, "x")
// 		b4.data = node
// 		b4.invoke = proc(button: ^Button, data: rawptr) {
// 			combo := cast(^Combo_Node) data
// 			// NOTE dangerous!!!
// 			keymap := cast(^Keymap) button.parent.parent.data
// 			keymap_remove_combo(keymap, combo)
// 			element_destroy(button.parent)
// 		}
// 	}

// 	// badd := button_init(p, {}, "Add")
// 	// badd.data = p
// 	// badd.invoke = proc(button: ^Button, data: rawptr) {
		
// 	// }
// }

// keymap_editor_spawn_floaty_command :: proc(
// 	keymap: ^Keymap,
// 	button: ^Button, 
// 	combo: ^Combo_Node,
// ) {
// 	menu_close(ke.window)
// 	ke.temp = { button, combo }

// 	menu := menu_init(ke.window, { .Panel_Expand, .Panel_Scroll_Vertical })
// 	menu.x = ke.window.cursor_x
// 	menu.y = ke.window.cursor_y
// 	menu.width = 200
// 	menu.height = 300
// 	p := menu.panel
// 	p.background_index = 2

// 	for key, value in keymap.commands {
// 		b := button_init(p, {}, key)
// 		b.invoke = proc(button: ^Button, data: rawptr) {
// 			bc := &ke.temp
// 			goal := strings.to_string(button.builder)
			
// 			delete(bc.combo.command)
// 			bc.combo.command = strings.clone(goal)
			
// 			strings.builder_reset(&bc.button.builder)
// 			strings.write_string(&bc.button.builder, goal)
			
// 			menu_close(button.window)
// 		}
// 	}

// 	// button_init(p, { .HF }, "testing")
// 	// button_init(p, { .HF }, "testing")
// 	window_repaint(ke.window)
// }