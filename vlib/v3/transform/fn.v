module transform

import v3.flat
import v3.types

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
	mut new_children := []flat.NodeId{cap: node.children_count}
	for i in 0 .. node.children_count {
		child_id := t.a.child(&node, i)
		new_children << t.transform_expr(child_id)
	}
	start := t.a.children.len
	for nc in new_children {
		t.a.children << nc
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

fn (mut t Transformer) stringify_expr(expr_id flat.NodeId) flat.NodeId {
	typ := t.node_type(expr_id)
	expr := t.transform_expr(expr_id)
	return t.wrap_string_conversion(expr, typ)
}

fn (mut t Transformer) wrap_string_conversion(expr flat.NodeId, typ string) flat.NodeId {
	mut clean_typ := typ
	if clean_typ.starts_with('&') {
		clean_typ = clean_typ[1..]
	}
	if clean_typ == 'string' {
		return expr
	}
	if clean_typ == 'IError' || clean_typ.ends_with('.IError') {
		start := t.a.children.len
		t.a.children << expr
		return t.a.add_node(flat.Node{
			kind:           .selector
			op:             .dot
			children_start: start
			children_count: 1
			value:          'message'
			typ:            'string'
		})
	}
	match clean_typ {
		'bool' {
			return t.make_call('bool_str', arr1(expr))
		}
		'u8', 'byte', 'u16', 'u32', 'u64' {
			return t.make_call('strconv__format_uint', arr2(expr, t.make_int_literal(10)))
		}
		'int', 'i8', 'i16', 'i32', 'i64', 'isize', 'usize' {
			return t.make_call('strconv__format_int', arr2(expr, t.make_int_literal(10)))
		}
		'f32' {
			return t.make_call('strconv__f32_to_str_l', arr1(expr))
		}
		'f64' {
			return t.make_call('strconv__f64_to_str_l', arr1(expr))
		}
		else {
			if clean_typ in t.structs || clean_typ in t.sum_types {
				return t.make_call('${c_name(clean_typ)}__str', arr1(expr))
			} else {
				return t.make_call('strconv__format_int', arr2(expr, t.make_int_literal(10)))
			}
		}
	}
}

fn (t &Transformer) is_flag_enum_type(typ string) bool {
	mut clean := typ
	if clean.starts_with('&') {
		clean = clean[1..]
	}
	if clean.len == 0 {
		return false
	}
	if !isnil(t.tc) {
		parsed := t.tc.parse_type(clean)
		if parsed is types.Enum {
			return parsed.is_flag
		}
	}
	return false
}

fn (t &Transformer) is_runtime_array_flags_selector(id flat.NodeId) bool {
	if int(id) < 0 {
		return false
	}
	node := t.a.nodes[int(id)]
	if node.kind != .selector || node.value != 'flags' || node.children_count == 0 {
		return false
	}
	owner_id := t.a.child(&node, 0)
	owner_type := t.node_type(owner_id).trim_left('&')
	return owner_type.starts_with('[]') || owner_type == 'strings.Builder'
}

fn (mut t Transformer) try_lower_flag_enum_stmt(call_id flat.NodeId) ?flat.NodeId {
	if int(call_id) < 0 {
		return none
	}
	call := t.a.nodes[int(call_id)]
	if call.kind != .call || call.children_count < 2 {
		return none
	}
	fn_id := t.a.child(&call, 0)
	fn_node := t.a.nodes[int(fn_id)]
	if fn_node.kind != .selector || fn_node.children_count == 0
		|| fn_node.value !in ['set', 'clear'] {
		return none
	}
	base_id := t.a.child(&fn_node, 0)
	if t.is_runtime_array_flags_selector(base_id) {
		return none
	}
	base_type := t.node_type(base_id)
	if !t.is_flag_enum_type(base_type) {
		return none
	}
	base := t.transform_expr(base_id)
	arg := t.transform_expr(t.a.child(&call, 1))
	if fn_node.value == 'set' {
		return t.make_assign_op(base, arg, .pipe_assign)
	}
	return t.make_assign_op(base, t.make_prefix(.bit_not, arg), .amp_assign)
}

fn (mut t Transformer) try_lower_flag_enum_call(node flat.Node) ?flat.NodeId {
	if node.children_count < 2 {
		return none
	}
	fn_id := t.a.child(&node, 0)
	fn_node := t.a.nodes[int(fn_id)]
	if fn_node.kind != .selector || fn_node.children_count == 0 || fn_node.value !in ['has', 'all'] {
		return none
	}
	base_id := t.a.child(&fn_node, 0)
	if t.is_runtime_array_flags_selector(base_id) {
		return none
	}
	base_type := t.node_type(base_id)
	if !t.is_flag_enum_type(base_type) {
		return none
	}
	base := t.transform_expr(base_id)
	arg_id := t.a.child(&node, 1)
	arg := t.transform_expr(arg_id)
	masked := t.make_infix(.amp, base, arg)
	if fn_node.value == 'has' {
		return t.make_infix(.ne, masked, t.make_int_literal(0))
	}
	arg_copy := t.transform_expr(arg_id)
	return t.make_infix(.eq, masked, arg_copy)
}

fn (mut t Transformer) try_lower_array_method_call(node flat.Node) ?flat.NodeId {
	if node.children_count == 0 {
		return none
	}
	fn_id := t.a.child(&node, 0)
	fn_node := t.a.nodes[int(fn_id)]
	if fn_node.kind != .selector || fn_node.children_count == 0 {
		return none
	}
	base_id := t.a.child(&fn_node, 0)
	base_type := t.node_type(base_id)
	if !base_type.starts_with('[]') {
		return none
	}
	elem_type := base_type[2..]
	receiver := t.transform_expr(base_id)
	match fn_node.value {
		'clone' {
			return t.make_call_typed('array_clone', arr1(receiver), base_type)
		}
		'contains' {
			if node.children_count < 2 {
				return none
			}
			arg := t.transform_expr(t.a.child(&node, 1))
			fn_name := if elem_type == 'string' {
				'array_contains_string'
			} else {
				'array_contains_int'
			}
			return t.make_call_typed(fn_name, arr2(receiver, arg), 'bool')
		}
		'index' {
			if node.children_count < 2 {
				return none
			}
			arg := t.transform_expr(t.a.child(&node, 1))
			fn_name := if elem_type == 'string' { 'array_index_string' } else { 'array_index_int' }
			return t.make_call_typed(fn_name, arr2(receiver, arg), 'int')
		}
		'join' {
			if node.children_count < 2 {
				return none
			}
			arg := t.transform_expr(t.a.child(&node, 1))
			return t.make_call_typed('array_string_join', arr2(receiver, arg), 'string')
		}
		else {
			return none
		}
	}
}

// try_lower_builtin_call checks if a call is to a builtin that needs special lowering.
// Returns none for most calls so the caller falls through to generic call transform.
fn (mut t Transformer) try_lower_builtin_call(_id flat.NodeId, node flat.Node) ?flat.NodeId {
	name := t.resolve_call_name(node)
	if name.len == 0 {
		return none
	}
	if flag_call := t.try_lower_flag_enum_call(node) {
		return flag_call
	}
	if array_call := t.try_lower_array_method_call(node) {
		return array_call
	}
	match name {
		'println', 'eprintln', 'print' {
			if node.children_count < 2 {
				return t.transform_call_args(node)
			}
			arg := t.stringify_expr(t.a.child(&node, 1))
			return t.make_call(name, arr1(arg))
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
