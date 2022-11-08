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

// paint timestamps in different color
task_repaint_timestamps :: proc() {
	if task_head == -1 {
		return
	}

	clear(&timestamp_regions)

	for task in tasks_visible {
		text := task_string(task)

		if res := timing_timestamp_check(text); res != -1 {
			if len(task.box.rendered_glyphs) != 0 {
				// push the wanted timestamp tasks to an array
				append(&timestamp_regions, Timestamp_Task {
					task,
					{
						int(task.box.rendered_glyphs[0].x),
						int(task.box.rendered_glyphs[TIMESTAMP_LENGTH].x),
						task.box.bounds.t,
						task.box.bounds.b,
					},
				})

				// actually repaint the glpyhs
				for i in 0..<res {
					b := task.box.rendered_glyphs[i]

					for v in &b.vertices {
						v.color = theme.text_date
					}
				}
			}
		}
	}
}

// do hover info on timestamp
task_timestamp_check_hover :: proc() {
	if len(timestamp_regions) == 0 {
		return
	}

	// nope out on these
	if window_main.menu != nil || (.Hide not_in window_main.hovered_panel.flags) {
		return
	}

	x := window_main.cursor_x
	y := window_main.cursor_y
	found: bool
	top: int
	task: ^Task

	// TODO does this get obstructed by the mode_panel?
	for tt in timestamp_regions {
		if rect_contains(tt.rect, x, y) {
			top = tt.rect.t
			task = tt.task
			found = true
			break
		}
	}

	if found {
		if timestamp_hover == nil {
			timestamp_hover = panel_floaty_init(&window_main.element, {})
			incl(&timestamp_hover.flags, Element_Flag.Disabled)
			label_init(timestamp_hover.panel, {}, "")
		}

		timestamp_hover.x = x
		timestamp_hover.y = top - int(DEFAULT_FONT_SIZE * SCALE) * 2
		timestamp_hover.width = 100
		timestamp_hover.height = int((DEFAULT_FONT_SIZE + TEXT_MARGIN_VERTICAL) * SCALE)

		e1 := timestamp_hover.panel.children[0]
		assert(e1.message_class == label_message)
		l := cast(^Label) e1
		strings.builder_reset(&l.builder)

		ss := &task.box.ss
		stamp, ok := timing_timestamp_extract(ss.buf[:TIMESTAMP_LENGTH])

		if ok {
			year, month, day := time.date(time.now())
			ydiff := year - stamp.year
			mdiff := int(month) - stamp.month
			ddiff := day - stamp.day
			count: int
			b := &l.builder

			if ydiff != 0 {
				strings.write_int(b, ydiff)
				strings.write_byte(b, ' ')
				strings.write_string(b, ydiff == 1 ? "year" : "years")
				count += 1
			}

			if mdiff != 0 {
				if count != 0 {
					strings.write_byte(b, ' ')
				}

				strings.write_int(b, mdiff)
				strings.write_byte(b, ' ')
				strings.write_string(b, mdiff == 1 ? "month" : "months")
				count += 1
			}

			if ddiff != 0 {
				if count != 0 {
					strings.write_byte(b, ' ')
				}

				strings.write_int(b, ddiff)
				strings.write_byte(b, ' ')
				strings.write_string(b, ddiff == 1 ? "day" : "days")
				count += 1
			}
		}

		// ignore if empty
		if len(l.builder.buf) == 0 {
			found = false
		} else {
			strings.write_string(&l.builder, " ago")
		}
	} 

	
	if timestamp_hover != nil && element_hide(timestamp_hover, !found) {
		// fmt.eprintln("found", found)
		window_repaint(window_main)
	}
}