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
	ok = true

	return
}

// timing_timestamp_today :: #force_inline proc() -> Timestamp {
// 	year, month, date
// }

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

	for task in tasks_visible {
		text := strings.to_string(task.box.builder)

		if res := timing_timestamp_check(text); res != -1 {
			if len(task.box.rendered_glyphs) != 0 {
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
