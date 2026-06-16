module flat

import v3.token

pub type NodeId = int

pub const empty_node = NodeId(-1)

pub enum NodeKind {
	empty
	// expressions
	int_literal
	float_literal
	bool_literal
	char_literal
	string_literal
	string_interp
	ident
	infix
	prefix
	postfix
	paren
	call
	selector
	index
	if_expr
	struct_init
	field_init
	array_literal
	array_init
	map_init
	fn_literal
	or_expr
	cast_expr
	as_expr
	enum_val
	assoc
	range
	nil_literal
	none_expr
	spawn_expr
	lock_expr
	lambda_expr
	sizeof_expr
	typeof_expr
	dump_expr
	offsetof_expr
	is_expr
	in_expr
	// statements
	expr_stmt
	assign
	decl_assign
	selector_assign
	index_assign
	return_stmt
	block
	for_stmt
	for_in_stmt
	break_stmt
	continue_stmt
	match_stmt
	match_branch
	defer_stmt
	assert_stmt
	goto_stmt
	label_stmt
	select_stmt
	select_branch
	comptime_if
	comptime_for
	asm_stmt
	// declarations
	fn_decl
	struct_decl
	field_decl
	global_decl
	const_decl
	const_field
	enum_decl
	enum_field
	type_decl
	interface_decl
	interface_field
	import_decl
	module_decl
	directive
	param
	c_fn_decl
	// top-level
	file
}

pub enum Op {
	none
	plus
	minus
	mul
	div
	mod
	eq
	ne
	lt
	gt
	le
	ge
	amp
	pipe
	xor
	left_shift
	right_shift
	logical_and
	logical_or
	not
	bit_not
	assign
	plus_assign
	minus_assign
	mul_assign
	div_assign
	mod_assign
	amp_assign
	pipe_assign
	xor_assign
	left_shift_assign
	right_shift_assign
	inc
	dec
}

pub struct Node {
pub:
	kind           NodeKind
	op             Op
	children_start int
	children_count int
	pos            token.Pos
pub mut:
	value string
	typ   string
}

@[heap]
pub struct FlatAst {
pub mut:
	nodes    []Node
	children []NodeId
}

pub fn FlatAst.new() FlatAst {
	return FlatAst{
		nodes:    []Node{cap: 256}
		children: []NodeId{cap: 512}
	}
}

pub fn (mut a FlatAst) add(kind NodeKind) NodeId {
	id := NodeId(a.nodes.len)
	a.nodes << Node{
		kind: kind
	}
	return id
}

pub fn (mut a FlatAst) add_val(kind NodeKind, value string) NodeId {
	id := NodeId(a.nodes.len)
	a.nodes << Node{
		kind:  kind
		value: value
	}
	return id
}

pub fn (mut a FlatAst) add_node(node Node) NodeId {
	id := NodeId(a.nodes.len)
	a.nodes << node
	return id
}

pub fn (mut a FlatAst) begin_children() int {
	return a.children.len
}

pub fn (mut a FlatAst) add_child(id NodeId) {
	a.children << id
}

pub fn (a &FlatAst) child(node &Node, index int) NodeId {
	return a.children[node.children_start + index]
}

pub fn (a &FlatAst) child_node(node &Node, index int) &Node {
	return &a.nodes[int(a.children[node.children_start + index])]
}

pub fn (a &FlatAst) node(id NodeId) &Node {
	return &a.nodes[int(id)]
}

pub fn (a &FlatAst) children_of(node &Node) []NodeId {
	if node.children_count == 0 {
		return []
	}
	return a.children[node.children_start..node.children_start + node.children_count]
}

pub fn (a &FlatAst) print_tree(id NodeId, indent int) {
	node := a.nodes[int(id)]
	mut prefix := ''
	for _ in 0 .. indent {
		prefix += '  '
	}
	mut info := '${node.kind}'
	if node.value.len > 0 {
		info += ' "${node.value}"'
	}
	if node.op != .none {
		info += ' op=${node.op}'
	}
	if node.typ.len > 0 {
		info += ' typ=${node.typ}'
	}
	println('${prefix}${info}')
	for i in 0 .. node.children_count {
		child_id := a.children[node.children_start + i]
		if int(child_id) >= 0 {
			a.print_tree(child_id, indent + 1)
		}
	}
}
