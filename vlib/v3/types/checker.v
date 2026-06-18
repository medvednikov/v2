module types

import v3.flat

fn tarr1(a Type) []Type {
	mut r := []Type{}
	r << a
	return r
}

fn tarr2(a Type, b Type) []Type {
	mut r := []Type{}
	r << a
	r << b
	return r
}

fn tarr3(a Type, b Type, c Type) []Type {
	mut r := []Type{}
	r << a
	r << b
	r << c
	return r
}

pub struct TypeError {
pub:
	msg  string
	kind TypeErrorKind
	node flat.NodeId
}

pub enum TypeErrorKind {
	unknown_ident
	unknown_fn
	unknown_field
	cannot_index
	if_branch_mismatch
	unhandled_node
}

@[heap]
pub struct TypeChecker {
pub mut:
	a               &flat.FlatAst = unsafe { nil }
	fn_ret_types    map[string]Type
	fn_param_types  map[string][]Type
	structs         map[string][]StructField
	type_aliases    map[string]string
	sum_types       map[string][]string
	enum_names      map[string]bool
	flag_enums      map[string]bool
	interface_names map[string]bool
	const_types     map[string]Type
	imports         map[string]string // alias -> short module name
	file_scope      &Scope = unsafe { nil }
	cur_scope       &Scope = unsafe { nil }
	has_builtins    bool
	cur_module      string
	errors          []TypeError
	resolved_calls  map[int]string // node_id -> resolved function name
	expr_types      map[int]Type   // node_id -> resolved type (populated by annotate_types)
}

pub fn TypeChecker.new(a &flat.FlatAst) TypeChecker {
	fs := new_scope(unsafe { nil })
	return TypeChecker{
		a:          a
		file_scope: fs
		cur_scope:  fs
	}
}

pub fn (mut tc TypeChecker) push_scope() {
	tc.cur_scope = new_scope(tc.cur_scope)
}

pub fn (mut tc TypeChecker) pop_scope() {
	tc.cur_scope = tc.cur_scope.parent
}

fn (mut tc TypeChecker) record_error(kind TypeErrorKind, msg string, node flat.NodeId) {
	tc.errors << TypeError{
		msg:  msg
		kind: kind
		node: node
	}
}

pub fn (mut tc TypeChecker) collect(a &flat.FlatAst) {
	tc.a = a
	tc.file_scope = new_scope(unsafe { nil })
	tc.cur_scope = tc.file_scope
	for node in a.nodes {
		if node.kind == .struct_decl && node.value == 'string' {
			tc.has_builtins = true
			break
		}
	}
	// Pass 1: collect type-level names (aliases, enums, sum types)
	for node in a.nodes {
		match node.kind {
			.file {
				tc.cur_module = ''
			}
			.module_decl {
				tc.cur_module = node.value
			}
			.import_decl {
				mod := if node.value.contains('.') {
					node.value.all_after_last('.')
				} else {
					node.value
				}
				tc.imports[node.typ] = mod
			}
			.enum_decl {
				qn := tc.qualify_name(node.value)
				tc.enum_names[qn] = true
				if node.typ == 'flag' {
					tc.flag_enums[qn] = true
				}
			}
			.type_decl {
				if node.children_count > 0 {
					mut variants := []string{}
					for i in 0 .. node.children_count {
						v := a.child_node(&node, i)
						variants << tc.qualify_name(v.value)
					}
					tc.sum_types[tc.qualify_name(node.value)] = variants
				} else if node.typ.len > 0 {
					tc.type_aliases[tc.qualify_name(node.value)] = node.typ
				}
			}
			.interface_decl {
				tc.interface_names[tc.qualify_name(node.value)] = true
			}
			else {}
		}
	}
	// Pass 2: collect struct fields, function signatures (type aliases now available)
	tc.cur_module = ''
	for node in a.nodes {
		match node.kind {
			.module_decl {
				tc.cur_module = node.value
			}
			.fn_decl {
				qname := tc.qualify_fn_name(node.value)
				tc.fn_ret_types[qname] = tc.parse_type(node.typ)
				if qname != node.value && node.value !in tc.fn_ret_types {
					tc.fn_ret_types[node.value] = tc.parse_type(node.typ)
				}
				mut ptypes := []Type{}
				for i in 0 .. node.children_count {
					child := a.child_node(&node, i)
					if child.kind == .param {
						ptypes << tc.parse_type(child.typ)
					}
				}
				tc.fn_param_types[qname] = ptypes
				if qname != node.value && node.value !in tc.fn_param_types {
					tc.fn_param_types[node.value] = ptypes
				}
			}
			.struct_decl {
				if node.value.starts_with('C.') {
					continue
				}
				mut fields := []StructField{}
				for i in 0 .. node.children_count {
					f := a.child_node(&node, i)
					if f.kind != .field_decl {
						continue
					}
					fields << StructField{
						name: f.value
						typ:  tc.parse_type(f.typ)
					}
				}
				tc.structs[tc.qualify_name(node.value)] = fields
			}
			.c_fn_decl {
				tc.fn_ret_types[node.value] = tc.parse_type(node.typ)
				mut ptypes := []Type{}
				for i in 0 .. node.children_count {
					child := a.child_node(&node, i)
					if child.kind == .param {
						ptypes << tc.parse_type(child.typ)
					}
				}
				tc.fn_param_types[node.value] = ptypes
			}
			.interface_decl {
				iface_name := tc.qualify_name(node.value)
				for i in 0 .. node.children_count {
					f := a.child_node(&node, i)
					if f.kind == .interface_field {
						mname := '${iface_name}.${f.value}'
						tc.fn_ret_types[mname] = tc.parse_type(f.typ)
						mut ptypes := []Type{}
						ptypes << Type(Pointer{
							base_type: Type(Struct{
								name: iface_name
							})
						})
						for j in 0 .. f.children_count {
							child := a.child_node(f, j)
							if child.kind == .param {
								ptypes << tc.parse_type(child.typ)
							}
						}
						tc.fn_param_types[mname] = ptypes
					}
				}
			}
			.global_decl {
				for i in 0 .. node.children_count {
					f := a.child_node(&node, i)
					if f.value.len > 0 && !f.value.starts_with('C.') {
						mut ft := tc.parse_type(f.typ)
						if ft is Void && f.children_count > 0 {
							ft = tc.resolve_type(a.child(f, 0))
						}
						tc.file_scope.insert(f.value, ft)
						qname := tc.qualify_name(f.value)
						if qname != f.value {
							tc.file_scope.insert(qname, ft)
						}
					}
				}
			}
			.const_decl {
				for i in 0 .. node.children_count {
					f := a.child_node(&node, i)
					if f.kind == .const_field && f.children_count > 0 {
						val_type := tc.resolve_type(a.child(f, 0))
						qname := tc.qualify_name(f.value)
						tc.const_types[qname] = val_type
					}
				}
			}
			else {}
		}
	}
	tc.register_runtime_methods()
}

pub fn (tc &TypeChecker) qualify_fn_name(name string) string {
	if tc.cur_module.len == 0 || tc.cur_module == 'main' || tc.cur_module == 'builtin' {
		return name
	}
	return '${tc.cur_module}.${name}'
}

pub fn (tc &TypeChecker) qualify_name(name string) string {
	if tc.cur_module.len == 0 || tc.cur_module == 'main' || tc.cur_module == 'builtin' {
		return name
	}
	if name.starts_with('[]') {
		return '[]' + tc.qualify_name(name[2..])
	}
	if name.starts_with('[') {
		idx := name.index_u8(`]`)
		if idx > 0 {
			return name[..idx + 1] + tc.qualify_name(name[idx + 1..])
		}
	}
	if name.starts_with('map[') {
		bracket_end := find_matching_bracket(name, 3)
		key_str := name[4..bracket_end]
		val_str := name[bracket_end + 1..]
		return 'map[${tc.qualify_name(key_str)}]${tc.qualify_name(val_str)}'
	}
	if name.starts_with('&') {
		return '&' + tc.qualify_name(name[1..])
	}
	if name.starts_with('?') {
		return '?' + tc.qualify_name(name[1..])
	}
	if name.contains('.') {
		return name
	}
	if is_builtin_type_name(name) {
		return name
	}
	return tc.cur_module + '.' + name
}

fn (mut tc TypeChecker) register_runtime_methods() {
	tc.fn_ret_types['strings.new_builder'] = tc.parse_type('strings.Builder')
	tc.fn_param_types['strings.new_builder'] = tarr1(tc.parse_type('int'))
	tc.fn_ret_types['strings.Builder.str'] = tc.parse_type('string')
	tc.fn_param_types['strings.Builder.str'] = tarr1(tc.parse_type('&strings.Builder'))
	tc.fn_ret_types['strings.Builder.write_string'] = tc.parse_type('void')
	tc.fn_param_types['strings.Builder.write_string'] = tarr2(tc.parse_type('&strings.Builder'),
		tc.parse_type('string'))
	tc.fn_ret_types['strings.Builder.writeln'] = tc.parse_type('void')
	tc.fn_param_types['strings.Builder.writeln'] = tarr2(tc.parse_type('&strings.Builder'),
		tc.parse_type('string'))
	tc.fn_ret_types['strings.Builder.write_ptr'] = tc.parse_type('void')
	tc.fn_param_types['strings.Builder.write_ptr'] = tarr3(tc.parse_type('&strings.Builder'),
		tc.parse_type('voidptr'), tc.parse_type('int'))
	tc.fn_ret_types['strings.Builder.write_u8'] = tc.parse_type('void')
	tc.fn_param_types['strings.Builder.write_u8'] = tarr2(tc.parse_type('&strings.Builder'),
		tc.parse_type('u8'))
	tc.fn_ret_types['strings.Builder.free'] = tc.parse_type('void')
	tc.fn_param_types['strings.Builder.free'] = tarr1(tc.parse_type('&strings.Builder'))
	tc.fn_ret_types['check_fwrite'] = tc.parse_type('!int')
	tc.fn_param_types['check_fwrite'] = tarr1(tc.parse_type('int'))
	tc.fn_ret_types['os.check_fwrite'] = tc.parse_type('!int')
	tc.fn_ret_types['malloc_noscan'] = tc.parse_type('voidptr')
	tc.fn_ret_types['u8.vstring'] = tc.parse_type('string')
	tc.fn_ret_types['u8.vstring_with_len'] = tc.parse_type('string')
	tc.fn_ret_types['IError.msg'] = tc.parse_type('string')
	tc.fn_ret_types['IError.code'] = tc.parse_type('int')
	tc.fn_ret_types['string__plus'] = tc.parse_type('string')
	tc.fn_ret_types['string__eq'] = tc.parse_type('bool')
	tc.fn_ret_types['string__lt'] = tc.parse_type('bool')
	tc.fn_ret_types['string_plus_many'] = tc.parse_type('string')
	tc.fn_ret_types['bool_str'] = tc.parse_type('string')
	tc.fn_ret_types['strconv__format_int'] = tc.parse_type('string')
	tc.fn_ret_types['strconv__format_uint'] = tc.parse_type('string')
	tc.fn_ret_types['strconv__f32_to_str_l'] = tc.parse_type('string')
	tc.fn_ret_types['strconv__f64_to_str_l'] = tc.parse_type('string')
	tc.fn_param_types['bool_str'] = tarr1(tc.parse_type('bool'))
	tc.fn_param_types['strconv__format_int'] = tarr2(tc.parse_type('i64'), tc.parse_type('int'))
	tc.fn_param_types['strconv__format_uint'] = tarr2(tc.parse_type('u64'), tc.parse_type('int'))
	tc.fn_param_types['strconv__f32_to_str_l'] = tarr1(tc.parse_type('f32'))
	tc.fn_param_types['strconv__f64_to_str_l'] = tarr1(tc.parse_type('f64'))
	tc.fn_ret_types['string__bytes'] = tc.parse_type('[]u8')
	tc.fn_ret_types['string__int'] = tc.parse_type('int')
	tc.fn_ret_types['string__clone'] = tc.parse_type('string')
	tc.fn_ret_types['string__contains'] = tc.parse_type('bool')
	tc.fn_ret_types['string__split'] = tc.parse_type('[]string')
	tc.fn_ret_types['string__replace'] = tc.parse_type('string')
	tc.fn_ret_types['string__substr'] = tc.parse_type('string')
	tc.fn_ret_types['string__trim_space'] = tc.parse_type('string')
	tc.fn_ret_types['string__starts_with'] = tc.parse_type('bool')
	tc.fn_ret_types['string__ends_with'] = tc.parse_type('bool')
	tc.fn_ret_types['string__all_before'] = tc.parse_type('string')
	tc.fn_ret_types['string__all_after'] = tc.parse_type('string')
	tc.fn_ret_types['string__all_after_last'] = tc.parse_type('string')
	tc.fn_ret_types['string__all_before_last'] = tc.parse_type('string')
	tc.fn_ret_types['string__count'] = tc.parse_type('int')
	tc.fn_ret_types['string__index_u8'] = tc.parse_type('int')
	tc.fn_ret_types['string__trim_left'] = tc.parse_type('string')
	tc.fn_ret_types['string__trim_right'] = tc.parse_type('string')
	tc.fn_param_types['IError.msg'] = tarr1(tc.parse_type('&IError'))
	tc.fn_param_types['IError.code'] = tarr1(tc.parse_type('&IError'))
	s := tc.parse_type('string')
	str_ref := tc.parse_type('&string')
	i := tc.parse_type('int')
	b := tc.parse_type('bool')
	u := tc.parse_type('u8')
	v := tc.parse_type('void')
	tc.register_string_method('all_before', tarr2(s, s), s)
	tc.register_string_method('all_before_last', tarr2(s, s), s)
	tc.register_string_method('all_after', tarr2(s, s), s)
	tc.register_string_method('all_after_last', tarr2(s, s), s)
	tc.register_string_method('before', tarr2(s, s), s)
	tc.register_string_method('after', tarr2(s, s), s)
	tc.register_string_method('substr', tarr3(s, i, i), s)
	tc.register_string_method('trim_left', tarr2(s, s), s)
	tc.register_string_method('trim_right', tarr2(s, s), s)
	tc.register_string_method('trim_space', tarr1(s), s)
	tc.register_string_method('count', tarr2(s, s), i)
	tc.register_string_method('index', tarr2(s, s), tc.parse_type('?int'))
	tc.register_string_method('last_index', tarr2(s, s), tc.parse_type('?int'))
	tc.register_string_method('replace', tarr3(s, s, s), s)
	tc.register_string_method('contains', tarr2(s, s), b)
	tc.register_string_method('split', tarr2(s, s), tc.parse_type('[]string'))
	tc.register_string_method('starts_with', tarr2(s, s), b)
	tc.register_string_method('ends_with', tarr2(s, s), b)
	tc.register_string_method('index_u8', tarr2(s, u), i)
	tc.register_string_method('last_index_u8', tarr2(s, u), i)
	tc.register_string_method('contains_u8', tarr2(s, u), b)
	tc.register_string_method('int', tarr1(s), i)
	tc.register_string_method('free', tarr1(str_ref), v)
	tc.register_string_method('clone', tarr1(s), s)
	tc.register_string_method('bytes', tarr1(s), tc.parse_type('[]u8'))
	tc.register_string_method('plus', tarr2(s, s), s)
	tc.register_string_method('eq', tarr2(s, s), b)
	tc.register_string_method('lt', tarr2(s, s), b)
}

fn (mut tc TypeChecker) register_string_method(name string, params []Type, ret Type) {
	full := 'string.${name}'
	if full !in tc.fn_param_types {
		tc.fn_param_types[full] = params
	}
	if full !in tc.fn_ret_types {
		tc.fn_ret_types[full] = ret
	}
}

// annotate_types performs a scope-aware walk over every function body, tracking
// local variable types as they are declared, and records the resolved type of
// every expression node into tc.expr_types (keyed by node id). This mirrors what
// the v2 transformer relies on: the type checker runs BEFORE the transformer and
// publishes per-expression types, so the transformer can own type-dependent
// lowering (string ops, `in` membership, ...) instead of the backend.
//
// It uses a single flat scope per function (an over-approximation: a local stays
// visible after its block ends), which is harmless for type lookup since variable
// names are effectively unique within a function.
pub fn (mut tc TypeChecker) annotate_types() {
	tc.cur_module = ''
	for node in tc.a.nodes {
		if node.kind == .module_decl {
			tc.cur_module = node.value
		} else if node.kind == .fn_decl {
			tc.cur_scope = new_scope(tc.file_scope)
			for pi in 0 .. node.children_count {
				p := tc.a.child_node(&node, pi)
				if p.kind == .param && p.value.len > 0 {
					tc.cur_scope.insert(p.value, tc.parse_type(p.typ))
				}
			}
			for i in 0 .. node.children_count {
				child := tc.a.child_node(&node, i)
				if child.kind != .param {
					tc.annotate_node(tc.a.child(&node, i))
				}
			}
			tc.cur_scope = tc.file_scope
		}
	}
}

fn (mut tc TypeChecker) annotate_node(id flat.NodeId) {
	if int(id) < 0 {
		return
	}
	node := tc.a.nodes[int(id)]
	match node.kind {
		.decl_assign {
			// children are interleaved pairs [lhs0, rhs0, lhs1, rhs1, ...].
			// Multi-return (`a, b := f()`) yields an odd count; we only insert
			// locals for clean pairs and skip MultiReturn rhs values.
			mut i := 0
			for i + 1 < node.children_count {
				lhs_id := tc.a.child(&node, i)
				rhs_id := tc.a.child(&node, i + 1)
				tc.annotate_node(rhs_id)
				lhs := tc.a.nodes[int(lhs_id)]
				if lhs.kind == .ident && lhs.value.len > 0 {
					mut typ := Type(void_)
					if node.children_count == 2 && node.typ.len > 0 {
						typ = tc.parse_type(node.typ)
					} else {
						typ = tc.resolve_type(rhs_id)
					}
					if typ !is MultiReturn && typ !is Void {
						tc.cur_scope.insert(lhs.value, typ)
						tc.expr_types[int(lhs_id)] = typ
					}
				}
				i += 2
			}
			return
		}
		.for_in_stmt {
			tc.annotate_for_in(id, node)
			return
		}
		else {}
	}

	tc.expr_types[int(id)] = tc.resolve_type(id)
	for i in 0 .. node.children_count {
		tc.annotate_node(tc.a.child(&node, i))
	}
}

fn (mut tc TypeChecker) annotate_for_in(_id flat.NodeId, node flat.Node) {
	header := node.value.int()
	if header < 3 || node.children_count < 3 {
		return
	}
	key_id := tc.a.child(&node, 0)
	val_id := tc.a.child(&node, 1)
	container_id := tc.a.child(&node, 2)
	tc.annotate_node(container_id)
	has_val := int(val_id) >= 0
	if header == 4 {
		tc.insert_loop_var(key_id, Type(int_))
		tc.annotate_node(tc.a.child(&node, 3))
	} else {
		clean := unwrap_pointer(tc.resolve_type(container_id))
		if clean is Array {
			if has_val {
				tc.insert_loop_var(key_id, Type(int_))
				tc.insert_loop_var(val_id, clean.elem_type)
			} else {
				tc.insert_loop_var(key_id, clean.elem_type)
			}
		} else if clean is Map {
			if has_val {
				tc.insert_loop_var(key_id, clean.key_type)
				tc.insert_loop_var(val_id, clean.value_type)
			} else {
				tc.insert_loop_var(key_id, clean.value_type)
			}
		} else if clean is String {
			if has_val {
				tc.insert_loop_var(key_id, Type(int_))
				tc.insert_loop_var(val_id, Type(u8_))
			} else {
				tc.insert_loop_var(key_id, Type(u8_))
			}
		} else {
			container := tc.a.nodes[int(container_id)]
			if container.kind == .range {
				tc.insert_loop_var(key_id, Type(int_))
			}
		}
	}
	for i in header .. node.children_count {
		tc.annotate_node(tc.a.child(&node, i))
	}
}

fn (mut tc TypeChecker) insert_loop_var(id flat.NodeId, typ Type) {
	if int(id) < 0 {
		return
	}
	v := tc.a.nodes[int(id)]
	if v.kind == .ident && v.value.len > 0 {
		tc.cur_scope.insert(v.value, typ)
		tc.expr_types[int(id)] = typ
	}
}

// expr_type returns the resolved type recorded for a node during annotate_types.
pub fn (tc &TypeChecker) expr_type(id flat.NodeId) ?Type {
	if t := tc.expr_types[int(id)] {
		return t
	}
	return none
}

pub fn (mut tc TypeChecker) check_semantics() {
	tc.cur_module = ''
	for i, node in tc.a.nodes {
		match node.kind {
			.module_decl {
				tc.cur_module = node.value
			}
			.fn_decl {
				tc.push_scope()
				for pi in 0 .. node.children_count {
					p := tc.a.child_node(&node, pi)
					if p.kind == .param && p.value.len > 0 {
						tc.cur_scope.insert(p.value, tc.parse_type(p.typ))
					}
				}
				tc.check_fn_body(node)
				tc.pop_scope()
			}
			else {}
		}

		_ = i
	}
}

fn (mut tc TypeChecker) check_fn_body(node flat.Node) {
	for i in 0 .. node.children_count {
		child_id := tc.a.child(&node, i)
		child := tc.a.child_node(&node, i)
		if child.kind == .param {
			continue
		}
		tc.check_node(child_id)
	}
}

fn (mut tc TypeChecker) check_node(id flat.NodeId) {
	if int(id) < 0 {
		return
	}
	node := tc.a.nodes[int(id)]
	match node.kind {
		.call {
			tc.check_call(id, node)
		}
		.if_expr {
			tc.check_if_expr(id, node)
		}
		else {}
	}

	for i in 0 .. node.children_count {
		tc.check_node(tc.a.child(&node, i))
	}
}

fn (mut tc TypeChecker) check_call(id flat.NodeId, node flat.Node) {
	if node.children_count == 0 {
		return
	}
	fn_node := tc.a.child_node(&node, 0)
	mut resolved := ''
	if fn_node.kind == .selector {
		base_node := tc.a.child_node(fn_node, 0)
		if base_node.kind == .ident {
			resolved_mod := if base_node.value in tc.imports {
				tc.imports[base_node.value]
			} else {
				base_node.value
			}
			mod_name := '${resolved_mod}.${fn_node.value}'
			if mod_name in tc.fn_ret_types {
				resolved = mod_name
			} else {
				base_type := tc.resolve_type(tc.a.child(fn_node, 0))
				clean := unwrap_pointer(base_type)
				type_name := resolve_type_name_for_method(clean)
				if type_name.len > 0 {
					mname := '${type_name}.${fn_node.value}'
					if mname in tc.fn_ret_types {
						resolved = mname
					}
				}
			}
		}
	} else if fn_node.kind == .ident {
		qfn := tc.qualify_fn_name(fn_node.value)
		if qfn in tc.fn_ret_types {
			resolved = qfn
		} else if fn_node.value in tc.fn_ret_types {
			resolved = fn_node.value
		}
	}
	if resolved.len > 0 {
		tc.resolved_calls[int(id)] = resolved
	}
}

fn (mut tc TypeChecker) check_if_expr(id flat.NodeId, node flat.Node) {
	if node.children_count < 3 {
		return
	}
	then_block := tc.a.child_node(&node, 1)
	mut then_type := Type(void_)
	if then_block.children_count > 0 {
		last := tc.a.child_node(then_block, then_block.children_count - 1)
		then_type = if last.kind == .expr_stmt {
			tc.resolve_type(tc.a.child(last, 0))
		} else {
			tc.resolve_type(tc.a.child(then_block, then_block.children_count - 1))
		}
	}
	else_node := tc.a.child_node(&node, 2)
	mut else_type := Type(void_)
	if else_node.kind == .block && else_node.children_count > 0 {
		last := tc.a.child_node(else_node, else_node.children_count - 1)
		else_type = if last.kind == .expr_stmt {
			tc.resolve_type(tc.a.child(last, 0))
		} else {
			tc.resolve_type(tc.a.child(else_node, else_node.children_count - 1))
		}
	} else if else_node.kind == .if_expr {
		else_type = tc.resolve_type(tc.a.child(&node, 2))
	}
	if then_type !is Void && else_type !is Void {
		if then_type.name() != else_type.name() {
			tc.record_error(.if_branch_mismatch,
				'if-expression branch type mismatch: then `${then_type.name()}` vs else `${else_type.name()}`',
				id)
		}
	}
}

// parse_type converts a V type string (from parser) to a structured Type.
pub fn (tc &TypeChecker) parse_type(typ string) Type {
	if typ.len == 0 {
		return Type(void_)
	}
	if typ.starts_with('&') {
		return Type(Pointer{
			base_type: tc.parse_type(typ[1..])
		})
	}
	if typ.starts_with('shared ') {
		return tc.parse_type(typ[7..])
	}
	if typ.starts_with('?') {
		return Type(OptionType{
			base_type: tc.parse_type(typ[1..])
		})
	}
	if typ.starts_with('!') {
		return Type(ResultType{
			base_type: tc.parse_type(typ[1..])
		})
	}
	if typ.starts_with('...') {
		return Type(Array{
			elem_type: tc.parse_type(typ[3..])
		})
	}
	if typ.starts_with('[]') {
		return Type(Array{
			elem_type: tc.parse_type(typ[2..])
		})
	}
	if typ.starts_with('map[') {
		bracket_end := find_matching_bracket(typ, 3)
		key_str := typ[4..bracket_end]
		val_str := typ[bracket_end + 1..]
		return Type(Map{
			key_type:   tc.parse_type(key_str)
			value_type: tc.parse_type(val_str)
		})
	}
	if typ.starts_with('[') {
		idx := typ.index_u8(`]`)
		if idx > 0 {
			return Type(ArrayFixed{
				elem_type: tc.parse_type(typ[idx + 1..])
				len:       typ[1..idx].int()
			})
		}
	}
	if typ.starts_with('(') && typ.contains(',') {
		inner := typ[1..typ.len - 1]
		parts := split_params(inner)
		mut types := []Type{}
		for p in parts {
			types << tc.parse_type(p.trim_space())
		}
		return Type(MultiReturn{
			types: types
		})
	}
	if typ.starts_with('fn(') || typ.starts_with('fn (') {
		return tc.parse_fn_type(typ)
	}
	if bt := builtin_type(typ) {
		return bt
	}
	if typ.starts_with('C.') {
		return Type(Struct{
			name: typ
		})
	}
	qtyp := tc.qualify_name(typ)
	if typ in tc.type_aliases {
		return tc.parse_type(tc.type_aliases[typ])
	}
	if qtyp in tc.type_aliases {
		return tc.parse_type(tc.type_aliases[qtyp])
	}
	if typ in tc.flag_enums {
		return Type(Enum{
			name:    typ
			is_flag: true
		})
	}
	if qtyp in tc.flag_enums {
		return Type(Enum{
			name:    qtyp
			is_flag: true
		})
	}
	if typ in tc.enum_names {
		return Type(Enum{
			name: typ
		})
	}
	if qtyp in tc.enum_names {
		return Type(Enum{
			name: qtyp
		})
	}
	if typ in tc.sum_types {
		return Type(SumType{
			name: typ
		})
	}
	if qtyp in tc.sum_types {
		return Type(SumType{
			name: qtyp
		})
	}
	if typ.contains('[') && !typ.starts_with('[') {
		bracket := typ.index_u8(`[`)
		bracket_end := typ.index_u8(`]`)
		if bracket_end > bracket {
			return Type(ArrayFixed{
				elem_type: tc.parse_type(typ[..bracket])
				len:       typ[bracket + 1..bracket_end].int()
			})
		}
	}
	if typ in tc.interface_names {
		return Type(Struct{
			name: typ
		})
	}
	if qtyp in tc.interface_names {
		return Type(Struct{
			name: qtyp
		})
	}
	if typ in tc.structs {
		return Type(Struct{
			name: typ
		})
	}
	if qtyp != typ {
		return Type(Struct{
			name: qtyp
		})
	}
	return Type(Struct{
		name: typ
	})
}

fn (tc &TypeChecker) parse_fn_type(typ string) Type {
	params_start := typ.index_u8(`(`) + 1
	mut depth := 1
	mut params_end := params_start
	for params_end < typ.len {
		if typ[params_end] == `(` {
			depth++
		} else if typ[params_end] == `)` {
			depth--
			if depth == 0 {
				break
			}
		}
		params_end++
	}
	params_str := typ[params_start..params_end]
	ret_str := typ[params_end + 1..].trim_left(' ')
	mut params := []Type{}
	if params_str.len > 0 {
		param_parts := split_params(params_str)
		for p in param_parts {
			trimmed := p.trim_space()
			parts := trimmed.split(' ')
			param_type := if parts.len >= 2 { parts[parts.len - 1] } else { trimmed }
			params << tc.parse_type(param_type)
		}
	}
	mut ret_type := Type(Void{})
	if ret_str.len > 0 {
		ret_type = tc.parse_type(ret_str)
	}
	return Type(FnType{
		params:      params
		return_type: ret_type
	})
}

pub fn (tc &TypeChecker) resolve_type(id flat.NodeId) Type {
	if int(id) < 0 {
		return Type(int_)
	}
	node := tc.a.nodes[int(id)]
	match node.kind {
		.int_literal {
			return Type(int_)
		}
		.float_literal {
			return Type(f64_)
		}
		.bool_literal {
			return Type(bool_)
		}
		.char_literal {
			return Type(u8_)
		}
		.string_literal, .string_interp {
			return Type(string_)
		}
		.nil_literal {
			return Type(voidptr_)
		}
		.none_expr {
			return Type(OptionType{
				base_type: Type(void_)
			})
		}
		.enum_val {
			return Type(int_)
		}
		.ident {
			if typ := tc.cur_scope.lookup(node.value) {
				return typ
			}
			qname := tc.qualify_name(node.value)
			if qname in tc.const_types {
				return tc.const_types[qname] or { Type(int_) }
			}
			if node.value in tc.const_types {
				return tc.const_types[node.value] or { Type(int_) }
			}
			return Type(int_)
		}
		.call {
			if node.typ.len > 0 {
				return tc.parse_type(node.typ)
			}
			fn_node := tc.a.child_node(&node, 0)
			if fn_node.kind == .selector {
				base_node := tc.a.child_node(fn_node, 0)
				if base_node.kind == .ident && base_node.value == 'C' {
					if fn_node.value in tc.fn_ret_types {
						return tc.fn_ret_types[fn_node.value] or { Type(int_) }
					}
					return Type(Struct{
						name: 'C.${fn_node.value}'
					})
				}
				if base_node.kind == .ident {
					resolved := if base_node.value in tc.imports {
						tc.imports[base_node.value]
					} else {
						base_node.value
					}
					mod_name := '${resolved}.${fn_node.value}'
					if mod_name in tc.fn_ret_types {
						return tc.fn_ret_types[mod_name] or { Type(int_) }
					}
					if mod_name in tc.sum_types {
						return Type(SumType{
							name: mod_name
						})
					}
					if mod_name in tc.structs {
						return Type(Struct{
							name: mod_name
						})
					}
					if mod_name in tc.enum_names {
						return Type(Enum{
							name: mod_name
						})
					}
					if base_node.value in tc.structs || base_node.value in tc.enum_names {
						qname := tc.qualify_name(base_node.value)
						sname := '${qname}.${fn_node.value}'
						if sname in tc.fn_ret_types {
							return tc.fn_ret_types[sname] or { Type(int_) }
						}
					} else {
						qname := tc.qualify_name(base_node.value)
						if qname in tc.structs || qname in tc.enum_names {
							sname := '${qname}.${fn_node.value}'
							if sname in tc.fn_ret_types {
								return tc.fn_ret_types[sname] or { Type(int_) }
							}
						}
					}
				} else if base_node.kind == .selector {
					inner := tc.a.child_node(base_node, 0)
					if inner.kind == .ident {
						mod_name := if inner.value in tc.imports {
							tc.imports[inner.value]
						} else {
							inner.value
						}
						full_name := '${mod_name}.${base_node.value}.${fn_node.value}'
						if full_name in tc.fn_ret_types {
							return tc.fn_ret_types[full_name] or { Type(int_) }
						}
					}
				}
				base_type := tc.resolve_type(tc.a.child(fn_node, 0))
				clean_type := unwrap_pointer(base_type)
				if clean_type is Array {
					if fn_node.value == 'clone' {
						return base_type
					}
					if fn_node.value == 'last' || fn_node.value == 'first' || fn_node.value == 'pop' {
						return clean_type.elem_type
					}
					if fn_node.value == 'contains' {
						return Type(bool_)
					}
					if fn_node.value == 'index' {
						return Type(int_)
					}
					if fn_node.value == 'join' || fn_node.value == 'str' {
						return Type(string_)
					}
					elem_name := clean_type.elem_type.name()
					short_elem := if elem_name.contains('.') {
						elem_name.all_after_last('.')
					} else {
						elem_name
					}
					mod_prefix := if elem_name.contains('.') {
						elem_name.all_before_last('.')
					} else {
						''
					}
					arr_mname1 := '[]${short_elem}.${fn_node.value}'
					if mod_prefix.len > 0 {
						arr_mkey := '${mod_prefix}.${arr_mname1}'
						if arr_mkey in tc.fn_ret_types {
							return tc.fn_ret_types[arr_mkey] or { Type(int_) }
						}
					}
					if arr_mname1 in tc.fn_ret_types {
						return tc.fn_ret_types[arr_mname1] or { Type(int_) }
					}
					return Type(int_)
				}
				if clean_type is Map {
					if fn_node.value == 'clone' {
						return base_type
					}
					return Type(int_)
				}
				if clean_type is String {
					mname := 'string.${fn_node.value}'
					if mname in tc.fn_ret_types {
						return tc.fn_ret_types[mname] or { Type(int_) }
					}
				}
				if clean_type is Struct {
					mname := '${clean_type.name}.${fn_node.value}'
					if mname in tc.fn_ret_types {
						return tc.fn_ret_types[mname] or { Type(int_) }
					}
				}
				if clean_type is SumType {
					mname := '${clean_type.name}.${fn_node.value}'
					if mname in tc.fn_ret_types {
						return tc.fn_ret_types[mname] or { Type(int_) }
					}
				}
				if clean_type is Enum {
					mname := '${clean_type.name}.${fn_node.value}'
					if mname in tc.fn_ret_types {
						return tc.fn_ret_types[mname] or { Type(int_) }
					}
				}
				if clean_type is Primitive {
					mname := '${prim_c_type_from(clean_type.props, clean_type.size)}.${fn_node.value}'
					if mname in tc.fn_ret_types {
						return tc.fn_ret_types[mname] or { Type(int_) }
					}
				}
			}
			qfn := tc.qualify_fn_name(fn_node.value)
			if qfn in tc.fn_ret_types {
				return tc.fn_ret_types[qfn] or { Type(int_) }
			}
			if fn_node.value in tc.fn_ret_types {
				return tc.fn_ret_types[fn_node.value] or { Type(int_) }
			}
			for _, imp in tc.imports {
				imp_name := '${imp}.${fn_node.value}'
				if imp_name in tc.fn_ret_types {
					return tc.fn_ret_types[imp_name] or { Type(int_) }
				}
			}
			$if debug {
				eprintln('warning: unknown fn return type `${fn_node.value}`, recovering as int')
			}
			return Type(int_)
		}
		.infix {
			if node.op in [.eq, .ne, .lt, .gt, .le, .ge, .logical_and, .logical_or] {
				return Type(bool_)
			}
			lt := tc.resolve_type(tc.a.child(&node, 0))
			if lt is String {
				return lt
			}
			rt := tc.resolve_type(tc.a.child(&node, 1))
			if rt is String {
				return rt
			}
			if lt.is_float() || rt.is_float() {
				return Type(f64_)
			}
			return lt
		}
		.prefix {
			if node.op == .amp {
				inner := tc.resolve_type(tc.a.child(&node, 0))
				return Type(Pointer{
					base_type: inner
				})
			}
			if node.op == .mul {
				inner := tc.resolve_type(tc.a.child(&node, 0))
				if inner is Pointer {
					return inner.base_type
				}
				return inner
			}
			return tc.resolve_type(tc.a.child(&node, 0))
		}
		.paren {
			return tc.resolve_type(tc.a.child(&node, 0))
		}
		.or_expr {
			return tc.resolve_type(tc.a.child(&node, 0))
		}
		.struct_init {
			return tc.parse_type(node.value)
		}
		.cast_expr {
			return tc.parse_type(node.value)
		}
		.selector {
			base_node := tc.a.child_node(&node, 0)
			if base_node.kind == .ident {
				if gt := tc.file_scope.lookup(node.value) {
					return gt
				}
				resolved := if base_node.value in tc.imports {
					tc.imports[base_node.value]
				} else {
					base_node.value
				}
				qname := '${resolved}.${node.value}'
				if qname in tc.const_types {
					return tc.const_types[qname] or { Type(int_) }
				}
			}
			base_type := tc.resolve_type(tc.a.child(&node, 0))
			clean := unwrap_pointer(base_type)
			if node.value == 'len' {
				if clean is Array || clean is Map || clean is String || clean is ArrayFixed {
					return Type(int_)
				}
			}
			if clean is Struct {
				if clean.name in tc.structs {
					for f in tc.structs[clean.name] {
						if f.name == node.value {
							return f.typ
						}
					}
				}
			}
			if clean is Array || clean is Map || clean is String {
				sname := if clean is Array {
					'array'
				} else if clean is Map {
					'map'
				} else {
					'string'
				}
				if sname in tc.structs {
					for f in tc.structs[sname] {
						if f.name == node.value {
							return f.typ
						}
					}
				}
			}
			if clean is Primitive && base_node.kind == .selector {
				vname := base_node.value.replace('__', '.')
				if vname in tc.structs {
					for f in tc.structs[vname] {
						if f.name == node.value {
							return f.typ
						}
					}
				}
			}
			return Type(int_)
		}
		.array_literal {
			if node.children_count > 0 {
				elem_type := tc.resolve_type(tc.a.child(&node, 0))
				return Type(ArrayFixed{
					elem_type: elem_type
					len:       node.children_count
				})
			}
			return Type(ArrayFixed{
				elem_type: Type(int_)
				len:       0
			})
		}
		.index {
			base_type := tc.resolve_type(tc.a.child(&node, 0))
			if node.value == 'range' {
				if base_type is Array {
					return base_type
				}
				return Type(string_)
			}
			if base_type is Map {
				return base_type.value_type
			}
			if base_type is Array {
				return base_type.elem_type
			}
			if base_type is ArrayFixed {
				return base_type.elem_type
			}
			if base_type is String {
				return Type(u8_)
			}
			return Type(int_)
		}
		.array_init {
			t := tc.parse_type(node.value)
			if t is ArrayFixed {
				return t
			}
			return Type(Array{
				elem_type: t
			})
		}
		.if_expr {
			mut then_type := Type(void_)
			then_block := tc.a.child_node(&node, 1)
			if then_block.children_count > 0 {
				last := tc.a.child_node(then_block, then_block.children_count - 1)
				then_type = if last.kind == .expr_stmt {
					tc.resolve_type(tc.a.child(last, 0))
				} else {
					tc.resolve_type(tc.a.child(then_block, then_block.children_count - 1))
				}
			}
			if node.children_count > 2 {
				else_node := tc.a.child_node(&node, 2)
				mut else_type := Type(void_)
				if else_node.kind == .block && else_node.children_count > 0 {
					last := tc.a.child_node(else_node, else_node.children_count - 1)
					else_type = if last.kind == .expr_stmt {
						tc.resolve_type(tc.a.child(last, 0))
					} else {
						tc.resolve_type(tc.a.child(else_node, else_node.children_count - 1))
					}
				} else if else_node.kind == .if_expr {
					else_type = tc.resolve_type(tc.a.child(&node, 2))
				}
				if then_type !is Void && then_type !is Primitive {
					return then_type
				}
				if else_type !is Void && else_type !is Primitive {
					return else_type
				}
				if then_type !is Void {
					return then_type
				}
				return else_type
			}
			if then_type !is Void {
				return then_type
			}
			return Type(void_)
		}
		.map_init {
			return tc.parse_type(node.value)
		}
		.in_expr {
			return Type(bool_)
		}
		.block {
			if node.children_count > 0 {
				last_id := tc.a.child(&node, node.children_count - 1)
				last := tc.a.nodes[int(last_id)]
				if last.kind == .expr_stmt {
					return tc.resolve_type(tc.a.child(&last, 0))
				}
				return tc.resolve_type(last_id)
			}
			return Type(void_)
		}
		.as_expr {
			return tc.parse_type(node.value)
		}
		.is_expr {
			return Type(bool_)
		}
		else {
			$if debug {
				eprintln('warning: unhandled node kind .${node.kind} in resolve_type, recovering as int')
			}
			return Type(int_)
		}
	}
}

pub fn (tc &TypeChecker) c_type(t Type) string {
	if t is Void {
		return 'void'
	}
	if t is Nil {
		return 'void*'
	}
	if t is None {
		return 'Optional'
	}
	if t is String {
		return 'string'
	}
	if t is Char {
		return 'char'
	}
	if t is Rune {
		return 'i32'
	}
	if t is ISize {
		return 'ptrdiff_t'
	}
	if t is USize {
		return 'size_t'
	}
	if t is Primitive {
		return prim_c_type_from(t.props, t.size)
	}
	if t is Array {
		return 'Array'
	}
	if t is ArrayFixed {
		return if tc.has_builtins { 'array' } else { 'Array' }
	}
	if t is Map {
		return 'map'
	}
	if t is Pointer {
		return tc.c_type(t.base_type) + '*'
	}
	if t is FnType {
		ret := if t.return_type is Void { 'void' } else { tc.c_type(t.return_type) }
		if t.params.len == 0 {
			return 'fn_ptr:${ret}|void'
		}
		mut params := []string{}
		for p in t.params {
			params << tc.c_type(p)
		}
		return 'fn_ptr:${ret}|${params.join(', ')}'
	}
	if t is OptionType {
		return 'Optional'
	}
	if t is ResultType {
		return 'Optional'
	}
	if t is Struct {
		if t.name.starts_with('C.') {
			raw := t.name[2..]
			if raw.len > 0 && raw[0] >= `a` && raw[0] <= `z` && !raw.ends_with('_t') {
				return 'struct ${raw}'
			}
			return raw
		}
		return c_name(t.name)
	}
	if t is Enum {
		return 'int'
	}
	if t is SumType {
		return c_name(t.name)
	}
	if t is Alias {
		return tc.c_type(t.base_type)
	}
	if t is MultiReturn {
		mut parts := []string{}
		for ty in t.types {
			parts << tc.c_type(ty)
		}
		return 'multi_return_${parts.join('_')}'
	}
	return 'int'
}

fn resolve_type_name_for_method(t Type) string {
	if t is Struct {
		return t.name
	}
	if t is String {
		return 'string'
	}
	if t is Array {
		return 'Array'
	}
	if t is Map {
		return 'map'
	}
	if t is Primitive {
		return prim_c_type_from(t.props, t.size)
	}
	return ''
}

fn prim_c_type_from(props Properties, size u8) string {
	if props.has(.boolean) {
		return 'bool'
	}
	if props.has(.integer) {
		if props.has(.unsigned) {
			return match size {
				8 { 'u8' }
				16 { 'u16' }
				32 { 'u32' }
				64 { 'u64' }
				else { 'u${size}' }
			}
		}
		return match size {
			0 { 'int' }
			8 { 'i8' }
			16 { 'i16' }
			32 { 'i32' }
			64 { 'i64' }
			else { 'i${size}' }
		}
	}
	if props.has(.float) {
		return match size {
			32 { 'float' }
			64 { 'double' }
			else { 'double' }
		}
	}
	return 'int'
}

fn prim_c_type(p Primitive) string {
	if p.props.has(.boolean) {
		return 'bool'
	}
	if p.props.has(.integer) {
		if p.props.has(.unsigned) {
			return match p.size {
				8 { 'u8' }
				16 { 'u16' }
				32 { 'u32' }
				64 { 'u64' }
				else { 'u${p.size}' }
			}
		}
		return match p.size {
			0 { 'int' }
			8 { 'i8' }
			16 { 'i16' }
			32 { 'i32' }
			64 { 'i64' }
			else { 'i${p.size}' }
		}
	}
	if p.props.has(.float) {
		return match p.size {
			32 { 'float' }
			64 { 'double' }
			else { 'double' }
		}
	}
	return 'int'
}

fn find_matching_bracket(s string, start int) int {
	mut depth := 1
	for i := start + 1; i < s.len; i++ {
		if s[i] == `[` {
			depth++
		}
		if s[i] == `]` {
			depth--
			if depth == 0 {
				return i
			}
		}
	}
	return s.len
}

fn split_params(s string) []string {
	mut parts := []string{}
	mut depth := 0
	mut start := 0
	for i := 0; i < s.len; i++ {
		match s[i] {
			`(`, `[` {
				depth++
			}
			`)`, `]` {
				depth--
			}
			`,` {
				if depth == 0 {
					parts << s[start..i]
					start = i + 1
				}
			}
			else {}
		}
	}
	if start < s.len {
		parts << s[start..]
	}
	return parts
}

fn c_name(name string) string {
	if name.starts_with('C.') {
		return name[2..]
	}
	return name.replace('.', '__')
}
