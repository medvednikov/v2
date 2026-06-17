module c

import strings
import v3.flat
import v3.types

pub struct FlatGen {
mut:
	sb                    strings.Builder
	indent                int
	a                     &flat.FlatAst = unsafe { nil }
	used_fns              map[string]bool
	str_lits              []string
	global_types          map[string]types.Type
	enum_vals             map[string]int
	defers                []flat.NodeId
	interfaces            map[string][]string
	const_vals            map[string]flat.NodeId
	const_modules         map[string]string
	global_modules        map[string]string
	tc                    types.TypeChecker
	has_builtins          bool
	tmp_count             int
	modules               map[string]string // alias -> full module name
	fn_ptr_types          map[string]string // fn_ptr:ret|params -> typedef name
	runtime_inits         []string
	cur_fn_ret            types.Type = types.Type(types.void_)
	needed_optional_types map[string]string
	emitted_fns           map[string]bool
}

pub fn FlatGen.new() FlatGen {
	return FlatGen{
		sb: strings.new_builder(4096)
	}
}

pub fn (mut g FlatGen) gen(a &flat.FlatAst) string {
	return g.gen_with_used(a, map[string]bool{}, types.TypeChecker{})
}

pub fn (mut g FlatGen) gen_with_used(a &flat.FlatAst, used_fns map[string]bool, tc types.TypeChecker) string {
	g.a = a
	g.used_fns = used_fns.clone()
	if tc.a != unsafe { nil } {
		g.tc = tc
	} else {
		g.tc.collect(a)
	}
	g.has_builtins = g.tc.has_builtins
	g.collect_gen_info()
	const_code := g.precompute_consts()
	orig_sb := g.sb
	g.sb = strings.new_builder(4096)
	g.gen_fns()
	fn_code := g.sb.str()
	g.sb = orig_sb
	g.preamble()
	if g.has_builtins {
		g.writeln('typedef struct Array { void* data; int len; int cap; int elem_size; } Array;')
		g.writeln('typedef Array array;')
		g.writeln('typedef Array strings__Builder;')
		g.writeln('typedef struct { unsigned int hash; bool used; } MapSlot;')
		g.writeln('typedef struct { MapSlot* slots; char* keys; char* vals; int cap; int len; int key_size; int val_size; } map;')
		g.writeln('')
	}
	g.enum_decls()
	g.type_alias_decls()
	g.struct_decls()
	g.optional_typedefs()
	g.multi_return_typedefs()
	g.runtime_fns()
	g.global_decls()
	g.fn_ptr_typedefs()
	g.forward_decls()
	g.string_literals()
	g.sb.write_string(const_code)
	if g.runtime_inits.len > 0 {
		g.writeln('void _vinit() {')
		for ri in g.runtime_inits {
			g.writeln(ri)
		}
		g.writeln('}')
		g.writeln('')
	}
	g.sb.write_string(fn_code)
	return g.sb.str()
}

fn (mut g FlatGen) collect_gen_info() {
	for node in g.a.nodes {
		match node.kind {
			.module_decl {
				g.tc.cur_module = node.value
			}
			.fn_decl {
				for i in 0 .. node.children_count {
					child := g.a.child_node(&node, i)
					if child.kind == .param {
						pt := g.tc.parse_type(child.typ)
						if pt is types.FnType {
							g.resolve_fn_ptr_type(g.tc.c_type(pt))
						}
					}
				}
			}
			.global_decl {
				for i in 0 .. node.children_count {
					f := g.a.child_node(&node, i)
					if f.value.starts_with('C.') {
						continue
					}
					mut ft := g.tc.parse_type(f.typ)
					if ft is types.Void && f.children_count > 0 {
						ft = g.tc.resolve_type(g.a.child(f, 0))
					}
					qname := g.tc.qualify_name(f.value)
					g.global_types[qname] = ft
					g.global_modules[f.value] = g.tc.cur_module
					g.tc.file_scope.insert(f.value, ft)
					if qname != f.value {
						g.tc.file_scope.insert(qname, ft)
					}
				}
			}
			.enum_decl {
				is_flag := node.typ == 'flag'
				mut val := 0
				enum_name := g.tc.qualify_name(node.value)
				for i in 0 .. node.children_count {
					f := g.a.child_node(&node, i)
					if f.children_count > 0 {
						ev := g.a.child_node(f, 0)
						if ev.kind == .int_literal {
							val = ev.value.int()
						}
					}
					if is_flag {
						g.enum_vals['${enum_name}.${f.value}'] = 1 << val
						val++
					} else {
						g.enum_vals['${enum_name}.${f.value}'] = val
						val++
					}
				}
			}
			.interface_decl {
				mut methods := []string{}
				for i in 0 .. node.children_count {
					f := g.a.child_node(&node, i)
					if f.kind == .interface_field {
						methods << f.value
					}
				}
				g.interfaces[g.tc.qualify_name(node.value)] = methods
			}
			.const_decl {
				for i in 0 .. node.children_count {
					f := g.a.child_node(&node, i)
					if f.kind == .const_field && f.children_count > 0 {
						g.const_vals[f.value] = g.a.child(f, 0)
						g.const_modules[f.value] = g.tc.cur_module
					}
				}
			}
			.import_decl {
				g.modules[node.typ] = node.value
			}
			else {}
		}
	}
	g.modules['strings'] = 'strings'
}

fn (mut g FlatGen) gen_fns() {
	for i, node in g.a.nodes {
		if node.kind == .module_decl {
			g.tc.cur_module = node.value
			continue
		}
		if node.kind == .fn_decl {
			if g.has_builtins && i < g.a.user_code_start {
				continue
			}
			dfn := g.dotted_fn_name(node.value)
			if g.used_fns.len > 0 && node.value !in g.used_fns && dfn !in g.used_fns {
				continue
			}
			if g.has_generic_params(node) {
				continue
			}
			if g.tc.cur_module == 'strings' && node.value in ['Builder.ensure_cap', 'Builder.grow_len', 'Builder.free', 'Builder.reuse_as_plain_u8_array', 'Builder.byte_at', 'Builder.drain_builder', 'Builder.indent'] {
				continue
			}
			if node.value.starts_with('Gen.') && g.tc.cur_module == 'c' {
				continue
			}
			qfn := g.qualified_fn_name(node.value)
			if qfn in g.emitted_fns {
				continue
			}
			g.emitted_fns[qfn] = true
			g.gen_fn(node)
		}
	}
}

fn (g &FlatGen) qualified_fn_name(name string) string {
	if g.tc.cur_module.len > 0 && g.tc.cur_module != 'main' && g.tc.cur_module != 'builtin' {
		return c_name('${g.tc.cur_module}.${name}')
	}
	return c_name(name)
}

fn (g &FlatGen) dotted_fn_name(name string) string {
	if g.tc.cur_module.len > 0 && g.tc.cur_module != 'main' && g.tc.cur_module != 'builtin' {
		return '${g.tc.cur_module}.${name}'
	}
	return name
}

fn (mut g FlatGen) gen_fn(node flat.Node) {
	g.tc.push_scope()
	g.defers = []flat.NodeId{}
	params := g.fn_params_list(node)
	for p in params {
		if p.value.len > 0 {
			g.tc.cur_scope.insert(p.value, g.tc.parse_type(p.typ))
		}
	}

	if node.value == 'main' {
		g.writeln('int main(int argc, char** argv) {')
		if g.has_builtins {
			g.writeln('\tg_main_argc = argc;')
			g.writeln('\tg_main_argv = argv;')
		}
		if g.runtime_inits.len > 0 {
			g.writeln('\t_vinit();')
		}
	} else {
		ret_type := g.tc.parse_type(node.typ)
		g.cur_fn_ret = ret_type
		g.write(g.optional_type_name(ret_type))
		g.write(' ')
		g.write(g.qualified_fn_name(node.value))
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
			if child.kind == .call {
				fn_n := g.a.child_node(&child, 0)
				if fn_n.kind == .selector && fn_n.value in ['set', 'clear'] {
					base_sel := g.a.child_node(fn_n, 0)
					if base_sel.kind == .selector && base_sel.value == 'flags' {
						return
					}
				}
			}
			if child.kind == .or_expr {
				g.gen_or_expr_stmt(child)
			} else if child.kind == .infix && child.op == .left_shift {
				lhs_id := g.a.child(&child, 0)
				if child.value == 'push_many' {
					g.write('array_push_many(&')
					g.gen_expr(lhs_id)
					g.write(', ')
					g.gen_expr(g.a.child(&child, 1))
					g.writeln(');')
				} else if child.value == 'push' {
					c_elem := g.tc.c_type(g.tc.parse_type(child.typ))
					g.write('array_push(&')
					g.gen_expr(lhs_id)
					g.write(', &(${c_elem}[]){')
					g.gen_expr(g.a.child(&child, 1))
					g.writeln('});')
				} else {
					lhs_type_raw := g.tc.resolve_type(lhs_id)
					lhs_type := types.unwrap_pointer(lhs_type_raw)
					if lhs_type is types.Array {
						rhs_id := g.a.child(&child, 1)
						rhs_type := g.tc.resolve_type(rhs_id)
						if rhs_type is types.Array {
							g.write('array_push_many(&')
							g.gen_expr(lhs_id)
							g.write(', ')
							g.gen_expr(rhs_id)
							g.writeln(');')
						} else {
							c_elem := g.tc.c_type(lhs_type.elem_type)
							g.write('array_push(&')
							g.gen_expr(lhs_id)
							g.write(', &(${c_elem}[]){')
							g.gen_expr(rhs_id)
							g.writeln('});')
						}
					} else {
						g.gen_expr(child_id)
						g.writeln(';')
					}
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
			if node.children_count > 0 {
				ret_id := g.a.child(&node, 0)
				ret_node := g.a.nodes[int(ret_id)]
				if ret_node.kind == .call {
					fn_n := g.a.child_node(&ret_node, 0)
					if fn_n.value == 'error' || fn_n.value == 'error_with_code' {
						if g.cur_fn_ret is types.OptionType || g.cur_fn_ret is types.ResultType {
							ct := g.optional_type_name(g.cur_fn_ret)
							g.writeln('return (${ct}){.ok = false};')
						} else {
							g.write('return ')
							g.gen_expr(ret_id)
							g.writeln(';')
						}
						return
					}
				}
				if g.cur_fn_ret is types.OptionType || g.cur_fn_ret is types.ResultType {
					ct := g.optional_type_name(g.cur_fn_ret)
					base := if g.cur_fn_ret is types.OptionType {
						g.cur_fn_ret.base_type
					} else if g.cur_fn_ret is types.ResultType {
						g.cur_fn_ret.base_type
					} else {
						types.Type(types.void_)
					}
					if base is types.Void {
						g.writeln('return (${ct}){.ok = false};')
					} else {
						expr_type := g.tc.resolve_type(ret_id)
						if expr_type is types.OptionType || expr_type is types.ResultType {
							g.write('return ')
							g.gen_expr(ret_id)
							g.writeln(';')
						} else {
							base_ct := g.tc.c_type(base)
							expr_ct := g.tc.c_type(expr_type)
							if expr_ct != base_ct && expr_type !is types.Primitive {
								g.writeln('return (${ct}){.ok = false};')
							} else {
								g.write('return (${ct}){.ok = true, .value = ')
								g.gen_expr(ret_id)
								g.writeln('};')
							}
						}
					}
				} else if g.cur_fn_ret is types.MultiReturn {
					expr_type := g.tc.resolve_type(ret_id)
					if expr_type is types.MultiReturn {
						g.write('return ')
						g.gen_expr(ret_id)
						g.writeln(';')
					} else {
						ct := g.tc.c_type(g.cur_fn_ret)
						g.write('return (${ct}){')
						g.gen_expr(ret_id)
						g.writeln('};')
					}
				} else {
					if g.cur_fn_ret is types.Struct && g.cur_fn_ret.name in g.tc.interface_names {
						ct := g.tc.c_type(g.cur_fn_ret)
						g.writeln('return (${ct}){0};')
					} else {
						g.write('return ')
						g.gen_expr(ret_id)
						g.writeln(';')
					}
				}
			} else {
				if g.cur_fn_ret is types.OptionType || g.cur_fn_ret is types.ResultType {
					ct := g.optional_type_name(g.cur_fn_ret)
					g.writeln('return (${ct}){.ok = true};')
				} else {
					g.writeln('return;')
				}
			}
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
		.empty, .asm_stmt {}
		else {
			// NOTE: match_stmt is intentionally absent — the transformer lowers every
			// match into an if/else-if chain (see transform.lower_match_stmts), so the
			// backend never sees one. Match lowering lives in the transformer, not here.
			eprintln('gen_node: unsupported node kind: ${node.kind}')
		}
	}
}

fn (mut g FlatGen) gen_decl_assign(node flat.Node) {
	if node.children_count >= 3 && node.children_count % 2 == 1 {
		g.gen_multi_return_decl(node)
		return
	}
	mut i := 0
	for i < node.children_count {
		lhs_id := g.a.child(&node, i)
		rhs_id := g.a.child(&node, i + 1)
		lhs := g.a.nodes[int(lhs_id)]
		rhs := g.a.nodes[int(rhs_id)]
		if rhs.kind == .array_literal {
			elem_type := if rhs.children_count > 0 {
				g.tc.resolve_type(g.a.child(&rhs, 0))
			} else {
				types.Type(types.int_)
			}
			c_elem := g.tc.c_type(elem_type)
			count := rhs.children_count
			g.write('${c_elem} ')
			g.gen_decl_lhs(lhs_id)
			g.write('[] = {')
			for j in 0 .. count {
				if j > 0 {
					g.write(', ')
				}
				g.gen_expr(g.a.child(&rhs, j))
			}
			g.writeln('};')
			if lhs.kind == .ident {
				g.tc.cur_scope.insert(lhs.value, types.Type(types.ArrayFixed{
					elem_type: elem_type
					len:       count
				}))
			}
		} else if rhs.kind == .or_expr {
			g.gen_decl_or_expr(lhs, rhs)
		} else if rhs.kind == .array_init {
			elem_type := g.tc.parse_type(rhs.value)
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
			lhs_str := g.decl_lhs_str(lhs_id)
			g.writeln('Array ${lhs_str} = array_new(sizeof(${c_elem}), ${init_len}, ${init_cap});')
			if init_val.len > 0 {
				g.writeln('for (int _ai = 0; _ai < ${lhs_str}.len; _ai++) ((${c_elem}*)${lhs_str}.data)[_ai] = ${init_val};')
			}
			if lhs.kind == .ident {
				g.tc.cur_scope.insert(lhs.value, types.Type(types.Array{
					elem_type: elem_type
				}))
			}
		} else if rhs.kind == .map_init {
			v_type := g.tc.resolve_type(rhs_id)
			c_typ := g.tc.c_type(v_type)
			g.write('${c_typ} ')
			g.gen_decl_lhs(lhs_id)
			g.write(' = ')
			g.gen_expr(rhs_id)
			g.writeln(';')
			if lhs.kind == .ident {
				g.tc.cur_scope.insert(lhs.value, v_type)
			}
			if rhs.children_count > 0 {
				if v_type is types.Map {
					c_key := g.tc.c_type(v_type.key_type)
					c_val := g.tc.c_type(v_type.value_type)
					for j := 0; j < rhs.children_count; j += 2 {
						g.write('map__set(&')
						g.gen_decl_lhs(lhs_id)
						g.write(', &(${c_key}[]){')
						g.gen_expr(g.a.child(&rhs, j))
						g.write('}, &(${c_val}[]){')
						g.gen_expr(g.a.child(&rhs, j + 1))
						g.writeln('});')
					}
				}
			}
		} else {
			v_type := g.tc.resolve_type(rhs_id)
			ct := g.tc.c_type(v_type)
			if ct.starts_with('fn_ptr:') {
				fp_name := g.resolve_fn_ptr_type(ct)
				g.write('${fp_name} ')
			} else {
				g.write('${ct} ')
			}
			g.gen_decl_lhs(lhs_id)
			g.write(' = ')
			g.gen_expr(rhs_id)
			g.writeln(';')
			if lhs.kind == .ident {
				g.tc.cur_scope.insert(lhs.value, v_type)
			}
		}
		i += 2
	}
}

fn (mut g FlatGen) gen_multi_return_decl(node flat.Node) {
	num_lhs := (node.children_count + 1) / 2
	rhs_id := g.a.child(&node, 1)
	rhs_type := g.tc.resolve_type(rhs_id)
	ct := g.tc.c_type(rhs_type)
	tmp := g.tmp_name()
	g.write('${ct} ${tmp} = ')
	g.gen_expr(rhs_id)
	g.writeln(';')
	for j in 0 .. num_lhs {
		lhs_idx := j * 2
		if lhs_idx >= node.children_count {
			break
		}
		lhs_id := g.a.child(&node, lhs_idx)
		lhs := g.a.nodes[int(lhs_id)]
		if lhs.kind == .ident && lhs.value == '_' {
			continue
		}
		field_type := if rhs_type is types.MultiReturn && j < (rhs_type as types.MultiReturn).types.len {
			g.tc.c_type((rhs_type as types.MultiReturn).types[j])
		} else {
			'int'
		}
		lhs_name := c_name(lhs.value)
		g.writeln('${field_type} ${lhs_name} = ${tmp}.arg${j};')
		if lhs.kind == .ident {
			inner := if rhs_type is types.MultiReturn && j < (rhs_type as types.MultiReturn).types.len {
				(rhs_type as types.MultiReturn).types[j]
			} else {
				types.Type(types.int_)
			}
			g.tc.cur_scope.insert(lhs.value, inner)
		}
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
			if node.value == 'push_many' {
				g.write('array_push_many(&${c_name(lhs.value)}, ')
				g.gen_expr(g.a.child(&node, i + 1))
				g.writeln(');')
			} else if node.value == 'push' {
				c_elem := g.tc.c_type(g.tc.parse_type(node.typ))
				g.write('array_push(&${c_name(lhs.value)}, &(${c_elem}[]){')
				g.gen_expr(g.a.child(&node, i + 1))
				g.writeln('});')
			} else {
				lhs_type := g.tc.cur_scope.lookup(lhs.value) or { types.Type(types.void_) }
				if lhs_type is types.Array {
					rhs_id := g.a.child(&node, i + 1)
					rhs_type := g.tc.resolve_type(rhs_id)
					if rhs_type is types.Array {
						g.write('array_push_many(&${c_name(lhs.value)}, ')
						g.gen_expr(rhs_id)
						g.writeln(');')
					} else {
						c_elem := g.tc.c_type(lhs_type.elem_type)
						g.write('array_push(&${c_name(lhs.value)}, &(${c_elem}[]){')
						g.gen_expr(rhs_id)
						g.writeln('});')
					}
				} else {
					g.gen_expr(g.a.child(&node, i))
					g.write(' <<= ')
					g.gen_expr(g.a.child(&node, i + 1))
					g.writeln(';')
					}
				}
			} else {
			rhs_id := g.a.child(&node, i + 1)
			rhs_node := g.a.nodes[int(rhs_id)]
			if rhs_node.kind == .array_literal && rhs_node.children_count > 0 {
				elem_type := g.tc.resolve_type(g.a.child(&rhs_node, 0))
				c_elem := g.tc.c_type(elem_type)
				count := rhs_node.children_count
				g.gen_expr(g.a.child(&node, i))
				g.write(' = new_array_from_c_array(${count}, ${count}, sizeof(${c_elem}), (${c_elem}[${count}]){')
				for j in 0 .. count {
					if j > 0 {
						g.write(', ')
					}
					g.gen_expr(g.a.child(&rhs_node, j))
				}
				g.writeln('});')
			} else {
				g.gen_expr(g.a.child(&node, i))
				g.write(' ${g.op_str(node.op)} ')
				g.gen_expr(rhs_id)
				g.writeln(';')
			}
		}
		i += 2
	}
}

fn (mut g FlatGen) gen_decl_lhs(id flat.NodeId) {
	node := g.a.nodes[int(id)]
	if node.kind == .ident {
		g.write(c_name(node.value))
	} else {
		g.gen_expr(id)
	}
}

fn (mut g FlatGen) decl_lhs_str(id flat.NodeId) string {
	node := g.a.nodes[int(id)]
	if node.kind == .ident {
		return c_name(node.value)
	}
	return g.expr_to_string(id)
}

fn (mut g FlatGen) expr_to_string(id flat.NodeId) string {
	orig := g.sb
	g.sb = strings.new_builder(64)
	g.gen_expr(id)
	result := g.sb.str()
	g.sb = orig
	return result
}

fn (mut g FlatGen) gen_slice_expr(node flat.Node, base_id flat.NodeId, base_type types.Type) {
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
	if base_type is types.String {
		g.write('string__substr(${base_str}, ${start_str}, ${end_str})')
	} else if base_type is types.Array {
		g.write('array_slice(${base_str}, ${start_str}, ${end_str})')
	} else {
		g.write('string__substr(${base_str}, ${start_str}, ${end_str})')
	}
}

fn (mut g FlatGen) gen_array_method_call(node flat.Node, fn_node &flat.Node, arr types.Array) {
	c_elem := g.tc.c_type(arr.elem_type)
	base_id := g.a.child(fn_node, 0)
	base_node := g.a.nodes[int(base_id)]
	is_ptr := if base_node.kind == .ident {
		g.tc.resolve_type(base_id) is types.Pointer
	} else {
		false
	}
	dot := if is_ptr { '->' } else { '.' }
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
			g.write('${dot}len--')
		}
		'clear' {
			g.gen_expr(base_id)
			g.write('${dot}len = 0')
		}
		'push_many' {
			g.write('array_push_many_ptr(&')
			g.gen_expr(base_id)
			g.write(', ')
			g.gen_expr(g.a.child(&node, 1))
			g.write(', ')
			g.gen_expr(g.a.child(&node, 2))
			g.write(')')
		}
		'trim' {
			g.gen_expr(base_id)
			g.write('${dot}len = ')
			g.gen_expr(g.a.child(&node, 1))
		}
		'ensure_cap' {
			g.write('array_ensure_cap(&')
			g.gen_expr(base_id)
			g.write(', ')
			g.gen_expr(g.a.child(&node, 1))
			g.write(')')
		}
		'delete' {
			g.write('array_delete(&')
			g.gen_expr(base_id)
			g.write(', ')
			g.gen_expr(g.a.child(&node, 1))
			g.write(')')
		}
		'free' {
			g.write('free(')
			g.gen_expr(base_id)
			g.write('${dot}data)')
		}
		'str' {
			g.write('strings__Builder__str(&')
			g.gen_expr(base_id)
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
			contains_fn := if arr.elem_type is types.String {
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
			index_fn := if arr.elem_type is types.String {
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
			mut found_method := false
			for mname, _ in g.tc.fn_param_types {
				if mname.ends_with('.${fn_node.value}') {
					g.write(c_name(mname))
					g.write('(&')
					g.gen_expr(base_id)
					for i in 1 .. node.children_count {
						g.write(', ')
						g.gen_expr(g.a.child(&node, i))
					}
					g.write(')')
					found_method = true
					break
				}
			}
			if !found_method {
				g.gen_expr(g.a.child(&node, 0))
				g.write('(')
				g.gen_expr(base_id)
				g.write(')')
			}
		}
	}
}

fn (mut g FlatGen) gen_map_delete(node flat.Node, fn_node &flat.Node, m types.Map) {
	c_key := g.tc.c_type(m.key_type)
	g.write('map__delete(&')
	g.gen_expr(g.a.child(fn_node, 0))
	g.write(', &(${c_key}[]){')
	g.gen_expr(g.a.child(&node, 1))
	g.write('})')
}

fn (mut g FlatGen) gen_index_assign(node flat.Node) {
	lhs_id := g.a.child(&node, 0)
	lhs := g.a.nodes[int(lhs_id)]
	if lhs.kind == .index {
		base_id := g.a.child(&lhs, 0)
		base_type := g.tc.resolve_type(base_id)
		if base_type is types.Map {
			c_key := g.tc.c_type(base_type.key_type)
			c_val := g.tc.c_type(base_type.value_type)
			g.write('map__set(&')
			g.gen_expr(base_id)
			g.write(', &(${c_key}[]){')
			g.gen_expr(g.a.child(&lhs, 1))
			g.write('}, &(${c_val}[]){')
			g.gen_expr(g.a.child(&node, 1))
			g.writeln('});')
			return
		}
		if base_type is types.Pointer && (base_type as types.Pointer).base_type is types.Void {
			g.write('((u8*)')
			g.gen_expr(base_id)
			g.write(')[')
			g.gen_expr(g.a.child(&lhs, 1))
			g.write('] = ')
			g.gen_expr(g.a.child(&node, 1))
			g.writeln(';')
			return
		}
		if base_type is types.Array || (base_type is types.Pointer && (base_type as types.Pointer).base_type is types.Array) {
			arr_type := if base_type is types.Array {
				base_type as types.Array
			} else if base_type is types.Pointer {
				(base_type as types.Pointer).base_type as types.Array
			} else {
				types.Array{}
			}
			c_elem := g.tc.c_type(arr_type.elem_type)
			g.write('array_set(')
			if base_type is types.Pointer {
				g.write('*')
			}
			g.gen_expr(base_id)
			g.write(', ')
			g.gen_expr(g.a.child(&lhs, 1))
			g.write(', &(${c_elem}[]){')
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
	g.tc.cur_scope.insert(var_node.value, types.Type(types.int_))
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
			if container_type is types.Map {
				c_key := g.tc.c_type(container_type.key_type)
				c_val := g.tc.c_type(container_type.value_type)
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
					g.tc.cur_scope.insert(key_var, container_type.key_type)
				}
				g.tc.cur_scope.insert(val_var_, container_type.value_type)
			} else if container_type is types.Array {
				c_elem := g.tc.c_type(container_type.elem_type)
				container_str := g.expr_to_string(g.a.child(&node, 2))
				g.writeln('for (int ${idx_var} = 0; ${idx_var} < ${container_str}.len; ${idx_var}++) {')
				g.indent++
				g.writeln('${c_elem} ${elem_var} = *(${c_elem}*)array_get(${container_str}, ${idx_var});')
				g.tc.cur_scope.insert(elem_var, container_type.elem_type)
			} else if container_type is types.String {
				container_str := g.expr_to_string(g.a.child(&node, 2))
				g.writeln('for (int ${idx_var} = 0; ${idx_var} < ${container_str}.len; ${idx_var}++) {')
				g.indent++
				g.writeln('u8 ${elem_var} = ((u8*)${container_str}.str)[${idx_var}];')
				g.tc.cur_scope.insert(elem_var, types.Type(types.u8_))
			} else if container_type is types.ArrayFixed {
				af := container_type as types.ArrayFixed
				c_elem := g.tc.c_type(af.elem_type)
				arr_len := '${af.len}'
				g.writeln('for (int ${idx_var} = 0; ${idx_var} < ${arr_len}; ${idx_var}++) {')
				g.indent++
				g.write('${c_elem} ${elem_var} = ')
				g.gen_expr(g.a.child(&node, 2))
				g.writeln('[${idx_var}];')
				g.tc.cur_scope.insert(elem_var, af.elem_type)
			} else {
				g.writeln('for (int ${idx_var} = 0; ${idx_var} < 0; ${idx_var}++) {')
				g.indent++
				g.writeln('int ${elem_var} = 0;')
				g.tc.cur_scope.insert(elem_var, types.Type(types.int_))
			}
			if has_index {
				g.tc.cur_scope.insert(idx_var, types.Type(types.int_))
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
			v_type := g.tc.resolve_type(rhs_id)
			typ := g.tc.c_type(v_type)
			g.write('${typ} ')
			g.gen_expr(lhs_id)
			g.write(' = ')
			g.gen_expr(rhs_id)
			if lhs.kind == .ident {
				g.tc.cur_scope.insert(lhs.value, v_type)
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

fn (g &FlatGen) expr_key(id flat.NodeId) string {
	node := g.a.nodes[int(id)]
	if node.kind == .ident {
		return node.value
	}
	if node.kind == .selector && node.children_count > 0 {
		base_key := g.expr_key(g.a.child(&node, 0))
		if base_key.len > 0 {
			return '${base_key}.${node.value}'
		}
	}
	return ''
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
		if base_type is types.Map {
			c_val_type := g.tc.c_type(base_type.value_type)
			c_key_type := g.tc.c_type(base_type.key_type)
			g.write('void* ${tmp} = map__get_check(&')
			g.gen_expr(base_id)
			g.write(', &(${c_key_type}[]){')
			g.gen_expr(g.a.child(rhs, 1))
			g.writeln('});')
			g.writeln('if (${tmp} != NULL) {')
			g.tc.push_scope()
			g.indent++
			g.writeln('${c_val_type} ${var_name} = *(${c_val_type}*)${tmp};')
			g.tc.cur_scope.insert(lhs.value, base_type.value_type)
		} else {
			rhs_type := g.tc.resolve_type(rhs_id)
			opt_ct := g.optional_type_name(rhs_type)
			val_ct, val_type := g.optional_value_ct(rhs_type)
			g.write('${opt_ct} ${tmp} = ')
			g.gen_expr(rhs_id)
			g.writeln(';')
			g.writeln('if (${tmp}.ok) {')
			g.tc.push_scope()
			g.indent++
			g.writeln('${val_ct} ${var_name} = ${tmp}.value;')
			g.tc.cur_scope.insert(lhs.value, val_type)
		}
	} else {
		rhs_type := g.tc.resolve_type(rhs_id)
		opt_ct := g.optional_type_name(rhs_type)
		val_ct, val_type := g.optional_value_ct(rhs_type)
		g.write('${opt_ct} ${tmp} = ')
		g.gen_expr(rhs_id)
		g.writeln(';')
		g.writeln('if (${tmp}.ok) {')
		g.tc.push_scope()
		g.indent++
		g.writeln('${val_ct} ${var_name} = ${tmp}.value;')
		g.tc.cur_scope.insert(lhs.value, val_type)
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

fn (mut g FlatGen) gen_if_expr(node flat.Node) {
	then_block := g.a.child_node(&node, 1)
	mut needs_stmt_expr := then_block.children_count > 1
	if !needs_stmt_expr && node.children_count > 2 {
		else_node := g.a.child_node(&node, 2)
		if else_node.kind == .block && else_node.children_count > 1 {
			needs_stmt_expr = true
		} else if else_node.kind == .if_expr {
			needs_stmt_expr = true
		}
	}
	if needs_stmt_expr {
		g.gen_if_expr_stmt(node)
		return
	}
	g.write('(')
	g.gen_expr(g.a.child(&node, 0))
	g.write(' ? ')
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

fn (mut g FlatGen) gen_if_expr_block(block &flat.Node) {
	for i in 0 .. block.children_count {
		child := g.a.child_node(block, i)
		if i == block.children_count - 1 {
			if child.kind == .expr_stmt {
				g.write('_ifexpr = ')
				g.gen_expr(g.a.child(child, 0))
				g.writeln(';')
			} else {
				g.gen_node(g.a.child(block, i))
			}
		} else {
			g.gen_node(g.a.child(block, i))
		}
	}
}

fn (mut g FlatGen) gen_if_expr_stmt(node flat.Node) {
	then_block := g.a.child_node(&node, 1)
	last := g.a.child_node(then_block, then_block.children_count - 1)
	mut ret_type := if last.kind == .expr_stmt {
		g.tc.resolve_type(g.a.child(last, 0))
	} else {
		g.tc.resolve_type(g.a.child(then_block, then_block.children_count - 1))
	}
	if ret_type is types.Primitive && node.children_count > 2 {
		else_node := g.a.child_node(&node, 2)
		if else_node.kind == .block && else_node.children_count > 0 {
			el := g.a.child_node(else_node, else_node.children_count - 1)
			et := if el.kind == .expr_stmt {
				g.tc.resolve_type(g.a.child(el, 0))
			} else {
				g.tc.resolve_type(g.a.child(else_node, else_node.children_count - 1))
			}
			if et !is types.Primitive {
				ret_type = et
			}
		} else if else_node.kind == .if_expr && else_node.children_count > 2 {
			inner_else := g.a.child_node(else_node, 2)
			if inner_else.kind == .block && inner_else.children_count > 0 {
				el := g.a.child_node(inner_else, inner_else.children_count - 1)
				et := if el.kind == .expr_stmt {
					g.tc.resolve_type(g.a.child(el, 0))
				} else {
					g.tc.resolve_type(g.a.child(inner_else, inner_else.children_count - 1))
				}
				if et !is types.Primitive {
					ret_type = et
				}
			}
		}
	}
	ct := g.tc.c_type(ret_type)
	g.writeln('({${ct} _ifexpr;')
	g.write('if (')
	g.gen_expr(g.a.child(&node, 0))
	g.writeln(') {')
	g.gen_if_expr_block(then_block)
	g.write('} else ')
	if node.children_count > 2 {
		else_node := g.a.child_node(&node, 2)
		if else_node.kind == .if_expr {
			g.gen_if_expr_else_if(*else_node)
		} else if else_node.kind == .block {
			g.writeln('{')
			g.gen_if_expr_block(else_node)
			g.writeln('}')
		}
	} else {
		g.writeln('{ _ifexpr = 0; }')
	}
	g.write('_ifexpr;})')
}

fn (mut g FlatGen) gen_if_expr_else_if(node flat.Node) {
	then_block := g.a.child_node(&node, 1)
	g.write('if (')
	g.gen_expr(g.a.child(&node, 0))
	g.writeln(') {')
	g.gen_if_expr_block(then_block)
	g.write('} else ')
	if node.children_count > 2 {
		else_node := g.a.child_node(&node, 2)
		if else_node.kind == .if_expr {
			g.gen_if_expr_else_if(*else_node)
		} else if else_node.kind == .block {
			g.writeln('{')
			g.gen_if_expr_block(else_node)
			g.writeln('}')
		}
	} else {
		g.writeln('{ _ifexpr = 0; }')
	}
}

fn (mut g FlatGen) gen_expr(id flat.NodeId) {
	if int(id) < 0 {
		return
	}
	node := g.a.nodes[int(id)]
	match node.kind {
		.int_literal {
			v := node.value.replace('_', '')
			if v.starts_with('0o') {
				g.write('0${v[2..]}')
			} else {
				g.write(v)
			}
		}
		.float_literal {
			g.write(node.value)
		}
		.bool_literal {
			g.write(node.value)
		}
		.char_literal {
			v := node.value
			if v.len == 1 {
				if v[0] == `\\` {
					g.write("'\\\\'")
				} else if v[0] == `'` {
					g.write("'\\''")
				} else {
					g.write("'${v}'")
				}
			} else if v.starts_with('\\') {
				g.write("'${v}'")
			} else {
				g.write(v)
			}
		}
		.string_literal {
			sid := g.intern_string(node.value)
			g.write('_str_${sid}')
		}
		.string_interp {
			g.gen_string_interp(node)
		}
		.ident {
			looked_up := g.tc.cur_scope.lookup(node.value) or { types.Type(types.void_) }
			is_local := looked_up !is types.Void
			if !is_local && node.value in g.const_vals {
				mod := if node.value in g.const_modules { g.const_modules[node.value] } else { '' }
				if mod.len > 0 && mod != 'main' && mod != 'builtin' {
					g.write(c_name('${mod}.${node.value}'))
				} else {
					g.write(c_name(node.value))
				}
			} else if node.value in g.global_modules {
				mod := g.global_modules[node.value]
				if mod.len > 0 && mod != 'main' && mod != 'builtin' {
					g.write(c_name('${mod}.${node.value}'))
				} else {
					g.write(c_name(node.value))
				}
			} else {
				g.write(c_name(node.value))
			}
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
			// NOTE: string operators (+, ==, !=, <, >, <=, >=) are lowered to
			// string__plus / string__eq / string__lt calls by the transformer
			// (transform.transform_infix_string_ops + match/condition lowering),
			// which is type-aware via the pre-transform type checker. The backend
			// only emits primitive infix here.
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
			} else if node.op == .amp && child.kind == .cast_expr {
				target_type := g.tc.parse_type(child.value)
				ct := g.tc.c_type(target_type)
				g.write('(${ct}*)(')
				g.gen_expr(g.a.child(&child, 0))
				g.write(')')
			} else if node.op == .amp && child.kind == .call {
				fn_child := g.a.child_node(&child, 0)
				if fn_child.kind == .selector {
					base_child := g.a.child_node(fn_child, 0)
					if base_child.kind == .ident && base_child.value == 'C' {
						c_struct_prefix := if fn_child.value.len > 0 && fn_child.value[0] >= `a` && fn_child.value[0] <= `z` && !fn_child.value.ends_with('_t') {
							'struct '
						} else {
							''
						}
						g.write('(${c_struct_prefix}${fn_child.value}*)(')
						if child.children_count > 1 {
							g.gen_expr(g.a.child(&child, 1))
						} else {
							g.write('0')
						}
						g.write(')')
					} else {
						g.write(g.op_str(node.op))
						g.gen_expr(child_id)
					}
				} else {
					g.write(g.op_str(node.op))
					g.gen_expr(child_id)
				}
			} else {
				g.write(g.op_str(node.op))
				g.gen_expr(child_id)
			}
		}
		.in_expr {
			// NOTE: range membership, inline-array-literal membership, dynamic- and
			// fixed-array membership, and `!in` negation are all lowered by the
			// transformer (transform.transform_in_expr). Only MAP membership reaches
			// the backend, because map__exists needs a C key pointer (compound
			// literal) that cannot be expressed at the AST level.
			lhs_id := g.a.child(&node, 0)
			rhs_id := g.a.child(&node, 1)
			rhs_type := g.tc.resolve_type(rhs_id)
			if rhs_type is types.Map {
				c_key := g.tc.c_type(rhs_type.key_type)
				g.write('map__exists(&')
				g.gen_expr(rhs_id)
				g.write(', &(${c_key}[]){')
				g.gen_expr(lhs_id)
				g.write('})')
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
			if base.kind == .ident && base.value == 'C' {
				g.write(node.value)
			} else if base.kind == .ident && (base.value in g.tc.enum_names || g.tc.qualify_name(base.value) in g.tc.enum_names) {
				qbase := if base.value in g.tc.enum_names {
					base.value
				} else {
					g.tc.qualify_name(base.value)
				}
				ekey := '${qbase}.${node.value}'
				if eval := g.enum_vals[ekey] {
					g.write('${eval}')
				} else {
					g.write('0')
				}
			} else if node.value == 'len' && base.kind == .ident {
				base_type := g.tc.resolve_type(base_id)
				if base_type is types.ArrayFixed {
					g.write('${(base_type as types.ArrayFixed).len}')
				} else {
					raw_type := g.tc.cur_scope.lookup(base.value) or { base_type }
					g.gen_expr(base_id)
					if raw_type is types.Pointer {
						g.write('->len')
					} else {
						g.write('.len')
					}
				}
			} else if base.kind == .ident && base.value in g.modules {
				mod := g.modules[base.value]
				short_mod := if mod.contains('.') {
					mod.all_after_last('.')
				} else {
					mod
				}
				g.write(c_name('${short_mod}.${node.value}'))
			} else {
				g.gen_expr(base_id)
				if node.op == .arrow {
					g.write('->')
				} else if node.op == .dot {
					g.write('.')
				} else {
					mut is_ptr := false
					if base.kind == .ident {
						if typ := g.tc.cur_scope.lookup(base.value) {
							is_ptr = typ is types.Pointer
						}
					} else {
						resolved := g.tc.resolve_type(base_id)
						is_ptr = resolved is types.Pointer
					}
					if is_ptr {
						g.write('->')
					} else {
						g.write('.')
					}
				}
				g.write(c_name(node.value))
			}
		}
		.index {
			base_id := g.a.child(&node, 0)
			base_type := g.tc.resolve_type(base_id)
			if node.value == 'range' {
				g.gen_slice_expr(node, base_id, base_type)
			} else if base_type is types.Map {
				c_key := g.tc.c_type(base_type.key_type)
				c_val := g.tc.c_type(base_type.value_type)
				g.write('*(${c_val}*)map__get(&')
				g.gen_expr(base_id)
				g.write(', &(${c_key}[]){')
				g.gen_expr(g.a.child(&node, 1))
				g.write('}, &(${c_val}[]){0})')
			} else if base_type is types.Array || (base_type is types.Pointer && (base_type as types.Pointer).base_type is types.Array) {
				arr_type := if base_type is types.Array {
					base_type as types.Array
				} else if base_type is types.Pointer {
					(base_type as types.Pointer).base_type as types.Array
				} else {
					types.Array{}
				}
				c_elem := g.tc.c_type(arr_type.elem_type)
				g.write('(*(${c_elem}*)array_get(')
				if base_type is types.Pointer {
					g.write('*')
				}
				g.gen_expr(base_id)
				g.write(', ')
				g.gen_expr(g.a.child(&node, 1))
				g.write('))')
			} else if base_type is types.String {
				g.gen_expr(base_id)
				g.write('.str[')
				g.gen_expr(g.a.child(&node, 1))
				g.write(']')
			} else if base_type is types.Pointer && (base_type as types.Pointer).base_type is types.Void {
				g.write('((u8*)')
				g.gen_expr(base_id)
				g.write(')[')
				g.gen_expr(g.a.child(&node, 1))
				g.write(']')
			} else {
				g.gen_expr(base_id)
				g.write('[')
				g.gen_expr(g.a.child(&node, 1))
				g.write(']')
			}
		}
		.array_init {
			elem_type := g.tc.parse_type(node.value)
			c_elem := g.tc.c_type(elem_type)
			g.write('array_new(sizeof(${c_elem}), 0, 0)')
		}
		.map_init {
			g.gen_map_init(node)
		}
		.cast_expr {
			target_type := g.tc.parse_type(node.value)
			ct := g.tc.c_type(target_type)
			if target_type is types.SumType {
				inner_id := g.a.child(&node, 0)
				inner := g.a.nodes[int(inner_id)]
				variant_name0 := if inner.kind == .struct_init || inner.kind == .cast_expr {
					inner.value
				} else {
					g.tc.resolve_type(inner_id).name()
				}
				variant_name := g.resolve_variant(target_type.name, variant_name0)
				idx := g.sum_type_index(target_type.name, variant_name)
				field := g.sum_field_name(variant_name)
				if g.variant_references_sum(variant_name, target_type.name) {
					inner_ct := g.tc.c_type(g.tc.parse_type(variant_name))
					g.write('(${ct}){.typ = ${idx}, .${field} = (${inner_ct}*)memdup(&(${inner_ct}){')
					if inner.kind == .struct_init {
						for si in 0 .. inner.children_count {
							sf := g.a.child_node(&inner, si)
							if si > 0 {
								g.write(', ')
							}
							g.write('.${c_name(sf.value)} = ')
							g.gen_expr(g.a.child(sf, 0))
						}
					} else {
						g.gen_expr(inner_id)
					}
					g.write('}, sizeof(${inner_ct}))}')
				} else {
					g.write('(${ct}){.typ = ${idx}, .${field} = ')
					g.gen_expr(inner_id)
					g.write('}')
				}
			} else {
				g.write('(${ct})(')
				g.gen_expr(g.a.child(&node, 0))
				g.write(')')
			}
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
			ct := g.optional_type_name(g.cur_fn_ret)
			g.write('(${ct}){.ok = false}')
		}
		.or_expr {
			g.gen_or_expr(node)
		}
		.block {
			if node.children_count > 0 {
				last_id := g.a.child(&node, node.children_count - 1)
				last := g.a.nodes[int(last_id)]
				if last.kind == .expr_stmt {
					g.gen_expr(g.a.child(&last, 0))
				} else {
					g.gen_expr(last_id)
				}
			}
		}
		.is_expr {
			expr_id := g.a.child(&node, 0)
			expr_type := g.tc.resolve_type(expr_id)
			clean := types.unwrap_pointer(expr_type)
			if clean is types.SumType {
				idx := g.sum_type_index(clean.name, node.value)
				if expr_type.is_pointer() {
					g.gen_expr(expr_id)
					g.write('->typ == ${idx}')
				} else {
					g.gen_expr(expr_id)
					g.write('.typ == ${idx}')
				}
			} else {
				g.write('1')
			}
		}
		.as_expr {
			expr_id := g.a.child(&node, 0)
			expr_type := g.tc.resolve_type(expr_id)
			clean := types.unwrap_pointer(expr_type)
			if clean is types.SumType {
				qv := g.resolve_variant(clean.name, node.value)
				field := g.sum_field_name(qv)
				if g.variant_references_sum(qv, clean.name) {
					g.write('(*')
					if expr_type.is_pointer() {
						g.gen_expr(expr_id)
						g.write('->${field})')
					} else {
						g.gen_expr(expr_id)
						g.write('.${field})')
					}
				} else {
					if expr_type.is_pointer() {
						g.gen_expr(expr_id)
						g.write('->${field}')
					} else {
						g.gen_expr(expr_id)
						g.write('.${field}')
					}
				}
			} else {
				g.gen_expr(expr_id)
			}
		}
		.sizeof_expr {
			if _ := g.tc.cur_scope.lookup(node.value) {
				g.write('sizeof(${c_name(node.value)})')
			} else {
				t := g.tc.parse_type(node.value)
				ct := g.tc.c_type(t)
				g.write('sizeof(${ct})')
			}
		}
		.empty {}
		else {}
	}
}

fn (mut g FlatGen) gen_decl_or_expr(lhs flat.Node, or_node flat.Node) {
	expr_id := g.a.child(&or_node, 0)
	or_body_id := g.a.child(&or_node, 1)
	or_body := g.a.nodes[int(or_body_id)]
	expr_node := g.a.nodes[int(expr_id)]
	if expr_node.kind == .index {
		base_type := g.tc.resolve_type(g.a.child(&expr_node, 0))
		clean := types.unwrap_pointer(base_type)
		if clean is types.Map {
			g.gen_decl_or_map_index(lhs, expr_node, clean as types.Map, or_body)
			return
		}
	}
	tmp := g.tmp_name()
	expr_type := g.tc.resolve_type(expr_id)
	opt_ct := g.optional_type_name(expr_type)
	val_ct, val_type := g.optional_value_ct(expr_type)
	g.tc.cur_scope.insert(lhs.value, val_type)
	g.write('${opt_ct} ${tmp} = ')
	g.gen_expr(expr_id)
	g.writeln(';')
	g.writeln('${val_ct} ${c_name(lhs.value)};')
	g.writeln('if (${tmp}.ok) {')
	g.indent++
	g.writeln('${c_name(lhs.value)} = ${tmp}.value;')
	g.indent--
	g.writeln('} else {')
	g.tc.push_scope()
	g.tc.cur_scope.insert('err', types.Type(types.Struct{
		name: 'IError'
	}))
	g.indent++
	g.writeln('IError err = (IError){0};')
	if or_body.children_count > 0 {
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
	}
	g.indent--
	g.tc.pop_scope()
	g.writeln('}')
}

fn (mut g FlatGen) gen_decl_or_map_index(lhs flat.Node, expr_node flat.Node, m types.Map, or_body flat.Node) {
	tmp := g.tmp_name()
	c_val := g.tc.c_type(m.value_type)
	c_key := g.tc.c_type(m.key_type)
	g.tc.cur_scope.insert(lhs.value, m.value_type)
	g.write('void* ${tmp} = map__get_check(&')
	g.gen_expr(g.a.child(&expr_node, 0))
	g.write(', &(${c_key}[]){')
	g.gen_expr(g.a.child(&expr_node, 1))
	g.writeln('});')
	g.writeln('${c_val} ${c_name(lhs.value)};')
	g.writeln('if (${tmp}) {')
	g.indent++
	g.writeln('${c_name(lhs.value)} = *(${c_val}*)${tmp};')
	g.indent--
	g.writeln('} else {')
	g.indent++
	if or_body.children_count > 0 {
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
	}
	g.indent--
	g.writeln('}')
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
	expr_node := g.a.nodes[int(expr_id)]
	if expr_node.kind == .index {
		base_type := g.tc.resolve_type(g.a.child(&expr_node, 0))
		clean := types.unwrap_pointer(base_type)
		if clean is types.Map {
			g.gen_or_map_index(expr_node, clean as types.Map, or_body)
			return
		}
	}
	tmp := g.tmp_name()
	expr_type := g.tc.resolve_type(expr_id)
	opt_ct := g.optional_type_name(expr_type)
	g.write('({${opt_ct} ${tmp} = ')
	g.gen_expr(expr_id)
	g.write('; ${tmp}.ok ? ${tmp}.value : ({IError err = (IError){0}; (void)err; ')
	g.gen_or_body(or_body)
	g.write(';})')
}

fn (mut g FlatGen) gen_or_body(or_body flat.Node) {
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
}

fn (mut g FlatGen) gen_or_map_index(expr_node flat.Node, m types.Map, or_body flat.Node) {
	tmp := g.tmp_name()
	c_val := g.tc.c_type(m.value_type)
	c_key := g.tc.c_type(m.key_type)
	g.write('({void* ${tmp} = map__get_check(&')
	g.gen_expr(g.a.child(&expr_node, 0))
	g.write(', &(${c_key}[]){')
	g.gen_expr(g.a.child(&expr_node, 1))
	g.write('}); ${tmp} ? *(${c_val}*)${tmp} : ')
	g.gen_or_body(or_body)
	g.write(';})')
}

fn (mut g FlatGen) gen_or_expr_stmt(node flat.Node) {
	expr_id := g.a.child(&node, 0)
	or_body_id := g.a.child(&node, 1)
	or_body := g.a.nodes[int(or_body_id)]
	tmp := g.tmp_name()
	expr_type := g.tc.resolve_type(expr_id)
	opt_ct := g.optional_type_name(expr_type)
	g.writeln('${opt_ct} ${tmp} = ')
	g.gen_expr(expr_id)
	g.writeln(';')
	g.writeln('if (!${tmp}.ok) {')
	g.tc.push_scope()
	g.tc.cur_scope.insert('err', types.Type(types.Struct{
		name: 'IError'
	}))
	g.indent++
	g.writeln('IError err = (IError){0};')
	for i in 0 .. or_body.children_count {
		g.gen_node(g.a.child(&or_body, i))
	}
	g.indent--
	g.tc.pop_scope()
	g.writeln('}')
}

fn (mut g FlatGen) gen_struct_init(node flat.Node) {
	name := g.tc.c_type(g.tc.parse_type(node.value))
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
	name := g.tc.c_type(g.tc.parse_type(node.value))
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
	map_type := g.tc.parse_type(node.value)
	if map_type is types.Map {
		c_key := g.tc.c_type(map_type.key_type)
		c_val := g.tc.c_type(map_type.value_type)
		g.write('new_map(sizeof(${c_key}), sizeof(${c_val}), 0, 0, 0, 0)')
	} else {
		g.write('new_map(sizeof(int), sizeof(int), 0, 0, 0, 0)')
	}
}

fn (mut g FlatGen) gen_call(node flat.Node) {
	fn_node := g.a.child_node(&node, 0)
	fn_name := fn_node.value
	match fn_name {
		'panic' {
			g.write('v_panic(')
			if node.children_count > 1 {
				arg_id := g.a.child(&node, 1)
				arg_type := g.tc.resolve_type(arg_id)
				if arg_type is types.Struct && arg_type.name == 'IError' {
					g.gen_expr(arg_id)
					g.write('.message')
				} else {
					g.gen_expr(arg_id)
				}
			}
			g.write(')')
			return
		}
		'error' {
			if g.cur_fn_ret is types.OptionType || g.cur_fn_ret is types.ResultType {
				ct := g.optional_type_name(g.cur_fn_ret)
				g.write('(${ct}){.ok = false}')
			} else {
				ct := g.tc.c_type(g.cur_fn_ret)
				g.write('(${ct}){0}')
			}
			return
		}
		'error_with_code' {
			if g.cur_fn_ret is types.OptionType || g.cur_fn_ret is types.ResultType {
				ct := g.optional_type_name(g.cur_fn_ret)
				g.write('(${ct}){.ok = false}')
			} else {
				ct := g.tc.c_type(g.cur_fn_ret)
				g.write('(${ct}){0}')
			}
			return
		}
		'println', 'print' {
			g.write(fn_name)
			g.write('(')
			if node.children_count > 1 {
				arg_id := g.a.child(&node, 1)
				arg_type := g.tc.resolve_type(arg_id)
				if arg_type is types.String {
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
				} else if base.kind == .ident && base.value in g.modules {
					mod := g.modules[base.value]
					short_mod := if mod.contains('.') {
						mod.all_after_last('.')
					} else {
						mod
					}
					full_name := '${short_mod}.${fn_node.value}'
					if full_name in g.tc.type_aliases || full_name in g.tc.structs || full_name in g.tc.enum_names || full_name in g.tc.sum_types {
						target_type := g.tc.parse_type(full_name)
						ct := g.tc.c_type(target_type)
						if target_type is types.SumType && node.children_count > 1 {
							inner_id := g.a.child(&node, 1)
							inner := g.a.nodes[int(inner_id)]
							variant_name0 := if inner.kind == .struct_init || inner.kind == .cast_expr {
								inner.value
							} else {
								g.tc.resolve_type(inner_id).name()
							}
							variant_name := g.resolve_variant(target_type.name, variant_name0)
							idx := g.sum_type_index(target_type.name, variant_name)
							field := g.sum_field_name(variant_name)
							if g.variant_references_sum(variant_name, target_type.name) {
								inner_ct := g.tc.c_type(g.tc.parse_type(variant_name))
								g.write('(${ct}){.typ = ${idx}, .${field} = (${inner_ct}*)memdup(&(${inner_ct}){')
								if inner.kind == .struct_init {
									for si in 0 .. inner.children_count {
										sf := g.a.child_node(&inner, si)
										if si > 0 {
											g.write(', ')
										}
										g.write('.${c_name(sf.value)} = ')
										g.gen_expr(g.a.child(sf, 0))
									}
								} else {
									g.gen_expr(inner_id)
								}
								g.write('}, sizeof(${inner_ct}))}')
							} else {
								g.write('(${ct}){.typ = ${idx}, .${field} = ')
								g.gen_expr(inner_id)
								g.write('}')
							}
						} else {
							g.write('(${ct})(')
							for i in 1 .. node.children_count {
								if i > 1 {
									g.write(', ')
								}
								g.gen_expr(g.a.child(&node, i))
							}
							g.write(')')
						}
						return
					}
					g.write(c_name(full_name))
					g.write('(')
					g.gen_call_args(full_name, node, 1)
					g.write(')')
					return
				} else if base.kind == .selector {
					// module.Type.method() pattern
					inner := g.a.child_node(base, 0)
					if inner.kind == .ident && inner.value in g.modules {
						mod := g.modules[inner.value]
						short_mod := if mod.contains('.') {
							mod.all_after_last('.')
						} else {
							mod
						}
						full_name := '${short_mod}.${base.value}.${fn_node.value}'
						g.write(c_name(full_name))
						g.write('(')
						g.gen_call_args(full_name, node, 1)
						g.write(')')
						return
					} else {
						base_type := g.tc.resolve_type(g.a.child(fn_node, 0))
						clean_type := types.unwrap_pointer(base_type)
						if clean_type is types.Array {
							g.gen_array_method_call(node, fn_node, clean_type as types.Array)
							return
						}
						if clean_type is types.Map {
							if fn_node.value == 'delete' {
								g.gen_map_delete(node, fn_node, clean_type as types.Map)
								return
							} else if fn_node.value == 'clone' {
								g.write('map__clone(&')
								g.gen_expr(g.a.child(fn_node, 0))
								g.write(')')
								return
							} else if fn_node.value == 'clear' {
								g.write('map__clear(&')
								g.gen_expr(g.a.child(fn_node, 0))
								g.write(')')
								return
							}
						}
						if clean_type is types.String {
							method_name = 'string.${fn_node.value}'
							if method_name in g.tc.fn_param_types {
								is_method = true
								base_id = g.a.child(fn_node, 0)
								g.write(c_name(method_name))
							} else {
								g.write('string__${fn_node.value}(')
								g.gen_expr(g.a.child(fn_node, 0))
								for i in 1 .. node.children_count {
									g.write(', ')
									g.gen_expr(g.a.child(&node, i))
								}
								g.write(')')
								return
							}
						}
						if !is_method {
							struct_name := if clean_type is types.Struct {
								clean_type.name
							} else {
								clean_type.name()
							}
							method_name = '${struct_name}.${fn_node.value}'
							if method_name !in g.tc.fn_param_types {
								for alias, target in g.tc.type_aliases {
									if target == struct_name {
										alias_method := '${alias}.${fn_node.value}'
										if alias_method in g.tc.fn_param_types {
											method_name = alias_method
											break
										}
									}
								}
							}
							if method_name in g.tc.fn_param_types {
								is_method = true
								base_id = g.a.child(fn_node, 0)
								g.write(c_name(method_name))
							} else {
								str_method := 'string.${fn_node.value}'
								if str_method in g.tc.fn_param_types {
									is_method = true
									method_name = str_method
									base_id = g.a.child(fn_node, 0)
									g.write(c_name(str_method))
								} else {
									g.gen_expr(g.a.child(&node, 0))
								}
							}
						}
					}
				} else if base.kind == .ident && (base.value in g.tc.structs || base.value in g.tc.enum_names || g.tc.qualify_name(base.value) in g.tc.structs || g.tc.qualify_name(base.value) in g.tc.enum_names) {
					qname := if base.value in g.tc.structs || base.value in g.tc.enum_names {
						base.value
					} else {
						g.tc.qualify_name(base.value)
					}
					static_name := '${qname}.${fn_node.value}'
					g.write(c_name(static_name))
					g.write('(')
					for i in 1 .. node.children_count {
						if i > 1 {
							g.write(', ')
						}
						g.gen_expr(g.a.child(&node, i))
					}
					g.write(')')
					return
				} else {
					base_type := g.tc.resolve_type(g.a.child(fn_node, 0))
					clean_type := types.unwrap_pointer(base_type)
					if clean_type is types.Array {
						g.gen_array_method_call(node, fn_node, clean_type as types.Array)
						return
					}
					if clean_type is types.Map {
						if fn_node.value == 'delete' {
							g.gen_map_delete(node, fn_node, clean_type as types.Map)
							return
						} else if fn_node.value == 'clone' {
							g.write('map__clone(&')
							g.gen_expr(g.a.child(fn_node, 0))
							g.write(')')
							return
						} else if fn_node.value == 'clear' {
							g.write('map__clear(&')
							g.gen_expr(g.a.child(fn_node, 0))
							g.write(')')
							return
						}
					}
					if clean_type is types.String {
						method_name = 'string.${fn_node.value}'
						if method_name in g.tc.fn_param_types {
							is_method = true
							base_id = g.a.child(fn_node, 0)
							g.write(c_name(method_name))
						} else {
							g.write('string__${fn_node.value}(')
							g.gen_expr(g.a.child(fn_node, 0))
							for i in 1 .. node.children_count {
								g.write(', ')
								g.gen_expr(g.a.child(&node, i))
							}
							g.write(')')
							return
						}
					}
					if !is_method && (clean_type is types.Void || clean_type is types.Primitive) && fn_node.value in ['vstring', 'vstring_with_len'] {
						g.write('u8__${fn_node.value}((u8*)')
						g.gen_expr(g.a.child(fn_node, 0))
						for i in 1 .. node.children_count {
							g.write(', ')
							g.gen_expr(g.a.child(&node, i))
						}
						g.write(')')
						return
					}
					if !is_method && clean_type is types.Struct && clean_type.name == 'IError' {
						if fn_node.value == 'msg' {
							g.gen_expr(g.a.child(fn_node, 0))
							g.write('.message')
							return
						} else if fn_node.value == 'code' {
							g.gen_expr(g.a.child(fn_node, 0))
							g.write('.code')
							return
						}
					}
					if !is_method {
					struct_name := if clean_type is types.Struct {
						clean_type.name
					} else {
						clean_type.name()
					}
					method_name = '${struct_name}.${fn_node.value}'
					if method_name !in g.tc.fn_param_types {
						for alias, target in g.tc.type_aliases {
							if target == struct_name {
								alias_method := '${alias}.${fn_node.value}'
								if alias_method in g.tc.fn_param_types {
									method_name = alias_method
									break
								}
							}
						}
					}
					if method_name in g.tc.fn_param_types {
						is_method = true
						base_id = g.a.child(fn_node, 0)
						g.write(c_name(method_name))
					} else {
						str_method := 'string.${fn_node.value}'
						if str_method in g.tc.fn_param_types {
							is_method = true
							method_name = str_method
							base_id = g.a.child(fn_node, 0)
							g.write(c_name(str_method))
						} else {
							g.gen_expr(g.a.child(&node, 0))
						}
					}
					} // !is_method
				}
			} else {
				fn_id := g.a.child(&node, 0)
				fn_ident := g.a.nodes[int(fn_id)]
				if fn_ident.kind == .ident {
					qname := g.tc.qualify_name(fn_ident.value)
					if fn_ident.value in g.tc.type_aliases || qname in g.tc.type_aliases || fn_ident.value in g.tc.structs || qname in g.tc.structs || fn_ident.value in g.tc.enum_names || qname in g.tc.enum_names || fn_ident.value in g.tc.sum_types || qname in g.tc.sum_types {
						target_type := g.tc.parse_type(fn_ident.value)
						ct := g.tc.c_type(target_type)
						if target_type is types.SumType && node.children_count > 1 {
							inner_id := g.a.child(&node, 1)
							inner := g.a.nodes[int(inner_id)]
							variant_name0 := if inner.kind == .struct_init || inner.kind == .cast_expr {
								inner.value
							} else {
								g.tc.resolve_type(inner_id).name()
							}
							variant_name := g.resolve_variant(target_type.name, variant_name0)
							idx := g.sum_type_index(target_type.name, variant_name)
							field := g.sum_field_name(variant_name)
							if g.variant_references_sum(variant_name, target_type.name) {
								inner_ct := g.tc.c_type(g.tc.parse_type(variant_name))
								g.write('(${ct}){.typ = ${idx}, .${field} = (${inner_ct}*)memdup(&(${inner_ct}){')
								if inner.kind == .struct_init {
									for si in 0 .. inner.children_count {
										sf := g.a.child_node(&inner, si)
										if si > 0 {
											g.write(', ')
										}
										g.write('.${c_name(sf.value)} = ')
										g.gen_expr(g.a.child(sf, 0))
									}
								} else {
									g.gen_expr(inner_id)
								}
								g.write('}, sizeof(${inner_ct}))}')
							} else {
								g.write('(${ct}){.typ = ${idx}, .${field} = ')
								g.gen_expr(inner_id)
								g.write('}')
							}
						} else {
							g.write('(${ct})(')
							for i in 1 .. node.children_count {
								if i > 1 {
									g.write(', ')
								}
								g.gen_expr(g.a.child(&node, i))
							}
							g.write(')')
						}
						return
					}
					qfn := g.tc.qualify_fn_name(fn_ident.value)
					if qfn in g.tc.fn_ret_types || qfn in g.tc.fn_param_types {
						g.write(c_name(qfn))
					} else {
						g.write(c_name(fn_ident.value))
					}
				} else {
					g.gen_expr(fn_id)
				}
			}
			g.write('(')
			actual_fn := if is_method {
				method_name
			} else {
				g.tc.qualify_fn_name(fn_name)
			}
			param_types := if actual_fn in g.tc.fn_param_types {
				g.tc.fn_param_types[actual_fn]
			} else if fn_name in g.tc.fn_param_types {
				g.tc.fn_param_types[fn_name]
			} else {
				[]types.Type{}
			}
			mut arg_start := 1
			if is_method {
				base_type := g.tc.resolve_type(base_id)
				is_ptr_base := base_type is types.Pointer
				wants_ptr := param_types.len > 0 && param_types[0] is types.Pointer
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
				arg_id := g.a.child(&node, i)
				arg_node := g.a.nodes[int(arg_id)]
				if !is_c_call && arg_idx < param_types.len && param_types[arg_idx] is types.Pointer && !(arg_node.kind == .prefix && arg_node.op == .amp) {
					arg_type := g.tc.resolve_type(arg_id)
					if arg_type !is types.Pointer {
						g.write('&')
					}
				}
				g.gen_expr(arg_id)
			}
			actual_args := node.children_count - arg_start
			expected_args := if is_method {
				param_types.len - 1
			} else {
				param_types.len
			}
			if !is_c_call && expected_args > 0 && actual_args < expected_args {
				for pi in actual_args .. expected_args {
					if is_method || pi > 0 {
						g.write(', ')
					}
					pidx := if is_method { pi + 1 } else { pi }
					pt := param_types[pidx]
					ct := g.tc.c_type(pt)
					g.write('(${ct}){0}')
				}
			}
			g.write(')')
		}
	}
}

fn (mut g FlatGen) gen_call_args(fn_name string, node flat.Node, start int) {
	param_types := if fn_name in g.tc.fn_param_types {
		g.tc.fn_param_types[fn_name]
	} else {
		[]types.Type{}
	}
	variadic_idx := if param_types.len > 0 && param_types[param_types.len - 1] is types.Array {
		param_types.len - 1
	} else {
		-1
	}
	num_args := node.children_count - start
	is_variadic := variadic_idx >= 0 && num_args > param_types.len
	for i in start .. node.children_count {
		if i > start {
			g.write(', ')
		}
		arg_idx := i - start
		arg_id := g.a.child(&node, i)
		arg_node := g.a.nodes[int(arg_id)]
		if is_variadic && arg_idx == variadic_idx {
			variadic_type := param_types[variadic_idx]
			if variadic_type is types.Array {
				c_elem := g.tc.c_type(variadic_type.elem_type)
				count := num_args - variadic_idx
				g.write('new_array_from_c_array(${count}, ${count}, sizeof(${c_elem}), (${c_elem}[]){')
				for j in i .. node.children_count {
					if j > i {
						g.write(', ')
					}
					g.gen_expr(g.a.child(&node, j))
				}
				g.write('})')
			}
			break
		}
		if arg_idx < param_types.len && param_types[arg_idx] is types.Pointer && !(arg_node.kind == .prefix && arg_node.op == .amp) {
			arg_type := g.tc.resolve_type(arg_id)
			if arg_type !is types.Pointer {
				g.write('&')
			}
		}
		g.gen_expr(arg_id)
	}
	num_provided := node.children_count - start
	if num_provided < param_types.len {
		for i in num_provided .. param_types.len {
			if num_provided > 0 || i > num_provided {
				g.write(', ')
			}
			ct := g.tc.c_type(param_types[i])
			g.write('(${ct}){0}')
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
	clean := types.unwrap_pointer(base_type)
	if clean is types.Enum {
		return true
	} else if clean is types.Primitive {
		return clean.props.has(.integer)
	}
	return false
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
			if typ is types.String {
				g.gen_expr(child_id)
			} else if typ is types.Struct && typ.name == 'IError' {
				g.gen_expr(child_id)
				g.write('.message')
			} else if typ is types.Primitive {
				ct := g.tc.c_type(typ)
				g.write('${ct}_str(')
				g.gen_expr(child_id)
				g.write(')')
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
	return g.tc.resolve_type(id) is types.String
}

fn is_generic_type(typ string) bool {
	t := typ.trim_left('&?!')
	return t.len == 1 && t[0] >= `A` && t[0] <= `Z`
}

fn (g &FlatGen) has_generic_params(node flat.Node) bool {
	for i in 0 .. node.children_count {
		child := g.a.child_node(&node, i)
		if child.kind == .param && is_generic_type(child.typ) {
			return true
		}
	}
	return is_generic_type(node.typ)
}

fn (mut g FlatGen) optional_type_name(t types.Type) string {
	base_type := if t is types.OptionType {
		t.base_type
	} else if t is types.ResultType {
		t.base_type
	} else {
		return g.tc.c_type(t)
	}

	if base_type is types.Void || base_type is types.Primitive || base_type is types.Enum {
		return 'Optional'
	}
	inner_ct := g.tc.c_type(base_type)
	safe_name := inner_ct.replace('*', 'ptr').replace(' ', '_')
	opt_name := 'Optional_${safe_name}'
	g.needed_optional_types[opt_name] = inner_ct
	return opt_name
}

fn (mut g FlatGen) optional_value_ct(t types.Type) (string, types.Type) {
	if t is types.OptionType {
		if t.base_type is types.Void {
			return 'int', types.Type(types.int_)
		}
		return g.tc.c_type(t.base_type), t.base_type
	} else if t is types.ResultType {
		if t.base_type is types.Void {
			return 'int', types.Type(types.int_)
		}
		return g.tc.c_type(t.base_type), t.base_type
	}
	return 'int', types.Type(types.int_)
}

fn (mut g FlatGen) optional_typedefs() {
	for opt_name, val_type in g.needed_optional_types {
		g.writeln('typedef struct { bool ok; ${val_type} value; } ${opt_name};')
	}
	if g.needed_optional_types.len > 0 {
		g.writeln('')
	}
}

fn (mut g FlatGen) forward_decls() {
	for i, node in g.a.nodes {
		if node.kind == .module_decl {
			g.tc.cur_module = node.value
			continue
		}
		if node.kind == .fn_decl && node.value != 'main' {
			if g.has_builtins && i < g.a.user_code_start {
				continue
			}
			dfn := g.dotted_fn_name(node.value)
			if g.used_fns.len > 0 && node.value !in g.used_fns && dfn !in g.used_fns {
				continue
			}
			if g.has_generic_params(node) {
				continue
			}
			if g.tc.cur_module == 'strings' && node.value in ['Builder.ensure_cap', 'Builder.grow_len', 'Builder.free', 'Builder.reuse_as_plain_u8_array', 'Builder.byte_at', 'Builder.drain_builder', 'Builder.indent'] {
				continue
			}
			params := g.fn_params_list(node)
			if g.has_c_struct_type(node, params) {
				continue
			}
			ret_type := g.tc.parse_type(node.typ)
			g.write(g.optional_type_name(ret_type))
			g.write(' ')
			g.write(g.qualified_fn_name(node.value))
			g.write('(')
			g.write_fn_params(params)
			g.writeln(');')
		}
	}
	g.writeln('')
}

fn (g &FlatGen) has_c_struct_type(node flat.Node, params []flat.Node) bool {
	ret := g.tc.parse_type(node.typ)
	if ret is types.Struct && ret.name.starts_with('C.') {
		return true
	}
	for p in params {
		pt := g.tc.parse_type(p.typ)
		if pt is types.Struct && pt.name.starts_with('C.') {
			return true
		}
	}
	return false
}

fn (mut g FlatGen) write_fn_params(params []flat.Node) {
	if params.len == 0 {
		g.write('void')
		return
	}
	for i, p in params {
		pt := g.tc.parse_type(p.typ)
		ct := g.tc.c_type(pt)
		if ct.starts_with('fn_ptr:') {
			g.write(g.resolve_fn_ptr_type(ct))
		} else {
			g.write(ct)
		}
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
	if g.has_builtins {
		g.writeln('#include <time.h>')
		g.writeln('#include <sys/time.h>')
		g.writeln('#include <errno.h>')
		g.writeln('#include <signal.h>')
		g.writeln('#include <dirent.h>')
		g.writeln('#include <sys/stat.h>')
		g.writeln('#include <fcntl.h>')
		g.writeln('#include <pthread.h>')
		g.writeln('#include <unistd.h>')
		g.writeln('#ifdef __APPLE__')
		g.writeln('#include <mach/mach_time.h>')
		g.writeln('#endif')
	}
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
	g.writeln('#ifndef __bool_true_false_are_defined')
	g.writeln('typedef int bool;')
	g.writeln('#endif')
	g.writeln('typedef void* voidptr;')
	g.writeln('#define true 1')
	g.writeln('#define false 0')
	g.writeln('')
	if !g.has_builtins {
		g.writeln('typedef struct {')
		g.writeln('\tchar* str;')
		g.writeln('\tint len;')
		g.writeln('\tint is_lit;')
		g.writeln('} string;')
		g.writeln('')
	}
	g.writeln('#define element_size elem_size')
	g.writeln('#define c_name types__c_name')
	if g.has_builtins {
		return
	}
	g.writeln('typedef struct Array { void* data; int len; int cap; int elem_size; } Array;')
	g.writeln('')
}

fn (mut g FlatGen) runtime_fns() {
	g.writeln('Array array_new(int elem_size, int len, int cap) {')
	g.writeln('\tArray a; a.elem_size = elem_size; a.len = len; a.cap = cap > len ? cap : (len > 0 ? len : 4);')
	g.writeln('\ta.data = calloc(a.cap, elem_size); return a;')
	g.writeln('}')
	g.writeln('Array new_array_from_c_array(int len, int cap, int elem_size, void* data) {')
	g.writeln('\tArray a = array_new(elem_size, len, cap);')
	g.writeln('\tmemcpy(a.data, data, len * elem_size); return a;')
	g.writeln('}')
	g.writeln('void array_push(Array* a, void* elem) {')
	g.writeln('\tif (a->len >= a->cap) { a->cap = a->cap < 4 ? 4 : a->cap * 2; a->data = realloc(a->data, a->cap * a->elem_size); }')
	g.writeln('\tmemcpy((char*)a->data + a->len * a->elem_size, elem, a->elem_size); a->len++;')
	g.writeln('}')
	g.writeln('void array_push_many(Array* a, Array b) {')
	g.writeln('\tint new_len = a->len + b.len;')
	g.writeln('\tif (new_len > a->cap) { a->cap = new_len < 4 ? 4 : new_len * 2; a->data = realloc(a->data, a->cap * a->elem_size); }')
	g.writeln('\tmemcpy((char*)a->data + a->len * a->elem_size, b.data, b.len * a->elem_size); a->len = new_len;')
	g.writeln('}')
	g.writeln('void array_push_many_ptr(Array* a, void* ptr, int len) {')
	g.writeln('\tint new_len = a->len + len;')
	g.writeln('\tif (new_len > a->cap) { a->cap = new_len < 4 ? 4 : new_len * 2; a->data = realloc(a->data, a->cap * a->elem_size); }')
	g.writeln('\tmemcpy((char*)a->data + a->len * a->elem_size, ptr, len * a->elem_size); a->len = new_len;')
	g.writeln('}')
	g.writeln('void* array_get(Array a, int idx) { return (char*)a.data + idx * a.elem_size; }')
	g.writeln('void array_set(Array a, int idx, void* val) { memcpy((char*)a.data + idx * a.elem_size, val, a.elem_size); }')
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
	g.writeln('bool fixed_array_contains_string(const string* a, int len, string val) {')
	g.writeln('\tfor (int i = 0; i < len; i++) if (string__eq(a[i], val)) return true; return false;')
	g.writeln('}')
	g.writeln('bool fixed_array_contains_int(const int* a, int len, int val) {')
	g.writeln('\tfor (int i = 0; i < len; i++) if (a[i] == val) return true; return false;')
	g.writeln('}')
	g.writeln('')
	if !g.has_builtins {
		g.writeln('typedef struct { unsigned int hash; bool used; } MapSlot;')
		g.writeln('typedef struct { MapSlot* slots; char* keys; char* vals; int cap; int len; int key_size; int val_size; } map;')
	}
	g.writeln('')
	g.writeln('static unsigned int _map_hash_bytes(const void* key, int key_size) {')
	g.writeln('\tunsigned int h = 2166136261u; const unsigned char* p = (const unsigned char*)key;')
	g.writeln('\tfor (int i = 0; i < key_size; i++) { h ^= p[i]; h *= 16777619u; } return h ? h : 1;')
	g.writeln('}')
	g.writeln('static unsigned int _map_hash_string(string key) { return _map_hash_bytes(key.str, key.len); }')
	g.writeln('static void _map_set_internal(map* m, const void* key, unsigned int hash, const void* val);')
	g.writeln('static void _map_grow(map* m) {')
	g.writeln('\tint old_cap = m->cap; MapSlot* old_slots = m->slots; char* old_keys = m->keys; char* old_vals = m->vals;')
	g.writeln('\tm->cap *= 2; m->len = 0;')
	g.writeln('\tm->slots = (MapSlot*)calloc(m->cap, sizeof(MapSlot));')
	g.writeln('\tm->keys = (char*)calloc(m->cap, m->key_size); m->vals = (char*)calloc(m->cap, m->val_size);')
	g.writeln('\tfor (int i = 0; i < old_cap; i++) if (old_slots[i].used)')
	g.writeln('\t\t_map_set_internal(m, old_keys + i * m->key_size, old_slots[i].hash, old_vals + i * m->val_size);')
	g.writeln('\tfree(old_slots); free(old_keys); free(old_vals);')
	g.writeln('}')
	g.writeln('static void _map_set_internal(map* m, const void* key, unsigned int hash, const void* val) {')
	g.writeln('\tif (m->len * 2 >= m->cap) _map_grow(m);')
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
	g.writeln('map new_map(int key_size, int val_size, void* hash_fn, void* eq_fn, void* clone_fn, void* free_fn) {')
	g.writeln('\tmap m = {0}; m.cap = 16; m.key_size = key_size; m.val_size = val_size;')
	g.writeln('\tm.slots = (MapSlot*)calloc(m.cap, sizeof(MapSlot));')
	g.writeln('\tm.keys = (char*)calloc(m.cap, key_size); m.vals = (char*)calloc(m.cap, val_size); return m;')
	g.writeln('}')
	g.writeln('void map__set(map* m, void* key, void* val) {')
	g.writeln('\tif (m->key_size > (int)sizeof(void*)) {')
	g.writeln('\t\tunsigned int hash = _map_hash_string(*(string*)key);')
	g.writeln('\t\tunsigned int idx = hash & (m->cap - 1);')
	g.writeln('\t\tif (m->len * 2 >= m->cap) _map_grow(m);')
	g.writeln('\t\tidx = hash & (m->cap - 1);')
	g.writeln('\t\twhile (m->slots[idx].used) {')
	g.writeln('\t\t\tif (m->slots[idx].hash == hash && string__eq(*(string*)(m->keys + idx * m->key_size), *(string*)key)) {')
	g.writeln('\t\t\t\tmemcpy(m->vals + idx * m->val_size, val, m->val_size); return; }')
	g.writeln('\t\t\tidx = (idx + 1) & (m->cap - 1);')
	g.writeln('\t\t}')
	g.writeln('\t\tm->slots[idx].used = 1; m->slots[idx].hash = hash;')
	g.writeln('\t\tmemcpy(m->keys + idx * m->key_size, key, m->key_size);')
	g.writeln('\t\tmemcpy(m->vals + idx * m->val_size, val, m->val_size); m->len++;')
	g.writeln('\t} else { _map_set_internal(m, key, _map_hash_bytes(key, m->key_size), val); }')
	g.writeln('}')
	g.writeln('void* map__get(map* m, void* key, void* zero) {')
	g.writeln('\tif (m->len == 0) return zero;')
	g.writeln('\tunsigned int hash = (m->key_size > (int)sizeof(void*)) ? _map_hash_string(*(string*)key) : _map_hash_bytes(key, m->key_size);')
	g.writeln('\tunsigned int idx = hash & (m->cap - 1);')
	g.writeln('\twhile (m->slots[idx].used) {')
	g.writeln('\t\tif (m->slots[idx].hash == hash) {')
	g.writeln('\t\t\tint eq = (m->key_size > (int)sizeof(void*)) ? string__eq(*(string*)(m->keys + idx * m->key_size), *(string*)key) : memcmp(m->keys + idx * m->key_size, key, m->key_size) == 0;')
	g.writeln('\t\t\tif (eq) return m->vals + idx * m->val_size;')
	g.writeln('\t\t}')
	g.writeln('\t\tidx = (idx + 1) & (m->cap - 1);')
	g.writeln('\t} return zero;')
	g.writeln('}')
	g.writeln('void* map__get_check(map* m, void* key) {')
	g.writeln('\tif (m->len == 0) return 0;')
	g.writeln('\tunsigned int hash = (m->key_size > (int)sizeof(void*)) ? _map_hash_string(*(string*)key) : _map_hash_bytes(key, m->key_size);')
	g.writeln('\tunsigned int idx = hash & (m->cap - 1);')
	g.writeln('\twhile (m->slots[idx].used) {')
	g.writeln('\t\tif (m->slots[idx].hash == hash) {')
	g.writeln('\t\t\tint eq = (m->key_size > (int)sizeof(void*)) ? string__eq(*(string*)(m->keys + idx * m->key_size), *(string*)key) : memcmp(m->keys + idx * m->key_size, key, m->key_size) == 0;')
	g.writeln('\t\t\tif (eq) return m->vals + idx * m->val_size;')
	g.writeln('\t\t}')
	g.writeln('\t\tidx = (idx + 1) & (m->cap - 1);')
	g.writeln('\t} return 0;')
	g.writeln('}')
	g.writeln('bool map__exists(map* m, void* key) { return map__get_check(m, key) != 0; }')
	g.writeln('static void _map_delete_idx(map* m, unsigned int idx) {')
	g.writeln('\tm->slots[idx].used = 0; m->len--;')
	g.writeln('\tunsigned int j = (idx + 1) & (m->cap - 1);')
	g.writeln('\twhile (m->slots[j].used) {')
	g.writeln('\t\tunsigned int k = m->slots[j].hash & (m->cap - 1);')
	g.writeln('\t\tif ((j > idx && (k <= idx || k > j)) || (j < idx && k <= idx && k > j)) {')
	g.writeln('\t\t\tm->slots[idx] = m->slots[j];')
	g.writeln('\t\t\tmemcpy(m->keys + idx * m->key_size, m->keys + j * m->key_size, m->key_size);')
	g.writeln('\t\t\tmemcpy(m->vals + idx * m->val_size, m->vals + j * m->val_size, m->val_size);')
	g.writeln('\t\t\tm->slots[j].used = 0; idx = j;')
	g.writeln('\t\t}')
	g.writeln('\t\tj = (j + 1) & (m->cap - 1);')
	g.writeln('\t}')
	g.writeln('}')
	g.writeln('void map__delete(map* m, void* key) {')
	g.writeln('\tunsigned int hash = (m->key_size > (int)sizeof(void*)) ? _map_hash_string(*(string*)key) : _map_hash_bytes(key, m->key_size);')
	g.writeln('\tunsigned int idx = hash & (m->cap - 1);')
	g.writeln('\twhile (m->slots[idx].used) {')
	g.writeln('\t\tif (m->slots[idx].hash == hash) {')
	g.writeln('\t\t\tint eq = (m->key_size > (int)sizeof(void*)) ? string__eq(*(string*)(m->keys + idx * m->key_size), *(string*)key) : memcmp(m->keys + idx * m->key_size, key, m->key_size) == 0;')
	g.writeln('\t\t\tif (eq) { _map_delete_idx(m, idx); return; }')
	g.writeln('\t\t}')
	g.writeln('\t\tidx = (idx + 1) & (m->cap - 1);')
	g.writeln('\t}')
	g.writeln('}')
	g.writeln('map map__clone(map* m) {')
	g.writeln('\tmap n = new_map(m->key_size, m->val_size, 0, 0, 0, 0);')
	g.writeln('\tfree(n.slots); free(n.keys); free(n.vals);')
	g.writeln('\tn.cap = m->cap; n.len = m->len;')
	g.writeln('\tn.slots = (MapSlot*)calloc(m->cap, sizeof(MapSlot)); memcpy(n.slots, m->slots, m->cap * sizeof(MapSlot));')
	g.writeln('\tn.keys = (char*)calloc(m->cap, m->key_size); memcpy(n.keys, m->keys, m->cap * m->key_size);')
	g.writeln('\tn.vals = (char*)calloc(m->cap, m->val_size); memcpy(n.vals, m->vals, m->cap * m->val_size);')
	g.writeln('\treturn n;')
	g.writeln('}')
	g.writeln('void map__clear(map* m) {')
	g.writeln('\tmemset(m->slots, 0, m->cap * sizeof(MapSlot));')
	g.writeln('\tm->len = 0;')
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
	g.writeln('string tos(u8* s, int len) { return (string){(char*)s, len, 0}; }')
	g.writeln('string tos3(char* s) { return (string){s, s ? (int)strlen(s) : 0, 0}; }')
	g.writeln('string tos_clone(u8* s) { if (!s) return (string){0}; int n = (int)strlen((char*)s); char* p = malloc(n+1); memcpy(p,s,n); p[n]=0; return (string){p,n,0}; }')
	g.writeln('string string__clone(string s) {')
	g.writeln('\tchar* p = malloc(s.len + 1); memcpy(p, s.str, s.len); p[s.len] = 0;')
	g.writeln('\treturn (string){p, s.len, 0};')
	g.writeln('}')
	g.writeln('void string__free(string* s) { if (s->str && !s->is_lit) free((void*)s->str); }')
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
	g.writeln('Array string__bytes(string s) {')
	g.writeln('\tArray a = array_new(1, s.len, s.len);')
	g.writeln('\tmemcpy(a.data, s.str, s.len);')
	g.writeln('\treturn a;')
	g.writeln('}')
	g.writeln('int string__index_u8(string s, u8 c) {')
	g.writeln('\tfor (int i = 0; i < s.len; i++) if (((u8*)s.str)[i] == c) return i;')
	g.writeln('\treturn -1;')
	g.writeln('}')
	g.writeln('int string__last_index_u8(string s, u8 c) {')
	g.writeln('\tfor (int i = s.len - 1; i >= 0; i--) if (((u8*)s.str)[i] == c) return i;')
	g.writeln('\treturn -1;')
	g.writeln('}')
	g.writeln('Optional string__index(string s, string p) {')
	g.writeln('\tif (p.len > s.len) return (Optional){0};')
	g.writeln('\tfor (int i = 0; i <= s.len - p.len; i++) if (memcmp(s.str + i, p.str, p.len) == 0) return (Optional){.ok = true, .value = i};')
	g.writeln('\treturn (Optional){0};')
	g.writeln('}')
	g.writeln('Optional string__last_index(string s, string p) {')
	g.writeln('\tif (p.len > s.len) return (Optional){0};')
	g.writeln('\tfor (int i = s.len - p.len; i >= 0; i--) if (memcmp(s.str + i, p.str, p.len) == 0) return (Optional){.ok = true, .value = i};')
	g.writeln('\treturn (Optional){0};')
	g.writeln('}')
	g.writeln('string string__substr(string s, int start, int end) {')
	g.writeln('\tint slen = end - start; if (slen <= 0) return (string){"", 0, 1};')
	g.writeln('\tchar* buf = malloc(slen + 1); memcpy(buf, s.str + start, slen); buf[slen] = 0;')
	g.writeln('\treturn (string){buf, slen, 0};')
	g.writeln('}')
	g.writeln('string string__all_before(string s, string sub) {')
	g.writeln('\tOptional r = string__index(s, sub); if (!r.ok) return s;')
	g.writeln('\treturn string__substr(s, 0, r.value);')
	g.writeln('}')
	g.writeln('string string__all_before_last(string s, string sub) {')
	g.writeln('\tOptional r = string__last_index(s, sub); if (!r.ok) return s;')
	g.writeln('\treturn string__substr(s, 0, r.value);')
	g.writeln('}')
	g.writeln('string string__all_after(string s, string sub) {')
	g.writeln('\tOptional r = string__index(s, sub); if (!r.ok) return s;')
	g.writeln('\treturn string__substr(s, r.value + sub.len, s.len);')
	g.writeln('}')
	g.writeln('string string__all_after_last(string s, string sub) {')
	g.writeln('\tOptional r = string__last_index(s, sub); if (!r.ok) return s;')
	g.writeln('\treturn string__substr(s, r.value + sub.len, s.len);')
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
	g.writeln('i64 string__i64(string s) { return (i64)strtoll(s.str, NULL, 10); }')
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
	g.writeln('bool isnil(void* p) { return p == NULL; }')
	g.writeln('Optional error_with_code(string msg, int code) { return (Optional){.ok = false}; }')
	g.writeln('Optional check_fwrite(size_t n) { return (Optional){.ok = n > 0, .value = (int)n}; }')
	g.writeln('void* malloc_noscan(size_t n) { return malloc(n); }')
	g.writeln('string u8__vstring(u8* s) { return (string){(char*)s, (int)strlen((char*)s), 0}; }')
	g.writeln('string u8__vstring_with_len(u8* s, int len) { return (string){(char*)s, len, 0}; }')
	g.writeln('char v_char(char c) { return c; }')
	g.writeln('')
	if g.has_builtins {
		g.writeln('extern int g_main_argc;')
		g.writeln('extern void* g_main_argv;')
		g.writeln('string utf32_to_str_no_malloc(u32 code, u8* buf) {')
		g.writeln('\tif (code <= 0x7F) { buf[0] = (u8)code; return tos(buf, 1); }')
		g.writeln('\tif (code <= 0x7FF) { buf[0] = 0xC0|(code>>6); buf[1] = 0x80|(code&0x3F); return tos(buf, 2); }')
		g.writeln('\tif (code <= 0xFFFF) { buf[0] = 0xE0|(code>>12); buf[1] = 0x80|((code>>6)&0x3F); buf[2] = 0x80|(code&0x3F); return tos(buf, 3); }')
		g.writeln('\tbuf[0] = 0xF0|(code>>18); buf[1] = 0x80|((code>>12)&0x3F); buf[2] = 0x80|((code>>6)&0x3F); buf[3] = 0x80|(code&0x3F); return tos(buf, 4);')
		g.writeln('}')
		g.writeln('void array_ensure_cap(Array* a, int cap) {')
		g.writeln('\tif (cap <= a->cap) return;')
		g.writeln('\tint new_cap = a->cap > 0 ? a->cap : 2;')
		g.writeln('\twhile (new_cap < cap) new_cap *= 2;')
		g.writeln('\ta->data = realloc(a->data, new_cap * a->elem_size);')
		g.writeln('\ta->cap = new_cap;')
		g.writeln('}')
		g.writeln('Array arguments(void) {')
		g.writeln('\tchar** argv = (char**)g_main_argv;')
		g.writeln('\tArray a = {0, 0, 0, sizeof(string)};')
		g.writeln('\ta.data = malloc(g_main_argc * sizeof(string));')
		g.writeln('\ta.len = g_main_argc; a.cap = g_main_argc;')
		g.writeln('\tfor (int i = 0; i < g_main_argc; i++) {')
		g.writeln('\t\tint slen = strlen(argv[i]);')
		g.writeln('\t\tchar* s = malloc(slen + 1); memcpy(s, argv[i], slen + 1);')
		g.writeln('\t\t((string*)a.data)[i] = (string){s, slen, 0};')
		g.writeln('\t}')
		g.writeln('\treturn a;')
		g.writeln('}')
		g.writeln('string os__getwd(void) {')
		g.writeln('\tchar buf[4096];')
		g.writeln('\tif (getcwd(buf, sizeof(buf))) {')
		g.writeln('\t\tint len = strlen(buf);')
		g.writeln('\t\tchar* s = malloc(len + 1); memcpy(s, buf, len + 1);')
		g.writeln('\t\treturn (string){s, len, 0};')
		g.writeln('\t}')
		g.writeln('\treturn (string){"", 0, 0};')
		g.writeln('}')
		g.writeln('mach_timebase_info_data_t time__init_time_base(void) {')
		g.writeln('\tmach_timebase_info_data_t tb; mach_timebase_info(&tb); return tb;')
		g.writeln('}')
		g.writeln('Optional os__check_fwrite(size_t n) { return (Optional){.ok = n > 0, .value = (int)n}; }')
		if 'os.File' !in g.tc.structs {
			g.writeln('typedef struct { void* cfile; int fd; bool is_opened; } os__File;')
		}
		if 'os.File.close' !in g.tc.fn_param_types {
			g.writeln('void os__File__close(os__File* f) { if (!f->is_opened) return; f->is_opened = false; fflush((FILE*)f->cfile); fclose((FILE*)f->cfile); f->cfile = 0; }')
		}
		g.writeln('void* memdup_noscan(void* src, int sz) { void* d = malloc(sz); memcpy(d, src, sz); return d; }')
		g.writeln('#include <spawn.h>')
		g.writeln('extern char **environ;')
		g.writeln('static int v_os_execute_capture_start(const char *cmd, int *child_pid, int *read_fd) {')
		g.writeln('\tint pipefd[2]; if (pipe(pipefd) != 0) return -1;')
		g.writeln('\tposix_spawn_file_actions_t fa; posix_spawn_file_actions_init(&fa);')
		g.writeln('\tposix_spawn_file_actions_adddup2(&fa, pipefd[1], 1);')
		g.writeln('\tposix_spawn_file_actions_adddup2(&fa, pipefd[1], 2);')
		g.writeln('\tposix_spawn_file_actions_addclose(&fa, pipefd[0]);')
		g.writeln('\tchar *argv[] = {"/bin/sh", "-c", (char*)cmd, NULL};')
		g.writeln('\tpid_t pid; int ret = posix_spawn(&pid, "/bin/sh", &fa, NULL, argv, environ);')
		g.writeln('\tposix_spawn_file_actions_destroy(&fa); close(pipefd[1]);')
		g.writeln('\tif (ret != 0) { close(pipefd[0]); return -1; }')
		g.writeln('\t*child_pid = pid; *read_fd = pipefd[0]; return 0;')
		g.writeln('}')
		g.writeln('#define vmemcpy memcpy')
		g.writeln('#define vmemset memset')
		g.writeln('')
	} else {
		g.writeln('typedef struct { char* buf; int len; int cap; } strings__Builder;')
		g.writeln('strings__Builder strings__new_builder(int cap) {')
		g.writeln('\tstrings__Builder b; b.cap = cap > 0 ? cap : 64; b.len = 0;')
		g.writeln('\tb.buf = (char*)malloc(b.cap); return b;')
		g.writeln('}')
		g.writeln('void strings__Builder__write_string(strings__Builder* b, string s) {')
		g.writeln('\twhile (b->len + s.len > b->cap) { b->cap *= 2; b->buf = (char*)realloc(b->buf, b->cap); }')
		g.writeln('\tmemcpy(b->buf + b->len, s.str, s.len); b->len += s.len;')
		g.writeln('}')
		g.writeln('void strings__Builder__writeln(strings__Builder* b, string s) {')
		g.writeln('\tstrings__Builder__write_string(b, s);')
		g.writeln('\twhile (b->len + 1 > b->cap) { b->cap *= 2; b->buf = (char*)realloc(b->buf, b->cap); }')
		g.writeln('\tb->buf[b->len++] = 10;')
		g.writeln('}')
		g.writeln('string strings__Builder__str(strings__Builder* b) {')
		g.writeln('\tchar* s = (char*)malloc(b->len + 1); memcpy(s, b->buf, b->len); s[b->len] = 0;')
		g.writeln('\tstring r = {s, b->len, 0}; b->len = 0; return r;')
		g.writeln('}')
		g.writeln('void strings__Builder__write_ptr(strings__Builder* b, void* ptr, int len) {')
		g.writeln('\twhile (b->len + len > b->cap) { b->cap *= 2; b->buf = (char*)realloc(b->buf, b->cap); }')
		g.writeln('\tmemcpy(b->buf + b->len, ptr, len); b->len += len;')
		g.writeln('}')
		g.writeln('void strings__Builder__write_u8(strings__Builder* b, u8 c) {')
		g.writeln('\twhile (b->len + 1 > b->cap) { b->cap *= 2; b->buf = (char*)realloc(b->buf, b->cap); }')
		g.writeln('\tb->buf[b->len++] = c;')
		g.writeln('}')
		g.writeln('')
	}
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

fn (mut g FlatGen) type_alias_decls() {
	mut emitted := false
	for name, target in g.tc.type_aliases {
		if target.starts_with('fn_ptr:') || target.starts_with('C.') {
			continue
		}
		if g.has_builtins {
			continue
		}
		ct := g.tc.c_type(g.tc.parse_type(target))
		if ct == 'void' || ct == name {
			continue
		}
		g.writeln('typedef ${ct} ${c_name(name)};')
		emitted = true
	}
	if emitted {
		g.writeln('')
	}
}

fn (g &FlatGen) skip_builtin_struct(name string) bool {
	return g.has_builtins && name in ['array', 'map', 'DenseArray', 'MapHashFn', 'MapEqFn', 'MapCloneFn', 'MapFreeFn', 'MapSlot', 'ArrayDataHeader']
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
	g.writeln('typedef struct Optional { bool ok; int value; } Optional;')
	g.writeln('')
	mut emitted := map[string]bool{}
	mut remaining := map[string]bool{}
	mut remaining_cnames := map[string]bool{}
	mut iface_remaining := map[string]bool{}
	for name, _ in g.interfaces {
		iface_remaining[name] = true
		remaining_cnames[c_name(name)] = true
	}
	for name, _ in g.tc.structs {
		if g.skip_builtin_struct(name) {
			continue
		}
		remaining[name] = true
		remaining_cnames[c_name(name)] = true
	}
	mut sum_remaining := map[string]bool{}
	for name, _ in g.tc.sum_types {
		sum_remaining[name] = true
		remaining_cnames[c_name(name)] = true
	}
	for _ in 0 .. 30 {
		if remaining.len == 0 && iface_remaining.len == 0 && sum_remaining.len == 0 {
			break
		}
		mut progress := false
		for name, _ in iface_remaining {
			cn := c_name(name)
			mut can_emit := true
			if cn == 'IError' {
				if 'string' !in emitted && 'string' in remaining_cnames {
					can_emit = false
				}
			}
			if can_emit {
				g.writeln('struct ${cn} {')
				g.writeln('\tint _typ;')
				if cn == 'IError' {
					g.writeln('\tstring message;')
					g.writeln('\tint code;')
				}
				g.writeln('};')
				g.writeln('')
				emitted[cn] = true
				iface_remaining.delete(name)
				remaining_cnames.delete(cn)
				progress = true
			}
		}
		for name, _ in remaining {
			cn := c_name(name)
			if cn in emitted {
				remaining.delete(name)
				remaining_cnames.delete(cn)
				progress = true
				continue
			}
			mut can_emit := true
			if name in g.tc.structs {
				for f in g.tc.structs[name] {
					if f.typ is types.Pointer {
						continue
					}
					ct := if f.typ is types.ArrayFixed {
						g.tc.c_type(f.typ.elem_type)
					} else {
						g.tc.c_type(f.typ)
					}
					if ct !in emitted && ct != cn && ct in remaining_cnames {
						can_emit = false
						break
					}
				}
			}
			if can_emit {
				g.emit_struct(name)
				emitted[cn] = true
				remaining.delete(name)
				remaining_cnames.delete(cn)
				progress = true
			}
		}
		for name, _ in sum_remaining {
			cn := c_name(name)
			mut can_emit_sum := true
			if name in g.tc.sum_types {
				for v in g.tc.sum_types[name] {
					if g.variant_references_sum(v, name) {
						continue
					}
					vt := g.tc.parse_type(v)
					if vt is types.SumType {
						if vt.name in sum_remaining {
							can_emit_sum = false
							break
						}
					}
					vct := g.tc.c_type(vt)
					if vct !in emitted && vct in remaining_cnames {
						can_emit_sum = false
						break
					}
				}
			}
			if can_emit_sum {
				g.emit_sum_type(name)
				emitted[cn] = true
				sum_remaining.delete(name)
				remaining_cnames.delete(cn)
				progress = true
			}
		}
		if !progress {
			break
		}
	}
	for name, _ in iface_remaining {
		cn := c_name(name)
		g.writeln('struct ${cn} {')
		g.writeln('\tint _typ;')
		if cn == 'IError' {
			g.writeln('\tstring message;')
			g.writeln('\tint code;')
		}
		g.writeln('};')
		g.writeln('')
	}
	for name, _ in sum_remaining {
		g.emit_sum_type(name)
	}
	for name, _ in remaining {
		g.emit_struct(name)
	}
}

fn (mut g FlatGen) emit_sum_type(name string) {
	variants := g.tc.sum_types[name]
	g.writeln('struct ${c_name(name)} {')
	g.writeln('\tint typ;')
	g.writeln('\tunion {')
	for v in variants {
		ct := g.tc.c_type(g.tc.parse_type(v))
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

fn (mut g FlatGen) emit_struct(name string) {
	if name in g.tc.structs {
		fields := g.tc.structs[name]
		g.writeln('struct ${c_name(name)} {')
		if fields.len == 0 {
			g.writeln('\tint _dummy;')
		}
		for f in fields {
			g.write_struct_field(name, f)
		}
		g.writeln('};')
		g.writeln('')
	}
}

fn (mut g FlatGen) write_struct_field(struct_name string, f types.StructField) {
	if f.typ is types.FnType {
		ret := if r := f.typ.return_type { g.tc.c_type(r) } else { 'void' }
		mut params := []string{}
		for p in f.typ.params {
			params << g.tc.c_type(p)
		}
		params_str := if params.len > 0 { params.join(', ') } else { 'void' }
		g.writeln('\t${ret} (*${c_name(f.name)})(${params_str});')
	} else if f.typ is types.ArrayFixed {
		c_elem := g.tc.c_type(f.typ.elem_type)
		g.writeln('\t${c_elem} ${c_name(f.name)}[${f.typ.len}];')
	} else {
		ct := g.tc.c_type(f.typ)
		g.writeln('\t${ct} ${c_name(f.name)};')
	}
}

fn (g &FlatGen) sum_type_contains_struct(sum_name string, struct_name string) bool {
	if sum_name in g.tc.sum_types {
		for v in g.tc.sum_types[sum_name] {
			if v == struct_name {
				return true
			}
		}
	}
	return false
}

fn (mut g FlatGen) fn_ptr_typedefs() {
	for encoded, name in g.fn_ptr_types {
		parts := encoded['fn_ptr:'.len..].split('|')
		ret := parts[0]
		params := if parts.len > 1 { parts[1] } else { 'void' }
		g.writeln('typedef ${ret} (*${name})(${params});')
	}
	if g.fn_ptr_types.len > 0 {
		g.writeln('')
	}
}

fn (mut g FlatGen) multi_return_typedefs() {
	mut emitted := map[string]bool{}
	for _, ret in g.tc.fn_ret_types {
		if ret is types.MultiReturn {
			name := g.tc.c_type(ret)
			if name in emitted {
				continue
			}
			emitted[name] = true
			g.writeln('typedef struct {')
			for i, t in ret.types {
				g.writeln('\t${g.tc.c_type(t)} arg${i};')
			}
			g.writeln('} ${name};')
		}
	}
	if emitted.len > 0 {
		g.writeln('')
	}
}

fn (mut g FlatGen) resolve_fn_ptr_type(typ string) string {
	if typ in g.fn_ptr_types {
		return g.fn_ptr_types[typ]
	}
	name := '_fn_ptr_${g.fn_ptr_types.len}'
	g.fn_ptr_types[typ] = name
	return name
}

fn (g &FlatGen) variant_references_sum(variant string, sum_name string) bool {
	mut visited := map[string]bool{}
	return g.variant_refs_sum_inner(variant, sum_name, mut visited)
}

fn (g &FlatGen) variant_refs_sum_inner(variant string, sum_name string, mut visited map[string]bool) bool {
	if variant == sum_name || variant.all_after_last('.') == sum_name.all_after_last('.') {
		return true
	}
	if variant in visited {
		return false
	}
	visited[variant] = true
	if variant in g.tc.structs {
		for f in g.tc.structs[variant] {
			clean := types.unwrap_pointer(f.typ)
			if clean is types.Struct && clean.name == sum_name {
				return true
			}
			if clean is types.SumType && clean.name == sum_name {
				return true
			}
			if clean is types.Struct {
				if g.variant_refs_sum_inner(clean.name, sum_name, mut visited) {
					return true
				}
			}
			if clean is types.SumType {
				if clean.name in g.tc.sum_types {
					for sv in g.tc.sum_types[clean.name] {
						if g.variant_refs_sum_inner(sv, sum_name, mut visited) {
							return true
						}
					}
				}
			}
		}
	}
	return false
}

fn (g &FlatGen) resolve_variant(sum_name string, variant string) string {
	if sum_name in g.tc.sum_types {
		for v in g.tc.sum_types[sum_name] {
			if v == variant {
				return variant
			}
		}
		for v in g.tc.sum_types[sum_name] {
			if v.all_after_last('.') == variant {
				return v
			}
		}
	}
	return variant
}

fn (g &FlatGen) sum_field_name(variant string) string {
	if variant.starts_with('[]') {
		return '_Array_${c_name(variant[2..])}'
	}
	if variant.starts_with('map[') {
		return '_Map_${c_name(variant[4..])}'
	}
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
	if sum_name in g.tc.sum_types {
		for i, v in g.tc.sum_types[sum_name] {
			if v == variant {
				return i + 1
			}
		}
		for i, v in g.tc.sum_types[sum_name] {
			if v.all_after_last('.') == variant {
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
		if typ is types.Struct && typ.name.starts_with('C.') {
			continue
		}
		g.writeln('${ct} ${c_name(name)};')
	}
	if g.global_types.len > 0 {
		g.writeln('')
	}
}

fn (g &FlatGen) const_refs_other_const(val_id flat.NodeId) bool {
	if int(val_id) < 0 || int(val_id) >= g.a.nodes.len {
		return false
	}
	node := g.a.nodes[int(val_id)]
	if node.kind == .ident && node.value in g.const_vals {
		return true
	}
	for i in 0 .. node.children_count {
		if g.const_refs_other_const(g.a.child(&node, i)) {
			return true
		}
	}
	return false
}

fn (mut g FlatGen) emit_const(name string, val_id flat.NodeId) {
	if name in g.const_modules {
		g.tc.cur_module = g.const_modules[name]
	}
	val_node := g.a.nodes[int(val_id)]
	if val_node.kind == .empty {
		return
	}
	tmp_sb := g.sb
	g.sb = strings.new_builder(256)
	g.gen_expr(val_id)
	expr_str := g.sb.str()
	g.sb = tmp_sb
	if expr_str.trim_space().len == 0 {
		return
	}
	v_type := g.tc.resolve_type(val_id)
	ct := g.tc.c_type(v_type)
	qname := if name in g.const_modules && g.const_modules[name].len > 0 && g.const_modules[name] != 'main' && g.const_modules[name] != 'builtin' {
		c_name('${g.const_modules[name]}.${name}')
	} else {
		c_name(name)
	}
	if !g.is_const_expr(val_id) {
		if v_type is types.ArrayFixed && val_node.kind == .array_literal {
			c_elem := g.tc.c_type(v_type.elem_type)
			g.writeln('${c_elem} ${qname}[${v_type.len}];')
			for ci in 0 .. val_node.children_count {
				elem_id := g.a.child(&val_node, ci)
				tmp2 := g.sb
				g.sb = strings.new_builder(64)
				g.gen_expr(elem_id)
				estr := g.sb.str()
				g.sb = tmp2
				g.runtime_inits << '\t${qname}[${ci}] = ${estr};'
			}
		} else if g.is_runtime_assignable(val_id) {
			g.writeln('${ct} ${qname};')
			g.runtime_inits << '\t${qname} = ${expr_str};'
		}
		return
	}
	if v_type is types.String {
		g.writeln('string ${qname} = ${expr_str};')
	} else if v_type is types.ArrayFixed {
		c_elem := g.tc.c_type(v_type.elem_type)
		g.writeln('const ${c_elem} ${qname}[] = ${expr_str};')
	} else {
		g.writeln('const ${ct} ${qname} = ${expr_str};')
	}
}

fn (mut g FlatGen) precompute_consts() string {
	old_sb := g.sb
	g.sb = strings.new_builder(1024)
	// Emit constants without dependencies first
	mut deferred := []string{}
	for name, val_id in g.const_vals {
		if int(val_id) < 0 || int(val_id) >= g.a.nodes.len {
			continue
		}
		if g.const_refs_other_const(val_id) {
			deferred << name
		} else {
			g.emit_const(name, val_id)
		}
	}
	// Then emit constants that reference other constants
	for name in deferred {
		g.emit_const(name, g.const_vals[name])
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
		.int_literal, .float_literal, .bool_literal, .char_literal, .enum_val {
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
		.array_literal {
			mut all_const := true
			for ci in 0 .. node.children_count {
				if !g.is_const_expr(g.a.child(&node, ci)) {
					all_const = false
					break
				}
			}
			all_const
		}
		.struct_init {
			mut all_const := true
			for ci in 0 .. node.children_count {
				child := g.a.child_node(&node, ci)
				if child.children_count > 0 && !g.is_const_expr(g.a.child(child, 0)) {
					all_const = false
					break
				}
			}
			all_const
		}
		else {
			false
		}
	}
}

fn (g &FlatGen) is_runtime_assignable(id flat.NodeId) bool {
	if int(id) < 0 || int(id) >= g.a.nodes.len {
		return false
	}
	node := g.a.nodes[int(id)]
	return match node.kind {
		.string_literal, .string_interp {
			true
		}
		.call {
			if node.children_count > 0 {
				callee_id := g.a.child(&node, 0)
				if int(callee_id) >= 0 {
					callee := g.a.nodes[int(callee_id)]
					callee.kind == .ident || callee.kind == .selector
				} else {
					false
				}
			} else {
				false
			}
		}
		.ident {
			true
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
		.dot { '.' }
		.arrow { '->' }
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
