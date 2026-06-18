import os

const vexe = @VEXE
const tests_dir = os.dir(@FILE)
const v3_dir = os.dir(tests_dir)
const v3_src = os.join_path(v3_dir, 'v3.v')

fn build_v3() string {
	v3_bin := os.join_path(os.temp_dir(), 'v3_type_checker_errors_test')
	build := os.execute('${vexe} -o ${v3_bin} ${v3_src}')
	assert build.exit_code == 0
	return v3_bin
}

fn run_bad(v3_bin string, name string, src string, expected string) {
	bad_src := os.join_path(os.temp_dir(), 'v3_${name}.v')
	os.write_file(bad_src, src) or { panic(err) }
	bad_bin := os.join_path(os.temp_dir(), 'v3_${name}')
	result := os.execute('${v3_bin} ${bad_src} -b c -o ${bad_bin}')
	assert result.exit_code != 0
	assert result.output.contains(expected)
	assert !result.output.contains('C compilation failed')
}

fn test_type_checker_reports_core_semantic_errors() {
	v3_bin := build_v3()
	run_bad(v3_bin, 'bad_assignment', "fn main() {\n\tmut x := 1\n\tx = 'bad'\n}\n",
		'cannot assign `string` to `int`')
	run_bad(v3_bin, 'bad_return', "fn f() int {\n\treturn 'bad'\n}\nfn main() {}\n",
		'cannot return `string` as `int`')
	run_bad(v3_bin, 'bad_call_arg', "fn takes_int(x int) {}\nfn main() {\n\ttakes_int('bad')\n}\n",
		'cannot use `string` as argument 1 to `takes_int`; expected `int`')
	run_bad(v3_bin, 'bad_field',
		'struct Foo {\n\tx int\n}\nfn main() {\n\tf := Foo{}\n\t_ := f.y\n}\n',
		'unknown field `y` on `Foo`')
	run_bad(v3_bin, 'bad_index', 'fn main() {\n\tx := 1\n\t_ := x[0]\n}\n', 'cannot index `int`')
	run_bad(v3_bin, 'bad_condition', "fn main() {\n\tif 'bad' {}\n}\n",
		'if condition must be `bool`, not `string`')
}
