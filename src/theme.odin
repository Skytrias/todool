package src

import "core:slice"
import "core:mem"
import "core:math"
import "core:math/rand"
import "core:log"
import "core:strconv"
import "core:strings"
import "core:fmt"

Theme_Editor :: struct {
	open: bool,
	panel: ^Panel,
	grid: ^Static_Grid,
	// picker: ^Color_Picker,
	window: ^Window,

	color_copy: Color,
	theme_previous: Theme,
}
theme_editor: Theme_Editor

Theme :: struct {
	background: [3]Color, // 3 variants, lowest to highest
	panel: [2]Color, // 2 variants, parent - front

	text_default: Color,
	text_blank: Color,
	text_good: Color,
	text_bad: Color,
	text_link: Color,
	text_date: Color,

	shadow: Color,
	
	caret: Color,
	caret_selection: Color,

	tags: [8]Color,
}

Theme_Save_Load :: struct {
	background: [3]u32, // 3 variants, lowest to highest
	panel: [2]u32, // 2 variants, parent - front

	text_default: u32,
	text_blank: u32,
	text_good: u32,
	text_bad: u32,
	text_link: u32,
	text_date: u32,

	shadow: u32,
	
	caret: u32,
	caret_selection: u32,	
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
	text_link = { 0, 0, 255, 255 },
	text_date = { 50, 160, 230, 255 },

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
	text_blank = {150, 150, 150, 255}, 
	text_good = {138, 234, 85, 255}, 
	text_bad = {77, 144, 222, 255}, 
	text_link = { 0, 0, 255, 255 },
	text_date = { 50, 160, 230, 255 },
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

// layouts children in a grid, where 
Static_Grid :: struct {
	using element: Element,
	cell_sizes: []int,
	cell_height: int,
	cell_margin: int,
	skips: []int, // where to insert spaces
}

static_grid_init :: proc(
	parent: ^Element,
	flags: Element_Flags,
	cell_sizes: []int,
	cell_height: int,
	cell_margin: int,
	skips: []int,
) -> (res: ^Static_Grid) {
	res = element_init(Static_Grid, parent, flags, static_grid_message, context.allocator)
	assert(len(cell_sizes) > 1)
	res.cell_sizes = slice.clone(cell_sizes)
	res.cell_height = cell_height
	res.cell_margin = cell_margin
	res.skips = slice.clone(skips)
	return
}

static_grid_message :: proc(element: ^Element, msg: Message, di: int, dp: rawptr) -> int {
	sg := cast(^Static_Grid) element
	SKIP_HEIGHT :: 20

	#partial switch msg {
		case .Layout: {
			total := element.bounds
			height := int(f32(sg.cell_height) * SCALE)
			temp: RectI
			wrapped: int
			margin := int(f32(sg.cell_margin) * SCALE)
			next_skip := len(sg.skips) == 0 ? -1 : sg.skips[0]
			skip_index: int
			line_index := -1

			// layout elements
			for child, i in element.children {
				// put skippers inside layouting
				if next_skip != -1 && line_index == next_skip {
					rect_cut_top(&total, int(SCALE * SKIP_HEIGHT))
					skip_index += 1
					next_skip = len(sg.skips) <= skip_index ? -1 : sg.skips[skip_index]
				}

				if wrapped >= len(sg.cell_sizes) {
					wrapped = 0
				}

				if wrapped == 0 {
					temp = rect_cut_top(&total, height)
					line_index += 1
				} 

				rect := rect_cut_left(&temp, int(f32(sg.cell_sizes[wrapped]) * SCALE))
				rect = rect_margin(rect, margin)
				element_move(child, rect)
				wrapped += 1
			}
		}

		case .Paint_Recursive: {
			target := element.window.target
			render_rect_outline(target, element.bounds, theme.background[2], ROUNDNESS)
			// render_rect_outline(target, element.bounds, RED, ROUNDNESS)
		}

		case .Get_Width: {
			sum: int

			for i in 0..<len(sg.cell_sizes) {
				sum += int(f32(sg.cell_sizes[i]) * SCALE)
			}

			return sum
		}

		case .Get_Height: {
			add := SKIP_HEIGHT * len(sg.skips)
			count := int(f32(len(sg.children)) / f32(len(sg.cell_sizes)))
			return int(SCALE * f32(sg.cell_height * count) + f32(add) * SCALE)
		}

		case .Destroy: {
			delete(sg.cell_sizes)
			delete(sg.skips)
		}
	}

	return 0
}

static_grid_iter :: proc(sg: ^Static_Grid, index: ^int) -> (start: int, ok: bool) {
	wrap_at := len(theme_editor.grid.cell_sizes)
	
	if index^ == 0 {
		index^ = wrap_at
	}

	if index^ < len(theme_editor.grid.children) {
		start = index^
		index^ += wrap_at
		ok = true
	} 

	return
}

Toggle_Simple :: struct {
	using element: Element,
	state: bool,
}

toggle_simple_init :: proc(parent: ^Element, state: bool) -> (res: ^Toggle_Simple) {
	res = element_init(Toggle_Simple, parent, {}, toggle_simple_message, context.allocator)
	return
}

toggle_simple_message :: proc(element: ^Element, msg: Message, di: int, dp: rawptr) -> int {
	toggle := cast(^Toggle_Simple) element 

	#partial switch msg {
		case .Paint_Recursive: {
			target := element.window.target
			pressed := element.window.pressed == element
			hovered := element.window.hovered == element

			icon: Icon = toggle.state ? .Check : .Close
			fcs_icon(SCALE)
			fcs_ahv()
			color := toggle.state ? theme.text_good : theme.text_bad
			fcs_color(color)

			if hovered {
				render_hovered_highlight(target, element.bounds)
			}

			render_icon_rect(target, element.bounds, icon)
		}

		case .Mouse_Move: {
			element_repaint(element)
		}

		case .Clicked: {
			toggle.state = !toggle.state
			element_repaint(element)
		}

		case .Get_Cursor: {
			return int(Cursor.Hand)
		}
	}

	return 0
}

// Button with a normal string, that changes to "Reset?" on hover
// should be used to reset things in a grid
Button_Reset :: struct {
	using element: Element,
	name: string,
	invoke: proc(),
}

button_reset_init :: proc(
	parent: ^Element, 
	name: string,
	invoke: proc() = nil,
) -> (res: ^Button_Reset) {
	res = element_init(Button_Reset, parent, {}, button_reset_message, context.allocator)
	res.name = strings.clone(name)
	res.invoke = invoke
	return
}

button_reset_message :: proc(element: ^Element, msg: Message, di: int, dp: rawptr) -> int {
	button := cast(^Button_Reset) element

	#partial switch msg {
		case .Paint_Recursive: {
			target := element.window.target
			hovered := element.window.hovered == element
			pressed := element.window.pressed == element
			interacted := (hovered || pressed) && button.invoke != nil

			if interacted {
				render_hovered_highlight(target, element.bounds)
			}

			fcs_ahv()
			fcs_font(interacted ? font_bold : font_regular)
			fcs_size(DEFAULT_FONT_SIZE * SCALE)
			fcs_color(interacted ? theme.text_good : theme.text_default)
			text := interacted ? "Reset?" : button.name
			render_string_rect(target, element.bounds, text)
		}

		case .Get_Cursor: {
			if button.invoke != nil {
				return int(Cursor.Hand)
			}
		}

		case .Clicked: {
			if button.invoke != nil {
				button.invoke()
			}
		}

		case .Mouse_Move: {
			if button.invoke != nil {
				element_repaint(element)
			}
		}

		case .Destroy: {
			delete(button.name)
		}
	}

	return 0
}

theme_panel_locked :: proc(panel: ^Panel) -> bool {
	checkbox := cast(^Checkbox) panel.children[1]
	return checkbox.state
}

theme_editor_locked_reset :: proc() {
	index: int
	sg := theme_editor.grid
	for root in static_grid_iter(sg, &index) {
		locked := cast(^Toggle_Simple) sg.children[root + 2]
		locked.state = false
	}
	element_repaint(sg)
}

theme_editor_saturation_reset :: proc() {
	index: int
	sg := theme_editor.grid
	for root in static_grid_iter(sg, &index) {
		slider := cast(^Slider) sg.children[root + 3]
		slider.position = 1
	}
	element_repaint(sg)
}

theme_editor_value_reset :: proc() {
	index: int
	sg := theme_editor.grid
	for root in static_grid_iter(sg, &index) {
		slider := cast(^Slider) sg.children[root + 4]
		slider.position = 1
	}
	element_repaint(sg)
}

theme_editor_spawn :: proc(du: u32 = COMBO_EMPTY) {
	if !theme_editor.open {
		theme_editor = {}
		theme_editor.open = true
	} else {
		window_raise(theme_editor.window)
		return
	}

	theme_editor.theme_previous = theme

	window := window_init(nil, {}, "Todool Theme Editor", i32(700 * SCALE), i32(700 * SCALE), 8, 8)
	window.element.message_user = proc(element: ^Element, msg: Message, di: int, dp: rawptr) -> int {
		#partial switch msg {
			case .Key_Combination: {
				combo := (cast(^string) dp)^
				handled := true

				switch combo {
					case "ctrl s": {
						json_save_misc("save.sjson")
					}

					// case "ctrl c": {
					// 	p := theme_selected_panel()
					// 	color_mod := cast(^Color) p.data
					// 	theme_editor.color_copy = color_mod^
					// }

					// case "ctrl v": {
					// 	found: bool

					// 	if clipboard_has_content() {
					// 		// NOTE could be big clip
					// 		text := clipboard_get_string(context.temp_allocator)
					// 		color, ok := color_parse_string(text)
					// 		// log.info("clipboard", text, ok, color)

					// 		if ok {
					// 			p := theme_selected_panel()

					// 			color_mod := cast(^Color) p.data
					// 			color_mod^ = color

					// 			theme_reformat_panel_sliders(p)
					// 			gs_update_all_windows()
					// 			found = true
					// 		}
					// 	} 

					// 	if !found && theme_editor.color_copy != {} {
					// 		p := theme_selected_panel()
					// 		color_mod := cast(^Color) p.data
					// 		color_mod^ = theme_editor.color_copy
					// 		theme_reformat_panel_sliders(p)
					// 		gs_update_all_windows()
					// 	}
					// }

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

	color_line :: proc(
		parent: ^Element, 
		color_mod: ^Color, 
		name: string,
	) {
		label_init(parent, { .Label_Right }, name)

		cb := color_button_init(parent, {}, color_mod)
		cb.invoke = proc(button: ^Color_Button, data: rawptr) {
			element_message(button.parent, .Left_Down)
		}

		toggle_simple_init(parent, false)

		sat := slider_init(parent, {}, 1)
		sat.formatting = proc(builder: ^strings.Builder, position: f32) {
			fmt.sbprintf(builder, "%.3f", position)
		}

		val := slider_init(parent, {}, 1)
		val.formatting = proc(builder: ^strings.Builder, position: f32) {
			fmt.sbprintf(builder, "%.3f", position)
		}
	}

	p := theme_editor.panel

	{
		panel_current := panel_init(p, { .HF })

		button_panel := panel_init(panel_current, { .Panel_Default_Background, .Panel_Horizontal }, 5, 0)
		button_panel.background_index = 1
		button_panel.rounded = true

		b2 := button_init(button_panel, {}, "Randomize All")
		b2.invoke = proc(button: ^Button, data: rawptr) {
			gen :: proc(low, high: f32) -> f32 {
				low := clamp(low, 0, high)
				high := clamp(high, low, 1)
				return rand.float32() * (high - low) + low
			}

			gen_hue :: proc(low, high: f32) -> f32 {
				low := clamp(low, 0, high)
				high := clamp(high, low, 1)
				res := rand.float32()
				res += 0.618033988749895
			  res = math.wrap(res, 1.0)
			  return res * (high - low) + low
			}

			sg := theme_editor.grid
			index: int
			for root in static_grid_iter(sg, &index) {
				// NOTE manual indexed based on layout
				locked := cast(^Toggle_Simple) sg.children[root + 2]

				if !locked.state {
					cb := cast(^Color_Button) sg.children[root + 1]
					sat := cast(^Slider) sg.children[root + 3]
					val := cast(^Slider) sg.children[root + 4]
					h := gen_hue(0, 1)
					s := gen(0, sat.position)
					v := gen(0, val.position)
					cb.color^ = color_hsv_to_rgb(h, s, v)
				}
			}

			gs_update_all_windows()
		}	

		r3 := button_init(button_panel, {}, "Reset Previous")
		r3.invoke = proc(button: ^Button, data: rawptr) {
			theme = theme_editor.theme_previous
			gs_update_all_windows()
		}

		r1 := button_init(button_panel, {}, "Reset / Light")
		r1.invoke = proc(button: ^Button, data: rawptr) {
			theme = theme_default_light
			gs_update_all_windows()
		}
		r2 := button_init(button_panel, {}, "Reset / Black")
		r2.invoke = proc(button: ^Button, data: rawptr) {
			theme = theme_default_black
			gs_update_all_windows()
		}

		when !TODOOL_RELEASE {
			// temp print theme
			button_init(button_panel, {}, "Print").invoke = proc(button: ^Button, data: rawptr) {
				fmt.eprintln(theme)
			}
		} 

		// LABEL_WIDTH :: 100

		// push_sliders :: proc(parent: ^Element, a, b, c: ^^Slider, static: f32, low: f32, high: f32) {
		// 	a^ = slider_init(parent, {}, static)
		// 	a^.formatting = proc(builder: ^strings.Builder, position: f32) {
		// 		fmt.sbprintf(builder, "Static %.3f", position)
		// 	}
		// 	b^ = slider_init(parent, {}, low)
		// 	b^.formatting = proc(builder: ^strings.Builder, position: f32) {
		// 		fmt.sbprintf(builder, "Low %.3f", position)
		// 	}
		// 	c^ = slider_init(parent, {}, high)
		// 	c^.formatting = proc(builder: ^strings.Builder, position: f32) {
		// 		fmt.sbprintf(builder, "High %.3f", position)
		// 	}
		// }
		// using theme_editor

		// p1 := panel_init(panel_current, { .Panel_Horizontal }, 5, 5)
		// label_init(p1, {}, "Hue", LABEL_WIDTH)
		// checkbox_hue = checkbox_init(p1, {}, "USE", true)
		// push_sliders(p1, &slider_hue_static, &slider_hue_low, &slider_hue_high, 0, 0, 1)
		
		// p2 := panel_init(panel_current, { .Panel_Horizontal }, 5, 5)
		// label_init(p2, {}, "Saturation", LABEL_WIDTH)
		// checkbox_sat = checkbox_init(p2, {}, "USE", true)
		// push_sliders(p2, &slider_sat_static, &slider_sat_low, &slider_sat_high, 1, 0.5, 0.75)
		
		// p3 := panel_init(panel_current, { .Panel_Horizontal }, 5, 5)
		// label_init(p3, {}, "Value", LABEL_WIDTH)
		// checkbox_value = checkbox_init(p3, {}, "USE", true)
		// push_sliders(p3, &slider_value_static, &slider_value_low, &slider_value_high, 1, 0.5, 1)
	}

	SPACER_WIDTH :: 10

	{
		sg := static_grid_init(
			p,
			{},
			{ 200, 100, 100, 100, 100 },
			40,
			2,
			{ 3, 6, 12, 14 },
		)
		theme_editor.grid = sg

		button_reset_init(sg, "Name")
		button_reset_init(sg, "Color")
		button_reset_init(sg, "Locked", theme_editor_locked_reset)
		button_reset_init(sg, "Saturation", theme_editor_saturation_reset)
		button_reset_init(sg, "Value", theme_editor_value_reset)

		color_line(sg, &theme.background[0], "background 0")
		color_line(sg, &theme.background[1], "background 1")
		color_line(sg, &theme.background[2], "background 2")
		
		color_line(sg, &theme.panel[0], "panel parent")
		color_line(sg, &theme.panel[1], "panel front")
		color_line(sg, &theme.shadow, "shadow")

		color_line(sg, &theme.text_default, "default")
		color_line(sg, &theme.text_blank, "blank")
		color_line(sg, &theme.text_good, "good")
		color_line(sg, &theme.text_bad, "bad")
		color_line(sg, &theme.text_link, "link")
		color_line(sg, &theme.text_date, "date")

		color_line(sg, &theme.caret, "caret")
		color_line(sg, &theme.caret_selection, "caret selection")

		for i in 0..<8 {
			color_line(sg, &theme.tags[i], fmt.tprintf("tag %d", i))
		}
	}

	// spacer_init(theme_editor.panel, { .HF }, 0, SPACER_WIDTH, .Thin)
	// {
	// 	panel := panel_init(p, { .HF })
	// 	picker := color_picker_init(panel, {}, 0)
	// 	picker.sv.message_user = proc(element: ^Element, msg: Message, di: int, dp: rawptr) -> int {
	// 		sv := cast(^Color_Picker_SV) element

	// 		if msg == .Value_Changed {
	// 			hue := cast(^Color_Picker_HUE) element.parent.children[1]
	// 			p := theme_selected_panel()
	// 			color_mod := cast(^Color) p.data
				
	// 			output := color_hsv_to_rgb(hue.y, sv.x, 1 - sv.y)
	// 			color_mod^ = output

	// 			theme_reformat_panel_sliders(p)
	// 			gs_update_all_windows()
	// 		}

	// 		return 0
	// 	}
	// 	theme_editor.picker = picker
	// 	theme_editor.panel.data = picker
	// 	window.element.data = picker
	// }	
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