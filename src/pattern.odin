package src

import "core:log"
import "core:fmt"
import "core:time"
import "core:mem"
import "core:os"
import "core:unicode"
import "core:unicode/utf8"
import "core:slice"
import "core:strings"

// wanted pattern

// find start pattern: # // -- 
// skip whitespaces
// find tag pattern: TODO
// needs whitespace
// skip whitespace
// get remainder till newline

EOF :: -1
COMMENT :: -2
MULTILINE_COMMENT_START :: -3
MULTILINE_COMMENT_END :: -4
TAG :: -5
STRING_END :: -6

Whitespace :: distinct bit_set['\x00'..<utf8.RUNE_SELF; u128]
Default_Whitespace :: Whitespace{'\t', '\n', '\r', ' '}

// scanner working on utf8 input
Pattern_Scanner :: struct {
	src: string,
	ch: rune,
	src_pos: int,
	src_end: int,
	prev_char_len: int,
	prev_line_len: int,

	tok_pos: int,
	tok_end: int,

	column: int,
	line: int,

	// tags that get found after a command in patter_scan
	tags: map[string]int,
}

pattern_scanner_init :: proc(src: string) -> (res: Pattern_Scanner) {
  res.src = src
  res.tok_pos = -1
  res.ch = -2
  return
}

pattern_scanner_destroy :: proc(res: Pattern_Scanner) {
	delete(res.tags)
}

pattern_advance :: proc(s: ^Pattern_Scanner) -> rune {
	if s.src_pos >= len(s.src) {
		s.prev_char_len = 0
		return EOF
	}
	ch, width := rune(s.src[s.src_pos]), 1

	if ch >= utf8.RUNE_SELF {
		ch, width = utf8.decode_rune_in_string(s.src[s.src_pos:])
		if ch == utf8.RUNE_ERROR && width == 1 {
			s.src_pos += width
			s.prev_char_len = width
			s.column += 1
			// error(s, "invalid UTF-8 encoding")
			return ch
		}
	}

	s.src_pos += width
	s.prev_char_len = width
	s.column += 1

	switch ch {
		case 0: {
			// error(s, "invalid character NUL")
		}
	
		case '\n': {
			s.line += 1
			s.prev_line_len = s.column
			s.column = 0
		}
	}

	return ch
}

pattern_next :: proc(s: ^Pattern_Scanner) -> rune {
	s.tok_pos = -1
	ch := pattern_peek(s)

	if ch != EOF {
		s.ch = pattern_advance(s)
	}

	return ch
}

pattern_peek :: proc(s: ^Pattern_Scanner, n := 0) -> (ch: rune) {
	if s.ch == -2 {
		s.ch = pattern_advance(s)
		if s.ch == '\ufeff' { // Ignore BOM
			s.ch = pattern_advance(s)
		}
	}

	ch = s.ch

	if n > 0 {
		prev_s := s^
		for in 0..<n {
			pattern_next(s)
		}
		ch = s.ch
		s^ = prev_s
	}

	return ch
}

@(private)
is_ident_rune :: proc(s: ^Pattern_Scanner, ch: rune, i: int) -> bool {
	return ch == '_' || unicode.is_letter(ch) || unicode.is_digit(ch) && i > 0
}

// TODO toggle these
pattern_scan :: proc(s: ^Pattern_Scanner, last_was_comment := false) -> (tok: rune) {
	assert(s.tags != nil)

	ch := pattern_peek(s)
	if ch == EOF {
		return ch
	}

	s.tok_pos = -1

	redo: for {
		for ch < utf8.RUNE_SELF && (ch in Default_Whitespace) {
			ch = pattern_advance(s)
		}

		s.tok_pos = s.src_pos - s.prev_char_len
		tok = ch

		if is_ident_rune(s, ch, 0) {
			ch = pattern_scan_identifier(s)

			if !last_was_comment {
				continue
			}

			s.tok_end = s.src_pos - s.prev_char_len
			ident_text := pattern_token_text(s)
			
			// found tag, skip till newline
			if tag, ok := s.tags[ident_text]; ok {
				// skip whitespace again
				for ch < utf8.RUNE_SELF && (ch in Default_Whitespace) {
					ch = pattern_advance(s)
				}

				s.tok_pos = s.src_pos - s.prev_char_len

				// loop till newline
				for ch != '\n' && ch >= 0 {
					ch = pattern_advance(s)
				}
			
				tok = STRING_END
				break redo
			}
		} else {
			switch ch {
				case EOF: {
					break
				}

				case '*': {
					ch = pattern_advance(s)

					if ch == '/' {
						ch = pattern_advance(s)
						tok = MULTILINE_COMMENT_END
					}
				}

				// c style comments
				case '/': {
					ch = pattern_advance(s)
					
					// check if multiline
					if ch == '*' {
						ch = pattern_advance(s)
						tok = MULTILINE_COMMENT_START
					} else if ch == '/' {
						ch = pattern_advance(s)
						tok = COMMENT
					}
				}

				// lua style comments
				case '-': {
					ch = pattern_advance(s)

					if ch == '-' {
						ch = pattern_advance(s)
						tok = COMMENT
					}
				}

				case '#': {
					ch = pattern_advance(s)
					tok = COMMENT
				}

				case: {
					ch = pattern_advance(s)
				}
			}
		}

		break redo
	}

	s.tok_end = s.src_pos - s.prev_char_len
	s.ch = ch
	return tok
}

pattern_scan_identifier :: proc(s: ^Pattern_Scanner) -> rune {
  ch := pattern_advance(s)

  for i := 1; is_ident_rune(s, ch, i); i += 1 {
		ch = pattern_advance(s)
	}

	return ch
}

pattern_token_text :: proc(s: ^Pattern_Scanner) -> string {
	if s.tok_pos < 0 {
		return ""
	}

	return string(s.src[s.tok_pos:s.tok_end])
}

// token_string returns a printable string for a token or Unicode character
// By default, it uses the context.temp_allocator to produce the string
pattern_token_string :: proc(tok: rune, allocator := context.temp_allocator) -> string {
	context.allocator = allocator
	
	switch tok {
		case EOF:	return strings.clone("EOF")
		case COMMENT: return strings.clone("Comment")
		case MULTILINE_COMMENT_START: return strings.clone("Multi Comment start")
		case MULTILINE_COMMENT_END: return strings.clone("Multi Comment end")
		case TAG: return strings.clone("Tag")
		case STRING_END: return strings.clone("String End")
	}

	return fmt.aprintf("%q", tok)
}

pattern_load_content :: proc(manager: ^Undo_Manager, content: string) {
  scanner := pattern_scanner_init(content)
	defer pattern_scanner_destroy(scanner)
	
	scanner.tags = {
		"TODO" = 0,
		"NOTE" = 1,
	}
	
	multiline_count: int
	was_comment: bool
	inject_count: int

	for {
		tok := pattern_scan(&scanner, was_comment)

		if tok == EOF	{
			break
		} else if tok == STRING_END {
			text := pattern_token_text(&scanner)
		// 	log.info("found:", text)

			task_current := tasks_visible[task_head]
			index_at := task_current.index + inject_count + 1

			task_push_undoable(manager, task_current.indentation, text, index_at)
		} else if tok == MULTILINE_COMMENT_START { 
			multiline_count += 1
		} else if tok == MULTILINE_COMMENT_END {
			multiline_count -= 1
		}

		was_comment = tok == COMMENT || multiline_count != 0
	}
}

// pattern_read_dir :: proc(
// 	path: string, 
// 	call: proc(string, ^Task, ^history.Batch), 
// 	parent: ^Task,
// 	batch: ^history.Batch,
// 	allocator := context.allocator,
// ) {
// 	if handle, err := os.open(path); err == os.ERROR_NONE {
// 		if file_infos, err := os.read_dir(handle, 100, allocator); err == os.ERROR_NONE {
// 			for file in file_infos {
// 				if file.is_dir {
// 					// recursively read inner directories
// 					pattern_read_dir(file.fullpath, call, parent, batch, allocator)
// 				} else {
// 					if bytes, ok := os.read_entire_file(file.fullpath, allocator); ok {
// 					// 	append(&ims.loaded_files, string(bytes))
// 						call(string(bytes[:]), parent, batch)
// 					}
// 				}
// 			}
// 		} else {
// 			// try normal read
// 			if bytes, ok := os.read_entire_file(path, allocator); ok {
// 				// append(&ims.loaded_files, string(bytes))
// 				call(string(bytes[:]), parent, batch)
// 			}
// 		}
// 	} else {
// 		log.error("failed to open file %v", err)
// 	}
// }
