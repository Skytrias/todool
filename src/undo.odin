package src

import "core:runtime"
import "core:fmt"
import "core:log"
import "core:mem"

// TODO multiple managers and 1 active only

Undo_State :: enum {
	Normal,
	Undoing,
	Redoing,
}

Undo_Manager :: struct {
	undo: [dynamic]byte,
	redo: [dynamic]byte,
	state: Undo_State,
}

undo_manager_init :: proc(manager: ^Undo_Manager, cap: int = mem.Kilobyte * 10) {
	manager.undo = make([dynamic]byte, 0, cap)
	manager.redo = make([dynamic]byte, 0, cap)
}

undo_manager_reset :: proc(manager: ^Undo_Manager) {
	clear(&manager.undo)
	clear(&manager.redo)
	manager.state = .Normal
}

undo_manager_destroy :: proc(manager: ^Undo_Manager) {
	delete(manager.undo)
	delete(manager.redo)
}

// callback type
Undo_Callback :: proc(manager: ^Undo_Manager, item: rawptr)

// footer used to describe the item region coming before this footer in bytes
Undo_Item_Footer :: struct {
	callback: Undo_Callback, // callback that will be called on invoke
	byte_count: int, // item byte count
	group_end: bool, // wether this item means the end of undo steps
}

// push an item with its size and a callback
undo_push :: proc(
	manager: ^Undo_Manager, 
	callback: Undo_Callback,
	item: rawptr, 
	item_bytes: int,
) -> []byte {
	stack := manager.state == .Undoing ? &manager.redo : &manager.undo
	footer := Undo_Item_Footer {
		callback = callback,
		// TODO align?
		byte_count = item_bytes,
	}

	// copy item content and footer
	old_length := len(stack)
	resize(stack, old_length + item_bytes + size_of(Undo_Item_Footer))
	root := uintptr(raw_data(stack^)) + uintptr(old_length)
	mem.copy(rawptr(root), item, item_bytes)
	mem.copy(rawptr(root + uintptr(item_bytes)), &footer, size_of(Undo_Item_Footer))

	if manager.state == .Normal {
		clear(&manager.redo)
	}

	return mem.slice_ptr(cast(^byte) root, item_bytes)
}

// set group_end to true
undo_group_end :: proc(manager: ^Undo_Manager) -> bool {
	assert(manager.state == .Normal)
	stack := &manager.undo
	
	if len(stack) == 0 {
		return false
	}
	
	footer := cast(^Undo_Item_Footer) &stack[len(stack) - size_of(Undo_Item_Footer)]
	footer.group_end = true
	return true
}

// set group_end to false
undo_group_continue :: proc(manager: ^Undo_Manager) -> bool {
	if manager == nil {
		return false
	}

	assert(manager.state == .Normal)
	stack := &manager.undo
	
	if len(stack) == 0 {
		return false
	}
	
	footer := cast(^Undo_Item_Footer) &stack[len(stack) - size_of(Undo_Item_Footer)]
	footer.group_end = false
	return true
}

// check if undo / redo is empty
undo_is_empty :: proc(manager: ^Undo_Manager, redo: bool) -> bool {
	stack := redo ? &manager.redo : &manager.undo
	return len(stack) == 0
}

// invoke the undo / redo action
undo_invoke :: proc(manager: ^Undo_Manager, redo: bool) {
	assert(manager.state == .Normal)
	manager.state = redo ? .Redoing : .Undoing
	stack := redo ? &manager.redo : &manager.undo
	assert(len(stack) != 0)

	first := true
	count: int
	for len(stack) != 0 {
		old_length := len(stack)
		footer := cast(^Undo_Item_Footer) &stack[old_length - size_of(Undo_Item_Footer)]

		if !first && footer.group_end {
			break	
		}
		first = false

		item_root := &stack[old_length - footer.byte_count - size_of(Undo_Item_Footer)]
		footer.callback(manager, item_root)
		resize(stack, old_length - footer.byte_count - size_of(Undo_Item_Footer))
		count += 1
	}

	fmt.eprintf("UNDO: did %d items\n", count)

	// set oposite stack latest footer to group_end = true
	{
		stack := redo ? &manager.undo : &manager.redo
		assert(len(stack) != 0)
		footer := cast(^Undo_Item_Footer) &stack[len(stack) - size_of(Undo_Item_Footer)]
		footer.group_end = true
	}

	manager.state = .Normal
}

undo_is_in_undo :: #force_inline proc(manager: ^Undo_Manager) -> bool {
	return manager.state != .Normal
}

undo_is_in_normal :: #force_inline proc(manager: ^Undo_Manager) -> bool {
	return manager.state == .Normal
}

// // peek the latest undo step in the queue
// undo_peek :: proc(manager: ^Undo_Manager) -> (
// 	callback: Undo_Callback,
// 	item: rawptr,
// 	ok: bool,
// ) {
// 	stack := manager.state == .Undoing ? &manager.redo : &manager.undo
// 	if len(stack) == 0 {
// 		return
// 	}

// 	footer := cast(^Undo_Item_Footer) &stack[len(stack) - size_of(Undo_Item_Footer)]
// 	callback = footer.callback
// 	item = &stack[len(stack) - size_of(Undo_Item_Footer) - footer.byte_count]
// 	ok = true
// 	return
// }