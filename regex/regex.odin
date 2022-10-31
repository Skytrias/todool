/*
	Copyright 2021 Jeroen van Rijn <nom@duclavier.com>.
	Made available under Odin's BSD-3 license.

	`core:regex` began life as a port of the public domain [Tiny Regex by kokke](https://github.com/kokke/tiny-regex-c), with thanks.
*/
package regex

import "core:fmt"

/*
	Mini regex-module inspired by Rob Pike's regex code described in:
		http://www.cs.princeton.edu/courses/archive/spr09/cos333/beautiful.html

	Supports:
	---------
	'.'        Dot, matches any character
	'^'        Start anchor, matches beginning of string
	'$'        End anchor, matches end of string
	'*'        Asterisk, match zero or more (greedy)
	'+'        Plus, match one or more (greedy)
	'?'        Question, match zero or one (non-greedy)
	'[abc]'    Character class, match if one of {'a', 'b', 'c'}
	'[^abc]'   Inverted class, match if NOT one of {'a', 'b', 'c'} -- NOTE: feature is currently broken!
	'[a-zA-Z]' Character ranges, the character set of the ranges { a-z | A-Z }
	'\s'       Whitespace, \t \f \r \n \v and spaces
	'\S'       Non-whitespace
	'\w'       Alphanumeric, [a-zA-Z0-9_]
	'\W'       Non-alphanumeric
	'\d'       Digits, [0-9]
	'\D'       Non-digits
*/

/* Definitions: */

MAX_REGEXP_OBJECTS :: #config(REGEX_MAX_REGEXP_OBJECTS, 30) /* Max number of regex symbols in expression. */
MAX_CHAR_CLASS_LEN :: #config(REGEX_MAX_CHAR_CLASS_LEN, 40) /* Max length of character-class buffer in.   */

DEFAULT_OPTIONS    :: Options{ .Byte_Index }

Option :: enum u8 {
	Dot_Matches_Newline,      /* `.` should match newline as well                                              */
	Case_Insensitive,         /* Case-insensitive match, e.g. [a] matches [aA], can work with Unicode options  */

	ASCII_Only,               /* Accept ASCII haystacks and patterns only to speed things up                   */

	Unicode_Alpha_Match,      /* `\w` uses `core:unicode` to determine if rune is a letter                     */
	Unicode_Digit_Match,      /* `\d` uses `core:unicode` to determine if rune is a digit                      */
	Unicode_Whitespace_Match, /* `\s` uses `core:unicode` to determine if rune is whitespace                   */

	Byte_Index,               /* Return byte index instead of character index for utf-8 input                  */
}
Options :: bit_set[Option; u8]

Error :: enum u8 {
	OK = 0,
	No_Match,

	Pattern_Too_Long,
	Pattern_Ended_Unexpectedly,
	Character_Class_Buffer_Too_Small,
	Operation_Unsupported,
	Rune_Error,
	Incompatible_Option,
}

/* Internal definitions: */

Operator_Type :: enum u8 {
	Sentinel,
	Dot,
	Begin,
	End,
	Question_Mark,
	Star,
	Plus,
	Char,
	Character_Class,
	Inverse_Character_Class,
	Digit,
	Not_Digit,
	Alpha,
	Not_Alpha,
	Whitespace,
	Not_Whitespace,
	Branch,
}

Character :: struct #raw_union {
	r: rune,
	c: u8,
}

Slice :: struct {
	start_idx: u16,
	length:    u16,
}

Compiled :: union {
	Compiled_ASCII,
	Compiled_UTF8,
}

Object_ASCII :: struct {
	type:  Operator_Type, /* Char, Star, etc. */
	char:  Character,     /* The character itself. */
	class: Slice,         /* OR a string with characters in a class */
}

Compiled_ASCII :: struct {
	objects:  [MAX_REGEXP_OBJECTS + 1]Object_ASCII, // Add 1 for the end-of-pattern sentinel
	classes:  [MAX_CHAR_CLASS_LEN]Character,
}

/*
	Public procedures
*/
compile :: proc(pattern: string, options := DEFAULT_OPTIONS) -> (compiled: Compiled, err: Error) {
	if .ASCII_Only in options {
		return compile_ascii(pattern)
	} else {
		return compile_utf8(pattern)
	}
}

match_string :: proc(pattern, haystack: string, options := DEFAULT_OPTIONS) -> (position, length: int, err: Error) {
	compiled := compile(pattern, options) or_return
	return match_compiled(compiled, haystack, options)
}

match_compiled :: proc(pattern: $T, haystack: string, options := DEFAULT_OPTIONS) -> (position, length: int, err: Error) {
	when T == Compiled_UTF8 {
		return match_compiled_utf8(pattern, haystack, options)
	} else when T == Compiled_ASCII {
		return match_compiled_ascii(pattern, haystack, options)
	} else {
		if p, ok := pattern.(Compiled_UTF8); ok {
			return match_compiled_utf8(p, haystack, options)
		} else if p, ok := pattern.(Compiled_ASCII); ok {
			return match_compiled_ascii(p, haystack, options)
		} else {
			unreachable()		
		}
	}
}

match       :: proc { match_string,       match_compiled       }
match_utf8  :: proc { match_string_utf8,  match_compiled_utf8  }
match_ascii :: proc { match_string_ascii, match_compiled_ascii }

print :: proc(pattern: $T) {
	when T == Compiled_UTF8 {
		print_utf8(pattern)
	} else when T == Compiled_ASCII {
		print_ascii(pattern)
	} else {
		if p, ok := pattern.(Compiled_UTF8); ok {
			print_utf8(p)
		} else if p, ok := pattern.(Compiled_ASCII); ok {
			print_ascii(p)
		} else {
			unreachable()
		}
	}
}

/*
	Private functions
*/

match_digit           :: proc { match_digit_ascii,           match_digit_utf8           }
match_alpha           :: proc { match_alpha_ascii,           match_alpha_utf8           }
match_whitepace       :: proc { match_whitespace_ascii,      match_whitespace_utf8      }
match_alphanum        :: proc { match_alphanum_ascii,        match_alphanum_utf8        }
match_range           :: proc { match_range_ascii,           match_range_utf8           }
match_dot             :: proc { match_dot_ascii,             match_dot_utf8             }
is_meta_character     :: proc { is_meta_character_ascii,     is_meta_character_utf8     }
match_meta_character  :: proc { match_meta_character_ascii,  match_meta_character_utf8  }
match_character_class :: proc { match_character_class_ascii, match_character_class_utf8 }

match_one             :: proc { match_one_ascii,             match_one_utf8             }
match_star            :: proc { match_star_ascii,            match_star_utf8            }
match_plus            :: proc { match_plus_ascii,            match_plus_utf8            }
match_question        :: proc { match_question_ascii,        match_question_utf8        }

match_pattern         :: proc { match_pattern_ascii,         match_pattern_utf8         }