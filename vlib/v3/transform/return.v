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
		return arr1(id)
	}
	// Check if current function returns a sum type
	if t.cur_fn_ret_type.len == 0 || t.cur_fn_ret_type !in t.sum_types {
		return arr1(id)
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
				return arr1(id)
			}
		}
	}
	return arr1(id)
}

// branch_tail_expr extracts the tail EXPRESSION id from a branch block,
// unwrapping a trailing `.expr_stmt` so we get the expression inside it
// rather than the statement wrapper.
fn (t &Transformer) branch_tail_expr(block_id flat.NodeId) flat.NodeId {
	if int(block_id) < 0 {
		return block_id
	}
	block := t.a.nodes[int(block_id)]
	if block.kind != .block || block.children_count == 0 {
		return block_id
	}
	last_id := t.a.child(&block, block.children_count - 1)
	last := t.a.nodes[int(last_id)]
	if last.kind == .expr_stmt && last.children_count > 0 {
		return t.a.child(&last, 0)
	}
	return last_id
}

// make_return builds a `return <val>` statement node with the given type.
fn (mut t Transformer) make_return(val flat.NodeId, ret_typ string) flat.NodeId {
	start := t.a.children.len
	t.a.children << val
	return t.a.add_node(flat.Node{
		kind:           .return_stmt
		children_start: start
		children_count: 1
		typ:            ret_typ
	})
}

// return_block_from_branch builds a block that keeps leading statements
// (transformed) and turns the tail expression of the branch into a `return`.
fn (mut t Transformer) return_block_from_branch(branch_id flat.NodeId, ret_typ string) flat.NodeId {
	branch := t.a.nodes[int(branch_id)]
	if branch.kind != .block {
		// single expression branch: just `return <expr>`
		ret := t.make_return(t.wrap_sum_return_expr(branch_id), ret_typ)
		return t.make_block(arr1(ret))
	}
	mut stmt_ids := []flat.NodeId{}
	for i in 0 .. branch.children_count {
		stmt_ids << t.a.child(&branch, i)
	}
	if stmt_ids.len == 0 {
		return t.make_block([]flat.NodeId{})
	}
	// all but the last are kept as statements (transformed); the last becomes a return
	lead := stmt_ids[..stmt_ids.len - 1].clone()
	new_lead := t.transform_stmts(lead)
	tail_expr := t.branch_tail_expr(branch_id)
	ret := t.make_return(t.wrap_sum_return_expr(tail_expr), ret_typ)
	mut all := []flat.NodeId{}
	for s in new_lead {
		all << s
	}
	all << ret
	return t.make_block(all)
}

// build_return_if_chain recursively converts an if_expr (possibly an else-if
// chain) into an if-statement whose branch tails are `return` statements.
fn (mut t Transformer) build_return_if_chain(if_id flat.NodeId, ret_typ string) flat.NodeId {
	if_node := t.a.nodes[int(if_id)]
	cond_id := t.a.child(&if_node, 0)
	new_cond := t.transform_expr(cond_id)
	then_id := t.a.child(&if_node, 1)
	then_block := t.return_block_from_branch(then_id, ret_typ)
	mut else_block := flat.empty_node
	if if_node.children_count >= 3 {
		else_id := t.a.child(&if_node, 2)
		else_node := t.a.nodes[int(else_id)]
		if else_node.kind == .if_expr {
			// else-if chain: recurse, wrap resulting if-stmt in a block
			inner := t.build_return_if_chain(else_id, ret_typ)
			else_block = t.make_block(arr1(inner))
		} else {
			else_block = t.return_block_from_branch(else_id, ret_typ)
		}
	}
	return t.make_if(new_cond, then_block, else_block)
}

// try_expand_return_if detects a `return if cond { a } else { b }` pattern
// and expands it into `if cond { return a } else { return b }`.
// This simplification makes the C backend's job easier since it avoids
// needing statement-expressions for the if-as-value in the return position.
//
// Leading statements in each branch are preserved, and a trailing `.expr_stmt`
// is unwrapped so the inner expression (not the statement) is returned.
//
// Returns the expanded if-statement as a single-element array, or none if the
// pattern does not match. A plain `return if x {..}` with no else (if_expr with
// fewer than 3 children) is left unexpanded.
fn (mut t Transformer) try_expand_return_if(_id flat.NodeId, node flat.Node) ?[]flat.NodeId {
	if node.children_count == 0 {
		return none
	}
	val_id := t.a.child(&node, 0)
	val_node := t.a.nodes[int(val_id)]
	if val_node.kind != .if_expr || val_node.children_count < 3 {
		return none
	}
	return arr1(t.build_return_if_chain(val_id, node.typ))
}

// try_expand_return_match detects a `return match x { ... }` pattern where
// the return value is a match expression. By the time this runs, match
// expressions should already be lowered to if_expr chains by lower_match_stmts,
// so this would see an if_expr chain rather than a match_stmt.
//
// For now, returns none. This will be implemented after confirming that
// match lowering always runs before the return expansion pass.
fn (mut t Transformer) try_expand_return_match(_id flat.NodeId, node flat.Node) ?[]flat.NodeId {
	if node.children_count == 0 {
		return none
	}
	// After match lowering, the return value would be an if_expr chain.
	// We could walk the chain and wrap each leaf in a return statement,
	// similar to try_expand_return_if but recursively through the chain.
	// For now, return none until the ordering guarantee is confirmed.
	return none
}
