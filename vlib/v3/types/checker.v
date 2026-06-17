module types

import v3.flat

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
				mut ptypes := []Type{}
				for i in 0 .. node.children_count {
					child := a.child_node(&node, i)
					if child.kind == .param {
						ptypes << tc.parse_type(child.typ)
					}
				}
				tc.fn_param_types[qname] = ptypes
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
			.global_decl {
				for i in 0 .. node.children_count {
					f := a.child_node(&node, i)
					if f.value.len > 0 && !f.value.starts_with('C.') {
						mut ft := tc.parse_type(f.typ)
						if ft is Void && f.children_count > 0 {
							ft = tc.resolve_type(a.child(f, 0))
						}
						tc.file_scope.insert(f.value, ft)
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
	if builtin_type(name) != none {
		return name
	}
	return tc.cur_module + '.' + name
}

fn (mut tc TypeChecker) register_runtime_methods() {
	tc.type_aliases.delete('strings.Builder')
	tc.fn_ret_types['strings.new_builder'] = tc.parse_type('strings.Builder')
	tc.fn_param_types['strings.new_builder'] = [tc.parse_type('int')]
	tc.fn_ret_types['strings.Builder.str'] = tc.parse_type('string')
	tc.fn_param_types['strings.Builder.str'] = [tc.parse_type('&strings.Builder')]
	tc.fn_ret_types['strings.Builder.write_string'] = tc.parse_type('void')
	tc.fn_param_types['strings.Builder.write_string'] = [
		tc.parse_type('&strings.Builder'),
		tc.parse_type('string'),
	]
	tc.fn_ret_types['strings.Builder.writeln'] = tc.parse_type('void')
	tc.fn_param_types['strings.Builder.writeln'] = [tc.parse_type('&strings.Builder'),
		tc.parse_type('string')]
	tc.fn_ret_types['strings.Builder.write_ptr'] = tc.parse_type('void')
	tc.fn_param_types['strings.Builder.write_ptr'] = [
		tc.parse_type('&strings.Builder'),
		tc.parse_type('voidptr'),
		tc.parse_type('int'),
	]
	tc.fn_ret_types['strings.Builder.write_u8'] = tc.parse_type('void')
	tc.fn_param_types['strings.Builder.write_u8'] = [
		tc.parse_type('&strings.Builder'),
		tc.parse_type('u8'),
	]
	tc.fn_ret_types['strings.Builder.free'] = tc.parse_type('void')
	tc.fn_param_types['strings.Builder.free'] = [tc.parse_type('&strings.Builder')]
	tc.fn_ret_types['check_fwrite'] = tc.parse_type('!int')
	tc.fn_param_types['check_fwrite'] = [tc.parse_type('int')]
	tc.fn_ret_types['os.check_fwrite'] = tc.parse_type('!int')
	tc.fn_ret_types['malloc_noscan'] = tc.parse_type('voidptr')
	tc.fn_ret_types['u8.vstring'] = tc.parse_type('string')
	tc.fn_ret_types['u8.vstring_with_len'] = tc.parse_type('string')
	methods := {
		'string.all_before':      ['string', 'string']
		'string.all_before_last': ['string', 'string']
		'string.all_after':       ['string', 'string']
		'string.all_after_last':  ['string', 'string']
		'string.before':          ['string', 'string']
		'string.after':           ['string', 'string']
		'string.substr':          ['string', 'int', 'int']
		'string.trim_left':       ['string', 'string']
		'string.trim_right':      ['string', 'string']
		'string.trim_space':      ['string']
		'string.count':           ['string', 'string']
		'string.index_':          ['string', 'string']
		'string.last_index_':     ['string', 'string']
		'string.replace':         ['string', 'string', 'string']
		'string.contains':        ['string', 'string']
		'string.split':           ['string', 'string']
		'string.starts_with':     ['string', 'string']
		'string.ends_with':       ['string', 'string']
		'string.index_u8':        ['string', 'u8']
		'string.last_index_u8':   ['string', 'u8']
		'string.contains_u8':     ['string', 'u8']
		'string.int':             ['string']
		'string.free':            ['&string']
		'string.clone':           ['string']
	}
	ret_types := {
		'string.all_before':      'string'
		'string.all_before_last': 'string'
		'string.all_after':       'string'
		'string.all_after_last':  'string'
		'string.before':          'string'
		'string.after':           'string'
		'string.substr':          'string'
		'string.trim_left':       'string'
		'string.trim_right':      'string'
		'string.trim_space':      'string'
		'string.count':           'int'
		'string.index_':          'int'
		'string.last_index_':     'int'
		'string.replace':         'string'
		'string.contains':        'bool'
		'string.split':           '[]string'
		'string.starts_with':     'bool'
		'string.ends_with':       'bool'
		'string.index_u8':        'int'
		'string.last_index_u8':   'int'
		'string.contains_u8':     'bool'
		'string.int':             'int'
		'string.free':            'void'
		'string.clone':           'string'
	}
	for name, params in methods {
		if name !in tc.fn_param_types {
			mut pt := []Type{}
			for p in params {
				pt << tc.parse_type(p)
			}
			tc.fn_param_types[name] = pt
		}
	}
	for name, ret in ret_types {
		if name !in tc.fn_ret_types {
			tc.fn_ret_types[name] = tc.parse_type(ret)
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
	mut ret_type := ?Type(none)
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
				return tc.const_types[qname]
			}
			if node.value in tc.const_types {
				return tc.const_types[node.value]
			}
			return Type(int_)
		}
		.call {
			fn_node := tc.a.child_node(&node, 0)
			if fn_node.kind == .selector {
				base_node := tc.a.child_node(fn_node, 0)
				if base_node.kind == .ident {
					resolved := if base_node.value in tc.imports {
						tc.imports[base_node.value]
					} else {
						base_node.value
					}
					mod_name := '${resolved}.${fn_node.value}'
					if mod_name in tc.fn_ret_types {
						return tc.fn_ret_types[mod_name]
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
							return tc.fn_ret_types[full_name]
						}
					}
				}
				base_type := tc.resolve_type(tc.a.child(fn_node, 0))
				clean_type := unwrap_pointer(base_type)
				if clean_type is Array {
					return match fn_node.value {
						'clone' { base_type }
						'last', 'first', 'pop' { clean_type.elem_type }
						'contains' { Type(bool_) }
						'index' { Type(int_) }
						'join' { Type(string_) }
						else { Type(int_) }
					}
				}
				if clean_type is Map {
					return match fn_node.value {
						'clone' { base_type }
						else { Type(int_) }
					}
				}
				if clean_type is String {
					mname := 'string.${fn_node.value}'
					if mname in tc.fn_ret_types {
						return tc.fn_ret_types[mname]
					}
				}
				if clean_type is Struct {
					mname := '${clean_type.name}.${fn_node.value}'
					if mname in tc.fn_ret_types {
						return tc.fn_ret_types[mname]
					}
				}
			}
			if fn_node.value in tc.fn_ret_types {
				return tc.fn_ret_types[fn_node.value]
			}
			qfn := tc.qualify_fn_name(fn_node.value)
			if qfn in tc.fn_ret_types {
				return tc.fn_ret_types[qfn]
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
					return tc.const_types[qname]
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
			return Type(int_)
		}
		.array_init {
			return Type(Array{
				elem_type: tc.parse_type(node.value)
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
			return Type(int_)
		}
	}
}

pub fn (tc &TypeChecker) c_type(t Type) string {
	match t {
		Void {
			return 'void'
		}
		Nil {
			return 'void*'
		}
		None {
			return 'Optional'
		}
		String {
			return 'string'
		}
		Char {
			return 'char'
		}
		Rune {
			return 'i32'
		}
		ISize {
			return 'ptrdiff_t'
		}
		USize {
			return 'size_t'
		}
		Primitive {
			return prim_c_type(t)
		}
		Array {
			return 'Array'
		}
		ArrayFixed {
			return if tc.has_builtins { 'array' } else { 'Array' }
		}
		Map {
			return 'map'
		}
		Pointer {
			return tc.c_type(t.base_type) + '*'
		}
		FnType {
			ret := if r := t.return_type { tc.c_type(r) } else { 'void' }
			if t.params.len == 0 {
				return 'fn_ptr:${ret}|void'
			}
			mut params := []string{}
			for p in t.params {
				params << tc.c_type(p)
			}
			return 'fn_ptr:${ret}|${params.join(', ')}'
		}
		OptionType {
			return 'Optional'
		}
		ResultType {
			return 'Optional'
		}
		Struct {
			if t.name.starts_with('C.') {
				return c_name(t.name)
			}
			return c_name(t.name)
		}
		Enum {
			return 'int'
		}
		SumType {
			return c_name(t.name)
		}
		Alias {
			return tc.c_type(t.base_type)
		}
		MultiReturn {
			mut parts := []string{}
			for ty in t.types {
				parts << tc.c_type(ty)
			}
			return 'multi_return_${parts.join('_')}'
		}
	}
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
