package src

import "core:unicode"
import "core:fmt"
import "core:slice"
import "core:time"
import "core:io"
import "core:strings"
import "core:mem"
import "core:bytes"
import "core:log"
import "core:os"
import "core:encoding/json"
import "../cutf8"

/* 
TODOOL SAVE FILE FORMAT - currently *uncompressed*

file_signature: "TODOOLFF"
version: [8]u8 -> version number as a string "00.02.00"

header: 
	block_size: u32be
	
	block read into struct -> based on block_size
		Version "00.02.00":
			task_head: u32be -> head line
			task_tail: u32be -> tail line
			camera_offset_x: i32be,
			camera_offset_y: i32be,
			task_count: u32be -> how many "task lines" to read
			task_bytes_min: u16be -> size to read per task line in memory

task line: atleast "task_bytes_min" big
	Version "00.02.00":
		indentation: u8 -> indentation used, capped to 255
		folded: u8 -> task folded
		state: u8 -> task state
		tags: u8 -> task tags, NO STRING CONTENT!
		text_size: u16be -> text content amount to read
		text_content: [N]u8

// hold *N* task lines
body: 
	read task line by line -> read opt data till end 

// Rest of the bytes after body will be read as opt data!
// holds *N* Task Line index + additional data
opt data: 
	line_index: u32be
	
	Save_Tag enum -> u8
*/

// NOTE should only increase, mark things as deprecated!
Save_Tag :: enum u8 {
	None, // Empty flag
	Finished, // Finished reading all tags + tag data
	
	Folded, // NO data included
	Bookmark, // NO data included
	Image_Path, // u16be string len + [N]u8 byte data
}

bytes_file_signature := [8]u8 { 'T', 'O', 'D', 'O', 'O', 'L', 'F', 'F' }

buffer_write_type :: proc(b: ^bytes.Buffer, type: $T) -> (err: io.Error) {
	// NOTE could use pointer ^T instead?
	type := type
	byte_slice := mem.byte_slice(&type, size_of(T))
	bytes.buffer_write(b, byte_slice) or_return
	return
}

buffer_write_builder :: proc(b: ^bytes.Buffer, builder: strings.Builder) -> (err: io.Error) {
	count := u16be(len(builder.buf))
	buffer_write_type(b, count) or_return
	bytes.buffer_write_string(b, strings.to_string(builder)) or_return
	return
}

buffer_write_string :: proc(b: ^bytes.Buffer, text: string) -> (err: io.Error) {
	count := u16be(len(text))
	buffer_write_type(b, count) or_return
	bytes.buffer_write_string(b, text) or_return
	return
}

editor_save :: proc(file_path: string) -> (err: io.Error) {
	buffer: bytes.Buffer
	bytes.buffer_init_allocator(&buffer, 0, mem.Megabyte)
	defer bytes.buffer_destroy(&buffer)

	// signature
	bytes.buffer_write_ptr(&buffer, &bytes_file_signature[0], 8) or_return
	// NOTE 8 bytes only
	version := "00.02.00"
	bytes.buffer_write_ptr(&buffer, raw_data(version), 8) or_return

	// current version structs
	Save_Header :: struct #packed {
		task_head: u32be,
		task_tail: u32be,
		// ONLY VALID FOR THE SAME WINDOW SIZE
		camera_offset_x: i32be,
		camera_offset_y: i32be,
		task_count: u32be,
		task_bytes_min: u16be,
	}

	Save_Task :: struct #packed {
		indentation: u8,
		state: u8,
		tags: u8,
		text_size: u16be,
		// N text content comes after this
	}

	// header block
	header_size := u32be(size_of(Save_Header))
	buffer_write_type(&buffer, header_size) or_return
	
	cam := mode_panel_cam()
	header := Save_Header {
		u32be(task_head),
		u32be(task_tail),
		i32be(cam.offset_x),
		i32be(cam.offset_y),
		u32be(len(mode_panel.children)),
		size_of(Save_Task),
	}
	buffer_write_type(&buffer, header) or_return
	
	// write all lines
	for child in mode_panel.children {
		task := cast(^Task) child
		t := Save_Task {
			u8(task.indentation),
			u8(task.state),
			u8(task.tags),
			u16be(len(task.box.builder.buf)),
		}
		buffer_write_type(&buffer, t) or_return
		bytes.buffer_write_string(&buffer, strings.to_string(task.box.builder)) or_return
	}

	// write line to buffer if it doesnt exist yet
	opt_write_line :: proc(buffer: ^bytes.Buffer, state: ^bool, index: int) -> (err: io.Error) {
		if !state^ {
			buffer_write_type(buffer, u32be(index)) or_return
			state^ = true 
		}

		return
	}

	// helper to write tag
	opt_write_tag :: proc(buffer: ^bytes.Buffer, tag: Save_Tag) -> (err: io.Error) {
		bytes.buffer_write_byte(buffer, transmute(u8) tag) or_return
		return
	}

	// write opt data
	for child, i in mode_panel.children {
		task := cast(^Task) child
		line_written: bool

		// look for opt data
		if task.bookmarked {
			opt_write_line(&buffer, &line_written, i) or_return
			opt_write_tag(&buffer, .Bookmark) or_return
		}

		if task.folded {
			opt_write_line(&buffer, &line_written, i) or_return
			opt_write_tag(&buffer, .Folded) or_return			
		}

		if image_display_has_content(task.image_display) {
			opt_write_line(&buffer, &line_written, i) or_return
			opt_write_tag(&buffer, .Image_Path) or_return
			buffer_write_string(&buffer, task.image_display.img.cloned_path) or_return
		}

		// write finish flag
		if line_written {
			opt_write_tag(&buffer, .Finished) or_return
		}
	}

	ok := gs_write_safely(file_path, buffer.buf[:])
	if !ok {
		err = .Invalid_Write
	}

	return 
}

editor_load_version :: proc(
	reader: ^bytes.Reader,
	block_size: u32be, 
	version: string,
) -> (err: io.Error) {
	switch version {
		case "00.02.00": {
			Save_Header :: struct #packed {
				task_head: u32be,
				task_tail: u32be,
				// ONLY VALID FOR THE SAME WINDOW SIZE
				camera_offset_x: i32be,
				camera_offset_y: i32be,

				task_count: u32be,
				task_bytes_min: u16be,
			}

			if int(block_size) != size_of(Save_Header) {
				log.error("LOAD: Wrong block size for version: ", version)
				return
			}

			// save when size is the same as version based size
			header := reader_read_type(reader, Save_Header) or_return
			cam := mode_panel_cam()
			cam_set_x(cam, f32(header.camera_offset_x))
			cam_set_y(cam, f32(header.camera_offset_y))
			log.info("CAM OFFSET", cam.offset_x, cam.offset_y)

			Save_Task :: struct #packed {
				indentation: u8,
				state: u8,
				tags: u8,
				text_size: u16be,
				// N text content comes after this
			}

			if int(header.task_bytes_min) != size_of(Save_Task) {
				log.error("LOAD: Wrong task byte size", size_of(Save_Task), header.task_bytes_min)
				return
			}

			// read each task
			for i in 0..<header.task_count {
				block_task := reader_read_type(reader, Save_Task) or_return
				text_byte_content := reader_read_bytes_out(reader, int(block_task.text_size)) or_return

				line := task_push(int(block_task.indentation), string(text_byte_content[:]))
				line.state = Task_State(block_task.state)
				line.tags = block_task.tags
			}

			task_head = int(header.task_head)
			task_tail = int(header.task_tail)
		}
	}

	return
}

editor_read_opt_tags :: proc(reader: ^bytes.Reader) -> (err: io.Error) {
	// read until finished
	for bytes.reader_length(reader) > 0 {
		line_index := reader_read_type(reader, u32be) or_return
		task := cast(^Task) mode_panel.children[line_index]

		// read tag + opt data
		tag: Save_Tag
		for tag != .Finished {
			tag = transmute(Save_Tag) bytes.reader_read_byte(reader) or_return

			switch tag {
				case .None, .Finished: {}
				case .Bookmark: task.bookmarked = true
				case .Folded: task.folded = true
				case .Image_Path: {
					length := reader_read_type(reader, u16be) or_return
					byte_content := reader_read_bytes_out(reader, int(length)) or_return

					path := string(byte_content[:])
					handle := image_load_push(path)
					task_set_img(task, handle)
				}
			}
		}
	}

	return 
}

editor_load :: proc(file_path: string) -> (err: io.Error) {
	file_data, ok := os.read_entire_file(file_path)
	defer delete(file_data)

	if !ok {
		log.error("LOAD: File not found")
		err = .Unknown
		return
	}

	reader: bytes.Reader
	bytes.reader_init(&reader, file_data)

	start := reader_read_bytes_out(&reader, 8) or_return
	if mem.compare(start, bytes_file_signature[:]) != 0 {
		log.error("LOAD: Start signature invalid")
		err = .Unknown
		return
	} 

	tasks_load_reset()

	// header block
	version_bytes := reader_read_bytes_out(&reader, 8) or_return
	version := string(version_bytes)
	block_size := reader_read_type(&reader, u32be) or_return
	log.info("SAVE FILE FOUND VERSION", version)
	editor_load_version(&reader, block_size, version) or_return
	editor_read_opt_tags(&reader) or_return

	return
}

reader_read_type :: proc(r: ^bytes.Reader, $T: typeid) -> (output: T, err: io.Error) {
	if r.i + size_of(T) >= i64(len(r.s)) {
		err = .EOF
		return
	}

	output = (cast(^T) &r.s[r.i])^
	r.i += i64(size_of(T))
	return
}

reader_read_bytes_out :: proc(r: ^bytes.Reader, size: int) -> (output: []byte, err: io.Error) {
	if r.i + i64(size) - 1 >= i64(len(r.s)) {
		err = .EOF
		return
	}
	
	output = r.s[r.i:r.i + i64(size)]
	r.i += i64(size)
	return
}

//////////////////////////////////////////////
// json save file
//////////////////////////////////////////////

Misc_Save_Load :: struct {
	// not shown directly to the user,
	hidden: struct {
		scale: f32,
		mode_index: int,

		font_regular_path: string,
		font_bold_path: string,

		window_x: int, 
		window_y: int,
		window_width: int,
		window_height: int,	

		last_save_location: string,
	},

	options: struct {
		tab: f32,
		autosave: bool,
		invert_x: bool,
		invert_y: bool,
		uppercase_word: bool,
		use_animations: bool,
		wrapping: bool,
		bordered: bool,
		volume: f32,
	},

	tags: struct {
		names: [8]string,
		tag_mode: int,
	},

	pomodoro: struct {
		index: int,

		work: int,
		short_break: int,
		long_break: int,

		stopwatch_running: bool,
		stopwatch_acuumulation: int, // time.Duration 
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
}

json_save_misc :: proc(path: string) -> bool {
	arena, _ := arena_scoped(mem.Megabyte * 10)
	context.allocator = mem.arena_allocator(&arena)

	// set tag data
	tag_colors: [8]u32
	tag_names: [8]string
	for i in 0..<8 {
		tag := sb.tags.names[i]
		tag_names[i] = strings.to_string(tag^)
	}

	// create theme save data
	theme_save: Theme_Save_Load
	{
		count := size_of(Theme) / size_of(Color)
		for i in 0..<count {
			from := mem.ptr_offset(cast(^Color) &theme, i)
			to := mem.ptr_offset(cast(^u32) &theme_save, i)
			to^ = transmute(u32) from^
		}
	}

	pomodoro_diff := time.stopwatch_duration(pomodoro.stopwatch)
	
	// archive data
	archive_data := make([]string, len(sb.archive.buttons.children))
	// NOTE SKIP THE SCROLLBAR
	for i in 0..<len(sb.archive.buttons.children) {
		button := cast(^Archive_Button) sb.archive.buttons.children[i]
		archive_data[i] = strings.to_string(button.builder)
	}

	window_x, window_y := window_get_position(window_main)
	window_width := window_main.width
	window_height := window_main.height
	// log.warn("WINDOW SAVED", window_x, window_y)

	// adjust by window border
	{
		t, l, b, r := window_border_size(window_main)
		// log.info(t, l, b, r)
		// log.info(window_x, window_y, window_width, window_height)
		window_y -= t
		window_x -= l
		window_width += r
		window_height += b
	}

	value := Misc_Save_Load {
		hidden = {
			scale =  SCALE,
			mode_index = int(mode_panel.mode),
			
			font_regular_path = gs.font_regular_path,
			font_bold_path = gs.font_bold_path,

			window_x = window_x,
			window_y = window_y,
			window_width = window_width,
			window_height = window_height,

			last_save_location = last_save_location,
		},

		options = {
			options_tab(),
			options_autosave(),
			sb.options.checkbox_invert_x.state,
			sb.options.checkbox_invert_y.state,
			options_uppercase_word(),
			options_use_animations(),
			options_wrapping(),
			options_bordered(),
			options_volume(),
		},

		tags = {
			tag_names,
			options_tag_mode(),
		},

		pomodoro = {
			pomodoro.index,

			int(pomodoro_time_index(0)),
			int(pomodoro_time_index(1)),
			int(pomodoro_time_index(2)),

			pomodoro.stopwatch.running,
			int(pomodoro_diff),
		},

		statistics = {
			int(pomodoro.accumulated),
			int(sb.options.slider_work_today.position * 24),
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
		// ok := bpath_file_write(path, result[:])
		file_path := bpath_temp(path)
		return gs_write_safely(file_path, result[:])
		// return ok
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
		// TODO hook this up properly?
		scaling_set(misc.hidden.scale)
		mode_panel.mode = Mode(clamp(misc.hidden.mode_index, 0, len(Mode)))

		if misc.hidden.window_width != 0 && misc.hidden.window_height != 0 {
			// log.warn("WINDOW SET POS", misc.hidden.window_x, misc.hidden.window_y)
			window_set_position(window_main, misc.hidden.window_x, misc.hidden.window_y)
			window_set_size(window_main, clamp(misc.hidden.window_width, 0, max(int)), clamp(misc.hidden.window_height, 0, max(int)))
		}

		last_save_set(misc.hidden.last_save_location)
		// last_save_location = strings.clone(misc.hidden.last_save_location)

		if misc.hidden.font_regular_path != "" {
			gs.font_regular_path = strings.clone(misc.hidden.font_regular_path)
		}

		if misc.hidden.font_bold_path != "" {
			gs.font_bold_path = strings.clone(misc.hidden.font_bold_path)
		}
	}

	// tag data
	sb.tags.tag_show_mode = misc.tags.tag_mode
	// sb.tags.toggle_selector_tag.cell_unit = f32(misc.tags.tag_mode)
	for i in 0..<8 {
		tag := sb.tags.names[i]
		strings.builder_reset(tag)
		strings.write_string(tag, misc.tags.names[i])
	}	

	// options
	slider_set(sb.options.slider_tab, misc.options.tab)
	checkbox_set(sb.options.checkbox_autosave, misc.options.autosave)
	checkbox_set(sb.options.checkbox_invert_x, misc.options.invert_x)
	checkbox_set(sb.options.checkbox_invert_y, misc.options.invert_y)
	checkbox_set(sb.options.checkbox_uppercase_word, misc.options.uppercase_word)
	checkbox_set(sb.options.checkbox_use_animations, misc.options.use_animations)
	checkbox_set(sb.options.checkbox_wrapping, misc.options.wrapping)
	checkbox_set(sb.options.checkbox_bordered, misc.options.bordered)
	slider_set(sb.options.slider_volume, misc.options.volume)

	// theme
	{
		count := size_of(Theme) / size_of(Color)
		for i in 0..<count {
			from := mem.ptr_offset(cast(^u32) &misc.theme, i)
			to := mem.ptr_offset(cast(^Color) &theme, i)
			to^ = transmute(Color) from^
		}
	}

	// pomodoro
	pomodoro.index = misc.pomodoro.index
	slider_set(sb.options.slider_pomodoro_work, f32(misc.pomodoro.work) / 60)
	slider_set(sb.options.slider_pomodoro_short_break, f32(misc.pomodoro.short_break) / 60)
	slider_set(sb.options.slider_pomodoro_long_break, f32(misc.pomodoro.long_break) / 60)
	pomodoro.stopwatch.running = misc.pomodoro.stopwatch_running
	pomodoro.stopwatch._accumulation = time.Duration(misc.pomodoro.stopwatch_acuumulation)
	
	// statistics
	goal := clamp(misc.statistics.work_goal, 1, 24)
	sb.options.slider_work_today.position = f32(goal) / 24.0
	pomodoro.accumulated = time.Duration(misc.statistics.accumulated)

	pomodoro.stopwatch._start_time = time.tick_now()
	
	// run everything
	if pomodoro.stopwatch.running {
		element_hide(sb.options.button_pomodoro_reset, false)
	}

	pomodoro_label_format()
	element_repaint(mode_panel)

	// archive
	for text, i in misc.archive.data {
		archive_push(text)
	}
	sb.archive.head = misc.archive.head
	sb.archive.tail = misc.archive.tail

	// custom sounds path setting
	sound_path_write(.Timer_Start, misc.custom_sounds.timer_start)
	sound_path_write(.Timer_Stop, misc.custom_sounds.timer_stop)
	sound_path_write(.Timer_Resume, misc.custom_sounds.timer_resume)
	sound_path_write(.Timer_Ended, misc.custom_sounds.timer_ended)

	return true
}

// CUSTOM FORMAT: 
// [SECTION]
// move_up = shift+up ctrl+up up
keymap_save :: proc(path: string) -> bool {
	arena, _ := arena_scoped(mem.Megabyte)
	context.allocator = mem.arena_allocator(&arena)

	b := strings.builder_make(0, mem.Kilobyte * 2)
	s := &window_main.shortcut_state

	write_content :: proc(b: ^strings.Builder, name: string, mapping: map[string]string) {
		strings.write_string(b, name)
		strings.write_byte(b, '\n')
		rows := make(map[string]strings.Builder, len(mapping))

		// gather row data
		for k, v in mapping {
			if row, ok := &rows[v]; ok {
				strings.write_byte(row, ' ')
				strings.write_string(row, k)
			} else {
				row_builder := strings.builder_make(0, 64)
				fmt.sbprintf(&row_builder, "\t%s = %s", v, k)
				rows[v] = row_builder
			}
		}

		// write each row
		for _, row in rows {
			strings.write_string(b, strings.to_string(row))
			strings.write_byte(b, '\n')
		}		

		strings.write_string(b, "[END]\n")
	}

	write_content(&b, "[BOX]", s.box)
	strings.write_byte(&b, '\n')
	write_content(&b, "[TODOOL]", s.general)

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

	arena, _ := arena_scoped(mem.Megabyte)
	context.allocator = mem.arena_allocator(&arena)

	section_read :: proc(content: ^string, section: string, expected: int) -> (mapping: map[string]string, ok: bool) {
		mapping = make(map[string]string, expected)
		found_section: bool
		ds: cutf8.Decode_State

		for line in strings.split_lines_iterator(content) {
			// end reached for the section
			if line == "[END]" {
				break
			}

			if !found_section {
				// can skip empty lines
				if line == section {
					found_section = true
				}
			} else {
				word_start := -1
				first_found: bool
				first_word: string
				line_valid: bool
				only_space := true
				ds = {}

				for codepoint, codepoint_index in cutf8.ds_iter(&ds, line) {
					if codepoint == '=' {
						line_valid = true
					}

					// word validity
					if unicode.is_letter(codepoint) || codepoint == '+' {
						if word_start == -1 {
							word_start = ds.byte_offset_old
						}

						only_space = false
					} else if unicode.is_space(codepoint) {
						// ignoring spacing
						if word_start != -1 {
							word := line[word_start:ds.byte_offset_old]
							word_start = -1

							// insert first word as value
							if !first_found {
								first_word = word
								first_found = true
							} else {
								mapping[word] = first_word
							}
						}
					}
				}

				// check end of word
				if word_start != -1 {
					word := line[word_start:ds.byte_offset]

					if first_found {
						mapping[word] = first_word
					}
				}

				// invalid typed line disallowed, empty line allowed
				if !line_valid && !only_space {
					return
				}

				// log.info(line, first_word, len(mapping))
			}
		}

		ok = len(mapping) != 0 && found_section
		return
	}

	content := string(bytes)
	box := section_read(&content, "[BOX]", 32) or_return
	general := section_read(&content, "[TODOOL]", 128) or_return

	// NOTE ONLY TRANSFERS DATA ON ALL SUCCESS
	{
		shortcuts_clear(window_main)
		s := &window_main.shortcut_state
		context.allocator = mem.arena_allocator(&s.arena)
		
		for combo, command in box {
			s.box[strings.clone(combo)] = strings.clone(command)
		}

		for combo, command in general {
			s.general[strings.clone(combo)] = strings.clone(command)
		}
	}

	return true
}