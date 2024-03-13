package tfd

import "core:c"

when ODIN_OS == .Windows { 
	foreign import lib { "main.lib", "system:user32.lib", "system:ole32.lib", "system:Comdlg32.lib", "system:shell32.lib" }
}
when ODIN_OS == .Linux || ODIN_OS == .Darwin { 
	foreign import lib { "main.a" }
}

@(default_calling_convention="c", link_prefix="tinyfd_")
foreign lib {
	saveFileDialog :: proc(
		title: cstring, // nil or ""
		defaultPathAndFile: cstring, // nil or ""
		numOfFilterPatterns: c.int,
		filterPatterns: [^]cstring, 
		singleFilterDescription: cstring, // nil or "text files"
	) -> cstring ---

	openFileDialog :: proc(
		title: cstring, // nil or ""
		defaultPathAndFile: cstring, // nil or ""
		numOfFilterPatterns: c.int,
		filterPatterns: [^]cstring,
		singleFilterDescription: cstring, // nil or "image files"
		allowMultipleSelects: c.int, // 0 / 1
			// in case of multiple files, the separator is |
			// returns NULL on cancel
	) -> cstring ---
}

save_file_dialog :: proc(
	title: cstring,
	default_path_and_file: cstring, 
	file_patterns: []cstring, 
	single_filter_description: cstring = "",
) -> cstring {
	return saveFileDialog(title, default_path_and_file, i32(len(file_patterns)), auto_cast raw_data(file_patterns), single_filter_description)
}

open_file_dialog :: proc(
	title: cstring,
	default_path_and_file: cstring, 
	file_patterns: []cstring, 
	single_filter_description: cstring = "",
	allow_multiple_selectss: bool = false,
) -> cstring {
	return openFileDialog(
		title, 
		default_path_and_file, 
		i32(len(file_patterns)), 
		auto_cast raw_data(file_patterns), 
		single_filter_description, 
		i32(allow_multiple_selectss),
	)
}
