package src

import "core:os"
import "core:slice"
import "core:mem"
import "core:math"
import "core:math/rand"
import "core:log"
import "core:strconv"
import "core:strings"
import "core:fmt"
import "core:encoding/json"

Theme_Editor :: struct {
	open: bool,
	panel: ^Panel,
	grid: ^Static_Grid,
	window: ^Window,
	lines: [64]^Element,
	line_index: int,
	line_selected: int,
	skips: [7]int,

	color_modify: ^Color,
	color_copy: Color,
	theme_previous: Theme,

	rgb_bgr: ^Checkbox,
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

theme_load_from :: proc(temp: Theme_Save_Load) {
	temp := temp
	count := size_of(Theme) / size_of(Color)
	for i in 0..<count {
		from := mem.ptr_offset(cast(^u32) &temp, i)
		to := mem.ptr_offset(cast(^Color) &theme, i)
		to^ = transmute(Color) from^
	}
}

Theme_Panel :: enum {
	Parent,
	Front,
}

theme_panel :: #force_inline proc(panel: Theme_Panel) -> Color #no_bounds_check {
	return theme.panel[panel]
}

Theme_Preset :: struct {
	theme: Theme,
	name: string,
}

theme_presets: [dynamic]Theme_Preset
theme: Theme

theme_presets_destroy :: proc() {
	for preset in theme_presets {
		delete(preset.name)
	}

	delete(theme_presets)
}

theme_preset_add :: proc(name: string, theme: Theme) {
	append(&theme_presets, Theme_Preset {
		theme,
		strings.clone(name),
	})
}

theme_presets_init :: proc() {
	theme_presets = make([dynamic]Theme_Preset, 0, 32)

	theme_preset_add("light", {
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
	})

	theme_preset_add("black", {
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
	})

	theme_preset_add("beach", Theme{background = {{131, 229, 236, 255}, {202, 255, 198, 255}, {173, 221, 138, 255}}, panel = {{255, 224, 82, 255}, {239, 255, 200, 255}}, text_default = {68, 68, 68, 255}, text_blank = {106, 82, 122, 255}, text_good = {241, 51, 165, 255}, text_bad = {54, 84, 255, 255}, text_link = {144, 76, 76, 255}, text_date = {111, 99, 99, 255}, shadow = {0, 0, 0, 255}, caret = {255, 0, 0, 255}, caret_selection = {255, 202, 202, 255}, tags = {{38, 168, 76, 0}, {0, 0, 0, 0}, {131, 229, 236, 255}, {202, 255, 198, 255}, {173, 221, 138, 255}, {255, 224, 82, 255}, {239, 255, 200, 255}, {68, 68, 68, 255}}})
	theme_preset_add("dark purple", Theme{background = {{32, 30, 48, 255}, {19, 13, 36, 255}, {0, 0, 0, 255}}, panel = {{0, 0, 0, 255}, {42, 9, 45, 255}}, text_default = {255, 255, 255, 255}, text_blank = {216, 215, 243, 255}, text_good = {107, 103, 117, 255}, text_bad = {189, 149, 174, 255}, text_link = {181, 205, 137, 255}, text_date = {54, 104, 249, 255}, shadow = {110, 110, 110, 255}, caret = {220, 168, 110, 255}, caret_selection = {221, 133, 85, 255}, tags = {{207, 56, 139, 255}, {170, 86, 133, 255}, {111, 114, 126, 255}, {169, 153, 170, 255}, {114, 66, 137, 255}, {206, 129, 146, 255}, {104, 35, 104, 255}, {133, 100, 108, 255}}})
	theme_preset_add("dark green", Theme{background = {{0, 52, 2, 255}, {9, 28, 10, 255}, {0, 0, 0, 255}}, panel = {{49, 139, 101, 255}, {32, 122, 84, 255}}, text_default = {255, 255, 255, 255}, text_blank = {202, 202, 202, 255}, text_good = {77, 255, 130, 255}, text_bad = {241, 162, 59, 255}, text_link = {255, 255, 255, 255}, text_date = {255, 255, 255, 255}, shadow = {0, 0, 0, 255}, caret = {255, 22, 22, 255}, caret_selection = {213, 89, 89, 255}, tags = {{49, 139, 101, 255}, {49, 139, 101, 255}, {49, 139, 101, 255}, {49, 139, 101, 255}, {49, 139, 101, 255}, {49, 139, 101, 255}, {32, 122, 84, 255}, {255, 255, 255, 255}}})
	theme_preset_add("white green", Theme{background = {{232, 238, 229, 255}, {240, 233, 232, 255}, {255, 255, 255, 255}}, panel = {{255, 255, 255, 255}, {247, 250, 234, 255}}, text_default = {100, 100, 100, 255}, text_blank = {98, 122, 100, 255}, text_good = {18, 190, 21, 255}, text_bad = {187, 29, 116, 255}, text_link = {125, 196, 98, 255}, text_date = {190, 170, 155, 255}, shadow = {0, 0, 0, 255}, caret = {177, 137, 52, 255}, caret_selection = {191, 141, 76, 255}, tags = {{143, 51, 96, 255}, {157, 25, 137, 255}, {189, 33, 122, 255}, {185, 106, 81, 255}, {181, 96, 147, 255}, {173, 134, 132, 255}, {120, 37, 67, 255}, {136, 141, 93, 255}}})
	theme_preset_add("white orange", Theme{background = {{222, 222, 227, 255}, {224, 233, 238, 255}, {240, 240, 240, 255}}, panel = {{240, 240, 240, 255}, {238, 233, 225, 255}}, text_default = {0, 0, 0, 255}, text_blank = {1, 49, 11, 255}, text_good = {192, 148, 34, 255}, text_bad = {23, 29, 249, 255}, text_link = {158, 69, 188, 255}, text_date = {171, 11, 87, 255}, shadow = {0, 0, 0, 255}, caret = {229, 79, 62, 255}, caret_selection = {221, 75, 59, 255}, tags = {{156, 146, 234, 255}, {80, 164, 142, 255}, {160, 138, 236, 255}, {95, 129, 183, 255}, {186, 74, 194, 255}, {144, 125, 145, 255}, {90, 152, 185, 255}, {119, 126, 119, 255}}})
	theme_preset_add("nord", Theme{background = {{46, 52, 64, 255}, {59, 66, 82, 255}, {67, 76, 94, 255}}, panel = {{62, 71, 89, 255}, {76, 86, 106, 255}}, text_default = {216, 222, 233, 255}, text_blank = {202, 208, 220, 255}, text_good = {80, 224, 80, 255}, text_bad = {208, 65, 65, 255}, text_link = {110, 172, 248, 255}, text_date = {110, 172, 248, 255}, shadow = {39, 46, 61, 255}, caret = {136, 192, 208, 255}, caret_selection = {136, 192, 208, 255}, tags = {{255, 255, 255, 255}, {209, 209, 209, 255}, {193, 193, 193, 255}, {155, 155, 155, 255}, {89, 89, 89, 255}, {69, 69, 69, 255}, {48, 48, 48, 255}, {0, 0, 0, 255}}})
	theme_preset_add("witness", Theme{background = {{7, 38, 38, 255}, {7, 33, 40, 255}, {15, 53, 51, 255}}, panel = {{30, 56, 51, 255}, {24, 50, 47, 255}}, text_default = {179, 147, 105, 255}, text_blank = {183, 155, 113, 255}, text_good = {73, 130, 25, 255}, text_bad = {137, 34, 34, 255}, text_link = {183, 155, 113, 255}, text_date = {183, 155, 113, 255}, shadow = {0, 0, 0, 255}, caret = {145, 211, 147, 255}, caret_selection = {255, 104, 180, 255}, tags = {{255, 255, 255, 255}, {204, 204, 204, 255}, {169, 169, 169, 255}, {123, 123, 123, 255}, {83, 83, 83, 255}, {52, 52, 52, 255}, {33, 33, 33, 255}, {0, 0, 0, 255}}})
	theme_preset_add("monokai", Theme{background = {{46, 46, 46, 255}, {77, 77, 77, 255}, {121, 121, 121, 255}}, panel = {{126, 126, 126, 255}, {88, 88, 88, 255}}, text_default = {246, 246, 246, 255}, text_blank = {178, 178, 178, 255}, text_good = {167, 226, 46, 255}, text_bad = {102, 217, 238, 255}, text_link = {174, 129, 255, 255}, text_date = {174, 129, 255, 255}, shadow = {0, 0, 0, 255}, caret = {249, 39, 114, 255}, caret_selection = {255, 140, 181, 255}, tags = {{38, 168, 76, 0}, {0, 0, 0, 0}, {131, 229, 236, 255}, {202, 255, 198, 255}, {173, 221, 138, 255}, {255, 224, 82, 255}, {239, 255, 200, 255}, {68, 68, 68, 255}}})
	theme_preset_add("candy", Theme{background = {{255, 199, 213, 255}, {255, 168, 189, 255}, {255, 126, 157, 255}}, panel = {{255, 76, 120, 255}, {255, 126, 157, 255}}, text_default = {255, 255, 255, 255}, text_blank = {41, 41, 41, 255}, text_good = {230, 255, 107, 255}, text_bad = {153, 58, 243, 255}, text_link = {255, 255, 255, 255}, text_date = {255, 255, 255, 255}, shadow = {76, 35, 49, 255}, caret = {85, 214, 219, 255}, caret_selection = {192, 235, 237, 255}, tags = {{255, 168, 189, 255}, {255, 168, 189, 255}, {255, 168, 189, 255}, {255, 168, 189, 255}, {255, 126, 157, 255}, {255, 76, 120, 255}, {255, 126, 157, 255}, {255, 255, 255, 255}}})
}

theme_task_text :: #force_inline proc(state: Task_State) -> Color {
	switch state {
		case .Normal: return theme.text_default
		case .Done: return theme.text_good
		case .Canceled: return theme.text_bad
	}

	return {}
}

// simple line with internal layout based on parent
Static_Line :: struct {
	using element: Element,
	cell_sizes: ^[]int,
	index: int,
}

static_line_init :: proc(
	parent: ^Element,
	cell_sizes: ^[]int,
	index: int = -1,
) -> (res: ^Static_Line) {
	res = element_init(Static_Line, parent, {}, static_line_message, context.allocator)
	res.cell_sizes = cell_sizes
	res.index = index
	return
}

static_line_message :: proc(element: ^Element, msg: Message, di: int, dp: rawptr) -> int {
	sl := cast(^Static_Line) element
	
	#partial switch msg {
		case .Layout: {
			assert(len(sl.cell_sizes) == len(element.children))
			padding := rect_xxyy(0, int(SCALE * 2))
			bounds := rect_padding(element.bounds, padding) 

			for child, i in element.children {
				size := int(f32(sl.cell_sizes[i]) * SCALE)
				rect := rect_cut_left(&bounds, size)
				element_move(child, rect)
			}
		}

		case .Clicked: {
			if sl.index != -1 {
				theme_editor.line_selected = sl.index
			}
		}

		case .Get_Cursor: {
			return int(Cursor.Hand)
		}

		case .Paint_Recursive: {
			target := element.window.target
			hovered := element.window.hovered
			
			if 
				sl.index != -1 && 
				hovered != nil && 
				(hovered == element || hovered.parent == element) {
				render_hovered_highlight(target, element.bounds)
			}
				
			if theme_editor.line_selected == sl.index {
				render_hovered_highlight(target, element.bounds)
			}
		}

		case .Update: {
			element_repaint(element)
		}
	}

	return 0
}

// layouts children in a grid, where 
Static_Grid :: struct {
	using element: Element,
	cell_sizes: []int,
	cell_height: int,
}

static_grid_init :: proc(
	parent: ^Element,
	flags: Element_Flags,
	cell_sizes: []int,
	cell_height: int,
) -> (res: ^Static_Grid) {
	res = element_init(Static_Grid, parent, flags, static_grid_message, context.allocator)
	assert(len(cell_sizes) > 1)
	res.cell_sizes = slice.clone(cell_sizes)
	res.cell_height = cell_height
	return
}

theme_editor_lines :: proc() -> []^Element {
	return theme_editor.lines[:theme_editor.line_index]
}

theme_editor_skips_finalize :: proc() {
	lines := theme_editor_lines()
	skip := theme_editor.skips[0]
	skip_index: int

	for line, i in lines {
		toggle := cast(^Toggle_Simple) line.children[3]
		
		if i == skip {
			toggle.state = true
			skip_index += 1
			skip = theme_editor.skips[skip_index]
		} else {
			toggle.state = false
		}
	}
}

static_grid_message :: proc(element: ^Element, msg: Message, di: int, dp: rawptr) -> int {
	sg := cast(^Static_Grid) element

	#partial switch msg {
		case .Layout: {
			total := element.bounds
			height := int(f32(sg.cell_height) * SCALE)

			// layout elements
			for child, i in element.children {
				h := element_message(child, .Get_Height) 
				if h == 0 {
					h = height
				}
				element_move(child, rect_cut_top(&total, h))
			}
		}

		case .Get_Width: {
			sum: int

			for i in 0..<len(sg.cell_sizes) {
				sum += int(f32(sg.cell_sizes[i]) * SCALE)
			}

			return sum
		}

		case .Get_Height: {
			sum: int
			height := int(f32(sg.cell_height) * SCALE)

			for child, i in element.children {
				h := element_message(child, .Get_Height) 
				if h == 0 {
					h = height
				}
				sum += h
			}

			return sum
		}

		case .Destroy: {
			delete(sg.cell_sizes)
		}
	}

	return 0
}

static_grid_line_count :: proc(sg: ^Static_Grid) -> int {
	return len(sg.children)
}

// simple toggle with state
Toggle_Simple :: struct {
	using element: Element,
	state: bool,
	invoke: proc(toggle: ^Toggle_Simple),
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

		case .Update: {
			element_repaint(element)
		}

		case .Clicked: {
			if toggle.invoke != nil {
				toggle->invoke()
			} else {
				toggle.state = !toggle.state
			}

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

		case .Update: {
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

theme_editor_variation_reset :: proc() {
	lines := theme_editor_lines()

	for line in lines {
		slider := cast(^Slider) line.children[4]
		slider.position = 1
	}

	window_repaint(theme_editor.window)
}

theme_editor_skip_from_to :: proc(line_index: int) -> (from, to: int) {
	for skip, i in theme_editor.skips {
		if skip == -1 {
			continue
		}

		if skip <= line_index {
			from = skip
		} else if skip >= line_index {
			to = skip
			break
		}
	}		

	return
}

theme_editor_root_reset :: proc() {
	theme_editor_skips_finalize()
	window_repaint(theme_editor.window)
}

theme_editor_locked_reset :: proc() {
	lines := theme_editor_lines()
	for line in lines {
		toggle := cast(^Toggle_Simple) line.children[2]
		toggle.state = false
	}
	window_repaint(theme_editor.window)
}

theme_editor_root_set :: proc(toggle: ^Toggle_Simple) {
	lines := theme_editor_lines()
	line := cast(^Static_Line) toggle.parent
	from, to := theme_editor_skip_from_to(line.index)

	for i in from..<to {
		real := lines[i]
		other := cast(^Toggle_Simple) real.children[3]
		other.state = false
	}
	
	toggle.state = true
}

theme_randomize_all :: proc(tags_only: bool) {
	lines := theme_editor_lines() 
	other: [32]int
	other_index: int
	skips := theme_editor.skips[:] if !tags_only else theme_editor.skips[4:]

	for skip, i in skips {
		if skip != -1 {
			root_color: ^Color
			locked: bool
			other_index = 0
			
			from, to := skip, skips[i + 1]
			if to == -1 {
				break
			}

			// find root
			for line_index in from..<to {
				line := lines[line_index]
				lock := cast(^Toggle_Simple) line.children[2]
				root := cast(^Toggle_Simple) line.children[3]

				if root.state {
					button := cast(^Color_Button) line.children[1]
					locked = lock.state
					root_color = button.color
				} else {
					// add other 
					other[other_index] = line_index
					other_index += 1
				}
			}

			if !locked {
				root_color^ = color_rand_non_alpha()
			}

			for line_index in other[:other_index] {
				line := lines[line_index]
				lock := cast(^Toggle_Simple) line.children[2]
				
				if !lock.state {
					button := cast(^Color_Button) line.children[1]
					newish := color_rand_non_alpha()
					slider := cast(^Slider) line.children[4]
					button.color^ = color_blend_amount(newish, root_color^, slider.position)
				}
			}
		}
	}

	gs_update_all_windows()
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
		window := cast(^Window) element

		#partial switch msg {
			case .Dropped_Text: {
				content := window_dropped_text(window)
				theme_load_parse_json(transmute([]byte) content)
			}

			case .Key_Combination: {
				combo := (cast(^string) dp)^
				handled := true

				switch combo {
					case "space": {
						theme_randomize_all(false)
					}

					case "return": {
						theme_randomize_all(true)
					}

					case "ctrl s": {
						json_save_misc("save.sjson")
					}

					case "ctrl c": {
						lines := theme_editor_lines()
						line := lines[theme_editor.line_selected]
						button := cast(^Color_Button) line.children[1]
						theme_editor.color_copy = button.color^
					}

					case "ctrl v": {
						found: bool

						if clipboard_has_content() {
							// NOTE could be big clip
							text := clipboard_get_string(context.temp_allocator)
							color, ok := color_parse_string(text)

							if ok {
								lines := theme_editor_lines()
								line := lines[theme_editor.line_selected]
								button := cast(^Color_Button) line.children[1]
								button.color^ = color
								gs_update_all_windows()
								found = true
							}
						} 

						if !found && theme_editor.color_copy != {} {
							lines := theme_editor_lines()
							line := lines[theme_editor.line_selected]
							button := cast(^Color_Button) line.children[1]
							button.color^ = theme_editor.color_copy
							gs_update_all_windows()
						}
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
	theme_editor.panel = panel_init(&window.element, { .HF, .VF, .Sort_By_Z_Index })

	{
		p := panel_init(theme_editor.panel, { .HF, .Panel_Default_Background, .Panel_Horizontal })
		p.background_index = 2
		p.z_index = 255

		b2 := button_init(p, {}, "Randomize All")
		b2.hover_info = "Press SPACE to generate"
		b2.invoke = proc(button: ^Button, data: rawptr) {
			theme_randomize_all(false)
		}	

		b3 := button_init(p, {}, "Randomize Tags")
		b3.hover_info = "Press ENTER to generate tag colors only"
		b3.invoke = proc(button: ^Button, data: rawptr) {
			theme_randomize_all(true)
		}	

		b4 := button_init(p, {}, "Reset Previous")
		b4.hover_info = "Resets to the theme when the theme editor was started"
		b4.invoke = proc(button: ^Button, data: rawptr) {
			theme = theme_editor.theme_previous
			gs_update_all_windows()
		}

		b5 := button_init(p, {}, "Presets")
		b5.hover_info = "Right Click empty space to open presets"
		b5.invoke = proc(button: ^Button, data: rawptr) {
			theme_editor_menu_colors()
		}

		when !TODOOL_RELEASE {
			// temp print theme
			button_init(p, {}, "Print").invoke = proc(button: ^Button, data: rawptr) {
				builder := strings.builder_make_len_cap(0, mem.Kilobyte, context.temp_allocator)
				fmt.sbprint(&builder, theme)

				for b, i in builder.buf {
					if b == '[' { builder.buf[i] = '{' }
					if b == ']' { builder.buf[i] = '}' }
				}

				fmt.eprintln(strings.to_string(builder))
			}
		} 

		theme_editor.rgb_bgr = checkbox_init(p, {}, "Paste RGB / BGR", false)
	}

	color_line :: proc(
		parent: ^Element, 
		cell_sizes: ^[]int,
		color_mod: ^Color, 
		name: string,
		variation_value: f32,
	) {
		line := static_line_init(parent, cell_sizes, theme_editor.line_index)
		theme_editor.lines[theme_editor.line_index] = line
		theme_editor.line_index += 1
		label_init(line, { .Label_Right }, name)

		cb := color_button_init(line, {}, color_mod)
		cb.invoke = proc(button: ^Color_Button, data: rawptr) {
			theme_editor_menu_picker(button.color)
		}

		toggle1 := toggle_simple_init(line, false)

		toggle2 := toggle_simple_init(line, false)
		toggle2.invoke = theme_editor_root_set

		variation := slider_init(line, {}, variation_value)
		variation.formatting = proc(builder: ^strings.Builder, position: f32) {
			fmt.sbprintf(builder, "%d%%", int(position * 100))
		}
	}

	{
		p := panel_init(theme_editor.panel, { .HF, .VF, .Panel_Default_Background, .Panel_Scroll_Vertical })
		p.margin = 10
		p.message_user = proc(element: ^Element, msg: Message, di: int, dp: rawptr) -> int {	
			panel := cast(^Panel) element

			if msg == .Right_Down {
				theme_editor_menu_colors()
			}

			return 0
		}

		sg := static_grid_init(
			p,
			{},
			{ 200, 100, 75, 75, 100 },
			40,
		)
		theme_editor.grid = sg
		sizes := &sg.cell_sizes
		space :: proc(parent: ^Element) {
			spacer := spacer_init(parent, {}, 2, 10, .Thin)
			spacer.color = &theme.background[2]
		}

		{
			line := static_line_init(sg, sizes)
			button_reset_init(line, "Name")
			button_reset_init(line, "Color")
			button_reset_init(line, "Locked", theme_editor_locked_reset)
			button_reset_init(line, "Root", theme_editor_root_reset)
			button_reset_init(line, "Variation", theme_editor_variation_reset)
		}
		space(sg)

		color_line(sg, sizes, &theme.background[0], "background 0", 0.05)
		color_line(sg, sizes, &theme.background[1], "background 1", 0.05)
		color_line(sg, sizes, &theme.background[2], "background 2", 0.1)
		space(sg)

		color_line(sg, sizes, &theme.panel[0], "panel parent", 0.2)
		color_line(sg, sizes, &theme.panel[1], "panel front", 0.2)
		color_line(sg, sizes, &theme.shadow, "shadow", 0.5)
		space(sg)

		color_line(sg, sizes, &theme.text_default, "default", 0.2)
		color_line(sg, sizes, &theme.text_blank, "blank", 0.2)
		color_line(sg, sizes, &theme.text_good, "good", 0.8)
		color_line(sg, sizes, &theme.text_bad, "bad", 0.8)
		color_line(sg, sizes, &theme.text_link, "link", 0.4)
		color_line(sg, sizes, &theme.text_date, "date", 0.4)
		space(sg)

		color_line(sg, sizes, &theme.caret, "caret", 0.25)
		color_line(sg, sizes, &theme.caret_selection, "caret selection", 0.25)
		space(sg)

		for i in 0..<8 {
			color_line(sg, sizes, &theme.tags[i], fmt.tprintf("tag %d", i), 0.4)
		}

		theme_editor.skips = { 0, 3, 6, 12, 14, theme_editor.line_index, -1 }
		theme_editor_skips_finalize()
	}
}

theme_editor_menu_picker :: proc(color: ^Color) {
	menu := menu_init(theme_editor.window, {}, 0)
	p := menu.panel
	p.shadow = true
	theme_editor.color_modify = color

	h, s, v, _ := color_rgb_to_hsv(color^)

	picker := color_picker_init(p, {}, h, s, v)
	picker.sv.message_user = proc(element: ^Element, msg: Message, di: int, dp: rawptr) -> int {
		sv := cast(^Color_Picker_SV) element

		if msg == .Value_Changed {
			hue := cast(^Color_Picker_HUE) element.parent.children[1]
			
			output := color_hsv_to_rgb(hue.y, sv.x, 1 - sv.y)
			theme_editor.color_modify^ = output

			gs_update_all_windows()
		}

		return 0
	}

	menu_show(menu)
}

theme_editor_menu_colors :: proc() {
	menu := menu_init(theme_editor.window, {}, 0)
	defer menu_show(menu)
	
	p := menu.panel
	p.shadow = true
	
	for preset in &theme_presets {
		b := button_init(p, { .HF }, preset.name)
		b.data = &preset.theme
		b.invoke = proc(button: ^Button, data: rawptr) {
			goal := cast(^Theme) data
			theme = goal^
		}
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

		if theme_editor.rgb_bgr.state {
			r, b = b, r
		}

		ok = true
		res = { r, g, b, 255 }
	}

	return
}

theme_load_parse_json :: proc(data: []byte) {
	temp: Theme_Save_Load
	arena, _ := arena_scoped(mem.Megabyte * 2)
	err := json.unmarshal(data, &temp, .MJSON, mem.arena_allocator(&arena))

	if err == nil && temp != {} {
		theme_load_from(temp)
		gs_update_all_windows()
	} else {
		text: string
		if err != nil {
			text = fmt.tprintf("Error: %v", err)
		} else {
			text = fmt.tprint("Try without \"Theme = {...}\"")
		}

		dialog_spawn(
			theme_editor.window, 
			300, 
			"JSON failed loading\n%l\n%f\n%s",
			text,
		)
	}
}