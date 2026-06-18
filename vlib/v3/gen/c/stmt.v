module c

import v3.flat
import v3.types

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
					push_rhs_id := g.a.child(&child, 1)
					push_rhs_type := g.tc.resolve_type(push_rhs_id)
					push_rhs_clean := types.unwrap_pointer(push_rhs_type)
					if push_rhs_clean is types.Array {
						g.write('array_push_many(&')
						g.gen_expr(lhs_id)
						g.write(', ')
						g.gen_expr(push_rhs_id)
						g.writeln(');')
					} else {
						c_elem := g.tc.c_type(g.tc.parse_type(child.typ))
						g.write('array_push(&')
						g.gen_expr(lhs_id)
						g.write(', &(${c_elem}[]){')
						g.gen_expr(push_rhs_id)
						g.writeln('});')
					}
				} else {
					lhs_type := g.tc.resolve_type(lhs_id)
					clean := types.unwrap_pointer(lhs_type)
					if clean is types.Array {
						rhs_id := g.a.child(&child, 1)
						rhs_type := g.tc.resolve_type(rhs_id)
						rhs_clean := types.unwrap_pointer(rhs_type)
						if rhs_clean is types.Array {
							g.write('array_push_many(&')
							g.gen_expr(lhs_id)
							g.write(', ')
							g.gen_expr(rhs_id)
							g.writeln(');')
						} else {
							c_elem := g.tc.c_type(clean.elem_type)
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
				} else if ret_node.kind == .assoc {
					g.gen_return_assoc(ret_node)
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
	if node.children_count >= 3 {
		rhs_type := g.tc.resolve_type(g.a.child(&node, 1))
		if rhs_type is types.MultiReturn {
			g.gen_multi_return_decl(node)
			return
		}
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
	rhs_id := g.a.child(&node, 1)
	rhs_type := g.tc.resolve_type(rhs_id)
	ct := g.tc.c_type(rhs_type)
	tmp := g.tmp_name()
	g.write('${ct} ${tmp} = ')
	g.gen_expr(rhs_id)
	g.writeln(';')
	num_lhs := node.children_count - 1
	for j in 0 .. num_lhs {
		lhs_idx := if j == 0 { 0 } else { j + 1 }
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
				// Array appends are annotated by the transformer; an un-annotated
				// `<<=` here is the integer bit-shift-assign operator.
				g.gen_expr(g.a.child(&node, i))
				g.write(' <<= ')
				g.gen_expr(g.a.child(&node, i + 1))
				g.writeln(';')
			}
		} else {
			rhs_id := g.a.child(&node, i + 1)
			rhs_node := g.a.nodes[int(rhs_id)]
			if rhs_node.kind == .or_expr {
				g.gen_assign_or_expr(node, i, rhs_node)
				i += 2
				continue
			}
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

fn (mut g FlatGen) gen_assign_or_expr(node flat.Node, lhs_idx int, or_node flat.Node) {
	expr_id := g.a.child(&or_node, 0)
	or_body_id := g.a.child(&or_node, 1)
	or_body := g.a.nodes[int(or_body_id)]
	tmp := g.tmp_name()
	expr_type := g.tc.resolve_type(expr_id)
	opt_ct := g.optional_type_name(expr_type)
	g.write('${opt_ct} ${tmp} = ')
	g.gen_expr(expr_id)
	g.writeln(';')
	g.writeln('if (${tmp}.ok) {')
	g.indent++
	g.gen_expr(g.a.child(&node, lhs_idx))
	g.writeln(' = ${tmp}.value;')
	g.indent--
	g.writeln('} else {')
	g.tc.push_scope()
	g.tc.cur_scope.insert('err', types.Type(types.Struct{
		name: 'IError'
	}))
	g.indent++
	g.writeln('IError err = (IError){0};')
	for j in 0 .. or_body.children_count {
		child_id := g.a.child(&or_body, j)
		g.gen_node(child_id)
	}
	g.indent--
	g.tc.pop_scope()
	g.writeln('}')
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
