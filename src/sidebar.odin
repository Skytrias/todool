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

ARCHIVE_MAX :: 512
OPACITY_MIN :: 0.1
OPACITY_MAX :: 1.0
ANIMATION_SPEED_MIN :: 0.1
ANIMATION_SPEED_MAX :: 4

// push to archive text
archive_push :: proc(archive: ^Sidebar_Archive, text: string) {
	if len(text) == 0 {
		return
	}

	c := panel_children(archive.buttons)

	// KEEP AT MAX.
	if len(c) == ARCHIVE_MAX {
		for i := len(c) - 1; i >= 1; i -= 1 {
			a := cast(^Archive_Button) c[i]
			b := cast(^Archive_Button) c[i - 1]
			ss_copy(&a.ss, &b.ss)
		}

		c := cast(^Archive_Button) c[0]
		ss_set_string(&c.ss, text)
	} else {
		// log.info("LEN", len(c))
		archive_button_init(archive.buttons, { .HF }, text)
		archive.head += 1
		archive.tail += 1
	}
}

archive_low_and_high :: proc(archive: ^Sidebar_Archive) -> (low, high: int) {
	low = min(archive.head, archive.tail)
	high = max(archive.head, archive.tail)
	return
}

archive_reset :: proc(archive: ^Sidebar_Archive) {
	element_destroy_descendents(archive.buttons, true)
	archive.head = -1
	archive.tail = -1
}

Sidebar_Mode :: enum {
	Options,
	Tags,
	Archive,
	Stats,
}

Sidebar :: struct {
	split: ^Split_Pane,
	enum_panel: ^Enum_Panel,
	
	mode: Sidebar_Mode,
	options: Sidebar_Options,
	tags: Sidebar_Tags,
	archive: Sidebar_Archive,
	stats: Sidebar_Stats,

	pomodoro_label: ^Label,
	label_line: ^Label,
}
sb: Sidebar

Sidebar_Options :: struct {
	panel: ^Panel,
	checkbox_autosave: ^Checkbox,
	checkbox_invert_x: ^Checkbox,
	checkbox_invert_y: ^Checkbox,
	checkbox_uppercase_word: ^Checkbox,
	checkbox_bordered: ^Checkbox,
	checkbox_hide_statusbar: ^Checkbox,
	checkbox_hide_menubar: ^Checkbox,
	checkbox_vim: ^Checkbox,
	checkbox_spell_checking: ^Checkbox,
	volume: ^Drag_Float,
	opacity: ^Drag_Float,

	// visuals
	visuals: struct {
		tab: ^Drag_Int,
		fps: ^Drag_Int,
		kanban_gap: ^Drag_Int,
		kanban_width: ^Drag_Int,
		task_gap: ^Drag_Int,
		task_margin: ^Drag_Int,
		animation_speed: ^Drag_Int,
		use_animations: ^Checkbox,
	},

	// progressbar
	progressbar: struct {
		show: ^Checkbox,
		percentage: ^Checkbox,
		hover_only: ^Checkbox,
	},

	line_highlight: struct {
		use: ^Checkbox,
		alpha: ^Drag_Float,
	},

	// powermode
	pm: struct {
		ps_show: ^Checkbox,

		// particle
		p_lifetime: ^Drag_Float,
		p_alpha_scale: ^Drag_Float,
		p_colored: ^Checkbox,

		// screenshake
		s_use: ^Checkbox,
		s_amount: ^Drag_Float,
		s_lifetime: ^Drag_Float,
	},

	caret: struct {
		animate: ^Checkbox,
		motion: ^Checkbox,
		alpha: ^Checkbox,
	},
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
	names: [8]^Small_String,
	temp_index: int,
	tag_show_mode: int,
	toggle_selector_tag: ^Toggle_Selector,
}

Sidebar_Archive :: struct {
	panel: ^Panel,
	buttons: ^Panel,
	head, tail: int,
}

Sidebar_Stats :: struct {
	panel: ^Panel,

	work: ^Drag_Int,
	short_break: ^Drag_Int,
	long_break: ^Drag_Int,
	pomodoro_reset: ^Icon_Button,

	work_today: ^Drag_Int,
	gauge_work_today: ^Linear_Gauge,
	label_time_accumulated: ^Label,
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
	app.panel_info = panel_init(parent, { .Panel_Default_Background, .VF, .Tab_Movement_Allowed }, 0, 5)
	app.panel_info.background_index = 2
	app.panel_info.z_index = 10

	// side options
	{
		i1 := icon_button_init(app.panel_info, { .HF }, .COG, sidebar_button_message)
		i1.data = new_clone(Sidebar_Mode.Options)
		i1.hover_info = "Options"
		
		i2 := icon_button_init(app.panel_info, { .HF }, .TAG, sidebar_button_message)
		i2.data = new_clone(Sidebar_Mode.Tags)
		i2.hover_info = "Tags"

		i3 := icon_button_init(app.panel_info, { .HF }, .ARCHIVE, sidebar_button_message)
		i3.data = new_clone(Sidebar_Mode.Archive)
		i3.hover_info = "Archive"

		i4 := icon_button_init(app.panel_info, { .HF }, .CHART_AREA, sidebar_button_message)
		i4.data = new_clone(Sidebar_Mode.Stats)
		i4.hover_info = "Stats"
	}

	// pomodoro
	{
		spacer_init(app.panel_info, { .VF, }, 0, 20, .Thin)
		i1 := icon_button_init(app.panel_info, { .HF }, .PLAY_CIRCLED)
		i1.hover_info = "Start / Stop Pomodoro Time"
		i1.invoke = proc(button: ^Icon_Button, data: rawptr) {
			element_hide(sb.stats.pomodoro_reset, pomodoro.stopwatch.running)
			pomodoro_stopwatch_toggle()
		}
		i2 := icon_button_init(app.panel_info, { .HF }, .STOP)
		i2.invoke = proc(button: ^Icon_Button, data: rawptr) {
			element_hide(sb.stats.pomodoro_reset, pomodoro.stopwatch.running)
			pomodoro_stopwatch_reset()
			pomodoro_label_format()
			sound_play(.Timer_Stop)
		}
		i2.hover_info = "Reset Pomodoro Time"
		sb.stats.pomodoro_reset = i2
		element_hide(i2, true)

		sb.pomodoro_label = label_init(app.panel_info, { .HF, .Label_Center }, "00:00")

		b1 := button_init(app.panel_info, { .HF }, "1", pomodoro_button_message)
		b1.hover_info = "Select Work Time"
		b2 := button_init(app.panel_info, { .HF }, "2", pomodoro_button_message)
		b2.hover_info = "Select Short Break Time"
		b3 := button_init(app.panel_info, { .HF }, "3", pomodoro_button_message)
		b3.hover_info = "Select Long Break Time"
	}

	// copy mode
	{
		copy_label_message :: proc(element: ^Element, msg: Message, di: int, dp: rawptr) -> int {
			label := cast(^Label) element

			if msg == .Paint_Recursive {
				target := element.window.target
				text := strings.to_string(label.builder)
				rev := app.last_was_task_copy ~ (uintptr(label.data) == uintptr(0))
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

		spacer_init(app.panel_info, { }, 0, 20, .Thin)
		l1 := label_init(app.panel_info, { .HF }, "TEXT")
		l1.message_user = copy_label_message
		l1.hover_info = "Next paste will insert raw text"
		l1.data = rawptr(uintptr(0))
		l2 := label_init(app.panel_info, { .HF }, "TASK")
		l2.message_user = copy_label_message
		l2.hover_info = "Next paste will insert a task"
		l2.data = rawptr(uintptr(1))
	}

	// mode		
	{
		spacer_init(app.panel_info, { }, 0, 20, .Thin)
		SIZE :: 50
		b1 := image_button_init(app.panel_info, { .HF }, .List, SIZE, SIZE, mode_based_button_message)
		b1.hover_info = "List Mode"
		b2 := image_button_init(app.panel_info, { .HF }, .Kanban, SIZE, SIZE, mode_based_button_message)
		b2.hover_info = "Kanban Mode"
	}	

	when PRESENTATION_MODE {
		element_hide(app.panel_info, true)
	}
}

sidebar_enum_panel_init :: proc(parent: ^Element) {
	shared_panel :: proc(element: ^Element, title: string, scrollable := true) -> ^Panel {
		// dont use scrollbar if not wanted
		flags := Element_Flags { .Panel_Default_Background, .Tab_Movement_Allowed }
		if scrollable {
			flags += Element_Flags { .Panel_Scroll_Vertical }
		}
		panel := panel_init(element, flags, 5, 5)
		panel.background_index = 1
		// panel.z_index = 2

		header := label_init(panel, { .Label_Center }, title)
		header.font_options = &app.font_options_header
		spacer_init(panel, {}, 0, 5, .Thin)

		return panel
	}

	// init all sidebar panels

	enum_panel := enum_panel_init(parent, { .Tab_Movement_Allowed }, cast(^int) &sb.mode, len(Sidebar_Mode))
	sb.enum_panel = enum_panel
	element_hide(sb.enum_panel, true)

	SPACER_HEIGHT :: 10
	spacer_scaled := int(SPACER_HEIGHT * SCALE)

	// options
	{
		temp := &sb.options
		using temp
		flags := Element_Flags { .HF }

		panel = shared_panel(enum_panel, "Options")

		checkbox_autosave = checkbox_init(panel, flags, "Autosave", true)
		checkbox_autosave.hover_info = "Autosave on exit & opening different files"
		checkbox_uppercase_word = checkbox_init(panel, flags, "Uppercase Parent Word", true)
		checkbox_uppercase_word.hover_info = "Uppercase the task text when inserting a new child"
		checkbox_invert_x = checkbox_init(panel, flags, "Invert Scroll X", false)
		checkbox_invert_y = checkbox_init(panel, flags, "Invert Scroll Y", false)
		checkbox_bordered = checkbox_init(panel, flags, "Borderless Window", false)
		checkbox_bordered.message_user = proc(element: ^Element, msg: Message, di: int, dp: rawptr) -> int {
			if msg == .Value_Changed {
				checkbox := cast(^Checkbox) element
				window_border_set(checkbox.window, !checkbox.state)
			}

			return 0
		}
		checkbox_hide_statusbar = checkbox_init(panel, flags, "Hide Statusbar", false)
		checkbox_hide_statusbar.invoke = proc(box: ^Checkbox) {
			element_hide(statusbar.stat, box.state)
		}
		checkbox_hide_menubar = checkbox_init(panel, flags, "Hide Menubar", false)
		checkbox_hide_menubar.invoke = proc(box: ^Checkbox) {
			element_hide(app.task_menu_bar, box.state)
		}
		checkbox_vim = checkbox_init(panel, flags, "Use VIM bindings", false)
		checkbox_spell_checking = checkbox_init(panel, flags, "Use Spell-Checking", false)
	
		volume = drag_float_init(panel, flags, 1, 0, 1, 0.02, "Volume: %.3f")
		volume.hover_info = "Volume of all sound effects"
		volume.on_changed = proc(drag: ^Drag_Float) {
			value := i32(drag.position * 128)
			mix_volume_set(value)
		}

		opacity = drag_float_init(panel, flags, 1, 0.1, 1, 0.02, "Opacity: %.3f")
		opacity.hover_info = "Opacity of the main window"
		opacity.on_changed = proc(drag: ^Drag_Float) {
			window_opacity_set(app.window_main, drag.position)
		}

		spacer_init(panel, { .HF }, 0, spacer_scaled, .Empty)
		label_visuals := label_init(panel, { .HF, .Label_Center }, "Visuals")
		label_visuals.font_options = &app.font_options_header

		visuals.tab = drag_int_init(panel, flags, 20, 0, 200, 5, "Tab: %dpx")
		visuals.tab.hover_info = "Tab Indentation Width"
		
		visuals.kanban_gap = drag_int_init(panel, flags, 10, 0, 100, 5, "Kanban Gap: %dpx")
		visuals.kanban_gap.hover_info = "Horizontal gap between kanbans"

		visuals.kanban_width = drag_int_init(panel, flags, 300, 300, 1000, 20, "Kanban Width: %dpx")
		visuals.kanban_width.hover_info = "Minimum width of a Kanban"

		visuals.task_gap = drag_int_init(panel, flags, 1, 0, 20, 1, "Task Gap: %dpx")
		visuals.task_gap.hover_info = "Vertical gap between tasks"

		visuals.task_margin = drag_int_init(panel, flags, 5, 0, 50, 1, "Task Margin: %dpx")
		visuals.task_margin.hover_info = "Margin around tasks"

		visuals.animation_speed = drag_int_init(panel, flags, 100, 10, 400, 5, "Animation Speed: %d%%")
		visuals.animation_speed.hover_info = "Animation speed multiplier of all linear animations"

		visuals.fps = drag_int_init(panel, flags, 60, 10, 240, 5, "Wanted FPS: %dfps")
		visuals.fps.hover_info = "Set the minimum FPS, in case vsync isn't enabled, only used if vsync frequency is higher than FPS"

		visuals.use_animations = checkbox_init(panel, flags, "Use Animations", true)
	
		// progressbar
		{
			spacer_init(panel, { .HF }, 0, spacer_scaled, .Empty)
			header := label_init(panel, { .HF, .Label_Center }, "Progressbars")
			header.font_options = &app.font_options_header
			progressbar.show = checkbox_init(panel, flags, "Show", true)
			progressbar.show.invoke = proc(box: ^Checkbox) {
				app.progressbars_goal = box.state ? 1 : 0
			}
			progressbar.percentage = checkbox_init(panel, flags, "Use Percentage", false)
			progressbar.hover_only = checkbox_init(panel, flags, "Hover Only", false)
		}

		// caret
		{
			temp2 := &sb.options.caret
			using temp2
			spacer_init(panel, { .HF }, 0, spacer_scaled, .Empty)
			header := label_init(panel, { .HF, .Label_Center }, "Caret")
			header.font_options = &app.font_options_header

			animate = checkbox_init(panel, flags, "Use Animations", true)
			animate.hover_info = "Toggle all caret animations"
			motion = checkbox_init(panel, flags, "Animate Motion", true)
			motion.hover_info = "Animate the movement motion of the caret"
			alpha = checkbox_init(panel, flags, "Animate Alpha", true)
			alpha.hover_info = "Animate the alpha fading of the caret - will redraw every frame"
		}

		// line highlight
		{
			spacer_init(panel, { .HF }, 0, spacer_scaled, .Empty)
			header := label_init(panel, { .HF, .Label_Center }, "Line Numbers")
			header.font_options = &app.font_options_header

			line_highlight.use = checkbox_init(panel, flags, "Show", false)
			line_highlight.alpha = drag_float_init(panel, flags, 0.5, 0, 1, 0.02, "Alpha: %.3f")
			line_highlight.alpha.hover_info = "Alpha for line numbers"
		}

		// power mode
		{
			temp2 := &sb.options.pm
			using temp2

			spacer_init(panel, { .HF }, 0, spacer_scaled, .Empty)
			header := label_init(panel, { .HF, .Label_Center }, "Power Mode")
			header.font_options = &app.font_options_header

			ps_show = checkbox_init(panel, flags, "Show", false)

			p_lifetime = drag_float_init(panel, flags, 0.5, 0.25, 2, 0.02, "Particle Lifetime: %.3f")
			p_lifetime.hover_info = "Particle Lifetime Scaling - the higher the longer one stays alive"

			p_alpha_scale = drag_float_init(panel, flags, 0.5, 0, 1, 0.02, "Particle Alpha: %.3f")
			p_alpha_scale.hover_info = "Particle Alpha Scale - the higher the more visible"

			p_colored = checkbox_init(panel, flags, "Use Colors", true)
			p_colored.hover_info = "Wether to use slowly shifting color hues"

			// screenshake
			s_use = checkbox_init(panel, flags, "Use Screenshake", true)

			s_amount = drag_float_init(panel, flags, 3, 1, 20, 1, "Screenshake Amount: %.0fpx")
			s_amount.hover_info = "Screenshake Amount in px - the higher the more screenshake"

			s_lifetime = drag_float_init(panel, flags, 1, 0, 1, 0.02, "Screenshake Multiplier: %.3f")
			s_lifetime.hover_info = "Screenshake Multiplier - the lower the longer it screenshakes"
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
			b.um = &app.um_sidebar_tags
			sb.tags.names[sb.tags.temp_index]	= &b.ss
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
			sb.tags.tag_show_mode,
			TAG_SHOW_COUNT,
			tag_show_text[:],
		)
		toggle_selector_tag.changed = proc(toggle: ^Toggle_Selector) {
			sb.tags.tag_show_mode = toggle.value
		}
	}

	// archive
	{
		temp := &sb.archive
		using temp
		panel = shared_panel(enum_panel, "Archive", false)

		top := panel_init(panel, { .HF, .Panel_Horizontal, .Panel_Default_Background })
		top.rounded = true
		top.background_index = 2

		b1 := button_init(top, { .HF }, "Clear")
		b1.hover_info = "Clear all archive entries"
		b1.invoke = proc(button: ^Button, data: rawptr) {
			archive_reset(&sb.archive)
		}
		b2 := button_init(top, { .HF }, "Copy")
		b2.hover_info = "Copy selected archive region for next task copy"
		b2.invoke = proc(button: ^Button, data: rawptr) {
			if sb.archive.head == -1 {
				return
			}

			low, high := archive_low_and_high(&sb.archive)
			c := panel_children(sb.archive.buttons)
			
			copy_state_reset(&app.copy_state)
			app.last_was_task_copy = true
			element_repaint(app.mmpp)

			for i in low..<high + 1 {
				button := cast(^Archive_Button) c[i - 1]
				copy_state_push_empty(&app.copy_state, ss_string(&button.ss))
			}
		}

		{
			buttons = panel_init(panel, { .HF, .VF, .Panel_Default_Background, .Panel_Scroll_Vertical }, 5, 1)
			buttons.background_index = 2
			buttons.layout_elements_in_reverse = true
		}
	}

	// statistics
	{
		temp := &sb.stats
		using temp
		flags := Element_Flags { .HF }
		panel = shared_panel(enum_panel, "Pomodoro")

		// pomodoro		
		work = drag_int_init(panel, flags, 50, 0, 60, 1, "Work: %dmin")
		short_break = drag_int_init(panel, flags, 10, 0, 60, 1, "Short Break: %dmin")
		long_break = drag_int_init(panel, flags, 30, 0, 60, 1, "Long Break: %dmin")

		// statistics
		spacer_init(panel, flags, 0, spacer_scaled, .Empty)
		l2 := label_init(panel, { .HF, .Label_Center }, "Statistics")
		l2.font_options = &app.font_options_header

		label_time_accumulated = label_init(panel, { .HF, .Label_Center })
		b1 := button_init(panel, flags, "Reset acummulated")
		b1.invoke = proc(button: ^Button, data: rawptr) {
			pomodoro.accumulated = {}
			pomodoro.celebration_goal_reached = false
		}

		{
			sub := panel_init(panel, { .HF, .Panel_Horizontal, .Panel_Default_Background }, 0, 2)
			sub.rounded = true
			sub.background_index = 2
			drag := drag_int_init(sub, flags, 30.0, 0, 60, 1, "Cheat: %dmin")

			b := button_init(sub, flags, "Add")
			b.data = drag
			b.invoke = proc(button: ^Button, data: rawptr) {
				drag := cast(^Drag_Int) data
				minutes := time.Duration(drag.position) * time.Minute
				pomodoro.accumulated += minutes
			}
		}

		work_today = drag_int_init(panel, flags, 8, 0, 24, 1, "Goal Today: %dh")

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
}

// cuts of text rendering at limit
// on press inserts it back to the mode_panel
// saved to save file!
Archive_Button :: struct {
	using element: Element,
	// builder: strings.Builder,
	ss: Small_String,
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

			low, high := archive_low_and_high(&sb.archive)
			if low <= button.visual_index && button.visual_index <= high {
				render_rect(target, element.bounds, theme_panel(.Front), ROUNDNESS)
				text_color = theme.text_default
			}

			text := ss_string(&button.ss)
			rect := element.bounds
			rect.l += int(TEXT_PADDING * SCALE)
			fcs_element(element)
			fcs_ahv(.LEFT, .MIDDLE)
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
			text := ss_string(&button.ss)
			fcs_element(element)
			width := max(int(50 * SCALE), string_width(text) + int(TEXT_MARGIN_HORIZONTAL * SCALE))
			return int(width)
		}

		case .Get_Height: {
			return efont_size(element) + int(TEXT_MARGIN_VERTICAL * SCALE)
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
	ss_set_string(&res.ss, text)
	res.visual_index = len(parent.children) - 1
	return
}

options_bordered :: #force_inline proc() -> bool {
	return sb.options.checkbox_bordered.state
}

options_volume :: #force_inline proc() -> f32 {
	return sb.options.volume.position
}

options_autosave :: #force_inline proc() -> bool {
	return sb.options.checkbox_autosave.state
}

options_scroll_x :: #force_inline proc() -> int {
	return sb.options.checkbox_invert_x == nil ? 1 : sb.options.checkbox_invert_x.state ? -1 : 1
}

options_scroll_y :: #force_inline proc() -> int {
	return sb.options.checkbox_invert_y == nil ? 1 : sb.options.checkbox_invert_y.state ? -1 : 1
}

options_tag_mode :: #force_inline proc() -> int {
	return sb.tags.tag_show_mode
}

options_uppercase_word :: #force_inline proc() -> bool {
	return sb.options.checkbox_uppercase_word.state
}

options_vim_use :: #force_inline proc() -> bool {
	return sb.options.checkbox_vim.state
}

options_spell_checking :: #force_inline proc() -> bool {
	return sb.options.checkbox_spell_checking.state
}

visuals_use_animations :: #force_inline proc() -> bool {
	return sb.options.visuals.use_animations.state
}

visuals_tab :: #force_inline proc() -> int {
	return sb.options.visuals.tab.position
}

visuals_task_gap :: #force_inline proc() -> int {
	return sb.options.visuals.task_gap.position
}

visuals_kanban_gap :: #force_inline proc() -> int {
	return sb.options.visuals.kanban_gap.position
}

// remap from unit to wanted range
visuals_kanban_width :: #force_inline proc() -> int {
	return sb.options.visuals.kanban_width.position
}

visuals_task_margin :: #force_inline proc() -> int {
	return sb.options.visuals.task_margin.position
}

visuals_animation_speed :: #force_inline proc() -> f32 {
	return f32(sb.options.visuals.animation_speed.position) / 100
}

visuals_fps :: #force_inline proc() -> int {
	return sb.options.visuals.fps.position
}

visuals_line_highlight_use :: #force_inline proc() -> bool {
	return sb.options.line_highlight.use.state
}

visuals_line_highlight_alpha :: #force_inline proc() -> f32 {
	return sb.options.line_highlight.alpha.position
}

progressbar_show :: #force_inline proc() -> bool {
	return sb.options.progressbar.show.state
}
progressbar_percentage :: #force_inline proc() -> bool {
	return sb.options.progressbar.percentage.state
}
progressbar_hover_only :: #force_inline proc() -> bool {
	return sb.options.progressbar.hover_only.state
}

// power mode options

pm_show :: #force_inline proc() -> bool {
	return sb.options.pm.ps_show.state
}
pm_particle_lifetime :: #force_inline proc() -> f32 {
	return sb.options.pm.p_lifetime.position
}
pm_particle_alpha_scale :: #force_inline proc() -> f32 {
	return sb.options.pm.p_alpha_scale.position
}
pm_particle_colored :: #force_inline proc() -> bool {
	return sb.options.pm.p_colored.state
}
pm_screenshake_use :: #force_inline proc() -> bool {
	return sb.options.pm.s_use.state
}
pm_screenshake_amount :: #force_inline proc() -> f32 {
	return math.remap(sb.options.pm.s_amount.position, 0, 1, S_AMOUNT_MIN, S_AMOUNT_MAX)
}
pm_screenshake_lifetime :: #force_inline proc() -> f32 {
	return sb.options.pm.s_lifetime.position
}

// caret options

caret_animate :: #force_inline proc() -> bool {
	return sb.options.caret.animate.state
}
caret_motion :: #force_inline proc() -> bool {
	return sb.options.caret.motion.state
}
caret_alpha :: #force_inline proc() -> bool {
	return sb.options.caret.alpha.state
}

mode_based_button_message :: proc(element: ^Element, msg: Message, di: int, dp: rawptr) -> int {
	button := cast(^Image_Button) element
	index := button.kind == .List ? 0 : 1

	#partial switch msg {
		case .Button_Highlight: {
			color := cast(^Color) dp
			selected := index == int(app.mmpp.mode)
			color^ = selected ? theme.text_default : theme.text_blank
			return selected ? 1 : 2
		}

		case .Clicked: {
			set := cast(^int) &app.mmpp.mode
			if set^ != index {
				set^ = index
				element_repaint(element)
				power_mode_clear()
			}
		}
	}

	return 0
}