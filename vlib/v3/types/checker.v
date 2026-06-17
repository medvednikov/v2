module types

import v3.flat

pub struct StructField {
pub:
	name string
	typ  string
}

@[heap]
pub struct TypeChecker {
pub mut:
	a              &flat.FlatAst = unsafe { nil }
	fn_ret_types   map[string]string
	fn_param_types map[string][]string
	structs        map[string][]StructField
	type_aliases   map[string]string
	sum_types      map[string][]string
	enum_names     map[string]bool
	flag_enums     map[string]bool
	file_scope     &Scope = unsafe { nil }
	cur_scope      &Scope = unsafe { nil }
	has_builtins   bool
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

pub fn (tc &TypeChecker) resolve_type(id flat.NodeId) string {
	if int(id) < 0 {
		return 'int'
	}
	node := tc.a.nodes[int(id)]
	match node.kind {
		.int_literal {
			return 'int'
		}
		.float_literal {
			return 'double'
		}
		.bool_literal {
			return 'bool'
		}
		.char_literal {
			return 'u8'
		}
		.string_literal, .string_interp {
			return 'string'
		}
		.nil_literal {
			return 'void*'
		}
		.none_expr {
			return 'Optional'
		}
		.enum_val {
			return 'int'
		}
		.ident {
			if typ := tc.cur_scope.lookup(node.value) {
				return typ
			}
			return 'int'
		}
		.call {
			fn_node := tc.a.child_node(&node, 0)
			if fn_node.kind == .selector {
				base_type := tc.resolve_type(tc.a.child(fn_node, 0))
				clean_type := base_type.trim_left('&').trim_right('*')
				if clean_type.starts_with('[]') {
					return match fn_node.value {
						'clone' { clean_type }
						'last', 'first', 'pop' { clean_type[2..] }
						'contains' { 'bool' }
						'index' { 'int' }
						'join' { 'string' }
						else { 'int' }
					}
				}
				if clean_type.starts_with('map[') {
					return match fn_node.value {
						'clone' { clean_type }
						else { 'int' }
					}
				}
				mname := '${clean_type}.${fn_node.value}'
				if ret := tc.fn_ret_types[mname] {
					return ret
				}
			}
			if ret := tc.fn_ret_types[fn_node.value] {
				return ret
			}
			return 'int'
		}
		.infix {
			if node.op in [.eq, .ne, .lt, .gt, .le, .ge, .logical_and, .logical_or] {
				return 'bool'
			}
			lt := tc.resolve_type(tc.a.child(&node, 0))
			if lt == 'string' {
				return 'string'
			}
			rt := tc.resolve_type(tc.a.child(&node, 1))
			if rt == 'string' {
				return 'string'
			}
			if lt == 'double' || rt == 'double' {
				return 'double'
			}
			return lt
		}
		.prefix {
			if node.op == .amp {
				return tc.resolve_type(tc.a.child(&node, 0)) + '*'
			}
			if node.op == .mul {
				inner := tc.resolve_type(tc.a.child(&node, 0))
				if inner.ends_with('*') {
					return inner[..inner.len - 1]
				}
				return inner
			}
			return tc.resolve_type(tc.a.child(&node, 0))
		}
		.paren {
			return tc.resolve_type(tc.a.child(&node, 0))
		}
		.struct_init {
			return node.value
		}
		.cast_expr {
			return node.value
		}
		.selector {
			base_type := tc.resolve_type(tc.a.child(&node, 0))
			clean_base := base_type.trim_right('*')
			if node.value == 'len' {
				if base_type.contains('[') || clean_base == 'string' {
					return 'int'
				}
			}
			if fields := tc.structs[clean_base] {
				for f in fields {
					if f.name == node.value {
						return f.typ
					}
				}
			}
			return 'int'
		}
		.array_literal {
			if node.children_count > 0 {
				elem_type := tc.resolve_type(tc.a.child(&node, 0))
				return '${elem_type}[${node.children_count}]'
			}
			return 'int[0]'
		}
		.index {
			base_type := tc.resolve_type(tc.a.child(&node, 0))
			if node.value == 'range' {
				if base_type.starts_with('[]') {
					return base_type
				}
				return 'string'
			}
			if base_type.starts_with('map[') {
				return base_type[base_type.index_u8(`]`) + 1..]
			}
			if base_type.starts_with('[]') {
				return base_type[2..]
			}
			if base_type.contains('[') {
				return base_type.before('[')
			}
			return 'int'
		}
		.array_init {
			return '[]${node.value}'
		}
		.if_expr {
			then_block := tc.a.child_node(&node, 1)
			if then_block.children_count > 0 {
				last := tc.a.child_node(then_block, then_block.children_count - 1)
				if last.kind == .expr_stmt {
					return tc.resolve_type(tc.a.child(last, 0))
				}
				return tc.resolve_type(tc.a.child(then_block, then_block.children_count - 1))
			}
			if node.children_count > 2 {
				else_node := tc.a.child_node(&node, 2)
				if else_node.kind == .block && else_node.children_count > 0 {
					last := tc.a.child_node(else_node, else_node.children_count - 1)
					if last.kind == .expr_stmt {
						return tc.resolve_type(tc.a.child(last, 0))
					}
					return tc.resolve_type(tc.a.child(else_node, else_node.children_count - 1))
				}
				if else_node.kind == .if_expr {
					return tc.resolve_type(tc.a.child(&node, 2))
				}
			}
			return 'int'
		}
		.map_init {
			return node.value
		}
		.in_expr {
			return 'bool'
		}
		else {
			return 'int'
		}
	}
}

pub fn (tc &TypeChecker) c_type(typ string) string {
	if typ.starts_with('&') {
		return tc.c_type(typ[1..]) + '*'
	}
	if typ.starts_with('shared ') {
		return tc.c_type(typ[7..])
	}
	if typ.starts_with('?') {
		return 'Optional'
	}
	if typ.starts_with('!') {
		return 'Optional'
	}
	if typ.starts_with('[]') {
		return 'Array'
	}
	if typ.starts_with('map[') {
		return 'HashMap'
	}
	if typ.starts_with('[') && typ.contains(']') {
		return if tc.has_builtins { 'array' } else { 'Array' }
	}
	if typ.starts_with('fn(') {
		return tc.c_fn_ptr_type(typ)
	}
	if typ in tc.type_aliases {
		return tc.c_type(tc.type_aliases[typ])
	}
	if typ in tc.sum_types {
		return c_name(typ)
	}
	if typ in tc.flag_enums {
		return 'int'
	}
	if typ in tc.enum_names {
		return 'int'
	}
	return match typ {
		'int' { 'int' }
		'i8' { 'i8' }
		'i16' { 'i16' }
		'i32' { 'i32' }
		'i64' { 'i64' }
		'u8', 'byte' { 'u8' }
		'u16' { 'u16' }
		'u32' { 'u32' }
		'u64' { 'u64' }
		'isize' { 'ptrdiff_t' }
		'usize' { 'size_t' }
		'f32' { 'float' }
		'f64' { 'double' }
		'bool' { 'bool' }
		'string' { 'string' }
		'char' { 'char' }
		'void' { 'void' }
		'voidptr' { 'void*' }
		'charptr' { 'char*' }
		'byteptr' { 'u8*' }
		'' { 'void' }
		else { c_name(typ) }
	}
}

fn (tc &TypeChecker) c_fn_ptr_type(typ string) string {
	// fn(param_types) ret_type → fn_ptr:c_ret|c_param1, c_param2
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
	ret_c := if ret_str.len > 0 { tc.c_type(ret_str) } else { 'void' }
	if params_str.len == 0 {
		return 'fn_ptr:${ret_c}|void'
	}
	params := params_str.split(',')
	mut c_params := []string{}
	for p in params {
		c_params << tc.c_type(p.trim_space())
	}
	return 'fn_ptr:${ret_c}|${c_params.join(', ')}'
}

fn c_name(name string) string {
	return name.replace('.', '__')
}
