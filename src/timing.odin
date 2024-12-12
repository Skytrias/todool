package src

import "core:reflect"
import "core:math"
import "core:strconv"
import "core:unicode"
import "core:fmt"
import "core:strings"
import "core:time"

menu_date_time_ptr: ^time.Time
menu_date_day_offset: int
menu_date_grid: ^Panel_Grid

duration_clock :: proc(duration: time.Duration) -> (hours, minutes, seconds: int) {
	hours = int(time.duration_hours(duration)) % 24
	minutes = int(time.duration_minutes(duration)) % 60
	seconds = int(time.duration_seconds(duration)) % 60
	return
}

DAY :: time.Hour * 24
MONTH :: DAY * 30
YEAR :: MONTH * 12
TIMESTAMP_LENGTH :: 10

// build today timestamp
timing_sbprint_timestamp :: proc(b: ^strings.Builder) {
	year, month, day := time.date(time.now())
	strings.builder_reset(b)
	fmt.sbprintf(b, "%4d-%2d-%2d", year, month, day)
}

// build today timestamp
timing_bprint_timestamp :: proc(b: []byte) {
	year, month, day := time.date(time.now())
	fmt.bprintf(b, "%4d-%2d-%2d ", year, month, day)
}

// check if the text contains a timestamp at the starting runes
timing_timestamp_check :: proc(text: string) -> (index: int) {
	index = -1
	
	if len(text) >= 8 && unicode.is_digit(rune(text[0])) {
		// find 2 minus signs without break
		// 2022-01-28 
		minus_count := 0
		index = 0

		for index < 10 {
			b := rune(text[index])
		
			if b == '-' {
				minus_count += 1
			}

			if !(b == '-' || unicode.is_digit(b)) {
				break
			}

			index += 1
		}

		if minus_count != 2 {
			index = -1
		}
		} 

	return
}

Timestamp :: struct {
	year, month, day: int,
}

timing_timestamp_extract :: proc(text: []byte) -> (
	stamp: Timestamp,
	ok: bool,
) {
	assert(len(text) >= TIMESTAMP_LENGTH)

	stamp.year = strconv.parse_int(string(text[0:4])) or_return
	stamp.month = strconv.parse_int(string(text[5:7])) or_return
	stamp.day = strconv.parse_int(string(text[8:10])) or_return
	stamp.month = clamp(stamp.month, 0, 12)
	stamp.day = clamp(stamp.day, 0, 31)
	ok = true

	return
}

// true if the timestamp isnt today
timing_timestamp_is_today :: proc(stamp: Timestamp) -> bool {
	year, month, day := time.date(time.now())
	return year == stamp.year &&
		int(month) == stamp.month &&
		day == stamp.day
}

time_get_weekday :: proc(date: time.Time) -> time.Weekday {
	// abs := time._time_abs(date)
	abs := u64(date._nsec / 1e9 + time.UNIX_TO_ABSOLUTE)
	sec := (abs + u64(time.Weekday.Monday) * time.SECONDS_PER_DAY) % time.SECONDS_PER_WEEK
	return time.Weekday(int(sec) / time.SECONDS_PER_DAY)
}

month_day_count :: proc(month: time.Month) -> i32 {
	month := int(month)
	assert(month >= 0 && month <= 12)
	return time.days_before[month] - time.days_before[month - 1]
}

wrap_int :: proc(x, low, high: int) -> int {
	temp := x % high
	return temp < low ? high + (temp - low) : temp
}

month_wrap :: proc(month: time.Month, offset: int) -> time.Month {
	return time.Month(wrap_int(int(month) + offset, 1, 13))
}

Time_Date_Format :: enum {
	US,
	EUROPE,
}

Time_Date_Drag :: enum {
	None,
	Day,
	Month,
	Year,
}

// positions
TIME_DATE_FORMAT_TABLE :: [Time_Date_Drag][Time_Date_Format][2]int {
	.None = {}, // empty
	.Day = { // day
		.US = { 8, 10 },
		.EUROPE = { 0, 2 },
	},
	.Month = { // month
		.US = { 5, 7 },
		.EUROPE = { 3, 5 },
	},
	.Year = { // year
		.US = { 0, 4 },
		.EUROPE = { 6, 10 },
	},
}

// TODO put this into options
time_date_format: Time_Date_Format = .US

Time_Date :: struct {
	using element: Element,

	stamp: time.Time,
	saved: time.Time,
	drag: Time_Date_Drag,

	builder: strings.Builder,
	rendered_glyphs: []Rendered_Glyph,
	spawn_particles: bool,
}

time_date_init :: proc(
	parent: ^Element,
	flags: Element_Flags,
	particles: bool,
) -> (res: ^Time_Date) {
	res = element_init(Time_Date, parent, flags, time_date_message, context.allocator)
	res.stamp = time.now()
	strings.builder_init(&res.builder, 0, 16)
	res.spawn_particles = particles
	return
}

time_date_drag_find :: proc(td: ^Time_Date) -> Time_Date_Drag {
	// find dragged property
	if td.rendered_glyphs != nil {
		count: int
		
		for g in td.rendered_glyphs {
			if td.window.cursor_x < int(g.x) {
				break
			}

			if g.codepoint == '-' || g.codepoint == '.' {
				count += 1
			}
		}

		// set drag property
		switch time_date_format {
			case .US: {
				return Time_Date_Drag(2 - count + 1)
			}

			case .EUROPE: {
				return Time_Date_Drag(count + 1)
			}
		}
	}

	return .None
}

time_date_message :: proc(element: ^Element, msg: Message, di: int, dp: rawptr) -> int {
	td := cast(^Time_Date) element

	#partial switch msg {
		case .Paint_Recursive: {
			target := element.window.target

			fcs_ahv()
			task := cast(^Task) element.parent
			task_color := theme_panel(task_has_children(task) ? .Parent : .Front)
			fcs_color(task_color)
			fcs_font(font_regular)
			fcs_size(DEFAULT_FONT_SIZE * TASK_SCALE)
			
			render_rect(target, element.bounds, theme.text_date, ROUNDNESS)

			render_string_rect_store(target, element.bounds, strings.to_string(td.builder), &td.rendered_glyphs)
		}

		case .Layout: {
			td.rendered_glyphs = nil

			b := &td.builder
			strings.builder_reset(b)
			year, month, day := time.date(td.stamp)
			switch time_date_format {
				case .US: fmt.sbprintf(b, "%4d-%2d-%2d", year, int(month), day)
				case .EUROPE: fmt.sbprintf(b, "%2d.%2d.%4d", day, int(month), year)
			}

			if td.spawn_particles {
				x := f32(element.bounds.l)
				y := f32(element.bounds.t)
				power_mode_spawn_along_text(strings.to_string(td.builder), x, y, theme.text_date)
				td.spawn_particles = false
			}
		}

		case .Destroy: {
			strings.builder_destroy(&td.builder)
		}

		case .Left_Down: {
			td.saved = td.stamp
			td.drag = time_date_drag_find(td)

			if di > 0 {
				menu_date_spawn(&td.stamp, td.element.bounds.r, td.element.bounds.t)
				return 1
			}
		}

		case .Get_Cursor: {
			return int(Cursor.Resize_Horizontal)
		}

		case .Left_Up: {
			td.drag = .None
			element_repaint(element)
		}

		case .Mouse_Move: {
			element_repaint(element)
		}

		case .Mouse_Drag: {
			if element.window.pressed_button == MOUSE_LEFT && !menu_visible(element.window) {
				diff := window_mouse_position(element.window) - element.window.down_left
				old := td.stamp

				switch td.drag {
					case .None: {}

					case .Day: {
						step := time.Duration(diff.x / 20)
						td.stamp = time.time_add(td.saved, DAY * step)
					}

					case .Month: {
						year, month, day := time.date(td.saved)
						goal := clamp(int(month) + int(diff.x / 20), 1, 12)
						out, ok := time.datetime_to_time(year, goal, day, 0, 0, 0)

						if ok {
							td.stamp = out
						}
					}

					case .Year: {
						year, month, day := time.date(td.saved)
						goal := clamp(int(year) + int(diff.x / 20), 1970, 100_000)
						out, ok := time.datetime_to_time(goal, int(month), day, 10, 10, 10)

						if ok {
							td.stamp = out
						}
					}
				}

				if old != td.stamp {
					element_repaint(element)

					if pm_show() {
						table := TIME_DATE_FORMAT_TABLE
						pair := table[td.drag][time_date_format]
						
						if td.rendered_glyphs != nil {
							glyphs := td.rendered_glyphs
							cam := mode_panel_cam()
							x1 := glyphs[pair.x].x
							x2 := glyphs[pair.y - 1].x
							x := f32(x1 + (x2 - x1))
							y := f32(glyphs[pair.x].y)
							cam_screenshake_reset(cam)
							power_mode_spawn_at(x, y, cam.offset_x, cam.offset_y, 4, theme.text_date)
						}
					}
				}
			} 
		}

		case .Right_Down: {
			element_hide(td, true)
			// time_date_format = Time_Date_Format((int(time_date_format) + 1) % len(Time_Date_Format))
			// window_repaint(window_main)
		}
	}

	return 0
}

// set to the newest time & date
time_date_update :: proc(td: ^Time_Date) -> bool {
	y1, m1, d1 := time.date(td.stamp)
	next := time.now()
	y2, m2, d2 := time.date(next)
	td.stamp = next
	return y1 == y2 && m1 == m2 && d1 == d2
}

time_date_render_highlight_on_pressed :: proc(
	target: ^Render_Target, 
	clip: RectI,
) {
	element := app.window_main.pressed

	if element == nil {
		element = app.window_main.hovered

		if element == nil {
			return
		}
	}

	if element.message_class == time_date_message {
		td := cast(^Time_Date) element
		drag := td.drag

		if drag == .None {
			drag = time_date_drag_find(td)

			if drag == .None {
				return
			}
		}

		// render glyphs differently based on drag property
		if td.rendered_glyphs != nil {
			table := TIME_DATE_FORMAT_TABLE
			pair := table[drag][time_date_format]
			glyphs := td.rendered_glyphs

			for i in pair.x..<pair.y {
				glyph := glyphs[i]

				for &v in &glyph.vertices {
					v.color = theme.text_default
				}
			}
		}
	}
}

Panel_Grid :: struct {
	using element: Element,
	cell_width: int,
	cell_height: int,
	cell_gap: int,
	wrap_at: int, // when to wrap around
}

panel_grid_init :: proc(
	parent: ^Element,
	flags: Element_Flags,
	wrap_at: int,
	cell_width: int,
	cell_height: int,
	gap: int,
) -> (res: ^Panel_Grid) {
	res = element_init(Panel_Grid, parent, flags, panel_grid_message, context.allocator)
	assert(wrap_at > 0)
	res.wrap_at = wrap_at
	res.cell_width = cell_width
	res.cell_height = cell_height
	res.cell_gap = gap
	return
}

panel_grid_message :: proc(element: ^Element, msg: Message, di: int, dp: rawptr) -> int {
	panel := cast(^Panel_Grid) element

	#partial switch msg {
		case .Layout: {
			width := int(f32(panel.cell_width) * SCALE)
			height := int(f32(panel.cell_height) * SCALE)
			// height := element_message(element, .Get_Height)
			bounds := element.bounds
			current := rect_cut_top(&bounds, height)

			for child, index in element.children {
				if index != 0 && index % panel.wrap_at == 0 {
					current = rect_cut_top(&bounds, height)
				}

				rect := rect_cut_left(&current, width)
				element_move(child, rect)
			}
		}

		case .Paint_Recursive: {
			target := element.window.target
			render_rect_outline(target, element.bounds, theme.text_default, ROUNDNESS)
			// render_rect(target, element.bounds, RED, ROUNDNESS)
		}

		case .Get_Width: {
			return int(SCALE * f32(panel.cell_width * panel.wrap_at))
		}

		case .Get_Height: {
			lines := f32(6)
			c := element.children[7 * 6]

			if .Hide not_in c.flags {
				lines += 1
			}

			return int(SCALE * f32(panel.cell_height) * lines)
		}
	}

	return 0
}

Button_Day :: struct {
	using element: Element,
	bytes: [8]u8,
	byte_length: u8,
	alpha: u8,
	highlight: bool,
}

button_day_init :: proc(
	parent: ^Element,
	flags: Element_Flags,
	text: string,
	alpha: u8,
) -> (res: ^Button_Day) {
	res = element_init(Button_Day, parent, flags, button_day_message, context.allocator)

	if len(text) != 0 {
		assert(len(text) <= 8)
		copy(res.bytes[:], text[:])
		res.byte_length = u8(len(text))
	}

	res.alpha = alpha
	return
}

button_day_message :: proc(element: ^Element, msg: Message, di: int, dp: rawptr) -> int {
	button := cast(^Button_Day) element

	#partial switch msg {
		case .Paint_Recursive: {
			hovered := element.window.hovered == element
			pressed := element.window.pressed == element
			target := element.window.target 

			text := string(button.bytes[:button.byte_length])
			fcs_ahv()
			fcs_font(font_regular)
			fcs_size(DEFAULT_FONT_SIZE * SCALE)

			if button.highlight {
				fcs_color(color_alpha(theme.background[2], f32(button.alpha) / 255))
				render_rect(target, element.bounds, theme.text_default, ROUNDNESS)
				render_string_rect(target, element.bounds, text)
			} else {
				fcs_color(color_alpha(theme.text_default, f32(button.alpha) / 255))
				render_string_rect(target, element.bounds, text)
			}
			
			if hovered || pressed {
				render_hovered_highlight(target, element.bounds)
			}
		}

		case .Clicked: {
			if button.alpha == 255 {
				text := string(button.bytes[:button.byte_length])
				value := strconv.atoi(text)
				menu_date_day_set(value)
			}
		}

		case .Get_Cursor: {
			if button.alpha == 255 {
				return int(Cursor.Hand)
			}
		}
	}

	return 0
}

menu_date_timing :: proc() -> (year: int, month: time.Month, day: int) {
	offset := time.Hour * 24 * time.Duration(menu_date_day_offset)
	offset_time := time.time_add(menu_date_time_ptr^, offset)
	year, month, day = time.date(offset_time)
	return
}

menu_date_day_set :: proc(value: int) {
	assert(menu_date_time_ptr != nil)
	
	offset_year, offset_month, offset_day := menu_date_timing()
	menu_date_time_ptr^, _ = time.datetime_to_time(offset_year, int(offset_month), value, 1, 1, 1)

	menu_close(app.window_main)
}

MENU_DATE_COUNT :: 7 * 6 // 7 days times 5

menu_date_buttons_set :: proc() {
	offset_year, offset_month, offset_day := menu_date_timing()
	real_year, real_month, real_day := time.date(menu_date_time_ptr^)

	// month data
	days_in_month_prior := int(month_day_count(month_wrap(offset_month, -1)))
	days_in_month := int(month_day_count(offset_month))

	// retrieve week data
	first_in_month, ok := time.datetime_to_time(offset_year, int(offset_month), 1, 12, 0, 0)
	weekday := time_get_weekday(first_in_month)
	weekday_index := int(weekday)

	// prior days
	count := 7
	for i in 0..<weekday_index {
		button := cast(^Button_Day) menu_date_grid.children[count]
		day := int(days_in_month_prior) - weekday_index + 1 + i
		text := fmt.bprintf(button.bytes[:], "%d", day)
		button.byte_length = u8(len(text))
		button.alpha = 100
		button.highlight = false
		count += 1
	}

	for i in 0..<days_in_month {
		button := cast(^Button_Day) menu_date_grid.children[count]
		button.highlight = false

		if i + 1 == real_day && offset_month == real_month && offset_year == real_year {
			button.highlight = true
		}

		text := fmt.bprintf(button.bytes[:], "%d", i + 1)
		button.byte_length = u8(len(text))
		button.alpha = 255
		button.flags -= { Element_Flag.Hide }
		count += 1
	}

	// hide the rest of them
	for i in count..<MENU_DATE_COUNT + 7 {
		button := cast(^Button_Day) menu_date_grid.children[i]
		button.flags += { Element_Flag.Hide }
	}

	window_repaint(app.window_main)
}

menu_date_spawn :: proc(ptr: ^time.Time, x, y: int) {
	menu_date_time_ptr = ptr
	menu_date_day_offset = 0

	menu := menu_init(app.mmpp.window, { .Panel_Expand })
	menu.x = x
	menu.y = y
	menu.message_user = proc(element: ^Element, msg: Message, di: int, dp: rawptr) -> int {
		floaty := cast(^Panel_Floaty) element

		// update to latest height
		if msg == .Layout {
			w := floaty.width
			floaty.height = element_message(floaty.panel, .Get_Height)
			h := floaty.height
			
			rect := rect_wh(floaty.x, floaty.y, w, h)
			element_move(floaty.panel, rect)
			return 1
		}

		return 0
	}
	defer menu_show(menu)

	p := menu.panel
	p.gap = 10
	p.shadow = true
	p.background_index = 2
	p.message_user = proc(element: ^Element, msg: Message, di: int, dp: rawptr) -> int {
		panel := cast(^Panel) element

		if msg == .Mouse_Scroll_Y {
			offset_year, offset_month, offset_day := menu_date_timing()

			// scroll movement through months
			if di > 0 {
				days_in_month := int(month_day_count(offset_month))
				menu_date_day_offset += (days_in_month - offset_day) + 1
			} else {
				menu_date_day_offset -= offset_day
			}

			menu_date_buttons_set()
		}

		return 0
	}

	header := label_init(p, { .Label_Center }, "Calendar")
	header.font_options = &app.font_options_header

	// top bar
	{
		top := panel_init(p, { .Panel_Horizontal })
		b1 := icon_button_init(top, {}, .LEFT_OPEN)
		b1.invoke = proc(button: ^Icon_Button, data: rawptr) {
			offset_year, offset_month, offset_day := menu_date_timing()
			menu_date_day_offset -= offset_day
			menu_date_buttons_set()
		}

		label := label_init(top, { .HF, .Label_Center }, "")
		label.message_user = proc(element: ^Element, msg: Message, di: int, dp: rawptr) -> int {
			label := cast(^Label) element

			// set the year/month/day each time
			if msg == .Layout {
				offset_year, offset_month, offset_day := menu_date_timing()
				b := &label.builder
				strings.builder_reset(b)
				assert(menu_date_time_ptr != nil)
				fmt.sbprintf(b, "%s %d", reflect.enum_string(offset_month), offset_year)
			}

			return 0
		}
		b3 := icon_button_init(top, {}, .RIGHT_OPEN)
		b3.invoke = proc(button: ^Icon_Button, data: rawptr) {
			offset_year, offset_month, offset_day := menu_date_timing()
			days_in_month := int(month_day_count(offset_month))
			menu_date_day_offset += (days_in_month - offset_day) + 1
			menu_date_buttons_set()
		}
	}

	week_names := [7]string {
		"Sun",
		"Mon",
		"Tue",
		"Wed",
		"Thu",
		"Fri",
		"Sat",
	}

	grid := panel_grid_init(p, {}, 7, 50, 50, 0)
	menu_date_grid = grid

	// week names
	for i in 0..<7 {
		name := week_names[i]
		label_init(grid, { .Label_Center }, name)
	}

	for i in 0..<MENU_DATE_COUNT {
		button_day_init(grid, {}, "", 255)
	}

	menu_date_buttons_set()
}