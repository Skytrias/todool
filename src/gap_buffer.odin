package src

import "core:unicode/utf8"
import "../cutf8"
import "core:fmt"

GAP_BUFFER_SIZE :: 32

// build only on UTF8
// statically sized gap buffer for short lines of text
Gap_Buffer :: struct {
	buf: [GAP_BUFFER_SIZE]u8,
	left, right: u8,
}

// set right to size
gb_init :: proc() -> (res: Gap_Buffer) {
	res.right = GAP_BUFFER_SIZE
	return
}

// space used up so far
gb_space_used :: proc(gb: ^Gap_Buffer) -> u8 {
	return gb.left + (GAP_BUFFER_SIZE - gb.right)
}

// how much space the gap buffer has left
gb_space_left :: proc(gb: ^Gap_Buffer) -> u8 {
	return GAP_BUFFER_SIZE - gb_space_used(gb)
}

// true if left and right dont eq each other
gb_has_space :: proc(gb: ^Gap_Buffer) -> bool {
	return gb.left != gb.right
}

// insert utfu8 character
gb_insert :: proc(gb: ^Gap_Buffer, c: rune) -> bool {
	buf, size := utf8.encode_rune(c)

	// check if the rune has enough space left
	if int(gb_space_left(gb)) - size < 0 {
		return false
	}

	for i in 0..<size {
		gb.buf[gb.left] = buf[i]
		gb.left += 1
	}

	return true
}

// move to the left as long as the buffer doesnt hit the limit
gb_move_left :: proc(gb: ^Gap_Buffer) -> bool {
	if gb.left > 0 {
		// need to lookup rune backwards!
		r, size := utf8.decode_last_rune(gb.buf[:gb.left])
		
		if r != utf8.RUNE_ERROR {
			for i in 0..<size {
				gb.right -= 1
				gb.left -= 1
				gb.buf[gb.right] = gb.buf[gb.left]
			}

			return true
		}
	} 

	return false
}

// move to the right as long as the buffer doesnt hit the limit
gb_move_right :: proc(gb: ^Gap_Buffer) -> bool {
	if gb.right < GAP_BUFFER_SIZE {
		r, size := utf8.decode_rune(gb.buf[gb.right:])

		// check for no error!
		if r != utf8.RUNE_ERROR {
			for i in 0..<size {
				gb.buf[gb.left] = gb.buf[gb.right]
				gb.right += 1
				gb.left += 1
			}

			return true
		}
	} 

	return false
}

// NOTE in rune steps
gb_move_to :: proc(gb: ^Gap_Buffer, index: int) {

}

// backwards delete a rune
gb_backspace :: proc(gb: ^Gap_Buffer) -> bool {
	if gb.left > 0 {
		// need to lookup rune backwards!
		r, size := utf8.decode_last_rune(gb.buf[:gb.left])
		
		if r != utf8.RUNE_ERROR {
			gb.left -= u8(size)
			return true
		}
	}

	return false
}

// forwards remove a rune in the gap
gb_delete :: proc(gb: ^Gap_Buffer) -> bool {
	if gb.right < GAP_BUFFER_SIZE {
		r, size := utf8.decode_rune(gb.buf[gb.right:])

		// check for no error!
		if r != utf8.RUNE_ERROR {
			gb.right += u8(size)
			return true
		}
	}

	return false
}

// left utf8 string
gb_string_left :: proc(gb: ^Gap_Buffer) -> string {
	return string(gb.buf[:gb.left])
}

// right utf8 string
gb_string_right :: proc(gb: ^Gap_Buffer) -> string {
	return string(gb.buf[gb.right:])
}

// debug print output
gb_print_all :: proc(gb: ^Gap_Buffer) {
	ds: cutf8.Decode_State

	if gb.left != 0 {
		for codepoint in cutf8.ds_iter(&ds, gb_string_left(gb)) {
			fmt.eprint(codepoint)
		}
	}

	fmt.eprint("|")
	fmt.eprint(gb_space_left(gb))
	fmt.eprint("|")

	if gb.right != GAP_BUFFER_SIZE {
		ds = {}

		for codepoint in cutf8.ds_iter(&ds, gb_string_right(gb)) {
			fmt.eprint(codepoint)
		}
	}

	fmt.eprintln()
}

gb_string :: proc(gb: ^Gap_Buffer) -> string {
	return ""
}
