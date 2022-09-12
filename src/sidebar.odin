package src

import "core:time"
import "core:runtime"
import "core:math"
import "core:fmt"
import "core:mem"
import "core:log"
import "core:os"
import "core:strings"
import "core:encoding/json"

ARCHIVE_MAX :: 256

// push to archive text
archive_push :: proc(text: string) {
	if len(text) == 0 {
		return
	}

	// KEEP AT MAX.
	if len(sb.archive.buttons.children) == ARCHIVE_MAX {
		for i := len(sb.archive.buttons.children) - 1; i >= 1; i -= 1 {
			a := cast(^Archive_Button) sb.archive.buttons.children[i]
			b := cast(^Archive_Button) sb.archive.buttons.children[i - 1]
			strings.builder_reset(&a.builder)
			strings.write_string(&a.builder, strings.to_string(b.builder))
		}

		c := cast(^Archive_Button) sb.archive.buttons.children[0]
		strings.builder_reset(&c.builder)
		strings.write_string(&c.builder, text)
	} else {
		// log.info("LEN", len(sb.archive.buttons.children))
		archive_button_init(sb.archive.buttons, { .HF }, text)
		sb.archive.head += 1
		sb.archive.tail += 1
	}
}

archive_low_and_high :: proc() -> (low, high: int) {
	low = min(sb.archive.head, sb.archive.tail)
	high = max(sb.archive.head, sb.archive.tail)
	return
}

Sidebar_Mode :: enum {
	Options,
	Tags,
	Archive,
}

Sidebar :: struct {
	split: ^Split_Pane,
	enum_panel: ^Enum_Panel,
	
	mode: Sidebar_Mode,
	options: Sidebar_Options,
	tags: Sidebar_Tags,
	archive: Sidebar_Archive,

	pomodoro_label: ^Label,
}
sb: Sidebar

Sidebar_Options :: struct {
	panel: ^Panel,
	slider_tab: ^Slider,
	checkbox_autosave: ^Checkbox,
	checkbox_invert_x: ^Checkbox,
	checkbox_invert_y: ^Checkbox,
	checkbox_uppercase_word: ^Checkbox,
	checkbox_use_animations: ^Checkbox,	
	checkbox_wrapping: ^Checkbox,
	checkbox_bordered: ^Checkbox,
	slider_volume: ^Slider,

	slider_pomodoro_work: ^Slider,
	slider_pomodoro_short_break: ^Slider,
	slider_pomodoro_long_break: ^Slider,
	button_pomodoro_reset: ^Icon_Button,

	slider_work_today: ^Slider,
	gauge_work_today: ^Linear_Gauge,
	label_time_accumulated: ^Label,
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

Sidebar_Tags :: struct {
	panel: ^Panel,
	names: [8]^strings.Builder,
	temp_index: int,
	tag_show_mode: int,
	toggle_selector_tag: ^Toggle_Selector,
}

Sidebar_Archive :: struct {
	panel: ^Panel,
	buttons: ^Panel,
	head, tail: int,
}

sidebar_mode_toggle :: proc(to: Sidebar_Mode) {
	if (.Hide in sb.enum_panel.flags) || to != sb.mode {
		sb.mode = to
		element_hide(sb.enum_panel, false)
	} else {
		element_hide(sb.enum_panel, true)
	}
}

// button with highlight based on selected
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

		case .Destroy: {
			free(element.data)
		}
	}

	return 0
}

sidebar_panel_init :: proc(parent: ^Element) {
	panel_info = panel_init(parent, { .Panel_Default_Background, .VF, .Tab_Movement_Allowed }, 0, 5)
	panel_info.background_index = 2
	panel_info.z_index = 3

	// side options
	{
		i1 := icon_button_init(panel_info, { .HF }, .Cog, sidebar_button_message)
		i1.data = new_clone(Sidebar_Mode.Options)
		i1.hover_info = "Options"
		
		i2 := icon_button_init(panel_info, { .HF }, .Tag, sidebar_button_message)
		i2.data = new_clone(Sidebar_Mode.Tags)
		i2.hover_info = "Tags"

		i3 := icon_button_init(panel_info, { .HF }, .Archive, sidebar_button_message)
		i3.data = new_clone(Sidebar_Mode.Archive)
		i3.hover_info = "Archive"
	}

	// pomodoro
	{
		spacer_init(panel_info, { .VF, }, 0, 20, .Thin)
		i1 := icon_button_init(panel_info, { .HF }, .Tomato)
		i1.hover_info = "Start / Stop Pomodoro Time"
		i1.invoke = proc(data: rawptr) {
			element_hide(sb.options.button_pomodoro_reset, pomodoro.stopwatch.running)
			pomodoro_stopwatch_toggle()
		}
		i2 := icon_button_init(panel_info, { .HF }, .Reply)
		i2.invoke = proc(data: rawptr) {
			element_hide(sb.options.button_pomodoro_reset, pomodoro.stopwatch.running)
			pomodoro_stopwatch_reset()
			pomodoro_label_format()
			sound_play(.Timer_Stop)
		}
		i2.hover_info = "Reset Pomodoro Time"
		sb.options.button_pomodoro_reset = i2
		element_hide(i2, true)

		sb.pomodoro_label = label_init(panel_info, { .HF, .Label_Center }, "00:00")

		b1 := button_init(panel_info, { .HF }, "1", pomodoro_button_message)
		b1.hover_info = "Select Work Time"
		b2 := button_init(panel_info, { .HF }, "2", pomodoro_button_message)
		b2.hover_info = "Select Short Break Time"
		b3 := button_init(panel_info, { .HF }, "3", pomodoro_button_message)
		b3.hover_info = "Select Long Break Time"
	}

	// copy mode
	{
		copy_label_message :: proc(element: ^Element, msg: Message, di: int, dp: rawptr) -> int {
			label := cast(^Label) element

			if msg == .Paint_Recursive {
				target := element.window.target
				text := strings.to_string(label.builder)
				rev := last_was_task_copy ~ (uintptr(label.data) == uintptr(0))
				color := rev ? theme.text_default : theme.text_blank
				fcs_element(element)
				fcs_ahv()
				fcs_color(color)
				render_string_rect(target, element.bounds, text)
				// erender_string_aligned(element, text, element.bounds, color, .Middle, .Middle)
				return 1
			}

			return 0
		}

		spacer_init(panel_info, { }, 0, 20, .Thin)
		l1 := label_init(panel_info, { .HF }, "TEXT")
		l1.message_user = copy_label_message
		l1.hover_info = "Next paste will insert raw text"
		l1.data = rawptr(uintptr(0))
		l2 := label_init(panel_info, { .HF }, "TASK")
		l2.message_user = copy_label_message
		l2.hover_info = "Next paste will insert a task"
		l2.data = rawptr(uintptr(1))
	}

	// mode		
	{
		spacer_init(panel_info, { }, 0, 20, .Thin)
		b1 := button_init(panel_info, { .HF }, "L", mode_based_button_message)
		b1.data = new_clone(Mode_Based_Button { 0 })
		b1.hover_info = "List Mode"
		b2 := button_init(panel_info, { .HF }, "K", mode_based_button_message)
		b2.data = new_clone(Mode_Based_Button { 1 })
		b2.hover_info = "Kanban Mode"
	}	
}

sidebar_enum_panel_init :: proc(parent: ^Element) {
	shared_panel :: proc(element: ^Element, title: string, scrollable := true) -> ^Panel {
		// dont use scrollbar if not wanted
		parent := element
		if scrollable {
			parent = scrollbar_init(element, {})
		}

		flags := Element_Flags { .Panel_Default_Background, .Tab_Movement_Allowed }
		panel := panel_init(parent, flags, 5, 5)
		panel.background_index = 1
		// panel.z_index = 2
		panel.name = "shared panel"

		header := label_init(panel, { .Label_Center }, title)
		header.font_options = &font_options_header
		spacer_init(panel, {}, 0, 5, .Thin)

		return panel
	}

	// init all sidebar panels

	enum_panel := enum_panel_init(parent, { .Tab_Movement_Allowed }, cast(^int) &sb.mode, len(Sidebar_Mode))
	sb.enum_panel = enum_panel
	element_hide(sb.enum_panel, true)

	SPACER_HEIGHT :: 10
	spacer_scaled := SPACER_HEIGHT * SCALE

	// options
	{
		temp := &sb.options
		using temp
		flags := Element_Flags { .HF }

		panel = shared_panel(enum_panel, "Options")

		slider_tab = slider_init(panel, flags, 0.25)
		slider_tab.formatting = proc(builder: ^strings.Builder, position: f32) {
			fmt.sbprintf(builder, "Tab: %.3f%%", position)
		}

		slider_volume = slider_init(panel, flags, 1)
		slider_volume.message_user = proc(element: ^Element, msg: Message, di: int, dp: rawptr) -> int {
			slider := cast(^Slider) element

			if msg == .Value_Changed {
				value := i32(slider.position * 128)
				mix_volume_set(value)
			}

			return 0
		}
		slider_volume.formatting = proc(builder: ^strings.Builder, position: f32) {
			fmt.sbprintf(builder, "Volume: %d%%", int(position * 100))
		}

		checkbox_autosave = checkbox_init(panel, flags, "Autosave", true)
		checkbox_uppercase_word = checkbox_init(panel, flags, "Uppercase Parent Word", true)
		checkbox_invert_x = checkbox_init(panel, flags, "Invert Scroll X", false)
		checkbox_invert_y = checkbox_init(panel, flags, "Invert Scroll Y", false)
		checkbox_use_animations = checkbox_init(panel, flags, "Use Animations", true)
		checkbox_wrapping = checkbox_init(panel, flags, "Wrap in List Mode", true)
		checkbox_bordered = checkbox_init(panel, flags, "Borderless Window", false)
		checkbox_bordered.message_user = proc(element: ^Element, msg: Message, di: int, dp: rawptr) -> int {
			if msg == .Value_Changed {
				checkbox := cast(^Checkbox) element
				window_border_set(checkbox.window, !checkbox.state)
			}

			return 0
		}

		// pomodoro
		spacer_init(panel, flags, 0, spacer_scaled, .Empty)
		l1 := label_init(panel, { .HF, .Label_Center }, "Pomodoro")
		l1.font_options = &font_options_header
		
		slider_pomodoro_work = slider_init(panel, flags, 50.0 / 60.0)
		slider_pomodoro_work.formatting = proc(builder: ^strings.Builder, position: f32) {
			fmt.sbprintf(builder, "Work: %dmin", int(position * 60))
		}
		slider_pomodoro_short_break = slider_init(panel, flags, 10.0 / 60)
		slider_pomodoro_short_break.formatting = proc(builder: ^strings.Builder, position: f32) {
			fmt.sbprintf(builder, "Short Break: %dmin", int(position * 60))
		}
		slider_pomodoro_long_break = slider_init(panel, flags, 30.0 / 60)
		slider_pomodoro_long_break.formatting = proc(builder: ^strings.Builder, position: f32) {
			fmt.sbprintf(builder, "Long Break: %dmin", int(position * 60))
		}

		// statistics
		spacer_init(panel, flags, 0, spacer_scaled, .Empty)
		l2 := label_init(panel, { .HF, .Label_Center }, "Statistics")
		l2.font_options = &font_options_header

		label_time_accumulated = label_init(panel, { .HF, .Label_Center })
		b1 := button_init(panel, flags, "Reset acummulated")
		b1.invoke = proc(data: rawptr) {
			pomodoro.accumulated = {}
			pomodoro.celebration_goal_reached = false
		}

		{
			sub := panel_init(panel, { .HF, .Panel_Horizontal, .Panel_Default_Background }, 0, 2)
			sub.rounded = true
			sub.background_index = 2
			s := slider_init(sub, flags, 30.0 / 60)
			s.formatting = proc(builder: ^strings.Builder, position: f32) {
				fmt.sbprintf(builder, "Cheat: %dmin", int(position * 60))
			}

			b := button_init(sub, flags, "Add")
			b.data = s
			b.invoke = proc(data: rawptr) {
				slider := cast(^Slider) data
				// sb.options.slider_work_today.position += (slider.position / 60)
				minutes := time.Duration(slider.position * 60) * time.Minute
				pomodoro.accumulated += minutes
			}
		}

		slider_work_today = slider_init(panel, flags, 8.0 / 24)
		slider_work_today.formatting = proc(builder: ^strings.Builder, position: f32) {
			fmt.sbprintf(builder, "Goal Today: %dh", int(position * 24))
		}

		gauge_work_today = linear_gauge_init(panel, flags, 0.5, "Done Today", "Working Overtime")
		gauge_work_today.message_user = proc(element: ^Element, msg: Message, di: int, dp: rawptr) -> int {
			if msg == .Paint_Recursive {
				if pomodoro.celebrating {
					target := element.window.target
					render_push_clip(target, element.parent.bounds)
					pomodoro_celebration_render(target)
				}
			}

			return 0
		}
	}

	// tags
	{
		temp := &sb.tags
		using temp
		panel = shared_panel(enum_panel, "Tags")

		shared_box :: proc(
			panel: ^Panel, 
			text: string,
		) {
			b := text_box_init(panel, { .HF }, text)
			sb.tags.names[sb.tags.temp_index]	= &b.builder
			sb.tags.temp_index += 1
		}

		label_init(panel, { .Label_Center }, "Tags 1-8")
		shared_box(panel, "one")
		shared_box(panel, "two")
		shared_box(panel, "three")
		shared_box(panel, "four")
		shared_box(panel, "five")
		shared_box(panel, "six")
		shared_box(panel, "seven")
		shared_box(panel, "eight")

		spacer_init(panel, { .HF }, 0, spacer_scaled, .Empty)
		label_init(panel, { .HF, .Label_Center }, "Tag Showcase")
		toggle_selector_tag = toggle_selector_init(
			panel,
			{ .HF },
			&sb.tags.tag_show_mode,
			TAG_SHOW_COUNT,
			tag_show_text[:],
		)
	}

	// archive
	{
		temp := &sb.archive
		using temp
		panel = shared_panel(enum_panel, "Archive", false)

		top := panel_init(panel, { .HF, .Panel_Horizontal, .Panel_Default_Background })
		top.rounded = true
		top.background_index = 2;

		b1 := button_init(top, { .HF }, "Clear")
		b1.hover_info = "Clear all archive entries"
		b1.invoke = proc(data: rawptr) {
			panel_clear_without_scrollbar(sb.archive.buttons)
			sb.archive.head = -1
			sb.archive.tail = -1
		}
		b2 := button_init(top, { .HF }, "Copy")
		b2.hover_info = "Copy selected archive region for next task copy"
		b2.invoke = proc(data: rawptr) {
			if sb.archive.head == -1 {
				return
			}

			low, high := archive_low_and_high()
			c := sb.archive.buttons.children
			
			copy_reset()
			last_was_task_copy = true
			element_repaint(mode_panel)

			for i in low..<high + 1 {
				button := cast(^Archive_Button) c[len(c) - 1 - i]
				copy_push_empty(strings.to_string(button.builder))
			}
		}

		{
			scrollbar := scrollbar_init(panel, { .HF, .VF })
			buttons = panel_init(scrollbar, { .Panel_Default_Background }, 5, 1)
			buttons.name = "buttons panel"
			buttons.background_index = 2
			buttons.layout_elements_in_reverse = true
			// buttons.rounded = true
		}
	}
}

// cuts of text rendering at limit
// on press inserts it back to the mode_panel
// saved to save file!
Archive_Button :: struct {
	using element: Element,
	builder: strings.Builder,
	visual_index: int,
}

archive_button_message :: proc(element: ^Element, msg: Message, di: int, dp: rawptr) -> int {
	button := cast(^Archive_Button) element

	#partial switch msg {
		case .Paint_Recursive: {
			pressed := element.window.pressed == element
			hovered := element.window.hovered == element
			target := element.window.target
			text_color := hovered || pressed ? theme.text_default : theme.text_blank

			low, high := archive_low_and_high()
			if low <= button.visual_index && button.visual_index <= high {
				render_rect(target, element.bounds, theme_panel(.Front), ROUNDNESS)
				text_color = theme.text_default
			}

			text := strings.to_string(button.builder)
			rect := element.bounds
			rect.l += (5 * SCALE)
			fcs_element(element)
			fcs_ahv(.Left, .Middle)
			fcs_color(text_color)
			render_string_rect(target, rect, text)
			// erender_string_aligned(element, text, rect, text_color, .Left, .Middle)

			if hovered || pressed {
				render_rect_outline(target, element.bounds, text_color)
			}
		}

		case .Update: {
			element_repaint(element)
		}

		case .Get_Cursor: {
			return int(Cursor.Hand)
		}

		case .Clicked: {
			// head / tail setting
			if element.window.shift {
				sb.archive.tail = button.visual_index
			} else {
				sb.archive.head = button.visual_index
				sb.archive.tail = button.visual_index
			}

			element_repaint(element)
		}

		case .Get_Width: {
			text := strings.to_string(button.builder)
			fcs_element(element)
			width := max(50 * SCALE, string_width(text) + TEXT_MARGIN_HORIZONTAL * SCALE)
			return int(width)
		}

		case .Get_Height: {
			return int(efont_size(element) + TEXT_MARGIN_VERTICAL * SCALE)
		}

		case .Destroy: {
			delete(button.builder.buf)
		}
	}

	return 0
}

archive_button_init :: proc(
	parent: ^Element,
	flags: Element_Flags,
	text: string,
	allocator := context.allocator,
) -> (res: ^Archive_Button) {
	res = element_init(Archive_Button, parent, flags | { .Tab_Stop }, archive_button_message, allocator)
	res.builder = strings.builder_make(0, len(text))
	strings.write_string(&res.builder, text)
	res.visual_index = len(parent.children) - 1
	return
}

options_bordered :: #force_inline proc() -> bool {
	return sb.options.checkbox_bordered.state
}

options_volume :: #force_inline proc() -> f32 {
	return sb.options.slider_volume.position
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
	// TODO reenable
	return 1
	// return sb.options.checkbox_invert_y.state ? -1 : 1
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

		case .Paint_Recursive: {
			target := element.window.target
			pressed := element.window.pressed == element
			hovered := element.window.hovered == element
			text_color := hovered || pressed ? theme.text_default : theme.text_blank

			kind: Texture_Kind = info.index == 1 ? .Kanban : .List

			if res := element_message(element, .Button_Highlight, 0, &text_color); res != 0 {
				if res == 1 {
					rect := element.bounds
					// rect.l = rect.r - (4 * SCALE)
					rect.r = rect.l + (4 * SCALE)
					render_rect(target, rect, text_color, 0)
				}
			}

			if hovered || pressed {
				render_rect_outline(target, element.bounds, text_color)
				render_hovered_highlight(target, element.bounds)
			}

			smallest_size := min(rect_width(element.bounds), rect_height(element.bounds))
			rect := element.bounds
			rect.l += rect_width_halfed(rect) - smallest_size / 2
			rect.r = rect.l + smallest_size
			render_texture_from_kind(target, kind, rect, text_color)
			return 1
		}

		case .Destroy: {
			free(element.data)
		}
	}

	return 0
}