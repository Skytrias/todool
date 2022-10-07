package src

import "core:fmt"
import "core:mem"

Keymap :: struct {
	window: ^Window,
	panel: ^Panel,
}
keymap: Keymap
keymap_color_pattern := Color { 255, 255, 255, 50 }

keymap_window_message :: proc(element: ^Element, msg: Message, di: int, dp: rawptr) -> int {
	window := cast(^Window) element

	#partial switch msg {
		case .Destroy: {
			keymap = {}
		}
	}

	return 0
}

keymap_spawn :: proc() {
	if keymap.window != nil {
		return
	}

	keymap.window = window_init(nil, {}, "Keymap Editor", 700, 700, mem.Kilobyte)
	keymap.window.element.message_user = keymap_window_message
	// keymap.window.update = proc(window: ^Window) {}

	keymap.panel = panel_init(
		&keymap.window.element,
		{ .HF, .VF, .Panel_Default_Background, .Panel_Scroll_Vertical },
		5,
		5,
	)
	keymap.panel.background_index = 0

	{
		ss := &window_main.shortcut_state
		index: int

		for k, v in &ss.general {
			p := panel_init(keymap.panel, { .HF, .Panel_Horizontal }, 5, 5)
			p.color = (index % 2) == 0 ? nil : &keymap_color_pattern
			p.rounded = true
			b1 := button_init(p, { .HF }, k)
			b1.data = &v
			b1.invoke = proc(data: rawptr) {
				combo := cast(^string) data
				fmt.eprintln("combo", combo)
				// invoke record next key combo
			}
			b2 := button_init(p, { .HF }, v)
			b2.invoke = proc(data: rawptr) {
				// spawn lister with selectable & info per key command maybe with text box
			}
			index += 1
		}
	}
}