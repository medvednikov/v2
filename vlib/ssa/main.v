module main

import os
import v2.parser
import v2.token
import v2.pref
import ssa
import backend
import time

fn main() {
	println('--- V Compiler Pipeline ---')

	// 1. Setup Parser
	t0 := time.now()
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

	native := true

	if native {
		// 5. Generate Mach-O Object
		println('[*] Generating Mach-O ARM64 Object...')
		mut arm_gen := backend.Arm64Gen.new(mod)
		arm_gen.gen()
		arm_gen.write_file('main.o')

		println('generating main.o took ${time.since(t0)}')
		// 6. Link
		println('[*] Linking...')
		// Need SDK path
		sdk_res := os.execute('xcrun -sdk macosx --show-sdk-path')
		sdk_path := sdk_res.output.trim_space()

		// Link command
		// -lSystem links standard libc (printf)
		t := time.now()
		link_cmd := 'ld -o out_bin main.o -lSystem -syslibroot "${sdk_path}" -e _main -arch arm64 -platform_version macos 11.0.0 11.0.0'
		if os.system(link_cmd) != 0 {
			eprintln('Link failed')
			return
		}
		println('linking took ${time.since(t)}')
	} else {
		// 5. Generate C Code
		println('[*] Generating C Backend...')
		mut c_gen := backend.CGen.new(mod)
		c_source := c_gen.gen()

		os.write_file('out.c', c_source) or { panic(err) }
		println('[*] Done. Wrote out.c')

		// 6. Compile C Code
		println('[*] Compiling out.c...')
		// -w suppresses the return-type warnings if the fix wasn't perfect,
		// though we fixed the builder to generate return 0.
		cc_res := os.system('cc out.c -o out_bin -w')
		if cc_res != 0 {
			eprintln('Error: C compilation failed with code ${cc_res}')
			return
		}
	}

	// 7. Run Reference (v run test.v)
	println('[*] Running reference: v -enable-globals run ${input_file}...')
	ref_res := os.execute('v -n -enable-globals run ${input_file}')
	if ref_res.exit_code != 0 {
		eprintln('Error: Reference run failed')
		eprintln(ref_res.output)
		return
	}
	// Normalize newlines
	expected_out := ref_res.output.trim_space().replace('\r\n', '\n')

	// 8. Run Generated Binary
	println('[*] Running generated binary (with 2s timeout)...')

	// Prepare command with timeout
	// On macOS/Linux, use perl as a portable timeout mechanism since 'timeout' isn't always available on macOS
	mut cmd := "perl -e 'alarm 2; exec @ARGV' ./out_bin"
	if os.user_os() == 'windows' {
		// No easy one-liner for timeout on Windows cmd without PowerShell, running directly
		cmd = 'out_bin.exe'
	}

	gen_res := os.execute(cmd)

	// Perl alarm usually kills with SIGALRM (14), exit code might vary (e.g. 142)
	// If it was killed by signal, we assume timeout.
	if gen_res.exit_code != 0 {
		// Check for timeout symptoms
		// Standard SIGALRM is 14. Bash reports 128+14=142.
		if gen_res.exit_code == 142 || gen_res.exit_code == 14 {
			eprintln('Error: Execution timed out (infinite loop detected)')
			return
		}
		// It might just be a crash or non-zero return (our main returns 0 usually)
		if gen_res.exit_code != 0 {
			// In the current builder, main returns 0. If it returns something else, it might be an error.
			// However, perl exec propagation might change codes.
			// Let's proceed to compare output, but warn.
			println('Warning: Binary exited with code ${gen_res.exit_code}')
		}
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
