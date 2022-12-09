package src

import "core:fmt"
import "core:math"
import "core:math/rand"

GRAVITY :: 9.81
BOOKMARK_SPLITS :: 8

Bookmark_State :: struct {
	current_index: int,
	rows: [dynamic]^Task,
	alpha: f32,
}
bs: Bookmark_State

bookmark_state_init :: proc() {
	using bs
	current_index = -1
	rows = make([dynamic]^Task, 0, 32)
}

bookmark_state_destroy :: proc() {
	using bs
	delete(rows)
}

bookmark_nearest_index :: proc(backward: bool) -> int {
	// on reset set to closest from current
	if app_filter_not_empty() {
		// look for anything higher than the current index
		filter_index := app_task_head().filter_index
		found: bool

		if backward {
			// backward
			for i := len(bs.rows) - 1; i >= 0; i -= 1 {
				if bs.rows[i].filter_index < filter_index {
					return i
				}
			}
		} else {
			// forward
			for task, i in &bs.rows {
				if task.filter_index > filter_index {
					return i
				}
			}
		}
	}	

	return -1
}

// advance bookmark or jump to closest on reset
bookmark_advance :: proc(backward: bool) {
	if app.task_head == -1 {
		return
	}

	if bs.current_index == -1 {
		nearest := bookmark_nearest_index(backward)
		
		if nearest != -1 {
			bs.current_index = nearest
			return
		}
	}

	// just normally set
	range_advance_index(&bs.current_index, len(bs.rows) - 1, backward)
}

bookmarks_clear_and_set :: proc() {
	// count first
	clear(&bs.rows)
	for index in app.pool.filter {
		task := app_task_list(index)

		if task_bookmark_is_valid(task) {
			append(&bs.rows, task)
		}
	}
}

bookmarks_render_connections :: proc(target: ^Render_Target, clip: RectI) {
	if app.task_head == -1 || len(bs.rows) <= 1 || bs.alpha == 0 {
		return
	}

	render_push_clip(target, clip)
	p_last: [2]f32
	count := -1
	goal := bs.current_index

	if bs.current_index == -1 {
		goal = bookmark_nearest_index(true)
	}

	for task in bs.rows {
		alpha := (count == goal ? 0.5 : 0.25) * bs.alpha
		color := color_alpha(theme.text_default, alpha)
		
		x, y := rect_center(task.button_bookmark.bounds)
		p := [2]f32 { x, y }

		if p_last != {} {
			render_line(target, p_last, p, color)
		}

		p_last = p
		count += 1
	}
}