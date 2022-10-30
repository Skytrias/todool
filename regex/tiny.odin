package regex

import "core:unicode"
import "core:fmt"
import "core:reflect"
import "core:io"
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

Re :: struct #packed {
	type: Regex_Type,
	c: u8,
}

compile :: proc(push: ^[dynamic]Re, pattern: string) -> (res: []Re, ok: bool) {
	clear(push)
	p := pattern
	ok = true
	
	for len(p) > 0 {
		c := p[0]
		defer p = p[1:]

		switch c {
			case '^': append(push, Re { type = .Begin })
			case '$': append(push, Re { type = .End })
			case '.': append(push, Re { type = .Dot })
			case '*': append(push, Re { type = .Star })
			case '+': append(push, Re { type = .Plus })
			case '?': append(push, Re { type = .Questionmark })

			// escaped character classes
			case '\\': {
				if len(p) > 1 {
					p = p[1:]

					switch p[0] {
						// meta character
						case 'd': append(push, Re { type = .Digit }) 
						case 'D': append(push, Re { type = .Not_Digit })
						case 'w': append(push, Re { type = .Alpha }) 
						case 'W': append(push, Re { type = .Not_Alpha })
						case 's': append(push, Re { type = .Whitespace }) 
						case 'S': append(push, Re { type = .Not_Whitespace })

						// push escaped character
						case: {
							append(push, Re { .Char, p[0] })
						}
					}
				}
			}

			// character class
			case '[': {
				// skip
			}

			case: {
				// fmt.eprintln("push")
				append(push, Re { .Char, c })
			}
		}

		// end
	}
	
	append(push, Re { type = .Unused })

	// get result
	res = push[:]
	return 
}

print :: proc(data: []Re) {
	b := data
	enum_names := reflect.enum_field_names(Regex_Type)

	for len(b) > 0 {
		type := b[0].type
		type_index := int(type)

		// exit early
		if type == .Unused {
			break
		}

		fmt.eprint("type:", enum_names[type_index])

		if type == .Char_Class || type == .Inv_Char_Class {
			// TODO
		} else  if type == .Char {
			fmt.eprintf(" %v", rune(b[0].c))
		}

		fmt.eprintf("\n")
		b = b[1:]
	}
}

match_digit_ascii :: proc(c: u8) -> bool {
	return '0' <= c && c <= '9'
}
match_digit_utf8 :: unicode.is_digit
match_digit :: proc { match_digit_utf8, match_digit_ascii }

match_alpha_ascii :: proc(c: u8) -> bool {
	return ('A' <= c && c <= 'Z') || ('a' <= c && c <= 'z')
}
match_alpha_utf8 :: unicode.is_alpha
match_alpha :: proc { match_alpha_utf8, match_alpha_ascii }

match_whitespace_ascii :: proc(c: u8) -> bool {
	switch c {
	case '\t', '\n', '\v', '\f', '\r', ' ', 0x85, 0xa0: return true
	case:                                               return false
	} 	
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

match_one_ascii :: proc(
	p: Re, 
	c: u8,
) -> bool {
	#partial switch p.type {
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
			fmt.eprintln("matching one:", rune(p.c), rune(c), p.c == c)
			return p.c == c
		}
	}

	return false
}
match_one_utf8 :: proc(type: Regex_Type, c: rune) -> bool {
	// TODO
	return false
}
match_one :: proc { match_one_utf8, match_one_ascii }

// match_star_ascii :: proc(type: Regex_Type, ) {
  	
// }

match_star_ascii :: proc(
	b: []Re,
	p: Re, 
	text: string,
	match_length: ^int,
) -> bool {
	pre_length := match_length^
	text_offset := 0

	for len(text) > text_offset && match_one_ascii(p, text[text_offset]) {
		text_offset += 1
		match_length^ += 1
	}

	for text_offset >= 0 {
		if match_pattern_ascii(b, text[text_offset:], match_length) {
			return true
		}

		text_offset -= 1
		match_length^ -= 1
	}

	match_length^ = pre_length
	return false
}

match_plus_ascii :: proc(
	b: []Re,
	p: Re, 
	text: string,
	match_length: ^int,
) -> bool {
	text_offset := 0
	fmt.eprintln("+++try")

	for len(text) > text_offset && match_one_ascii(p, text[text_offset]) {
		fmt.eprintln("match +++++", text_offset)
		text_offset += 1
		match_length^ += 1
	}

	fmt.eprintln("mid+++++", text_offset)

	for text_offset > 0 {
		fmt.eprintln("it", text_offset, text[text_offset:])

		if match_pattern_ascii(b, text[text_offset:], match_length) {
			return true
		}

		text_offset -= 1
		match_length^ -= 1
	}

	return false
}

match_question_ascii :: proc(
	b: []Re,
	p: Re, 
	text: string,
	match_length: ^int,
) -> bool {
	if p.type == .Unused {
		return true
	}

	if match_pattern_ascii(b, text, match_length) {
		return true
	}

	if len(text) > 0 {
		// TODO maybe text[1]?
		if match_one_ascii(p, text[0]) {
			if match_pattern_ascii(b, text[1:], match_length) {
				match_length^ += 1
				return true
			}
		}
	}

	return false
}

match_pattern_ascii :: proc(b: []Re, text: string, match_length: ^int) -> bool {
	t := text
	pre := match_length^	
	b := b
	fmt.eprintln("PATTERN", text)
	fmt.eprintln("\tWITH", b)

	for len(b) > 0 && len(t) > 0 {
		p0 := b[0]
		
		// only when there are two valid bytes next
		if len(b) > 1 {
			p1 := b[1]
			// fmt.eprintln("check extra", p0.type, p1.type)

			if p0.type == .Unused || p1.type == .Questionmark {
				return match_question_ascii(b[2:], p0, t, match_length)
			} else if p1.type == .Star {
				return match_star_ascii(b[2:], p0, t, match_length)
			} else if p1.type == .Plus {
				fmt.eprintln("check extra")
				return match_plus_ascii(b[2:], p0, t, match_length)
			} else if p0.type == .End && p1.type == .Unused {
				// end early?
 				if len(t) == 0 {
 					return true
 				}

 				return false
 			}
 		}

 		// advance match length
		// match_length^ += 1
		
		if !match_one_ascii(p0, t[0]) {
			break
		}

		match_length^ += 1
		b = b[1:]
		t = t[1:]
	}

	match_length^ = pre
	return false
}

// match_

match :: proc(pattern: string, text: string, match_length: ^int) -> int {
	push := make([dynamic]Re, 0, 128, context.temp_allocator)
	res, _ := compile(&push, pattern)
	return matchp(res, text, match_length)
}

matchp :: proc(pattern: []Re, text: string, match_length: ^int) -> int {
	match_length^ = 0 
	text_offset: int

	if len(pattern) != 0 {
		if pattern[0].type == .Begin {
			// return
		} else {
			t := text
			
			// reset iteration on fail
			for len(text) > text_offset {
				fmt.eprintln("--------------------------")
				if match_pattern_ascii(pattern, text[text_offset:], match_length) {
					return text_offset
				}

				text_offset += 1
			}
		}
	}

	return -1
}

// match_ :: proc(regexp, text: string) -> (match_length: int, found: bool) {
// 	res, ok := compile(&push, regexp)
// 	print(res)

// 	if ok {
// 		found = match_pattern_ascii(res, text, &match_length)
// 	} 

// 	return
// }