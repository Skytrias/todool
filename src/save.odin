package src

import "core:time"
import "core:io"
import "core:strings"
import "core:mem"
import "core:bytes"
import "core:log"
import "core:os"
import "core:encoding/json"

/* 
TODOOL SAVE FILE FORMAT - currently *uncompressed*

file_signature: "TODOOLFF"

header: 
	block_size: u32be
	version: u16be -> version number
	
	block read into struct -> based on block_size
		Version 1:
			task_head: u32be -> head line
			task_tail: u32be -> tail line
			task_bytes_min: u16be -> size to read per task line in memory
			task_count: u32be -> how many "task lines" to read

task line: atleast "task_bytes_min" big
	Version 1:
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

V1_Save_Header :: struct {
	task_head: u32be,
	task_tail: u32be,
	task_count: u32be,
	task_bytes_min: u16be,
}

V1_Save_Task :: struct {
	indentation: u8,
	state: u8,
	tags: u8,
	text_size: u16be,
	// N text content comes after this
}

// NOTE should only increase, mark things as deprecated!
Save_Tag :: enum u8 {
	None, // Empty flag
	Finished, // Finished reading all tags + tag data
	Folded, // NO data included
	Bookmark, // NO data included
}

bytes_file_signature := [8]u8 { 'T', 'O', 'D', 'O', 'O', 'L', 'F', 'F' }

buffer_write_type :: proc(b: ^bytes.Buffer, type: $T) -> (err: io.Error) {
	// NOTE use pointer instead?
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

editor_save :: proc(file_name: string) -> (err: io.Error) {
	buffer: bytes.Buffer
	bytes.buffer_init_allocator(&buffer, 0, mem.Megabyte)
	defer bytes.buffer_destroy(&buffer)

	// signature
	bytes.buffer_write_ptr(&buffer, &bytes_file_signature[0], 8) or_return

	// header block
	header_size := u32be(size_of(V1_Save_Header))
	buffer_write_type(&buffer, header_size) or_return
	header_version := u16be(1)
	buffer_write_type(&buffer, header_version) or_return

	header := V1_Save_Header {
		u32be(task_head),
		u32be(task_tail),
		u32be(len(mode_panel.children)),
		size_of(V1_Save_Task),
	}
	buffer_write_type(&buffer, header) or_return
	
	// write all lines
	for child in mode_panel.children {
		task := cast(^Task) child
		t := V1_Save_Task {
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

		// write finish flag
		if line_written {
			opt_write_tag(&buffer, .Finished) or_return
		}
	}

	ok := bpath_file_write(file_name, buffer.buf[:])
	if !ok {
		log.error("SAVE: File write failed")
	}
	
	return
}

editor_load_version :: proc(
	reader: ^bytes.Reader,
	block_size: u32be, 
	version: u16be,
) -> (err: io.Error) {
	switch version {
		case 1: {
			if int(block_size) != size_of(V1_Save_Header) {
				log.error("LOAD: Wrong block size for version: ", version)
				return
			}

			// save when size is the same as version based size
			header := reader_read_type(reader, V1_Save_Header) or_return

			if int(header.task_bytes_min) != size_of(V1_Save_Task) {
				log.error("LOAD: Wrong task byte size", size_of(V1_Save_Task), header.task_bytes_min)
				return
			}

			// read each task
			for i in 0..<header.task_count {
				block_task := reader_read_type(reader, V1_Save_Task) or_return
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
				case .Bookmark: task.bookmarked = true
				case .Folded: task.folded = true
				case .None, .Finished: {}
			}
		}
	}

	return 
}

editor_load :: proc(file_name: string) -> (err: io.Error) {
	file_data, ok := bpath_file_read(file_name)
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
		return
	} 

	tasks_load_reset()

	// header block
	block_size := reader_read_type(&reader, u32be) or_return
	version := reader_read_type(&reader, u16be) or_return
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
	scale: f32,

	options: struct {
		tab: f32,
		autosave: bool,
		invert_x: bool,
		invert_y: bool,
		uppercase_word: bool,
		use_animations: bool,
		wrapping: bool,
	},

	tags: struct {
		names: [8]string,
		tag_mode: int,
	},

	pomodoro: struct {
		work: int,
		short_break: int,
		long_break: int,
	},

	statistics: struct {
		accumulated: int, // time.Duration
		work_goal: int,
	},

	theme: Theme_Save_Load,
}

json_save_misc :: proc(path: string) -> bool {
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

	value := Misc_Save_Load {
		scale =  SCALE,

		options = {
			options_tab(),
			options_autosave(),
			sb.options.checkbox_invert_x.state,
			sb.options.checkbox_invert_y.state,
			options_uppercase_word(),
			options_use_animations(),
			options_wrapping(),
		},

		tags = {
			tag_names,
			options_tag_mode(),
		},

		pomodoro = {
			int(pomodoro_time_index(0)),
			int(pomodoro_time_index(1)),
			int(pomodoro_time_index(2)),
		},

		statistics = {
			int(pomodoro.accumulated),
			int(sb.options.slider_work_today.position * 24),
		},

		theme = theme_save,
	}

	result, err := json.marshal(
		value, 
		{
			spec = .MJSON,
			pretty = true,
			write_uint_as_hex = true,
			mjson_keys_use_equal_sign = true,
		},
		context.temp_allocator,
	)
	// log.info("json marshal: err =", err)

	if err == nil {
		ok := bpath_file_write(path, result[:])
		return ok
	}

	return false
}

json_load_misc :: proc(path: string) -> bool{
	bytes := bpath_file_read(path) or_return
	defer delete(bytes)

	misc: Misc_Save_Load
	err := json.unmarshal(bytes, &misc, .MJSON, context.temp_allocator)

	if err != nil {
		return false
	}

	SCALE = misc.scale
	LINE_WIDTH = max(2, 2 * SCALE)
	ROUNDNESS = 5 * SCALE

	// tag data
	sb.tags.tag_show_mode = misc.tags.tag_mode
	for i in 0..<8 {
		tag := sb.tags.names[i]
		strings.builder_reset(tag)
		strings.write_string(tag, misc.tags.names[i])
	}	

	// options
	sb.options.slider_tab.position = misc.options.tab
	checkbox_set(sb.options.checkbox_autosave, misc.options.autosave)
	checkbox_set(sb.options.checkbox_invert_x, misc.options.invert_x)
	checkbox_set(sb.options.checkbox_invert_y, misc.options.invert_y)
	checkbox_set(sb.options.checkbox_uppercase_word, misc.options.uppercase_word)
	checkbox_set(sb.options.checkbox_use_animations, misc.options.use_animations)
	checkbox_set(sb.options.checkbox_wrapping, misc.options.wrapping)

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
	sb.options.slider_pomodoro_work.position = f32(misc.pomodoro.work) / 60
	sb.options.slider_pomodoro_short_break.position = f32(misc.pomodoro.short_break) / 60
	sb.options.slider_pomodoro_long_break.position = f32(misc.pomodoro.long_break) / 60

	// statistics
	goal := clamp(misc.statistics.work_goal, 1, 24)
	sb.options.slider_work_today.position = f32(goal) / 24.0
	pomodoro.accumulated = time.Duration(misc.statistics.accumulated)

	return true
}