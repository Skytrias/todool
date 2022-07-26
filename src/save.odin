package src

import "core:io"
import "core:strings"
import "core:mem"
import "core:bytes"
import "core:log"
import "core:os"

/* 
TODOOL SAVE FILE FORMAT

file_signature: "TODOOLFF"

header: 
	block_size: u64be
	version: u16be -> version number
	
	block read into struct -> based on block_size
		Version 1:
			task_head: u64be -> head line
			task_tail: u64be -> tail line
			task_bytes_min: u16be -> size to read per task line in memory
			task_count: u64be -> how many "task lines" to read

task line: atleast "task_bytes_min" big
	Version 1:
		indentation: u8 -> indentation used, capped to 255
		folded: u8 -> task folded
		state: u8 -> task state
		tags: u8 -> task tags, NO STRING CONTENT!
		text_size: u16be -> text content amount to read
		text_content: [N]u8

body: hold *N* task lines
	read task line by line -> read opt data till end 

opt data: Task Line index + additional data
	TODO
*/

V1_Save_Header :: struct {
	task_head: u64be,
	task_tail: u64be,
	task_count: u64be,
	task_bytes_min: u16be,
}

V1_Save_Task :: struct {
	indentation: u8,
	folded: b8,
	state: u8,
	tags: u8,
	text_size: u16be,
	// N text content comes after this
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
	header_size := u64be(size_of(V1_Save_Header))
	buffer_write_type(&buffer, header_size) or_return
	header_version := u16be(1)
	buffer_write_type(&buffer, header_version) or_return

	header := V1_Save_Header {
		u64be(task_head),
		u64be(task_tail),
		u64be(len(mode_panel.children)),
		size_of(V1_Save_Task),
	}
	buffer_write_type(&buffer, header) or_return
	
	// write all lines
	for child in mode_panel.children {
		task := cast(^Task) child
		t := V1_Save_Task {
			u8(task.indentation),
			b8(task.folded),
			u8(task.state),
			u8(task.tags),
			u16be(len(task.box.builder.buf)),
		}
		buffer_write_type(&buffer, t) or_return
		bytes.buffer_write_string(&buffer, strings.to_string(task.box.builder)) or_return
	}

	os.write_entire_file(file_name, buffer.buf[:])
	return
}

editor_load_version :: proc(
	reader: ^bytes.Reader,
	block_size: u64be, 
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

			for i in 0..<header.task_count {
				block_task := reader_read_type(reader, V1_Save_Task) or_return
				text_byte_content := reader_read_bytes_out(reader, int(block_task.text_size)) or_return

				line := task_push(int(block_task.indentation), string(text_byte_content[:]))
				line.folded = bool(block_task.folded)
				line.state = Task_State(block_task.state)
				line.tags = block_task.tags
			}

			task_head = int(header.task_head)
			task_tail = int(header.task_tail)
		}
	}

	return
}

editor_load :: proc(file_name: string) -> (err: io.Error) {
	file_data, ok := os.read_entire_file(file_name)
	defer delete(file_data)

	if !ok {
		log.error("LOAD: File not found = ")
		return
	}

	reader: bytes.Reader
	bytes.reader_init(&reader, file_data)

	start := reader_read_bytes_out(&reader, 8) or_return
	if mem.compare(start, bytes_file_signature[:]) != 0 {
		log.error("LOAD: Start signature invalid")
		return
	}

	// header block
	block_size := reader_read_type(&reader, u64be) or_return
	version := reader_read_type(&reader, u16be) or_return
	editor_load_version(&reader, block_size, version) or_return

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