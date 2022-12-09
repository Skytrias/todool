package src

import "core:runtime"

// TASK LAYOUT DATA
// dynamic array to store new tasks -> no new(Task) required anymore
// free list to store which tasks were previously "removed" for undo/redo capability
// (maybe) free list for folded content
// "visible" list is fed manually

// MANUAL TASK ACTIONS
//   deleting
//     remove handle from the "filter"
//     push handle to the free list
//   folding
//     pop all children handles
//     push to a folded list which stores all handles
//   swapping
//     happens in visible space only - no complexity at all
//   pushing new
//     just push to the pool
//     insert the handle at any "filter" index

Task_Pool :: struct {
	list: [dynamic]Task, // storage for tasks, never change layout here
	removed_list: [dynamic]int, // list of removed indices
	filter: [dynamic]int, // what to use
}

task_pool_push_new :: proc(pool: ^Task_Pool) -> (index: int) {
	index = len(pool.list)
	append(&pool.list, Task {
		index = index,
	})
	return
}

task_pool_push_remove :: proc(pool: ^Task_Pool, index: int, loc := #caller_location) #no_bounds_check {
	runtime.bounds_check_error_loc(loc, index, len(pool.list) - 1)
	append(&pool.removed_list, index)
}

task_pool_init :: proc() -> (res: Task_Pool) {
	res.list = make([dynamic]Task, 0, 256)
	res.removed_list = make([dynamic]int, 0, 64)
	res.filter = make([dynamic]int, 0, 256)
	return
}

task_pool_clear :: proc(pool: ^Task_Pool) {
	// TODO clear other data
	clear(&pool.list)
	clear(&pool.removed_list)
	clear(&pool.filter)
}

task_pool_destroy :: proc(pool: Task_Pool) {
	// TODO clear other data
	delete(pool.list)
	delete(pool.removed_list)
	delete(pool.filter)
}
