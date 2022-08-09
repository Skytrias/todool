package  src

import "core:runtime"
import "core:fmt"
import "core:strings"
import "core:time"
import sdl "vendor:sdl2"

POMODORO_MAX :: 2
pomodoro_index: int // 0-2
pomodoro_timer_id: sdl.TimerID
pomodoro_stopwatch: time.Stopwatch
pomodoro_acummulated_today: time.Duration

pomodoro_init :: proc() {
	pomodoro_timer_id = sdl.AddTimer(500, pomodoro_timer_callback, nil)
}

pomodoro_destroy :: proc() {
	sdl.RemoveTimer(pomodoro_timer_id)
}

// NOTE same as before, just return diff
time_stop_stopwatch :: proc(using stopwatch: ^time.Stopwatch) -> (diff: time.Duration) {
	if running {
		diff = time.tick_diff(_start_time, time.tick_now())
		_accumulation += diff
		running = false
	}

	return
}

duration_clock :: proc(duration: time.Duration) -> (hours, minutes, seconds: int) {
	hours = int(time.duration_hours(duration)) % 24
	minutes = int(time.duration_minutes(duration)) % 60
	seconds = int(time.duration_seconds(duration)) % 60
	return
}

pomodoro_stopwatch_toggle :: proc() {
	if pomodoro_stopwatch.running {
		diff := time_stop_stopwatch(&pomodoro_stopwatch)
		pomodoro_acummulated_today += diff
		// pomodoro_acummulated_today += time.Minute * 61
		sound_play(.Timer_Stop)
	} else {
		if pomodoro_stopwatch._accumulation != {} {
			sound_play(.Timer_Resume)
		} else {
			sound_play(.Timer_Start)
		}

		time.stopwatch_start(&pomodoro_stopwatch)
	}
}

pomodoro_stopwatch_reset :: #force_inline proc() {
	element_hide(sb.options.button_pomodoro_reset, true)
	time.stopwatch_reset(&pomodoro_stopwatch)
}

// toggle stopwatch on or off based on index
pomodoro_stopwatch_hot_toggle :: proc(index: int) {
	defer {
		element_hide(sb.options.button_pomodoro_reset, !pomodoro_stopwatch.running)
		element_repaint(mode_panel)
	}
	
	if index == pomodoro_index {
		pomodoro_stopwatch_toggle()
		return
	}

	pomodoro_index = index
	
	if pomodoro_stopwatch.running {
		pomodoro_stopwatch_reset()
	}

	time.stopwatch_start(&pomodoro_stopwatch)
	pomodoro_label_format()
}

// writes the pomodoro label
pomodoro_label_format :: proc() {
	accumulated := time.stopwatch_duration(pomodoro_stopwatch)
	wanted_minutes := pomodoro_time_index(pomodoro_index)
	duration := (time.Minute * time.Duration(wanted_minutes)) - accumulated
	_, minutes, seconds := duration_clock(duration)

	// TODO could check for diff and only repaint then!
	b := &sb.pomodoro_label.builder
	strings.builder_reset(b)
	fmt.sbprintf(b, "%2d:%2d", int(minutes), int(seconds))
	element_repaint(sb.pomodoro_label)
}		

// on interval update the pomodoro label
pomodoro_timer_callback :: proc "c" (interval: u32, data: rawptr) -> u32 {
	context = runtime.default_context()
	context.logger = gs.logger

	if pomodoro_stopwatch.running {
		pomodoro_label_format()
		sdl_push_empty_event()
	} 

	return interval
}

// get time from slider
pomodoro_time_index :: proc(index: int) -> f32 {
	index := clamp(index, 0, 2)
	position: f32
	switch index {
		case 0: position = sb.options.slider_pomodoro_work.position
		case 1: position = sb.options.slider_pomodoro_short_break.position
		case 2: position = sb.options.slider_pomodoro_long_break.position
	}
	return position * 60
}

pomodoro_button_message :: proc(element: ^Element, msg: Message, di: int, dp: rawptr) -> int {
	button := cast(^Button) element

	pomodoro_index_from :: proc(builder: strings.Builder) -> int {
		text := strings.to_string(builder)
		
		switch text {
			case "1": return 0
			case "2": return 1
			case "3": return 2
		}			

		unimplemented("gotta add pomodoro index")
	}

	#partial switch msg {
		case .Button_Highlight: {
			color := cast(^Color) dp
			index := pomodoro_index_from(button.builder)
			selected := index == pomodoro_index
			color^ = selected ? theme.text_default : theme.text_blank
			return selected ? 1 : 2
		}

		case .Clicked: {
			pomodoro_index = pomodoro_index_from(button.builder)
			pomodoro_stopwatch_reset()
			pomodoro_label_format()
			element_repaint(element)
		}
	}

	return 0
}

pomodoro_update :: proc() {
	goal_today := max(time.Duration(sb.options.slider_work_today.position * 24), 1) * time.Hour
	sb.options.gauge_work_today.position = f32(pomodoro_acummulated_today) / f32(goal_today)
}