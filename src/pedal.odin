package src

import "core:log"
import pm "vendor:portmidi"
import sdl "vendor:sdl2"

Midi_Pedal :: struct {
	timer_id: sdl.TimerID,
	stream: pm.Stream,
	down: bool, // thing to use
}

midi_pedal_callback :: proc "c" (interval: u32, data: rawptr) -> u32 {
	// context = runtime.default_context()

	pedal := cast(^Midi_Pedal) data
	old := pedal.down
	available := pm.Poll(pedal.stream)

	if available != .NoData {
		buffer: [128]pm.Event
		length := pm.Read(pedal.stream, &buffer[0], 128)
		pedal.down = false

		for event, i in buffer[:length] {
			status, data1, data2 := pm.MessageDecompose(event.message)
			
			// check for any down event
			if status == 144 {
				pedal.down = true
				break
			}
		}
	}

	// if pedal.down != old {
	// 	fmt.eprintln(pedal.down ? "\tON" : "OFF")
	// }

	return interval
}

midi_pedal_init :: proc(show: bool) -> (res: ^Midi_Pedal) {
	err1 := pm.Initialize()

	if err1 != .NoError {
		log.error("PORTMIDI Initialize: %v", err1)
		return
	}

	device_count := pm.CountDevices()
	device_id := pm.DeviceID(3)

	info := pm.GetDeviceInfo(device_id)

	// if show {
	// 	for i in 0..<device_count {
	// 		fmt.eprintf("%d. DEV = %v\n", i, pm.GetDeviceInfo(pm.DeviceID(i)))
	// 	}
	
	// 	fmt.eprintln("USING", info)
	// }

	stream: pm.Stream
	err2 := pm.OpenInput(&stream, device_id, info, 1024, nil, nil)
	if err2 != .NoError {
		log.error("PORTMIDI OpenInput: %v", err2)
		return
	}

	res = new(Midi_Pedal)
	res.stream = stream
	res.timer_id = sdl.AddTimer(100, midi_pedal_callback, res)
	return	
}

midi_pedal_destroy :: proc(pedal: ^Midi_Pedal) {
	sdl.RemoveTimer(pedal.timer_id)
	free(pedal)
}
