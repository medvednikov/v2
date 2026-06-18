module transform

import v3.flat

fn (mut t Transformer) make_array_new_call(elem_type string, len_expr flat.NodeId, cap_expr flat.NodeId) flat.NodeId {
	return t.make_call_typed('array_new', arr3(t.make_sizeof_type(elem_type), len_expr, cap_expr),
		'[]${elem_type}')
}

fn (mut t Transformer) lower_array_init_to_runtime(id flat.NodeId, node flat.Node) flat.NodeId {
	if node.value.len == 0 || is_fixed_array_type(node.value) {
		return id
	}
	elem_type := node.value
	mut len_expr := t.make_int_literal(0)
	mut cap_expr := t.make_int_literal(0)
	mut init_expr := flat.empty_node
	for i in 0 .. node.children_count {
		child := t.a.child_node(&node, i)
		if child.kind == .field_init && child.children_count > 0 {
			val := t.transform_expr(t.a.child(child, 0))
			if child.value == 'len' {
				len_expr = val
			} else if child.value == 'cap' {
				cap_expr = val
			} else if child.value == 'init' {
				init_expr = val
			}
		}
	}
	new_call := t.make_array_new_call(elem_type, len_expr, cap_expr)
	if int(init_expr) < 0 {
		return new_call
	}
	tmp_name := t.new_temp('arr_init')
	idx_name := t.new_temp('arr_idx')
	t.pending_stmts << t.make_decl_assign_typed(tmp_name, new_call, '[]${elem_type}')
	init_idx := t.make_decl_assign_typed(idx_name, t.make_int_literal(0), 'int')
	cond := t.make_infix(.lt, t.make_ident(idx_name), t.make_selector(t.make_ident(tmp_name),
		'len', 'int'))
	post := t.make_expr_stmt(t.make_postfix(t.make_ident(idx_name), .inc))
	elem_lhs := t.make_index(t.make_ident(tmp_name), t.make_ident(idx_name), elem_type)
	assign := t.make_assign(elem_lhs, init_expr)
	t.pending_stmts << t.make_for_stmt(init_idx, cond, post, arr1(assign), node)
	return t.make_ident(tmp_name)
}

fn (mut t Transformer) lower_array_literal_to_runtime(id flat.NodeId, node flat.Node) flat.NodeId {
	array_type := t.node_type(id)
	if !array_type.starts_with('[]') {
		return id
	}
	elem_type := array_type[2..]
	tmp_name := t.new_temp('arr_lit')
	t.pending_stmts << t.make_decl_assign_typed(tmp_name, t.make_array_new_call(elem_type,
		t.make_int_literal(0), t.make_int_literal(node.children_count)), array_type)
	for i in 0 .. node.children_count {
		value_name := t.new_temp('arr_val')
		t.pending_stmts << t.make_decl_assign_typed(value_name,
			t.transform_expr(t.a.child(&node, i)), elem_type)
		call := t.make_call_typed('array_push', arr2(t.make_prefix(.amp, t.make_ident(tmp_name)), t.make_prefix(.amp,
			t.make_ident(value_name))), 'void')
		t.pending_stmts << t.make_expr_stmt(call)
	}
	return t.make_ident(tmp_name)
}
