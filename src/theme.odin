package src

import "core:mem"
import "core:math/rand"
import "core:log"
import "core:strconv"
import "core:strings"
import "core:fmt"

Theme_Editor :: struct {
	open: bool,
	// scrollbar: ^Scrollbar,
	panel: ^Panel,
	panel_list: [32]^Panel,
	panel_list_index: int,
	panel_selected_index: int, // theme
	picker: ^Color_Picker,
	window: ^Window,

	// randomization
	checkbox_hue: ^Checkbox,
	checkbox_sat: ^Checkbox,
	checkbox_value: ^Checkbox,
	slider_hue_static: ^Slider,
	slider_hue_low: ^Slider,
	slider_hue_high: ^Slider,
	slider_sat_static: ^Slider,
	slider_sat_low: ^Slider,
	slider_sat_high: ^Slider,
	slider_value_static: ^Slider,
	slider_value_low: ^Slider,
	slider_value_high: ^Slider,

	color_copy: Color,
}
theme_editor: Theme_Editor

Theme :: struct {
	background: [3]Color, // 3 variants, lowest to highest
	panel: [2]Color, // 2 variants, parent - front

	text_default: Color,
	text_good: Color,
	text_bad: Color,
	text_blank: Color,

	shadow: Color,
	
	caret: Color,
	caret_selection: Color,

	tags: [8]Color,
}

Theme_Save_Load :: struct {
	background: [3]u32, // 3 variants, lowest to highest
	panel: [2]u32, // 2 variants, parent - front

	text_default: u32,
	text_good: u32,
	text_bad: u32,
	text_blank: u32,

	shadow: u32,
	
	caret: u32,
	caret_selection: u32,	
	
	tags: [8]u32,
}

Theme_Panel :: enum {
	Parent,
	Front,
}

theme_panel :: #force_inline proc(panel: Theme_Panel) -> Color #no_bounds_check {
	return theme.panel[panel]
}

theme_default_light := Theme {
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
	caret_selection = GREEN,

	panel = { 
		0 = { 240, 240, 240, 255 },
		1 = { 255, 255, 255, 255 },
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
theme_default_black := Theme {
	background = {
		{0, 0, 0, 255}, 
		{20, 20, 20, 255}, 
		{40, 40, 40, 255},
	}, 
	panel = {
		{50, 10, 10, 255}, 
		{40, 40, 40, 255},
	}, 
	text_default = {201, 201, 201, 255}, 
	text_good = {138, 234, 85, 255}, 
	text_bad = {77, 144, 222, 255}, 
	text_blank = {150, 150, 150, 255}, 
	shadow = {110, 110, 110, 255}, 
	caret = {252, 77, 77, 255}, 
	caret_selection = {226, 167, 32, 255}, 
	tags = {
		{255, 0, 0, 255}, 
		{255, 191, 0, 255}, 
		{127, 255, 0, 255}, 
		{0, 255, 35, 255}, 
		{0, 255, 255, 255}, 
		{255, 0, 191, 255}, 
		{199, 99, 0, 255}, 
		{199, 99, 0, 255},
	},
}
theme := theme_default_light

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
	for child in panel.children {
		if child.message_class == slider_message {
			slider := cast(^Slider) child
			value := cast(^u8) slider.data
			slider.position = f32(value^) / 255
		}
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

	window := window_init(nil, {}, "Todool Theme Editor", i32(700 * SCALE), 700)
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

	theme_editor.panel = panel_init(&window.element, { .Panel_Default_Background, .Panel_Scroll_Vertical }, 0, 5)
	theme_editor.panel.margin = 10
	
	label := label_init(theme_editor.panel, {}, "Theme Editor")
	label.font_options = &font_options_header
	
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
		color_button_init(slider_panel, { .VF }, color_mod)

		for i in 0..<4 {
			value := &color_mod[i]
			s := slider_init(slider_panel, {}, f32(value^) / 255)
			s.data = value
			s.formatting = proc(builder: ^strings.Builder, position: f32) {
				fmt.sbprintf(builder, "%d", u8(position * 255))
			}
			
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
				} 

				return 0
			}
		}
	}

	p := theme_editor.panel
	SPACER_WIDTH :: 10
	spacer_init(theme_editor.panel, { .HF }, 0, SPACER_WIDTH, .Thin)
	
	{
		t := toggle_panel_init(p, { .HF }, {}, "Background", true)
		color_slider(t.panel, &theme.background[0], "background 0")
		color_slider(t.panel, &theme.background[1], "background 1")
		color_slider(t.panel, &theme.background[2], "background 2")
	}
	
	{
		t := toggle_panel_init(p, { .HF }, {}, "Panel", true)
		color_slider(t.panel, &theme.panel[0], "panel parent")
		color_slider(t.panel, &theme.panel[1], "panel front")
		color_slider(t.panel, &theme.shadow, "shadow")
	}

	{
		t := toggle_panel_init(p, { .HF }, {}, "Text", true)
		color_slider(t.panel, &theme.text_default, "text default")
		color_slider(t.panel, &theme.text_blank, "text blank")
		color_slider(t.panel, &theme.text_good, "text good")
		color_slider(t.panel, &theme.text_bad, "text bad")
	}

	{
		t := toggle_panel_init(p, { .HF }, {}, "Caret", true)
		color_slider(t.panel, &theme.caret, "caret")
		color_slider(t.panel, &theme.caret_selection, "caret selection")
	}
	
	{
		t := toggle_panel_init(p, { .HF }, {}, "Tags", true)
		for i in 0..<8 {
			color_slider(t.panel, &theme.tags[i], fmt.tprintf("tag %d", i))
		}
	}

	spacer_init(theme_editor.panel, { .HF }, 0, SPACER_WIDTH, .Thin)
	{
		panel := panel_init(p, { .HF })
		picker := color_picker_init(panel, {}, 0)
		picker.sv.message_user = proc(element: ^Element, msg: Message, di: int, dp: rawptr) -> int {
			sv := cast(^Color_Picker_SV) element

			if msg == .Value_Changed {
				hue := cast(^Color_Picker_HUE) element.parent.children[1]
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
		theme_editor.panel.data = picker
		window.element.data = picker
	}
	
	spacer_init(theme_editor.panel, { .HF }, 0, SPACER_WIDTH, .Thin)
	{
		panel_current := panel_init(p, { .HF })

		button_panel := panel_init(panel_current, { .Panel_Default_Background, .Panel_Horizontal }, 5, 0)
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

			hue_static := theme_editor.slider_hue_static.position
			hue_low := theme_editor.slider_hue_low.position
			hue_high := theme_editor.slider_hue_high.position
			sat_static := theme_editor.slider_sat_static.position
			sat_low := theme_editor.slider_sat_low.position
			sat_high := theme_editor.slider_sat_high.position
			value_static := theme_editor.slider_value_static.position
			value_low := theme_editor.slider_value_low.position
			value_high := theme_editor.slider_value_high.position

			gen :: proc(low, high: f32) -> f32 {
				low := clamp(low, 0, high)
				high := clamp(high, low, 1)
				return rand.float32() * (high - low) + low
			}

			for i in 0..<theme_editor.panel_list_index {
				p := theme_editor.panel_list[i]
				locked := theme_panel_locked(p)

				if !locked {
					color := cast(^Color) p.data
					h := rand_hue ? gen(hue_low, hue_high) : hue_static
					s := rand_sat ? gen(sat_low, sat_high) : sat_static
					v := rand_value ? gen(value_low, value_high) : value_static
					color^ = color_hsv_to_rgb(h, s, v)
					theme_reformat_panel_sliders(p)
				}
			}

			gs_update_all_windows()
		}	

		r1 := button_init(button_panel, {}, "Reset / Light")
		r1.invoke = proc(data: rawptr) {
			theme = theme_default_light
			gs_update_all_windows()
		}
		r2 := button_init(button_panel, {}, "Reset / Black")
		r2.invoke = proc(data: rawptr) {
			theme = theme_default_black
			gs_update_all_windows()
		}
		// temp print theme
		button_init(button_panel, {}, "Print").invoke = proc(data: rawptr) {
			fmt.eprintln(theme)
		}

		LABEL_WIDTH :: 100

		push_sliders :: proc(parent: ^Element, a, b, c: ^^Slider, static: f32, low: f32, high: f32) {
			a^ = slider_init(parent, {}, static)
			a^.formatting = proc(builder: ^strings.Builder, position: f32) {
				fmt.sbprintf(builder, "Static %.3f", position)
			}
			b^ = slider_init(parent, {}, low)
			b^.formatting = proc(builder: ^strings.Builder, position: f32) {
				fmt.sbprintf(builder, "Low %.3f", position)
			}
			c^ = slider_init(parent, {}, high)
			c^.formatting = proc(builder: ^strings.Builder, position: f32) {
				fmt.sbprintf(builder, "High %.3f", position)
			}
		}
		using theme_editor

		p1 := panel_init(panel_current, { .Panel_Horizontal }, 5, 5)
		label_init(p1, {}, "Hue", LABEL_WIDTH)
		checkbox_hue = checkbox_init(p1, {}, "USE", true)
		push_sliders(p1, &slider_hue_static, &slider_hue_low, &slider_hue_high, 0, 0, 1)
		
		p2 := panel_init(panel_current, { .Panel_Horizontal }, 5, 5)
		label_init(p2, {}, "Saturation", LABEL_WIDTH)
		checkbox_sat = checkbox_init(p2, {}, "USE", true)
		push_sliders(p2, &slider_sat_static, &slider_sat_low, &slider_sat_high, 1, 0.5, 0.75)
		
		p3 := panel_init(panel_current, { .Panel_Horizontal }, 5, 5)
		label_init(p3, {}, "Value", LABEL_WIDTH)
		checkbox_value = checkbox_init(p3, {}, "USE", true)
		push_sliders(p3, &slider_value_static, &slider_value_low, &slider_value_high, 1, 0.5, 1)
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