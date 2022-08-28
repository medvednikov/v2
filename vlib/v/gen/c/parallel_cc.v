module c

import os
import time
import sync
import v.util

fn (mut g Gen) parallel_cc(header string, res string, out_str string) {
	nr_cpus := util.nr_cpus
	println('len=$nr_cpus')
	out_h := header.replace_once('static char * v_typeof_interface_IError', 'char * v_typeof_interface_IError')
	os.write_file('out.h', out_h) or { panic(err) }
	// Write generated stuff in `g.out` before and after the `out_fn_start_pos` locations,
	// like the `int main()` to "out_0.c" and "out_x.c"
	out0 := out_str[..g.out_fn_start_pos[0]].replace_once('static char * v_typeof_interface_IError',
		'char * v_typeof_interface_IError')
	os.write_file('out_0.c', '#include "out.h"\n' + out0) or { panic(err) }
	os.write_file('out_x.c', '#include "out.h"\n' + out_str[g.out_fn_start_pos.last()..]) or {
		panic(err)
	}

	mut prev_fn_pos := 0
	mut out_files := []os.File{len: nr_cpus}
	mut fnames := []string{}
	for i in 0 .. nr_cpus {
		fname := 'out_${i + 1}.c'
		fnames << fname
		out_files[i] = os.create(fname) or { panic(err) }
		out_files[i].writeln('#include "out.h"\n') or { panic(err) }
	}
	// g.out_fn_start_pos.sort()
	for i, fn_pos in g.out_fn_start_pos {
		if prev_fn_pos >= out_str.len || fn_pos >= out_str.len || prev_fn_pos > fn_pos {
			println('EXITING i=$i out of $g.out_fn_start_pos.len prev_pos=$prev_fn_pos fn_pos=$fn_pos')
			break
		}
		if i == 0 {
			// Skip typeof etc stuff that's been added to out_0.c
			prev_fn_pos = fn_pos
			continue
		}
		fn_text := out_str[prev_fn_pos..fn_pos]
		out_files[i % nr_cpus].writeln(fn_text + '\n//////////////////////////////////////\n\n') or {
			panic(err)
		}
		prev_fn_pos = fn_pos
	}
	for i in 0 .. nr_cpus {
		out_files[i].close()
	}
	t := time.now()
	mut wg := sync.new_waitgroup()
	for i in ['0', 'x'] {
		wg.add(1)
		go build_o(i, mut wg)
	}
	for i in 0 .. nr_cpus {
		wg.add(1)
		go build_o((i + 1).str(), mut wg)
	}
	wg.wait()
	println(time.now() - t)
	link_cmd := 'cc -o v_parallel out_0.o ${fnames.map(it.replace('.c', '.o')).join(' ')} out_x.o -lpthread'
	link_res := os.execute(link_cmd)
	println('> link_cmd: $link_cmd => $link_res.exit_code')
	println(time.now() - t)
}

fn build_o(postfix string, mut wg sync.WaitGroup) {
	cmd := 'cc -c -w -o out_${postfix}.o out_${postfix}.c'
	res := os.execute(cmd)
	wg.done()
	println('cmd: `$cmd` => $res.exit_code')
}
