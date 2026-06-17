module transform

import v3.flat

// transform_return_with_sumtype_wrap checks if a return statement returns a
// variant value where the function's return type is a sum type. In that case,
// the variant value may need to be wrapped in the sum type's tagged union.
//
// For now, passes through unchanged since the C gen handles wrapping currently.
// This is a hook for future sum type return wrapping at the transform level.
fn (mut t Transformer) transform_return_with_sumtype_wrap(id flat.NodeId, node flat.Node) []flat.NodeId {
	if node.children_count == 0 {
		return [id]
	}
	// Check if current function returns a sum type
	if t.cur_fn_ret_type.len == 0 || t.cur_fn_ret_type !in t.sum_types {
		return [id]
	}
	// Check if the return value is a struct init whose type is a variant
	child_id := t.a.child(&node, 0)
	child := t.a.nodes[int(child_id)]
	if child.kind == .struct_init && child.value.len > 0 {
		variants := t.sum_types[t.cur_fn_ret_type]
		for v in variants {
			if v == child.value {
				// This is a variant being returned as a sum type.
				// For now, pass through - C gen handles the wrapping.
				// TODO: Generate explicit sum type wrapping here.
				return [id]
			}
		}
	}
	return [id]
}

// try_expand_return_if detects a `return if cond { a } else { b }` pattern
// and expands it into `if cond { return a } else { return b }`.
// This simplification makes the C backend's job easier since it avoids
// needing statement-expressions for the if-as-value in the return position.
//
// Returns the expanded if_expr as a single-element array, or none if the
// pattern does not match.
fn (mut t Transformer) try_expand_return_if(id flat.NodeId, node flat.Node) ?[]flat.NodeId {
	if node.children_count == 0 {
		return none
	}
	// The return value must be an if_expr with both then and else branches
	val_id := t.a.child(&node, 0)
	val_node := t.a.nodes[int(val_id)]
	if val_node.kind != .if_expr || val_node.children_count < 3 {
		return none
	}
	// Extract condition, then-block, and else-block from the if_expr
	cond_id := t.a.child(&val_node, 0)
	then_id := t.a.child(&val_node, 1)
	else_id := t.a.child(&val_node, 2)
	then_node := t.a.nodes[int(then_id)]
	else_node := t.a.nodes[int(else_id)]
	// Extract the last expression from each branch block as the return value
	then_val := if then_node.kind == .block && then_node.children_count > 0 {
		t.a.child(&then_node, then_node.children_count - 1)
	} else {
		then_id
	}
	else_val := if else_node.kind == .block && else_node.children_count > 0 {
		t.a.child(&else_node, else_node.children_count - 1)
	} else {
		else_id
	}
	// Build: return <then_val>
	then_ret_start := t.a.children.len
	t.a.children << then_val
	then_ret := t.a.add_node(flat.Node{
		kind:           .return_stmt
		children_start: then_ret_start
		children_count: 1
		typ:            node.typ
	})
	// Build: return <else_val>
	else_ret_start := t.a.children.len
	t.a.children << else_val
	else_ret := t.a.add_node(flat.Node{
		kind:           .return_stmt
		children_start: else_ret_start
		children_count: 1
		typ:            node.typ
	})
	// Build then-block and else-block containing the return statements
	then_block := t.make_block([then_ret])
	else_block := t.make_block([else_ret])
	// Build: if cond { return a } else { return b }
	expanded_if := t.make_if(cond_id, then_block, else_block)
	return [expanded_if]
}

// try_expand_return_match detects a `return match x { ... }` pattern where
// the return value is a match expression. By the time this runs, match
// expressions should already be lowered to if_expr chains by lower_match_stmts,
// so this would see an if_expr chain rather than a match_stmt.
//
// For now, returns none. This will be implemented after confirming that
// match lowering always runs before the return expansion pass.
fn (mut t Transformer) try_expand_return_match(id flat.NodeId, node flat.Node) ?[]flat.NodeId {
	if node.children_count == 0 {
		return none
	}
	// After match lowering, the return value would be an if_expr chain.
	// We could walk the chain and wrap each leaf in a return statement,
	// similar to try_expand_return_if but recursively through the chain.
	// For now, return none until the ordering guarantee is confirmed.
	return none
}
