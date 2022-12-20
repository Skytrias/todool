package src

import "core:strconv"
import "core:strings"
import "core:fmt"
import "core:mem"
import dll "core:container/intrusive/list"
import "../fuzz"

Keymap_Editor :: struct {
	window: ^Window,
	panel: ^Panel,

	grids: [4]^Static_Grid,
	// grid_keep_in_frame: Maybe(^Static_Grid),

	// interactables
	issue_update: ^Static_Grid,
	stealer: ^KE_Stealer,

	menu: struct {
		combo: ^Combo_Node, // for menu setting
		sub: ^Panel,
		line: ^Static_Line,
		box: ^Text_Box,
		keymap: ^Keymap,
	},

	um: Undo_Manager,
}
ke: Keymap_Editor

keymap_editor_window_message :: proc(element: ^Element, msg: Message, di: int, dp: rawptr) -> int {
	window := cast(^Window) element

	#partial switch msg {
		case .Key_Combination: {
			combo := (cast(^string) dp)^

			switch combo {
				case "1"..<"5": {
					value := strconv.atoi(combo)
					grid := ke.grids[value - 1]
					// ke.grid_keep_in_frame = grid
					state := grid.hide_cells
					state^ = !state^
					window_repaint(window)
					return 1
				}

				case "escape": {
					if ke.menu.box != nil {
						if ke.menu.box.ss.length == 0 {
							menu_close(window)
						} else {
							box_head_tail_push(&ke.um, ke.menu.box)
							box_set_caret_dp(ke.menu.box, BOX_SELECT_ALL, nil)
							box_replace(&ke.um, ke.menu.box, ke.menu.box, "", -1, true, false)
							undo_group_end(&ke.um)
							element_focus(window, ke.menu.box)
						}

						window_repaint(window)
						return 1
					}
				}

				case "return": {
					if ke.menu.box != nil && ke.menu.sub != nil {
						found: ^Element
						children := panel_children(ke.menu.sub)

						// NOTE force not to use the scrollbar...
						for child in children {
							if .Hide not_in child.flags {
								found = child
								break
							}
						}

						if found != nil {
							cmd := cast(^KE_Command) found
							ke_command_build(cmd)
							return 1
						}
					}
				}
			}

			if ke.menu.box != nil {
				element_focus(window, ke.menu.box)
				element_message(ke.menu.box, msg, di, dp)
			}
		}

		case .Unicode_Insertion: {
			if ke.menu.box != nil {
				element_focus(window, ke.menu.box)
				element_message(ke.menu.box, msg, di, dp)
			}
		}

		case .Destroy: {
			undo_manager_destroy(&ke.um)
			ke = {}
		}
	}

	return 0
}

comment_keymap_editor_spawn :: "spawn the keymap editor window"
keymap_editor_spawn :: proc(du: u32) {
	if ke.window != nil {
		window_raise(ke.window)
		return
	}

	ke.window = window_init(nil, {}, "Keymap Editor", 800, 800, 8, 8)
	ke.window.name = "KEYMAP"
	ke.window.element.message_user = keymap_editor_window_message
	ke.window.on_menu_close = proc(window: ^Window) {
		ke.menu = {}
	}
	ke.window.update = proc(window: ^Window) {
		// if grid, ok := ke.grid_keep_in_frame.?; ok {
		// 	bounds := grid.children[0].bounds
		// 	direction := ke.panel.vscrollbar.position > rect_heightf_halfed(bounds)
		// 	fmt.eprintln("direction", direction)
		// 	scrollbar_keep_in_frame(ke.panel.vscrollbar, bounds, direction)
		// 	ke.grid_keep_in_frame = nil
		// }

		// reset node pointers
		if ke.issue_update != nil {
			children := ke.issue_update.children
			keymap := cast(^Keymap) ke.issue_update.data

			// update combo lines and offsets
			index: int
			count: int
			for line, offset in static_grid_real_lines_iter(ke.issue_update, &index, &count) {
				keymap_editor_update_combo_data(line, &keymap.combos[offset])
				line.index = offset
			}

			window_repaint(ke.window)
			ke.issue_update = nil
		}
	}

	ke.panel = panel_init(
		&ke.window.element,
		{ .Panel_Default_Background, .Panel_Scroll_Vertical },
		5,
		5,
	)
	ke.panel.background_index = 0

	ke.grids[0] = keymap_editor_push_keymap(&app.window_main.keymap_box, "Box", true)
	ke.grids[1] = keymap_editor_push_keymap(&app.window_main.keymap_custom, "Todool", false)
	ke.grids[2] = keymap_editor_push_keymap(&app.keymap_vim_normal, "Vim Normal", true)
	ke.grids[3] = keymap_editor_push_keymap(&app.keymap_vim_insert, "Vim Insert", true)

	undo_manager_init(&ke.um, mem.Kilobyte * 2)

	keymap_push_box_commands(&ke.window.keymap_box)
	keymap_push_box_combos(&ke.window.keymap_box)
}

KE_Stealer :: struct {
	using element: Element,
	builder: strings.Builder,
}

ke_stealer_init :: proc(
	parent: ^Element,
	flags: Element_Flags,
	text: string,
) -> (res: ^KE_Stealer) {
	res = element_init(KE_Stealer, parent, flags, ke_stealer_message, context.allocator)  	
	res.builder = strings.builder_make(0, 64, context.allocator)
	strings.write_string(&res.builder, text)
	return
}

ke_stealer_message :: proc(element: ^Element, msg: Message, di: int, dp: rawptr) -> int {
	stealer := cast(^KE_Stealer) element

	#partial switch msg {
		case .Paint_Recursive: {
			target := element.window.target
			// pressed := element.window.pressed == element
			// hovered := element.window.hovered == element
			focused := element.window.focused == element

			outline := focused ? theme.text_good : theme.text_default
			render_rect_outline(target, element.bounds, outline)

			fcs_element(element)
			fcs_ahv()
			text_color := theme.text_default
			fcs_color(text_color)
			text := strings.to_string(stealer.builder)
			render_string_rect(target, element.bounds, text)
		}

		case .Key_Combination: {
			combo := (cast(^string) dp)^
			b := &stealer.builder

			// cancel on double escape
			if combo == "escape" && strings.to_string(b^) == "escape" {
				dialog_close(element.window, .Cancel)
				return 1
			}

			strings.builder_reset(b)
			strings.write_string(b, combo)
			element_repaint(element)
			return 1
		}

		case .Get_Width: {
			fcs_element(element)
			text := strings.to_string(stealer.builder)
			width := max(int(50 * SCALE), string_width(text) + int(TEXT_MARGIN_HORIZONTAL * SCALE))
			return width
		}

		case .Get_Height: {
			return efont_size(element) + int(TEXT_MARGIN_VERTICAL * SCALE)
		}

		case .Get_Cursor: {
			return int(Cursor.Hand)
		}

		case .Clicked: {
			element_focus(element.window, element)
			element_repaint(element)
		}

		case .Destroy: {
			delete(stealer.builder.buf)
		}
	}

	return 0
}

// check wether the combo_node needs its conflict removed
keymap_editor_check_conflict_removal :: proc(keymap: ^Keymap, combo_node: ^Combo_Node, check: string, ignore_check: bool) {
	// check if last conflict can be resolved
	if combo_node.conflict != nil {
		conflict_check := combo_node.conflict
		
		// remove the current conflict if the new name differs
		if ignore_check || string(combo_node.conflict.combo[:combo_node.conflict.combo_index]) != check {
			combo_node.conflict = nil
		}

		// count and keep track of existing conflicts
		temp := make([dynamic]^Combo_Node, 0, 32, context.temp_allocator)
		count: int
		for node in &keymap.combos {
			if node.conflict == conflict_check {
				count += 1
				append(&temp, &node)
			}
		}

		// too few conflicts to keep existing
		if count == 1 {
			// reset saved nodes
			for node in temp {
				node.conflict = nil
			}

			dll.remove(&keymap.conflict_list, conflict_check)
		} else {
			conflict_check.count = u16(count)
		}
	}
}

keymap_editor_check_conflicts :: proc(keymap: ^Keymap, skip: ^Combo_Node, check: string) {
	keymap_editor_check_conflict_removal(keymap, skip, check, false)

	// check if conflict with the same name exists already
	{
		iter := dll.iterator_head(keymap.conflict_list, Combo_Conflict, "node")
		for node in dll.iterate_next(&iter) {
			c1 := string(node.combo[:node.combo_index])
			
			if c1 == check {
				skip.conflict = node
				node.count += 1
				return
			}
		}
	}

	// hook up nodes that dont have a conflict set yet
	conflict: ^Combo_Conflict
	for node in &keymap.combos {
		c1 := string(node.combo[:node.combo_index])

		if &node != skip && node.conflict == nil && c1 == check {
			if conflict == nil {
				conflict = new(Combo_Conflict)
			}

			node.conflict = conflict
		}
	}

	// properly set new data for this conflict
	if conflict != nil {
		skip.conflict = conflict
		mem.copy(&conflict.combo[0], raw_data(check), len(check))
		conflict.combo_index = u8(len(check))
		conflict.color = color_hsl_rand()
		conflict.count = 2
		dll.push_back(&keymap.conflict_list, conflict)
	}
}

KE_Button_Combo :: struct {
	using element: Element,
	node: ^Combo_Node,
}

KE_Button_Command :: struct {
	using element: Element,
	node: ^Combo_Node,
}

ke_button_combo_init :: proc(
	parent: ^Element, 
	flags: Element_Flags, 
	node: ^Combo_Node,
) -> (res: ^KE_Button_Combo) {
	res = element_init(KE_Button_Combo, parent, flags, ke_button_combo_message, context.allocator)
	res.node = node
	return
}

ke_button_command_init :: proc(
	parent: ^Element, 
	flags: Element_Flags, 
	node: ^Combo_Node,
) -> (res: ^KE_Button_Command) {
	res = element_init(KE_Button_Command, parent, flags, ke_button_command_message, context.allocator)
	res.node = node
	return	
}

// get text per mode
ke_button_combo_text :: proc(button: ^KE_Button_Combo) -> string {
	return string(button.node.combo[:button.node.combo_index])
}

// get text per mode
ke_button_command_text :: proc(button: ^KE_Button_Combo) -> string {
	return string(button.node.command[:button.node.command_index])
}

ke_button_command_message :: proc(element: ^Element, msg: Message, di: int, dp: rawptr) -> int {
	button := cast(^KE_Button_Combo) element

	#partial switch msg {
		case .Paint_Recursive: {
			target := element.window.target
			pressed := element.window.pressed == element
			hovered := element.window.hovered == element
			text_color := hovered || pressed ? theme.text_default : theme.text_blank

			keymap := cast(^Keymap) button.parent.parent.data
			text := ke_button_command_text(button)

			// find assigned color
			command, ok := keymap.commands[text]
			color := keymap.command_colors[command] or_else TRANSPARENT
			render_rect(target, rect_padding(element.bounds, rect_xxyy(LINE_WIDTH, 0)), color)

			if hovered || pressed {
				render_rect_outline(target, element.bounds, text_color)
				render_hovered_highlight(target, element.bounds)
			}

			fcs_element(button)
			fcs_ahv(.LEFT, .MIDDLE)
			fcs_color(text_color)

			// offset left words
			bounds := element.bounds
			bounds.l += int(TEXT_PADDING * SCALE)

			render_string_rect(target, bounds, text)
		}

		case .Update: {
			element_repaint(element)
		}

		case .Clicked: {
			keymap := cast(^Keymap) button.parent.parent.data
			keymap_editor_menu_command(keymap, button.node)
		}

		case .Get_Cursor: {
			return int(Cursor.Hand)
		}

		case .Get_Width: {
			fcs_element(element)
			text := ke_button_command_text(button)
			width := max(int(50 * SCALE), string_width(text) + int(TEXT_MARGIN_HORIZONTAL * SCALE))
			return int(width)
		}

		case .Get_Height: {
			return efont_size(element) + int(TEXT_MARGIN_VERTICAL * SCALE)
		}

		case .Key_Combination: {
			key_combination_check_click(element, dp)
		}

		case .Hover_Info: {
			keymap := cast(^Keymap) button.parent.parent.data
			c1 := string(button.node.command[:button.node.command_index])
			command, ok := keymap.commands[c1]

			if ok {
				comment, found := keymap_comments[command]

				if found {
					res := cast(^string) dp
					res^ = comment 
				}
			}
		}
	}

	return 0
}

ke_button_combo_message :: proc(element: ^Element, msg: Message, di: int, dp: rawptr) -> int {
	button := cast(^KE_Button_Combo) element

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

			fcs_element(button)

			// show conflicts
			if button.node.conflict != nil {
				color := button.node.conflict.color
				fcs_color(color)
				fcs_ahv(.LEFT, .MIDDLE)
				bounds := element.bounds
				bounds.l += int(TEXT_PADDING * SCALE)
				render_string_rect(target, bounds, fmt.tprintf("%dx", button.node.conflict.count))

				color.a = 100
				render_rect(target, element.bounds, color)
			}

			fcs_ahv(.RIGHT, .MIDDLE)
			fcs_color(text_color)
			text := ke_button_combo_text(button)
			bounds := element.bounds
			bounds.r -= int(TEXT_PADDING * SCALE)
			render_string_rect(target, bounds, text)
		}

		case .Update: {
			element_repaint(element)
		}

		case .Clicked: {
			ke.menu.line = cast(^Static_Line) button.parent
			combo_name := string(button.node.combo[:button.node.combo_index])

			dialog_spawn(
				ke.window,
				proc(dialog: ^Dialog, result: string) {
					if dialog.result == .Default {
						keymap := cast(^Keymap) ke.menu.line.parent.data
						node := &keymap.combos[ke.menu.line.index]

						mem.copy(&node.combo[0], raw_data(result), len(result))
						node.combo_index = u8(len(result))
						keymap_editor_check_conflicts(keymap, node, result)
					}

					ke.menu.line = nil
				},
				300,
				"Press a Key Combination\n%x\n%B%C",
				combo_name,
				"Accept",
				"Cancel",
			)
		}

		case .Get_Cursor: {
			return int(Cursor.Hand)
		}

		case .Get_Width: {
			fcs_element(element)
			text := ke_button_combo_text(button)
			width := max(int(50 * SCALE), string_width(text) + int(TEXT_MARGIN_HORIZONTAL * SCALE))
			return int(width)
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

// NOTE this has to be the same as the init code
keymap_editor_update_combo_data :: proc(line: ^Static_Line, combo: ^Combo_Node) {
	b1 := cast(^KE_Button_Combo) line.children[0]
	b1.node = combo
	b2 := cast(^KE_Button_Command) line.children[1]
	b2.node = combo
	b3 := cast(^Button) line.children[2]
	strings.builder_reset(&b3.builder)
	fmt.sbprintf(&b3.builder, "0x%2x", combo.du)
	// b4 := cast(^Button) line.children[3]
}

keymap_editor_remove_call :: proc(line: ^Static_Line) {
	grid := cast(^Static_Grid) line.parent
	keymap := cast(^Keymap) grid.data

	if line.index != -1 && len(keymap.combos) != 0 {
		node := &keymap.combos[line.index]
		keymap_editor_check_conflict_removal(keymap, node, "", true)

		ordered_remove(&keymap.combos, line.index)
		ke.issue_update = grid
		element_repaint(line)
		element_destroy(line)
	} 
}

keymap_editor_static_line_message :: proc(element: ^Element, msg: Message, di: int, dp: rawptr) -> int {
	sl := cast(^Static_Line) element

	#partial switch msg {
		case .Paint_Recursive: {
			target := element.window.target

			// highlight second lines
			if sl.index % 2 == 1 {
				render_hovered_highlight(target, element.bounds)
			}

			if ke.menu.line == sl {
				render_rect_outline(target, element.bounds, theme.text_good)
			}
		}

		case .Right_Down: {
			keymap_editor_menu_combo(sl)
			return 1
		}
	}

	return 0
}

keymap_editor_static_grid_message :: proc(element: ^Element, msg: Message, di: int, dp: rawptr) -> int {
	grid := cast(^Static_Grid) element

	if msg == .Paint_Recursive {
		target := element.window.target
		shadow := theme_shadow()
		render_rect_outline(target, element.bounds, shadow, ROUNDNESS)

		height := element_message(element, .Get_Height)
		r := rect_wh(
			element.bounds.l - LINE_WIDTH / 2, 
			element.bounds.t + LINE_WIDTH + grid.cell_height, 
			LINE_WIDTH, 
			height - LINE_WIDTH * 2,
		)

		for size in grid.cell_sizes {
			render_rect(target, r, shadow)
			r.l += size
			r.r = r.l + LINE_WIDTH
		}

		// only draw the top cell
		if grid.hide_cells != nil && grid.hide_cells^ {
			assert(len(element.children) > 0)
			element_message(element.children[0], msg, di, dp)
		}  else {
			for child in element.children {
				render_element_clipped(target, child)
			}
	
			keymap := cast(^Keymap) grid.data

			// when non hidden, draw collision lines
			if !dll.is_empty(&keymap.conflict_list) {
				render_push_clip(target, ke.window.element.bounds)
				iter := dll.iterator_head(keymap.conflict_list, Combo_Conflict, "node") 
				width := int(14 * SCALE)
				gap := int(4 * SCALE)
				offset := width + gap

				for node in dll.iterate_next(&iter) {
					bounds := element.bounds
					bounds.l -= offset
					bounds.r = element.bounds.l - gap
					sum := RECT_INF

					// run through nodes, draw connections to nodes
					{
						index: int
						count: int
						for line, offset in static_grid_real_lines_iter(grid, &index, &count) {
							combo_node := &keymap.combos[offset]
							
							if node == combo_node.conflict {
								r := bounds
								r.t = line.bounds.t + rect_height_halfed(line.bounds)
								r.b = r.t + LINE_WIDTH 
								render_rect(target, r, node.color)
								rect_inf_push(&sum, r)
							}
						}
					}

					// thin line
					{
						r := sum
						r.r = r.l + LINE_WIDTH
						render_rect(target, r, node.color)
					}

					offset += width + gap
				}
			}
		}

		return 1
	}

	return 0
}

keymap_editor_push_keymap :: proc(keymap: ^Keymap, header: string, folded: bool) -> (grid: ^Static_Grid) {
	reserve(&keymap.command_colors, len(keymap.commands))
	clear(&keymap.command_colors)
	for key, value in keymap.commands {
		keymap.command_colors[value] = color_hsl_golden_rand(nil, 0.5, 1)
	}

	cell_sizes := [?]int { 250, 200, 100 }
	grid = static_grid_init(ke.panel, {}, cell_sizes[:], DEFAULT_FONT_SIZE + TEXT_MARGIN_VERTICAL)
	grid.data = keymap
	grid.message_user = keymap_editor_static_grid_message

	// fold cell with cell setting
	fold := button_fold_init(grid, {}, header, folded)
	grid.hide_cells = &fold.state

	// line description
	{
		p := static_line_init(grid, &grid.cell_sizes, -1)
		label_init(p, { .Label_Center }, "Combination")
		label_init(p, { .Label_Center }, "Command")
		label_init(p, { .Label_Center }, "Modifiers")
	}

	line_count: int
	for node in &keymap.combos {
		keymap_editor_line_append(grid, &node, line_count)
		line_count += 1
	}

	return
}

keymap_editor_line_append :: proc(
	grid: ^Static_Grid, 
	node: ^Combo_Node,
	line_count: int,
	) {
	p := static_line_init(grid, &grid.cell_sizes, line_count)
	p.message_user = keymap_editor_static_line_message

	// c1 := strings.string_from_ptr(&node.combo[0], int(node.combo_index))
	b1 := ke_button_combo_init(p, {}, node)
	b2 := ke_button_command_init(p, {}, node)

	b3 := button_init(p, {}, "")

	if node != nil {
		fmt.sbprintf(&b3.builder, "0x%2x", node.du)  	
	}
}

KE_Command :: struct {
	using element: Element,
	index: int,
	text: string,
	is_current: bool,
}

ke_command_init :: proc(
	parent: ^Element, 
	index: int, 
	text: string,
	is_current: bool,
) -> (res: ^KE_Command) {
	res = element_init(KE_Command, parent, {}, ke_command_message, context.allocator)
	res.index = index
	res.text = text
	res.is_current = is_current
	return
}

ke_command_build :: proc(cmd: ^KE_Command) {
	assert(ke.menu.combo != nil)
	assert(cmd != nil)
	n := ke.menu.combo

	index := min(len(n.command), len(cmd.text))
	mem.copy(&n.command[0], raw_data(cmd.text), index)
	n.command_index = u8(index)

	menu_close(cmd.window)
}

ke_command_message :: proc(element: ^Element, msg: Message, di: int, dp: rawptr) -> int {
	cmd := cast(^KE_Command) element

	#partial switch msg {
		case .Paint_Recursive: {
			target := element.window.target
			pressed := element.window.pressed == element
			hovered := element.window.hovered == element
			
			builder := strings.builder_make(0, 64, context.temp_allocator)
			strings.write_int(&builder, cmd.index)
			strings.write_string(&builder, ". ")
			strings.write_string(&builder, cmd.text)

			// find assigned color
			command, ok := ke.menu.keymap.commands[cmd.text]
			color := ke.menu.keymap.command_colors[command] or_else TRANSPARENT
			render_rect(target, rect_margin(element.bounds, 1), color)

			if hovered || pressed {
				render_rect_outline(target, element.bounds, theme.text_default)
				render_hovered_highlight(target, element.bounds)
			}

			bounds := element.bounds
			bounds.l += int(TEXT_PADDING * SCALE)

			fcs_element(element)
			fcs_ahv(.LEFT, .MIDDLE)
			color = cmd.is_current ? theme.text_good : theme.text_default
			fcs_color(color)
			render_string_rect(target, bounds, strings.to_string(builder))
		}

		case .Update: {
			element_repaint(element)
		}

		// set combo command name
		case .Clicked: {
			ke_command_build(cmd)
		}

		case .Get_Height: {
			return efont_size(element) + int(TEXT_MARGIN_VERTICAL * SCALE)
		}

		case .Get_Cursor: {
			return int(Cursor.Hand)
		}

		// case .Hover_Info: {
		// 	command, ok := ke.menu.keymap.commands[cmd.text]
		// 	assert(ok)
		// 	comment, found := keymap_comments[command]

		// 	if found {
		// 		res := cast(^string) dp
		// 		res^ = comment 
		// 	}
		// }
	}

	return 0
}

keymap_editor_menu_command :: proc(
	keymap: ^Keymap,
	combo: ^Combo_Node,
) {
	menu_close(ke.window)

	menu := menu_init(ke.window, { .Panel_Expand }, -1, true)
	defer menu_show_position(menu)
	menu.x = ke.window.cursor_x
	menu.y = ke.window.cursor_y
	menu.width = 250
	menu.height = 300
	p := menu.panel
	p.background_index = 1
	p.gap = 5
	
	ke.menu.combo = combo
	offset: int
	is_current: bool
	c1 := string(combo.command[:combo.command_index])

	ke.menu.keymap = keymap
	ke.menu.box = text_box_init(p, { .HF })
	ke.menu.box.um = &ke.um
	ke.menu.box.message_user = proc(element: ^Element, msg: Message, di: int, dp: rawptr) -> int {
		box := cast(^Text_Box) element
		
		if msg == .Value_Changed {
			pattern := ss_string(&box.ss)
			children := panel_children(ke.menu.sub)
			
			if pattern == "" {
				// unhide all children
				for child in children {
					element_hide(child, false)
				}
			} else {
				// hide all children that arent fuzzd
				for child in children {
					if child.message_class == ke_command_message {
						cmd := cast(^KE_Command) child
						res, ok := fuzz.match(cmd.text, pattern)
						hide := res.score > 10 && ok
						element_hide(cmd, !hide)
					}
				}
			}

			element_repaint(element)
		}

		return 0
	}
	undo_manager_reset(&ke.um)
	element_focus(ke.window, ke.menu.box)

	ke.menu.sub = panel_init(p, { .HF, .VF, .Panel_Expand, .Panel_Scroll_Vertical, .Panel_Default_Background }, 5)
	ke.menu.sub.background_index = 2

	for key, value in keymap.commands {
		is_current = key == c1
		ke_command_init(ke.menu.sub, offset, key, is_current)
		offset += 1
	}

	window_repaint(ke.window)
}

keymap_editor_menu_combo :: proc(line: ^Static_Line) {
	menu := menu_init(ke.window, {}, 0)
	defer menu_show(menu)

	p := menu.panel
	p.shadow = true
	p.flags |= { .Panel_Expand }

	ke.menu.line = line

	mbc(p, "Add", proc() {
		grid := cast(^Static_Grid) ke.menu.line.parent
		keymap := cast(^Keymap) grid.data
		
		index := ke.menu.line.index + 1
		inject_at(&keymap.combos, index, Combo_Node {})

		keymap_editor_line_append(grid, nil, 0)
		ke.issue_update = grid
		menu_close(ke.window)
	}, .Plus)
	mbc(p, "Remove", proc() {
		keymap_editor_remove_call(ke.menu.line)
		menu_close(ke.window)
	}, .Close)
}