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
	if node.children_count < 1 {
		return [id]
	}
	// Determine the iterable type
	iter_type := t.detect_for_in_type(node)
	// Parse variable names from node.value and register their types
	val_field := node.value
	if val_field.len > 0 {
		if val_field.contains(',') {
			// "idx,val" form: two variables
			parts := val_field.split(',')
			idx_name := parts[0]
			val_name := parts[1]
			if idx_name.len > 0 {
				if iter_type.starts_with('map[') {
					// For maps, the index variable gets the key type
					bracket_end := iter_type.index(']') or { 0 }
					if bracket_end > 4 {
						key_type := iter_type[4..bracket_end]
						t.var_types[idx_name] = key_type
					}
				} else {
					t.var_types[idx_name] = 'int'
				}
			}
			if val_name.len > 0 {
				elem_type := t.infer_for_in_elem_type(iter_type, node)
				if elem_type.len > 0 {
					t.var_types[val_name] = elem_type
				}
			}
		} else {
			// "val" form: single variable
			if val_field.len > 0 {
				elem_type := t.infer_for_in_elem_type(iter_type, node)
				if elem_type.len > 0 {
					t.var_types[val_field] = elem_type
				}
			}
		}
	}
	// child 0: iterable expression
	iter_id := t.a.child(&node, 0)
	new_iter := t.transform_expr(iter_id)
	// children 1..n: body statements
	mut body_ids := []flat.NodeId{}
	for i in 1 .. node.children_count {
		body_ids << t.a.child(&node, i)
	}
	new_body := t.transform_stmts(body_ids)
	// Rebuild the for_in_stmt with transformed children
	start := t.a.children.len
	t.a.children << new_iter
	for bid in new_body {
		t.a.children << bid
	}
	count := t.a.children.len - start
	new_id := t.a.add_node(flat.Node{
		kind:           .for_in_stmt
		op:             node.op
		children_start: start
		children_count: count
		pos:            node.pos
		value:          node.value
		typ:            node.typ
	})
	return [new_id]
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
