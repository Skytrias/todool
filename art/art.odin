package art

import "core:os"
import "core:mem"
import "core:math/bits"
import "core:fmt"

ALPHABET_SIZE :: 26

/*
	CTrie (104B)
		uses smallest index possible to reduce size constraints
		data allocated in array -> easy to free/clear/delete
		should be the same speed of the default Trie
*/

// treating 0 as nil as 0 is the root
CTrie :: struct {
	array: [ALPHABET_SIZE]u32,
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

// push a ctrie bitfield and its dynamic data
comp_push_ctrie :: proc(t: ^CTrie, previous_data: ^u32) {
	if previous_data != nil {
		previous_data^ = u32(comp_index)
	}

	alphabet_bits := comp_push_bits()

	for i in 0..<ALPHABET_SIZE {
		if t.array[i] != 0 {
			alphabet_bits^ = bits.bitfield_insert_u32(alphabet_bits^, 1, uint(i), 1)
		}
	}

	if alphabet_bits^ != 0 {
		ones := bits.count_ones(alphabet_bits^)
		data := comp_push_data(int(ones))
		index: int

		// TODO optimize to store actual used characters to iterate?
		for i in 0..<ALPHABET_SIZE {
			if t.array[i] != 0 {
				comp_push_ctrie(ctrie_get(t.array[i]), &data[index])
				index += 1
			}
		}
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

	index: int
	mask: u32
	for i in 0..<u32(ALPHABET_SIZE) {
		mask = (1 << i)
		
		// search for matching bits
		if b & mask == mask {
			depth^ += 1
			for i in 0..<depth^ - 1 {
				fmt.eprint('\t')
			}
			codepoint := rune(i + 'a')
			fmt.eprint(codepoint, '\n')

			next := mem.ptr_offset(alphabet_bits, index + 1)
			comp_print_recursive(cast(^u32) &comp[next^], depth)
			depth^ -= 1
			index += 1
		}
	}	
}

// comp_bits_contains_byte :: proc(bits: u32, b: u8) -> bool {
// 	mask := u32(1 << u32(b - 'a'))
// 	return bits & mask == mask
// }

// true when the idx exists in the bitfield
comp_bits_contains_index :: proc(bits: u32, idx: u32) -> bool {
	mask := u32(1 << idx)
	return bits & mask == mask
}

// print logical size of the compressed trie
comp_print_size :: proc() {
	size := comp_index
	fmt.eprintf("SIZE in %dB %dKB %dMB for compressed\n", size, size / 1024, size / 1024 / 1024)
}

// converts alphabetic byte index into the remapped bitfield space
comp_bits_index_to_counted_one :: proc(bits: u32, idx: u32) -> (res: u32, ok: bool) {
	mask: u32
	for i in 0..<u32(ALPHABET_SIZE) {
		mask = u32(1 << i)
		
		if bits & mask == mask {
			if idx == i {
				ok = true
				return
			}

			res += 1
		}
	}

	return
}

// prints used characters in the bitset
comp_print_characters :: proc(bits: u32) {
	if bits == 0 {
		fmt.eprintln("EMPTY BITS")
		return
	}

	for i in 0..<ALPHABET_SIZE {
		if comp_bits_contains_index(bits, u32(i)) {
			fmt.eprint(rune(i + 'a'), ' ')
		}
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

// // searches the compressed trie for the wanted word
// comp_search :: proc(key: string) -> bool {
// 	alphabet_bits := cast(^u32) &comp[0]

// 	for i in 0..<len(key) {
// 		b := ascii_check_lower(key[i])

// 		if ascii_is_letter(b) {
// 			idx := b - 'a'
// 			// comp_print_characters(alphabet_bits^)
			
// 			if res, ok := comp_bits_index_to_counted_one(alphabet_bits^, u32(idx)); ok {
// 				next := mem.ptr_offset(alphabet_bits, res + 1)
// 				alphabet_bits = cast(^u32) &comp[next^]
// 			} else {
// 				return false
// 			}
// 		} else {
// 			return false
// 		}
// 	}

// 	return true
// }

comp_search :: proc(key: string) -> bool {
	alphabet := mem.slice_data_cast([]u32, comp)
	next := u32(0)

	for i in 0..<len(key) {
		b := ascii_check_lower(key[i])

		if ascii_is_letter(b) {
			letter := b - 'a'
			// comp_print_characters(alphabet_bits^)

			if res, ok := comp_bits_index_to_counted_one(alphabet[next], u32(letter)); ok {
				next = alphabet[next + res + 1] / size_of(u32)
			} else {
				return false
			}
		} else {
			return false
		}
	}
	
	return true
}

comp_write_to_file :: proc(path: string) -> bool {
	return os.write_entire_file(path, comp[:])
}

comp_read_from_file :: proc(path: string) {
	content, ok := os.read_entire_file(path)

	if ok {
		comp = content
		comp_index = len(content)
	}
}