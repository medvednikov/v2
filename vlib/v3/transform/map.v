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
	return t.make_call_typed('new_map', [
		t.make_sizeof_type(key_type),
		t.make_sizeof_type(value_type),
		t.make_int_literal(0),
		t.make_int_literal(0),
		t.make_int_literal(0),
		t.make_int_literal(0),
	], map_type)
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
	call := t.make_call_typed('map__get', [
		t.runtime_addr(map_expr, base_type),
		t.make_prefix(.amp, t.make_ident(key_name)),
		t.make_prefix(.amp, t.make_ident(zero_name)),
	], 'voidptr')
	cast := t.make_cast('&${value_type}', call, '&${value_type}')
	return t.make_prefix(.mul, cast)
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
	call := t.make_call_typed('map__set', [
		t.runtime_addr(map_expr, base_type),
		t.make_prefix(.amp, t.make_ident(key_name)),
		t.make_prefix(.amp, t.make_ident(value_name)),
	], 'void')
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
		call := t.make_call_typed('map__set', [
			t.make_prefix(.amp, t.make_ident(tmp_name)),
			t.make_prefix(.amp, t.make_ident(key_name)),
			t.make_prefix(.amp, t.make_ident(value_name)),
		], 'void')
		t.pending_stmts << t.make_expr_stmt(call)
	}
	return t.make_ident(tmp_name)
}
