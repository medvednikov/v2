module transform

import v3.flat

// propagate_decl_type infers the declared variable type from a .decl_assign node
// and registers it in var_types so downstream transforms can resolve it.
fn (mut t Transformer) propagate_decl_type(node flat.Node) {
	if node.kind != .decl_assign || node.children_count < 2 {
		return
	}
	lhs_id := t.a.child(&node, 0)
	lhs := t.a.nodes[int(lhs_id)]
	if lhs.kind != .ident || lhs.value.len == 0 {
		return
	}
	mut typ := ''
	if node.typ.len > 0 {
		typ = node.typ
	} else {
		rhs_id := t.a.child(&node, 1)
		typ = t.resolve_expr_type(rhs_id)
	}
	if typ.len > 0 {
		t.var_types[lhs.value] = typ
	}
}

// resolve_selector_type resolves the type of a .selector node (e.g. `obj.field`).
// Looks up the base expression type, then finds the field in the struct definition.
fn (t &Transformer) resolve_selector_type(node flat.Node) string {
	if node.kind != .selector || node.children_count == 0 {
		return ''
	}
	base_id := t.a.child(&node, 0)
	base_type := t.resolve_expr_type(base_id)
	if base_type.len == 0 {
		return ''
	}
	field_name := node.value
	if field_name.len == 0 {
		return ''
	}
	// Strip pointer prefix if present (e.g. "&MyStruct" -> "MyStruct")
	lookup_type := if base_type.starts_with('&') { base_type[1..] } else { base_type }
	info := t.structs[lookup_type] or { return '' }
	for f in info.fields {
		if f.name == field_name {
			return f.typ
		}
	}
	return ''
}

// resolve_index_elem_type determines the element type of an .index expression.
// For `[]T` arrays returns `T`, for `map[K]V` returns `V`, for `string` returns `u8`.
fn (t &Transformer) resolve_index_elem_type(node flat.Node) string {
	if node.kind != .index || node.children_count == 0 {
		return ''
	}
	base_id := t.a.child(&node, 0)
	base_type := t.resolve_expr_type(base_id)
	if base_type.len == 0 {
		return ''
	}
	if base_type.starts_with('[]') {
		return base_type[2..]
	}
	if base_type.starts_with('map[') {
		bracket_end := base_type.index(']') or { return '' }
		if bracket_end + 1 < base_type.len {
			return base_type[bracket_end + 1..]
		}
		return ''
	}
	if base_type == 'string' {
		return 'u8'
	}
	return ''
}

// is_string_type checks if an expression resolves to string type.
// Handles string literals, interpolations, and ident/call expressions typed as string.
fn (t &Transformer) is_string_type(id flat.NodeId) bool {
	if int(id) < 0 {
		return false
	}
	node := t.a.nodes[int(id)]
	if node.kind == .string_literal || node.kind == .string_interp {
		return true
	}
	return t.resolve_expr_type(id) == 'string'
}

// is_array_type checks if a type string represents an array type (starts with `[]`).
fn (t &Transformer) is_array_type(type_str string) bool {
	return type_str.starts_with('[]')
}

// is_map_type checks if a type string represents a map type (starts with `map[`).
fn (t &Transformer) is_map_type(type_str string) bool {
	return type_str.starts_with('map[')
}

// array_elem_type extracts the element type from an array type string.
// `[]int` -> `int`, `[][]string` -> `[]string`.
fn (t &Transformer) array_elem_type(type_str string) string {
	if type_str.starts_with('[]') {
		return type_str[2..]
	}
	return ''
}

// map_value_type extracts the value type from a map type string.
// `map[string]int` -> `int`, `map[string][]bool` -> `[]bool`.
fn (t &Transformer) map_value_type(type_str string) string {
	if !type_str.starts_with('map[') {
		return ''
	}
	bracket_end := type_str.index(']') or { return '' }
	if bracket_end + 1 < type_str.len {
		return type_str[bracket_end + 1..]
	}
	return ''
}

// map_key_type extracts the key type from a map type string.
// `map[string]int` -> `string`, `map[int]bool` -> `int`.
fn (t &Transformer) map_key_type(type_str string) string {
	if !type_str.starts_with('map[') {
		return ''
	}
	bracket_end := type_str.index(']') or { return '' }
	if bracket_end > 4 {
		return type_str[4..bracket_end]
	}
	return ''
}
