module transform

import v3.flat

fn (mut t Transformer) map_type_parts(map_type string) (string, string) {
	clean := t.clean_map_type(map_type)
	if !clean.starts_with('map[') {
		return '', ''
	}
	return t.map_key_type(clean), t.map_value_type(clean)
}

fn (mut t Transformer) make_new_map_call(map_type string) flat.NodeId {
	key_type, value_type := t.map_type_parts(map_type)
	mut args := []flat.NodeId{}
	args << t.make_sizeof_type(key_type)
	args << t.make_sizeof_type(value_type)
	args << t.make_int_literal(0)
	args << t.make_int_literal(0)
	args << t.make_int_literal(0)
	args << t.make_int_literal(0)
	return t.make_call_typed('new_map', args, map_type)
}

fn (mut t Transformer) try_lower_map_index_expr(_id flat.NodeId, node flat.Node) ?flat.NodeId {
	if node.kind != .index || node.children_count < 2 || node.value == 'range' {
		return none
	}
	base_id := t.a.child(&node, 0)
	key_id := t.a.child(&node, 1)
	base_type := t.node_type(base_id)
	map_type := t.clean_map_type(base_type)
	if !map_type.starts_with('map[') {
		return none
	}
	key_type, value_type := t.map_type_parts(map_type)
	if key_type.len == 0 || value_type.len == 0 {
		return none
	}
	map_expr := t.stable_expr_for_reuse(base_id)
	key_name := t.new_temp('map_key')
	zero_name := t.new_temp('map_zero')
	t.pending_stmts << t.make_decl_assign_typed(key_name, t.transform_expr(key_id), key_type)
	t.pending_stmts << t.make_decl_assign_typed(zero_name, t.zero_value_for_type(value_type),
		value_type)
	call := t.make_call_typed('map__get', arr3(t.runtime_addr(map_expr, base_type), t.make_prefix(.amp,
		t.make_ident(key_name)), t.make_prefix(.amp, t.make_ident(zero_name))), 'voidptr')
	cast := t.make_cast('&${value_type}', call, '&${value_type}')
	return t.make_prefix(.mul, cast)
}

fn (mut t Transformer) is_map_index_or_expr(node flat.Node) bool {
	if node.kind != .or_expr || node.children_count < 2 {
		return false
	}
	expr := t.a.child_node(&node, 0)
	if expr.kind != .index || expr.children_count < 2 || expr.value == 'range' {
		return false
	}
	base_id := t.a.child(expr, 0)
	base_type := t.node_type(base_id)
	return t.clean_map_type(base_type).starts_with('map[')
}

fn (mut t Transformer) transform_map_index_or_expr(id flat.NodeId, node flat.Node) flat.NodeId {
	if node.children_count < 2 {
		return id
	}
	expr_id := t.a.child(&node, 0)
	body_id := t.a.child(&node, 1)
	expr := t.a.nodes[int(expr_id)]
	if expr.kind != .index || expr.children_count < 2 {
		return id
	}
	base := t.transform_expr(t.a.child(&expr, 0))
	key := t.transform_expr(t.a.child(&expr, 1))
	index_start := t.a.children.len
	t.a.children << base
	t.a.children << key
	new_index := t.a.add_node(flat.Node{
		kind:           .index
		op:             expr.op
		children_start: index_start
		children_count: 2
		pos:            expr.pos
		value:          expr.value
		typ:            expr.typ
	})
	body := t.a.nodes[int(body_id)]
	new_body := if body.kind == .block {
		t.make_block(t.transform_stmts(t.a.children_of(&body)))
	} else {
		t.transform_expr(body_id)
	}
	start := t.a.children.len
	t.a.add_child(new_index)
	t.a.add_child(new_body)
	return t.a.add_node(flat.Node{
		kind:           .or_expr
		op:             node.op
		children_start: start
		children_count: 2
		pos:            node.pos
		value:          node.value
		typ:            node.typ
	})
}

fn (mut t Transformer) try_lower_map_index_assign(node flat.Node) ?[]flat.NodeId {
	if node.kind != .index_assign || node.children_count < 2 || node.op != .assign {
		return none
	}
	lhs_id := t.a.child(&node, 0)
	lhs := t.a.nodes[int(lhs_id)]
	if lhs.kind != .index || lhs.children_count < 2 {
		return none
	}
	base_id := t.a.child(&lhs, 0)
	key_id := t.a.child(&lhs, 1)
	base_type := t.node_type(base_id)
	map_type := t.clean_map_type(base_type)
	if !map_type.starts_with('map[') {
		return none
	}
	key_type, value_type := t.map_type_parts(map_type)
	if key_type.len == 0 || value_type.len == 0 {
		return none
	}
	map_expr := t.stable_expr_for_reuse(base_id)
	key_name := t.new_temp('map_key')
	value_name := t.new_temp('map_val')
	mut result := []flat.NodeId{}
	t.drain_pending(mut result)
	result << t.make_decl_assign_typed(key_name, t.transform_expr(key_id), key_type)
	rhs_id := t.a.child(&node, 1)
	result << t.make_decl_assign_typed(value_name, t.transform_expr(rhs_id), value_type)
	call := t.make_call_typed('map__set', arr3(t.runtime_addr(map_expr, base_type), t.make_prefix(.amp,
		t.make_ident(key_name)), t.make_prefix(.amp, t.make_ident(value_name))), 'void')
	result << t.make_expr_stmt(call)
	return result
}

fn (mut t Transformer) lower_map_init_to_runtime(id flat.NodeId, node flat.Node) flat.NodeId {
	map_type := if node.value.len > 0 { node.value } else { node.typ }
	if !map_type.starts_with('map[') {
		return id
	}
	init_call := t.make_new_map_call(map_type)
	if node.children_count == 0 {
		return init_call
	}
	tmp_name := t.new_temp('map_lit')
	t.pending_stmts << t.make_decl_assign_typed(tmp_name, init_call, map_type)
	key_type, value_type := t.map_type_parts(map_type)
	for i := 0; i + 1 < node.children_count; i += 2 {
		key_name := t.new_temp('map_key')
		value_name := t.new_temp('map_val')
		t.pending_stmts << t.make_decl_assign_typed(key_name,
			t.transform_expr(t.a.child(&node, i)), key_type)
		t.pending_stmts << t.make_decl_assign_typed(value_name, t.transform_expr(t.a.child(&node,

			i + 1)), value_type)
		call := t.make_call_typed('map__set', arr3(t.make_prefix(.amp, t.make_ident(tmp_name)), t.make_prefix(.amp,
			t.make_ident(key_name)), t.make_prefix(.amp, t.make_ident(value_name))), 'void')
		t.pending_stmts << t.make_expr_stmt(call)
	}
	return t.make_ident(tmp_name)
}
