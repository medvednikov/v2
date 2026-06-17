module transform

import v3.flat

fn (mut t Transformer) transform_for_body(id flat.NodeId, node flat.Node) []flat.NodeId {
	if node.children_count < 3 {
		return [id]
	}
	// child 0: init statement
	init_id := t.a.child(&node, 0)
	mut new_init := init_id
	if int(init_id) >= 0 {
		expanded := t.transform_stmt(init_id)
		if expanded.len > 0 {
			new_init = expanded[0]
		}
	}
	// child 1: condition expression
	cond_id := t.a.child(&node, 1)
	new_cond := t.transform_expr(cond_id)
	// child 2: post statement
	post_id := t.a.child(&node, 2)
	mut new_post := post_id
	if int(post_id) >= 0 {
		expanded := t.transform_stmt(post_id)
		if expanded.len > 0 {
			new_post = expanded[0]
		}
	}
	// children 3..n: body statements
	mut body_ids := []flat.NodeId{}
	for i in 3 .. node.children_count {
		body_ids << t.a.child(&node, i)
	}
	new_body := t.transform_stmts(body_ids)
	// Rebuild the for_stmt with transformed children
	start := t.a.children.len
	t.a.children << new_init
	t.a.children << new_cond
	t.a.children << new_post
	for bid in new_body {
		t.a.children << bid
	}
	count := t.a.children.len - start
	new_id := t.a.add_node(flat.Node{
		kind:           .for_stmt
		op:             node.op
		children_start: start
		children_count: count
		pos:            node.pos
		value:          node.value
		typ:            node.typ
	})
	return [new_id]
}

fn (mut t Transformer) transform_for_in_body(id flat.NodeId, node flat.Node) []flat.NodeId {
	header_count := node.value.int()
	if header_count < 3 || node.children_count < 3 {
		return [id]
	}
	key_id := t.a.child(&node, 0) // loop var ident — pass through (do not transform a binding)
	val_id := t.a.child(&node, 1) // may be flat.empty_node (-1)
	container_id := t.a.child(&node, 2)
	new_container := t.transform_expr(container_id)

	// register loop-variable types (best effort) — read var NAMES from child0/child1 idents
	iter_type := t.detect_for_in_type(node)
	has_index := int(val_id) >= 0
	container_is_range := if int(container_id) >= 0 {
		t.a.nodes[int(container_id)].kind == .range
	} else {
		false
	}
	if header_count == 4 || container_is_range {
		// range `for i in 0 .. n`: single loop var (child0) is an int
		if int(key_id) >= 0 {
			key_name := t.a.nodes[int(key_id)].value
			if key_name.len > 0 {
				t.var_types[key_name] = 'int'
			}
		}
	} else if has_index {
		// two loop vars: child0 = key/index, child1 = value/element
		key_name := if int(key_id) >= 0 { t.a.nodes[int(key_id)].value } else { '' }
		val_name := if int(val_id) >= 0 { t.a.nodes[int(val_id)].value } else { '' }
		if iter_type.starts_with('map[') {
			// map[K]V: child0 (key) -> key type, child1 (val) -> value type
			bracket_end := iter_type.index(']') or { 0 }
			if key_name.len > 0 && bracket_end > 4 {
				t.var_types[key_name] = iter_type[4..bracket_end]
			}
		} else {
			// []E: child0 (index) -> 'int'
			if key_name.len > 0 {
				t.var_types[key_name] = 'int'
			}
		}
		if val_name.len > 0 {
			elem_type := t.infer_for_in_elem_type(iter_type, node)
			if elem_type.len > 0 {
				t.var_types[val_name] = elem_type
			}
		}
	} else {
		// single var, child0 is the element
		if int(key_id) >= 0 {
			key_name := t.a.nodes[int(key_id)].value
			if key_name.len > 0 {
				elem_type := t.infer_for_in_elem_type(iter_type, node)
				if elem_type.len > 0 {
					t.var_types[key_name] = elem_type
				}
			}
		}
	}

	mut ids := []flat.NodeId{}
	ids << key_id
	ids << val_id
	ids << new_container
	if header_count == 4 {
		range_end_id := t.a.child(&node, 3)
		ids << t.transform_expr(range_end_id)
	}
	body_ids := t.a.children_of(&node)[header_count..].clone()
	new_body := t.transform_stmts(body_ids)
	for bid in new_body {
		ids << bid
	}
	start := t.a.children.len
	for cid in ids {
		t.a.children << cid
	}
	return [t.a.add_node(flat.Node{
		kind:           .for_in_stmt
		op:             node.op
		children_start: start
		children_count: ids.len
		pos:            node.pos
		value:          node.value // MUST preserve "3"/"4" header count
		typ:            node.typ
	})]
}

fn (mut t Transformer) detect_for_in_type(node flat.Node) string {
	// Check if the parser already set a type on the for_in_stmt node
	if node.typ.len > 0 {
		return node.typ
	}
	// Try to resolve the type from the iterable expression (child 0)
	if node.children_count > 0 {
		iter_id := t.a.child(&node, 0)
		return t.resolve_expr_type(iter_id)
	}
	return ''
}

// Infer the element type for the loop variable from the iterable type.
fn (t &Transformer) infer_for_in_elem_type(iter_type string, node flat.Node) string {
	if iter_type.starts_with('[]') {
		return iter_type[2..]
	}
	if iter_type.starts_with('map[') {
		// map[K]V -> value type is everything after the closing ']'
		bracket_end := iter_type.index(']') or { return '' }
		if bracket_end + 1 < iter_type.len {
			return iter_type[bracket_end + 1..]
		}
		return ''
	}
	if iter_type == 'string' {
		return 'u8'
	}
	// Check if the iterable is a range expression
	if node.children_count > 0 {
		iter_id := t.a.child(&node, 0)
		iter_node := t.a.nodes[int(iter_id)]
		if iter_node.kind == .range {
			return 'int'
		}
	}
	return ''
}
