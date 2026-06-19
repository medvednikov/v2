module transform

import v3.flat
import v3.types

// is_generic_fn checks if a function name refers to a generic function.
fn (mut t Transformer) is_generic_fn(name string) bool {
	return name in t.generic_fns
}

// is_generic_struct checks if a struct name is generic.
fn (mut t Transformer) is_generic_struct(name string) bool {
	return name in t.generic_structs
}

// monomorphize_pass is the top-level generic monomorphization pass.
// Uses a worklist: scan, instantiate, then rescan cloned declarations
// to discover transitive generic uses, repeating until no new
// instantiations are found.
fn (mut t Transformer) monomorphize_pass() {
	if t.generic_fns.len == 0 && t.generic_structs.len == 0 {
		return
	}

	// Track all call/struct-init sites that need rewriting (node_idx -> mangled_name)
	mut call_rewrites := map[int]string{}
	mut struct_init_rewrites := map[int]string{}

	// Worklist loop: keep scanning until no new instantiations are found.
	// scan_start tracks where to begin scanning on each iteration (new clones
	// are appended past the previous end).
	mut scan_start := 0
	for round := 0; round < 64; round++ {
		mut fn_instances := map[string][]string{}
		mut struct_instances := map[string][]string{}
		mut fn_instance_keys := map[string]string{}
		mut struct_instance_keys := map[string]string{}
		scan_end := t.a.nodes.len

		for ni in scan_start .. scan_end {
			node := t.a.nodes[ni]
			if node.kind == .call && node.children_count > 0 {
				t.scan_call_for_generics(ni, node, mut fn_instances, mut fn_instance_keys, mut
					call_rewrites)
			}
			if node.kind == .struct_init {
				t.scan_struct_init_for_generics(ni, node, mut struct_instances, mut
					struct_instance_keys, mut struct_init_rewrites)
			}
			if node.kind == .decl_assign {
				t.scan_decl_for_generic_structs(node, mut struct_instances, mut
					struct_instance_keys)
			}
		}

		if fn_instances.len == 0 && struct_instances.len == 0 {
			break
		}

		// Find module context for appended clones: insert a module_decl marker
		// before each batch of cloned declarations so codegen/markused attributes
		// them to the correct module.
		for mangled, type_args in struct_instances {
			generic_key := struct_instance_keys[mangled]
			info := t.generic_structs[generic_key] or { continue }
			t.insert_module_marker(info.module_name)
			t.instantiate_struct(mangled, generic_key, info, type_args)
		}
		for mangled, type_args in fn_instances {
			generic_key := fn_instance_keys[mangled]
			info := t.generic_fns[generic_key] or { continue }
			t.insert_module_marker(info.module_name)
			t.instantiate_fn(mangled, generic_key, info, type_args)
		}

		scan_start = scan_end
	}

	// Rewrite call sites to use mangled names
	for ni, mangled in call_rewrites {
		t.rewrite_call_site(ni, mangled)
	}

	// Rewrite struct init sites
	for ni, mangled in struct_init_rewrites {
		node := t.a.nodes[ni]
		if node.kind == .struct_init {
			short_mangled := short_name(mangled)
			t.a.nodes[ni] = flat.Node{
				kind:           node.kind
				op:             node.op
				children_start: node.children_start
				children_count: node.children_count
				pos:            node.pos
				value:          short_mangled
				typ:            node.typ
			}
		}
	}

	// Mark original generic declarations as empty
	for _, info in t.generic_fns {
		if info.node_idx >= 0 && info.node_idx < t.a.nodes.len {
			t.a.nodes[info.node_idx] = flat.Node{
				kind: .empty
			}
		}
	}
	for _, info in t.generic_structs {
		if info.node_idx >= 0 && info.node_idx < t.a.nodes.len {
			t.a.nodes[info.node_idx] = flat.Node{
				kind: .empty
			}
		}
	}
}

// scan_call_for_generics checks a call node for generic function usage,
// handling both inferred calls (ident child) and explicit generic calls
// where the parser produces an index node like id[int](args).
fn (mut t Transformer) scan_call_for_generics(ni int, node flat.Node, mut fn_instances map[string][]string, mut fn_instance_keys map[string]string, mut call_rewrites map[int]string) {
	fn_node := t.a.child_node(&node, 0)

	if fn_node.kind == .ident {
		call_name := fn_node.value
		t.try_match_generic_fn(ni, node, call_name, mut fn_instances, mut fn_instance_keys, mut
			call_rewrites)
		// Also check qualified name
		if t.tc != unsafe { nil } {
			qname := t.qualify_call_name(call_name)
			if qname != call_name {
				t.try_match_generic_fn(ni, node, qname, mut fn_instances, mut fn_instance_keys, mut
					call_rewrites)
			}
		}
		return
	}

	// Handle explicit generic calls: id[int](args)
	// The parser produces: call -> [index -> [ident("id"), ident("int")], arg1, ...]
	if fn_node.kind == .index && fn_node.children_count >= 2 {
		base := t.a.child_node(fn_node, 0)
		if base.kind == .ident {
			call_name := base.value
			// Look up the generic fn
			lookup := t.resolve_generic_fn_key(call_name)
			if lookup.len > 0 {
				if info := t.generic_fns[lookup] {
					// Extract explicit type args from the index children
					mut type_args := []string{}
					for ci in 1 .. fn_node.children_count {
						arg_node := t.a.child_node(fn_node, ci)
						if arg_node.kind == .ident {
							type_args << arg_node.value
						} else if arg_node.value.len > 0 {
							type_args << arg_node.value
						} else if arg_node.typ.len > 0 {
							type_args << arg_node.typ
						}
					}
					if type_args.len == info.type_params.len {
						mangled := mangle_name(lookup, info.type_params, type_args)
						fn_instances[mangled] = type_args
						fn_instance_keys[mangled] = lookup
						call_rewrites[ni] = mangled
					}
				}
			}
		}
	}
}

fn (mut t Transformer) try_match_generic_fn(ni int, node flat.Node, call_name string, mut fn_instances map[string][]string, mut fn_instance_keys map[string]string, mut call_rewrites map[int]string) {
	if info := t.generic_fns[call_name] {
		type_args := t.infer_fn_type_args(node, info)
		if type_args.len == info.type_params.len {
			mangled := mangle_name(call_name, info.type_params, type_args)
			fn_instances[mangled] = type_args
			fn_instance_keys[mangled] = call_name
			call_rewrites[ni] = mangled
		}
	}
}

fn (mut t Transformer) scan_struct_init_for_generics(ni int, node flat.Node, mut struct_instances map[string][]string, mut struct_instance_keys map[string]string, mut struct_init_rewrites map[int]string) {
	struct_name := node.value
	if !struct_name.contains('[') || struct_name.starts_with('[') {
		return
	}
	bracket := struct_name.index_u8(`[`)
	bracket_end := types.find_matching_bracket_pub(struct_name, int(bracket))
	if bracket_end <= int(bracket) {
		return
	}
	base_name := struct_name[..bracket]
	inner := struct_name[bracket + 1..bracket_end]
	lookup := t.resolve_generic_struct_key(base_name)
	if lookup.len == 0 {
		return
	}
	if info := t.generic_structs[lookup] {
		parts := types.split_params_pub(inner)
		mut type_args := []string{}
		for p in parts {
			type_args << p.trim_space()
		}
		if type_args.len == info.type_params.len {
			mangled := mangle_name(lookup, info.type_params, type_args)
			struct_instances[mangled] = type_args
			struct_instance_keys[mangled] = lookup
			struct_init_rewrites[ni] = mangled
		}
	}
}

fn (mut t Transformer) scan_decl_for_generic_structs(node flat.Node, mut struct_instances map[string][]string, mut struct_instance_keys map[string]string) {
	if !node.typ.contains('[') || node.typ.starts_with('[') || node.typ.starts_with('[]')
		|| node.typ.starts_with('map[') {
		return
	}
	bracket := node.typ.index_u8(`[`)
	bracket_end := types.find_matching_bracket_pub(node.typ, int(bracket))
	if bracket_end <= int(bracket) {
		return
	}
	base_name := node.typ[..bracket]
	inner := node.typ[bracket + 1..bracket_end]
	lookup := t.resolve_generic_struct_key(base_name)
	if lookup.len == 0 {
		return
	}
	if info := t.generic_structs[lookup] {
		parts := types.split_params_pub(inner)
		mut type_args := []string{}
		for p in parts {
			type_args << p.trim_space()
		}
		if type_args.len == info.type_params.len {
			mangled := mangle_name(lookup, info.type_params, type_args)
			struct_instances[mangled] = type_args
			struct_instance_keys[mangled] = lookup
		}
	}
}

fn (mut t Transformer) resolve_generic_fn_key(name string) string {
	if name in t.generic_fns {
		return name
	}
	if t.tc != unsafe { nil } {
		qname := t.qualify_call_name(name)
		if qname in t.generic_fns {
			return qname
		}
	}
	return ''
}

fn (mut t Transformer) resolve_generic_struct_key(name string) string {
	qbase := t.qualify_struct_name(name)
	if qbase in t.generic_structs {
		return qbase
	}
	if name in t.generic_structs {
		return name
	}
	return ''
}

// rewrite_call_site rewrites a call node's callee to the mangled concrete name.
// Handles both simple ident callees and explicit generic index callees.
fn (mut t Transformer) rewrite_call_site(ni int, mangled string) {
	node := t.a.nodes[ni]
	if node.kind != .call || node.children_count == 0 {
		return
	}
	fn_child_id := t.a.child(&node, 0)
	if int(fn_child_id) < 0 {
		return
	}
	fn_child := t.a.nodes[int(fn_child_id)]
	sm := short_name(mangled)

	if fn_child.kind == .ident {
		t.a.nodes[int(fn_child_id)] = flat.Node{
			kind:           fn_child.kind
			op:             fn_child.op
			children_start: fn_child.children_start
			children_count: fn_child.children_count
			pos:            fn_child.pos
			value:          sm
			typ:            fn_child.typ
		}
		return
	}
	// Explicit generic call: replace the index node with a plain ident
	if fn_child.kind == .index {
		t.a.nodes[int(fn_child_id)] = flat.Node{
			kind:  .ident
			pos:   fn_child.pos
			value: sm
		}
	}
}

// insert_module_marker appends a module_decl node so that subsequent
// cloned declarations are attributed to the correct module.
fn (mut t Transformer) insert_module_marker(mod string) {
	if mod.len == 0 {
		return
	}
	t.a.add_val(.module_decl, mod)
}

fn short_name(mangled string) string {
	if mangled.contains('.') {
		return mangled.all_after_last('.')
	}
	return mangled
}

// instantiate_fn clones a generic function, substituting type parameters
// with concrete types, and appends the new concrete function to the AST.
fn (mut t Transformer) instantiate_fn(mangled string, _ string, info GenericFnInfo, type_args []string) {
	if mangled in t.instantiated {
		return
	}
	t.instantiated[mangled] = true

	src_node := t.a.nodes[info.node_idx]
	if src_node.kind != .fn_decl {
		return
	}

	// Build substitution map: type_param -> concrete_type
	mut bindings := map[string]string{}
	for i, tp in info.type_params {
		if i < type_args.len {
			bindings[tp] = type_args[i]
		}
	}

	// Get mangled short name (without module prefix)
	short_mangled := if mangled.contains('.') {
		mangled.all_after_last('.')
	} else {
		mangled
	}

	// Clone all children, remapping indices and substituting types
	mut new_child_ids := []flat.NodeId{}
	for i in 0 .. src_node.children_count {
		old_child_id := t.a.child(&src_node, i)
		new_child_id := t.clone_node_with_subs(old_child_id, bindings)
		new_child_ids << new_child_id
	}

	start := t.a.children.len
	for id in new_child_ids {
		t.a.children << id
	}

	// Substitute the return type
	new_ret_type := substitute_type_string(src_node.typ, bindings)

	t.a.add_node(flat.Node{
		kind:           .fn_decl
		op:             src_node.op
		children_start: start
		children_count: flat.child_count(new_child_ids.len)
		pos:            src_node.pos
		value:          short_mangled
		typ:            new_ret_type
	})

	// Register in fn_ret_types so the checker/codegen can find it
	t.fn_ret_types[short_mangled] = new_ret_type
	if info.module_name.len > 0 && info.module_name != 'main' && info.module_name != 'builtin' {
		t.fn_ret_types['${info.module_name}.${short_mangled}'] = new_ret_type
	}
}

// instantiate_struct clones a generic struct, substituting type parameters
// with concrete types, and appends the new concrete struct to the AST.
fn (mut t Transformer) instantiate_struct(mangled string, _ string, info GenericStructInfo, type_args []string) {
	if mangled in t.instantiated {
		return
	}
	t.instantiated[mangled] = true

	src_node := t.a.nodes[info.node_idx]
	if src_node.kind != .struct_decl {
		return
	}

	// Build substitution map
	mut bindings := map[string]string{}
	for i, tp in info.type_params {
		if i < type_args.len {
			bindings[tp] = type_args[i]
		}
	}

	short_mangled := if mangled.contains('.') {
		mangled.all_after_last('.')
	} else {
		mangled
	}

	// Clone field declarations with type substitution
	mut new_child_ids := []flat.NodeId{}
	for i in 0 .. src_node.children_count {
		old_child_id := t.a.child(&src_node, i)
		new_child_id := t.clone_node_with_subs(old_child_id, bindings)
		new_child_ids << new_child_id
	}

	start := t.a.children.len
	for id in new_child_ids {
		t.a.children << id
	}

	new_typ := if src_node.typ == 'union' { 'union' } else { '' }

	t.a.add_node(flat.Node{
		kind:           .struct_decl
		op:             src_node.op
		children_start: start
		children_count: flat.child_count(new_child_ids.len)
		pos:            src_node.pos
		value:          short_mangled
		typ:            new_typ
	})

	// Register in structs map
	mut fields := []FieldInfo{}
	for i in 0 .. src_node.children_count {
		f := t.a.child_node(&src_node, i)
		if f.kind != .field_decl {
			continue
		}
		fields << FieldInfo{
			name: f.value
			typ:  substitute_type_string(f.typ, bindings)
		}
	}
	si := StructInfo{
		name:   short_mangled
		module: info.module_name
		fields: fields
	}
	t.structs[short_mangled] = si
	if info.module_name.len > 0 && info.module_name != 'main' && info.module_name != 'builtin' {
		t.structs['${info.module_name}.${short_mangled}'] = si
	}
}

// clone_node_with_subs deep-clones a node subtree, applying type substitutions.
fn (mut t Transformer) clone_node_with_subs(id flat.NodeId, bindings map[string]string) flat.NodeId {
	if int(id) < 0 {
		return id
	}
	node := t.a.nodes[int(id)]

	// Clone children recursively
	mut new_child_ids := []flat.NodeId{}
	for i in 0 .. node.children_count {
		old_child := t.a.child(&node, i)
		new_child_ids << t.clone_node_with_subs(old_child, bindings)
	}

	mut new_start := node.children_start
	if new_child_ids.len > 0 {
		new_start = t.a.children.len
		for cid in new_child_ids {
			t.a.children << cid
		}
	}

	new_typ := substitute_type_string(node.typ, bindings)
	new_value := substitute_value_string(node.value, node.kind, bindings)

	return t.a.add_node(flat.Node{
		kind:           node.kind
		op:             node.op
		children_start: new_start
		children_count: node.children_count
		pos:            node.pos
		value:          new_value
		typ:            new_typ
	})
}

// substitute_type_string replaces generic type parameter names with concrete
// types in a type string. Uses whole-word matching to avoid replacing 'T'
// inside 'Type'.
fn substitute_type_string(typ string, bindings map[string]string) string {
	if typ.len == 0 || bindings.len == 0 {
		return typ
	}
	mut result := typ
	for param, concrete in bindings {
		result = replace_type_param(result, param, concrete)
	}
	return result
}

// substitute_value_string replaces type param names in node values that
// represent types (e.g., struct init names like "Box[T]").
fn substitute_value_string(value string, kind flat.NodeKind, bindings map[string]string) string {
	if value.len == 0 || bindings.len == 0 {
		return value
	}
	// For struct_init and certain other nodes, the value may contain type references
	if kind in [.struct_init, .cast_expr, .is_expr, .as_expr] {
		return substitute_type_string(value, bindings)
	}
	return value
}

// replace_type_param replaces whole-word occurrences of a type parameter
// name with the concrete type in a type string.
fn replace_type_param(typ string, param string, concrete string) string {
	if typ.len == 0 || param.len == 0 {
		return typ
	}
	// Quick check: if the param doesn't appear at all, return early
	if !typ.contains(param) {
		return typ
	}
	// Simple case: the entire string is the param
	if typ == param {
		return concrete
	}
	// Walk through and replace whole-word occurrences
	mut result := []u8{cap: typ.len + 16}
	mut i := 0
	for i < typ.len {
		if i + param.len <= typ.len && typ[i..i + param.len] == param {
			// Check word boundaries
			before_ok := i == 0 || !is_ident_char(typ[i - 1])
			after_ok := i + param.len >= typ.len || !is_ident_char(typ[i + param.len])
			if before_ok && after_ok {
				for c in concrete {
					result << c
				}
				i += param.len
				continue
			}
		}
		result << typ[i]
		i++
	}
	return result.bytestr()
}

fn is_ident_char(c u8) bool {
	return (c >= `a` && c <= `z`) || (c >= `A` && c <= `Z`) || (c >= `0` && c <= `9`) || c == `_`
}

// mangle_name generates a mangled name for a generic instantiation.
// E.g., "id" with params ["T"] and args ["int"] -> "id_T_int"
// E.g., "Box" with params ["T"] and args ["int"] -> "Box_T_int"
fn mangle_name(base string, type_params []string, type_args []string) string {
	mut name := base
	for i, tp in type_params {
		if i < type_args.len {
			arg := type_args[i].replace('[]', 'Array_').replace('[', '_').replace(']', '').replace('.', '_').replace('&',
				'ref_').replace(' ', '')
			name += '_${tp}_${arg}'
		}
	}
	return name
}

// infer_fn_type_args tries to infer the concrete type arguments for a generic
// function call from the argument types at the call site.
fn (mut t Transformer) infer_fn_type_args(call_node flat.Node, info GenericFnInfo) []string {
	src_node := t.a.nodes[info.node_idx]
	if src_node.kind != .fn_decl {
		return []string{}
	}

	// Collect param types from the generic fn declaration
	mut param_types := []string{}
	for i in 0 .. src_node.children_count {
		child := t.a.child_node(&src_node, i)
		if child.kind == .param {
			param_types << child.typ
		}
	}

	// Try to match each type param to a concrete type from call args
	mut bindings := map[string]string{}
	// Call args start at index 1 (index 0 is the fn ident/selector)
	mut arg_idx := 0
	for pi, ptyp in param_types {
		// Skip receiver for methods (first param is receiver)
		call_arg_idx := pi + 1 // +1 because child 0 is the fn name
		if call_arg_idx >= call_node.children_count {
			break
		}
		arg_id := t.a.child(&call_node, call_arg_idx)
		arg_type := t.node_type(arg_id)
		if arg_type.len == 0 {
			continue
		}
		// Try to bind type params from this param-argument pair
		bind_type_params(ptyp, arg_type, info.type_params, mut bindings)
		arg_idx++
	}

	// Build the result in type_params order
	mut result := []string{}
	for tp in info.type_params {
		if concrete := bindings[tp] {
			result << concrete
		} else {
			// Could not infer this type param
			return []string{}
		}
	}
	return result
}

// bind_type_params tries to match a parameter type pattern against a concrete
// argument type and extract bindings for type parameters.
// Handles direct params, arrays, pointers, options, results, maps, and
// generic struct patterns like Box[T] against Box[int].
fn bind_type_params(pattern string, concrete string, type_params []string, mut bindings map[string]string) {
	if pattern.len == 0 || concrete.len == 0 {
		return
	}
	// Direct match: pattern is a type param
	for tp in type_params {
		if pattern == tp {
			if tp !in bindings {
				bindings[tp] = concrete
			}
			return
		}
	}
	// Array pattern: []T vs []int
	if pattern.starts_with('[]') && concrete.starts_with('[]') {
		bind_type_params(pattern[2..], concrete[2..], type_params, mut bindings)
		return
	}
	// Pointer pattern: &T vs &int
	if pattern.starts_with('&') && concrete.starts_with('&') {
		bind_type_params(pattern[1..], concrete[1..], type_params, mut bindings)
		return
	}
	// Option pattern: ?T vs ?int
	if pattern.starts_with('?') && concrete.starts_with('?') {
		bind_type_params(pattern[1..], concrete[1..], type_params, mut bindings)
		return
	}
	// Result pattern: !T vs !int
	if pattern.starts_with('!') && concrete.starts_with('!') {
		bind_type_params(pattern[1..], concrete[1..], type_params, mut bindings)
		return
	}
	// Map pattern: map[K]V vs map[string]int
	if pattern.starts_with('map[') && concrete.starts_with('map[') {
		p_bracket := types.find_matching_bracket_pub(pattern, 3)
		c_bracket := types.find_matching_bracket_pub(concrete, 3)
		if p_bracket > 3 && c_bracket > 3 {
			bind_type_params(pattern[4..p_bracket], concrete[4..c_bracket], type_params, mut
				bindings)
			if p_bracket + 1 < pattern.len && c_bracket + 1 < concrete.len {
				bind_type_params(pattern[p_bracket + 1..], concrete[c_bracket + 1..], type_params, mut
					bindings)
			}
		}
		return
	}
	// Generic struct pattern: Box[T] vs Box[int], Pair[A, B] vs Pair[int, string]
	if pattern.contains('[') && concrete.contains('[') {
		p_bracket := pattern.index_u8(`[`)
		c_bracket := concrete.index_u8(`[`)
		if p_bracket > 0 && c_bracket > 0 {
			p_base := pattern[..p_bracket]
			c_base := concrete[..c_bracket]
			if p_base == c_base {
				p_end := types.find_matching_bracket_pub(pattern, int(p_bracket))
				c_end := types.find_matching_bracket_pub(concrete, int(c_bracket))
				if p_end > int(p_bracket) && c_end > int(c_bracket) {
					p_params := types.split_params_pub(pattern[p_bracket + 1..p_end])
					c_params := types.split_params_pub(concrete[c_bracket + 1..c_end])
					for i, pp in p_params {
						if i < c_params.len {
							bind_type_params(pp.trim_space(), c_params[i].trim_space(),
								type_params, mut bindings)
						}
					}
				}
			}
		}
	}
}

fn (t &Transformer) qualify_call_name(name string) string {
	if t.cur_module.len == 0 || t.cur_module == 'main' || t.cur_module == 'builtin' {
		return name
	}
	if name.contains('.') {
		return name
	}
	return '${t.cur_module}.${name}'
}

fn (t &Transformer) qualify_struct_name(name string) string {
	if t.cur_module.len == 0 || t.cur_module == 'main' || t.cur_module == 'builtin' {
		return name
	}
	if name.contains('.') {
		return name
	}
	return '${t.cur_module}.${name}'
}
