/*
	Copyright 2021 Jeroen van Rijn <nom@duclavier.com>.
	Made available under Odin's BSD-3 license.

	`core:regex` began life as a port of the public domain [Tiny Regex by kokke](https://github.com/kokke/tiny-regex-c), with thanks.
*/
package regex

import "core:fmt"

when false {
	printf :: fmt.printf
} else {
	printf :: proc(f: string, v: ..any) {}
}


/* Definitions: */

/*
	Public procedures
*/
compile_ascii :: proc(pattern: string) -> (compiled: Compiled_ASCII, err: Error) {
	/*
		The sizes of the two static arrays substantiate the static RAM usage of this package.
		MAX_REGEXP_OBJECTS is the max number of symbols in the expression.
		MAX_CHAR_CLASS_LEN determines the size of buffer for runes in all char-classes in the expression.

		TODO(Jeroen): Use a state machine design to handle escaped characters and character classes as part of the main switch?
	*/

	buf := transmute([]u8)pattern

	ccl_buf_idx := u16(0)

	j:         int  /* index into re_compiled    */
	char:      u8

	for len(buf) > 0 {

		char = buf[0]

		switch char {
		/*
			Meta-characters:
		*/
		case '^': compiled.objects[j].type = .Begin
		case '$': compiled.objects[j].type = .End
		case '.': compiled.objects[j].type = .Dot
		case '*': compiled.objects[j].type = .Star
		case '+': compiled.objects[j].type = .Plus
		case '?': compiled.objects[j].type = .Question_Mark
		case '|':
			/*
				Branch is currently bugged
			*/
			return {}, .Operation_Unsupported

		/*
			Escaped character-classes (\s \w ...):
		*/
		case '\\':
			/*
				Eat the escape character and decode the escaped character.
			*/
			if len(buf) == 0 {
				/* '\\' as last char in pattern -> invalid regular expression. */
				return {}, .Pattern_Ended_Unexpectedly
			}

			buf = buf[1:]
			char = buf[0]

			switch char {
			/*
				Meta-character:
			*/
			case 'd': compiled.objects[j].type = .Digit
			case 'D': compiled.objects[j].type = .Not_Digit
			case 'w': compiled.objects[j].type = .Alpha
			case 'W': compiled.objects[j].type = .Not_Alpha
			case 's': compiled.objects[j].type = .Whitespace
			case 'S': compiled.objects[j].type = .Not_Whitespace
			case:
				/*
					Escaped character, e.g. `\`, '.' or '$'
				*/
				compiled.objects[j].type   = .Char
				compiled.objects[j].char.c = char
			}

		case '[':
			/*
				Character class:
			*/

			/*
				Eat the `[` and decode the next character.
			*/
			if len(buf) == 0 {
				/* '['' as last char in pattern -> invalid regular expression. */
				return {}, .Pattern_Ended_Unexpectedly
			}

			buf = buf[1:]
			char = buf[0]

			/*
				Remember where the rune buffer starts in `.classes`.
			*/
			begin := ccl_buf_idx

			switch char {
			case '^':
				/*
					Set object type to inverse and eat `^`.
				*/
				compiled.objects[j].type = .Inverse_Character_Class

				if len(buf) == 0 {
					/* '^' as last char in pattern -> invalid regular expression. */
					return {}, .Pattern_Ended_Unexpectedly
				}

				buf = buf[1:]
				char = buf[0]

			case:
				compiled.objects[j].type = .Character_Class
			}

			/*
				Copy characters inside `[...]` to buffer.
			*/
			for {
				if char == '\\' {
					if len(buf) == 0 {
						return {}, .Pattern_Ended_Unexpectedly  // Expected an escaped character
					}

					if ccl_buf_idx >= MAX_CHAR_CLASS_LEN {
						return {}, .Character_Class_Buffer_Too_Small
					}

					compiled.classes[ccl_buf_idx].c = char
					ccl_buf_idx += 1

					if len(buf) == 0 {
						/* '\\' as last char in pattern -> invalid regular expression. */
						return {}, .Pattern_Ended_Unexpectedly
					}

					buf = buf[1:]
					char = buf[0]
				}

				if char == ']' {
					break;
				}

				if ccl_buf_idx >= MAX_CHAR_CLASS_LEN {
					return {}, .Character_Class_Buffer_Too_Small
				}

				compiled.classes[ccl_buf_idx].c = char
				ccl_buf_idx += 1				

				if len(buf) == 0 {
					/* pattern ended before ']' -> invalid regular expression. */
					return {}, .Pattern_Ended_Unexpectedly
				}

				buf = buf[1:]
				char = buf[0]
			}

			compiled.objects[j].class = Slice{begin, ccl_buf_idx - begin}

		case:
			/*
				Other characters:
			*/
			compiled.objects[j].type   = .Char
			compiled.objects[j].char.c = char
		}

		/*
			Advance pattern
		*/
		j  += 1
		buf = buf[1:]
	}

	/*
		Finish pattern with a Sentinel
	*/
	compiled.objects[j].type = .Sentinel

	return
}

match_string_ascii :: proc(pattern, haystack: string, options := DEFAULT_OPTIONS) -> (position, length: int, err: Error) {
	if .ASCII_Only not_in options {
		return 0, 0, .Incompatible_Option
	}
	compiled := compile_ascii(pattern) or_return

	return match_compiled_ascii(compiled, haystack, options)
}

match_compiled_ascii :: proc(pattern: Compiled_ASCII, haystack: string, options := DEFAULT_OPTIONS) -> (position, length: int, err: Error) {
	/*
		Bail on empty pattern.
	*/
	pattern  := pattern
	objects  := pattern.objects[:]
	haystack := haystack
	buf      := transmute([]u8)haystack

	l := int(0)

	if objects[0].type != .Sentinel {
		if objects[0].type == .Begin {
			e := match_pattern_ascii(pattern, objects[1:], buf, &l, options)
			return 0, length, e
		} else {
			for _, byte_idx in haystack {
				l = 0
				e := match_pattern(pattern, objects[:], buf[byte_idx:], &l, options)

				#partial switch e {
				case .No_Match:
					/*
						Iterate.
					*/
				case:
					/*
						Either a match or an error, so return.
					*/
					return byte_idx, l, e
				}
			}
		}
	}
	return 0, 0, .No_Match
}

/*
	Private functions:
*/
@(private="package")
match_digit_ascii :: proc(c: u8) -> (matched: bool) {
	return '0' <= c && c <= '9'
}

@(private="package")
match_alpha_ascii :: proc(c: u8) -> (matched: bool) {
	return ('A' <= c && c <= 'Z') || ('a' <= c && c <= 'z')
}

@(private="package")
match_whitespace_ascii :: proc(c: u8) -> (matched: bool) {
	switch c {
	case '\t', '\n', '\v', '\f', '\r', ' ', 0x85, 0xa0: return true
	case:                                               return false
	}
}

@(private="package")
match_alphanum_ascii :: proc(c: u8) -> (matched: bool) {
	return c == '_' || match_alpha_ascii(c) || match_digit_ascii(c)
}

@(private="package")
match_range_ascii :: proc(c: u8, range: []Character) -> (matched: bool) {
	if len(range) < 3 {
		return false
	}
	return range[1].c == '-' && c >= range[0].c && c <= range[2].c
}

@(private="package")
match_dot_ascii :: proc(c: u8, match_newline: bool) -> (matched: bool) {
	return match_newline || c != '\n' && c != '\r'
}

@(private="package")
is_meta_character_ascii :: proc(c: u8) -> (matched: bool) {
	return (c == 's') || (c == 'S') || (c == 'w') || (c == 'W') || (c == 'd') || (c == 'D')
}

@(private="package")
match_meta_character_ascii :: proc(c, meta: u8) -> (matched: bool) {
	switch meta {
	case 'd': return  match_digit_ascii     (c)
	case 'D': return !match_digit_ascii     (c)
	case 'w': return  match_alphanum_ascii  (c)
	case 'W': return !match_alphanum_ascii  (c)
	case 's': return  match_whitespace_ascii(c)
	case 'S': return !match_whitespace_ascii(c)
	case:     return  c == meta
	}
}

@(private="package")
match_character_class_ascii :: proc(c: u8, class: []Character) -> (matched: bool) {
	class := class

	for len(class) > 0 {
		if (match_range(c, class)) {
			return true
		} else if class[0].c == '\\' {
			/* Escape-char: Eat `\\` and match on next char. */
			class = class[1:]
			if len(class) == 0 {
				return false
			}

			if (match_meta_character(c, class[0].c)) {
				return true
			} else if c == class[0].c && !is_meta_character(c) {
				return true
			}
		} else if c == class[0].c {
			if c == '-' && len(class) == 1 {
				return true
			} else {
				return true
			}
		}

		class = class[1:]
	}
	return false
}

@(private="package")
match_one_ascii :: proc(classes: []Character, object: Object_ASCII, char: u8, options := DEFAULT_OPTIONS) -> (matched: bool) {
	printf("[match 1] %c (%v)\n", char, object.type)
	#partial switch object.type {
	case .Sentinel:                return false
	case .Dot:                     return  match_dot(char, .Dot_Matches_Newline in options)
	case .Character_Class:         return  match_character_class(char, classes)
	case .Inverse_Character_Class: return !match_character_class(char, classes)
	case .Digit:                   return  match_digit(char)
	case .Not_Digit:               return !match_digit(char)
	case .Alpha:                   return  match_alphanum(char)
	case .Not_Alpha:               return !match_alphanum(char)
	case .Whitespace:              return  match_whitepace(char)
	case .Not_Whitespace:          return !match_whitepace(char)
	case:                          return  object.char.c == char
	}
}

@(private="package")
match_star_ascii :: proc(pattern: Compiled_ASCII, objects: []Object_ASCII, buf: []u8, length: ^int, options: Options) -> (err: Error) {
	pattern := pattern
	idx := 0
	prelen := length^

	for idx < len(buf) && match_one_ascii(pattern.classes[:], objects[0], buf[idx]) {
		idx += 1
		length^ += 1
	}
	printf("idx: %v, length: %v\n", idx, length^)

	for idx > 0 {
		if match_pattern_ascii(pattern, objects[2:], buf[idx:], length, options) == .OK {
			return .OK
		}
		idx -= 1
		length^ -= 1
	}

	length^ = prelen
	return .No_Match
}

@(private="package")
match_plus_ascii :: proc(pattern: Compiled_ASCII, objects: []Object_ASCII, buf: []u8, length: ^int, options: Options) -> (err: Error) {
	pattern := pattern
	idx := 0

	for idx < len(buf) && match_one_ascii(pattern.classes[:], objects[0], buf[idx]) {
		idx += 1
		length^ += 1
	}

	for idx > 0 {
		if match_pattern_ascii(pattern, objects[2:], buf[idx:], length, options) == .OK {
			return .OK
		}
		idx -= 1
		length^ -= 1
	}

	return .No_Match
}

@(private="package")
match_question_ascii :: proc(pattern: Compiled_ASCII, objects: []Object_ASCII, buf: []u8, length: ^int, options: Options) -> (err: Error) {
	pattern := pattern

	if objects[0].type == .Sentinel {
		return .OK
	}
	if match_pattern_ascii(pattern, objects[2:], buf, length, options) == .OK {
		return .OK
	}
	if len(buf) != 0 && match_one_ascii(pattern.classes[:], objects[0], buf[0]) {
		if match_pattern_ascii(pattern, objects[2:], buf, length, options) == .OK {
			length^ += 1
			return .OK
		}
	}
	return .No_Match
}

/* Iterative matching */
@(private="package")
match_pattern_ascii :: proc(pattern: Compiled_ASCII, objects: []Object_ASCII, buf: []u8, length: ^int, options: Options) -> (err: Error) {
	objects := objects
	pattern := pattern
	buf     := buf

	length_in := length^

	if len(buf) == 0 || len(objects) == 0 {
		return .No_Match
	}

	printf("[match] %v\n", string(buf))

	for {
		// printf("type: %v %v\n", objects[0].type, objects[1].type)

		if objects[0].type == .Sentinel || objects[1].type == .Question_Mark {
			c := 0 if len(buf) == 0 else buf[0]
			printf("[match ?] char: %c\n", c)
			return match_question(pattern, objects, buf, length, options)

		} else if objects[1].type == .Star {
			printf("[match *] char: %c\n", buf[0])
			return match_star(pattern, objects, buf, length, options)

		} else if objects[1].type == .Plus {
			printf("[match +] char: %c\n", buf[0])
			return match_plus(pattern, objects, buf, length, options)

		} else if objects[0].type == .End && objects[1].type == .Sentinel {
	  		if len(buf) == 0 {
	  			return .OK
	  		}
	  		return .No_Match
		}

		/*  Branching is not working properly
			else if (pattern[1].type == BRANCH)
			{
			  return (matchpattern(pattern, text) || matchpattern(&pattern[2], text));
			}
		*/

		if len(buf) == 0 || !match_one(pattern.classes[:], objects[0], buf[0], options) {
			break
		} else {
			length^ += 1
			buf     = buf[1:]
			objects = objects[1:]
		}
		printf("length: %v\n", length^)
	}

  	length^ = length_in
	return .No_Match
}

print_ascii :: proc(compiled: Compiled_ASCII) {
	for o in compiled.objects {
		if o.type == .Sentinel {
			break
		} else if o.type == .Character_Class || o.type == .Inverse_Character_Class {
			fmt.printf("type: %v[ ", o.type)
			for i := o.class.start_idx; i < o.class.start_idx + o.class.length; i += 1 {
				fmt.printf("%c, ", compiled.classes[i].c)
			}
			fmt.printf("]\n")
		} else if o.type == .Char {
			fmt.printf("type: %v{{'%c'}}\n", o.type, o.char.c)
		} else {
			fmt.printf("type: %v\n", o.type)
		}
	}
}