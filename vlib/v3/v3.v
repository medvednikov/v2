module main

import os
import v3.bench
import v3.flat
import v3.gen.c as cgen
import v3.parser
import v3.pref
import v3.token

fn main() {
	args := os.args[1..]
	if args.len == 0 {
		eprintln('usage: v3 <file.v> [-o output]')
		exit(1)
	}

	mut input_file := ''
	mut output_file := ''
	mut i := 0
	for i < args.len {
		if args[i] == '-o' && i + 1 < args.len {
			output_file = args[i + 1]
			i += 2
		} else {
			input_file = args[i]
			i++
		}
	}

	if input_file == '' {
		eprintln('no input file')
		exit(1)
	}

	mut bin_file := ''
	if output_file == '' {
		bin_file = input_file.all_before_last('.v')
		output_file = bin_file + '.c'
	} else {
		bin_file = output_file
		output_file = bin_file + '.c'
	}

	mut b := bench.new()

	// Parse
	prefs := pref.new_preferences()
	mut p := parser.Parser.new(prefs)
	mut file_set := token.FileSet.new()
	files := p.parse_files([input_file], mut file_set)
	b.step('parse')

	// Flatten AST
	a := flat.flatten(files)
	b.step('flatten')

	// Generate C
	mut g := cgen.FlatGen.new()
	c_code := g.gen(&a)
	b.step('gen C')

	// Write C file
	os.write_file(output_file, c_code) or {
		eprintln('error writing ${output_file}: ${err}')
		exit(1)
	}
	b.step('write')

	// Compile C
	cc_cmd := 'cc -std=gnu11 -w -o ${bin_file} ${output_file} -lm'
	result := os.execute(cc_cmd)
	if result.exit_code != 0 {
		eprintln('C compilation failed:')
		eprintln(result.output)
		exit(1)
	}
	b.step('cc')

	b.print_report()
}
