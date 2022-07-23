package src

color_alpha :: proc(color: Color, alpha: f32) -> (res: Color) {
	res = color
	res.a = u8(alpha * 255)
	return
}

color_blend_amount :: proc(a, b: Color, t: f32) -> (result: Color) {
	result.a = a.a
	result.r = u8((1.0 - t) * f32(b.r) + t * f32(a.r))
	result.g = u8((1.0 - t) * f32(b.g) + t * f32(a.g))
	result.b = u8((1.0 - t) * f32(b.b) + t * f32(a.b))
	return
}

color_blend :: proc(c1: Color, c2: Color, amount: f32, use_alpha: bool) -> Color {
	r := amount * (f32(c1.r) / 255) + (1 - amount) * (f32(c2.r) / 255)
	g := amount * (f32(c1.g) / 255) + (1 - amount) * (f32(c2.g) / 255)
	b := amount * (f32(c1.b) / 255) + (1 - amount) * (f32(c2.b) / 255)
	a := amount * (f32(c1.a) / 255) + (1 - amount) * (f32(c2.a) / 255)

	return Color {
		u8(r * 255),
		u8(g * 255),
		u8(b * 255),
		u8(use_alpha ? u8(a * 255) : 255),
	}
}

color_from_f32 :: #force_inline proc(r, g, b, a: f32) -> Color {
	return {
		u8(r * 255),
		u8(g * 255),
		u8(b * 255),
		u8(a * 255),
	}
}

color_hsv_to_rgb :: proc(h, s, v: f32) -> (res: Color) {
	if s == 0 {
		return color_from_f32(v, v, v, 1)
	}

	i := int(h * 6)
	f := (h * 6) - f32(i)
	p := v * (1 - s)
	q := v * (1 - s * f)
	t := v * (1 - s * (1 - f))
	i %= 6

	switch i {
		case 0: return color_from_f32(v, t, p, 1)
		case 1: return color_from_f32(q, v, p, 1)
		case 2: return color_from_f32(p, v, t, 1)
		case 3: return color_from_f32(p, q, v, 1)
		case 4: return color_from_f32(t, p, v, 1)
		case 5: return color_from_f32(v, p, q, 1)
	}

	unimplemented("yup")
}

color_rgb_to_hsv :: proc(col: Color) -> (f32, f32, f32, f32) {
	r := f32(col.r) / 255
	g := f32(col.g) / 255
	b := f32(col.b) / 255
	a := f32(col.a) / 255
	c_min := min(r, g, b)
	c_max := max(r, g, b)
	h, s, v: f32
	h  = 0.0
	s  = 0.0
	// v  = (c_min + c_max) * 0.5
	v = c_max

	if c_max != c_min {
		delta := c_max - c_min
		// s = c_max == 0 ? 0 : 1 - (1 * c_min / c_max)
		s = c_max == 0 ? 0 : delta / c_max
		// s = d / (2.0 - c_max - c_min) if v > 0.5 else d / (c_max + c_min)
		switch {
			case c_max == r: {
				h = (g - b) / delta + (6.0 if g < b else 0.0)
			}
			
			case c_max == g: {
				h = (b - r) / delta + 2.0
			}

			case c_max == b: {
				h = (r - g) / delta + 4.0
			}
		}

		h *= 1.0 / 6.0
	}

	return h, s, v, a
}