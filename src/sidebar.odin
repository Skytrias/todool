package src

import "core:mem"
import "core:log"
import "core:os"
import "core:strings"
import "core:encoding/json"

Sidebar_Mode :: enum {
	Options,
	Tags,
	// Sorting
}

Sidebar :: struct {
	split: ^Split_Pane,
	enum_panel: ^Enum_Panel,
	
	mode: Sidebar_Mode,
	options: Sidebar_Options,
	tags: Sidebar_Tags,
	// sorting: Sidebar_Sorting,
}

Sidebar_Options :: struct {
	panel: ^Panel,
	slider_tab: ^Slider,
	checkbox_autosave: ^Checkbox,
	checkbox_invert_x: ^Checkbox,
	checkbox_invert_y: ^Checkbox,
	checkbox_uppercase_word: ^Checkbox,
	checkbox_use_animations: ^Checkbox,	
	checkbox_wrapping: ^Checkbox,
}

TAG_SHOW_TEXT_AND_COLOR :: 0
TAG_SHOW_COLOR :: 1
TAG_SHOW_NONE :: 2
TAG_SHOW_COUNT :: 3

tag_show_text := [TAG_SHOW_COUNT]string {
	"Text & Color",
	"Color",
	"None",
}

Tag_Data :: struct {
	builder: ^strings.Builder,
	color: Color,
}

Sidebar_Tags :: struct {
	panel: ^Panel,
	tag_data: [8]Tag_Data,
	temp_index: int,
	tag_show_mode: int,
	toggle_selector_tag: ^Toggle_Selector,
}

sb: Sidebar

sidebar_mode_toggle :: proc(to: Sidebar_Mode) {
	if (.Hide in sb.enum_panel.flags) || to != sb.mode {
		sb.mode = to
		element_hide(sb.enum_panel, false)
	} else {
		element_hide(sb.enum_panel, true)
	}
}

sidebar_button_message :: proc(element: ^Element, msg: Message, di: int, dp: rawptr) -> int {
	button := cast(^Icon_Button) element
	mode := cast(^Sidebar_Mode) element.data

	#partial switch msg {
		case .Button_Highlight: {
			color := cast(^Color) dp
			selected := (.Hide not_in sb.enum_panel.flags) && sb.mode == mode^
			color^ = selected ? theme.text_default : theme.text_blank
			return selected ? 1 : 2

		}

		case .Clicked: {
			sidebar_mode_toggle(mode^)
			element_repaint(element)
		}

		case .Deallocate_Recursive: {
			free(element.data)
		}
	}

	return 0
}

sidebar_init :: proc(parent: ^Element) -> (split: ^Split_Pane) {
	// left panel
	{
		panel_info = panel_init(parent, { .Panel_Default_Background, .VF, .Tab_Movement_Allowed }, 0, 5)
		panel_info.background_index = 2
		panel_info.z_index = 3

		i1 := icon_button_init(panel_info, { .HF }, .Cog)
		i1.message_user = sidebar_button_message
		i1.data = new_clone(Sidebar_Mode.Options)
		i1.hover_info = "Options"
		
		i2 := icon_button_init(panel_info, { .HF }, .Tag)
		i2.data = new_clone(Sidebar_Mode.Tags)
		i2.hover_info = "Tags"
		i2.message_user = sidebar_button_message

		// i3 := icon_button_init(panel_info, {}, .Sort)
		// i3.data = new_clone(Sidebar_Mode.Sorting)
		// i3.hover_info = "Sorting"
		// i3.message_user = sidebar_button_message
		
		spacer_init(panel_info, { .VF, }, 0, 20, .Thin)
		icon_button_init(panel_info, { .HF }, .Stopwatch)
		icon_button_init(panel_info, { .HF }, .Clock)
		icon_button_init(panel_info, { .HF }, .Tomato)

		spacer_init(panel_info, { }, 0, 20, .Thin)
		b1 := button_init(panel_info, { .HF }, "L")
		b1.message_user = mode_based_button_message
		b1.data = new_clone(Mode_Based_Button { 0 })
		b1.hover_info = "List Mode"
		b2 := button_init(panel_info, { .HF }, "K")
		b2.message_user = mode_based_button_message
		b2.data = new_clone(Mode_Based_Button { 1 })
		b2.hover_info = "Kanban Mode"

		// b := button_init(panel_info, { .CT, .Hover_Has_Info }, "b")
		// b.invoke = proc(data: rawptr) {
		// 	element := cast(^Element) data
		// 	window_border_toggle(element.window)
		// 	element_repaint(element)
		// }
		// b.hover_info = "border"

	}

	split = split_pane_init(parent, { .Split_Pane_Hidable, .VF, .HF, .Tab_Movement_Allowed }, 300, 300)
	sb.split = split
	sb.split.pixel_based = true

	shared_panel :: proc(element: ^Element, title: string) -> ^Panel {
		panel := panel_init(element, { .Panel_Default_Background, .Tab_Movement_Allowed }, 5, 5)
		panel.background_index = 1
		panel.z_index = 2

		header := label_init(panel, { .Label_Center }, title)
		header.font_options = &font_options_header
		spacer_init(panel, {}, 0, 5, .Thin)

		return panel
	}

	// init all sidebar panels

	enum_panel := enum_panel_init(split, { .Tab_Movement_Allowed }, cast(^int) &sb.mode, len(Sidebar_Mode))
	sb.enum_panel = enum_panel
	element_hide(sb.enum_panel, true)

	{
		temp := &sb.options
		using temp
		flags := Element_Flags { .HF }

		panel = shared_panel(enum_panel, "Options")

		slider_tab = slider_init(panel, flags, 0.5)
		slider_tab.format = "Tab: %f"

		checkbox_autosave = checkbox_init(panel, flags, "Autosave", true)
		checkbox_uppercase_word = checkbox_init(panel, flags, "Uppercase Parent Word", true)
		checkbox_invert_x = checkbox_init(panel, flags, "Invert Scroll X", false)
		checkbox_invert_y = checkbox_init(panel, flags, "Invert Scroll Y", false)
		checkbox_use_animations = checkbox_init(panel, flags, "Use Animations", true)
		checkbox_wrapping = checkbox_init(panel, flags, "Wrap in List Mode", true)
	}

	SPACER_HEIGHT :: 10

	{
		temp := &sb.tags
		temp.panel = shared_panel(enum_panel, "Tags")

		shared_box :: proc(
			panel: ^Panel, 
			text: string,
		) {
			b := text_box_init(panel, { .HF }, text)
			tag := &sb.tags.tag_data[sb.tags.temp_index]	
			tag.builder = &b.builder
			color := color_hsv_to_rgb(f32(sb.tags.temp_index) / 8, 1, 1)
			tag.color = color
			sb.tags.temp_index += 1
		}

		label_init(temp.panel, { .Label_Center }, "Tags 1-8")
		shared_box(temp.panel, "one")
		shared_box(temp.panel, "two")
		shared_box(temp.panel, "three")
		shared_box(temp.panel, "four")
		shared_box(temp.panel, "five")
		shared_box(temp.panel, "six")
		shared_box(temp.panel, "seven")
		shared_box(temp.panel, "eight")

		spacer_init(temp.panel, { .HF }, 0, SPACER_HEIGHT, .Empty)
		label_init(temp.panel, { .HF, .Label_Center }, "Tag Showcase")
		temp.toggle_selector_tag = toggle_selector_init(
			temp.panel,
			{ .HF },
			&sb.tags.tag_show_mode,
			TAG_SHOW_COUNT,
			tag_show_text[:],
		)
	}

	return
}

options_autosave :: #force_inline proc() -> bool {
	return sb.options.checkbox_autosave.state
}

options_wrapping :: #force_inline proc() -> bool {
	return sb.options.checkbox_wrapping.state
}

options_tab :: #force_inline proc() -> f32 {
	return sb.options.slider_tab.position
}

options_scroll_x :: #force_inline proc() -> int {
	return sb.options.checkbox_invert_x.state ? -1 : 1
}

options_scroll_y :: #force_inline proc() -> int {
	return sb.options.checkbox_invert_y.state ? -1 : 1
}

options_tag_mode :: #force_inline proc() -> int {
	return sb.tags.tag_show_mode
}

options_uppercase_word :: #force_inline proc() -> bool {
	return sb.options.checkbox_uppercase_word.state
}

options_use_animations :: #force_inline proc() -> bool {
	return sb.options.checkbox_use_animations.state
}

Mode_Based_Button :: struct {
	index: int,
}

mode_based_button_message :: proc(element: ^Element, msg: Message, di: int, dp: rawptr) -> int {
	button := cast(^Button) element
	info := cast(^Mode_Based_Button) element.data

	#partial switch msg {
		case .Button_Highlight: {
			color := cast(^Color) dp
			selected := info.index == int(mode_panel.mode)
			color^ = selected ? theme.text_default : theme.text_blank
			return selected ? 1 : 2
		}

		case .Clicked: {
			set := cast(^int) &mode_panel.mode
			if set^ != info.index {
				set^ = info.index
				element_repaint(element)
			}
		}

		case .Deallocate_Recursive: {
			free(element.data)
		}
	}

	return 0
}
