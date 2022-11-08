package src

import "core:math"

RectF :: struct {
	l, r, t, b: f32,
}

RECT_LERP_INIT :: RectF {
	max(f32),
	-max(f32),
	max(f32),
	-max(f32),
}

RectI :: struct {
	l, r, t, b: int,
}

RECT_INF :: RectI {
	max(int),
	-max(int),
	max(int),
	-max(int),
}

// build a rectangle from multiple
rect_inf_push :: proc(rect: ^RectI, other: RectI) {
	rect.t = min(rect.t, other.t)
	rect.l = min(rect.l, other.l)
	rect.b = max(rect.b, other.b)
	rect.r = max(rect.r, other.r)
}

rect_one :: #force_inline proc(a: int) -> RectI {
	return { a, a, a, a }
}

rect_one_inv :: #force_inline proc(a: int) -> RectI {
	return { a, -a, a, -a }
}

rect_negate :: #force_inline proc(a: RectI) -> RectI {
	return {
		-a.l,
		-a.r,
		-a.t,
		-a.b,
	}
}

rect_valid :: #force_inline proc(a: RectI) -> bool {
	return a.r > a.l && a.b > a.t
}

rect_invalid :: #force_inline proc(rect: RectI) -> bool { 
	return !rect_valid(rect) 
}

rect_wh :: #force_inline proc(x, y, w, h: int) -> RectI {
  return { x, x + w, y, y + h }
}

rect_center :: #force_inline proc(a: RectI) -> (x, y: f32) {
	return f32(a.l) + f32(a.r - a.l) / 2, f32(a.t) + f32(a.b - a.t) / 2
}

// width
rect_width :: #force_inline proc(a: RectI) -> int {
	return (a.r - a.l)
}
rect_widthf :: #force_inline proc(a: RectI) -> f32 {
	return f32(a.r - a.l)
}
rect_width_halfed :: #force_inline proc(a: RectI) -> int {
	return (a.r - a.l) / 2
}
rect_widthf_halfed :: #force_inline proc(a: RectI) -> f32 {
	return f32(a.r - a.l) / 2
}

// height
rect_height :: #force_inline proc(a: RectI) -> int {
	return (a.b - a.t)
}
rect_heightf :: #force_inline proc(a: RectI) -> f32 {
	return f32(a.b - a.t)
}
rect_height_halfed :: #force_inline proc(a: RectI) -> int {
	return (a.b - a.t) / 2
}
rect_heightf_halfed :: #force_inline proc(a: RectI) -> f32 {
	return f32(a.b - a.t) / 2
}

// width / height by option
rect_opt_v :: #force_inline proc(a: RectI, vertical: bool) -> int {
	return vertical ? rect_height(a) : rect_width(a)
}
rect_opt_h :: #force_inline proc(a: RectI, horizontal: bool) -> int {
	return horizontal ? rect_width(a) : rect_height(a)
}
rect_opt_vf :: #force_inline proc(a: RectI, vertical: bool) -> f32 {
	return vertical ? rect_heightf(a) : rect_widthf(a)
}
rect_opt_hf :: #force_inline proc(a: RectI, horizontal: bool) -> f32 {
	return horizontal ? rect_widthf(a) : rect_heightf(a)
}

rect_xxyy :: #force_inline proc(x, y: int) -> RectI {
	return { x, x, y, y }
}

rect_intersection :: proc(a, b: RectI) -> RectI {
	a := a
	if a.l < b.l do a.l = b.l
	if a.t < b.t do a.t = b.t
	if a.r > b.r do a.r = b.r
	if a.b > b.b do a.b = b.b
	return a
}

// smallest rectangle
rect_bounding :: proc(a, b: RectI) -> RectI {
	a := a
	if a.l > b.l do a.l = b.l
	if a.t > b.t do a.t = b.t
	if a.r < b.r do a.r = b.r
	if a.b < b.b do a.b = b.b
	return a
}

rect_contains :: proc(a: RectI, x, y: int) -> bool {
	return a.l <= x && a.r > x && a.t <= y && a.b > y
}		

// rect cutting with HARD CUT, will result in invalid rectangles when out of size

rect_cut_left :: proc(rect: ^RectI, a: int) -> (res: RectI) {
	res = rect^
	res.r = rect.l + a
	rect.l = res.r
	return
}

rect_cut_right :: proc(rect: ^RectI, a: int) -> (res: RectI) {
	res = rect^
	res.l = rect.r - a
	rect.r = res.l
	return
}

rect_cut_top :: proc(rect: ^RectI, a: int) -> (res: RectI) {
	res = rect^
	res.b = rect.t + a
	rect.t = res.b
	return
}

rect_cut_bottom :: proc(rect: ^RectI, a: int) -> (res: RectI) {
	res = rect^
	res.t = rect.b - a
	rect.b = res.t
	return
}

// add another rect as padding
rect_padding :: proc(a, b: RectI) -> RectI {
	a := a
	a.l += b.l
	a.t += b.t
	a.r -= b.r
	a.b -= b.b
	return a
}

// add another rect as padding
rect_margin :: proc(a: RectI, value: int) -> RectI {
	a := a
	a.l += value
	a.t += value
	a.r -= value
	a.b -= value
	return a
}

rect_add :: proc(a, b: RectI) -> RectI {
	a := a
	a.l += b.l
	a.t += b.t
	a.r += b.r
	a.b += b.b
	return a
}

rect_translate :: proc(a, b: RectI) -> RectI {
	a := a
	a.l += b.l
	a.t += b.t
	a.r += b.l
	a.b += b.t
	return a
}

rect_overlap :: proc(a, b: RectI) -> bool {
	return b.r >= a.l && b.l <= a.r && b.b >= a.t && b.t <= a.b
}

// cuts out rect b from a and returns the left regions
rect_cut_out_rect :: proc(a, b: RectI) -> (res: [4]RectI) {
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

rect_lerp :: proc(a: ^RectF, b: RectI, rate: f32) {
	if a^ == RECT_LERP_INIT {
		a^ = rect_itof(b)
	} else {
		a.l = math.lerp(a.l, f32(b.l), rate)
		a.r = math.lerp(a.r, f32(b.r), rate)
		a.t = math.lerp(a.t, f32(b.t), rate)
		a.b = math.lerp(a.b, f32(b.b), rate)
	}
}

rect_ftoi :: proc(a: RectF) -> RectI {
	return {
		int(a.l),
		int(a.r),
		int(a.t),
		int(a.b),
	}
}

rect_itof :: proc(a: RectI) -> RectF {
	return {
		f32(a.l),
		f32(a.r),
		f32(a.t),
		f32(a.b),
	}
}