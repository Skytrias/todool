package spall

import "core:fmt"
import "core:time"
import "core:os"

MAGIC :: u64(0x0BADF00D)
MEASURE :: false

Header :: struct #packed {
	magic:          u64,
	version:        u64,
	timestamp_unit: f64,
	must_be_0:      u64,
}

Event_Type :: enum u8 {
	Invalid             = 0,
	Custom_Data         = 1, // Basic readers can skip this.
	StreamOver          = 2,

	Begin               = 3,
	End                 = 4,
	Instant             = 5,

	Overwrite_Timestamp = 6, // Retroactively change timestamp units - useful for incrementally improving RDTSC frequency.
	Update_Checksum     = 7, // Verify rolling checksum. Basic readers/writers can ignore/omit this.
}

Complete_Event :: struct #packed {
	type: Event_Type,
	pid:      u32,
	tid:      u32,
	time:     f64,
	duration: f64,
	name_len: u8,
}

Begin_Event :: struct #packed {
	type: Event_Type,
	pid:      u32,
	tid:      u32,
	time:     f64,
	name_len: u8,
}

End_Event :: struct #packed {
	type: Event_Type,
	pid:  u32,
	tid:  u32,
	time: f64,
}

time_start: time.Time
file_handle: os.Handle

init :: proc(path: string, cap: int) {
	when MEASURE {
		time_start = time.now()
		
		errno: os.Errno
		when os.OS == .Linux {
			// all rights on linux
			file_handle, errno = os.open(path, os.O_WRONLY | os.O_CREATE | os.O_TRUNC, 0o0777)
		} else {
			file_handle, errno = os.open(path, os.O_WRONLY | os.O_CREATE | os.O_TRUNC)
		}

		header := Header{
			magic = MAGIC, 
			version = 0, 
			timestamp_unit = 1.0, 
			must_be_0 = 0,
		}
		header_bytes := transmute([size_of(Header)]u8)header
		os.write(file_handle, header_bytes[:])
	}
}

destroy :: proc() {
	when MEASURE {
		os.close(file_handle)
	}
}

begin :: proc(name: string, tid: u32) {
	when MEASURE {
		ts := time.duration_microseconds(time.since(time_start))
		name_length := u8(len(name))
		
		event := Begin_Event {
			type = .Begin,
			pid  = 0,
			tid  = tid,
			time = ts,
			name_len = name_length,
		}

		begin_bytes := transmute([size_of(Begin_Event)]u8) event
		os.write(file_handle, begin_bytes[:])
		os.write_string(file_handle, name[:u8(len(name))])
	}
}

end :: proc(tid: u32) {
	when MEASURE {
		ts := time.duration_microseconds(time.since(time_start))
		
		event := End_Event {
			type = .End,
			pid  = 0,
			tid  = tid,
			time = ts,
		}

		end_bytes := transmute([size_of(End_Event)]u8) event
		os.write(file_handle, end_bytes[:])
	}
}

@(deferred_out=end)
scoped :: proc(name: string, tid: u32 = 0) -> (u32) {
	begin(name, tid)
	return tid
}

// NOTE uses tid 0 by default
@(deferred_out=end)
fscoped :: proc(format: string, args: ..any) -> u32 {
	text := fmt.tprintf(format, ..args)
	begin(text, 0)
	return 0
}