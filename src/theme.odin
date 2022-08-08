package src

import "core:math/rand"
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

	checkbox_hue: ^Checkbox,
	checkbox_sat: ^Checkbox,
	checkbox_value: ^Checkbox,
	slider_hue: ^Slider,
	slider_sat: ^Slider,
	slider_value: ^Slider,

	color_copy: Color,
}
theme_editor: Theme_Editor

Theme :: struct {
	background: [3]Color, // 3 variants, lowest to highest
	panel: [3]Color, // 3 variants, back - parent - front

	text_default: Color,
	text_good: Color,
	text_bad: Color,
	text_blank: Color,

	shadow: Color,
	
	caret: Color,
	caret_highlight: Color,
	caret_selection: Color,

	tags: [8]Color,
}

Theme_Save_Load :: struct {
	background: [3]u32, // 3 variants, lowest to highest
	panel: [3]u32, // 3 variants, back - parent - front

	text_default: u32,
	text_good: u32,
	text_bad: u32,
	text_blank: u32,

	shadow: u32,
	
	caret: u32,
	caret_highlight: u32,
	caret_selection: u32,	
}

Theme_Panel :: enum {
	Back,
	Parent,
	Front,
}

theme_panel :: #force_inline proc(panel: Theme_Panel) -> Color #no_bounds_check {
	return theme.panel[panel]
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

	panel = { 
		0 = { 230, 230, 230, 255 },
		1 = { 255, 100, 100, 255 },
		2 = { 255, 255, 255, 255 },
	},

	tags = {
		{ 255, 0, 0, 255 },
		{ 255, 191, 0, 255 },
		{ 127, 255, 0, 255 },
		{ 0, 255, 35, 255 },
		{ 0, 255, 255, 255 },
		{ 255, 0, 191, 255 },
		{ 199, 99, 0, 255 },
		{ 199, 99, 0, 255 },
	},
}

theme_task_text :: #force_inline proc(state: Task_State) -> Color {
	switch state {
		case .Normal: return theme.text_default
		case .Done: return theme.text_good
		case .Canceled: return theme.text_bad
	}

	return {}
}

theme_selected_panel :: proc() -> ^Panel {
	return theme_editor.panel_list[theme_editor.panel_selected_index]
}

theme_reformat_panel_sliders :: proc(panel: ^Panel) {
	// reformat sliders		
	for i in 0..<4 {
		slider := cast(^Slider) panel.children[2 + i]
		value := cast(^u8) slider.data
		slider.position = f32(value^) / 255
		element_message(slider, .Reformat)
	}
}

theme_panel_locked :: proc(panel: ^Panel) -> bool {
	checkbox := cast(^Checkbox) panel.children[1]
	return checkbox.state
}

theme_editor_spawn :: proc() {
	if !theme_editor.open {
		theme_editor = {}
		theme_editor.open = true
	} else {
		return
	}

	window := window_init("Todool Theme Editor", 700, 900)
	window.element.message_user = proc(element: ^Element, msg: Message, di: int, dp: rawptr) -> int {
		#partial switch msg {
			case .Key_Combination: {
				combo := (cast(^string) dp)^
				handled := true

				switch combo {
					case "ctrl+s": {
						json_save_misc("save.sjson")
					}

					case "ctrl+c": {
						p := theme_selected_panel()
						color_mod := cast(^Color) p.data
						theme_editor.color_copy = color_mod^
					}

					case "ctrl+v": {
						found: bool

						if clipboard_has_content() {
							// NOTE could be big clip
							text := clipboard_get_string(context.temp_allocator)
							color, ok := color_parse_string(text)
							// log.info("clipboard", text, ok, color)

							if ok {
								p := theme_selected_panel()

								color_mod := cast(^Color) p.data
								color_mod^ = color

								theme_reformat_panel_sliders(p)
								gs_update_all_windows()
								found = true
							}
						} 

						if !found && theme_editor.color_copy != {} {
							p := theme_selected_panel()
							color_mod := cast(^Color) p.data
							color_mod^ = theme_editor.color_copy
							theme_reformat_panel_sliders(p)
							gs_update_all_windows()
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

					case "space": {
						p := theme_selected_panel()
						element_message(p.children[1], .Clicked)
						element_repaint(p)
					}

					case: {
						handled = false
					}
				}

				return int(handled)
			}

			case .Destroy: {
				theme_editor.open = false
			}
		}

		return 0
	}
	theme_editor.window = window

	panel := panel_init(&window.element, { .Panel_Scrollable, .Panel_Default_Background })
	panel.margin = 10
	
	label := label_init(panel, {}, "Theme Editor")
	label.font_options = &font_options_header

	SPACER_WIDTH :: 20
	spacer_init(panel, { .HF }, 0, SPACER_WIDTH, .Thin)
	
	Color_Pair :: struct {
		color: ^Color,
		index: int,
	}

	color_slider :: proc(parent: ^Element, color_mod: ^Color, name: string) {
		slider_panel := panel_init(parent, { .Panel_Horizontal, .HF }, 5, 5)
		slider_panel.message_user = proc(element: ^Element, msg: Message, di: int, dp: rawptr) -> int {
			panel := cast(^Panel) element

			#partial switch msg {
				case .Paint_Recursive: {
					target := element.window.target
					hovered := element.window.hovered == element

					panel_selected := theme_selected_panel()
					if panel == panel_selected {
						render_rect(target, element.bounds, theme.background[2], ROUNDNESS)
					} else if hovered {
						render_rect(target, element.bounds, color_alpha(theme.background[2], 0.5), ROUNDNESS)
					}
				}

				case .Left_Down: {
					for i in 0..<theme_editor.panel_list_index {
						p := theme_editor.panel_list[i]

						if p == panel {
							if i != theme_editor.panel_selected_index {
								element_repaint(panel)
							}

							theme_editor.panel_selected_index = i
							break
						}
					}
				}

				case .Get_Cursor: {
					return int(Cursor.Hand)
				}
			}

			return 0
		}
		slider_panel.data = color_mod
		theme_editor.panel_list[theme_editor.panel_list_index] = slider_panel
		theme_editor.panel_list_index += 1
		label_init(slider_panel, { .HF }, name)

		checkbox_init(slider_panel, {}, "Lock", false)
		color_button_init(slider_panel, {}, color_mod)

		for i in 0..<4 {
			value := &color_mod[i]
			s := slider_init(slider_panel, {}, f32(value^) / 255)
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

						gs_update_all_windows()
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
	spacer_init(panel, { .HF }, 0, SPACER_WIDTH, .Thin)
	color_slider(panel, &theme.panel[0], "panel back")
	color_slider(panel, &theme.panel[1], "panel parent")
	color_slider(panel, &theme.panel[2], "panel front")
	color_slider(panel, &theme.shadow, "shadow")
	spacer_init(panel, { .HF }, 0, SPACER_WIDTH, .Thin)
	color_slider(panel, &theme.text_default, "text default")
	color_slider(panel, &theme.text_blank, "text blank")
	color_slider(panel, &theme.text_good, "text good")
	color_slider(panel, &theme.text_bad, "text bad")
	spacer_init(panel, { .HF }, 0, SPACER_WIDTH, .Thin)
	color_slider(panel, &theme.caret, "caret")
	color_slider(panel, &theme.caret_highlight, "caret highlight")
	color_slider(panel, &theme.caret_selection, "caret selection")
	spacer_init(panel, { .HF }, 0, SPACER_WIDTH, .Thin)
	
	for i in 0..<8 {
		color_slider(panel, &theme.tags[i], fmt.tprintf("tag %d", i))
	}

	spacer_init(panel, { .HF }, 0, SPACER_WIDTH, .Thin)
	bot_panel := panel_init(panel, { .Panel_Horizontal, .HF })

	picker := color_picker_init(bot_panel, {}, 0)
	picker.sv.message_user = proc(element: ^Element, msg: Message, di: int, dp: rawptr) -> int {
		sv := cast(^Color_Picker_SV) element
		hue := cast(^Color_Picker_HUE) element.parent.children[1]

		if msg == .Value_Changed {
			p := theme_selected_panel()
			color_mod := cast(^Color) p.data
			
			output := color_hsv_to_rgb(hue.y, sv.x, 1 - sv.y)
			color_mod^ = output

			theme_reformat_panel_sliders(p)
			gs_update_all_windows()
		}

		return 0
	}
	theme_editor.picker = picker
	panel.data = picker
	window.element.data = picker
	
	{
		right_panel := panel_init(bot_panel, { .HF })

		button_panel := panel_init(right_panel, { .Panel_Default_Background, .Panel_Horizontal }, 5, 0)
		button_panel.background_index = 1
		button_panel.rounded = true

		b1 := button_init(button_panel, {}, "Randomize Simple")
		b1.invoke = proc(data: rawptr) {
			for i in 0..<theme_editor.panel_list_index {
				p := theme_editor.panel_list[i]
				locked := theme_panel_locked(p)

				if !locked {
					color := cast(^Color) p.data
					color.r = u8(rand.float32() * 255)
					color.g = u8(rand.float32() * 255)
					color.b = u8(rand.float32() * 255)
					theme_reformat_panel_sliders(p)
				}
			}
	
			gs_update_all_windows()
		}		
		b2 := button_init(button_panel, {}, "Randomize HSV")
		b2.invoke = proc(data: rawptr) {
			rand_hue := theme_editor.checkbox_hue.state
			rand_sat := theme_editor.checkbox_sat.state
			rand_value := theme_editor.checkbox_value.state

			hue := theme_editor.slider_hue.position
			sat := theme_editor.slider_sat.position
			value := theme_editor.slider_value.position

			for i in 0..<theme_editor.panel_list_index {
				p := theme_editor.panel_list[i]
				locked := theme_panel_locked(p)

				if !locked {
					color := cast(^Color) p.data
					h := rand_hue ? rand.float32() : hue
					s := rand_sat ? rand.float32() : sat
					v := rand_value ? rand.float32() : value
					color^ = color_hsv_to_rgb(h, s, v)
					theme_reformat_panel_sliders(p)
				}
			}

			gs_update_all_windows()
		}	

		LABEL_WIDTH :: 100

		p1 := panel_init(right_panel, { .Panel_Horizontal }, 5, 5)
		label_init(p1, {}, "Hue", LABEL_WIDTH)
		theme_editor.checkbox_hue = checkbox_init(p1, {}, "USE", true)
		spacer_init(p1, { .HF }, 0, 0, .Empty)
		theme_editor.slider_hue = slider_init(p1, {}, 0)
		
		p2 := panel_init(right_panel, { .Panel_Horizontal }, 5, 5)
		label_init(p2, {}, "Saturation", LABEL_WIDTH)
		theme_editor.checkbox_sat = checkbox_init(p2, {}, "USE", false)
		theme_editor.slider_sat = slider_init(p2, {}, 1)
		
		p3 := panel_init(right_panel, { .Panel_Horizontal }, 5, 5)
		label_init(p3, {}, "Value", LABEL_WIDTH)
		theme_editor.checkbox_value = checkbox_init(p3, {}, "USE", false)
		theme_editor.slider_value = slider_init(p3, {}, 1)
	}
}

// parse text to color
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