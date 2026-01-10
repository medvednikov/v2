module main

import os
import v2.parser
import v2.token
import v2.pref
import ssa
import backend

fn main() {
	println('--- V Compiler Pipeline ---')

	// 1. Setup Parser
	prefs := &pref.Preferences{}
	mut file_set := token.FileSet.new()
	mut p := parser.Parser.new(prefs)

	// 2. Parse File
	input_file := 'test.v'
	if !os.exists(input_file) {
		eprintln('Error: ${input_file} not found')
		return
	}

	println('[*] Parsing ${input_file}...')
	// This uses the parser code you submitted in prompt 1
	file := p.parse_file(input_file, mut file_set)

	if file.stmts.len == 0 {
		println('Warning: No statements found in ${input_file}')
	}

	// 3. Initialize SSA Module
	mut mod := ssa.Module.new('main')

	// 4. Build SSA from AST
	println('[*] Building SSA...')
	mut builder := ssa.Builder.new(mod)
	builder.build(file)

	// 5. Generate C Code
	println('[*] Generating C Backend...')
	mut c_gen := backend.CGen.new(mod)
	c_source := c_gen.gen()

	os.write_file('out.c', c_source) or { panic(err) }
	println('[*] Done. Wrote out.c')

	println('\n--- Generated C Code ---\n')
	println(c_source)
}
