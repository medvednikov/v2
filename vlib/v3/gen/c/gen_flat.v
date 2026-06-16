module c

import strings
import v3.flat

struct StructField {
	name string
	typ  string
}

pub struct FlatGen {
mut:
	sb             strings.Builder
	indent         int
	a              &flat.FlatAst = unsafe { nil }
	str_lits       []string
	fn_ret_types   map[string]string
	fn_param_types map[string][]string
	var_types      map[string]string
	structs        map[string][]StructField
	global_types   map[string]string
}

pub fn FlatGen.new() FlatGen {
	return FlatGen{
		sb: strings.new_builder(4096)
	}
}

pub fn (mut g FlatGen) gen(a &flat.FlatAst) string {
	g.a = a
	g.collect()
	orig_sb := g.sb
	g.sb = strings.new_builder(4096)
	g.gen_fns()
	fn_code := g.sb.str()
	g.sb = orig_sb
	g.preamble()
	g.struct_decls()
	g.global_decls()
	g.forward_decls()
	g.string_literals()
	g.sb.write_string(fn_code)
	return g.sb.str()
}

fn (mut g FlatGen) collect() {
	for node in g.a.nodes {
		match node.kind {
			.fn_decl {
				g.fn_ret_types[node.value] = g.c_type(node.typ)
				mut ptypes := []string{}
				for i in 0 .. node.children_count {
					child := g.a.child_node(&node, i)
					if child.kind == .param {
						ptypes << g.c_type(child.typ)
					}
				}
				g.fn_param_types[node.value] = ptypes
			}
			.struct_decl {
				mut fields := []StructField{}
				for i in 0 .. node.children_count {
					f := g.a.child_node(&node, i)
					fields << StructField{
						name: f.value
						typ:  g.c_type(f.typ)
					}
				}
				g.structs[node.value] = fields
			}
			.global_decl {
				for i in 0 .. node.children_count {
					f := g.a.child_node(&node, i)
					g.global_types[f.value] = f.typ
				}
			}
			else {}
		}
	}
}

fn (mut g FlatGen) gen_fns() {
	for node in g.a.nodes {
		if node.kind == .fn_decl {
			g.gen_fn(node)
		}
	}
}

fn (mut g FlatGen) gen_fn(node flat.Node) {
	g.var_types = map[string]string{}
	params := g.fn_params_list(node)
	for p in params {
		if p.value.len > 0 {
			g.var_types[p.value] = g.c_type(p.typ)
		}
	}

	if node.value == 'main' {
		g.writeln('int main(int argc, char** argv) {')
	} else {
		g.write(g.c_type(node.typ))
		g.write(' ')
		g.write(c_name(node.value))
		g.write('(')
		g.write_fn_params(params)
		g.writeln(') {')
	}
	g.indent++

	body := g.fn_body_ids(node)
	for id in body {
		g.gen_node(id)
	}
	if node.value == 'main' {
		g.writeln('return 0;')
	}
	g.indent--
	g.writeln('}')
	g.writeln('')
}

fn (g &FlatGen) fn_params_list(node flat.Node) []flat.Node {
	mut params := []flat.Node{}
	for i in 0 .. node.children_count {
		child := g.a.child_node(&node, i)
		if child.kind == .param {
			params << *child
		}
	}
	return params
}

fn (g &FlatGen) fn_body_ids(node flat.Node) []flat.NodeId {
	mut ids := []flat.NodeId{}
	for i in 0 .. node.children_count {
		child := g.a.child_node(&node, i)
		if child.kind != .param {
			ids << g.a.child(&node, i)
		}
	}
	return ids
}

fn (mut g FlatGen) gen_node(id flat.NodeId) {
	if int(id) < 0 {
		return
	}
	node := g.a.nodes[int(id)]
	match node.kind {
		.expr_stmt {
			g.gen_expr(g.a.child(&node, 0))
			g.writeln(';')
		}
		.decl_assign {
			g.gen_decl_assign(node)
		}
		.assign, .selector_assign, .index_assign {
			g.gen_assign(node)
		}
		.return_stmt {
			g.write('return')
			if node.children_count > 0 {
				g.write(' ')
				g.gen_expr(g.a.child(&node, 0))
			}
			g.writeln(';')
		}
		.for_stmt {
			g.gen_for(node)
		}
		.break_stmt {
			g.writeln('break;')
		}
		.continue_stmt {
			g.writeln('continue;')
		}
		.block {
			g.writeln('{')
			g.indent++
			for i in 0 .. node.children_count {
				g.gen_node(g.a.child(&node, i))
			}
			g.indent--
			g.writeln('}')
		}
		.if_expr {
			g.gen_if(node)
		}
		.assert_stmt {
			g.write('if (!(')
			g.gen_expr(g.a.child(&node, 0))
			g.writeln(')) {')
			g.indent++
			g.writeln('fprintf(stderr, "assert failed\\n");')
			g.writeln('exit(1);')
			g.indent--
			g.writeln('}')
		}
		.empty {}
		else {
			eprintln('gen_node: unsupported node kind: ${node.kind}')
		}
	}
}

fn (mut g FlatGen) gen_decl_assign(node flat.Node) {
	mut i := 0
	for i < node.children_count {
		lhs_id := g.a.child(&node, i)
		rhs_id := g.a.child(&node, i + 1)
		lhs := g.a.nodes[int(lhs_id)]
		typ := g.infer_type(rhs_id)
		g.write('${typ} ')
		g.gen_expr(lhs_id)
		g.write(' = ')
		g.gen_expr(rhs_id)
		g.writeln(';')
		if lhs.kind == .ident {
			g.var_types[lhs.value] = typ
		}
		i += 2
	}
}

fn (mut g FlatGen) gen_assign(node flat.Node) {
	mut i := 0
	for i < node.children_count {
		g.gen_expr(g.a.child(&node, i))
		g.write(' ${g.op_str(node.op)} ')
		g.gen_expr(g.a.child(&node, i + 1))
		g.writeln(';')
		i += 2
	}
}

fn (mut g FlatGen) gen_for(node flat.Node) {
	init_node := g.a.child_node(&node, 0)
	cond_id := g.a.child(&node, 1)
	cond_node := g.a.nodes[int(cond_id)]
	post_node := g.a.child_node(&node, 2)

	if init_node.kind == .empty && cond_node.kind == .empty && post_node.kind == .empty {
		g.writeln('for (;;) {')
	} else if init_node.kind == .empty && post_node.kind == .empty {
		g.write('while (')
		g.gen_expr(cond_id)
		g.writeln(') {')
	} else {
		g.write('for (')
		if init_node.kind != .empty {
			g.gen_node_inline(g.a.child(&node, 0))
		}
		g.write('; ')
		if cond_node.kind != .empty {
			g.gen_expr(cond_id)
		}
		g.write('; ')
		if post_node.kind != .empty {
			g.gen_node_inline(g.a.child(&node, 2))
		}
		g.writeln(') {')
	}
	g.indent++
	for i in 3 .. node.children_count {
		g.gen_node(g.a.child(&node, i))
	}
	g.indent--
	g.writeln('}')
}

fn (mut g FlatGen) gen_node_inline(id flat.NodeId) {
	node := g.a.nodes[int(id)]
	match node.kind {
		.expr_stmt {
			g.gen_expr(g.a.child(&node, 0))
		}
		.decl_assign {
			lhs_id := g.a.child(&node, 0)
			rhs_id := g.a.child(&node, 1)
			typ := g.infer_type(rhs_id)
			g.write('${typ} ')
			g.gen_expr(lhs_id)
			g.write(' = ')
			g.gen_expr(rhs_id)
		}
		.assign {
			g.gen_expr(g.a.child(&node, 0))
			g.write(' ${g.op_str(node.op)} ')
			g.gen_expr(g.a.child(&node, 1))
		}
		else {}
	}
}

fn (mut g FlatGen) gen_if(node flat.Node) {
	cond := g.a.child_node(&node, 0)
	if cond.kind != .empty {
		g.write('if (')
		g.gen_expr(g.a.child(&node, 0))
		g.writeln(') {')
	} else {
		g.writeln('{')
	}
	g.indent++
	then_block := g.a.child_node(&node, 1)
	for i in 0 .. then_block.children_count {
		g.gen_node(g.a.child(then_block, i))
	}
	g.indent--
	if node.children_count > 2 {
		else_node := g.a.child_node(&node, 2)
		if else_node.kind == .if_expr {
			g.write('} else ')
			g.gen_if(*else_node)
		} else if else_node.kind == .block {
			g.writeln('} else {')
			g.indent++
			for i in 0 .. else_node.children_count {
				g.gen_node(g.a.child(else_node, i))
			}
			g.indent--
			g.writeln('}')
		} else {
			g.writeln('}')
		}
	} else {
		g.writeln('}')
	}
}

fn (mut g FlatGen) gen_expr(id flat.NodeId) {
	if int(id) < 0 {
		return
	}
	node := g.a.nodes[int(id)]
	match node.kind {
		.int_literal, .float_literal {
			g.write(node.value)
		}
		.bool_literal {
			g.write(node.value)
		}
		.char_literal {
			g.write(node.value)
		}
		.string_literal {
			sid := g.intern_string(node.value)
			g.write('_str_${sid}')
		}
		.string_interp {
			g.gen_string_interp(node)
		}
		.ident {
			g.write(c_name(node.value))
		}
		.call {
			g.gen_call(node)
		}
		.infix {
			if node.op == .plus {
				if g.is_string_node(g.a.child(&node, 0)) || g.is_string_node(g.a.child(&node, 1)) {
					g.write('string__plus(')
					g.gen_expr(g.a.child(&node, 0))
					g.write(', ')
					g.gen_expr(g.a.child(&node, 1))
					g.write(')')
					return
				}
			}
			g.gen_expr(g.a.child(&node, 0))
			g.write(' ${g.op_str(node.op)} ')
			g.gen_expr(g.a.child(&node, 1))
		}
		.prefix {
			child_id := g.a.child(&node, 0)
			child := g.a.nodes[int(child_id)]
			if node.op == .amp && child.kind == .struct_init {
				g.gen_heap_struct_init(child)
			} else {
				g.write(g.op_str(node.op))
				g.gen_expr(child_id)
			}
		}
		.postfix {
			g.gen_expr(g.a.child(&node, 0))
			g.write(g.op_str(node.op))
		}
		.paren {
			g.write('(')
			g.gen_expr(g.a.child(&node, 0))
			g.write(')')
		}
		.selector {
			base_id := g.a.child(&node, 0)
			base := g.a.nodes[int(base_id)]
			mut is_ptr := false
			if base.kind == .ident {
				if typ := g.var_types[base.value] {
					is_ptr = typ.ends_with('*')
				}
			}
			g.gen_expr(base_id)
			if is_ptr {
				g.write('->')
			} else {
				g.write('.')
			}
			g.write(node.value)
		}
		.index {
			g.gen_expr(g.a.child(&node, 0))
			g.write('[')
			g.gen_expr(g.a.child(&node, 1))
			g.write(']')
		}
		.cast_expr {
			g.write('(${g.c_type(node.value)})(')
			g.gen_expr(g.a.child(&node, 0))
			g.write(')')
		}
		.struct_init {
			g.gen_struct_init(node)
		}
		.if_expr {
			g.gen_if(node)
		}
		.nil_literal {
			g.write('NULL')
		}
		.empty {}
		else {}
	}
}

fn (mut g FlatGen) gen_struct_init(node flat.Node) {
	name := c_name(node.value)
	g.write('(${name}){')
	for i in 0 .. node.children_count {
		field := g.a.child_node(&node, i)
		if i > 0 {
			g.write(', ')
		}
		g.write('.${c_name(field.value)} = ')
		g.gen_expr(g.a.child(field, 0))
	}
	g.write('}')
}

fn (mut g FlatGen) gen_heap_struct_init(node flat.Node) {
	name := c_name(node.value)
	g.write('(${name}*)memdup(&(${name}){')
	for i in 0 .. node.children_count {
		field := g.a.child_node(&node, i)
		if i > 0 {
			g.write(', ')
		}
		g.write('.${c_name(field.value)} = ')
		g.gen_expr(g.a.child(field, 0))
	}
	g.write('}, sizeof(${name}))')
}

fn (mut g FlatGen) gen_call(node flat.Node) {
	fn_node := g.a.child_node(&node, 0)
	fn_name := fn_node.value
	match fn_name {
		'println', 'print' {
			g.write(fn_name)
			g.write('(')
			if node.children_count > 1 {
				arg_id := g.a.child(&node, 1)
				arg_type := g.infer_type(arg_id)
				if arg_type == 'string' {
					g.gen_expr(arg_id)
				} else {
					g.write('int_str(')
					g.gen_expr(arg_id)
					g.write(')')
				}
			}
			g.write(')')
		}
		else {
			if fn_node.kind == .selector {
				base := g.a.child_node(fn_node, 0)
				if base.kind == .ident && base.value == 'C' {
					g.write(fn_node.value)
				} else {
					g.gen_expr(g.a.child(&node, 0))
				}
			} else {
				g.gen_expr(g.a.child(&node, 0))
			}
			g.write('(')
			param_types := g.fn_param_types[fn_name]
			for i in 1 .. node.children_count {
				if i > 1 {
					g.write(', ')
				}
				arg_idx := i - 1
				if arg_idx < param_types.len && param_types[arg_idx].ends_with('*') {
					g.write('&')
				}
				g.gen_expr(g.a.child(&node, i))
			}
			g.write(')')
		}
	}
}

fn (mut g FlatGen) gen_string_interp(node flat.Node) {
	n := node.children_count
	if n == 0 {
		sid := g.intern_string('')
		g.write('_str_${sid}')
		return
	}
	g.write('string_plus_many(${n}, (string[${n}]){')
	for i in 0 .. n {
		if i > 0 {
			g.write(', ')
		}
		child_id := g.a.child(&node, i)
		child := g.a.nodes[int(child_id)]
		if child.kind == .string_literal {
			sid := g.intern_string(child.value)
			g.write('_str_${sid}')
		} else {
			typ := g.infer_type(child_id)
			if typ == 'string' {
				g.gen_expr(child_id)
			} else {
				g.write('int_str(')
				g.gen_expr(child_id)
				g.write(')')
			}
		}
	}
	g.write('})')
}

fn (g &FlatGen) infer_type(id flat.NodeId) string {
	if int(id) < 0 {
		return 'int'
	}
	node := g.a.nodes[int(id)]
	match node.kind {
		.int_literal {
			return 'int'
		}
		.float_literal {
			return 'double'
		}
		.bool_literal {
			return 'bool'
		}
		.char_literal {
			return 'u8'
		}
		.string_literal, .string_interp {
			return 'string'
		}
		.ident {
			if typ := g.var_types[node.value] {
				return typ
			}
			if typ := g.global_types[node.value] {
				return typ
			}
			return 'int'
		}
		.call {
			fn_node := g.a.child_node(&node, 0)
			if ret := g.fn_ret_types[fn_node.value] {
				return ret
			}
			return 'int'
		}
		.infix {
			lt := g.infer_type(g.a.child(&node, 0))
			if lt == 'string' {
				return 'string'
			}
			rt := g.infer_type(g.a.child(&node, 1))
			if rt == 'string' {
				return 'string'
			}
			return lt
		}
		.prefix {
			if node.op == .amp {
				return g.infer_type(g.a.child(&node, 0)) + '*'
			}
			return g.infer_type(g.a.child(&node, 0))
		}
		.paren {
			return g.infer_type(g.a.child(&node, 0))
		}
		.struct_init {
			return node.value
		}
		.selector {
			base_type := g.infer_type(g.a.child(&node, 0))
			if fields := g.structs[base_type] {
				for f in fields {
					if f.name == node.value {
						return f.typ
					}
				}
			}
			return 'int'
		}
		else {
			return 'int'
		}
	}
}

fn (g &FlatGen) is_string_node(id flat.NodeId) bool {
	return g.infer_type(id) == 'string'
}

fn (mut g FlatGen) forward_decls() {
	for node in g.a.nodes {
		if node.kind == .fn_decl && node.value != 'main' {
			g.write(g.c_type(node.typ))
			g.write(' ')
			g.write(c_name(node.value))
			g.write('(')
			params := g.fn_params_list(node)
			g.write_fn_params(params)
			g.writeln(');')
		}
	}
	g.writeln('')
}

fn (mut g FlatGen) write_fn_params(params []flat.Node) {
	if params.len == 0 {
		g.write('void')
		return
	}
	for i, p in params {
		g.write(g.c_type(p.typ))
		if p.value.len > 0 {
			g.write(' ')
			g.write(c_name(p.value))
		}
		if i < params.len - 1 {
			g.write(', ')
		}
	}
}

fn (mut g FlatGen) string_literals() {
	for i, s in g.str_lits {
		g.writeln("string _str_${i} = {\"${c_escape(s)}\", ${s.len}};")
	}
	if g.str_lits.len > 0 {
		g.writeln('')
	}
}

fn (mut g FlatGen) preamble() {
	g.writeln('#include <stdio.h>')
	g.writeln('#include <stdlib.h>')
	g.writeln('#include <string.h>')
	g.writeln('')
	g.writeln('typedef struct {')
	g.writeln('\tchar* str;')
	g.writeln('\tint len;')
	g.writeln('} string;')
	g.writeln('')
	g.writeln('typedef signed char i8;')
	g.writeln('typedef short i16;')
	g.writeln('typedef int i32;')
	g.writeln('typedef long long i64;')
	g.writeln('typedef unsigned char u8;')
	g.writeln('typedef unsigned char byte;')
	g.writeln('typedef unsigned short u16;')
	g.writeln('typedef unsigned int u32;')
	g.writeln('typedef unsigned long long u64;')
	g.writeln('typedef int bool;')
	g.writeln('#define true 1')
	g.writeln('#define false 0')
	g.writeln('')
	g.writeln('void println(string s) {')
	g.writeln('\tfwrite(s.str, 1, s.len, stdout);')
	g.writeln('\tputchar(10);')
	g.writeln('}')
	g.writeln('')
	g.writeln('void print(string s) {')
	g.writeln('\tfwrite(s.str, 1, s.len, stdout);')
	g.writeln('}')
	g.writeln('')
	g.writeln('string int_str(int n) {')
	g.writeln('\tstatic char buf[20];')
	g.writeln('\tint len = snprintf(buf, sizeof(buf), "%d", n);')
	g.writeln('\treturn (string){buf, len};')
	g.writeln('}')
	g.writeln('')
	g.writeln('string string__plus(string a, string b) {')
	g.writeln('\tint len = a.len + b.len;')
	g.writeln('\tchar* s = malloc(len + 1);')
	g.writeln('\tmemcpy(s, a.str, a.len);')
	g.writeln('\tmemcpy(s + a.len, b.str, b.len);')
	g.writeln('\ts[len] = 0;')
	g.writeln('\treturn (string){s, len};')
	g.writeln('}')
	g.writeln('')
	g.writeln('void* memdup(const void* src, int sz) {')
	g.writeln('\tvoid* p = malloc(sz);')
	g.writeln('\tmemcpy(p, src, sz);')
	g.writeln('\treturn p;')
	g.writeln('}')
	g.writeln('')
	g.writeln('string string_plus_many(int count, string* parts) {')
	g.writeln('\tint len = 0;')
	g.writeln('\tfor (int i = 0; i < count; i++) len += parts[i].len;')
	g.writeln('\tchar* s = malloc(len + 1);')
	g.writeln('\tint off = 0;')
	g.writeln('\tfor (int i = 0; i < count; i++) {')
	g.writeln('\t\tmemcpy(s + off, parts[i].str, parts[i].len);')
	g.writeln('\t\toff += parts[i].len;')
	g.writeln('\t}')
	g.writeln('\ts[len] = 0;')
	g.writeln('\treturn (string){s, len};')
	g.writeln('}')
	g.writeln('')
}

fn (mut g FlatGen) struct_decls() {
	for name, fields in g.structs {
		g.writeln('typedef struct {')
		for f in fields {
			g.writeln('\t${f.typ} ${c_name(f.name)};')
		}
		g.writeln('} ${c_name(name)};')
		g.writeln('')
	}
}

fn (mut g FlatGen) global_decls() {
	for name, typ in g.global_types {
		g.writeln('${g.c_type(typ)} ${c_name(name)};')
	}
	if g.global_types.len > 0 {
		g.writeln('')
	}
}

fn (mut g FlatGen) intern_string(s string) int {
	for i, existing in g.str_lits {
		if existing == s {
			return i
		}
	}
	id := g.str_lits.len
	g.str_lits << s
	return id
}

fn (g &FlatGen) c_type(typ string) string {
	if typ.starts_with('&') {
		return g.c_type(typ[1..]) + '*'
	}
	return match typ {
		'int' { 'int' }
		'i8' { 'i8' }
		'i16' { 'i16' }
		'i32' { 'i32' }
		'i64' { 'i64' }
		'u8', 'byte' { 'u8' }
		'u16' { 'u16' }
		'u32' { 'u32' }
		'u64' { 'u64' }
		'f32' { 'float' }
		'f64' { 'double' }
		'bool' { 'bool' }
		'string' { 'string' }
		'void' { 'void' }
		'voidptr' { 'void*' }
		'' { 'void' }
		else { typ }
	}
}

fn (g &FlatGen) op_str(op flat.Op) string {
	return match op {
		.plus { '+' }
		.minus { '-' }
		.mul { '*' }
		.div { '/' }
		.mod { '%' }
		.eq { '==' }
		.ne { '!=' }
		.lt { '<' }
		.gt { '>' }
		.le { '<=' }
		.ge { '>=' }
		.amp { '&' }
		.pipe { '|' }
		.xor { '^' }
		.left_shift { '<<' }
		.right_shift { '>>' }
		.logical_and { '&&' }
		.logical_or { '||' }
		.not { '!' }
		.bit_not { '~' }
		.assign { '=' }
		.plus_assign { '+=' }
		.minus_assign { '-=' }
		.mul_assign { '*=' }
		.div_assign { '/=' }
		.mod_assign { '%=' }
		.amp_assign { '&=' }
		.pipe_assign { '|=' }
		.xor_assign { '^=' }
		.left_shift_assign { '<<=' }
		.right_shift_assign { '>>=' }
		.inc { '++' }
		.dec { '--' }
		.none { '' }
	}
}

fn (mut g FlatGen) write(s string) {
	if g.sb.len == 0 || g.sb.last_n(1) == '\n' {
		g.write_indent()
	}
	g.sb.write_string(s)
}

fn (mut g FlatGen) writeln(s string) {
	if s.len > 0 {
		if g.sb.len == 0 || g.sb.last_n(1) == '\n' {
			g.write_indent()
		}
		g.sb.write_string(s)
	}
	g.sb.write_string('\n')
}

fn (mut g FlatGen) write_indent() {
	for _ in 0 .. g.indent {
		g.sb.write_string('\t')
	}
}
