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
import "core:hash"
import "core:text/match"

pattern_load_content_simple :: proc(
	manager: ^Undo_Manager, 
	content: string,
	pattern: string,
	indentation: int,
	index_at: ^int,
) -> (found_any: bool) {
	temp := content

	for line in strings.split_lines_iterator(&temp) {
		m := match.matcher_init(line, pattern)
	
		res, ok := match.matcher_match(&m)

		if ok && m.captures_length > 1 {
			word := match.matcher_capture(&m, 0)
			task_push_undoable(manager, indentation, word, index_at^)
			index_at^ += 1
			found_any = true
		}
	}

	return
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
