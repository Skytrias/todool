package regex

import "core:unicode"
import "core:fmt"
import "core:reflect"
import "core:io"
import "core:bytes"
import "core:mem"
import "core:strings"

Regex_Type :: enum u8 {
	Unused,
	Dot, 
	Begin, 
	End, 
	Questionmark, 
	Star, 
	Plus, 
	Char, 
	Char_Class, 
	Inv_Char_Class, 
	Digit, 
	Not_Digit, 
	Alpha, 
	Not_Alpha, 
	Whitespace, 
	Not_Whitespace, 
}

// byte buffer to store more dynamic data
// only type + additional data stored
State :: struct {
	buffer: bytes.Buffer,
}

state_init :: proc(cap: int = mem.Kilobyte) -> (res: State) {
	bytes.buffer_init_allocator(&res.buffer, 0, cap)
	return
}

state_destroy :: proc(state: ^State) {
	bytes.buffer_destroy(&state.buffer)
}

state_push_type :: proc(state: ^State, type: Regex_Type) -> (err: io.Error) {
	bytes.buffer_write_byte(&state.buffer, transmute(u8) type) or_return
	return
}

state_push_type_char :: proc(state: ^State, c: u8) -> (err: io.Error) {
	bytes.buffer_write_byte(&state.buffer, transmute(u8) Regex_Type.Char) or_return
	bytes.buffer_write_byte(&state.buffer, c) or_return
	return
}

compile :: proc(state: ^State, pattern: string) -> (res: []byte, err: io.Error) {
	bytes.buffer_reset(&state.buffer)
	p := pattern
	
	for len(p) > 0 {
		c := p[0]
		defer p = p[1:]

		switch c {
			case '^': state_push_type(state, .Begin) or_return
			case '$': state_push_type(state, .End) or_return
			case '.': state_push_type(state, .Dot) or_return
			case '*': state_push_type(state, .Star) or_return
			case '+': state_push_type(state, .Plus) or_return
			case '?': state_push_type(state, .Questionmark) or_return

			// escaped character classes
			case '\\': {
				if len(pattern) > 1 {
					p = p[1:]

					switch pattern[0] {
						// meta character
						case 'd': state_push_type(state, .Digit) or_return
						case 'D': state_push_type(state, .Not_Digit) or_return
						case 'w': state_push_type(state, .Alpha) or_return
						case 'W': state_push_type(state, .Not_Alpha) or_return
						case 's': state_push_type(state, .Whitespace) or_return
						case 'S': state_push_type(state, .Not_Whitespace) or_return

						// push escaped character
						case: {
							state_push_type_char(state, pattern[0]) or_return
						}
					}
				}
			}

			// character class
			case '[': {
				// skip
			}

			case: {
				fmt.eprintln("push")
				state_push_type_char(state, c) or_return
			}
		}

		// end
	}
	
	state_push_type(state, .Unused) or_return

	// get result
	res = state.buffer.buf[:]
	return
}

state_print :: proc(state: ^State) {
	if bytes.buffer_is_empty(&state.buffer) {
		return
	}

	print(state.buffer.buf[:])
}

print :: proc(data: []byte) {
	b := data
	enum_names := reflect.enum_field_names(Regex_Type)

	for len(b) > 0 {
		type := transmute(Regex_Type) b[0]
		type_index := int(type)
		defer b = b[1:]

		// exit early
		if type == .Unused {
			break
		}

		fmt.eprint("type:", enum_names[type_index])

		if type == .Char_Class || type == .Inv_Char_Class {
			// TODO
		} else  if type == .Char {
			b = b[1:]
			c := b[0]
			fmt.eprintf(" %v", rune(c))
		}

		fmt.eprintf("\n")
	}
}

match_digit_ascii :: proc(c: u8) -> bool {
	return false
}
match_digit_utf8 :: unicode.is_digit
match_digit :: proc { match_digit_utf8, match_digit_ascii }

match_alpha_ascii :: proc(c: u8) -> bool {
	return false
}
match_alpha_utf8 :: unicode.is_alpha
match_alpha :: proc { match_alpha_utf8, match_alpha_ascii }

match_whitespace_ascii :: proc(c: u8) -> bool {
	return false  	
}
match_whitespace_utf8 :: unicode.is_space
match_whitespace :: proc { match_whitespace_utf8, match_whitespace_ascii }

match_alpha_numeric_ascii :: proc(c: u8) -> bool {
	return c == '_' || match_alpha_ascii(c) || match_digit_ascii(c)
}
match_alpha_numeric_utf8 :: proc(c: rune) -> bool {
	return c == '_' || match_alpha_utf8(c) || match_digit_utf8(c)
}
match_alpha_numeric :: proc { match_alpha_numeric_utf8, match_alpha_numeric_ascii }

match_range_ascii :: proc(c: u8, str: string) -> bool {
	return c != '-' &&
		(len(str) > 0 && str[0] != '-') && 
		(len(str) > 1 && str[1] == '-') &&
		(len(str) > 2 && c >= str[0]  && c <= str[2])
}
match_range_utf8 :: proc(c: rune, str: string) -> bool {
	// TODO do proper utf8!
	return c != '-' &&
		(len(str) > 0 && str[0] != '-') && 
		(len(str) > 1 && str[1] == '-') &&
		(len(str) > 2 && c >= rune(str[0])  && c <= rune(str[2]))
}
match_range :: proc { match_range_utf8, match_range_ascii }

match_dot_ascii :: proc(c: u8) -> bool {
	return c != '\n' && c != '\r'
}
match_dot_utf8 :: proc(c: rune) -> bool {
	return c != '\n' && c != '\r'
}
match_dot :: proc { match_dot_utf8, match_dot_ascii }

// TODO could just use rune for both?
is_meta_char_ascii :: proc(c: u8) -> bool {	
	switch c {
		case 's', 'S', 'w', 'W', 'd', 'D': {
			return true
		}
	}

	return false
}
is_meta_char_utf8 :: proc(c: rune) -> bool {
	switch c {
		case 's', 'S', 'w', 'W', 'd', 'D': {
			return true
		}
	}

	return false
}
is_meta_char :: proc { is_meta_char_utf8, is_meta_char_ascii }

match_meta_char_ascii :: proc(c: u8, str: string) -> bool {
	if len(str) > 0 {
		other := str[0]

		switch other {
			case 'd': return match_digit_ascii(c)
			case 'D': return !match_digit_ascii(c)
			case 'w': return match_alpha_numeric_ascii(c)
			case 'W': return !match_alpha_numeric_ascii(c)
			case 's': return match_whitespace_ascii(c)
			case 'S': return !match_whitespace_ascii(c)
			case: return c == other
		}
	}

	return false
}
match_meta_char_utf8 :: proc(c: rune, str: string) -> bool {
	if len(str) > 0 {
		// TODO check utf8 first char
		other := rune(str[0])

		switch other {
			case 'd': return match_digit_utf8(c)
			case 'D': return !match_digit_utf8(c)
			case 'w': return match_alpha_numeric_utf8(c)
			case 'W': return !match_alpha_numeric_utf8(c)
			case 's': return match_whitespace_utf8(c)
			case 'S': return !match_whitespace_utf8(c)
			case: return c == other
		}
	}

	return false
}
match_meta_char :: proc { match_meta_char_utf8, match_meta_char_ascii }

match_char_class_ascii :: proc(c: u8, str: string) -> bool {
	// TODO
	return false
}
match_char_class_utf8 :: proc(c: rune, str: string) -> bool {
	// TODO
	return false
}
match_char_class :: proc { match_char_class_utf8, match_char_class_ascii }

match_one_ascii :: proc(type: Regex_Type, c: u8, data: rawptr) -> bool {
	#partial switch type {
		case .Dot: return match_dot_ascii(c)
		// TODO
		case .Char_Class: return match_char_class_ascii(c, "")
		// TODO
		case .Inv_Char_Class: return !match_char_class_ascii(c, "")
		case .Digit: return match_digit_ascii(c)
		case .Not_Digit: return !match_digit_ascii(c)
		case .Alpha: return match_alpha_numeric_ascii(c)
		case .Not_Alpha: return !match_alpha_numeric_ascii(c)
		case .Whitespace: return match_whitespace_ascii(c)
		case .Not_Whitespace: return !match_whitespace_ascii(c)
		
		// interpret dynamic data
		case: {
			other := (cast(^u8) data)^
			return c == other
		}
	}
}
match_one_utf8 :: proc(type: Regex_Type, c: rune) -> bool {
	// TODO
	return false
}
match_one :: proc { match_one_utf8, match_one_ascii }

// match_star_ascii :: proc(type: Regex_Type, ) {
  	
// }

match_pattern_ascii :: proc(data: []byte, text: string) -> (res: int) {
	b := data
	t := text

	btype :: #force_inline proc(b: u8) -> Regex_Type {
		return transmute(Regex_Type) b
	}

	for len(b) > 0 {
		type := btype(b[0])
		
		// advance
		defer {
			b = b[1:]
			t = t[1:]
		}

		if len(b) > 2 {
			next := transmute(Regex_Type) b[1]

			if type == .Unused || next == .Questionmark {
				// return match_question
			} else if next == .Star {

			} else if next == .Plus {

			} 
 		} else if len(b) > 1 {
			next := transmute(Regex_Type) b[1]

 			if type == .End && next == .Unused {
 				return len(t
 			}
 		}
	}

	return 0
}