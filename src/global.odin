package src

import "core:thread"
import "core:image"
import "core:image/png"
import "core:fmt"
import "core:os"
import "core:time"
import "core:math"
import "core:math/ease"
import "core:mem"
import "core:log"
import "core:strings"
import "core:runtime"
import "core:unicode"
import "core:unicode/utf8"
import sdl "vendor:sdl2"
import mix "vendor:sdl2/mixer"
import gl "vendor:OpenGL"
import "../fontstash"
import "../cutf8"

LETTER_SPACING :: 0
SCALE := f32(1)
LINE_WIDTH := max(2, 2 * SCALE)
ROUNDNESS := 5.0 * SCALE
HOVER_WIDTH :: 100

Font :: fontstash.Font
data_font_icon := #load("../assets/icofont.ttf")
data_font_regular := #load("../assets/Lato-Regular.ttf")
data_font_bold := #load("../assets/Lato-Bold.ttf")
font_regular: int
font_bold: int
font_icon: int
data_sound_timer_start := #load("../assets/sounds/timer_start.wav")
data_sound_timer_stop := #load("../assets/sounds/timer_stop.wav")
data_sound_timer_resume := #load("../assets/sounds/timer_resume.wav")
data_sound_timer_ended := #load("../assets/sounds/timer_ended.wav")

// load wav files from mem or path, optional
custom_load_wav_path :: mix.LoadWAV
custom_load_wav_mem :: proc(data: []byte) -> ^mix.Chunk {
	return mix.LoadWAV_RW(sdl.RWFromMem(raw_data(data), i32(len(data))), false)
}
custom_load_wav_opt :: proc(index: Sound_Index, opt_data: []byte) {
	path := gs.sound_paths[index]
	res: ^mix.Chunk

	// load from opt path
	if path != "" {
		if strings.has_suffix(path, ".wav") {
			cpath := gs_string_to_cstring(path)
			res = custom_load_wav_path(cpath)
		} else {
			log.info("SOUND: only .wav soundfiles are allowed!")
		}
	}
	
	// loadfrom default bytes
	if res == nil {
		res = custom_load_wav_mem(opt_data)
	}

	gs.sounds[index] = res
}

sound_path_write :: proc(index: Sound_Index, text: string) {
	to := &gs.sound_paths[index] 

	if text != "" {
		to^ = strings.clone(text)
	}
}

fonts_push :: proc() {
	ctx := &gs.fc
	font_icon = 0
	font_regular = 1
	font_bold = 2
}

fonts_load_pushed :: proc() {
	ctx := &gs.fc
	fontstash.font_push(ctx, data_font_icon)

	if gs.font_regular_path != "" {
		fontstash.font_push(ctx, gs.font_regular_path, true, 20)
	} else {
		fontstash.font_push(ctx, data_font_regular, true, 20)
	}

	if gs.font_bold_path != "" {
		fontstash.font_push(ctx, gs.font_bold_path, true, 20)
	} else {
		fontstash.font_push(ctx, data_font_bold, true, 20)
	}
}

Shortcut_Proc :: proc() -> bool

HOVER_TIME :: time.Millisecond * 500
MOUSE_CLICK_TIME :: time.Millisecond * 500
MOUSE_LEFT :: 1
MOUSE_MIDDLE :: 2
MOUSE_RIGHT :: 3
Mouse_Coordinates :: [2]f32

Window :: struct {
	element: Element,
	
	// interactable elements
	hovered: ^Element,
	pressed: ^Element,
	pressed_last: ^Element,
	focused: ^Element,

	// hovered info 
	hovered_start: time.Tick, // when the element was first hovered
	hovered_panel: ^Panel_Floaty, // set in init, but hidden

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
	target: ^Render_Target,
	
	// sdl data
	w: ^sdl.Window,
	w_id: u32,
	cursor: Cursor,
	// bordered: bool,

	// key state
	combo_builder: strings.Builder,
	ignore_text_input: bool,
	ctrl, shift, alt: bool,

	// assigned shortcuts to procedures in window
	shortcut_state: Shortcut_State,

	// wether a dialog is currently showing
	dialog: ^Element,
	dialog_finished: bool,
	dialog_builder: strings.Builder,

	// menu
	menu: ^Panel_Floaty,

	// proc that gets called before layout & draw
	update: proc(window: ^Window),

	// undo / redo
	manager: Undo_Manager,

	// title
	title_builder: strings.Builder,

	// drop handling
	drop_indices: [dynamic]int, // indices into the file name builder
	drop_file_name_builder: strings.Builder,

	// arena
	element_arena: mem.Arena,
	element_arena_backing: []byte,

	// callbacks
	on_resize: proc(window: ^Window),

	// next window
	window_next: ^Window,
}

Cursor :: enum {
	Arrow,
	IBeam,
	Hand,
	Hand_Drag,
	Resize_Vertical,
	Resize_Horizontal,
	Crosshair,
}

Global_State :: struct {
	windows: ^Window,

	// only used in iteration, never double iter :)
	windows_iter: ^Window,

	// logger data
	logger: log.Logger,
	log_path: string, // freed at destroy
	pref_path: string, // freed at destroy
	base_path: string, // freed at destroy
	cstring_builder: strings.Builder,

	// builder to store clipboard content
	copy_builder: strings.Builder,

	running: bool,
	cursors: [Cursor]^sdl.Cursor,

	frame_start: u64,
	dt: f32,

	// animating elements
	animating: [dynamic]^Element,

	// event intercepting
	ignore_quit: bool,

	audio_ok: bool, // true when sdl mix module loaded fine
	sound_paths: [Sound_Index]string,
	sounds: [Sound_Index]^mix.Chunk,
	flux: ease.Flux_Map(f32),

	// stores multiple png images
	stored_images: map[string]Stored_Image,
	stored_image_thread: ^thread.Thread,
	
	window_hovering_timer: sdl.TimerID,

	font_regular_path: string,
	font_bold_path: string,

	track: mem.Tracking_Allocator,
	fc: fontstash.Font_Context,
}
gs: ^Global_State

Stored_Image_Load_Finished :: proc(img: ^Stored_Image, data: rawptr)
Stored_Image :: struct {
	using backing: ^image.Image,
	handle: u32,
	handle_set: bool,
	loaded: bool,
	cloned_path: string, // removed automatically
}

// push a load command and create a thread if not existing yet
image_load_push :: proc(path: string) -> (res: ^Stored_Image) {
	out, ok := &gs.stored_images[path]

	if !ok {
		if gs.stored_image_thread == nil {
			gs.stored_image_thread = thread.create_and_start(image_load_process_on_thread)
		} 

		cloned_path := strings.clone(path, context.allocator)
		gs.stored_images[cloned_path] = { cloned_path = path }
		out = &gs.stored_images[path]
	} 

	res = out
	return
}

// loads an image from a file
image_load_from_file :: proc(path: string) -> (res: ^image.Image) {
	content, ok := os.read_entire_file(path)
	
	if !ok {
		log.error("IMAGE: path not found", path)
		return
	}

	err: image.Error
	res, err = png.load_from_bytes(content)

	if err != nil {
		log.error("IMAGE: png load failed")
		res = nil
		return
	}

	return
}

// loads images on a seperate thread to the stored data
image_load_process_on_thread :: proc(t: ^thread.Thread) {
	for key, img in &gs.stored_images {
		// loading needs to be done
		if !img.loaded {
			img.backing = image_load_from_file(key)
			img.loaded = true
			fmt.eprintln("image load finished", key, img.backing == nil)
		}
	}

	gs.stored_image_thread = nil
	thread.destroy(t)
}

image_load_process_texture_handles :: proc(window: ^Window) {
	for key, img in &gs.stored_images {
		if img.backing != nil && img.loaded && !img.handle_set {
			fmt.eprintln("generated handle on main thread", img.handle)
			img.handle = shallow_texture_init(window.target, img.backing)
			img.handle_set = true
		}
	}
}

Sound_Index :: enum {
	Timer_Start,
	Timer_Stop,
	Timer_Resume,
	Timer_Ended,
}

// play a single sound
sound_play :: proc(index: Sound_Index) {	
	if gs.audio_ok {
		mix.PlayChannel(0, gs.sounds[index], 0)
	}
}

// get volume at 0-128
mix_volume_get :: proc() -> i32 {
	if gs.audio_ok {
		return mix.Volume(0, -1)
	} else {
		return 0
	}
}

// set to 0-128
mix_volume_set :: proc(to: i32) {
	if gs.audio_ok {
		mix.Volume(0, to)
	}
}

window_destroy :: proc(window: ^Window) {
	sdl.HideWindow(window.w)
	element_destroy(&window.element)
	sdl_push_empty_event()
}

window_init :: proc(
	owner: ^Window,
	flags: Element_Flags,
	title: cstring, 
	w, h: i32,
	arena_cap: int,
) -> (res: ^Window) {
	// TODO other menus close?
	// menus_close()

	x_pos := i32(sdl.WINDOWPOS_UNDEFINED)
	y_pos := i32(sdl.WINDOWPOS_UNDEFINED)
	window_flags: sdl.WindowFlags = { .OPENGL, .HIDDEN }

	if .Window_Menu not_in flags {
		window_flags |= { .RESIZABLE }
	} else {
		window_flags |= { .BORDERLESS }
	}

	if .Window_Center_In_Owner in flags {
		x_pos	= sdl.WINDOWPOS_CENTERED
		y_pos	= sdl.WINDOWPOS_CENTERED
	}

	window := sdl.CreateWindow(
		title, 
		x_pos,
		y_pos,
		w,
		h,
		window_flags,
	)
	if window == nil {
		sdl.Quit()
		log.panic("SDL2: error during window creation %v", sdl.GetError())
	}
	window_id := sdl.GetWindowID(window)
	
	if .Window_Menu in flags {
		sdl.RaiseWindow(window)
	}

	_window_message :: proc(element: ^Element, msg: Message, di: int, dp: rawptr) -> int {
		window := cast(^Window) element

		#partial switch msg {
			case .Layout: {
				for child in element.children {
					element_move(child, element.bounds)
				}
			}

			case .Deallocate: {
				// NEEDS TO BE CALLED IN HERE, CUZ OTHERWHISE ITS ALREADY REMOVED
				window_deallocate(window)
			}
		}

		return 0
	}

	// spawn an arena

	window_element_flags := flags
	window_element_flags |= { .Tab_Movement_Allowed, .Sort_By_Z_Index }

	res = element_init(
		Window, 
		nil, 
		window_element_flags,
		_window_message,
		context.allocator,
	)

	res.element_arena_backing = make([]byte, arena_cap)
	mem.arena_init(&res.element_arena, res.element_arena_backing)

	res.w = window
	res.w_id = window_id
	res.hovered = &res.element
	res.combo_builder = strings.builder_make(0, 32)
	res.title_builder = strings.builder_make(0, 64)
	res.dialog_builder = strings.builder_make(0, 64)
	res.target = render_target_init(window)
	res.update_next = true
	res.cursor_x = -100
	res.cursor_y = -100
	res.drop_file_name_builder = strings.builder_make(0, mem.Kilobyte * 2)
	res.drop_indices = make([dynamic]int, 0, 128)
	res.width = int(w)
	res.widthf = f32(w)
	res.height = int(h)
	res.heightf = f32(h)
	res.element.name = "WINDOW"
	undo_manager_init(&res.manager)

	res.element.window = res
	res.window_next = gs.windows
	gs.windows = res
	shortcut_state_init(&res.shortcut_state, mem.Megabyte * 2)

	// set hovered panel
	{
		floaty := panel_floaty_init(&res.element, {})
		floaty.width = HOVER_WIDTH * SCALE
		// floaty.height = DEFAULT_FONT_SIZE * SCALE + TEXT_MARGIN_VERTICAL * SCALE
		p := floaty.panel
		p.flags |= { .Panel_Expand }
		p.shadow = true
		p.rounded = true
		label_init(p, { .Label_Center })
		res.hovered_panel = floaty
		element_hide(floaty, true)
	}

	// menu panel
	{
		menu := panel_floaty_init(&res.element, {})
		// menu.panel.flags ~= { .Panel_Default_Background }
		// menu.panel.color = RED
		element_hide(menu, true)
		res.menu = menu
	}

	return
}

gs_update_after_load :: proc() {
	floaty := window_main.hovered_panel
	floaty.height = DEFAULT_FONT_SIZE * SCALE + TEXT_MARGIN_VERTICAL * SCALE

	if gs.audio_ok {
		custom_load_wav_opt(.Timer_Start, data_sound_timer_start)
		custom_load_wav_opt(.Timer_Stop, data_sound_timer_stop)
		custom_load_wav_opt(.Timer_Resume, data_sound_timer_resume)
		custom_load_wav_opt(.Timer_Ended, data_sound_timer_ended)
	}
}

window_allocator :: proc(window: ^Window) -> mem.Allocator {
	return mem.arena_allocator(&window.element_arena)
}

window_hovered_panel_spawn :: proc(window: ^Window, element: ^Element, text: string) {
	floaty := window.hovered_panel
	element_hide(floaty, false)
	
	p := floaty.panel
	floaty.x = window.cursor_x

	// NOTE static
	label := cast(^Label) p.children[0]
	strings.builder_reset(&label.builder)
	strings.write_string(&label.builder, text)

	goal_y := element.bounds.b + 5

	// bounds check
	if goal_y + floaty.height > window.heightf {
		goal_y = element.bounds.t - floaty.height
	}

	floaty.y = goal_y
	scaled_size := i16(DEFAULT_FONT_SIZE * SCALE)

	fontstash.state_set_size(&gs.fc, DEFAULT_FONT_SIZE * SCALE)
	text_width := fontstash.text_bounds(&gs.fc, text)
	floaty.width = max(HOVER_WIDTH * SCALE, text_width + TEXT_MARGIN_HORIZONTAL * SCALE)

	if floaty.x + floaty.width > window.widthf {
		floaty.x = window.widthf - floaty.width - 5
	}
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

window_mouse_inside :: proc(window: ^Window) -> bool {
	rect := window_rect(window)
	return rect_contains(rect, window.cursor_x, window.cursor_y)
}

// get xy
window_get_position :: proc(window: ^Window) -> (int, int) {
	x, y: i32
	sdl.GetWindowPosition(window.w, &x, &y)
	return int(x), int(y)
}

// set xy
window_set_position :: proc(window: ^Window, x, y: int) {
	sdl.SetWindowPosition(window.w, i32(x), i32(y))
}

// set size of window
window_set_size :: proc(window: ^Window, w, h: int) {
	sdl.SetWindowSize(window.w, i32(w), i32(h))
}

// NOTE ignores pixel border of 1
window_border_size :: proc(window: ^Window) -> (top, left, bottom, right: int) {
	t, l, b, r: i32
	res := sdl.GetWindowBordersSize(window.w, &t, &l, &b, &r)
	
	if res == 0 {
		top = int(t)
		left = int(l)
		bottom = int(b)
		right = int(r)
	} else {
		log.error("WINDOW BORDER SIZE call not supported")
	}

	return 
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
			
			if window.dialog != nil && e == window.dialog {
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
	if msg == .Dropped_Files {
		to := window.hovered == nil ? &window.element : window.hovered
		element_send_msg_until_received(to, msg, di, dp)
		return
	}

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

			sdl.CaptureMouse(true)
			element_send_msg_until_received(window.pressed, .Mouse_Drag, window.click_count, coords)
		} else if msg == .Left_Up && window.pressed_button == MOUSE_LEFT {
			// if the left mouse button was released - and this button that was pressed to begin with
			if window.hovered == window.pressed {
				element_message(window.pressed, .Clicked, di, dp)
			}

			// stop pressing the element
			element_message(window.pressed, .Left_Up, di, dp)
			window_set_pressed(window, nil, MOUSE_LEFT)
			sdl.CaptureMouse(false)
		} else if msg == .Middle_Up && window.pressed_button == MOUSE_MIDDLE {
			element_message(window.pressed, .Middle_Up, di, dp)
			window_set_pressed(window, nil, MOUSE_MIDDLE)
			sdl.CaptureMouse(false)
		} else if msg == .Right_Up && window.pressed_button == MOUSE_RIGHT {
			element_message(window.pressed, .Right_Up, di, dp)
			window_set_pressed(window, nil, MOUSE_RIGHT)
			sdl.CaptureMouse(false)
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
		// p := Find_By_Point { window.cursor_x, window.cursor_y, nil }
		hovered := element_find_by_point(&window.element, window.cursor_x, window.cursor_y)

		#partial switch msg {
			case .Mouse_Move: {
				// if the mouse was moved, tell the hovered parent
				element_message(hovered, .Mouse_Move, di, dp)
				wanted_cursor := element_message(hovered, .Get_Cursor)
				cursor := cast(Cursor) wanted_cursor
				
				if cursor != window.cursor {
					window_set_cursor(window, cursor)
				}
			} 

			case .Left_Down: {
				if element_is_from_menu(window, hovered) || !menu_close(window) {
					// if the left mouse button is pressed, start pressing the hovered element
					window_set_pressed(window, hovered, MOUSE_LEFT)
					element_message(hovered, msg, window.click_count, dp)
				}
			}

			case .Middle_Down: {
				if element_is_from_menu(window, hovered) || !menu_close(window) {
					// if the middle mouse button is pressed, start pressing the hovered element
					window_set_pressed(window, hovered, MOUSE_MIDDLE)
					element_send_msg_until_received(hovered, msg, di, dp)
				}
			}

			case .Right_Down: {
				if element_is_from_menu(window, hovered) || !menu_close(window) {
					// if the middle mouse button is pressed, start pressing the hovered element
					window_set_pressed(window, hovered, MOUSE_RIGHT)
					element_message(hovered, msg, di, dp)
				}
			}

			case .Key_Combination: {
				handled := false

				// quick ask window element
				if window.focused == nil {
					if element_message(&window.element, msg, di, dp) == 1 {
						handled = true
					}
				}

				if !handled && !window.ctrl && !window.alt {
					combo := (cast(^string) dp)^
					match := combo == "tab" || combo == "shift+tab"
					backwards := window.shift

					// NOTE allows arrow based movement on dialog
					if window.dialog != nil {
						match |= combo == "up" || combo == "down" || combo == "left" || combo == "right"
						backwards |= combo == "up" || combo == "left" 
					}

					if match {
						start := window.focused != nil ? window.focused : &window.element
						element := start
						first := true
						
						cond :: proc(element, start: ^Element, first: ^bool) -> bool {
							if first^ {
								first^ = false
								return true
							}

							return element != start && (
								(.Tab_Stop not_in element.flags) ||
								(.Hide in element.flags)
							)
						}

						// simulate do while
						next_search: for cond(element, start, &first) {
							// set to first child?
							if 
								(.Tab_Movement_Allowed in element.flags) &&
								len(element.children) != 0 && 
								(.Hide not_in element.flags) && 
								element.clip != {} 
							{
								if backwards {
									element = element.children[len(element.children) - 1]
								} else {
									element = element.children[0]
								}

								continue
							}

							// set sibling
							for element != nil {
								sibling := element_next_or_previous_sibling(element, backwards)

								if sibling != nil {
									element = sibling
									break
								}

								if window.dialog == nil {
									element = element.parent
								} else {
									// skip dialog element setting
									element = start
									break next_search
								}
							}

							// set to window element
							if element == nil {
								element = &window.element
							}
						}

						element_focus(element)
						element_repaint(element)
						handled = true
					}
				} 

				if !handled {
					handled = window_send_msg_to_focused_or_parents(window, .Key_Combination, di, dp)
				}

				res = handled
			}

			case .Unicode_Insertion: {
				if menu_close(window) {
					return false
				}

				handled := window_send_msg_to_focused_or_parents(window, .Unicode_Insertion, di, dp)
				res = handled
			}

			case .Mouse_Scroll_X: {
				di := di * options_scroll_x()
				element_send_msg_until_received(window.hovered, .Mouse_Scroll_X, di, dp)
			}

			case .Mouse_Scroll_Y: {
				di := di * options_scroll_y()
				element_send_msg_until_received(window.hovered, .Mouse_Scroll_Y, di, dp)
			}
		}

		// update the hovered element if necessary
		if hovered != window.hovered {
			previous := window.hovered
			window.hovered = hovered
			window.hovered_start = time.tick_now()
			window.pressed_last = nil

			element_message(previous, .Update, UPDATE_HOVERED_LEAVE)
			element_message(window.hovered, .Update, UPDATE_HOVERED)
		} else {
			window_hovered_check(window)
		}
	}

	return
}

element_next_or_previous_sibling :: proc(element: ^Element, shift: bool) -> ^Element {
	if element.parent == nil {
		return nil
	}

	children := element.parent.children
	for e, i in children {
		if e == element {
			// shift moves backwards
			if shift {
				return i > 0 ? children[i - 1] : nil
			} else {
				return i < len(children) - 1 ? children[i + 1] : nil
			}
		}
	}

	unimplemented("ELEMENT_NEXT_OR_PREVIOUS_SIBLING FAILED")
}

window_hovered_check :: proc(window: ^Window) -> bool {
	// same hovered, do diff check
	e := window.hovered
	if e == nil || window.hovered_panel == nil {
		return false
	}

	if (.Hide in window.hovered_panel.flags) {
		if e.hover_info != "" && window.pressed_last != e {
			diff := time.tick_since(window.hovered_start)

			if diff > HOVER_TIME {
				text := e.hover_info
				window_hovered_panel_spawn(window, e, text)
				element_repaint(&window.element)
				return true
			}
		}
	} else {
		// hide away again on non info
		if e.hover_info == "" {
			element_hide(window.hovered_panel, true)
			element_repaint(&window.element)
			return true
		}

		if window.pressed_last == e {
			element_hide(window.hovered_panel, true)
			element_repaint(&window.element)					
			return true
		}
	}

	return false
}

window_set_pressed :: proc(window: ^Window, element: ^Element, button: int) {
	previous := window.pressed

	window.pressed = element
	window.pressed_button = button

	if previous != nil {
		element_message(previous, .Update, UPDATE_PRESSED_LEAVE)
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

	// save non nil pressed
	if element != nil {
		window.pressed_last = element
	}
}

window_title_push_builder :: proc(window: ^Window, builder: ^strings.Builder) {
	strings.write_byte(builder, '\x00')
	ctext := strings.unsafe_string_to_cstring(strings.to_string(builder^))
	sdl.SetWindowTitle(window.w, ctext)
}

window_deallocate :: proc(window: ^Window) {
	log.info("WINDOW: Deallocate START")
	shortcut_state_destroy(&window.shortcut_state)

	free_all(mem.arena_allocator(&window.element_arena))
	delete(window.element_arena_backing)
	delete(window.drop_indices)
	delete(window.drop_file_name_builder.buf)

	undo_manager_destroy(window.manager)
	render_target_destroy(window.target)
	delete(window.combo_builder.buf)
	delete(window.title_builder.buf)
	delete(window.dialog_builder.buf)
	sdl.DestroyWindow(window.w)
	log.info("WINDOW: Deallocate END")
}

window_layout_update :: proc(window: ^Window) {
	window.element.bounds = { 0, window.widthf, 0, window.heightf }
	window.element.clip = window.element.bounds
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
						log.warn("WINDOW CLOSE EVENT DESTROY")
						window_destroy(window)
						gs.ignore_quit = false
					}
				}

				case .RESIZED: {
					window.width = int(e.window.data1)
					window.widthf = f32(window.width)
					window.height = int(e.window.data2)
					window.heightf = f32(window.height)	
					window.update_next = true

					if window.on_resize != nil {
						window->on_resize()
					}
				}

				// called on first shown
				case .EXPOSED: {
					if window.update != nil {
						window->update()
					}

					window_poll_size(window)
					window_layout_update(window)
				}

				case .FOCUS_GAINED: {
					// flush key event when gained
					sdl.FlushEvent(.KEYDOWN)
				}
			}
		}

		case .KEYDOWN: {
			if e.key.windowID != window.w_id {
				return
			}

			if menu_close(window) {
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

		// write indices & text content linearly, not send over message!
		case .DROPBEGIN, .DROPCOMPLETE, .DROPFILE, .DROPTEXT: {
			if e.drop.windowID != window.w_id {
				return
			}

			b := &window.drop_file_name_builder
			indices := &window.drop_indices

			if e.type == .DROPBEGIN {
				clear(indices)
				clear(&b.buf)
			} else if e.type == .DROPCOMPLETE {
				window_input_event(window, .Dropped_Files)
			} else if e.type == .DROPFILE {
				text := string(e.drop.file)
				strings.write_string(b, text)
				append(indices, len(b.buf))
			}
		}
	}
}

gs_windows_iter_init :: proc() {
	gs.windows_iter = gs.windows
}

gs_windows_iter_step :: proc() -> (res: ^Window, ok: bool) {
	res = gs.windows_iter
	ok = gs.windows_iter != nil
	
	if ok {
		gs.windows_iter = gs.windows_iter.window_next
	}

	return
}

gs_allocator :: proc() -> mem.Allocator {
	when TRACK_MEMORY {
		return mem.tracking_allocator(&gs.track)
	} else {
		return context.allocator
	}
}

gs_init :: proc() {
	gs = new(Global_State)
	using gs
	running = true

	when TRACK_MEMORY {
		mem.tracking_allocator_init(&track, context.allocator)
	}
	context.allocator = gs_allocator()
	
	err := sdl.Init(sdl.INIT_VIDEO | sdl.INIT_EVENTS | sdl.INIT_AUDIO)
	if err != 0 {
		fmt.panicf("SDL2: failed to initialize %d", err)
	}

	sdl.StartTextInput()
	sdl.EnableScreenSaver()
	sdl.SetHint(sdl.HINT_VIDEO_X11_NET_WM_BYPASS_COMPOSITOR, "0")

	// create cursors
	cursors[.Arrow] = sdl.CreateSystemCursor(.ARROW)
	cursors[.IBeam] = sdl.CreateSystemCursor(.IBEAM)
	cursors[.Hand] = sdl.CreateSystemCursor(.HAND)
	cursors[.Hand_Drag] = sdl.CreateSystemCursor(.SIZEALL)
	cursors[.Resize_Horizontal] = sdl.CreateSystemCursor(.SIZEWE)
	cursors[.Resize_Vertical] = sdl.CreateSystemCursor(.SIZENS)
	cursors[.Crosshair] = sdl.CreateSystemCursor(.CROSSHAIR)

	// get pref path
	{
		path := sdl.GetPrefPath("skytrias", "todool")
		if path != nil {
			pref_path = strings.clone_from_cstring(path)
			sdl.free(rawptr(path))
		} else {
			when os.OS == .Linux {
				pref_path = ".\\"
			} 

			when os.OS == .Windows {
				pref_path = "./"
			}
		}
	}

	{
		path := sdl.GetBasePath()
		if path != nil {
			base_path = strings.clone_from_cstring(path)
			sdl.free(rawptr(path))
		} 
	}

	// use file logger on release builds
	when TODOOL_RELEASE {
		log_path = strings.clone(bpath_temp("log.txt"))

		// write only, create new file if not exists, truncate file at start
		when os.OS == .Linux {
			// all rights on linux
			mode := 0o0777
			log_file_handle, errno := os.open(log_path, os.O_WRONLY | os.O_CREATE | os.O_TRUNC, mode)
		} else {
			log_file_handle, errno := os.open(log_path, os.O_WRONLY | os.O_CREATE | os.O_TRUNC)
		}

		logger = log.create_file_logger(log_file_handle)
	} else {
		logger = log.create_console_logger()
	}	
	context.logger = logger

	{
		linked: sdl.version
		sdl.GetVersion(&linked)
		log.infof("SDL2: Linked Version %d.%d.%d", linked.major, linked.minor, linked.patch)
	}

	fontstash.init(&fc, 500, 500)
	fc.callback_resize = proc(data: rawptr, w, h: int) {
		if data != nil {
			// regenerate the texture on all windows
			window := gs.windows
			for window != nil {
				// NOTE dunno if this is safe to be called during glyph calls
				render_target_fontstash_generate(window.target, w, h)
				window = window.window_next
			}
		}
	}
	fc.callback_update = proc(data: rawptr, dirty_rect: [4]f32, texture_data: rawptr) {
		// update the texture on all windows
		if data != nil {
			window := cast(^Window) data
			sdl.GL_MakeCurrent(window.w, window.target.opengl_context)
			t := &window.target.textures[.Fonts]
			t.data = texture_data
			texture_update_subimage(t, dirty_rect, texture_data)
		}
	}
	fonts_push()
	animating = make([dynamic]^Element, 0, 32)

	copy_builder = strings.builder_make(0, mem.Kilobyte)

	// audio
	{
		// audio support
		wanted_flags := mix.InitFlags {}
		init_flags := transmute(mix.InitFlags) mix.Init(wanted_flags)
		gs.audio_ok = true
		
		if wanted_flags != init_flags {
			log.error("MIXER: couldnt load audio format")
			gs.audio_ok = false
		}

		if mix.OpenAudio(44100, mix.DEFAULT_FORMAT, 2, 1024) == -1 {
			log.error("MIXER: failed loading")
			gs.audio_ok = false
		}
	}

	flux = ease.flux_init(f32, 128)

	window_timer_callback :: proc "c" (interval: u32, data: rawptr) -> u32 {
		context = runtime.default_context()
		context.logger = gs.logger

		window := cast(^Window) data
		if window_hovered_check(window) {
			sdl_push_empty_event()
		}

		return interval
	}

	window_hovering_timer = sdl.AddTimer(250, window_hovering_timer_callback, &gs.windows)
	strings.builder_init(&cstring_builder, 0, 128)
}

window_hovering_timer_callback :: proc "c" (interval: u32, data: rawptr) -> u32 {
	context = runtime.default_context()
	context.logger = gs.logger

	window := (cast(^^Window) data)^
	for window != nil {	
		if window_hovered_check(window) {
			sdl_push_empty_event()
		}

		window = window.window_next
	}

	return interval
}

gs_check_leaks :: proc(ta: ^mem.Tracking_Allocator) {
	if len(ta.allocation_map) > 0 {
		for _, v in ta.allocation_map {
			fmt.eprintf("%v LEAK: %dB\n", v.location, v.size)
		}
	}
	
	if len(ta.bad_free_array) > 0 {
		for v in ta.bad_free_array {
			fmt.eprintf("%v BAD FREE PTR: %p\n", v.location, v.memory)
		}
	}
}

gs_destroy :: proc() {
	using gs

	for index in Sound_Index {
		path := sound_paths[index]
		if path != "" {
			delete(path)
		}
	}

	if font_regular_path != "" {
		delete(font_regular_path)
	} 

	if font_bold_path != "" {
		delete(font_bold_path)
	}

	delete(animating)
	delete(copy_builder.buf)
	delete(cstring_builder.buf)

	sdl.RemoveTimer(window_hovering_timer)

	if gs.stored_image_thread != nil {
		thread.destroy(gs.stored_image_thread)
		gs.stored_image_thread = nil
	}
	for key, value in gs.stored_images {
		delete(key)
	}
	delete(gs.stored_images)

	for sound in sounds {
		mix.FreeChunk(sound)
	}

	mix.Quit()

	ease.flux_destroy(flux)
	fontstash.destroy(&fc)

	// based on mode
	when TODOOL_RELEASE {
		log.destroy_file_logger(&logger)
		delete(log_path)
	} else {
		log.destroy_console_logger(logger)
	}
	delete(pref_path)
	delete(base_path)

	when TRACK_MEMORY {
		gs_check_leaks(&track)
		mem.tracking_allocator_destroy(&track)
	}	

	for cursor in cursors {
		sdl.FreeCursor(cursor)
	}

	sdl.Quit()
	free(gs)
}

// build a cstring with a builder
// NOTE appends a nul byte
cstring_build :: proc(b: ^strings.Builder) -> cstring {
	strings.write_byte(b, '\x00')
	return cstring(raw_data(b.buf))
}

// build a cstring with a builder
gs_string_to_cstring :: proc(text: string) -> cstring {
	b := &gs.cstring_builder
	strings.builder_reset(b)
	strings.write_string(b, text)
	strings.write_byte(b, '\x00')
	return cstring(raw_data(b.buf))
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
	{
		gs_windows_iter_init()
		for w in gs_windows_iter_step() {
			w.ctrl = ctrl
			w.shift = shift
			w.alt = alt
			w.ignore_text_input = false
		}
	}

	// iterate events
	event: sdl.Event
	for sdl.PollEvent(&event) {
		// if event.type == .KEYDOWN {
		// 	// if event.key.keysym.scancode == .ESCAPE {
		// 		gs_windows_iter_init()
		// 		for w in gs_windows_iter_step() {
		// 			menu_close(w)
		// 		}
		// 	// }
		// }

		if event.type == .QUIT && !gs.ignore_quit {
			gs.running = false

			// if gs_window_count() == 1 {


			// }
			log.info("~~~QUIT EVENT~~~")

			gs_windows_iter_init()
			for w in gs_windows_iter_step() {
				window_destroy(w)
				w.dialog_finished = true
			}

			break
		}

		gs_windows_iter_init()
		for w in gs_windows_iter_step() {
			window_handle_event(w, &event)
		}
	}
}

gs_message_loop :: proc() {
	context.logger = gs.logger
	
	for gs.running {
		// when animating
		if len(gs.animating) != 0 || len(gs.flux.values) != 0 {
			gs.frame_start = sdl.GetPerformanceCounter()
			gs_process_animations()
			gs_process_events()
			
			if len(gs.flux.values) != 0 {
				gs_update_all_windows()
			}	
		} else {
			// wait for event to arive
			available := sdl.WaitEvent(nil)
			// set frame start after waiting
			gs.frame_start = sdl.GetPerformanceCounter()
			gs_process_events()
		}
		
		// repaint all of the window
		gs_draw_and_cleanup()

		// TODO could be bad cuz this is for multiple windows?
		// TODO maybe time the section of time that was waited on?
		// update frame counter
		{
			frame_end := sdl.GetPerformanceCounter()
			elapsed_ms := f64(frame_end - gs.frame_start) / f64(sdl.GetPerformanceFrequency())
			gs.dt = f32(elapsed_ms)
		}

		if len(gs.flux.values) != 0 {
			ease.flux_update(&gs.flux, f64(gs.dt))
		}
	}

	task_data_destroy()
	gs_destroy()
}

gs_update_all_windows :: proc() {
	gs_windows_iter_init()
	for w in gs_windows_iter_step() {
		w.update_next = true
	}
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

	link := &gs.windows
	window := gs.windows
	window_count: int

	for window != nil {
		next := window.window_next

		// anything to destroy?
		if element_deallocate(&window.element) {
			log.info("WINDOW DEALLOC COUNT DECREASE")
			window_count -= 1
			link^ = next
		} else if window.update_next {
			link = &window.window_next

			// reset focuse on hidden
			if window.focused != nil {
				if !window_focused_shown(window) {
					window.focused = nil
				}
			}

			if window.update != nil {
				window->update()
			}

			gs.fc.user_data = window
			fontstash.state_begin(&gs.fc)
			render_target_begin(window.target, theme.shadow)
			element_message(&window.element, .Layout)
			render_element_clipped(window.target, &window.element)
			fontstash.state_end(&gs.fc)
			render_target_end(window.target, window.w, window.width, window.height)

			// TODO could use specific update region only
			window.update_next = false
		}
		
		window_count += 1
		// log.info("W COUNT", window_count, window.name)
		window = next
	}

	if window_count == 0 {
		gs.running = false
		log.info("SHOULD QUIT")
	}
}

gs_window_count :: proc() -> (res: int) {
	gs_windows_iter_init()
	for w in gs_windows_iter_step() {
		res += 1
	}
	return
}

//////////////////////////////////////////////
// dialog
//////////////////////////////////////////////

dialog_message :: proc(element: ^Element, msg: Message, di: int, dp: rawptr) -> int {
	#partial switch msg {
		case .Layout: {
			w := element.window
			assert(len(element.children) != 0)
			
			panel := cast(^Panel) element.children[0]
			width := f32(element_message(panel, .Get_Width, 0))
			height := f32(element_message(panel, .Get_Height, 0))
			cx := (element.bounds.l + element.bounds.r) / 2
			cy := (element.bounds.t + element.bounds.b) / 2
			bounds := Rect {
				cx - (width + 1) / 2,
				cx + width / 2, 
				cy - (height + 1),
				cy + height / 2,
			}
			element_move(panel, bounds)
		}

		case .Update: {
			panel := element.children[0]
			element_message(panel, .Update, di, dp)
		}

		case .Key_Combination: {
			combo := (cast(^string) dp)^
			w := element.window
			b := &w.dialog_builder

			if combo == "escape" {
				strings.builder_reset(b)
				strings.write_string(b, "_C") // canceled
				w.dialog_finished = true
				return 1
			} else if combo == "return" {
				strings.builder_reset(b)
				strings.write_string(b, "_D") // default 
				w.dialog_finished = true
				return 1
			}
		}

		// select the element with the starting character
		case .Unicode_Insertion: {
			codepoint := (cast(^rune) dp)^
			codepoint = unicode.to_upper(codepoint)

			// panel
			row_container := element.children[0]
			duplicate: bool
			target: ^Element

			for i in 0..<len(row_container.children) {
				row := row_container.children[i]

				for j in 0..<len(row.children) {
					item := row.children[j]

					// matching to button
					if item.message_class == button_message {
						button := cast(^Button) item
						text := strings.to_string(button.builder)
						// NOTE dangerous due to unicode
						first := rune(text[0])

						if first == codepoint {
							if target == nil {
								target = item
							} else {
								duplicate = true
							}
						}
					}
				}
			}

			if target != nil {
				if duplicate {
					element_focus(target)
				} else {
					element_message(target, .Clicked)
				}
			}
		}
	}

	return 0
}

dialog_button_message :: proc(element: ^Element, msg: Message, di: int, dp: rawptr) -> int {
	button := cast(^Button) element

	if msg == .Clicked {
		window := element.window
		builder := &window.dialog_builder
		strings.builder_reset(builder)
		strings.write_string(builder, strings.to_string(button.builder))
		window.dialog_finished = true
	}

	return 0
}

dialog_spawn :: proc(
	window: ^Window,
	format: string,
	args: ..string,
) -> string {
	if window.dialog != nil {
		return ""
	}

	window.dialog = element_init(Element, &window.element, {}, dialog_message, mem.arena_allocator(&window.element_arena))
	panel := panel_init(window.dialog, { .Tab_Movement_Allowed, .Panel_Default_Background }, 5, 5)
	panel.background_index = 2
	panel.shadow = true
	panel.rounded = true
	window.dialog.z_index = 255

	// state to be retrieved from iter
	focus_next: ^Element
	cancel_button: ^Button
	default_button: ^Button
	button_count: int

	arg_index: int
	row: ^Panel = nil
	ds: cutf8.Decode_State

	for codepoint, i in cutf8.ds_iter(&ds, format) {
		codepoint := codepoint
		i := i

		if i == 0 || codepoint == '\n' {
			row = panel_init(panel, { .Panel_Horizontal, .HF }, 0, 5)
		}

		if codepoint == ' ' || codepoint == '\n' {
			continue
		}

		if codepoint == '%' {
			// next
			codepoint, i, _ = cutf8.ds_iter(&ds, format)

			switch codepoint {
				case 'b', 'B', 'C': {
					text := args[arg_index]
					arg_index += 1
					b := button_init(row, {}, text)
					b.message_user = dialog_button_message

					// default
					if codepoint == 'B' {
						default_button = b
					}

					// canceled
					if codepoint == 'C' {
						cancel_button = b
					}

					// set first focused
					if focus_next == nil {
						focus_next = b
					}

					button_count += 1
				}

				case 'f': {
					spacer_init(row, { .HF }, 0, LINE_WIDTH, .Empty)
				}

				case 'l': {
					spacer_init(row, { .HF }, 0, LINE_WIDTH, .Thin)
				}

				case 's': {
					text := args[arg_index]
					arg_index += 1
					label_init(row, {}, text)
				}
			}
		} else {
			byte_start := ds.byte_offset_old
			byte_end := ds.byte_offset
			end_early: bool

			// advance till empty
			for other_codepoint in cutf8.ds_iter(&ds, format) {
				byte_end = ds.byte_offset

				if other_codepoint == '%' || other_codepoint == '\n' {
					end_early = true
					break
				}
			}

			text := format[byte_start:byte_end - (end_early ? 1 : 0)]
			label_init(row, { .Label_Center, .HF }, text)

			if end_early {
				row = panel_init(panel, { .Panel_Horizontal, .HF }, 0, 5)
			}
		}
	}

	window.dialog_finished = false
	old_focus := window.focused
	element_focus(focus_next == nil ? window.dialog : focus_next)
	defer {
		if old_focus != nil {
			element_focus(old_focus)
		}
	}

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

	// check keyboard set
	output := strings.to_string(window.dialog_builder)

	// cancel set to default at 1
	if button_count == 1 && default_button != nil && cancel_button == nil {
		cancel_button = default_button
	}

	if output == "_C" && cancel_button != nil {
		element_message(cancel_button, .Clicked)
		output = strings.to_string(window.dialog_builder)
	} 

	if output == "_D" && default_button != nil {
		element_message(default_button, .Clicked)
		output = strings.to_string(window.dialog_builder)
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
	return output
}

//////////////////////////////////////////////
// sdl helpers
//////////////////////////////////////////////

// window_border_toggle :: proc(window: ^Window) {
// 	window.bordered = !window.bordered
// }

window_border_set :: proc(window: ^Window, state: bool) {
	sdl.SetWindowBordered(window.w, cast(sdl.bool) state)
	// window.bordered = state
}

clipboard_has_content :: sdl.HasClipboardText

clipboard_get_string :: proc(allocator := context.allocator) -> string {
	text := sdl.GetClipboardText()
	result := strings.clone(string(text), allocator)
	sdl.free(cast(rawptr) text)
	return result
}

// get clipboard string and write it into the builder
clipboard_get_with_builder :: proc() -> string {
	text := sdl.GetClipboardText()
	b := &gs.copy_builder
	strings.builder_reset(b)
	raw := (transmute(mem.Raw_Cstring) text).data
	resize(&b.buf, len(text))
	mem.copy(raw_data(b.buf), raw, len(text))
	sdl.free(cast(rawptr) text)
	return strings.to_string(b^)
}

// get clipboard string and write it into the builder
// stops at newline
clipboard_get_with_builder_till_newline :: proc() -> string {
	ctext := sdl.GetClipboardText()
	defer sdl.free(cast(rawptr) ctext)
	text := string(ctext)

	b := &gs.copy_builder
	strings.builder_reset(b)

	ds: cutf8.Decode_State
	for codepoint in cutf8.ds_iter(&ds, text) {
		if codepoint == '\n' {
			break	
		}
		
		strings.write_rune(b, codepoint)
	}

	return strings.to_string(b^)
}

clipboard_set_prepare :: proc() -> ^strings.Builder {
	strings.builder_reset(&gs.copy_builder)
	return &gs.copy_builder
}

clipboard_set_with_builder_prefilled :: proc() -> i32 {
	b := &gs.copy_builder
	strings.write_byte(b, 0)
	ctext := strings.unsafe_string_to_cstring(strings.to_string(b^))
	return sdl.SetClipboardText(ctext)
}

clipboard_set_with_builder :: proc(text: string) -> i32 {
	b := &gs.copy_builder
	strings.builder_reset(b)
	strings.write_string(b, text)
	strings.write_byte(b, 0)
	ctext := strings.unsafe_string_to_cstring(strings.to_string(b^))
	return sdl.SetClipboardText(ctext)
}

// empty event to update message loop
sdl_push_empty_event :: #force_inline proc() {
	custom_event: sdl.Event
	sdl.PushEvent(&custom_event)
}

//////////////////////////////////////////////
// arena
//////////////////////////////////////////////

@(deferred_out=arena_scoped_end)
arena_scoped :: proc(cap: int) -> (arena: mem.Arena, backing: []byte) {
	backing = make([]byte, cap)
	mem.arena_init(&arena, backing)
	return
}

arena_scoped_end :: proc(arena: mem.Arena, backing: []byte) {
	delete(backing)
}

//////////////////////////////////////////////
// bpath, initialized once
//////////////////////////////////////////////

bpath_temp :: proc(path: string) -> string {
	return fmt.tprintf("%s%s", gs.pref_path, path)
}

bpath_file_write :: proc(path: string, content: []byte) -> bool {
	return os.write_entire_file(bpath_temp(path), content)
}

bpath_file_read :: proc(path: string, allocator := context.allocator) -> ([]byte, bool) {
	return os.read_entire_file(bpath_temp(path), allocator)
}

//////////////////////////////////////////////
// menus
//////////////////////////////////////////////

// close the current menu when its opened
menu_close :: proc(window: ^Window) -> (any_closed: bool) {
	assert(window.menu != nil)

	if element_hide(window.menu, true) {
		element_repaint(&window.element)
		any_closed = true
	}

	return
}

// true when the menu is shown
menu_open :: proc(window: ^Window) -> bool {
	assert(window.menu != nil) 
	return .Hide in window.menu.flags
}

menu_init :: proc(window: ^Window, flags: Element_Flags) -> (menu: ^Panel_Floaty) {
	menu = window.menu
	element_hide(menu, false)
	panel_clear_without_scrollbar(menu.panel)
	menu.x = window.cursor_x
	menu.y = window.cursor_y
	return
}

// add a basic button with auto closing
menu_add_item :: proc(
	menu: ^Panel_Floaty, 
	flags: Element_Flags,
	text: string,
	invoke: proc(data: rawptr),
	data: rawptr = nil,
) {
	button := button_init(menu.panel, {}, text)
	button.message_user = proc(element: ^Element, msg: Message, di: int, dp: rawptr) -> int {
		button := cast(^Button) element

		if msg == .Clicked {
			menu_close(element.window)
		}

		return 0
	}
	button.invoke = invoke
	button.data = data
}

// set width & height based on child elements and keep menu in frame
menu_show :: proc(menu: ^Panel_Floaty) {
	width := element_message(menu.panel, .Get_Width)
	height := element_message(menu.panel, .Get_Height)
	menu.width = f32(width)
	menu.height = f32(height)

	full := window_rect(menu.window)

	// keep x & y in frame with a margin
	margin := 10 * SCALE
	menu.x = clamp(menu.x, margin, full.r - menu.width - margin)
	menu.y = clamp(menu.y, margin, full.b - menu.height - margin)
}

// true wether the requested element is from the menu tree
element_is_from_menu :: proc(window: ^Window, element: ^Element) -> bool {
	assert(window.menu != nil)

	if .Hide in window.menu.flags {
		return false
	}

	p := element
	
	for p != nil {
		if p == &window.menu.panel.element {
			return true
		}

		p = p.parent
	}

	return false
}

//////////////////////////////////////////////
// fontstash helpers
//////////////////////////////////////////////

Font_Options :: struct {
	font: int,
	size: f32,
}

efont_size :: proc(element: ^Element) -> f32 {
	scaled_size := f32(element.font_options == nil ? DEFAULT_FONT_SIZE : element.font_options.size) * SCALE * 10
	return f32(i16(scaled_size) / 10)
}	

fcs_icon :: proc() -> f32 {
	fcs_size(DEFAULT_ICON_SIZE * SCALE)
	fcs_font(font_icon)
	return DEFAULT_ICON_SIZE * SCALE
}

fcs_element :: proc(element: ^Element) -> f32 {
	font_index: int
	size: f32

	if element.font_options == nil {
		font_index = font_regular
		size = DEFAULT_FONT_SIZE
	} else {
		font_index = element.font_options.font
		size = element.font_options.size
	}

	fcs_size(size * SCALE)
	fcs_font(font_index)
	return f32(size) * SCALE
}

string_width :: #force_inline proc(text: string, x: f32 = 0, y: f32 = 0) -> f32 {
	return fontstash.text_bounds(&gs.fc, text, x, y)
}

icon_width :: #force_inline proc(icon: Icon) -> f32 {
	font := fontstash.font_get(&gs.fc, font_icon)
	isize := i16(DEFAULT_FONT_SIZE * 10 * SCALE)
	scale := fontstash.scale_for_pixel_height(font, f32(isize / 10))
	return fontstash.codepoint_width(font, rune(icon), scale)
}

fcs_size :: #force_inline proc(size: f32) {
	fontstash.state_set_size(&gs.fc, size)
}

fcs_font :: #force_inline proc(font: int) {
	fontstash.state_set_font(&gs.fc, font)
}

// font context state set color
fcs_color :: #force_inline proc(color: Color) {
	fontstash.state_set_color(&gs.fc, color)
}

fcs_spacing :: #force_inline proc(spacing: f32) {
	fontstash.state_set_spacing(&gs.fc, spacing)
}

fcs_blur :: #force_inline proc(blur: f32) {
	fontstash.state_set_blur(&gs.fc, blur)
}

fcs_ah :: #force_inline proc(ah: Align_Horizontal) {
	fontstash.state_set_ah(&gs.fc, ah)
}

fcs_av :: #force_inline proc(av: Align_Vertical) {
	fontstash.state_set_av(&gs.fc, av)
}

fcs_ahv :: #force_inline proc(ah: Align_Horizontal = .Middle, av: Align_Vertical = .Middle) {
	fontstash.state_set_ah(&gs.fc, ah)
	fontstash.state_set_av(&gs.fc, av)
}

font_get :: #force_inline proc(font_index: int, loc := #caller_location) -> ^Font {
	return fontstash.font_get(&gs.fc, font_index, loc)
}
