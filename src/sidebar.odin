package src

import "core:strings"

Sidebar_Mode :: enum {
	None,	
	Options,
	Tags,
}

Sidebar :: struct {
	mode: Sidebar_Mode,
	options: Sidebar_Options,
	tags: Sidebar_Tags,
}

Sidebar_Options :: struct {
	panel: ^Panel,
	slider_tab: ^Slider,
	checkbox_autosave: ^Checkbox,
	checkbox_invert_x: ^Checkbox,
	checkbox_invert_y: ^Checkbox,
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

sidebar_mode_panel :: proc() -> ^Panel {
	switch sb.mode {
		case .None: return nil
		case .Options: return sb.options.panel
		case .Tags: return sb.tags.panel
	}

	return nil
}

sidebar_mode_toggle :: proc(to: Sidebar_Mode) {
	if to != sb.mode {
		// hide the current one
		if panel := sidebar_mode_panel(); panel != nil {
			element_hide(panel, true)
		}

		sb.mode = to
		
		// unhide the current one
		if panel := sidebar_mode_panel(); panel != nil {
			element_hide(panel, false)
		}
	} else {
		// hide the last one
		if panel := sidebar_mode_panel(); panel != nil {
			element_hide(panel, true)
		}
		
		sb.mode = .None
	}
}

sidebar_button_message :: proc(element: ^Element, msg: Message, di: int, dp: rawptr) -> int {
	button := cast(^Icon_Button) element
	mode := cast(^Sidebar_Mode) element.data

	#partial switch msg {
		case .Button_Highlight: {
			color := cast(^Color) dp
			selected := sb.mode == mode^
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

sidebar_init :: proc(window: ^Window) {
	// left panel
	{
		panel_info = panel_init(&window.element, { .CL, .Panel_Default_Background }, 35, 0, 5)
		panel_info.background_index = 2
		panel_info.z_index = 3

		b1 := button_init(panel_info, { .CB, .CF }, "L")
		b1.message_user = mode_based_button_message
		b1.data = new_clone(Mode_Based_Button { 0 })
		b1.hover_info = "List Mode"
		b2 := button_init(panel_info, { .CB, .CF }, "K")
		b2.message_user = mode_based_button_message
		b2.data = new_clone(Mode_Based_Button { 1 })
		b2.hover_info = "Kanban Mode"
		spacer_init(panel_info, { .CB, .CF }, 0, 20, .Thin)
		icon_button_init(panel_info, { .CB, .CF }, .Stopwatch)
		icon_button_init(panel_info, { .CB, .CF }, .Clock)
		icon_button_init(panel_info, { .CB, .CF }, .Tomato)
		spacer_init(panel_info, { .CB, .CF }, 0, 20, .Thin)

		// b := button_init(panel_info, { .CT, .Hover_Has_Info }, "b")
		// b.invoke = proc(data: rawptr) {
		// 	element := cast(^Element) data
		// 	window_border_toggle(element.window)
		// 	element_repaint(element)
		// }
		// b.hover_info = "border"

		i1 := icon_button_init(panel_info, { .CT, .CF }, .Cog)
		i1.message_user = sidebar_button_message
		i1.data = new_clone(Sidebar_Mode.Options)
		i1.hover_info = "Options"
		
		i2 := icon_button_init(panel_info, { .CT, .CF }, .Tag)
		i2.data = new_clone(Sidebar_Mode.Tags)
		i2.hover_info = "Tags"
		i2.message_user = sidebar_button_message
	}

	shared_panel :: proc(element: ^Element, title: string) -> ^Panel {
		panel := panel_init(element, { .CL, .Panel_Default_Background }, 300, 5, 5)
		panel.background_index = 1
		panel.z_index = 2
		element_hide(panel, true)

		header := label_init(panel, { .CT, .CF, .Label_Center }, title)
		header.font_options = &font_options_header
		spacer_init(panel, { .CT, .CF }, 0, 5, .Thin)

		return panel
	}

	// init all sidebar panels

	{
		temp := &sb.options
		temp.panel = shared_panel(&window.element, "Options")

		temp.slider_tab = slider_init(temp.panel, { .CT, .CF }, 0.5)
		temp.slider_tab.format = "Tab: %f"

		temp.checkbox_autosave = checkbox_init(temp.panel, { .CT, .CF }, "Autosave")
		temp.checkbox_invert_x = checkbox_init(temp.panel, { .CT, .CF }, "Invert Scroll X")
		temp.checkbox_invert_y = checkbox_init(temp.panel, { .CT, .CF }, "Invert Scroll Y")
	}

	{
		temp := &sb.tags
		temp.panel = shared_panel(&window.element, "Tags")

		shared_box :: proc(
			panel: ^Panel, 
			text: string,
		) {
			b := text_box_init(panel, { .CT, .CF }, text)
			tag := &sb.tags.tag_data[sb.tags.temp_index]	
			tag.builder = &b.builder
			color := color_hsv_to_rgb(f32(sb.tags.temp_index) / 8, 1, 1)
			tag.color = color
			sb.tags.temp_index += 1
		}

		label_init(temp.panel, { .CT, .CF, .Label_Center }, "Tags 1-8")
		shared_box(temp.panel, "one")
		shared_box(temp.panel, "two")
		shared_box(temp.panel, "three")
		shared_box(temp.panel, "four")
		shared_box(temp.panel, "five")
		shared_box(temp.panel, "six")
		shared_box(temp.panel, "seven")
		shared_box(temp.panel, "eight")

		spacer_init(temp.panel, { .CT, .CF }, 0, 10, .Empty)
		label_init(temp.panel, { .CT, .CF, .Label_Center }, "Tag Showcase")
		temp.toggle_selector_tag = toggle_selector_init(
			temp.panel,
			{ .CT, .CF },
			&sb.tags.tag_show_mode,
			TAG_SHOW_COUNT,
			tag_show_text[:],
		)
	}
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