module transform

import v3.flat

// resolve_call_name resolves the function name from a .call node.
// child[0] is the function expression: .ident for plain calls, .selector for method calls.
fn (mut t Transformer) resolve_call_name(node flat.Node) string {
	if node.children_count == 0 {
		return ''
	}
	fn_id := t.a.child(&node, 0)
	if int(fn_id) < 0 {
		return ''
	}
	fn_node := t.a.nodes[int(fn_id)]
	match fn_node.kind {
		.ident {
			name := fn_node.value
			// Try unqualified name first
			if name in t.fn_ret_types {
				return name
			}
			// Try qualified with current module
			if t.cur_module.len > 0 && t.cur_module != 'main' && t.cur_module != 'builtin' {
				qname := '${t.cur_module}.${name}'
				if qname in t.fn_ret_types {
					return qname
				}
			}
			return name
		}
		.selector {
			if fn_node.children_count > 0 {
				base_id := t.a.child(&fn_node, 0)
				base := t.a.nodes[int(base_id)]
				if base.kind == .ident {
					return '${base.value}.${fn_node.value}'
				}
			}
			return ''
		}
		else {
			return ''
		}
	}
}

// resolve_method_receiver_type determines the receiver type for method calls.
// For a call where child[0] is a .selector, resolves the type of the selector's base expression.
fn (mut t Transformer) resolve_method_receiver_type(call_node flat.Node) string {
	if call_node.children_count == 0 {
		return ''
	}
	fn_id := t.a.child(&call_node, 0)
	if int(fn_id) < 0 {
		return ''
	}
	fn_node := t.a.nodes[int(fn_id)]
	if fn_node.kind != .selector || fn_node.children_count == 0 {
		return ''
	}
	base_id := t.a.child(&fn_node, 0)
	return t.resolve_expr_type(base_id)
}

// transform_call_args transforms all children of a call expression.
// child[0] is the function expression, children[1..n] are arguments.
fn (mut t Transformer) transform_call_args(node flat.Node) flat.NodeId {
	if node.children_count == 0 {
		return t.a.add_node(flat.Node{
			kind:  .call
			op:    node.op
			pos:   node.pos
			value: node.value
			typ:   node.typ
		})
	}
	start := t.a.children.len
	for i in 0 .. node.children_count {
		child_id := t.a.child(&node, i)
		t.a.children << t.transform_expr(child_id)
	}
	return t.a.add_node(flat.Node{
		kind:           .call
		op:             node.op
		children_start: start
		children_count: node.children_count
		pos:            node.pos
		value:          node.value
		typ:            node.typ
	})
}

// try_lower_builtin_call checks if a call is to a builtin that needs special lowering.
// Returns none for most calls so the caller falls through to generic call transform.
fn (mut t Transformer) try_lower_builtin_call(id flat.NodeId, node flat.Node) ?flat.NodeId {
	name := t.resolve_call_name(node)
	if name.len == 0 {
		return none
	}
	match name {
		'println', 'eprintln', 'print' {
			// Pass through - no transform needed yet
			return none
		}
		'sizeof' {
			return none
		}
		'typeof' {
			return none
		}
		else {
			return none
		}
	}
}

// is_method_call checks if a .call node is a method call (child[0] is .selector).
// Returns true for `obj.method(args)` patterns.
fn (mut t Transformer) is_method_call(node flat.Node) bool {
	if node.children_count == 0 {
		return false
	}
	fn_id := t.a.child(&node, 0)
	if int(fn_id) < 0 {
		return false
	}
	fn_node := t.a.nodes[int(fn_id)]
	return fn_node.kind == .selector
}

// get_call_return_type looks up the return type for a resolved call.
// Handles both simple and qualified names.
fn (mut t Transformer) get_call_return_type(node flat.Node) string {
	name := t.resolve_call_name(node)
	if name.len == 0 {
		return ''
	}
	// Try exact name first
	if ret := t.fn_ret_types[name] {
		return ret
	}
	// Try qualified with current module
	if t.cur_module.len > 0 && t.cur_module != 'main' && t.cur_module != 'builtin' {
		qname := '${t.cur_module}.${name}'
		if ret := t.fn_ret_types[qname] {
			return ret
		}
	}
	return ''
}
