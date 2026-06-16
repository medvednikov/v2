module main

import os
import v3.bench
import v3.gen.arm64
import v3.gen.c as cgen
import v3.insel
import v3.markused
import v3.mir
import v3.parser
import v3.pref
import v3.ssa
import v3.ssa.optimize
import v3.transform

fn main() {
	args := os.args[1..]
	if args.len == 0 {
		eprintln('usage: v3 <file.v> [-o output] [-b c|arm64]')
		exit(1)
	}

	mut input_file := ''
	mut output_file := ''
	mut backend := 'c'
	mut is_prod := false
	mut i := 0
	for i < args.len {
		if args[i] == '-o' && i + 1 < args.len {
			output_file = args[i + 1]
			i += 2
		} else if args[i] == '-b' && i + 1 < args.len {
			backend = args[i + 1]
			i += 2
		} else if args[i] == '-prod' {
			is_prod = true
			i++
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

	// Parse directly to flat AST
	prefs := pref.new_preferences()
	mut p := parser.FlatParser.new(prefs)

	builtin_path := os.join_path(os.dir(@FILE), 'builtins', 'builtin.v')

	mut files := []string{}
	if backend == 'arm64' {
		if os.exists(builtin_path) {
			files << builtin_path
		}
	}
	files << input_file

	mut a := p.parse_files(files)
	b.step('parse')

	// Transform (match lowering etc.)
	transform.transform(mut a)
	b.step('transform')

	// Mark used functions (dead-code elimination)
	used_fns := markused.mark_used(a)
	b.step('markused')

	if backend == 'arm64' {
		// SSA + ARM64 native backend
		mut m := ssa.build_with_used(a, used_fns)
		b.step('ssa build')

		if is_prod {
			optimize.optimize(mut m)
			b.step('optimize')

			mir_mod := mir.lower_from_ssa(m)
			b.step('mir')

			mut mir_m := mir_mod
			insel.select_(mut mir_m)
			b.step('insel')
		}

		mut g := arm64.Gen.new(m)
		g.gen()
		b.step('arm64 gen')

		g.write_and_link(bin_file)
		b.step('link')
	} else {
		// C backend (default)
		mut g := cgen.FlatGen.new()
		c_code := g.gen_with_used(a, used_fns)
		b.step('gen C')

		os.write_file(output_file, c_code) or {
			eprintln('error writing ${output_file}: ${err}')
			exit(1)
		}
		b.step('write')

		opt_flag := if is_prod { '-O2 ' } else { '' }
		cc_cmd := 'cc -std=gnu11 ${opt_flag}-w -o ${bin_file} ${output_file} -lm'
		result := os.execute(cc_cmd)
		if result.exit_code != 0 {
			eprintln('C compilation failed:')
			eprintln(result.output)
			exit(1)
		}
		b.step('cc')
	}

	b.print_report()
}
