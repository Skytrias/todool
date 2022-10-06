package rax

import "core:math/bits"
import "core:c"

when ODIN_OS == .Windows { 
	foreign import lib { "main.lib" }
}
when ODIN_OS == .Linux { 
	foreign import lib { "main.a" }
}

Node :: struct {
	// uint32_t iskey:1;     /* Does this node contain a key? */
	// uint32_t isnull:1;    /* Associated value is NULL (don't store it). */
	// uint32_t iscompr:1;   /* Node is compressed. */
	// uint32_t size:29;     /* Number of children, or compressed string len. */
	bitdata: u32,

	data: ^c.uchar,
}

State :: struct {
	head: ^Node,
	numele: u64,
	numnodes: u64,
}

// used value to compare to invalid find result
STACK_STATIC_ITEMS :: 32

Stack :: struct {
	stack: ^rawptr,
	items: c.size_t,
	maxitems: c.size_t,
	static_items: [STACK_STATIC_ITEMS]rawptr,
	oom: c.int,
}

ITER_STATIC_LEN :: 128
ITER_JUST_SEEKED :: (1<<0)
ITER_JUST_EOF :: (1<<1)
ITER_JUST_SAFE :: (1<<2)

NodeCallback :: proc "c" (noderef: ^^Node) -> int

Iterator :: struct {
	flags: c.int,
	rt: ^State,
	key: ^c.uchar,
	data: rawptr,
	key_len: c.size_t,
	key_max: c.size_t,
	key_static_string: [ITER_STATIC_LEN]c.uchar,
	node: ^Node,
	stack: Stack,
	// node_cb: rawptr,
	node_cb: NodeCallback,
}

FindResult :: struct {
	data: rawptr,
	valid: c.bool,
}

@(default_calling_convention="c", link_prefix="rax")
foreign lib {
	New :: proc() -> ^State ---
	Free :: proc(state: ^State) ---
	FreeWithCallback :: proc(state: ^State, free_callback: proc "c"(data: rawptr)) ---

	Insert :: proc(state: ^State, s: ^c.uchar, len: c.size_t, data: rawptr, old: ^rawptr) -> c.int ---
	Remove :: proc(state: ^State, s: ^c.uchar, len: c.size_t, old: ^rawptr) -> c.int ---
	Find :: proc(state: ^State, s: ^c.uchar, len: c.size_t) -> rawptr ---
	// NOTE custom implemented
	CustomFind :: proc(state: ^State, s: ^c.uchar, len: c.size_t) -> FindResult ---
	
	// iterators
	Start :: proc(it: ^Iterator, state: ^State) ---
	Seek :: proc(it: ^Iterator, op: cstring, ele: ^c.uchar, len: c.size_t) -> c.int ---
	Next :: proc(it: ^Iterator) -> c.int ---
	Prev :: proc(it: ^Iterator) -> c.int ---
	RandomWalk :: proc(it: ^Iterator) -> c.int ---
	Compare :: proc(it: ^Iterator, op: cstring, key: ^c.uchar, key_len: c.size_t) -> c.int ---
	Stop :: proc(it: ^Iterator) ---
	EOF :: proc(it: ^Iterator) -> c.int ---
	
	Show :: proc(state: ^State) ---
	Size :: proc(state: ^State) -> c.uint64_t ---
	Touch :: proc(node: ^Node) -> c.ulong ---

	GetData :: proc(node: ^Node) -> rawptr ---

	// LowWalk :: proc(
	// 	state: ^State, 
	// 	s: ^c.uchar, 
	// 	len: c.size_t, 
	// 	stopnode: ^^Node,
	// 	plink: ^^^Node,
	// 	splitpos: ^int,
	// 	ts: ^Stack,
	// ) -> c.size_t ---

}

// insert with defaults
insert_string :: proc(
	state: ^State, 
	text: string, 
	data: rawptr = nil,
	old: ^rawptr = nil,
) -> i32 {
	return Insert(state, raw_data(text), c.size_t(len(text)), data, old)
}

// // simple bool return
// find_string_simple :: proc(
// 	state: ^State,
// 	text: string,
// ) -> bool {
// 	res := Find(state, raw_data(text), c.size_t(len(text)))
// 	return uintptr(res) != NotFound
// }

// find_string :: proc(
// 	state: ^State,
// 	text: string,
// ) -> rawptr {
// 	return Find(state, raw_data(text), c.size_t(len(text)))
// }

// // helper call
// iter :: proc(state: ^State) -> (iter: Iterator) {
// 	Start(&iter, state)
// 	return
// }

// NOTE cautious with returns/params on linux, these will break without setters

seek_string :: proc(
	it: ^Iterator,
	op: cstring,
	ele: string,
) -> bool {
	ele := ele
	return bool(Seek(it, op, raw_data(ele), c.size_t(len(ele))))
}

compare_string :: proc(
	it: ^Iterator,
	op: cstring,
	ele: string,
) -> bool {
	ele := ele
	return bool(Compare(it, op, raw_data(ele), c.size_t(len(ele))))
}

next :: proc(it: ^Iterator) -> bool {
	return bool(Next(it))
}

// CustomNotFound :: 0x50

// custom_find :: proc(state: ^State, s: ^c.uchar, len: c.size_t) -> (data: rawptr, ok: bool) {
// 	h: ^Node

// 	splitpos := 0
// 	i := LowWalk(state, s, len, &h, nil, &splitpos, nil)

// 	iscompr := bits.bitfield_extract(h.bitdata, 2, 1)	
// 	iskey := bits.bitfield_extract(h.bitdata, 0, 1)
// 	if i != len || (iscompr != 0 && splitpos != 0) || iskey == 0 {
// 		return 
// 	}

// 	ok = true
// 	data = GetData(h)
// 	return
// }