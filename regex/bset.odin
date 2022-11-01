package re
import "core:fmt"

Bset::distinct [4]u64

bset_empty::proc(s: Bset) -> bool {
	return s[0] == 0 && s[1] == 0 && s[2] == 0 && s[3] == 0
}

bset_binop::proc"contextless"(
	l, r: Bset, 
	op: proc"contextless"(u64,u64) -> u64,
) -> (re:Bset) {
	for i in 0..<3 do re[i] = op(l[i], r[i])
	return
}

bset_not::proc"contextless"(s: Bset) -> (re: Bset) {
	for i in 0..<3 do re[i] = ~s[i]
	return
}

bset_and::proc"contextless"(l, r: Bset) -> (re:Bset) { 
	for i in 0..<3 do re[i] = l[i] & r[i]
	return
}

bset_orr::proc"contextless"(l, r: Bset) -> (re:Bset) { 
	for i in 0..<3 do re[i] = l[i] | r[i]
	return
}

bset_xor::proc"contextless"(l, r: Bset) -> (re:Bset) { 
	for i in 0..<3 do re[i] = l[i] ~ r[i]
	return
}

bstr::proc(s:string) -> (r:Bset) {
	for c in s do r = bset_orr(r, bbyte(u8(c)))
	return
}

bbyte::proc(c: u8) -> Bset {
	c := u64(c)
	return brange(c,c)
}

bget::proc"contextless"(s: Bset) -> (re:[256]bool) {
	for j in 0..<u64(3) {
		c := s[j]
		for i in u64(0)..<63 {
			re[i + j * 64] = 0 != ((c >> i) & 1)
		}
	}
	return
}

brange::proc(lo, hi: u64) -> Bset {
	if lo > hi {
		return {}
	}
	brange::proc"contextless"(len, off: u64) -> u64 {
		if 0 == len do return 0
		b: u64 = (1 << len) - 1
		return b << off
	}
	s:Bset
	hix := hi / 64
	hiy := hi % 64
	lox := lo / 64
	loy := lo % 64
	dif := hix - lox

	for dif >= 1 {
		s[lox] = brange(64-loy+1, loy)
		loy  = 0
		lox += 1
		dif -= 1
	}
	s[hix] = brange(hiy+1-loy, loy)
	return s
}
