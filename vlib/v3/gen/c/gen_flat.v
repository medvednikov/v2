module c

import strings
import v3.flat
import v3.types

pub struct FlatGen {
mut:
	sb           strings.Builder
	indent       int
	a            &flat.FlatAst = unsafe { nil }
	used_fns     map[string]bool
	str_lits     []string
	global_types map[string]string
	enum_vals    map[string]int
	defers       []flat.NodeId
	interfaces   map[string][]string
	const_vals   map[string]flat.NodeId
	tc           types.TypeChecker
	has_builtins bool
	tmp_count    int
}

pub fn FlatGen.new() FlatGen {
	return FlatGen{
		sb: strings.new_builder(4096)
	}
}

pub fn (mut g FlatGen) gen(a &flat.FlatAst) string {
	return g.gen_with_used(a, map[string]bool{})
}

pub fn (mut g FlatGen) gen_with_used(a &flat.FlatAst, used_fns map[string]bool) string {
	g.a = a
	g.used_fns = used_fns.clone()
	g.tc.a = a
	g.tc.file_scope = types.new_scope(unsafe { nil })
	g.tc.cur_scope = g.tc.file_scope
	for node in a.nodes {
		if node.kind == .struct_decl && node.value == 'string' {
			g.has_builtins = true
			g.tc.has_builtins = true
			break
		}
	}
	g.collect()
	g.register_runtime_methods()
	orig_sb := g.sb
	g.sb = strings.new_builder(4096)
	g.gen_fns()
	fn_code := g.sb.str()
	g.sb = orig_sb
	g.preamble()
	if g.has_builtins {
		g.writeln('typedef struct { void* data; int len; int cap; int elem_size; } Array;')
		g.writeln('typedef Array array;')
		g.writeln('typedef struct { unsigned int hash; bool used; } MapSlot;')
		g.writeln('typedef struct { MapSlot* slots; char* keys; char* vals; int cap; int len; int key_size; int val_size; } HashMap;')
		g.writeln('')
	}
	g.enum_decls()
	g.struct_decls()
	g.runtime_fns()
	g.global_decls()
	g.forward_decls()
	const_code := g.precompute_consts()
	g.string_literals()
	g.sb.write_string(const_code)
	g.sb.write_string(fn_code)
	return g.sb.str()
}

fn (mut g FlatGen) collect() {
	for node in g.a.nodes {
		match node.kind {
			.fn_decl {
				g.tc.fn_ret_types[node.value] = node.typ
				mut ptypes := []string{}
				for i in 0 .. node.children_count {
					child := g.a.child_node(&node, i)
					if child.kind == .param {
						ptypes << g.tc.c_type(child.typ)
					}
				}
				g.tc.fn_param_types[node.value] = ptypes
			}
			.struct_decl {
				if node.value.starts_with('C.') {
					continue
				}
				mut fields := []types.StructField{}
				for i in 0 .. node.children_count {
					f := g.a.child_node(&node, i)
					fields << types.StructField{
						name: f.value
						typ:  g.tc.c_type(f.typ)
					}
				}
				g.tc.structs[node.value] = fields
			}
			.global_decl {
				for i in 0 .. node.children_count {
					f := g.a.child_node(&node, i)
					if f.value.starts_with('C.') {
						continue
					}
					g.global_types[f.value] = f.typ
					g.tc.file_scope.insert(f.value, g.tc.c_type(f.typ))
				}
			}
			.enum_decl {
				g.tc.enum_names[node.value] = true
				is_flag := node.typ == 'flag'
				if is_flag {
					g.tc.flag_enums[node.value] = true
				}
				mut val := 0
				for i in 0 .. node.children_count {
					f := g.a.child_node(&node, i)
					if f.children_count > 0 {
						ev := g.a.child_node(f, 0)
						if ev.kind == .int_literal {
							val = ev.value.int()
						}
					}
					if is_flag {
						g.enum_vals['${node.value}.${f.value}'] = 1 << val
						val++
					} else {
						g.enum_vals['${node.value}.${f.value}'] = val
						val++
					}
				}
			}
			.type_decl {
				if node.children_count > 0 {
					mut variants := []string{}
					for i in 0 .. node.children_count {
						v := g.a.child_node(&node, i)
						variants << v.value
					}
					g.tc.sum_types[node.value] = variants
				} else if node.typ.len > 0 {
					g.tc.type_aliases[node.value] = node.typ
				}
			}
			.c_fn_decl {
				g.tc.fn_ret_types[node.value] = g.tc.c_type(node.typ)
				mut ptypes := []string{}
				for i in 0 .. node.children_count {
					child := g.a.child_node(&node, i)
					if child.kind == .param {
						ptypes << g.tc.c_type(child.typ)
					}
				}
				g.tc.fn_param_types[node.value] = ptypes
			}
			.interface_decl {
				mut methods := []string{}
				for i in 0 .. node.children_count {
					f := g.a.child_node(&node, i)
					if f.kind == .interface_field {
						methods << f.value
					}
				}
				g.interfaces[node.value] = methods
			}
			.const_decl {
				for i in 0 .. node.children_count {
					f := g.a.child_node(&node, i)
					if f.kind == .const_field && f.children_count > 0 {
						g.const_vals[f.value] = g.a.child(f, 0)
					}
				}
			}
			else {}
		}
	}
}

fn (mut g FlatGen) register_runtime_methods() {
	methods := {
		'string.all_before':      ['string', 'string']
		'string.all_before_last': ['string', 'string']
		'string.all_after':       ['string', 'string']
		'string.all_after_last':  ['string', 'string']
		'string.before':          ['string', 'string']
		'string.after':           ['string', 'string']
		'string.substr':          ['string', 'int', 'int']
		'string.trim_left':       ['string', 'string']
		'string.trim_right':      ['string', 'string']
		'string.trim_space':      ['string']
		'string.count':           ['string', 'string']
		'string.index_':          ['string', 'string']
		'string.last_index_':     ['string', 'string']
		'string.replace':         ['string', 'string', 'string']
		'string.contains':        ['string', 'string']
		'string.split':           ['string', 'string']
		'string.starts_with':     ['string', 'string']
		'string.ends_with':       ['string', 'string']
		'string.index_u8':        ['string', 'u8']
		'string.last_index_u8':   ['string', 'u8']
		'string.contains_u8':     ['string', 'u8']
		'string.int':             ['string']
	}
	ret_types := {
		'string.all_before':      'string'
		'string.all_before_last': 'string'
		'string.all_after':       'string'
		'string.all_after_last':  'string'
		'string.before':          'string'
		'string.after':           'string'
		'string.substr':          'string'
		'string.trim_left':       'string'
		'string.trim_right':      'string'
		'string.trim_space':      'string'
		'string.count':           'int'
		'string.index_':          'int'
		'string.last_index_':     'int'
		'string.replace':         'string'
		'string.contains':        'bool'
		'string.split':           '[]string'
		'string.starts_with':     'bool'
		'string.ends_with':       'bool'
		'string.index_u8':        'int'
		'string.last_index_u8':   'int'
		'string.contains_u8':     'bool'
		'string.int':             'int'
	}
	for name, params in methods {
		if name !in g.tc.fn_param_types {
			g.tc.fn_param_types[name] = params
		}
	}
	for name, ret in ret_types {
		if name !in g.tc.fn_ret_types {
			g.tc.fn_ret_types[name] = ret
		}
	}
}

fn (mut g FlatGen) gen_fns() {
	for i, node in g.a.nodes {
		if node.kind == .fn_decl {
			if g.has_builtins && i < g.a.user_code_start {
				continue
			}
			if g.used_fns.len > 0 && node.value !in g.used_fns {
				continue
			}
			g.gen_fn(node)
		}
	}
}

fn (mut g FlatGen) gen_fn(node flat.Node) {
	g.tc.push_scope()
	g.defers = []flat.NodeId{}
	params := g.fn_params_list(node)
	for p in params {
		if p.value.len > 0 {
			g.tc.cur_scope.insert(p.value, g.tc.c_type(p.typ))
		}
	}

	if node.value == 'main' {
		g.writeln('int main(int argc, char** argv) {')
	} else {
		g.write(g.tc.c_type(node.typ))
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
	g.gen_defers()
	if node.value == 'main' {
		g.writeln('return 0;')
	}
	g.indent--
	g.writeln('}')
	g.writeln('')
	g.tc.pop_scope()
}

fn (mut g FlatGen) gen_defers() {
	mut i := g.defers.len - 1
	for i >= 0 {
		defer_body := g.a.nodes[int(g.defers[i])]
		for j in 0 .. defer_body.children_count {
			g.gen_node(g.a.child(&defer_body, j))
		}
		i--
	}
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
			child_id := g.a.child(&node, 0)
			child := g.a.nodes[int(child_id)]
			if child.kind == .or_expr {
				g.gen_or_expr_stmt(child)
			} else if child.kind == .infix && child.op == .left_shift {
				lhs_id := g.a.child(&child, 0)
				lhs_node := g.a.nodes[int(lhs_id)]
				lhs_type := if lhs_node.kind == .ident {
					g.tc.cur_scope.lookup(lhs_node.value) or { '' }
				} else {
					''
				}
				if lhs_type.starts_with('[]') {
					elem_type := lhs_type[2..]
					c_elem := g.tc.c_type(elem_type)
					g.write('array_push(&')
					g.gen_expr(lhs_id)
					g.write(', &(${c_elem}[]){')
					g.gen_expr(g.a.child(&child, 1))
					g.writeln('});')
				} else {
					g.gen_expr(child_id)
					g.writeln(';')
				}
			} else {
				g.gen_expr(child_id)
				g.writeln(';')
			}
		}
		.decl_assign {
			g.gen_decl_assign(node)
		}
		.assign, .selector_assign {
			g.gen_assign(node)
		}
		.index_assign {
			g.gen_index_assign(node)
		}
		.return_stmt {
			g.gen_defers()
			g.write('return')
			if node.children_count > 0 {
				g.write(' ')
				g.gen_expr(g.a.child(&node, 0))
			}
			g.writeln(';')
		}
		.defer_stmt {
			g.defers << g.a.child(&node, 0)
		}
		.for_stmt {
			g.gen_for(node)
		}
		.for_in_stmt {
			g.gen_for_in(node)
		}
		.break_stmt {
			g.writeln('break;')
		}
		.continue_stmt {
			g.writeln('continue;')
		}
		.block {
			g.writeln('{')
			g.tc.push_scope()
			g.indent++
			for i in 0 .. node.children_count {
				g.gen_node(g.a.child(&node, i))
			}
			g.indent--
			g.tc.pop_scope()
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
		.goto_stmt {
			g.writeln('goto ${c_name(node.value)};')
		}
		.label_stmt {
			old_indent := g.indent
			g.indent = 0
			g.writeln('${c_name(node.value)}: ;')
			g.indent = old_indent
		}
		.match_stmt {
			g.gen_match(node)
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
		rhs := g.a.nodes[int(rhs_id)]
		if rhs.kind == .array_literal {
			elem_type := if rhs.children_count > 0 {
				g.tc.c_type(g.tc.resolve_type(g.a.child(&rhs, 0)))
			} else {
				'int'
			}
			count := rhs.children_count
			g.write('${elem_type} ')
			g.gen_expr(lhs_id)
			g.write('[] = {')
			for j in 0 .. count {
				if j > 0 {
					g.write(', ')
				}
				g.gen_expr(g.a.child(&rhs, j))
			}
			g.writeln('};')
			if lhs.kind == .ident {
				g.tc.cur_scope.insert(lhs.value, '${elem_type}[${count}]')
			}
		} else if rhs.kind == .or_expr {
			g.gen_decl_or_expr(lhs, rhs)
		} else if rhs.kind == .array_init {
			elem_type := rhs.value
			c_elem := g.tc.c_type(elem_type)
			mut init_len := '0'
			mut init_cap := '0'
			mut init_val := ''
			for j in 0 .. rhs.children_count {
				child := g.a.child_node(&rhs, j)
				if child.kind == .field_init {
					if child.value == 'len' {
						init_len = g.expr_to_string(g.a.child(child, 0))
					} else if child.value == 'cap' {
						init_cap = g.expr_to_string(g.a.child(child, 0))
					} else if child.value == 'init' {
						init_val = g.expr_to_string(g.a.child(child, 0))
					}
				}
			}
			lhs_str := g.expr_to_string(lhs_id)
			g.writeln('Array ${lhs_str} = array_new(sizeof(${c_elem}), ${init_len}, ${init_cap});')
			if init_val.len > 0 {
				g.writeln('for (int _ai = 0; _ai < ${lhs_str}.len; _ai++) ((${c_elem}*)${lhs_str}.data)[_ai] = ${init_val};')
			}
			if lhs.kind == .ident {
				g.tc.cur_scope.insert(lhs.value, '[]${elem_type}')
			}
		} else if rhs.kind == .map_init {
			v_type := g.tc.resolve_type(rhs_id)
			c_typ := g.tc.c_type(v_type)
			g.write('${c_typ} ')
			g.gen_expr(lhs_id)
			g.write(' = ')
			g.gen_expr(rhs_id)
			g.writeln(';')
			if lhs.kind == .ident {
				g.tc.cur_scope.insert(lhs.value, v_type)
			}
			if rhs.children_count > 0 {
				map_type := rhs.value
				key_type := map_type[4..map_type.index_u8(`]`)]
				get_fn := if key_type == 'string' {
					'hashmap_set_string'
				} else {
					'hashmap_set_int'
				}
				for j := 0; j < rhs.children_count; j += 2 {
					g.write('${get_fn}(&')
					g.gen_expr(lhs_id)
					g.write(', ')
					g.gen_expr(g.a.child(&rhs, j))
					g.write(', &(${g.tc.c_type(map_type[map_type.index_u8(`]`) + 1..])}[]){')
					g.gen_expr(g.a.child(&rhs, j + 1))
					g.writeln('});')
				}
			}
		} else {
			v_type := g.tc.resolve_type(rhs_id)
			typ := g.tc.c_type(v_type)
			g.write('${typ} ')
			g.gen_expr(lhs_id)
			g.write(' = ')
			g.gen_expr(rhs_id)
			g.writeln(';')
			if lhs.kind == .ident {
				if v_type.starts_with('[]') || v_type.starts_with('map[') {
					g.tc.cur_scope.insert(lhs.value, v_type)
				} else {
					g.tc.cur_scope.insert(lhs.value, typ)
				}
			}
		}
		i += 2
	}
}

fn (mut g FlatGen) gen_assign(node flat.Node) {
	mut i := 0
	for i < node.children_count {
		lhs := g.a.nodes[int(g.a.child(&node, i))]
		if lhs.kind == .ident && lhs.value == '_' {
			g.write('(void)(')
			g.gen_expr(g.a.child(&node, i + 1))
			g.writeln(');')
		} else if node.op == .left_shift_assign && lhs.kind == .ident {
			lhs_type := g.tc.cur_scope.lookup(lhs.value) or { '' }
			if lhs_type.starts_with('[]') {
				elem_type := lhs_type[2..]
				c_elem := g.tc.c_type(elem_type)
				g.write('array_push(&${c_name(lhs.value)}, &(${c_elem}[]){')
				g.gen_expr(g.a.child(&node, i + 1))
				g.writeln('});')
			} else {
				g.gen_expr(g.a.child(&node, i))
				g.write(' <<= ')
				g.gen_expr(g.a.child(&node, i + 1))
				g.writeln(';')
			}
		} else {
			g.gen_expr(g.a.child(&node, i))
			g.write(' ${g.op_str(node.op)} ')
			g.gen_expr(g.a.child(&node, i + 1))
			g.writeln(';')
		}
		i += 2
	}
}

fn (mut g FlatGen) expr_to_string(id flat.NodeId) string {
	orig := g.sb
	g.sb = strings.new_builder(64)
	g.gen_expr(id)
	result := g.sb.str()
	g.sb = orig
	return result
}

fn (mut g FlatGen) gen_slice_expr(node flat.Node, base_id flat.NodeId, base_type string) {
	start_node := g.a.child_node(&node, 1)
	has_start := start_node.kind != .empty
	has_end := node.children_count > 2
	base_str := g.expr_to_string(base_id)
	start_str := if has_start { g.expr_to_string(g.a.child(&node, 1)) } else { '0' }
	end_str := if has_end {
		g.expr_to_string(g.a.child(&node, 2))
	} else {
		'${base_str}.len'
	}
	if base_type == 'string' {
		g.write('string__substr(${base_str}, ${start_str}, ${end_str})')
	} else if base_type.starts_with('[]') {
		g.write('array_slice(${base_str}, ${start_str}, ${end_str})')
	} else {
		g.write('string__substr(${base_str}, ${start_str}, ${end_str})')
	}
}

fn (mut g FlatGen) gen_array_method_call(node flat.Node, fn_node &flat.Node, base_type string) {
	elem_type := base_type[2..]
	c_elem := g.tc.c_type(elem_type)
	base_id := g.a.child(fn_node, 0)
	match fn_node.value {
		'clone' {
			g.write('array_clone(')
			g.gen_expr(base_id)
			g.write(')')
		}
		'last' {
			g.write('*(${c_elem}*)array_get(')
			g.gen_expr(base_id)
			g.write(', ')
			g.gen_expr(base_id)
			g.write('.len - 1)')
		}
		'first' {
			g.write('*(${c_elem}*)array_get(')
			g.gen_expr(base_id)
			g.write(', 0)')
		}
		'delete_last' {
			g.gen_expr(base_id)
			g.write('.len--')
		}
		'clear' {
			g.gen_expr(base_id)
			g.write('.len = 0')
		}
		'delete' {
			g.write('array_delete(&')
			g.gen_expr(base_id)
			g.write(', ')
			g.gen_expr(g.a.child(&node, 1))
			g.write(')')
		}
		'join' {
			g.write('array_string_join(')
			g.gen_expr(base_id)
			g.write(', ')
			g.gen_expr(g.a.child(&node, 1))
			g.write(')')
		}
		'contains' {
			contains_fn := if elem_type == 'string' {
				'array_contains_string'
			} else {
				'array_contains_int'
			}
			g.write('${contains_fn}(')
			g.gen_expr(base_id)
			g.write(', ')
			g.gen_expr(g.a.child(&node, 1))
			g.write(')')
		}
		'index' {
			index_fn := if elem_type == 'string' {
				'array_index_string'
			} else {
				'array_index_int'
			}
			g.write('${index_fn}(')
			g.gen_expr(base_id)
			g.write(', ')
			g.gen_expr(g.a.child(&node, 1))
			g.write(')')
		}
		else {
			g.gen_expr(g.a.child(&node, 0))
			g.write('(')
			g.gen_expr(base_id)
			g.write(')')
		}
	}
}

fn (mut g FlatGen) gen_map_delete(node flat.Node, fn_node &flat.Node, base_type string) {
	key_type := base_type[4..base_type.index_u8(`]`)]
	del_fn := if key_type == 'string' { 'hashmap_delete_string' } else { 'hashmap_delete_int' }
	g.write('${del_fn}(&')
	g.gen_expr(g.a.child(fn_node, 0))
	g.write(', ')
	g.gen_expr(g.a.child(&node, 1))
	g.write(')')
}

fn (mut g FlatGen) gen_index_assign(node flat.Node) {
	lhs_id := g.a.child(&node, 0)
	lhs := g.a.nodes[int(lhs_id)]
	if lhs.kind == .index {
		base_id := g.a.child(&lhs, 0)
		base_type := g.tc.resolve_type(base_id)
		if base_type.starts_with('map[') {
			key_type := base_type[4..base_type.index_u8(`]`)]
			val_type := base_type[base_type.index_u8(`]`) + 1..]
			c_val := g.tc.c_type(val_type)
			set_fn := if key_type == 'string' {
				'hashmap_set_string'
			} else {
				'hashmap_set_int'
			}
			g.write('${set_fn}(&')
			g.gen_expr(base_id)
			g.write(', ')
			g.gen_expr(g.a.child(&lhs, 1))
			g.write(', &(${c_val}[]){')
			g.gen_expr(g.a.child(&node, 1))
			g.writeln('});')
			return
		}
	}
	g.gen_assign(node)
}

fn (mut g FlatGen) gen_for(node flat.Node) {
	g.tc.push_scope()
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
	g.tc.pop_scope()
}

fn (mut g FlatGen) gen_for_in(node flat.Node) {
	g.tc.push_scope()
	header_count := node.value.int()
	val_id := g.a.child(&node, 1)
	var_node := if int(val_id) >= 0 {
		g.a.child_node(&node, 1)
	} else {
		g.a.child_node(&node, 0)
	}
	var_name := c_name(var_node.value)
	g.tc.cur_scope.insert(var_node.value, 'int')
	body_start := header_count

	if header_count == 4 {
		g.write('for (int ${var_name} = ')
		g.gen_expr(g.a.child(&node, 2))
		g.write('; ${var_name} < ')
		g.gen_expr(g.a.child(&node, 3))
		g.writeln('; ${var_name}++) {')
	} else if header_count == 3 {
		container := g.a.child_node(&node, 2)
		if container.kind == .range {
			g.write('for (int ${var_name} = ')
			g.gen_expr(g.a.child(container, 0))
			g.write('; ${var_name} < ')
			g.gen_expr(g.a.child(container, 1))
			g.writeln('; ${var_name}++) {')
		} else {
			container_type := g.tc.resolve_type(g.a.child(&node, 2))
			has_index := int(val_id) >= 0
			idx_var := if has_index {
				c_name(g.a.child_node(&node, 0).value)
			} else {
				'__iter_${var_name}'
			}
			elem_var := if has_index {
				c_name(g.a.child_node(&node, 1).value)
			} else {
				var_name
			}
			if container_type.starts_with('map[') {
				key_type_v := container_type[4..container_type.index_u8(`]`)]
				val_type_v := container_type[container_type.index_u8(`]`) + 1..]
				c_key := g.tc.c_type(key_type_v)
				c_val := g.tc.c_type(val_type_v)
				container_str := g.expr_to_string(g.a.child(&node, 2))
				iter_var := '__mi_${g.tmp_count}'
				g.tmp_count++
				key_var := if has_index { idx_var } else { '__mk_${g.tmp_count}' }
				val_var_ := if has_index { elem_var } else { var_name }
				g.writeln('for (int ${iter_var} = 0; ${iter_var} < ${container_str}.cap; ${iter_var}++) {')
				g.indent++
				g.writeln('if (!${container_str}.slots[${iter_var}].used) continue;')
				g.writeln('${c_key} ${key_var} = *(${c_key}*)(${container_str}.keys + ${iter_var} * ${container_str}.key_size);')
				g.writeln('${c_val} ${val_var_} = *(${c_val}*)(${container_str}.vals + ${iter_var} * ${container_str}.val_size);')
				if has_index {
					g.tc.cur_scope.insert(key_var, key_type_v)
				}
				g.tc.cur_scope.insert(val_var_, val_type_v)
			} else if container_type.starts_with('[]') {
				elem_type := g.tc.c_type(container_type[2..])
				container_str := g.expr_to_string(g.a.child(&node, 2))
				g.writeln('for (int ${idx_var} = 0; ${idx_var} < ${container_str}.len; ${idx_var}++) {')
				g.indent++
				g.writeln('${elem_type} ${elem_var} = *(${elem_type}*)array_get(${container_str}, ${idx_var});')
				g.tc.cur_scope.insert(elem_var, container_type[2..])
			} else if container_type == 'string' {
				container_str := g.expr_to_string(g.a.child(&node, 2))
				g.writeln('for (int ${idx_var} = 0; ${idx_var} < ${container_str}.len; ${idx_var}++) {')
				g.indent++
				g.writeln('u8 ${elem_var} = ((u8*)${container_str}.str)[${idx_var}];')
				g.tc.cur_scope.insert(elem_var, 'u8')
			} else {
				arr_len := if container_type.contains('[') {
					container_type.after('[').before(']')
				} else {
					'0'
				}
				elem_type := if container_type.contains('[') {
					g.tc.c_type(container_type.before('['))
				} else {
					'int'
				}
				g.writeln('for (int ${idx_var} = 0; ${idx_var} < ${arr_len}; ${idx_var}++) {')
				g.indent++
				g.write('${elem_type} ${elem_var} = ')
				g.gen_expr(g.a.child(&node, 2))
				g.writeln('[${idx_var}];')
				g.tc.cur_scope.insert(elem_var, elem_type)
			}
			if has_index {
				g.tc.cur_scope.insert(var_name, 'int')
			}
			for i in body_start .. node.children_count {
				g.gen_node(g.a.child(&node, i))
			}
			g.indent--
			g.writeln('}')
			g.tc.pop_scope()
			return
		}
	} else {
		g.tc.pop_scope()
		return
	}
	g.indent++
	for i in body_start .. node.children_count {
		g.gen_node(g.a.child(&node, i))
	}
	g.indent--
	g.writeln('}')
	g.tc.pop_scope()
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
			lhs := g.a.nodes[int(lhs_id)]
			typ := g.tc.c_type(g.tc.resolve_type(rhs_id))
			g.write('${typ} ')
			g.gen_expr(lhs_id)
			g.write(' = ')
			g.gen_expr(rhs_id)
			if lhs.kind == .ident {
				g.tc.cur_scope.insert(lhs.value, typ)
			}
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
	if cond.kind == .decl_assign {
		g.gen_if_guard(node, *cond)
		return
	}
	if cond.kind != .empty {
		g.write('if (')
		g.gen_expr(g.a.child(&node, 0))
		g.writeln(') {')
	} else {
		g.writeln('{')
	}
	g.tc.push_scope()
	g.indent++
	then_block := g.a.child_node(&node, 1)
	for i in 0 .. then_block.children_count {
		g.gen_node(g.a.child(then_block, i))
	}
	g.indent--
	g.tc.pop_scope()
	g.gen_if_else(node)
}

fn (mut g FlatGen) gen_if_guard(node flat.Node, cond flat.Node) {
	lhs := g.a.child_node(&cond, 0)
	rhs_id := g.a.child(&cond, 1)
	rhs := g.a.child_node(&cond, 1)
	var_name := c_name(lhs.value)
	tmp := g.tmp_name()
	if rhs.kind == .index {
		base_id := g.a.child(rhs, 0)
		base_type := g.tc.resolve_type(base_id)
		if base_type.starts_with('map[') {
			key_type := base_type[4..base_type.index_u8(`]`)]
			val_type := base_type[base_type.index_u8(`]`) + 1..]
			c_val_type := g.tc.c_type(val_type)
			get_fn := if key_type == 'string' { 'hashmap_get_string' } else { 'hashmap_get_int' }
			g.write('void* ${tmp} = ${get_fn}(&')
			g.gen_expr(base_id)
			g.write(', ')
			g.gen_expr(g.a.child(rhs, 1))
			g.writeln(');')
			g.writeln('if (${tmp} != NULL) {')
			g.tc.push_scope()
			g.indent++
			g.writeln('${c_val_type} ${var_name} = *(${c_val_type}*)${tmp};')
			g.tc.cur_scope.insert(lhs.value, val_type)
		} else {
			g.write('Optional ${tmp} = ')
			g.gen_expr(rhs_id)
			g.writeln(';')
			g.writeln('if (${tmp}.ok) {')
			g.tc.push_scope()
			g.indent++
			g.writeln('int ${var_name} = ${tmp}.value;')
			g.tc.cur_scope.insert(lhs.value, 'int')
		}
	} else {
		g.write('Optional ${tmp} = ')
		g.gen_expr(rhs_id)
		g.writeln(';')
		g.writeln('if (${tmp}.ok) {')
		g.tc.push_scope()
		g.indent++
		g.writeln('int ${var_name} = ${tmp}.value;')
		g.tc.cur_scope.insert(lhs.value, 'int')
	}
	then_block := g.a.child_node(&node, 1)
	for i in 0 .. then_block.children_count {
		g.gen_node(g.a.child(then_block, i))
	}
	g.indent--
	g.tc.pop_scope()
	g.gen_if_else(node)
}

fn (mut g FlatGen) gen_if_else(node flat.Node) {
	if node.children_count > 2 {
		else_node := g.a.child_node(&node, 2)
		if else_node.kind == .if_expr {
			g.write('} else ')
			g.gen_if(*else_node)
		} else if else_node.kind == .block {
			g.writeln('} else {')
			g.tc.push_scope()
			g.indent++
			for i in 0 .. else_node.children_count {
				g.gen_node(g.a.child(else_node, i))
			}
			g.indent--
			g.tc.pop_scope()
			g.writeln('}')
		} else {
			g.writeln('}')
		}
	} else {
		g.writeln('}')
	}
}

fn (mut g FlatGen) gen_match(node flat.Node) {
	match_expr_id := g.a.child(&node, 0)
	match_type := g.tc.resolve_type(match_expr_id)
	is_sum := match_type in g.tc.sum_types || match_type.trim_right('*') in g.tc.sum_types
	clean_type := match_type.trim_right('*')

	for i in 1 .. node.children_count {
		branch := g.a.child_node(&node, i)
		is_else := branch.value == 'else'
		n_conds := if is_else {
			0
		} else if branch.value.len > 0 && branch.value != 'else' {
			branch.value.int()
		} else {
			1
		}
		body_start := if is_else { 0 } else { n_conds }

		if is_else {
			if i > 1 {
				g.writeln('} else {')
			} else {
				g.writeln('{')
			}
		} else {
			if i > 1 {
				g.write('} else if (')
			} else {
				g.write('if (')
			}
			for c in 0 .. n_conds {
				if c > 0 {
					g.write(' || ')
				}
				cond := g.a.child_node(branch, c)
				if is_sum {
					idx := g.sum_type_index(clean_type, cond.value)
					g.gen_expr(match_expr_id)
					g.write('.typ == ${idx}')
				} else {
					g.gen_expr(match_expr_id)
					g.write(' == ')
					g.gen_expr(g.a.child(branch, c))
				}
			}
			g.writeln(') {')
		}
		g.tc.push_scope()
		g.indent++
		for j in body_start .. branch.children_count {
			g.gen_node(g.a.child(branch, j))
		}
		g.indent--
		g.tc.pop_scope()
	}
	g.writeln('}')
}

fn (mut g FlatGen) gen_if_expr(node flat.Node) {
	g.write('(')
	g.gen_expr(g.a.child(&node, 0))
	g.write(' ? ')
	then_block := g.a.child_node(&node, 1)
	if then_block.children_count > 0 {
		last := g.a.child_node(then_block, then_block.children_count - 1)
		if last.kind == .expr_stmt {
			g.gen_expr(g.a.child(last, 0))
		} else {
			g.gen_expr(g.a.child(then_block, then_block.children_count - 1))
		}
	}
	g.write(' : ')
	if node.children_count > 2 {
		else_node := g.a.child_node(&node, 2)
		if else_node.kind == .if_expr {
			g.gen_if_expr(*else_node)
		} else if else_node.kind == .block {
			if else_node.children_count > 0 {
				last := g.a.child_node(else_node, else_node.children_count - 1)
				if last.kind == .expr_stmt {
					g.gen_expr(g.a.child(last, 0))
				} else {
					g.gen_expr(g.a.child(else_node, else_node.children_count - 1))
				}
			} else {
				g.write('0')
			}
		}
	} else {
		g.write('0')
	}
	g.write(')')
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
		.enum_val {
			for ename, eval in g.enum_vals {
				if ename.ends_with('.${node.value}') {
					g.write('${eval}')
					return
				}
			}
			g.write('0')
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
			if node.op in [.eq, .ne] {
				if g.is_string_node(g.a.child(&node, 0)) || g.is_string_node(g.a.child(&node, 1)) {
					if node.op == .eq {
						g.write('string__eq(')
					} else {
						g.write('!string__eq(')
					}
					g.gen_expr(g.a.child(&node, 0))
					g.write(', ')
					g.gen_expr(g.a.child(&node, 1))
					g.write(')')
					return
				}
			}
			lhs_id := g.a.child(&node, 0)
			rhs_id := g.a.child(&node, 1)
			lhs_node := g.a.nodes[int(lhs_id)]
			rhs_node := g.a.nodes[int(rhs_id)]
			if lhs_node.kind == .infix {
				g.write('(')
				g.gen_expr(lhs_id)
				g.write(')')
			} else {
				g.gen_expr(lhs_id)
			}
			g.write(' ${g.op_str(node.op)} ')
			if rhs_node.kind == .infix {
				g.write('(')
				g.gen_expr(rhs_id)
				g.write(')')
			} else {
				g.gen_expr(rhs_id)
			}
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
		.in_expr {
			lhs_id := g.a.child(&node, 0)
			rhs_id := g.a.child(&node, 1)
			rhs_type := g.tc.resolve_type(rhs_id)
			if rhs_type.starts_with('map[') {
				key_type := rhs_type[4..rhs_type.index_u8(`]`)]
				has_fn := if key_type == 'string' { 'hashmap_has_string' } else { 'hashmap_has_int' }
				g.write('${has_fn}(&')
				g.gen_expr(rhs_id)
				g.write(', ')
				g.gen_expr(lhs_id)
				g.write(')')
			} else if rhs_type.starts_with('[]') {
				elem_type := rhs_type[2..]
				contains_fn := if elem_type == 'string' {
					'array_contains_string'
				} else {
					'array_contains_int'
				}
				g.write('${contains_fn}(')
				g.gen_expr(rhs_id)
				g.write(', ')
				g.gen_expr(lhs_id)
				g.write(')')
			} else {
				g.gen_expr(lhs_id)
				g.write(' == ')
				g.gen_expr(rhs_id)
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
			if base.kind == .ident && base.value in g.tc.enum_names {
				ekey := '${base.value}.${node.value}'
				if eval := g.enum_vals[ekey] {
					g.write('${eval}')
				} else {
					g.write('0')
				}
			} else if node.value == 'len' && base.kind == .ident {
				base_type := g.tc.cur_scope.lookup(base.value) or { '' }
				if base_type.starts_with('[]') || base_type.starts_with('map[') {
					g.gen_expr(base_id)
					g.write('.len')
				} else if base_type.contains('[') {
					arr_len := base_type.after('[').before(']')
					g.write(arr_len)
				} else if base_type == 'string' {
					g.gen_expr(base_id)
					g.write('.len')
				} else {
					g.gen_expr(base_id)
					g.write('.len')
				}
			} else {
				mut is_ptr := false
				if base.kind == .ident {
					if typ := g.tc.cur_scope.lookup(base.value) {
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
		}
		.index {
			base_id := g.a.child(&node, 0)
			base_type := g.tc.resolve_type(base_id)
			if node.value == 'range' {
				g.gen_slice_expr(node, base_id, base_type)
			} else if base_type.starts_with('map[') {
				key_type := base_type[4..base_type.index_u8(`]`)]
				val_type := base_type[base_type.index_u8(`]`) + 1..]
				c_val := g.tc.c_type(val_type)
				get_fn := if key_type == 'string' { 'hashmap_get_string' } else { 'hashmap_get_int' }
				g.write('*(${c_val}*)${get_fn}(&')
				g.gen_expr(base_id)
				g.write(', ')
				g.gen_expr(g.a.child(&node, 1))
				g.write(')')
			} else if base_type.starts_with('[]') {
				elem_type := base_type[2..]
				c_elem := g.tc.c_type(elem_type)
				g.write('*(${c_elem}*)array_get(')
				g.gen_expr(base_id)
				g.write(', ')
				g.gen_expr(g.a.child(&node, 1))
				g.write(')')
			} else {
				g.gen_expr(base_id)
				g.write('[')
				g.gen_expr(g.a.child(&node, 1))
				g.write(']')
			}
		}
		.array_init {
			elem_type := node.value
			c_elem := g.tc.c_type(elem_type)
			g.write('array_new(sizeof(${c_elem}), 0, 0)')
		}
		.map_init {
			g.gen_map_init(node)
		}
		.cast_expr {
			g.write('(${g.tc.c_type(node.value)})(')
			g.gen_expr(g.a.child(&node, 0))
			g.write(')')
		}
		.struct_init {
			g.gen_struct_init(node)
		}
		.if_expr {
			g.gen_if_expr(node)
		}
		.array_literal {
			g.write('{')
			for i in 0 .. node.children_count {
				if i > 0 {
					g.write(', ')
				}
				g.gen_expr(g.a.child(&node, i))
			}
			g.write('}')
		}
		.nil_literal {
			g.write('NULL')
		}
		.none_expr {
			g.write('(Optional){.ok = false}')
		}
		.or_expr {
			g.gen_or_expr(node)
		}
		.empty {}
		else {}
	}
}

fn (mut g FlatGen) gen_decl_or_expr(lhs flat.Node, or_node flat.Node) {
	expr_id := g.a.child(&or_node, 0)
	or_body_id := g.a.child(&or_node, 1)
	or_body := g.a.nodes[int(or_body_id)]
	tmp := g.tmp_name()
	g.write('Optional ${tmp} = ')
	g.gen_expr(expr_id)
	g.writeln(';')
	g.writeln('int ${c_name(lhs.value)};')
	g.writeln('if (${tmp}.ok) {')
	g.indent++
	g.writeln('${c_name(lhs.value)} = ${tmp}.value;')
	g.indent--
	g.write('} else {')
	if or_body.children_count > 0 {
		g.writeln('')
		g.indent++
		for i in 0 .. or_body.children_count {
			child_id := g.a.child(&or_body, i)
			child := g.a.nodes[int(child_id)]
			if i == or_body.children_count - 1 && child.kind == .expr_stmt {
				inner := g.a.child_node(&child, 0)
				if inner.kind == .call && g.is_noreturn_call(inner) {
					g.gen_node(child_id)
				} else {
					g.write('${c_name(lhs.value)} = ')
					g.gen_expr(g.a.child(&child, 0))
					g.writeln(';')
				}
			} else {
				g.gen_node(child_id)
			}
		}
		g.indent--
	}
	g.writeln('}')
	if lhs.kind == .ident {
		g.tc.cur_scope.insert(lhs.value, 'int')
	}
}

fn (g &FlatGen) is_noreturn_call(node &flat.Node) bool {
	if node.kind != .call || node.children_count == 0 {
		return false
	}
	fn_node := g.a.child_node(node, 0)
	return fn_node.value in ['panic', 'exit']
}

fn (mut g FlatGen) tmp_name() string {
	g.tmp_count++
	return '_t${g.tmp_count}'
}

fn (mut g FlatGen) gen_or_expr(node flat.Node) {
	expr_id := g.a.child(&node, 0)
	or_body_id := g.a.child(&node, 1)
	or_body := g.a.nodes[int(or_body_id)]
	tmp := g.tmp_name()
	g.write('({Optional ${tmp} = ')
	g.gen_expr(expr_id)
	g.write('; ${tmp}.ok ? ${tmp}.value : ')
	if or_body.children_count == 1 {
		last_id := g.a.child(&or_body, or_body.children_count - 1)
		last := g.a.nodes[int(last_id)]
		if last.kind == .expr_stmt {
			g.gen_expr(g.a.child(&last, 0))
		} else {
			g.gen_expr(last_id)
		}
	} else {
		g.write('({')
		for i in 0 .. or_body.children_count {
			child_id := g.a.child(&or_body, i)
			child := g.a.nodes[int(child_id)]
			if i == or_body.children_count - 1 && child.kind == .expr_stmt {
				g.gen_expr(g.a.child(&child, 0))
				g.write(';')
			} else {
				g.gen_node(child_id)
			}
		}
		g.write('})')
	}
	g.write(';})')
}

fn (mut g FlatGen) gen_or_expr_stmt(node flat.Node) {
	expr_id := g.a.child(&node, 0)
	or_body_id := g.a.child(&node, 1)
	or_body := g.a.nodes[int(or_body_id)]
	tmp := g.tmp_name()
	g.writeln('Optional ${tmp} = ')
	g.gen_expr(expr_id)
	g.writeln(';')
	g.writeln('if (!${tmp}.ok) {')
	g.indent++
	for i in 0 .. or_body.children_count {
		g.gen_node(g.a.child(&or_body, i))
	}
	g.indent--
	g.writeln('}')
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

fn (mut g FlatGen) gen_map_init(node flat.Node) {
	map_type := node.value
	key_type := map_type[4..map_type.index_u8(`]`)]
	val_type := map_type[map_type.index_u8(`]`) + 1..]
	c_key := g.tc.c_type(key_type)
	c_val := g.tc.c_type(val_type)
	g.write('hashmap_new(sizeof(${c_key}), sizeof(${c_val}))')
}

fn (mut g FlatGen) gen_call(node flat.Node) {
	fn_node := g.a.child_node(&node, 0)
	fn_name := fn_node.value
	match fn_name {
		'panic' {
			g.write('v_panic(')
			if node.children_count > 1 {
				g.gen_expr(g.a.child(&node, 1))
			}
			g.write(')')
			return
		}
		'println', 'print' {
			g.write(fn_name)
			g.write('(')
			if node.children_count > 1 {
				arg_id := g.a.child(&node, 1)
				arg_type := g.tc.resolve_type(arg_id)
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
			mut is_method := false
			mut is_c_call := false
			mut method_name := ''
			mut base_id := flat.NodeId(0)
			if fn_node.kind == .selector {
				base := g.a.child_node(fn_node, 0)
				if base.kind == .ident && base.value == 'C' {
					g.write(fn_node.value)
					is_c_call = true
				} else if g.is_flag_enum_method(fn_node) {
					g.gen_flag_enum_call(node)
					return
				} else {
					base_type := g.tc.resolve_type(g.a.child(fn_node, 0))
					if base_type.starts_with('[]') {
						g.gen_array_method_call(node, fn_node, base_type)
						return
					}
					if base_type.starts_with('map[') {
						if fn_node.value == 'delete' {
							g.gen_map_delete(node, fn_node, base_type)
							return
						} else if fn_node.value == 'clone' {
							g.write('hashmap_clone(')
							g.gen_expr(g.a.child(fn_node, 0))
							g.write(')')
							return
						}
					}
					clean_type := base_type.trim_left('&').trim_right('*')
					method_name = '${clean_type}.${fn_node.value}'
					if method_name in g.tc.fn_param_types {
						is_method = true
						base_id = g.a.child(fn_node, 0)
						g.write(c_name(method_name))
					} else {
						g.gen_expr(g.a.child(&node, 0))
					}
				}
			} else {
				g.gen_expr(g.a.child(&node, 0))
			}
			g.write('(')
			actual_fn := if is_method { method_name } else { fn_name }
			param_types := g.tc.fn_param_types[actual_fn]
			mut arg_start := 1
			if is_method {
				base_type := g.tc.resolve_type(base_id)
				is_ptr_base := base_type.ends_with('*')
				wants_ptr := param_types.len > 0 && param_types[0].ends_with('*')
				if wants_ptr && !is_ptr_base {
					g.write('&')
				} else if !wants_ptr && is_ptr_base {
					g.write('*')
				}
				g.gen_expr(base_id)
				arg_start = 1
			}
			for i in arg_start .. node.children_count {
				if is_method || i > 1 {
					g.write(', ')
				}
				arg_idx := if is_method { i } else { i - 1 }
				if !is_c_call && arg_idx < param_types.len && param_types[arg_idx].ends_with('*') {
					g.write('&')
				}
				g.gen_expr(g.a.child(&node, i))
			}
			g.write(')')
		}
	}
}

fn (g &FlatGen) is_flag_enum_method(fn_node &flat.Node) bool {
	if fn_node.kind != .selector {
		return false
	}
	method := fn_node.value
	if method !in ['has', 'all', 'set', 'clear'] {
		return false
	}
	base_type := g.tc.resolve_type(g.a.child(fn_node, 0))
	clean := base_type.trim_left('&').trim_right('*')
	return clean == 'int' || clean in g.tc.flag_enums || clean in g.tc.enum_names
}

fn (mut g FlatGen) gen_flag_enum_call(node flat.Node) {
	fn_node := g.a.child_node(&node, 0)
	method := fn_node.value
	base_id := g.a.child(fn_node, 0)
	match method {
		'has' {
			g.write('((')
			g.gen_expr(base_id)
			g.write(' & ')
			if node.children_count > 1 {
				g.gen_expr(g.a.child(&node, 1))
			}
			g.write(') != 0)')
		}
		'all' {
			g.write('((')
			g.gen_expr(base_id)
			g.write(' & (')
			if node.children_count > 1 {
				g.gen_expr(g.a.child(&node, 1))
			}
			g.write(')) == (')
			if node.children_count > 1 {
				g.gen_expr(g.a.child(&node, 1))
			}
			g.write('))')
		}
		'set' {
			g.gen_expr(base_id)
			g.write(' |= ')
			if node.children_count > 1 {
				g.gen_expr(g.a.child(&node, 1))
			}
		}
		'clear' {
			g.gen_expr(base_id)
			g.write(' &= ~(')
			if node.children_count > 1 {
				g.gen_expr(g.a.child(&node, 1))
			}
			g.write(')')
		}
		else {}
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
			typ := g.tc.resolve_type(child_id)
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

fn (g &FlatGen) is_string_node(id flat.NodeId) bool {
	return g.tc.resolve_type(id) == 'string'
}

fn (mut g FlatGen) forward_decls() {
	for i, node in g.a.nodes {
		if node.kind == .fn_decl && node.value != 'main' {
			if g.has_builtins && i < g.a.user_code_start {
				continue
			}
			if g.used_fns.len > 0 && node.value !in g.used_fns {
				continue
			}
			g.write(g.tc.c_type(node.typ))
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
		g.write(g.tc.c_type(p.typ))
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
		g.writeln("string _str_${i} = {\"${c_escape(s)}\", ${s.len}, 1};")
	}
	if g.str_lits.len > 0 {
		g.writeln('')
	}
}

fn (mut g FlatGen) preamble() {
	g.writeln('#include <stdio.h>')
	g.writeln('#include <stdlib.h>')
	g.writeln('#include <string.h>')
	g.writeln('#include <stddef.h>')
	g.writeln('#include <unistd.h>')
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
	g.writeln('typedef void* voidptr;')
	g.writeln('#define true 1')
	g.writeln('#define false 0')
	g.writeln('')
	if !g.has_builtins {
		g.writeln('typedef struct {')
		g.writeln('\tchar* str;')
		g.writeln('\tint len;')
		g.writeln('} string;')
		g.writeln('')
	}
	if g.has_builtins {
		return
	}
	g.writeln('typedef struct { bool ok; int value; string msg; } Optional;')
	g.writeln('')
	g.writeln('typedef struct { void* data; int len; int cap; int elem_size; } Array;')
	g.writeln('')
	g.writeln('Array array_new(int elem_size, int len, int cap) {')
	g.writeln('\tArray a; a.elem_size = elem_size; a.len = len; a.cap = cap > len ? cap : (len > 0 ? len : 4);')
	g.writeln('\ta.data = calloc(a.cap, elem_size); return a;')
	g.writeln('}')
	g.writeln('Array array_literal(int elem_size, int len, void* data) {')
	g.writeln('\tArray a = array_new(elem_size, len, len > 0 ? len : 1);')
	g.writeln('\tif (len > 0) memcpy(a.data, data, len * elem_size); return a;')
	g.writeln('}')
	g.writeln('void array_push(Array* a, void* elem) {')
	g.writeln('\tif (a->len >= a->cap) { a->cap = a->cap < 4 ? 4 : a->cap * 2; a->data = realloc(a->data, a->elem_size); }')
	g.writeln('\tmemcpy((char*)a->data + a->len * a->elem_size, elem, a->elem_size); a->len++;')
	g.writeln('}')
	g.writeln('void* array_get(Array a, int idx) { return (char*)a.data + idx * a.elem_size; }')
	g.writeln('Array array_clone(Array a) {')
	g.writeln('\tArray b = array_new(a.elem_size, a.len, a.cap);')
	g.writeln('\tmemcpy(b.data, a.data, a.len * a.elem_size); return b;')
	g.writeln('}')
	g.writeln('Array array_slice(Array a, int start, int end) {')
	g.writeln('\tint slen = end - start; if (slen < 0) slen = 0;')
	g.writeln('\tArray b = array_new(a.elem_size, slen, slen > 0 ? slen : 1);')
	g.writeln('\tif (slen > 0) memcpy(b.data, (char*)a.data + start * a.elem_size, slen * a.elem_size); return b;')
	g.writeln('}')
	g.writeln('int array_index_int(Array a, int val) {')
	g.writeln('\tfor (int i = 0; i < a.len; i++) if (*(int*)array_get(a, i) == val) return i; return -1;')
	g.writeln('}')
	g.writeln('int array_index_string(Array a, string val) {')
	g.writeln('\tfor (int i = 0; i < a.len; i++) if (string__eq(*(string*)array_get(a, i), val)) return i; return -1;')
	g.writeln('}')
	g.writeln('bool array_contains_int(Array a, int val) { return array_index_int(a, val) >= 0; }')
	g.writeln('bool array_contains_string(Array a, string val) { return array_index_string(a, val) >= 0; }')
	g.writeln('bool array_eq_int(Array a, Array b) {')
	g.writeln('\tif (a.len != b.len) return 0;')
	g.writeln('\tfor (int i = 0; i < a.len; i++) if (*(int*)array_get(a, i) != *(int*)array_get(b, i)) return 0;')
	g.writeln('\treturn 1;')
	g.writeln('}')
	g.writeln('')
	g.writeln('typedef struct { unsigned int hash; bool used; } MapSlot;')
	g.writeln('typedef struct { MapSlot* slots; char* keys; char* vals; int cap; int len; int key_size; int val_size; } HashMap;')
	g.writeln('')
	g.writeln('static unsigned int _map_hash_bytes(const void* key, int key_size) {')
	g.writeln('\tunsigned int h = 2166136261u; const unsigned char* p = (const unsigned char*)key;')
	g.writeln('\tfor (int i = 0; i < key_size; i++) { h ^= p[i]; h *= 16777619u; } return h ? h : 1;')
	g.writeln('}')
	g.writeln('static unsigned int _map_hash_string(string key) {')
	g.writeln('\treturn _map_hash_bytes(key.str, key.len);')
	g.writeln('}')
	g.writeln('HashMap hashmap_new(int key_size, int val_size) {')
	g.writeln('\tHashMap m = {0}; m.cap = 16; m.key_size = key_size; m.val_size = val_size;')
	g.writeln('\tm.slots = (MapSlot*)calloc(m.cap, sizeof(MapSlot));')
	g.writeln('\tm.keys = (char*)calloc(m.cap, key_size); m.vals = (char*)calloc(m.cap, val_size); return m;')
	g.writeln('}')
	g.writeln('static void _hashmap_set_internal(HashMap* m, const void* key, unsigned int hash, const void* val);')
	g.writeln('static void _hashmap_grow(HashMap* m) {')
	g.writeln('\tint old_cap = m->cap; MapSlot* old_slots = m->slots; char* old_keys = m->keys; char* old_vals = m->vals;')
	g.writeln('\tm->cap *= 2; m->len = 0;')
	g.writeln('\tm->slots = (MapSlot*)calloc(m->cap, sizeof(MapSlot));')
	g.writeln('\tm->keys = (char*)calloc(m->cap, m->key_size); m->vals = (char*)calloc(m->cap, m->val_size);')
	g.writeln('\tfor (int i = 0; i < old_cap; i++) if (old_slots[i].used)')
	g.writeln('\t\t_hashmap_set_internal(m, old_keys + i * m->key_size, old_slots[i].hash, old_vals + i * m->val_size);')
	g.writeln('\tfree(old_slots); free(old_keys); free(old_vals);')
	g.writeln('}')
	g.writeln('static void _hashmap_set_internal(HashMap* m, const void* key, unsigned int hash, const void* val) {')
	g.writeln('\tif (m->len * 2 >= m->cap) _hashmap_grow(m);')
	g.writeln('\tunsigned int idx = hash & (m->cap - 1);')
	g.writeln('\twhile (m->slots[idx].used) {')
	g.writeln('\t\tif (m->slots[idx].hash == hash && memcmp(m->keys + idx * m->key_size, key, m->key_size) == 0) {')
	g.writeln('\t\t\tmemcpy(m->vals + idx * m->val_size, val, m->val_size); return; }')
	g.writeln('\t\tidx = (idx + 1) & (m->cap - 1);')
	g.writeln('\t}')
	g.writeln('\tm->slots[idx].used = 1; m->slots[idx].hash = hash;')
	g.writeln('\tmemcpy(m->keys + idx * m->key_size, key, m->key_size);')
	g.writeln('\tmemcpy(m->vals + idx * m->val_size, val, m->val_size); m->len++;')
	g.writeln('}')
	g.writeln('void hashmap_set_int(HashMap* m, int key, const void* val) {')
	g.writeln('\t_hashmap_set_internal(m, &key, _map_hash_bytes(&key, sizeof(int)), val);')
	g.writeln('}')
	g.writeln('void hashmap_set_string(HashMap* m, string key, const void* val) {')
	g.writeln('\t_hashmap_set_internal(m, &key, _map_hash_string(key), val);')
	g.writeln('}')
	g.writeln('void* hashmap_get_int(HashMap* m, int key) {')
	g.writeln('\tunsigned int hash = _map_hash_bytes(&key, sizeof(int));')
	g.writeln('\tunsigned int idx = hash & (m->cap - 1);')
	g.writeln('\twhile (m->slots[idx].used) {')
	g.writeln('\t\tif (m->slots[idx].hash == hash && *(int*)(m->keys + idx * m->key_size) == key) return m->vals + idx * m->val_size;')
	g.writeln('\t\tidx = (idx + 1) & (m->cap - 1); } return NULL;')
	g.writeln('}')
	g.writeln('void* hashmap_get_string(HashMap* m, string key) {')
	g.writeln('\tunsigned int hash = _map_hash_string(key);')
	g.writeln('\tunsigned int idx = hash & (m->cap - 1);')
	g.writeln('\twhile (m->slots[idx].used) {')
	g.writeln('\t\tif (m->slots[idx].hash == hash && string__eq(*(string*)(m->keys + idx * m->key_size), key)) return m->vals + idx * m->val_size;')
	g.writeln('\t\tidx = (idx + 1) & (m->cap - 1); } return NULL;')
	g.writeln('}')
	g.writeln('bool hashmap_has_int(HashMap* m, int key) { return hashmap_get_int(m, key) != NULL; }')
	g.writeln('bool hashmap_has_string(HashMap* m, string key) { return hashmap_get_string(m, key) != NULL; }')
	g.writeln('HashMap hashmap_clone(HashMap m) {')
	g.writeln('\tHashMap n = hashmap_new(m.key_size, m.val_size);')
	g.writeln('\tfree(n.slots); free(n.keys); free(n.vals);')
	g.writeln('\tn.cap = m.cap; n.len = m.len;')
	g.writeln('\tn.slots = (MapSlot*)calloc(m.cap, sizeof(MapSlot)); memcpy(n.slots, m.slots, m.cap * sizeof(MapSlot));')
	g.writeln('\tn.keys = (char*)calloc(m.cap, m.key_size); memcpy(n.keys, m.keys, m.cap * m.key_size);')
	g.writeln('\tn.vals = (char*)calloc(m.cap, m.val_size); memcpy(n.vals, m.vals, m.cap * m.val_size);')
	g.writeln('\treturn n;')
	g.writeln('}')
	g.writeln('void hashmap_delete_int(HashMap* m, int key) {')
	g.writeln('\tunsigned int hash = _map_hash_bytes(&key, sizeof(int));')
	g.writeln('\tunsigned int idx = hash & (m->cap - 1);')
	g.writeln('\twhile (m->slots[idx].used) {')
	g.writeln('\t\tif (m->slots[idx].hash == hash && *(int*)(m->keys + idx * m->key_size) == key) { m->slots[idx].used = 0; m->len--; return; }')
	g.writeln('\t\tidx = (idx + 1) & (m->cap - 1); }')
	g.writeln('}')
	g.writeln('void hashmap_delete_string(HashMap* m, string key) {')
	g.writeln('\tunsigned int hash = _map_hash_string(key);')
	g.writeln('\tunsigned int idx = hash & (m->cap - 1);')
	g.writeln('\twhile (m->slots[idx].used) {')
	g.writeln('\t\tif (m->slots[idx].hash == hash && string__eq(*(string*)(m->keys + idx * m->key_size), key)) { m->slots[idx].used = 0; m->len--; return; }')
	g.writeln('\t\tidx = (idx + 1) & (m->cap - 1); }')
	g.writeln('}')
	g.writeln('')
	g.writeln('string Array_int_str(Array a) {')
	g.writeln('\tstring s = (string){"[", 1};')
	g.writeln('\tfor (int i = 0; i < a.len; i++) {')
	g.writeln('\t\tif (i > 0) s = string__plus(s, (string){", ", 2});')
	g.writeln('\t\ts = string__plus(s, int_str(*(int*)array_get(a, i)));')
	g.writeln('\t} return string__plus(s, (string){"]", 1});')
	g.writeln('}')
	g.writeln('string Array_string_str(Array a) {')
	g.writeln('\tstring s = (string){"[\'", 2};')
	g.writeln('\tfor (int i = 0; i < a.len; i++) {')
	g.writeln('\t\tif (i > 0) s = string__plus(s, (string){"\', \'", 4});')
	g.writeln('\t\ts = string__plus(s, *(string*)array_get(a, i));')
	g.writeln('\t} return string__plus(s, (string){"\']", 2});')
	g.writeln('}')
	g.writeln('string Array_u8_str(Array a) {')
	g.writeln('\tstring s = (string){"[", 1};')
	g.writeln('\tfor (int i = 0; i < a.len; i++) {')
	g.writeln('\t\tif (i > 0) s = string__plus(s, (string){", ", 2});')
	g.writeln('\t\ts = string__plus(s, int_str((int)*(u8*)array_get(a, i)));')
	g.writeln('\t} return string__plus(s, (string){"]", 1});')
	g.writeln('}')
	g.writeln('')
}

fn (mut g FlatGen) runtime_fns() {
	g.writeln('typedef struct { bool ok; int value; string msg; } Optional;')
	g.writeln('')
	if !g.has_builtins {
		g.writeln('typedef struct { void* data; int len; int cap; int elem_size; } Array;')
	}
	g.writeln('Array array_new(int elem_size, int len, int cap) {')
	g.writeln('\tArray a; a.elem_size = elem_size; a.len = len; a.cap = cap > len ? cap : (len > 0 ? len : 4);')
	g.writeln('\ta.data = calloc(a.cap, elem_size); return a;')
	g.writeln('}')
	g.writeln('void array_push(Array* a, void* elem) {')
	g.writeln('\tif (a->len >= a->cap) { a->cap = a->cap < 4 ? 4 : a->cap * 2; a->data = realloc(a->data, a->cap * a->elem_size); }')
	g.writeln('\tmemcpy((char*)a->data + a->len * a->elem_size, elem, a->elem_size); a->len++;')
	g.writeln('}')
	g.writeln('void* array_get(Array a, int idx) { return (char*)a.data + idx * a.elem_size; }')
	g.writeln('Array array_clone(Array a) {')
	g.writeln('\tArray b = array_new(a.elem_size, a.len, a.cap);')
	g.writeln('\tmemcpy(b.data, a.data, a.len * a.elem_size); return b;')
	g.writeln('}')
	g.writeln('Array array_slice(Array a, int start, int end) {')
	g.writeln('\tint slen = end - start; if (slen < 0) slen = 0;')
	g.writeln('\tArray b = array_new(a.elem_size, slen, slen > 0 ? slen : 1);')
	g.writeln('\tif (slen > 0) memcpy(b.data, (char*)a.data + start * a.elem_size, slen * a.elem_size); return b;')
	g.writeln('}')
	g.writeln('void array_delete(Array* a, int idx) {')
	g.writeln('\tif (idx < a->len - 1) memmove((char*)a->data + idx * a->elem_size, (char*)a->data + (idx+1) * a->elem_size, (a->len - idx - 1) * a->elem_size);')
	g.writeln('\ta->len--;')
	g.writeln('}')
	g.writeln('int array_index_int(Array a, int val) {')
	g.writeln('\tfor (int i = 0; i < a.len; i++) if (*(int*)array_get(a, i) == val) return i; return -1;')
	g.writeln('}')
	g.writeln('bool array_contains_int(Array a, int val) { return array_index_int(a, val) >= 0; }')
	g.writeln('')
	g.writeln('static bool string__eq(string a, string b);')
	g.writeln('int array_index_string(Array a, string val) {')
	g.writeln('\tfor (int i = 0; i < a.len; i++) if (string__eq(*(string*)array_get(a, i), val)) return i; return -1;')
	g.writeln('}')
	g.writeln('bool array_contains_string(Array a, string val) { return array_index_string(a, val) >= 0; }')
	if !g.has_builtins {
		g.writeln('typedef struct { unsigned int hash; bool used; } MapSlot;')
		g.writeln('typedef struct { MapSlot* slots; char* keys; char* vals; int cap; int len; int key_size; int val_size; } HashMap;')
	}
	g.writeln('')
	g.writeln('static unsigned int _map_hash_bytes(const void* key, int key_size) {')
	g.writeln('\tunsigned int h = 2166136261u; const unsigned char* p = (const unsigned char*)key;')
	g.writeln('\tfor (int i = 0; i < key_size; i++) { h ^= p[i]; h *= 16777619u; } return h ? h : 1;')
	g.writeln('}')
	g.writeln('static unsigned int _map_hash_string(string key) {')
	g.writeln('\treturn _map_hash_bytes(key.str, key.len);')
	g.writeln('}')
	g.writeln('HashMap hashmap_new(int key_size, int val_size) {')
	g.writeln('\tHashMap m = {0}; m.cap = 16; m.key_size = key_size; m.val_size = val_size;')
	g.writeln('\tm.slots = (MapSlot*)calloc(m.cap, sizeof(MapSlot));')
	g.writeln('\tm.keys = (char*)calloc(m.cap, key_size); m.vals = (char*)calloc(m.cap, val_size); return m;')
	g.writeln('}')
	g.writeln('static void _hashmap_set_internal(HashMap* m, const void* key, unsigned int hash, const void* val);')
	g.writeln('static void _hashmap_grow(HashMap* m) {')
	g.writeln('\tint old_cap = m->cap; MapSlot* old_slots = m->slots; char* old_keys = m->keys; char* old_vals = m->vals;')
	g.writeln('\tm->cap *= 2; m->len = 0;')
	g.writeln('\tm->slots = (MapSlot*)calloc(m->cap, sizeof(MapSlot));')
	g.writeln('\tm->keys = (char*)calloc(m->cap, m->key_size); m->vals = (char*)calloc(m->cap, m->val_size);')
	g.writeln('\tfor (int i = 0; i < old_cap; i++) if (old_slots[i].used)')
	g.writeln('\t\t_hashmap_set_internal(m, old_keys + i * m->key_size, old_slots[i].hash, old_vals + i * m->val_size);')
	g.writeln('\tfree(old_slots); free(old_keys); free(old_vals);')
	g.writeln('}')
	g.writeln('static void _hashmap_set_internal(HashMap* m, const void* key, unsigned int hash, const void* val) {')
	g.writeln('\tif (m->len * 2 >= m->cap) _hashmap_grow(m);')
	g.writeln('\tunsigned int idx = hash & (m->cap - 1);')
	g.writeln('\twhile (m->slots[idx].used) {')
	g.writeln('\t\tif (m->slots[idx].hash == hash && memcmp(m->keys + idx * m->key_size, key, m->key_size) == 0) {')
	g.writeln('\t\t\tmemcpy(m->vals + idx * m->val_size, val, m->val_size); return; }')
	g.writeln('\t\tidx = (idx + 1) & (m->cap - 1);')
	g.writeln('\t}')
	g.writeln('\tm->slots[idx].used = 1; m->slots[idx].hash = hash;')
	g.writeln('\tmemcpy(m->keys + idx * m->key_size, key, m->key_size);')
	g.writeln('\tmemcpy(m->vals + idx * m->val_size, val, m->val_size); m->len++;')
	g.writeln('}')
	g.writeln('void hashmap_set_int(HashMap* m, int key, const void* val) {')
	g.writeln('\t_hashmap_set_internal(m, &key, _map_hash_bytes(&key, sizeof(int)), val);')
	g.writeln('}')
	g.writeln('void hashmap_set_string(HashMap* m, string key, const void* val) {')
	g.writeln('\t_hashmap_set_internal(m, &key, _map_hash_string(key), val);')
	g.writeln('}')
	g.writeln('void* hashmap_get_int(HashMap* m, int key) {')
	g.writeln('\tunsigned int hash = _map_hash_bytes(&key, sizeof(int));')
	g.writeln('\tunsigned int idx = hash & (m->cap - 1);')
	g.writeln('\twhile (m->slots[idx].used) {')
	g.writeln('\t\tif (m->slots[idx].hash == hash && *(int*)(m->keys + idx * m->key_size) == key) return m->vals + idx * m->val_size;')
	g.writeln('\t\tidx = (idx + 1) & (m->cap - 1); } return NULL;')
	g.writeln('}')
	g.writeln('void* hashmap_get_string(HashMap* m, string key) {')
	g.writeln('\tunsigned int hash = _map_hash_string(key);')
	g.writeln('\tunsigned int idx = hash & (m->cap - 1);')
	g.writeln('\twhile (m->slots[idx].used) {')
	g.writeln('\t\tif (m->slots[idx].hash == hash && string__eq(*(string*)(m->keys + idx * m->key_size), key)) return m->vals + idx * m->val_size;')
	g.writeln('\t\tidx = (idx + 1) & (m->cap - 1); } return NULL;')
	g.writeln('}')
	g.writeln('bool hashmap_has_int(HashMap* m, int key) { return hashmap_get_int(m, key) != NULL; }')
	g.writeln('bool hashmap_has_string(HashMap* m, string key) { return hashmap_get_string(m, key) != NULL; }')
	g.writeln('HashMap hashmap_clone(HashMap m) {')
	g.writeln('\tHashMap n = hashmap_new(m.key_size, m.val_size);')
	g.writeln('\tfree(n.slots); free(n.keys); free(n.vals);')
	g.writeln('\tn.cap = m.cap; n.len = m.len;')
	g.writeln('\tn.slots = (MapSlot*)calloc(m.cap, sizeof(MapSlot)); memcpy(n.slots, m.slots, m.cap * sizeof(MapSlot));')
	g.writeln('\tn.keys = (char*)calloc(m.cap, m.key_size); memcpy(n.keys, m.keys, m.cap * m.key_size);')
	g.writeln('\tn.vals = (char*)calloc(m.cap, m.val_size); memcpy(n.vals, m.vals, m.cap * m.val_size);')
	g.writeln('\treturn n;')
	g.writeln('}')
	g.writeln('void hashmap_delete_int(HashMap* m, int key) {')
	g.writeln('\tunsigned int hash = _map_hash_bytes(&key, sizeof(int));')
	g.writeln('\tunsigned int idx = hash & (m->cap - 1);')
	g.writeln('\twhile (m->slots[idx].used) {')
	g.writeln('\t\tif (m->slots[idx].hash == hash && *(int*)(m->keys + idx * m->key_size) == key) { m->slots[idx].used = 0; m->len--; return; }')
	g.writeln('\t\tidx = (idx + 1) & (m->cap - 1); }')
	g.writeln('}')
	g.writeln('void hashmap_delete_string(HashMap* m, string key) {')
	g.writeln('\tunsigned int hash = _map_hash_string(key);')
	g.writeln('\tunsigned int idx = hash & (m->cap - 1);')
	g.writeln('\twhile (m->slots[idx].used) {')
	g.writeln('\t\tif (m->slots[idx].hash == hash && string__eq(*(string*)(m->keys + idx * m->key_size), key)) { m->slots[idx].used = 0; m->len--; return; }')
	g.writeln('\t\tidx = (idx + 1) & (m->cap - 1); }')
	g.writeln('}')
	g.writeln('')
	g.writeln('void println(string s) {')
	g.writeln('\tfwrite(s.str, 1, s.len, stdout);')
	g.writeln('\tputchar(10);')
	g.writeln('}')
	g.writeln('void print(string s) {')
	g.writeln('\tfwrite(s.str, 1, s.len, stdout);')
	g.writeln('}')
	g.writeln('void eprintln(string s) {')
	g.writeln('\tfwrite(s.str, 1, s.len, stderr);')
	g.writeln('\tputchar(10);')
	g.writeln('}')
	g.writeln('string int_str(int n) {')
	g.writeln('\tchar* buf = malloc(20);')
	g.writeln('\tint len = snprintf(buf, 20, "%d", n);')
	g.writeln('\treturn (string){buf, len, 0};')
	g.writeln('}')
	g.writeln('string string__plus(string a, string b) {')
	g.writeln('\tint len = a.len + b.len;')
	g.writeln('\tchar* s = malloc(len + 1);')
	g.writeln('\tmemcpy(s, a.str, a.len);')
	g.writeln('\tmemcpy(s + a.len, b.str, b.len);')
	g.writeln('\ts[len] = 0;')
	g.writeln('\treturn (string){s, len, 0};')
	g.writeln('}')
	g.writeln('void* memdup(const void* src, int sz) {')
	g.writeln('\tvoid* p = malloc(sz);')
	g.writeln('\tmemcpy(p, src, sz);')
	g.writeln('\treturn p;')
	g.writeln('}')
	g.writeln('bool string__eq(string a, string b) {')
	g.writeln('\tif (a.len != b.len) return 0;')
	g.writeln('\treturn memcmp(a.str, b.str, a.len) == 0;')
	g.writeln('}')
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
	g.writeln('\treturn (string){s, len, 0};')
	g.writeln('}')
	g.writeln('string i64_str(i64 n) {')
	g.writeln('\tchar* buf = malloc(24); int len = snprintf(buf, 24, "%lld", (long long)n);')
	g.writeln('\treturn (string){buf, len, 0};')
	g.writeln('}')
	g.writeln('string u8_str(u8 n) { return int_str((int)n); }')
	g.writeln('string bool_str(bool b) { return b ? (string){"true", 4, 1} : (string){"false", 5, 1}; }')
	g.writeln('string double_str(double d) {')
	g.writeln('\tchar* buf = malloc(32); int len = snprintf(buf, 32, "%g", d);')
	g.writeln('\treturn (string){buf, len, 0};')
	g.writeln('}')
	g.writeln('bool string__contains(string s, string sub) {')
	g.writeln('\tif (sub.len > s.len) return 0;')
	g.writeln('\tfor (int i = 0; i <= s.len - sub.len; i++) if (memcmp(s.str + i, sub.str, sub.len) == 0) return 1;')
	g.writeln('\treturn 0;')
	g.writeln('}')
	g.writeln('string string__replace(string s, string old_s, string new_s) {')
	g.writeln('\tif (old_s.len == 0 || old_s.len > s.len) return s;')
	g.writeln('\tint count = 0;')
	g.writeln('\tfor (int i = 0; i <= s.len - old_s.len; i++) if (memcmp(s.str+i, old_s.str, old_s.len)==0) { count++; i += old_s.len-1; }')
	g.writeln('\tif (count == 0) return s;')
	g.writeln('\tint new_len = s.len + count * (new_s.len - old_s.len);')
	g.writeln('\tchar* buf = malloc(new_len + 1); int pos = 0;')
	g.writeln('\tfor (int i = 0; i < s.len; ) {')
	g.writeln('\t\tif (i <= s.len - old_s.len && memcmp(s.str+i, old_s.str, old_s.len)==0) { memcpy(buf+pos, new_s.str, new_s.len); pos += new_s.len; i += old_s.len; }')
	g.writeln('\t\telse { buf[pos++] = s.str[i++]; }')
	g.writeln('\t} buf[new_len] = 0; return (string){buf, new_len, 0};')
	g.writeln('}')
	g.writeln('bool string__starts_with(string s, string p) {')
	g.writeln('\tif (p.len > s.len) return 0;')
	g.writeln('\treturn memcmp(s.str, p.str, p.len) == 0;')
	g.writeln('}')
	g.writeln('bool string__ends_with(string s, string p) {')
	g.writeln('\tif (p.len > s.len) return 0;')
	g.writeln('\treturn memcmp(s.str + s.len - p.len, p.str, p.len) == 0;')
	g.writeln('}')
	g.writeln('int string__index_u8(string s, u8 c) {')
	g.writeln('\tfor (int i = 0; i < s.len; i++) if (((u8*)s.str)[i] == c) return i;')
	g.writeln('\treturn -1;')
	g.writeln('}')
	g.writeln('int string__last_index_u8(string s, u8 c) {')
	g.writeln('\tfor (int i = s.len - 1; i >= 0; i--) if (((u8*)s.str)[i] == c) return i;')
	g.writeln('\treturn -1;')
	g.writeln('}')
	g.writeln('int string__index_(string s, string p) {')
	g.writeln('\tif (p.len > s.len) return -1;')
	g.writeln('\tfor (int i = 0; i <= s.len - p.len; i++) if (memcmp(s.str + i, p.str, p.len) == 0) return i;')
	g.writeln('\treturn -1;')
	g.writeln('}')
	g.writeln('int string__last_index_(string s, string p) {')
	g.writeln('\tif (p.len > s.len) return -1;')
	g.writeln('\tfor (int i = s.len - p.len; i >= 0; i--) if (memcmp(s.str + i, p.str, p.len) == 0) return i;')
	g.writeln('\treturn -1;')
	g.writeln('}')
	g.writeln('string string__substr(string s, int start, int end) {')
	g.writeln('\tint slen = end - start; if (slen <= 0) return (string){"", 0, 1};')
	g.writeln('\tchar* buf = malloc(slen + 1); memcpy(buf, s.str + start, slen); buf[slen] = 0;')
	g.writeln('\treturn (string){buf, slen, 0};')
	g.writeln('}')
	g.writeln('string string__all_before(string s, string sub) {')
	g.writeln('\tint idx = string__index_(s, sub); if (idx < 0) return s;')
	g.writeln('\treturn string__substr(s, 0, idx);')
	g.writeln('}')
	g.writeln('string string__all_before_last(string s, string sub) {')
	g.writeln('\tint idx = string__last_index_(s, sub); if (idx < 0) return s;')
	g.writeln('\treturn string__substr(s, 0, idx);')
	g.writeln('}')
	g.writeln('string string__all_after(string s, string sub) {')
	g.writeln('\tint idx = string__index_(s, sub); if (idx < 0) return s;')
	g.writeln('\treturn string__substr(s, idx + sub.len, s.len);')
	g.writeln('}')
	g.writeln('string string__all_after_last(string s, string sub) {')
	g.writeln('\tint idx = string__last_index_(s, sub); if (idx < 0) return s;')
	g.writeln('\treturn string__substr(s, idx + sub.len, s.len);')
	g.writeln('}')
	g.writeln('string string__trim_left(string s, string cutset) {')
	g.writeln('\tint i = 0; while (i < s.len) { bool found = 0;')
	g.writeln('\t\tfor (int j = 0; j < cutset.len; j++) if (s.str[i] == cutset.str[j]) { found = 1; break; }')
	g.writeln('\t\tif (!found) break; i++; }')
	g.writeln('\treturn string__substr(s, i, s.len);')
	g.writeln('}')
	g.writeln('string string__trim_right(string s, string cutset) {')
	g.writeln('\tint i = s.len - 1; while (i >= 0) { bool found = 0;')
	g.writeln('\t\tfor (int j = 0; j < cutset.len; j++) if (s.str[i] == cutset.str[j]) { found = 1; break; }')
	g.writeln('\t\tif (!found) break; i--; }')
	g.writeln('\treturn string__substr(s, 0, i + 1);')
	g.writeln('}')
	g.writeln('string string__trim_space(string s) {')
	g.writeln('\treturn string__trim_right(string__trim_left(s, (string){" \\t\\n\\r", 4, 1}), (string){" \\t\\n\\r", 4, 1});')
	g.writeln('}')
	g.writeln('bool string__contains_u8(string s, u8 x) { return string__index_u8(s, x) >= 0; }')
	g.writeln('int string__count(string s, string sub) {')
	g.writeln('\tif (sub.len == 0 || sub.len > s.len) return 0; int c = 0;')
	g.writeln('\tfor (int i = 0; i <= s.len - sub.len; i++) if (memcmp(s.str+i, sub.str, sub.len)==0) { c++; i += sub.len-1; }')
	g.writeln('\treturn c;')
	g.writeln('}')
	g.writeln('string string__after(string s, string sub) { return string__all_after(s, sub); }')
	g.writeln('string string__before(string s, string sub) { return string__all_before(s, sub); }')
	g.writeln('int string__int(string s) { return (int)strtol(s.str, NULL, 10); }')
	g.writeln('Array string__split(string s, string delim) {')
	g.writeln('\tArray a = array_new(sizeof(string), 0, 4);')
	g.writeln('\tif (delim.len == 0) { array_push(&a, &s); return a; }')
	g.writeln('\tint i = 0;')
	g.writeln('\twhile (i <= s.len - delim.len) {')
	g.writeln('\t\tif (memcmp(s.str + i, delim.str, delim.len) == 0) {')
	g.writeln('\t\t\tstring part = string__substr(s, 0, i);')
	g.writeln('\t\t\tarray_push(&a, &part);')
	g.writeln('\t\t\ts = string__substr(s, i + delim.len, s.len);')
	g.writeln('\t\t\ti = 0; continue;')
	g.writeln('\t\t} i++;')
	g.writeln('\t}')
	g.writeln('\tarray_push(&a, &s); return a;')
	g.writeln('}')
	g.writeln('string array_string_join(Array a, string sep) {')
	g.writeln('\tif (a.len == 0) return (string){"", 0, 1};')
	g.writeln('\tint total = 0;')
	g.writeln('\tfor (int i = 0; i < a.len; i++) { total += (*(string*)array_get(a, i)).len; if (i > 0) total += sep.len; }')
	g.writeln('\tchar* buf = malloc(total + 1); int pos = 0;')
	g.writeln('\tfor (int i = 0; i < a.len; i++) {')
	g.writeln('\t\tif (i > 0) { memcpy(buf + pos, sep.str, sep.len); pos += sep.len; }')
	g.writeln('\t\tstring s = *(string*)array_get(a, i); memcpy(buf + pos, s.str, s.len); pos += s.len;')
	g.writeln('\t} buf[total] = 0; return (string){buf, total, 0};')
	g.writeln('}')
	g.writeln('void v_panic(string s) {')
	g.writeln('\tfwrite(s.str, 1, s.len, stderr);')
	g.writeln('\tputc(10, stderr);')
	g.writeln('\texit(1);')
	g.writeln('}')
	g.writeln('Optional optional_ok(int v) { return (Optional){.ok = true, .value = v}; }')
	g.writeln('Optional optional_none() { return (Optional){.ok = false}; }')
	g.writeln('')
}

fn (mut g FlatGen) enum_decls() {
	for name, _ in g.tc.enum_names {
		cn := c_name(name)
		g.writeln('typedef enum {')
		for ekey, eval in g.enum_vals {
			if ekey.starts_with('${name}.') {
				member := ekey[name.len + 1..]
				g.writeln('\t${cn}__${member} = ${eval},')
			}
		}
		g.writeln('} ${cn};')
		g.writeln('')
	}
}

fn (g &FlatGen) skip_builtin_struct(name string) bool {
	return g.has_builtins && name in ['array', 'map', 'DenseArray', 'MapSlot', 'ArrayDataHeader']
}

fn (mut g FlatGen) struct_decls() {
	for name, _ in g.tc.structs {
		if g.skip_builtin_struct(name) {
			continue
		}
		g.writeln('typedef struct ${c_name(name)} ${c_name(name)};')
	}
	for name, variants in g.tc.sum_types {
		g.writeln('typedef struct ${c_name(name)} ${c_name(name)};')
		_ = variants
	}
	for name, _ in g.interfaces {
		g.writeln('typedef struct ${c_name(name)} ${c_name(name)};')
	}
	g.writeln('')
	// Emit interface structs early (before structs that embed them)
	for name, _ in g.interfaces {
		g.writeln('struct ${c_name(name)} {')
		g.writeln('\tint _typ;')
		g.writeln('};')
		g.writeln('')
	}
	// Build set of struct names that are defined
	mut emitted := map[string]bool{}
	for name, _ in g.interfaces {
		emitted[c_name(name)] = true
	}
	// Topological sort: emit structs whose value-type deps are all satisfied
	mut remaining := map[string]bool{}
	for name, _ in g.tc.structs {
		if g.skip_builtin_struct(name) {
			continue
		}
		remaining[name] = true
	}
	for _ in 0 .. 20 {
		if remaining.len == 0 {
			break
		}
		mut progress := false
		for name, _ in remaining {
			cn := c_name(name)
			if cn in emitted {
				remaining.delete(name)
				progress = true
				continue
			}
			mut can_emit := true
			if fields := g.tc.structs[name] {
				for f in fields {
					raw := f.typ.trim_right('*')
					if f.typ.ends_with('*') {
						continue
					}
					if raw in g.tc.structs && raw !in emitted && raw != cn {
						can_emit = false
						break
					}
				}
			}
			if can_emit {
				g.emit_struct(name)
				emitted[cn] = true
				remaining.delete(name)
				progress = true
			}
		}
		if !progress {
			break
		}
	}
	for name, _ in remaining {
		g.emit_struct(name)
	}
	for name, variants in g.tc.sum_types {
		g.writeln('struct ${c_name(name)} {')
		g.writeln('\tint typ;')
		g.writeln('\tunion {')
		for v in variants {
			ct := g.tc.c_type(v)
			field := g.sum_field_name(v)
			if g.variant_references_sum(v, name) {
				g.writeln('\t\t${ct}* ${field};')
			} else {
				g.writeln('\t\t${ct} ${field};')
			}
		}
		g.writeln('\t};')
		g.writeln('};')
		g.writeln('')
	}
}

fn (mut g FlatGen) emit_struct(name string) {
	if fields := g.tc.structs[name] {
		g.writeln('struct ${c_name(name)} {')
		if fields.len == 0 {
			g.writeln('\tint _dummy;')
		}
		for f in fields {
			g.write_struct_field(f)
		}
		g.writeln('};')
		g.writeln('')
	}
}

fn (mut g FlatGen) write_struct_field(f types.StructField) {
	if f.typ.starts_with('fn_ptr:') {
		parts := f.typ['fn_ptr:'.len..].split('|')
		ret := parts[0]
		params := if parts.len > 1 { parts[1] } else { 'void' }
		g.writeln('\t${ret} (*${c_name(f.name)})(${params});')
	} else {
		g.writeln('\t${f.typ} ${c_name(f.name)};')
	}
}

fn (g &FlatGen) variant_references_sum(variant string, sum_name string) bool {
	if fields := g.tc.structs[variant] {
		for f in fields {
			raw := f.typ.trim_right('*').trim_left('&')
			if raw == sum_name {
				return true
			}
		}
	}
	return false
}

fn (g &FlatGen) sum_field_name(variant string) string {
	return match variant {
		'int' { '_int' }
		'i8' { '_i8' }
		'i16' { '_i16' }
		'i64' { '_i64' }
		'u8', 'byte' { '_u8' }
		'u16' { '_u16' }
		'u32' { '_u32' }
		'u64' { '_u64' }
		'f32' { '_f32' }
		'f64' { '_f64' }
		'bool' { '_bool' }
		'string' { '_string' }
		else { c_name(variant) }
	}
}

fn (g &FlatGen) sum_type_index(sum_name string, variant string) int {
	if variants := g.tc.sum_types[sum_name] {
		for i, v in variants {
			if v == variant {
				return i + 1
			}
		}
	}
	return 0
}

fn (mut g FlatGen) global_decls() {
	for name, typ in g.global_types {
		ct := g.tc.c_type(typ)
		if ct == 'void' {
			continue
		}
		g.writeln('${ct} ${c_name(name)};')
	}
	if g.global_types.len > 0 {
		g.writeln('')
	}
}

fn (mut g FlatGen) precompute_consts() string {
	old_sb := g.sb
	g.sb = strings.new_builder(1024)
	for name, val_id in g.const_vals {
		if int(val_id) < 0 || int(val_id) >= g.a.nodes.len {
			continue
		}
		val_node := g.a.nodes[int(val_id)]
		if val_node.kind == .empty {
			continue
		}
		if !g.is_const_expr(val_id) {
			continue
		}
		tmp_sb := g.sb
		g.sb = strings.new_builder(256)
		g.gen_expr(val_id)
		expr_str := g.sb.str()
		g.sb = tmp_sb
		if expr_str.trim_space().len == 0 {
			continue
		}
		typ := g.tc.c_type(g.tc.resolve_type(val_id))
		if typ == 'string' {
			g.writeln('string ${c_name(name)} = ${expr_str};')
		} else {
			g.writeln('const ${typ} ${c_name(name)} = ${expr_str};')
		}
	}
	if g.const_vals.len > 0 {
		g.writeln('')
	}
	result := g.sb.str()
	g.sb = old_sb
	return result
}

fn (g &FlatGen) is_const_expr(id flat.NodeId) bool {
	if int(id) < 0 || int(id) >= g.a.nodes.len {
		return false
	}
	node := g.a.nodes[int(id)]
	return match node.kind {
		.int_literal, .float_literal, .bool_literal, .char_literal {
			true
		}
		.prefix {
			g.is_const_expr(g.a.child(&node, 0))
		}
		.infix {
			g.is_const_expr(g.a.child(&node, 0)) && g.is_const_expr(g.a.child(&node, 1))
		}
		.paren {
			g.is_const_expr(g.a.child(&node, 0))
		}
		.cast_expr {
			g.is_const_expr(g.a.child(&node, 0))
		}
		.ident {
			node.value in g.const_vals
		}
		else {
			false
		}
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
