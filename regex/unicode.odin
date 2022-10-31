/*
	Copyright 2021 Jeroen van Rijn <nom@duclavier.com>.
	Made available under Odin's BSD-3 license.

	`core:regex` began life as a port of the public domain [Tiny Regex by kokke](https://github.com/kokke/tiny-regex-c), with thanks.
*/
package regex

import "core:fmt"
import "core:unicode"
import "core:unicode/utf8"

Object_UTF8 :: struct {
	type:  Operator_Type, /* Char, Star, etc. */
	char:  rune,          /* The character itself. */
	class: []rune,        /* OR a string with characters in a class */
}

Compiled_UTF8 :: struct {
	objects:  [MAX_REGEXP_OBJECTS + 1]Object_UTF8, // Add 1 for the end-of-pattern sentinel
	classes:  [MAX_CHAR_CLASS_LEN]rune,
}

/*
	Public procedures
*/
compile_utf8 :: proc(pattern: string) -> (compiled: Compiled_UTF8, err: Error) {
	/*
		The sizes of the two static arrays substantiate the static RAM usage of this package.
		MAX_REGEXP_OBJECTS is the max number of symbols in the expression.
		MAX_CHAR_CLASS_LEN determines the size of buffer for runes in all char-classes in the expression.

		TODO(Jeroen): Use a state machine design to handle escaped characters and character classes as part of the main switch?
	*/

	buf := transmute([]u8)pattern

	ccl_buf_idx := int(0)

	j:         int  /* index into re_compiled    */
	char:      rune
	rune_size: int 

	for len(buf) > 0 {
		char, rune_size = utf8.decode_rune(buf)

		switch char {
		/* '\\' as last char in pattern -> invalid regular expression. */
		case utf8.RUNE_ERROR: return {}, .Rune_Error

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
				buf = buf[1:]
				char, rune_size = utf8.decode_rune(buf)

			switch char {
			/* '\\' as last char in pattern -> invalid regular expression. */
			case utf8.RUNE_ERROR: return {}, .Pattern_Ended_Unexpectedly

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
				compiled.objects[j].type = .Char
				compiled.objects[j].char = char
			}

		case '[':
			/*
				Character class:
			*/

				/*
				Eat the `[` and decode the next character.
				*/
				buf = buf[1:]
				char, rune_size = utf8.decode_rune(buf)

			/*
				Remember where the rune buffer starts in `.classes`.
			*/
			begin := ccl_buf_idx

			switch char {
			case utf8.RUNE_ERROR: return {}, .Pattern_Ended_Unexpectedly
			case '^':
				/*
					Set object type to inverse and eat `^`.
				*/
				compiled.objects[j].type = .Inverse_Character_Class

					buf = buf[1:]
					char, rune_size = utf8.decode_rune(buf)				
				case:
				compiled.objects[j].type = .Character_Class
			}

			/*
				Copy characters inside `[...]` to buffer.
			*/
			for {
				if char == utf8.RUNE_ERROR {
					return {}, .Pattern_Ended_Unexpectedly
				}

				if char == '\\' {
					if len(buf) == 0 {
						return {}, .Pattern_Ended_Unexpectedly  // Expected an escaped character
					}

					if ccl_buf_idx >= MAX_CHAR_CLASS_LEN {
						return {}, .Character_Class_Buffer_Too_Small
					}

					compiled.classes[ccl_buf_idx] = char
					ccl_buf_idx += 1

						buf = buf[1:]
						char, rune_size = utf8.decode_rune(buf)				
				}

				if char == ']' {
					break;
				}

				if ccl_buf_idx >= MAX_CHAR_CLASS_LEN {
					return {}, .Character_Class_Buffer_Too_Small
				}

				compiled.classes[ccl_buf_idx] = char
				ccl_buf_idx += 1				

				buf = buf[1:]
				char, rune_size = utf8.decode_rune(buf)				
			}

			compiled.objects[j].class = compiled.classes[begin:ccl_buf_idx]

		case:
			/*
				Other characters:
			*/
			compiled.objects[j].type = .Char
			compiled.objects[j].char = char
		}

		/*
			Advance pattern
		*/
		j  += 1
		buf = buf[rune_size:]
	}

	/*
		Finish pattern with a Sentinel
	*/
	compiled.objects[j].type = .Sentinel

	return
}

match_string_utf8 :: proc(pattern, haystack: string, options := DEFAULT_OPTIONS) -> (position, length: int, err: Error) {
	if .ASCII_Only in options {
		return 0, 0, .Incompatible_Option
	}
	compiled := compile_utf8(pattern) or_return
	return match_compiled_utf8(compiled, haystack, options)
}

match_compiled_utf8 :: proc(pattern: Compiled_UTF8, haystack: string, options := DEFAULT_OPTIONS) -> (position, length: int, err: Error) {
	/*
		Bail on empty pattern.
	*/
	pattern := pattern
	objects := pattern.objects[:]

	if objects[0].type != .Sentinel {
		if objects[0].type == .Begin {
			return 0, match_pattern(objects[1:], haystack, options)
		} else {
			byte_idx := 0
			char_idx := 0

			for _, byte_idx in haystack {
				length, err = match_pattern(objects[:], haystack, options)

				#partial switch err {
				case .No_Match:
					/*
						Iterate.
					*/
				case:
					/*
						Either a match or an error, so return.
					*/
					position = byte_idx if .Byte_Index in options else char_idx
					return
				}
				char_idx += 1
			}
		}
	}
	return 0, 0, .No_Match
}

/*
	Private functions:
*/
@(private="package")
match_digit_utf8 :: proc(r: rune) -> (match_size: int) {
	return utf8.rune_size(r) if unicode.is_number(r) else 0
}

@(private="package")
match_alpha_utf8 :: proc(r: rune) -> (match_size: int) {
	return utf8.rune_size(r) if unicode.is_alpha(r) else 0
}

@(private="package")
match_whitespace_utf8 :: proc(r: rune) -> (match_size: int) {
	return utf8.rune_size(r) if unicode.is_space(r) else 0
}

@(private="package")
match_alphanum_utf8 :: proc(r: rune) -> (match_size: int) {
	if r == '_' {
		return 1
	}

	alpha := match_alpha_utf8(r)
	return alpha if alpha != 0 else match_digit_utf8(r)
}

@(private="package")
match_range_utf8 :: proc(r: rune, buf: []u8) -> (match_size: int) {
	/*
		Decode first charater of range. Ensure we have at least 2 characters left.
		1 for `-` and 1 for the second character.
	*/
	if a, la := utf8.decode_rune(buf); a != utf8.RUNE_ERROR && len(buf) >= la + 2 {
		if buf[la] == '-' {
			/*
				Decode second charater of range.
			*/
			if b, lb := utf8.decode_rune(buf); b != utf8.RUNE_ERROR {
				return la + 1 + lb if a >= r && r >= b else 0
			}
		}
	}
	return 0
}

@(private="package")
match_dot_utf8 :: proc(r: rune, match_newline: bool) -> (match_size: int) {
	if match_newline {
		return utf8.rune_size(r)
	} else {
		return 1 if r != '\n' && r != '\r' else 0
	}
}

@(private="package")
is_meta_character_utf8 :: proc(r: rune) -> (match_size: int) {
	return 1 if (r == 's') || (r == 'S') || (r == 'w') || (r == 'W') || (r == 'd') || (r == 'D') else 0
}

@(private="package")
match_meta_character_utf8 :: proc(r: rune, meta: rune, unicode_match: bool) -> (match_size: int) {
	switch meta {
	case 'd': return match_digit       (r)
	case 'D': return utf8.rune_size(r) if match_digit(r)      == 0 else 0
	case 'w': return match_alphanum    (r)
	case 'W': return utf8.rune_size(r) if match_alphanum(r)   == 0 else 0
	case 's': return match_whitepace  (r)
	case 'S': return utf8.rune_size(r) if match_whitepace(r) == 0 else 0
	case:     return utf8.rune_size(r) if r == meta               else 0
	}
}

/*
match_character_class :: proc(r: rune)

static int matchcharclass(char c, const char* str)
{
	do
	{
	if (matchrange(c, str))
	{
		return 1;
	}
	else if (str[0] == '\\')
	{
		/* Escape-char: increment str-ptr and match on next char */
		str += 1;
		if (matchmetachar(c, str))
		{
		return 1;
		}
		else if ((c == str[0]) && !ismetachar(c))
		{
		return 1;
		}
	}
	else if (c == str[0])
	{
		if (c == '-')
		{
		return ((str[-1] == '\0') || (str[1] == '\0'));
		}
		else
		{
		return 1;
		}
	}
	}
	while (*str++ != '\0');

	return 0;
}
*/

@(private="package")
match_character_class_utf8 :: proc(r: rune, class: []rune) -> (matched: bool) {

	return false

}

@(private="package")
match_one_utf8 :: proc(object: Object_UTF8, char: rune) -> (matched: bool) {


	return false
}

@(private="package")
match_star_utf8 :: proc() -> (matched: bool) {

	return false
}

@(private="package")
match_plus_utf8 :: proc() -> (matched: bool) {

	return false
}

@(private="package")
match_question_utf8 :: proc() -> (matched: bool) {

	return false
}

/*
static int matchone(regex_t p, char c)
{
	switch (p.type)
	{
	case DOT:            return matchdot(c);
	case CHAR_CLASS:     return  matchcharclass(c, (const char*)p.u.ccl);
	case INV_CHAR_CLASS: return !matchcharclass(c, (const char*)p.u.ccl);
	case DIGIT:          return  matchdigit(c);
	case NOT_DIGIT:      return !matchdigit(c);
	case ALPHA:          return  matchalphanum(c);
	case NOT_ALPHA:      return !matchalphanum(c);
	case WHITESPACE:     return  matchwhitespace(c);
	case NOT_WHITESPACE: return !matchwhitespace(c);
	default:             return  (p.u.ch == c);
	}
}

static int matchstar(regex_t p, regex_t* pattern, const char* text, int* matchlength)
{
	int prelen = *matchlength;
	const char* prepoint = text;
	while ((text[0] != '\0') && matchone(p, *text))
	{
	text++;
	(*matchlength)++;
	}
	while (text >= prepoint)
	{
	if (matchpattern(pattern, text--, matchlength))
		return 1;
	(*matchlength)--;
	}

	*matchlength = prelen;
	return 0;
}

static int matchplus(regex_t p, regex_t* pattern, const char* text, int* matchlength)
{
	const char* prepoint = text;
	while ((text[0] != '\0') && matchone(p, *text))
	{
	text++;
	(*matchlength)++;
	}
	while (text > prepoint)
	{
	if (matchpattern(pattern, text--, matchlength))
		return 1;
	(*matchlength)--;
	}

	return 0;
}

static int matchquestion(regex_t p, regex_t* pattern, const char* text, int* matchlength)
{
	if (p.type == UNUSED)
	return 1;
	if (matchpattern(pattern, text, matchlength))
		return 1;
	if (*text && matchone(p, *text++))
	{
	if (matchpattern(pattern, text, matchlength))
	{
		(*matchlength)++;
		return 1;
	}
	}
	return 0;
}

/* Iterative matching */
static int matchpattern(regex_t* pattern, const char* text, int* matchlength)
{
	int pre = *matchlength;
	do
	{
	if ((pattern[0].type == UNUSED) || (pattern[1].type == QUESTIONMARK))
	{
		return matchquestion(pattern[0], &pattern[2], text, matchlength);
	}
	else if (pattern[1].type == STAR)
	{
		return matchstar(pattern[0], &pattern[2], text, matchlength);
	}
	else if (pattern[1].type == PLUS)
	{
		return matchplus(pattern[0], &pattern[2], text, matchlength);
	}
	else if ((pattern[0].type == END) && pattern[1].type == UNUSED)
	{
		return (text[0] == '\0');
	}
/*  Branching is not working properly
	else if (pattern[1].type == BRANCH)
	{
		return (matchpattern(pattern, text) || matchpattern(&pattern[2], text));
	}
*/
	(*matchlength)++;
	}
	while ((text[0] != '\0') && matchone(*pattern++, *text++));

	*matchlength = pre;
	return 0;
}
*/

match_pattern_utf8 :: proc(objects: []Object_UTF8, haystack: string, options: Options, match_length_in := int(0)) -> (length: int, err: Error) {
	fmt.printf("Trying to match against \"%v\" using options %v:\n\n", haystack, options)

	for o in objects {
		if o.type == .Sentinel {
			break
		} else if o.type == .Character_Class || o.type == .Inverse_Character_Class {
			fmt.printf("type: %v%v\n", o.type, o.class)
		} else if o.type == .Char {
			fmt.printf("type: %v{{'%c'}}\n", o.type, o.char)
		} else {
			fmt.printf("type: %v\n", o.type)
		}
	}

	return	
}

print_utf8 :: proc(compiled: Compiled_UTF8) {
	for o in compiled.objects {
		if o.type == .Sentinel {
			break
		} else if o.type == .Character_Class || o.type == .Inverse_Character_Class {
			fmt.printf("type: %v%v\n", o.type, o.class)
		} else if o.type == .Char {
			fmt.printf("type: %v{{'%c'}}\n", o.type, o.char)
		} else {
			fmt.printf("type: %v\n", o.type)
		}
	}
}