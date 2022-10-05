package spall

import "core:fmt"
import "core:time"
import "core:os"

MAGIC :: u64(0x0BADF00D)
MEASURE :: true

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

// tid: u32 = 0
buf: [dynamic]u8
time_start: time.Time
// time_start: time.Tick

init :: proc(cap: int) {
	when MEASURE {
		buf = make([dynamic]u8, 0, cap)
		time_start = time.now()
		// time_start = time.tick_now()
	}
}

destroy :: proc() {
	when MEASURE {
		delete(buf)
	}
}

write_and_destroy :: proc(path: string) {
	when MEASURE {
		os.write_entire_file(path, buf[:])
		delete(buf)
	}
}

header :: proc() {
	when MEASURE {
		header := Header{
			magic = MAGIC, 
			version = 0, 
			timestamp_unit = 1.0, 
			must_be_0 = 0,
		}
		header_bytes := transmute([size_of(Header)]u8)header
		append(&buf, ..header_bytes[:])
	}
}

begin :: proc(name: string) {	
	when MEASURE {
		ts := time.duration_milliseconds(time.since(time_start))

		begin := Begin_Event {
			type = .Begin,
			pid  = 0,
			tid  = 0,
			time = ts,
			name_len = u8(len(name)),
		}

		begin_bytes := transmute([size_of(Begin_Event)]u8)begin
		append(&buf, ..begin_bytes[:])
		append(&buf, name)
	}
}

end :: proc() {
	when MEASURE {
		ts := time.duration_milliseconds(time.since(time_start))
		end := End_Event {
			type = .End,
			pid  = 0,
			tid  = 0,
			time = ts,
		}
		end_bytes := transmute([size_of(End_Event)]u8)end
		append(&buf, ..end_bytes[:])
	}
}

@(deferred_none=end)
scoped :: proc(name: string) {
	when MEASURE {
		begin(name)
	}
}

@(deferred_none=end)
fscoped :: proc(format: string, args: ..any) {
	when MEASURE {
		begin(fmt.tprintf(format, ..args))
	}
}