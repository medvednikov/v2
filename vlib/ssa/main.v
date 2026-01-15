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

	// 6. Compile C Code
	println('[*] Compiling out.c...')
	if os.system('cc out.c -o out_bin') != 0 {
		eprintln('Error: C compilation failed')
		return
	}

	// 7. Run Reference (v run test.v)
	println('[*] Running reference: v run ${input_file}...')
	ref_res := os.execute('v -enable-globals run ${input_file}')
	if ref_res.exit_code != 0 {
		eprintln('Error: Reference run failed')
		eprintln(ref_res.output)
		return
	}
	expected_out := ref_res.output.trim_space().replace('\r\n', '\n')

	// 8. Run Generated Binary
	println('[*] Running generated binary (with 2s timeout)...')
	// Using timeout command (available on Linux/macOS) to prevent hanging on infinite loops
	gen_res := os.execute('timeout 2s ./out_bin')

	if gen_res.exit_code == 124 {
		eprintln('Error: Execution timed out (possible infinite loop)')
		return
	}
	if gen_res.exit_code != 0 {
		eprintln('Error: Binary execution failed (code ${gen_res.exit_code})')
		eprintln(gen_res.output)
		return
	}

	actual_out := gen_res.output.trim_space().replace('\r\n', '\n')

	// 9. Compare
	if expected_out == actual_out {
		println('\n[SUCCESS] Outputs match!')
	} else {
		println('\n[FAILURE] Outputs differ')
		println('--- Expected ---')
		println(expected_out)
		println('--- Actual ---')
		println(actual_out)
		println('----------------')
	}
}
