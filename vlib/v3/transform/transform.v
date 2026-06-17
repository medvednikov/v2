module transform

import v3.flat

pub struct Transformer {
mut:
	a            &flat.FlatAst = unsafe { nil }
	structs      map[string]StructInfo
	globals      map[string]string
	sum_types    map[string][]string
	fn_ret_types map[string]string
	cur_module   string
	var_types    map[string]string
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
	t.lower_array_appends()
}

fn (mut t Transformer) collect_types() {
	mut cur_mod := ''
	for node in t.a.nodes {
		match node.kind {
			.module_decl {
				cur_mod = node.value
			}
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
			.type_decl {
				if node.children_count > 0 {
					mut variants := []string{}
					for i in 0 .. node.children_count {
						v := t.a.child_node(&node, i)
						variants << v.value
					}
					t.sum_types[node.value] = variants
				}
			}
			.global_decl {
				for i in 0 .. node.children_count {
					f := t.a.child_node(&node, i)
					t.globals[f.value] = f.typ
				}
			}
			.fn_decl {
				if node.typ.len > 0 {
					t.fn_ret_types[node.value] = node.typ
					if cur_mod.len > 0 && cur_mod != 'main' && cur_mod != 'builtin' {
						t.fn_ret_types['${cur_mod}.${node.value}'] = node.typ
					}
				}
			}
			else {}
		}
	}
}

fn (mut t Transformer) lower_array_appends() {
	for i, node in t.a.nodes {
		if node.kind == .module_decl {
			t.cur_module = node.value
			continue
		}
		if node.kind == .fn_decl {
			t.var_types = map[string]string{}
			t.annotate_fn_body(node)
			continue
		}
		if node.kind == .decl_assign && node.children_count >= 2 {
			lhs := t.a.child_node(&node, 0)
			if lhs.kind == .ident && lhs.value.len > 0 {
				typ := t.infer_decl_type(node)
				if typ.len > 0 {
					t.var_types[lhs.value] = typ
				}
			}
		}
		if node.kind == .expr_stmt && node.children_count == 1 {
			child_id := t.a.child(&node, 0)
			mut child := &t.a.nodes[int(child_id)]
			if child.kind == .infix && child.op == .left_shift {
				t.annotate_left_shift(child_id)
			}
		}
		if node.kind == .assign && node.op == .left_shift_assign && node.children_count >= 2 {
			lhs := t.a.child_node(&node, 0)
			if lhs.kind == .ident && lhs.value.len > 0 {
				lhs_type := t.var_types[lhs.value] or { '' }
				if lhs_type.starts_with('[]') {
					rhs_id := t.a.child(&node, 1)
					rhs_type := t.resolve_expr_type(rhs_id)
					if rhs_type.starts_with('[]') {
						t.a.nodes[i] = flat.Node{kind: node.kind, op: node.op, children_start: node.children_start, children_count: node.children_count, value: 'push_many', typ: lhs_type[2..]}
					} else {
						t.a.nodes[i] = flat.Node{kind: node.kind, op: node.op, children_start: node.children_start, children_count: node.children_count, value: 'push', typ: lhs_type[2..]}
					}
				}
			}
		}
	}
}

fn (mut t Transformer) annotate_fn_body(fn_node flat.Node) {
	for i in 0 .. fn_node.children_count {
		child_id := t.a.child(&fn_node, i)
		if int(child_id) < 0 {
			continue
		}
		child := t.a.nodes[int(child_id)]
		if child.kind == .param && child.value.len > 0 && child.typ.len > 0 {
			t.var_types[child.value] = child.typ
		}
		if child.kind == .decl_assign && child.children_count >= 2 {
			lhs := t.a.child_node(&child, 0)
			if lhs.kind == .ident && lhs.value.len > 0 {
				typ := t.infer_decl_type(child)
				if typ.len > 0 {
					t.var_types[lhs.value] = typ
				}
			}
		}
		if child.kind == .expr_stmt && child.children_count == 1 {
			inner_id := t.a.child(&child, 0)
			inner := t.a.nodes[int(inner_id)]
			if inner.kind == .infix && inner.op == .left_shift {
				t.annotate_left_shift(inner_id)
			}
		}
		t.annotate_block_stmts(child_id)
	}
}

fn (mut t Transformer) annotate_block_stmts(node_id flat.NodeId) {
	if int(node_id) < 0 {
		return
	}
	node := t.a.nodes[int(node_id)]
	for i in 0 .. node.children_count {
		child_id := t.a.child(&node, i)
		if int(child_id) < 0 {
			continue
		}
		child := t.a.nodes[int(child_id)]
		if child.kind == .decl_assign && child.children_count >= 2 {
			lhs := t.a.child_node(&child, 0)
			if lhs.kind == .ident && lhs.value.len > 0 {
				typ := t.infer_decl_type(child)
				if typ.len > 0 {
					t.var_types[lhs.value] = typ
				}
			}
		}
		if child.kind == .expr_stmt && child.children_count == 1 {
			inner_id := t.a.child(&child, 0)
			inner := t.a.nodes[int(inner_id)]
			if inner.kind == .infix && inner.op == .left_shift {
				t.annotate_left_shift(inner_id)
			}
		}
		t.annotate_block_stmts(child_id)
	}
}

fn (mut t Transformer) annotate_left_shift(node_id flat.NodeId) {
	node := t.a.nodes[int(node_id)]
	if node.children_count < 2 {
		return
	}
	lhs_id := t.a.child(&node, 0)
	lhs := t.a.nodes[int(lhs_id)]
	if lhs.kind != .ident {
		return
	}
	lhs_type := t.var_types[lhs.value] or { '' }
	if !lhs_type.starts_with('[]') {
		return
	}
	rhs_id := t.a.child(&node, 1)
	rhs_type := t.resolve_expr_type(rhs_id)
	if rhs_type.starts_with('[]') {
		t.a.nodes[int(node_id)] = flat.Node{kind: .infix, op: .left_shift, children_start: node.children_start, children_count: node.children_count, value: 'push_many', typ: lhs_type[2..]}
	} else {
		t.a.nodes[int(node_id)] = flat.Node{kind: .infix, op: .left_shift, children_start: node.children_start, children_count: node.children_count, value: 'push', typ: lhs_type[2..]}
	}
}

fn (t &Transformer) infer_decl_type(node &flat.Node) string {
	if node.typ.len > 0 {
		return node.typ
	}
	if node.children_count >= 2 {
		rhs_id := t.a.child(node, 1)
		rhs := t.a.nodes[int(rhs_id)]
		if rhs.kind == .array_literal || rhs.kind == .array_init {
			return rhs.typ
		}
		return t.resolve_expr_type(rhs_id)
	}
	return ''
}

fn (t &Transformer) resolve_expr_type(id flat.NodeId) string {
	if int(id) < 0 {
		return ''
	}
	node := t.a.nodes[int(id)]
	match node.kind {
		.ident {
			return t.var_types[node.value] or { '' }
		}
		.call {
			if node.children_count > 0 {
				fn_id := t.a.child(&node, 0)
				fn_node := t.a.nodes[int(fn_id)]
				if fn_node.kind == .ident {
					if ret := t.fn_ret_types[fn_node.value] {
						return ret
					}
					qname := if t.cur_module.len > 0 && t.cur_module != 'main' && t.cur_module != 'builtin' { '${t.cur_module}.${fn_node.value}' } else { fn_node.value }
					if ret := t.fn_ret_types[qname] {
						return ret
					}
				} else if fn_node.kind == .selector && fn_node.children_count > 0 {
					base_id := t.a.child(&fn_node, 0)
					base := t.a.nodes[int(base_id)]
					if base.kind == .ident {
						full := '${base.value}.${fn_node.value}'
						if ret := t.fn_ret_types[full] {
							return ret
						}
					}
				}
			}
			return ''
		}
		.array_literal, .array_init {
			return node.typ
		}
		.string_literal, .string_interp {
			return 'string'
		}
		.int_literal {
			return 'int'
		}
		else {
			return ''
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
	match_expr := t.a.nodes[int(match_expr_id)]

	needs_temp := match_expr.kind !in [.ident, .int_literal, .bool_literal, .string_literal,
		.char_literal]

	mut actual_expr_id := match_expr_id
	mut prefix_id := flat.empty_node

	if needs_temp {
		tmp_name := '__match_tmp_${int(match_expr_id)}'
		tmp_ident := t.a.add_val(.ident, tmp_name)
		decl_start := t.a.children.len
		t.a.children << tmp_ident
		t.a.children << match_expr_id
		prefix_id = t.a.add_node(flat.Node{
			kind:           .decl_assign
			children_start: decl_start
			children_count: 2
		})
		actual_expr_id = t.a.add_val(.ident, tmp_name)
	}

	mut branches := []flat.NodeId{}
	for i in 1 .. node.children_count {
		branches << t.a.child(&node, i)
	}
	if_id := t.build_match_chain(actual_expr_id, branches, 0)

	if needs_temp {
		block_start := t.a.children.len
		t.a.children << prefix_id
		t.a.children << if_id
		return t.a.add_node(flat.Node{
			kind:           .block
			children_start: block_start
			children_count: 2
		})
	}
	return if_id
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

fn (t &Transformer) is_sum_variant(name string) bool {
	for _, variants in t.sum_types {
		for v in variants {
			if v == name {
				return true
			}
		}
	}
	return false
}

fn (mut t Transformer) build_match_cond(match_expr_id flat.NodeId, branch flat.Node) flat.NodeId {
	n_conds := t.count_conds(branch)
	if n_conds == 1 {
		cond_val_id := t.a.child(&branch, 0)
		cond_val := t.a.nodes[int(cond_val_id)]
		if cond_val.kind == .ident && t.is_sum_variant(cond_val.value) {
			is_start := t.a.children.len
			t.a.children << match_expr_id
			return t.a.add_node(flat.Node{
				kind:           .is_expr
				value:          cond_val.value
				children_start: is_start
				children_count: 1
			})
		}
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
		cond_val := t.a.nodes[int(cond_val_id)]
		is_sum_cond := cond_val.kind == .ident && t.is_sum_variant(cond_val.value)
		cmp := if is_sum_cond {
			is_start := t.a.children.len
			t.a.children << match_expr_id
			t.a.add_node(flat.Node{
				kind:           .is_expr
				value:          cond_val.value
				children_start: is_start
				children_count: 1
			})
		} else {
			cmp_start := t.a.children.len
			t.a.children << match_expr_id
			t.a.children << cond_val_id
			t.a.add_node(flat.Node{
				kind:           .infix
				op:             .eq
				children_start: cmp_start
				children_count: 2
			})
		}
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
	if branch.value.len > 0 && branch.value != 'else' {
		return branch.value.int()
	}
	mut count := 0
	for i in 0 .. branch.children_count {
		child := t.a.child_node(&branch, i)
		if child.kind == .int_literal || child.kind == .ident || child.kind == .string_literal || child.kind == .enum_val || child.kind == .bool_literal || child.kind == .char_literal {
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
