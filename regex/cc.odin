package re

import "core:fmt"
import "core:mem"

Action::struct {
	a: [2]int,
	n: ^Instr,
}

Node::struct {
	e: [dynamic]Edge,
	a: [2]int,
	f: bool,
	ok: bool,
}

Edge::struct {
	a: [2]int,
	c: Bset, 
	n: ^Node,
}

Set::struct {s:Bset, n:^Instr}
Split::distinct Pair(^Instr)

Instr::union {
	Action,
	Split,
	Set,
}

__match:Instr= nil

compile::proc(re: ^Re) -> ^Instr {
	compile::proc(re: ^Re, t: ^Instr) -> ^Instr {
			switch v in re {
				case Cap:
					e1 := new(Instr)
					e0 := new(Instr)
					e1 ^= Action{{0, 1 << uint(v.g)}, t}
					x := compile(v.x, e1)
					e0 ^= Action{{1 << uint(v.g), 0}, x}
					return e0
				case Bset:
					x := new(Instr)
					x ^= Set{v,t}
					return x
				case Alt:
					r := compile(v.r, t)
					l := compile(v.l, t)
					x := new(Instr)
					x ^= Split{l,r}
					return x
				case Cat:
					return compile(v.l,  compile(v.r,t))
				case Star:
					// if v^ == NON do return t;
					s := new(Instr)
					x := compile(v.x, s)
					s ^= Split{x, t}
					return s
				case Plus:
					s := new(Instr)
					x := compile(v.x, s)
					s ^= Split{x, t}
					return x
				case:
					panic("123")
			}
	}

	e1 := new(Instr)
	e0 := new(Instr)
	e1 ^= Action{{0, 1}, &__match}
	x := compile(re, e1)
	e0 ^= Action{{1, 0}, x}  
	return e0
}

merge::proc(a, b: [2]int) -> [2]int {
	return {a[0] | b[0], a[1] | b[1]}
}

Leaf::struct {
	i: ^Instr,
	a: [2]int,
	s: Bset,
}

closure::proc(instr: ^Instr, a: [2]int, sink: ^[dynamic]Leaf) {
	switch v in instr {
		case Action:
			closure(v.n, merge(v.a,a), sink)
		case Split:
			closure(v.l, a, sink)
			closure(v.r, a, sink)
		case Set:
			append(sink, Leaf{v.n, a, v.s})
		case:
			append(sink, Leaf{nil, a, {}})
	}
}

// collect2::proc(instr: ^Instr) -> ^Node {
// 	head := new(Node);
// 	closure(instr, {}, head, &{});
// 	return head;
// }