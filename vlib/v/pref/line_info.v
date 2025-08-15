// Copyright (c) 2019-2024 Alexander Medvednikov. All rights reserved.
// Use of this source code is governed by an MIT license that can be found in the LICENSE file.
module pref

fn (mut p Preferences) parse_line_info(line string) {
	// println("parse_line_info '${line}'")
	format_err := 'wrong format, use `-line-info "file.v:24:7"'
	vals := line.split(':')
	if vals.len != 3 {
		eprintln(format_err)
		return
	}
	file_name := vals[0]
	line_nr := vals[1].int() - 1

	if !file_name.ends_with('.v') || line_nr == -1 {
		eprintln(format_err)
		return
	}

	// Third value can be a column or expression for autocomplete like `os.create()`
	third := vals[2]
	if third[0].is_digit() {
		col := vals[2].int() - 1
		p.linfo = LineInfo{
			line_nr: line_nr
			path:    file_name
			col:     col
		}
	} else {
		expr := vals[2]
		p.linfo = LineInfo{
			line_nr: line_nr
			path:    file_name
			expr:    expr
		}
	}
}
