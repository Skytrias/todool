package notify

import "core:c"

when ODIN_OS == .Linux { 
	foreign import lib { "system:notify" }
}

Notify_Notification :: struct {
	data: rawptr,
}

@(default_calling_convention="c", link_prefix="notify_")
foreign lib {
	init :: proc(app_name: cstring) -> c.bool ---
	uninit :: proc() ---
	notification_new :: proc(title, sub, icon: cstring) -> ^Notify_Notification ---
	notification_show :: proc(not: ^Notify_Notification, data: rawptr) -> c.bool ---
	notification_close :: proc(not: ^Notify_Notification, data: rawptr) -> c.bool ---
}

run :: proc(
	title: cstring,
	sub: cstring,
	icon: cstring,
) -> c.bool {
	not := notification_new(title, sub, icon)
	return notification_show(not, nil)
}