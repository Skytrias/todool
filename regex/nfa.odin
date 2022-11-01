package re

import "core:fmt"
import "core:mem"
import "core:os"

Reg::distinct [10]Pair(Maybe(int))

Thread::struct {
	node: ^Node,
	reg:  Reg,
}

Match::struct {
	group:      int,
	start, end: int,
	str:        string,
}

act::proc(a: [2]int, idx: int, r: ^Reg) {

	i := 0
	x := a[0]

	for 0 != x {
		if 0 != (x & 1) {
			r[i].l = idx
		}
		i += 1
		x >>= 1
	}

	i = 0
	x = a[1]
	for 0 != x {
		if 0 != (x & 1) {
			r[i].r = idx
		}
		i += 1
		x >>= 1
	}
}

step::proc(cur:  ^[dynamic]Thread, next: ^[dynamic]Thread, idx: int, c: int, glob: ^Reg) {
	clear_dynamic_array(next)
	for t in cur {
		for e in t.node.e {
	
			if bget(e.c)[c] {
				thr := Thread{e.n, t.reg}
				act(e.a, idx, &thr.reg)
				append(next, thr)
			}
		}
		if t.node.f {
			glob ^= t.reg
		}
	}
}

match::proc(node: ^Node, g: int, src: string) -> []Match {
	cur  : [dynamic]Thread
	next : [dynamic]Thread
	append(&cur, Thread{node, Reg{}})
	glob : Reg

	for c, i in src {
		step(&cur, &next, i, int(c), &glob)
		cur, next = next, cur
	}
	step(&cur, &next, len(src), 0, &glob)
	
	delete(cur)
	delete(next)
	matchs := make([]Match, g+1)
	sp := 0
	for p, i in glob {
		if l, ok := p.l.(int); ok {
			if r, ok := p.r.(int); ok {
				// matchs.len += 1;
				matchs[sp].start = l
				matchs[sp].end   = r
				matchs[sp].str   = src[l:r]
				matchs[sp].group = i
				sp+=1
			}
		}
	}
	return matchs
}

main::proc() {
	using fmt

	src := "f[o]+bar"

	if len(os.args) > 1 {
		src = os.args[1]
	}

	println("Parsing regex:", src)

	re, g, ok := parse_expr(src)

	display(re)
	instr := compile(re)
	sink: [dynamic][dynamic]^Instr
	vis:  map[^Instr]int
	fmt.println(instr)

	// head := collect2(instr);
	// tail :=  new(Node);
	// tail.f = true;
	// head := compile2(re, {}, tail);
	// graph(head, src);
}
