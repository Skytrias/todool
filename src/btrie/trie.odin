package btrie

import "core:os"
import "core:mem"
import "core:math/bits"
import "core:fmt"
import "core:strings"

ALPHABET_SIZE :: 26
SHORTCUT_VALUE :: 0xFC000000 //w upper 6 bits set from u32
ALPHABET_MASK :: u32(1 << 26) - 1

/*
	CTrie (104B)
		uses smallest index possible to reduce size constraints
		data allocated in array -> easy to free/clear/delete
		should be the same speed of the default Trie
*/

// treating 0 as nil as 0 is the root
CTrie :: struct #packed {
	array: [ALPHABET_SIZE]u32,
	count: u8, // count of used array fields
}

ctrie_data: [dynamic]CTrie

ctrie_init :: proc(cap: int) {
	ctrie_data = make([dynamic]CTrie, 0, cap)
	append(&ctrie_data, CTrie {})
}

ctrie_destroy :: proc() {
	delete(ctrie_data)
}

// push a node to the ctrie array and return its index
ctrie_push :: proc() -> u32 {
	append(&ctrie_data, CTrie {})
	return u32(len(ctrie_data) - 1)
}

// simple helper
ctrie_get :: #force_inline proc(index: u32) -> ^CTrie {
	return &ctrie_data[index]
}

// get the root of the ctrie tree
ctrie_root :: #force_inline proc() -> ^CTrie {
	return &ctrie_data[0]
}

// insert a key
ctrie_insert :: proc(key: string) {
	t := ctrie_root()

	for b in key {
		idx := b - 'a'

		if t.array[idx] == 0 {
			t.array[idx] = ctrie_push()
			t.count += 1
		}

		t = ctrie_get(t.array[idx])
	}	
}

// print the ctrie tree
ctrie_print :: proc() {
	depth: int
	ctrie_print_recursive(ctrie_root(), &depth, 0)
}

// print the ctrie tree recursively by nodes
ctrie_print_recursive :: proc(t: ^CTrie, depth: ^int, b: u8) {
	if depth^ != 0 {
		for i in 0..<depth^ - 1 {
			fmt.eprint('\t')
		}
		codepoint := rune(b + 'a')
		fmt.eprint(codepoint, '\n')
	}

	for i in 0..<ALPHABET_SIZE {
		if t.array[i] != 0 {
			depth^ += 1
			ctrie_print_recursive(ctrie_get(t.array[i]), depth, u8(i))
			depth^ -= 1
		}
	}
}

// DEBUG print the ctrie tree size
ctrie_print_size :: proc() {
	size := len(ctrie_data) * size_of(CTrie)
	fmt.eprintf("SIZE in %dB %dKB %dMB for CTrie\n", size, size / 1024, size / 1024 / 1024)
}

/*
	Compressed trie in flat memory
		uses the least amount of memory possible while still being accessible
		bitfield with 32 bits describing 26 wanted bits (a-z)
*/

// dynamic byte array containing flexible compressed trie data
comp: []byte
comp_index: int

// init the comp to some cap
comp_init :: proc(cap := mem.Megabyte) {
	comp = make([]byte, cap)
}

// destroy the comp data
comp_destroy :: proc() {
	delete(comp)	
}

// push u32 alphabet bits data
comp_push_bits :: proc() -> (res: ^u32) {
	old := comp_index
	res = cast(^u32) &comp[old]
	comp_index += size_of(u32)
	return
}

// push trie children nodes as indexes
comp_push_data :: proc(count: int) -> (res: []u32) {
	old := comp_index
	res = mem.slice_ptr(cast(^u32) &comp[old], count)
	comp_index += size_of(u32) * count
	return
}

// baking data when single lane only
single_characters: [256]u8
single_index: int

ctrie_check_single_only :: proc(t: ^CTrie) -> bool {
	if t.count ==0 || t.count == 1 {
		for i in 0..<ALPHABET_SIZE {
			if t.array[i] != 0 {
				// prebake data already
				single_characters[single_index] = u8(i) + 'a'
				single_index += 1

				return ctrie_check_single_only(ctrie_get(t.array[i]))
			}
		}

		return true
	} else {
		return false
	}
}

comp_push_shortcut :: proc(t: ^CTrie) {
	for i in 0..<single_index {
		comp[comp_index] = single_characters[i]
		comp_index += 1
	}	
}

// push a ctrie bitfield and its dynamic data
comp_push_ctrie :: proc(t: ^CTrie, previous_data: ^u32) {
	if previous_data != nil {
		previous_data^ = u32(comp_index)
	}

	alphabet_bits := comp_push_bits()

	// on valid sub nodes -> insert data
	if t.count != 0 {
		field: u32

		// check for single branches only
		if t.count == 1 {
			single_index = 0
			single_only := ctrie_check_single_only(t)
			// fmt.eprintln("single_only?", single_only)

			if single_only {
				// insert shortcut signal
				field = SHORTCUT_VALUE
				// insert string length
				field = bits.bitfield_insert_u32(field, u32(single_index), 0, 26)
				// insert characters
				comp_push_shortcut(t)
			}
		} 

		// if nothing was set
		if field == 0 {
			data := comp_push_data(int(t.count))
			index: int

			for i in 0..<uint(ALPHABET_SIZE) {
				if t.array[i] != 0 {
					field = bits.bitfield_insert_u32(field, 1, i, 1)
					comp_push_ctrie(ctrie_get(t.array[i]), &data[index])
					index += 1
				}
			}
		}

		// only set once
		alphabet_bits^ = field
	}
}

// DEBUG print the trie tree
comp_print :: proc() {
	assert(comp_index != 0)
	depth: int
	comp_print_recursive(cast(^u32) &comp[0], &depth)
}

// DEBUG print the trie tree recursively
comp_print_recursive :: proc(alphabet_bits: ^u32, depth: ^int) {
	b := alphabet_bits^

	if b == 0 {
		return
	}

	// check for shortcut bits
	if comp_bits_is_shortcut(b) {
		depth^ += 1
		for i in 0..<depth^ - 1 {
			fmt.eprint('\t')
		}

		text := comp_bits_shortcut_text(alphabet_bits)
		fmt.eprintln(text)

		depth^ -= 1
		return
	} 

	bit_index: int
	for i := 0; b > 0; i += 1 {
		if b & 1 == 1 {
			// search for matching bits
			depth^ += 1
			for j in 0..<depth^ - 1 {
				fmt.eprint('\t')
			}
			codepoint := rune(i + 'a')
			fmt.eprint(codepoint, '\n')

			next := mem.ptr_offset(alphabet_bits, bit_index + 1)
			comp_print_recursive(cast(^u32) &comp[next^], depth)
			depth^ -= 1
			bit_index += 1
		}

		b >>= 1
	}
}

// print logical size of the compressed trie
comp_print_size :: proc() {
	size := comp_index
	fmt.eprintf("SIZE in %dB %dKB %dMB for compressed\n", size, size / 1024, size / 1024 / 1024)
}

// converts alphabetic byte index into the remapped bitfield space
comp_bits_index_to_counted_one :: proc(field: u32, idx: u32) -> (res: u32, ok: bool) {
	b := field

	for i := u32(0); b > 0; i += 1 {
		if b & 1 == 1 {
			if idx == i {
				ok = true
				return
			}

			res += 1
		}

		b >>= 1
	}

	return
}

// DEBUG prints used characters in the bitset
comp_print_characters :: proc(field: u32) {
	if field == 0 {
		fmt.eprintln("EMPTY BITS")
		return
	}

	b := field
	for i := u32(0); b > 0; i += 1 {
		if b & 1 == 1 {
			fmt.eprint(rune(i + 'a'), ' ')
		}

		b >>= 1
	}

	fmt.eprintln()
}

// TODO escape on utf8 byte?
// lowercase valid alpha
ascii_check_lower :: proc(b: u8) -> u8 {
	if 'A' <= b && b <= 'Z' {
		return b + 32
	} else {
		return b
	}
}

// wether the byte is a letter
ascii_is_letter :: #force_inline proc(b: u8) -> bool {
	return 'a' <= b && b <= 'z'
}

// less pointer offseting sent by Jeroen :)
comp_search :: proc(key: string) -> bool {
	alphabet_bits := cast(^u32) &comp[0]

	for i := 0; i < len(key); i += 1 {
		b := ascii_check_lower(key[i])

		if ascii_is_letter(b) {
			letter := b - 'a'

			// check for shortcut first!
			if comp_bits_is_shortcut(alphabet_bits^) {
				// fmt.eprintln("check bits", key)
				rest := comp_bits_shortcut_text(alphabet_bits)
				assert(len(rest) != 0)
				rest_index: int

				// match the rest letters
				for j in i..<len(key) {
					b = ascii_check_lower(key[j])
					
					if ascii_is_letter(b) {
						// range check
						if rest_index < len(rest) {
							if b != rest[rest_index] {
								return false
							}
						}
					} else {
						return false
					}

					rest_index += 1
				}
			} else {
				// extract bit info
				if res, ok := comp_bits_index_to_counted_one(alphabet_bits^, u32(letter)); ok {
					next := mem.ptr_offset(alphabet_bits, res + 1)
					alphabet_bits = cast(^u32) &comp[next^]
				} else {
					return false
				}
			}
		} else {
			return false
		}
	}
	
	return true
}

// check if the field includes a shortcut
comp_bits_is_shortcut :: #force_inline proc(field: u32) -> bool {
	return (field & SHORTCUT_VALUE) == SHORTCUT_VALUE
}

// extract shortcut length
comp_bits_shortcut_length :: #force_inline proc(field: u32) -> u32 {
	return bits.bitfield_extract_u32(field, 0, 26)
}

// get the shortcut text as a string from the ptr
comp_bits_shortcut_text :: proc(field: ^u32) -> string {
	length := comp_bits_shortcut_length(field^)
	
	return strings.string_from_ptr(
		cast(^u8) mem.ptr_offset(field, 1),
		int(length),
	)
}

comp_write_to_file :: proc(path: string) -> bool {
	return os.write_entire_file(path, comp[:comp_index])
}

comp_read_from_file :: proc(path: string) {
	content, ok := os.read_entire_file(path)

	if ok {
		comp = content
		comp_index = len(content)
	}
}

comp_read_from_data :: proc(data: []byte) {
	comp = data
	comp_index = len(data)
}