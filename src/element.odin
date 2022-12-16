package src

import "core:sort"
import "core:slice"
import "core:runtime"
import "core:image"
import "core:image/png"
import "core:mem"
import "core:log"
import "core:fmt"
import "core:math"
import "core:time"
import "core:unicode"
import "core:strings"
import "../fontstash"

DEBUG_PANEL :: false
UPDATE_HOVERED :: 1
UPDATE_HOVERED_LEAVE :: 2
UPDATE_PRESSED :: 3
UPDATE_PRESSED_LEAVE :: 4
UPDATE_FOCUS_GAINED :: 5
UPDATE_FOCUS_LOST :: 6

di_update_interacted :: proc(di: int) -> bool {
	return di == UPDATE_HOVERED || 
		di == UPDATE_HOVERED_LEAVE ||
		di == UPDATE_PRESSED ||
		di == UPDATE_PRESSED_LEAVE
}

di_update_pressed :: proc(di: int) -> bool {
	return di == UPDATE_PRESSED ||
		di == UPDATE_PRESSED_LEAVE
}

SCROLLBAR_SIZE :: 15
TEXT_MARGIN_VERTICAL :: 10
TEXT_MARGIN_HORIZONTAL :: 10
DEFAULT_FONT_SIZE :: 20
DEFAULT_ICON_SIZE :: 18
SPLITTER_SIZE :: 4

IMAGE_DISPLAY_HEIGHT :: 200

Message :: enum {
	Invalid,
	Update,
	Paint_Recursive,
	Layout,
	Deallocate,
	Destroy,
	Animate,
	Custom_Clip,

	// layouting
	Get_Width,
	Get_Height,

	// MOUSE
	INPUT_START,
	Mouse_Move,
	Mouse_Scroll_X, // di = scrolling
	Mouse_Scroll_Y, // di = scrolling
	Mouse_Drag, // dp = Mouse_Coordinates of drag point
	Left_Down, // di = click amount
	Left_Up,
	Middle_Down, // di = click amount
	Middle_Up,
	Right_Down, // di = click amount
	Right_Up,
	Clicked,
	INPUT_END,

	// get wanted hover cursor
	Get_Cursor,
	Scrolled_X, // wether the element has scrolled
	Scrolled_Y, // wether the element has scrolled
	Dropped_Files,
	Dropped_Text,

	Key_Combination, // dp = ^string, return 1 if handled
	Unicode_Insertion, // dp = ^rune, return 1 if handled

	Find_By_Point_Recursive, // dp = Find_By_Point struct
	Value_Changed, // whenever an element changes internal value

	// element specific
	Box_Set_Caret, // di = const start / end, dp = ^int index to set
	Box_Text_Color,
	Table_Get_Item, // dp = Table_Get_Item
	Button_Highlight, // di = 1 use, dp = optional color
	Panel_Color,

	// window
	Window_Close,
}

Find_By_Point :: struct {
	x, y: int,
	res: ^Element,
}

// using bprint* to print into the buffer
Table_Get_Item :: struct {
	buffer: []u8,
	output: string, // output from buffer data
	index: int,
	column: int,
	is_selected: bool,
}

Message_Proc :: proc(e: ^Element, msg: Message, di: int, dp: rawptr) -> int

Element_Flag :: enum {
	Invalid,

	Hide,
	Destroy,
	Destroy_Descendent,
	Disabled, // cant receive any input messages
	Non_Client, // non client elements

	VF, // Vertical Fill
	HF, // Horizontal Fill

	Tab_Movement_Allowed, // wether or not movement is allowed for the parent  
	Tab_Stop, // wether the element acts as a tab stop

	Sort_By_Z_Index, // sorts children by element.z_index

	// element specific flags
	Label_Center,
	Label_Right,
	Box_Can_Focus,

	Panel_Expand,
	Panel_Scroll_XY,
	Panel_Scroll_Horizontal,
	Panel_Scroll_Vertical,
	Panel_Horizontal,
	Panel_Default_Background,

	Split_Pane_Vertical,
	Split_Pane_Hidable,
	Split_Pane_Reversed,

	// windowing
	Window_Maximize,
	Window_Center_In_Owner,
}
Element_Flags :: bit_set[Element_Flag]

Element :: struct {
	flags: Element_Flags,
	parent: ^Element,children: [dynamic]^Element,
	
	window: ^Window, // root hierarchy

	bounds, clip: RectI,

	message_class: Message_Proc,
	message_user: Message_Proc,

	// z index, children will be drawn in different order
	z_index: int, 
	font_options: ^Font_Options, // biggy
	hover_info: string,

	// optional data that can be set andd used
	data: rawptr,
	allocator: mem.Allocator,
}

// default way to call clicked event on tab stop element
key_combination_check_click :: proc(element: ^Element, dp: rawptr) {
	combo := (cast(^string) dp)^
	
	if element.window.focused == element {
		if combo == "space" || combo == "return" {
			element_message(element, .Clicked)
		}
	}
}

// toggle hide flag
element_hide_toggle :: proc(element: ^Element) {
	element.flags ~= { .Hide }
}

// set hide flag
element_hide :: proc(element: ^Element, state: bool) -> (res: bool) {
	if state {
		res = .Hide not_in element.flags
		incl(&element.flags, Element_Flag.Hide)
	} else {
		res = .Hide in element.flags
		excl(&element.flags, Element_Flag.Hide)
	}
	
	return 
}

// add or stop an element from animating
element_animation_start :: proc(element: ^Element) {
	if element == nil {
		return
	}

	// find preexisting animation
	for e in gs.animating {
		if e == element {
			return
		}
	}

	append(&gs.animating, element)
	assert(.Destroy not_in element.flags)
}

// stop the animation of an element 
element_animation_stop :: proc(element: ^Element) -> bool {
	for i := len(gs.animating) - 1; i >= 0; i -= 1 {
		if gs.animating[i] == element {
			unordered_remove(&gs.animating, i)
			return true
		}
	}

	return false
}

// animate an value to a goal 
// returns true when the value is still lerped
animate_to :: proc(
	animate: ^bool,
	value: ^f32, 
	goal: f32,
	rate := f32(1),
	cuttoff := f32(0.001),
) -> (ok: bool) {
	// skip early
	if !animate^ {
		return
	}

	// check animations supported
	if !visuals_use_animations() {
		value^ = goal
		return
	}

	if value^ == -1 {
		value^ = goal
	} else {
		lambda := 10 * rate * visuals_animation_speed()
		res := math.lerp(value^, goal, 1 - math.exp(-lambda * gs.dt))
		// res := math.lerp(value^, end, 1 - math.pow(rate, core.dt * 10))

		// skip cutoff
		if abs(res - goal) < cuttoff {
			value^ = goal
		} else {
			value^ = res
			ok = true
		}
	}

	// set animate to false
	if !ok {
		animate^ = false
	}

	return
}

element_message :: proc(element: ^Element, msg: Message, di: int = 0, dp: rawptr = nil) -> int {
	if element == nil || (msg != .Deallocate && (.Destroy in element.flags)) {
		return 0
	}

	// skip disabled elements
	if msg >= .INPUT_START && msg <= .INPUT_END && (.Disabled in element.flags) {
		return 0
	}

	// try user call, exit call early on non 0 result
	if element.message_user != nil {
		if res := element.message_user(element, msg, di, dp); res != 0 {
			return res
		}
	}

	// execute normal call
	if element.message_class != nil {
		return element.message_class(element, msg, di, dp)
	}

	return 0
}

// init to wanted data type and set element data
element_init :: proc(
	$T: typeid, 
	parent: ^Element, 
	flags: Element_Flags, 
	messaging: Message_Proc,
	allocator: mem.Allocator,
	index_at := -1,
	cap := runtime.DEFAULT_RESERVE_CAPACITY,
	loc := #caller_location,
) -> (res: ^T) {
	res = new(T, allocator, loc)
	element := cast(^Element) res
	element.allocator = allocator
	element.children = make([dynamic]^Element, 0, cap, allocator)
	element.flags = flags
	element.message_class = messaging

	if parent != nil {
		element.window = parent.window
		element.parent = parent

		if index_at == -1 || index_at == len(parent.children) {
			append(&parent.children, element)
		} else {
			inject_at(&parent.children, index_at, element)
		}
	} 

	return
}

// reposition element and cal layout to children
element_move :: proc(element: ^Element, bounds: RectI) {
	// move to new position - msg children to layout
	element.clip = rect_intersection(element.parent.clip, bounds)
	element.bounds = bounds
	element_message(element, .Layout)
}

element_moveold :: proc(element: ^Element, bounds: RectI) {
	clip := element.parent != nil ? rect_intersection(element.parent.clip, bounds) : bounds
	moved := element.bounds != bounds || element.clip != clip
	layout: bool

	if moved {
		layout = true
		element.clip = clip
		element.bounds = bounds
	}

	if layout {
		// move to new position - msg children to layout
		element_message(element, .Layout)
	}
}

// issue repaints for children
element_repaint :: #force_inline proc(element: ^Element) {
	element.window.update_next = true
}

// custom call that can be used to iterate as wanted through children and output result
element_find_by_point_custom :: proc(element: ^Element, p: ^Find_By_Point) -> int {
	for i := len(element.children) - 1; i >= 0; i -= 1 {
		child := element.children[i]

		if child.bounds == {} {
			continue
		}

		if (.Hide not_in child.flags) && rect_contains(child.bounds, p.x, p.y) {
			p.res = child
			return 1
		}
	}

	return 0
}

// find first element by point
element_find_by_point :: proc(element: ^Element, x, y: int) -> ^Element {
	p := Find_By_Point { x, y, nil }

	// allowing custom find by point calls
	if element_message(element, .Find_By_Point_Recursive, 0, &p) == 1 {
		return p.res != nil ? p.res : element
	}

	temp := element_children_sorted_or_unsorted(element)

	for i := len(temp) - 1; i >= 0; i -= 1 {
		child := temp[i]

		if child.bounds == {} {
			continue
		}

		if (.Disabled not_in child.flags) && (.Hide not_in child.flags) && rect_contains(child.clip, p.x, p.y) {
			return element_find_by_point(child, x, y)
		}
	}


	return element
}

// find index linearly of element in parent
element_find_index_linear :: proc(element: ^Element) -> int {
	if element == nil {
		return -1
	}

	for child, i in element.parent.children {
		if child == element {
			return i
		}
	}

	return -1
}

// dont set any signals or flags
element_destroy_and_deallocate :: proc(element: ^Element) {
	element_message(element, .Destroy)

	// recurse to destroy all children
	for child in element.children {
		element_destroy_and_deallocate(child)
	}

	element_deallocate_raw(element)
}

element_destroy_descendents :: proc(element: ^Element, top_level: bool) {
	// recurse to destroy all children
	for child in element.children {
		if !top_level || (.Non_Client not_in child.flags) {
			element_destroy(child)
		}
	}
}

// mark children for destruction
// calls .Destroy in case anything should happen already
// doesnt deallocate!
element_destroy :: proc(element: ^Element) -> bool {
	// skip flag done
	if .Destroy in element.flags {
		return false
	}

	// add destroy flag
	element_message(element, .Destroy)
	incl(&element.flags, Element_Flags { .Destroy, .Hide })

	// set parent to destroy_descendent flag
	ancestor := element.parent
	for ancestor != nil {
		// stop early when one is already done
		if .Destroy_Descendent in ancestor.flags {
			break
		}

		incl(&ancestor.flags, Element_Flag.Destroy_Descendent)
		ancestor = ancestor.parent
	}

	element_destroy_descendents(element, false)

	// push repaint
	if element.parent != nil {
		element_repaint(element.parent)
	}

	return true
}

element_deallocate_raw :: proc(element: ^Element) {
	// if this element is being pressed -> clear the pressed field
	if element.window.pressed == element {
		window_set_pressed(element.window, nil, 0)
	}

	// reset to window element when this element was hovered
	if element.window.hovered == element {
		element.window.hovered = &element.window.element
	}

	// reset focused element
	if element.window.focused == element {
		element.window.focused = nil
	}

	// stop animation
	element_animation_stop(element)
	// free data
	delete(element.children)
	free(element, element.allocator)
}

// NOTE used internally
element_deallocate :: proc(element: ^Element) -> bool {
	if .Destroy_Descendent in element.flags {
		// clear flag
		excl(&element.flags, Element_Flag.Destroy_Descendent)

		// destroy each child, loop from end to pop quickly
		for i := len(element.children) - 1; i >= 0; i -= 1 {
			child := element.children[i]

			if element_deallocate(child) {
				unordered_remove(&element.children, i)
			}
		}
	}

	// log.info("DESTROY?", (.Destroy in element.flags), element.name)
	if .Destroy in element.flags {
		// send the destroy message to clear data
		element_message(element, .Deallocate)
		element_deallocate_raw(element)
		return true
	} else {
		// wasnt destroyed
		return false
	}
}

// reset focus to window
element_reset_focus :: proc(window: ^Window) {
	if window.focused != &window.element {
		element_focus(window, &window.element)
		element_repaint(&window.element)
	}
}

// focus an element and update both elements
element_focus :: proc(window: ^Window, element: ^Element) -> bool {
	prev := window.focused
	
	// skip same element
	if prev == element {
		return false
	}

	window.focused = element
	
	// send messages to prev and current
	if prev != nil {
		element_message(prev, .Update, UPDATE_FOCUS_LOST)
	}

	if element != nil {
		element_message(element, .Update, UPDATE_FOCUS_GAINED)
	}

	return true
}

// retrieve wanted children, may be sorted and need to be deallocated manually
element_children_sorted_or_unsorted :: proc(element: ^Element) -> (res: []^Element) {
	res = element.children[:]

	if .Sort_By_Z_Index in element.flags {
		res = slice.clone(res, context.temp_allocator)
		
		sort.quick_sort_proc(res, proc(a, b: ^Element) -> int {
			if a.z_index < b.z_index {
				return -1
			}	

			if a.z_index > b.z_index {
				return 1
			}

			return 0
		})
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

render_hovered_highlight :: #force_inline proc(target: ^Render_Target, bounds: RectI, scale := f32(1)) {
	color := theme_shadow(1)
	render_rect(target, bounds, color, ROUNDNESS)
}

//////////////////////////////////////////////
// button
//////////////////////////////////////////////

Button :: struct {
	using element: Element,
	builder: strings.Builder,
	invoke: proc(button: ^Button, data: rawptr),
}

button_message :: proc(element: ^Element, msg: Message, di: int, dp: rawptr) -> int {
	button := cast(^Button) element

	#partial switch msg {
		case .Paint_Recursive: {
			target := element.window.target
			pressed := element.window.pressed == element
			hovered := element.window.hovered == element
			text_color := hovered || pressed ? theme.text_default : theme.text_blank

			if res := element_message(element, .Button_Highlight, 0, &text_color); res != 0 {
				if res == 1 {
					rect := element.bounds
					// rect.l = rect.r - (4 * SCALE)
					rect.r = rect.l + int(4 * SCALE)
					render_rect(target, rect, text_color, 0)
				}
			}

			if hovered || pressed {
				render_rect_outline(target, element.bounds, text_color)
				render_hovered_highlight(target, element.bounds)
			}

			fcs_element(button)
			fcs_ahv()
			fcs_color(text_color)
			text := strings.to_string(button.builder)
			render_string_rect(target, element.bounds, text)
		}

		case .Update: {
			element_repaint(element)
		}

		case .Destroy: {
			delete(button.builder.buf)
		}

		case .Clicked: {
			if button.invoke != nil {
				button->invoke(button.data)
			}
		}

		case .Get_Cursor: {
			return int(Cursor.Hand)
		}

		case .Get_Width: {
			fcs_element(element)
			text := strings.to_string(button.builder)
			width := max(int(50 * SCALE), string_width(text) + int(TEXT_MARGIN_HORIZONTAL * SCALE))
			return width
		}

		case .Get_Height: {
			return efont_size(element) + int(TEXT_MARGIN_VERTICAL * SCALE)
		}

		case .Key_Combination: {
			key_combination_check_click(element, dp)
		}
	}

	return 0
}

button_init :: proc(
	parent: ^Element, 
	flags: Element_Flags, 
	text: string,
	message_user: Message_Proc = nil,
	allocator := context.allocator,
) -> (res: ^Button) {
	res = element_init(Button, parent, flags | { .Tab_Stop }, button_message, allocator)
	res.builder = strings.builder_make(0, 32)
	strings.write_string(&res.builder, text)
	res.message_user = message_user
	return
}

//////////////////////////////////////////////
// color button
//////////////////////////////////////////////

Color_Button :: struct {
	using element: Element,
	invoke: proc(button: ^Color_Button, data: rawptr),
	color: ^Color,
}

color_button_message :: proc(element: ^Element, msg: Message, di: int, dp: rawptr) -> int {
	button := cast(^Color_Button) element

	#partial switch msg {
		case .Paint_Recursive: {
			pressed := element.window.pressed == element
			hovered := element.window.hovered == element
			target := element.window.target

			text_color := hovered || pressed ? theme.text_default : theme.text_blank
			render_rect(target, element.bounds, button.color^)

			if hovered || pressed {
				render_rect_outline(target, element.bounds, text_color)
				render_hovered_highlight(target, element.bounds)
			}
		}

		case .Update: {
			element_repaint(element)
		}

		case .Clicked: {
			if button.invoke != nil {
				button->invoke(button.data)
			}
		}

		case .Get_Cursor: {
			return int(Cursor.Hand)
		}

		case .Get_Width: {
			return int(DEFAULT_FONT_SIZE * SCALE * 2)
		}

		case .Get_Height: {
			return int(DEFAULT_FONT_SIZE * SCALE)
		}

		case .Key_Combination: {
			key_combination_check_click(element, dp)
		}
	}

	return 0
}

color_button_init :: proc(
	parent: ^Element, 
	flags: Element_Flags, 
	color: ^Color,
	allocator := context.allocator,
) -> (res: ^Color_Button) {
	res = element_init(Color_Button, parent, flags, color_button_message, allocator)
	res.color = color
	res.data = res
	return
}

//////////////////////////////////////////////
// icon button
//////////////////////////////////////////////

Icon_Button :: struct {
	using element: Element,
	icon: Icon,
	invoke: proc(button: ^Icon_Button, data: rawptr),
}

icon_button_render_default :: proc(button: ^Icon_Button) {
	pressed := button.window.pressed == button
	hovered := button.window.hovered == button
	target := button.window.target

	text_color := hovered || pressed ? theme.text_default : theme.text_blank

	if element_message(button, .Button_Highlight, 0, &text_color) == 1 {
		rect := button.bounds
		rect.r = rect.l + int(4 * SCALE)
		render_rect(target, rect, text_color, 0)
	}

	if hovered || pressed {
		render_rect_outline(target, button.bounds, text_color)
		render_hovered_highlight(target, button.bounds)
	}

	fcs_icon(SCALE)
	fcs_ahv()
	fcs_color(text_color)
	render_icon_rect(target, button.bounds, button.icon)
}

icon_button_message :: proc(element: ^Element, msg: Message, di: int, dp: rawptr) -> int {
	button := cast(^Icon_Button) element

	#partial switch msg {
		case .Paint_Recursive: {
			icon_button_render_default(button)
		}

		case .Update: {
			element_repaint(element)
		}

		case .Clicked: {
			if button.invoke != nil {
				button->invoke(button.data)
			}
		}

		case .Get_Cursor: {
			return int(Cursor.Hand)
		}

		case .Get_Width: {
			w := icon_width(button.icon, SCALE)
			return int(w + TEXT_MARGIN_HORIZONTAL * SCALE)
		}

		case .Get_Height: {
			return efont_size(element) + int(TEXT_MARGIN_VERTICAL * SCALE)
		}

		case .Key_Combination: {
			key_combination_check_click(element, dp)
		}
	}

	return 0
}

icon_button_init :: proc(
	parent: ^Element, 
	flags: Element_Flags, 
	icon: Icon,
	message_user: Message_Proc = nil,
	allocator := context.allocator,
) -> (res: ^Icon_Button) {
	res = element_init(Icon_Button, parent, flags | { .Tab_Stop }, icon_button_message, allocator)
	res.icon = icon
	res.data = res
	res.message_user = message_user
	return
}

//////////////////////////////////////////////
// image button with fixed size
//////////////////////////////////////////////

Image_Button :: struct {
	using element: Element,
	kind: Texture_Kind,
	invoke: proc(data: rawptr),
	width: int,
	height: int,
	margin: int,
}

image_button_message :: proc(element: ^Element, msg: Message, di: int, dp: rawptr) -> int {
	button := cast(^Image_Button) element

	#partial switch msg {
		case .Paint_Recursive: {
			target := element.window.target
			pressed := element.window.pressed == element
			hovered := element.window.hovered == element
			color := hovered || pressed ? theme.text_default : theme.text_blank

			if res := element_message(element, .Button_Highlight, 0, &color); res != 0 {
				if res == 1 {
					rect := element.bounds
					rect.r = rect.l + int(4 * SCALE)
					render_rect(target, rect, color, 0)
				}
			}

			if hovered || pressed {
				render_rect_outline(target, element.bounds, color)
				render_hovered_highlight(target, element.bounds)
			}

			r := rect_margin(element.bounds, button.margin)
			render_texture_from_kind(target, button.kind, r, color)
		}

		case .Update: {
			element_repaint(element)
		}

		case .Clicked: {
			if button.invoke != nil {
				button.invoke(button.data)
			}
		}

		case .Get_Cursor: {
			return int(Cursor.Hand)
		}

		case .Get_Width: {
			return int(f32(button.width) * SCALE)
		}

		case .Get_Height: {
			return int(f32(button.height) * SCALE)
		}

		case .Key_Combination: {
			key_combination_check_click(element, dp)
		}
	}

	return 0
}

image_button_init :: proc(
	parent: ^Element, 
	flags: Element_Flags, 
	kind: Texture_Kind,
	w, h: int,
	message_user: Message_Proc = nil,
	allocator := context.allocator,	
) -> (res: ^Image_Button) {
	res = element_init(Image_Button, parent, flags | { .Tab_Stop }, image_button_message, allocator)
	assert(kind != .Fonts)
	res.kind = kind
	res.data = res
	res.width = w
	res.height = h
	res.margin = 5
	res.message_user = message_user
	return
}

//////////////////////////////////////////////
// label
//////////////////////////////////////////////

Label :: struct {
	using element: Element,
	builder: strings.Builder,
	custom_width: f32,
	color: ^Color,
}

label_message :: proc(element: ^Element, msg: Message, di: int, dp: rawptr) -> int {
	label := cast(^Label) element

	#partial switch msg {
		case .Paint_Recursive: {
			target := element.window.target
			text := strings.to_string(label.builder)
			
			ah: Align_Horizontal
			av: Align_Vertical
			if .Label_Center in element.flags {
				ah = .Middle
				av = .Middle
			} else if .Label_Right in element.flags {
				ah = .Right
				av = .Middle
			}

			fcs_element(element)
			fcs_ahv(ah, av)
			fcs_color(label.color == nil ? theme.text_default : label.color^)
			render_string_rect(target, element.bounds, text)
		}
		
		case .Update: {
			// if label.hover_info != "" {
			// 	// element_repaint(element)
			// }
		}

		case .Destroy: {
			delete(label.builder.buf)
		}

		case .Get_Width: {
			if label.custom_width != -1 {
				return int(label.custom_width * SCALE)
			} else {
				text := strings.to_string(label.builder)
				fcs_element(element)
				return string_width(text)
			}
		}

		case .Get_Height: {
			return efont_size(element)
		}

		// disables label intersection, sets to parent result
		case .Find_By_Point_Recursive: {
			// if label.hover_info == "" {
				point := cast(^Find_By_Point) dp
				point.res = element.parent
				return 1
			// }
		}
	}

	return 0
}

label_init :: proc(
	parent: ^Element, 
	flags: Element_Flags, 
	text := "",
	custom_width: f32 = -1,
	allocator := context.allocator,
) -> (res: ^Label) {
	res = element_init(Label, parent, flags, label_message, allocator)
	res.builder = strings.builder_make(0, 32)
	res.custom_width = custom_width
	strings.write_string(&res.builder, text)
	return
}

//////////////////////////////////////////////
// slider
//////////////////////////////////////////////

Slider_Format_Proc :: proc(builder: ^strings.Builder, position: f32)

Slider :: struct {
	using element: Element,
	position: f32,
	builder: strings.Builder,
	formatting: Slider_Format_Proc,
}

slider_default_formatting :: proc(
	builder: ^strings.Builder, 
	position: f32,
) {
	strings.builder_reset(builder)
	fmt.sbprintf(builder, "%.1f", position)
}

slider_message :: proc(element: ^Element, msg: Message, di: int, dp: rawptr) -> int {
	slider := cast(^Slider) element
	// SLIDER_ADD :: 8
	SLIDER_ADD :: 0

	#partial switch msg {
		case .Paint_Recursive: {
			pressed := element.window.pressed == element
			hovered := element.window.hovered == element
			target := element.window.target
	
			// CLIPPED STYLE
			bounds := element.bounds
			clips := [2]RectI {
				rect_cut_left(&bounds, int(slider.position	* rect_widthf(bounds))),
				bounds,
			}
			
			text_color := hovered || pressed ? theme.text_default : theme.text_blank
			colors := [2]Color {
				text_color,
				theme.background[1],
			}

			fcs_element(slider)
			fcs_ahv()
			strings.builder_reset(&slider.builder)
			slider.formatting(&slider.builder, slider.position)
			text := strings.to_string(slider.builder)

			for i in 0..<2 {
				render_push_clip(target, clips[i])
				fcs_color(colors[1 - i])
				render_rect(target, element.bounds, colors[i], ROUNDNESS)
				render_string_rect(target, element.bounds, text)
			}

			render_push_clip(target, element.bounds)
			render_rect_outline(target, element.bounds, text_color)
		}

		case .Mouse_Scroll_Y: {
			if element.window.ctrl {
				old := slider.position
				slider.position = clamp(slider.position + f32(di) * 0.05, 0, 1) 

				if old != slider.position	{
					element_message(element, .Value_Changed)
					element_repaint(element)
				}

				return 1
			}
		}

		case .Get_Cursor: {
			return int(Cursor.Resize_Horizontal)
		}

		case .Update: {
			element_repaint(element)
		}

		case .Get_Width: {
			return int(SCALE * 100)
		}

		case .Get_Height: {
			return efont_size(element) + int(TEXT_MARGIN_VERTICAL * SCALE + SLIDER_ADD * SCALE)
		}

		case .Destroy: {
			delete(slider.builder.buf)
		}
	}

	// change slider position and cause repaint
	if msg == .Left_Down || (msg == .Mouse_Drag && element.window.pressed_button == MOUSE_LEFT) {
		old := slider.position
		unit := f32(element.window.cursor_x - element.bounds.l) / f32(rect_width(element.bounds))

		if element.window.shift || element.window.ctrl || element.window.alt {
			unit = math.round(unit * 10) / 10
		}

		slider.position = 
			clamp(
				unit,
				0,
				1,
			)
		
		if old != slider.position	{
			element_message(element, .Value_Changed)
			element_repaint(element)
		}
	}

	return 0
}

slider_init :: proc(
	parent: ^Element, 
	flags: Element_Flags, 
	position: f32 = 0,
	formatting: Slider_Format_Proc = slider_default_formatting,
	allocator := context.allocator,
) -> (res: ^Slider) {
	res = element_init(Slider, parent, flags, slider_message, allocator)
	res.builder = strings.builder_make(0, 32)
	res.position = clamp(position, 0, 1)
	res.formatting = formatting
	return
}

// use this in case procedures have a value changed call!
slider_set :: proc(slider: ^Slider, goal: f32) {
	slider.position = clamp(goal, 0, 1)
	element_message(slider, .Value_Changed)
}

//////////////////////////////////////////////
// checkbox
//////////////////////////////////////////////

Checkbox :: struct {
	using element: Element,
	builder: strings.Builder,
	state: bool,
	state_transition: bool,
	state_unit: f32,
	invoke: proc(data: rawptr),
}

checkbox_message :: proc(element: ^Element, msg: Message, di: int, dp: rawptr) -> int {
	box := cast(^Checkbox) element

	BOX_MARGIN :: 5
	BOX_GAP :: 5

	box_icon_rect :: proc(box: ^Checkbox) -> (res: RectI) {
		res = rect_margin(box.bounds, int(BOX_MARGIN * SCALE))
		res.r = res.l + box_width(box)
		return
	}

	box_width :: proc(box: ^Checkbox) -> int {
		height := element_message(box, .Get_Height)
		return height + int(TEXT_MARGIN_VERTICAL * SCALE)
	}

	#partial switch msg {
		// width of text + icon rect
		case .Get_Width: {
			text := strings.to_string(box.builder)
			fcs_element(element)
			text_width := string_width(text)
			
			margin := int(BOX_MARGIN * SCALE)
			gap := int(BOX_GAP * SCALE)
			box_width := box_width(box)

			return int(text_width + margin * 2 + box_width + gap)
		}

		case .Get_Height: {
			return efont_size(element) + int(TEXT_MARGIN_VERTICAL * SCALE)
		}

		case .Get_Cursor: {
			return int(Cursor.Hand)
		}

		case .Paint_Recursive: {
			pressed := element.window.pressed == element
			hovered := element.window.hovered == element
			target := element.window.target

			text_color := hovered || pressed ? theme.text_default : theme.text_blank
			render_rect_outline(target, element.bounds, text_color)

			box_rect := box_icon_rect(box)
			box_color := color_blend(theme.text_good, theme.text_bad, box.state_unit, true)
			render_rect(target, box_rect, box_color, ROUNDNESS)
			
			if hovered {
				render_hovered_highlight(target, element.bounds)
			}

			box_width := rect_width_halfed(box_rect)

			moving_rect := box_rect
			moving_rect.l = box_rect.l + int(box.state_unit * f32(box_width))
			moving_rect.r = moving_rect.l + box_width - int(1 * SCALE)
			moving_rect = rect_margin(moving_rect, int(2 * SCALE))
			render_rect(target, moving_rect, text_color, ROUNDNESS)

			text_bounds := element.bounds
			text_bounds.l = box_rect.r + int(BOX_GAP * SCALE)

			fcs_element(element)
			fcs_ahv(.Left, .Middle)
			fcs_color(text_color)
			render_string_rect(target, text_bounds, strings.to_string(box.builder))
		}

		case .Clicked: {
			box.state = !box.state
			element_repaint(element)
	
			element_message(element, .Value_Changed)
			element_animation_start(element)
			box.state_transition = true

			if box.invoke != nil {
				box.invoke(box.data)
			}
		}

		case .Animate: {
			handled := animate_to(
				&box.state_transition,
				&box.state_unit,
				box.state ? 1 : 0,
				1,
				0.01,
			)

			return int(handled)
		}

		case .Key_Combination: {
			key_combination_check_click(element, dp)
		}

		case .Destroy: {
			delete(box.builder.buf)
		}
	}

	return 0
}

checkbox_init :: proc(
	parent: ^Element, 
	flags: Element_Flags, 
	text: string,
	state: bool,
	allocator := context.allocator,
) -> (res: ^Checkbox) {
	res = element_init(Checkbox, parent, flags | { .Tab_Stop }, checkbox_message, allocator)
	checkbox_set(res, state)
	res.builder = strings.builder_make(0, 32)
	res.data = res
	strings.write_string(&res.builder, text)
	return
}

checkbox_set :: proc(box: ^Checkbox, to: bool) {
	box.state = to
	box.state_unit = f32(to ? 1 : 0)
	element_message(box, .Value_Changed)
}

//////////////////////////////////////////////
// spacer
//////////////////////////////////////////////

Spacer_Style :: enum {
	Empty,
	Thin,
	Full,
	Dotted,
}

Spacer :: struct {
	using element: Element,
	width, height: int,
	vertical: bool,
	style: Spacer_Style,
	color: ^Color,
}

spacer_message :: proc(element: ^Element, msg: Message, di: int, dp: rawptr) -> int {
	spacer := cast(^Spacer) element

	#partial switch msg {
		case .Paint_Recursive: {
			target := element.window.target
			color := spacer.color == nil ? theme.text_default : spacer.color^

			switch spacer.style {
				case .Empty: {} 
				
				case .Thin: {
					// limit to height / width
					rect := element.bounds

					if spacer.vertical {
						rect.l += rect_width_halfed(rect)
						rect.r = rect.l + LINE_WIDTH
					} else {
						rect.t += rect_height_halfed(rect)
						rect.b = rect.t + LINE_WIDTH
					}

					render_rect(target, rect, color, ROUNDNESS)
				} 

				case .Full: {
					render_rect(target, element.bounds, color, ROUNDNESS)
				}

				case .Dotted: {
					// TODO dotted line
				}
			}
		}

		case .Get_Width: {
			return int(f32(spacer.width) * SCALE)
		}

		case .Get_Height: {
			return int(f32(spacer.height) * SCALE)
		}
	}

	return 0
}

spacer_init :: proc(
	parent: ^Element, 
	flags: Element_Flags, 
	w: int,
	h: int,
	style: Spacer_Style = .Empty,
	vertical := false,
	allocator := context.allocator,
) -> (res: ^Spacer) {
	res = element_init(Spacer, parent, flags, spacer_message, allocator)
	res.width = w
	res.height = h
	res.vertical = vertical
	res.style = style
	return
}

//////////////////////////////////////////////
// panel
//////////////////////////////////////////////

Panel :: struct {
	using element: Element,
	hscrollbar: ^Scrollbar,
	vscrollbar: ^Scrollbar,

	// good to have
	layout_elements_in_reverse: bool,
	
	// gut info
	margin: int,
	gap: int,
	color: ^Color,

	// shadow + roundness
	shadow: bool,
	rounded: bool,
	outline: bool,

	background_index: int,
}

// // clears the panel children, with care for the scrollbar
// panel_clear_without_scrollbar :: proc(panel: ^Panel) {
// 	// TODO probably leaks cuz children werent destroyed
// 	clear(&panel.children)
// 	// if panel.scrollbar == nil {
// 	// 	clear(&panel.children)
// 	// } else {
// 	// 	resize(&panel.children, 1)
// 	// }
// }

panel_calculate_per_fill :: proc(panel: ^Panel, hspace, vspace: int) -> (per_fill, count: int) {
	horizontal := .Panel_Horizontal in panel.flags 
	available := horizontal ? hspace : vspace
	fill: int

	for child in panel.children {
		if (.Hide in child.flags) || (.Non_Client) in child.flags {
			continue
		}

		count += 1

		if horizontal {
			if .HF in child.flags {
				fill += 1
			} else if available > 0 {
				available -= element_message(child, .Get_Width, vspace)
			}
		} else {
			if .VF in child.flags {
				fill += 1
			} else if available > 0 {
				available -= element_message(child, .Get_Height, hspace)
			}
		}
	}

	if count != 0 {
		available -= (count - 1) * int(f32(panel.gap) * SCALE)
	}

	if available > 0 && fill != 0 {
		per_fill = available / fill
	}

	return
}

panel_measure :: proc(panel: ^Panel, di: int) -> int {
	horizontal := .Panel_Horizontal in panel.flags 
	per_fill, _ := panel_calculate_per_fill(panel, horizontal ? di : 0, horizontal ? 0 : di)
	size := 0

	for child, i in panel.children {
		if (.Hide in child.flags) || (.Non_Client in child.flags) {
			continue
		}

		temp_size := ((horizontal ? .HF : .VF) in child.flags) ? per_fill : 0
		child_size := element_message(child, horizontal ? .Get_Height : .Get_Width, temp_size)
		if child_size > size {
			size = child_size
		}
	}

	return size + int(f32(panel.margin) * SCALE * 2)
}

panel_layout :: proc(
	panel: ^Panel, 
	bounds: RectI, 
	measure: bool, 
) -> int {
	horizontal := .Panel_Horizontal in panel.flags
	scaled_margin := int(f32(panel.margin) * SCALE)
	position_x := int(0)
	position_y := int(0)
	position_layout := scaled_margin

	// TODO check for scrollbar hide flag?
	if !measure && scrollbar_valid(panel.hscrollbar) {
		position_x -= int(panel.hscrollbar.position)
	}

	if !measure && scrollbar_valid(panel.vscrollbar) {
		position_y -= int(panel.vscrollbar.position)
	}

	hspace := rect_width(bounds) - scaled_margin * 2
	vspace := rect_height(bounds) - scaled_margin * 2
	per_fill, count := panel_calculate_per_fill(panel, int(hspace), int(vspace))
	expand := .Panel_Expand in panel.flags
	gap_scaled := int(f32(panel.gap) * SCALE)

	for i in 0..<len(panel.children) {
		child := panel.children[panel.layout_elements_in_reverse ? len(panel.children) - 1 - i : i]
		// child := panel.children[i]

		if (.Hide in child.flags) || (.Non_Client in child.flags) {
			continue
		}

		if horizontal {
			height := (.VF in child.flags) || expand ? vspace : element_message(child, .Get_Height, (.HF in child.flags) ? per_fill : 0)
			width := (.HF in child.flags) ? per_fill : element_message(child, .Get_Width, height)

			relative := RectI {
				position_layout + position_x,
				position_layout + position_x + width,
				position_y + scaled_margin + (vspace - height) / 2,
				position_y + scaled_margin + (vspace + height) / 2,
			}

			if !measure {
				element_move(child, rect_translate(relative, bounds))
			}

			position_layout += width + gap_scaled
		} else {
			width := (.HF in child.flags) || expand ? hspace : element_message(child, .Get_Width, (.VF in child.flags) ? per_fill : 0)
			height := (.VF in child.flags) ? per_fill : element_message(child, .Get_Height, int(width))

			relative := RectI {
				position_x + scaled_margin + (hspace - width) / 2,
				position_x + scaled_margin + (hspace + width) / 2,
				position_layout + position_y,
				position_layout + position_y + height,
			}

			if !measure {
				element_move(child, rect_translate(relative, bounds))
			}

			position_layout += height + gap_scaled
		}
	}

	return position_layout - int((count != 0 ? f32(panel.gap) : 0) * SCALE) + scaled_margin
}

panel_render_default :: proc(target: ^Render_Target, panel: ^Panel) {
	color: Color
	element_message(panel, .Panel_Color, 0, &color)

	if color == {} {
		when DEBUG_PANEL {
			render_rect_outline(target, rect_margin(element.bounds, 0), BLUE)
		}
		
		return
	}

	bounds := panel.bounds

	roundness := panel.rounded ? ROUNDNESS : 0
	if panel.shadow {
		render_drop_shadow(target, bounds, color, roundness)
	} else {
		render_rect(target, bounds, color, roundness)
	}

	if panel.outline {
		render_rect_outline(target, bounds, theme.text_default, roundness)
	}

	when DEBUG_PANEL {
		render_rect_outline(target, rect_margin(element.bounds, 0), GREEN)
	}
}

panel_message :: proc(element: ^Element, msg: Message, di: int, dp: rawptr) -> int {
	panel := cast(^Panel) element

	#partial switch msg {
		case .Custom_Clip: {
			if panel.shadow {
				rect := cast(^RectI) dp
				rect^ = rect_margin(element.clip, -DROP_SHADOW)
			}
		}

		case .Layout: {
			bounds := element.bounds
			scrollbar_size := int(SCROLLBAR_SIZE * SCALE)
			scrollbar_both := scrollbar_valid(panel.vscrollbar) && scrollbar_valid(panel.hscrollbar)

			if panel.vscrollbar != nil {
				bounds_before := bounds
				scrollbar_bounds := rect_cut_right(&bounds, scrollbar_size)
				panel.vscrollbar.maximum = panel_layout(panel, bounds, true)
				panel.vscrollbar.page = rect_height(bounds)
				panel.vscrollbar.shorted = scrollbar_both
				element_move(panel.vscrollbar, scrollbar_bounds)

				// reset bounds if hidden
				if .Hide in panel.vscrollbar.flags {
					bounds = bounds_before
				} 
			}

			if panel.hscrollbar != nil {
				bounds_before := bounds
				scrollbar_bounds := rect_cut_bottom(&bounds, scrollbar_size)
				// TODO double check max 
				panel.hscrollbar.maximum = element_message(panel, .Get_Width)
				panel.hscrollbar.page = rect_width(bounds)
				element_move(panel.hscrollbar, scrollbar_bounds)

				// reset bounds if hidden
				if .Hide in panel.hscrollbar.flags {
					bounds = bounds_before
				} 
			}

			// panel.clip = bounds
			panel_layout(panel, bounds, false)
		}

		case .Update: {
			for child in element.children {
				element_message(child, .Update, di, dp)
			}
		}

		case .Left_Down: {
			element_reset_focus(element.window)
		}

		case .Get_Width: {
			if .Panel_Horizontal in element.flags {
				height := di

				// take out horizontal scrollbar
				if scrollbar_valid(panel.hscrollbar) {
					scrollbar_size := int(SCROLLBAR_SIZE * SCALE)
					height -= scrollbar_size					
				}

				return int(panel_layout(panel, { 0, 0, 0, height }, true))
			} else {
				return panel_measure(panel, di)
			}
		}

		case .Get_Height: {
			if .Panel_Horizontal in element.flags {
				return panel_measure(panel, di)
			} else {
				width := di
		
				// take out vertical scrollbar
				if scrollbar_valid(panel.vscrollbar) {
					scrollbar_size := int(SCROLLBAR_SIZE * SCALE)
					width -= scrollbar_size
				}
		
				return int(panel_layout(panel, { 0, width, 0, 0 }, true))
			}
		}

		case .Panel_Color: {
			color := cast(^Color) dp
			
			if panel.color != nil {
				color^ = panel.color^
			}

			if .Panel_Default_Background in panel.flags {
				color^ = theme.background[panel.background_index]
			}

			if color^ == TRANSPARENT {
				return 0
			}
		}

		case .Paint_Recursive: {
			target := element.window.target
			panel_render_default(target, panel)
		}

		case .Mouse_Scroll_X: {
			if scrollbar_valid(panel.hscrollbar) {
				return element_message(panel.hscrollbar, msg, di, dp)
			}
		}

		case .Mouse_Scroll_Y: {
			if scrollbar_valid(panel.vscrollbar) {
				return element_message(panel.vscrollbar, msg, di, dp)
			}
		}
	}

	return 0
}	

// check for scrolling flags
scroll_flags :: proc(flags: Element_Flags) -> bool {
	return (.Panel_Scroll_XY in flags) ||
		(.Panel_Scroll_Horizontal in flags) ||
		(.Panel_Scroll_Vertical in flags) 
}

// panel destroy elements besides 

panel_init :: proc(
	parent: ^Element, 
	flags: Element_Flags, 
	margin: int = 0,
	gap: int = 0,
	color: ^Color = nil,
	allocator := context.allocator,
) -> (res: ^Panel) {
	has_scroll_flags := scroll_flags(flags)
	flags := flags

	if has_scroll_flags {
		flags += { .Sort_By_Z_Index }
	}

	res = element_init(Panel, parent, flags, panel_message, allocator)
	res.margin = margin
	res.color = color
	res.gap = gap

	if has_scroll_flags {
		if (.Panel_Scroll_XY in flags) || (.Panel_Scroll_Vertical in flags) {
			res.vscrollbar = scrollbar_init(res, { .Non_Client }, false, allocator)
		}

		if (.Panel_Scroll_XY in flags) || (.Panel_Scroll_Horizontal in flags) {
			res.hscrollbar = scrollbar_init(res, { .Non_Client }, true, allocator)
		}
	}

	return
}

// offset by scrollbar
panel_children :: proc(panel: ^Panel) -> []^Element {
	off := int(panel.vscrollbar != nil) + int(panel.hscrollbar != nil)
	return panel.children[off:]
}

//////////////////////////////////////////////
// panel floaty
//////////////////////////////////////////////

// nice to have a panel with static size or changable size 
Panel_Floaty :: struct {
	using element: Element,
	panel: ^Panel,

	x, y: int,
	width, height: int,
}

panel_floaty_message :: proc(element: ^Element, msg: Message, di: int, dp: rawptr) -> int {
	floaty := cast(^Panel_Floaty) element
	panel := floaty.panel

	#partial switch msg {
		case .Layout: {
			w := int(f32(floaty.width))
			h := int(f32(floaty.height))
			// w := int(f32(floaty.width) * SCALE)
			// h := int(f32(floaty.height) * SCALE)
			rect := rect_wh(floaty.x, floaty.y, w, h)
			element_move(panel, rect)
		}
	}

	return 0
}

panel_floaty_init :: proc(
	parent: ^Element,
	panel_flags: Element_Flags,
	allocator := context.allocator,
) -> (res: ^Panel_Floaty) {
	res	= element_init(Panel_Floaty, parent, {}, panel_floaty_message, allocator)
	res.z_index = 255
	
	flags := panel_flags + { .Panel_Default_Background }
	p := panel_init(res, flags)
	p.margin = 4
	p.rounded = true
	res.panel = p
	return
}

//////////////////////////////////////////////
// scrollbar
//////////////////////////////////////////////

// scrollbar can be horizontal or vertically set
// elements 0&2 are buttons
// element 1 is the thumb that can be dragged
Scrollbar :: struct {
	using element: Element,
	horizontal: bool,
	// TODO force opened option

	force_visible: bool,
	maximum: int,
	page: int,
	drag_offset: int,
	position: f32,
	in_drag: bool,	
	shorted: bool,
}

// clamp position
scrollbar_position_clamp :: proc(scrollbar: ^Scrollbar) -> (diff: int) {
	diff = scrollbar.maximum - scrollbar.page

	if scrollbar.position < 0 {
		scrollbar.position = 0
	} else if scrollbar.position > f32(diff) {
		scrollbar.position = f32(diff)
	}

	return
}

scrollbar_message :: proc(element: ^Element, msg: Message, di: int, dp: rawptr) -> int {
	scrollbar := cast(^Scrollbar) element

	#partial switch msg {
		case .Paint_Recursive: {
			rect := element.bounds
			render_rect(element.window.target, rect, theme.background[0])

			// leave early when rendering and forced visible
			if scrollbar_inactive(scrollbar) && scrollbar.force_visible {
				return 1
			}
		}

		case .Get_Width, .Get_Height: {
			scaled_size := SCROLLBAR_SIZE * SCALE
			return int(scaled_size)
		}

		case .Mouse_Scroll_X, .Mouse_Scroll_Y: {
			handled: int

			// avoid unwanted scroll
			if 
				(msg == .Mouse_Scroll_X && !scrollbar.horizontal) || 
				(msg == .Mouse_Scroll_Y && scrollbar.horizontal) || 
				(.Hide in scrollbar.flags) {
				return 0
			}

			scrollbar.position -= f32(di) * 20
			scrollbar_position_clamp(scrollbar)

			element_repaint(scrollbar)
			out: Message = msg == .Mouse_Scroll_X ? .Scrolled_X : .Scrolled_Y
			element_message(scrollbar.parent, out)
			return 1
		}

		case .Layout: {
			a := scrollbar.children[0]
			b := scrollbar.children[1]
			c := scrollbar.children[2]

			hovered := element.window.hovered == b
			pressed := element.window.hovered == b

			if scrollbar_inactive(scrollbar) && !scrollbar.force_visible {
				scrollbar.position = 0
				incl(&element.flags, Element_Flag.Hide)
				incl(&a.flags, Element_Flag.Hide)
				incl(&b.flags, Element_Flag.Hide)
				incl(&c.flags, Element_Flag.Hide)
			} else {
				excl(&element.flags, Element_Flag.Hide)
				excl(&a.flags, Element_Flag.Hide)
				excl(&b.flags, Element_Flag.Hide)
				excl(&c.flags, Element_Flag.Hide)

				// layout each element
				scrollbar_size := scrollbar.horizontal ? rect_width(element.bounds) : rect_height(element.bounds)
				// if !scrollbar.horizontal && scrollbar.shorted {
				// 	scrollbar_size -= math.round(SCROLLBAR_SIZE * SCALE)
				// }

				// TODO will probably not work without float calc
				thumb_size := scrollbar_size * scrollbar.page / scrollbar.maximum
				thumb_size = max(int(SCROLLBAR_SIZE * 2 * SCALE), thumb_size)

				// clamp position
				diff := scrollbar_position_clamp(scrollbar)

				// clamp
				thumb_position := int(scrollbar.position / f32(diff) * f32(scrollbar_size - thumb_size))
				if scrollbar.position == f32(diff) {
					thumb_position = scrollbar_size - thumb_size
				}

				if !scrollbar.horizontal {
					r := element.bounds
					r.b = r.t + thumb_position
					element_move(a, r) // button
					r.t = r.b
					r.b = r.t + thumb_size
					element_move(b, r) // thumb
					r.t = r.b
					r.b = element.bounds.b
					element_move(c, r) // button
				} else {
					r := element.bounds
					r.r = r.l + thumb_position
					element_move(a, r) // button
					r.l = r.r
					r.r = r.l + thumb_size
					element_move(b, r) // thumb
					r.l = r.r
					r.r = element.bounds.r
					element_move(c, r) // button
				}
			}
		}
	}

	return 0
}

scrollbar_button_message :: proc(element: ^Element, msg: Message, di: int, dp: rawptr) -> int {
	button := cast(^Scrollbar_Button) element
	scrollbar := cast(^Scrollbar) element.parent
	is_down := button.direction_down

	#partial switch msg {
		// case .Paint_Recursive: {
		// 	target := element.window.target

		// 	if is_down {
		// 		render_rect(target, element.bounds, { 210, 255, 210, 255 })
		// 	} else {
		// 		render_rect(target, element.bounds, { 210, 210, 255, 255 })
		// 	}
		// }

		case .Get_Cursor: {
			return int(Cursor.Arrow)
		}

		case .Left_Down: {
			element_animation_start(element)
		}

		case .Left_Up: {
			element_animation_stop(element)
		}

		case .Animate: {
			direction: f32 = is_down ? 1 : -1
			scrollbar.position += direction * 0.01 * f32(scrollbar.page)
			element_repaint(scrollbar)
			out: Message = scrollbar.horizontal ? .Scrolled_X : .Scrolled_Y
			element_message(scrollbar.parent, out)
			return 1
		}
	}

	return 0
}

scroll_thumb_message :: proc(element: ^Element, msg: Message, di: int, dp: rawptr) -> int {
	scrollbar := cast(^Scrollbar) element.parent
	
	#partial switch msg {
		case .Paint_Recursive: {
			target := element.window.target
			hovered := element.window.hovered == element
			pressed := element.window.pressed == element
			rect := rect_margin(element.bounds, int(3 * SCALE))
			color := theme.text_default
			color.a = pressed || hovered ? 200 : 150
			render_rect(target, rect, color, ROUNDNESS)
		}

		case .Update: {
			element_repaint(element)
		}

		case .Mouse_Drag: {
			if element.window.pressed_button == MOUSE_LEFT {
				if !scrollbar.in_drag {
					scrollbar.in_drag = true

					if !scrollbar.horizontal {
						scrollbar.drag_offset = element.bounds.t - scrollbar.bounds.t - element.window.cursor_y
					} else {
						scrollbar.drag_offset = element.bounds.l - scrollbar.bounds.l - element.window.cursor_x
					}
				}

				thumb_position := (!scrollbar.horizontal ? element.window.cursor_y : element.window.cursor_x) + scrollbar.drag_offset
				thumb_size := !scrollbar.horizontal ? rect_height(element.bounds) : rect_width(element.bounds)
				thumb_diff := scrollbar.page - thumb_size
				scrollbar.position = f32(thumb_position) / f32(thumb_diff) * f32(scrollbar.maximum - scrollbar.page)
				element_repaint(scrollbar)
				out: Message = scrollbar.horizontal ? .Scrolled_X : .Scrolled_Y
				element_message(scrollbar.parent, out)
			}
		}

		case .Left_Up: {
			scrollbar.in_drag = false
		}
	}

	return 0
}

Scrollbar_Button :: struct {
	using element: Element,
	direction_down: bool,
	horizontal: bool,
}

scrollbar_button_init :: proc(
	parent: ^Element,
	direction_down: bool,
	horizontal: bool,
	allocator := context.allocator,
) -> (res: ^Scrollbar_Button) {
	res = element_init(Scrollbar_Button, parent, {}, scrollbar_button_message, allocator)
	res.direction_down = direction_down
	res.horizontal = horizontal
	return
}

scrollbar_init :: proc(
	parent: ^Element, 
	flags: Element_Flags,
	horizontal: bool,
	allocator := context.allocator,
) -> (res: ^Scrollbar) {
	res = element_init(Scrollbar, parent, flags, scrollbar_message, allocator)
	res.horizontal = horizontal
	res.z_index = 255

	scrollbar_button_init(res, false, horizontal, allocator)
	element_init(Element, res, {}, scroll_thumb_message, allocator)
	scrollbar_button_init(res, true, horizontal, allocator)

	return
}

scrollbars_layout_prior :: proc(
	bounds: ^RectI,
	hscrollbar: ^Scrollbar,
	vscrollbar: ^Scrollbar,
) -> (bottom, right: RectI) {
	scrollbar_size := int(SCROLLBAR_SIZE * SCALE)
	
	if vscrollbar != nil {
		right = rect_cut_right(bounds, scrollbar_size)
	}

	if hscrollbar != nil {
		bottom = rect_cut_bottom(bounds, scrollbar_size)
	}

	return
}

scrollbar_layout_post :: proc(
	hscrollbar: ^Scrollbar,
	hrect: RectI,
	hmax: int,
	vscrollbar: ^Scrollbar,
	vrect: RectI,
	vmax: int,
) {
	if vscrollbar != nil {
		vscrollbar.maximum = vmax
		vscrollbar.page = rect_height(vrect)
		element_move(vscrollbar, vrect)
	}

	if hscrollbar != nil {
		hrect := hrect

		// extend the hrect if the vscrollbar was invalid
		if .Hide in vscrollbar.flags {
			hrect.r += int(SCROLLBAR_SIZE * SCALE)
		}

		hscrollbar.maximum = hmax
		hscrollbar.page = rect_width(hrect)
		element_move(hscrollbar, hrect)
	}
}

// // keep scrollbar in frame when in need for manual panning
// scrollbar_keep_in_frame :: proc(
// 	scrollbar: ^Scrollbar, 
// 	bounds: RectI, 
// 	up: bool,
// ) {
// 	scrollbar_size := scrollbar.horizontal ? rect_widthf(bounds) : rect_heightf(bounds)
// 	MARGIN :: 50

// 	if !scrollbar.horizontal {
// 		if up && bounds.t - MARGIN <= 0 {
// 			scrollbar.position = f32(bounds.t) + scrollbar.position - MARGIN
// 			return
// 		}

// 		if !up && f32(bounds.b) + scrollbar.position + MARGIN >= scrollbar_size {
// 			scrollbar.position = (f32(bounds.b) + scrollbar.position) - scrollbar_size + MARGIN
// 			return
// 		}
// 	} else {			
// 		// if up && bounds.t - MARGIN <= 0 {
// 		// 	scrollbar.position = bounds.t + scrollbar.position - MARGIN
// 		// } 

// 		// if !up && bounds.b + scrollbar.position + MARGIN >= scrollbar_size {
// 		// 	scrollbar.position = (bounds.b + scrollbar.position) - scrollbar_size + MARGIN
// 		// }
// 	}
// }

// wether the scrollbar is currently active
scrollbar_inactive :: proc(scrollbar: ^Scrollbar) -> bool {
	return scrollbar.page >= scrollbar.maximum || scrollbar.maximum <= 0 || scrollbar.page == 0
}

scrollbar_valid :: proc(scrollbar: ^Scrollbar) -> bool {
	return scrollbar != nil && (.Hide not_in scrollbar.flags)
}

scrollbar_position_set :: #force_inline proc(scrollbar: ^Scrollbar, pos: f32) {
	if scrollbar != nil {
		scrollbar.position = pos
	}
}

//////////////////////////////////////////////
// table
//////////////////////////////////////////////

// TABLE_ROW :: 30
// TABLE_HEADER :: 30
// TABLE_COLUMN_GAP :: 20

// Table :: struct {
// 	using element: Element,
	
// 	scrollbar: ^Scrollbar,
// 	columns: string,
// 	buffer: [256]u8,

// 	item_count: int, // top to bottom per column
// 	column_widths: []f32, // max width per every column
// 	column_count: int, // columns are left to right <->
// }

// table_message :: proc(element: ^Element, msg: Message, di: int, dp: rawptr) -> int {
// 	table := cast(^Table) element

// 	#partial switch msg {
// 		case .Get_Width: {
// 			return int(200 * SCALE)
// 		}

// 		case .Get_Height: {
// 			return int(200 * SCALE)
// 		}

// 		case .Layout: {
// 			scrollbar_bounds := element.bounds
// 			scrollbar_bounds.l = scrollbar_bounds.r - SCROLLBAR_SIZE * SCALE
// 			table.scrollbar.maximum = f32(table.item_count) * TABLE_ROW * SCALE
// 			table.scrollbar.page = rect_height(element.bounds) - TABLE_HEADER * SCALE
// 			element_move(table.scrollbar, scrollbar_bounds)
// 		}

// 		case .Paint_Recursive: {
// 			target := element.window.target
// 			defer render_rect_outline(target, element.bounds, theme.text_default)

// 			assert(table.column_widths != nil, "table_resize_columns needs to be called once")

// 			item := Table_Get_Item {
// 				buffer = table.buffer[:],
// 			}

// 			row := element.bounds
// 			row_height := TABLE_ROW * SCALE
// 			row.t += TABLE_HEADER * SCALE
// 			row.t -= f32(int(table.scrollbar.position) % int(row_height))

// 			fcs_element(element)
// 			fcs_ahv(.Left, .Middle)

// 			hovered := table_hit_test(table, element.window.cursor_x, element.window.cursor_y)
// 			for i := int(table.scrollbar.position / row_height); i < table.item_count; i += 1 {
// 				if row.t > element.clip.b {
// 					break
// 				}

// 				row.b = row.t + row_height
				
// 				// init
// 				item.index = i
// 				item.is_selected = false
// 				item.column = 0
// 				text_color := theme.text_default
// 				element_message(element, .Table_Get_Item, 0, &item)

// 				if item.is_selected {
// 					render_rect(target, row, text_color, 0)
// 					text_color = theme.background[0]
// 				} else if hovered == i {
// 					render_rect(target, row, text_color, 0)
// 					text_color = theme.background[0]
// 				}

// 				fcs_color(text_color)
// 				fcs_ahv(.Left, .Middle)
// 				cell := row
// 				cell.l += TABLE_COLUMN_GAP * SCALE

// 				// walk through each column
// 				for j in 0..<table.column_count {
// 					// dont recall j == 0
// 					if j != 0 {
// 						item.column = j
// 						element_message(element, .Table_Get_Item, 0, &item)
// 					}

// 					cell.r = cell.l + table.column_widths[j]
// 					render_string_rect(target, cell, item.output)
// 					cell.l += table.column_widths[j] + TABLE_COLUMN_GAP * SCALE
// 				}

// 				row.t += row_height
// 			}

// 			// header 
// 			header := element.bounds
// 			header.b = header.t + TABLE_HEADER * SCALE
// 			render_rect(target, header, color_blend_amount(theme.text_default, WHITE, 0.1), ROUNDNESS)
// 			render_underline(target, header, theme.text_default, 2)
// 			header.l += TABLE_COLUMN_GAP * SCALE

// 			fcs_color(theme.text_default)

// 			// draw each column
// 			index := 0
// 			mod := table.columns
// 			for word in strings.split_iterator(&mod, "\t") {
// 				header.r = header.l + table.column_widths[index]
// 				render_string_rect(target, header, word)
// 				header.l += table.column_widths[index] + TABLE_COLUMN_GAP * SCALE
// 				index += 1	
// 			}
// 		}

// 		case .Mouse_Scroll_Y: {
// 			return element_message(table.scrollbar, msg, di, dp)
// 		}

// 		case .Mouse_Move, .Update: {
// 			element_repaint(element)
// 		}

// 		case .Destroy: {
// 			delete(table.columns)
// 			delete(table.column_widths)
// 		}
// 	}

// 	return 0
// }

// table_init :: proc(
// 	parent: ^Element, 
// 	flags: Element_Flags, 
// 	columns := "",
// 	allocator := context.allocator,
// ) -> (res: ^Table) {
// 	res = element_init(Table, parent, flags, table_message, allocator)	
// 	res.scrollbar = scrollbar_init(res, {}, allocator)
// 	res.columns = strings.clone(columns)
// 	return
// }

// table_hit_test :: proc(table: ^Table, x, y: f32) -> int {
// 	x := x - table.bounds.l

// 	// x check
// 	if x < 0 || x >= rect_width(table.bounds) - SCROLLBAR_SIZE * SCALE {
// 		return - 1
// 	}

// 	y := y
// 	y -= (table.bounds.t + TABLE_HEADER * SCALE) - table.scrollbar.position

// 	// y check
// 	row_height := TABLE_ROW * SCALE
// 	if y < 0 || y >= row_height * f32(table.item_count) {
// 		return -1
// 	}

// 	return int(y / row_height)
// }

// table_header_hit_test :: proc(table: ^Table, x, y: int) -> int {
// 	if table.column_count == 0 {
// 		return -1
// 	}

// 	header := table.bounds
// 	header.b = header.t + TABLE_HEADER * SCALE
// 	header.l += TABLE_COLUMN_GAP * SCALE

// 	// iterate columns
// 	mod := table.columns
// 	index := 0
// 	for word in strings.split_iterator(&mod, "\t") {
// 		header.r = header.l + table.column_widths[index]

// 		if rect_contains(header, f32(x), f32(y)) {
// 			return index
// 		}

// 		header.l += table.column_widths[index] + TABLE_COLUMN_GAP * SCALE
// 		index += 1
// 	}

// 	return -1
// }

// table_ensure_visible :: proc(table: ^Table, index: int) -> bool {
// 	row_height := TABLE_ROW * SCALE
// 	y := f32(index) * row_height
// 	height := rect_height(table.bounds) - TABLE_HEADER * SCALE - row_height

// 	if y < 0 {
// 		table.scrollbar.position += y
// 		element_repaint(table)
// 		return true
// 	} else if y > height {
// 		table.scrollbar.position -= height - y
// 		element_repaint(table)
// 		return true
// 	} else {
// 		return false
// 	}
// }

// // calculate column widths based on each item width
// table_resize_columns :: proc(table: ^Table) {
// 	table.column_count = 0
// 	mod := table.columns
// 	for word in strings.split_iterator(&mod, "\t") {
// 		table.column_count += 1
// 	}

// 	delete(table.column_widths)
// 	table.column_widths = make([]f32, table.column_count)

// 	item := Table_Get_Item {
// 		buffer = table.buffer[:],
// 	}

// 	// retrieve longest textual width per column by iterating through all items widths
// 	mod = table.columns
// 	fcs_element(table)
// 	for word in strings.split_iterator(&mod, "\t") {
// 		longest := string_width(word)

// 		for i in 0..<table.item_count {
// 			item.index = i
// 			element_message(table, .Table_Get_Item, 0, &item)
// 			width := string_width(item.output)

// 			if width > longest {
// 				longest = width
// 			}
// 		}

// 		table.column_widths[item.column] = longest
// 		item.column += 1
// 	}
// }

//////////////////////////////////////////////
// color wheel
//////////////////////////////////////////////

// includes 2 elements
// slider with hue texture
// custom element to drag
Color_Picker :: struct {
	using element: Element,
	sv: ^Color_Picker_SV,
	hue: ^Color_Picker_HUE,
	color_mod: ^Color,
}

Color_Picker_SV :: struct {
	using element: Element,
	x, y: f32,
	output: Color,

	animating: bool,
	animating_unit: f32,
	animating_goal: f32,
}

Color_Picker_HUE :: struct {
	using element: Element,
	y: f32,

	animating: bool,
	animating_unit: f32,
	animating_goal: f32,
}

color_picker_message :: proc(element: ^Element, msg: Message, di: int, dp: rawptr) -> int {
	picker := cast(^Color_Picker) element

	SV_WIDTH :: 200
	HUE_WIDTH :: 50

	#partial switch msg {
		case .Get_Width: {
			return int((HUE_WIDTH + SV_WIDTH) * SCALE)
		}

		case .Get_Height: {
			return int(200 * SCALE)
		}

		case .Layout: {
			sv := element.children[0]
			hue := element.children[1]
		
			gap := int(10 * SCALE)
			cut := rect_margin(element.bounds, 5)
			left := rect_cut_left(&cut, int(SV_WIDTH * SCALE))
			cut.l += gap
			element_move(sv, left)
			element_move(hue, cut)
		}

		case .Paint_Recursive: {
			target := element.window.target
			// render_rect(target, element.bounds, theme.background[0], 0)
			// render_rect_outline(target, element.bounds, theme.text_default, 0, LINE_WIDTH)
		}
	}

	return 0
}

color_picker_hue_message :: proc(element: ^Element, msg: Message, di: int, dp: rawptr) -> int {
	hue := cast(^Color_Picker_HUE) element
	sv := cast(^Color_Picker_SV) element.parent.children[0]

	#partial switch msg {
		case .Paint_Recursive: {
			target := element.window.target
			render_texture_from_kind(target, .HUE, element.bounds)

			out_size := int(10 * SCALE)

			hue_out := element.bounds
			hue_out.t += int(hue.y * rect_heightf(element.bounds)) - out_size / 2
			hue_out.b = hue_out.t + out_size
			hue_out = rect_margin(hue_out, int(-hue.animating_unit * 5))

			out_color := color_hsv_to_rgb(hue.y, 1, 1)
			render_rect(target, hue_out, out_color)
			render_rect_outline(target, hue_out, theme.text_default, 0, LINE_WIDTH)
		}

		case .Get_Cursor: {
			return int(Cursor.Resize_Vertical)
		}

		// on update hovering do an animation
		case .Update: {
			switch di {
				case UPDATE_PRESSED: {
					hue.animating = true
					hue.animating_goal = 1
					element_animation_start(element)
				}

				case UPDATE_PRESSED_LEAVE: {
					hue.animating = true
					hue.animating_goal = 0
					element_animation_start(element)
				}
			}
		}

		case .Animate: {
			handled := false
			handled |= animate_to(
				&hue.animating,
				&hue.animating_unit,
				hue.animating_goal,
				1,
			)
			return int(handled)
		}
	}

	if msg == .Left_Down || (msg == .Mouse_Drag && element.window.pressed_button == MOUSE_LEFT) {
		relative_y := element.window.cursor_y - element.bounds.t
		hue.y = clamp(f32(relative_y) / rect_heightf(element.bounds), 0, 1)
		element_message(sv, .Value_Changed)
		element_repaint(element)
	}

	return 0
}

color_picker_sv_message :: proc(element: ^Element, msg: Message, di: int, dp: rawptr) -> int {
	sv := cast(^Color_Picker_SV) element
	sv_out_size := int(10 * SCALE)

	#partial switch msg {
		case .Paint_Recursive: {
			hue := cast(^Color_Picker_HUE) element.parent.children[1]
			target := element.window.target
			color := color_hsv_to_rgb(hue.y, 1, 1)
			render_texture_from_kind(target, .SV, element.bounds, color)

			sv_out := rect_wh(
				element.bounds.l + int(sv.x * rect_widthf(element.bounds)) - sv_out_size / 2, 
				element.bounds.t + int(sv.y * rect_heightf(element.bounds)) - sv_out_size / 2,
				sv_out_size,
				sv_out_size,
			)
			sv_out = rect_margin(sv_out, int(-sv.animating_unit * 5))
			color = color_to_bw(sv.output)
			render_rect(target, sv_out, sv.output)
			render_rect_outline(target, sv_out, color, 0, LINE_WIDTH)
		}

		case .Get_Cursor: {
			return int(Cursor.Crosshair)
		}

		case .Value_Changed: {
			hue := cast(^Color_Picker_HUE) element.parent.children[1]
			picker := cast(^Color_Picker) sv.parent
			sv.output = color_hsv_to_rgb(hue.y, sv.x, 1 - sv.y)

			if picker.color_mod != nil {
				picker.color_mod^ = sv.output
			}
		}

		// on update hovering do an animation
		case .Update: {
			switch di {
				case UPDATE_PRESSED: {
					sv.animating = true
					sv.animating_goal = 1
					element_animation_start(element)
				}

				case UPDATE_PRESSED_LEAVE: {
					sv.animating = true
					sv.animating_goal = 0
					element_animation_start(element)
				}
			}
		}

		case .Animate: {
			handled := false
			handled |= animate_to(
				&sv.animating,
				&sv.animating_unit,
				sv.animating_goal,
				1,
			)
			return int(handled)
		}
	}

	if msg == .Left_Down || (msg == .Mouse_Drag && element.window.pressed_button == MOUSE_LEFT) {
		relative_x := element.window.cursor_x - element.bounds.l
		relative_y := element.window.cursor_y - element.bounds.t
		sv.x = clamp(f32(relative_x) / rect_widthf(element.bounds), 0, 1)
		sv.y = clamp(f32(relative_y) / rect_heightf(element.bounds), 0, 1)
		element_message(element, .Value_Changed)
		element_repaint(element)
	}

	return 0
}

color_picker_init :: proc(
	parent: ^Element, 
	flags: Element_Flags, 
	hue: f32,
	saturation: f32,
	value: f32,
	allocator := context.allocator,
) -> (res: ^Color_Picker) {
	res = element_init(Color_Picker, parent, flags, color_picker_message, allocator)
	res.sv = element_init(Color_Picker_SV, res, flags, color_picker_sv_message, allocator)
	sv := cast(^Color_Picker_SV) res.sv
	sv.x = saturation
	sv.y = 1 - value

	res.hue = element_init(Color_Picker_HUE, res, flags, color_picker_hue_message, allocator)
	h := cast(^Color_Picker_HUE) res.hue
	h.y = hue

	return 
}

//////////////////////////////////////////////
// toggle selector
//////////////////////////////////////////////

Toggle_Selector :: struct {
	using element: Element,
	value: int,
	count: int,
	names: []string,

	// layouted cells and animation
	cells: []RectI,
	cell_gap: int,

	// animation
	cell_values: []f32,

	// callback
	changed: proc(toggle: ^Toggle_Selector),
}

toggle_selector_message :: proc(element: ^Element, msg: Message, di: int, dp: rawptr) -> int {
	toggle := cast(^Toggle_Selector) element
	assert(len(toggle.names) == toggle.count)
	POINT_SIZE :: 20
	MARGIN :: 10

	#partial switch msg {
		case .Layout: {
			point_size := int(POINT_SIZE * SCALE)
			margin_size := int(MARGIN * SCALE)
			fcs_element(element)

			// layout cells
			cut := element.bounds
			cut.l += margin_size
			cut.r -= margin_size
			for i in 0..<toggle.count {
				width := point_size + string_width(toggle.names[i])
				toggle.cells[i] = rect_cut_left(&cut, width)
			}
			toggle.cell_gap = int(rect_widthf(cut) / f32(toggle.count))

			for i in 0..<toggle.count {
				toggle.cells[i].l += i * toggle.cell_gap
				toggle.cells[i].r += i * toggle.cell_gap
			}
		}

		case .Get_Cursor: {
			return int(Cursor.Hand)
		}

		case .Paint_Recursive: {
			target := element.window.target
			hovered := element.window.hovered == element
			pressed := element.window.pressed == element

			text_color := hovered || pressed ? theme.text_default : theme.text_blank
			
			if hovered {
				render_hovered_highlight(target, element.bounds)
			}

			fcs_element(element)
			fcs_ahv()
			point_size := int(POINT_SIZE * SCALE)

			for i in 0..<toggle.count {
				cell := toggle.cells[i]

				color := theme.text_default

				if !rect_contains(cell, element.window.cursor_x, element.window.cursor_y) {
					color = theme.text_blank
				}

				fcs_color(color)
				rect := cell
				rect.r = rect.l + point_size
				rect.t = rect.t + rect_height_halfed(rect) - point_size / 2
				rect.b = rect.t + point_size
				rect = rect_margin(rect, 2)
				color_point := color_blend(theme.text_good, theme.text_default, toggle.cell_values[i], false)
				render_rect(target, rect, color_point, int(10 * SCALE))

				rect.l = cell.l + point_size
				rect.r = cell.r
				render_string_rect(target, rect, toggle.names[i])
			}
			
			render_rect_outline(target, element.bounds, text_color)
		}

		case .Get_Width: {
			sum_width: int
			fcs_element(element)
			// height := f32(element_message(element, .Get_Height))
			scaled_size := efont_size(element)

			for name in toggle.names {
				sum_width += string_width(name) + scaled_size
			}
			
			return sum_width + int(MARGIN * SCALE * 2)
		}

		case .Get_Height: {
			return efont_size(element) + int(TEXT_MARGIN_VERTICAL * SCALE)
		}

		case .Mouse_Move: {
			element_repaint(element)
		}

		case .Clicked: {
			// select and start animation transition towards
			for i in 0..<toggle.count {
				r := toggle.cells[i]
				if rect_contains(r, element.window.cursor_x, element.window.cursor_y) {
					if toggle.value != i {
						// toggle.value_old = toggle.value^
						toggle.value = i
						element_message(element, .Value_Changed)
						element_animation_start(element)
						element_repaint(element)
					}

					break
				}
			}
		}

		case .Animate: {
			handled := false

			for i in 0..<toggle.count {
				state := true
				handled |= animate_to(
					&state,
					&toggle.cell_values[i],
					f32(i == toggle.value ? 1 : 0),
					2,
					0.01,
				)
			}

			return int(handled)
		}

		case .Destroy: {
			delete(toggle.cells)
			delete(toggle.cell_values)
		}

		case .Value_Changed: {
			if toggle.changed != nil {
				toggle->changed()
			}
		}
	}

	return 0
}

toggle_selector_init :: proc(
	parent: ^Element,
	flags: Element_Flags,
	value: int,
	count: int,
	names: []string,
	allocator := context.allocator,
) -> (res: ^Toggle_Selector) {
	res = element_init(Toggle_Selector, parent, flags, toggle_selector_message, allocator)
	res.value = value
	res.count = count
	res.names = names
	res.cell_values = make([]f32, count)
	res.cells = make([]RectI, count)
	res.cell_values[value] = 1
	return 
}

// NOTE without animation
toggle_selector_set :: proc(
	toggle: ^Toggle_Selector,
	value: int,
) {
	toggle.value = value
	for i in 0..<toggle.count {
		if i == value {
			toggle.cell_values[i] = 1
		} else {
			toggle.cell_values[i] = 0
		}
	}
}

//////////////////////////////////////////////
// split pane
//////////////////////////////////////////////

// TODO just rework this to be seperate instead of mixing all shit
// v / h split 2 panels with a controlable weight
Split_Pane :: struct {
	using element: Element,
	pixel_based: bool, // wether weight works in pixel or unit space

	weight: f32,
	weight_origin: f32,
	weight_lowest: f32,
	weight_reset: f32,
}

split_pane_message :: proc(element: ^Element, msg: Message, di: int, dp: rawptr) -> int {
	split := cast(^Split_Pane) element
	vertical := .Split_Pane_Vertical in element.flags
	hideable := .Split_Pane_Hidable in split.flags
	reversed := .Split_Pane_Reversed in split.flags

	#partial switch msg {
		case .Layout: {
			splitter := element.children[0]
			left := element.children[1]
			right := element.children[2]

			// reset to hideable 
			if hideable {
				if .Hide in left.flags {
					if split.weight_reset == -1 {
						split.weight_reset = split.weight
					}

					// set to reversed location
					if reversed {
						bound := vertical ? split.bounds.b : split.bounds.r
						split.weight = f32(bound) - SPLITTER_SIZE * SCALE
					} else {
						split.weight = 0
					}
				} else {
					if split.weight_reset != -1 {
						split.weight = split.weight_reset
						split.weight_reset = -1
					}
				}
			}

			// swap elements to deal with sizing
			if reversed {
				left, right = right, left
			}

			splitter_size := math.round(SPLITTER_SIZE * SCALE)
			space := rect_opt_vf(element.bounds, vertical) - splitter_size
			left_size, right_size: f32
			b := element.bounds
			
			if split.pixel_based {
				// weight is the value to split at
				left_size = split.weight * SCALE
				right_size = space - split.weight * SCALE
			} else {
				// unit weight based
				left_size = space * split.weight
				right_size = space - left_size
			}
			
			if vertical {
				element_move(left, { b.l, b.r, b.t, b.t + int(left_size) })
				element_move(splitter, { b.l, b.r, b.t + int(left_size), b.t + int(left_size + splitter_size) })
				element_move(right, { b.l, b.r, b.b - int(right_size), b.b })
			} else {
				element_move(left, { b.l, b.l + int(left_size), b.t, b.b })
				element_move(splitter, { b.l + int(left_size), b.l + int(left_size) + int(splitter_size), b.t, b.b })
				element_move(right, { b.r - int(right_size), b.r, b.t, b.b })
			}
		}
	}

	return 0 
}

splitter_message :: proc(element: ^Element, msg: Message, di: int, dp: rawptr) -> int {
	split := cast(^Split_Pane) element.parent
	vertical := .Split_Pane_Vertical in split.flags
	hideable := .Split_Pane_Hidable in split.flags
	reversed := .Split_Pane_Reversed in split.flags

	#partial switch msg {
		case .Paint_Recursive: {
			target := element.window.target
			render_rect(target, element.bounds, theme.text_default)
		}

		case .Get_Cursor: {
			return int(vertical ? Cursor.Resize_Vertical : Cursor.Resize_Horizontal)
		}

		case .Left_Down: {
			click_count := di

			// double click reset to origin
			if click_count != 0 {
				if split.weight != split.weight_origin {
					split.weight = split.weight_origin
					element_repaint(split)
				}
			}
		}

		case .Mouse_Drag: {
			cursor := f32(vertical ? element.window.cursor_y : element.window.cursor_x)
			splitter_size := math.round(SPLITTER_SIZE * SCALE)
			space := rect_opt_vf(split.bounds, vertical) - splitter_size
			old_weight := split.weight
			
			if split.pixel_based {
				unit := (cursor - splitter_size / 2 - f32(vertical ? split.bounds.t : split.bounds.l))
				split.weight = unit / SCALE
			} else {
				split.weight = (cursor - splitter_size / 2 - f32(vertical ? split.bounds.t : split.bounds.l)) / space
			}

			if !hideable {
				// bound clamping
				if split.pixel_based {
					low := reversed ? 0 : split.weight_lowest
					high := reversed ? space - split.weight_lowest : space

					// limit to lowest
					if split.weight < low {
						split.weight = low
					}

					// limit to highest
					if split.weight > high {
						split.weight = high
					}
				} else {
					// care about reversing with lowest weight
					low := reversed ? 0 : split.weight_lowest
					high := reversed ? 1 - split.weight_lowest : 1
					
					if split.weight < low {
						split.weight = low
					}

					if split.weight > high {
						split.weight = high
					}
				}
			} else {
				if split.weight_lowest != -1 {
					left := split.children[1]

					if split.pixel_based {
						w := reversed ? space - split.weight : split.weight
						low := split.weight_lowest

						if split.weight > low / 2 {
							element_hide(left, false)
						}
						
						// keep below half lowest, or hide away
						if w < low {
							if w < low / 2 {
								if split.weight_reset == -1 {
									split.weight_reset = split.weight_lowest
								}

								split.weight = reversed ? space : 0
								element_hide(left, true)
							} else {
								// split.weight = reversed ? low : split.weight_lowest
								split.weight = reversed ? space - split.weight_lowest : split.weight_lowest
							}
						}
					} else {
						w := reversed ? 1 - split.weight : split.weight
						low := reversed ? 1 - split.weight_lowest : split.weight_lowest

						if w > low / 2 {
							element_hide(left, false)
						}
						
						// keep below half lowest, or hide away
						if w < low {
							if w < low / 2 {
								if split.weight_reset == -1 {
									split.weight_reset = split.weight_lowest
								}

								split.weight = reversed ? 1 : 0
								element_hide(left, true)
							} else {
								split.weight = split.weight_lowest
							}
						}
					}
				}
			}

			// TODO NESTING
			// if (splitPane->e.children[2]->messageClass == _UISplitPaneMessage 
			// 		&& (splitPane->e.children[2]->flags & UI_SPLIT_PANE_VERTICAL) == (splitPane->e.flags & UI_SPLIT_PANE_VERTICAL)) {
			// 	UISplitPane *subSplitPane = (UISplitPane *) splitPane->e.children[2];
			// 	subSplitPane->weight = (splitPane->weight - oldWeight - subSplitPane->weight + oldWeight * subSplitPane->weight) / (-1 + splitPane->weight);
			// 	if (subSplitPane->weight < 0.05f) subSplitPane->weight = 0.05f;
			// 	if (subSplitPane->weight > 0.95f) subSplitPane->weight = 0.95f;
			// }

			element_repaint(split)
		}
	}

	return 0
}

split_pane_init :: proc(
	parent: ^Element, 
	flags: Element_Flags, 
	weight: f32,
	weight_lowest: f32 = -1,
	allocator := context.allocator,
) -> (res: ^Split_Pane) {
	res = element_init(Split_Pane, parent, flags, split_pane_message, allocator)
	res.weight = weight
	res.weight_origin = weight
	res.weight_lowest = weight_lowest
	res.weight_reset = -1
	element_init(Element, res, {}, splitter_message, allocator)
	return
}

//////////////////////////////////////////////
// enum based panel
//////////////////////////////////////////////

// only renders a specific panel
// NOTE: assumes mode == 0 is None state
Enum_Panel :: struct {
	using element: Element,
	mode: ^int,
	count: int,
}

// NOTE only layouts the chosen element
enum_panel_message :: proc(element: ^Element, msg: Message, di: int, dp: rawptr) -> int {
	panel := cast(^Enum_Panel) element 
	assert(panel.mode != nil)

	#partial switch msg {
		case .Layout: {
			chosen := element.children[panel.mode^]
		
			for child in element.children {
				child.clip = {}
			}

			element_move(chosen, element.bounds)
		}

		case .Update: {
			chosen := element.children[panel.mode^]
			element_message(chosen, msg, di, dp)
		}

		case .Find_By_Point_Recursive: {
			chosen := element.children[panel.mode^]
			point := cast(^Find_By_Point) dp
			element_find_by_point_custom(chosen, point)	
			return 0
		}

		case .Paint_Recursive: {
			chosen := element.children[panel.mode^]
			target := element.window.target
			render_element_clipped(target, chosen)
			return 1
		}
	}

	return 0
}

enum_panel_init :: proc(
	parent: ^Element, 
	flags: Element_Flags,
	mode: ^int,
	count: int,
	allocator := context.allocator,
) -> (res: ^Enum_Panel) {
	res = element_init(Enum_Panel, parent, flags, enum_panel_message, allocator)
	res.mode = mode
	res.count = count
	return
}

//////////////////////////////////////////////
// Linear Gauge
//////////////////////////////////////////////

Linear_Gauge :: struct {
	using element: Element,
	position: f32,
	builder: strings.Builder,
	text_below: string, // below 1
	text_above: string, // above 1
}

linear_gauge_message :: proc(element: ^Element, msg: Message, di: int, dp: rawptr) -> int {
	gauge := cast(^Linear_Gauge) element

	gauge_text :: proc(gauge: ^Linear_Gauge) -> string {
		text := gauge.position >= 1.0 ? gauge.text_above : gauge.text_below
		strings.builder_reset(&gauge.builder)
		return fmt.sbprintf(&gauge.builder, "%s: %d%%", text, int(gauge.position * 100))
	}

	#partial switch msg {
		case .Paint_Recursive: {
			target := element.window.target
			text_color := theme.background[1]

			render_rect(target, element.bounds, theme.text_bad, ROUNDNESS)
			slide := element.bounds
			// slide.t = slide.b - math.round(5 * SCALE)
			// slide.b = slide.t + math.round(3 * SCALE)
			slide.r = slide.l + int(min(gauge.position, 1) * rect_widthf(slide))
			render_rect(target, slide, theme.text_good, ROUNDNESS)
			// render_rect_outline(target, element.bounds, text_color)

			output := gauge_text(gauge)
			fcs_element(element)
			fcs_ahv()
			fcs_color(text_color)
			render_string_rect(target, element.bounds, output)
		}

		case .Get_Width: {
			output := gauge_text(gauge)
			fcs_element(element)
			width := max(int(150 * SCALE), string_width(output) + int(TEXT_MARGIN_HORIZONTAL * SCALE))
			return int(width)
		}

		case .Get_Height: {
			return efont_size(element) + int(TEXT_MARGIN_VERTICAL * SCALE)
		}
	}

	return 0
}

linear_gauge_init :: proc(
	parent: ^Element,
	flags: Element_Flags,
	position: f32,
	text_below: string,
	text_above: string,
	allocator := context.allocator,
) -> (res: ^Linear_Gauge) {
	res = element_init(Linear_Gauge, parent, flags, linear_gauge_message, allocator)
	res.text_below = text_below
	res.text_above = text_above
	res.position = position
	return 
}

//////////////////////////////////////////////
// Radial Gauge
//////////////////////////////////////////////

// Radial_Gauge :: struct {
// 	using element: Element,
// 	position: f32,
// 	text: string,
// }

// radial_gauge_message :: proc(element: ^Element, msg: Message, di: int, dp: rawptr) -> int {
// 	gauge := cast(^Radial_Gauge) element

// 	#partial switch msg {
// 		case .Paint_Recursive: {
// 			target := element.window.target
// 			text_color := theme.text_default

// 			render_arc(target, element.bounds, BLACK, 13 * SCALE, 3.14, 0)
// 			render_arc(target, rect_margin(element.bounds, 2 * SCALE), GREEN, 10 * SCALE, gauge.position * math.PI, 0)

// 			text := fmt.tprintf("%s: %d%%", gauge.text, int(gauge.position * 100))

// 			fcs_element(element)
// 			fcs_ahv()
// 			fcs_color(text_color)
// 			render_string_rect(target, element.bounds, text)
// 		}

// 		case .Get_Width: {
// 			return int(200 * SCALE)
// 		}

// 		case .Get_Height: {
// 			return int(200 * SCALE)
// 		}

// 	}

// 	return 0
// }

// radial_gauge_init :: proc(
// 	parent: ^Element,
// 	flags: Element_Flags,
// 	position: f32,
// 	text: string,
// 	allocator := context.allocator,
// ) -> (res: ^Radial_Gauge) {
// 	res = element_init(Radial_Gauge, parent, flags, radial_gauge_message, allocator)
// 	res.text = text
// 	res.position = position
// 	res.font_options = &font_options_bold
// 	return 
// }

//////////////////////////////////////////////
// image display
//////////////////////////////////////////////

Image_Aspect :: enum {
	Height,
	Width,
	Mix,
}

Image_Display :: struct {
	using element: Element,
	img: ^Stored_Image,
	aspect: Image_Aspect,
}

image_display_message :: proc(element: ^Element, msg: Message, di: int, dp: rawptr) -> int {
	display := cast(^Image_Display) element
	has_content := image_display_has_content_now(display)

	#partial switch msg {
		case .Paint_Recursive: {
			target := element.window.target

			if has_content {
				rect := element.bounds
				
				img_width := f32(element_message(element, .Get_Width))
				img_height := f32(element_message(element, .Get_Height))

				ratio_width := img_width / rect_widthf(rect)
				ratio_height := img_height / rect_heightf(rect)
				
				ratio_aspect: f32
				switch display.aspect {
					case .Height: ratio_aspect = ratio_height
					case .Width: ratio_aspect = ratio_width
					case .Mix: ratio_aspect = ratio_width > 1 ? ratio_width : ratio_height > 1 ? ratio_height : 1
				}

				wanted_width := img_width / ratio_aspect
				wanted_height := img_height / ratio_aspect

				offset_x := rect_widthf_halfed(rect) - wanted_width / 2
				offset_y := rect_heightf_halfed(rect) - wanted_height / 2

				rect.l = rect.l + int(offset_x)
				rect.r = rect.l + int(wanted_width)
				rect.t = rect.t + int(offset_y)
				rect.b = rect.t + int(wanted_height)

				render_texture_from_handle(target, display.img.handle, rect, WHITE)
			} else {
				render_rect(target, element.bounds, theme.background[0])
			}
		}

		case .Get_Width: {
			return has_content ? display.img.width : 100
		}

		case .Get_Height: {
			return has_content ? display.img.height : 100
		}
	}

	return 0
}

image_display_init :: proc(
	parent: ^Element,
	flags: Element_Flags,
	img: ^Stored_Image,
	message_user: Message_Proc = nil,
	allocator := context.allocator,
) -> (res: ^Image_Display) {
	res = element_init(Image_Display, parent, flags, image_display_message, allocator)
	res.img = img
	res.message_user = message_user
	res.aspect = .Height
	return
}

image_display_has_path :: #force_inline proc(display: ^Image_Display) -> bool {
	return display != nil && display.img != nil && display.img.path_length != 0
}

image_display_has_content_soon :: #force_inline proc(display: ^Image_Display) -> bool {
	return display != nil && display.img != nil
}

image_display_has_content_now :: #force_inline proc(display: ^Image_Display) -> bool {
	return display != nil && display.img != nil && display.img.loaded && display.img.handle_set
}

//////////////////////////////////////////////
// Toggle Panel
// hides its children and shows a preview if it has content
//////////////////////////////////////////////

Toggle_Panel :: struct {
	using element: Element,
	panel: ^Panel,
	builder: strings.Builder, // label
}

toggle_panel_message :: proc(element: ^Element, msg: Message, di: int, dp: rawptr) -> int {
	toggle := cast(^Toggle_Panel) element
	MARGIN :: 0

	#partial switch msg {
		case .Paint_Recursive: {
			target := element.window.target

			bounds := element.bounds

			text_height := efont_size(element) + int(TEXT_MARGIN_VERTICAL * SCALE)
			render_rect(target, bounds, theme.background[1], ROUNDNESS)

			top := rect_cut_top(&bounds, text_height)
			fcs_ahv(.Left, .Middle)
			fcs_color(theme.text_default)
			fcs_icon(SCALE)

			hovered := element.window.hovered == element
			pressed := element.window.pressed == element
			if hovered {
				// render_hovered_highlight(target, top)
			}

			top.l += int(MARGIN * SCALE)
			icon: Icon = (.Hide in toggle.panel.flags) ? .Simple_Right : .Simple_Down
			top.l += int(render_icon_rect(target, top, icon)) + int(5 * SCALE)
			
			fcs_element(toggle)
			text := strings.to_string(toggle.builder)
			render_string_rect(target, top, text)
		}

		case .Layout: {
			bounds := element.bounds
			text_height := efont_size(element) + int(TEXT_MARGIN_VERTICAL * SCALE)
			bounds.t += text_height
			element_move(toggle.panel, rect_margin(bounds, int(MARGIN * SCALE)))
		}

		case .Update: {
			element_repaint(element)
		}

		case .Destroy: {
			delete(toggle.builder.buf)
		}

		case .Clicked: {
			element_hide_toggle(toggle.panel)
		}

		case .Get_Cursor: {
			return int(Cursor.Hand)
		}

		case .Get_Height: {
			height := efont_size(element) + int(TEXT_MARGIN_VERTICAL * SCALE)
			
			if .Hide not_in toggle.panel.flags {
				height += element_message(toggle.panel, .Get_Height) + MARGIN * 2
			}

			return height
		}

		case .Get_Width: {
			fcs_element(element)
			text := strings.to_string(toggle.builder)
			width := max(int(50 * SCALE), string_width(text) + int(TEXT_MARGIN_HORIZONTAL * SCALE))
			return int(width)
		}
	}

	return 0
}

toggle_panel_init :: proc(
	parent: ^Element, 
	flags: Element_Flags, 
	panel_flags: Element_Flags, 
	text: string,
	hide: bool = false,
	message_user: Message_Proc = nil,
	allocator := context.allocator,
) -> (res: ^Toggle_Panel) {
	res = element_init(Toggle_Panel, parent, flags, toggle_panel_message, allocator)
	res.builder = strings.builder_make(0, 32)
	res.data = res
	res.panel = panel_init(res, panel_flags)
	strings.write_string(&res.builder, text)
	res.message_user = message_user
	element_hide(res.panel, hide)
	return
}

//////////////////////////////////////////////
// menu bar and sub elements
//////////////////////////////////////////////

// layouts sub buttons in the expected way
Menu_Bar :: struct {
	using element: Element,
	active: bool, // active to enable hover switching of floaty menus
}

menu_bar_init :: proc(parent: ^Element) -> (res: ^Menu_Bar) {
	res = element_init(Menu_Bar, parent, {}, menu_bar_message, context.allocator)
	return
}

// recreate menu with set properties
menu_bar_push :: proc(window: ^Window, menu_info: int) -> (res: ^Panel_Floaty) {
	res = menu_init_or_replace_new(window, { .Panel_Expand }, menu_info)
	if res != nil {
		res.panel.margin = 0
		res.panel.rounded = false
		res.panel.outline = true
		res.panel.background_index = 1
	}
	return 
}

// start showing menu but underneath the element
menu_bar_show :: proc(menu: ^Panel_Floaty, element: ^Element) {
	menu_show(menu)
	menu.x = element.bounds.l
	menu.y = element.bounds.b
}

menu_bar_message :: proc(element: ^Element, msg: Message, di: int, dp: rawptr) -> int {
	bar := cast(^Menu_Bar) element

	#partial switch msg {
		case .Paint_Recursive: {
			target := element.window.target
			render_rect(target, element.bounds, theme.background[2])
		}

		case .Layout: {
			bounds := element.bounds

			// layout elements left to right
			for c in element.children {
				w := element_message(c, .Get_Width)
				cut := rect_cut_left(&bounds, w)
				element_move(c, cut)
			}

			if element.window.menu == nil {
				bar.active = false
			}
		}
	}

	return 0
}

// single textual field of a menu bar
Menu_Bar_Field :: struct {
	using element: Element,
	text: string,
	menu_info: int, // used to change between submenus and stop recreating
	invoke: proc(panel: ^Panel), // how the menu is created internally
}

menu_bar_field_init :: proc(
	parent: ^Element, 
	text: string,
	menu_info: int,
) -> (res: ^Menu_Bar_Field) {
	res = element_init(Menu_Bar_Field, parent, {}, menu_bar_field_message, context.allocator)
	res.text = text
	res.menu_info = menu_info
	return
}

// only create menu when invoke is valid
menu_bar_field_invoke :: proc(field: ^Menu_Bar_Field) {
	if field.invoke != nil {
		if menu := menu_bar_push(field.window, field.menu_info); menu != nil {
			field.invoke(menu.panel)
			menu_bar_show(menu, field)
		}
	}
}

menu_bar_field_message :: proc(element: ^Element, msg: Message, di: int, dp: rawptr) -> int {
	field := cast(^Menu_Bar_Field) element

	#partial switch msg {
		case .Get_Width: {
			fcs_element(element)
			width := string_width(field.text) + int(TEXT_MARGIN_HORIZONTAL * SCALE)
			return int(width)
		}

		case .Get_Height: {
			return efont_size(element) + int(TEXT_MARGIN_VERTICAL * SCALE)
		}

		case .Update: {
			bar := cast(^Menu_Bar) element.parent

			if bar.active && di == UPDATE_HOVERED {
				menu_bar_field_invoke(field)
			}

			element_repaint(element)
		}

		case .Get_Cursor: {
			return int(Cursor.Hand)
		}

		case .Clicked: {
			bar := cast(^Menu_Bar) element.parent
			bar.active = true
			
			if field.invoke != nil {
				menu_bar_field_invoke(field)
			}
		}

		case .Paint_Recursive: {
			target := element.window.target
			pressed := element.window.pressed == element
			hovered := element.window.hovered == element
			text_color := hovered || pressed ? theme.text_default : theme.text_blank

			if hovered || pressed || element.window.menu_info == field.menu_info {
				render_rect(target, element.bounds, { 0, 0, 0, 100 })
			}

			fcs_element(field)
			fcs_ahv()
			fcs_color(theme.text_default)
			render_string_rect(target, element.bounds, field.text)
		}
	}

	return 0
}

// simple top split at some px
// optional bottom split for statusbar
Menu_Split :: struct {
	using element: Element,
}

menu_split_init :: proc(parent: ^Element) -> (res: ^Menu_Split) {
	res = element_init(Menu_Split, parent, {}, menu_split_message, context.allocator)
	return
}

menu_split_message :: proc(element: ^Element, msg: Message, di: int, dp: rawptr) -> int {
	split := cast(^Menu_Split) element

	#partial switch msg {
		case .Layout: {
			if len(element.children) > 1 {
				a := element.children[0]
				b := element.children[1]
				bounds := element.bounds

				// top bar
				if .Hide not_in a.flags {
					size := int(DEFAULT_FONT_SIZE * SCALE + TEXT_MARGIN_VERTICAL * SCALE)
					element_move(a, rect_cut_top(&bounds, size))
				}

				// opt bottom bar
				if len(element.children) == 3 {
					c := element.children[2]

					if .Hide not_in c.flags {
						size := int(DEFAULT_FONT_SIZE * SCALE + TEXT_MARGIN_VERTICAL * SCALE * 2)
						element_move(c, rect_cut_bottom(&bounds, size))
					}
				}

				// middle section
				element_move(b, bounds)
			}
		}
	}

	return 0
}

// single line commonly used with optional icon, text + key command or custom call
Menu_Bar_Line :: struct {
	using element: Element,
	icon: Icon,
	builder: strings.Builder,
	
	command: string,
	command_du: u32,

	command_custom: proc(),
}

// spacer for menus
mbs :: proc(parent: ^Element) {
	spacer_init(parent, {}, 10, 10, .Thin)
}

// custom menu bar line
mbc :: proc(
	parent: ^Element,
	text: string,
	command_custom: proc(),
	icon: Icon = .None,
) -> (res: ^Menu_Bar_Line) {
	res = element_init(Menu_Bar_Line, parent, {}, menu_bar_line_message, context.allocator)
	res.builder = strings.builder_make(0, len(text))
	strings.write_string(&res.builder, text)
	res.command_custom = command_custom
	res.icon = icon
	return
}

mbl :: menu_bar_line_init
menu_bar_line_init :: proc(
	parent: ^Element,
	text: string,
	command: string = "",
	command_du: u32 = COMBO_EMPTY,
	icon: Icon = .None,
) -> (res: ^Menu_Bar_Line) {
	res = element_init(Menu_Bar_Line, parent, {}, menu_bar_line_message, context.allocator)
	res.builder = strings.builder_make(0, len(text))
	strings.write_string(&res.builder, text)
	res.command = command
	res.command_du = command_du
	res.icon = icon
	return
}

menu_bar_line_combo :: proc(line: ^Menu_Bar_Line) -> (
	node: ^Combo_Node,
	combo_text: string,
) {
	if line.command != "" {
		node = keymap_command_find_combo(
			&app.window_main.keymap_custom, 
			line.command,
			line.command_du,
		)

		if node != nil {
			combo_text = strings.string_from_ptr(&node.combo[0], int(node.combo_index))
		}
	}

	return
}

menu_bar_line_message :: proc(element: ^Element, msg: Message, di: int, dp: rawptr) -> int {
	line := cast(^Menu_Bar_Line) element
	FIXED_ICON_WIDTH :: 30
	FIXED_COMBO_SPACE :: 30

	#partial switch msg {
		case .Paint_Recursive: {
			target := element.window.target
			bounds := element.bounds
			pressed := element.window.pressed == element
			hovered := element.window.hovered == element
			text_color := hovered || pressed ? theme.text_default : theme.text_blank

			if hovered || pressed {
				render_rect(target, element.bounds, { 0, 0, 0, 100 })
			}

			icon_width := int(FIXED_ICON_WIDTH * SCALE)
			icon_rect := rect_cut_left(&bounds, icon_width)
			if line.icon != .None {
				fcs_icon(SCALE)
				fcs_ahv()
				fcs_color(text_color)
				render_icon_rect(target, icon_rect, line.icon)
			}

			fcs_element(element)
			fcs_color(text_color)

			if combo, c1 := menu_bar_line_combo(line); combo != nil {
				fcs_ahv(.Right, .Middle)
				render_string_rect(target, bounds, c1)
			}

			fcs_ahv(.Left, .Middle)
			text := strings.to_string(line.builder)
			render_string_rect(target, bounds, text)
		}	

		case .Update: {
			element_repaint(element)
		}

		case .Get_Width: {
			line_width := int(FIXED_ICON_WIDTH * SCALE)

			fcs_element(element)
			line_width += string_width(strings.to_string(line.builder))

			if combo, c1 := menu_bar_line_combo(line); combo != nil {
				line_width += string_width(c1) + int(FIXED_COMBO_SPACE * SCALE)
			}

			return max(int(50 * SCALE), line_width + 10)
		}

		case .Clicked: {
			if line.command_custom != nil {
				line.command_custom()
			} else {
				if cmd, ok := app.window_main.keymap_custom.commands[line.command]; ok {
					cmd(line.command_du)
				}
			}

			menu_close(app.window_main)
		}

		case .Get_Height: {
			return efont_size(element) + int(TEXT_MARGIN_VERTICAL * SCALE)
		}

		case .Destroy: {
			delete(line.builder.buf)
		}
	}

	return 0
}


//////////////////////////////////////////////
// static grid
//////////////////////////////////////////////

// layouts children in a grid, where 
Static_Grid :: struct {
	using element: Element,
	cell_sizes: []int,
	cell_height: int,
	hide_cells: ^bool,
}

static_grid_init :: proc(
	parent: ^Element,
	flags: Element_Flags,
	cell_sizes: []int,
	cell_height: int,
) -> (res: ^Static_Grid) {
	res = element_init(Static_Grid, parent, flags, static_grid_message, context.allocator)
	assert(len(cell_sizes) > 1)
	res.cell_sizes = slice.clone(cell_sizes)
	res.cell_height = cell_height
	return
}

static_grid_message :: proc(element: ^Element, msg: Message, di: int, dp: rawptr) -> int {
	sg := cast(^Static_Grid) element

	#partial switch msg {
		case .Layout: {
			total := element.bounds
			height := int(f32(sg.cell_height) * SCALE)

			if sg.hide_cells != nil && sg.hide_cells^ {
				assert(len(element.children) > 0)
				// layout only top thing
				element_move(element.children[0], total)
			} else {
				// layout elements
				for child, i in element.children {
					h := element_message(child, .Get_Height) 
					if h == 0 {
						h = height
					}
					element_move(child, rect_cut_top(&total, h))
				}
			}
		}

		case .Find_By_Point_Recursive: {
			// only interact with the top cell
			if sg.hide_cells != nil && sg.hide_cells^ {
				assert(len(element.children) > 0)
				point := cast(^Find_By_Point) dp
				chosen := element.children[0]
				return element_find_by_point_custom(chosen, point)
				// return 1
			} 
		}

		case .Paint_Recursive: {
			// only draw the top cell
			if sg.hide_cells != nil && sg.hide_cells^ {
				assert(len(element.children) > 0)
				element_message(element.children[0], msg, di, dp)
				return 1
			} 
		}

		case .Get_Width: {
			sum: int

			for i in 0..<len(sg.cell_sizes) {
				sum += int(f32(sg.cell_sizes[i]) * SCALE)
			}

			return sum
		}

		case .Get_Height: {
			sum: int

			if sg.hide_cells != nil && sg.hide_cells^ {
				height := int(f32(sg.cell_height) * SCALE)
				sum = height
			} else {
				height := int(f32(sg.cell_height) * SCALE)

				for child, i in element.children {
					h := element_message(child, .Get_Height) 
					if h == 0 {
						h = height
					}
					sum += h
				}
			}

			return sum
		}

		case .Destroy: {
			delete(sg.cell_sizes)
		}
	}

	return 0
}

static_grid_line_count :: proc(sg: ^Static_Grid) -> int {
	return len(sg.children)
}

// simple line with internal layout based on parent
Static_Line :: struct {
	using element: Element,
	cell_sizes: ^[]int,
	index: int,
}

static_line_init :: proc(
	parent: ^Element,
	cell_sizes: ^[]int,
	index: int = -1,
) -> (res: ^Static_Line) {
	res = element_init(Static_Line, parent, {}, static_line_message, context.allocator)
	res.cell_sizes = cell_sizes
	res.index = index
	return
}

static_line_message :: proc(element: ^Element, msg: Message, di: int, dp: rawptr) -> int {
	sl := cast(^Static_Line) element
	
	#partial switch msg {
		case .Layout: {
			assert(len(sl.cell_sizes) == len(element.children))
			padding := rect_xxyy(0, int(SCALE * 2))
			bounds := rect_padding(element.bounds, padding) 

			for child, i in element.children {
				size := int(f32(sl.cell_sizes[i]) * SCALE)
				rect := rect_cut_left(&bounds, size)
				element_move(child, rect)
			}
		}

		case .Clicked: {
			if sl.index != -1 {
				theme_editor.line_selected = sl.index
			}
		}

		// case .Get_Cursor: {
		// 	return int(Cursor.Hand)
		// }

		case .Paint_Recursive: {
			target := element.window.target
			hovered := element.window.hovered
			
			if 
				sl.index > 0 && 
				hovered != nil && 
				(hovered == element || hovered.parent == element) {
				render_hovered_highlight(target, element.bounds)
			}
		}

		case .Update: {
			element_repaint(element)
		}
	}

	return 0
}

Button_Fold :: struct {
	using element: Element,
	state: bool,
	builder: strings.Builder,
}

button_fold_init :: proc(
	parent: ^Element, 
	flags: Element_Flags, 
	name: string,
	state: bool,
) -> (res: ^Button_Fold) {
	res = element_init(Button_Fold, parent, flags, button_fold_message, context.allocator)
	res.state = state
	res.builder = strings.builder_make(0, 32, context.allocator)
	strings.write_string(&res.builder, name)
	return
}

button_fold_message :: proc(element: ^Element, msg: Message, di: int, dp: rawptr) -> int {
	button := cast(^Button_Fold) element

	#partial switch msg {
		case .Paint_Recursive: {
			target := element.window.target
			pressed := element.window.pressed == element
			hovered := element.window.hovered == element
			text_color := hovered || pressed ? theme.text_default : theme.text_blank

			if hovered || pressed {
				render_rect_outline(target, element.bounds, text_color)
				render_hovered_highlight(target, element.bounds)
			}

			fcs_ahv()
			fcs_color(text_color)
			fcs_icon(SCALE)
			icon: Icon = button.state ? .Simple_Right : .Simple_Down
			size := int(DEFAULT_ICON_SIZE * SCALE)
			bounds := element.bounds
			bounds.l += TEXT_MARGIN_HORIZONTAL / 2
			bounds.r = bounds.l + size
			render_icon_rect(target, bounds, icon)

			bounds.l = bounds.r + TEXT_MARGIN_HORIZONTAL
			fcs_ahv(.Left, .Middle)
			fcs_element(element)
			text := strings.to_string(button.builder)
			render_string_rect(target, bounds, text)
		}

		case .Update: {
			element_repaint(element)
		}

		case .Clicked: {
			button.state = !button.state
			element_repaint(element)
		}

		case .Get_Cursor: {
			return int(Cursor.Hand)
		}

		case .Destroy: {
			delete(button.builder.buf)
		}
	}

	return 0
}