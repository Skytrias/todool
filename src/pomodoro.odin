package src

import "core:log"
import "core:fmt"
import "core:math/rand"
import "core:math/ease"
import "core:runtime"
import "core:strings"
import "core:time"
import sdl "vendor:sdl2"

Pomodoro_Celebration :: struct {
	x, y: f32,
	color: Color,
	skip: bool,
}

Pomodoro :: struct {
	index: int, // 0-2
	timer_id: sdl.TimerID,
	stopwatch: time.Stopwatch,
	accumulated: time.Duration,

	celebration_goal_reached: bool,
	celebrating: bool,
	celebration: []Pomodoro_Celebration,
}
pomodoro: Pomodoro

pomodoro_init :: proc() {
	pomodoro.timer_id = sdl.AddTimer(500, pomodoro_timer_callback, nil)
	pomodoro.celebration = make([]Pomodoro_Celebration, 256)
}

pomodoro_destroy :: proc() {
	delete(pomodoro.celebration)
	sdl.RemoveTimer(pomodoro.timer_id)
}

// spawn & move particles down
pomodoro_celebration_spawn :: proc(x, y: f32) {
	if !pomodoro.celebrating {
		pomodoro.celebrating = true
		// fmt.eprintln("called", mode_panel.bounds)
		
		for c in &pomodoro.celebration {
			c.skip = false
			c.x	= x
			c.y = y
			c.color = color_rand_non_alpha()

			WIDTH :: 400
			x_goal := x + rand.float32() * WIDTH - WIDTH / 2 
			anim_duration := time.Millisecond * time.Duration(rand.float32() * 4000 + 500)
			anim_wait := rand.float64() * 2
			window_animate(window_main, &c.y, f32(mode_panel.bounds.b + 50), .Quadratic_In_Out, anim_duration, anim_wait)
			window_animate(window_main, &c.x, x_goal, .Quadratic_Out, anim_duration, anim_wait)
		}
	}
}

// render particles as circles
pomodoro_celebration_render :: proc(target: ^Render_Target) {
	if pomodoro.celebrating {
		draw_count := 0

		for c in &pomodoro.celebration {
			if c.skip {
				continue
			}

			draw_count += 1
			rect := rect_wh(int(c.x), int(c.y), 10, 10)
			render_rect(target, rect, c.color, ROUNDNESS)	

			if int(c.y) >= mode_panel.bounds.b {
				c.skip = true
			}
		}

		// clear
		if draw_count == 0 {
			pomodoro.celebrating = false
		}
	}
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

pomodoro_stopwatch_stop_add :: proc() {
	diff := time_stop_stopwatch(&pomodoro.stopwatch)
	pomodoro.accumulated += diff
	// pomodoro.accumulated += time.Minute * 61		
}

pomodoro_stopwatch_toggle :: proc() {
	if pomodoro.stopwatch.running {
		pomodoro_stopwatch_stop_add()
		sound_play(.Timer_Stop)
	} else {
		if pomodoro.stopwatch._accumulation != {} {
			sound_play(.Timer_Resume)
		} else {
			sound_play(.Timer_Start)
		}

		time.stopwatch_start(&pomodoro.stopwatch)
	}
}

pomodoro_stopwatch_reset :: #force_inline proc() {
	element_hide(sb.stats.button_pomodoro_reset, true)

	if pomodoro.stopwatch.running {
		pomodoro_stopwatch_stop_add()
		pomodoro.stopwatch._accumulation = {}
	}
}

// toggle stopwatch on or off based on index
pomodoro_stopwatch_hot_toggle :: proc(du: u32) {
	defer {
		element_hide(sb.stats.button_pomodoro_reset, !pomodoro.stopwatch.running)
		element_repaint(mode_panel)
	}
	
	value, ok := du_value(du)
	if !ok {
		return
	}

	index := int(value)
	if index == pomodoro.index {
		pomodoro_stopwatch_toggle()
		return
	}

	pomodoro.index = index
	
	if pomodoro.stopwatch.running {
		pomodoro_stopwatch_reset()
	}

	time.stopwatch_start(&pomodoro.stopwatch)
	pomodoro_label_format()
}

pomodoro_stopwatch_diff :: proc() -> time.Duration {
	accumulated := time.stopwatch_duration(pomodoro.stopwatch)
	wanted_minutes := pomodoro_time_index(pomodoro.index)
	// log.info("WANTED", wanted_minutes, accumulated)
	return (time.Minute * time.Duration(wanted_minutes)) - accumulated
}

// writes the pomodoro label
pomodoro_label_format :: proc() {
	duration := pomodoro_stopwatch_diff()
	_, minutes, seconds := duration_clock(duration)

	// TODO could check for diff and only repaint then!
	b := &sb.pomodoro_label.builder
	strings.builder_reset(b)
	text := fmt.sbprintf(b, "%2d:%2d", int(minutes), int(seconds))
	element_repaint(sb.pomodoro_label)
	// log.info("PRINTED", text, duration)
}		

// on interval update the pomodoro label
pomodoro_timer_callback :: proc "c" (interval: u32, data: rawptr) -> u32 {
	context = runtime.default_context()
	context.logger = gs.logger

	if pomodoro.stopwatch.running {
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
		case 0: position = sb.stats.slider_pomodoro_work.position
		case 1: position = sb.stats.slider_pomodoro_short_break.position
		case 2: position = sb.stats.slider_pomodoro_long_break.position
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
			selected := index == pomodoro.index
			color^ = selected ? theme.text_default : theme.text_blank
			return selected ? 1 : 2
		}

		case .Clicked: {
			pomodoro.index = pomodoro_index_from(button.builder)
			pomodoro_stopwatch_reset()
			pomodoro_label_format()
			element_repaint(element)
		}
	}

	return 0
}

pomodoro_update :: proc() {
	// check for duration diff > 0
	{
		if pomodoro.stopwatch.running {
			diff := pomodoro_stopwatch_diff()

			if diff < 0 {
				pomodoro_stopwatch_reset()
				sound_play(.Timer_Ended)
			}
		}
	}

	// set work today position
	{
		goal_today := max(time.Duration(sb.stats.slider_work_today.position * 24), 1) * time.Hour
		sb.stats.gauge_work_today.position = f32(pomodoro.accumulated) / f32(goal_today)
	}

	// just update every frame
	{
		b := &sb.stats.label_time_accumulated.builder
		strings.builder_reset(b)
		hours, minutes, seconds := duration_clock(pomodoro.accumulated)
		fmt.sbprintf(b, "Total: %dh %dm %ds", hours, minutes, seconds)
	}

	{
		if 
			sb.stats.gauge_work_today.position > 1.0 && 
			!pomodoro.celebration_goal_reached && 
			sb.stats.gauge_work_today.bounds != {} && 
			(.Hide not_in sb.enum_panel.flags) {
			pomodoro.celebration_goal_reached = true
			x := sb.stats.gauge_work_today.bounds.l + rect_width_halfed(sb.stats.gauge_work_today.bounds)
			y := sb.stats.gauge_work_today.bounds.t
			pomodoro_celebration_spawn(f32(x), f32(y))
		}
	}
}