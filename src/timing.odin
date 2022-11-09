package src

import "core:strconv"
import "core:unicode"
import "core:fmt"
import "core:strings"
import "core:time"

duration_clock :: proc(duration: time.Duration) -> (hours, minutes, seconds: int) {
	hours = int(time.duration_hours(duration)) % 24
	minutes = int(time.duration_minutes(duration)) % 60
	seconds = int(time.duration_seconds(duration)) % 60
	return
}

DAY :: time.Hour * 24
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

Time_Date_Format :: enum {
	US,
	EUROPE,
}

// TODO put this into options
time_date_format: Time_Date_Format = .US

Time_Date :: struct {
	using element: Element,

	stamp: time.Time,
	saved: time.Time,
	drag_from: int,
	drag_to: int,

	builder: strings.Builder,
	rendered_glyphs: [dynamic]Rendered_Glyph,
}

time_date_init :: proc(
	parent: ^Element,
	flags: Element_Flags,
) -> (res: ^Time_Date) {
	res = element_init(Time_Date, parent, flags, time_date_message, context.allocator)
	res.stamp = time.now()
	strings.builder_init(&res.builder, 0, 16)
	return
}

time_date_message :: proc(element: ^Element, msg: Message, di: int, dp: rawptr) -> int {
	td := cast(^Time_Date) element

	#partial switch msg {
		case .Paint_Recursive: {
			target := element.window.target
			b := &td.builder
			strings.builder_reset(b)
			year, month, day := time.date(td.stamp)

			switch time_date_format {
				case .US: fmt.sbprintf(b, "%4d-%2d-%2d", year, int(month), day)
				case .EUROPE: fmt.sbprintf(b, "%2d.%2d.%4d", day, int(month), year)
			}

			fcs_ahv()
			task := cast(^Task) element.parent
			task_color := theme_panel(task.has_children ? .Parent : .Front)
			fcs_color(task_color)
			fcs_font(font_regular)
			fcs_size(DEFAULT_FONT_SIZE * TASK_SCALE)

			render_rect(target, element.bounds, theme.text_date, ROUNDNESS)
			clear(&td.rendered_glyphs)
			render_string_rect_store(target, element.bounds, strings.to_string(td.builder), &td.rendered_glyphs)
		}

		case .Destroy: {
			strings.builder_destroy(&td.builder)
			delete(td.rendered_glyphs)
		}

		case .Left_Down: {
			td.saved = td.stamp
		}

		case .Mouse_Drag: {
			if element.window.pressed_button == MOUSE_LEFT {
				diff := window_mouse_position(element.window) - element.window.down_left

				// switch time_date_format {
				// 	case .US: {
				// 		drag_from
				// 	}
				// }
				// for i in 0..<

				old := td.stamp
				td.stamp = time.time_add(td.saved, DAY * time.Duration(diff.x / 20))

				element_repaint(element)
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

time_date_update :: proc(td: ^Time_Date) {
	td.stamp = time.now()
}

// time_date_render_highlight_on_pressed :: proc(
// 	target: ^Render_Target, 
// 	clip: RectI,
// 	pressed: ^Element,
// ) {
// 	if pressed == nil {
// 		return
// 	}

// 	// if pressed.message_class == time_date_message {
// 	// 	render_push_clip(target, clip)

// 	// 	td := cast(^Time_Date) pressed
// 	// 	r := td.bounds
// 	// 	r.t -= rect_height(r)
// 	// 	r.b = td.bounds.t
// 	// 	diff := window_mouse_position(td.window) - td.window.down_left
// 	// 	r.r = r.l + int(diff.x / 20) * 20
// 	// 	render_rect(target, r, RED, ROUNDNESS)
// 	// }
// }