package re

import "core:fmt"
import "core:mem"

Allocator::mem.Allocator
Arena::mem.Arena

panic::proc(s: string, loc := #caller_location) -> ! {
	fmt.println(s, loc)

	for {}
}

Star::struct {x:^Re}
Plus::struct {x:^Re}
Gcap::struct(T:typeid){ x: ^T, g: int }
Pair::struct(T:typeid){ l, r: T }
Cap::#type Gcap(Re)

Alt::distinct Pair(^Re)
Cat::distinct Pair(^Re)

ReKind::enum {
	Star,
	Plus,
	Cap,
	Alt,
	Cat,
	Set,
}

Re::union {
	Cap,
	Bset,
	Star,
	Plus,
	Alt,
	Cat,
}


ALP :Re = Re(Bset{~u64(0), ~u64(0), ~u64(0), ~u64(0)})
NON :Re = Re(Bset{})
LAN :Re = Re(Star{&ALP})
EPS :Re = Re(Star{&NON})

unop::proc(k: ReKind, x: Re) -> Re {

	#partial switch k {
		case .Plus:
				return Plus{new_clone(x)}
		case .Star:
				return Star{new_clone(x)}
		case:
			panic("invalid re kind")
	}
}

binop::proc(k: ReKind, l: Re, r: Re) -> Re {

	if .Alt == k {
		switch l {
			case LAN:
				return LAN
			case NON:
				return r
		}
		
		switch r {
			case LAN:
				return LAN
			case NON:
				return l
		}

		if v, ok := l.(Bset); ok {
			if u, ok := r.(Bset); ok {
				return Bset(bset_orr(u,v))
			}
		}
		return Alt{new_clone(l), new_clone(r)}
	}

	if l == NON || r == NON {
		return NON
	}


	return Cat{new_clone(l), new_clone(r)}
}

// parses through text
Parser::struct {
	d: int,
	g: int,
	ng: int,
	s: string, // string to parse, string gets modified throughout bumps
}

// get the next character from the string
peek::proc(p: ^Parser, n := 0 ) -> (c:u8, b:bool) {
	if len(p.s) > n {
		c = p.s[n]
		b = true
	}
	return
}

// peek compare next character to input character
peekc::proc(p: ^Parser, c: u8) -> bool {
	cc, ok := peek(p) 
	return ok && cc == c
}

// peek compare next character to all string characters
peeks::proc(p: ^Parser, s: string) -> bool {
	cc, ok := peek(p) 
	if !ok do return false
	for c in s do if cc == u8(c) do return true
	return false
}

// peek for character match, then increase and return true
bumpc::proc(p: ^Parser, c: u8) -> bool {
	if peekc(p, c) {
		bump(p)
		return true
	}
	return false
}

// bump and return the character result and ok
bump::proc(p: ^Parser) -> (c:u8, b:bool) {
	if c, b = peek(p); b {
		p.s = p.s[1:]
	}
	return
}

// alpha bitset range?
alpha::proc() -> Bset {
	s0 := brange('a','z')
	s1 := brange('A','Z')
	s2 := brange('0','9')
	s3 := bbyte('_')
	x0 := bset_orr(s0, s2)
	x1 := bset_orr(s1, s3)
	return bset_orr(x0, x1)
}

parse_charset::proc(p: ^Parser) -> (re:Re, ok:bool) {
	if bumpc(p, '[') {
		s: Bset
		neg := false
		if bumpc(p, '^') do neg = true
		for !peekc(p, ']') {
			c, ok := bump(p)
			switch c {
				case '\\':
					cc , _ := bump(p)
					switch cc {
						case 'w': s = bset_orr(s, alpha())
						case 'd': s = bset_orr(s, brange('0','9'))
						case 's': s = bset_orr(s, bstr(" \t\n"))
						case 'W': s = bset_orr(s, bset_not(alpha()))
						case 'D': s = bset_orr(s, bset_not(brange('0','9')))
						case 'S': s = bset_orr(s, bset_not(bstr(" \t\n")))
						case:     s = bset_orr(s, bbyte(cc))
					}
				case:
					if m, ok := bump(p); ok && m == '-' {
						if r, ok := bump(p); ok {
							s = bset_orr(s, brange(u64(c), u64(r)))
						} else do panic("123")
					}
					s = bset_orr(s, bbyte(c))
			}
		}
		if !bumpc(p, ']') do panic("123")
		if neg do s = bset_not(s)
		re = Re(s)
		ok = true
	}
	return
}

parse_atom::proc(p: ^Parser, loc := #caller_location) -> (re:Re, ok:bool) {
	c:u8
	
	if c, ok = peek(p); ok {
		switch c {
			case '[':
				return parse_charset(p)
			case '(':
				cap := true
				bump(p)
			
				if peekc(p, '?') {
					if c, ok := peek(p, 1); ok && c == ':' {
						bump(p)
						bump(p)
						cap = false
					}
				}

				if cap {
					p.g  += 1
					p.ng += 1
				}
				d := p.d
				g := p.g
				p.d += 1

				re, ok = parse_alt(p)
				p.d -= 1

				if !ok || d != p.d || !bumpc(p, ')') {
					fmt.println(p.s)
					 panic("unbalanced paranthesis")
				}

				if cap do re = Cap{new_clone(re), g}
				
			case ')', ']', '|', '+', '?', '*': 
				fmt.printf("wtf %c\n", c)
				panic("invalid token")
			case '\\':    
				bump(p)
				cc , _ := bump(p)
				s: Bset
				switch cc {
					case 'w': s = alpha()
					case 'd': s = brange('0','9')
					case 's': s = bstr(" \t\n")
					case 'W': s = bset_not(alpha())
					case 'D': s = bset_not(brange('0','9'))
					case 'S': s = bset_not(bstr(" \t\n"))
					case:     s = bbyte(cc)
				}
				re = s
			case '.':
				re = brange(0,255)
				bump(p)
			case:
				re = bbyte(c)
				bump(p)
		}
	}
	return
}

parse_post::proc(p: ^Parser) -> (re:Re, ok:bool) {
	if re, ok = parse_atom(p); ok {
		for c, ok := peek(p); ok; c, ok = peek(p) {
			fmt.println("[parse_post]", c, p)
			switch c {
					case '*': 
						bump(p) 
						re = unop(.Star, re)
					case '+': 
						bump(p) 
						re = unop(.Plus, re)
					case '?': 
						bump(p) 
						re = binop(.Alt, EPS, re)
					case:
						return
				}
		}
	}
	return
}

parse_cat::proc(p: ^Parser) -> (re:Re, ok:bool) {
	if re, ok = parse_post(p); ok {
		for !peeks(p, "|)]") {
			fmt.println("HERE:", p)
			if rhs, ok := parse_post(p); ok {
				fmt.println("HERE--:", p)
				re = binop(.Cat, re, rhs) 
			}
			else do break
		}
	}
	return
}

parse_alt::proc(p: ^Parser) -> (re:Re, ok:bool) {
	if re, ok = parse_cat(p); ok {
		for bumpc(p, '|') {
			if rhs, ok := parse_cat(p); ok {
				re = binop(.Alt, re, rhs) 
			} else {
				return re, false
			}
		}
	}
	return
}

parse_expr::proc(s: string) -> (re: ^Re, g:int, ok: bool) {
	p := Parser{0, 0, 0, s}
	x: Re
	x, ok = parse_alt(&p)

	if 0 != len(p.s) || !ok do panic("wtf")
	g = p.ng
	if ok do re = new_clone(x)
	return
}

display::proc(re: ^Re ) {
	display::proc(re: ^Re, d: int) {
		for i in 0..<d do fmt.printf("  ")
		d := d+1
		switch v in re {
			case Cap:
				fmt.println("Cap:", v.g)
				display(v.x, d)
			case Bset:
				// fmt.println("Bset:", settostr(v));
				fmt.println("Bset:", v)
			case Star:
				fmt.println("Star:")
				display(v.x, d)
			case Plus:
				fmt.println("Plus:")
				display(v.x, d)
			case Alt:
				fmt.println("Split:")
				display(v.l, d)
				display(v.r, d)
			case Cat:
				fmt.println("Cat:")
				display(v.l, d)
				display(v.r, d)
			case:
				panic("wtf")
		}
	}
	display(re, 0)
}
