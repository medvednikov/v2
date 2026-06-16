module transform

import v3.flat

pub struct Transformer {
mut:
	a       &flat.FlatAst = unsafe { nil }
	structs map[string]StructInfo
	globals map[string]string
}

pub struct StructInfo {
pub:
	name   string
	fields []FieldInfo
}

pub struct FieldInfo {
pub:
	name string
	typ  string
}

pub fn transform(mut a flat.FlatAst) {
	mut t := Transformer{
		a: &a
	}
	t.collect_types()
	t.lower_match_stmts()
}

fn (mut t Transformer) collect_types() {
	for node in t.a.nodes {
		match node.kind {
			.struct_decl {
				mut fields := []FieldInfo{}
				for i in 0 .. node.children_count {
					f := t.a.child_node(&node, i)
					fields << FieldInfo{
						name: f.value
						typ:  f.typ
					}
				}
				t.structs[node.value] = StructInfo{
					name:   node.value
					fields: fields
				}
			}
			.global_decl {
				for i in 0 .. node.children_count {
					f := t.a.child_node(&node, i)
					t.globals[f.value] = f.typ
				}
			}
			else {}
		}
	}
}

fn (mut t Transformer) lower_match_stmts() {
	for i, node in t.a.nodes {
		if node.kind == .match_stmt {
			if_id := t.lower_one_match(node)
			t.a.nodes[i] = t.a.nodes[int(if_id)]
		} else if node.kind == .expr_stmt && node.children_count == 1 {
			child_id := t.a.child(&node, 0)
			child := t.a.nodes[int(child_id)]
			if child.kind == .match_stmt {
				if_id := t.lower_one_match(child)
				t.a.nodes[i] = flat.Node{
					kind:           .expr_stmt
					children_start: t.a.children.len
					children_count: 1
				}
				t.a.children << if_id
			}
		}
	}
}

fn (mut t Transformer) lower_one_match(node flat.Node) flat.NodeId {
	match_expr_id := t.a.child(&node, 0)
	mut branches := []flat.NodeId{}
	for i in 1 .. node.children_count {
		branches << t.a.child(&node, i)
	}
	return t.build_match_chain(match_expr_id, branches, 0)
}

fn (mut t Transformer) build_match_chain(match_expr_id flat.NodeId, branches []flat.NodeId, idx int) flat.NodeId {
	if idx >= branches.len {
		return t.a.add(flat.NodeKind.empty)
	}
	branch := t.a.nodes[int(branches[idx])]
	is_else := branch.value == 'else'

	body_start_idx := if is_else { 0 } else { t.count_conds(branch) }
	mut body_ids := []flat.NodeId{}
	for i in body_start_idx .. branch.children_count {
		body_ids << t.a.child(&branch, i)
	}
	body_block_start := t.a.children.len
	for id in body_ids {
		t.a.children << id
	}
	body_block := t.a.add_node(flat.Node{
		kind:           .block
		children_start: body_block_start
		children_count: body_ids.len
	})

	if is_else {
		return body_block
	}

	cond_id := t.build_match_cond(match_expr_id, branch)

	mut if_ids := []flat.NodeId{}
	if_ids << cond_id
	if_ids << body_block
	if idx + 1 < branches.len {
		else_part := t.build_match_chain(match_expr_id, branches, idx + 1)
		if_ids << else_part
	}

	if_start := t.a.children.len
	for id in if_ids {
		t.a.children << id
	}
	return t.a.add_node(flat.Node{
		kind:           .if_expr
		children_start: if_start
		children_count: if_ids.len
	})
}

fn (mut t Transformer) build_match_cond(match_expr_id flat.NodeId, branch flat.Node) flat.NodeId {
	n_conds := t.count_conds(branch)
	if n_conds == 1 {
		cond_val_id := t.a.child(&branch, 0)
		cmp_start := t.a.children.len
		t.a.children << match_expr_id
		t.a.children << cond_val_id
		return t.a.add_node(flat.Node{
			kind:           .infix
			op:             .eq
			children_start: cmp_start
			children_count: 2
		})
	}
	mut result := flat.empty_node
	for i in 0 .. n_conds {
		cond_val_id := t.a.child(&branch, i)
		cmp_start := t.a.children.len
		t.a.children << match_expr_id
		t.a.children << cond_val_id
		cmp := t.a.add_node(flat.Node{
			kind:           .infix
			op:             .eq
			children_start: cmp_start
			children_count: 2
		})
		if int(result) < 0 {
			result = cmp
		} else {
			or_start := t.a.children.len
			t.a.children << result
			t.a.children << cmp
			result = t.a.add_node(flat.Node{
				kind:           .infix
				op:             .logical_or
				children_start: or_start
				children_count: 2
			})
		}
	}
	return result
}

fn (t &Transformer) count_conds(branch flat.Node) int {
	mut count := 0
	for i in 0 .. branch.children_count {
		child := t.a.child_node(&branch, i)
		if child.kind == .int_literal || child.kind == .ident || child.kind == .string_literal
			|| child.kind == .enum_val || child.kind == .bool_literal || child.kind == .char_literal {
			count++
		} else {
			break
		}
	}
	return count
}

pub fn (t &Transformer) get_struct_info(name string) ?StructInfo {
	if info := t.structs[name] {
		return info
	}
	return none
}

pub fn (t &Transformer) get_global_type(name string) ?string {
	if typ := t.globals[name] {
		return typ
	}
	return none
}
