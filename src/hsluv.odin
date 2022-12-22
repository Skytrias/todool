package src

import "core:math"
import "core:c/libc"

Triplet :: struct {
	a, b, c: f64,
}

// for RGB
m := [3]Triplet {
	{  3.24096994190452134377, -1.53738317757009345794, -0.49861076029300328366 },
	{ -0.96924363628087982613,  1.87596750150772066772,  0.04155505740717561247 },
	{  0.05563007969699360846, -0.20397695888897656435,  1.05697151424287856072 },
}

// for XYZ 
m_inv := [3]Triplet {
	{  0.41239079926595948129,  0.35758433938387796373,  0.18048078840183428751 },
	{  0.21263900587151035754,  0.71516867876775592746,  0.07219231536073371500 },
	{  0.01933081871559185069,  0.11919477979462598791,  0.95053215224966058086 },
}

REF_U :: 0.19783000664283680764
REF_V :: 0.46831999493879100370

KAPPA :: 903.29629629629629629630
EPSILON :: 0.00885645167903563082

Bounds :: struct {
	a, b: f64,
}

get_bounds :: proc "contextless" (l: f64) -> (bounds: [6]Bounds) {
	tl := l + 16.0
	sub1 := (tl * tl * tl) / 1560896.0
	sub2 := sub1 > EPSILON ? sub1 : (l / KAPPA)

	for channel in 0..<3 {
		m1 := m[channel].a
		m2 := m[channel].b
		m3 := m[channel].c

		for t in 0..<f64(2) {
			top1 := (284517.0 * m1 - 94839.0 * m3) * sub2
			top2 := (838422.0 * m3 + 769860.0 * m2 + 731718.0 * m1) * l * sub2 -  769860.0 * t * l
			bottom := (632260.0 * m3 - 126452.0 * m2) * sub2 + 126452.0 * t

			bounds[channel * 2 + int(t)].a = top1 / bottom
			bounds[channel * 2 + int(t)].b = top2 / bottom
		}
	}

	return
}

intersect_line_line :: proc "contextless" (line1, line2: Bounds) -> f64 {
	return (line1.b - line2.b) / (line2.a - line1.a)
}

dist_from_pole_squared :: proc "contextless" (x, y: f64) -> f64 {
	return x * x + y * y
}

ray_length_until_intersect :: proc "contextless" (theta: f64, line: Bounds) -> f64 {
	return line.b / (math.sin(theta) - line.a * math.cos(theta))
}

max_safe_chroma_for_l :: proc "contextless" (l: f64) -> f64 {
	min_len_squared := max(f64)
	bounds := get_bounds(l)

	for i in 0..<6 {
		m1 := bounds[i].a
		b1 := bounds[i].b
		// x where line intersects with perpendicular running though (0, 0)
		line2 := Bounds { -1.0 / m1, 0.0 }
		x := intersect_line_line(bounds[i], line2)
		distance := dist_from_pole_squared(x, b1 + x * m1)

		if distance < min_len_squared {
			min_len_squared = distance
		}
	}

	return math.sqrt(min_len_squared)
}

max_chroma_for_lh :: proc "contextless" (l, h: f64) -> f64 {
	min_len := max(f64)
	hrad := h * 0.01745329251994329577 // (2 * pi / 360)
	bounds := get_bounds(l)

	for i in 0..<6 {
		len := ray_length_until_intersect(hrad, bounds[i])

		if len >= 0 && len < min_len {
			min_len = len
		}
	}

	return min_len
}

dot_product :: proc "contextless" (t1, t2: Triplet) -> f64 {
	return t1.a * t2.a + t1.b * t2.b + t1.c * t2.c
}

// Used for rgb conversions
from_linear :: proc "contextless" (c: f64) -> f64 {
	if c <= 0.0031308 {
		return 12.92 * c
	} else {
		return 1.055 * math.pow(c, 1.0 / 2.4) - 0.055
	}
}

to_linear :: proc "contextless" (c: f64) -> f64 {
	if c > 0.04045 {
		return math.pow((c + 0.055) / 1.055, 2.4)
	}	else {
		return c / 12.92
	}
}

xyz_to_rgb :: proc "contextless" (in_out: ^Triplet) {
	r := from_linear(dot_product(m[0], in_out^))
	g := from_linear(dot_product(m[1], in_out^))
	b := from_linear(dot_product(m[2], in_out^))
	in_out.a = r
	in_out.b = g
	in_out.c = b
}

rgb_to_xyz :: proc "contextless" (in_out: ^Triplet) {
	rgbl := Triplet { to_linear(in_out.a), to_linear(in_out.b), to_linear(in_out.c) }
	x := dot_product(m_inv[0], rgbl)
	y := dot_product(m_inv[1], rgbl)
	z := dot_product(m_inv[2], rgbl)
	in_out.a = x
	in_out.b = y
	in_out.c = z
}

cbrt :: proc "contextless" (y: f64) -> f64 {
	return math.pow(y, 1.0 / 3.0)
}

/*
https://en.wikipedia.org/wiki/CIELUV
In these formulas, Yn refers to the reference white point. We are using
illuminant D65, so Yn (see refY in Maxima file) equals 1. The formula is
simplified accordingly.
*/
y_to_l :: proc "contextless" (y: f64) -> f64 {
	if y <= EPSILON {
		return y * KAPPA
	}	else {
		return 116.0 * cbrt(y) - 16.0
	}
}

l_to_y :: proc "contextless" (l: f64) -> f64 {
	if l <= 8.0 {
		return l / KAPPA
	} else {
		x := (l + 16.0) / 116.0
		return (x * x * x)
	}
}

xyz_to_luv :: proc "contextless" (in_out: ^Triplet) {
	var_u := (4.0 * in_out.a) / (in_out.a + (15.0 * in_out.b) + (3.0 * in_out.c))
	var_v := (9.0 * in_out.b) / (in_out.a + (15.0 * in_out.b) + (3.0 * in_out.c))
	l := y_to_l(in_out.b)
	u := 13.0 * l * (var_u - REF_U)
	v := 13.0 * l * (var_v - REF_V)

	in_out.a = l
	if l < 0.00000001 {
		in_out.b = 0.0
		in_out.c = 0.0
	} else {
		in_out.b = u
		in_out.c = v
	}
}

luv_to_xyz :: proc "contextless" (in_out: ^Triplet) {
	if in_out.a <= 0.00000001 {
		// Black will create a divide-by-zero error.
		in_out.a = 0.0
		in_out.b = 0.0
		in_out.c = 0.0
		return
	}

	var_u := in_out.b / (13.0 * in_out.a) + REF_U
	var_v := in_out.c / (13.0 * in_out.a) + REF_V
	y := l_to_y(in_out.a)
	x := -(9.0 * y * var_u) / ((var_u - 4.0) * var_v - var_u * var_v)
	z := (9.0 * y - (15.0 * var_v * y) - (var_v * x)) / (3.0 * var_v)
	in_out.a = x
	in_out.b = y
	in_out.c = z
}

luv_to_lch :: proc "contextless" (in_out: ^Triplet) {
	l := in_out.a
	u := in_out.b
	v := in_out.c
	h: f64
	c := math.sqrt(u * u + v * v)

	// Grays: disambiguate hue
	if c < 0.00000001 {
		h = 0
	} else {
		h = math.atan2(v, u) * 57.29577951308232087680  // (180 / pi)
		
		if h < 0.0 {
			h += 360.0
		}
	}

	in_out.a = l
	in_out.b = c
	in_out.c = h
}

lch_to_luv :: proc "contextless" (in_out: ^Triplet) {
	hrad := in_out.c * 0.01745329251994329577  // (pi / 180.0)
	u := math.cos(hrad) * in_out.b
	v := math.sin(hrad) * in_out.b

	in_out.b = u
	in_out.c = v
}

hsluv_to_lch :: proc "contextless" (in_out: ^Triplet) {
	h := in_out.a
	s := in_out.b
	l := in_out.c
	c: f64

	// White and black: disambiguate chroma
	if l > 99.9999999 || l < 0.00000001 {
		c = 0.0
	}	else {
		c = max_chroma_for_lh(l, h) / 100.0 * s
	}

	// Grays: disambiguate hue
	if s < 0.00000001 {
		h = 0.0
	}

	in_out.a = l
	in_out.b = c
	in_out.c = h
}

lch_to_hsluv :: proc "contextless" (in_out: ^Triplet) {
	l := in_out.a
	c := in_out.b
	h := in_out.c
	s: f64

	// White and black: disambiguate saturation
	if l > 99.9999999 || l < 0.00000001 {
		s = 0.0
	}	else {
		s = c / max_chroma_for_lh(l, h) * 100.0
	}

	// Grays: disambiguate hue
	if c < 0.00000001 {
		h = 0.0
	}

	in_out.a = h
	in_out.b = s
	in_out.c = l
}

hpluv_to_lch :: proc "contextless" (in_out: ^Triplet) {
	h := in_out.a
	s := in_out.b
	l := in_out.c
	c: f64

	// White and black: disambiguate chroma
	if l > 99.9999999 || l < 0.00000001 {
		c = 0.0
	}	else {
		c = max_safe_chroma_for_l(l) / 100.0 * s
	}

	// Grays: disambiguate hue
	if s < 0.00000001 {
		h = 0.0
	}

	in_out.a = l
	in_out.b = c
	in_out.c = h
}

lch_to_hpluv :: proc "contextless" (in_out: ^Triplet) {
	l := in_out.a
	c := in_out.b
	h := in_out.c
	s: f64

	// White and black: disambiguate saturation
	if l > 99.9999999 || l < 0.00000001 {
		s = 0.0
	}	else {
		s = c / max_safe_chroma_for_l(l) * 100.0
	}

	// Grays: disambiguate hue
	if c < 0.00000001 {
		h = 0.0
	}

	in_out.a = h
	in_out.b = s
	in_out.c = l
}


/*
Convert HSLuv to RGB.

@param h Hue. Between 0.0 and 360.0.
@param s Saturation. Between 0.0 and 100.0.
@param l Lightness. Between 0.0 and 100.0.
@param[out] pr Red component. Between 0.0 and 1.0.
@param[out] pg Green component. Between 0.0 and 1.0.
@param[out] pb Blue component. Between 0.0 and 1.0.
*/
hsluv_to_rgb :: proc "contextless" (h, s, l: f64) -> (pr, pg, pb: f64) {
	tmp := Triplet { h, s, l }
	hsluv_to_lch(&tmp)
	lch_to_luv(&tmp)
	luv_to_xyz(&tmp)
	xyz_to_rgb(&tmp)

	pr = tmp.a
	pg = tmp.b
	pb = tmp.c
	return
}

hpluv_to_rgb :: proc "contextless" (h, s, l: f64) -> (pr, pg, pb: f64) {
	tmp := Triplet { h, s, l }

	hpluv_to_lch(&tmp)
	lch_to_luv(&tmp)
	luv_to_xyz(&tmp)
	xyz_to_rgb(&tmp)

	pr = tmp.a
	pg = tmp.b
	pb = tmp.c
	return
}

/*
Convert RGB to HSLuv.

@param r Red component. Between 0.0 and 1.0.
@param g Green component. Between 0.0 and 1.0.
@param b Blue component. Between 0.0 and 1.0.
@param[out] ph Hue. Between 0.0 and 360.0.
@param[out] ps Saturation. Between 0.0 and 100.0.
@param[out] pl Lightness. Between 0.0 and 100.0.
*/
rgb_to_hsluv :: proc "contextless" (r, g, b: f64) -> (ph, ps, pl: f64) {
	tmp := Triplet { r, g, b }

	rgb_to_xyz(&tmp)
	xyz_to_luv(&tmp)
	luv_to_lch(&tmp)
	lch_to_hsluv(&tmp)

	ph = tmp.a
	ps = tmp.b
	pl = tmp.c
	return
}

rgb_to_hpluv :: proc "contextless" (r, g, b: f64) -> (ph, ps, pl: f64) {
	tmp := Triplet { r, g, b }

	rgb_to_xyz(&tmp)
	xyz_to_luv(&tmp)
	luv_to_lch(&tmp)
	lch_to_hpluv(&tmp)

	ph = tmp.a
	ps = tmp.b
	pl = tmp.c
	return
}
