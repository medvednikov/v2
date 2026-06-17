module c

import v3.flat
import v3.types

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
