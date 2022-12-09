package src

import "core:fmt"
import "core:log"
import "core:math"
import "core:strings"
import "core:math/rand"
import "core:math/ease"
import "core:intrinsics"

CAM_CENTER :: 100

Pan_Camera_Animation :: struct {
	animating: bool,
	direction: int,
	goal: int,
}

Pan_Camera :: struct {
	start_x, start_y: int, // start of drag
	offset_x, offset_y: f32,
	margin_x, margin_y: int,

	freehand: bool, // disables auto centering while panning

	ay: Pan_Camera_Animation,
	ax: Pan_Camera_Animation,

	// screenshake, running on power mode
	screenshake_counter: f32,
	screenshake_x, screenshake_y: f32,
}

// update lifetime
cam_update_screenshake :: proc(using cam: ^Pan_Camera, update: bool) {
	if !pm_screenshake_use() || !pm_show() {
		screenshake_x = 0
		screenshake_y = 0
		screenshake_counter = 0
		return
	} 

	if update {
		// unit range nums
		x := (rand.float32() * 2 - 1)
		y := (rand.float32() * 2 - 1)
		shake := pm_screenshake_amount() // skake amount in px
		lifetime_opt := pm_screenshake_lifetime()
		screenshake_x = x * max(shake - screenshake_counter * shake * 2 * lifetime_opt, 0)
		screenshake_y = y * max(shake - screenshake_counter * shake * 2 * lifetime_opt, 0)
		screenshake_counter += gs.dt
	} else {
		screenshake_x = 0
		screenshake_y = 0
		screenshake_counter = 0
	}
}

// return offsets + screenshake
cam_offsets :: proc(cam: ^Pan_Camera) -> (f32, f32) {
	return cam.offset_x + cam.screenshake_x, cam.offset_y + cam.screenshake_y
}

cam_init :: proc(cam: ^Pan_Camera, margin_x, margin_y: int) {
	cam.offset_x = f32(margin_x)
	cam.margin_x = margin_x
	cam.offset_y = f32(margin_y)
	cam.margin_y = margin_y
}

cam_set_y :: proc(cam: ^Pan_Camera, to: int) {
	cam.offset_y = f32(to)
	scrollbar_position_set(app.custom_split.vscrollbar, f32(-cam.offset_y))
}

cam_set_x :: proc(cam: ^Pan_Camera, to: int) {
	cam.offset_x = f32(to)
	scrollbar_position_set(app.custom_split.hscrollbar, f32(-cam.offset_x))
}

cam_inc_y :: proc(cam: ^Pan_Camera, off: f32) {
	cam.offset_y += off
	scrollbar_position_set(app.custom_split.vscrollbar, f32(-cam.offset_y))
}

cam_inc_x :: proc(cam: ^Pan_Camera, off: f32) {
	cam.offset_x += off
	scrollbar_position_set(app.custom_split.hscrollbar, f32(-cam.offset_x))
}

// return the cam per mode
mode_panel_cam :: #force_inline proc() -> ^Pan_Camera #no_bounds_check {
	return &app.mmpp.cam[app.mmpp.mode]
}

cam_animate :: proc(cam: ^Pan_Camera, x: bool) -> bool {
	a := x ? &cam.ax : &cam.ay
	off := x ? &cam.offset_x : &cam.offset_y
	lerp := x ? &app.caret_lerp_speed_x : &app.caret_lerp_speed_y
	using a

	if cam.freehand || !animating {
		return false
	}

	real_goal := direction == CAM_CENTER ? f32(goal) : off^ + f32(direction * goal)
	// fmt.eprintln("real_goal", x ? "x" : "y", direction == 0, real_goal, off^, direction)
	res := animate_to(
		&animating,
		off,
		real_goal,
		1 + lerp^,
		1,
	)

	scrollbar_position_set(app.custom_split.vscrollbar, f32(-cam.offset_y))
	scrollbar_position_set(app.custom_split.hscrollbar, f32(-cam.offset_x))

	lerp^ = res ? lerp^ + 0.5 : 1

	// if !res {
	// 	fmt.eprintln("done", x ? "x" : "y", off^, goal)
	// }

	return res
}

// returns the wanted goal + direction if y is out of bounds of focus rect
cam_bounds_check_y :: proc(
	cam: ^Pan_Camera,
	focus: RectI,
	to_top: int,
	to_bottom: int,
) -> (goal: int, direction: int) {
	if cam.margin_y * 2 > rect_height(focus) {
		return
	}

	if to_top < focus.t + cam.margin_y {
		goal = focus.t - to_top + cam.margin_y
	
		if goal != 0 {
			direction = 1
			return
		}
	} 

	if to_bottom > focus.b - cam.margin_y {
		goal = to_bottom - focus.b + cam.margin_y

		if goal != 0 {
			direction = -1
		}
	}

	return
}

cam_bounds_check_x :: proc(
	cam: ^Pan_Camera,
	focus: RectI,
	to_left: int,
	to_right: int,
) -> (goal: int, direction: int) {
	if cam.margin_x * 2 >= rect_width(focus) {
		return
	}

	if to_left < focus.l + cam.margin_x {
		goal = focus.l - to_left + cam.margin_x

		if goal != 0 {
			direction = 1
			return
		}
	} 

	if to_right >= focus.r - cam.margin_x {
		goal = to_right - focus.r + cam.margin_x
		
		if goal != 0 {
			direction = -1
		}
	}

	return
}

// check animation on caret bounds
mode_panel_cam_bounds_check_y :: proc(
	to_top: int,
	to_bottom: int,
	use_task: bool, // use task boundary
) {
	cam := mode_panel_cam()

	if cam.freehand {
		return
	}

	to_top := to_top
	to_bottom := to_bottom

	goal: int
	direction: int
	if app.task_head != -1 && use_task {
		task := app_task_head()
		to_top = task.bounds.t
		to_bottom = task.bounds.b
	}

	goal, direction = cam_bounds_check_y(cam, app.mmpp.bounds, to_top, to_bottom)

	if direction != 0 {
		element_animation_start(app.mmpp)
		cam.ay.animating = true
		cam.ay.direction = direction
		cam.ay.goal = goal
	}
}

// check animation on caret bounds
mode_panel_cam_bounds_check_x :: proc(
	to_left: int,
	to_right: int,
	check_stop: bool,
	use_kanban: bool,
) {
	cam := mode_panel_cam()

	if cam.freehand {
		return
	}

	goal: int
	direction: int
	to_left := to_left
	to_right := to_right

	switch app.mmpp.mode {
		case .List: {
			if app.task_head != -1 {
				t := app_task_head()

				// check if one liner
				if len(t.box.wrapped_lines) == 1 {
					fcs_element(t)
					fcs_ahv(.Left, .Top)
					text_width := string_width(ss_string(&t.box.ss))

					// if rect_width(mode_panel.bounds) - cam.margin_x * 2 

					to_left = t.bounds.l
					to_right = t.bounds.l + text_width
					// rect := rect_wh(t.bounds.l, t.bounds.t, text_width, text_width + LINE_WIDTH, scaled_size)
				}
			}

			goal, direction = cam_bounds_check_x(cam, app.mmpp.bounds, to_left, to_right)
		}

		case .Kanban: {
			// find indent 0 task and get its rect
			t: ^Task
			if app.task_head != -1 && use_kanban {
				index := app.task_head
				
				for t == nil || (t.indentation != 0 && index >= 0) {
					t = app_task_filter(index)
					index -= 1
				}
			}

			if t != nil && t.kanban_rect != {} && use_kanban {
				// check if larger than kanban size
				if rect_width(t.kanban_rect) < rect_width(app.mmpp.bounds) - cam.margin_x * 2 {
					to_left = t.kanban_rect.l
					to_right = t.kanban_rect.r
				} 
			}

			goal, direction = cam_bounds_check_x(cam, app.mmpp.bounds, to_left, to_right)
		}
	} 

	// fmt.eprintln(goal, direction)

	if check_stop {
		if direction == 0 {
			cam.ax.animating = false
			// fmt.eprintln("FORCE STOP")
		} else {
			// fmt.eprintln("HAD DIRECTION X", goal, direction)
		}
	} else if direction != 0 {
		element_animation_start(app.mmpp)
		cam.ax.animating = true
		cam.ax.direction = direction
		cam.ax.goal = goal
	}
}

cam_center_by_height_state :: proc(
	cam: ^Pan_Camera,
	focus: RectI,
	y: int,
	max_height: int = -1,
) {
	if cam.freehand {
		return
	}

	height := rect_height(focus)
	offset_goal: int

	switch app.mmpp.mode {
		case .List: {
			// center by view height max height is lower than view height
			if max_height != -1 && max_height < height {
				offset_goal = (height / 2 - max_height / 2)
			} else {
				top := y - int(cam.offset_y)
				offset_goal = (height / 2 - top)
			}
		}

		case .Kanban: {
			// center by view height max height is lower than view height
			if max_height != -1 && max_height < height {
				offset_goal = (height / 2 - max_height / 2)
			} else {
				top := y - int(cam.offset_y)
				// NOTE clamps to the top of the kanban region youd like to see at max
				offset_goal = min(height / 2 - top, cam.margin_y)
				// fmt.eprintln(top, height, offset_goal, cam.offset_y)
			}
		}
	}

	element_animation_start(app.mmpp)
	cam.ay.animating = true
	cam.ay.direction = CAM_CENTER
	cam.ay.goal = offset_goal
}