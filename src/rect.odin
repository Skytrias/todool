package src

import "core:math"

Rect :: struct {
	l, r, t, b: f32,
}

RECT_INF :: Rect {
	max(f32),
	-max(f32),
	max(f32),
	-max(f32),
}

// build a rectangle from multiple
rect_inf_push :: proc(rect: ^Rect, other: Rect) {
	rect.t = min(rect.t, other.t)
	rect.l = min(rect.l, other.l)
	rect.b = max(rect.b, other.b)
	rect.r = max(rect.r, other.r)
}

rect_one :: #force_inline proc(a: f32) -> Rect {
	return { a, a, a, a }
}

rect_one_inv :: #force_inline proc(a: f32) -> Rect {
	return { a, -a, a, -a }
}

rect_negate :: #force_inline proc(a: Rect) -> Rect {
	return {
		-a.l,
		-a.r,
		-a.t,
		-a.b,
	}
}

rect_valid :: #force_inline proc(a: Rect) -> bool {
	return a.r > a.l && a.b > a.t
}

rect_invalid :: #force_inline proc(rect: Rect) -> bool { 
	return !rect_valid(rect) 
}

rect_wh :: #force_inline proc(x, y, w, h: f32) -> Rect {
  return { x, x + w, y, y + h }
}

rect_center :: #force_inline proc(a: Rect) -> (x, y: f32) {
	return a.l + (a.r - a.l) / 2, a.t + (a.b - a.t) / 2
}

rect_width_halfed :: #force_inline proc(a: Rect) -> f32 {
	return (a.r - a.l) / 2
}

rect_width :: #force_inline proc(a: Rect) -> f32 {
	return (a.r - a.l)
}

rect_height_halfed :: #force_inline proc(a: Rect) -> f32 {
	return (a.b - a.t) / 2
}

rect_height :: #force_inline proc(a: Rect) -> f32 {
	return (a.b - a.t)
}

rect_xxyy :: #force_inline proc(x, y: f32) -> Rect {
	return { x, x, y, y }
}

rect_intersection :: proc(a, b: Rect) -> Rect {
	a := a
	if a.l < b.l do a.l = b.l
	if a.t < b.t do a.t = b.t
	if a.r > b.r do a.r = b.r
	if a.b > b.b do a.b = b.b
	return a
}

// smallest rectangle
rect_bounding :: proc(a, b: Rect) -> Rect {
	a := a
	if a.l > b.l do a.l = b.l
	if a.t > b.t do a.t = b.t
	if a.r < b.r do a.r = b.r
	if a.b < b.b do a.b = b.b
	return a;
}

rect_contains :: proc(a: Rect, x, y: f32) -> bool {
	return a.l <= x && a.r > x && a.t <= y && a.b > y
}		

// rect cutting with MIN

// rect_cut_left :: proc(rect: ^Rect, a: f32) -> Rect {
// 	min_x := rect.l
// 	rect.l = min(rect.r, rect.l + a)
// 	return { min_x, rect.l, rect.t, rect.b }
// }

// rect_cut_right :: proc(rect: ^Rect, a: f32) -> Rect {
// 	max_x := rect.r
// 	rect.r = max(rect.l, rect.r - a)
// 	return { rect.r, max_x, rect.t, rect.b }
// }

// rect_cut_top :: proc(rect: ^Rect, a: f32) -> Rect {
// 	min_y := rect.t
// 	rect.t = min(rect.b, rect.t + a)
// 	return { rect.l, rect.r, min_y, rect.t }
// }

// rect_cut_bottom :: proc(rect: ^Rect, a: f32) -> Rect {
// 	max_y := rect.b
// 	rect.b = max(rect.t, rect.b - a)
// 	return { rect.l, rect.r, rect.b, max_y }
// }

// rect cutting with HARD CUT, will result in invalid rectangles when out of size

rect_cut_left :: proc(rect: ^Rect, a: f32) -> (res: Rect) {
	res = rect^
	res.r = rect.l + a
	rect.l = res.r
	return
}

rect_cut_right :: proc(rect: ^Rect, a: f32) -> (res: Rect) {
	res = rect^
	res.l = rect.r - a
	rect.r = res.l
	return
}

rect_cut_top :: proc(rect: ^Rect, a: f32) -> (res: Rect) {
	res = rect^
	res.b = rect.t + a
	rect.t = res.b
	return
}

rect_cut_bottom :: proc(rect: ^Rect, a: f32) -> (res: Rect) {
	res = rect^
	res.t = rect.b - a
	rect.b = res.t
	return
}

// add another rect as padding
rect_padding :: proc(a, b: Rect) -> Rect {
	a := a
	a.l += b.l
	a.t += b.t
	a.r -= b.r
	a.b -= b.b
	return a
}

// add another rect as padding
rect_margin :: proc(a: Rect, value: f32) -> Rect {
	a := a
	a.l += value
	a.t += value
	a.r -= value
	a.b -= value
	return a
}

rect_add :: proc(a, b: Rect) -> Rect {
	a := a
	a.l += b.l
	a.t += b.t
	a.r += b.r
	a.b += b.b
	return a
}

rect_translate :: proc(a, b: Rect) -> Rect {
	a := a
	a.l += b.l
	a.t += b.t
	a.r += b.l
	a.b += b.t
	return a
}

// cuts out rect b from a and returns the left regions
rect_cut_out_rect :: proc(a, b: Rect) -> (res: [4]Rect) {
	// top
	res[0] = a
	res[0].b = b.t

	// bottom
	res[1] = a
	res[1].t = b.b

	// middle
	last := rect_intersection(res[0], res[1])
	
	// left
	res[2] = last
	res[2].r = b.l
	
	// right
	res[3] = last
	res[3].l = b.r
	return
}

rect_rounded :: proc(using a: Rect) -> Rect {
	return {
		math.round(l),
		math.round(r),
		math.round(t),
		math.round(b),
	}
}

rect_lerp :: proc(a: ^Rect, b: Rect, rate: f32) {
	a.l = math.lerp(a.l, b.l, rate)
	a.r = math.lerp(a.r, b.r, rate)
	a.t = math.lerp(a.t, b.t, rate)
	a.b = math.lerp(a.b, b.b, rate)
}