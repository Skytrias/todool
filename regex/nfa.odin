package regex

// import "core:mem"
// import "core:fmt"

// buf: [8000]u8
// buf_dst: []u8

// Paren :: struct {
// 	nalt: int,
// 	natom: int,
// }

// Regex_To_Postfix_Error :: enum {
// 	None,
// 	Buffer_To_Small,
// 	Parens_Exceeded,
// 	Parens_At_Start,
// 	Atom_Not_Set_Yet,
// 	Unknown,
// }

// // converts infix regexp to postfix notation
// // insert . as explicit concatenation operator
// // returns the resulting bytes, possible error
// re2post :: proc(re: string) -> (
// 	res: []byte,
// 	err: Regex_To_Postfix_Error,
// ) {
// 	nalt, natom: int
// 	paren: [100]Paren

// 	if len(re) >= size_of(buf) / 2 {
// 		err = .Buffer_To_Small
// 		return
// 	}

// 	buf_dst = buf[:] // global for easier proc
// 	paren_index := 0
// 	re := re

// 	buf_push :: proc(c: u8) {
// 		buf_dst[0] = c
// 		buf_dst = buf_dst[1:]
// 	}

// 	for len(re) > 0 {
// 		defer re = re[1:]

// 		switch re[0] {
// 			case '(': {
// 				if natom > 1 {
// 					natom -= 1
// 					buf_push('.')
// 				}

// 				if paren_index >= len(paren) {
// 					err = .Parens_Exceeded
// 					return
// 				}

// 				paren[paren_index] = { nalt, natom }
// 				paren_index += 1
// 				nalt = 0
// 				natom = 0
// 			}

// 			case '|': {
// 				if natom == 0 {
// 					err = .Atom_Not_Set_Yet
// 					return
// 				}

// 				natom -= 1
// 				for natom > 0 {
// 					buf_push('.')
// 					natom -= 1
// 				}

// 				nalt += 1
// 			}

// 			case ')': {
// 				if paren_index == 0 {
// 					err = .Parens_At_Start
// 					return
// 				}

// 				if natom == 0 {
// 					err = .Atom_Not_Set_Yet
// 					return 
// 				}

// 				natom -= 1
// 				for natom > 0 {
// 					buf_push('.')
// 					natom -= 1
// 				}

// 				for ; nalt > 0; nalt -= 1 {
// 					buf_push('|')
// 				}

// 				paren_index -= 1
// 				p := &paren[paren_index]
// 				nalt = p.nalt
// 				natom = p.natom
// 				natom += 1
// 			}

// 			case '*', '+', '?': {
// 				if natom == 0 {
// 					err = .Atom_Not_Set_Yet
// 					return
// 				}

// 				buf_push(re[0])
// 			}

// 			case: {
// 				if natom > 1 {
// 					natom -= 1
// 					buf_push('.')
// 				}

// 				buf_push(re[0])
// 				natom += 1
// 			}
// 		}
// 	}

// 	if paren_index != 0 {
// 		err = .Parens_At_Start
// 		return
// 	}

// 	natom -= 1
// 	for natom > 0 {
// 		buf_push('.')
// 		natom -= 1
// 	}	

// 	for ; nalt > 0; nalt -= 1 {
// 		buf_push('|')
// 	}

// 	// TODO might need more?
// 	res = buf[:len(buf) - len(buf_dst)]
// 	return
// }

// STATE_MATCH :: 256
// STATE_SPLIT :: 256

// State :: struct {
// 	c: int,
// 	out: ^State,
// 	out1: ^State,
// 	lastlist: int,
// }
// matchstate := State { c = STATE_MATCH }
// nstate: int

// state_init :: proc(
// 	c: int,
// 	out: ^State,
// 	out1: ^State,
// ) -> (s: ^State) {
// 	s = new(State)
// 	s.c = c
// 	s.out = out
// 	s.out1 = out1
// 	nstate += 1
// 	return
// }

// Frag :: struct {
// 	start: ^State,
// 	list: [dynamic]^State,
// }

// // // create singleton list containing just outp
// // list1 :: proc(s: ^^State) -> (res: ^Ptrlist) {
// // 	res = new(Ptrlist)

// // 	res.s = s^
// // 	fmt.eprintln("list res:", res)
// // 	return
// // }

// frag_init :: proc(start, to: ^State) -> (res: Frag) {
// 	res.list = make([dynamic]^State, 0, 8)
// 	res.start = start
// 	append(&res.list, to)
// 	return
// }

// // frag_push :: proc(frag: ^, to: ^State) {
// // 	append(&state.list, to)
// // }

// frag_list_patch :: proc(frag: ^Frag, to: ^State) {
// 	for i in 0..<len(frag.list) {
// 		frag.list[i] = to
// 	}
// }

// // // patch the list of states at out to point to start
// // patch :: proc(l: ^Ptrlist, s: ^State) {
// // 	next: ^Ptrlist
// // 	// fmt.eprintln(l, s, s == &matchstate)

// // 	for l := l; l != nil; l = next {
// // 		// fmt.eprintln("\t1")
// // 		next = l.next
// // 		// fmt.eprintln("\t\t2")
// // 		l.s = s
// // 	}
// // }

// // // join the two lists l1 and l2
// // // returns the combination
// // list_append :: proc(l1, l2: ^Ptrlist) -> (res: ^Ptrlist) {
// // 	res = l1
// // 	l1 := l1

// // 	for l1.next != nil {
// // 		l1 = l1.next
// // 	}
// // 	l1.next = l2

// // 	return
// // }

// // globals to deal with stack better
// stackp: ^Frag

// post2nfa :: proc(postfix: string) -> ^State {
// 	if len(postfix) == 0 {
// 		return nil
// 	}

// 	stack: [1000]Frag
// 	e1, e2, e: Frag
// 	s: ^State
	
// 	// set globals
// 	stackp = &stack[0]

// 	push :: proc(s: Frag) {
// 		stackp^ = s
// 		stackp = mem.ptr_offset(stackp, 1)
// 	}

// 	pop :: proc() -> (res: Frag) {
// 		res = stackp^
// 		stackp = mem.ptr_offset(stackp, -1)
// 		// stack_index -= 1
// 		// res = stack_dst[stack_index]
// 		return
// 	}

// 	PP :: proc(args: ..any) {
// 		when true {
// 			fmt.eprintln(..args)
// 		}
// 	}

// 	for p_index := 0; p_index < len(postfix); p_index += 1 {
// 		c := postfix[p_index]
		
// 		switch c {
// 			case: {
// 				PP("CHAR", rune(c))

// 				s = state_init(int(c), nil, nil)
// 				push(frag_init(s, s.out))
// 			}

// 			// catenate
// 			case '.': {
// 				PP("CAT")

// 				e2 = pop()
// 				e1 = pop()
// 				f := frag_init(e1.start, e2.start)
// 				// frag_list_patch(f, e1.out, e2.start)
// 				push(f)
// 			}

// 			// alternate
// 			case '|': {
// 				// PP("ALT")
				
// 				// e2 = pop()
// 				// e1 = pop()
// 				// s = state_init(STATE_SPLIT, e1.start, e2.start)
// 				// push({ s, list_append(e1.out, e2.out) })
// 			}

// 			// zero or one
// 			case '?': {
// 				// PP("Z_O")
				
// 				// e = pop()
// 				// s = state_init(STATE_SPLIT, e.start, nil)
// 				// push({ s, list_append(e.out, list1(s, &s.out1)) })
// 			}

// 			// zero or more
// 			case '*': {
// 				// PP("Z_M")
				
// 				// e = pop()
// 				// s = state_init(STATE_SPLIT, e.start, nil)
// 				// patch(e.out, s)
// 				// push({ s, list1(&s.out1) })
// 			}

// 			// one or more
// 			case '+': {
// 				// PP("O_M")
				
// 				// e = pop()
// 				// s = state_init(STATE_SPLIT, e.start, nil)
// 				// patch(e.out, s)
// 				// push({ e.start, list1(&s.out1) })
// 			}
// 		}
// 	}

// 	PP("DONE")
// 	e = pop()
// 	// if stack_index != 0 {
// 	if stackp != &stack[0] {
// 		return nil
// 	}

// 	fmt.eprintln("PP")
// 	for i in 0..<nstate {
// 		// if stack[i] {
// 			temp := stack[i].start
// 			fmt.eprintf("%d, %p, %p\n", temp.c, temp.out, temp.out1)
// 		// } else {
// 		// 	fmt.eprintln("~~~~~~~~~~~~~~~~NIL~~~~~~~~~~~~~~~")
// 		// }
// 	}

// 	// frag_list_patch(e.start)
// 	// patch(e.start, &matchstate)
// 	return e.start
// }

// List :: struct {
// 	s: [dynamic]^State,
// }

// l1, l2: List
// listid: int

// // compute initial state list
// startlist :: proc(start: ^State, l: ^List) -> ^List {
// 	clear(&l.s)
// 	listid += 1
// 	addstate(l, start)
// 	return l
// }

// // check wether state list contains a match
// ismatch :: proc(l: ^List) -> bool {
// 	for i in 0..<len(l.s) {
// 		if l.s[i] == &matchstate {
// 			fmt.eprintln("\tMATCH STATE FOUND")
// 			return true
// 		}
// 	}

// 	return false
// }

// // add s to l, following unlabeled arrows
// addstate :: proc(l: ^List, s: ^State) {
// 	if s == nil {
// 		fmt.eprintln("SKIP empty state")
// 		return
// 	}

// 	if s.lastlist == listid {
// 		fmt.eprintln("SKIP same id")
// 		return		
// 	}

// 	s.lastlist = listid
// 	if s.c == STATE_SPLIT {
// 		// follow unlabeled arrows
// 		fmt.eprintln("addstate: follow unlabeled")
// 		addstate(l, s.out)
// 		addstate(l, s.out1)
// 		return
// 	}

// 	fmt.eprintln("append state success", s)
// 	append(&l.s, s)
// }

// // step the nfa from the states in clist past the character c
// // create the next NFA state nlist
// step :: proc(clist: ^List, c: int, nlist: ^List) {
// 	listid += 1
// 	clear(&nlist.s)

// 	for i in 0..<len(clist.s) {
// 		s := clist.s[i]

// 		if s.c == c {
// 			fmt.eprintln("Matched byte", s, rune(c), s == &matchstate)
// 			addstate(nlist, s.out)
// 		}
// 	}
// }

// // initialize lists to expected state count
// lists_init :: proc() {
// 	l1.s = make([dynamic]^State, 0, nstate)
// 	l2.s = make([dynamic]^State, 0, nstate)
// }

// match :: proc(start: ^State, s: string) -> bool {
// 	s := s
// 	clist := startlist(start, &l1)
// 	nlist := &l2

// 	for len(s) > 0 {
// 		c := s[0] & 0xFF
// 		fmt.eprintln("B:", rune(c))
// 		step(clist, int(c), nlist)
// 		clist, nlist = nlist, clist // swap
// 		s = s[1:]
// 	}

// 	return ismatch(clist)
// }