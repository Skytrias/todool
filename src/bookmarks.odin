package src

import "core:fmt"
import "core:math"
import "core:math/rand"

GRAVITY :: 9.81
BOOKMARK_SPLITS :: 8

Bookmark_State :: struct {
	count: f32,
	speed: f32,
	xoff: f32,
}

// bookmark data
bookmark_index := -1
bookmarks: [dynamic]int
bookmark_states: [dynamic][BOOKMARK_SPLITS]Bookmark_State

bookmark_nearest_index :: proc(backward: bool) -> int {
	// on reset set to closest from current
	if task_head != -1 {
		// look for anything higher than the current index
		visible_index := tasks_visible[task_head].visible_index
		found: bool

		if backward {
			// backward
			for i := len(bookmarks) - 1; i >= 0; i -= 1 {
				index := bookmarks[i]

				if index < visible_index {
					return i
				}
			}
		} else {
			// forward
			for index, i in bookmarks {
				if index > visible_index {
					return i
				}
			}
		}
	}	

	return -1
}

// advance bookmark or jump to closest on reset
bookmark_advance :: proc(backward: bool) {
	if task_head == -1 {
		return
	}

	if bookmark_index == -1 {
		nearest := bookmark_nearest_index(backward)
		
		if nearest != -1 {
			bookmark_index = nearest
			return
		}
	}

	// just normally set
	range_advance_index(&bookmark_index, len(bookmarks) - 1, backward)
}

bookmarks_figure :: proc(direction: f32) {
	for bs in &bookmark_states {
		for i in 0..<BOOKMARK_SPLITS {
			bs[i].xoff += direction * rand.float32() * 5
		}
	}		
}

bookmarks_update :: proc(force_reset: bool) {
	if task_head == -1 {
		return
	}

	// count each bookmark
	count: int
	reset := force_reset
	for task in tasks_visible {
		if task_bookmark_is_valid(task) {
			count += 1
		}
	}

	goal_count := count
	if goal_count != len(bookmark_states) {
		resize(&bookmark_states, goal_count)
		reset = true
	}

	for bs in &bookmark_states {
		for i in 0..<BOOKMARK_SPLITS {
			s := &bs[i]
			
			// init
			if reset {
				s.count = 1
				s.speed = rand.float32() * 2 + 1
			}

			if s.count < 100 - s.speed {
				s.count += (s.count + s.speed) * gs.dt * 2
			}

			if s.xoff != 0 {
				state := true
				animate_to(&state, &s.xoff, 0, 1, 0.1)
			}
		}
	}
}

bookmarks_render_connections :: proc(target: ^Render_Target, clip: RectI) {
	if task_head == -1 {
		return
	}

	render_push_clip(target, clip)
	// render_group_blend_test(target)
	p_last: [2]f32
	count := -1
	goal := bookmark_index

	if bookmark_index == -1 {
		goal = bookmark_nearest_index(true)
	}

	for task in tasks_visible {
		if task_bookmark_is_valid(task) {
			// color := color_alpha(RED, count == goal ? 0.5 : 0.25)
			color := color_alpha(theme.text_default, count == goal ? 0.5 : 0.25)
			x, y := rect_center(task.button_bookmark.bounds)
			p := [2]f32 { x, y }

			if p_last != {} {
				state_index: int
				
				for i in 0..<BOOKMARK_SPLITS {
					t := f32(i) / (BOOKMARK_SPLITS - 1)
					next := [2]f32 { 
						math.lerp(p_last.x, p.x, t),
						math.lerp(p_last.y, p.y, t),
					}
		
					if i != 0 && i != BOOKMARK_SPLITS - 1 {
						state := bookmark_states[count][state_index]
						next.x += state.xoff * 0.1
						next.y += state.count * 0.2
						state_index += 1
					}
		
					render_line(target, p_last, next, color)
					p_last = next
				}
			}

			p_last = p
			count += 1
		}
	}

	// bookmark_noise += 1
	// bookmark_dt += f64(gs.dt)
}