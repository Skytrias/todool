package src

import "core:log"
import "core:strconv"
import "core:strings"
import "core:fmt"

Theme_Editor :: struct {
	open: bool,
	panel_list: [32]^Panel,
	panel_list_index: int,
	panel_selected_index: int, // theme
	picker: ^Color_Picker,
	window: ^Window,
}
theme_editor: Theme_Editor

Theme :: struct {
	background: [3]Color, // 3 variants, lowest to highest
	text_default: Color,
	text_good: Color,
	text_bad: Color,
	text_blank: Color,

	shadow: Color,
	
	caret: Color,
	caret_highlight: Color,
	caret_selection: Color,

	panel_back: Color,
	panel_front: Color,
}

theme := Theme {
	background = {
		0 = { 200, 200, 200, 255 },
		1 = { 220, 220, 220, 255 },
		2 = { 240, 240, 240, 255 },
	},

	text_default = BLACK,
	text_blank = { 75, 75, 75, 255 },
	text_good = { 25, 200, 25, 255 },
	text_bad = { 200, 25, 25, 255 },

	shadow = BLACK,
	
	caret = BLUE,
	caret_highlight = RED,
	caret_selection = GREEN,

	panel_back = { 230, 230, 230, 255 },
	panel_front = { 255, 255, 255, 255 },
}

theme_task_text :: #force_inline proc(state: Task_State) -> Color {
	switch state {
		case .Normal: return theme.text_default
		case .Done: return theme.text_good
		case .Canceled: return theme.text_bad
	}

	return {}
}

theme_editor_spawn :: proc() {
	if !theme_editor.open {
		theme_editor = {}
		theme_editor.open = true
	} else {
		return
	}

	window := window_init("Todool Theme Editor", 600, 900)
	window.element.message_user = proc(element: ^Element, msg: Message, di: int, dp: rawptr) -> int {
		#partial switch msg {
			case .Key_Combination: {
				combo := (cast(^string) dp)^

				switch combo {
					case "ctrl+v": {
						if clipboard_has_content() {
							// NOTE could be big clip
							text := clipboard_get_string(context.temp_allocator)
							color, ok := color_parse_string(text)

							if ok {
								picker := cast(^Color_Picker) element.data
								if picker.color_mod != nil {
									picker.color_mod^ = color
			
									for w in gs.windows {
										w.update_next = true
									}
								}
							}
						}
					}

					case "up": {
						using theme_editor

						if panel_selected_index > 0 {
							panel_selected_index -= 1
							window.update_next = true
						}
					}

					case "down": {
						using theme_editor
						color_amount := size_of(Theme) / size_of(Color)
						
						if panel_selected_index < color_amount - 1 {
							panel_selected_index += 1
							window.update_next = true
						}
					}
				}
			}

			case .Destroy: {
				theme_editor.open = false
			}
		}

		return 0
	}
	theme_editor.window = window

	panel := panel_init(&window.element, { .CF, .Panel_Scrollable, .Panel_Default_Background })
	panel.margin = 10
	
	label := label_init(panel, { .CT }, "Theme Editor")
	label.font_options = &font_options_header

	SPACER_WIDTH :: 20
	spacer_init(panel, { .CT, .CF }, 0, SPACER_WIDTH, .Thin)
	
	Color_Pair :: struct {
		color: ^Color,
		index: int,
	}

	color_slider :: proc(parent: ^Element, color_mod: ^Color, name: string) {
		slider_panel := panel_init(parent, { .CT }, 40, 5, 5)
		slider_panel.message_user = proc(element: ^Element, msg: Message, di: int, dp: rawptr) -> int {
			panel := cast(^Panel) element
			
			if msg == .Paint_Recursive {
				target := element.window.target

				panel_selected := theme_editor.panel_list[theme_editor.panel_selected_index]
				if panel == panel_selected {
					render_rect(target, element.bounds, theme.background[2], style.roundness)
				}
			}

			return 0
		}
		slider_panel.data = color_mod
		theme_editor.panel_list[theme_editor.panel_list_index] = slider_panel
		theme_editor.panel_list_index += 1
		label_init(slider_panel, { .CL }, name)

		for i in 0..<4 {
			value := &color_mod[3 - i]
			s := slider_init(slider_panel, { .CR }, f32(value^) / 255)
			s.data = value
			
			s.message_user = proc(element: ^Element, msg: Message, di: int, dp: rawptr) -> int {
				slider := cast(^Slider) element

				#partial switch msg {
					case .Value_Changed: {
						value := cast(^u8) element.data
						value^ = u8(slider.position * 255)
						
						for i in 0..<theme_editor.panel_list_index {
							panel := theme_editor.panel_list[i]
							if panel == cast(^Panel) element.parent {
								theme_editor.panel_selected_index = i
								break
							}
						}

						for w in gs.windows {
							w.update_next = true
						}
					}

					case .Reformat: {
						strings.builder_reset(&slider.builder)
						fmt.sbprintf(&slider.builder, "%d", u8(slider.position * 255))
						return 1
					}

					case .Deallocate_Recursive: {
						free(slider.data)
					}
				} 

				return 0
			}
		}
	}

	color_slider(panel, &theme.background[0], "background 0")
	color_slider(panel, &theme.background[1], "background 1")
	color_slider(panel, &theme.background[2], "background 2")
	color_slider(panel, &theme.shadow, "shadow")
	spacer_init(panel, { .CT, .CF }, 0, SPACER_WIDTH, .Thin)
	color_slider(panel, &theme.text_default, "text default")
	color_slider(panel, &theme.text_blank, "text blank")
	color_slider(panel, &theme.text_good, "text good")
	color_slider(panel, &theme.text_bad, "text bad")
	spacer_init(panel, { .CT, .CF }, 0, SPACER_WIDTH, .Thin)
	color_slider(panel, &theme.caret, "caret")
	color_slider(panel, &theme.caret_highlight, "caret highlight")
	color_slider(panel, &theme.caret_selection, "caret selection")
	spacer_init(panel, { .CT, .CF }, 0, SPACER_WIDTH, .Thin)
	color_slider(panel, &theme.panel_back, "panel back")
	color_slider(panel, &theme.panel_front, "panel front")

	spacer_init(panel, { .CT, .CF }, 0, SPACER_WIDTH, .Thin)
	picker := color_picker_init(panel, { .CT }, 0)
	picker.sv.message_user = proc(element: ^Element, msg: Message, di: int, dp: rawptr) -> int {
		sv := cast(^Color_Picker_SV) element
		hue := cast(^Color_Picker_HUE) element.parent.children[1]

		if msg == .Value_Changed {
			p := theme_editor.panel_list[theme_editor.panel_selected_index]
			
			color_mod := cast(^Color) p.data
			output := color_hsv_to_rgb(hue.y, sv.x, 1 - sv.y)
			color_mod^ = output
			
			for i in 0..<4 {
				slider := cast(^Slider) p.children[1 + i]
				value := cast(^u8) slider.data
				slider.position = f32(value^) / 255
				element_message(slider, .Reformat)
			}

			// update all windows on change
			for w in gs.windows {
				w.update_next = true
			}
		}

		return 0
	}
	theme_editor.picker = picker
	panel.data = picker
	window.element.data = picker

	// button_init(panel, { .CT, .CF }, "Randomize").invoke = proc(data: rawptr) {
	// 	total_size := size_of(Theme) / size_of(Color)
		
	// 	for i in 0..<total_size {
	// 		root := uintptr(&theme) + uintptr(i * size_of(Color))
	// 		color := cast(^Color) root
	// 		color.r = u8(rand.float32() * 255)
	// 		color.g = u8(rand.float32() * 255)
	// 		color.b = u8(rand.float32() * 255)
	// 	}

	// 	// button := cast(^Button) data
	// 	// for child in button.parent.children {
	// 	// 	log.info("yo")
	// 	// 	if child.message_class == slider_message {
	// 	// 		log.info("tried")
	// 	// 		value := cast(^u8) child.data
	// 	// 		slider := cast(^Slider) child
	// 	// 		slider.position = f32(value^) / 255
	// 	// 		element_message(child, .Reformat)
	// 	// 	}
	// 	// }

	// 	for w in gs.windows {
	// 		w.update_next = true
	// 	}
	// }
}

color_parse_string :: proc(text: string) -> (res: Color, ok: bool) {
	text := text

	if text[:2] == "0x" {
		text = string(text[2:])
	}

	if text[:1] == "#" {
		text = string(text[1:])
	}

	if len(text) == 6 {
		v :: proc(text: string) -> u8 {
			value, _ := strconv.parse_int(text, 16)
			return u8(value)
		}

		r := v(text[:2])
		g := v(text[2:4])
		b := v(text[4:6])
		ok = true
		res = { r, g, b, 255 }
	}

	return
}