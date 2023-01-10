package src

import "core:time"
import "core:mem"
import "core:fmt"
import "core:strings"
import sdl "vendor:sdl2"
import "../cutf8"

Dialog_Callback :: proc(^Dialog, string)

Dialog :: struct {
	using element: Element,
	width: f32,
	shadow: f32,
	um: Undo_Manager,

	// resulting state
	result: Dialog_Result,

	// stored state
	focus_start: ^Element,
	
	// callbacks
	on_finish: Dialog_Callback,

	// found elements
	button_default: ^Button,
	button_cancel: ^Button,
	stealer: ^KE_Stealer,
	text_box: ^Text_Box,

	// children
	panel: ^Panel,
}

Dialog_Result :: enum {
	None,
	Default,
	Cancel,
}

dialog_init :: proc(
	parent: ^Element,
	on_finish: Dialog_Callback,
	width: f32,
	format: string,
	args: ..string,
) -> (res: ^Dialog) {
	window := parent.window

	// disable other elements
	for element in window.element.children {
		incl(&element.flags, Element_Flag.Disabled)
	}

	res = element_init(Dialog, parent, {}, dialog_message, context.allocator)
	res.z_index = 255
	res.on_finish = on_finish
	res.focus_start = window.focused
	res.width = width

	// flush old state
	window_flush_mouse_state(window)
	window.pressed = nil
	window.hovered = nil
	window.update_next = true

	// write content
	element_animation_start(res)
	// window_animate(parent.window, &res.shadow, 1, .Quadratic_Out, time.Millisecond * 200)
	undo_manager_init(&res.um, mem.Kilobyte * 2)

	// panel 
	panel := panel_init(res, { .Tab_Movement_Allowed, .Panel_Default_Background }, 5, 5)
	panel.background_index = 2
	panel.shadow = true
	panel.rounded = true
	res.panel = panel

	dialog_build_elements(res, format, ..args)

	return
}

dialog_spawn :: proc(
	window: ^Window,
	on_finish: Dialog_Callback,
	width: f32,
	format: string,
	args: ..string,
) -> (res: ^Dialog) {
	dialog_close(window)
	res = dialog_init(&window.element, on_finish, width, format, ..args)
	window.dialog = res
	return
}

dialog_message :: proc(element: ^Element, msg: Message, di: int, dp: rawptr) -> int {
	dialog := cast(^Dialog) element

	#partial switch msg {
		case .Paint_Recursive: {
			target := element.window.target
			render_push_clip(target, element.window.rect)
			shadow := theme.shadow
			shadow.a = u8(dialog.shadow * 0.5 * 255)
			render_rect(target, element.window.rect, shadow)
			render_push_clip(target, element.bounds)
		}

		case .Layout: {
			w := element.window
			assert(len(element.children) != 0)
			
			panel := cast(^Panel) element.children[0]
			width := int(dialog.width * SCALE)
			height := element_message(panel, .Get_Height, 0)
			cx := (element.bounds.l + element.bounds.r) / 2
			cy := (element.bounds.t + element.bounds.b) / 2
			bounds := RectI {
				cx - (width + 1) / 2,
				cx + width / 2, 
				cy - (height + 1) / 2,
				cy + height / 2,
			}
			element_move(panel, bounds)
		}

		case .Update: {
			panel := element.children[0]
			element_message(panel, .Update, di, dp)
		}

		case .Destroy: {
			undo_manager_destroy(&dialog.um)
		}

		case .Key_Combination: {
			combo := (cast(^string) dp)^

			if combo == "escape" && dialog.button_cancel != nil {
				dialog_close(dialog.window, .Cancel)
				return 1
			} 

			if combo == "return" && dialog.button_default != nil {
				dialog_close(dialog.window, .Default)
				return 1
			}

			if combo == "escape" {
				dialog_close(dialog.window)
				return 1
			}
		}

		case .Animate: {
			handled := dialog.shadow >= 1
			dialog.shadow = min(dialog.shadow + gs.dt * visuals_animation_speed(), 1)
			return int(handled)
		}
	}

	return 0
}

dialog_build_elements :: proc(dialog: ^Dialog, format: string, args: ..string) {
	arg_index: int
	row: ^Panel = nil
	ds: cutf8.Decode_State
	focus_next: ^Element

	for codepoint, i in cutf8.ds_iter(&ds, format) {
		codepoint := codepoint
		i := i

		if i == 0 || codepoint == '\n' {
			row = panel_init(dialog.panel, { .Panel_Horizontal, .HF }, 0, 5)
		}

		if codepoint == ' ' || codepoint == '\n' {
			continue
		}

		if codepoint == '%' {
			// next
			codepoint, i, _ = cutf8.ds_iter(&ds, format)

			switch codepoint {
				case 'b', 'B', 'C': {
					text := args[arg_index]
					arg_index += 1
					b := button_init(row, { .HF }, text)
					b.message_user = dialog_button_message

					// default
					if codepoint == 'B' {
						dialog.button_default = b
					}

					// canceled
					if codepoint == 'C' {
						dialog.button_cancel = b
					}

					// set first focused
					if focus_next == nil {
						focus_next = b
					}
				}

				case 'f': {
					spacer_init(row, { .HF }, 0, int(10 * SCALE), .Empty)
				}

				case 'l': {
					spacer_init(row, { .HF }, 0, LINE_WIDTH, .Thin)
				}

				// text box
				case 't': {
					text := args[arg_index]
					arg_index += 1
					box := text_box_init(row, { .HF }, text)
					
					// box.um = &dialog.um
					element_message(box, .Value_Changed)
					dialog.text_box = box

					if focus_next == nil {
						focus_next = box
					}
				}

				// text line
				case 's': {
					text := args[arg_index]
					arg_index += 1
					label_init(row, { .HF }, text)
				}

				// keyboard input stealer
				case 'x': {
					text := args[arg_index]
					arg_index += 1

					stealer := ke_stealer_init(row, { .HF }, text)
					dialog.stealer = stealer

					if focus_next == nil {
						focus_next = stealer
					}
				}
			}
		} else {
			byte_start := ds.byte_offset_old
			byte_end := ds.byte_offset
			end_early: bool

			// advance till empty
			for other_codepoint in cutf8.ds_iter(&ds, format) {
				byte_end = ds.byte_offset

				if other_codepoint == '%' || other_codepoint == '\n' {
					end_early = true
					break
				}
			}

			text := format[byte_start:byte_end - (end_early ? 1 : 0)]
			label := label_init(row, { .Label_Center, .HF }, text)
			label.font_options = &app.font_options_bold

			if end_early {
				row = panel_init(dialog.panel, { .Panel_Horizontal, .HF }, 0, 5)
			}
		}
	}

	// force dialog to receive key combinations still
	if focus_next == nil {
		focus_next = dialog
	}

	element_focus(dialog.window, focus_next)
}

// close a window dialog
dialog_close :: proc(window: ^Window, set: Maybe(Dialog_Result) = nil) -> bool {
	if window.dialog == nil {
		return false
	}

	if value, ok := set.?; ok {
		window.dialog.result = value
	}

	// reset state
	window.focused = window.dialog.focus_start
	for element in window.element.children {
		excl(&element.flags, Element_Flag.Disabled)
	}

	// reset state to default
	window_flush_mouse_state(window)
	window.pressed = nil
	window.hovered = nil

	if window.dialog.on_finish != nil {
		result := ""

		if window.dialog.stealer != nil {
			result = strings.to_string(window.dialog.stealer.builder)
		} else if window.dialog.text_box != nil {
			result = ss_string(&window.dialog.text_box.ss)
		}

		window.dialog.on_finish(window.dialog, result)
	}

	element_destroy(window.dialog)
	window_repaint(window)
	window.dialog = nil
	return true
}

dialog_button_message :: proc(element: ^Element, msg: Message, di: int, dp: rawptr) -> int {
	button := cast(^Button) element

	if msg == .Clicked {
		dialog := element.window.dialog
		
		if button == dialog.button_default {
			dialog.result = .Default
		}

		if button == dialog.button_cancel {
			dialog.result = .Cancel
		}

		dialog_close(element.window)
	}

	return 0
}
