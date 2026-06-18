module transform

import v3.flat

// transform_struct_fields transforms struct initialization fields with enum resolution.
// For each .field_init child, transforms the value expression. If the struct field type
// is a known enum, resolves shorthand enum values (e.g. `.red` -> `Color.red`).
fn (mut t Transformer) transform_struct_fields(id flat.NodeId, node flat.Node) flat.NodeId {
	if node.children_count == 0 {
		return id
	}
	info := t.structs[node.value] or {
		// Unknown struct: fall back to generic child transform
		return t.transform_struct_children(id, node)
	}
	// Build a field name -> type lookup from the struct definition
	mut field_types := map[string]string{}
	for f in info.fields {
		field_types[f.name] = f.typ
	}
	mut field_ids := []flat.NodeId{}
	for i in 0 .. node.children_count {
		child_id := t.a.child(&node, i)
		child := t.a.nodes[int(child_id)]
		if child.kind == .field_init && child.children_count > 0 {
			val_id := t.a.child(&child, 0)
			val_node := t.a.nodes[int(val_id)]
			field_type := field_types[child.value] or { '' }
			// Check if the value is an enum shorthand and the field type is an enum
			new_val := if val_node.kind == .enum_val && field_type.len > 0
				&& field_type in t.enum_types {
				t.transform_enum_shorthand(val_id, val_node, field_type)
			} else {
				t.transform_expr(val_id)
			}
			fi_start := t.a.children.len
			t.a.children << new_val
			field_ids << t.a.add_node(flat.Node{
				kind:           .field_init
				op:             child.op
				children_start: fi_start
				children_count: 1
				pos:            child.pos
				value:          child.value
				typ:            child.typ
			})
		} else {
			field_ids << child_id
		}
	}
	start := t.a.children.len
	for fid in field_ids {
		t.a.children << fid
	}
	return t.a.add_node(flat.Node{
		kind:           .struct_init
		op:             node.op
		children_start: start
		children_count: field_ids.len
		pos:            node.pos
		value:          node.value
		typ:            node.typ
	})
}

// transform_struct_children is a fallback for struct inits where the struct type is unknown.
// Transforms all field_init value expressions without enum resolution.
fn (mut t Transformer) transform_struct_children(id flat.NodeId, node flat.Node) flat.NodeId {
	if node.children_count == 0 {
		return id
	}
	mut field_ids := []flat.NodeId{}
	for i in 0 .. node.children_count {
		child_id := t.a.child(&node, i)
		child := t.a.nodes[int(child_id)]
		if child.kind == .field_init && child.children_count > 0 {
			val_id := t.a.child(&child, 0)
			new_val := t.transform_expr(val_id)
			fi_start := t.a.children.len
			t.a.children << new_val
			field_ids << t.a.add_node(flat.Node{
				kind:           .field_init
				op:             child.op
				children_start: fi_start
				children_count: 1
				pos:            child.pos
				value:          child.value
				typ:            child.typ
			})
		} else {
			field_ids << child_id
		}
	}
	start := t.a.children.len
	for fid in field_ids {
		t.a.children << fid
	}
	return t.a.add_node(flat.Node{
		kind:           .struct_init
		op:             node.op
		children_start: start
		children_count: field_ids.len
		pos:            node.pos
		value:          node.value
		typ:            node.typ
	})
}

// add_missing_struct_defaults checks if any fields with default values are missing
// from the struct initialization. This is a hook point for future default-fill logic.
// Currently returns the node unchanged because StructInfo does not yet store default values.
fn (mut t Transformer) add_missing_struct_defaults(id flat.NodeId, node flat.Node) flat.NodeId {
	if node.value.len == 0 {
		return id
	}
	_ = t.structs[node.value] or { return id }
	// TODO: Compare provided field_init children against known fields,
	// and insert default values for missing fields once FieldInfo carries defaults.
	return id
}

// transform_array_init_expr transforms .array_init nodes (e.g. `[]int{len: n}`).
// Recursively transforms any child expressions (len, cap, init values).
fn (mut t Transformer) transform_array_init_expr(id flat.NodeId, node flat.Node) flat.NodeId {
	lowered := t.lower_array_init_to_runtime(id, node)
	if lowered != id {
		return lowered
	}
	if node.children_count == 0 {
		return id
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
		kind:           .array_init
		op:             node.op
		children_start: start
		children_count: node.children_count
		pos:            node.pos
		value:          node.value
		typ:            node.typ
	})
}

// transform_map_init_expr transforms .map_init nodes.
// Recursively transforms all child key/value expressions.
fn (mut t Transformer) transform_map_init_expr(id flat.NodeId, node flat.Node) flat.NodeId {
	if node.value.starts_with('map[') || node.typ.starts_with('map[') {
		return t.lower_map_init_to_runtime(id, node)
	}
	if node.children_count == 0 {
		return id
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
		kind:           .map_init
		op:             node.op
		children_start: start
		children_count: node.children_count
		pos:            node.pos
		value:          node.value
		typ:            node.typ
	})
}
