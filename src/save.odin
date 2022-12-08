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
import "core:math/bits"
import "../cutf8"

// TODO lower the task text size to u8

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

tags: (optional)
	8 strings (length u8 + []u8)
	8 colors (u32be)

// Rest of the bytes after body will be read as opt data!
// holds *N* Task Line index + additional data
opt data: 
	line_index: u32be
	
	Save_Tag enum -> u8
*/

save_tag_color_signature := [8]u8 { 'T', 'A', 'G', 'C', 'O', 'L', 'O', 'R' }

Save_Tag_Color_Header :: struct {
	signature: [8]u8,
	version: u8,
	tag_mode: u8,
}

// additional data can be added later on
// 8 strings (length u8 + []u8)
// 8 colors (u32be)

// NOTE should only increase, mark things as deprecated!
Save_Tag :: enum u8 {
	None, // Empty flag
	Finished, // Finished reading all tags + tag data
	
	Folded, // NO data included
	Bookmark, // NO data included
	Image_Path, // u16be string len + [N]u8 byte data
	Link_Path, // u16be string len + [N]u8 byte data
	Seperator, // NO data included

	Timestamp, // i64be included = time.Time
}

bytes_file_signature := [8]u8 { 'T', 'O', 'D', 'O', 'O', 'L', 'F', 'F' }

buffer_write_color :: proc(b: ^bytes.Buffer, color: Color) -> (err: io.Error) {
	// CHECK is this safe endianness?
	color_u32be := transmute(u32be) color
	buffer_write_type(b, color_u32be) or_return
	return
}

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

buffer_write_string_u16 :: proc(b: ^bytes.Buffer, text: string) -> (err: io.Error) {
	count := u16be(len(text))
	buffer_write_type(b, count) or_return
	// TODO is this utf8 safe?
	bytes.buffer_write_string(b, text[:count]) or_return
	return
}

buffer_write_string_u8 :: proc(b: ^bytes.Buffer, text: string) -> (err: io.Error) {
	count := u8(len(text))
	buffer_write_type(b, count) or_return
	// TODO is this utf8 safe?
	bytes.buffer_write_string(b, text[:count]) or_return
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
		u32be(app.task_head),
		u32be(app.task_tail),
		i32be(cam.offset_x),
		i32be(cam.offset_y),
		u32be(len(app.mode_panel.children)),
		size_of(Save_Task),
	}
	buffer_write_type(&buffer, header) or_return
	
	// write all lines
	for child in app.mode_panel.children {
		task := cast(^Task) child
		t := Save_Task {
			u8(task.indentation),
			u8(task.state),
			u8(task.tags),
			u16be(task.box.ss.length),
		}
		buffer_write_type(&buffer, t) or_return
		bytes.buffer_write_string(&buffer, ss_string(&task.box.ss)) or_return
	}

	editor_save_tag_colors(&buffer) or_return

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
	for child, i in app.mode_panel.children {
		task := cast(^Task) child
		line_written: bool

		// look for opt data
		if task_bookmark_is_valid(task) {
			opt_write_line(&buffer, &line_written, i) or_return
			opt_write_tag(&buffer, .Bookmark) or_return
		}

		if task.folded {
			opt_write_line(&buffer, &line_written, i) or_return
			opt_write_tag(&buffer, .Folded) or_return			
		}

		if image_display_has_path(task.image_display) {
			opt_write_line(&buffer, &line_written, i) or_return
			opt_write_tag(&buffer, .Image_Path) or_return
			buffer_write_string_u16(&buffer, image_path(task.image_display.img)) or_return
			// fmt.eprintln("SAVE WRITE IMAGE PATH", image_path(task.image_display.img))
		}

		if task_link_is_valid(task) {
			opt_write_line(&buffer, &line_written, i) or_return
			opt_write_tag(&buffer, .Link_Path) or_return
			buffer_write_string_u16(&buffer, strings.to_string(task.button_link.builder)) or_return
		}

		if task_seperator_is_valid(task) {
			opt_write_line(&buffer, &line_written, i) or_return
			opt_write_tag(&buffer, .Seperator) or_return
		}

		if task_time_date_is_valid(task) {
			opt_write_line(&buffer, &line_written, i) or_return
			opt_write_tag(&buffer, .Timestamp) or_return
			out := i64be(task.time_date.stamp._nsec)
			buffer_write_type(&buffer, out) or_return
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
			cam_set_x(cam, int(header.camera_offset_x))
			cam_set_y(cam, int(header.camera_offset_y))

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
				word := string(text_byte_content[:])

				spell_check_mapping_words_add(word)

				line := task_push(int(block_task.indentation), word)
				line.state = Task_State(block_task.state)
				line.tags = block_task.tags
			}

			app.task_head = int(header.task_head)
			app.task_tail = int(header.task_tail)
		}
	}

	return
}

editor_read_opt_tags :: proc(reader: ^bytes.Reader) -> (err: io.Error) {
	// read until finished
	for bytes.reader_length(reader) > 0 {
		line_index := reader_read_type(reader, u32be) or_return
		task := cast(^Task) app.mode_panel.children[line_index]

		// read tag + opt data
		tag: Save_Tag
		for tag != .Finished {
			tag = transmute(Save_Tag) bytes.reader_read_byte(reader) or_return

			switch tag {
				case .None, .Finished: {}
				case .Bookmark: {
					task_set_bookmark(task, true)
				}
				case .Folded: task.folded = true
				case .Image_Path: {
					length := reader_read_type(reader, u16be) or_return
					byte_content := reader_read_bytes_out(reader, int(length)) or_return

					path := string(byte_content[:])
					// fmt.eprintln("LOAD IMAGE PATH", path)
					handle := image_load_push(path)
					task_set_img(task, handle)
				}
				case .Link_Path: {
					length := reader_read_type(reader, u16be) or_return
					byte_content := reader_read_bytes_out(reader, int(length)) or_return					

					link := string(byte_content[:])
					task_set_link(task, link)
				}
				case .Seperator: {
					task_set_seperator(task, true)
				}
				case .Timestamp: {
					input := reader_read_type(reader, i64be) or_return
					task_set_time_date(task)
					task.time_date.stamp = time.Time { i64(input) }
				}
			}
		}
	}

	return 
}

editor_save_tag_colors :: proc(b: ^bytes.Buffer) -> (err: io.Error) {
	header := Save_Tag_Color_Header {
		signature = save_tag_color_signature,
		version = 1,
		tag_mode = u8(options_tag_mode()),
	}

	// write out header with wanted info
	buffer_write_type(b, header) or_return

	// write out small string content 
	for i in 0..<8 {
		buffer_write_string_u8(b, ss_string(sb.tags.names[i])) or_return
	}	

	// write out colors
	for i in 0..<8 {
		buffer_write_color(b, theme.tags[i]) or_return
	}

	return
}

editor_read_tag_colors :: proc(reader: ^bytes.Reader) -> (err: io.Error) {
	// peek for tag save color byte signature
	if bytes.reader_length(reader) > 8 {
		signature := reader.s[reader.i:reader.i + 8]

		if mem.compare(signature, save_tag_color_signature[:]) != 0 {
			log.warn("LOAD: Save Tag Color Signature not found")
		} else {
			// found, read entire header
			header := reader_read_type(reader, Save_Tag_Color_Header) or_return
			
			switch header.version {
				case: {
					log.warn("LOAD: unknown header version")
				}

				case 1: {
					sb.tags.tag_show_mode = int(header.tag_mode)
					toggle_selector_set(sb.tags.toggle_selector_tag, int(header.tag_mode))

					for i in 0..<8 {
						text_length := reader_read_type(reader, u8) or_return
						text_content := reader_read_bytes_out(reader, int(text_length)) or_return
						ss := sb.tags.names[i]
						ss_set_string(ss, transmute(string) text_content)
					}

					for i in 0..<8 {
						color := reader_read_type(reader, u32be) or_return
						// CHECK is this safe to do since endianness?
						theme.tags[i] = transmute(Color) color
					}
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

	spell_check_clear_user()
	tasks_load_reset()

	// header block
	version_bytes := reader_read_bytes_out(&reader, 8) or_return
	version := string(version_bytes)
	block_size := reader_read_type(&reader, u32be) or_return
	log.info("SAVE FILE FOUND VERSION", version)
	editor_load_version(&reader, block_size, version) or_return
	editor_read_tag_colors(&reader) or_return
	editor_read_opt_tags(&reader) or_return

	return
}

reader_read_type :: proc(r: ^bytes.Reader, $T: typeid) -> (output: T, err: io.Error) {
	if r.i + size_of(T) - 1 >= i64(len(r.s)) {
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
		task_scale: f32,
		mode_index: int,

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
		// log.info(t, l, b, r)
		// log.info(window_x, window_y, window_width, window_height)
		window_y -= t
		window_x -= l
		window_width += r
		window_height += b
	}

	value := Misc_Save_Load {
		hidden = {
			scale = SCALE,
			task_scale = TASK_SCALE,
			mode_index = int(app.mode_panel.mode),
			
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
		// TODO hook this up properly?
		if misc.hidden.task_scale == 0 {
			misc.hidden.task_scale = 1
		}
		scaling_set(misc.hidden.scale, misc.hidden.task_scale)
		app.mode_panel.mode = Mode(clamp(misc.hidden.mode_index, 0, len(Mode)))

		if misc.hidden.window_width != 0 && misc.hidden.window_height != 0 {
			total_width, total_height := gs_display_total_bounds()

			w := max(misc.hidden.window_width, 200)
			h := max(misc.hidden.window_height, 200)
			// clamp window based on total display width/height
			x := min(max(misc.hidden.window_x, 0) + w, total_width) - w
			y := min(max(misc.hidden.window_y, 0) + h, total_height) - h

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

		slider_set(sb.options.slider_opacity, misc.hidden.window_opacity)
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

		if sb.options.pm != {} {
			checkbox_set(ps_show, misc.power_mode.show)
			slider_set(p_lifetime, misc.power_mode.particle_lifetime)
			slider_set(p_alpha_scale, misc.power_mode.particle_alpha_scale)
			checkbox_set(p_colored, misc.power_mode.particle_colored)
			checkbox_set(s_use, misc.power_mode.screenshake_use)
			slider_set(s_amount, misc.power_mode.screenshake_amount)
			slider_set(s_lifetime, misc.power_mode.screenshake_lifetime)
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
	element_repaint(app.mode_panel)

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
			c1 := strings.string_from_ptr(&node.combo[0], int(node.combo_index))
			c2 := strings.string_from_ptr(&node.command[0], int(node.command_index))

			if cmd, ok1 := keymap.commands[c2]; ok1 {
				if comment, ok2 := keymap_comments[cmd]; ok2 {
					strings.write_string(b, "\t// ")
					strings.write_string(b, comment)
					strings.write_byte(b, '\n')
				} else {
					// NOTE skip non found command
					continue
				}
			}

			strings.write_byte(b, '\t')
			strings.write_string(b, c1)
			strings.write_string(b, " = ")
			strings.write_string(b, c2)

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