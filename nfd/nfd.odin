package nfd

// import "core:c"

// // when ODIN_OS == .Windows { foreign import stbtt "../lib/stb_truetype.lib" }
// when ODIN_OS == .Linux { 
// 	foreign import lib { "libnfd.a", "system:gtk-3", "system:gobject-2.0", "system:glib-2.0" }
// }
// // when ODIN_OS == .Darwin  { foreign import stbtt "../lib/stb_truetype.a"   }

// Result :: enum c.int {
// 	ERROR,
// 	OKAY,
// 	CANCEL,
// }

// // opaque data structure -- see PathSet_*
// Path_Set :: struct {
// 	buffer: [^]u8,
// 	indices: [^]c.size_t,
// 	count: c.size_t,
// }

// @(default_calling_convention="c", link_prefix="NFD_")
// foreign lib {
// 	OpenDialog :: proc(
// 		filter_list: cstring, 
// 		default_path: cstring,
// 		out_path: ^cstring,
// 	) -> Result ---

// 	OpenDialogMultiple :: proc(
// 		filter_list: cstring, 
// 		default_path: cstring,
// 		out_path: ^cstring,
// 	) -> Result ---

// 	SaveDialog :: proc(
// 		filter_list: cstring, 
// 		default_path: cstring,
// 		out_path: ^cstring,
// 	) -> Result ---

// 	PickFolder :: proc(
// 		default_path: cstring,
// 		out_path: ^cstring,
// 	) -> Result ---

// 	GetError :: proc() -> cstring ---
// 	PathSet_GetCount :: proc(path_set: ^Path_Set) -> c.size_t ---
// 	PathSet_GetPath :: proc(path_set: ^Path_Set, index: c.size_t) -> cstring ---
// 	PathSet_Free :: proc(path_set: ^Path_Set) ---
// }