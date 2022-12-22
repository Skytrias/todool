package src

import "core:unicode"
import "core:fmt"
import "core:slice"
import "core:time"
import "core:io"
import "core:strings"
import "core:strconv"
import "core:mem"
import "core:bytes"
import "core:log"
import "core:os"
import "core:encoding/json"
import "core:math"
import "core:math/bits"
import "core:runtime"
import "../cutf8"

save_loc: runtime.Source_Code_Location

SIGNATURE_LENGTH :: 8 * size_of(u8)
SAVE_SIGNATURE_TODOOL := [8]u8 { 'T', 'O', 'D', 'O', 'O', 'L', '_', '_' }
SAVE_SIGNATURE_VIEWS := [8]u8 { 'V', 'I', 'E', 'W', 'S', '_', '_', '_' }
SAVE_SIGNATURE_TAGS := [8]u8 { 'T', 'A', 'G', 'S', '_', '_', '_', '_' }
SAVE_SIGNATURE_DATA := [8]u8 { 'D', 'A', 'T', 'A', '_', '_', '_', '_' }
SAVE_SIGNATURE_FILTER := [8]u8 { 'F', 'I', 'L', 'T', 'E', 'R', '_', '_' }
SAVE_SIGNATURE_FLAGS := [8]u8 { 'F', 'L', 'A', 'G', 'S', '_', '_', '_' }

Save_Flag :: enum u8 {
	// simple
	Bookmark,
	Seperator,

	Image_Path, // u16be string len + [N]u8 byte data
	Link_Path, // u16be string len + [N]u8 byte data
	Timestamp, // i64be included = time.Time
	Folded, // NO data included u16be length + N * size_of(u32be)
}
Save_Flags :: bit_set[Save_Flag]

buffer_write_color :: proc(buffer: ^bytes.Buffer, color: Color) -> (err: io.Error) {
	// CHECK is this safe endianness?
	color := color
	bytes.buffer_write_ptr(buffer, &color, size_of(u32)) or_return
	return
}

buffer_write_string_u16 :: proc(buffer: ^bytes.Buffer, text: string) -> (err: io.Error) {
	count := u16be(len(text))
	bytes.buffer_write_ptr(buffer, &count, size_of(u16be)) or_return
	// TODO is this utf8 safe?
	bytes.buffer_write_string(buffer, text[:count]) or_return
	return
}

buffer_write_string_u8 :: proc(buffer: ^bytes.Buffer, text: string) -> (err: io.Error) {
	count := u8(len(text))
	bytes.buffer_write_byte(buffer, count) or_return
	// TODO is this utf8 safe?
	bytes.buffer_write_string(buffer, text[:count]) or_return
	return
}

// Header for a byte blob
Save_Header :: struct {
	signature: [8]u8,
	version: u8,
	block_size: u32be, // region that data ends at
}

Save_RW_Error :: enum {
	None,
	Wrong_File_Format,
	Unexpected_Signature,
	Unsupported_Version,
	No_Space_Advance, // + loc
	
	Block_Not_Fully_Read,
	File_Not_Fully_Read,
}

Save_Error :: union #shared_nil {
	Save_RW_Error,
	io.Error,
}

save_push_header :: proc(
	buffer: ^bytes.Buffer, 
	signature: [8]u8,
	version: u8,
) -> (block_start: int, block_size: ^u32be, err: Save_Error) {
	header := Save_Header {
		signature = signature,
		version = version,
	}

	old := len(buffer.buf)
	bytes.buffer_write_ptr(buffer, &header, size_of(Save_Header)) or_return
	block_start = len(buffer.buf)
	block_size = cast(^u32be) &buffer.buf[old + int(offset_of(Save_Header, block_size))]

	return
}

load_header :: proc(data: ^[]u8, signature: [8]u8) -> (
	version: u8,
	output: []byte, 
	err: Save_Error,
) {
	// stop if no space is left
	if len(data) == 0 {
		err = .Unexpected_Signature
		return
	}

	temp := data^
	header: Save_Header
	advance_ptr(data, &header, size_of(Save_Header)) or_return

	if header.signature != signature {
		// reset to old position
		data^ = temp
		err = .Unexpected_Signature
		return
	}

	version = header.version
	output = advance_slice(data, int(header.block_size)) or_return
	return
}

save_tags :: proc(buffer: ^bytes.Buffer) -> (err: Save_Error) {
	block_start, block_size := save_push_header(buffer, SAVE_SIGNATURE_TAGS, 1) or_return
	defer block_size^ = u32be(len(buffer.buf) - block_start)

	// write out small string content 
	for i in 0..<8 {
		buffer_write_string_u8(buffer, ss_string(sb.tags.names[i])) or_return
	}	

	// write out colors
	for i in 0..<8 {
		buffer_write_color(buffer, theme.tags[i]) or_return
	}

	return
}

save_views :: proc(buffer: ^bytes.Buffer) -> (err: Save_Error) {
	block_start, block_size := save_push_header(buffer, SAVE_SIGNATURE_VIEWS, 1) or_return
	defer block_size^ = u32be(len(buffer.buf) - block_start)
	
	// mode count
	bytes.buffer_write_byte(buffer, u8(len(Mode)))
	bytes.buffer_write_byte(buffer, u8(app.mmpp.mode))
	save_scale := u8(math.round(TASK_SCALE * 100))
	// fmt.eprintln("+++", save_scale, TASK_SCALE)
	bytes.buffer_write_byte(buffer, save_scale)

	// camera positions
	temp: i32be
	for mode in Mode {
		cam := &app.mmpp.cam[mode]
		temp = i32be(cam.offset_x)
		bytes.buffer_write_ptr(buffer, &temp, size_of(i32be))
		temp = i32be(cam.offset_y)
		bytes.buffer_write_ptr(buffer, &temp, size_of(i32be))
	}

	return		
}

Save_Task_V1 :: struct {
	indentation: u8,
	state: u8,
	tags: u8,
	text_length: u8,
}

save_data :: proc(
	buffer: ^bytes.Buffer, 
	removed: []int,
	valid_length: int,
) -> (err: Save_Error) {
	block_start, block_size := save_push_header(buffer, SAVE_SIGNATURE_DATA, 1) or_return
	defer block_size^ = u32be(len(buffer.buf) - block_start)

	// write count
	count := u32be(valid_length)
	bytes.buffer_write_ptr(buffer, &count, size_of(u32be)) or_return

	// write all lines
	t: Save_Task_V1
	removed_index: int
	for list_index in 0..<valid_length {
		task := &app.pool.list[list_index]

		// dont add any removed line
		if removed_index < len(removed) && removed[removed_index] == list_index {
			// skip removed data
			bytes.buffer_write_byte(buffer, 1) or_return
			removed_index += 1
		} else {
			bytes.buffer_write_byte(buffer, 0) or_return

			t = {
				u8(task.indentation),
				u8(task.state),
				task.tags,
				task.box.ss.length,
			}
			// write blob
			bytes.buffer_write_ptr(buffer, &t, size_of(Save_Task_V1)) or_return
			
			// write textual content
			bytes.buffer_write(buffer, task.box.ss.buf[:task.box.ss.length]) or_return
		}
	}

	return		
}

save_filter :: proc(buffer: ^bytes.Buffer) -> (err: Save_Error) {
	block_start, block_size := save_push_header(buffer, SAVE_SIGNATURE_FILTER, 1) or_return
	defer block_size^ = u32be(len(buffer.buf) - block_start)

	// write count
	head := i64be(app.task_head)
	bytes.buffer_write_ptr(buffer, &head, size_of(i64be)) or_return
	
	tail := i64be(app.task_tail)
	bytes.buffer_write_ptr(buffer, &tail, size_of(i64be)) or_return

	// write count
	count := u32be(len(app.pool.filter))
	bytes.buffer_write_ptr(buffer, &count, size_of(u32be)) or_return

	for list_index in app.pool.filter {
		index := u32be(list_index)
		bytes.buffer_write_ptr(buffer, &index, size_of(u32be)) or_return
	}	

	return
}

// line_index + bit_set of common flags without associated data
save_flags :: proc(
	buffer: ^bytes.Buffer, 
	removed: []int,
	valid_length: int,
) -> (err: Save_Error) {
	block_start, block_size := save_push_header(buffer, SAVE_SIGNATURE_FLAGS, 1) or_return
	defer block_size^ = u32be(len(buffer.buf) - block_start)

	flag_count: ^u32be
	{
		old := len(buffer.buf)
		resize(&buffer.buf, old + size_of(u32be))
		flag_count = cast(^u32be) &buffer.buf[old]
	}

	removed_index: int
	for list_index in 0..<valid_length {
		task := &app.pool.list[list_index]
		flags: Save_Flags

		if removed_index < len(removed) && removed[removed_index] == list_index {
			// skip removed data
			removed_index += 1
			continue
		}

		if task_bookmark_is_valid(task) {
			incl(&flags, Save_Flag.Bookmark)
		}
		if task_seperator_is_valid(task) {
			incl(&flags, Save_Flag.Seperator)
		}
		if image_display_has_path(task.image_display) {
			incl(&flags, Save_Flag.Image_Path)
		}
		if task_link_is_valid(task) {
			incl(&flags, Save_Flag.Link_Path)
		}
		if task_time_date_is_valid(task) {
			incl(&flags, Save_Flag.Timestamp)
		}
		if task.filter_folded {
			incl(&flags, Save_Flag.Folded)
		}

		// in case any flag was set, write them linearly in mem
		if flags != {} {
			index := u32be(list_index)
			bytes.buffer_write_ptr(buffer, &index, size_of(u32be)) or_return
			bytes.buffer_write_byte(buffer, transmute(u8) flags) or_return

			// NOTE dont change the order of writes upcoming
			if .Image_Path in flags {
				buffer_write_string_u16(buffer, image_path(task.image_display.img)) or_return
			}
			if .Link_Path in flags {
				buffer_write_string_u16(buffer, strings.to_string(task.button_link.builder)) or_return
			}
			if .Timestamp in flags {
				out := i64be(task.time_date.stamp._nsec)
				bytes.buffer_write_ptr(buffer, &out, size_of(i64be)) or_return
			}
			if .Folded in flags {
				count := u32be(len(task.filter_children))
				bytes.buffer_write_ptr(buffer, &count, size_of(u32be)) or_return

				temp: u32be
				for i in 0..<count {
					temp = u32be(task.filter_children[i])
					bytes.buffer_write_ptr(buffer, &temp, size_of(u32be)) or_return
				}
			}

			flag_count^ += 1
		}
	}

	return
}

save_all :: proc(file_path: string) -> (err: Save_Error) {
	buffer: bytes.Buffer
	bytes.buffer_init_allocator(&buffer, 0, mem.Megabyte * 10)
	defer bytes.buffer_destroy(&buffer)

	// write start signature
	bytes.buffer_write(&buffer, SAVE_SIGNATURE_TODOOL[:]) or_return
	
	save_tags(&buffer) or_return
	save_views(&buffer) or_return

	collect_sorted_removed_list :: proc() -> (removed: []int, valid_length: int) {
		Empty :: struct {}

		// gather all removed lines in a non duplicate map
		list := make(map[int]Empty, 256, context.temp_allocator)
		for task, list_index in app.pool.list {
			if task.removed {
				list[list_index] = {}

				// gather even children from tasks that were removed
				// as they are also removed for saving
				for child_index in task.filter_children {
					list[child_index] = {}
				}
			}
		}

		// get the non duplicate indicies sorted
		removed, _ = slice.map_keys(list, context.temp_allocator)
		slice.sort(removed[:])

		// find lowest removed node
		last_removed: bool
		removed_index := len(removed) - 1
		valid_length = len(app.pool.list)
		for list_index := len(app.pool.list) - 1; list_index >= 0; list_index -= 1 {
			if removed_index >= 0 && removed[removed_index] == list_index {
				last_removed = true
				removed_index -= 1
			} else {
				if last_removed {
					valid_length = list_index + 1
				}

				// stop even if length wasnt set
				break
			}
		}
		
		// if valid_length != 0 {
		// 	t := app.pool.list[valid_length - 1]
		// 	fmt.eprintln("SEE", t.removed, valid_length)
		// }

		return
	}
	
	removed, valid_length := collect_sorted_removed_list()	
	save_data(&buffer, removed, valid_length) or_return
	save_flags(&buffer, removed, valid_length) or_return
	save_filter(&buffer) or_return

	ok := gs_write_safely(file_path, buffer.buf[:])
	if !ok {
		err = .Invalid_Write
	}

	return
}

// advance and set the data 
advance_ptr :: proc(data: ^[]u8, dst: rawptr, size: int, loc := #caller_location) -> (err: Save_Error) {
	if len(data) < size {
		err = .No_Space_Advance
		save_loc = loc
		return
	}

	mem.copy(dst, &data[0], size)
	data^ = data[size:]
	return
}

// advance and output a slice for the advanced size
advance_slice :: proc(data: ^[]u8, size: int, loc := #caller_location) -> (output: []u8, err: Save_Error) {
	if len(data) < size {
		err = .No_Space_Advance
		save_loc = loc
		return
	}

	output = data[:size]
	data^ = data[size:]
	return
}

// advance and set the data 
advance_string_u16 :: proc(data: ^[]u8, loc := #caller_location) -> (output: string, err: Save_Error) {
	length: u16be
	advance_ptr(data, &length, size_of(u16be), loc) or_return
	content := advance_slice(data, int(length), loc) or_return
	output = string(content)
	return
}

// check for done block 
advance_check_done :: proc(data: []u8) -> (err: Save_Error) {
	if len(data) != 0 {
		err = .Block_Not_Fully_Read
	}

	return
}

// stop when unexpected signature is hit
load_optional :: proc(input: Save_Error) -> Save_Error {
	if input == .Unexpected_Signature {
		return nil
	}

	return input
}

load_tags :: proc(data: ^[]u8) -> (err: Save_Error) {
	version, input := load_header(data, SAVE_SIGNATURE_TAGS) or_return

	switch version {
		case 1: {
			string_length: u8
			for i in 0..<8 {
				advance_ptr(&input, &string_length, size_of(u8)) or_return
				string_bytes := advance_slice(&input, size_of(u8) * int(string_length)) or_return
				ss := sb.tags.names[i]
				ss_set_string(ss, transmute(string) string_bytes)
			}

			color: u32
			for i in 0..<8 {
				advance_ptr(&input, &color, size_of(u32)) or_return
				theme.tags[i] = transmute(Color) color
			}
		}

		case: err = .Unsupported_Version
	}

	advance_check_done(input) or_return
	return
}

load_views :: proc(data: ^[]u8) -> (err: Save_Error) {
	version, input := load_header(data, SAVE_SIGNATURE_VIEWS) or_return

	switch version {
		case 1: {
			count: u8
			advance_ptr(&input, &count, size_of(u8)) or_return
			mode: u8
			advance_ptr(&input, &mode, size_of(u8)) or_return
			app.mmpp.mode = Mode(mode)
			scale: u8
			advance_ptr(&input, &scale, size_of(u8)) or_return
			load_scale := f32(scale) / 100
			// fmt.eprintln("---", scale, load_scale)
			scaling_set(SCALE, load_scale)

			temp: i32be
			for i in 0..<count {
				cam := &app.mmpp.cam[Mode(i)]
				advance_ptr(&input, &temp, size_of(i32be)) or_return
				cam_set_x(cam, int(temp))
				advance_ptr(&input, &temp, size_of(i32be)) or_return
				cam_set_y(cam, int(temp))
			}
		}

		case: err = .Unsupported_Version
	}

	advance_check_done(input) or_return
	return
}

load_data :: proc(data: ^[]u8) -> (err: Save_Error) {
	version, input := load_header(data, SAVE_SIGNATURE_DATA) or_return

	switch version {
		case 1: {
			count: u32be
			advance_ptr(&input, &count, size_of(u32be)) or_return

			for i in 0..<count {
				skip: b8
				advance_ptr(&input, &skip, size_of(b8)) or_return

				// init data but put it on the free list
				if skip {
					// fmt.eprintln("\tFREED at", i)
					task_init(0, "", false)
					
					// append to free list
					append(&app.pool.free_list, int(i))
					continue
				}

				// init data as expected
				t: Save_Task_V1
				advance_ptr(&input, &t, size_of(Save_Task_V1)) or_return

				string_bytes := advance_slice(&input, int(t.text_length)) or_return
				spell_check_mapping_words_add(string(string_bytes))

				// push to the pool
				task := task_init(int(t.indentation), string(string_bytes), false)
				task.tags = t.tags
				task.state = Task_State(t.state)
			}

			// fmt.eprintln("FREE LIST", app.pool.free_list)
		}

		case: err = .Unsupported_Version
	}

	advance_check_done(input) or_return
	return
}

load_filter :: proc(data: ^[]u8) -> (err: Save_Error) {
	version, input := load_header(data, SAVE_SIGNATURE_FILTER) or_return

	switch version {
		case 1: {
			head: i64be
			advance_ptr(&input, &head, size_of(i64be)) or_return
			app.task_head = int(head)
			
			tail: i64be
			advance_ptr(&input, &tail, size_of(i64be)) or_return
			app.task_tail = int(tail)

			count: u32be
			advance_ptr(&input, &count, size_of(u32be)) or_return

			index: u32be
			for i in 0..<count {
				advance_ptr(&input, &index, size_of(u32be)) or_return
				append(&app.pool.filter, int(index))
			}
		}
		
		case: err = .Unsupported_Version
	}

	advance_check_done(input) or_return
	return
}

load_flags :: proc(data: ^[]u8) -> (err: Save_Error) {
	version, input := load_header(data, SAVE_SIGNATURE_FLAGS) or_return

	switch version {
		case 1: {
			count: u32be
			advance_ptr(&input, &count, size_of(u32be)) or_return

			list_index: u32be 
			flags: Save_Flags
			for i in 0..<count {
				advance_ptr(&input, &list_index, size_of(u32be)) or_return
				advance_ptr(&input, &flags, size_of(u8)) or_return
				task := app_task_list(int(list_index))

				if .Bookmark in flags {
					task_set_bookmark(task, true)
				}
				if .Seperator in flags {
					task_set_seperator(task, true)
				}

				// NOTE advance dependant should not go out of order!
				if .Image_Path in flags {
					path := advance_string_u16(&input) or_return
					handle := image_load_push(path)
					task_set_img(task, handle)
				}
				if .Link_Path in flags {
					link := advance_string_u16(&input) or_return
					task_set_link(task, link)
				}
				if .Timestamp in flags {
					task_set_time_date(task)
					value: i64be
					advance_ptr(&input, &value, size_of(i64be)) or_return
					task.time_date.stamp = time.Time { i64(value) }
				}
				if .Folded in flags {
					task.filter_folded = true
					count: u32be
					advance_ptr(&input, &count, size_of(u32be)) or_return
					resize(&task.filter_children, int(count))

					temp: u32be
					for i in 0..<count {
						advance_ptr(&input, &temp, size_of(u32be)) or_return
						task.filter_children[i] = int(temp)
					}
				}
			}
		}

		case: err = .Unsupported_Version
	}

	advance_check_done(input) or_return
	return
}

load_all :: proc(data: []u8) -> (err: Save_Error) {
	data := data

	signature := advance_slice(&data, SIGNATURE_LENGTH) or_return

	if mem.compare(signature, SAVE_SIGNATURE_TODOOL[:]) != 0 {
		err = .Wrong_File_Format
		return
	}

	tasks_load_reset()

	load_optional(load_tags(&data)) or_return
	load_optional(load_views(&data)) or_return
	load_optional(load_data(&data)) or_return
	load_optional(load_flags(&data)) or_return
	load_optional(load_filter(&data)) or_return

	if len(data) != 0 {
		err = .File_Not_Fully_Read
	}

	return
}

//////////////////////////////////////////////
// json save file
//////////////////////////////////////////////

Misc_Save_Load :: struct {
	// not shown directly to the user,
	hidden: struct {
		scale: f32,
		fps: f32,

		font_regular_path: string,
		font_bold_path: string,

		window_x: int, 
		window_y: int,
		window_width: int,
		window_height: int,	
		window_fullscreen: bool,
		hide_statusbar: bool,
		hide_menubar: bool,
		window_opacity: f32,
		animation_speed: f32,

		last_save_location: string,
	},

	options: struct {
		tab: f32,
		autosave: bool,
		invert_x: bool,
		invert_y: bool,
		uppercase_word: bool,
		use_animations: bool,
		bordered: bool,
		volume: f32,
		gap_horizontal: f32,
		gap_vertical: f32,
		kanban_width: f32,
		task_margin: f32,
		vim: bool,
		spell_checking: bool,
		
		progressbar_show: bool,
		progressbar_percentage: bool,
		progressbar_hover_only: bool,

		line_highlight_use: bool,
		line_highlight_alpha: f32,
	},

	pomodoro: struct {
		index: int,

		work: int,
		short_break: int,
		long_break: int,

		stopwatch_running: bool,
		stopwatch_acuumulation: int, // time.Duration 
	},

	power_mode: struct {
		show: bool,

		particle_lifetime: f32,
		particle_alpha_scale: f32,
		particle_colored: bool,

		screenshake_use: bool,
		screenshake_amount: f32,
		screenshake_lifetime: f32,
	},

	caret: struct {
		use_animations: bool,
		use_motion: bool,
		use_alpha: bool,
	},

	statistics: struct {
		accumulated: int, // time.Duration
		work_goal: int,
	},

	theme: Theme_Save_Load,

	custom_sounds: struct {
		timer_start: string,
		timer_stop: string,
		timer_resume: string,
		timer_ended: string,
	},

	archive: struct {
		head: int,
		tail: int,
		data: []string,
	},

	search: struct {
		pattern: string,
		case_insensitive: bool,
	},
}

json_save_misc :: proc(path: string) -> bool {
	arena, _ := arena_scoped(mem.Megabyte * 10)
	context.allocator = mem.arena_allocator(&arena)

	// create theme save data
	theme_save: Theme_Save_Load
	{
		// NOTE dumb but it works :D
		theme_save.background = transmute([3]u32) theme.background
		theme_save.panel = transmute([2]u32) theme.panel

		theme_save.text_default = transmute(u32) theme.text_default
		theme_save.text_blank = transmute(u32) theme.text_blank
		theme_save.text_good = transmute(u32) theme.text_good
		theme_save.text_bad = transmute(u32) theme.text_bad
		theme_save.text_date = transmute(u32) theme.text_date
		theme_save.text_link = transmute(u32) theme.text_link

		theme_save.shadow = transmute(u32) theme.shadow

		theme_save.caret = transmute(u32) theme.caret
		theme_save.caret_selection = transmute(u32) theme.caret_selection
	}

	pomodoro_diff := time.stopwatch_duration(pomodoro.stopwatch)
	
	// archive data
	// NOTE always skip scrollbar
	archive_children := panel_children(sb.archive.buttons)
	archive_data := make([]string, len(archive_children))
	for i in 0..<len(archive_children) {
		button := cast(^Archive_Button) archive_children[i]
		archive_data[i] = strings.to_string(button.builder)
	}

	window_x, window_y := window_get_position(app.window_main)
	window_width := app.window_main.width
	window_height := app.window_main.height

	// adjust by window border
	{
		t, l, b, r := window_border_size(app.window_main)
		// fmt.eprintln("BORDER", t, l, b, r)
		// fmt.eprintln("WINDOW DIMS BEFORE", window_x, window_y, window_width, window_height)
		window_y -= t
		window_x -= l
		window_width += r
		window_height += b
		// fmt.eprintln("WINDOW DIMS AFTER", window_x, window_y, window_width, window_height)
	}

	value := Misc_Save_Load {
		hidden = {
			scale = SCALE,
			fps = FPS,

			font_regular_path = gs.font_regular_path,
			font_bold_path = gs.font_bold_path,

			window_x = window_x,
			window_y = window_y,
			window_width = window_width,
			window_height = window_height,
			window_fullscreen = app.window_main.fullscreened,
			hide_statusbar = sb.options.checkbox_hide_statusbar.state,
			hide_menubar = sb.options.checkbox_hide_menubar.state,
			window_opacity = window_opacity_get(app.window_main),
			animation_speed = sb.options.slider_animation_speed.position,

			last_save_location = strings.to_string(app.last_save_location),
		},

		options = {
			visuals_tab(),
			options_autosave(),
			sb.options.checkbox_invert_x.state,
			sb.options.checkbox_invert_y.state,
			options_uppercase_word(),
			visuals_use_animations(),
			options_bordered(),
			options_volume(),
			sb.options.slider_gap_horizontal.position,
			sb.options.slider_gap_vertical.position,
			sb.options.slider_kanban_width.position,
			sb.options.slider_task_margin.position,
			options_vim_use(),
			options_spell_checking(),

			// progressbar
			progressbar_show(),
			progressbar_percentage(),
			progressbar_hover_only(),

			// line highlights
			sb.options.checkbox_line_highlight_use.state,
			sb.options.slider_line_highlight_alpha.position,
		},

		pomodoro = {
			pomodoro.index,

			int(pomodoro_time_index(0)),
			int(pomodoro_time_index(1)),
			int(pomodoro_time_index(2)),

			pomodoro.stopwatch.running,
			int(pomodoro_diff),
		},

		power_mode = {
			pm_show(),
			sb.options.pm.p_lifetime.position,
			sb.options.pm.p_alpha_scale.position,
			pm_particle_colored(),
			pm_screenshake_use(),
			sb.options.pm.s_amount.position,
			sb.options.pm.s_lifetime.position,
		},

		statistics = {
			int(pomodoro.accumulated),
			int(sb.stats.slider_work_today.position * 24),
		},

		theme = theme_save,

		// just write paths in that might have been set
		custom_sounds = {
			gs.sound_paths[.Timer_Start],
			gs.sound_paths[.Timer_Stop],
			gs.sound_paths[.Timer_Resume],
			gs.sound_paths[.Timer_Ended],
		},

		archive = {
			sb.archive.head,
			sb.archive.tail,
			archive_data,
		},

		search = {
			ss_string(&search.text_box.ss),
			search.case_insensitive,
		},

		caret = {
			caret_animate(),
			caret_motion(),
			caret_alpha(),
		},
	}

	result, err := json.marshal(
		value, 
		{
			spec = .MJSON,
			pretty = true,
			write_uint_as_hex = true,
			mjson_keys_use_equal_sign = true,
		},
	)

	if err == nil {
		file_path := bpath_temp(path)
		return gs_write_safely(file_path, result[:])
	}

	return false
}

json_load_misc :: proc(path: string) -> bool {
	bytes := bpath_file_read(path) or_return
	defer delete(bytes)

	arena, _ := arena_scoped(mem.Megabyte * 10)
	misc: Misc_Save_Load
	err := json.unmarshal(bytes, &misc, .MJSON, mem.arena_allocator(&arena))

	if err != nil {
		log.info("JSON: Load error unmarshal", err)
		return false
	}

	// hidden
	{
		// cap to defaults
		if misc.hidden.fps >= 30 {
			FPS = clamp(misc.hidden.fps, 30, 240)
			fmt.eprintln(FPS, misc.hidden.fps)
		}

		if misc.hidden.window_width != 0 && misc.hidden.window_height != 0 {
			total_width, total_height := gs_display_total_bounds()

			w := max(misc.hidden.window_width, 200)
			h := max(misc.hidden.window_height, 200)
			// fmt.eprintln("WINDOW DIMS LOAD WH", misc.hidden.window_x, misc.hidden.window_y, w, h)
			// x := misc.hidden.window_x
			// y := misc.hidden.window_y
			// clamp window based on total display width/height
			x := min(max(misc.hidden.window_x, 0) + w, total_width) - w
			y := min(max(misc.hidden.window_y, 0) + h, total_height) - h
			// fmt.eprintln("WINDOW DIMS CLAMPED WH", x, y)

			window_set_position(app.window_main, x, y)
			window_set_size(app.window_main, w, h)
		}

		last_save_set(misc.hidden.last_save_location)

		if misc.hidden.font_regular_path != "" {
			gs.font_regular_path = strings.clone(misc.hidden.font_regular_path)
		}

		if misc.hidden.font_bold_path != "" {
			gs.font_bold_path = strings.clone(misc.hidden.font_bold_path)
		}

		if misc.hidden.window_fullscreen {
			window_fullscreen_toggle(app.window_main)
		}

		checkbox_set(sb.options.checkbox_hide_statusbar, misc.hidden.hide_statusbar)
		element_hide(statusbar.stat, misc.hidden.hide_statusbar)
		checkbox_set(sb.options.checkbox_hide_menubar, misc.hidden.hide_menubar)
		element_hide(app.task_menu_bar, misc.hidden.hide_menubar)

		opacity := misc.hidden.window_opacity == 0 ? 1 : misc.hidden.window_opacity
		slider_set(sb.options.slider_opacity, opacity)
		slider_set(sb.options.slider_animation_speed, misc.hidden.animation_speed)
	}

	// options
	slider_set(sb.options.slider_tab, misc.options.tab)
	checkbox_set(sb.options.checkbox_autosave, misc.options.autosave)
	checkbox_set(sb.options.checkbox_invert_x, misc.options.invert_x)
	checkbox_set(sb.options.checkbox_invert_y, misc.options.invert_y)
	checkbox_set(sb.options.checkbox_uppercase_word, misc.options.uppercase_word)
	checkbox_set(sb.options.checkbox_use_animations, misc.options.use_animations)
	checkbox_set(sb.options.checkbox_bordered, misc.options.bordered)
	slider_set(sb.options.slider_volume, misc.options.volume)
	slider_set(sb.options.slider_gap_horizontal, misc.options.gap_horizontal)
	slider_set(sb.options.slider_gap_vertical, misc.options.gap_vertical)
	slider_set(sb.options.slider_kanban_width, misc.options.kanban_width)
	slider_set(sb.options.slider_task_margin, misc.options.task_margin)
	checkbox_set(sb.options.checkbox_vim, misc.options.vim)
	checkbox_set(sb.options.checkbox_spell_checking, misc.options.spell_checking)
	
	// progressbar 
	checkbox_set(sb.options.checkbox_progressbar_show, misc.options.progressbar_show)
	checkbox_set(sb.options.checkbox_progressbar_percentage, misc.options.progressbar_percentage)
	checkbox_set(sb.options.checkbox_progressbar_hover_only, misc.options.progressbar_hover_only)

	// theme
	theme_load_from(misc.theme)

	// pomodoro
	pomodoro.index = misc.pomodoro.index
	slider_set(sb.stats.slider_pomodoro_work, f32(clamp(misc.pomodoro.work, 0, 60)) / 60)
	slider_set(sb.stats.slider_pomodoro_short_break, f32(clamp(misc.pomodoro.short_break, 0, 60)) / 60)
	slider_set(sb.stats.slider_pomodoro_long_break, f32(clamp(misc.pomodoro.long_break, 0, 60)) / 60)
	pomodoro.stopwatch.running = misc.pomodoro.stopwatch_running
	pomodoro.stopwatch._accumulation = time.Duration(misc.pomodoro.stopwatch_acuumulation)

	// line highlights
	checkbox_set(sb.options.checkbox_line_highlight_use, misc.options.line_highlight_use)
	slider_set(sb.options.slider_line_highlight_alpha, misc.options.line_highlight_alpha)

	// power mode
	{
		temp := &sb.options.pm	
		using temp

		if misc.power_mode != {} {
			checkbox_set(ps_show, misc.power_mode.show)
			slider_set(p_lifetime, misc.power_mode.particle_lifetime)
			slider_set(p_alpha_scale, misc.power_mode.particle_alpha_scale)
			checkbox_set(p_colored, misc.power_mode.particle_colored)
			checkbox_set(s_use, misc.power_mode.screenshake_use)
			slider_set(s_amount, misc.power_mode.screenshake_amount)
			slider_set(s_lifetime, misc.power_mode.screenshake_lifetime)
		}
	}
	
	// caret
	{
		temp := &sb.options.caret
		using temp

		if misc.caret != {} {
			checkbox_set(animate, misc.caret.use_animations)
			checkbox_set(motion, misc.caret.use_motion)
			checkbox_set(alpha, misc.caret.use_alpha)
		}
	}
	
	// statistics
	goal := clamp(misc.statistics.work_goal, 1, 24)
	sb.stats.slider_work_today.position = f32(goal) / 24.0
	pomodoro.accumulated = time.Duration(misc.statistics.accumulated)

	pomodoro.stopwatch._start_time = time.tick_now()
	
	// run everything
	if pomodoro.stopwatch.running {
		element_hide(sb.stats.button_pomodoro_reset, false)
	}

	pomodoro_label_format()
	element_repaint(app.mmpp)

	// archive
	for text, i in misc.archive.data {
		archive_push(text)
	}
	sb.archive.head = misc.archive.head
	sb.archive.tail = misc.archive.tail

	// search
	if misc.search != {} {
		ss_set_string(&search.text_box.ss, misc.search.pattern)
		search.case_insensitive = misc.search.case_insensitive
	}

	// custom sounds path setting
	sound_path_write(.Timer_Start, misc.custom_sounds.timer_start)
	sound_path_write(.Timer_Stop, misc.custom_sounds.timer_stop)
	sound_path_write(.Timer_Resume, misc.custom_sounds.timer_resume)
	sound_path_write(.Timer_Ended, misc.custom_sounds.timer_ended)

	return true
}

// CUSTOM FORMAT: 
// [SECTION]
// up = move_up 
// shift up = move_up SHIFT
keymap_save :: proc(path: string) -> bool {
	arena, _ := arena_scoped(mem.Megabyte)
	context.allocator = mem.arena_allocator(&arena)

	b := strings.builder_make(0, mem.Kilobyte * 2)

	write_content :: proc(
		b: ^strings.Builder, 
		name: string, 
		keymap: ^Keymap,
	) {
		strings.write_string(b, name)
		strings.write_byte(b, '\n')
		count: int

		for node in &keymap.combos {
			if node.command_index == -1 {
				continue
			}

			c1 := string(node.combo[:node.combo_index])
			cmd := keymap_get_command(keymap, node.command_index)

			strings.write_string(b, "\t// ")
			strings.write_string(b, cmd.comment)
			strings.write_byte(b, '\n')

			strings.write_byte(b, '\t')
			strings.write_string(b, c1)
			strings.write_string(b, " = ")
			strings.write_string(b, cmd.name)

			// write optional data
			if node.du != COMBO_EMPTY {
				if node.du >= COMBO_VALUE {
					fmt.sbprintf(b, " 0x%2x", uint(node.du - COMBO_VALUE))
				} else {
					for i in 0..<5 {
						bit := bits.bitfield_extract(node.du, uint(i), 1)
						
						if bit != 0x00 {
							stringified := du_to_string(i)
							strings.write_byte(b, ' ')
							strings.write_string(b, stringified)
						}
					}
				}
			}

			strings.write_byte(b, '\n')

			if count > 5 {
				count = 0
				strings.write_byte(b, '\n')
			} else {
				count += 1
			}
		}

		strings.write_string(b, "[END]\n")
	}

	write_content(&b, "[BOX]", &app.window_main.keymap_box)
	strings.write_byte(&b, '\n')
	write_content(&b, "[TODOOL]", &app.window_main.keymap_custom)
	strings.write_byte(&b, '\n')
	write_content(&b, "[VIM-NORMAL]", &app.keymap_vim_normal)
	strings.write_byte(&b, '\n')
	write_content(&b, "[VIM-INSERT]", &app.keymap_vim_insert)

	file_path := bpath_temp(path)
	ok := gs_write_safely(file_path, b.buf[:])
	if !ok {
		log.error("SAVE: Keymap save failed")
		return false
	}

	return true
}

keymap_load :: proc(path: string) -> bool {
	bytes := bpath_file_read(path) or_return
	defer delete(bytes)

	section_read :: proc(
		keymap: ^Keymap,
		content: ^string, 
		section: string, 
	) -> (ok: bool) {
		found_section: bool
		du: u32
		du_index: int
		command: string

		for line in strings.split_lines_iterator(content) {
			// end reached for the section
			if line == "[END]" {
				break
			}

			// TODO optimize to auto detect combo / command / du sections

			if !found_section {
				// can skip empty lines
				if line == section {
					found_section = true
				}
			} else {
				trimmed := strings.trim_space(line)

				// skip comments
				if len(trimmed) == 0 {
					continue
				} else if len(trimmed) > 1 {
					if trimmed[0] == '/' && trimmed[1] == '/' {
						continue
					}
				}

				head, _, tail := strings.partition(trimmed, " = ")
				if head != "" {
					du = 0x00
					du_index = 0
					command_du := tail

					for text in combo_iterate(&command_du) {
						if du_index == 0 {
							command = text
						} else {
							du_res := du_from_string(text)

							// interpret data uint value
							if du_res != COMBO_EMPTY {
								du |= du_res
							} else {
								if val, ok := strconv.parse_uint(text); ok {
									du = u32(val + COMBO_VALUE)
								} else {

								}
							}
						}

						du_index += 1
					}

					keymap_push_combo(keymap, head, command, du)
				}
			}
		}

		ok = found_section
		return
	}

	content := string(bytes)
	section_read(&app.window_main.keymap_box, &content, "[BOX]") or_return
	section_read(&app.window_main.keymap_custom, &content, "[TODOOL]") or_return
	section_read(&app.keymap_vim_normal, &content, "[VIM-NORMAL]") or_return
	section_read(&app.keymap_vim_insert, &content, "[VIM-INSERT]") or_return

	keymap_force_push_latest()

	return true
}