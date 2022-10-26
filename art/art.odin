package art

import "core:mem"
import "core:math/bits"
import "core:fmt"

ALPHABET_SIZE :: 26

/*
	Trie (208B)
		uses new() -> needs proper allocator -> hard to predict size
*/

Trie :: struct {
	array: [ALPHABET_SIZE]^Trie,
}

trie_insert :: proc(t: ^Trie, key: string) {
	n := t

	for b in key {
		idx := b - 'a'

		if n.array[idx] == nil {
			n.array[idx] = new(Trie)
		}

		n = n.array[idx]
	}
}

trie_print :: proc(t: ^Trie) {
	depth: int
	trie_print_recursive(t, &depth, 0)
}

trie_print_recursive :: proc(t: ^Trie, depth: ^int, b: u8) {
	if depth^ != 0 {
		for i in 0..<depth^ - 1 {
			fmt.eprint('\t')
		}
		codepoint := rune(b + 'a')
		fmt.eprint(codepoint, '\n')
	}

	for i in 0..<ALPHABET_SIZE {
		if t.array[i] != nil {
			depth^ += 1
			trie_print_recursive(t.array[i], depth, u8(i))
			depth^ -= 1
		}
	}
}

trie_print_size :: proc(t: ^Trie) {
	size: int
	trie_size_recursive(t, &size)
	fmt.eprintf("SIZE in %dB %dKB %dMB\n", size, size / 1024, size / 1024 / 1024)
}

trie_size_recursive :: proc(t: ^Trie, size: ^int) {
	size^ += size_of(Trie)

	for i in 0..<ALPHABET_SIZE {
		if t.array[i] != nil {
			trie_size_recursive(t.array[i], size)
		}
	}
}

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

ctrie_push :: proc() -> u32 {
	append(&ctrie_data, CTrie {})
	return u32(len(ctrie_data) - 1)
}

ctrie_get :: #force_inline proc(index: u32) -> ^CTrie {
	return &ctrie_data[index]
}

ctrie_root :: #force_inline proc() -> ^CTrie {
	return &ctrie_data[0]
}

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

ctrie_print :: proc() {
	depth: int
	ctrie_print_recursive(ctrie_root(), &depth, 0)
}

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

ctrie_print_size :: proc() {
	size := len(ctrie_data) * size_of(CTrie)
	fmt.eprintf("SIZE in %dB %dKB %dMB for CTrie\n", size, size / 1024, size / 1024 / 1024)
}

/*
	Compressed trie in flat memory
		uses the least amount of memory possible while still being accessible
		bitfield with 32 bits describing 26 wanted bits (a-z)
		map
*/

// dynamic byte array containing flexible compressed trie data
comp: [dynamic]byte

// init the comp to some cap
comp_init :: proc(cap := mem.Megabyte) {
	comp = make([dynamic]byte, 0, cap)
}

// destroy the comp data
comp_destroy :: proc() {
	delete(comp)	
}

// push u32 alphabet bits data
comp_push_bits :: proc() -> ^u32 {
	old := len(comp)
	resize(&comp, old + size_of(u32))
	return cast(^u32) &comp[old]
}

// push trie children nodes as indexes
comp_push_data :: proc(count: int) -> (res: []u32) {
	old := len(comp)
	resize(&comp, old + size_of(u32) * count)
	res = mem.slice_ptr(cast(^u32) &comp[old], count)
	return
}

// push a ctrie bitfield and its dynamic data
comp_push_ctrie :: proc(t: ^CTrie, previous_data: ^u32) {
	if previous_data != nil {
		previous_data^ = u32(len(comp))
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
	assert(len(comp) != 0)
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
	size := len(comp)
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

// searches the compressed trie for the wanted word
comp_search :: proc(key: string) -> bool {
	alphabet_bits := cast(^u32) &comp[0]

	for i in 0..<len(key) {
		b := ascii_check_lower(key[i])

		if ascii_is_letter(b) {
			idx := b - 'a'
			// comp_print_characters(alphabet_bits^)
			
			if res, ok := comp_bits_index_to_counted_one(alphabet_bits^, u32(idx)); ok {
				next := mem.ptr_offset(alphabet_bits, res + 1)
				alphabet_bits = cast(^u32) &comp[next^]
			} else {
				return false
			}
		} else {
			return false
		}
	}

	return true
}

// import "core:fmt"
// import "core:math/bits"
// import "core:strings"
// import "core:mem"

// PREFIX_MAX :: 10

// Node_Type :: enum u8 {
// 	N4,
// 	N16,
// 	N48,
// 	N256,
// }

// Node :: struct {
// 	prefix_length: u32,
// 	type: Node_Type,
// 	children_count: u8,
// 	prefix: [PREFIX_MAX]u8,
// }

// Node4 :: struct {
// 	using n: Node,
// 	key: [4]u8,
// 	children: [4]^Node,
// }

// Node16 :: struct {
// 	using n: Node,
// 	key: [16]u8,
// 	children: [16]^Node,
// }

// Node48 :: struct {
// 	using n: Node,
// 	key: [256]u8,
// 	children: [48]^Node,
// }

// Node256 :: struct {
// 	using n: Node,
// 	children: [256]^Node,
// }

// // Leaf handle to store dynamic strings
// // length + key bytes in memory
// Leaf :: struct {
// 	value: rawptr,
// 	key_length: u16,
// 	// NOTE key data following
// }

// Tree :: struct {
// 	root: ^Node,
// 	size: u64,
// }

// init :: proc() -> (res: Tree) {
// 	return
// }

// destroy :: proc(t: Tree) {

// }

// leaf_new :: proc(key: string, value: rawptr) -> (leaf: ^Leaf) {
// 	// TODO what if key is larger than u16?
// 	leaf = cast(^Leaf) mem.alloc(size_of(Leaf) + len(key))
// 	leaf.value = value
// 	leaf.key_length = u16(len(key))

// 	data := leaf_string_data(leaf)
// 	mem.copy(data, raw_data(key), len(key))

// 	return
// }

// // raw data loction of leaf text
// leaf_string_data :: proc(leaf: ^Leaf) -> ^u8 {
// 	return cast(^u8) mem.ptr_offset(leaf, size_of(Leaf))
// }

// // return odin string from data location + length
// leaf_string :: proc(leaf: ^Leaf) -> string {
// 	return strings.string_from_ptr(leaf_string_data(leaf), int(leaf.key_length))
// }

// // check if the node is a leaf
// leaf_check :: proc(node: ^Node) -> bool {
// 	return uintptr(node) & 1 != 0
// }

// leaf_set :: proc(leaf: ^Leaf) -> rawptr {
// 	return rawptr(uintptr(leaf) | 1)
// }

// leaf_get :: proc(node: ^Node) -> ^Leaf {
// 	return cast(^Leaf) (uintptr(node) &~ 1)
// }

// // check if leaf text matches key
// leaf_matches :: proc(leaf: ^Leaf, key: string) -> bool {
// 	text := leaf_string(leaf)
// 	return text == key
// }

// // find the minimum leaf under a node
// leaf_minimum :: proc(node: ^Node) -> ^Leaf {
// 	if node == nil {
// 		return nil
// 	}

// 	if leaf_check(node) {
// 		return leaf_get(node)
// 	}

// 	switch node.type {
// 		case .N4: {
// 			n := cast(^Node4) node
// 			return leaf_minimum(n.children[0])
// 		}

// 		case .N16: {
// 			n := cast(^Node16) node
// 			return leaf_minimum(n.children[0])
// 		}

// 		case .N48: {
// 			n := cast(^Node48) node
			
// 			idx := 0
// 			for n.key[idx] != 0 {
// 				idx += 1
// 			}
// 			idx = int(n.key[idx]) - 1
				
// 			return leaf_minimum(n.children[idx])
// 		}

// 		case .N256: {
// 			n := cast(^Node256) node
			
// 			idx := 0
// 			for n.children[idx] != nil {
// 				idx += 1
// 			}

// 			return leaf_minimum(n.children[idx])
// 		}
// 	}

// 	panic("leaf_minimum: node type out of bounds")
// }


// // find the maximum leaf under a node
// leaf_maximum :: proc(node: ^Node) -> ^Leaf {
// 	if node == nil {
// 		return nil
// 	}

// 	if leaf_check(node) {
// 		return leaf_get(node)
// 	}

// 	switch node.type {
// 		case .N4: {
// 			n := cast(^Node4) node
// 			return leaf_maximum(n.children[n.children_count - 1])
// 		}

// 		case .N16: {
// 			n := cast(^Node16) node
// 			return leaf_maximum(n.children[n.children_count - 1])
// 		}

// 		case .N48: {
// 			n := cast(^Node48) node
			
// 			idx := 255
// 			for n.key[idx] != 0 {
// 				idx -= 1
// 			}
// 			idx = int(n.key[idx]) - 1
				
// 			return leaf_maximum(n.children[idx])
// 		}

// 		case .N256: {
// 			n := cast(^Node256) node
			
// 			idx := 255
// 			for n.children[idx] != nil {
// 				idx -= 1
// 			}

// 			return leaf_maximum(n.children[idx])
// 		}
// 	}

// 	panic("leaf_maximum: node type out of bounds")
// }

// longest_common_prefix :: proc(l1, l2: ^Leaf, depth: int) -> (idx: int) {
// 	max_cmp := int(min(l1.key_length, l2.key_length)) - depth;
// 	k1 := leaf_string(l1)
// 	k2 := leaf_string(l2)

// 	for ; idx < max_cmp; idx += 1 {
// 		if k1[depth + idx] != k2[depth + idx] {
// 			return 
// 		}
// 	}

// 	return
// }

// insert :: proc(t: ^Tree, key: string, value: rawptr) -> rawptr {
// 	old_replaced: bool
// 	old := insert_recursive(t.root, &t.root, key, value, 0, &old_replaced, true)
// 	if !old_replaced {
// 		t.size += 1
// 	}
// 	return old
// }

// insert_recursive :: proc(
// 	node: ^Node, 
// 	ref: ^^Node,
// 	key: string, 
// 	value: rawptr,
// 	depth: int,

// 	// replace value
// 	old_replaced: ^bool,
// 	replace: bool,
// ) -> (out: rawptr) {
// 	// handle empty tree
// 	if node == nil { 
// 		fmt.eprintln("INSERT: empty to leaf", key)
// 		ref^ = cast(^Node) leaf_set(leaf_new(key, value))
// 		return
// 	}

// 	// expand node
// 	if leaf_check(node) {
// 		l1 := leaf_get(node)

// 		// update data
// 		fmt.eprintln("INSERT: expand", leaf_string(l1), key)
// 		if leaf_matches(l1, key) {
// 			old_replaced^ = true
// 			old_value := l1.value
// 			if replace {
// 				l1.value = value
// 			}
// 			fmt.eprintln("INSERT: same key -> update")
// 			out = old_value
// 			return
// 		}

// 		// create new leaf
// 		node_next := node_new(.N4)
// 		l2 := leaf_new(key, value)

// 		// determine longest prefix
// 		longest_prefix := longest_common_prefix(l1, l2, depth)
// 		{
// 			node_next.prefix_length = u32(longest_prefix)
// 			data := transmute([]byte) key
// 			mem.copy(&node_next.prefix[0], &data[depth], min(PREFIX_MAX, longest_prefix))
// 		}

// 		// add leafs to new Node4
// 		ref^ = node_next
// 		k1 := leaf_string(l1)
// 		k2 := leaf_string(l2)
// 		fmt.eprintln("INSERT: try add 2 children", depth, longest_prefix, k1, k2)
// 		add_child4(node_next, ref, k1[min(depth + longest_prefix, len(k1) - 1)], leaf_set(l1))
// 		add_child4(node_next, ref, k2[depth + longest_prefix], leaf_set(l2))
// 		// add_child4(node_next, ref, k2[min(depth + longest_prefix, len(k2) - 1)], leaf_set(l2))
// 		fmt.eprintln("INSERT: expand end")
// 		return
// 	}

// 	depth := depth

// 	// check if given node has a prefix
// 	if node.prefix_length != 0 {
// 		// determine if the prefixes differ since we need to split
// 		prefix_diff := prefix_mismatch(node, key, depth)
// 		if u32(prefix_diff) >= node.prefix_length {
// 			depth += int(node.prefix_length)

// 			// find a child to recurse to
// 			child := find_child(node, key[depth])
// 			if child != nil {
// 				return insert_recursive(child^, child, key, value, depth + 1, old_replaced, replace)
// 			}

// 			leaf := leaf_new(key, value)
// 			add_child(node, ref, key[depth], leaf_set(leaf))
// 			return
// 		}

// 		// create a new node
// 		node_next := node_new(.N4)
// 		ref^ = node_next
// 		node_next.prefix_length = u32(prefix_diff)
// 		mem.copy(&node_next.prefix[0], &node.prefix[0], min(PREFIX_MAX, prefix_diff))

// 		// adjust the prefix of the old node
// 		if node.prefix_length <= PREFIX_MAX {
// 			add_child4(node_next, ref, node.prefix[prefix_diff], node)
// 			node.prefix_length -= u32(prefix_diff + 1)
// 			fmt.eprintln("ANOTHER MEMMOVE")
// 			mem.copy(&node.prefix[0], &node.prefix[prefix_diff + 1], int(min(PREFIX_MAX, node.prefix_length)))
// 			// TODO mem move
// 		} else {
// 			node.prefix_length -= u32(prefix_diff + 1)
// 			leaf := leaf_minimum(node)
// 			leaf_key := leaf_string(leaf)
// 			add_child4(node_next, ref, leaf_key[depth + prefix_diff], node)
// 			leaf_from := mem.ptr_offset(leaf_string_data(leaf), depth + prefix_diff + 1)
// 			mem.copy(&node.prefix[0], leaf_from, int(min(PREFIX_MAX, node.prefix_length)))
// 		}

// 		leaf := leaf_new(key, value)
// 		add_child4(node_next, ref, key[depth + prefix_diff], leaf_set(leaf))
// 		return
// 	}

// 	return
// }

// prefix_mismatch :: proc(node: ^Node, key: string, depth: int) -> int {
// 	max_cmp := min(min(int(node.prefix_length), PREFIX_MAX), len(key) - depth)
// 	idx: int
// 	for ; idx < max_cmp; idx += 1 {
// 		if node.prefix[idx] != key[depth + idx] {
// 			return idx
// 		}
// 	}

// 	// avoid finding leaf if prefix is short
// 	if node.prefix_length > PREFIX_MAX {
// 		// prefix is no longer than what we've checked, find a leaf
// 		leaf := leaf_minimum(node)
// 		leaf_key := leaf_string(leaf)
// 		max_cmp = min(int(leaf.key_length), len(key)) - depth
		
// 		for ; idx < max_cmp; idx += 1 {
// 			if leaf_key[idx + depth] != key[depth + idx] {
// 				return idx
// 			}
// 		}
// 	}

// 	return idx
// }

// copy_header :: proc(dest, src: ^Node) {
// 	dest.children_count = src.children_count
// 	dest.prefix_length = src.prefix_length
// 	mem.copy(&dest.prefix[0], &src.prefix[0], min(PREFIX_MAX, int(src.prefix_length)))
// }

// add_child :: proc(
// 	node: ^Node,
// 	ref: ^^Node,
// 	b: byte,
// 	child: rawptr,
// ) {
// 	switch node.type {
// 		case .N4: add_child4(node, ref, b, child)
// 		case .N16: add_child16(node, ref, b, child)
// 		case .N48: add_child48(node, ref, b, child)
// 		case .N256: add_child256(node, ref, b, child)
// 	}	

// 	panic("add child: node type out of bounds")
// }

// add_child4 :: proc(
// 	node: ^Node,
// 	ref: ^^Node,
// 	b: byte,
// 	child: rawptr,
// ) {
// 	n := cast(^Node4) node
	
// 	// insert before
// 	if n.children_count < 4 {
// 		idx: u8
// 		for ; idx < n.children_count; idx += 1 {
// 			if b < n.key[idx] {
// 				break
// 			}
// 		}

// 		sub := int(n.children_count) - int(idx)
// 		mem.copy(&n.key[idx + 1], &n.key[idx], sub)
// 		mem.copy(&n.children[idx + 1], &n.children[idx], sub * size_of(rawptr))

// 		// TODO mem move?

// 		// insert
// 		n.key[idx] = b
// 		n.children[idx] = cast(^Node) child
// 		n.children_count += 1
// 	} else {
// 		node_next := cast(^Node16) node_new(.N16)
// 		copy(node_next.children[:], n.children[:])
// 		copy(node_next.key[:], n.key[:])
// 		copy_header(node_next, n)
// 		ref^ = node_next
// 		free(n)
// 		add_child16(node_next, ref, b, child)
// 	}
// }

// add_child16 :: proc(
// 	node: ^Node,
// 	ref: ^^Node,
// 	b: byte,
// 	child: rawptr,
// ) {
// 	n := cast(^Node16) node
	
// 	// insert before
// 	if n.children_count < 16 {
// 		mask := (1 << u32(n.children_count)) - 1

// 		// TODO SSE2
// 		bitfield: u32
// 		for i in 0..<u32(16) {
// 			if b < n.key[i] {
// 				bitfield |= (1 << i)
// 			}
// 		}


// 		idx: int
// 		if bitfield != 0 {
// 			idx = bits.trailing_zeros(int(bitfield))
// 			// TODO mem move?
// 			// could just do mem.copy or copy()
// 			fmt.eprintln("TRYYYYYYYYYYYYYYYYYYYYYYYYYYY copy")
// 		} else {
// 			idx = int(n.children_count)
// 		}

// 		// insert
// 		n.key[idx] = b
// 		n.children[idx] = cast(^Node) child
// 		n.children_count += 1
// 	} else {
// 		node_next := cast(^Node48) node_new(.N48)
// 		copy(node_next.children[:], n.children[:])
// 		for i in 0..<n.children_count {
// 			node_next.key[n.key[i]] = i + 1
// 		}
// 		copy_header(node_next, n)
// 		ref^ = node_next
// 		free(n)
		
// 		add_child48(node_next, ref, b, child)
// 	}
// }

// add_child48 :: proc(
// 	node: ^Node,
// 	ref: ^^Node,
// 	b: byte,
// 	child: rawptr,
// ) {
// 	n := cast(^Node48) node
	
// 	// insert before
// 	if n.children_count < 48 {
// 		// find empty spot
// 		pos := 0
// 		for n.children[pos] != nil {
// 			pos += 1
// 		}

// 		// insert
// 		n.children[pos] = cast(^Node) child
// 		// NOTE might wrap?
// 		n.key[b] = u8(pos + 1) // offset by one since we use "0" as empty
// 		n.children_count += 1
// 	} else {
// 		node_next := cast(^Node256) node_new(.N256)
		
// 		for i in 0..<256 {
// 			if n.key[i] != 0 { // avoid empty "0" 
// 				node_next.children[i] = n.children[n.key[i] - 1]
// 			}
// 		}

// 		copy_header(node_next, n)
// 		ref^ = node_next
// 		free(n)
// 		add_child256(node_next, ref, b, child)
// 	}
// }

// add_child256 :: proc(
// 	node: ^Node,
// 	ref: ^^Node,
// 	b: byte,
// 	child: rawptr,
// ) {
// 	n := cast(^Node256) node
// 	n.children_count += 1
// 	n.children[b] = cast(^Node) child
// }

// // check length based on node type
// is_full :: proc(node: ^Node) -> bool {
// 	return false
// }

// // grow node to larger size
// grow :: proc(node: ^Node) {

// }

// // prefix character shared between key and node
// check_prefix :: proc(node: ^Node, key: string, depth: int) -> (idx: u32) {
// 	max_cmp := min(min(node.prefix_length, PREFIX_MAX), u32(len(key) - depth))

// 	for ; idx < max_cmp; idx += 1 {
// 		if node.prefix[idx] != key[depth + int(idx)] {
// 			return
// 		}
// 	}

// 	return
// }

// find_child :: proc(node: ^Node, b: u8) -> ^^Node {
// 	switch node.type {
// 		case .N4: {
// 			n := cast(^Node4) node
			
// 			// simple loop
// 			for i in 0..<n.children_count {
// 				if n.key[i] == b {
// 					return &n.children[i]
// 				}
// 			}
// 		}

// 		case .N16: {
// 			n := cast(^Node16) node
// 			// TODO SSE implementation
			
// 			for i in 0..<n.children_count {
// 				if n.key[i] == b {
// 					return &n.children[i]
// 				}
// 			}
// 		}

// 		case .N48: {
// 			// two array lookups
// 			n := cast(^Node48) node
// 			index := n.key[b]

// 			if index != 0 {
// 				return &n.children[index - 1]
// 			}
// 		}

// 		case .N256: {
// 			// one array lookup
// 			n := cast(^Node256) node

// 			if n.children[b] != nil {
// 				return &n.children[b]
// 			}
// 		}
// 	}

// 	return nil
// }

// search :: proc(t: ^Tree, key: string) -> (res: rawptr) {
// 	node := t.root
// 	child: ^^Node
// 	depth: int
// 	prefix_length: u32

// 	for node != nil {
// 		// might be a leaf
// 		if leaf_check(node) {
// 			leaf := leaf_get(node)

// 			// check if the expanded path matches
// 			if leaf_matches(leaf, key) {
// 				res = leaf.value
// 			}

// 			return
// 		}

// 		// bail if the prefix does not match
// 		if node.prefix_length != 0 {
// 			prefix_length = check_prefix(node, key, depth)

// 			if prefix_length != min(PREFIX_MAX, node.prefix_length) {
// 				return 
// 			}

// 			depth += int(node.prefix_length)
// 		}

// 		// recursively search
// 		child = find_child(node, key[depth])
// 		node = child != nil ? child^ : nil
// 		depth += 1
// 	}

// 	return
// }

// node_new :: proc(type: Node_Type) -> (res: ^Node) {
// 	switch type {
// 		case .N4: {
// 			res = new(Node4)
// 		}

// 		case .N16: {
// 			res = new(Node16)
// 		}

// 		case .N48: {
// 			res = new(Node48)
// 		}

// 		case .N256: {
// 			res = new(Node256)
// 		}
// 	}	

// 	res.type = type
// 	return
// }

// // TODO iter could just return bool?
// Iter_Callback :: proc(rawptr, string, rawptr) -> int

// // returns 
// iter :: proc(
// 	t: ^Tree, 
// 	cb: Iter_Callback,
// 	data: rawptr,
// ) -> int {
// 	return iter_recursive(t.root, cb, data)
// }

// // recursively iterates over the tree
// iter_recursive :: proc(
// 	node: ^Node, 
// 	cb: Iter_Callback, 
// 	data: rawptr,
// ) -> int {
// 	if node == nil {
// 		return 0
// 	}

// 	if leaf_check(node) {
// 		leaf := leaf_get(node)
// 		return cb(data, leaf_string(leaf), leaf.value)
// 	}

// 	res: int
// 	switch node.type {
// 		case .N4: {
// 			n := cast(^Node4) node

// 			for i in 0..<n.children_count {
// 				res = iter_recursive(n.children[i], cb, data)
				
// 				if res != 0 {
// 					return res
// 				}
// 			}
// 		}

// 		case .N16: {
// 			n := cast(^Node16) node
			
// 			for i in 0..<n.children_count {
// 				res = iter_recursive(n.children[i], cb, data)
				
// 				if res != 0 {
// 					return res
// 				}
// 			}
// 		}

// 		case .N48: {
// 			n := cast(^Node48) node
// 			idx: int

// 			for i in 0..<256 {
// 				idx = int(n.key[i])
// 				if idx == 0 {
// 					continue
// 				}

// 				res = iter_recursive(n.children[idx - 1], cb, data)
// 				if res != 0 {
// 					return res
// 				}
// 			}
// 		}

// 		case .N256: {
// 			n := cast(^Node256) node
			
// 			for i in 0..<256 {
// 				if n.children[i] == nil {
// 					continue
// 				}

// 				res = iter_recursive(n.children[i], cb, data)
// 				if res != 0 {
// 					return res
// 				}
// 			}
// 		}

// 		case: {
// 			panic("iter_resurive: node type out of bounds")
// 		}
// 	}

// 	return 0
// 	// fmt.eprintln(int(node.type))
// }

// // import "core:fmt"
// // import "core:mem"
// // import "core:math/bits"

// // NODE_MAX :: (1 << 29) - 1

// // Node :: struct {
// // 	info: u32,
// // 	data: [^]byte,
// // }

// // // does this node contain a key?
// // node_is_key :: proc(n: ^Node) -> bool {
// // 	return bits.bitfield_extract_u32(n.info, 0, 1) == 1
// // }

// // // set node key bit
// // node_key_set :: proc(n: ^Node, value: bool) {
// // 	n.info = bits.bitfield_insert_u32(n.info, u32(value), 0, 1)
// // }

// // // associated value is nil
// // node_is_null :: proc(n: ^Node) -> bool {
// // 	return bits.bitfield_extract_u32(n.info, 1, 1) == 1
// // }

// // // set node null bit
// // node_null_set :: proc(n: ^Node, value: bool) {
// // 	n.info = bits.bitfield_insert_u32(n.info, u32(value), 1, 1)
// // }

// // // node is compressed
// // node_is_compressed :: proc(n: ^Node) -> bool {
// // 	return bits.bitfield_extract_u32(n.info, 2, 1) == 1
// // }

// // // set node compressed bit
// // node_compressed_set :: proc(n: ^Node, value: bool) {
// // 	n.info = bits.bitfield_insert_u32(n.info, u32(value), 2, 1)
// // }

// // // number of children or compressed string length
// // node_size_get :: proc(n: ^Node) -> u32 {
// // 	return bits.bitfield_extract_u32(n.info, 3, 29)
// // }

// // node_size_set :: proc(n: ^Node, value: u32) {
// // 	n.info = bits.bitfield_insert_u32(n.info, value, 3, 29)
// // }

// // node_padding :: proc(children: int) -> int {
// // 	return (size_of(rawptr) - ((children + 4) % size_of(rawptr))) & (size_of(rawptr)-1)
// // }

// // // node_string :: proc(node: ^Node) -> string {
// // // 	// return 
// // // }

// // node_first_child_ptr :: proc(node: ^Node, children: int) -> ^^Node {
// // 	return cast(^^Node) mem.ptr_offset(node.data, children + node_padding(children))
// // }

// // node_last_child_ptr :: proc(node: ^Node, children: int) -> ^^Node {
// // 	temp := (node_is_key(node) && !node_is_null(node)) ? size_of(rawptr) : 0
	
// // 	return cast(^^Node) mem.ptr_offset(
// // 		cast(^u8) node.data, 
// // 		node_current_length(node, children) - size_of(^Node) - temp,
// // 	)
// // }

// // node_current_length :: proc(node: ^Node, children: int) -> (res: int) {
// // 	res = size_of(Node) + children + node_padding(children)
	
// // 	if node_is_compressed(node) {
// // 		res += size_of(^Node)
// // 	} else {
// // 		add := int(node_is_key(node) && !node_is_null(node)) * size_of(rawptr)
// // 		res += size_of(^Node) * children + add
// // 	}

// // 	return
// // }

// // node_data_set :: proc(node: ^Node, data: rawptr) {
// // 	node_key_set(node, true)

// // 	if data != nil {
// // 		node_null_set(node, false)
		
// // 		children := int(node_size_get(node))
// // 		ndata := mem.ptr_offset(cast(^u8) node, node_current_length(node, children) - size_of(rawptr))

// // 		// TODO check this out more?
// // 		mem.copy(ndata, data, size_of(data))
// // 	} else {
// // 		node_null_set(node, true)
// // 	}
// // }

// // node_data_get :: proc(node: ^Node) -> (res: rawptr) {
// // 	if node_is_null(node) {
// // 		return
// // 	}

// // 	children := int(node_size_get(node))
// // 	ndata := mem.ptr_offset(cast(^u8) node, node_current_length(node, children) - size_of(rawptr))

// // 	mem.copy(res, ndata, size_of(rawptr))
// // 	return
// // }

// // State :: struct {
// // 	head: ^Node,
// // 	number_of_elements: int,
// // 	number_of_nodes: int,
// // }

// // state_new :: proc() -> (state: State) {
// // 	state.number_of_nodes = 1
// // 	state.head = node_new(0, false)
// // 	return
// // }

// // STACK_STATIC_ITEMS :: 32
// // Stack :: [dynamic]rawptr

// // node_new :: proc(children: int, data_field: bool) -> (node: ^Node) {
// // 	node_size := size_of(Node) + children + node_padding(children) + size_of(Node) * children
// // 	fmt.eprintln(node_size)
	
// // 	if data_field {
// // 		node_size += size_of(rawptr)
// // 	}

// // 	// TODO do alignment here?
// // 	node = cast(^Node) mem.alloc(node_size)
// // 	node_size_set(node, u32(children))
// // 	return
// // }

// // // walking through the tree downwards, trying to match the key
// // low_walk :: proc(
// // 	state: ^State,
// // 	key: string,
// // 	stopnode: ^^Node,
// // 	plink: ^^^Node,
// // 	split_pos: ^int,
// // 	ts: ^Stack,
// // ) -> int {
// // 	h := state.head
// // 	parent_link := &state.head

// // 	i, j := 0, 0
// // 	for {
// // 		fmt.eprintln("1: lookup current node", h)
// // 		hsize := int(node_size_get(h))

// // 		if !(hsize != 0 && i < len(key)) {
// // 			break
// // 		}

// // 		v := h.data

// // 		if node_is_compressed(h) {
// // 			for j = 0; j < hsize && i < len(key);  {
// // 				if v[j] != key[i] {
// // 					break
// // 				}

// // 				j += 1 
// // 				i += 1
// // 			}

// // 			if j != hsize {
// // 				break
// // 			}
// // 		} else {
// // 			for j = 0; j < hsize; j += 1 {
// // 				if v[j] == key[i] {
// // 					break
// // 				}
// // 			}

// // 			if j == hsize {
// // 				break
// // 			}
// // 			i += 1
// // 		}

// // 		// save stack of parent nodes
// // 		if ts != nil {
// // 			append(ts, h)
// // 		}

// // 		children := node_first_child_ptr(h, hsize)

// // 		if node_is_compressed(h) {
// // 			j = 0
// // 		}

// // 		parent_link = mem.ptr_offset(children, j)
// // 		j = 0
// // 	}

// // 	fmt.eprintln("1: Lookup stop node is", h)

// // 	if stopnode != nil {
// // 		stopnode^ = h
// // 	}

// // 	if plink != nil {
// // 		plink^ = parent_link
// // 	}

// // 	if split_pos != nil && node_is_compressed(h) {
// // 		split_pos^ = j
// // 	}

// // 	return i
// // }

// // Insert_Result :: enum {
// // 	Failed,
// // 	Success,
// // 	Already_Exists,
// // 	No_Memory,
// // }

// // // insert a string
// // generic_insert :: proc(
// // 	state: ^State,
// // 	key: string,
// // 	data: rawptr,
// // 	old: ^rawptr,
// // 	overwrite: bool,
// // ) -> (res: Insert_Result) {
// // 	fmt.eprintf("2: insert %s with value %p\n", key, data)
// // 	h: ^Node
// // 	parent_link: ^^Node
// // 	j: int
// // 	i := low_walk(state, key, &h, &parent_link, &j, nil)

// // 	if i == len(key) && (!node_is_compressed(h) || j == 0) {
// // 		fmt.eprintln("2: insert: node representing key exists")

// // 		if !node_is_key(h) || (node_is_null(h) && overwrite) {
// // 			// TODO realloc
// // 			// h = 
// // 		}

// // 		if h == nil {
// // 			res = .No_Memory
// // 			return
// // 		}

// // 		if node_is_key(h) {
// // 			if old != nil {
// // 				old^ = node_data_get(h)
// // 			}

// // 			if overwrite {
// // 				node_data_set(h, data)
// // 			}

// // 			res = .Already_Exists
// // 			return
// // 		}

// // 		node_data_set(h, data)
// // 		state.number_of_elements += 1
// // 		res = .Success
// // 		return
// // 	}

// // 	// algorithm 1
// // 	if node_is_compressed(h) && i != len(key) {
// // 		fmt.eprintf("ALGO 1: Stopped at compressed node %v %p\n", node_size_get(h), h.data)
// // 		fmt.eprintln("Still to insert:", len(key) - i, key[i:])
// // 		fmt.eprintf("Splitting at %d: %v\n", j, h.data[j])
// // 		fmt.eprintln("other (key) letter is", key[i])

// // 		// 1: save next pointer
// // 		child_field := node_last_child_ptr(h, int(node_size_get(h)))
// // 		next: ^Node
// // 		mem.copy(&next, child_field, size_of(^Node))
// // 		fmt.eprintf("Next is %p\n", rawptr(next))
// // 		fmt.eprintln("iskey", node_is_key(h))

// // 		if node_is_key(h) {
// // 			fmt.eprintln("key value is", node_data_get(h))
// // 		}

// // 		// set length of additional nodes we will need
// // 		trimmedlen := j
// // 		postfixlen := int(node_size_get(h)) - j - 1
// // 		split_node_is_key := trimmedlen == 0 && node_is_key(h) && !node_is_null(h)
// // 		nodesize: int

// // 		// 2: create the split node
// // 		splitnode := node_new(1, split_node_is_key)
// // 		trimmed, postfix: ^Node

// // 		if trimmedlen != 0 {
// // 			nodesize = size_of(Node) + trimmedlen + node_padding(trimmedlen) + size_of(^Node)
// // 			if node_is_key(h) && !node_is_null(h) {
// // 				nodesize += size_of(rawptr)
// // 			}
// // 			trimmed = cast(^Node) mem.alloc(nodesize)
// // 		}

// // 		if postfixlen != 0 {
// // 			nodesize = size_of(Node) + postfixlen + node_padding(postfixlen) + size_of(^Node)
// // 			postfix = cast(^Node) mem.alloc(nodesize)
// // 		}

// // 		splitnode.data[0] = h.data[j]

// // 		if j == 0 {
// // 			// 3a: replace the old node with the split node
// // 			if node_is_key(h) {
// // 				node_data_set(splitnode, node_data_get(h))
// // 			}

// // 			mem.copy(parent_link, &splitnode, size_of(splitnode))
// // 		} else {
// // 			// 3b: trim the compressed node
// // 			node_size_set(trimmed, u32(j))
// // 			mem.copy(trimmed.data, h.data, j)
// // 			node_compressed_set(trimmed, j > 1)
// // 			node_key_set(trimmed, node_is_key(h))
// // 			node_null_set(trimmed, node_is_null(h))

// // 			if node_is_key(h) && !node_is_null(h) {
// // 				node_data_set(splitnode, node_data_get(h))
// // 			}

// // 			cp := node_last_child_ptr(trimmed, j)
// // 			mem.copy(cp, &splitnode, size_of(splitnode))
// // 			mem.copy(parent_link, &trimmed, size_of(trimmed))
// // 			parent_link = cp
// // 			state.number_of_nodes += 1
// // 		}

// // 		// 4: create postfix node
// // 		if postfixlen != 0 {
// // 			// 4a: create a postfix node
// // 			node_key_set(postfix, false)
// // 			node_null_set(postfix, false)
// // 			node_size_set(postfix, u32(postfixlen))
// // 			node_compressed_set(postfix, postfixlen > 1)
// // 			mem.copy(postfix.data, &h.data[j + 1], postfixlen)
// // 			cp := node_last_child_ptr(postfix, postfixlen)
// // 			mem.copy(cp, &next, size_of(next))
// // 			state.number_of_nodes += 1
// // 		} else {
// // 			// 4b: just use next as postfix node
// // 			postfix = next
// // 		}

// // 		// 5: set splitnode first child as the postfix node
// // 		splitchild := node_last_child_ptr(splitnode, int(node_size_get(splitnode)))
// // 		mem.copy(splitchild, &postfix, size_of(postfix))

// // 		// 6: continue insertion
// // 		free(h)
// // 		h = splitnode
// // 	} else if node_is_compressed(h) && i == len(key) {
// // 		// algorithm 2
// // 		// fmt.eprintln("algorithm 2: stopped at compressed node", node_size_get(h), string(h.data[:]))
// // 		fmt.eprintln("algorithm 2: stopped at compressed node", node_size_get(h))
	
// // 		postfixlen := int(node_size_get(h)) - j
// // 		nodesize := size_of(Node) + postfixlen + node_padding(postfixlen) + size_of(^Node)
// // 		if data != nil {
// // 			nodesize += size_of(rawptr)
// // 		}		
// // 		postfix := cast(^Node) mem.alloc(nodesize)

// // 		nodesize = size_of(Node) + j + node_padding(j) + size_of(^Node)
// // 		if node_is_key(h) && !node_is_null(h) {
// // 			nodesize += size_of(rawptr)
// // 		}
// // 		trimmed := cast(^Node) mem.alloc(nodesize)

// // 		// 1. save next pointer
// // 		childfield := node_last_child_ptr(h, int(node_size_get(h)))
// // 		next: ^Node
// // 		mem.copy(&next, childfield, size_of(next))

// // 		// 2. create the postfix node
// // 		node_size_set(postfix, u32(postfixlen))
// // 		node_compressed_set(postfix, postfixlen > 1)
// // 		node_key_set(postfix, true)
// // 		node_null_set(postfix, false)
// // 		mem.copy(postfix.data, &h.data[i], postfixlen)
// // 		node_data_set(postfix, data)
// // 		cp := node_last_child_ptr(postfix, postfixlen)
// // 		mem.copy(cp, &next, size_of(next))
// // 		state.number_of_nodes += 1

// // 		// 3. trim the compressed node
// // 		node_size_set(trimmed, u32(j))
// // 		node_compressed_set(trimmed, j > 1)
// // 		node_key_set(trimmed, false)
// // 		node_null_set(trimmed, false)
// // 		mem.copy(trimmed.data, h.data, j)
// // 		mem.copy(parent_link, &trimmed, size_of(trimmed))
// // 		if node_is_key(h) {
// // 			node_data_set(trimmed, node_data_get(h))
// // 		}

// // 		// fix the trimmed node child pointer to point to the postfix node
// // 		cp = node_last_child_ptr(trimmed, j)
// // 		mem.copy(cp, &next, size_of(postfix))

// // 		// finish
// // 		state.number_of_elements += 1
// // 		res = .Success
// // 		return 
// // 	}

// // 	// insert missing nodes
// // 	for i < len(key) {
// // 		child: ^Node

// // 		if node_size_get(h) == 0 && len(key) - i > 1 {
// // 			fmt.eprintln("Inserting compressed node")
// // 			comprsize := len(key) - i
// // 			if comprsize > NODE_MAX {
// // 				comprsize = NODE_MAX
// // 			}
// // 			newh := node_compress(h, key[i:comprsize], &child)
// // 			h = newh
// // 			mem.copy(parent_link, &h, size_of(h))
// // 			parent_link = node_last_child_ptr(h, int(node_size_get(h)))
// // 			i += comprsize
// // 		} else {
// // 			fmt.eprintln("Inserting normal node")
// // 			new_parentlink: ^^Node
// // 			newh := node_add_child(h, key[i], &child, &new_parentlink)
// // 			h = newh
// // 			mem.copy(parent_link, &h, size_of(h))
// // 			parent_link = new_parentlink
// // 			i += 1
// // 		}
// // 	}

// // 	// TODO
// // 	// newh = 

// // 	return
// // }

// // // 
// // node_compress :: proc(node: ^Node, key: string, child: ^^Node) -> ^Node {
// // 	assert(node_size_get(node) == 0 && !node_is_compressed(node))

// // 	fmt.eprintln("Compress node:", key)

// // 	// allocate child to link to
// // 	child^ = node_new(0, false)

// // 	// make space in the parent node
// // 	newsize := size_of(Node) + len(key) + node_padding(len(key)) + size_of(^Node)

// // 	data: rawptr
// // 	if node_is_key(node) {
// // 		data = node_data_get(node)

// // 		if !node_is_null(node) {
// // 			newsize += size_of(rawptr)
// // 		}
// // 	} 

// // 	newn := cast(^Node) mem.alloc(newsize)
// // 	node := newn

// // 	node_compressed_set(node, true)
// // 	node_size_set(node, u32(len(key)))
// // 	mem.copy(node.data, raw_data(key), len(key))

// // 	if node_is_key(node) {
// // 		node_data_set(node, data)
// // 	}

// // 	childfield := node_last_child_ptr(node, int(node_size_get(node)))
// // 	mem.copy(childfield, child, size_of(child^))
// // 	return node
// // }

// // node_add_child :: proc(
// // 	node: ^Node,
// // 	c: byte,
// // 	childptr: ^^Node,
// // 	parentlink: ^^^Node,
// // ) -> ^Node {
// // 	assert(!node_is_compressed(node))

// // 	// NOTE alignment stuff?
// // 	temp_size := node_size_get(node)
// // 	curlen := node_current_length(node, int(temp_size))
// // 	node_size_set(node, temp_size + 1)
// // 	temp_size = node_size_get(node)
// // 	newlen := node_current_length(node, int(temp_size))
// // 	node_size_set(node, temp_size - 1)

// // 	// alloc the new child we will link to
// // 	child := node_new(0, false)

// // 	// NOTE realloc 
// // 	// make space in the original node
// // 	newn := cast(^Node) mem.resize(node, curlen, newlen)
// // 	node := newn

// // 	pos: int
// // 	for ; pos < int(node_size_get(node)); pos += 1 {
// // 		if node.data[pos] > c {
// // 			break
// // 		}
// // 	}

// // 	src, dst: ^u8
// // 	if node_is_key(node) && !node_is_null(node) {
// // 		src = &node.data[curlen - size_of(rawptr)]
// // 		dst = &node.data[newlen - size_of(rawptr)]
// // 		// NOTE replaced with copy
// // 		mem.copy(dst, src, size_of(rawptr))
// // 	}

// // 	shift := newlen - curlen - size_of(rawptr)

// // 	nsize := int(node_size_get(node))
// // 	src = node.data[nsize + node_padding(nsize) + size_of(^Node) * pos]
// // 	// NOTE replaced with copy
// // 	mem.copy(mem.ptr_offset(src, shift + size_of(^Node)))

// // 	return node
// // }