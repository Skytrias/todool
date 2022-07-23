package src

import "core:time"
import "core:math"
import "core:mem"
import "core:log"
import "core:strings"
import "core:runtime"
import "core:unicode/utf8"
import sdl "vendor:sdl2"
import gl "vendor:OpenGL"
import "../fontstash"

Font :: fontstash.Font
font_regular: ^Font
font_bold: ^Font
font_icon: ^Font

fonts_init :: proc() {
	font_regular = fontstash.font_init("Lato-Regular.ttf", true, 20)
	font_bold = fontstash.font_init("Lato-Bold.ttf", true, 20)
	font_icon = fontstash.font_init("icofont.ttf")  	
}

fonts_destroy :: proc() {
	fontstash.font_destroy(font_regular)	
	fontstash.font_destroy(font_bold)	
	fontstash.font_destroy(font_icon)	
}

Shortcut_Proc :: proc() -> bool

HOVER_TIME :: time.Millisecond * 500
MOUSE_CLICK_TIME :: time.Millisecond * 500
MOUSE_LEFT :: 1
MOUSE_MIDDLE :: 2
MOUSE_RIGHT :: 3
Mouse_Coordinates :: [2]f32
LAYOUT_FULL :: 1

Window :: struct {
	element: Element,
	modifiable_bounds: Rect,
	
	// interactable elements
	hovered: ^Element,
	pressed: ^Element,
	focused: ^Element,

	// hovered info 
	hovered_start: time.Tick, // when the element was first hovered
	hovered_panel: ^Panel, // set in init, but hidden
	hover_timer: int, // sdl based timer to check hover on a different thread 

	// click counting
	clicked_last: ^Element,
	click_count: int,
	clicked_start: time.Tick,

	// mouse behaviour
	cursor_x, cursor_y: f32,
	down_middle: Mouse_Coordinates,
	down_left: Mouse_Coordinates,
	down_right: Mouse_Coordinates,
	pressed_button: int,
	width, height: int,
	widthf, heightf: f32,
	
	// rendering
	update_next: bool,
	scale: f32,
	target: ^Render_Target,
	
	// sdl data
	w: ^sdl.Window,
	w_id: u32,
	cursor: Cursor,
	bordered: bool,

	// key state
	combo_builder: strings.Builder,
	ignore_text_input: bool,
	ctrl, shift, alt: bool,

	// assigned shortcuts to procedures in window
	shortcuts: map[string]Shortcut_Proc,

	// wether a dialog is currently showing
	dialog: ^Element,
	dialog_finished: bool,

	// proc that gets called before layout & draw
	update: proc(),

	// undo / redo
	manager: Undo_Manager,

	// title
	title_builder: strings.Builder,
}

Cursor :: enum {
	Arrow,
	IBeam,
	Hand,
	Resize_Vertical,
	Resize_Horizontal,
	Crosshair,
}

Global_State :: struct {
	windows: [dynamic]^Window,
	logger: log.Logger,
	running: bool,
	cursors: [Cursor]^sdl.Cursor,

	frame_start: u64,
	dt: f32,

	// animating elements
	animating: [dynamic]^Element,

	// event intercepting
	ignore_quit: bool,
}
gs: Global_State

// add shortcut to map
window_add_shortcut :: proc(
	window: ^Window,
	combo: string, 
	call: Shortcut_Proc,
) {
	window.shortcuts[combo] = call
}

window_init :: proc(
	title: cstring, 
	w, h: i32,
	scale: f32 = 1,
) -> (res: ^Window) {
	window := sdl.CreateWindow(
		title, 
		sdl.WINDOWPOS_UNDEFINED,
		sdl.WINDOWPOS_UNDEFINED,
		w,
		h,
		{ .RESIZABLE, .OPENGL },
	)
	if window == nil {
		sdl.Quit()
		log.panic("SDL2: error during window creation %v", sdl.GetError())
	}
	window_id := sdl.GetWindowID(window)
	
	_window_message :: proc(element: ^Element, msg: Message, di: int, dp: rawptr) -> int {
		window := cast(^Window) element

		#partial switch msg {
			case .Layout: {
				// log.info("relayout all")
				window.modifiable_bounds = window_rect(window)

				for child in element.children {
					if .Hide not_in child.flags {
						element_message(child, .Layout, LAYOUT_FULL)
					}
				}
			}

			case .Key_Combination: {
				combo := (cast(^string) dp)^
				
				if call, ok := window.shortcuts[combo]; ok {
					if call() {
						return 1
					}
				}
			}
		}

		return 0
	}

	res = cast(^Window) element_init(Window, nil, {}, _window_message)
	res.w = window
	res.w_id = window_id
	res.hovered = &res.element
	res.scale = scale
	res.combo_builder = strings.builder_make(0, 32)
	res.title_builder = strings.builder_make(0, 64)
	res.shortcuts = make(map[string]Shortcut_Proc, 32)
	res.target = render_target_init(window)
	res.update_next = true
	undo_manager_init(&res.manager)
	append(&gs.windows, res)

	window_ptr := gs.windows[len(gs.windows) - 1]
	res.element.window = window_ptr

	// window_timer_callback :: proc "c" (interval: u32, data: rawptr) -> u32 {
	// 	context = runtime.default_context()
	// 	context.logger = gs.logger
	// 	window := cast(^Window) data

	// 	e := window.hovered
	// 	if e != nil && (.Hover_Has_Info in e.flags) && window.hovered_start != {} {
	// 		diff := time.tick_since(window.hovered_start)

	// 		if diff > HOVER_TIME && (.Hide in window.hovered_panel.flags) {
	// 			window_hovered_panel_spawn(window, e)
	// 			// element_hide(window.hovered_panel, false)
	// 			// TODO needs to be synced
	// 			element_repaint(&window.element)
	// 			log.info("make appear")
	// 		}
	// 	}

	// 	return interval
	// }

	// sdl.AddTimer(500, window_timer_callback, res)

	// set hovered panel
	panel := panel_init(&res.element, { .Panel_Floaty, .Panel_Default_Background })
	panel.float_x = 0
	panel.float_y = 0
	panel.float_width = 200
	panel.float_height = 40
	panel.shadow = true
	panel.z_index = 255
	label_init(panel, { .CF, .Label_Center }, "testing this out man")
	res.hovered_panel = panel
	element_hide(panel, true)

	return
}

window_hovered_panel_spawn :: proc(window: ^Window, element: ^Element) {
	p := window.hovered_panel
	element_hide(p, false)
	p.float_x = window.cursor_x
	goal_y := element.bounds.b + 5

	// bounds check
	if goal_y - p.float_height < window.heightf {
		goal_y = element.bounds.t - p.float_height
	}

	p.float_y = goal_y
}

window_poll_size :: proc(window: ^Window) {
	w, h: i32
	sdl.GetWindowSize(window.w, &w, &h)
	window.width = int(w)
	window.widthf = f32(window.width)
	window.height = int(h)
	window.heightf = f32(window.height)
}

window_rect :: #force_inline proc(window: ^Window) -> Rect {
	return { 0, window.widthf, 0, window.heightf }
}

// send call to focused, focused parents or window
window_send_msg_to_focused_or_parents :: proc(window: ^Window, msg: Message, di: int, dp: rawptr) -> (handled: bool) {
	if window.focused != nil {
		// call messages up the parents till anyone returns 1
		e := window.focused
		for e != nil {
			if element_message(e, msg, di, dp) == 1 {
				handled = true
				break
			}

			e = e.parent
		}
	} else {
		// give the message to parent
		if element_message(&window.element, msg, di, dp) == 1 {
			handled = true
		}
	}		

	return
}

element_send_msg_until_received :: proc(element: ^Element, msg: Message, di: int, dp: rawptr) {
	e := element
	
	for e != nil {
		if element_message(e, msg, di, dp) == 1 {
			break
		}

		e = e.parent
	}
}

window_set_cursor :: proc(window: ^Window, cursor: Cursor) {
	window.cursor = cursor
	sdl.SetCursor(gs.cursors[cursor])
}

// handle all os input events
window_input_event :: proc(window: ^Window, msg: Message, di: int = 0, dp: rawptr = nil) -> (res: bool) {
	if window.pressed != nil {
		if msg == .Mouse_Move {
			// mouse move events become mouse drag messages
			coords: ^Mouse_Coordinates

			// push mouse coordinates of down press
			if window.pressed_button == MOUSE_LEFT {
				coords = &window.down_left
			} else if window.pressed_button == MOUSE_MIDDLE {
				coords = &window.down_middle
			} else if window.pressed_button == MOUSE_RIGHT {
				coords = &window.down_right
			}

			if window.pressed_button == MOUSE_MIDDLE {
				sdl.CaptureMouse(true)
			}

			element_send_msg_until_received(window.pressed, .Mouse_Drag, window.click_count, coords)
		} else if msg == .Left_Up && window.pressed_button == MOUSE_LEFT {
			// if the left mouse button was released - and this button that was pressed to begin with
			if window.hovered == window.pressed {
				element_message(window.pressed, .Clicked, di, dp)
			}

			// stop pressing the element
			element_message(window.pressed, .Left_Up, di, dp)
			window_set_pressed(window, nil, MOUSE_LEFT)
		} else if msg == .Middle_Up && window.pressed_button == MOUSE_MIDDLE {
			element_message(window.pressed, .Middle_Up, di, dp)
			window_set_pressed(window, nil, MOUSE_MIDDLE)
			sdl.CaptureMouse(false)
		} else if msg == .Right_Up && window.pressed_button == MOUSE_RIGHT {
			element_message(window.pressed, .Right_Up, di, dp)
			window_set_pressed(window, nil, MOUSE_RIGHT)
		}
	}

	if window.pressed != nil {
		// While a mouse button is held, the hovered element is either the pressed element,
		// or the window element (at the root of the hierarchy).
		// Other elements are not allowed to be considered hovered until the button is released.
		// Here, we update the hovered field and send out MSG_UPDATE messages as necessary.

		inside := rect_contains(window.pressed.clip, window.cursor_x, window.cursor_y)

		if inside && window.hovered == &window.element {
			window.hovered = window.pressed
			element_message(window.pressed, .Update, UPDATE_HOVERED)
		} else if !inside && window.hovered == window.pressed {
			window.hovered = &window.element
			element_message(window.pressed, .Update, UPDATE_HOVERED)
		}
	} else {
		// no element is currently pressed
		// find the element we're hovering over
		hovered := element_find_by_point(&window.element, window.cursor_x, window.cursor_y)

		#partial switch msg {
			case .Mouse_Move: {
				// if the mouse was moved, tell the hovered parent
				element_message(hovered, .Mouse_Move, di, dp)
				cursor := cast(Cursor) element_message(hovered, .Get_Cursor)
				
				if cursor != window.cursor {
					window_set_cursor(window, cursor)
				}
			} 

			case .Left_Down: {
				// if the left mouse button is pressed, start pressing the hovered element
				window_set_pressed(window, hovered, MOUSE_LEFT)
				element_message(hovered, msg, window.click_count, dp)
			}

			case .Middle_Down: {
				// if the middle mouse button is pressed, start pressing the hovered element
				window_set_pressed(window, hovered, MOUSE_MIDDLE)
				element_send_msg_until_received(hovered, msg, di, dp)
			}

			case .Right_Down: {
				// if the middle mouse button is pressed, start pressing the hovered element
				window_set_pressed(window, hovered, MOUSE_RIGHT)
				element_message(hovered, msg, di, dp)
			}

			case .Key_Combination: {
				handled := window_send_msg_to_focused_or_parents(window, .Key_Combination, di, dp)
				res = handled

				// NOTE could add tab movement on "tab" or "shift tab"
			}

			case .Unicode_Insertion: {
				handled := window_send_msg_to_focused_or_parents(window, .Unicode_Insertion, di, dp)
				res = handled
			}

			case .Mouse_Scroll_X: {
				element_send_msg_until_received(window.hovered, .Mouse_Scroll_X, di, dp)
			}

			case .Mouse_Scroll_Y: {
				element_send_msg_until_received(window.hovered, .Mouse_Scroll_Y, di, dp)
			}
		}

		// update the hovered element if necessary
		if hovered != window.hovered {
			previous := window.hovered
			window.hovered = hovered
			window.hovered_start = time.tick_now()

			element_message(previous, .Update, UPDATE_HOVERED)
			element_message(window.hovered, .Update, UPDATE_HOVERED)
		} else {
			// same hovered, do diff check
			e := window.hovered

			if (.Hide in window.hovered_panel.flags) {
				if (.Hover_Has_Info in e.flags) {
					diff := time.tick_since(window.hovered_start)

					if diff > HOVER_TIME {
						window_hovered_panel_spawn(window, e)
						element_repaint(&window.element)
					}
				}
			} else {
				if (.Hover_Has_Info not_in e.flags) {
					element_hide(window.hovered_panel, true)
					element_repaint(&window.element)
				}
			}
		}
	}

	return
}

window_set_pressed :: proc(window: ^Window, element: ^Element, button: int) {
	previous := window.pressed

	window.pressed = element
	window.pressed_button = button

	if previous != nil {
		element_message(previous, .Update, UPDATE_PRESSED)
	}

	if element != nil {
		element_message(element, .Update, UPDATE_PRESSED)
	}

	// click timing
	if element != nil {
		// reset click count on different element
		if window.clicked_last != element {
			window.click_count = 0
		} else {
			if window.clicked_start == {} {
				window.click_count = 0
				// window.clicked_start = time.tick_now()
			} else {
				diff := time.tick_since(window.clicked_start)

				// increase or reset when below time limit
				if diff < MOUSE_CLICK_TIME {
					window.click_count += 1
				} else {
					window.click_count = 0
				}
			}
		}

		window.clicked_last = element
		window.clicked_start = time.tick_now()
	}
}

window_title_build :: proc(window: ^Window, text: string) {
	b := &window.title_builder
	strings.builder_reset(b)
	strings.write_string(b, text)
	strings.write_byte(b, '\x00')
	ctext := strings.unsafe_string_to_cstring(strings.to_string(b^))
	sdl.SetWindowTitle(window.w, ctext)
}

window_destroy :: proc(window: ^Window) {
	undo_manager_destroy(window.manager)
	render_target_destroy(window.target)
	delete(window.shortcuts)
	element_destroy(&window.element)
	element_deallocate(&window.element)
	delete(window.combo_builder.buf)
	delete(window.title_builder.buf)
	sdl.DestroyWindow(window.w)
}

window_layout_update :: proc(window: ^Window) {
	window.element.bounds = { 0, window.widthf, 0, window.heightf }
	window.element.clip = window.element.bounds
	window.modifiable_bounds = window.element.bounds
	window.update_next = true
}

window_build_combo :: proc(window: ^Window, key: sdl.KeyboardEvent) -> (res: string, ok: bool) {
	was_ctrl := key.keysym.scancode == .LCTRL || key.keysym.scancode == .RCTRL
	was_shift := key.keysym.scancode == .LSHIFT || key.keysym.scancode == .RSHIFT
	was_alt := key.keysym.scancode == .LALT || key.keysym.scancode == .RALT
	was_gui := key.keysym.scancode == .LGUI || key.keysym.scancode == .RGUI

	if was_ctrl || was_shift || was_alt || was_gui {
		return
	}

	using strings
	b := &window.combo_builder
	builder_reset(b)
	
	if window.ctrl {
		write_string(b, "ctrl+")
	}
	
	if window.shift {
		write_string(b, "shift+")
	}
	
	if window.alt {
		write_string(b, "alt+")
	}
	
	key_name := sdl.GetKeyName(key.keysym.sym)
	write_string(b, string(key_name))

	ok = true	
	res = to_lower(to_string(b^), context.temp_allocator)
	return
}

window_handle_event :: proc(window: ^Window, e: ^sdl.Event) {
	#partial switch e.type {
		case .WINDOWEVENT: {
			// log.info("window id", e.window.windowID, window.w_id == e.window.windowID)
			
			if window.w_id != e.window.windowID {
				return
			}

			#partial switch e.window.event {
				case .CLOSE: {
					gs.ignore_quit = true
						
					if element_message(&window.element, .Window_Close) == 0 {
						// log.info("hide window")
						element_destroy(&window.element)
						sdl.HideWindow(window.w)
	
						// post another quit message in case its flushed by dialog
						if len(gs.windows) == 1 {
							// log.info("send quit event")
							custom_event: sdl.Event
							custom_event.type = .QUIT
							sdl.PushEvent(&custom_event)
						}

						gs.ignore_quit = false
					}
				}

				case .RESIZED: {
					window.width = int(e.window.data1)
					window.widthf = f32(window.width)
					window.height = int(e.window.data2)
					window.heightf = f32(window.height)					
					window.update_next = true
				}

				// called on first shown
				case .EXPOSED: {
					if window.update != nil {
						window.update()
					}

					window_poll_size(window)
					window_layout_update(window)
				}
			}
		}

		case .QUIT: {
			if gs.ignore_quit {
				return
			}

			gs.running = false

			for w in gs.windows {
				w.dialog_finished = true
			}
		}

		case .KEYDOWN: {
			if e.key.windowID != window.w_id {
				return
			}

			if combo, ok := window_build_combo(window, e.key); ok {
				if window_input_event(window, .Key_Combination, 0, &combo) {
					window.ignore_text_input = true
				}
			}
		}

		case .TEXTINPUT: {
			if e.text.windowID != window.w_id {
				return
			}

			if window.ignore_text_input {
				return
			} 

			// nul search through fixed string
			nul := -1
			nul_search: for i in 0..<32 {	
			if e.text.text[i] == 0 {
					nul = i
					break nul_search
				}
			}

			r, size := utf8.decode_rune(e.text.text[:nul])
			window_input_event(window, .Unicode_Insertion, 0, &r)
		}

		case .MOUSEWHEEL: {
			if e.wheel.windowID != window.w_id {
				return
			}

			direction: i32 = 1
			if e.wheel.direction == u32(sdl.SDL_MouseWheelDirection.FLIPPED) {
				direction *= -1
			}

			// scroll up
			if e.wheel.y != 0 {
				window_input_event(window, .Mouse_Scroll_Y, int(e.wheel.y * direction))
			}

			if e.wheel.x != 0 {
				window_input_event(window, .Mouse_Scroll_X, int(e.wheel.x * direction))
			}
		}

		case .MOUSEMOTION: {
			if e.motion.windowID != window.w_id {
				return
			}

			window.cursor_x = f32(e.motion.x)
			window.cursor_y = f32(e.motion.y)
			window_input_event(window, .Mouse_Move)
		}

		case .MOUSEBUTTONDOWN: {
			if e.button.windowID != window.w_id {
				return
			}

			if e.button.button == sdl.BUTTON_LEFT {
				window.down_left = { f32(e.button.x), f32(e.button.y) }
				window_input_event(window, .Left_Down, int(e.button.clicks))
			} else if e.button.button == sdl.BUTTON_MIDDLE {
				window.down_middle = { f32(e.button.x), f32(e.button.y) }
				window_input_event(window, .Middle_Down, int(e.button.clicks))
			} else if e.button.button == sdl.BUTTON_RIGHT {
				window.down_right = { f32(e.button.x), f32(e.button.y) }
				window_input_event(window, .Right_Down, int(e.button.clicks))
			}
		}

		case .MOUSEBUTTONUP: {
			if e.button.windowID != window.w_id {
				return
			}

			if e.button.button == sdl.BUTTON_LEFT {
				window_input_event(window, .Left_Up)
			} else if e.button.button == sdl.BUTTON_MIDDLE {
				window_input_event(window, .Middle_Up)
			} else if e.button.button == sdl.BUTTON_RIGHT {
				window_input_event(window, .Right_Up)
			}
		}
	}
}

gs_init :: proc() {
	using gs
	logger = log.create_console_logger()
	context.logger = logger
	windows = make([dynamic]^Window, 0, 8)
	running = true

	err := sdl.Init(sdl.INIT_VIDEO | sdl.INIT_EVENTS)
	if err != 0 {
		log.panicf("SDL2: failed to initialize %d", err)
	}

	sdl.StartTextInput()
	sdl.EnableScreenSaver()
	sdl.SetHint(sdl.HINT_VIDEO_X11_NET_WM_BYPASS_COMPOSITOR, "0")

	// create cursors
	cursors[.Arrow] = sdl.CreateSystemCursor(.ARROW)
	cursors[.IBeam] = sdl.CreateSystemCursor(.IBEAM)
	cursors[.Hand] = sdl.CreateSystemCursor(.HAND)
	cursors[.Resize_Horizontal] = sdl.CreateSystemCursor(.SIZEWE)
	cursors[.Resize_Vertical] = sdl.CreateSystemCursor(.SIZENS)
	cursors[.Crosshair] = sdl.CreateSystemCursor(.CROSSHAIR)

	fontstash.init(1000, 1000)
	fonts_init()
}

gs_destroy :: proc() {
	using gs

	fontstash.destroy()
	fonts_destroy()
	log.destroy_console_logger(&logger)

	for cursor in cursors {
		sdl.FreeCursor(cursor)
	}

	for window in windows {
		window_destroy(window)
	}

	delete(windows)
	sdl.Quit()
}

window_flush_mouse_state :: proc(window: ^Window) {
	for i in 1..<4 {
		window_set_pressed(window, nil, i)
	}
}

gs_flush_events :: proc() {
	sdl.PumpEvents()
	sdl.FlushEvents(.FIRSTEVENT, .LASTEVENT)
}

gs_process_events :: proc() {
	// query ctrl, shift, alt state
	ctrl, shift, alt: bool
	num: i32
	num = 0
	state := sdl.GetKeyboardState(&num)
	shift = state[sdl.SCANCODE_LSHIFT] == 1 || state[sdl.SCANCODE_RSHIFT] == 1
	ctrl = state[sdl.SCANCODE_LCTRL] == 1 || state[sdl.SCANCODE_RCTRL] == 1
	alt = state[sdl.SCANCODE_LALT] == 1 || state[sdl.SCANCODE_RALT] == 1

	// prep window state once
	for window in &gs.windows {
		window.ctrl = ctrl
		window.shift = shift
		window.alt = alt
		window.ignore_text_input = false
	}	  	

	// iterate events
	event: sdl.Event
	for sdl.PollEvent(&event) {
		for window in &gs.windows {
			window_handle_event(window, &event)
		}
	}
}

gs_message_loop :: proc() {
	context.logger = gs.logger
	
	for gs.running {
		// when animating
		if len(gs.animating) != 0 {
			gs.frame_start = sdl.GetPerformanceCounter()
			gs_process_animations()
			gs_process_events()
		} else {
			// wait for event to arive
			available := sdl.WaitEvent(nil)
			// set frame start after waiting
			gs.frame_start = sdl.GetPerformanceCounter()
			gs_process_events()
		}
		
		// repaint all of the window
		gs_draw_and_cleanup()

		// TODO maybe time the section of time that was waited on?
		// update frame counter
		{
			frame_end := sdl.GetPerformanceCounter()
			elapsed_ms := f64(frame_end - gs.frame_start) / f64(sdl.GetPerformanceFrequency())
			gs.dt = f32(elapsed_ms)
		}
	}

	gs_destroy()
}

// send animations messages
gs_process_animations :: proc() {
	for element in gs.animating {
		// allow elmeent to animate multiple things until it returns 0
		if element_message(element, .Animate) == 0 {
			element_animation_stop(element)
		}

		// NOTE repaint even on last frame
		element_repaint(element)
	}
}

gs_draw_and_cleanup :: proc() {
	context.logger = gs.logger 

	// for window in &gs.windows {
	for i := len(gs.windows) - 1; i >= 0; i -= 1 {
		window := gs.windows[i]

		// anything to destroy?
		if element_deallocate(&window.element) {
			unordered_remove(&gs.windows, i)
			// log.info("dealloc window")
		} else if window.update_next {
			if window.update != nil {
				window.update()
			}

			render_target_begin(window.target, theme.shadow)
			element_message(&window.element, .Layout, LAYOUT_FULL)
			render_element_clipped(window.target, &window.element)
			render_target_end(window.target, window.w, i32(window.width), i32(window.height))

			// TODO could use specific update region only
			window.update_next = false
		}
	}
}

//////////////////////////////////////////////
// dialog
//////////////////////////////////////////////

dialog_message :: proc(element: ^Element, msg: Message, di: int, dp: rawptr) -> int {
	#partial switch msg {
		case .Layout: {
			w := element.window
			assert(len(element.children) != 0)
			
			// TODO poll max necessary width
			width := 300 * w.scale
			height := 100 * w.scale

			// set dialog size
			element.bounds = rect_wh(
				w.widthf / 2 - width / 2, 
				w.heightf / 2 - height / 2, 
				width,
				height,
			)
			element.clip = element.bounds
			
			// set panel bounds
			panel := element.children[0]
			element_message(panel, .Layout, di, dp)
		}

		case .Update: {
			panel := element.children[0]
			element_message(panel, .Update, di, dp)
		}
	}

	return 0
}

dialog_spawn :: proc(
	window: ^Window,
	text_arguments: ..string,
) -> string {
	if window.dialog != nil {
		return ""
	}

	window.dialog = element_init(Element, &window.element, {}, dialog_message)
	panel := panel_init(window.dialog, { .CF })
	panel.color = { 255, 210, 210, 255 }
	panel.margin = 10
	panel.gap = 5
	panel.shadow = true
	window.dialog.z_index = 255

	dialog_output: string

	label_init(panel, { .CT, .CF }, text_arguments[0])
	focus_next: ^Element

	for i in 1..<len(text_arguments) {
		word := text_arguments[i]
		assert(len(word) >= 2)

		// get text arguments
		format := word[:2]
		text := word[2:]

		// TODO add more element options
		switch format {
			case "%b": {
				b := button_init(panel, { .CR }, text)
				b.data = &dialog_output

				if focus_next == nil {
					incl(&b.flags, Element_Flag.Button_Can_Focus)
					focus_next = b
				}
			
				b.message_user = proc(element: ^Element, msg: Message, di: int, dp: rawptr) -> int {
					window := element.window
					button := cast(^Button) element
					output := cast(^string) element.data

					if msg == .Clicked {
						output^ = strings.clone(strings.to_string(button.builder), context.temp_allocator)
						window.dialog_finished = true
					}

					return 0
				}
			}
		}
	}

	window.dialog_finished = false
	old_focus := window.focused
	assert(focus_next != nil)
	element_focus(focus_next)
	defer element_focus(old_focus)

	for element in window.element.children {
		if element != window.dialog {
			incl(&element.flags, Element_Flag.Disabled)
		} 
	}

	window_flush_mouse_state(window)
	window.pressed = nil
	window.hovered = nil
	window.update_next = true
	gs_draw_and_cleanup()

	for !window.dialog_finished {
		// wait for event to arive
		available := sdl.WaitEvent(nil)
		gs_process_events()

		// repaint all of the window
		gs_draw_and_cleanup()
	}

	// gs_flush_events()
	window_flush_mouse_state(window)
	window.pressed = nil
	window.hovered = nil

	for element in window.element.children {
		excl(&element.flags, Element_Flag.Disabled)
	}

	element_destroy(window.dialog)
	window.dialog = nil
	return dialog_output 
}

window_border_toggle :: proc(window: ^Window) {
	sdl.SetWindowBordered(window.w, cast(sdl.bool) window.bordered)
	window.bordered = !window.bordered
}