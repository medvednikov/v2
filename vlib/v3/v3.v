module main

import os
import v3.bench
import v3.flat
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
import v3.types

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
	mut is_strict := false
	mut no_parallel := false
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
		} else if args[i] == '-selfhost' {
			i++
		} else if args[i] == '-strict' {
			is_strict = true
			i++
		} else if args[i] == '-no-parallel' || args[i] == '--no-parallel' {
			no_parallel = true
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
	println('=== v3 benchmark ===')

	// Parse directly to flat AST
	mut prefs := pref.new_preferences()
	prefs.backend = backend
	mut p := parser.Parser.new(prefs)

	mut files := []string{}
	builtin_dir := os.join_path(prefs.vroot, 'vlib', 'builtin')
	files << pref.get_v_files_from_dir(builtin_dir, prefs.user_defines, prefs.target_os)
	mut a := p.parse_files(files)
	a.user_code_start = a.nodes.len

	// Parse user input: single file or directory
	mut user_files := []string{}
	if os.is_dir(input_file) {
		user_files = pref.get_v_files_from_dir(input_file, prefs.user_defines, prefs.target_os)
	} else {
		user_files << input_file
	}
	for uf in user_files {
		p.parse_into(uf)
	}

	// Resolve imports recursively
	resolve_imports(mut a, mut p, prefs, user_files)

	b.step('parse')

	// Type-collect + annotate expression types BEFORE transform, so the
	// transformer is type-aware (like v2: check runs before transform). The
	// transformer reads per-expression types to own type-dependent lowering.
	mut pre_tc := types.TypeChecker.new(a)
	pre_tc.collect(a)
	pre_tc.annotate_types()
	pre_tc.diagnose_unknown_calls = true
	for uf in user_files {
		pre_tc.diagnostic_files[uf] = true
	}
	pre_tc.check_semantics()
	if pre_tc.errors.len > 0 {
		print_type_errors(pre_tc.errors)
		exit(1)
	}

	// Transform (match lowering, string/in lowering, etc.)
	transform.transform(mut a, &pre_tc)
	b.step('transform')

	// Type check — shared phase before backend selection
	mut tc := types.TypeChecker.new(a)
	tc.collect(a)
	tc.annotate_types()
	tc.reject_unlowered_map_mutation = true
	for uf in user_files {
		tc.diagnostic_files[uf] = true
	}
	b.step('check')

	tc.check_semantics()
	if tc.errors.len > 0 {
		print_type_errors(tc.errors)
		exit(1)
	}

	// Mark used functions (dead-code elimination)
	used_fns := markused.mark_used(a, tc)
	b.step('markused')

	if backend == 'arm64' {
		// SSA + ARM64 native backend
		mut m := ssa.build_with_used(a, used_fns, tc)
		b.step('ssa build')

		if is_prod {
			optimize.optimize(mut m)
			b.step('optimize')
		}

		mut mir_mod := mir.lower_from_ssa_for_target(m, mir.arm64_target())
		b.step('mir')

		selected := insel.select_(mut mir_mod)
		_ = selected
		b.step('insel')

		mut g := arm64.Gen.new(m)
		g.gen()
		b.step('arm64 gen')

		g.write_and_link(bin_file)
		b.step('link')
	} else {
		// C backend (default)
		mut g := cgen.FlatGen.new()
		c_code := g.gen_with_used_options(a, used_fns, tc, no_parallel)
		b.step('gen C')

		os.write_file(output_file, c_code) or {
			eprintln('error writing ${output_file}: ${err}')
			exit(1)
		}
		b.step('write')

		opt_flag := if is_prod { '-O2 ' } else { '' }
		warn_flags := if is_strict {
			'-Wall -Wextra -Werror=implicit-function-declaration -Wno-unused-variable -Wno-unused-parameter -Wno-int-conversion -Wno-missing-braces'
		} else {
			'-w'
		}
		mut cc_cmd := ''
		mut result := os.Result{}
		if !is_prod {
			tcc_dir := os.join_path(os.home_dir(), 'code', 'v', 'thirdparty', 'tcc')
			tcc_path := os.join_path(tcc_dir, 'tcc.exe')
			tcc_includes := '-I${os.join_path(tcc_dir, 'lib', 'include')}'
			tcc_lib := '-L${os.join_path(tcc_dir, 'lib')}'
			cc_cmd = '${tcc_path} ${tcc_includes} ${tcc_lib} ${warn_flags} -o ${bin_file} ${output_file} -lm'
			println('  > ${cc_cmd}')
			result = os.execute(cc_cmd)
		}
		if is_prod || result.exit_code != 0 {
			if result.exit_code != 0 && result.output.len > 0 {
				eprintln('  tcc error: ${result.output.trim_space()}')
			}
			cc_cmd = 'cc -std=gnu11 ${opt_flag}${warn_flags} -Wno-int-conversion -Wl,-stack_size,0x4000000 -o ${bin_file} ${output_file} -lm'
			println('  > ${cc_cmd}')
			result = os.execute(cc_cmd)
			if result.exit_code != 0 {
				eprintln('C compilation failed:')
				eprintln(result.output)
				exit(1)
			}
		}
		b.step('cc')
	}

	b.print_report()
}

fn print_type_errors(errors []types.TypeError) {
	eprintln('type checker found ${errors.len} error(s):')
	max_errors := if errors.len < 20 { errors.len } else { 20 }
	for ei in 0 .. max_errors {
		eprintln('  ${errors[ei].msg}')
	}
	if errors.len > 20 {
		eprintln('  ... and ${errors.len - 20} more')
	}
}

fn resolve_imports(mut a flat.FlatAst, mut p parser.Parser, prefs &pref.Preferences, initial_files []string) {
	mut parsed_modules := map[string]bool{}
	parsed_modules['builtin'] = true
	parsed_modules['main'] = true

	mut first_file := ''
	if initial_files.len > 0 {
		first_file = initial_files[0]
	}

	mut changed := true
	for changed {
		changed = false
		mut cur_file := first_file
		for node in a.nodes {
			if node.kind == .file && node.value.len > 0 {
				cur_file = node.value
				continue
			}
			if node.kind != .import_decl {
				continue
			}
			mod_name := node.value
			if mod_name in parsed_modules {
				continue
			}
			parsed_modules[mod_name] = true
			changed = true

			importing_file := if cur_file.len > 0 { cur_file } else { first_file }
			mod_dir := prefs.get_module_path(mod_name, importing_file)
			if mod_dir == '' || !os.is_dir(mod_dir) {
				continue
			}
			mod_files := pref.get_v_files_from_dir(mod_dir, prefs.user_defines, prefs.target_os)
			for mf in mod_files {
				p.parse_into(mf)
			}
		}
	}
}
