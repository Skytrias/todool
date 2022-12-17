package src

import "core:fmt"
import "core:strings"

Dialog :: struct {
	using element: Element,
	result: Dialog_Result,
	builder: strings.Builder,
	width: int,
	um: Undo_Manager,
	shadow: f32,
}

Dialog_Result :: enum {
	None,
	Default,
	Cancel,
}

dialog_spawn :: proc(
	window: ^Window,
) {

}