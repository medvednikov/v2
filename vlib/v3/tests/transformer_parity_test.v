import os
import v3.flat
import v3.parser
import v3.pref
import v3.transform
import v3.types

fn parse_transform_source(source string) &flat.FlatAst {
	src := os.join_path(os.temp_dir(), 'v3_transformer_parity_test.v')
	return parse_transform_file(src, source)
}

fn parse_transform_file(src string, source string) &flat.FlatAst {
	os.write_file(src, source) or { panic(err) }
	prefs := pref.new_preferences()
	mut p := parser.Parser.new(prefs)
	mut a := p.parse_file(src)
	mut tc := types.TypeChecker.new(a)
	tc.collect(a)
	tc.annotate_types()
	transform.transform(mut a, &tc)
	return a
}

fn find_fn(a &flat.FlatAst, name string) flat.Node {
	for node in a.nodes {
		if node.kind == .fn_decl && node.value == name {
			return node
		}
	}
	assert false
	return flat.Node{}
}

fn first_decl_rhs(a &flat.FlatAst, fn_name string) flat.Node {
	f := find_fn(a, fn_name)
	for i in 0 .. f.children_count {
		stmt := a.child_node(&f, i)
		if stmt.kind == .decl_assign && stmt.children_count == 2 {
			return *a.child_node(stmt, 1)
		}
	}
	assert false
	return flat.Node{}
}

fn count_kind(a &flat.FlatAst, id flat.NodeId, kind flat.NodeKind) int {
	if int(id) < 0 {
		return 0
	}
	node := a.nodes[int(id)]
	mut total := if node.kind == kind { 1 } else { 0 }
	for i in 0 .. node.children_count {
		total += count_kind(a, a.child(&node, i), kind)
	}
	return total
}

fn count_call_name(a &flat.FlatAst, id flat.NodeId, name string) int {
	if int(id) < 0 {
		return 0
	}
	node := a.nodes[int(id)]
	mut total := 0
	if node.kind == .call && node.children_count > 0 {
		fn_node := a.child_node(&node, 0)
		if fn_node.kind == .ident && fn_node.value == name {
			total++
		}
	}
	for i in 0 .. node.children_count {
		total += count_call_name(a, a.child(&node, i), name)
	}
	return total
}

fn test_typeof_expression_lowers_to_string_literal() {
	a := parse_transform_source('
fn main() {
	name := typeof(123)
}
')
	main_fn := find_fn(a, 'main')
	for i in 0 .. main_fn.children_count {
		stmt := a.child_node(&main_fn, i)
		if stmt.kind == .decl_assign && stmt.children_count == 2 {
			rhs := a.child_node(stmt, 1)
			assert rhs.kind == .string_literal
			assert rhs.value == 'int'
			return
		}
	}
	assert false
}

fn test_vmodroot_lowers_to_nearest_vmod_dir() {
	root := os.join_path(os.temp_dir(), 'v3_vmodroot_transformer_parity')
	os.mkdir_all(root) or { panic(err) }
	os.write_file(os.join_path(root, 'v.mod'), 'Module { name: "parity" }') or { panic(err) }
	src := os.join_path(root, 'main.v')
	a := parse_transform_file(src, '
fn main() {
	root := @VMODROOT
}
')
	rhs := first_decl_rhs(a, 'main')
	assert rhs.kind == .string_literal
	assert rhs.value == root
}

fn test_return_match_lowers_to_explicit_branch_returns() {
	a := parse_transform_source('
fn choose(x int) int {
	return match x {
		0 {
			10
		}
		else {
			20
		}
	}
}
')
	choose_fn := find_fn(a, 'choose')
	mut match_count := 0
	mut return_count := 0
	for i in 0 .. choose_fn.children_count {
		child_id := a.child(&choose_fn, i)
		match_count += count_kind(a, child_id, .match_stmt)
		return_count += count_kind(a, child_id, .return_stmt)
	}
	assert match_count == 0
	assert return_count == 2
}

fn test_return_if_keeps_or_lowering_inside_branch() {
	a := parse_transform_source('
fn maybe_int() ?int {
	return 8
}

fn choose(flag bool) int {
	return if flag {
		maybe_int() or {
			1
		}
	} else {
		2
	}
}
')
	choose_fn := find_fn(a, 'choose')
	mut body_ids := []flat.NodeId{}
	for i in 0 .. choose_fn.children_count {
		child_id := a.child(&choose_fn, i)
		child := a.nodes[int(child_id)]
		if child.kind != .param {
			body_ids << child_id
		}
	}
	assert body_ids.len == 1
	assert a.nodes[int(body_ids[0])].kind == .if_expr
}

fn test_or_expr_lowers_to_temp_and_if() {
	a := parse_transform_source('
fn maybe_int() ?int {
	return 3
}

fn main() {
	x := maybe_int() or {
		7
	}
}
')
	main_fn := find_fn(a, 'main')
	mut or_count := 0
	mut if_count := 0
	for i in 0 .. main_fn.children_count {
		child_id := a.child(&main_fn, i)
		or_count += count_kind(a, child_id, .or_expr)
		if_count += count_kind(a, child_id, .if_expr)
	}
	assert or_count == 0
	assert if_count == 1
}

fn test_map_index_or_lowers_to_get_check() {
	a := parse_transform_source('
fn main() {
	mut m := map[string]int{}
	x := m["a"] or {
		7
	}
}
')
	main_fn := find_fn(a, 'main')
	mut or_count := 0
	mut get_check_count := 0
	for i in 0 .. main_fn.children_count {
		child_id := a.child(&main_fn, i)
		or_count += count_kind(a, child_id, .or_expr)
		get_check_count += count_call_name(a, child_id, 'map__get_check')
	}
	assert or_count == 0
	assert get_check_count == 1
}
