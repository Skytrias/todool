package src

import "core:log"
import "core:math"

CAM_CENTER :: 100

Pan_Camera_Animation :: struct {
	animating: bool,
	direction: int,
	goal: f32,
}

Pan_Camera :: struct {
	start_x, start_y: f32, // start of drag
	offset_x, offset_y: f32,
	margin_x, margin_y: f32,

	freehand: bool, // disables auto centering while panning

	ay: Pan_Camera_Animation,
	ax: Pan_Camera_Animation,
}

cam_init :: proc(cam: ^Pan_Camera, margin_x, margin_y: f32) {
	cam.offset_x = margin_x
	cam.margin_x = margin_x
	cam.offset_y = margin_y
	cam.margin_y = margin_y
}

// return the cam per mode
mode_panel_cam :: proc() -> ^Pan_Camera {
	return &mode_panel.cam[mode_panel.mode]
}

cam_animate :: proc(cam: ^Pan_Camera, x: bool) -> bool {
	a := x ? &cam.ax : &cam.ay
	off := x ? &cam.offset_x : &cam.offset_y
	lerp := x ? &caret_lerp_speed_x : &caret_lerp_speed_y
	using a

	if cam.freehand || !animating {
		return false
	}

	real_goal := direction == CAM_CENTER ? goal : math.floor(off^ + f32(direction) * goal)
	// log.info("real_goal", x ? "x" : "y", direction == 0, real_goal, off^)
	res := animate_to(
		&animating,
		off,
		real_goal,
		1 + lerp^,
		1,
	)

	lerp^ = res ? lerp^ + 0.5 : 1

	// if !res {
	// 	log.info("done", x ? "x" : "y", off^, goal)
	// }

	return res
}

// returns the wanted goal + direction if y is out of bounds of focus rect
cam_bounds_check_y :: proc(
	cam: ^Pan_Camera,
	focus: Rect,
	to_top: f32,
	to_bottom: f32,
) -> (goal: f32, direction: int) {
	if cam.margin_y * 2 > rect_height(focus) {
		return
	}

	to_top := to_top * SCALE
	to_bottom := to_bottom * SCALE

	if to_top < focus.t + cam.margin_y {
		goal = math.round(focus.t - to_top + cam.margin_y)
		direction = 1
		return
	} 

	if to_bottom > focus.b - cam.margin_y {
		goal = math.round(to_bottom - focus.b + cam.margin_y)
		direction = -1
	}

	return
}

cam_bounds_check_x :: proc(
	cam: ^Pan_Camera,
	focus: Rect,
	to_left: f32,
	to_right: f32,
) -> (goal: f32, direction: int) {
	if cam.margin_x * 2 > rect_width(focus) {
		return
	}

	to_left := to_left * SCALE
	to_right := to_right * SCALE

	if to_left < focus.l + cam.margin_x {
		goal = math.round(focus.l - to_left + cam.margin_x)
		direction = 1
		return
	} 

	if to_right > focus.r - cam.margin_x {
		goal = math.round(to_right - focus.r + cam.margin_x)
		direction = -1
	}

	return
}

// check animation on caret bounds
mode_panel_cam_bounds_check_y :: proc() {
	cam := mode_panel_cam()

	if cam.freehand {
		return
	}

	goal: f32
	direction: int
	if task_head != -1 {
		to_top := caret_rect.t
		to_bottom := caret_rect.b
		task := tasks_visible[task_head]
		to_top = task.bounds.t
		to_bottom = task.bounds.b

		goal, direction = cam_bounds_check_y(cam, mode_panel.bounds, to_top, to_bottom)
	}

	if direction != 0 {
		element_animation_start(mode_panel)
		cam.ay.animating = true
		cam.ay.direction = direction
		cam.ay.goal = goal
	}
}

// check animation on caret bounds
mode_panel_cam_bounds_check_x :: proc(check_stop: bool) {
	cam := mode_panel_cam()

	if cam.freehand {
		return
	}

	goal: f32
	direction: int
	to_left := caret_rect.l
	to_right := caret_rect.r

	switch mode_panel.mode {
		case .List: {
			// if !options_wrapping() {
				goal, direction = cam_bounds_check_x(cam, mode_panel.bounds, to_left, to_right)
			// }
		}

		case .Kanban: {
			// find indent 0 task and get its rect
			index := task_head
			t: ^Task
			for t == nil || (t.indentation != 0 && index >= 0) {
				t = tasks_visible[index]
				index -= 1
			}

			if t.kanban_rect != {} {
				// check if larger than kanban size
				if rect_width(t.kanban_rect) < rect_width(mode_panel.bounds) - cam.margin_x * 2 {
					to_left = t.kanban_rect.l
					to_right = t.kanban_rect.r
				}

				goal, direction = cam_bounds_check_x(cam, mode_panel.bounds, to_left, to_right)
			}
		}
	} 

	if check_stop {
		if direction == 0 {
			cam.ax.animating = false
		}
	} else if direction != 0 {
		element_animation_start(mode_panel)
		cam.ax.animating = true
		cam.ax.direction = direction
		cam.ax.goal = goal
	}
}

cam_center_by_height_state :: proc(
	cam: ^Pan_Camera,
	focus: Rect,
	y: f32,
	max_height: f32 = -1,
) {
	if cam.freehand {
		return
	}

	height := rect_height(focus)
	offset_goal: f32

	switch mode_panel.mode {
		case .List: {
			// center by view height max height is lower than view height
			if max_height != -1 && max_height < height {
				offset_goal = f32(height / 2 - max_height / 2)
			} else {
				top := y - f32(cam.offset_y)
				offset_goal = f32(height / 2 - top)
			}
		}

		case .Kanban: {

		}
	}

	element_animation_start(mode_panel)
	cam.ay.animating = true
	cam.ay.direction = CAM_CENTER
	cam.ay.goal = offset_goal
}