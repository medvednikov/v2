module transform

import v3.flat

fn (mut t Transformer) transform_infix_string_ops(id flat.NodeId, node flat.Node) ?flat.NodeId {
	if node.children_count < 2 {
		return none
	}
	lhs_id := t.a.child(&node, 0)
	rhs_id := t.a.child(&node, 1)
	lhs := t.a.nodes[int(lhs_id)]
	rhs := t.a.nodes[int(rhs_id)]

	is_string := lhs.kind == .string_literal || rhs.kind == .string_literal
		|| lhs.kind == .string_interp || rhs.kind == .string_interp
		|| t.resolve_expr_type(lhs_id) == 'string' || t.resolve_expr_type(rhs_id) == 'string'

	if !is_string {
		return none
	}

	new_lhs := t.transform_expr(lhs_id)
	new_rhs := t.transform_expr(rhs_id)

	match node.op {
		.plus {
			return t.make_call('string__plus', [new_lhs, new_rhs])
		}
		.eq {
			return t.make_call('string__eq', [new_lhs, new_rhs])
		}
		.ne {
			eq_call := t.make_call('string__eq', [new_lhs, new_rhs])
			start := t.a.children.len
			t.a.children << eq_call
			return t.a.add_node(flat.Node{
				kind:           .prefix
				op:             .not
				children_start: start
				children_count: 1
			})
		}
		.lt {
			return t.make_call('string__lt', [new_lhs, new_rhs])
		}
		.gt {
			// a > b  ->  string__lt(b, a)
			return t.make_call('string__lt', [new_rhs, new_lhs])
		}
		else {
			return none
		}
	}
}

fn (mut t Transformer) transform_in_expr(id flat.NodeId, node flat.Node) flat.NodeId {
	if node.children_count < 2 {
		return id
	}
	lhs_id := t.a.child(&node, 0)
	rhs_id := t.a.child(&node, 1)
	rhs := t.a.nodes[int(rhs_id)]

	is_not_in := node.value == '!in'

	new_lhs := t.transform_expr(lhs_id)

	result := if rhs.kind == .range {
		// x in low..high  ->  x >= low && x < high
		if rhs.children_count >= 2 {
			low_id := t.a.child(&rhs, 0)
			high_id := t.a.child(&rhs, 1)
			new_low := t.transform_expr(low_id)
			new_high := t.transform_expr(high_id)

			// Need a second copy of lhs for the right side of &&
			lhs_copy := t.transform_expr(lhs_id)

			ge_cmp := t.make_infix(.ge, new_lhs, new_low)
			lt_cmp := t.make_infix(.lt, lhs_copy, new_high)
			t.make_infix(.logical_and, ge_cmp, lt_cmp)
		} else {
			id
		}
	} else if rhs.kind == .array_literal {
		// x in [a, b, c]  ->  x == a || x == b || x == c
		if rhs.children_count == 0 {
			t.make_bool_literal(false)
		} else {
			mut or_chain := flat.empty_node
			for i in 0 .. rhs.children_count {
				elem_id := t.a.child(&rhs, i)
				new_elem := t.transform_expr(elem_id)
				lhs_copy := t.transform_expr(lhs_id)
				eq_cmp := t.make_infix(.eq, lhs_copy, new_elem)
				if int(or_chain) < 0 {
					or_chain = eq_cmp
				} else {
					or_chain = t.make_infix(.logical_or, or_chain, eq_cmp)
				}
			}
			or_chain
		}
	} else {
		// array/map containment - return unchanged for now
		id
	}

	if is_not_in && result != id {
		start := t.a.children.len
		t.a.children << result
		return t.a.add_node(flat.Node{
			kind:           .prefix
			op:             .not
			children_start: start
			children_count: 1
		})
	}
	return result
}

fn (mut t Transformer) transform_enum_shorthand(id flat.NodeId, node flat.Node, expected_enum string) flat.NodeId {
	if expected_enum.len == 0 {
		return id
	}
	short_name := node.value.trim_left('.')
	if fields := t.enum_types[expected_enum] {
		for f in fields {
			if f == short_name {
				return t.a.add_val(.enum_val, '${expected_enum}.${short_name}')
			}
		}
	}
	return id
}

pub fn (mut t Transformer) make_call(fn_name string, args []flat.NodeId) flat.NodeId {
	fn_ident := t.make_ident(fn_name)
	start := t.a.children.len
	t.a.children << fn_ident
	for arg in args {
		t.a.children << arg
	}
	return t.a.add_node(flat.Node{
		kind:           .call
		children_start: start
		children_count: 1 + args.len
	})
}

pub fn (mut t Transformer) make_method_call(receiver flat.NodeId, method_name string, args []flat.NodeId) flat.NodeId {
	// Build selector: receiver.method_name
	sel_start := t.a.children.len
	t.a.children << receiver
	selector := t.a.add_node(flat.Node{
		kind:           .selector
		value:          method_name
		children_start: sel_start
		children_count: 1
	})

	start := t.a.children.len
	t.a.children << selector
	for arg in args {
		t.a.children << arg
	}
	return t.a.add_node(flat.Node{
		kind:           .call
		children_start: start
		children_count: 1 + args.len
	})
}

pub fn (mut t Transformer) make_string_literal(value string) flat.NodeId {
	return t.a.add_val(.string_literal, value)
}

pub fn (mut t Transformer) make_int_literal(value int) flat.NodeId {
	return t.a.add_val(.int_literal, value.str())
}

pub fn (mut t Transformer) make_bool_literal(value bool) flat.NodeId {
	return t.a.add_val(.bool_literal, if value { 'true' } else { 'false' })
}
