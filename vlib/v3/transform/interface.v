module transform

import v3.flat

// is_interface_type checks if a type name is a known interface.
// Currently returns false as interface tracking is not yet connected
// to the TypeChecker. Will be wired up when interface declarations
// are collected during the type collection pass.
fn (t &Transformer) is_interface_type(name string) bool {
	// TODO: Connect to TypeChecker or add interface_types map to Transformer
	// once interface_decl nodes are collected in collect_types.
	return false
}

// transform_interface_cast transforms interface-to-concrete type casts.
// This is a hook for future interface dispatch lowering where interface
// values need to be unwrapped to their concrete types.
// Currently passes through unchanged.
fn (mut t Transformer) transform_interface_cast(id flat.NodeId, node flat.Node) flat.NodeId {
	if node.children_count == 0 {
		return id
	}
	// TODO: When interface lowering is implemented, this will:
	// 1. Identify the concrete type from the cast target
	// 2. Generate the appropriate vtable lookup + pointer unwrap
	// 3. Return a transformed node that accesses the inner value
	start := t.a.children.len
	for i in 0 .. node.children_count {
		child_id := t.a.child(&node, i)
		t.a.children << t.transform_expr(child_id)
	}
	return t.a.add_node(flat.Node{
		kind:           node.kind
		op:             node.op
		children_start: start
		children_count: node.children_count
		pos:            node.pos
		value:          node.value
		typ:            node.typ
	})
}

// transform_interface_method_call transforms method calls on interface values.
// This is a hook for vtable dispatch lowering where `iface.method(args)`
// needs to be rewritten to indirect calls through the interface vtable.
// Currently passes through unchanged.
fn (mut t Transformer) transform_interface_method_call(id flat.NodeId, node flat.Node) flat.NodeId {
	if node.children_count == 0 {
		return id
	}
	// TODO: When interface dispatch is implemented, this will:
	// 1. Detect that the receiver is an interface type
	// 2. Look up the method index in the interface vtable
	// 3. Rewrite to: ((vtable_type*)iface._vtable)->method(iface._object, args)
	start := t.a.children.len
	for i in 0 .. node.children_count {
		child_id := t.a.child(&node, i)
		t.a.children << t.transform_expr(child_id)
	}
	return t.a.add_node(flat.Node{
		kind:           node.kind
		op:             node.op
		children_start: start
		children_count: node.children_count
		pos:            node.pos
		value:          node.value
		typ:            node.typ
	})
}
