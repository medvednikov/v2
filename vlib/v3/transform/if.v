module transform

import v3.flat

// try_expand_if_guard detects an if-guard pattern where the condition is a
// decl_assign whose RHS is a call returning an optional (?T) or result (!T).
// When detected it expands:
//   if val := maybe_call() { body }
// into:
//   __or_tmp_N := maybe_call()
//   if !__or_tmp_N.is_error { val := __or_tmp_N.data; body... }
//
// Currently returns none -- option/result type tracking is not yet in place,
// but the infrastructure is here for when it is.
fn (mut t Transformer) try_expand_if_guard(id flat.NodeId, node flat.Node) ?[]flat.NodeId {
	if node.kind != .if_expr || node.children_count < 2 {
		return none
	}
	cond_id := t.a.child(&node, 0)
	cond := t.a.nodes[int(cond_id)]
	if cond.kind != .decl_assign || cond.children_count < 2 {
		return none
	}
	// The RHS of the decl_assign would need to be a call returning ?T or !T.
	// We cannot determine that yet because optional/result type annotations
	// are not propagated through the flat AST at this stage.
	// When that information becomes available, the expansion is:
	//   1. Create a temp: __or_tmp_N := <rhs_call>
	//   2. Build condition: !__or_tmp_N.is_error
	//   3. Inside then-block prepend: val := __or_tmp_N.data
	//   4. Rebuild the if_expr with the new condition and augmented body
	return none
}

// try_expand_if_expr_value detects an if-expression used as a value and
// lowers it to a mutable temporary so that the C backend sees a simple
// variable instead of a gcc statement-expression.
//
//   x := if cond { a } else { b }
// becomes:
//   mut __if_tmp_N := zero_value
//   if cond { __if_tmp_N = a } else { __if_tmp_N = b }
//   x := __if_tmp_N
//
// Currently returns none -- this will be invoked from the assignment
// transform once if-as-value detection is wired up.
fn (mut t Transformer) try_expand_if_expr_value(id flat.NodeId, node flat.Node) ?flat.NodeId {
	if node.kind != .if_expr {
		return none
	}
	// An if-expression used as a value must have both then and else branches.
	if node.children_count < 3 {
		return none
	}
	// TODO: When the caller (assignment transform) invokes this, we will:
	//   1. Allocate a temp name via t.new_temp('__if_tmp')
	//   2. Create a decl_assign for the temp with a zero-value RHS
	//   3. Rewrite each branch's last expression into an assignment to the temp
	//   4. Return the temp ident as the replacement value for the original RHS
	return none
}

// transform_is_condition transforms an `x is Type` condition node.
// For sum types this will eventually become a tag comparison; for now the
// C gen already handles is_expr directly, so we pass through unchanged.
// The important side-effect is pushing a smartcast context so the
// then-branch can see x narrowed to the variant type.
fn (mut t Transformer) transform_is_condition(cond_id flat.NodeId) flat.NodeId {
	if int(cond_id) < 0 {
		return cond_id
	}
	cond := t.a.nodes[int(cond_id)]
	if cond.kind != .is_expr {
		return cond_id
	}
	// is_expr: child[0] is the expression being checked, value is the type name.
	if cond.children_count < 1 {
		return cond_id
	}
	expr_id := t.a.child(&cond, 0)
	expr_node := t.a.nodes[int(expr_id)]
	variant_name := cond.value
	if variant_name.len == 0 {
		return cond_id
	}
	// Determine the expression name for smartcast tracking.
	expr_name := if expr_node.kind == .ident {
		expr_node.value
	} else {
		''
	}
	if expr_name.len > 0 {
		// Find which sum type this variant belongs to.
		sum_type_name := t.find_sum_type_for_variant(variant_name)
		if sum_type_name.len > 0 {
			t.push_smartcast(expr_name, variant_name, sum_type_name)
		}
	}
	// The node itself passes through -- C gen handles is_expr.
	return cond_id
}

// transform_and_chain_smartcasts handles conditions like
// `x is T && x.field > 0` where the second operand should see x
// narrowed to T through a smartcast.
//
// It walks a left-associative chain of .logical_and nodes. When a
// term is an is_expr it pushes a smartcast so subsequent terms
// (and the then-branch) see the narrowed type.
//
// Currently passes through unchanged but is structured to detect
// the pattern for future expansion.
fn (mut t Transformer) transform_and_chain_smartcasts(cond_id flat.NodeId) flat.NodeId {
	if int(cond_id) < 0 {
		return cond_id
	}
	cond := t.a.nodes[int(cond_id)]
	if cond.kind != .infix || cond.op != .logical_and {
		// Not an && chain -- check if it is a bare is_expr.
		return t.transform_is_condition(cond_id)
	}
	if cond.children_count < 2 {
		return cond_id
	}
	// Left side of the &&.
	lhs_id := t.a.child(&cond, 0)
	lhs := t.a.nodes[int(lhs_id)]
	// If the left side is an is_expr, push smartcast before processing RHS.
	if lhs.kind == .is_expr && lhs.children_count >= 1 {
		lhs_expr_id := t.a.child(&lhs, 0)
		ek := t.expr_key(lhs_expr_id)
		if ek.len > 0 && lhs.value.len > 0 {
			sum_type_name := t.find_sum_type_for_variant(lhs.value)
			if sum_type_name.len > 0 {
				t.push_smartcast(ek, lhs.value, sum_type_name)
			}
		}
	} else if lhs.kind == .infix && lhs.op == .logical_and {
		// Recurse into nested && on the left.
		t.transform_and_chain_smartcasts(lhs_id)
	}
	// Right side -- future: transform under accumulated smartcasts.
	// For now, pass through.
	return cond_id
}

// transform_if_branches_with_smartcast is the main if-expr handler that
// integrates smartcasting. When the condition contains an is_expr, it
// pushes a smartcast for the then-branch, transforms the body under
// that context, pops the smartcast, then transforms the else-block.
fn (mut t Transformer) transform_if_branches_with_smartcast(id flat.NodeId, node flat.Node) flat.NodeId {
	if node.kind != .if_expr || node.children_count < 2 {
		return id
	}
	cond_id := t.a.child(&node, 0)
	then_id := t.a.child(&node, 1)
	has_else := node.children_count >= 3
	else_id := if has_else { t.a.child(&node, 2) } else { flat.empty_node }

	// Determine if the condition involves an is_expr. It might be:
	//   a) directly an is_expr
	//   b) an && chain where one term is an is_expr
	is_info := t.extract_is_expr(cond_id)

	mut has_smartcast := false
	if is_info.expr_name.len > 0 && is_info.sum_type_name.len > 0 {
		t.push_smartcast(is_info.expr_name, is_info.variant_name, is_info.sum_type_name)
		has_smartcast = true
	}
	new_cond_id := t.transform_expr(cond_id)

	// Transform then-block children under the smartcast context.
	then_node := t.a.nodes[int(then_id)]
	new_then_id := if then_node.kind == .block {
		child_ids := t.a.children_of(&then_node)
		new_children := t.transform_stmts(child_ids)
		block_start := t.a.children.len
		for c in new_children {
			t.a.children << c
		}
		t.a.add_node(flat.Node{
			kind:           .block
			children_start: block_start
			children_count: new_children.len
		})
	} else {
		then_id
	}

	// Pop smartcast before processing else-block.
	if has_smartcast {
		t.pop_smartcast()
	}

	// Transform else-block (no smartcast -- the is_expr was false here).
	new_else_id := if has_else {
		else_node := t.a.nodes[int(else_id)]
		if else_node.kind == .if_expr {
			// else-if chain: recurse.
			t.transform_if_branches_with_smartcast(else_id, else_node)
		} else if else_node.kind == .block {
			child_ids := t.a.children_of(&else_node)
			new_children := t.transform_stmts(child_ids)
			block_start := t.a.children.len
			for c in new_children {
				t.a.children << c
			}
			t.a.add_node(flat.Node{
				kind:           .block
				children_start: block_start
				children_count: new_children.len
			})
		} else {
			else_id
		}
	} else {
		flat.empty_node
	}

	// Rebuild the if_expr with (possibly) new children.
	if_start := t.a.children.len
	t.a.children << new_cond_id
	t.a.children << new_then_id
	mut child_count := 2
	if has_else {
		t.a.children << new_else_id
		child_count = 3
	}
	return t.a.add_node(flat.Node{
		kind:           .if_expr
		children_start: if_start
		children_count: child_count
		typ:            node.typ
		pos:            node.pos
	})
}

// --- helpers ---

struct IsExprInfo {
	expr_name      string
	variant_name   string
	sum_type_name  string
}

// extract_is_expr searches a condition tree for an is_expr and returns
// the expression name, variant, and owning sum type. Returns an empty
// struct if no is_expr is found.
fn (t &Transformer) extract_is_expr(cond_id flat.NodeId) IsExprInfo {
	if int(cond_id) < 0 {
		return IsExprInfo{}
	}
	cond := t.a.nodes[int(cond_id)]
	if cond.kind == .is_expr && cond.children_count >= 1 {
		expr_id := t.a.child(&cond, 0)
		ek := t.expr_key(expr_id)
		if ek.len > 0 && cond.value.len > 0 {
			return IsExprInfo{
				expr_name:     ek
				variant_name:  cond.value
				sum_type_name: t.find_sum_type_for_variant(cond.value)
			}
		}
	}
	if cond.kind == .infix && cond.op == .logical_and && cond.children_count >= 2 {
		// Check left side first (is_expr is typically on the left of &&).
		lhs_id := t.a.child(&cond, 0)
		info := t.extract_is_expr(lhs_id)
		if info.expr_name.len > 0 {
			return info
		}
		// Check right side as fallback.
		rhs_id := t.a.child(&cond, 1)
		return t.extract_is_expr(rhs_id)
	}
	return IsExprInfo{}
}

// find_sum_type_for_variant returns the sum type name that contains
// the given variant, or '' if none is found.
fn (t &Transformer) find_sum_type_for_variant(variant string) string {
	short := if variant.contains('.') { variant.all_after_last('.') } else { variant }
	mut best := ''
	for sum_name, variants in t.sum_types {
		for v in variants {
			if v == variant || v == short {
				if sum_name.contains('.') {
					return sum_name
				}
				if best.len == 0 {
					best = sum_name
				}
			}
		}
	}
	return best
}
