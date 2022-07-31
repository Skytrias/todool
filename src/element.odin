package src

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
UPDATE_PRESSED :: 2
UPDATE_FOCUSED :: 3

SCROLLBAR_SIZE :: 15
TEXT_MARGIN_VERTICAL :: 10
TEXT_MARGIN_HORIZONTAL :: 10
DEFAULT_FONT_SIZE :: 20

Color :: [4]u8
RED :: Color { 255, 0, 0, 255 }
GREEN :: Color { 0, 255, 0, 255 }
BLUE :: Color { 0, 0, 255, 255 }
BLACK :: Color { 0, 0, 0, 255 }
WHITE :: Color { 255, 255, 255, 255 }
TRANSPARENT :: Color { }

Style :: struct {
	icon_size: f32,
}
style := Style {
	icon_size = 18,
}

Message :: enum {
	Invalid,
	Update,
	Paint_Recursive,
	Layout,
	Deallocate_Recursive,
	Destroy,
	Destroy_Child_Finished,
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
	Scrolled, // wether the element has scrolled

	Key_Combination, // dp = ^string, return 1 if handled
	Unicode_Insertion, // dp = ^rune, return 1 if handled

	Find_By_Point_Recursive, // dp = Find_By_Point struct
	Value_Changed, // whenever an element changes internal value

	// element specific
	Box_Set_Caret, // di = const start / end, dp = ^int index to set
	Box_Text_Color,
	Table_Get_Item, // dp = Table_Get_Item
	Reformat,
	Button_Highlight, // di = 1 use, dp = optional color
	Panel_Color,

	// windowing
	Window_Close,
}

Find_By_Point :: struct {
	x, y: f32,
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
	Layout_Ignore, // non client elements

	// cut direction
	CL, // Cut Left
	CR, // Cut Right
	CT, // Cut Top
	CB, // Cut Bottom
	CF, // Cut fill can be additional to fill region or panel

	VF, // Vertical Fill
	HF, // Horizontal Fill
	HP, // Horizontal Panel

	Panel_Tab_Movement,
	Tab_Stop,

	// element specific flags
	Label_Center,
	Box_Can_Focus,

	Panel_Panable,
	Panel_Scrollable,
	Panel_Floaty,
	Panel_Floaty_Center_X,
	Panel_Floaty_Center_Y,
	Panel_Default_Background,

	Scrollbar_Horizontal,
}
Element_Flags :: bit_set[Element_Flag]

Element :: struct {
	flags: Element_Flags,
	parent: ^Element,
	children: [dynamic]^Element,
	window: ^Window, // root hierarchy

	bounds, clip: Rect,

	message_class: Message_Proc,
	message_user: Message_Proc,

	// z index, children will be drawn in different order
	z_index: int, 
	font_options: ^Font_Options, // biggy
	hover_info: string,

	// optional data that can be set andd used
	data: rawptr,
}

// TODO optimize this
cut_flag_from_flags :: proc(flags: Element_Flags) -> (res: Element_Flag) {
	if .CL in flags {
		res = .CL
	} else if .CR in flags {
		res = .CR
	} else if .CT in flags {
		res = .CT
	} else if .CB in flags {
		res = .CB
	} else if .CF in flags {
		res = .CF
	} 

	return
}

// TODO optimize this
rect_cut_from_flag :: proc(flag: Element_Flag, rect: ^Rect, w, h: f32) -> (res: Rect) {
	#partial switch flag {
		case .CL: res = rect_cut_left_hard(rect, w)
		case .CR: res = rect_cut_right_hard(rect, w)
		case .CT: res = rect_cut_top_hard(rect, h)
		case .CB: res = rect_cut_bottom_hard(rect, h)
		case .CF: {
			res = rect^
			rect^ = {}
		}
		case: {
			log.panic("no right cut flag inserted!", flag)
		}
	}

	return
}

// toggle hide flag
element_hide_toggle :: proc(element: ^Element) {
	element.flags ~= { .Hide }
}

// set hide flag
element_hide :: proc(element: ^Element, state: bool) {
	if state {
		incl(&element.flags, Element_Flag.Hide)
	} else {
		excl(&element.flags, Element_Flag.Hide)
	}
}

// add or stop an element from animating
element_animation_start :: proc(element: ^Element) {
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
	if !options_use_animations() {
		value^ = goal
		return
	}

	if value^ == -1 {
		value^ = goal
	} else {
		lambda := 10 * rate
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
	if element == nil || (msg != .Destroy && (.Destroy in element.flags)) {
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
	index_at := -1,
) -> (res: ^T) {
	res = new(T)
	element := cast(^Element) res
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
element_move :: proc(element: ^Element, bounds: Rect) {
	// move to new position - msg children to layout
	element.clip = rect_intersection(element.parent.clip, bounds)
	element.bounds = bounds
	element_message(element, .Layout)
}

// issue repaints for children
element_repaint :: #force_inline proc(element: ^Element) {
	element.window.update_next = true
}

// find first element by point
element_find_by_point :: proc(element: ^Element, x, y: f32) -> ^Element {
	p := Find_By_Point { x, y, nil }

	// stop disabled from interacting
	if (.Disabled in element.flags) {
		return nil
	}

	// allowing custom find by point calls
	if element_message(element, .Find_By_Point_Recursive, 0, &p) == 1 {
		return p.res != nil ? p.res : element
	}

	// default children watching
	// NOTE reverse order
	for i := len(element.children) - 1; i >= 0; i -= 1 {
		child := element.children[i]

		if (.Hide not_in child.flags) && rect_contains(child.clip, x, y) {
			if res := element_find_by_point(child, x, y); res != nil {
				return res
			}
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

// mark children for destruction
// calls .Destroy in case anything should happen already
// doesnt deallocate!
element_destroy :: proc(element: ^Element) {
	// skip flag done
	if .Destroy in element.flags {
		return
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

	// recurse to destroy all children
	for child in element.children {
		if .Layout_Ignore not_in child.flags {
			element_destroy(child)
		}
	}

	// push repaint
	if element.parent != nil {
		element_repaint(element.parent)
	}
}

// NOTE used internally
element_deallocate :: proc(element: ^Element) -> bool {
	if .Destroy_Descendent in element.flags {
		// clear flag
		excl(&element.flags, Element_Flag.Destroy_Descendent)

		// // destroy each child, loop from end to pop quickly
		// for i := len(element.children) - 1; i >= 0; i -= 1 {
		// 	child := element.children[i]

		// 	if element_destroy_now(child) {
		// 		unordered_remove(&element.children, i)
		// 	}
		// }

		// TODO use memmove?
		for i := 0; i < len(element.children); i += 1 {
			child := element.children[i]

			if element_deallocate(child) {
				ordered_remove(&element.children, i)
				element_message(element, .Destroy_Child_Finished, i)
				i -= 1
			}
		}
	}

	if .Destroy in element.flags {
		// send the destroy message to clear data
		element_message(element, .Deallocate_Recursive)

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
		// TODO is everything freed here? even higher memory?
		free(element)
		return true
	} else {
		// wasnt destroyed
		return false
	}
}

element_focus :: proc(element: ^Element) -> bool {
	prev := element.window.focused
	
	// skip same element
	if prev == element {
		return false
	}

	element.window.focused = element
	
	// send messages to prev and current
	if prev != nil {
		element_message(prev, .Update, UPDATE_FOCUSED)
	}

	if element != nil {
		element_message(element, .Update, UPDATE_FOCUSED)
	}

	return true
}

// true if the given element is 
window_focused_shown :: proc(window: ^Window) -> bool {
	if window.focused == nil {
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

//////////////////////////////////////////////
// button
//////////////////////////////////////////////

Button :: struct {
	using element: Element,
	builder: strings.Builder,
	invoke: proc(data: rawptr),
}

button_message :: proc(element: ^Element, msg: Message, di: int, dp: rawptr) -> int {
	button := cast(^Button) element

	#partial switch msg {
		case .Paint_Recursive: {
			pressed := element.window.pressed == element
			hovered := element.window.hovered == element
			target := element.window.target

			text_color := hovered || pressed ? theme.text_default : theme.text_blank

			if res := element_message(element, .Button_Highlight, 0, &text_color); res != 0 {
				if res == 1 {
					rect := element.bounds
					rect.r = rect.l + 4
					render_rect(target, rect, text_color, 0)
				}
			}

			if hovered || pressed {
				render_rect_outline(target, element.bounds, text_color)
			}

			text := strings.to_string(button.builder)
			erender_string_aligned(element, text, element.bounds, text_color, .Middle, .Middle)

			if element.window.focused == element {
				// log.info("rendering outline")
				render_rect_outline(target, element.bounds, RED)
			}
		}

		case .Custom_Clip: {
			pressed := element.window.pressed == element
			hovered := element.window.hovered == element

			if pressed || hovered {
				clip := cast(^Rect) dp
				clip^ = rect_margin(clip^, -DROP_SHADOW)
			}
		}

		case .Update: {
			element_repaint(element)
		}

		case .Deallocate_Recursive: {
			delete(button.builder.buf)
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
			text := strings.to_string(button.builder)
			width := max(50 * SCALE, estring_width(element, text) + TEXT_MARGIN_HORIZONTAL * SCALE)
			return int(width)
		}

		case .Get_Height: {
			return int(efont_size(element) + TEXT_MARGIN_VERTICAL * SCALE)
		}

		case .Key_Combination: {
			// if .Button_Can_Focus in element.flags {
			// 	combo := (cast(^string) dp)^
				
			// 	if combo == "space" || combo == "return" {
			// 		element_message(element, .Clicked)
			// 	}
			// }
		}
	}

	return 0
}

button_init :: proc(parent: ^Element, flags: Element_Flags, text: string) -> (res: ^Button) {
	flags := flags
	flags |= { .Tab_Stop }
	res = element_init(Button, parent, flags, button_message)
	res.builder = strings.builder_make(0, 32)
	res.data = res
	strings.write_string(&res.builder, text)
	return
}

//////////////////////////////////////////////
// icon button
//////////////////////////////////////////////

Icon_Button :: struct {
	using element: Element,
	icon: Icon,
	invoke: proc(data: rawptr),
}

icon_button_message :: proc(element: ^Element, msg: Message, di: int, dp: rawptr) -> int {
	button := cast(^Icon_Button) element

	#partial switch msg {
		case .Paint_Recursive: {
			pressed := element.window.pressed == element
			hovered := element.window.hovered == element
			target := element.window.target

			text_color := hovered || pressed ? theme.text_default : theme.text_blank

			if element_message(element, .Button_Highlight, 0, &text_color) == 1 {
				rect := element.bounds
				rect.r = rect.l + 4
				render_rect(target, rect, text_color, 0)
			}

			if hovered || pressed {
				render_rect_outline(target, element.bounds, text_color)
			}

			icon_size := style.icon_size * SCALE
			render_icon_aligned(target, font_icon, button.icon, element.bounds, text_color, .Middle, .Middle, icon_size)

			if element.window.focused == element {
				render_rect_outline(target, element.bounds, RED)
			}
		}

		case .Custom_Clip: {
			pressed := element.window.pressed == element
			hovered := element.window.hovered == element

			if pressed || hovered {
				clip := cast(^Rect) dp
				clip^ = rect_margin(clip^, -DROP_SHADOW)
			}
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
			icon_size := style.icon_size * SCALE
			icon_width := fontstash.icon_width(font_icon, icon_size, button.icon) 
			return int(icon_width + TEXT_MARGIN_HORIZONTAL * SCALE)
		}

		case .Get_Height: {
			return int(efont_size(element) + TEXT_MARGIN_VERTICAL * SCALE)
		}

		case .Key_Combination: {
			// if .Button_Can_Focus in element.flags {
			// 	combo := (cast(^string) dp)^
				
			// 	if combo == "space" || combo == "return" {
			// 		element_message(element, .Clicked)
			// 	}
			// }
		}
	}

	return 0
}

icon_button_init :: proc(parent: ^Element, flags: Element_Flags, icon: Icon) -> (res: ^Icon_Button) {
	flags := flags
	flags |= { .Tab_Stop }
	log.info("FLAGS", flags)
	res = element_init(Icon_Button, parent, flags, icon_button_message)
	res.icon = icon
	res.data = res
	return
}

//////////////////////////////////////////////
// label
//////////////////////////////////////////////

Label :: struct {
	using element: Element,
	builder: strings.Builder,
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
			}

			color := theme.text_default
			erender_string_aligned(element, text, element.bounds, color, ah, av)
		}
		
		case .Deallocate_Recursive: {
			delete(label.builder.buf)
		}

		case .Get_Width: {
			text := strings.to_string(label.builder)
			return int(estring_width(element, text))
		}

		case .Get_Height: {
			return int(efont_size(element))
		}
	}

	return 0
}

label_init :: proc(parent: ^Element, flags: Element_Flags, text := "") -> (res: ^Label) {
	res = element_init(Label, parent, flags, label_message)
	res.builder = strings.builder_make(0, 32)
	strings.write_string(&res.builder, text)
	return
}

//////////////////////////////////////////////
// slider
//////////////////////////////////////////////

Slider :: struct {
	using element: Element,
	position: f32,
	format: string,
	builder: strings.Builder,
}

slider_message :: proc(element: ^Element, msg: Message, di: int, dp: rawptr) -> int {
	slider := cast(^Slider) element

	#partial switch msg {
		case .Paint_Recursive: {
			pressed := element.window.pressed == element
			hovered := element.window.hovered == element
			target := element.window.target
			
			text_color := hovered || pressed ? theme.text_default : theme.text_blank
			render_rect_outline(target, element.bounds, text_color)

			slide := element.bounds
			slide.t = slide.b - math.round(5 * SCALE)
			slide.b = slide.t + math.round(3 * SCALE)
			slide.r = slide.l + slider.position	* f32(rect_width(slide))
			render_rect(target, slide, text_color, 0)

			element_message(slider, .Reformat)

			text := strings.to_string(slider.builder)
			erender_string_aligned(element, text, element.bounds, text_color, .Middle, .Middle)
		}

		case .Custom_Clip: {
			pressed := element.window.pressed == element
			hovered := element.window.hovered == element

			if pressed || hovered {
				clip := cast(^Rect) dp
				clip^ = rect_margin(clip^, -DROP_SHADOW)
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
			return int(efont_size(element) + TEXT_MARGIN_VERTICAL * SCALE)
		}

		case .Reformat: {
			strings.builder_reset(&slider.builder)
			fmt.sbprintf(&slider.builder, slider.format, slider.position)
		}

		case .Deallocate_Recursive: {
			delete(slider.builder.buf)
		}

		case .Left_Up: {
			// element_repaint(element)
		}
	}

	// change slider position and cause repaint
	if msg == .Left_Down || (msg == .Mouse_Drag && element.window.pressed_button == MOUSE_LEFT) {
		old := slider.position
		slider.position = 
			clamp(
				f32(element.window.cursor_x - element.bounds.l) / f32(rect_width(element.bounds)),
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

slider_init :: proc(parent: ^Element, flags: Element_Flags, position: f32 = 0) -> (res: ^Slider) {
	res = element_init(Slider, parent, flags, slider_message)
	res.builder = strings.builder_make(0, 32)
	res.position = clamp(position, 0, 1)
	res.format = "%.1f"
	fmt.sbprintf(&res.builder, res.format, res.position)
	return
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

	box_icon_rect :: proc(box: ^Checkbox) -> (res: Rect) {
		res = rect_margin(box.bounds, BOX_MARGIN * SCALE)
		res.r = res.l + (rect_height(box.bounds) + TEXT_MARGIN_VERTICAL) * SCALE
		return
	}

	#partial switch msg {
		// width of text + icon rect
		case .Get_Width: {
			text := strings.to_string(box.builder)
			text_width := estring_width(element, text)
			
			margin := BOX_MARGIN * SCALE
			gap := BOX_GAP * SCALE
			box_rect := box_icon_rect(box) 

			return int(text_width + margin * 2 + rect_width(box_rect) + gap)
		}

		case .Custom_Clip: {
			pressed := element.window.pressed == element
			hovered := element.window.hovered == element

			if pressed || hovered {
				clip := cast(^Rect) dp
				clip^ = rect_margin(clip^, -DROP_SHADOW)
			}
		}

		case .Get_Height: {
			return int(efont_size(element) + TEXT_MARGIN_VERTICAL * SCALE)
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

			box_width := math.round(rect_width_halfed(box_rect))

			moving_rect := box_rect
			moving_rect.l = box_rect.l + box.state_unit * box_width
			moving_rect.r = moving_rect.l + (box_width - 1 * SCALE)
			moving_rect = rect_margin(moving_rect, 2 * SCALE)
			render_rect(target, moving_rect, text_color, ROUNDNESS)

			text_bounds := element.bounds
			text_bounds.l = box_rect.r + BOX_GAP * SCALE

			erender_string_aligned(
				element,
				strings.to_string(box.builder),
				text_bounds,
				text_color,
				.Left,
				.Middle,
			)
		}

		case .Clicked: {
			box.state = !box.state
			element_repaint(element)
	
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
	}

	return 0
}

checkbox_init :: proc(
	parent: ^Element, 
	flags: Element_Flags, 
	text: string,
	state: bool,
) -> (res: ^Checkbox) {
	res = element_init(Checkbox, parent, flags, checkbox_message)
	res.state = state
	res.state_unit = f32(state ? 1 : 0)
	res.builder = strings.builder_make(0, 32)
	strings.write_string(&res.builder, text)
	return
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
	width, height: f32,
	vertical: bool,
	style: Spacer_Style,
}

spacer_message :: proc(element: ^Element, msg: Message, di: int, dp: rawptr) -> int {
	spacer := cast(^Spacer) element

	#partial switch msg {
		case .Paint_Recursive: {
			target := element.window.target

			switch spacer.style {
				case .Empty: {} 
				
				case .Thin: {
					// limit to height / width
					rect := element.bounds

					if spacer.vertical {
						rect.l += math.round(rect_width_halfed(rect))
						rect.r = rect.l + LINE_WIDTH
					} else {
						rect.t += math.round(rect_height_halfed(rect))
						rect.b = rect.t + LINE_WIDTH
					}

					render_rect(target, rect, theme.text_default, ROUNDNESS)
				} 

				case .Full: {
					render_rect(target, element.bounds, theme.text_default, ROUNDNESS)
				}

				case .Dotted: {
					// TODO dotted line
				}
			}
		}

		case .Get_Width: {
			return int(spacer.width * SCALE)
		}

		case .Get_Height: {
			return int(spacer.height * SCALE)
		}
	}

	return 0
}

spacer_init :: proc(
	parent: ^Element, 
	flags: Element_Flags, 
	w, h: f32,
	style: Spacer_Style,
	vertical := false,
) -> (res: ^Spacer) {
	res = element_init(Spacer, parent, flags, spacer_message)
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
	
	// gut info
	cut_amount: f32,
	margin: f32,
	color: Color,
	gap: f32,
	rounded: bool,

	// offset if panel is scrollable
	drag_x: f32,
	drag_y: f32,
	offset_x: f32,
	offset_y: f32,

	// shadow + roundness
	shadow: bool,

	// floaty property
	float_x: f32,
	float_y: f32,
	float_width: f32,
	float_height: f32,
	float_transparency: f32,

	scrollbar: ^Scrollbar,
	background_index: int,
}

panel_calculate_per_fill :: proc(panel: ^Panel, _count: ^int, hspace, vspace: int, scale: f32) -> int {
	horizontal := .HP in panel.flags 
	available := horizontal ? hspace : vspace;
	count, fill, per_fill: int

	for child in panel.children {
		if .Hide in child.flags {
			continue;
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
		available -= (count - 1) * int(panel.gap * scale)
	}

	if available > 0 && fill != 0 {
		per_fill = available / fill
	}

	if _count != nil {
		_count^ = count
	}

	return per_fill
}


// layout your panel, output the expected w / h
// effected by cut directions
panel_layout :: proc(panel: ^Panel, measure := false) -> (output_w, output_h: f32) {
	scrollbar_size := SCROLLBAR_SIZE * SCALE

	{
		// check parent
		cut_from: ^Rect
		if panel.parent == &panel.window.element {
			cut_from = &panel.window.modifiable_bounds
		} else {
			cut_from = &panel.parent.bounds
		}
	
		// get element rect		
		res: Rect
		if .Panel_Floaty in panel.flags {
			// get expected w + h
			// w, h := panel_layout(panel, true)
			x := panel.float_x
			y := panel.float_y

			if .Panel_Floaty_Center_X in panel.flags {
				x += panel.window.widthf / 2 - panel.float_width * SCALE / 2
				// y += style.floaty_margin * scale
			}

			if .Panel_Floaty_Center_Y in panel.flags {
				y += panel.window.heightf / 2 - panel.float_height * SCALE / 2
			}

			res = rect_wh(x, y, panel.float_width * SCALE, panel.float_height * SCALE)
		} else {
			// cut bounds of panel
			flag := cut_flag_from_flags(panel.flags)
			amt := SCALE * panel.cut_amount
			res = rect_cut_from_flag(flag, cut_from, amt, amt)
		}

		panel.clip = rect_intersection(panel.parent.clip, res)
		panel.bounds = res
	}

	if .Panel_Panable in panel.flags {
		panel.bounds.l += panel.offset_x
		panel.bounds.t += panel.offset_y
	}

	// scaled padding
	original := panel.bounds

	// use scrollbar
	if panel.scrollbar != nil {
		panel.bounds.t -= math.round(panel.scrollbar.position)
	}

	// subtract bounds
	if panel.scrollbar != nil {
		panel.bounds.r -= scrollbar_size
	}

	panel.bounds = rect_margin(panel.bounds, panel.margin * SCALE)

	// cut bound per element 
	gap_size := SCALE * panel.gap
	last_cut := Element_Flag.Invalid
	for child in panel.children {
		if (.Hide in child.flags) || (.Layout_Ignore in child.flags) {
			continue
		}

		w := f32(element_message(child, .Get_Width, 1))
		h := f32(element_message(child, .Get_Height, 1))
		flag := cut_flag_from_flags(child.flags)

		// apply gap
		if last_cut != .Invalid && panel.gap != 0 {
			// skip := 
			// 	panel.last_cut == .CL && flag == .CR ||
			// 	panel.last_cut == .CR && flag == .CL 
			skip := false						

			// disallow few scenarios
			if !skip {
				rect_cut_from_flag(last_cut, &panel.bounds, gap_size, gap_size)
			}
		}

		res := rect_cut_from_flag(flag, &panel.bounds, w, h)
		real_res := res
		last_cut = flag

		// if not fill apply normal size to other boundary
		if .CF not_in child.flags {
			if (.CL in child.flags) || (.CR in child.flags) {
				real_res.t = real_res.t + rect_height(real_res) / 2 - h / 2
				real_res.b = real_res.t + h
				real_res = rect_intersection(res, real_res)
				// log.info("try left / right")
			}

			if (.CT in child.flags) || (.CB in child.flags) {
				real_res.l = real_res.l + rect_width(real_res) / 2 - w / 2
				real_res.r = real_res.l + w
				real_res = rect_intersection(res, real_res)
				// log.info("try top / bottom")
			}
		}

		// move child to location
		if !measure {
			element_move(child, real_res)
		}
	}

	output_w = rect_width(original)
	output_h = panel.bounds.t - original.t
	panel.bounds = original
	
	// set props of scrollbar
	if panel.scrollbar != nil {
		output_h += math.round(panel.scrollbar.position)

		scroll_bounds := panel.bounds
		scroll_bounds.l = scroll_bounds.r - scrollbar_size
		panel.scrollbar.maximum = output_h // maximum size
		// panel.scrollbar.maximum = int(rect_height(panel.bounds) + 100) // actual size
		panel.scrollbar.page = rect_height(panel.bounds) // actual size
		element_move(panel.scrollbar, scroll_bounds)
	}

	return
}

panel_message :: proc(element: ^Element, msg: Message, di: int, dp: rawptr) -> int {
	panel := cast(^Panel) element
	panable := (.Panel_Panable in element.flags)
	floaty := (.Panel_Floaty in element.flags)
	// disallow both at the same time
	// assert(!(scrollable && floaty))

	#partial switch msg {
		case .Custom_Clip: {
			if panel.shadow {
				rect := cast(^Rect) dp
				before := rect^
				rect^ = rect_margin(element.clip, -DROP_SHADOW)
			}
		}

		case .Layout: {
			panel_layout(panel, false)
		}

		case .Update: {
			for child in element.children {
				element_message(child, .Update, di, dp)
			}
		}

		case .Mouse_Drag: {
			mouse := (cast(^Mouse_Coordinates) dp)^
			
			if panable && element.window.pressed_button == MOUSE_MIDDLE {
				diff_x := element.window.cursor_x - mouse.x
				diff_y := element.window.cursor_y - mouse.y

				panel.offset_x = panel.drag_x + diff_x
				panel.offset_y = panel.drag_y + diff_y
				// log.info("drag", diff_x, diff_y, panel.offset_x, panel.offset_y)

				window_set_cursor(element.window, .Crosshair)
				element_repaint(element)
			}

			if floaty && element.window.pressed_button == MOUSE_MIDDLE {
				diff_x := element.window.cursor_x - mouse.x
				diff_y := element.window.cursor_y - mouse.y

				panel.float_x = panel.drag_x + diff_x
				panel.float_y = panel.drag_y + diff_y

				window_set_cursor(element.window, .Crosshair)
				element_repaint(element)				
			}
		}

		case .Find_By_Point_Recursive: {
			p := cast(^Find_By_Point) dp

			// // ignore find by point when floaty or scrollable
			// if (scrollable || floaty) && element.window.pressed_button == MOUSE_MIDDLE {
			// 	p.res = element
			// 	return 1
			// }

			return 0
		}

		case .Middle_Down: {
			// store temp position
			if panable {
				panel.drag_x = panel.offset_x
				panel.drag_y = panel.offset_y
			}

			if floaty {
				panel.drag_x = panel.float_x
				panel.drag_y = panel.float_y
			}
		}

		case .Mouse_Scroll_Y: {
			handled := false

			if panable {
				panel.offset_y += f32(di) * 20
				element_repaint(element)
				handled = true
			}

			// send msg to scrollbar
			if panel.scrollbar != nil {
				element_message(panel.scrollbar, msg, di, dp)
				handled = true
			}

			return int(handled)
		}

		case .Mouse_Scroll_X: {
			if panable {
				panel.offset_x += f32(di) * 20
				element_repaint(element)
			}
		}

		case .Get_Width: {
			if di == LAYOUT_FULL {
				return 0
			}

			// TODO width? with layout
			return int(rect_width(element.bounds))
		}

		case .Get_Height: {
			if di == LAYOUT_FULL {
				return 0
			}

			// TODO height? with layout
			return int(rect_height(element.bounds))
		}

		case .Panel_Color: {
			color := cast(^Color) dp
			color^ = panel.color

			if .Panel_Default_Background in panel.flags {
				color^ = theme.background[panel.background_index]
			}

			if color^ == TRANSPARENT {
				return 0
			}
		}

		case .Paint_Recursive: {
			color: Color
			element_message(element, .Panel_Color, 0, &color)

			if color == {} {
				return 0
			}

			target := element.window.target
			bounds := element.bounds

			if panable {
				bounds.l -= panel.offset_x
				bounds.t -= panel.offset_y
			}

			if panel.shadow {
				render_drop_shadow(target, bounds, color, panel.rounded ? ROUNDNESS : 0)
			} else {
				render_rect(target, bounds, color, panel.rounded ? ROUNDNESS : 0)
			}
		}
	}

	return 0
}	

panel_init :: proc(
	parent: ^Element, 
	flags: Element_Flags, 
	cut_amount: f32 = 0,
	margin: f32 = 0,
	gap: f32 = 0,
	color: Color = TRANSPARENT,
) -> (res: ^Panel) {
	res = element_init(Panel, parent, flags, panel_message)
	res.cut_amount = cut_amount
	res.margin = margin
	res.color = color
	res.gap = gap

	if .Panel_Scrollable in flags {
		res.scrollbar = scrollbar_init(res, { .Layout_Ignore })
	}

	return
}

//////////////////////////////////////////////
// scrollbar
//////////////////////////////////////////////

Scrollbar :: struct {
	using element: Element,
	maximum, page: f32,
	drag_offset: f32,
	position: f32,
	in_drag: bool,
	horizontal: bool,
}

scrollbar_message :: proc(element: ^Element, msg: Message, di: int, dp: rawptr) -> int {
	scrollbar := cast(^Scrollbar) element

	#partial switch msg {
		case .Paint_Recursive: {
			rect := element.bounds
			rect = rect_margin(rect, 2 * SCALE)
			render_rect(element.window.target, rect, theme.background[0], ROUNDNESS)
		}

		case .Mouse_Scroll_Y: {
			if .Hide not_in element.children[0].flags {
				scrollbar.position -= f32(di) * 10

				// clamp position
				diff := scrollbar.maximum - scrollbar.page
				if scrollbar.position < 0 {
					scrollbar.position = 0
				} else if scrollbar.position > diff {
					scrollbar.position = diff
				}

				element_repaint(scrollbar)
				element_message(scrollbar.parent, .Scrolled)
				return 1
			}

			return 0
		}

		case .Layout: {
			up := element.children[0]
			thumb := element.children[1]
			down := element.children[2]

			// log.info(scrollbar.maximum, scrollbar.page, scrollbar.maximum - scrollbar.page)

			if scrollbar.page >= scrollbar.maximum || scrollbar.maximum <= 0 || scrollbar.page == 0 {
				incl(&up.flags, Element_Flag.Hide)
				incl(&thumb.flags, Element_Flag.Hide)
				incl(&down.flags, Element_Flag.Hide)
				scrollbar.position = 0
				// log.info("hidden")
			} else {
				excl(&up.flags, Element_Flag.Hide)
				excl(&thumb.flags, Element_Flag.Hide)
				excl(&down.flags, Element_Flag.Hide)

				// layout each element
				// TODO width or height
				scrollbar_size := rect_height(scrollbar.bounds)
				thumb_size := scrollbar_size * scrollbar.page / scrollbar.maximum
				thumb_size = max(SCROLLBAR_SIZE / 2, thumb_size)

				// clamp position
				diff := scrollbar.maximum - scrollbar.page
				if scrollbar.position < 0 {
					scrollbar.position = 0
				} else if scrollbar.position > diff {
					scrollbar.position = diff
				}

				// clamp
				thumb_position := scrollbar.position / diff * (scrollbar_size - thumb_size)
				if scrollbar.position == diff {
					thumb_position = scrollbar_size - thumb_size
				}

				// TODO horizontal
				r := element.bounds
				r.b = r.t + thumb_position
				element_move(up, r)
				r.t = r.b
				r.b = r.t + thumb_size
				element_move(thumb, r)
				r.t = r.b
				r.b = element.bounds.b
				element_move(down, r)
				// log.info("un")
			}
		}
	}

	return 0
}

scroll_up_down_message :: proc(element: ^Element, msg: Message, di: int, dp: rawptr) -> int {
	scrollbar := cast(^Scrollbar) element.parent
	is_down := uintptr(element.data) == SCROLLBAR_DOWN

	#partial switch msg {
		// case .Paint_Recursive: {
		// 	target := element.window.target

		// 	if is_down {
		// 		render_rect(target, element.bounds, { 210, 255, 210, 255 })
		// 	} else {
		// 		render_rect(target, element.bounds, { 210, 210, 255, 255 })
		// 	}
		// }

		case .Left_Down: {
			element_animation_start(element)
		}

		case .Left_Up: {
			element_animation_stop(element)
		}

		case .Animate: {
			// TODO investigate
			// // log.info("animating")
			// direction: f32 = is_down ? 1 : -1
			// goal := scrollbar.position + direction * 0.1 * scrollbar.page
			// animate_to(&scrollbar.position, goal, 1, 1)
			// element_repaint(scrollbar)

			// return 1
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
			rect := rect_margin(element.bounds, 3 * SCALE)
			color := theme.text_default
			color.a = pressed || hovered ? 200 : 150
			render_rect(target, rect, color, ROUNDNESS)
		}

		case .Update: {
			// log.info("update")
			element_repaint(element)
		}

		case .Mouse_Drag: {
			if element.window.pressed_button == MOUSE_LEFT {
				if !scrollbar.in_drag {
					scrollbar.in_drag = true
					// TODO horizontal
					scrollbar.drag_offset = element.bounds.t - scrollbar.bounds.t - f32(element.window.cursor_y)
				}

				thumb_position := element.window.cursor_y + scrollbar.drag_offset
				size := rect_height(scrollbar.bounds) - rect_height(element.bounds)
				scrollbar.position = thumb_position / size * (scrollbar.maximum - scrollbar.page)
				// log.info("pos", scrollbar.position)
				element_repaint(scrollbar)
				element_message(scrollbar.parent, .Scrolled)
			}
		}

		case .Left_Up: {
			scrollbar.in_drag = false
		}
	}

	return 0
}

SCROLLBAR_UP :: uintptr(0)
SCROLLBAR_DOWN :: uintptr(1)

scrollbar_init :: proc(parent: ^Element, flags: Element_Flags) -> (res: ^Scrollbar) {
	res = element_init(Scrollbar, parent, flags, scrollbar_message)		
	element_init(Element, res, flags, scroll_up_down_message).data = rawptr(SCROLLBAR_UP)
	element_init(Element, res, flags, scroll_thumb_message)
	element_init(Element, res, flags, scroll_up_down_message).data = rawptr(SCROLLBAR_DOWN)
	return
}

//////////////////////////////////////////////
// table
//////////////////////////////////////////////

TABLE_ROW :: 30
TABLE_HEADER :: 30
TABLE_COLUMN_GAP :: 20

Table :: struct {
	using element: Element,
	
	scrollbar: ^Scrollbar,
	columns: string,
	buffer: [256]u8,

	item_count: int, // top to bottom per column
	column_widths: []f32, // max width per every column
	column_count: int, // columns are left to right <->
}

table_message :: proc(element: ^Element, msg: Message, di: int, dp: rawptr) -> int {
	table := cast(^Table) element

	#partial switch msg {
		case .Get_Width: {
			return int(200 * SCALE)
		}

		case .Get_Height: {
			return int(200 * SCALE)
		}

		case .Layout: {
			scrollbar_bounds := element.bounds
			scrollbar_bounds.l = scrollbar_bounds.r - SCROLLBAR_SIZE * SCALE
			table.scrollbar.maximum = f32(table.item_count) * TABLE_ROW * SCALE
			table.scrollbar.page = rect_height(element.bounds) - TABLE_HEADER * SCALE
			element_move(table.scrollbar, scrollbar_bounds)
		}

		case .Paint_Recursive: {
			target := element.window.target
			defer render_rect_outline(target, element.bounds, theme.text_default)

			assert(table.column_widths != nil, "table_resize_columns needs to be called once")

			item := Table_Get_Item {
				buffer = table.buffer[:],
			}

			row := element.bounds
			row_height := TABLE_ROW * SCALE
			row.t += TABLE_HEADER * SCALE
			row.t -= f32(int(table.scrollbar.position) % int(row_height))

			hovered := table_hit_test(table, element.window.cursor_x, element.window.cursor_y)
			for i := int(table.scrollbar.position / row_height); i < table.item_count; i += 1 {
				if row.t > element.clip.b {
					break
				}

				row.b = row.t + row_height
				
				// init
				item.index = i
				item.is_selected = false
				item.column = 0
				text_color := theme.text_default
				element_message(element, .Table_Get_Item, 0, &item)

				if item.is_selected {
					render_rect(target, row, text_color, 0)
					text_color = theme.background[0]
				} else if hovered == i {
					render_rect(target, row, text_color, 0)
					text_color = theme.background[0]
				}

				cell := row
				cell.l += TABLE_COLUMN_GAP * SCALE

				// walk through each column
				for j in 0..<table.column_count {
					// dont recall j == 0
					if j != 0 {
						item.column = j
						element_message(element, .Table_Get_Item, 0, &item)
					}

					cell.r = cell.l + table.column_widths[j]
					erender_string_aligned(element, item.output, cell, text_color, .Left, .Middle)
					cell.l += table.column_widths[j] + TABLE_COLUMN_GAP * SCALE
				}

				row.t += row_height
			}

			// header 
			header := element.bounds
			header.b = header.t + TABLE_HEADER * SCALE
			render_rect(target, header, color_blend_amount(theme.text_default, WHITE, 0.1), ROUNDNESS)
			render_underline(target, header, theme.text_default, 2)
			header.l += TABLE_COLUMN_GAP * SCALE

			text_color := theme.text_default
			// draw each column
			index := 0
			mod := table.columns
			for word in strings.split_iterator(&mod, "\t") {
				header.r = header.l + table.column_widths[index]
				erender_string_aligned(element, word, header, text_color, .Left, .Middle)
				header.l += table.column_widths[index] + TABLE_COLUMN_GAP * SCALE
				index += 1	
			}
		}

		case .Mouse_Scroll_Y: {
			return element_message(table.scrollbar, msg, di, dp)
		}

		case .Mouse_Move, .Update: {
			element_repaint(element)
		}

		case .Deallocate_Recursive: {
			delete(table.columns)
			delete(table.column_widths)
		}
	}

	return 0
}

table_init :: proc(parent: ^Element, flags: Element_Flags, columns := "") -> (res: ^Table) {
	res = element_init(Table, parent, flags, table_message)	
	res.scrollbar = scrollbar_init(res, {})
	res.columns = strings.clone(columns)
	return
}

table_hit_test :: proc(table: ^Table, x, y: f32) -> int {
	x := x - table.bounds.l

	// x check
	if x < 0 || x >= rect_width(table.bounds) - SCROLLBAR_SIZE * SCALE {
		return - 1
	}

	y := y
	y -= (table.bounds.t + TABLE_HEADER * SCALE) - table.scrollbar.position

	// y check
	row_height := TABLE_ROW * SCALE
	if y < 0 || y >= row_height * f32(table.item_count) {
		return -1
	}

	return int(y / row_height)
}

table_header_hit_test :: proc(table: ^Table, x, y: int) -> int {
	if table.column_count == 0 {
		return -1
	}

	header := table.bounds
	header.b = header.t + TABLE_HEADER * SCALE
	header.l += TABLE_COLUMN_GAP * SCALE

	// iterate columns
	mod := table.columns
	index := 0
	for word in strings.split_iterator(&mod, "\t") {
		header.r = header.l + table.column_widths[index]

		if rect_contains(header, f32(x), f32(y)) {
			return index
		}

		header.l += table.column_widths[index] + TABLE_COLUMN_GAP * SCALE
		index += 1
	}

	return -1
}

table_ensure_visible :: proc(table: ^Table, index: int) -> bool {
	row_height := TABLE_ROW * SCALE
	y := f32(index) * row_height
	height := rect_height(table.bounds) - TABLE_HEADER * SCALE - row_height

	if y < 0 {
		table.scrollbar.position += y
		element_repaint(table)
		return true
	} else if y > height {
		table.scrollbar.position -= height - y
		element_repaint(table)
		return true
	} else {
		return false
	}
}

// calculate column widths based on each item width
table_resize_columns :: proc(table: ^Table) {
	table.column_count = 0
	mod := table.columns
	for word in strings.split_iterator(&mod, "\t") {
		table.column_count += 1
	}

	delete(table.column_widths)
	table.column_widths = make([]f32, table.column_count)

	item := Table_Get_Item {
		buffer = table.buffer[:],
	}

	// retrieve longest textual width per column by iterating through all items widths
	mod = table.columns
	for word in strings.split_iterator(&mod, "\t") {
		longest := estring_width(table, word)

		for i in 0..<table.item_count {
			item.index = i
			element_message(table, .Table_Get_Item, 0, &item)
			width := estring_width(table, item.output)

			if width > longest {
				longest = width
			}
		}

		table.column_widths[item.column] = longest
		item.column += 1
	}
}

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
}

Color_Picker_HUE :: struct {
	using element: Element,
	y: f32,
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
		
			gap := math.round(10 * SCALE)
			cut := rect_margin(element.bounds, 5)
			left := rect_cut_left(&cut, math.round(SV_WIDTH * SCALE))
			cut.l += gap
			element_move(sv, left)
			element_move(hue, cut)
		}

		// case .Custom_Clip: {
		// 	clip := cast(^Rect) dp
		// 	clip^ = rect_margin(clip^, -sv_out_size)
		// }

		case .Paint_Recursive: {
			target := element.window.target
			render_rect(target, element.bounds, theme.background[0], 0)
			render_rect_outline(target, element.bounds, theme.text_default, 0, LINE_WIDTH)
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
			render_texture(target, .HUE, element.bounds)
			render_rect_outline(target, element.bounds, theme.text_default, 0, LINE_WIDTH)

			OUT_SIZE :: 10
			out_size := math.round(OUT_SIZE * SCALE)

			hue_out := element.bounds
			hue_out.t += hue.y * rect_height(element.bounds) - out_size / 2
			hue_out.b = hue_out.t + out_size

			render_rect_outline(target, hue_out, theme.text_default, 0, LINE_WIDTH)
		}

		case .Get_Cursor: {
			return int(Cursor.Resize_Vertical)
		}
	}

	if msg == .Left_Down || (msg == .Mouse_Drag && element.window.pressed_button == MOUSE_LEFT) {
		relative_y := element.window.cursor_y - element.bounds.t
		hue.y = clamp(relative_y / rect_height(element.bounds), 0, 1)
		element_message(sv, .Value_Changed)
		element_repaint(element)
	}

	return 0
}

color_picker_sv_message :: proc(element: ^Element, msg: Message, di: int, dp: rawptr) -> int {
	sv := cast(^Color_Picker_SV) element
	hue := cast(^Color_Picker_HUE) element.parent.children[1]
	SV_OUT_SIZE :: 10
	sv_out_size := math.round(SV_OUT_SIZE * SCALE)

	#partial switch msg {
		case .Paint_Recursive: {
			target := element.window.target
			color := color_hsv_to_rgb(hue.y, 1, 1)
			render_texture(target, .SV, element.bounds, color)
			render_rect_outline(target, element.bounds, theme.text_default, 0, LINE_WIDTH)

			sv_out := rect_wh(
				element.bounds.l + sv.x * rect_width(element.bounds) - sv_out_size / 2, 
				element.bounds.t + sv.y * rect_height(element.bounds) - sv_out_size / 2,
				sv_out_size,
				sv_out_size,
			)
			render_rect_outline(target, sv_out, theme.text_default, 0, LINE_WIDTH)
		}

		case .Get_Cursor: {
			return int(Cursor.Crosshair)
		}

		case .Value_Changed: {
			picker := cast(^Color_Picker) sv.parent

			if picker.color_mod != nil {
				output := color_hsv_to_rgb(hue.y, sv.x, 1 - sv.y)
				picker.color_mod^ = output
			}
		}
	}

	if msg == .Left_Down || (msg == .Mouse_Drag && element.window.pressed_button == MOUSE_LEFT) {
		relative_x := element.window.cursor_x - element.bounds.l
		relative_y := element.window.cursor_y - element.bounds.t
		sv.x = clamp(relative_x / rect_width(element.bounds), 0, 1)
		sv.y = clamp(relative_y / rect_height(element.bounds), 0, 1)
		element_message(element, .Value_Changed)
		element_repaint(element)
	}

	return 0
}

color_picker_init :: proc(parent: ^Element, flags: Element_Flags, hue: f32) -> (res: ^Color_Picker) {
	res = element_init(Color_Picker, parent, flags, color_picker_message)
	res.sv = element_init(Color_Picker_SV, res, flags, color_picker_sv_message)
	res.hue = element_init(Color_Picker_HUE, res, flags, color_picker_hue_message)
	return 
}

//////////////////////////////////////////////
// enum selector
//////////////////////////////////////////////

Toggle_Selector :: struct {
	using element: Element,
	value: ^int,
	count: int,
	names: []string,

	// layouted cells and animation
	cells: []Rect,
	cell_transition: bool,
	cell_unit: f32,
	cell_width: f32, // width per cell
}

toggle_selector_message :: proc(element: ^Element, msg: Message, di: int, dp: rawptr) -> int {
	toggle := cast(^Toggle_Selector) element
	assert(len(toggle.names) == toggle.count)

	#partial switch msg {
		case .Layout: {
			toggle.cell_width = rect_width(element.bounds) / f32(toggle.count)

			// layout cells
			cut := element.bounds
			for i in 0..<toggle.count {
				toggle.cells[i] = rect_cut_left(&cut, toggle.cell_width)
			}
		}

		case .Paint_Recursive: {
			target := element.window.target
			hovered := element.window.hovered == element
			pressed := element.window.pressed == element

			text_color := hovered || pressed ? theme.text_default : theme.text_blank

			// animated cell highlight
			highlight := toggle.cells[0]
			highlight.l += toggle.cell_unit * toggle.cell_width 
			highlight.r = highlight.l + toggle.cell_width
			render_rect(target, highlight, theme.text_good, ROUNDNESS)

			for i in 0..<toggle.count {
				r := toggle.cells[i]
				color := text_color

				if !rect_contains(r, element.window.cursor_x, element.window.cursor_y) {
					color = theme.text_blank
				}

				erender_string_aligned(element, toggle.names[i], r, color, .Middle, .Middle)
			}
			
			render_rect_outline(target, element.bounds, text_color)
		}

		case .Get_Width: {
			return int(100 * SCALE)
		}

		case .Get_Height: {
			return int(efont_size(element) + TEXT_MARGIN_VERTICAL * SCALE)
		}

		case .Mouse_Move: {
			element_repaint(element)
		}

		case .Clicked: {
			old := toggle.value^

			// select and start animation transition towards
			for i in 0..<toggle.count {
				r := toggle.cells[i]
				if rect_contains(r, element.window.cursor_x, element.window.cursor_y) {
					toggle.value^ = i
					toggle.cell_transition = true
					element_animation_start(element)
					break
				}
			}

			if old != toggle.value^ {
				element_repaint(element)
			}
		}

		case .Animate: {
			handled := animate_to(
				&toggle.cell_transition,
				&toggle.cell_unit,
				f32(toggle.value^),
				1,
				0.01,
			)

			return int(handled)
		}

		case .Deallocate_Recursive: {
			delete(toggle.cells)
		}
	}

	return 0
}

toggle_selector_init :: proc(
	parent: ^Element,
	flags: Element_Flags,
	value: ^int,
	count: int,
	names: []string,
) -> (res: ^Toggle_Selector) {
	res = element_init(Toggle_Selector, parent, flags, toggle_selector_message)
	res.value = value
	res.count = count
	res.names = names
	res.cells = make([]Rect, count)
	return 
}

//////////////////////////////////////////////
// font size helpers
//////////////////////////////////////////////

Font_Options :: struct {
	font: ^Font,
	size: f32,
}

element_retrieve_font_options :: proc(element: ^Element) -> (font: ^Font, size: f32) {
	// default
	if element.font_options == nil {
		font = font_regular
		size = DEFAULT_FONT_SIZE
	} else {
		font = element.font_options.font
		size = element.font_options.size
	}

	return 
}

erender_string_aligned :: #force_inline proc(
	element: ^Element,
	text: string,
	rect: Rect,
	color: Color,
	ah: Align_Horizontal,
	av: Align_Vertical,
) {
	font, size := element_retrieve_font_options(element)
	
	render_string_aligned(
		element.window.target,
		font,
		text, 
		rect, 
		color, 
		ah, 
		av, 
		size * SCALE,
	)
}

erunes_width :: #force_inline proc(element: ^Element, runes: []rune) -> f32 {
	font, size := element_retrieve_font_options(element)
	return fontstash.runes_width(font, size * SCALE, runes)
}

estring_width :: #force_inline proc(element: ^Element, text: string) -> f32 {
	font, size := element_retrieve_font_options(element)
	return fontstash.string_width(font, size * SCALE, text)
}

efont_size :: proc(element: ^Element) -> f32 {
	_, size := element_retrieve_font_options(element)
	return math.round(size * SCALE)
}