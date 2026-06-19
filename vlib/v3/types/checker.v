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

fn unknown_type(reason string) Type {
	return Type(Unknown{
		reason: reason
	})
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
	assignment_mismatch
	return_mismatch
	call_arg_mismatch
	condition_mismatch
	unhandled_node
}

struct CallInfo {
	name         string
	params       []Type
	return_type  Type
	has_receiver bool
	is_variadic  bool
	params_known bool
}

struct LocalBinding {
	name string
	typ  Type
}

@[heap]
pub struct TypeChecker {
pub mut:
	a                             &flat.FlatAst = unsafe { nil }
	fn_ret_types                  map[string]Type
	fn_param_types                map[string][]Type
	fn_variadic                   map[string]bool
	structs                       map[string][]StructField
	unions                        map[string]bool
	type_aliases                  map[string]string
	sum_types                     map[string][]string
	enum_names                    map[string]bool
	flag_enums                    map[string]bool
	interface_names               map[string]bool
	const_types                   map[string]Type
	imports                       map[string]string // alias -> short module name
	file_scope                    &Scope = unsafe { nil }
	cur_scope                     &Scope = unsafe { nil }
	has_builtins                  bool
	cur_module                    string
	cur_file                      string
	errors                        []TypeError
	resolved_calls                map[int]string // node_id -> resolved function name
	expr_types                    map[int]Type   // node_id -> resolved type (populated by annotate_types)
	diagnose_unknown_calls        bool
	reject_unlowered_map_mutation bool
	diagnostic_files              map[string]bool
	cur_fn_ret_type               Type = Type(void_)
	smartcasts                    map[string]Type
}

pub fn TypeChecker.new(a &flat.FlatAst) TypeChecker {
	fs := new_scope(unsafe { nil })
	return TypeChecker{
		a:                a
		fn_ret_types:     map[string]Type{}
		fn_param_types:   map[string][]Type{}
		fn_variadic:      map[string]bool{}
		structs:          map[string][]StructField{}
		unions:           map[string]bool{}
		type_aliases:     map[string]string{}
		sum_types:        map[string][]string{}
		enum_names:       map[string]bool{}
		flag_enums:       map[string]bool{}
		interface_names:  map[string]bool{}
		const_types:      map[string]Type{}
		imports:          map[string]string{}
		file_scope:       fs
		cur_scope:        fs
		resolved_calls:   map[int]string{}
		expr_types:       map[int]Type{}
		diagnostic_files: map[string]bool{}
		smartcasts:       map[string]Type{}
	}
}

pub fn (mut tc TypeChecker) push_scope() {
	tc.cur_scope = new_scope(tc.cur_scope)
}

pub fn (mut tc TypeChecker) pop_scope() {
	if tc.cur_scope == unsafe { nil } {
		return
	}
	parent := tc.cur_scope.parent
	if parent == unsafe { nil } {
		return
	}
	tc.cur_scope = parent
}

fn (mut tc TypeChecker) record_error(kind TypeErrorKind, msg string, node flat.NodeId) {
	if !tc.should_diagnose(node) {
		return
	}
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
				tc.cur_file = node.value
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
					if node.value !in tc.type_aliases {
						tc.type_aliases[node.value] = node.typ
					}
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
			.file {
				tc.cur_file = node.value
			}
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
				mut is_variadic := false
				for i in 0 .. node.children_count {
					child := a.child_node(&node, i)
					if child.kind == .param {
						if child.typ.starts_with('...') {
							is_variadic = true
						}
						ptypes << tc.parse_type(child.typ)
					}
				}
				tc.fn_param_types[qname] = ptypes
				tc.fn_variadic[qname] = is_variadic
				if qname != node.value && node.value !in tc.fn_param_types {
					tc.fn_param_types[node.value] = ptypes
					tc.fn_variadic[node.value] = is_variadic
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
				qname := tc.qualify_name(node.value)
				tc.structs[qname] = fields
				if node.typ == 'union' {
					tc.unions[qname] = true
				}
			}
			.c_fn_decl {
				tc.fn_ret_types[node.value] = tc.parse_type(node.typ)
				mut ptypes := []Type{}
				mut is_variadic := false
				for i in 0 .. node.children_count {
					child := a.child_node(&node, i)
					if child.kind == .param {
						if child.typ.starts_with('...') {
							is_variadic = true
						}
						ptypes << tc.parse_type(child.typ)
					}
				}
				tc.fn_param_types[node.value] = ptypes
				tc.fn_variadic[node.value] = is_variadic
			}
			.interface_decl {
				iface_name := tc.qualify_name(node.value)
				for i in 0 .. node.children_count {
					f := a.child_node(&node, i)
					if f.kind == .interface_field {
						mname := '${iface_name}.${f.value}'
						tc.fn_ret_types[mname] = tc.parse_type(f.typ)
						mut ptypes := []Type{}
						mut is_variadic := false
						ptypes << Type(Pointer{
							base_type: Type(Interface{
								name: iface_name
							})
						})
						for j in 0 .. f.children_count {
							child := a.child_node(f, j)
							if child.kind == .param {
								if child.typ.starts_with('...') {
									is_variadic = true
								}
								ptypes << tc.parse_type(child.typ)
							}
						}
						tc.fn_param_types[mname] = ptypes
						tc.fn_variadic[mname] = is_variadic
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
	tc.fn_ret_types['strings.Builder.write_runes'] = tc.parse_type('void')
	tc.fn_param_types['strings.Builder.write_runes'] = tarr2(tc.parse_type('&strings.Builder'),
		tc.parse_type('[]rune'))
	tc.fn_ret_types['strings.Builder.free'] = tc.parse_type('void')
	tc.fn_param_types['strings.Builder.free'] = tarr1(tc.parse_type('&strings.Builder'))
	tc.fn_ret_types['strings.Builder.last_n'] = tc.parse_type('string')
	tc.fn_param_types['strings.Builder.last_n'] = tarr2(tc.parse_type('&strings.Builder'),
		tc.parse_type('int'))
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
	tc.fn_ret_types['array_contains_int'] = tc.parse_type('bool')
	tc.fn_ret_types['array_contains_string'] = tc.parse_type('bool')
	tc.fn_ret_types['fixed_array_contains_int'] = tc.parse_type('bool')
	tc.fn_ret_types['fixed_array_contains_string'] = tc.parse_type('bool')
	tc.fn_ret_types['string_plus_many'] = tc.parse_type('string')
	tc.fn_ret_types['int_str'] = tc.parse_type('string')
	tc.fn_ret_types['bool_str'] = tc.parse_type('string')
	tc.fn_ret_types['strconv__format_int'] = tc.parse_type('string')
	tc.fn_ret_types['strconv__format_uint'] = tc.parse_type('string')
	tc.fn_ret_types['strconv__f32_to_str_l'] = tc.parse_type('string')
	tc.fn_ret_types['strconv__f64_to_str_l'] = tc.parse_type('string')
	tc.fn_param_types['bool_str'] = tarr1(tc.parse_type('bool'))
	tc.fn_param_types['int_str'] = tarr1(tc.parse_type('int'))
	tc.fn_param_types['strconv__format_int'] = tarr2(tc.parse_type('i64'), tc.parse_type('int'))
	tc.fn_param_types['strconv__format_uint'] = tarr2(tc.parse_type('u64'), tc.parse_type('int'))
	tc.fn_param_types['strconv__f32_to_str_l'] = tarr1(tc.parse_type('f32'))
	tc.fn_param_types['strconv__f64_to_str_l'] = tarr1(tc.parse_type('f64'))
	tc.fn_ret_types['string__bytes'] = tc.parse_type('[]u8')
	tc.fn_ret_types['string__int'] = tc.parse_type('int')
	tc.fn_ret_types['string__clone'] = tc.parse_type('string')
	tc.fn_ret_types['string__contains'] = tc.parse_type('bool')
	tc.fn_ret_types['string__index'] = tc.parse_type('?int')
	tc.fn_ret_types['string__last_index'] = tc.parse_type('?int')
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
	tc.fn_param_types['string__index'] = tarr2(tc.parse_type('string'), tc.parse_type('string'))
	tc.fn_param_types['string__last_index'] = tarr2(tc.parse_type('string'),
		tc.parse_type('string'))
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
	tc.register_map_callbacks()
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

fn (mut tc TypeChecker) register_map_callbacks() {
	voidptr_type := tc.parse_type('voidptr')
	u64_type := tc.parse_type('u64')
	bool_type := tc.parse_type('bool')
	void_type := tc.parse_type('void')
	tc.register_int_map_callbacks('1', voidptr_type, u64_type, bool_type, void_type)
	tc.register_int_map_callbacks('2', voidptr_type, u64_type, bool_type, void_type)
	tc.register_int_map_callbacks('4', voidptr_type, u64_type, bool_type, void_type)
	tc.register_int_map_callbacks('8', voidptr_type, u64_type, bool_type, void_type)
	tc.fn_ret_types['v3_map_hash_string'] = u64_type
	tc.fn_param_types['v3_map_hash_string'] = tarr1(voidptr_type)
	tc.fn_ret_types['v3_map_eq_string'] = bool_type
	tc.fn_param_types['v3_map_eq_string'] = tarr2(voidptr_type, voidptr_type)
	tc.fn_ret_types['v3_map_clone_string'] = void_type
	tc.fn_param_types['v3_map_clone_string'] = tarr2(voidptr_type, voidptr_type)
	tc.fn_ret_types['v3_map_free_string'] = void_type
	tc.fn_param_types['v3_map_free_string'] = tarr1(voidptr_type)
	tc.fn_ret_types['v3_map_free_nop'] = void_type
	tc.fn_param_types['v3_map_free_nop'] = tarr1(voidptr_type)
}

fn (mut tc TypeChecker) register_int_map_callbacks(suffix string, voidptr_type Type, u64_type Type, bool_type Type, void_type Type) {
	tc.fn_ret_types['v3_map_hash_int_${suffix}'] = u64_type
	tc.fn_param_types['v3_map_hash_int_${suffix}'] = tarr1(voidptr_type)
	tc.fn_ret_types['v3_map_eq_int_${suffix}'] = bool_type
	tc.fn_param_types['v3_map_eq_int_${suffix}'] = tarr2(voidptr_type, voidptr_type)
	tc.fn_ret_types['v3_map_clone_int_${suffix}'] = void_type
	tc.fn_param_types['v3_map_clone_int_${suffix}'] = tarr2(voidptr_type, voidptr_type)
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
			tc.pop_scope()
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
		} else if clean is ArrayFixed {
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
	if int(id) >= 0 {
		node := tc.a.nodes[int(id)]
		if node.kind == .call && node.typ.len > 0 {
			return tc.parse_type(node.typ)
		}
	}
	if t := tc.resolved_call_type(id) {
		return t
	}
	if t := tc.expr_types[int(id)] {
		return t
	}
	return none
}

fn (tc &TypeChecker) resolved_call_type(id flat.NodeId) ?Type {
	if int(id) < 0 {
		return none
	}
	node := tc.a.nodes[int(id)]
	if node.kind != .call {
		return none
	}
	if name := tc.resolved_calls[int(id)] {
		if t := tc.fn_ret_types[name] {
			return t
		}
	}
	return none
}

// register_synth_type records the type of a generated or transformed node.
pub fn (mut tc TypeChecker) register_synth_type(id flat.NodeId, typ Type) {
	if int(id) < 0 {
		return
	}
	tc.expr_types[int(id)] = typ
}

pub fn (mut tc TypeChecker) check_semantics() {
	tc.cur_module = ''
	tc.cur_file = ''
	for i, node in tc.a.nodes {
		match node.kind {
			.file {
				tc.cur_file = node.value
			}
			.module_decl {
				tc.cur_module = node.value
			}
			.fn_decl {
				tc.cur_fn_ret_type = tc.parse_type(node.typ)
				tc.push_scope()
				for pi in 0 .. node.children_count {
					p := tc.a.child_node(&node, pi)
					if p.kind == .param && p.value.len > 0 {
						tc.cur_scope.insert(p.value, tc.parse_type(p.typ))
					}
				}
				tc.check_fn_body(node)
				if tc.cur_fn_ret_type !is Void && !tc.fn_body_definitely_returns(node)
					&& tc.should_diagnose(flat.NodeId(i)) {
					tc.record_error(.return_mismatch,
						'missing return at end of function `${node.value}`; expected `${tc.cur_fn_ret_type.name()}`',
						flat.NodeId(i))
				}
				tc.pop_scope()
				tc.cur_fn_ret_type = Type(void_)
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

fn (tc &TypeChecker) fn_body_definitely_returns(node flat.Node) bool {
	for i in 0 .. node.children_count {
		child_id := tc.a.child(&node, i)
		child := tc.a.child_node(&node, i)
		if child.kind == .param {
			continue
		}
		if tc.stmt_definitely_returns(child_id) {
			return true
		}
	}
	return false
}

fn (tc &TypeChecker) valid_node_id(id flat.NodeId) bool {
	return int(id) >= 0 && tc.a != unsafe { nil } && int(id) < tc.a.nodes.len
}

fn (tc &TypeChecker) stmt_definitely_returns(id flat.NodeId) bool {
	if !tc.valid_node_id(id) {
		return false
	}
	node := tc.a.nodes[int(id)]
	match node.kind {
		.return_stmt {
			return true
		}
		.block {
			for i in 0 .. node.children_count {
				if tc.stmt_definitely_returns(tc.a.child(&node, i)) {
					return true
				}
			}
			return false
		}
		.if_expr {
			if node.children_count < 3 {
				return false
			}
			return tc.stmt_definitely_returns(tc.a.child(&node, 1))
				&& tc.stmt_definitely_returns(tc.a.child(&node, 2))
		}
		.match_stmt {
			if node.children_count < 2 {
				return false
			}
			mut has_else := false
			for i in 1 .. node.children_count {
				branch := tc.a.child_node(&node, i)
				if branch.kind != .match_branch {
					return false
				}
				if branch.value == 'else' {
					has_else = true
				}
				if !tc.match_branch_definitely_returns(branch) {
					return false
				}
			}
			return has_else
		}
		else {
			return false
		}
	}
}

fn (tc &TypeChecker) match_branch_definitely_returns(branch &flat.Node) bool {
	body_start := if branch.value == 'else' { 0 } else { branch.value.int() }
	for i in body_start .. branch.children_count {
		if tc.stmt_definitely_returns(tc.a.child(branch, i)) {
			return true
		}
	}
	return false
}

fn (mut tc TypeChecker) check_node(id flat.NodeId) {
	if int(id) < 0 {
		return
	}
	node := tc.a.nodes[int(id)]
	match node.kind {
		.block {
			tc.check_block(node)
			return
		}
		.for_stmt {
			tc.check_for_stmt(node)
			return
		}
		.for_in_stmt {
			tc.check_for_in_stmt(node)
			return
		}
		.decl_assign {
			tc.check_decl_assign(id, node)
			return
		}
		.assign, .selector_assign, .index_assign {
			tc.check_assign(id, node)
			return
		}
		.return_stmt {
			tc.check_return(id, node)
			return
		}
		.call {
			tc.check_call(id, node)
			return
		}
		.if_expr {
			tc.check_if_expr(id, node)
			return
		}
		.or_expr {
			tc.check_or_expr(node)
			return
		}
		.match_stmt {
			tc.check_match_stmt(id, node)
			return
		}
		.is_expr {
			tc.check_is_expr(id, node)
			return
		}
		.postfix {
			tc.check_postfix(id, node)
			return
		}
		.struct_init, .assoc {
			tc.check_struct_init(id, node)
			return
		}
		.selector {
			tc.check_selector(id, node)
			return
		}
		.index {
			tc.check_index(id, node)
			return
		}
		.ident {
			tc.check_ident(id, node)
			return
		}
		else {}
	}

	for i in 0 .. node.children_count {
		tc.check_node(tc.a.child(&node, i))
	}
}

fn (mut tc TypeChecker) check_or_expr(node flat.Node) {
	if node.children_count == 0 {
		return
	}
	tc.check_node(tc.a.child(&node, 0))
	if node.children_count < 2 || node.value in ['!', '?'] {
		return
	}
	tc.push_scope()
	tc.cur_scope.insert('err', tc.parse_type('IError'))
	tc.check_node(tc.a.child(&node, 1))
	tc.pop_scope()
}

fn (mut tc TypeChecker) check_block(node flat.Node) {
	tc.push_scope()
	for i in 0 .. node.children_count {
		tc.check_node(tc.a.child(&node, i))
	}
	tc.pop_scope()
}

fn (mut tc TypeChecker) check_for_stmt(node flat.Node) {
	tc.push_scope()
	if node.children_count > 0 {
		init_id := tc.a.child(&node, 0)
		if int(init_id) >= 0 {
			tc.check_node(init_id)
		}
	}
	if node.children_count > 1 {
		cond_id := tc.a.child(&node, 1)
		if int(cond_id) >= 0 {
			tc.check_bool_condition(cond_id)
		}
	}
	if node.children_count > 2 {
		post_id := tc.a.child(&node, 2)
		if int(post_id) >= 0 {
			tc.check_node(post_id)
		}
	}
	for i in 3 .. node.children_count {
		tc.check_node(tc.a.child(&node, i))
	}
	tc.pop_scope()
}

fn (mut tc TypeChecker) check_for_in_stmt(node flat.Node) {
	header := node.value.int()
	if header < 3 || node.children_count < 3 {
		return
	}
	tc.push_scope()
	key_id := tc.a.child(&node, 0)
	val_id := tc.a.child(&node, 1)
	container_id := tc.a.child(&node, 2)
	tc.check_node(container_id)
	has_val := int(val_id) >= 0
	if header == 4 {
		tc.insert_loop_var(key_id, Type(int_))
		tc.check_node(tc.a.child(&node, 3))
	} else {
		clean := unwrap_pointer(tc.resolve_type(container_id))
		if clean is Array {
			if has_val {
				tc.insert_loop_var(key_id, Type(int_))
				tc.insert_loop_var(val_id, clean.elem_type)
			} else {
				tc.insert_loop_var(key_id, clean.elem_type)
			}
		} else if clean is ArrayFixed {
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
			} else if tc.should_diagnose(container_id) {
				tc.record_error(.cannot_index, 'cannot iterate over `${clean.name()}`',
					container_id)
			}
		}
	}
	for i in header .. node.children_count {
		tc.check_node(tc.a.child(&node, i))
	}
	tc.pop_scope()
}

fn (mut tc TypeChecker) check_decl_assign(id flat.NodeId, node flat.Node) {
	if node.children_count == 0 {
		return
	}
	if tc.check_multi_return_decl_assign(id, node) {
		return
	}
	mut i := 0
	for i + 1 < node.children_count {
		lhs_id := tc.a.child(&node, i)
		rhs_id := tc.a.child(&node, i + 1)
		tc.check_node(rhs_id)
		mut rhs_type := tc.resolve_type(rhs_id)
		mut expected := rhs_type
		if node.children_count == 2 && node.typ.len > 0 {
			expected = tc.parse_type(node.typ)
			rhs_type = tc.resolve_expr(rhs_id, expected)
			if !tc.type_compatible(rhs_type, expected) {
				tc.type_mismatch(.assignment_mismatch,
					'cannot assign `${rhs_type.name()}` to `${expected.name()}`', id)
			}
		}
		tc.insert_decl_lhs(lhs_id, expected)
		i += 2
	}
}

fn (mut tc TypeChecker) check_multi_return_decl_assign(id flat.NodeId, node flat.Node) bool {
	if node.children_count < 3 {
		return false
	}
	rhs_id := tc.a.child(&node, 1)
	rhs_type := tc.resolve_type(rhs_id)
	rhs_type_name := rhs_type.name()
	if rhs_type is MultiReturn {
		tc.check_node(rhs_id)
		lhs_ids := tc.multi_assign_lhs_ids(node)
		if lhs_ids.len != rhs_type.types.len {
			if tc.should_diagnose(id) {
				tc.record_error(.assignment_mismatch,
					'multi-return assignment mismatch: ${lhs_ids.len} variables but `${rhs_type_name}` has ${rhs_type.types.len} values',
					id)
			}
			return true
		}
		for i, lhs_id in lhs_ids {
			tc.insert_decl_lhs(lhs_id, rhs_type.types[i])
		}
		return true
	}
	return false
}

fn (tc &TypeChecker) multi_assign_lhs_ids(node flat.Node) []flat.NodeId {
	mut lhs_ids := []flat.NodeId{}
	if node.children_count > 0 {
		lhs_ids << tc.a.child(&node, 0)
	}
	for i in 2 .. node.children_count {
		lhs_ids << tc.a.child(&node, i)
	}
	return lhs_ids
}

fn (mut tc TypeChecker) insert_decl_lhs(lhs_id flat.NodeId, typ Type) {
	if int(lhs_id) < 0 || typ is Void {
		return
	}
	lhs := tc.a.nodes[int(lhs_id)]
	if lhs.kind == .ident && lhs.value.len > 0 {
		tc.cur_scope.insert(lhs.value, typ)
		tc.register_synth_type(lhs_id, typ)
	}
}

fn (mut tc TypeChecker) check_assign(id flat.NodeId, node flat.Node) {
	if node.children_count < 2 {
		return
	}
	if node.kind == .index_assign && tc.reject_unlowered_map_mutation
		&& tc.index_assign_lhs_is_map(node) {
		if tc.should_diagnose(id) {
			tc.record_error(.assignment_mismatch,
				'internal compiler error: unlowered map index assignment reached post-transform checker',
				id)
		}
		for i := 1; i < node.children_count; i += 2 {
			tc.check_node(tc.a.child(&node, i))
		}
		return
	}
	if tc.check_multi_return_assign(id, node) {
		return
	}
	mut i := 0
	for i + 1 < node.children_count {
		lhs_id := tc.a.child(&node, i)
		rhs_id := tc.a.child(&node, i + 1)
		lhs_type := tc.resolve_lvalue_type(lhs_id)
		tc.check_node(rhs_id)
		rhs_type := tc.resolve_expr(rhs_id, lhs_type)
		if !tc.type_compatible(rhs_type, lhs_type) {
			tc.type_mismatch(.assignment_mismatch,
				'cannot assign `${rhs_type.name()}` to `${lhs_type.name()}`', id)
		}
		i += 2
	}
}

fn (tc &TypeChecker) index_assign_lhs_is_map(node flat.Node) bool {
	if node.children_count == 0 {
		return false
	}
	lhs_id := tc.a.child(&node, 0)
	if int(lhs_id) < 0 {
		return false
	}
	lhs := tc.a.nodes[int(lhs_id)]
	if lhs.kind != .index || lhs.children_count < 2 {
		return false
	}
	base_type := unwrap_pointer(tc.resolve_type(tc.a.child(&lhs, 0)))
	return base_type is Map
}

fn (mut tc TypeChecker) check_multi_return_assign(id flat.NodeId, node flat.Node) bool {
	if node.children_count < 3 {
		return false
	}
	rhs_id := tc.a.child(&node, 1)
	rhs_type := tc.resolve_type(rhs_id)
	rhs_type_name := rhs_type.name()
	if rhs_type is MultiReturn {
		tc.check_node(rhs_id)
		lhs_ids := tc.multi_assign_lhs_ids(node)
		if lhs_ids.len != rhs_type.types.len {
			if tc.should_diagnose(id) {
				tc.record_error(.assignment_mismatch,
					'multi-return assignment mismatch: ${lhs_ids.len} variables but `${rhs_type_name}` has ${rhs_type.types.len} values',
					id)
			}
			return true
		}
		for i, lhs_id in lhs_ids {
			lhs_type := tc.resolve_lvalue_type(lhs_id)
			if !tc.type_compatible(rhs_type.types[i], lhs_type) {
				tc.type_mismatch(.assignment_mismatch,
					'cannot assign `${rhs_type.types[i].name()}` to `${lhs_type.name()}`', id)
			}
		}
		return true
	}
	return false
}

fn (mut tc TypeChecker) check_postfix(id flat.NodeId, node flat.Node) {
	if node.children_count == 0 {
		return
	}
	child_id := tc.a.child(&node, 0)
	tc.check_node(child_id)
	child := tc.a.nodes[int(child_id)]
	if child.kind == .index && child.children_count >= 2 {
		base_type := unwrap_pointer(tc.resolve_type(tc.a.child(&child, 0)))
		if base_type is Map && node.op in [.inc, .dec] && tc.reject_unlowered_map_mutation
			&& tc.should_diagnose(id) {
			tc.record_error(.assignment_mismatch,
				'internal compiler error: unlowered map index postfix mutation reached post-transform checker',
				id)
		}
	}
}

fn (mut tc TypeChecker) resolve_lvalue_type(lhs_id flat.NodeId) Type {
	if int(lhs_id) < 0 {
		return Type(void_)
	}
	lhs := tc.a.nodes[int(lhs_id)]
	if lhs.kind == .ident {
		if typ := tc.cur_scope.lookup(lhs.value) {
			return typ
		}
		if typ := tc.file_scope.lookup(lhs.value) {
			return typ
		}
		if tc.should_diagnose(lhs_id) && lhs.value != '_' {
			tc.record_error(.unknown_ident, 'unknown identifier `${lhs.value}`', lhs_id)
		}
		return unknown_type('unknown identifier `${lhs.value}`')
	}
	if lhs.kind == .selector {
		tc.check_selector(lhs_id, lhs)
		return tc.resolve_type(lhs_id)
	}
	if lhs.kind == .index {
		tc.check_index(lhs_id, lhs)
		return tc.resolve_type(lhs_id)
	}
	return tc.resolve_type(lhs_id)
}

fn (mut tc TypeChecker) check_return(id flat.NodeId, node flat.Node) {
	expected := tc.cur_fn_ret_type
	if expected is Void {
		if node.children_count > 0 && tc.should_diagnose(id) {
			tc.record_error(.return_mismatch, 'void function should not return a value', id)
		}
		for i in 0 .. node.children_count {
			tc.check_node(tc.a.child(&node, i))
		}
		return
	}
	if node.children_count == 0 {
		if tc.should_diagnose(id) {
			tc.record_error(.return_mismatch, 'missing return value of type `${expected.name()}`',
				id)
		}
		return
	}
	if expected is MultiReturn {
		if node.children_count != expected.types.len {
			if tc.should_diagnose(id) {
				tc.record_error(.return_mismatch,
					'return value count mismatch: expected ${expected.types.len}, got ${node.children_count}',
					id)
			}
			return
		}
		for i in 0 .. node.children_count {
			child_id := tc.a.child(&node, i)
			tc.check_node(child_id)
			actual := tc.resolve_expr(child_id, expected.types[i])
			if !tc.type_compatible(actual, expected.types[i]) {
				tc.type_mismatch(.return_mismatch,
					'cannot return `${actual.name()}` as `${expected.types[i].name()}`', id)
			}
		}
		return
	}
	if node.children_count != 1 {
		if tc.should_diagnose(id) {
			tc.record_error(.return_mismatch,
				'return value count mismatch: expected 1, got ${node.children_count}', id)
		}
		return
	}
	child_id := tc.a.child(&node, 0)
	tc.check_node(child_id)
	actual := tc.resolve_expr(child_id, expected)
	if !tc.type_compatible(actual, expected) {
		tc.type_mismatch(.return_mismatch,
			'cannot return `${actual.name()}` as `${expected.name()}`', id)
	}
}

fn (mut tc TypeChecker) check_call(id flat.NodeId, node flat.Node) {
	if info := tc.resolve_call_info(id, node) {
		if info.name.len > 0 {
			tc.resolved_calls[int(id)] = info.name
		}
		tc.check_call_arg_types(id, node, info)
		return
	}
	if tc.should_diagnose(id) && !tc.is_known_call(node) {
		tc.record_error(.unknown_fn, 'unknown function `${tc.call_display_name(node)}`', id)
	}
	for i in 1 .. node.children_count {
		tc.check_node(tc.call_arg_value(tc.a.child(&node, i)))
	}
}

fn (tc &TypeChecker) should_diagnose(id flat.NodeId) bool {
	if int(id) < 0 || int(id) < tc.a.user_code_start {
		return false
	}
	if int(id) < tc.a.nodes.len && !tc.a.nodes[int(id)].pos.is_valid() && !tc.diagnose_unknown_calls {
		return false
	}
	if tc.diagnostic_files.len == 0 {
		return true
	}
	return tc.cur_file in tc.diagnostic_files
}

fn (tc &TypeChecker) should_diagnose_unknown_call(id flat.NodeId) bool {
	return tc.diagnose_unknown_calls && tc.should_diagnose(id)
}

fn (mut tc TypeChecker) resolve_call_info(_id flat.NodeId, node flat.Node) ?CallInfo {
	if node.children_count == 0 {
		return none
	}
	fn_node := tc.a.child_node(&node, 0)
	if fn_node.kind == .selector {
		base_id := tc.a.child(fn_node, 0)
		base_node := tc.a.nodes[int(base_id)]
		if base_node.kind == .ident && base_node.value == 'C' {
			return none
		}
		if base_node.kind == .ident {
			resolved_mod := if base_node.value in tc.imports {
				tc.imports[base_node.value]
			} else {
				base_node.value
			}
			mod_name := '${resolved_mod}.${fn_node.value}'
			if mod_name in tc.fn_ret_types {
				return tc.call_info(mod_name, false)
			}
			qbase := tc.qualify_name(base_node.value)
			static_name := '${qbase}.${fn_node.value}'
			if static_name in tc.fn_ret_types && (qbase in tc.structs
				|| qbase in tc.enum_names || qbase in tc.sum_types
				|| qbase in tc.interface_names) {
				return tc.call_info(static_name, false)
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
					return tc.call_info(full_name, false)
				}
			}
		}
		base_type := tc.resolve_type(base_id)
		clean := unwrap_pointer(base_type)
		if clean is Array && fn_node.value == 'clone' {
			return CallInfo{
				name:         'array_clone'
				params:       tarr1(base_type)
				return_type:  base_type
				has_receiver: true
				params_known: true
			}
		}
		if clean is Array {
			match fn_node.value {
				'first', 'last', 'pop' {
					return CallInfo{
						name:         ''
						params:       tarr1(base_type)
						return_type:  clean.elem_type
						has_receiver: true
						params_known: true
					}
				}
				'contains' {
					return CallInfo{
						name:         ''
						params:       tarr2(base_type, clean.elem_type)
						return_type:  Type(bool_)
						has_receiver: true
						params_known: true
					}
				}
				'index', 'last_index' {
					return CallInfo{
						name:         ''
						params:       tarr2(base_type, clean.elem_type)
						return_type:  Type(int_)
						has_receiver: true
						params_known: true
					}
				}
				'delete' {
					return CallInfo{
						name:         ''
						params:       tarr2(Type(Pointer{
							base_type: base_type
						}), Type(int_))
						return_type:  Type(void_)
						has_receiver: true
						params_known: true
					}
				}
				'delete_last', 'clear' {
					return CallInfo{
						name:         ''
						params:       tarr1(Type(Pointer{
							base_type: base_type
						}))
						return_type:  Type(void_)
						has_receiver: true
						params_known: true
					}
				}
				else {}
			}
		}
		type_name := resolve_type_name_for_method(clean)
		if type_name.len > 0 {
			mname := '${type_name}.${fn_node.value}'
			if mname in tc.fn_ret_types {
				return tc.call_info(mname, true)
			}
		}
		if clean is SumType {
			mname := '${clean.name}.${fn_node.value}'
			if mname in tc.fn_ret_types {
				return tc.call_info(mname, true)
			}
		}
		if clean is Enum {
			mname := '${clean.name}.${fn_node.value}'
			if mname in tc.fn_ret_types {
				return tc.call_info(mname, true)
			}
		}
		return none
	}
	if fn_node.kind == .ident {
		if typ := tc.cur_scope.lookup(fn_node.value) {
			if typ is FnType {
				return CallInfo{
					name:         ''
					params:       typ.params
					return_type:  typ.return_type
					params_known: true
				}
			}
		}
		qfn := tc.qualify_fn_name(fn_node.value)
		if qfn in tc.fn_ret_types {
			return tc.call_info(qfn, false)
		}
		if fn_node.value in tc.fn_ret_types {
			return tc.call_info(fn_node.value, false)
		}
		for _, imp in tc.imports {
			imp_name := '${imp}.${fn_node.value}'
			if imp_name in tc.fn_ret_types {
				return tc.call_info(imp_name, false)
			}
		}
	}
	return none
}

fn (tc &TypeChecker) call_info(name string, has_receiver bool) CallInfo {
	mut params := []Type{}
	mut params_known := false
	if p := tc.fn_param_types[name] {
		params = p.clone()
		params_known = true
	}
	return CallInfo{
		name:         name
		params:       params
		return_type:  tc.fn_ret_types[name] or { unknown_type('unknown return type for `${name}`') }
		has_receiver: has_receiver
		is_variadic:  tc.fn_variadic[name] or { false }
		params_known: params_known
	}
}

fn (mut tc TypeChecker) check_call_arg_types(id flat.NodeId, node flat.Node, info CallInfo) {
	if node.children_count == 0 {
		return
	}
	if info.name.starts_with('map.') {
		for i in 1 .. node.children_count {
			tc.check_node(tc.call_arg_value(tc.a.child(&node, i)))
		}
		return
	}
	if !info.params_known {
		for i in 1 .. node.children_count {
			tc.check_node(tc.call_arg_value(tc.a.child(&node, i)))
		}
		return
	}
	actual_count := node.children_count - 1 + if info.has_receiver { 1 } else { 0 }
	min_count := if info.is_variadic && info.params.len > 0 {
		info.params.len - 1
	} else {
		info.params.len
	}
	if actual_count < min_count || (!info.is_variadic && actual_count != info.params.len) {
		if tc.should_diagnose(id) {
			tc.record_error(.call_arg_mismatch,
				'argument count mismatch for `${tc.call_display_name(node)}`: expected ${info.params.len}, got ${actual_count}',
				id)
		}
		for i in 1 .. node.children_count {
			tc.check_node(tc.call_arg_value(tc.a.child(&node, i)))
		}
		return
	}
	if info.has_receiver && info.params.len > 0 {
		fn_node := tc.a.child_node(&node, 0)
		recv_id := tc.a.child(fn_node, 0)
		tc.check_node(recv_id)
		recv_type := tc.resolve_expr(recv_id, info.params[0])
		if !tc.receiver_compatible(recv_type, info.params[0]) {
			tc.type_mismatch(.call_arg_mismatch,
				'cannot use receiver `${recv_type.name()}` as `${info.params[0].name()}`', id)
		}
	}
	for i in 1 .. node.children_count {
		arg_id := tc.call_arg_value(tc.a.child(&node, i))
		tc.check_node(arg_id)
		param_idx := if info.has_receiver { i } else { i - 1 }
		if param_idx >= info.params.len {
			if info.is_variadic && info.params.len > 0 {
				variadic_type := info.params[info.params.len - 1]
				if variadic_type is Array {
					actual := tc.resolve_expr(arg_id, variadic_type.elem_type)
					if !tc.receiver_compatible(actual, variadic_type.elem_type) {
						tc.type_mismatch(.call_arg_mismatch, 'cannot use `${actual.name()}` as argument ${
							param_idx + 1} to `${tc.call_display_name(node)}`; expected `${variadic_type.elem_type.name()}`',
							id)
					}
				}
			}
			continue
		}
		mut expected := info.params[param_idx]
		if tc.is_zero_literal(arg_id) && is_fn_pointer_type(expected) {
			continue
		}
		if info.is_variadic && param_idx == info.params.len - 1 && expected is Array {
			actual := tc.resolve_expr(arg_id, expected)
			actual_name := actual.name()
			expected_name := '[]${expected.elem_type.name()}'
			if actual is Array {
				if !tc.receiver_compatible(actual, expected) {
					tc.type_mismatch(.call_arg_mismatch, 'cannot use `${actual_name}` as argument ${
						param_idx + 1} to `${tc.call_display_name(node)}`; expected `${expected_name}`',
						id)
				}
				continue
			}
			expected = expected.elem_type
		}
		actual := tc.resolve_expr(arg_id, expected)
		if !tc.receiver_compatible(actual, expected) {
			tc.type_mismatch(.call_arg_mismatch, 'cannot use `${actual.name()}` as argument ${
				param_idx + 1} to `${tc.call_display_name(node)}`; expected `${expected.name()}`',
				id)
		}
	}
}

fn (tc &TypeChecker) call_arg_value(id flat.NodeId) flat.NodeId {
	if int(id) < 0 {
		return id
	}
	node := tc.a.nodes[int(id)]
	if node.kind == .field_init && node.children_count > 0 {
		return tc.a.child(&node, 0)
	}
	return id
}

fn (tc &TypeChecker) receiver_compatible(actual Type, expected Type) bool {
	if tc.type_compatible(actual, expected) {
		return true
	}
	if expected is Pointer {
		return tc.type_compatible(actual, expected.base_type)
	}
	if actual is Pointer {
		return tc.type_compatible(actual.base_type, expected)
	}
	return false
}

fn (tc &TypeChecker) is_zero_literal(id flat.NodeId) bool {
	if int(id) < 0 {
		return false
	}
	node := tc.a.nodes[int(id)]
	return node.kind == .int_literal && node.value == '0'
}

fn is_fn_pointer_type(typ Type) bool {
	mut clean := typ
	if clean is Alias {
		clean = clean.base_type
	}
	return clean is FnType
}

fn (tc &TypeChecker) is_known_call(node flat.Node) bool {
	if node.children_count == 0 {
		return true
	}
	if node.typ.len > 0 {
		return true
	}
	fn_node := tc.a.child_node(&node, 0)
	if fn_node.kind == .selector {
		base_node := tc.a.child_node(fn_node, 0)
		if base_node.kind == .ident {
			if base_node.value == 'C' {
				return true
			}
			resolved_mod := if base_node.value in tc.imports {
				tc.imports[base_node.value]
			} else {
				base_node.value
			}
			mod_name := '${resolved_mod}.${fn_node.value}'
			if mod_name in tc.fn_ret_types || mod_name in tc.sum_types || mod_name in tc.structs
				|| mod_name in tc.enum_names {
				return true
			}
			if base_node.value in tc.structs || base_node.value in tc.enum_names {
				qname := tc.qualify_name(base_node.value)
				if '${qname}.${fn_node.value}' in tc.fn_ret_types {
					return true
				}
			} else {
				qname := tc.qualify_name(base_node.value)
				if qname in tc.structs || qname in tc.enum_names {
					if '${qname}.${fn_node.value}' in tc.fn_ret_types {
						return true
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
				if '${mod_name}.${base_node.value}.${fn_node.value}' in tc.fn_ret_types {
					return true
				}
			}
		}
		base_type := tc.resolve_type(tc.a.child(fn_node, 0))
		clean_type := unwrap_pointer(base_type)
		if clean_type is Array || clean_type is ArrayFixed || clean_type is Map {
			return true
		}
		if clean_type is String {
			return 'string.${fn_node.value}' in tc.fn_ret_types
		}
		if clean_type is Alias {
			mname := '${clean_type.name}.${fn_node.value}'
			if mname in tc.fn_ret_types {
				return true
			}
			base_name := resolve_type_name_for_method(clean_type.base_type)
			if base_name.len > 0 {
				return '${base_name}.${fn_node.value}' in tc.fn_ret_types
			}
		}
		if clean_type is Struct {
			return '${clean_type.name}.${fn_node.value}' in tc.fn_ret_types
		}
		if clean_type is Interface {
			return '${clean_type.name}.${fn_node.value}' in tc.fn_ret_types
		}
		if clean_type is SumType {
			return '${clean_type.name}.${fn_node.value}' in tc.fn_ret_types
		}
		if clean_type is Enum {
			return '${clean_type.name}.${fn_node.value}' in tc.fn_ret_types
		}
		if clean_type is Primitive {
			mname := '${prim_c_type_from(clean_type.props, clean_type.size)}.${fn_node.value}'
			return mname in tc.fn_ret_types
		}
		return false
	}
	if fn_node.kind == .ident {
		if typ := tc.cur_scope.lookup(fn_node.value) {
			return typ is FnType
		}
		qfn := tc.qualify_fn_name(fn_node.value)
		if qfn in tc.fn_ret_types || fn_node.value in tc.fn_ret_types {
			return true
		}
		for _, imp in tc.imports {
			if '${imp}.${fn_node.value}' in tc.fn_ret_types {
				return true
			}
		}
	}
	return false
}

fn (tc &TypeChecker) call_display_name(node flat.Node) string {
	if node.children_count == 0 {
		return '<missing>'
	}
	fn_node := tc.a.child_node(&node, 0)
	if fn_node.kind == .ident {
		return fn_node.value
	}
	if fn_node.kind == .selector && fn_node.children_count > 0 {
		base := tc.a.child_node(fn_node, 0)
		if base.value.len > 0 {
			return '${base.value}.${fn_node.value}'
		}
	}
	return fn_node.value
}

fn (mut tc TypeChecker) check_if_expr(id flat.NodeId, node flat.Node) {
	if node.children_count < 2 {
		return
	}
	cond_id := tc.a.child(&node, 0)
	guard_bindings := tc.check_condition(cond_id)
	smartcasts := tc.extract_smartcasts(cond_id)
	then_id := tc.a.child(&node, 1)
	saved_smartcasts := tc.smartcasts.clone()
	for sc in smartcasts {
		tc.smartcasts[sc.name] = sc.typ
	}
	tc.push_scope()
	for binding in guard_bindings {
		tc.cur_scope.insert(binding.name, binding.typ)
	}
	tc.check_node(then_id)
	then_type := tc.branch_tail_type(then_id)
	tc.pop_scope()
	tc.smartcasts = saved_smartcasts.clone()
	mut else_type := Type(void_)
	if node.children_count > 2 {
		else_id := tc.a.child(&node, 2)
		tc.check_node(else_id)
		else_type = tc.branch_tail_type(else_id)
	}
	if then_type !is Void && else_type !is Void {
		if tc.branch_has_value_tail(then_id) && tc.branch_has_value_tail(tc.a.child(&node, 2))
			&& !tc.type_compatible(then_type, else_type)
			&& !tc.type_compatible(else_type, then_type) {
			if tc.should_diagnose(id) {
				tc.record_error(.if_branch_mismatch,
					'if-expression branch type mismatch: then `${then_type.name()}` vs else `${else_type.name()}`',
					id)
			}
		}
	}
}

fn (tc &TypeChecker) branch_has_value_tail(id flat.NodeId) bool {
	if !tc.valid_node_id(id) {
		return false
	}
	node := tc.a.nodes[int(id)]
	if node.kind == .block {
		if node.children_count == 0 {
			return false
		}
		last_id := tc.a.child(&node, node.children_count - 1)
		if !tc.valid_node_id(last_id) {
			return false
		}
		last := tc.a.nodes[int(last_id)]
		return last.kind == .expr_stmt
	}
	if node.kind == .match_branch {
		body_start := if node.value == 'else' { 0 } else { node.value.int() }
		if node.children_count <= body_start {
			return false
		}
		last_id := tc.a.child(&node, node.children_count - 1)
		if !tc.valid_node_id(last_id) {
			return false
		}
		last := tc.a.nodes[int(last_id)]
		return last.kind == .expr_stmt
	}
	return node.kind !in [.assign, .decl_assign, .selector_assign, .index_assign, .return_stmt,
		.block]
}

fn (mut tc TypeChecker) check_condition(cond_id flat.NodeId) []LocalBinding {
	if int(cond_id) < 0 {
		return []LocalBinding{}
	}
	cond := tc.a.nodes[int(cond_id)]
	if cond.kind == .decl_assign {
		return tc.check_if_guard(cond_id, cond)
	}
	tc.check_bool_condition(cond_id)
	return []LocalBinding{}
}

fn (mut tc TypeChecker) check_bool_condition(cond_id flat.NodeId) {
	tc.check_node(cond_id)
	cond_type := tc.resolve_type(cond_id)
	if !tc.type_compatible(cond_type, Type(bool_)) && tc.should_diagnose(cond_id) {
		tc.record_error(.condition_mismatch,
			'if condition must be `bool`, not `${cond_type.name()}`', cond_id)
	}
}

fn (mut tc TypeChecker) check_if_guard(id flat.NodeId, node flat.Node) []LocalBinding {
	if node.children_count < 2 {
		return []LocalBinding{}
	}
	lhs_id := tc.a.child(&node, 0)
	rhs_id := tc.a.child(&node, 1)
	tc.check_node(rhs_id)
	rhs_type := tc.resolve_type(rhs_id)
	mut payload := Type(void_)
	if rhs_type is OptionType {
		payload = rhs_type.base_type
	} else if rhs_type is ResultType {
		payload = rhs_type.base_type
	} else {
		rhs := tc.a.nodes[int(rhs_id)]
		if rhs.kind == .index && rhs.children_count > 0 {
			base_type := unwrap_pointer(tc.resolve_type(tc.a.child(&rhs, 0)))
			if base_type is Map {
				payload = base_type.value_type
			}
		}
	}
	if payload is Void {
		if tc.should_diagnose(id) {
			tc.record_error(.condition_mismatch,
				'if guard expression must be optional or result, not `${rhs_type.name()}`', id)
		}
	}
	lhs := tc.a.nodes[int(lhs_id)]
	if lhs.kind == .ident && lhs.value.len > 0 && payload !is Void {
		mut result := []LocalBinding{}
		result << LocalBinding{
			name: lhs.value
			typ:  payload
		}
		return result
	}
	return []LocalBinding{}
}

fn (mut tc TypeChecker) check_match_stmt(_id flat.NodeId, node flat.Node) {
	if node.children_count == 0 {
		return
	}
	subject_id := tc.a.child(&node, 0)
	tc.check_node(subject_id)
	subject_key := tc.expr_key(subject_id)
	for i in 1 .. node.children_count {
		branch_id := tc.a.child(&node, i)
		branch := tc.a.child_node(&node, i)
		if branch.kind != .match_branch {
			tc.check_node(branch_id)
			continue
		}
		n_conds := if branch.value == 'else' { 0 } else { branch.value.int() }
		saved_smartcasts := tc.smartcasts.clone()
		if subject_key.len > 0 && n_conds == 1 && branch.children_count > 0 {
			cond_id := tc.a.child(branch, 0)
			cond := tc.a.node(cond_id)
			if cond.kind == .ident || cond.kind == .selector {
				tc.smartcasts[subject_key] = tc.parse_type(cond.value)
			}
		}
		tc.push_scope()
		for j in n_conds .. branch.children_count {
			tc.check_node(tc.a.child(branch, j))
		}
		tc.pop_scope()
		tc.smartcasts = saved_smartcasts.clone()
	}
}

fn (mut tc TypeChecker) check_is_expr(id flat.NodeId, node flat.Node) {
	if node.children_count == 0 {
		return
	}
	expr_id := tc.a.child(&node, 0)
	tc.check_node(expr_id)
	expr_type := unwrap_pointer(tc.resolve_type(expr_id))
	if expr_type is SumType || expr_type is Interface || expr_type is Unknown {
		return
	}
	if tc.should_diagnose(id) {
		tc.record_error(.condition_mismatch,
			'`is` can only be used with sum type or interface values, not `${expr_type.name()}`',
			id)
	}
}

fn (tc &TypeChecker) branch_tail_type(id flat.NodeId) Type {
	if !tc.valid_node_id(id) {
		return Type(void_)
	}
	node := tc.a.nodes[int(id)]
	if node.kind == .block {
		if node.children_count == 0 {
			return Type(void_)
		}
		last_id := tc.a.child(&node, node.children_count - 1)
		if !tc.valid_node_id(last_id) {
			return Type(void_)
		}
		last := tc.a.nodes[int(last_id)]
		if last.kind == .expr_stmt && last.children_count > 0 {
			return tc.resolve_type(tc.a.child(&last, 0))
		}
		return tc.resolve_type(last_id)
	}
	if node.kind == .match_branch {
		body_start := if node.value == 'else' { 0 } else { node.value.int() }
		if node.children_count <= body_start {
			return Type(void_)
		}
		last_id := tc.a.child(&node, node.children_count - 1)
		if !tc.valid_node_id(last_id) {
			return Type(void_)
		}
		last := tc.a.nodes[int(last_id)]
		if last.kind == .expr_stmt && last.children_count > 0 {
			return tc.resolve_type(tc.a.child(&last, 0))
		}
		return tc.resolve_type(last_id)
	}
	return tc.resolve_type(id)
}

fn (tc &TypeChecker) extract_smartcasts(cond_id flat.NodeId) []LocalBinding {
	if int(cond_id) < 0 {
		return []LocalBinding{}
	}
	cond := tc.a.nodes[int(cond_id)]
	if cond.kind == .is_expr && cond.children_count > 0 {
		expr_id := tc.a.child(&cond, 0)
		key := tc.expr_key(expr_id)
		if key.len > 0 && cond.value.len > 0 {
			mut result := []LocalBinding{}
			result << LocalBinding{
				name: key
				typ:  tc.parse_type(cond.value)
			}
			return result
		}
	}
	if cond.kind == .infix && cond.op == .logical_and && cond.children_count >= 2 {
		mut result := tc.extract_smartcasts(tc.a.child(&cond, 0))
		result << tc.extract_smartcasts(tc.a.child(&cond, 1))
		return result
	}
	return []LocalBinding{}
}

fn (mut tc TypeChecker) check_struct_init(id flat.NodeId, node flat.Node) {
	init_type := tc.parse_type(node.value)
	if init_type is Struct {
		fields := tc.structs[init_type.name] or { []StructField{} }
		for i in 0 .. node.children_count {
			field_id := tc.a.child(&node, i)
			field := tc.a.nodes[int(field_id)]
			if field.kind != .field_init || field.children_count == 0 {
				tc.check_node(field_id)
				continue
			}
			value_id := tc.a.child(&field, 0)
			mut expected := Type(void_)
			if field.value.len > 0 {
				mut found := false
				for f in fields {
					if f.name == field.value {
						expected = f.typ
						found = true
						break
					}
				}
				if !found && tc.should_diagnose(field_id) && fields.len > 0 {
					tc.record_error(.unknown_field,
						'unknown field `${field.value}` in `${init_type.name}`', field_id)
				}
			} else if i < fields.len {
				expected = fields[i].typ
			}
			tc.check_node(value_id)
			if expected !is Void {
				actual := tc.resolve_expr(value_id, expected)
				if !tc.type_compatible(actual, expected) {
					tc.type_mismatch(.assignment_mismatch,
						'cannot initialize field `${field.value}` with `${actual.name()}`; expected `${expected.name()}`',
						field_id)
				}
			}
		}
		return
	}
	for i in 0 .. node.children_count {
		tc.check_node(tc.a.child(&node, i))
	}
	_ = id
}

fn (mut tc TypeChecker) check_selector(id flat.NodeId, node flat.Node) {
	if node.children_count == 0 {
		return
	}
	base_id := tc.a.child(&node, 0)
	base := tc.a.nodes[int(base_id)]
	if tc.is_namespace_selector(node, base) {
		return
	}
	tc.check_node(base_id)
	if _ := tc.selector_type(id, node) {
		return
	} else {
		if tc.should_diagnose(id) {
			base_type := tc.resolve_type(base_id)
			if base_type is Unknown {
				return
			}
			tc.record_error(.unknown_field,
				'unknown field `${node.value}` on `${base_type.name()}`', id)
		}
	}
}

fn (tc &TypeChecker) is_namespace_selector(node flat.Node, base flat.Node) bool {
	if base.kind != .ident {
		return false
	}
	if base.value == 'C' || base.value in tc.imports {
		return true
	}
	qbase := tc.qualify_name(base.value)
	if qbase in tc.structs || qbase in tc.enum_names || qbase in tc.sum_types
		|| qbase in tc.interface_names {
		return true
	}
	qname := '${qbase}.${node.value}'
	return qname in tc.const_types || qname in tc.fn_ret_types || qname in tc.enum_names
}

fn (tc &TypeChecker) selector_type(_id flat.NodeId, node flat.Node) ?Type {
	if node.children_count == 0 {
		return none
	}
	base_id := tc.a.child(&node, 0)
	base_type := tc.resolve_type(base_id)
	mut clean := unwrap_pointer(base_type)
	if clean is Alias {
		clean = clean.base_type
	}
	clean_name := clean.name()
	if typ := option_result_selector_type(clean, node.value) {
		return typ
	}
	if node.value == 'len' {
		if clean is Array || clean is Map || clean is String || clean is ArrayFixed {
			return Type(int_)
		}
	}
	if clean is Struct {
		if fields := tc.structs[clean_name] {
			for f in fields {
				if f.name == node.value {
					return f.typ
				}
			}
		}
	}
	if clean is MultiReturn {
		if typ := multi_return_selector_type(clean, node.value) {
			return typ
		}
	}
	if clean_name == 'IError' || clean_name.ends_with('.IError') {
		if node.value == 'message' {
			return Type(String{})
		}
		if node.value == '_object' {
			return tc.parse_type('voidptr')
		}
	}
	if clean is SumType {
		if typ := tc.lowered_sum_selector_type(clean, node.value) {
			return typ
		}
		variants := tc.sum_types[clean.name] or { []string{} }
		for variant in variants {
			fields := tc.structs[variant] or { []StructField{} }
			for f in fields {
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
		if fields := tc.structs[sname] {
			for f in fields {
				if f.name == node.value {
					return f.typ
				}
			}
		}
	}
	return none
}

fn multi_return_selector_type(typ MultiReturn, field string) ?Type {
	if !field.starts_with('arg') || field.len <= 3 {
		return none
	}
	idx_str := field[3..]
	idx := idx_str.int()
	if idx_str != idx.str() || idx < 0 || idx >= typ.types.len {
		return none
	}
	return typ.types[idx]
}

fn (tc &TypeChecker) lowered_sum_selector_type(sum SumType, field string) ?Type {
	if field == 'typ' {
		return Type(int_)
	}
	variants := tc.sum_types[sum.name] or { return none }
	for variant in variants {
		short := if variant.contains('.') { variant.all_after_last('.') } else { variant }
		if field == variant || field == short || field == c_name(variant) {
			return tc.parse_type(variant)
		}
	}
	return none
}

fn option_result_selector_type(typ Type, field string) ?Type {
	if typ is OptionType {
		if field == 'ok' {
			return Type(bool_)
		}
		if field == 'value' {
			return typ.base_type
		}
	}
	if typ is ResultType {
		if field == 'ok' {
			return Type(bool_)
		}
		if field == 'value' {
			return typ.base_type
		}
	}
	return none
}

fn (mut tc TypeChecker) check_index(id flat.NodeId, node flat.Node) {
	if node.children_count == 0 {
		return
	}
	base_id := tc.a.child(&node, 0)
	tc.check_node(base_id)
	mut base_type := unwrap_pointer(tc.resolve_type(base_id))
	if base_type is Alias {
		base_type = base_type.base_type
	}
	if node.value == 'range' {
		if !(base_type is Array || base_type is ArrayFixed || base_type is String)
			&& tc.should_diagnose(id) {
			tc.record_error(.cannot_index, 'cannot slice `${base_type.name()}`', id)
		}
		for i in 1 .. node.children_count {
			bound_id := tc.a.child(&node, i)
			if int(bound_id) >= 0 {
				bound := tc.a.nodes[int(bound_id)]
				if bound.kind == .empty {
					continue
				}
				tc.check_node(bound_id)
				bound_type := tc.resolve_type(bound_id)
				if bound_type !is Unknown && !bound_type.is_integer() {
					tc.type_mismatch(.cannot_index,
						'slice bound must be integer, not `${bound_type.name()}`', bound_id)
				}
			}
		}
		return
	}
	if node.children_count > 1 {
		index_id := tc.a.child(&node, 1)
		tc.check_node(index_id)
		if base_type is Map {
			actual_key := tc.resolve_expr(index_id, base_type.key_type)
			if !tc.type_compatible(actual_key, base_type.key_type) {
				tc.type_mismatch(.cannot_index,
					'map key must be `${base_type.key_type.name()}`, not `${actual_key.name()}`',
					index_id)
			}
			return
		}
		index_type := tc.resolve_type(index_id)
		if index_type !is Unknown && !index_type.is_integer() {
			tc.type_mismatch(.cannot_index, 'index must be integer, not `${index_type.name()}`',
				index_id)
		}
	}
	if !(base_type is Array || base_type is ArrayFixed || base_type is String
		|| base_type is Map || base_type is Unknown) && tc.should_diagnose(id) {
		tc.record_error(.cannot_index, 'cannot index `${base_type.name()}`', id)
	}
}

fn (mut tc TypeChecker) check_ident(id flat.NodeId, node flat.Node) {
	if node.value.len == 0 || node.value == '_' {
		return
	}
	if _ := tc.cur_scope.lookup(node.value) {
		return
	}
	if _ := tc.file_scope.lookup(node.value) {
		return
	}
	if node.value in tc.const_types || tc.qualify_name(node.value) in tc.const_types {
		return
	}
	if node.value in tc.fn_ret_types || tc.qualify_fn_name(node.value) in tc.fn_ret_types {
		return
	}
	if node.value in tc.imports || tc.qualify_name(node.value) in tc.structs
		|| tc.qualify_name(node.value) in tc.enum_names
		|| tc.qualify_name(node.value) in tc.sum_types
		|| tc.qualify_name(node.value) in tc.interface_names {
		return
	}
	if tc.should_diagnose(id) {
		tc.record_error(.unknown_ident, 'unknown identifier `${node.value}`', id)
	}
}

fn (mut tc TypeChecker) resolve_expr(id flat.NodeId, expected Type) Type {
	if int(id) < 0 {
		return unknown_type('missing expression')
	}
	node := tc.a.nodes[int(id)]
	if node.kind == .field_init && node.children_count > 0 {
		return tc.resolve_expr(tc.a.child(&node, 0), expected)
	}
	if node.kind == .none_expr {
		if expected is OptionType || expected is ResultType {
			tc.register_synth_type(id, expected)
			return expected
		}
	}
	if node.kind == .enum_val && expected is Enum {
		tc.register_synth_type(id, expected)
		return expected
	}
	if node.kind == .array_literal {
		if expected is Array && node.children_count == 0 {
			tc.register_synth_type(id, expected)
			return expected
		}
		if expected is ArrayFixed && node.children_count == 0 {
			tc.register_synth_type(id, expected)
			return expected
		}
	}
	if node.kind == .ident && expected is FnType {
		if tc.fn_value_matches(node.value, expected) {
			tc.register_synth_type(id, expected)
			return expected
		}
	}
	actual := tc.resolve_type(id)
	if tc.type_compatible(actual, expected) {
		if expected is SumType || expected is OptionType || expected is ResultType
			|| expected is Enum {
			tc.register_synth_type(id, expected)
			return expected
		}
	}
	return actual
}

fn (tc &TypeChecker) fn_value_matches(name string, expected Type) bool {
	if expected is FnType {
		actual := tc.fn_value_type(name) or { return false }
		if actual is FnType {
			if actual.params.len != expected.params.len {
				return false
			}
			for i, p in actual.params {
				if !tc.type_compatible(p, expected.params[i]) {
					return false
				}
			}
			return tc.type_compatible(actual.return_type, expected.return_type)
		}
	}
	return false
}

fn (tc &TypeChecker) fn_value_type(name string) ?Type {
	qfn := tc.qualify_fn_name(name)
	if qfn in tc.fn_ret_types {
		return tc.fn_type_from_key(qfn)
	}
	if name in tc.fn_ret_types {
		return tc.fn_type_from_key(name)
	}
	for _, imp in tc.imports {
		imp_name := '${imp}.${name}'
		if imp_name in tc.fn_ret_types {
			return tc.fn_type_from_key(imp_name)
		}
	}
	return none
}

fn (tc &TypeChecker) fn_type_from_key(key string) ?Type {
	params := tc.fn_param_types[key] or { return none }
	ret := tc.fn_ret_types[key] or { return none }
	return Type(FnType{
		params:      params.clone()
		return_type: ret
	})
}

fn (tc &TypeChecker) type_compatible(actual Type, expected Type) bool {
	if actual.name() == expected.name() {
		return true
	}
	if actual is Unknown || expected is Unknown {
		return true
	}
	if actual is Alias && expected is Alias {
		return tc.type_compatible(actual.base_type, expected.base_type)
	}
	if actual is Alias {
		return tc.type_compatible(actual.base_type, expected)
	}
	if expected is Alias {
		return tc.type_compatible(actual, expected.base_type)
	}
	if actual is None {
		return expected is OptionType || expected is ResultType
	}
	if expected is OptionType {
		if actual is OptionType {
			return tc.type_compatible(actual.base_type, expected.base_type)
		}
		return tc.type_compatible(actual, expected.base_type)
	}
	if expected is ResultType {
		if actual is ResultType {
			return tc.type_compatible(actual.base_type, expected.base_type)
		}
		return tc.type_compatible(actual, expected.base_type)
	}
	if expected is SumType {
		return tc.type_matches_sum(actual, expected)
	}
	if expected is Interface {
		return tc.type_implements_interface(actual, expected)
	}
	if actual is Interface {
		if expected is Interface {
			return tc.interface_implements_interface(actual.name, expected.name)
		}
		return false
	}
	if expected is Primitive {
		if actual is Primitive {
			if expected.props.has(.boolean) || actual.props.has(.boolean) {
				return expected.props.has(.boolean) && actual.props.has(.boolean)
			}
			if expected.props.has(.float) && actual.props.has(.integer) {
				return true
			}
			if expected.props.has(.integer) && actual.props.has(.integer) {
				return true
			}
			if expected.props.has(.float) && actual.props.has(.float) {
				return true
			}
		}
		if expected.props.has(.integer) && actual.is_integer() {
			return true
		}
	}
	if actual is Primitive && actual.props.has(.integer) && expected.is_integer() {
		return true
	}
	if expected is String {
		return actual is String
	}
	if expected is Char {
		return actual is Char || actual.name() == 'u8'
	}
	if expected is Pointer {
		if actual is Nil {
			return true
		}
		if actual is Pointer {
			if expected.base_type is Void || actual.base_type is Void {
				return true
			}
			return tc.type_compatible(actual.base_type, expected.base_type)
		}
	}
	if expected is Array {
		if actual is Array {
			return tc.type_compatible(actual.elem_type, expected.elem_type)
		}
		if actual is ArrayFixed {
			return tc.type_compatible(actual.elem_type, expected.elem_type)
		}
	}
	if expected is ArrayFixed {
		if actual is ArrayFixed {
			return actual.len == expected.len
				&& tc.type_compatible(actual.elem_type, expected.elem_type)
		}
	}
	if expected is Map {
		if actual is Map {
			return tc.type_compatible(actual.key_type, expected.key_type)
				&& tc.type_compatible(actual.value_type, expected.value_type)
		}
	}
	if expected is FnType {
		if actual is FnType {
			if actual.params.len != expected.params.len {
				return false
			}
			for i, p in actual.params {
				if !tc.type_compatible(p, expected.params[i]) {
					return false
				}
			}
			return tc.type_compatible(actual.return_type, expected.return_type)
		}
	}
	return false
}

fn (tc &TypeChecker) type_implements_interface(actual Type, expected Interface) bool {
	clean := unwrap_pointer(actual)
	if clean is Unknown {
		return true
	}
	if clean is Interface {
		return tc.interface_implements_interface(clean.name, expected.name)
	}
	concrete_name := method_type_name(clean)
	if concrete_name.len == 0 {
		return false
	}
	return tc.named_type_implements_interface(concrete_name, expected.name)
}

fn (tc &TypeChecker) interface_implements_interface(actual_name string, expected_name string) bool {
	if actual_name == expected_name {
		return true
	}
	for method in tc.interface_method_names(expected_name) {
		actual_key := '${actual_name}.${method}'
		expected_key := '${expected_name}.${method}'
		if actual_key !in tc.fn_param_types
			|| !tc.method_signature_compatible(actual_key, expected_key) {
			return false
		}
	}
	return true
}

fn (tc &TypeChecker) named_type_implements_interface(concrete_name string, iface_name string) bool {
	for method in tc.interface_method_names(iface_name) {
		concrete_key := '${concrete_name}.${method}'
		if concrete_key !in tc.fn_param_types {
			return false
		}
		expected_key := '${iface_name}.${method}'
		if !tc.method_signature_compatible(concrete_key, expected_key) {
			return false
		}
	}
	return true
}

fn (tc &TypeChecker) interface_method_names(iface_name string) []string {
	mut methods := []string{}
	prefix := '${iface_name}.'
	for key, _ in tc.fn_ret_types {
		if key.starts_with(prefix) {
			methods << key[prefix.len..]
		}
	}
	return methods
}

fn (tc &TypeChecker) method_signature_compatible(actual_key string, expected_key string) bool {
	actual_params := tc.fn_param_types[actual_key] or { return false }
	expected_params := tc.fn_param_types[expected_key] or { return false }
	if actual_params.len != expected_params.len {
		return false
	}
	for i in 1 .. actual_params.len {
		if !tc.type_compatible(actual_params[i], expected_params[i])
			|| !tc.type_compatible(expected_params[i], actual_params[i]) {
			return false
		}
	}
	actual_ret := tc.fn_ret_types[actual_key] or { Type(void_) }
	expected_ret := tc.fn_ret_types[expected_key] or { Type(void_) }
	return tc.type_compatible(actual_ret, expected_ret)
}

fn method_type_name(t Type) string {
	if t is Alias {
		return t.name
	}
	if t is Struct {
		return t.name
	}
	if t is Interface {
		return t.name
	}
	if t is SumType {
		return t.name
	}
	if t is Enum {
		return t.name
	}
	if t is String {
		return 'string'
	}
	if t is Primitive {
		return prim_c_type_from(t.props, t.size)
	}
	if t is ISize {
		return 'isize'
	}
	if t is USize {
		return 'usize'
	}
	if t is Rune {
		return 'rune'
	}
	return ''
}

fn (tc &TypeChecker) type_matches_sum(actual Type, expected Type) bool {
	if expected is SumType {
		variants := tc.sum_types[expected.name] or { return false }
		actual_name := actual.name()
		actual_short := short_type_name(actual_name)
		for variant in variants {
			if variant == actual_name || short_type_name(variant) == actual_short {
				return true
			}
		}
	}
	return false
}

fn short_type_name(name string) string {
	if name.contains('.') {
		return name.all_after_last('.')
	}
	return name
}

fn (mut tc TypeChecker) type_mismatch(kind TypeErrorKind, msg string, node flat.NodeId) {
	if tc.should_diagnose(node) {
		tc.record_error(kind, msg, node)
	}
}

fn (tc &TypeChecker) expr_key(id flat.NodeId) string {
	if int(id) < 0 {
		return ''
	}
	node := tc.a.nodes[int(id)]
	if node.kind == .ident {
		return node.value
	}
	if node.kind == .selector && node.children_count > 0 {
		base := tc.expr_key(tc.a.child(&node, 0))
		if base.len > 0 && node.value.len > 0 {
			return '${base}.${node.value}'
		}
	}
	return ''
}

fn (tc &TypeChecker) smartcast_type(id flat.NodeId) ?Type {
	key := tc.expr_key(id)
	if key.len == 0 {
		return none
	}
	if typ := tc.smartcasts[key] {
		return typ
	}
	return none
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
	qtyp := tc.qualify_name(typ)
	if typ == 'array' && tc.has_builtins && typ in tc.structs {
		return Type(Struct{
			name: typ
		})
	}
	if typ == 'map' && tc.has_builtins {
		return Type(Struct{
			name: typ
		})
	}
	if typ == 'array' && tc.has_builtins {
		return Type(Struct{
			name: typ
		})
	}
	if typ == 'strings.Builder'
		|| (typ == 'Builder' && tc.has_builtins && tc.cur_module == 'strings') {
		return Type(Alias{
			name:      typ
			base_type: tc.parse_type('[]u8')
		})
	}
	if is_builtin_type_name(typ) {
		return builtin_type_value(typ)
	}
	if typ == 'unknown' {
		return Type(Unknown{
			reason: 'unknown'
		})
	}
	if typ.starts_with('C.') {
		return Type(Struct{
			name: typ
		})
	}
	if qtyp in tc.type_aliases {
		return Type(Alias{
			name:      qtyp
			base_type: tc.parse_type(tc.type_aliases[qtyp])
		})
	}
	if qtyp in tc.structs {
		return Type(Struct{
			name: qtyp
		})
	}
	if typ in tc.type_aliases {
		return Type(Alias{
			name:      typ
			base_type: tc.parse_type(tc.type_aliases[typ])
		})
	}
	if typ in tc.interface_names {
		return Type(Interface{
			name: typ
		})
	}
	if qtyp in tc.interface_names {
		return Type(Interface{
			name: qtyp
		})
	}
	if typ in tc.structs {
		return Type(Struct{
			name: typ
		})
	}
	if qtyp in tc.structs {
		return Type(Struct{
			name: qtyp
		})
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
		return unknown_type('missing node')
	}
	node := tc.a.nodes[int(id)]
	if node.kind == .call && node.typ.len > 0 {
		return tc.parse_type(node.typ)
	}
	if t := tc.resolved_call_type(id) {
		return t
	}
	if node.kind == .or_expr {
		inner := tc.resolve_type(tc.a.child(&node, 0))
		if inner is OptionType {
			return inner.base_type
		}
		if inner is ResultType {
			return inner.base_type
		}
		return inner
	}
	if smart_type := tc.smartcast_type(id) {
		return smart_type
	}
	if node.kind == .index {
		return tc.resolve_index_type(node)
	}
	if node.kind != .ident && node.kind != .infix && node.kind != .selector
		&& !(tc.smartcasts.len > 0 && (node.kind == .ident || node.kind == .selector)) {
		if typ := tc.expr_types[int(id)] {
			return typ
		}
	}
	if node.typ.len > 0 && node.typ != 'unknown' {
		return tc.parse_type(node.typ)
	}
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
			if smart_type := tc.smartcast_type(id) {
				return smart_type
			}
			if typ := tc.cur_scope.lookup(node.value) {
				return typ
			}
			qname := tc.qualify_name(node.value)
			if qname in tc.const_types {
				return tc.const_types[qname] or { unknown_type('unknown const `${qname}`') }
			}
			if node.value in tc.const_types {
				return tc.const_types[node.value] or {
					unknown_type('unknown const `${node.value}`')
				}
			}
			if typ := tc.fn_value_type(node.value) {
				return typ
			}
			return unknown_type('unknown identifier `${node.value}`')
		}
		.call {
			fn_node := tc.a.child_node(&node, 0)
			if fn_node.kind == .ident {
				if typ := tc.cur_scope.lookup(fn_node.value) {
					if typ is FnType {
						return typ.return_type
					}
				}
			}
			if fn_node.kind == .selector {
				base_node := tc.a.child_node(fn_node, 0)
				if base_node.kind == .ident && base_node.value == 'C' {
					c_fn_name := 'C.${fn_node.value}'
					if c_fn_name in tc.fn_ret_types {
						return tc.fn_ret_types[c_fn_name] or {
							unknown_type('unknown return type for `${c_fn_name}`')
						}
					}
					if fn_node.value in tc.fn_ret_types {
						return tc.fn_ret_types[fn_node.value] or {
							unknown_type('unknown return type for `${fn_node.value}`')
						}
					}
					return Type(Struct{
						name: c_fn_name
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
						return tc.fn_ret_types[mod_name] or {
							unknown_type('unknown return type for `${mod_name}`')
						}
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
							return tc.fn_ret_types[sname] or {
								unknown_type('unknown return type for `${sname}`')
							}
						}
					} else {
						qname := tc.qualify_name(base_node.value)
						if qname in tc.structs || qname in tc.enum_names {
							sname := '${qname}.${fn_node.value}'
							if sname in tc.fn_ret_types {
								return tc.fn_ret_types[sname] or {
									unknown_type('unknown return type for `${sname}`')
								}
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
							return tc.fn_ret_types[full_name] or {
								unknown_type('unknown return type for `${full_name}`')
							}
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
					if fn_node.value == 'clone' {
						return base_type
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
							return tc.fn_ret_types[arr_mkey] or {
								unknown_type('unknown return type for `${arr_mkey}`')
							}
						}
					}
					if arr_mname1 in tc.fn_ret_types {
						return tc.fn_ret_types[arr_mname1] or {
							unknown_type('unknown return type for `${arr_mname1}`')
						}
					}
					return unknown_type('unknown array method `${fn_node.value}`')
				}
				if clean_type is Map {
					if fn_node.value == 'clone' {
						return base_type
					}
					return unknown_type('unknown map method `${fn_node.value}`')
				}
				if clean_type is String {
					mname := 'string.${fn_node.value}'
					if mname in tc.fn_ret_types {
						return tc.fn_ret_types[mname] or {
							unknown_type('unknown return type for `${mname}`')
						}
					}
				}
				if (clean_type is Void || clean_type is Primitive)
					&& fn_node.value in ['vstring', 'vstring_with_len'] {
					return Type(string_)
				}
				if clean_type is Alias {
					mname := '${clean_type.name}.${fn_node.value}'
					if mname in tc.fn_ret_types {
						return tc.fn_ret_types[mname] or {
							unknown_type('unknown return type for `${mname}`')
						}
					}
					base_name := resolve_type_name_for_method(clean_type.base_type)
					if base_name.len > 0 {
						base_mname := '${base_name}.${fn_node.value}'
						if base_mname in tc.fn_ret_types {
							return tc.fn_ret_types[base_mname] or {
								unknown_type('unknown return type for `${base_mname}`')
							}
						}
					}
				}
				if clean_type is Struct {
					mname := '${clean_type.name}.${fn_node.value}'
					if mname in tc.fn_ret_types {
						return tc.fn_ret_types[mname] or {
							unknown_type('unknown return type for `${mname}`')
						}
					}
				}
				if clean_type is Interface {
					mname := '${clean_type.name}.${fn_node.value}'
					if mname in tc.fn_ret_types {
						return tc.fn_ret_types[mname] or {
							unknown_type('unknown return type for `${mname}`')
						}
					}
				}
				if clean_type is SumType {
					mname := '${clean_type.name}.${fn_node.value}'
					if mname in tc.fn_ret_types {
						return tc.fn_ret_types[mname] or {
							unknown_type('unknown return type for `${mname}`')
						}
					}
				}
				if clean_type is Enum {
					mname := '${clean_type.name}.${fn_node.value}'
					if mname in tc.fn_ret_types {
						return tc.fn_ret_types[mname] or {
							unknown_type('unknown return type for `${mname}`')
						}
					}
				}
				if clean_type is Primitive {
					mname := '${prim_c_type_from(clean_type.props, clean_type.size)}.${fn_node.value}'
					if mname in tc.fn_ret_types {
						return tc.fn_ret_types[mname] or {
							unknown_type('unknown return type for `${mname}`')
						}
					}
				}
			}
			qfn := tc.qualify_fn_name(fn_node.value)
			if qfn in tc.fn_ret_types {
				return tc.fn_ret_types[qfn] or { unknown_type('unknown return type for `${qfn}`') }
			}
			if fn_node.value in tc.fn_ret_types {
				return tc.fn_ret_types[fn_node.value] or {
					unknown_type('unknown return type for `${fn_node.value}`')
				}
			}
			for _, imp in tc.imports {
				imp_name := '${imp}.${fn_node.value}'
				if imp_name in tc.fn_ret_types {
					return tc.fn_ret_types[imp_name] or {
						unknown_type('unknown return type for `${imp_name}`')
					}
				}
			}
			if node.typ.len > 0 {
				return tc.parse_type(node.typ)
			}
			$if debug {
				eprintln('warning: unknown fn return type `${fn_node.value}`')
			}
			return unknown_type('unknown function `${fn_node.value}`')
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
			inner := tc.resolve_type(tc.a.child(&node, 0))
			if inner is OptionType {
				return inner.base_type
			}
			if inner is ResultType {
				return inner.base_type
			}
			return inner
		}
		.struct_init {
			return tc.parse_type(node.value)
		}
		.assoc {
			if node.value.len > 0 {
				return tc.parse_type(node.value)
			}
			if node.children_count > 0 {
				return tc.resolve_type(tc.a.child(&node, 0))
			}
			return unknown_type('missing assoc base')
		}
		.sizeof_expr {
			return Type(USize{})
		}
		.cast_expr {
			return tc.parse_type(node.value)
		}
		.selector {
			if smart_type := tc.smartcast_type(id) {
				return smart_type
			}
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
					return tc.const_types[qname] or { unknown_type('unknown const `${qname}`') }
				}
			}
			base_type := tc.resolve_type(tc.a.child(&node, 0))
			mut clean := unwrap_pointer(base_type)
			if clean is Alias {
				clean = clean.base_type
			}
			if typ := option_result_selector_type(clean, node.value) {
				return typ
			}
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
			if clean is MultiReturn {
				if typ := multi_return_selector_type(clean, node.value) {
					return typ
				}
			}
			if clean is SumType {
				if typ := tc.lowered_sum_selector_type(clean, node.value) {
					return typ
				}
				if clean.name in tc.sum_types {
					for v in tc.sum_types[clean.name] {
						if c_name(v) == node.value {
							return tc.parse_type(v)
						}
						if v in tc.structs {
							for f in tc.structs[v] {
								if f.name == node.value {
									return f.typ
								}
							}
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
			return unknown_type('unknown selector `${node.value}`')
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
			return tc.resolve_index_type(node)
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
		.match_stmt {
			for i in 1 .. node.children_count {
				t := tc.branch_tail_type(tc.a.child(&node, i))
				if t !is Void {
					return t
				}
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
				eprintln('warning: unhandled node kind .${node.kind} in resolve_type')
			}
			return unknown_type('unhandled node kind .${node.kind}')
		}
	}
}

fn (tc &TypeChecker) resolve_index_type(node flat.Node) Type {
	mut base_type := tc.resolve_type(tc.a.child(&node, 0))
	if base_type is Alias {
		base_type = base_type.base_type
	}
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
	if base_type is Pointer {
		mut inner := base_type.base_type
		if inner is Alias {
			inner = inner.base_type
		}
		if inner is Array {
			return inner.elem_type
		}
		if inner is ArrayFixed {
			return inner.elem_type
		}
		return inner
	}
	if base_type is String {
		return Type(u8_)
	}
	return unknown_type('cannot index `${base_type.name()}`')
}

pub fn (tc &TypeChecker) c_type(t Type) string {
	if t is Void {
		return 'void'
	}
	if t is Unknown {
		return 'int'
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
	if t is Interface {
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
	if t is Alias {
		return t.name
	}
	if t is Struct {
		return t.name
	}
	if t is Interface {
		return t.name
	}
	if t is String {
		return 'string'
	}
	if t is Array {
		return 'array'
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

const c_reserved_words = ['auto', 'break', 'case', 'char', 'const', 'continue', 'copy', 'default',
	'do', 'double', 'else', 'enum', 'extern', 'float', 'for', 'goto', 'if', 'inline', 'int', 'long',
	'register', 'restrict', 'return', 'short', 'signed', 'sizeof', 'static', 'struct', 'switch',
	'typedef', 'union', 'unsigned', 'void', 'volatile', 'while']

fn c_name(name string) string {
	if name.starts_with('C.') {
		return name[2..]
	}
	if name == 'malloc' {
		return 'v_malloc'
	}
	n := name.replace('[]', 'Array_').replace('.-', '__minus').replace('.+', '__plus').replace('.==',
		'__eq').replace('.!=', '__ne').replace('.<=', '__le').replace('.>=', '__ge').replace('.<',
		'__lt').replace('.>', '__gt').replace('.', '__')
	if n in c_reserved_words {
		return 'v_${n}'
	}
	return n
}
