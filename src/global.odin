package src

import "core:intrinsics"
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
import dll "core:container/intrusive/list"
import sdl "vendor:sdl2"
import mix "vendor:sdl2/mixer"
import gl "vendor:OpenGL"
import "heimdall:fontstash"
import "../cutf8"
import "../spall"

FPS_MIN :: 15
FPS_MAX :: 240

SCALE := f32(1)
TASK_SCALE := f32(1)
TASK_SCALE_DEFAULT :: f32(1)
LINE_WIDTH := 2
ROUNDNESS :: 5
SCALE_MIN :: 0.25
SCALE_MAX :: 8
HOVER_WIDTH :: 100

scaling_set :: proc(global_scale: f32, task_scale: f32) {
	old := TASK_SCALE

	TASK_SCALE = clamp(task_scale, SCALE_MIN, SCALE_MAX)
	SCALE = clamp(global_scale, SCALE_MIN, SCALE_MAX)
	LINE_WIDTH = max(int(2 * SCALE), 2)
	fontstash.Reset(&gs.fc)
	app.caret.motion_skip = true

	if old != TASK_SCALE {
		mode_panel_zoom_animate()
	}
}

Font :: fontstash.Font
data_font_icon := #load("../assets/icons.ttf")
data_font_regular := #load("../assets/Lato-Regular.ttf")
data_font_bold := #load("../assets/Lato-Bold.ttf")
data_font_fallback := #load("../assets/NotoSans-Regular.ttf")
font_regular: int
font_bold: int
font_icon: int
font_fallback: int
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

Shortcut_Proc :: proc() -> bool

HOVER_TIME :: time.Millisecond * 500
MOUSE_CLICK_TIME :: time.Millisecond * 500
MOUSE_LEFT :: 1
MOUSE_MIDDLE :: 2
MOUSE_RIGHT :: 3
Mouse_Coordinates :: [2]int

Window :: struct {
	element: Element,
	node: dll.Node,
	
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
	raise_next: bool,

	// mouse behaviour
	cursor_x, cursor_y: int,
	cursor_x_old, cursor_y_old: int,
	down_middle: Mouse_Coordinates,
	down_left: Mouse_Coordinates,
	down_right: Mouse_Coordinates,
	pressed_button: int,
	
	// window sizing
	width, height: int,
	widthf, heightf: f32,
	rect: RectI,
	paint_clip: RectI,
	fullscreened: bool,

	// rendering
	update_next: bool,
	update_check: proc(window: ^Window) -> bool, // for custom animation handling
	target: ^Render_Target,

	// sdl data
	w: ^sdl.Window,
	w_id: u32,
	cursor: Cursor,

	// key state
	combo_builder: strings.Builder,
	ignore_text_input: bool,
	ctrl, shift, alt, super: bool,

	// assigned shortcuts to procedures in window
	keymap_box: Keymap,
	keymap_custom: Keymap,
	dialog: ^Dialog,

	// menu
	menu: ^Panel_Floaty,
	menu_info: int,
	menu_filter: bool, // accept unicode insertion for menus, writes into menu_builder

	// proc that gets called before layout & draw
	update_before: proc(window: ^Window),
	update_after: proc(window: ^Window),

	// title
	title_builder: strings.Builder,

	// drop handling
	drop_indices: [dynamic]int, // indices into the file name builder
	drop_file_name_builder: strings.Builder,
	drop_index: int,
	drop_indice: int,

	// callbacks
	on_resize: proc(window: ^Window),
	on_focus_gained: proc(window: ^Window),
	on_menu_close: proc(window: ^Window),

	// next window
	name: string,
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
	windows_list: dll.List,

	//  wether dropped was text or file paths
	dropped_text: bool,

	// logger data
	logger: log.Logger,
	log_path: string, // freed at destroy
	pref_path: string, // freed at destroy
	base_path: string, // freed at destroy
	cstring_builder: strings.Builder,

	// builder to store clipboard content
	copy_builder: strings.Builder,

	cursors: [Cursor]^sdl.Cursor,

	running: bool,
	frame_start: u64,
	dt: f32,
	accumulator: f32,

	// animating elements
	animating: [dynamic]^Element,

	// event intercepting
	ignore_quit: bool,

	audio_ok: bool, // true when sdl mix module loaded fine
	sound_paths: [Sound_Index]string,
	sounds: [Sound_Index]^mix.Chunk,

	// stores multiple png images
	stored_images: [dynamic]Stored_Image,
	stored_image_thread: ^thread.Thread,
	
	window_hovering_timer: sdl.TimerID,

	font_regular_path: string,
	font_bold_path: string,

	track: mem.Tracking_Allocator,
	fc: fontstash.FontContext,
}
gs: ^Global_State

Stored_Image_Load_Finished :: proc(img: ^Stored_Image, data: rawptr)
Stored_Image :: struct {
	using backing: ^image.Image,
	handle: u32,
	handle_set: bool,
	loaded: bool,
	
	path: [256]u8, // static path, clipped
	path_length: u8,
}

image_path :: proc(img: ^Stored_Image) -> string {
	return string(img.path[:img.path_length])
}

image_find :: proc(path: string) -> (index: int) {
	index = -1
	
	for img, i in &gs.stored_images {
		if image_path(&img) == path {
			index = i
			return 
		}
	}

	return 
}

// push a load command and create a thread if not existing yet
image_load_push :: proc(path: string) -> (res: ^Stored_Image) {
	if len(path) > 256 {
		log.warn("Image Load: aborted due to long path name")
		return
	}

	index := image_find(path)

	if index == -1 {
		if gs.stored_image_thread == nil {
			gs.stored_image_thread = thread.create_and_start(image_load_process_on_thread)
		} 

		append(&gs.stored_images, Stored_Image {})
		res = &gs.stored_images[len(gs.stored_images) - 1]
		res.path_length = u8(len(path))
		copy(res.path[:], path[:])
	} else {
		res = &gs.stored_images[index]
	}

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
	{
		spall.scoped("Load images", u32(t.id))

		for img in &gs.stored_images {
			// loading needs to be done
			if !img.loaded {
				img.backing = image_load_from_file(image_path(&img))
				img.loaded = true
				// fmt.eprintln("image load finished", key, img.backing == nil)
			}
		}
	}

	sdl_push_empty_event()
	intrinsics.atomic_store(&app.window_main.update_next, true)
	gs.stored_image_thread = nil
	thread.destroy(t)
}

image_load_process_texture_handles :: proc(window: ^Window) {
	sdl.GL_MakeCurrent(window.w, window.target.opengl_context)

	for img in &gs.stored_images {
		if img.backing != nil && img.loaded && !img.handle_set {
			img.handle = shallow_texture_init(img.backing)
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
	command_cap: int,
	combos_cap: int,
) -> (res: ^Window) {
	x_pos := i32(sdl.WINDOWPOS_UNDEFINED)
	y_pos := i32(sdl.WINDOWPOS_UNDEFINED)
	window_flags: sdl.WindowFlags = { .OPENGL, .HIDDEN, .RESIZABLE }
	spall.fscoped("window init %s", title)

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

	_window_message :: proc(element: ^Element, msg: Message, di: int, dp: rawptr) -> int {
		window := cast(^Window) element

		#partial switch msg {
			case .Layout: {
				for child in element.children {
					if child.message_class == panel_floaty_message {
						// layout floaty panels only with their own custom size
						floaty := cast(^Panel_Floaty) child
						floaty.clip = element.bounds
						element_message(floaty, .Layout)
						floaty.clip = floaty.panel.bounds
						floaty.bounds = floaty.panel.bounds
					} else {
						element_move(child, element.bounds)
					}
				}
			}

			case .Deallocate: {
				// NEEDS TO BE CALLED IN HERE, CUZ OTHERWHISE ITS ALREADY REMOVED
				window_deallocate(window)
			}
		}

		return 0
	}

	window_element_flags := flags
	window_element_flags |= { .Tab_Movement_Allowed, .Sort_By_Z_Index }

	res = element_init(
		Window, 
		nil, 
		window_element_flags,
		_window_message,
		context.allocator,
	)

	res.w = window
	res.w_id = window_id
	res.hovered = &res.element
	res.combo_builder = strings.builder_make(0, 32)
	res.title_builder = strings.builder_make(0, 64)
	// res.menu_builder = strings.builder_make(0, 64)
	
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
	res.rect = rect_wh(0, 0, int(w), int(h))
	res.element.window = res

	// push back to dll
	dll.push_back(&gs.windows_list, &res.node)

	keymap_init(&res.keymap_box, 16, 32)
	keymap_init(&res.keymap_custom, command_cap, combos_cap)

	// set hovered panel
	{
		floaty := panel_floaty_init(&res.element, { .Disabled })
		floaty.message_user = proc(element: ^Element, msg: Message, di: int, dp: rawptr) -> int {
			floaty := cast(^Panel_Floaty) element
			panel := floaty.panel

			#partial switch msg {
				case .Layout: {
					// NOTE could do hight here too
					floaty.height = int(DEFAULT_FONT_SIZE * SCALE + TEXT_MARGIN_VERTICAL * SCALE)
					rect := rect_wh(floaty.x, floaty.y, floaty.width, floaty.height)
					element_move(panel, rect)
					return 1
				}
			}

			return 0
		}
		p := floaty.panel
		p.flags |= { .Panel_Expand, .Disabled }
		p.shadow = true
		p.rounded = true
		label_init(p, { .Label_Center, .Disabled })
		res.hovered_panel = floaty
		element_hide(floaty, true)
	}

	return
}

gs_update_after_load :: proc() {
	spall.scoped("load after sjson")
	
	ctx := &gs.fc

	// preload most used characters
	add :: proc(index: int, pixel_size: int) {
		font := fontstash.__getFont(&gs.fc, index)
		isize := i16(pixel_size * 10)
		scale := fontstash.__getPixelHeightScale(font, f32(isize / 10))

		for i in 0..<95 {
			fontstash.__getGlyph(&gs.fc, font, rune(32 + i), isize)
		}
	}

	if gs.font_regular_path != "" {
		font_regular = fontstash.AddFont(ctx, "regular", gs.font_regular_path)
	} else {
		font_regular = fontstash.AddFontMem(ctx, "regular", data_font_regular, false)
	}

	if gs.font_bold_path != "" {
		font_bold = fontstash.AddFont(ctx, "bold", gs.font_bold_path)
	} else {
		font_bold = fontstash.AddFontMem(ctx, "bold", data_font_bold, false)
	}

	add(font_regular, 20)
	add(font_bold, 20)

	font_icon = fontstash.AddFontMem(ctx, "icons", data_font_icon, false)

	// add fallbacks
	font_fallback = fontstash.AddFontMem(ctx, "fallback", data_font_fallback, false)
	fontstash.AddFallbackFont(ctx, font_regular, font_fallback)
	fontstash.AddFallbackFont(ctx, font_bold, font_fallback) // TODO use bolded fallback?

	if gs.audio_ok {
		custom_load_wav_opt(.Timer_Start, data_sound_timer_start)
		custom_load_wav_opt(.Timer_Stop, data_sound_timer_stop)
		custom_load_wav_opt(.Timer_Resume, data_sound_timer_resume)
		custom_load_wav_opt(.Timer_Ended, data_sound_timer_ended)
	}
}

window_repaint :: #force_inline proc(window: ^Window) {
	window.update_next = true
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
	if goal_y + floaty.height > window.height {
		goal_y = element.bounds.t - floaty.height
	}

	floaty.y = goal_y

	fcs_size(DEFAULT_FONT_SIZE * SCALE)
	fcs_font(font_regular)
	text_width := fontstash.TextBounds(&gs.fc, text)
	floaty.width = max(int(HOVER_WIDTH * SCALE), int(text_width) + int(TEXT_MARGIN_HORIZONTAL * SCALE) * 2)

	if floaty.x + floaty.width > window.width {
		floaty.x = window.width - floaty.width - 5
	}
}

window_poll_size :: proc(window: ^Window) {
	w, h: i32
	sdl.GetWindowSize(window.w, &w, &h)
	window.width = int(w)
	window.widthf = f32(window.width)
	window.height = int(h)
	window.heightf = f32(window.height)
	window.rect = rect_wh(0, 0, window.width, window.height)
}

window_mouse_rect :: proc(window: ^Window, w := 1, h := 1) -> RectI {
	return rect_wh(window.cursor_x, window.cursor_y, w, h)
}

window_mouse_position :: proc(window: ^Window) -> Mouse_Coordinates {
	return { window.cursor_x, window.cursor_y }
}

window_mouse_inside :: proc(window: ^Window) -> bool {
	return rect_contains(window.rect, window.cursor_x, window.cursor_y)
}

window_raise :: proc(window: ^Window) {
	sdl.SetWindowInputFocus(window.w)
	sdl.RaiseWindow(window.w)
}

window_show :: proc(window: ^Window) {
	sdl.ShowWindow(window.w)
}

window_hide :: proc(window: ^Window) {
	sdl.HideWindow(window.w)
}

global_mouse_position :: proc() -> (int, int) {
	xx, yy: i32
	sdl.GetGlobalMouseState(&xx, &yy)
	return int(xx), int(yy)
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

	when ODIN_OS == .Linux {

	} else {
		left, right, top, bottom = 0, 0, 0, 0
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
	if msg == .Dropped_Files || msg == .Dropped_Text {
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
					element_send_msg_until_received(hovered, msg, window.click_count, dp)
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
					element_send_msg_until_received(hovered, msg, di, dp)
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

				combo := (cast(^string) dp)^

				if window.focused != nil && combo == "escape" {
					if window.dialog == nil && window.menu == nil {
						element_focus(window, nil)
						handled = true
						window.update_next = true
						return
					}
				}

				if !handled && !window.ctrl && !window.alt && !window.menu_filter {
					match := combo == "tab" || combo == "shift tab"
					backwards := window.shift

					// NOTE allows arrow based movement on dialog
					if window.dialog != nil {
						steal_input: bool

						if window.focused != nil {
							steal_input |= window.focused.message_class == text_box_message
							steal_input |= window.focused.message_class == ke_stealer_message
						}

						if !steal_input {
							match |= combo == "up" || combo == "down" || combo == "left" || combo == "right"
							backwards |= combo == "up" || combo == "left" 
						} else {
							match = false
						}
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

						element_focus(window, element)
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
				if !window.menu_filter && menu_close(window) {
					return false
				}

				return window_send_msg_to_focused_or_parents(window, .Unicode_Insertion, di, dp)
			}

			case .Mouse_Scroll_X: {
				if element_is_from_menu(window, hovered) || !menu_close(window) {
					di := di * options_scroll_x()
					element_send_msg_until_received(window.hovered, .Mouse_Scroll_X, di, dp)
				}
			}

			case .Mouse_Scroll_Y: {
				if element_is_from_menu(window, hovered) || !menu_close(window) {
					di := di * options_scroll_y()
					element_send_msg_until_received(window.hovered, .Mouse_Scroll_Y, di, dp)
				}
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
		hover_info := element_hover_info(e)
		
		if hover_info != "" && window.pressed_last != e {
			diff := time.tick_since(window.hovered_start)

			if diff > HOVER_TIME {
				window_hovered_panel_spawn(window, e, hover_info)
				window_repaint(window)
				return true
			}
		}
	} else {
		hover_info := element_hover_info(e)
		
		// hide away again on non info
		if hover_info == "" {
			element_hide(window.hovered_panel, true)
			window_repaint(window)
			return true
		}

		if window.pressed_last == e {
			element_hide(window.hovered_panel, true)
			window_repaint(window)					
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
	keymap_destroy(&window.keymap_box)
	keymap_destroy(&window.keymap_custom)

	delete(window.drop_indices)
	delete(window.drop_file_name_builder.buf)

	render_target_destroy(window.target)
	delete(window.combo_builder.buf)
	delete(window.title_builder.buf)
	// delete(window.menu_builder.buf)
	sdl.DestroyWindow(window.w)
	log.info("WINDOW: Deallocate END")
}

window_layout_update :: proc(window: ^Window) {
	window.element.bounds = { 0, window.width, 0, window.height }
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

	if window.super {
		write_string(b, "super ")
	}
	
	if window.ctrl {
		write_string(b, "ctrl ")
	}
	
	if window.shift {
		write_string(b, "shift ")
	}
	
	if window.alt {
		write_string(b, "alt ")
	}
	
	key_name := sdl.GetKeyName(key.keysym.sym)
	write_string(b, string(key_name))

	ok = true	
	res = to_lower(to_string(b^), context.temp_allocator)
	return
}

window_try_quit :: proc(window: ^Window, forced: bool = false) {
	gs.ignore_quit = true

	if forced || element_message(&window.element, .Window_Close_Interrupt) == 0 {
		log.warn("~~~WINDOW CLOSE EVENT~~~")
		element_message(&window.element, .Window_Close)
		window_destroy(window)
		gs.ignore_quit = false
	}
}

window_dropped_text :: proc(window: ^Window) -> string {
	return string(window.drop_file_name_builder.buf[:])
}

window_drop_init :: proc(window: ^Window) {
	window.drop_indice = 0
	window.drop_index = 0
}

window_drop_iter :: proc(window: ^Window) -> (path: string, ok: bool) {
	if window.drop_index >= len(window.drop_indices) {
		return
	}

	next := window.drop_indices[window.drop_index]
	ok = true
	path = string(window.drop_file_name_builder.buf[window.drop_indice:next])
	window.drop_indice = next
	window.drop_index += 1
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
					window_try_quit(window)
				}

				case .RESIZED: {
					window.width = int(e.window.data1)
					window.widthf = f32(window.width)
					window.height = int(e.window.data2)
					window.heightf = f32(window.height)	
					window.rect = rect_wh(0, 0, window.width, window.height)
					window.update_next = true
					menu_close(window)

					if window.on_resize != nil {
						window->on_resize()
					}
				}

				// called on first shown
				case .EXPOSED: {
					if window.update_before != nil {
						window->update_before()
					}

					window_poll_size(window)
					window_layout_update(window)

					if window.update_after != nil {
						window->update_after()
					}
				}

				case .FOCUS_GAINED: {
					if window != nil && window.on_focus_gained != nil {
						window->on_focus_gained()
					}

					// reset mouse
					window_set_cursor(window, .Arrow)

					// flush key event when gained
					sdl.FlushEvent(.KEYDOWN)
				}
			}
		}

		case .KEYDOWN: {
			if e.key.windowID != window.w_id {
				return
			}

			if !window.menu_filter && menu_close(window) {
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

			text := string(cstring(&e.text.text[0]))
			state, codepoint: rune
			length: int

			for i in 0..<len(text) {
				if cutf8.decode(&state, &codepoint, text[i]) {
					length = i
					break
				}
			}

			// NOTE only take the first codepoint
			window_input_event(window, .Unicode_Insertion, 0, &codepoint)
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

			window.cursor_x_old = window.cursor_x
			window.cursor_y_old = window.cursor_y
			window.cursor_x = int(e.motion.x)
			window.cursor_y = int(e.motion.y)
			window_input_event(window, .Mouse_Move)
		}

		case .MOUSEBUTTONDOWN: {
			if e.button.windowID != window.w_id {
				return
			}

			if e.button.button == sdl.BUTTON_LEFT {
				window.down_left = { int(e.button.x), int(e.button.y) }
				window_input_event(window, .Left_Down, int(e.button.clicks))
			} else if e.button.button == sdl.BUTTON_MIDDLE {
				window.down_middle = { int(e.button.x), int(e.button.y) }
				window_input_event(window, .Middle_Down, int(e.button.clicks))
			} else if e.button.button == sdl.BUTTON_RIGHT {
				window.down_right = { int(e.button.x), int(e.button.y) }
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
				window_input_event(window, gs.dropped_text ? .Dropped_Text : .Dropped_Files)
			} else if e.type == .DROPTEXT {
				gs.dropped_text = true
				text := string(e.drop.file)
				strings.write_string(b, text)
				append(indices, len(b.buf))
			} else if e.type == .DROPFILE {
				gs.dropped_text = false
				text := string(e.drop.file)
				strings.write_string(b, text)
				append(indices, len(b.buf))
			}
		}
	}
}

gs_windows_iter_head :: proc() -> dll.Iterator(Window) {
	return dll.iterator_head(gs.windows_list,  Window, "node")
}

gs_allocator :: proc() -> mem.Allocator {
	when TRACK_MEMORY {
		return mem.tracking_allocator(&gs.track)
	} else {
		return context.allocator
	}
}

gs_display_total_bounds :: proc() -> (width, height: int) {
	rect: sdl.Rect
	displays_count := sdl.GetNumVideoDisplays()

	for i in 0..<displays_count {
		sdl.GetDisplayBounds(i, &rect)
		width += int(rect.w)
		height += int(rect.h)
	}

	return
}

gs_display_dpi :: proc(index: int) -> (ddpi, hdpi, vdpi: f32, ok: bool) {
	res := sdl.GetDisplayDPI(i32(index), &ddpi, &hdpi, &vdpi)
	ok = res == 0
	return
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
	sdl.SetHint(sdl.HINT_MOUSE_FOCUS_CLICKTHROUGH, "1") // mouse clickable 

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

	fontstash.Init(&fc, 500, 500, .TOPLEFT)
	fc.callbackResize = proc(data: rawptr, w, h: int) {
		if data != nil {
			// regenerate the texture on all windows
			iter := gs_windows_iter_head()
			for window in dll.iterate_next(&iter) {
				// NOTE dunno if this is safe to be called during glyph calls
				render_target_fontstash_generate(window.target, w, h)
			}
		}
	}
	fc.callbackUpdate = proc(data: rawptr, dirty_rect: [4]f32, texture_data: rawptr) {
		// update the texture on all windows
		if data != nil {
			// NOTE need to update all window textures apparently
			iter := gs_windows_iter_head()
			for window in dll.iterate_next(&iter) {
				sdl.GL_MakeCurrent(window.w, window.target.opengl_context)
				t := &window.target.textures[.Fonts]
				t.data = texture_data
				texture_update_subimage(t, dirty_rect, texture_data)
			}
		}
	}

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

	window_check_hover_callback :: proc "c" (interval: u32, data: rawptr) -> u32 {
		context = runtime.default_context()
		context.logger = gs.logger

		iter := gs_windows_iter_head()

		for window in dll.iterate_next(&iter) {
			if window_hovered_check(window) {
				sdl_push_empty_event()
			}
		}

		return interval
	}

	window_hovering_timer = sdl.AddTimer(500, window_check_hover_callback, nil)
	strings.builder_init(&cstring_builder, 0, 128)

	stored_images = make([dynamic]Stored_Image, 0, 8)
	clipboard_get_with_builder()
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
		thread.terminate(gs.stored_image_thread, 0)
		thread.destroy(gs.stored_image_thread)
		gs.stored_image_thread = nil
	}
	delete(gs.stored_images)

	for sound in sounds {
		mix.FreeChunk(sound)
	}

	mix.Quit()
	fontstash.Destroy(&fc)

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

	// reset allocator after being done!
	context.allocator = runtime.default_allocator()

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
	// set frame start after waiting
	gs.frame_start = sdl.GetPerformanceCounter()
	
	// query ctrl, shift, alt state
	ctrl, shift, alt, super: bool
	num: i32
	num = 0
	state := sdl.GetKeyboardState(&num)
	shift = state[sdl.SCANCODE_LSHIFT] == 1 || state[sdl.SCANCODE_RSHIFT] == 1
	ctrl = state[sdl.SCANCODE_LCTRL] == 1 || state[sdl.SCANCODE_RCTRL] == 1
	alt = state[sdl.SCANCODE_LALT] == 1 || state[sdl.SCANCODE_RALT] == 1
	super = state[sdl.SCANCODE_LGUI] == 1 || state[sdl.SCANCODE_RGUI] == 1

	// prep window state once
	{
		iter := gs_windows_iter_head()

		for w in dll.iterate_next(&iter) {
			w.ctrl = ctrl
			w.shift = shift
			w.alt = alt
			w.super = super
			w.ignore_text_input = false
		}
	}

	// iterate events
	event: sdl.Event
	for sdl.PollEvent(&event) {
		if event.type == .QUIT && !gs.ignore_quit {
			gs.running = false
			log.warn("~~~QUIT EVENT~~~")

			iter := gs_windows_iter_head()
			for w in dll.iterate_next(&iter) {
				window_destroy(w)
			}

			break
		}

		iter := gs_windows_iter_head()
		for w in dll.iterate_next(&iter) {
			window_handle_event(w, &event)
		}
	}
}

gs_dt_start :: proc() {
	gs.frame_start = sdl.GetPerformanceCounter()
}

gs_dt_end :: proc() -> (elapsed_ms: f64) {
	// TODO could be bad cuz this is for multiple windows?
	// TODO maybe time the section of time that was waited on?
	// update frame counter
	frame_end := sdl.GetPerformanceCounter()
	elapsed_ms = f64(frame_end - gs.frame_start) / f64(sdl.GetPerformanceFrequency())
	gs.dt = f32(elapsed_ms)
	return
}

gs_message_loop :: proc() {
	context.logger = gs.logger
	
	for gs.running {
		free_all(context.temp_allocator)

		// check prior for any window needing updates
		iter := gs_windows_iter_head()

		// forced animation, from exterior animation
		iter = gs_windows_iter_head()
		for w in dll.iterate_next(&iter) {
			if w.update_check != nil {
				w.update_next |= w->update_check()
				// fmt.eprintln("\tCHECK?", w.update_next)
			}
		}

		// check if any have updates now
		any_update := len(gs.animating) != 0
		iter = gs_windows_iter_head()
		for w in dll.iterate_next(&iter) {
			if w.raise_next {
				w.raise_next = false
				w.update_next = true
				window_show(w)
			}

			any_update |= w.update_next
		}

		// fmt.eprintln("UPD?", any_update)

		if any_update {
			gs_process_animations()
			gs_process_events()
		} else {
			// wait for event to arive
			available := sdl.WaitEvent(nil)
			gs_process_events()
		}

		spall.scoped("message step")
		
		// repaint all of the window
		gs_draw_and_cleanup()
		elapsed_ms := gs_dt_end()

		// frame minimum, if vsync doesnt clamp it lower
		{
			wanted := f64(1) / f64(visuals_fps())
			diff := wanted - elapsed_ms
			goal := u32(diff * 1000)

			// fmt.eprintln("GOAL", elapsed_ms, wanted, diff, goal)
			if elapsed_ms < wanted && goal > 0 && goal < 500 {
				// fmt.eprintln("\tSLEEP")
				sdl.Delay(goal)
				gs_dt_end()
			}
		}
	}

	theme_presets_destroy()
	app_destroy(app)
	gs_destroy()
}

gs_update_all_windows :: proc() {
	iter := gs_windows_iter_head()
	for w in dll.iterate_next(&iter) {
		w.update_next = true
	}
}

// send animations messages
gs_process_animations :: proc() {
	for element in gs.animating {
		// allow element to animate multiple things until it returns 0
		if element_message(element, .Animate) == 0 {
			element_animation_stop(element)
		}

		// NOTE repaint even on last frame
		element_repaint(element)
	}
}
 
// window_animate_forced :: proc(
// 	window: ^Window,
// 	value: ^f32,
// 	to: f32,
// 	type: ease.Ease = .Quadratic_Out,
// 	duration: time.Duration = time.Second,
// 	delay: f64 = 0,
// ) {
// 	flux_to_restricted(&window.flux, value, to, type, duration, delay)
// }

// window_animate :: proc(
// 	window: ^Window,
// 	value: ^f32,
// 	to: f32,
// 	type: ease.Ease = .Quadratic_Out,
// 	duration: time.Duration = time.Second,
// 	delay: f64 = 0,
// ) {
// 	ease.flux_to(&window.flux, value, to, type, duration, delay)
// }

// version that stops ongoing animation on different goal
flux_to_restricted :: proc(
	flux: ^ease.Flux_Map($T),
	value: ^T, 
	goal: T, 
	type: ease.Ease = .Quadratic_Out,
	duration: time.Duration = time.Second, 
	delay: f64 = 0,
) -> (tween: ^ease.Flux_Tween(T)) where intrinsics.type_is_float(T) {
	if res, ok := &flux.values[value]; ok {
		// return on same goal
		if res.goal == goal {
			return
		}

		tween = res
	} else {
		flux.values[value] = {}
		tween = &flux.values[value]
	}

	tween^ = { 
		value = value, 
		goal = goal, 
		duration = duration,
		delay = delay,
		type = type,
		data = value,
	}

	return
}

// true if the given element is 
window_focused_shown :: proc(window: ^Window) -> bool {
	if window.focused == nil || window.focused == &window.element {
		return false
	}

	p := window.focused
	
	for p != nil {
		if .Hide in p.flags {
			return false
		}

		p = p.parent
	}

	return true
}

window_draw :: proc(window: ^Window) {
	// reset focus on hidden
	if window.focused != nil {
		if !window_focused_shown(window) {
			window.focused = nil
		}
	}

	if window.update_before != nil {
		window->update_before()
	}

	fontstash.BeginState(&gs.fc)
	render_target_begin(window.target, theme.shadow)
	element_message(&window.element, .Layout)
	window.paint_clip = window.rect
	render_element_clipped(window.target, &window.element)
	fontstash.EndState(&gs.fc)
	render_target_end(window.target, window.w, window.width, window.height)

	// TODO could use specific update region only
	window.update_next = false

	if window.update_after != nil {
		window->update_after()
	}
}

gs_draw_and_cleanup :: proc() {
	context.logger = gs.logger 

	window_count: int
	spall.scoped("draw&cleanup")
	iter := gs_windows_iter_head()

	for window in dll.iterate_next(&iter) {
		root := &window.node

		// anything to destroy?
		if element_deallocate(&window.element) {
			window_count -= 1
			// remove the node wanted out of the DLL
			dll.remove(&gs.windows_list, root)
		} else if window.update_next {
			spall.scoped("draw window")
			window_draw(window)
		}
		
		window_count += 1
	}

	if window_count == 0 {
		gs.running = false
	}
}

gs_destroy_all_windows :: proc() {
	iter := gs_windows_iter_head()
	
	for w in dll.iterate_next(&iter) {
		window_destroy(w)
	}
}

gs_window_count :: proc() -> (res: int) {
	iter := gs_windows_iter_head()
	for w in dll.iterate_next(&iter) {
		res += 1
	}
	return
}

//////////////////////////////////////////////
// sdl helpers
//////////////////////////////////////////////

// window_border_toggle :: proc(window: ^Window) {
// 	window.bordered = !window.bordered
// }

window_border_set :: proc(window: ^Window, state: bool) {
	sdl.SetWindowBordered(window.w, cast(sdl.bool) state)
}

window_fullscreen_toggle :: proc(window: ^Window) {
	if window.fullscreened {
		sdl.SetWindowFullscreen(window.w, {})
	} else {
		sdl.SetWindowFullscreen(window.w, sdl.WINDOW_FULLSCREEN_DESKTOP)
		// sdl.SetWindowFullscreen(window.w, sdl.WINDOW_FULLSCREEN)
	}

	window.fullscreened = !window.fullscreened
}

window_opacity_get :: proc(window: ^Window) -> (res: f32) {
	sdl.GetWindowOpacity(window.w, &res)
	return
}

window_opacity_set :: proc(window: ^Window, value: f32) {
	sdl.SetWindowOpacity(window.w, value)
}

clipboard_has_content :: sdl.HasClipboardText

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

clipboard_check_changes :: proc() -> bool {
	spall.scoped("clipboard changes check")

	if clipboard_has_content() {
		text := sdl.GetClipboardText()
		
		if string(text) != strings.to_string(gs.copy_builder) {
			return true
		}
	}

	return false
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
// more safeful writing to temp file first
//////////////////////////////////////////////

gs_write_safely :: proc(path: string, content: []byte) -> bool {
	temp_path := fmt.tprintf("%s.temp", path)
	os.write_entire_file(temp_path, content) or_return

	// no error
	when os.OS == .Windows {
		os.rename(temp_path, path)
	} else when os.OS == .Linux {
		os.rename(temp_path, path)
	}

	return true
}

//////////////////////////////////////////////
// menus
//////////////////////////////////////////////

// close the current menu when its opened
menu_close :: proc(window: ^Window) -> bool {
	if window.menu == nil {
		return false
	}

	// in case you need to do anything specific on any menu closing event
	if window.on_menu_close != nil {
		window->on_menu_close()
	}

	element_destroy(window.menu)
	window_repaint(window)
	window.menu = nil
	window.menu_filter = false
	window.menu_info = 0
	return true
}

// true when the menu is shown
menu_visible :: proc(window: ^Window) -> bool {
	return window.menu != nil && (.Hide not_in window.menu.flags)
}

menu_init_or_replace_new :: proc(
	window: ^Window, 
	flags: Element_Flags, 
	menu_info: int,
) -> (menu: ^Panel_Floaty) {
	if window.menu_info == 0 || window.menu_info != menu_info {
		menu = menu_init_or_replace(window, flags, menu_info)
	}	

	return
}

// replace existing menu
menu_init_or_replace :: proc(
	window: ^Window, 
	flags: Element_Flags, 
	menu_info: int = 0,
) -> (menu: ^Panel_Floaty) {
	if window.menu == nil {
		return menu_init(window, flags, menu_info)
	} else {
		element_destroy(window.menu)
		return menu_init(window, flags, menu_info)
	}
}

menu_init :: proc(
	window: ^Window, 
	flags: Element_Flags, 
	menu_info: int = -1,
	menu_filter := false,
) -> (menu: ^Panel_Floaty) {
	// strings.builder_reset(&window.menu_builder)
	window.menu_info = menu_info
	window.menu_filter = menu_filter
	
	menu = panel_floaty_init(&window.element, flags)
	menu.x = window.cursor_x
	menu.y = window.cursor_y
	window.menu = menu
	return
}

// add a basic button with auto closing
menu_add_item :: proc(
	menu: ^Panel_Floaty, 
	flags: Element_Flags,
	text: string,
	invoke: proc(^Button, rawptr),
	data: rawptr = nil,
) {
	button := button_init(menu.panel, flags, text)
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
	menu.width = width
	menu.height = height
	menu_show_position(menu)
}

menu_show_position :: proc(menu: ^Panel_Floaty) {
	margin := int(10 * SCALE)
	full := menu.window.rect
	menu.x = clamp(menu.x, margin, full.r - menu.width - margin)
	menu.y = clamp(menu.y, margin, full.b - menu.height - margin)
	element_repaint(menu)		
}

// true wether the requested element is from the menu tree
element_is_from_menu :: proc(window: ^Window, element: ^Element) -> bool {
	if window.menu == nil || (.Hide in window.menu.flags) {
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
	size: int,
}

efont_size :: proc(element: ^Element) -> int {
	scaled_size := f32(element.font_options == nil ? DEFAULT_FONT_SIZE : element.font_options.size) * SCALE * 10
	return int(i16(scaled_size) / 10)
}	

task_font_size :: proc(element: ^Element) -> int {
	scaled_size := f32(element.font_options == nil ? DEFAULT_FONT_SIZE : element.font_options.size) * TASK_SCALE * 10
	return int(i16(scaled_size) / 10)
	// scaled_size := f32(element.font_options == nil ? DEFAULT_FONT_SIZE : element.font_options.size) * TASK_SCALE
	// return int(scaled_size)
}	

fcs_icon :: proc(scaling: f32) -> int {
	fcs_size(DEFAULT_ICON_SIZE * scaling)
	fcs_font(font_icon)
	return int(i16(DEFAULT_ICON_SIZE * scaling * 10) / 10)
}

// using task scale
fcs_task :: proc(element: ^Element) -> int {
	font_index: int
	size: int

	if element.font_options == nil {
		font_index = font_regular
		size = DEFAULT_FONT_SIZE
	} else {
		font_index = element.font_options.font
		size = element.font_options.size
	}

	fcs_size(f32(size) * TASK_SCALE)
	fcs_font(font_index)
	return int(i16(f32(size) * TASK_SCALE * 10) / 10)
}

fcs_element :: proc(element: ^Element) -> int {
	font_index: int
	size: int

	if element.font_options == nil {
		font_index = font_regular
		size = DEFAULT_FONT_SIZE
	} else {
		font_index = element.font_options.font
		size = element.font_options.size
	}

	fcs_size(f32(size) * SCALE)
	fcs_font(font_index)
	return int(i16(f32(size) * SCALE * 10) / 10)
}

string_width :: #force_inline proc(text: string, x: f32 = 0, y: f32 = 0) -> int {
	return int(fontstash.TextBounds(&gs.fc, text, x, y))
}

icon_width :: #force_inline proc(icon: Icon, scaling: f32) -> f32 {
	font := fontstash.__getFont(&gs.fc, font_icon)
	isize := i16(DEFAULT_FONT_SIZE * 10 * scaling)
	scale := fontstash.__getPixelHeightScale(font, f32(isize / 10))
	return fontstash.CodepointWidth(font, rune(icon), scale)
}

fcs_size :: #force_inline proc(size: f32) {
	fontstash.SetSize(&gs.fc, size)
}

fcs_font :: #force_inline proc(font: int) {
	fontstash.SetFont(&gs.fc, font)
}

// font context state set color
fcs_color :: #force_inline proc(color: Color) {
	fontstash.SetColor(&gs.fc, color)
}

fcs_spacing :: #force_inline proc(spacing: f32) {
	fontstash.SetSpacing(&gs.fc, spacing)
}

fcs_blur :: #force_inline proc(blur: f32) {
	fontstash.SetBlur(&gs.fc, blur)
}

fcs_ah :: #force_inline proc(ah: Align_Horizontal) {
	fontstash.SetAH(&gs.fc, ah)
}

fcs_av :: #force_inline proc(av: Align_Vertical) {
	fontstash.SetAV(&gs.fc, av)
}

fcs_ahv :: #force_inline proc(ah: Align_Horizontal = .CENTER, av: Align_Vertical = .MIDDLE) {
	fontstash.SetAH(&gs.fc, ah)
	fontstash.SetAV(&gs.fc, av)
}

font_get :: #force_inline proc(font_index: int, loc := #caller_location) -> ^Font {
	return fontstash.__getFont(&gs.fc, font_index, loc)
}

fcs_push :: #force_inline proc() {
	fontstash.PushState(&gs.fc)
}

fcs_pop :: #force_inline proc() {
	fontstash.PopState(&gs.fc)
}

// counts first beginning tabs
tabs_count :: proc(text: string) -> (count: int) {
	for i in 0..<len(text) {
		if text[i] == '\t' {
			count += 1
		} else {
			return
		}
	}

	return
}