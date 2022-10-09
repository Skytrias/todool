package src

import "core:os"
import "core:fmt"
import "core:slice"
import "core:strings"
import "core:log"
import "core:mem"
import "../cutf8"
import "../tfd"

// // push default box shortcuts
// shortcuts_push_box_default :: proc(window: ^Window) {
// 	context.allocator = mem.arena_allocator(&window.shortcut_state.arena)
// 	mapping_push_to = &window.shortcut_state.box
// 	mapping_push("move_left", "ctrl+shift+left", "ctrl+left", "shift+left", "left")
// 	mapping_push("move_right", "ctrl+shift+right", "ctrl+right", "shift+right", "right")
// 	mapping_push("home", "shift+home", "home")
// 	mapping_push("end", "shift+end", "end")
// 	mapping_push("backspace", "ctrl+backspace", "shift+backspace", "backspace")
// 	mapping_push("delete", "shift+delete", "delete")
// 	mapping_push("select_all", "ctrl+a")
// 	mapping_push("copy", "ctrl+c")
// 	mapping_push("cut", "ctrl+x")
// 	mapping_push("paste", "ctrl+v")
// 	// mapping_push_v021_box(window, false)
// }

// shortcut_commands_box := map[string]string {
// 	"move_up" = "moves the thing up",
// }

// TODO could do a specialized allocator but it has to reallow memory regions
// like a memory pool, but needs to allow custom sized strings
//
// NOTE heap is easier for now
Keymap :: struct {
	commands: map[string]Command,
	combo_start: ^Combo_Node,
	combo_end: ^Combo_Node,
}

Command :: struct {
	call: proc(du: u32),
	comment: string,
}

Combo_Node :: struct {
	next: ^Combo_Node,
	combo: string,
	command: string,
	du: u32,
}

// combo extension flags
COMBO_EMPTY :: 0x00
COMBO_FALSE :: COMBO_EMPTY
COMBO_SHIFT :: 0x01
COMBO_TRUE :: 0x02
COMBO_NEGATIVE :: 0x04
COMBO_POSITIVE :: 0x08

// reinterpret data uint to proper data
du_bool :: proc(du: u32) -> bool {
	return du == COMBO_TRUE
}
du_shift :: proc(du: u32) -> bool {
	return du == COMBO_SHIFT
}
du_pos_neg :: proc(du: u32) -> int {
	return du == COMBO_NEGATIVE ? -1 : du == COMBO_POSITIVE ? 1 : 0
}

keymap_combo_execute :: proc(keymap: ^Keymap, combo: string) -> bool {
	for node := keymap.combo_start; node != nil; node = node.next {
		if combo == node.combo {
			if cmd, ok := keymap.commands[node.command]; ok  {
				cmd.call(node.du)
			}

			return true
		}
	} 

	return false
}

keymap_init :: proc(keymap: ^Keymap, cap: int) {
	keymap.commands = make(map[string]Command, cap)
}

keymap_destroy :: proc(keymap: ^Keymap) {
	delete(keymap.commands)
	keymap_clear_combos(keymap)
}

// push a combo to the SLL
keymap_push_combo :: proc(
	keymap: ^Keymap, 
	combo: string,
	command: string,
	du: u32,
) {
	node := new(Combo_Node)
	node.combo = strings.clone(combo)
	node.command = strings.clone(command)
	node.du = du

	if keymap.combo_start == nil {
		keymap.combo_start = node
	}

	if keymap.combo_end != nil {
		keymap.combo_end.next = node
	}

	keymap.combo_end = node
}

// free all nodes
keymap_clear_combos :: proc(keymap: ^Keymap) {
	next: ^Combo_Node
	node := keymap.combo_start
	for node != nil {
		next = node.next
		delete(node.command)
		delete(node.combo)
		free(node)
		node = next
	}	

	keymap.combo_start = nil
	keymap.combo_end = nil
}

keymap_push_box :: proc(keymap: ^Keymap) {

}

// shortcuts_push: ^[dynamic]Shortcut

// shortcuts_push_box :: proc(push_to: ^[dynamic]Shortcut) {
// 	shortcuts_push = push_to

// 	a :: proc(
// 		command: string, 
// 		combos: string, 
// 		call: proc(),
// 		comment: string,
// 	) {
// 		append(shortcuts_push, Shortcut { command, combos, call, comment })
// 	}

// 	a("move_left", "ctrl+shift+left ctrl+left shift+left left", )
// 	a("move_right", "ctrl+shift+right ctrl+right shift+right right")
// 	a("home", "shift+home", "home")
// 	a("end", "shift+end", "end")
// 	a("backspace", "ctrl+backspace shift+backspace backspace")
// 	a("delete", "shift+delete delete")
// 	a("select_all", "ctrl+a")
// 	a("copy", "ctrl+c")
// 	a("cut", "ctrl+x")
// 	a("paste", "ctrl+v")
// }

commands_push: ^map[string]Command
CP1 :: proc(command: string, call: proc(du: u32), comment: string) {
	commands_push[command] = { call, comment }
}

keymap_push: ^Keymap
CP2 :: proc(combo: string, command: string, du: u32 = 0x00) {
	keymap_push_combo(keymap_push, combo, command, du)
}

keymap_push_todool_commands :: proc(keymap: ^Keymap) {
	commands_push = &keymap.commands

	// movement
	CP1("move_up", todool_move_up, "select the upper visible task")
	CP1("move_down", todool_move_down, "select the lower visible task")
	CP1("indent_jump_low_prev", todool_indent_jump_low_prev, "")
	CP1("indent_jump_low_next", todool_indent_jump_low_next, "")
	CP1("indent_jump_same_prev", todool_indent_jump_same_prev, "")
	CP1("indent_jump_same_next", todool_indent_jump_same_next, "")
	CP1("indent_jump_scope", todool_indent_jump_scope, "cycle jump between the start/end task of the parents children")
	CP1("select_all", todool_select_all, "select all visible tasks")

	CP1("bookmark_jump", todool_bookmark_jump, "cycle jump to the previous bookmark")

	CP1("tasks_to_uppercase", todool_tasks_to_uppercase, "uppercase the starting letters of each word for the selected tasks")
	CP1("tasks_to_lowercase", todool_tasks_to_lowercase, "lowercase all the content for the selected tasks")

	CP1("delete_on_empty", todool_delete_on_empty, "deletes the task on no text content")
	CP1("delete_tasks", todool_delete_tasks, "deletes the selected tasks")

	// copy/paste	
	CP1("copy_tasks_to_clipboard", todool_copy_tasks_to_clipboard, "copy the selected tasks STRING content to the clipboard")
	CP1("copy_tasks", todool_copy_tasks, "deep copy the selected tasks to the copy buffer")
	CP1("duplicate_line", todool_duplicate_line, "duplicates the current line")
	CP1("cut_tasks", todool_cut_tasks, "cut the selected tasks to the copy buffer")
	CP1("paste_tasks", todool_paste_tasks, "paste the content from the copy buffer")
	CP1("paste_tasks_from_clipboard", todool_paste_tasks_from_clipboard, "paste the clipboard content based on the indentation")
	CP1("center", todool_center, "center the camera vertically")

	CP1("selection_stop", todool_selection_stop, "stops task selection")
	CP1("change_task_state", todool_change_task_state, "cycles through the task states forwards/backwards")
	CP1("toggle_folding", todool_toggle_folding, "toggle the task folding")
	CP1("toggle_bookmark", todool_toggle_bookmark, "toggle the task bookmark")

	CP1("toggle_tag", todool_toggle_tag, "toggle the task tag bit")
	
	// shifts
	CP1("indentation_shift", todool_indentation_shift, "shift the selected tasks to the left/right")
	CP1("shift_down", todool_shift_down, "shift the selected tasks down while keeping the same indentation")
	CP1("shift_up", todool_shift_up, "shift the selected tasks up while keeping the same indentation")

	// pomodoro
	CP1("pomodoro_toggle", pomodoro_stopwatch_hot_toggle, "toggle the pomodoro work/short break/long break timer")

	// modes	
	CP1("mode_list", todool_mode_list, "change to the list mode")
	CP1("mode_kanban", todool_mode_kanban, "change to the kanban mode")

	// windows
	CP1("theme_editor", theme_editor_spawn, "spawn the theme editor window")
	CP1("changelog", changelog_spawn, "spawn the changelog generator window")

	// insertion
	CP1("insert_sibling", todool_insert_sibling, "insert a task with the same indentation, SHIFT for above")
	CP1("insert_child", todool_insert_child, "insert a task below with increased indentation")

	// misc	
	CP1("undo", todool_undo, "undo the last set of actions")
	CP1("redo", todool_redo, "redo the last set of actions")
	CP1("save", todool_save, "save everything - will use last task save location if set | TRUE to force prompt")
	CP1("load", todool_load, "load task content through file prompt")
	CP1("new_file", todool_new_file, "empty the task content - will try to save before")
	CP1("escape", todool_escape, "escape out of prompts or focused elements")

	// drops
	CP1("goto", todool_goto, "spawn the goto prompt")
	CP1("search", todool_search, "spawn the search prompt")
}

keymap_push_todool_combos :: proc(keymap: ^Keymap) {
	keymap_push = keymap
	
	// movement & selection variants
	CP2("up", "move_up")
	CP2("shift up", "move_up", COMBO_SHIFT)
	CP2("down", "move_down")
	CP2("shift down", "move_down", COMBO_SHIFT)

	CP2("ctrl ,", "indent_jump_low_prev")
	CP2("ctrl shift ,", "indent_jump_low_prev", COMBO_SHIFT)
	CP2("ctrl .", "indent_jump_low_next")
	CP2("ctrl shift .", "indent_jump_low_next", COMBO_SHIFT)
	
	CP2("ctrl up", "indent_jump_same_prev")
	CP2("ctrl shift up", "indent_jump_same_prev", COMBO_SHIFT)
	CP2("ctrl down", "indent_jump_same_next")
	CP2("ctrl shift down", "indent_jump_same_next", COMBO_SHIFT)

	CP2("ctrl m", "indent_jump_scope")
	CP2("ctrl shift m", "indent_jump_scope", COMBO_SHIFT)
	CP2("ctrl shift a", "select_all")

	// commands
	CP2("ctrl tab", "bookmark_jump")
	CP2("ctrl shift tab", "bookmark_jump", COMBO_SHIFT)
	CP2("ctrl shift j", "tasks_to_uppercase")
	CP2("ctrl shift l", "tasks_to_lowercase")
	CP2("ctrl e", "center")

	// deletion
	CP2("backspace", "delete_on_empty")
	CP2("ctrl backspace", "delete_on_empty")
	CP2("ctrl d", "delete_tasks")
	CP2("ctrl shift k", "delete_tasks")

	// copy/paste
	CP2("ctrl alt c", "copy_tasks_to_clipboard")
	CP2("ctrl shift c", "copy_tasks_to_clipboard")
	CP2("ctrl shift alt c", "copy_tasks_to_clipboard")
	CP2("alt c", "copy_tasks_to_clipboard")
	CP2("ctrl c", "copy_tasks")
	CP2("ctrl l", "duplicate_line")
	CP2("ctrl x", "cut_tasks")
	CP2("ctrl v", "paste_tasks")
	CP2("ctrl shift v", "paste_tasks_from_clipboard")

	// misc
	CP2("left", "selection_stop")
	CP2("right", "selection_stop")
	CP2("ctrl q", "change_task_state")
	CP2("ctrl j", "toggle_folding")
	CP2("ctrl b", "toggle_bookmark")

	// tags
	CP2("ctrl 1", "toggle_tag", 0x00)
	CP2("ctrl 2", "toggle_tag", 0x01)
	CP2("ctrl 3", "toggle_tag", 0x02)
	CP2("ctrl 4", "toggle_tag", 0x04)
	CP2("ctrl 5", "toggle_tag", 0x08)
	CP2("ctrl 6", "toggle_tag", 0x10)
	CP2("ctrl 7", "toggle_tag", 0x20)
	CP2("ctrl 8", "toggle_tag", 0x40)

	// shifts
	CP2("tab", "indentation_shift", COMBO_POSITIVE)
	CP2("shift tab", "indentation_shift", COMBO_NEGATIVe)
	CP2("alt down", "shift_down")
	CP2("alt up", "shift_up")

	// modes
	CP2("alt q", "mode_list")
	CP2("alt w", "mode_kanban")

	// windows
	CP2("alt e", "theme_editor")
	CP2("alt x", "changelog")

	// insertion
	CP2("return", "insert_sibling")
	CP2("shift return", "insert_sibling", COMBO_TRUE)
	CP2("ctrl return", "insert_child")

	// misc
	CP2("ctrl z", "undo")
	CP2("ctrl y", "redo")
	CP2("ctrl s", "save")
	CP2("ctrl shift s", "save", COMBO_TRUE)
	CP2("ctrl o", "load")
	CP2("ctrl n", "new_file")
	CP2("escape", "escape")

	// drops
	CP2("ctrl g", "goto")
	CP2("ctrl f", "search")
}

// shortcuts_push_todool :: proc(keymap: ^Keymap) {
// 	// shortcuts_push = push_to
	
// 	a :: proc(
// 		command: string, 
// 		combos: string, 
// 		call: proc(),
// 		comment: string,
// 	) {
// 		append(shortcuts_push, Shortcut { command, combos, call, comment })
// 	}

// 	// movement
// 	a("move_up", "shift+up ctrl+up up", todool_move_up, "select the upper visible task")
// 	a("move_down", "shift+down ctrl+down down", todool_move_down, "select the lower visible task")
// 	a("indent_jump_low_prev", "ctrl+shift+, ctrl+,", todool_indent_jump_low_prev, "")
// 	a("indent_jump_low_next", "ctrl+shift+. ctrl+.", todool_indent_jump_low_next, "")
// 	a("indent_jump_same_prev", "ctrl+shift+up ctrl+up", todool_indent_jump_same_prev, "")
// 	a("indent_jump_same_next", "ctrl+shift+down ctrl+down", todool_indent_jump_same_next, "")
// 	a("indent_jump_scope", "ctrl+shift+m ctrl+m", todool_indent_jump_scope, "cycle jump between the start/end task of the parents children")
// 	a("select_all", "ctrl+shift+a", todool_select_all, "select all visible tasks")

// 	bprev := proc() { todool_bookmark_jump(true) }
// 	bnext := proc() { todool_bookmark_jump(false) }
// 	a("bookmark_jump_prev", "ctrl+shift+tab", bprev, "cycle jump to the previous bookmark")
// 	a("bookmark_jump_next", "ctrl+tab", bnext, "cycle jump to the next bookmark")

// 	a("tasks_to_uppercase", "ctrl+shift+j", todool_tasks_to_uppercase, "uppercase the starting letters of each word for the selected tasks")
// 	a("tasks_to_lowercase", "ctrl+shift+l", todool_tasks_to_lowercase, "lowercase all the content for the selected tasks")

// 	a("delete_on_empty", "ctrl+backspace backspace", todool_delete_on_empty, "deletes the task on no text content")
// 	a("delete_tasks", "ctrl+d ctrl+shift+k", todool_delete_tasks, "deletes the selected tasks")

// 	// copy/paste	
// 	a("copy_tasks_to_clipboard", "ctrl+shift+c ctrl+alt+c ctrl+shift+alt+c alt+c", todool_copy_tasks_to_clipboard, "copy the selected tasks STRING content to the clipboard")
// 	a("copy_tasks", "ctrl+c", todool_copy_tasks, "deep copy the selected tasks to the copy buffer")
// 	a("duplicate_line", "ctrl+l", todool_duplicate_line, "duplicates the current line")
// 	a("cut_tasks", "ctrl+x", todool_cut_tasks, "cut the selected tasks to the copy buffer")
// 	a("paste_tasks", "ctrl+v", todool_paste_tasks, "paste the content from the copy buffer")
// 	a("paste_tasks_from_clipboard", "ctrl+shift+v", todool_paste_tasks_from_clipboard, "paste the clipboard content based on the indentation")
// 	a("center", "ctrl+e", todool_center, "center the camera vertically")

// 	a("selection_stop", "left right", todool_selection_stop, "stops task selection")
// 	a("selection_stop", "left right", todool_selection_stop, "stops task selection")
// 	a("change_task_state", "ctrl+shift+q ctrl+q", todool_change_task_state, "cycles through the task states forwards/backwards")
// 	a("toggle_folding", "ctrl+j", todool_toggle_folding, "toggle the task folding")
// 	a("toggle_bookmark", "ctrl+b", todool_toggle_bookmark, "toggle the task bookmark")

// 	a("tag_toggle1", "ctrl+1", tag_toggle1, "toggle the task tag 1")
// 	a("tag_toggle2", "ctrl+2", tag_toggle2, "toggle the task tag 2")
// 	a("tag_toggle3", "ctrl+3", tag_toggle3, "toggle the task tag 3")
// 	a("tag_toggle4", "ctrl+4", tag_toggle4, "toggle the task tag 4")
// 	a("tag_toggle5", "ctrl+5", tag_toggle5, "toggle the task tag 5")
// 	a("tag_toggle6", "ctrl+6", tag_toggle6, "toggle the task tag 6")
// 	a("tag_toggle7", "ctrl+7", tag_toggle7, "toggle the task tag 7")
// 	a("tag_toggle8", "ctrl+8", tag_toggle8, "toggle the task tag 8")
	
// 	// shifts
// 	sr :: proc() { todool_indentation_shift(1) }
// 	sl :: proc() { todool_indentation_shift(-1) }
// 	a("indentation_shift_right", "tab", sr, "shift the selected tasks to the right")
// 	a("indentation_shift_left", "shift+tab", sl, "shift the selected tasks to the left")
// 	a("shift_down", "alt+down", todool_shift_down, "shift the selected tasks down while keeping the same indentation")
// 	a("shift_up", "alt+up", todool_shift_up, "shift the selected tasks up while keeping the same indentation")

// 	// pomodoro
// 	a("pomodoro_toggle1", "alt+1", pomodoro_stopwatch_hot_toggle0, "toggle the pomodoro work timer")
// 	a("pomodoro_toggle2", "alt+2", pomodoro_stopwatch_hot_toggle1, "toggle the pomodoro short break timer")
// 	a("pomodoro_toggle3", "alt+3", pomodoro_stopwatch_hot_toggle2, "toggle the pomodoro long break timer")

// 	// modes	
// 	a("mode_list", "alt+q", todool_mode_list, "change to the list mode")
// 	a("mode_kanban", "alt+w", todool_mode_kanban, "change to the kanban mode")

// 	// windows
// 	a("theme_editor", "alt+e", theme_editor_spawn, "spawn the theme editor window")
// 	a("changelog", "alt+x", changelog_spawn, "spawn the changelog generator window")

// 	// insertion
// 	a("insert_sibling", "return", proc() { todool_insert_sibling(false) }, "insert a task below with the same indentation")
// 	a("insert_child", "ctrl+return", todool_insert_child, "insert a task below with increased indentation")

// 	// misc	
// 	a("undo", "ctrl+z", todool_undo, "undo the last set of actions")
// 	a("redo", "ctrl+y", todool_redo, "redo the last set of actions")
// 	s1 :: proc() { todool_save(false) }
// 	s2 :: proc() { todool_save(true) }
// 	a("save", "ctrl+s", s1, "save everything - will use last task save location if set")
// 	a("save_as", "ctrl+shift+s", s2, "save everything - location forced by prompt")
// 	a("load", "ctrl+o", todool_load, "load task content through file prompt")
// 	a("new_file", "ctrl+n", todool_new_file, "empty the task content - will try to save before")
// 	a("escape", "escape", todool_escape, "escape out of prompts or focused elements")

// 	// drops
// 	a("goto", "ctrl+g", todool_goto, "spawn the goto prompt")
// 	a("search", "ctrl+f", todool_search, "spawn the search prompt")
// }

// iterate by whitespace, utf8 conform
combo_iterate :: proc(text: ^string) -> (res: string, ok: bool) {
	temp := text^
	state: rune
	codepoint: rune
	start := -1
	index: int
	set: bool

	for len(text) > 0 {
		if cutf8.decode(&state, &codepoint, text[0]) {
			if codepoint != ' ' {
				if start == -1 {
					start = index
				}
			} else {
				if start != -1 {
					res = temp[start:index]
					set = true
				}
			}
		}

		index += 1
		text^ = text^[1:]

		// check inbetween
		if set {
			ok = true
			return
		}
	}

	// add last one
	if start != -1 {
		res = temp[start:]
		ok = true
	}

	return
}

combo_iterate_test :: proc() {
	text := "ctrl+up         ctrl+down"
	fmt.eprintln(text)
	for combo in combo_iterate(&text) {
		fmt.eprintf("\tres: %s\n", combo)
	}
}

// shortcuts_command_execute_todool :: proc(command: string) -> (handled: bool) {
// 	ctrl := mode_panel.window.ctrl
// 	shift := mode_panel.window.shift
// 	handled = true

// 	switch command {
// 		case "move_up": todool_move_up()
// 		case "move_down": todool_move_down()
// 		case "move_up_stack": todool_move_up_stack()
// 		case "move_down_stack": todool_move_down_stack()
		
// 		case "indent_jump_low_prev": todool_indent_jump_low_prev()
// 		case "indent_jump_low_next": todool_indent_jump_low_next()
// 		case "indent_jump_same_prev": todool_indent_jump_same_prev()
// 		case "indent_jump_same_next": todool_indent_jump_same_next()
// 		case "indent_jump_scope": todool_indent_jump_scope()
	
// 		case "bookmark_jump_prev": todool_bookmark_jump(true)
// 		case "bookmark_jump_next": todool_bookmark_jump(false)
		
// 		case "tag_toggle1": tag_toggle(0x01)
// 		case "tag_toggle2": tag_toggle(0x02)
// 		case "tag_toggle3": tag_toggle(0x04)
// 		case "tag_toggle4": tag_toggle(0x08)
// 		case "tag_toggle5": tag_toggle(0x10)
// 		case "tag_toggle6": tag_toggle(0x20)
// 		case "tag_toggle7": tag_toggle(0x40)
// 		case "tag_toggle8": tag_toggle(0x80)

// 		case "delete_tasks": todool_delete_tasks()
// 		case "delete_on_empty": todool_delete_on_empty()
		
// 		case "copy_tasks_to_clipboard": todool_copy_tasks_to_clipboard()
// 		case "copy_tasks": todool_copy_tasks()
// 		case "duplicate_line": todool_duplicate_line()
// 		case "cut_tasks": todool_cut_tasks()
// 		case "paste_tasks": todool_paste_tasks()
// 		case "paste_tasks_from_clipboard": todool_paste_tasks_from_clipboard()
// 		case "center": todool_center()
		
// 		case "tasks_to_lowercase": todool_tasks_to_lowercase()
// 		case "tasks_to_uppercase": todool_tasks_to_uppercase()
		
// 		case "change_task_state": todool_change_task_state()
// 		case "changelog_generate": changelog_spawn()

// 		case "selection_stop": todool_selection_stop()
		
// 		case "toggle_folding": todool_toggle_folding()
// 		case "toggle_bookmark": todool_toggle_bookmark()

// 		case "indentation_shift_right": todool_indentation_shift(1)
// 		case "indentation_shift_left": todool_indentation_shift(-1)

// 		case "pomodoro_toggle1": pomodoro_stopwatch_hot_toggle(0)
// 		case "pomodoro_toggle2": pomodoro_stopwatch_hot_toggle(1)
// 		case "pomodoro_toggle3": pomodoro_stopwatch_hot_toggle(2)

// 		case "mode_list": todool_mode_list()
// 		case "mode_kanban": todool_mode_kanban()
// 		case "theme_editor": theme_editor_spawn()

// 		case "insert_sibling": todool_insert_sibling(false)
// 		case "insert_child": todool_insert_child()

// 		case "shift_up": todool_shift_up()
// 		case "shift_down": todool_shift_down()

// 		case "select_all": todool_select_all()

// 		case "undo": todool_undo()
// 		case "redo": todool_redo()
// 		case "save": todool_save(false)
// 		case "save_as": todool_save(true)
// 		case "new_file": todool_new_file()
// 		case "load": todool_load()

// 		case "goto": todool_goto()
// 		case "search": todool_search()
// 		case "escape": todool_escape()

// 		//v021
// 		case "select_children": todool_select_children()
// 		case "indent_jump_nearby_prev": todool_indent_jump_nearby(true)
// 		case "indent_jump_nearby_next": todool_indent_jump_nearby(false)
// 		case "fullscreen_toggle": window_fullscreen_toggle(window_main)

// 		//v022
// 		case "sort_locals": todool_sort_locals()
// 		case "insert_sibling_above": todool_insert_sibling(true)
// 		case "scale_increase": todool_scale(0.1)
// 		case "scale_decrease": todool_scale(-0.1)

// 		case: {
// 			handled = false
// 		}
// 	}

// 	return
// }

// shortcuts_push_todool_default :: proc(window: ^Window) {
// 	context.allocator = mem.arena_allocator(&window.shortcut_state.arena)
// 	mapping_push_to = &window.shortcut_state.general
// 	mapping_push("move_up", "shift+up", "ctrl+up", "up")
// 	mapping_push("move_down", "shift+down", "ctrl+down", "down")
	
// 	mapping_push("indent_jump_low_prev", "ctrl+shift+,", "ctrl+,")
// 	mapping_push("indent_jump_low_next", "ctrl+shift+.", "ctrl+.")
// 	mapping_push("indent_jump_same_prev", "ctrl+shift+up", "ctrl+up")
// 	mapping_push("indent_jump_same_next", "ctrl+shift+down", "ctrl+down")
// 	mapping_push("indent_jump_scope", "ctrl+shift+m", "ctrl+m")
	
// 	mapping_push("bookmark_jump_prev", "ctrl+shift+tab")
// 	mapping_push("bookmark_jump_next", "ctrl+tab")

// 	mapping_push("tasks_to_uppercase", "ctrl+shift+j")
// 	mapping_push("tasks_to_lowercase", "ctrl+shift+l")

// 	mapping_push("delete_on_empty", "ctrl+backspace", "backspace")
// 	mapping_push("delete_tasks", "ctrl+d", "ctrl+shift+k")
	
// 	mapping_push("copy_tasks_to_clipboard", "ctrl+shift+c", "ctrl+alt+c", "ctrl+shift+alt+c", "alt+c")
// 	mapping_push("copy_tasks", "ctrl+c")
// 	mapping_push("duplicate_line", "ctrl+l")
// 	mapping_push("cut_tasks", "ctrl+x")
// 	mapping_push("paste_tasks", "ctrl+v")
// 	mapping_push("paste_tasks_from_clipboard", "ctrl+shift+v")
// 	mapping_push("center", "ctrl+e")
	
// 	mapping_push("change_task_state", "ctrl+shift+q", "ctrl+q")
	
// 	mapping_push("selection_stop", "left", "right")
// 	mapping_push("toggle_folding", "ctrl+j")
// 	mapping_push("toggle_bookmark", "ctrl+b")

// 	mapping_push("tag_toggle1", "ctrl+1")
// 	mapping_push("tag_toggle2", "ctrl+2")
// 	mapping_push("tag_toggle3", "ctrl+3")
// 	mapping_push("tag_toggle4", "ctrl+4")
// 	mapping_push("tag_toggle5", "ctrl+5")
// 	mapping_push("tag_toggle6", "ctrl+6")
// 	mapping_push("tag_toggle7", "ctrl+7")
// 	mapping_push("tag_toggle8", "ctrl+8")
	
// 	mapping_push("changelog_generate", "alt+x")
	
// 	mapping_push("indentation_shift_right", "tab")
// 	mapping_push("indentation_shift_left", "shift+tab")

// 	mapping_push("pomodoro_toggle1", "alt+1")
// 	mapping_push("pomodoro_toggle2", "alt+2")
// 	mapping_push("pomodoro_toggle3", "alt+3")
	
// 	mapping_push("mode_list", "alt+q")
// 	mapping_push("mode_kanban", "alt+w")
// 	mapping_push("theme_editor", "alt+e")

// 	mapping_push("insert_sibling", "return")
// 	mapping_push("insert_child", "ctrl+return")

// 	mapping_push("shift_down", "alt+down")
// 	mapping_push("shift_up", "alt+up")
// 	mapping_push("select_all", "ctrl+shift+a")

// 	mapping_push("undo", "ctrl+z")
// 	mapping_push("redo", "ctrl+y")
// 	mapping_push("save", "ctrl+s")
// 	mapping_push("save_as", "ctrl+shift+s")
// 	mapping_push("new_file", "ctrl+n")
// 	mapping_push("load", "ctrl+o")

// 	mapping_push("goto", "ctrl+g")
// 	mapping_push("search", "ctrl+f")
// 	mapping_push("escape", "escape")

// 	mapping_push_v021_todool(window, false)
// 	mapping_push_v022_todool(window, false)
// }

// mapping_push_v021_todool :: proc(window: ^Window, maybe: bool) {
// 	mapping_check = maybe
// 	mapping_push_to = &window.shortcut_state.general
// 	mapping_push_checked("select_children", "ctrl+h")
// 	mapping_push_checked("move_up_stack", "ctrl+shift+home", "ctrl+home")
// 	mapping_push_checked("move_down_stack", "ctrl+shift+end", "ctrl+end")
// 	mapping_push_checked("indent_jump_nearby_prev", "alt+left")
// 	mapping_push_checked("indent_jump_nearby_next", "alt+right")
// 	mapping_push_checked("fullscreen_toggle", "f11")
// 	mapping_check = false
// }

// mapping_push_v021_box :: proc(window: ^Window, maybe: bool) {
// 	mapping_check = maybe
// 	mapping_push_to = &window.shortcut_state.box
// 	mapping_push_checked("undo", "ctrl+z")
// 	mapping_push_checked("redo", "ctrl+y")
// 	mapping_check = false
// }

// mapping_push_v022_todool :: proc(window: ^Window, maybe: bool) {
// 	mapping_check = maybe
// 	mapping_push_to = &window.shortcut_state.general
// 	mapping_push_checked("sort_locals", "alt+a")
// 	mapping_push_checked("insert_sibling_above", "shift+return")
// 	mapping_push_checked("scale_increase", "ctrl++")
// 	mapping_push_checked("scale_decrease", "ctrl+-")
// 	mapping_check = false
// }

// // use this on newest release
// mapping_push_newest_version :: proc(window: ^Window) {
// 	context.allocator = mem.arena_allocator(&window.shortcut_state.arena)
// 	mapping_push_v021_todool(window, true)
// 	mapping_push_v021_box(window, true)
// 	mapping_push_v022_todool(window, true)
// }

todool_delete_on_empty :: proc(du: u32) {
	if task_head == -1 {
		return
	}

	task := tasks_visible[task_head]

	if len(task.box.builder.buf) == 0 {
		manager := mode_panel_manager_scoped()
		task_head_tail_push(manager)
		index := task.index
		
		if index == len(mode_panel.children) {
			item := Undo_Item_Task_Pop {}
			undo_task_pop(manager, &item)
		} else {
			task_remove_at_index(manager, index)
		}

		element_repaint(task)
		task_head -= 1
		task_tail -= 1
	}
}

todool_move_up :: proc(du: u32) {
	if task_head == -1 {
		return
	}

	if task_head_tail_check_begin() {
		task_head -= 1
	}
	task_head_tail_check_end()
	bookmark_index = -1
	task := tasks_visible[max(task_head, 0)]
	element_repaint(mode_panel)
	element_message(task.box, .Box_Set_Caret, BOX_END)
}

todool_move_down :: proc(du: u32) {
	if task_head == -1 {
		return 
	}

	if task_head_tail_check_begin() {
		task_head += 1
	}
	task_head_tail_check_end()
	bookmark_index = -1

	task := tasks_visible[min(task_head, len(tasks_visible) - 1)]
	element_message(task.box, .Box_Set_Caret, BOX_END)
	element_repaint(mode_panel)
}

todool_move_up_stack :: proc(du: u32) {
	if task_head == -1 {
		return
	}

	// fill stack when jumping out
	task := tasks_visible[task_head]
	p := task
	for p != nil {
		task_move_stack[p.indentation] = p
		p = p.visible_parent
	}

	if task.indentation > 0 {
		goal := task_move_stack[task.indentation - 1]
		if task_head_tail_check_begin() {
			task_head = goal.visible_index
		}
		task_head_tail_check_end()

		task = tasks_visible[task_head]
		element_message(task.box, .Box_Set_Caret, BOX_END)
		element_repaint(mode_panel)
	}
}

todool_move_down_stack :: proc(du: u32) {
	if task_head == -1 {
		return
	}

	task := tasks_visible[task_head]
	goal := task_move_stack[task.indentation + 1]

	if goal != nil {
		if task_head_tail_check_begin() {
			if goal.visible_index < len(tasks_visible) {
				task_head = goal.visible_index
			}
		}
		task_head_tail_check_end()

		task = tasks_visible[task_head]
		element_message(task.box, .Box_Set_Caret, BOX_END)
		element_repaint(mode_panel)		
	}
}

todool_indent_jump_low_prev :: proc(du: u32) {
	if task_head == -1 {
		return
	}

	task_current := tasks_visible[task_head]

	for i := task_current.index - 1; i >= 0; i -= 1 {
		task := cast(^Task) mode_panel.children[i]

		if task.indentation == 0 && task.visible {
			if task_head_tail_check_begin() {
				task_head = task.visible_index
			}
			task_head_tail_check_end()
			element_message(task.box, .Box_Set_Caret, BOX_END)
			element_repaint(task)
			break
		}
	}
}

todool_indent_jump_low_next :: proc(du: u32) {
	if task_head == -1 {
		return
	}

	task_current := tasks_visible[task_head]

	for i in task_current.index + 1..<len(mode_panel.children) {
		task := cast(^Task) mode_panel.children[i]

		if task.indentation == 0 && task.visible {
			if task_head_tail_check_begin() {
				task_head = task.visible_index
			}
			task_head_tail_check_end()
			element_repaint(task)
			element_message(task.box, .Box_Set_Caret, BOX_END)
			break
		}
	}
}

todool_indent_jump_same_prev :: proc(du: u32) {
	if task_head == -1 {
		return
	}

	task_current := tasks_visible[task_head]

	for i := task_head - 1; i >= 0; i -= 1 {
		task := tasks_visible[i]
		
		if task.indentation == task_current.indentation {
			if task_head_tail_check_begin() {
				task_head = i
			}
			task_head_tail_check_end()
			element_repaint(mode_panel)
			element_message(task.box, .Box_Set_Caret, BOX_END)
			break
		}
	} 
}

todool_indent_jump_same_next :: proc(du: u32) {
	if task_head == -1 {
		return
	}

	task_current := tasks_visible[task_head]

	for i := task_head + 1; i < len(tasks_visible); i += 1 {
		task := tasks_visible[i]
		
		if task.indentation == task_current.indentation {
			if task_head_tail_check_begin() {
				task_head = i
			}
			task_head_tail_check_end()
			element_repaint(mode_panel)
			element_message(task.box, .Box_Set_Caret, BOX_END)
			break
		}
	} 
}

todool_bookmark_jump :: proc(du: u32) {
	shift := du_shift(du)
	
	if len(bookmarks) != 0 && len(tasks_visible) != 0 {
		bookmark_advance(shift)
		index := bookmarks[bookmark_index]
		task := tasks_visible[index]
		task_head = task.visible_index
		task_tail = task.visible_index
		element_repaint(mode_panel)
	}
}

todool_delete_tasks :: proc(du: u32 = 0) {
	if task_head == -1 {
		return
	}

	manager := mode_panel_manager_scoped()
	task_head_tail_push(manager)
	task_remove_selection(manager, true)
	element_repaint(mode_panel)
}

todool_copy_tasks_to_clipboard :: proc(du: u32) {
	if task_head == -1 {
		return
	}

	b := &gs.copy_builder
	strings.builder_reset(b)
	low, high := task_low_and_high()

	// get lowest
	lowest_indentation := max(int)
	for i in low..<high + 1 {
		task := tasks_visible[i]
		lowest_indentation = min(lowest_indentation, task.indentation)
	}

	// write text into buffer
	for i in low..<high + 1 {
		task := tasks_visible[i]
		relative_indentation := task.indentation - lowest_indentation
		task_write_text_indentation(b, task, relative_indentation)
	}

	last_was_task_copy = false
	clipboard_set_with_builder_prefilled()
	element_repaint(mode_panel)
	// fmt.eprint(strings.to_string(b))
}

todool_change_task_selection_state_to :: proc(state: Task_State) {
	if task_head == -1 {
		return
	}

	manager := mode_panel_manager_scoped()
	task_head_tail_push(manager)
	iter := ti_init()

	for task in ti_step(&iter) {
		task_set_state_undoable(manager, task, state)
	}
}

todool_change_task_state :: proc(du: u32) {
	if task_head == -1 {
		return
	}

	shift := du_shift(du)
	manager := mode_panel_manager_scoped()
	task_head_tail_push(manager)
	iter := ti_init()
	index: int

	// modify all states
	for task in ti_step(&iter) {
		index = int(task.state)
		range_advance_index(&index, len(Task_State) - 1, shift)
		// save old set
		task_set_state_undoable(manager, task, Task_State(index))
	}

	element_repaint(mode_panel)
}

todool_indent_jump_scope :: proc(du: u32) {
	if task_head == -1 {
		return
	}

	task_current := tasks_visible[task_head]
	defer element_repaint(mode_panel)

	// skip indent search at higher levels, just check for 0
	if task_current.indentation == 0 {
		// search for first indent 0 at end
		for i := len(tasks_visible) - 1; i >= 0; i -= 1 {
			current := tasks_visible[i]

			if current.indentation == 0 {
				if i == task_head {
					break
				}

				task_head_tail_check_begin()
				task_head = i
				task_head_tail_check_end()
				return
			}
		}

		// search for first indent at 0 
		for i in 0..<len(tasks_visible) {
			current := tasks_visible[i]

			if current.indentation == 0 {
				task_head_tail_check_begin()
				task_head = i
				task_head_tail_check_end()
				break
			}
		}
	} else {
		// check for end first
		last_good := task_head
		for i in task_head + 1..<len(tasks_visible) {
			next := tasks_visible[i]

			if next.indentation == task_current.indentation {
				last_good = i
			}

			if next.indentation < task_current.indentation || i + 1 == len(tasks_visible) {
				if last_good == task_head {
					break
				}

				task_head_tail_check_begin()
				task_head = last_good
				task_head_tail_check_end()
				return
			}
		}

		// move backwards
		last_good = -1
		for i := task_head - 1; i >= 0; i -= 1 {
			prev := tasks_visible[i]

			if prev.indentation == task_current.indentation {
				last_good = i
			}

			if prev.indentation < task_current.indentation {
				task_head_tail_check_begin()
				task_head = last_good
				task_head_tail_check_end()
				break
			}
		}
	}
}

todool_selection_stop :: proc(du: u32) {
	if task_has_selection() {
		task_tail = task_head
		element_repaint(mode_panel)
	}	
}

todool_escape :: proc(du: u32) {
	if image_display_has_content(custom_split.image_display) {
		custom_split.image_display.img = nil
		element_repaint(mode_panel)
		return
	}

	if element_hide(sb.enum_panel, true) {
		element_repaint(mode_panel)
		return
	}

	// reset selection
	if task_head != task_tail {
		task_tail = task_head
		element_repaint(mode_panel)
		return
	}
}

todool_toggle_folding :: proc(du: u32 = 0) {
	if task_head == -1 {
		return
	}

	task := tasks_visible[task_head]
	manager := mode_panel_manager_scoped()

	if task.has_children {
		task_head_tail_push(manager)
		item := Undo_Item_Bool_Toggle { &task.folded }
		undo_bool_toggle(manager, &item)
		
		task_tail = task_head
		element_repaint(mode_panel)
	}
}

todool_insert_sibling :: proc(du: u32) {
	above := du_bool(du)
	manager := mode_panel_manager_scoped()
	task_head_tail_push(manager)

	indentation: int
	goal: int
	if above {
		// above / same line
		if task_head != -1 && task_head > 0 {
			goal = tasks_visible[task_head].index
			indentation = tasks_visible[task_head].indentation
		}

		task_tail = task_head
	} else {
		// next line
		goal = len(mode_panel.children) // default append
		if task_head < len(tasks_visible) - 1 {
			goal = tasks_visible[task_head + 1].index
		}

		if task_head != -1 {
			indentation = tasks_visible[task_head].indentation
		}
	
		task_head += 1
	}

	task_push_undoable(manager, indentation, "", goal)
	task_head_tail_check_end()
	element_repaint(mode_panel)
}

todool_insert_child :: proc(du: u32) {
	indentation: int
	goal := len(mode_panel.children) // default append
	manager := mode_panel_manager_scoped()
	task_head_tail_push(manager)

	if task_head < len(tasks_visible) - 1 {
		goal = tasks_visible[task_head + 1].index
	}
	jump := 1

	if task_head != -1 {
		current_task := tasks_visible[task_head]
		indentation = current_task.indentation + 1
		builder := &current_task.box.builder

		// uppercase word
		if !current_task.has_children && options_uppercase_word() && len(builder.buf) != 0 {
			item := Undo_Builder_Uppercased_Content { builder }
			undo_box_uppercased_content(manager, &item)
		}

		// unfold current task if its folded 
		if current_task.folded {
			count := task_children_count(current_task)
			item := Undo_Item_Bool_Toggle { &current_task.folded }
			undo_bool_toggle(manager, &item)
			goal = current_task.index + 1
		}
	}

	task_push_undoable(manager, indentation, "", goal)
	task_head += jump
	task_head_tail_check_end()
	element_repaint(mode_panel)
}

todool_mode_list :: proc(du: u32) {
	if mode_panel.mode != .List {
		mode_panel.mode = .List
		custom_split_set_scrollbars(custom_split)
		element_repaint(mode_panel)
	}
}

todool_mode_kanban :: proc(du: u32) {
	if mode_panel.mode != .Kanban {
		mode_panel.mode = .Kanban
		custom_split_set_scrollbars(custom_split)
		element_repaint(mode_panel)
	}
}

todool_shift_down :: proc(du: u32) {
	low, high := task_low_and_high()
	if task_head == -1 || high + 1 >= len(tasks_visible) {
		return
	}

	manager := mode_panel_manager_scoped()
	task_head_tail_push(manager)

	for i := high + 1; i > low; i -= 1 {
		x, y := task_xy_to_real(i, i - 1)
		task_swap(manager, x, y)
	}

	task_head += 1
	task_tail += 1
	element_repaint(mode_panel)
}

todool_shift_up :: proc(du: u32) {
	low, high := task_low_and_high()

	if low - 1 < 0 {
		return
	}

	manager := mode_panel_manager_scoped()
	task_head_tail_push(manager)
	low -= 1

	for i in low..<high {
		x, y := task_xy_to_real(i, i + 1)
		task_swap(manager, x, y)
	}

	task_head -= 1
	task_tail -= 1
	element_repaint(mode_panel)
}

todool_select_all :: proc(du: u32) {
	task_tail = 0
	task_head = len(tasks_visible)
	element_repaint(mode_panel)
}

Undo_Item_Int_Set :: struct {
	value: ^int,
	to: int,
}

undo_int_set :: proc(manager: ^Undo_Manager, item: rawptr) {
	data := cast(^Undo_Item_Int_Set) item
	output := Undo_Item_Int_Set { data.value, data.value^ }
	data.value^ = data.to
	undo_push(manager, undo_int_set, &output, size_of(Undo_Item_Int_Set))
}

Undo_Item_Dirty_Increase :: struct {}

Undo_Item_Dirty_Decrease :: struct {}

undo_dirty_increase :: proc(manager: ^Undo_Manager, item: rawptr) {
	dirty += 1
	output := Undo_Item_Dirty_Decrease {}
	undo_push(manager, undo_dirty_decrease, &output, size_of(Undo_Item_Dirty_Decrease))
}

undo_dirty_decrease :: proc(manager: ^Undo_Manager, item: rawptr) {
	dirty -= 1
	output := Undo_Item_Dirty_Increase {}
	undo_push(manager, undo_dirty_increase, &output, size_of(Undo_Item_Dirty_Increase))
}

dirty_push :: proc(manager: ^Undo_Manager) {
	item := Undo_Item_Dirty_Increase {}
	undo_dirty_increase(manager, &item)
}

Undo_Item_Task_Head_Tail :: struct {
	head: int,
	tail: int,
}

undo_task_head_tail :: proc(manager: ^Undo_Manager, item: rawptr) {
	data := cast(^Undo_Item_Task_Head_Tail) item
	old_head := task_head
	old_tail := task_tail
	task_head = data.head
	task_tail = data.tail
	data.head = old_head
	data.tail = old_tail

	undo_push(manager, undo_task_head_tail, item, size_of(Undo_Item_Task_Head_Tail))
}

task_head_tail_push :: proc(manager: ^Undo_Manager) {
	item := Undo_Item_Task_Head_Tail {
		head = task_head,
		tail = task_tail,
	}
	undo_push(manager, undo_task_head_tail, &item, size_of(Undo_Item_Task_Head_Tail))
	dirty_push(manager)
}

Undo_Item_U8_XOR :: struct {
	value: ^u8,
	bit: u8,
}

undo_u8_xor :: proc(manager: ^Undo_Manager, item: rawptr) {
	data := cast(^Undo_Item_U8_XOR) item
	data.value^ ~= data.bit
	undo_push(manager, undo_u8_xor, item, size_of(Undo_Item_U8_XOR))
}

u8_xor_push :: proc(manager: ^Undo_Manager, value: ^u8, bit: u8) {
	item := Undo_Item_U8_XOR {
		value = value,
		bit = bit,
	}
	undo_u8_xor(manager, &item)
}

todool_toggle_tag :: proc(du: u32) {
	if task_head == -1 {
		return
	}

	manager := mode_panel_manager_scoped()
	task_head_tail_push(manager)
	iter := ti_init()
	bit := u8(du)

	for task in ti_step(&iter) {
		u8_xor_push(manager, &task.tags, bit)
	}

	element_repaint(mode_panel)
}

Undo_Item_Task_Swap :: struct {
	a, b: ^^Task,
}

task_indentation_set_animate :: proc(manager: ^Undo_Manager, task: ^Task, set: int, folded: bool) {
	item := Undo_Item_Task_Indentation_Set {
		task = task,
		set = task.indentation,
	}	
	undo_push(manager, undo_task_indentation_set, &item, size_of(Undo_Item_Task_Indentation_Set))

	task.indentation = set
	task.indentation_animating = true
	task.folded = folded
	element_animation_start(task)
}

undo_task_swap :: proc(manager: ^Undo_Manager, item: rawptr) {
	data := cast(^Undo_Item_Task_Swap) item
	a_indentation := data.a^.indentation
	b_indentation := data.b^.indentation
	a_folded := data.a^.folded
	b_folded := data.b^.folded
	data.a^, data.b^ = data.b^, data.a^

	task_indentation_set_animate(manager, data.a^, a_indentation, a_folded)
	task_indentation_set_animate(manager, data.b^, b_indentation, b_folded)

	undo_push(manager, undo_task_swap, item, size_of(Undo_Item_Task_Swap))	
}

task_swap_animation :: proc(task: ^Task) {
	if task.visible {
		task.top_offset = 0
		task.top_animation_start = true
		task.top_animating = true
		task.top_old = task.bounds.t
		element_animation_start(task)
	}
}

// swap with +1 / -1 offset 
task_swap :: proc(manager: ^Undo_Manager, a, b: int) {
	aa := cast(^^Task) &mode_panel.children[a]
	bb := cast(^^Task) &mode_panel.children[b]
	item := Undo_Item_Task_Swap {
		a = aa,
		b = bb,
	}
	undo_task_swap(manager, &item)

	// or dont swap indentation? could be optional
	// animate the thing when visible
	task_swap_animation(aa^)
	task_swap_animation(bb^)

	element_repaint(mode_panel)
}

Undo_Item_Bool_Toggle :: struct {
	value: ^bool,
}

// inverse bool set
undo_bool_toggle :: proc(manager: ^Undo_Manager, item: rawptr) {
	data := cast(^Undo_Item_Bool_Toggle) item
	data.value^ = !data.value^
	undo_push(manager, undo_bool_toggle, item, size_of(Undo_Item_Bool_Toggle))
}

Undo_Item_U8_Set :: struct {
	value: ^u8,
	to: u8,
}

undo_u8_set :: proc(manager: ^Undo_Manager, item: rawptr) {
	data := cast(^Undo_Item_U8_Set) item
	old := data.value^
	data.value^ = data.to
	data.to = old
	undo_push(manager, undo_u8_set, item, size_of(Undo_Item_U8_Set))
	changelog_update_safe()
}

task_set_state_undoable :: proc(manager: ^Undo_Manager, task: ^Task, goal: Task_State) {
	if manager == nil {
		task.state = goal
	} else {
		item := Undo_Item_U8_Set {
			cast(^u8) &task.state,
			cast(u8) task.state,
		}
		undo_push(manager, undo_u8_set, &item, size_of(Undo_Item_U8_Set))
		task.state = goal
		changelog_update_safe()
	}
}

Undo_Item_Task_Indentation_Set :: struct {
	task: ^Task,
	set: int,
}

undo_task_indentation_set :: proc(manager: ^Undo_Manager, item: rawptr) {
	data := cast(^Undo_Item_Task_Indentation_Set) item
	old_indentation := data.task.indentation
	data.task.indentation = data.set
	data.task.indentation_smooth = f32(data.set)
	data.set = old_indentation
	undo_push(manager, undo_task_indentation_set, item, size_of(Undo_Item_Task_Indentation_Set))
}

Undo_Item_Task_Remove_At :: struct {
	index: int,
	task: ^Task,
}

Undo_Item_Task_Insert_At :: struct {
	index: int,
	task: ^Task, // the task you want to insert
}

task_remove_at_index :: proc(manager: ^Undo_Manager, index: int) {
	item := Undo_Item_Task_Remove_At { index, cast(^Task) mode_panel.children[index] }
	undo_task_remove_at(manager, &item)
}

undo_task_remove_at :: proc(manager: ^Undo_Manager, item: rawptr) {
	data := cast(^Undo_Item_Task_Remove_At) item
	
	output := Undo_Item_Task_Insert_At {
		data.index, 
		data.task,
	} 

	// TODO maybe speedup somehow?
	ordered_remove(&mode_panel.children, data.index)
	undo_push(manager, undo_task_insert_at, &output, size_of(Undo_Item_Task_Insert_At))
	task_clear_checking[data.task] = 1
}

undo_task_insert_at :: proc(manager: ^Undo_Manager, item: rawptr) {
	data := cast(^Undo_Item_Task_Insert_At) item
	inject_at(&mode_panel.children, data.index, data.task)

	output := Undo_Item_Task_Remove_At { data.index, data.task }
	undo_push(manager, undo_task_remove_at, &output, size_of(Undo_Item_Task_Remove_At))
}

Undo_Item_Task_Append :: struct {
	task: ^Task,
}

Undo_Item_Task_Pop :: struct {
	task: ^Task,
}

undo_task_append :: proc(manager: ^Undo_Manager, item: rawptr) {
	data := cast(^Undo_Item_Task_Append) item
	append(&mode_panel.children, data.task)
	output := Undo_Item_Task_Pop { data.task }
	undo_push(manager, undo_task_pop, &output, size_of(Undo_Item_Task_Pop))
}

undo_task_pop :: proc(manager: ^Undo_Manager, item: rawptr) {
	data := cast(^Undo_Item_Task_Pop) item
	// gather the popped element before
	output := Undo_Item_Task_Append { 
		cast(^Task) mode_panel.children[len(mode_panel.children) - 1],
	}
	pop(&mode_panel.children)
	undo_push(manager, undo_task_append, &output, size_of(Undo_Item_Task_Append))
}

// Undo_Item_Task_Clear :: struct {
// 	old_length: int,
// }

// undo_task_clear :: proc(manager: ^Undo_Manager, item: rawptr) {
// 	data := cast(^Undo_Item_Task_Clear) item
// 	log.info("manager.state", manager.state, data.old_length)

// 	if manager.state == .Undoing {
// 		raw := cast(^mem.Raw_Dynamic_Array) &mode_panel.children
// 		raw.len = data.old_length
// 	} else {
// 		data.old_length = len(mode_panel.children)
// 		clear(&mode_panel.children)
// 	}

// 	undo_push(manager, undo_task_clear, item, size_of(Undo_Item_Task_Clear))
// }

// removes selected region and pushes them to the undo stack
task_remove_selection :: proc(manager: ^Undo_Manager, move: bool) {
	iter := ti_init()
	
	for i in 0..<iter.range {
		task := cast(^Task) mode_panel.children[iter.offset]
		archive_push(strings.to_string(task.box.builder)) // only valid
		task_remove_at_index(manager, iter.offset)
	}

	if move {
		task_head = iter.low - 1
		task_tail = iter.low - 1
	}
}

// copy selected tasks
copy_selection :: proc() -> bool {
	if task_head != -1 {
		copy_reset()
		low, high := task_low_and_high()

		// copy each line
		for i in low..<high + 1 {
			task := tasks_visible[i]
			copy_push_task(task)
		}

		return true
	}

	return false
}

todool_indentation_shift :: proc(du: u32) {
	amt := du_pos_neg(du)

	if task_head == -1 || amt == 0 {
		return
	}

	// skip first
	if task_head == task_tail && task_head == 0 {
		return
	}

	manager := mode_panel_manager_scoped()
	task_head_tail_push(manager)
	iter := ti_init()

	lowest := tasks_visible[iter.low - 1]
	unfolded: bool

	for task in ti_step(&iter) {
		if task.index == 0 {
			continue
		}

		// unfold lowest parent
		if amt > 0 && lowest.folded {
			item := Undo_Item_Bool_Toggle { &lowest.folded }
			undo_bool_toggle(manager, &item)
			unfolded = true
		}

		if task.indentation + amt >= 0 {
			task_indentation_set_animate(manager, task, task.indentation + amt, task.folded)
		}
	}

	// hacky way to offset selection by unfolded content
	if unfolded {
		l, h := task_children_range(lowest)
		size := h - l
		task_head += size - iter.range + 1
		task_tail += size - iter.range + 1
	}

	// set new indentation based task info and push state changes
	task_set_children_info()
	task_check_parent_states(manager)

	element_repaint(mode_panel)
}

todool_undo :: proc(du: u32) {
	manager := &um_task
	if !undo_is_empty(manager, false) {
		// reset bookmark index
		bookmark_index = -1

		undo_invoke(manager, false)
		element_repaint(mode_panel)
	}
}

todool_redo :: proc(du: u32) {
	manager := &um_task
	if !undo_is_empty(manager, true) {
		// reset bookmark index
		bookmark_index = -1

		undo_invoke(manager, true)
		element_repaint(mode_panel)
	}
}

todool_save :: proc(du: u32) {
	force_dialog := du_bool(du)
	
	if force_dialog || last_save_location == "" {
		// output: cstring
		default_path := gs_string_to_cstring(gs.pref_path)
		file_patterns := [?]cstring { "*.todool" }
		output := tfd.save_file_dialog("Save", default_path, file_patterns[:], "")

		if output != nil {
			last_save_set(string(output))
		} else {
			return
		}
	}

	err := editor_save(last_save_location)
	if err != .None {
		log.info("SAVE: save.todool failed saving =", err)
	}

	// when anything was pushed - set to false
	if dirty != dirty_saved {
		dirty_saved = dirty
	}

	if !json_save_misc("save.sjson") {
		log.info("SAVE: save.sjson failed saving")
	}

	if !keymap_save("save.keymap") {
		log.info("SAVE: save.keymap failed saving")
	}

	element_repaint(mode_panel)
}

// load
todool_load :: proc(du: u32) {
	default_path: cstring

	if last_save_location == "" {
		default_path = gs_string_to_cstring(gs.base_path)
		// log.info("----")
	} else {
		trimmed_path := last_save_location

		for i := len(trimmed_path) - 1; i >= 0; i -= 1 {
			b := trimmed_path[i]
			if b == '/' {
				trimmed_path = trimmed_path[:i]
				break
			}
		}

		default_path = gs_string_to_cstring(last_save_location)
		// log.info("++++", last_save_location, trimmed_path)
	}

	file_patterns := [?]cstring { "*.todool" }
	output := tfd.open_file_dialog("Open", default_path, file_patterns[:])
	
	if output == nil {
		return
	}

	// ask for save path after choosing the next "open" location
	// check for canceling loading
	if todool_check_for_saving(window_main) {
		return
	}

	last_save_set(string(output))
	err := editor_load(last_save_location)

	if err != .None {
		log.info("LOAD: FAILED =", err)
	}

	element_repaint(mode_panel)
}

todool_toggle_bookmark :: proc(du: u32) {
	if task_head == -1 {
		return
	}

	low, high := task_low_and_high()
	manager := mode_panel_manager_scoped()
	task_head_tail_push(manager)

	for i in low..<high + 1 {
		task := tasks_visible[i]
		item := Undo_Item_Bool_Toggle { &task.bookmarked }
		undo_bool_toggle(manager, &item)
	}

	element_repaint(mode_panel)
}

// use this for simple panels instead of manually indexing for the text box
// which could lead to errors when rearranging or adding new elements
// could return nil
element_find_first_text_box :: proc(parent: ^Element) -> ^Text_Box {
	for child in parent.children {
		if child.message_class == text_box_message {
			return cast(^Text_Box) child
		}
	}

	return nil
}

todool_goto :: proc(du: u32) {
	p := panel_goto

	element_hide(p, false)
	goto_transition_unit = 1
	goto_transition_hide = false
	goto_transition_animating = true
	element_animation_start(p)

	box := element_find_first_text_box(p.panel)
	assert(box != nil)
	element_focus(window_main, box)

	goto_saved_task_head = task_head
	goto_saved_task_tail = task_tail

	// reset text
	strings.builder_reset(&box.builder)
	box.head = 0
	box.tail = 0
}

todool_search :: proc(du: u32) {
	p := panel_search
	element_hide(p, false)

	// save info
	ss.saved_task_head = task_head
	ss.saved_task_tail = task_tail

	box := element_find_first_text_box(p)
	assert(box != nil)
	element_focus(window_main, box)

	if task_head != -1 {
		task := tasks_visible[task_head]

		// set word to search instantly
		if task.box.head != task.box.tail {
			// cut out selected word
			ds: cutf8.Decode_State
			low, high := box_low_and_high(task.box)
			text, ok := cutf8.ds_string_selection(
				&ds, 
				strings.to_string(task.box.builder), 
				low, 
				high,
			)

			strings.builder_reset(&box.builder)
			strings.write_string(&box.builder, text)

			ss_update(text)
		}

		ss.saved_box_head = task.box.head
		ss.saved_box_tail = task.box.tail
	}		

	element_message(box, .Box_Set_Caret, BOX_SELECT_ALL)
}

issue_copy :: proc() {
	if !last_was_task_copy {
		element_repaint(mode_panel) // required to make redraw and copy 
	}
	last_was_task_copy = true
}

todool_duplicate_line :: proc(du: u32) {
	if task_head == -1 {
		return
	}

	manager := mode_panel_manager_scoped()
	task_head_tail_push(manager)
	task_current := tasks_visible[task_head]
	index, indentation := task_head_safe_index_indentation()
	task_push_undoable(manager, indentation, strings.to_string(task_current.box.builder), index)
	element_repaint(mode_panel)

	task_head += 1
	task_head_tail_check_end()
}

todool_copy_tasks :: proc(du: u32 = 0) {
	if copy_selection() {
		issue_copy()
	}
}

todool_cut_tasks :: proc(du: u32 = 0) {
	if task_head == -1 {
		return 
	}

	last_was_task_copy = true
	manager := mode_panel_manager_scoped()
	task_head_tail_push(manager)

	copy_selection()
	task_remove_selection(manager, true)
	element_repaint(mode_panel)
}

todool_paste_tasks :: proc(du: u32 = 0) {
	if copy_empty() {
		return
	}

	manager := mode_panel_manager_scoped()
	task_head_tail_push(manager)

	// no selection
	if task_head == -1 || task_head == task_tail {
		index, indentation := task_head_safe_index_indentation()
		copy_paste_at(manager, index + 1, indentation)
		
		task_head = max(task_head, 0) + len(copy_task_data)
		task_tail = max(task_head, 0)
	} else {
		indentation := max(int)

		// get lowest indentation of removal selection
		{
			low, high := task_low_and_high()
			for i in low..<high + 1 {
				task := tasks_visible[i]
				indentation = min(indentation, task.indentation)
			}
		}

		task_remove_selection(manager, true)

		index, _ := task_head_safe_index_indentation()
		index += 1
		copy_paste_at(manager, index, indentation)
		
		task_head += len(copy_task_data)
		task_tail = task_head
	}

	element_repaint(mode_panel)
}

todool_paste_tasks_from_clipboard :: proc(du: u32) {
	if clipboard_has_content() {
		clipboard_text := clipboard_get_with_builder()
		
		// indentation
		indentation_per_line := make([dynamic]u16, 0, 256)
		defer delete(indentation_per_line)

		// find indentation per line
		{
			text := clipboard_text
			for line in strings.split_lines_iterator(&text) {
				append(&indentation_per_line, u16(tabs_count(line)))
			}
		}

		manager := mode_panel_manager_scoped()
		task_head_tail_push(manager)

		// have to make this work for non task case
		task_index: int
		indentation: int
		
		if task_head != -1 {
			low, high := task_low_and_high()
			highest_task := tasks_visible[high]
			task_index = highest_task.index + 1
			indentation = highest_task.indentation
		}

		// insert line at correct index
		line_index: int
		text := clipboard_text
		for line in strings.split_lines_iterator(&text) {
			off := indentation_per_line[line_index]
			task_push_undoable(manager, indentation + int(off), strings.trim_space(line), task_index)
			task_index += 1
			line_index += 1
		}

		task_tail = task_head + 1
		task_head = task_head + line_index
		element_repaint(mode_panel)
	}
}

todool_center :: proc(du: u32) {
	if task_head != -1 {
		cam := mode_panel_cam()
		cam.freehand = false
		cam_center_by_height_state(cam, mode_panel.bounds, caret_rect.t)
	}
}

todool_tasks_to_uppercase :: proc(du: u32) {
	if task_head != -1 {
		manager := mode_panel_manager_scoped()
		task_head_tail_push(manager)
		iter := ti_init()

		for task in ti_step(&iter) {
			builder := &task.box.builder
	
			if len(builder.buf) != 0 {
				item := Undo_Builder_Uppercased_Content { builder }
				undo_box_uppercased_content(manager, &item)
			}
		}

		element_repaint(mode_panel)
	}
}

todool_tasks_to_lowercase :: proc(du: u32) {
	if task_head != -1 {
		manager := mode_panel_manager_scoped()
		task_head_tail_push(manager)
		iter := ti_init()

		for task in ti_step(&iter) {
			builder := &task.box.builder
	
			if len(builder.buf) != 0 {
				item := Undo_Builder_Lowercased_Content { builder }
				undo_box_lowercased_content(manager, &item)
			}
		}

		element_repaint(mode_panel)
	}
}

todool_new_file :: proc(du: u32) {
  if !todool_check_for_saving(window_main) {
	  tasks_load_reset()
	  last_save_set("")
  }
}

todool_check_for_saving :: proc(window: ^Window) -> (canceled: bool) {
	// ignore empty file saving
	if task_head == -1 {
		return
	}

	if options_autosave() {
		todool_save(COMBO_FALSE)
	} else if dirty != dirty_saved {
		res := dialog_spawn(
			window, 
			"Save progress?\n%l\n%f%B%b%C",
			"Yes",
			"No",
			"Cancel",
		)
		
		switch res {
			case "Yes": {
				todool_save(COMBO_FALSE)
			}

			case "Cancel": {
				canceled = true
			}

			case "No": {}
		}
	}

	return
}

todool_select_children :: proc(du: u32) {
	if task_head == -1 {
		return
	}

	if task_head == task_tail {
		task := tasks_visible[task_head]

		if task.has_children {
			if task.folded {
				todool_toggle_folding()
				task_set_visible_tasks()
				task_check_parent_states(nil)
			}

			task_tail = task_head

			index := task.visible_index + 1
			for index < len(tasks_visible) {
				t := tasks_visible[index]

				if t.indentation <= task.indentation {
					break
				}

				index += 1
			}

			task_head = index - 1
		}		
	} else {
		task_head, task_tail = task_tail, task_head
	}

	element_repaint(mode_panel)
}

// jumps to nearby state changes
todool_indent_jump_nearby :: proc(du: u32) {
	backwards := du_bool(du)

	if task_head == -1 {
		return
	}

	task_current := tasks_visible[task_head]

	for i in 0..<len(tasks_visible) {
		index := backwards ? (task_head - i - 1) : (i + task_head + 1)
		// wrap negative
		if index < 0 {
			index = len(tasks_visible) + index
		}
		task := tasks_visible[index % len(tasks_visible)]
		
		if task.state != task_current.state {
			if task_head_tail_check_begin() {
				task_head = task.visible_index
			}
			task_head_tail_check_end()
			element_repaint(mode_panel)
			break
		}
	}
}

Undo_Item_Task_Sort :: struct {
	task_current: ^Task,
	from, to: int,
}

undo_task_sort :: proc(manager: ^Undo_Manager, item: rawptr) {
	data := cast(^Undo_Item_Task_Sort) item
	
	Task_Line :: struct {
		task: ^Task,
		children_from, children_to: i32,
	}

	sort_list := make([dynamic]Task_Line, 0, 64)
	defer delete(sort_list)
	
	children := make([dynamic]^Task, 0, 64)
	defer delete(children)

	for i in data.from..<data.to + 1 {
		task := cast(^Task) mode_panel.children[i]

		// if the task has the same parent push to sort list
		if task.visible_parent == data.task_current.visible_parent {
			append(&sort_list, Task_Line {
				task,
				-1, 
				0,
			})
		} else {
			// set child location info per pushed child on the last task
			last := &sort_list[len(sort_list) - 1]
			child_index := i32(len(children))
			if last.children_from == -1 {
				last.children_from = child_index
			}
			last.children_to = child_index
			append(&children, task)
		}
	}

	cmp :: proc(a, b: Task_Line) -> bool {
		return a.task.state < b.task.state
	}

	slice.sort_by(sort_list[:], cmp)

	// prepare reversal
	out := Undo_Item_Task_Sort_Original {
		data.task_current,
		data.from, 
		data.to,
	}
	count := (data.to - data.from) + 1
	bytes := undo_push(
		manager, 
		undo_task_sort_original, 
		&out, 
		size_of(Undo_Item_Task_Sort_Original) + count * size_of(^Task),
	)
	// actually save the data
	bytes_root := cast(^^Task) &bytes[size_of(Undo_Item_Task_Sort_Original)]
	storage := mem.slice_ptr(bytes_root, count)
	for i in 0..<count {
		storage[i] = cast(^Task) mode_panel.children[i + data.from]
	}

	insert_offset: int
	for i in 0..<len(sort_list) {
		line := sort_list[i]
		index := data.from + i + insert_offset
		mode_panel.children[index] = line.task

		if line.children_from != -1 {
			local_index := index + 1
			// fmt.eprintln("line", line.children_from, line.children_to)

			for j in line.children_from..<line.children_to + 1 {
				mode_panel.children[local_index] = children[j]
				local_index += 1
				insert_offset += 1
				// fmt.eprintln("jjj", j)
			}
		}
	}

	element_repaint(mode_panel)
}

Undo_Item_Task_Sort_Original :: struct {
	task_current: ^Task,
	from, to: int,
	// ^Task data upcoming
}

undo_task_sort_original :: proc(manager: ^Undo_Manager, item: rawptr) {
	data := cast(^Undo_Item_Task_Sort_Original) item

	bytes_root := cast(^^Task) (uintptr(item) + size_of(Undo_Item_Task_Sort_Original))
	count := data.to - data.from + 1
	storage := mem.slice_ptr(bytes_root, count)	

	// revert to unsorted data
	for i in 0..<count {
		mode_panel.children[i + data.from] = storage[i]
	}

	out := Undo_Item_Task_Sort {
		data.task_current,
		data.from,
		data.to,
	}
	undo_push(manager, undo_task_sort, &out, size_of(Undo_Item_Task_Sort))
}

// idea:
// gather all children to be sorted [from:to] without sub children
// sort based on wanted properties
// replace existing tasks by new result + offset by sub children
todool_sort_locals :: proc(du: u32) {
	if task_head == -1 {
		return
	}

	task_tail = task_head
	task_current := tasks_visible[task_head]

	// skip high level
	from, to: int
	if task_current.visible_parent == nil {
		from = 0
		to = len(mode_panel.children) - 1
		// return
	} else {
		from, to = task_children_range(task_current.visible_parent)

		// skip invalid 
		if from == -1 || to == -1 {
			return
		}
	}

	manager := mode_panel_manager_scoped()
	task_head_tail_push(manager)
	
	item := Undo_Item_Task_Sort {
		task_current,
		from,
		to,
	}
	undo_task_sort(manager, &item)

	// update info and reset to last position
	task_set_children_info()
	task_set_visible_tasks()
	task_head = task_current.visible_index
	task_tail = task_head
}

todool_scale :: proc(amt: f32) {
	scaling_inc(amt)
	element_repaint(mode_panel)
}