package src

import "core:unicode/utf8"
import "../cutf8"
import "core:fmt"

SS_SIZE :: 255

// static sized string with no magic going on
// insert & pop are fast and utf8 based
// 
// insert_at & remove_at are a bit more involved
Small_String :: struct {
	buf: [SS_SIZE]u8,
	length: u8, // used up content
}

// actual string space left
ss_size :: #force_inline proc(ss: ^Small_String) -> u8 {
	return ss.length
}

// true if the there is still space left
ss_has_space :: #force_inline proc(ss: ^Small_String) -> bool {
	return ss.length != SS_SIZE
}

// return the actual string 
ss_string :: #force_inline proc(ss: ^Small_String) -> string {
	return string(ss.buf[:ss.length])
}

// clear the small string
ss_clear :: #force_inline proc(ss: ^Small_String) {
	ss.length = 0
}

// append the rune to the buffer
// true on success
ss_append :: proc(ss: ^Small_String, c: rune) -> bool {
	data, size := utf8.encode_rune(c)

	if int(ss.length) + size < SS_SIZE {
		for i in 0..<size {
			ss.buf[ss.length] = data[i]
			ss.length += 1
		}

		return true
	}

	return false
}

// pop the last rune in the buffer off and return it
ss_pop :: proc(ss: ^Small_String) -> (c: rune, ok: bool) {
	if ss.length != 0 {
		size: int
		c, size = utf8.decode_last_rune(ss.buf[:ss.length])

		if c != utf8.RUNE_ERROR {
			// pop of the rune
			ss.length -= u8(size)
			ok = true
			return 
		}
	}

	return
}

SS_Byte_Info :: struct {
	byte_index: u8,
	codepoint: rune,
	size: u8,
}

// find byte index from wanted codepoint_index
_ss_find_byte_index_info :: proc(
	ss: ^Small_String, 
	index: int,
) -> (
	info: SS_Byte_Info,
	found: bool,
) {
	ds: cutf8.Decode_State

	for codepoint, i in cutf8.ds_iter(&ds, ss_string(ss)) {
		if i == index {
			info.codepoint = codepoint
			info.byte_index = u8(ds.byte_offset_old)
			info.size = u8(ds.byte_offset - ds.byte_offset_old)
			found = true
			return
		}
	}

	return 
}

// NOTE in utf8 indexing space!
// insert a rune at a wanted index
ss_insert_at :: proc(ss: ^Small_String, index: int, c: rune) -> bool {
	if ss.length == 0 {
		return ss_append(ss, c)
	} else {
		data, size := utf8.encode_rune(c)

		// check if we even have enough space
		if int(ss.length) + size < SS_SIZE {
			undex := u8(index)
			info, found := _ss_find_byte_index_info(ss, index)
			fmt.eprintln(info)

			// check for append situation still since its faster then copy
			if ss.length == info.byte_index || !found {
				for i in 0..<size {
					ss.buf[ss.length] = data[i]
					ss.length += 1
				}
				return true
			}

			// linear index to mem copy above
			ss.length += u8(size)
			copy(ss.buf[info.byte_index + u8(size):ss.length], ss.buf[info.byte_index:ss.length])

			// fill in the 1~4 bytes with the rune data
			for i in 0..<u8(size) {
				ss.buf[info.byte_index + i] = data[i]
			}

			return true
		}
	}

	return false
}

// NOTE in utf8 indexing space!
// removes a rune backwards at the wanted codepoint index
ss_remove_at :: proc(ss: ^Small_String, index: int) -> (c: rune, ok: bool) {
	if ss.length == 0 || index == 0 {
		return
	} 

	info, found := _ss_find_byte_index_info(ss, index - 1)

	if !found {
		return
	}

	// no need to copy if at end
	// if info.byte_index != ss.length {
		copy(ss.buf[info.byte_index:ss.length], ss.buf[info.byte_index + info.size:ss.length])
	// }

	ss.length -= info.size
	c = info.codepoint
	ok = true
	return
}

// NOTE in utf8 indexing space!
// removes a rune backwards at the wanted codepoint index
ss_delete_at :: proc(ss: ^Small_String, index: int) -> (c: rune, ok: bool) {
	if ss.length == 0 {
		return
	} 

	info, found := _ss_find_byte_index_info(ss, index)

	// leave early when out of bounds
	if !found {
		return
	}

	// skip empty anyway
	if ss.length == u8(info.size) {
		fmt.eprintln("skip")
	} else {
		copy(ss.buf[info.byte_index:ss.length], ss.buf[info.byte_index + info.size:ss.length])
	}

	c = info.codepoint
	ss.length -= info.size
	ok = true
	return
}

// init with string
ss_init_string :: proc(text: string) -> (ss: Small_String) {
	if len(text) != 0 {
		length := min(len(text), SS_SIZE)
		copy(ss.buf[:length], text[:length])
		ss.length = u8(length)
	}

	return
}

// set the small string to your wanted text
ss_set_string :: proc(ss: ^Small_String, text: string) {
	if len(text) == 0 {
		ss.length = 0
	} else {
		length := min(len(text), SS_SIZE)
		copy(ss.buf[:length], text[:length])
		ss.length = u8(length)
	}
}

// ss_recount :: proc(ss: ^Small_String) -> int {
// 	// ds: xDecode_State
// }

// ss_length :: proc(ss: )