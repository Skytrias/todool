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
	filter: [dynamic]int, // what to use
	free_list: [dynamic]int, // empty indices that are allocated but unused from a save file
}

task_pool_push_new :: proc(pool: ^Task_Pool, check_freed: bool) -> (task: ^Task) {
	if check_freed && len(pool.free_list) > 0 {
		freed_index := pool.free_list[len(pool.free_list) - 1]
		pop(&pool.free_list)
		return &pool.list[freed_index]
	}

	index := len(pool.list)
	append(&pool.list, Task {
		list_index = index,
	})
	return &pool.list[index]
}

task_pool_init :: proc() -> (res: Task_Pool) {
	res.list = make([dynamic]Task, 0, 256)
	res.filter = make([dynamic]int, 0, 256)
	return
}

task_pool_clear :: proc(pool: ^Task_Pool) {
	// for task in &pool.list {
	// 	// element_destroy(&task)
	// 	element_destroy_and_deallocate(&task)
	// }

	// TODO clear other data
	clear(&pool.list)
	clear(&pool.filter)
	clear(&pool.free_list)
}

task_pool_destroy :: proc(pool: ^Task_Pool) {
	// for task in &pool.list {
	// 	// element_destroy(&task)
	// 	element_destroy_and_deallocate(&task)
	// }

	// TODO clear other data
	delete(pool.list)
	delete(pool.filter)
	delete(pool.free_list)
}