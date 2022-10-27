package regex

import "core:mem"
import "core:fmt"

buf: [8000]u8
buf_dst: []u8

Paren :: struct {
	nalt: int,
	natom: int,
}

Regex_To_Postfix_Error :: enum {
	None,
	Buffer_To_Small,
	Parens_Exceeded,
	Parens_At_Start,
	Atom_Not_Set_Yet,
	Unknown,
}

// converts infix regexp to postfix notation
// insert . as explicit concatenation operator
// returns the resulting bytes, possible error
re2post :: proc(re: string) -> (
	res: []byte,
	err: Regex_To_Postfix_Error,
) {
	nalt, natom: int
	paren: [100]Paren

	if len(re) >= size_of(buf) / 2 {
		err = .Buffer_To_Small
		return
	}

	buf_dst = buf[:] // global for easier proc
	paren_index := 0
	re := re

	buf_push :: proc(c: u8) {
		buf_dst[0] = c
		buf_dst = buf_dst[1:]
	}

	for len(re) > 0 {
		defer re = re[1:]

		switch re[0] {
			case '(': {
				if natom > 1 {
					natom -= 1
					buf_push('.')
				}

				if paren_index >= len(paren) {
					err = .Parens_Exceeded
					return
				}

				paren[paren_index] = { nalt, natom }
				paren_index += 1
				nalt = 0
				natom = 0
			}

			case '|': {
				if natom == 0 {
					err = .Atom_Not_Set_Yet
					return
				}

				natom -= 1
				for natom > 0 {
					buf_push('.')
					natom -= 1
				}

				nalt += 1
			}

			case ')': {
				if paren_index == 0 {
					err = .Parens_At_Start
					return
				}

				if natom == 0 {
					err = .Atom_Not_Set_Yet
					return 
				}

				natom -= 1
				for natom > 0 {
					buf_push('.')
					natom -= 1
				}

				for ; nalt > 0; nalt -= 1 {
					buf_push('|')
				}

				paren_index -= 1
				p := &paren[paren_index]
				nalt = p.nalt
				natom = p.natom
				natom += 1
			}

			case '*', '+', '?': {
				if natom == 0 {
					err = .Atom_Not_Set_Yet
					return
				}

				buf_push(re[0])
			}

			case: {
				if natom > 1 {
					natom -= 1
					buf_push('.')
				}

				buf_push(re[0])
				natom += 1
			}
		}
	}

	if paren_index != 0 {
		err = .Parens_At_Start
		return
	}

	natom -= 1
	for natom > 0 {
		buf_push('.')
		natom -= 1
	}	

	for ; nalt > 0; nalt -= 1 {
		buf_push('|')
	}

	// TODO might need more?
	res = buf[:len(buf) - len(buf_dst)]
	return
}

STATE_MATCH :: 256
STATE_SPLIT :: 256

State :: struct {
	c: int,
	out: ^State,
	out1: ^State,
	lastlist: int,
}
matchstate := State { c = STATE_MATCH }
nstate: int

state_init :: proc(
	c: int,
	out: ^State,
	out1: ^State,
) -> (s: ^State) {
	s = new(State)
	s.c = c
	s.out = out
	s.out1 = out1
	nstate += 1
	return
}

Frag :: struct {
	start: ^State,
	out: ^Ptrlist,
}

Ptrlist :: struct #raw_union {
	next: ^Ptrlist,
	s: ^State,
}

// create singleton list containing just outp
list1 :: proc(outp: ^^State) -> (res: ^Ptrlist) {
	res.s = outp^
	return
}

// path the list of states at out to point to start
patch :: proc(l: ^Ptrlist, s: ^State) {
	next: ^Ptrlist
	l := l

	for l != nil {
		next = l.next
		l.s = s
		l = next
	}
}

// join the two lists l1 and l2
// returns the combination
list_append :: proc(l1, l2: ^Ptrlist) -> (res: ^Ptrlist) {
	res = l1
	l1 := l1

	for l1.next != nil {
		l1 = l1.next
	}
	l1.next = l2

	return
}

// globals to deal with stack better
stack_dst: []Frag
stack_index: int

post2nfa :: proc(postfix: string) -> ^State {
	if len(postfix) == 0 {
		return nil
	}

	stack: [1000]Frag
	e1, e2, e: Frag
	s: ^State
	
	// set globals
	stack_dst = stack[:]
	stack_index = 0


	push :: proc(s: Frag) {
	  stack_dst[stack_index] = s
	  stack_index += 1
	}

	pop :: proc() -> (res: Frag) {
		res = stack_dst[stack_index]
		stack_index -= 1
		return
	}

	for p_index := 0; p_index < len(postfix); p_index += 1 {
		c := postfix[p_index]
		
		switch c {
			case: {
				s = state_init(int(c), nil, nil)
				push({ s, list1(&s.out) })
			}

			// catenate
			case '.': {
				e2 = pop()
				e1 = pop()
				patch(e1.out, e2.start)
				push({ e1.start, e2.out })
			}

			// alternate
			case '|': {
				e2 = pop()
				e1 = pop()
				s = state_init(STATE_SPLIT, e1.start, e2.start)
				push({ s, list_append(e1.out, e2.out) })
			}

			// zero or one
			case '?': {
				e = pop()
				s = state_init(STATE_SPLIT, e.start, nil)
				push({ s, list_append(e.out, list1(&s.out1)) })
			}

			// zero or more
			case '*': {
				e = pop()
				s = state_init(STATE_SPLIT, e.start, nil)
				patch(e.out, s)
				push({ s, list1(&s.out1) })
			}

			// one or more
			case '+': {
				e = pop()
				s = state_init(STATE_SPLIT, e.start, nil)
				patch(e.out, s)
				push({ e.start, list1(&s.out1) })
			}
		}
	}

	e = pop()
	if stack_index != 0 {
		return nil
	}

	patch(e.out, &matchstate)
	return e.start
}