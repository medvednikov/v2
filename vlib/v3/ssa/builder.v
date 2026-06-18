module ssa

import v3.flat
import v3.types

pub struct Builder {
mut:
	m                &Module            = unsafe { nil }
	a                &flat.FlatAst      = unsafe { nil }
	tc               &types.TypeChecker = unsafe { nil }
	used_fns         map[string]bool
	cur_func         int
	cur_block        BlockID
	vars             map[string]ValueID
	i64_type         TypeID
	i32_type         TypeID
	i8_type          TypeID
	i1_type          TypeID
	void_type        TypeID
	str_type         TypeID
	array_type       TypeID
	map_type         TypeID
	fn_types         map[string]TypeID
	fn_ids           map[string]int
	struct_types     map[string]TypeID
	break_targets    []BlockID
	continue_targets []BlockID
}

pub fn build(a_ &flat.FlatAst) &Module {
	return build_with_used(a_, map[string]bool{}, unsafe { nil })
}

pub fn build_with_used(a_ &flat.FlatAst, used_fns map[string]bool, tc &types.TypeChecker) &Module {
	mut b := Builder{
		m:        Module.new()
		a:        unsafe { a_ }
		tc:       unsafe { tc }
		used_fns: used_fns
	}
	b.void_type = TypeID(0)
	b.i64_type = b.m.type_store.get_int(64)
	b.i32_type = b.m.type_store.get_int(32)
	b.i8_type = b.m.type_store.get_int(8)
	b.i1_type = b.m.type_store.get_int(1)
	mut str_fields := []TypeID{}
	str_fields << b.m.type_store.get_ptr(b.i8_type)
	str_fields << b.i32_type
	mut str_field_names := []string{}
	str_field_names << 'str'
	str_field_names << 'len'
	b.str_type = b.m.type_store.register(Type{
		kind:        .struct_t
		fields:      str_fields
		field_names: str_field_names
	})
	ptr_i8 := b.m.type_store.get_ptr(b.i8_type)
	mut array_fields := []TypeID{}
	array_fields << ptr_i8
	array_fields << b.i64_type
	array_fields << b.i64_type
	array_fields << b.i64_type
	mut array_field_names := []string{}
	array_field_names << 'data'
	array_field_names << 'len'
	array_field_names << 'cap'
	array_field_names << 'elem_size'
	b.array_type = b.m.type_store.register(Type{
		kind:        .struct_t
		fields:      array_fields
		field_names: array_field_names
	})
	mut map_fields := []TypeID{}
	map_fields << ptr_i8
	map_fields << ptr_i8
	map_fields << b.i64_type
	map_fields << b.i64_type
	map_fields << b.i64_type
	map_fields << b.i64_type
	mut map_field_names := []string{}
	map_field_names << 'keys'
	map_field_names << 'vals'
	map_field_names << 'cap'
	map_field_names << 'len'
	map_field_names << 'key_size'
	map_field_names << 'val_size'
	b.map_type = b.m.type_store.register(Type{
		kind:        .struct_t
		fields:      map_fields
		field_names: map_field_names
	})
	b.register_types()
	b.register_globals()
	b.register_functions()
	b.build_functions()
	return b.m
}

fn (mut b Builder) register_types() {
	for node in b.a.nodes {
		if node.kind == .struct_decl {
			mut field_types := []TypeID{}
			mut field_names := []string{}
			for i in 0 .. node.children_count {
				f := b.a.child_node(&node, i)
				field_types << b.resolve_type(f.typ)
				field_names << f.value
			}
			typ_id := b.m.type_store.register(Type{
				kind:        .struct_t
				fields:      field_types
				field_names: field_names
			})
			b.struct_types[node.value] = typ_id
		}
	}
}

fn (mut b Builder) register_globals() {
	for node in b.a.nodes {
		if node.kind == .global_decl {
			for i in 0 .. node.children_count {
				f := b.a.child_node(&node, i)
				typ := b.resolve_type(f.typ)
				b.vars[f.value] = b.m.add_global(f.value, typ)
			}
		}
	}
}

fn (mut b Builder) register_functions() {
	ptr_i8 := b.m.type_store.get_ptr(b.i8_type)
	mut p1 := []TypeID{}
	mut p2 := []TypeID{}
	mut p3 := []TypeID{}
	// C library externs
	p3 = []TypeID{}
	p3 << b.i64_type
	p3 << ptr_i8
	p3 << b.i64_type
	b.register_extern('write', b.i64_type, p3)
	p1 = []TypeID{}
	p1 << b.i64_type
	b.register_extern('putchar', b.i64_type, p1)
	b.register_extern('getchar', b.i64_type, []TypeID{})
	p1 = []TypeID{}
	p1 << b.i64_type
	b.register_extern('close', b.i64_type, p1)
	p1 = []TypeID{}
	p1 << ptr_i8
	b.register_extern('puts', b.i64_type, p1)
	p1 = []TypeID{}
	p1 << ptr_i8
	b.register_extern('strlen', b.i64_type, p1)
	p1 = []TypeID{}
	p1 << b.i64_type
	b.register_extern('strerror', ptr_i8, p1)
	p1 = []TypeID{}
	p1 << ptr_i8
	b.register_extern('feof', b.i64_type, p1)
	p1 = []TypeID{}
	p1 << ptr_i8
	b.register_extern('ferror', b.i64_type, p1)
	p1 = []TypeID{}
	p1 << ptr_i8
	b.register_extern('fclose', b.i64_type, p1)
	p1 = []TypeID{}
	p1 << ptr_i8
	b.register_extern('pclose', b.i64_type, p1)
	p1 = []TypeID{}
	p1 << ptr_i8
	b.register_extern('ftell', b.i64_type, p1)
	p1 = []TypeID{}
	p1 << ptr_i8
	b.register_extern('rewind', b.void_type, p1)
	p2 = []TypeID{}
	p2 << ptr_i8
	p2 << ptr_i8
	b.register_extern('fputs', b.i64_type, p2)
	p2 = []TypeID{}
	p2 << ptr_i8
	p2 << ptr_i8
	b.register_extern('fopen', ptr_i8, p2)
	p2 = []TypeID{}
	p2 << ptr_i8
	p2 << ptr_i8
	b.register_extern('popen', ptr_i8, p2)
	mut p4 := []TypeID{}
	p4 << ptr_i8
	p4 << b.i64_type
	p4 << b.i64_type
	p4 << ptr_i8
	b.register_extern('fread', b.i64_type, p4)
	p4 = []TypeID{}
	p4 << ptr_i8
	p4 << b.i64_type
	p4 << b.i64_type
	p4 << ptr_i8
	b.register_extern('fwrite', b.i64_type, p4)
	p3 = []TypeID{}
	p3 << ptr_i8
	p3 << b.i64_type
	p3 << b.i64_type
	b.register_extern('fseek', b.i64_type, p3)
	p1 = []TypeID{}
	p1 << b.i64_type
	b.register_extern('malloc', ptr_i8, p1)
	p2 = []TypeID{}
	p2 << b.i64_type
	p2 << b.i64_type
	b.register_extern('calloc', ptr_i8, p2)
	p2 = []TypeID{}
	p2 << ptr_i8
	p2 << b.i64_type
	b.register_extern('realloc', ptr_i8, p2)
	p3 = []TypeID{}
	p3 << ptr_i8
	p3 << ptr_i8
	p3 << b.i64_type
	b.register_extern('memcpy', ptr_i8, p3)
	p3 = []TypeID{}
	p3 << ptr_i8
	p3 << ptr_i8
	p3 << b.i64_type
	b.register_extern('memmove', ptr_i8, p3)
	p3 = []TypeID{}
	p3 << ptr_i8
	p3 << b.i64_type
	p3 << b.i64_type
	b.register_extern('memset', ptr_i8, p3)
	p3 = []TypeID{}
	p3 << ptr_i8
	p3 << ptr_i8
	p3 << b.i64_type
	b.register_extern('memcmp', b.i64_type, p3)
	p1 = []TypeID{}
	p1 << b.i64_type
	b.register_extern('exit', b.void_type, p1)
	p1 = []TypeID{}
	p1 << ptr_i8
	b.register_extern('fflush', b.void_type, p1)
	b.register_basic_format_stubs()
	p2 = []TypeID{}
	p2 << b.str_type
	p2 << b.str_type
	b.register_runtime_extern('string__plus', b.str_type, p2)
	p2 = []TypeID{}
	p2 << b.i64_type
	p2 << b.m.type_store.get_ptr(b.str_type)
	b.register_runtime_extern('string_plus_many', b.str_type, p2)
	p1 = []TypeID{}
	p1 << ptr_i8
	b.register_extern('free', b.void_type, p1)
	p2 = []TypeID{}
	p2 << ptr_i8
	p2 << ptr_i8
	b.register_extern('fprintf', b.void_type, p2)

	for node in b.a.nodes {
		if node.kind == .fn_decl {
			if b.skip_source_fn(node.value) {
				continue
			}
			if b.used_fns.len > 0 && !b.fn_is_used(node.value) {
				continue
			}
			ret_type := b.resolve_type(node.typ)
			mut param_types := []TypeID{}
			for i in 0 .. node.children_count {
				child := b.a.child_node(&node, i)
				if child.kind == .param {
					param_types << b.resolve_type(child.typ)
				}
			}
			fn_type := b.m.type_store.register(Type{
				kind:     .func_t
				ret_type: ret_type
				params:   param_types
			})
			b.fn_types[node.value] = fn_type
			func_id := b.m.new_function(node.value, ret_type)
			b.fn_ids[node.value] = func_id
		}
	}
	b.register_wyhash_stubs()
	b.register_string_eq_stub()
	b.register_fast_string_eq_stub()
	b.register_string_lt_stub()
	b.register_array_runtime_stubs()
	b.register_panic_stub()
	b.register_string_builder_stubs()
	b.register_map_runtime_stubs()
	b.register_u8_runtime_stubs()
	b.register_heap_tracking_stubs()
}

fn (mut b Builder) register_extern(name string, ret TypeID, params []TypeID) {
	fn_type := b.m.type_store.register(Type{
		kind:     .func_t
		ret_type: ret
		params:   params
	})
	b.fn_types[name] = fn_type
	func_id := b.m.new_function(name, ret)
	b.fn_ids[name] = func_id
	mut f := b.m.funcs[func_id]
	f.is_c_extern = true
	b.m.funcs[func_id] = f
}

fn (mut b Builder) register_runtime_extern(name string, ret TypeID, params []TypeID) {
	if b.has_fn_decl(name) {
		return
	}
	b.register_extern(name, ret, params)
}

fn (b &Builder) has_fn_decl(name string) bool {
	for node in b.a.nodes {
		if node.kind == .fn_decl && node.value == name {
			return true
		}
	}
	return false
}

fn (b &Builder) skip_source_fn(name string) bool {
	if name in ['_wymix', 'wyhash', 'wyhash64', 'string__eq', 'string__lt', 'array_new', 'array_get',
		'array_push', 'panic', 'fast_string_eq', 'strings.new_builder',
		'strings.Builder.write_string', 'strings.Builder.writeln', 'strings.Builder.str',
		'strings.Builder.write_ptr', 'strings.Builder.write_u8', 'strings.Builder.write_runes',
		'strings.Builder.free', 'strings.Builder.last_n', 'new_map', 'map__set', 'map__get',
		'map__exists', 'map__get_check', 'map__get_or_set', 'map__delete', 'map__clear', 'map__clone',
		'v3_map_find', 'u8.is_digit', 'u8.is_letter', 'u8.is_alnum', 'u8.is_capital', '_ht_alloc',
		'_ht_free', 'f32_to_str_l', 'f32_to_str_l_with_dot', 'f64_to_str_l',
		'f64_to_str_l_with_dot', 'fxx_to_str_l_parse', 'fxx_to_str_l_parse_with_dot'] {
		return true
	}
	return name.starts_with('print_backtrace') || name.starts_with('backtrace_')
		|| name.starts_with('map.')
		|| name in ['print_libbacktrace', 'eprint_libbacktrace', 'bsd_backtrace_resolve_atos']
}

fn (mut b Builder) register_wyhash_stubs() {
	mut p2 := []TypeID{}
	p2 << b.i64_type
	p2 << b.i64_type
	wymix_id := b.register_synthetic_function('_wymix', b.i64_type, p2)
	b.generate_wymix_body(wymix_id)
	wyhash64_id := b.register_synthetic_function('wyhash64', b.i64_type, p2)
	b.generate_wyhash64_body(wyhash64_id)

	ptr_u8 := b.m.type_store.get_ptr(b.i8_type)
	ptr_u64 := b.m.type_store.get_ptr(b.i64_type)
	mut p4 := []TypeID{}
	p4 << ptr_u8
	p4 << b.i64_type
	p4 << b.i64_type
	p4 << ptr_u64
	wyhash_id := b.register_synthetic_function('wyhash', b.i64_type, p4)
	b.generate_wyhash_body(wyhash_id)
}

fn (mut b Builder) register_synthetic_function(name string, ret TypeID, params []TypeID) int {
	fn_type := b.m.type_store.register(Type{
		kind:     .func_t
		ret_type: ret
		params:   params
	})
	b.fn_types[name] = fn_type
	func_id := b.m.new_function(name, ret)
	b.fn_ids[name] = func_id
	mut f := b.m.funcs[func_id]
	f.typ = ret
	f.blocks = []BlockID{}
	f.params = []ValueID{}
	f.is_c_extern = false
	b.m.funcs[func_id] = f
	return func_id
}

fn (mut b Builder) func_add_argument(func_id int, typ TypeID, name string) ValueID {
	mut f := b.m.funcs[func_id]
	param := b.m.add_value(.argument, typ, name, f.params.len)
	f.params << param
	b.m.funcs[func_id] = f
	return param
}

fn (mut b Builder) block_instr0(op OpCode, block_id BlockID, typ TypeID) ValueID {
	ops := []ValueID{}
	return b.m.add_instr(op, block_id, typ, ops)
}

fn (mut b Builder) block_instr1(op OpCode, block_id BlockID, typ TypeID, a ValueID) ValueID {
	mut ops := []ValueID{}
	ops << a
	return b.m.add_instr(op, block_id, typ, ops)
}

fn (mut b Builder) block_instr2(op OpCode, block_id BlockID, typ TypeID, a ValueID, c ValueID) ValueID {
	mut ops := []ValueID{}
	ops << a
	ops << c
	return b.m.add_instr(op, block_id, typ, ops)
}

fn (mut b Builder) block_instr3(op OpCode, block_id BlockID, typ TypeID, a ValueID, c ValueID, d ValueID) ValueID {
	mut ops := []ValueID{}
	ops << a
	ops << c
	ops << d
	return b.m.add_instr(op, block_id, typ, ops)
}

fn (mut b Builder) block_instr4(op OpCode, block_id BlockID, typ TypeID, a ValueID, c ValueID, d ValueID, e ValueID) ValueID {
	mut ops := []ValueID{}
	ops << a
	ops << c
	ops << d
	ops << e
	return b.m.add_instr(op, block_id, typ, ops)
}

fn (mut b Builder) block_struct_field_ptr(block_id BlockID, base_addr ValueID, typ_id TypeID, field_idx int) ValueID {
	typ := b.m.type_store.types[typ_id]
	field_type := if field_idx < typ.fields.len { typ.fields[field_idx] } else { b.i64_type }
	offset := b.m.struct_field_offset(typ_id, field_idx)
	off_const := b.m.get_or_add_const(b.i64_type, '${offset}')
	return b.block_instr2(.get_element_ptr, block_id, b.m.type_store.get_ptr(field_type),
		base_addr, off_const)
}

fn (mut b Builder) register_basic_format_stubs() {
	mut p1_i64 := []TypeID{}
	p1_i64 << b.i64_type
	int_str_id := b.register_synthetic_function('int_str', b.str_type, p1_i64)
	b.generate_const_string_body(int_str_id, '0')

	mut p1_i1 := []TypeID{}
	p1_i1 << b.i1_type
	bool_str_id := b.register_synthetic_function('bool_str', b.str_type, p1_i1)
	b.generate_const_string_body(bool_str_id, 'false')

	mut p2_i64 := []TypeID{}
	p2_i64 << b.i64_type
	p2_i64 << b.i64_type
	format_int_id := b.register_synthetic_function('strconv__format_int', b.str_type, p2_i64)
	b.generate_const_string_body(format_int_id, '0')
	format_uint_id := b.register_synthetic_function('strconv__format_uint', b.str_type, p2_i64)
	b.generate_const_string_body(format_uint_id, '0')

	f32_id := b.register_synthetic_function('strconv__f32_to_str_l', b.str_type, p1_i64)
	b.generate_const_string_body(f32_id, '0.0')
	f64_id := b.register_synthetic_function('strconv__f64_to_str_l', b.str_type, p1_i64)
	b.generate_const_string_body(f64_id, '0.0')
}

fn (mut b Builder) generate_const_string_body(func_id int, value string) {
	entry := b.m.add_block(func_id, 'entry')
	result := b.m.add_value(.string_literal, b.str_type, value, 0)
	b.block_instr1(.ret, entry, b.void_type, result)
}

fn (mut b Builder) register_array_runtime_stubs() {
	ptr_i8 := b.m.type_store.get_ptr(b.i8_type)
	ptr_array := b.m.type_store.get_ptr(b.array_type)

	mut p3 := []TypeID{}
	p3 << b.i64_type
	p3 << b.i64_type
	p3 << b.i64_type
	array_new_id := b.register_synthetic_function('array_new', b.array_type, p3)
	b.generate_array_new_body(array_new_id)

	mut p2 := []TypeID{}
	p2 << b.array_type
	p2 << b.i64_type
	array_get_id := b.register_synthetic_function('array_get', ptr_i8, p2)
	b.generate_array_get_body(array_get_id)

	p2 = []TypeID{}
	p2 << ptr_array
	p2 << ptr_i8
	array_push_id := b.register_synthetic_function('array_push', b.void_type, p2)
	b.generate_array_push_body(array_push_id)
}

fn (mut b Builder) register_panic_stub() {
	mut p1 := []TypeID{}
	p1 << b.str_type
	panic_id := b.register_synthetic_function('panic', b.void_type, p1)
	b.generate_panic_body(panic_id)
}

fn (mut b Builder) generate_panic_body(func_id int) {
	entry := b.m.add_block(func_id, 'entry')
	message := b.func_add_argument(func_id, b.str_type, 'message')
	if eprintln_id := b.fn_ids['eprintln'] {
		fn_ref := b.m.add_value(.func_ref, b.void_type, 'eprintln', eprintln_id)
		b.block_instr2(.call, entry, b.void_type, fn_ref, message)
	}
	if exit_id := b.fn_ids['exit'] {
		one := b.m.get_or_add_const(b.i64_type, '1')
		fn_ref := b.m.add_value(.func_ref, b.void_type, 'exit', exit_id)
		b.block_instr2(.call, entry, b.void_type, fn_ref, one)
	}
	b.block_instr0(.ret, entry, b.void_type)
}

fn (mut b Builder) register_string_builder_stubs() {
	ptr_i8 := b.m.type_store.get_ptr(b.i8_type)
	ptr_builder := b.m.type_store.get_ptr(b.array_type)

	mut p1 := []TypeID{}
	p1 << b.i64_type
	new_id := b.register_synthetic_function('strings.new_builder', b.array_type, p1)
	b.generate_builder_new_body(new_id)

	mut p2 := []TypeID{}
	p2 << ptr_builder
	p2 << b.str_type
	write_string_id :=
		b.register_synthetic_function('strings.Builder.write_string', b.void_type, p2)
	b.generate_builder_write_string_body(write_string_id, false)
	writeln_id := b.register_synthetic_function('strings.Builder.writeln', b.void_type, p2)
	b.generate_builder_write_string_body(writeln_id, true)

	p1 = []TypeID{}
	p1 << ptr_builder
	str_id := b.register_synthetic_function('strings.Builder.str', b.str_type, p1)
	b.generate_builder_str_body(str_id)
	free_id := b.register_synthetic_function('strings.Builder.free', b.void_type, p1)
	b.generate_builder_free_body(free_id)

	p2 = []TypeID{}
	p2 << ptr_builder
	p2 << b.i8_type
	write_u8_id := b.register_synthetic_function('strings.Builder.write_u8', b.void_type, p2)
	b.generate_builder_write_u8_body(write_u8_id)

	mut p3 := []TypeID{}
	p3 << ptr_builder
	p3 << ptr_i8
	p3 << b.i64_type
	write_ptr_id := b.register_synthetic_function('strings.Builder.write_ptr', b.void_type, p3)
	b.generate_builder_write_ptr_body(write_ptr_id)

	p2 = []TypeID{}
	p2 << ptr_builder
	p2 << b.array_type
	write_runes_id := b.register_synthetic_function('strings.Builder.write_runes', b.void_type, p2)
	b.generate_builder_free_body(write_runes_id)

	p2 = []TypeID{}
	p2 << ptr_builder
	p2 << b.i64_type
	last_n_id := b.register_synthetic_function('strings.Builder.last_n', b.str_type, p2)
	b.generate_builder_last_n_body(last_n_id)
}

fn (mut b Builder) generate_builder_new_body(func_id int) {
	entry := b.m.add_block(func_id, 'entry')
	initial_size := b.func_add_argument(func_id, b.i64_type, 'initial_size')
	one := b.m.get_or_add_const(b.i64_type, '1')
	zero := b.m.get_or_add_const(b.i64_type, '0')
	fn_ref := b.m.add_value(.func_ref, b.void_type, 'array_new', b.fn_ids['array_new'])
	builder := b.block_instr4(.call, entry, b.array_type, fn_ref, one, zero, initial_size)
	b.block_instr1(.ret, entry, b.void_type, builder)
}

fn (mut b Builder) emit_builder_append(func_id int, entry BlockID, builder_ptr ValueID, src_ptr ValueID, add_len ValueID) BlockID {
	ptr_i8 := b.m.type_store.get_ptr(b.i8_type)
	data_ptr := b.block_struct_field_ptr(entry, builder_ptr, b.array_type, 0)
	len_ptr := b.block_struct_field_ptr(entry, builder_ptr, b.array_type, 1)
	cap_ptr := b.block_struct_field_ptr(entry, builder_ptr, b.array_type, 2)
	old_len := b.block_instr1(.load, entry, b.i64_type, len_ptr)
	cap := b.block_instr1(.load, entry, b.i64_type, cap_ptr)
	needed := b.block_instr2(.add, entry, b.i64_type, old_len, add_len)
	needs_grow := b.block_instr2(.gt, entry, b.i1_type, needed, cap)

	blk_grow := b.m.add_block(func_id, 'builder_append_grow')
	blk_copy := b.m.add_block(func_id, 'builder_append_copy')
	b.block_instr3(.br, entry, b.void_type, needs_grow, ValueID(blk_grow), ValueID(blk_copy))

	two := b.m.get_or_add_const(b.i64_type, '2')
	old_data := b.block_instr1(.load, blk_grow, ptr_i8, data_ptr)
	double_needed := b.block_instr2(.mul, blk_grow, b.i64_type, needed, two)
	new_cap := b.block_instr2(.add, blk_grow, b.i64_type, double_needed, two)
	realloc_ref := b.m.add_value(.func_ref, b.void_type, 'realloc', b.fn_ids['realloc'])
	new_data := b.block_instr3(.call, blk_grow, ptr_i8, realloc_ref, old_data, new_cap)
	b.block_instr2(.store, blk_grow, b.void_type, new_data, data_ptr)
	b.block_instr2(.store, blk_grow, b.void_type, new_cap, cap_ptr)
	b.block_instr1(.jmp, blk_grow, b.void_type, ValueID(blk_copy))

	data := b.block_instr1(.load, blk_copy, ptr_i8, data_ptr)
	dest := b.block_instr2(.add, blk_copy, ptr_i8, data, old_len)
	memcpy_ref := b.m.add_value(.func_ref, b.void_type, 'memcpy', b.fn_ids['memcpy'])
	b.block_instr4(.call, blk_copy, ptr_i8, memcpy_ref, dest, src_ptr, add_len)
	b.block_instr2(.store, blk_copy, b.void_type, needed, len_ptr)
	return blk_copy
}

fn (mut b Builder) generate_builder_write_string_body(func_id int, add_newline bool) {
	ptr_i8 := b.m.type_store.get_ptr(b.i8_type)
	ptr_builder := b.m.type_store.get_ptr(b.array_type)
	ptr_string := b.m.type_store.get_ptr(b.str_type)
	ptr_i32 := b.m.type_store.get_ptr(b.i32_type)
	entry := b.m.add_block(func_id, 'entry')
	builder_ptr := b.func_add_argument(func_id, ptr_builder, 'builder')
	s := b.func_add_argument(func_id, b.str_type, 's')

	alloca_s := b.block_instr0(.alloca, entry, ptr_string)
	b.block_instr2(.store, entry, b.void_type, s, alloca_s)
	zero := b.m.get_or_add_const(b.i64_type, '0')
	len_off := b.m.get_or_add_const(b.i64_type, '${b.m.struct_field_offset(b.str_type, 1)}')
	str_ptr_ptr := b.block_instr2(.get_element_ptr, entry, ptr_i8, alloca_s, zero)
	len_ptr := b.block_instr2(.get_element_ptr, entry, ptr_i32, alloca_s, len_off)
	str_ptr := b.block_instr1(.load, entry, ptr_i8, str_ptr_ptr)
	len32 := b.block_instr1(.load, entry, b.i32_type, len_ptr)
	len64 := b.block_instr1(.zext, entry, b.i64_type, len32)
	end_block := b.emit_builder_append(func_id, entry, builder_ptr, str_ptr, len64)
	if add_newline {
		nl := b.m.get_or_add_const(b.i8_type, '10')
		alloca_nl := b.block_instr0(.alloca, end_block, ptr_i8)
		b.block_instr2(.store, end_block, b.void_type, nl, alloca_nl)
		one := b.m.get_or_add_const(b.i64_type, '1')
		final_block := b.emit_builder_append(func_id, end_block, builder_ptr, alloca_nl, one)
		b.block_instr0(.ret, final_block, b.void_type)
	} else {
		b.block_instr0(.ret, end_block, b.void_type)
	}
}

fn (mut b Builder) generate_builder_write_ptr_body(func_id int) {
	ptr_i8 := b.m.type_store.get_ptr(b.i8_type)
	ptr_builder := b.m.type_store.get_ptr(b.array_type)
	entry := b.m.add_block(func_id, 'entry')
	builder_ptr := b.func_add_argument(func_id, ptr_builder, 'builder')
	src_ptr := b.func_add_argument(func_id, ptr_i8, 'ptr')
	len := b.func_add_argument(func_id, b.i64_type, 'len')
	end_block := b.emit_builder_append(func_id, entry, builder_ptr, src_ptr, len)
	b.block_instr0(.ret, end_block, b.void_type)
}

fn (mut b Builder) generate_builder_write_u8_body(func_id int) {
	ptr_i8 := b.m.type_store.get_ptr(b.i8_type)
	ptr_builder := b.m.type_store.get_ptr(b.array_type)
	entry := b.m.add_block(func_id, 'entry')
	builder_ptr := b.func_add_argument(func_id, ptr_builder, 'builder')
	ch := b.func_add_argument(func_id, b.i8_type, 'ch')
	alloca_ch := b.block_instr0(.alloca, entry, ptr_i8)
	b.block_instr2(.store, entry, b.void_type, ch, alloca_ch)
	one := b.m.get_or_add_const(b.i64_type, '1')
	end_block := b.emit_builder_append(func_id, entry, builder_ptr, alloca_ch, one)
	b.block_instr0(.ret, end_block, b.void_type)
}

fn (mut b Builder) generate_builder_str_body(func_id int) {
	ptr_i8 := b.m.type_store.get_ptr(b.i8_type)
	ptr_builder := b.m.type_store.get_ptr(b.array_type)
	ptr_string := b.m.type_store.get_ptr(b.str_type)
	ptr_i32 := b.m.type_store.get_ptr(b.i32_type)
	entry := b.m.add_block(func_id, 'entry')
	builder_ptr := b.func_add_argument(func_id, ptr_builder, 'builder')
	alloca_s := b.block_instr0(.alloca, entry, ptr_string)
	data_ptr := b.block_struct_field_ptr(entry, builder_ptr, b.array_type, 0)
	len_ptr := b.block_struct_field_ptr(entry, builder_ptr, b.array_type, 1)
	data := b.block_instr1(.load, entry, ptr_i8, data_ptr)
	len := b.block_instr1(.load, entry, b.i64_type, len_ptr)
	zero := b.m.get_or_add_const(b.i64_type, '0')
	str_len_off := b.m.get_or_add_const(b.i64_type, '${b.m.struct_field_offset(b.str_type, 1)}')
	out_data_ptr := b.block_instr2(.get_element_ptr, entry, ptr_i8, alloca_s, zero)
	out_len_ptr := b.block_instr2(.get_element_ptr, entry, ptr_i32, alloca_s, str_len_off)
	b.block_instr2(.store, entry, b.void_type, data, out_data_ptr)
	b.block_instr2(.store, entry, b.void_type, len, out_len_ptr)
	result := b.block_instr1(.load, entry, b.str_type, alloca_s)
	b.block_instr1(.ret, entry, b.void_type, result)
}

fn (mut b Builder) generate_builder_last_n_body(func_id int) {
	ptr_i8 := b.m.type_store.get_ptr(b.i8_type)
	ptr_builder := b.m.type_store.get_ptr(b.array_type)
	ptr_string := b.m.type_store.get_ptr(b.str_type)
	ptr_i32 := b.m.type_store.get_ptr(b.i32_type)
	entry := b.m.add_block(func_id, 'entry')
	builder_ptr := b.func_add_argument(func_id, ptr_builder, 'builder')
	n := b.func_add_argument(func_id, b.i64_type, 'n')
	alloca_s := b.block_instr0(.alloca, entry, ptr_string)
	data_ptr := b.block_struct_field_ptr(entry, builder_ptr, b.array_type, 0)
	len_ptr := b.block_struct_field_ptr(entry, builder_ptr, b.array_type, 1)
	data := b.block_instr1(.load, entry, ptr_i8, data_ptr)
	len := b.block_instr1(.load, entry, b.i64_type, len_ptr)
	start := b.block_instr2(.sub, entry, b.i64_type, len, n)
	out_data := b.block_instr2(.add, entry, ptr_i8, data, start)
	zero := b.m.get_or_add_const(b.i64_type, '0')
	str_len_off := b.m.get_or_add_const(b.i64_type, '${b.m.struct_field_offset(b.str_type, 1)}')
	out_data_ptr := b.block_instr2(.get_element_ptr, entry, ptr_i8, alloca_s, zero)
	out_len_ptr := b.block_instr2(.get_element_ptr, entry, ptr_i32, alloca_s, str_len_off)
	b.block_instr2(.store, entry, b.void_type, out_data, out_data_ptr)
	b.block_instr2(.store, entry, b.void_type, n, out_len_ptr)
	result := b.block_instr1(.load, entry, b.str_type, alloca_s)
	b.block_instr1(.ret, entry, b.void_type, result)
}

fn (mut b Builder) generate_builder_free_body(func_id int) {
	ptr_builder := b.m.type_store.get_ptr(b.array_type)
	entry := b.m.add_block(func_id, 'entry')
	_ := b.func_add_argument(func_id, ptr_builder, 'builder')
	b.block_instr0(.ret, entry, b.void_type)
}

fn (mut b Builder) register_map_runtime_stubs() {
	ptr_i8 := b.m.type_store.get_ptr(b.i8_type)
	ptr_map := b.m.type_store.get_ptr(b.map_type)

	mut p2 := []TypeID{}
	p2 << ptr_map
	p2 << ptr_i8
	find_id := b.register_synthetic_function('v3_map_find', b.i64_type, p2)
	b.generate_map_find_body(find_id)

	mut p6 := []TypeID{}
	for _ in 0 .. 6 {
		p6 << b.i64_type
	}
	new_id := b.register_synthetic_function('new_map', b.map_type, p6)
	b.generate_new_map_body(new_id)

	mut p3 := []TypeID{}
	p3 << ptr_map
	p3 << ptr_i8
	p3 << ptr_i8
	set_id := b.register_synthetic_function('map__set', b.void_type, p3)
	b.generate_map_set_body(set_id)

	p3 = []TypeID{}
	p3 << ptr_map
	p3 << ptr_i8
	p3 << ptr_i8
	get_id := b.register_synthetic_function('map__get', ptr_i8, p3)
	b.generate_map_get_body(get_id)
	get_check_id := b.register_synthetic_function('map__get_check', ptr_i8, p3)
	b.generate_map_get_body(get_check_id)
	get_or_set_id := b.register_synthetic_function('map__get_or_set', ptr_i8, p3)
	b.generate_map_get_body(get_or_set_id)

	p2 = []TypeID{}
	p2 << ptr_map
	p2 << ptr_i8
	exists_id := b.register_synthetic_function('map__exists', b.i1_type, p2)
	b.generate_map_exists_body(exists_id)
}

fn (mut b Builder) register_u8_runtime_stubs() {
	mut p1 := []TypeID{}
	p1 << b.i8_type
	for name in ['u8.is_digit', 'u8.is_letter', 'u8.is_alnum', 'u8.is_capital'] {
		func_id := b.register_synthetic_function(name, b.i1_type, p1)
		b.generate_u8_predicate_body(func_id, name)
	}
}

fn (mut b Builder) generate_u8_predicate_body(func_id int, name string) {
	entry := b.m.add_block(func_id, 'entry')
	c := b.func_add_argument(func_id, b.i8_type, 'c')
	digit := b.u8_in_range(entry, c, `0`, `9`)
	lower := b.u8_in_range(entry, c, `a`, `z`)
	upper := b.u8_in_range(entry, c, `A`, `Z`)
	letter := b.block_instr2(.or_, entry, b.i1_type, lower, upper)
	result := match name {
		'u8.is_digit' {
			digit
		}
		'u8.is_letter' {
			letter
		}
		'u8.is_alnum' {
			b.block_instr2(.or_, entry, b.i1_type, digit, letter)
		}
		else {
			upper
		}
	}

	b.block_instr1(.ret, entry, b.void_type, result)
}

fn (mut b Builder) u8_in_range(block_id BlockID, c ValueID, low u8, high u8) ValueID {
	low_v := b.m.get_or_add_const(b.i8_type, '${int(low)}')
	high_v := b.m.get_or_add_const(b.i8_type, '${int(high)}')
	ge_low := b.block_instr2(.ge, block_id, b.i1_type, c, low_v)
	le_high := b.block_instr2(.le, block_id, b.i1_type, c, high_v)
	return b.block_instr2(.and_, block_id, b.i1_type, ge_low, le_high)
}

fn (mut b Builder) register_heap_tracking_stubs() {
	ptr_i8 := b.m.type_store.get_ptr(b.i8_type)
	mut p2 := []TypeID{}
	p2 << ptr_i8
	p2 << b.i64_type
	alloc_id := b.register_synthetic_function('_ht_alloc', b.void_type, p2)
	b.generate_void_noop_body(alloc_id)
	mut p1 := []TypeID{}
	p1 << ptr_i8
	free_id := b.register_synthetic_function('_ht_free', b.void_type, p1)
	b.generate_void_noop_body(free_id)
}

fn (mut b Builder) generate_void_noop_body(func_id int) {
	entry := b.m.add_block(func_id, 'entry')
	b.block_instr0(.ret, entry, b.void_type)
}

fn (mut b Builder) generate_new_map_body(func_id int) {
	ptr_i8 := b.m.type_store.get_ptr(b.i8_type)
	ptr_map := b.m.type_store.get_ptr(b.map_type)
	entry := b.m.add_block(func_id, 'entry')
	key_size := b.func_add_argument(func_id, b.i64_type, 'key_size')
	val_size := b.func_add_argument(func_id, b.i64_type, 'val_size')
	hash_fn := b.func_add_argument(func_id, b.i64_type, 'hash_fn')
	eq_fn := b.func_add_argument(func_id, b.i64_type, 'eq_fn')
	clone_fn := b.func_add_argument(func_id, b.i64_type, 'clone_fn')
	free_fn := b.func_add_argument(func_id, b.i64_type, 'free_fn')
	_ = hash_fn
	_ = eq_fn
	_ = clone_fn
	_ = free_fn

	alloca_m := b.block_instr0(.alloca, entry, ptr_map)
	cap := b.m.get_or_add_const(b.i64_type, '8')
	zero := b.m.get_or_add_const(b.i64_type, '0')
	calloc_ref := b.m.add_value(.func_ref, b.void_type, 'calloc', b.fn_ids['calloc'])
	keys := b.block_instr3(.call, entry, ptr_i8, calloc_ref, cap, key_size)
	vals := b.block_instr3(.call, entry, ptr_i8, calloc_ref, cap, val_size)

	keys_ptr := b.block_struct_field_ptr(entry, alloca_m, b.map_type, 0)
	vals_ptr := b.block_struct_field_ptr(entry, alloca_m, b.map_type, 1)
	cap_ptr := b.block_struct_field_ptr(entry, alloca_m, b.map_type, 2)
	len_ptr := b.block_struct_field_ptr(entry, alloca_m, b.map_type, 3)
	key_size_ptr := b.block_struct_field_ptr(entry, alloca_m, b.map_type, 4)
	val_size_ptr := b.block_struct_field_ptr(entry, alloca_m, b.map_type, 5)
	b.block_instr2(.store, entry, b.void_type, keys, keys_ptr)
	b.block_instr2(.store, entry, b.void_type, vals, vals_ptr)
	b.block_instr2(.store, entry, b.void_type, cap, cap_ptr)
	b.block_instr2(.store, entry, b.void_type, zero, len_ptr)
	b.block_instr2(.store, entry, b.void_type, key_size, key_size_ptr)
	b.block_instr2(.store, entry, b.void_type, val_size, val_size_ptr)
	result := b.block_instr1(.load, entry, b.map_type, alloca_m)
	b.block_instr1(.ret, entry, b.void_type, result)
}

fn (mut b Builder) generate_map_find_body(func_id int) {
	ptr_i8 := b.m.type_store.get_ptr(b.i8_type)
	ptr_map := b.m.type_store.get_ptr(b.map_type)
	ptr_i64 := b.m.type_store.get_ptr(b.i64_type)
	ptr_string := b.m.type_store.get_ptr(b.str_type)
	entry := b.m.add_block(func_id, 'entry')
	map_ptr := b.func_add_argument(func_id, ptr_map, 'map')
	key_ptr := b.func_add_argument(func_id, ptr_i8, 'key')

	alloca_i := b.block_instr0(.alloca, entry, ptr_i64)
	zero := b.m.get_or_add_const(b.i64_type, '0')
	b.block_instr2(.store, entry, b.void_type, zero, alloca_i)
	keys_ptr := b.block_struct_field_ptr(entry, map_ptr, b.map_type, 0)
	len_ptr := b.block_struct_field_ptr(entry, map_ptr, b.map_type, 3)
	key_size_ptr := b.block_struct_field_ptr(entry, map_ptr, b.map_type, 4)

	blk_loop := b.m.add_block(func_id, 'map_find_loop')
	blk_body := b.m.add_block(func_id, 'map_find_body')
	blk_string_cmp := b.m.add_block(func_id, 'map_find_string_cmp')
	blk_mem_cmp := b.m.add_block(func_id, 'map_find_mem_cmp')
	blk_found := b.m.add_block(func_id, 'map_find_found')
	blk_next := b.m.add_block(func_id, 'map_find_next')
	blk_not_found := b.m.add_block(func_id, 'map_find_not_found')
	b.block_instr1(.jmp, entry, b.void_type, ValueID(blk_loop))

	i := b.block_instr1(.load, blk_loop, b.i64_type, alloca_i)
	len := b.block_instr1(.load, blk_loop, b.i64_type, len_ptr)
	in_range := b.block_instr2(.lt, blk_loop, b.i1_type, i, len)
	b.block_instr3(.br, blk_loop, b.void_type, in_range, ValueID(blk_body), ValueID(blk_not_found))

	keys := b.block_instr1(.load, blk_body, ptr_i8, keys_ptr)
	key_size := b.block_instr1(.load, blk_body, b.i64_type, key_size_ptr)
	offset := b.block_instr2(.mul, blk_body, b.i64_type, i, key_size)
	slot_key := b.block_instr2(.add, blk_body, ptr_i8, keys, offset)
	string_key_size := b.m.get_or_add_const(b.i64_type, '16')
	is_string_key := b.block_instr2(.eq, blk_body, b.i1_type, key_size, string_key_size)
	b.block_instr3(.br, blk_body, b.void_type, is_string_key, ValueID(blk_string_cmp),
		ValueID(blk_mem_cmp))

	slot_string_ptr := b.block_instr1(.bitcast, blk_string_cmp, ptr_string, slot_key)
	key_string_ptr := b.block_instr1(.bitcast, blk_string_cmp, ptr_string, key_ptr)
	slot_string := b.block_instr1(.load, blk_string_cmp, b.str_type, slot_string_ptr)
	key_string := b.block_instr1(.load, blk_string_cmp, b.str_type, key_string_ptr)
	eq_ref := b.m.add_value(.func_ref, b.void_type, 'fast_string_eq', b.fn_ids['fast_string_eq'])
	string_eq := b.block_instr3(.call, blk_string_cmp, b.i1_type, eq_ref, slot_string, key_string)
	b.block_instr3(.br, blk_string_cmp, b.void_type, string_eq, ValueID(blk_found),
		ValueID(blk_next))

	memcmp_ref := b.m.add_value(.func_ref, b.void_type, 'memcmp', b.fn_ids['memcmp'])
	cmp := b.block_instr4(.call, blk_mem_cmp, b.i64_type, memcmp_ref, slot_key, key_ptr, key_size)
	mem_eq := b.block_instr2(.eq, blk_mem_cmp, b.i1_type, cmp, zero)
	b.block_instr3(.br, blk_mem_cmp, b.void_type, mem_eq, ValueID(blk_found), ValueID(blk_next))

	b.block_instr1(.ret, blk_found, b.void_type, i)

	one := b.m.get_or_add_const(b.i64_type, '1')
	next_i := b.block_instr2(.add, blk_next, b.i64_type, i, one)
	b.block_instr2(.store, blk_next, b.void_type, next_i, alloca_i)
	b.block_instr1(.jmp, blk_next, b.void_type, ValueID(blk_loop))

	not_found := b.m.get_or_add_const(b.i64_type, '-1')
	b.block_instr1(.ret, blk_not_found, b.void_type, not_found)
}

fn (mut b Builder) generate_map_exists_body(func_id int) {
	ptr_i8 := b.m.type_store.get_ptr(b.i8_type)
	ptr_map := b.m.type_store.get_ptr(b.map_type)
	entry := b.m.add_block(func_id, 'entry')
	map_ptr := b.func_add_argument(func_id, ptr_map, 'map')
	key_ptr := b.func_add_argument(func_id, ptr_i8, 'key')
	find_ref := b.m.add_value(.func_ref, b.void_type, 'v3_map_find', b.fn_ids['v3_map_find'])
	idx := b.block_instr3(.call, entry, b.i64_type, find_ref, map_ptr, key_ptr)
	zero := b.m.get_or_add_const(b.i64_type, '0')
	found := b.block_instr2(.ge, entry, b.i1_type, idx, zero)
	b.block_instr1(.ret, entry, b.void_type, found)
}

fn (mut b Builder) generate_map_get_body(func_id int) {
	ptr_i8 := b.m.type_store.get_ptr(b.i8_type)
	ptr_map := b.m.type_store.get_ptr(b.map_type)
	entry := b.m.add_block(func_id, 'entry')
	map_ptr := b.func_add_argument(func_id, ptr_map, 'map')
	key_ptr := b.func_add_argument(func_id, ptr_i8, 'key')
	zero_ptr := b.func_add_argument(func_id, ptr_i8, 'zero')
	find_ref := b.m.add_value(.func_ref, b.void_type, 'v3_map_find', b.fn_ids['v3_map_find'])
	idx := b.block_instr3(.call, entry, b.i64_type, find_ref, map_ptr, key_ptr)
	zero := b.m.get_or_add_const(b.i64_type, '0')
	found := b.block_instr2(.ge, entry, b.i1_type, idx, zero)

	blk_found := b.m.add_block(func_id, 'map_get_found')
	blk_missing := b.m.add_block(func_id, 'map_get_missing')
	b.block_instr3(.br, entry, b.void_type, found, ValueID(blk_found), ValueID(blk_missing))

	vals_ptr := b.block_struct_field_ptr(blk_found, map_ptr, b.map_type, 1)
	val_size_ptr := b.block_struct_field_ptr(blk_found, map_ptr, b.map_type, 5)
	vals := b.block_instr1(.load, blk_found, ptr_i8, vals_ptr)
	val_size := b.block_instr1(.load, blk_found, b.i64_type, val_size_ptr)
	offset := b.block_instr2(.mul, blk_found, b.i64_type, idx, val_size)
	result := b.block_instr2(.add, blk_found, ptr_i8, vals, offset)
	b.block_instr1(.ret, blk_found, b.void_type, result)

	b.block_instr1(.ret, blk_missing, b.void_type, zero_ptr)
}

fn (mut b Builder) generate_map_set_body(func_id int) {
	ptr_i8 := b.m.type_store.get_ptr(b.i8_type)
	ptr_map := b.m.type_store.get_ptr(b.map_type)
	entry := b.m.add_block(func_id, 'entry')
	map_ptr := b.func_add_argument(func_id, ptr_map, 'map')
	key_ptr := b.func_add_argument(func_id, ptr_i8, 'key')
	val_ptr := b.func_add_argument(func_id, ptr_i8, 'val')
	find_ref := b.m.add_value(.func_ref, b.void_type, 'v3_map_find', b.fn_ids['v3_map_find'])
	idx := b.block_instr3(.call, entry, b.i64_type, find_ref, map_ptr, key_ptr)
	zero := b.m.get_or_add_const(b.i64_type, '0')
	found := b.block_instr2(.ge, entry, b.i1_type, idx, zero)

	keys_ptr := b.block_struct_field_ptr(entry, map_ptr, b.map_type, 0)
	vals_ptr := b.block_struct_field_ptr(entry, map_ptr, b.map_type, 1)
	cap_ptr := b.block_struct_field_ptr(entry, map_ptr, b.map_type, 2)
	len_ptr := b.block_struct_field_ptr(entry, map_ptr, b.map_type, 3)
	key_size_ptr := b.block_struct_field_ptr(entry, map_ptr, b.map_type, 4)
	val_size_ptr := b.block_struct_field_ptr(entry, map_ptr, b.map_type, 5)

	blk_update := b.m.add_block(func_id, 'map_set_update')
	blk_insert := b.m.add_block(func_id, 'map_set_insert')
	b.block_instr3(.br, entry, b.void_type, found, ValueID(blk_update), ValueID(blk_insert))

	vals_update := b.block_instr1(.load, blk_update, ptr_i8, vals_ptr)
	val_size_update := b.block_instr1(.load, blk_update, b.i64_type, val_size_ptr)
	update_off := b.block_instr2(.mul, blk_update, b.i64_type, idx, val_size_update)
	update_dest := b.block_instr2(.add, blk_update, ptr_i8, vals_update, update_off)
	memcpy_ref_update := b.m.add_value(.func_ref, b.void_type, 'memcpy', b.fn_ids['memcpy'])
	b.block_instr4(.call, blk_update, ptr_i8, memcpy_ref_update, update_dest, val_ptr,
		val_size_update)
	b.block_instr0(.ret, blk_update, b.void_type)

	len := b.block_instr1(.load, blk_insert, b.i64_type, len_ptr)
	cap := b.block_instr1(.load, blk_insert, b.i64_type, cap_ptr)
	needs_grow := b.block_instr2(.ge, blk_insert, b.i1_type, len, cap)
	blk_grow := b.m.add_block(func_id, 'map_set_grow')
	blk_store := b.m.add_block(func_id, 'map_set_store')
	b.block_instr3(.br, blk_insert, b.void_type, needs_grow, ValueID(blk_grow), ValueID(blk_store))

	two := b.m.get_or_add_const(b.i64_type, '2')
	eight := b.m.get_or_add_const(b.i64_type, '8')
	key_size_grow := b.block_instr1(.load, blk_grow, b.i64_type, key_size_ptr)
	val_size_grow := b.block_instr1(.load, blk_grow, b.i64_type, val_size_ptr)
	keys_old := b.block_instr1(.load, blk_grow, ptr_i8, keys_ptr)
	vals_old := b.block_instr1(.load, blk_grow, ptr_i8, vals_ptr)
	double_cap := b.block_instr2(.mul, blk_grow, b.i64_type, cap, two)
	new_cap := b.block_instr2(.add, blk_grow, b.i64_type, double_cap, eight)
	key_bytes := b.block_instr2(.mul, blk_grow, b.i64_type, new_cap, key_size_grow)
	val_bytes := b.block_instr2(.mul, blk_grow, b.i64_type, new_cap, val_size_grow)
	realloc_ref_keys := b.m.add_value(.func_ref, b.void_type, 'realloc', b.fn_ids['realloc'])
	realloc_ref_vals := b.m.add_value(.func_ref, b.void_type, 'realloc', b.fn_ids['realloc'])
	keys_new := b.block_instr3(.call, blk_grow, ptr_i8, realloc_ref_keys, keys_old, key_bytes)
	vals_new := b.block_instr3(.call, blk_grow, ptr_i8, realloc_ref_vals, vals_old, val_bytes)
	b.block_instr2(.store, blk_grow, b.void_type, keys_new, keys_ptr)
	b.block_instr2(.store, blk_grow, b.void_type, vals_new, vals_ptr)
	b.block_instr2(.store, blk_grow, b.void_type, new_cap, cap_ptr)
	b.block_instr1(.jmp, blk_grow, b.void_type, ValueID(blk_store))

	keys := b.block_instr1(.load, blk_store, ptr_i8, keys_ptr)
	vals := b.block_instr1(.load, blk_store, ptr_i8, vals_ptr)
	key_size := b.block_instr1(.load, blk_store, b.i64_type, key_size_ptr)
	val_size := b.block_instr1(.load, blk_store, b.i64_type, val_size_ptr)
	key_off := b.block_instr2(.mul, blk_store, b.i64_type, len, key_size)
	val_off := b.block_instr2(.mul, blk_store, b.i64_type, len, val_size)
	key_dest := b.block_instr2(.add, blk_store, ptr_i8, keys, key_off)
	val_dest := b.block_instr2(.add, blk_store, ptr_i8, vals, val_off)
	memcpy_ref_key := b.m.add_value(.func_ref, b.void_type, 'memcpy', b.fn_ids['memcpy'])
	memcpy_ref_val := b.m.add_value(.func_ref, b.void_type, 'memcpy', b.fn_ids['memcpy'])
	b.block_instr4(.call, blk_store, ptr_i8, memcpy_ref_key, key_dest, key_ptr, key_size)
	b.block_instr4(.call, blk_store, ptr_i8, memcpy_ref_val, val_dest, val_ptr, val_size)
	one := b.m.get_or_add_const(b.i64_type, '1')
	new_len := b.block_instr2(.add, blk_store, b.i64_type, len, one)
	b.block_instr2(.store, blk_store, b.void_type, new_len, len_ptr)
	b.block_instr0(.ret, blk_store, b.void_type)
}

fn (mut b Builder) generate_array_new_body(func_id int) {
	ptr_i8 := b.m.type_store.get_ptr(b.i8_type)
	ptr_array := b.m.type_store.get_ptr(b.array_type)
	ptr_i64 := b.m.type_store.get_ptr(b.i64_type)
	entry := b.m.add_block(func_id, 'entry')
	elem_size := b.func_add_argument(func_id, b.i64_type, 'elem_size')
	len := b.func_add_argument(func_id, b.i64_type, 'len')
	cap := b.func_add_argument(func_id, b.i64_type, 'cap')

	alloca_arr := b.block_instr0(.alloca, entry, ptr_array)
	alloca_cap := b.block_instr0(.alloca, entry, ptr_i64)
	cap_lt_len := b.block_instr2(.lt, entry, b.i1_type, cap, len)

	blk_use_len := b.m.add_block(func_id, 'array_new_use_len')
	blk_use_cap := b.m.add_block(func_id, 'array_new_use_cap')
	blk_init := b.m.add_block(func_id, 'array_new_init')
	b.block_instr3(.br, entry, b.void_type, cap_lt_len, ValueID(blk_use_len), ValueID(blk_use_cap))

	b.block_instr2(.store, blk_use_len, b.void_type, len, alloca_cap)
	b.block_instr1(.jmp, blk_use_len, b.void_type, ValueID(blk_init))

	b.block_instr2(.store, blk_use_cap, b.void_type, cap, alloca_cap)
	b.block_instr1(.jmp, blk_use_cap, b.void_type, ValueID(blk_init))

	final_cap := b.block_instr1(.load, blk_init, b.i64_type, alloca_cap)
	fn_ref := b.m.add_value(.func_ref, b.void_type, 'calloc', b.fn_ids['calloc'])
	data := b.block_instr3(.call, blk_init, ptr_i8, fn_ref, final_cap, elem_size)

	data_ptr := b.block_struct_field_ptr(blk_init, alloca_arr, b.array_type, 0)
	len_ptr := b.block_struct_field_ptr(blk_init, alloca_arr, b.array_type, 1)
	cap_ptr := b.block_struct_field_ptr(blk_init, alloca_arr, b.array_type, 2)
	elem_size_ptr := b.block_struct_field_ptr(blk_init, alloca_arr, b.array_type, 3)
	b.block_instr2(.store, blk_init, b.void_type, data, data_ptr)
	b.block_instr2(.store, blk_init, b.void_type, len, len_ptr)
	b.block_instr2(.store, blk_init, b.void_type, final_cap, cap_ptr)
	b.block_instr2(.store, blk_init, b.void_type, elem_size, elem_size_ptr)

	arr := b.block_instr1(.load, blk_init, b.array_type, alloca_arr)
	b.block_instr1(.ret, blk_init, b.void_type, arr)
}

fn (mut b Builder) generate_array_get_body(func_id int) {
	ptr_i8 := b.m.type_store.get_ptr(b.i8_type)
	ptr_array := b.m.type_store.get_ptr(b.array_type)
	entry := b.m.add_block(func_id, 'entry')
	arr := b.func_add_argument(func_id, b.array_type, 'arr')
	idx := b.func_add_argument(func_id, b.i64_type, 'idx')

	alloca_arr := b.block_instr0(.alloca, entry, ptr_array)
	b.block_instr2(.store, entry, b.void_type, arr, alloca_arr)

	data_ptr := b.block_struct_field_ptr(entry, alloca_arr, b.array_type, 0)
	elem_size_ptr := b.block_struct_field_ptr(entry, alloca_arr, b.array_type, 3)
	data := b.block_instr1(.load, entry, ptr_i8, data_ptr)
	elem_size := b.block_instr1(.load, entry, b.i64_type, elem_size_ptr)
	offset := b.block_instr2(.mul, entry, b.i64_type, idx, elem_size)
	result := b.block_instr2(.add, entry, ptr_i8, data, offset)
	b.block_instr1(.ret, entry, b.void_type, result)
}

fn (mut b Builder) generate_array_push_body(func_id int) {
	ptr_i8 := b.m.type_store.get_ptr(b.i8_type)
	ptr_array := b.m.type_store.get_ptr(b.array_type)
	entry := b.m.add_block(func_id, 'entry')
	arr_ptr := b.func_add_argument(func_id, ptr_array, 'arr')
	elem_ptr := b.func_add_argument(func_id, ptr_i8, 'elem')

	data_ptr := b.block_struct_field_ptr(entry, arr_ptr, b.array_type, 0)
	len_ptr := b.block_struct_field_ptr(entry, arr_ptr, b.array_type, 1)
	cap_ptr := b.block_struct_field_ptr(entry, arr_ptr, b.array_type, 2)
	elem_size_ptr := b.block_struct_field_ptr(entry, arr_ptr, b.array_type, 3)
	len := b.block_instr1(.load, entry, b.i64_type, len_ptr)
	cap := b.block_instr1(.load, entry, b.i64_type, cap_ptr)
	needs_grow := b.block_instr2(.ge, entry, b.i1_type, len, cap)

	blk_grow := b.m.add_block(func_id, 'array_push_grow')
	blk_store := b.m.add_block(func_id, 'array_push_store')
	b.block_instr3(.br, entry, b.void_type, needs_grow, ValueID(blk_grow), ValueID(blk_store))

	two := b.m.get_or_add_const(b.i64_type, '2')
	old_data := b.block_instr1(.load, blk_grow, ptr_i8, data_ptr)
	elem_size_grow := b.block_instr1(.load, blk_grow, b.i64_type, elem_size_ptr)
	double_cap := b.block_instr2(.mul, blk_grow, b.i64_type, cap, two)
	new_cap := b.block_instr2(.add, blk_grow, b.i64_type, double_cap, two)
	new_size := b.block_instr2(.mul, blk_grow, b.i64_type, new_cap, elem_size_grow)
	realloc_ref := b.m.add_value(.func_ref, b.void_type, 'realloc', b.fn_ids['realloc'])
	new_data := b.block_instr3(.call, blk_grow, ptr_i8, realloc_ref, old_data, new_size)
	b.block_instr2(.store, blk_grow, b.void_type, new_data, data_ptr)
	b.block_instr2(.store, blk_grow, b.void_type, new_cap, cap_ptr)
	b.block_instr1(.jmp, blk_grow, b.void_type, ValueID(blk_store))

	data := b.block_instr1(.load, blk_store, ptr_i8, data_ptr)
	elem_size := b.block_instr1(.load, blk_store, b.i64_type, elem_size_ptr)
	offset := b.block_instr2(.mul, blk_store, b.i64_type, len, elem_size)
	dest := b.block_instr2(.add, blk_store, ptr_i8, data, offset)
	memcpy_ref := b.m.add_value(.func_ref, b.void_type, 'memcpy', b.fn_ids['memcpy'])
	b.block_instr4(.call, blk_store, ptr_i8, memcpy_ref, dest, elem_ptr, elem_size)
	one := b.m.get_or_add_const(b.i64_type, '1')
	new_len := b.block_instr2(.add, blk_store, b.i64_type, len, one)
	b.block_instr2(.store, blk_store, b.void_type, new_len, len_ptr)
	b.block_instr0(.ret, blk_store, b.void_type)
}

fn (mut b Builder) register_string_eq_stub() {
	mut p2 := []TypeID{}
	p2 << b.str_type
	p2 << b.str_type
	func_id := b.register_synthetic_function('string__eq', b.i1_type, p2)
	b.generate_string_eq_body(func_id)
}

fn (mut b Builder) register_fast_string_eq_stub() {
	mut p2 := []TypeID{}
	p2 << b.str_type
	p2 << b.str_type
	func_id := b.register_synthetic_function('fast_string_eq', b.i1_type, p2)
	b.generate_string_eq_body(func_id)
}

fn (mut b Builder) register_string_lt_stub() {
	mut p2 := []TypeID{}
	p2 << b.str_type
	p2 << b.str_type
	func_id := b.register_synthetic_function('string__lt', b.i1_type, p2)
	b.generate_string_lt_body(func_id)
}

fn (mut b Builder) generate_string_eq_body(func_id int) {
	ptr_string := b.m.type_store.get_ptr(b.str_type)
	ptr_i8 := b.m.type_store.get_ptr(b.i8_type)
	ptr_i32 := b.m.type_store.get_ptr(b.i32_type)
	entry := b.m.add_block(func_id, 'entry')
	param_a := b.func_add_argument(func_id, b.str_type, 'a')
	param_b := b.func_add_argument(func_id, b.str_type, 'b')

	alloca_a := b.block_instr0(.alloca, entry, ptr_string)
	alloca_b := b.block_instr0(.alloca, entry, ptr_string)
	b.block_instr2(.store, entry, b.void_type, param_a, alloca_a)
	b.block_instr2(.store, entry, b.void_type, param_b, alloca_b)

	zero_64 := b.m.get_or_add_const(b.i64_type, '0')
	len_off := b.m.get_or_add_const(b.i64_type, '${b.m.struct_field_offset(b.str_type, 1)}')
	a_str_ptr := b.block_instr2(.get_element_ptr, entry, ptr_i8, alloca_a, zero_64)
	b_str_ptr := b.block_instr2(.get_element_ptr, entry, ptr_i8, alloca_b, zero_64)
	a_len_ptr := b.block_instr2(.get_element_ptr, entry, ptr_i32, alloca_a, len_off)
	b_len_ptr := b.block_instr2(.get_element_ptr, entry, ptr_i32, alloca_b, len_off)
	a_str := b.block_instr1(.load, entry, ptr_i8, a_str_ptr)
	b_str := b.block_instr1(.load, entry, ptr_i8, b_str_ptr)
	a_len := b.block_instr1(.load, entry, b.i32_type, a_len_ptr)
	b_len := b.block_instr1(.load, entry, b.i32_type, b_len_ptr)
	len_eq := b.block_instr2(.eq, entry, b.i1_type, a_len, b_len)

	blk_cmp := b.m.add_block(func_id, 'string_eq_cmp')
	blk_false := b.m.add_block(func_id, 'string_eq_false')
	b.block_instr3(.br, entry, b.void_type, len_eq, ValueID(blk_cmp), ValueID(blk_false))

	false_val := b.m.get_or_add_const(b.i1_type, '0')
	b.block_instr1(.ret, blk_false, b.void_type, false_val)

	a_len64 := b.block_instr1(.zext, blk_cmp, b.i64_type, a_len)
	fn_ref := b.m.add_value(.func_ref, b.void_type, 'memcmp', b.fn_ids['memcmp'])
	cmp := b.block_instr4(.call, blk_cmp, b.i64_type, fn_ref, a_str, b_str, a_len64)
	is_eq := b.block_instr2(.eq, blk_cmp, b.i1_type, cmp, zero_64)
	b.block_instr1(.ret, blk_cmp, b.void_type, is_eq)
}

fn (mut b Builder) generate_string_lt_body(func_id int) {
	ptr_string := b.m.type_store.get_ptr(b.str_type)
	ptr_i8 := b.m.type_store.get_ptr(b.i8_type)
	ptr_i32 := b.m.type_store.get_ptr(b.i32_type)
	entry := b.m.add_block(func_id, 'entry')
	param_a := b.func_add_argument(func_id, b.str_type, 'a')
	param_b := b.func_add_argument(func_id, b.str_type, 'b')

	alloca_a := b.block_instr0(.alloca, entry, ptr_string)
	alloca_b := b.block_instr0(.alloca, entry, ptr_string)
	alloca_min := b.block_instr0(.alloca, entry, ptr_i32)
	b.block_instr2(.store, entry, b.void_type, param_a, alloca_a)
	b.block_instr2(.store, entry, b.void_type, param_b, alloca_b)

	zero_64 := b.m.get_or_add_const(b.i64_type, '0')
	len_off := b.m.get_or_add_const(b.i64_type, '${b.m.struct_field_offset(b.str_type, 1)}')
	a_str_ptr := b.block_instr2(.get_element_ptr, entry, ptr_i8, alloca_a, zero_64)
	b_str_ptr := b.block_instr2(.get_element_ptr, entry, ptr_i8, alloca_b, zero_64)
	a_len_ptr := b.block_instr2(.get_element_ptr, entry, ptr_i32, alloca_a, len_off)
	b_len_ptr := b.block_instr2(.get_element_ptr, entry, ptr_i32, alloca_b, len_off)
	a_str := b.block_instr1(.load, entry, ptr_i8, a_str_ptr)
	b_str := b.block_instr1(.load, entry, ptr_i8, b_str_ptr)
	a_len := b.block_instr1(.load, entry, b.i32_type, a_len_ptr)
	b_len := b.block_instr1(.load, entry, b.i32_type, b_len_ptr)
	a_shorter := b.block_instr2(.lt, entry, b.i1_type, a_len, b_len)

	blk_a_min := b.m.add_block(func_id, 'string_lt_a_min')
	blk_b_min := b.m.add_block(func_id, 'string_lt_b_min')
	blk_cmp := b.m.add_block(func_id, 'string_lt_cmp')
	blk_true := b.m.add_block(func_id, 'string_lt_true')
	blk_false := b.m.add_block(func_id, 'string_lt_false')
	blk_cmp_gt := b.m.add_block(func_id, 'string_lt_cmp_gt')
	blk_len := b.m.add_block(func_id, 'string_lt_len')
	b.block_instr3(.br, entry, b.void_type, a_shorter, ValueID(blk_a_min), ValueID(blk_b_min))

	b.block_instr2(.store, blk_a_min, b.void_type, a_len, alloca_min)
	b.block_instr1(.jmp, blk_a_min, b.void_type, ValueID(blk_cmp))

	b.block_instr2(.store, blk_b_min, b.void_type, b_len, alloca_min)
	b.block_instr1(.jmp, blk_b_min, b.void_type, ValueID(blk_cmp))

	min_len := b.block_instr1(.load, blk_cmp, b.i32_type, alloca_min)
	min_len64 := b.block_instr1(.zext, blk_cmp, b.i64_type, min_len)
	fn_ref := b.m.add_value(.func_ref, b.void_type, 'memcmp', b.fn_ids['memcmp'])
	cmp := b.block_instr4(.call, blk_cmp, b.i64_type, fn_ref, a_str, b_str, min_len64)
	cmp_lt_zero := b.block_instr2(.lt, blk_cmp, b.i1_type, cmp, zero_64)
	b.block_instr3(.br, blk_cmp, b.void_type, cmp_lt_zero, ValueID(blk_true), ValueID(blk_cmp_gt))

	cmp_gt_zero := b.block_instr2(.gt, blk_cmp_gt, b.i1_type, cmp, zero_64)
	b.block_instr3(.br, blk_cmp_gt, b.void_type, cmp_gt_zero, ValueID(blk_false), ValueID(blk_len))

	true_val := b.m.get_or_add_const(b.i1_type, '1')
	false_val := b.m.get_or_add_const(b.i1_type, '0')
	b.block_instr1(.ret, blk_true, b.void_type, true_val)
	b.block_instr1(.ret, blk_false, b.void_type, false_val)

	len_lt := b.block_instr2(.lt, blk_len, b.i1_type, a_len, b_len)
	b.block_instr1(.ret, blk_len, b.void_type, len_lt)
}

fn (mut b Builder) generate_wymix_body(func_id int) {
	entry := b.m.add_block(func_id, 'entry')
	param_a := b.func_add_argument(func_id, b.i64_type, 'a')
	param_b := b.func_add_argument(func_id, b.i64_type, 'b')
	result := b.wymix_inline(entry, param_a, param_b)
	b.block_instr1(.ret, entry, b.void_type, result)
}

fn (mut b Builder) generate_wyhash64_body(func_id int) {
	entry := b.m.add_block(func_id, 'entry')
	param_a := b.func_add_argument(func_id, b.i64_type, 'a')
	param_b := b.func_add_argument(func_id, b.i64_type, 'b')

	wyp0 := b.m.get_or_add_const(b.i64_type, '3257665815644502181')
	wyp1 := b.m.get_or_add_const(b.i64_type, '-8378864009470890807')

	x := b.block_instr2(.xor, entry, b.i64_type, param_a, wyp0)
	y := b.block_instr2(.xor, entry, b.i64_type, param_b, wyp1)
	result := b.wymix_inline(entry, x, y)
	b.block_instr1(.ret, entry, b.void_type, result)
}

fn (mut b Builder) wymum_pair_inline(block_id BlockID, a ValueID, b_val ValueID) (ValueID, ValueID) {
	mask32 := b.m.get_or_add_const(b.i64_type, '4294967295')
	c32 := b.m.get_or_add_const(b.i64_type, '32')

	lo := b.block_instr2(.mul, block_id, b.i64_type, a, b_val)

	x0 := b.block_instr2(.and_, block_id, b.i64_type, a, mask32)
	x1 := b.block_instr2(.lshr, block_id, b.i64_type, a, c32)
	y0 := b.block_instr2(.and_, block_id, b.i64_type, b_val, mask32)
	y1 := b.block_instr2(.lshr, block_id, b.i64_type, b_val, c32)
	w0 := b.block_instr2(.mul, block_id, b.i64_type, x0, y0)
	x1y0 := b.block_instr2(.mul, block_id, b.i64_type, x1, y0)
	w0_hi := b.block_instr2(.lshr, block_id, b.i64_type, w0, c32)
	t := b.block_instr2(.add, block_id, b.i64_type, x1y0, w0_hi)
	t_lo := b.block_instr2(.and_, block_id, b.i64_type, t, mask32)
	x0y1 := b.block_instr2(.mul, block_id, b.i64_type, x0, y1)
	w1 := b.block_instr2(.add, block_id, b.i64_type, t_lo, x0y1)
	w2 := b.block_instr2(.lshr, block_id, b.i64_type, t, c32)
	x1y1 := b.block_instr2(.mul, block_id, b.i64_type, x1, y1)
	w1_hi := b.block_instr2(.lshr, block_id, b.i64_type, w1, c32)
	hi_tmp := b.block_instr2(.add, block_id, b.i64_type, x1y1, w2)
	hi := b.block_instr2(.add, block_id, b.i64_type, hi_tmp, w1_hi)

	return lo, hi
}

fn (mut b Builder) wymix_inline(block_id BlockID, a ValueID, b_val ValueID) ValueID {
	lo, hi := b.wymum_pair_inline(block_id, a, b_val)
	return b.block_instr2(.xor, block_id, b.i64_type, hi, lo)
}

fn (mut b Builder) generate_wyhash_body(func_id int) {
	ptr_u8 := b.m.type_store.get_ptr(b.i8_type)
	ptr_u32 := b.m.type_store.get_ptr(b.i32_type)
	ptr_u64 := b.m.type_store.get_ptr(b.i64_type)

	entry := b.m.add_block(func_id, 'entry')
	param_key := b.func_add_argument(func_id, ptr_u8, 'key')
	param_len := b.func_add_argument(func_id, b.i64_type, 'len')
	param_seed := b.func_add_argument(func_id, b.i64_type, 'seed')
	_ := b.func_add_argument(func_id, ptr_u64, 'secret')

	wyp0 := b.m.get_or_add_const(b.i64_type, '3257665815644502181')
	wyp1 := b.m.get_or_add_const(b.i64_type, '-8378864009470890807')

	seed_xor_s0 := b.block_instr2(.xor, entry, b.i64_type, param_seed, wyp0)
	seed_xor_s0_len := b.block_instr2(.xor, entry, b.i64_type, seed_xor_s0, param_len)
	seed_mix := b.wymix_inline(entry, seed_xor_s0_len, wyp1)
	seed_init := b.block_instr2(.xor, entry, b.i64_type, param_seed, seed_mix)

	alloca_a := b.block_instr0(.alloca, entry, ptr_u64)
	alloca_b := b.block_instr0(.alloca, entry, ptr_u64)
	alloca_seed := b.block_instr0(.alloca, entry, ptr_u64)

	zero_64 := b.m.get_or_add_const(b.i64_type, '0')
	one_64 := b.m.get_or_add_const(b.i64_type, '1')
	two_64 := b.m.get_or_add_const(b.i64_type, '2')
	three_64 := b.m.get_or_add_const(b.i64_type, '3')
	four_64 := b.m.get_or_add_const(b.i64_type, '4')
	eight_64 := b.m.get_or_add_const(b.i64_type, '8')
	sixteen_64 := b.m.get_or_add_const(b.i64_type, '16')
	c32 := b.m.get_or_add_const(b.i64_type, '32')

	b.block_instr2(.store, entry, b.void_type, zero_64, alloca_a)
	b.block_instr2(.store, entry, b.void_type, zero_64, alloca_b)
	b.block_instr2(.store, entry, b.void_type, seed_init, alloca_seed)

	blk_short := b.m.add_block(func_id, 'wyhash_short')
	blk_short_4_16 := b.m.add_block(func_id, 'wyhash_short_4_16')
	blk_short_0_3 := b.m.add_block(func_id, 'wyhash_short_0_3')
	blk_wyr3 := b.m.add_block(func_id, 'wyhash_wyr3')
	blk_long := b.m.add_block(func_id, 'wyhash_long')
	blk_final := b.m.add_block(func_id, 'wyhash_final')

	len_le_16 := b.block_instr2(.le, entry, b.i1_type, param_len, sixteen_64)
	b.block_instr3(.br, entry, b.void_type, len_le_16, ValueID(blk_short), ValueID(blk_long))

	len_ge_4 := b.block_instr2(.ge, blk_short, b.i1_type, param_len, four_64)
	b.block_instr3(.br, blk_short, b.void_type, len_ge_4, ValueID(blk_short_4_16),
		ValueID(blk_short_0_3))

	p_as_u32 := b.block_instr1(.bitcast, blk_short_4_16, ptr_u32, param_key)
	wyr4_0 := b.block_instr1(.load, blk_short_4_16, b.i32_type, p_as_u32)
	wyr4_0_64 := b.block_instr1(.zext, blk_short_4_16, b.i64_type, wyr4_0)

	len_shr3 := b.block_instr2(.lshr, blk_short_4_16, b.i64_type, param_len, three_64)
	off1 := b.block_instr2(.shl, blk_short_4_16, b.i64_type, len_shr3, two_64)

	p_off1 := b.block_instr2(.add, blk_short_4_16, ptr_u8, param_key, off1)
	p_off1_u32 := b.block_instr1(.bitcast, blk_short_4_16, ptr_u32, p_off1)
	wyr4_1 := b.block_instr1(.load, blk_short_4_16, b.i32_type, p_off1_u32)
	wyr4_1_64 := b.block_instr1(.zext, blk_short_4_16, b.i64_type, wyr4_1)

	wyr4_0_shifted := b.block_instr2(.shl, blk_short_4_16, b.i64_type, wyr4_0_64, c32)
	a_val := b.block_instr2(.or_, blk_short_4_16, b.i64_type, wyr4_0_shifted, wyr4_1_64)

	len_m4 := b.block_instr2(.sub, blk_short_4_16, b.i64_type, param_len, four_64)
	p_lm4 := b.block_instr2(.add, blk_short_4_16, ptr_u8, param_key, len_m4)
	p_lm4_u32 := b.block_instr1(.bitcast, blk_short_4_16, ptr_u32, p_lm4)
	wyr4_2 := b.block_instr1(.load, blk_short_4_16, b.i32_type, p_lm4_u32)
	wyr4_2_64 := b.block_instr1(.zext, blk_short_4_16, b.i64_type, wyr4_2)

	lm4_moff1 := b.block_instr2(.sub, blk_short_4_16, b.i64_type, len_m4, off1)
	p_lm4_moff1 := b.block_instr2(.add, blk_short_4_16, ptr_u8, param_key, lm4_moff1)
	p_lm4_moff1_u32 := b.block_instr1(.bitcast, blk_short_4_16, ptr_u32, p_lm4_moff1)
	wyr4_3 := b.block_instr1(.load, blk_short_4_16, b.i32_type, p_lm4_moff1_u32)
	wyr4_3_64 := b.block_instr1(.zext, blk_short_4_16, b.i64_type, wyr4_3)

	wyr4_2_shifted := b.block_instr2(.shl, blk_short_4_16, b.i64_type, wyr4_2_64, c32)
	b_val := b.block_instr2(.or_, blk_short_4_16, b.i64_type, wyr4_2_shifted, wyr4_3_64)

	b.block_instr2(.store, blk_short_4_16, b.void_type, a_val, alloca_a)
	b.block_instr2(.store, blk_short_4_16, b.void_type, b_val, alloca_b)
	b.block_instr1(.jmp, blk_short_4_16, b.void_type, ValueID(blk_final))

	len_gt_0 := b.block_instr2(.gt, blk_short_0_3, b.i1_type, param_len, zero_64)
	b.block_instr3(.br, blk_short_0_3, b.void_type, len_gt_0, ValueID(blk_wyr3), ValueID(blk_final))

	byte_0 := b.block_instr1(.load, blk_wyr3, b.i8_type, param_key)
	byte_0_64 := b.block_instr1(.zext, blk_wyr3, b.i64_type, byte_0)
	byte_0_shifted := b.block_instr2(.shl, blk_wyr3, b.i64_type, byte_0_64, sixteen_64)

	len_shr1 := b.block_instr2(.lshr, blk_wyr3, b.i64_type, param_len, one_64)
	p_mid := b.block_instr2(.add, blk_wyr3, ptr_u8, param_key, len_shr1)
	byte_mid := b.block_instr1(.load, blk_wyr3, b.i8_type, p_mid)
	byte_mid_64 := b.block_instr1(.zext, blk_wyr3, b.i64_type, byte_mid)
	byte_mid_shifted := b.block_instr2(.shl, blk_wyr3, b.i64_type, byte_mid_64, eight_64)

	len_m1 := b.block_instr2(.sub, blk_wyr3, b.i64_type, param_len, one_64)
	p_last := b.block_instr2(.add, blk_wyr3, ptr_u8, param_key, len_m1)
	byte_last := b.block_instr1(.load, blk_wyr3, b.i8_type, p_last)
	byte_last_64 := b.block_instr1(.zext, blk_wyr3, b.i64_type, byte_last)

	a_tmp := b.block_instr2(.or_, blk_wyr3, b.i64_type, byte_0_shifted, byte_mid_shifted)
	a_wyr3 := b.block_instr2(.or_, blk_wyr3, b.i64_type, a_tmp, byte_last_64)

	b.block_instr2(.store, blk_wyr3, b.void_type, a_wyr3, alloca_a)
	b.block_instr1(.jmp, blk_wyr3, b.void_type, ValueID(blk_final))

	p_as_u64 := b.block_instr1(.bitcast, blk_long, ptr_u64, param_key)
	wyr8_first := b.block_instr1(.load, blk_long, b.i64_type, p_as_u64)

	p_plus_8 := b.block_instr2(.add, blk_long, ptr_u8, param_key, eight_64)
	p_plus_8_u64 := b.block_instr1(.bitcast, blk_long, ptr_u64, p_plus_8)
	wyr8_second := b.block_instr1(.load, blk_long, b.i64_type, p_plus_8_u64)

	len_m16 := b.block_instr2(.sub, blk_long, b.i64_type, param_len, sixteen_64)
	p_end_16 := b.block_instr2(.add, blk_long, ptr_u8, param_key, len_m16)
	p_end_16_u64 := b.block_instr1(.bitcast, blk_long, ptr_u64, p_end_16)
	wyr8_end_16 := b.block_instr1(.load, blk_long, b.i64_type, p_end_16_u64)

	len_m8 := b.block_instr2(.sub, blk_long, b.i64_type, param_len, eight_64)
	p_end_8 := b.block_instr2(.add, blk_long, ptr_u8, param_key, len_m8)
	p_end_8_u64 := b.block_instr1(.bitcast, blk_long, ptr_u64, p_end_8)
	wyr8_end_8 := b.block_instr1(.load, blk_long, b.i64_type, p_end_8_u64)

	mix_a := b.block_instr2(.xor, blk_long, b.i64_type, wyr8_first, wyp1)
	seed_cur := b.block_instr1(.load, blk_long, b.i64_type, alloca_seed)
	mix_b := b.block_instr2(.xor, blk_long, b.i64_type, wyr8_second, seed_cur)
	seed_long := b.wymix_inline(blk_long, mix_a, mix_b)

	b.block_instr2(.store, blk_long, b.void_type, seed_long, alloca_seed)
	b.block_instr2(.store, blk_long, b.void_type, wyr8_end_16, alloca_a)
	b.block_instr2(.store, blk_long, b.void_type, wyr8_end_8, alloca_b)
	b.block_instr1(.jmp, blk_long, b.void_type, ValueID(blk_final))

	final_a := b.block_instr1(.load, blk_final, b.i64_type, alloca_a)
	final_b := b.block_instr1(.load, blk_final, b.i64_type, alloca_b)
	final_seed := b.block_instr1(.load, blk_final, b.i64_type, alloca_seed)

	final_a_xor := b.block_instr2(.xor, blk_final, b.i64_type, final_a, wyp1)
	final_b_xor := b.block_instr2(.xor, blk_final, b.i64_type, final_b, final_seed)

	mum_lo, mum_hi := b.wymum_pair_inline(blk_final, final_a_xor, final_b_xor)

	lo_xor_s0 := b.block_instr2(.xor, blk_final, b.i64_type, mum_lo, wyp0)
	lo_xor_s0_len := b.block_instr2(.xor, blk_final, b.i64_type, lo_xor_s0, param_len)
	hi_xor_s1 := b.block_instr2(.xor, blk_final, b.i64_type, mum_hi, wyp1)

	final_result := b.wymix_inline(blk_final, lo_xor_s0_len, hi_xor_s1)
	b.block_instr1(.ret, blk_final, b.void_type, final_result)
}

fn (mut b Builder) build_functions() {
	for node in b.a.nodes {
		if node.kind == .fn_decl {
			if b.skip_source_fn(node.value) {
				continue
			}
			if b.used_fns.len > 0 && !b.fn_is_used(node.value) {
				continue
			}
			b.build_function(node)
		}
	}
}

fn (b &Builder) fn_is_used(name string) bool {
	if name in b.used_fns {
		return true
	}
	if name.contains('__') && name.replace('__', '.') in b.used_fns {
		return true
	}
	if name.starts_with('array_') || name.starts_with('string__') || name.starts_with('strings__')
		|| name.starts_with('strconv__') || name.starts_with('IError.') {
		return true
	}
	if name in ['new_map', 'memdup', 'int_str', 'bool_str', 'print', 'println', 'eprint', 'eprintln',
		'exit', 'arguments', 'tos', 'tos3', 'tos_clone', 'cstring_to_vstring', 'malloc_noscan',
		'isnil', 'error', 'error_with_code'] {
		return true
	}
	return false
}

fn (mut b Builder) build_function(node flat.Node) {
	func_id := b.fn_ids[node.value]
	b.cur_func = func_id
	b.vars = map[string]ValueID{}

	for v in b.m.values {
		if v.kind == .global {
			b.vars[v.name] = v.id
		}
	}

	entry := b.m.add_block(func_id, 'entry')
	b.cur_block = entry

	for i in 0 .. node.children_count {
		child := b.a.child_node(&node, i)
		if child.kind == .param {
			typ := b.resolve_type(child.typ)
			param_val := b.m.add_value(.argument, typ, child.value, b.m.funcs[func_id].params.len)
			mut f := b.m.funcs[func_id]
			f.params << param_val
			b.m.funcs[func_id] = f

			alloca := b.emit0(.alloca, b.m.type_store.get_ptr(typ))
			b.emit2(.store, b.void_type, param_val, alloca)
			b.vars[child.value] = alloca
		}
	}

	body_ids := b.fn_body_ids(node)
	for id in body_ids {
		b.build_stmt(id)
	}

	blk := b.m.blocks[b.cur_block]
	if blk.instrs.len == 0 || !b.is_terminator(blk.instrs.last()) {
		ret_type := b.m.funcs[func_id].typ
		if ret_type == b.void_type {
			b.emit0(.ret, b.void_type)
		}
	}
}

fn (b &Builder) fn_body_ids(node flat.Node) []flat.NodeId {
	mut ids := []flat.NodeId{}
	for i in 0 .. node.children_count {
		child := b.a.child_node(&node, i)
		if child.kind != .param {
			ids << b.a.child(&node, i)
		}
	}
	return ids
}

fn (b &Builder) is_terminator(val_id ValueID) bool {
	if val_id <= 0 || val_id >= b.m.values.len {
		return false
	}
	v := b.m.values[val_id]
	if v.kind != .instruction {
		return false
	}
	instr := b.m.instrs[v.index]
	return instr.op == .ret || instr.op == .br || instr.op == .jmp
}

fn (mut b Builder) build_stmt(id flat.NodeId) {
	if int(id) < 0 {
		return
	}
	node := b.a.nodes[int(id)]
	match node.kind {
		.expr_stmt {
			b.build_expr(b.a.child(&node, 0))
		}
		.decl_assign {
			b.build_decl_assign(node)
		}
		.assign {
			b.build_assign(node)
		}
		.selector_assign {
			b.build_selector_assign(node)
		}
		.return_stmt {
			if node.children_count > 0 {
				val := b.build_expr(b.a.child(&node, 0))
				b.emit1(.ret, b.void_type, val)
			} else {
				b.emit0(.ret, b.void_type)
			}
		}
		.for_stmt {
			b.build_for(node)
		}
		.break_stmt {
			if b.break_targets.len > 0 {
				target := b.break_targets.last()
				b.emit1(.jmp, b.void_type, ValueID(target))
			}
		}
		.continue_stmt {
			if b.continue_targets.len > 0 {
				target := b.continue_targets.last()
				b.emit1(.jmp, b.void_type, ValueID(target))
			}
		}
		.if_expr {
			b.build_if(node)
		}
		.block {
			for i in 0 .. node.children_count {
				b.build_stmt(b.a.child(&node, i))
			}
		}
		.assert_stmt {
			b.build_assert(node)
		}
		.empty {}
		else {
			eprintln('build_stmt: unsupported node kind: ${node.kind}')
		}
	}
}

fn (mut b Builder) build_decl_assign(node flat.Node) {
	mut i := 0
	for i < node.children_count {
		lhs_id := b.a.child(&node, i)
		rhs_id := b.a.child(&node, i + 1)
		lhs := b.a.nodes[int(lhs_id)]
		rhs_val := b.build_expr(rhs_id)
		rhs_type := b.value_type(rhs_val)
		alloca := b.emit0(.alloca, b.m.type_store.get_ptr(rhs_type))
		b.emit2(.store, b.void_type, rhs_val, alloca)
		if lhs.kind == .ident {
			b.vars[lhs.value] = alloca
		}
		i += 2
	}
}

fn (mut b Builder) build_assign(node flat.Node) {
	mut i := 0
	for i < node.children_count {
		lhs_id := b.a.child(&node, i)
		rhs_id := b.a.child(&node, i + 1)
		lhs := b.a.nodes[int(lhs_id)]

		if lhs.kind == .ident {
			if addr := b.vars[lhs.value] {
				if node.op == .assign {
					rhs_val := b.build_expr(rhs_id)
					b.emit2(.store, b.void_type, rhs_val, addr)
				} else {
					cur := b.emit1(.load, b.deref_type(addr), addr)
					rhs_val := b.build_expr(rhs_id)
					op := b.compound_to_op(node.op)
					result := b.emit2(op, b.value_type(cur), cur, rhs_val)
					b.emit2(.store, b.void_type, result, addr)
				}
			}
		}
		i += 2
	}
}

fn (mut b Builder) build_selector_assign(node flat.Node) {
	mut i := 0
	for i < node.children_count {
		lhs_id := b.a.child(&node, i)
		rhs_id := b.a.child(&node, i + 1)
		lhs := b.a.nodes[int(lhs_id)]

		if lhs.kind == .selector {
			base_id := b.a.child(&lhs, 0)
			base := b.a.nodes[int(base_id)]
			field_name := lhs.value

			if base.kind == .ident {
				if addr := b.vars[base.value] {
					field_ptr := b.get_field_ptr(addr, field_name)
					if node.op == .assign {
						rhs_val := b.build_expr(rhs_id)
						b.emit2(.store, b.void_type, rhs_val, field_ptr)
					} else {
						field_type := b.deref_type(field_ptr)
						cur := b.emit1(.load, field_type, field_ptr)
						rhs_val := b.build_expr(rhs_id)
						op := b.compound_to_op(node.op)
						result := b.emit2(op, field_type, cur, rhs_val)
						b.emit2(.store, b.void_type, result, field_ptr)
					}
				}
			}
		}
		i += 2
	}
}

fn (mut b Builder) build_for(node flat.Node) {
	init_id := b.a.child(&node, 0)
	cond_id := b.a.child(&node, 1)
	post_id := b.a.child(&node, 2)
	init_node := b.a.nodes[int(init_id)]
	cond_node := b.a.nodes[int(cond_id)]
	post_node := b.a.nodes[int(post_id)]

	if init_node.kind != .empty {
		b.build_stmt(init_id)
	}

	cond_block := b.m.add_block(b.cur_func, 'for_cond')
	body_block := b.m.add_block(b.cur_func, 'for_body')
	post_block := b.m.add_block(b.cur_func, 'for_post')
	exit_block := b.m.add_block(b.cur_func, 'for_exit')

	b.emit1(.jmp, b.void_type, ValueID(cond_block))
	b.cur_block = cond_block

	if cond_node.kind != .empty {
		cond_val := b.build_expr(cond_id)
		b.emit3(.br, b.void_type, cond_val, ValueID(body_block), ValueID(exit_block))
	} else {
		b.emit1(.jmp, b.void_type, ValueID(body_block))
	}

	b.cur_block = body_block
	b.break_targets << exit_block
	b.continue_targets << if post_node.kind != .empty { post_block } else { cond_block }

	for i in 3 .. node.children_count {
		b.build_stmt(b.a.child(&node, i))
	}
	b.break_targets.delete_last()
	b.continue_targets.delete_last()

	blk := b.m.blocks[b.cur_block]
	if blk.instrs.len == 0 || !b.is_terminator(blk.instrs.last()) {
		if post_node.kind != .empty {
			b.emit1(.jmp, b.void_type, ValueID(post_block))
		} else {
			b.emit1(.jmp, b.void_type, ValueID(cond_block))
		}
	}

	if post_node.kind != .empty {
		b.cur_block = post_block
		b.build_stmt(post_id)
		post_blk := b.m.blocks[b.cur_block]
		if post_blk.instrs.len == 0 || !b.is_terminator(post_blk.instrs.last()) {
			b.emit1(.jmp, b.void_type, ValueID(cond_block))
		}
	}

	b.cur_block = exit_block
}

fn (mut b Builder) build_if(node flat.Node) {
	cond_node := b.a.child_node(&node, 0)
	then_block := b.m.add_block(b.cur_func, 'if_then')
	merge_block := b.m.add_block(b.cur_func, 'if_merge')

	if cond_node.kind == .empty {
		b.emit1(.jmp, b.void_type, ValueID(then_block))
	} else {
		cond_val := b.build_expr(b.a.child(&node, 0))
		if node.children_count > 2 {
			else_block := b.m.add_block(b.cur_func, 'if_else')
			b.emit3(.br, b.void_type, cond_val, ValueID(then_block), ValueID(else_block))

			b.cur_block = else_block
			else_node := b.a.child_node(&node, 2)
			if else_node.kind == .if_expr {
				b.build_if(*else_node)
			} else if else_node.kind == .block {
				for i in 0 .. else_node.children_count {
					b.build_stmt(b.a.child(else_node, i))
				}
			}
			eblk := b.m.blocks[b.cur_block]
			if eblk.instrs.len == 0 || !b.is_terminator(eblk.instrs.last()) {
				b.emit1(.jmp, b.void_type, ValueID(merge_block))
			}
		} else {
			b.emit3(.br, b.void_type, cond_val, ValueID(then_block), ValueID(merge_block))
		}
	}

	b.cur_block = then_block
	then_node := b.a.child_node(&node, 1)
	for i in 0 .. then_node.children_count {
		b.build_stmt(b.a.child(then_node, i))
	}
	tblk := b.m.blocks[b.cur_block]
	if tblk.instrs.len == 0 || !b.is_terminator(tblk.instrs.last()) {
		b.emit1(.jmp, b.void_type, ValueID(merge_block))
	}

	b.cur_block = merge_block
}

fn (mut b Builder) build_assert(node flat.Node) {
	cond_val := b.build_expr(b.a.child(&node, 0))
	fail_block := b.m.add_block(b.cur_func, 'assert_fail')
	ok_block := b.m.add_block(b.cur_func, 'assert_ok')
	b.emit3(.br, b.void_type, cond_val, ValueID(ok_block), ValueID(fail_block))

	b.cur_block = fail_block
	if exit_fn := b.fn_ids['exit'] {
		one := b.m.get_or_add_const(b.i64_type, '1')
		fn_ref := b.m.add_value(.func_ref, b.void_type, 'exit', exit_fn)
		b.emit2(.call, b.void_type, fn_ref, one)
	}
	b.emit0(.ret, b.void_type)

	b.cur_block = ok_block
}

fn (mut b Builder) build_expr(id flat.NodeId) ValueID {
	if int(id) < 0 {
		return b.m.get_or_add_const(b.i64_type, '0')
	}
	node := b.a.nodes[int(id)]
	match node.kind {
		.int_literal {
			return b.m.get_or_add_const(b.i64_type, node.value)
		}
		.bool_literal {
			val := if node.value == 'true' { '1' } else { '0' }
			return b.m.get_or_add_const(b.i1_type, val)
		}
		.string_literal {
			return b.m.add_value(.string_literal, b.str_type, node.value, 0)
		}
		.string_interp {
			return b.build_string_interp(node)
		}
		.sizeof_expr {
			size := b.m.type_size(b.resolve_type(node.value))
			return b.m.get_or_add_const(b.i64_type, '${size}')
		}
		.ident {
			if addr := b.vars[node.value] {
				addr_val := b.m.values[addr]
				if addr_val.kind == .argument {
					return addr
				}
				return b.emit1(.load, b.deref_type(addr), addr)
			}
			return b.m.get_or_add_const(b.i64_type, '0')
		}
		.infix {
			return b.build_infix(node)
		}
		.prefix {
			return b.build_prefix(node, id)
		}
		.postfix {
			return b.build_postfix(node)
		}
		.paren {
			return b.build_expr(b.a.child(&node, 0))
		}
		.call {
			return b.build_call(node)
		}
		.selector {
			return b.build_selector(node)
		}
		.struct_init {
			return b.build_struct_init(node)
		}
		.cast_expr {
			return b.build_expr(b.a.child(&node, 0))
		}
		.nil_literal {
			return b.m.get_or_add_const(b.m.type_store.get_ptr(b.i8_type), '0')
		}
		.if_expr {
			b.build_if(node)
			return b.m.get_or_add_const(b.i64_type, '0')
		}
		else {
			eprintln('build_expr: unsupported expr kind: ${node.kind}')
			return b.m.get_or_add_const(b.i64_type, '0')
		}
	}
}

fn (mut b Builder) build_infix(node flat.Node) ValueID {
	if node.op == .logical_and || node.op == .logical_or {
		return b.build_short_circuit(node)
	}
	lhs := b.build_expr(b.a.child(&node, 0))
	rhs := b.build_expr(b.a.child(&node, 1))
	op := match node.op {
		.plus { OpCode.add }
		.minus { OpCode.sub }
		.mul { OpCode.mul }
		.div { OpCode.sdiv }
		.mod { OpCode.srem }
		.amp { OpCode.and_ }
		.pipe { OpCode.or_ }
		.xor { OpCode.xor }
		.left_shift { OpCode.shl }
		.right_shift { OpCode.ashr }
		.eq { OpCode.eq }
		.ne { OpCode.ne }
		.lt { OpCode.lt }
		.gt { OpCode.gt }
		.le { OpCode.le }
		.ge { OpCode.ge }
		else { OpCode.add }
	}

	result_type := b.value_type(lhs)
	return b.emit2(op, result_type, lhs, rhs)
}

fn (mut b Builder) build_short_circuit(node flat.Node) ValueID {
	result_alloca := b.emit0(.alloca, b.m.type_store.get_ptr(b.i1_type))
	lhs := b.build_expr(b.a.child(&node, 0))
	b.emit2(.store, b.void_type, lhs, result_alloca)

	rhs_block := b.m.add_block(b.cur_func, 'sc_rhs')
	merge_block := b.m.add_block(b.cur_func, 'sc_merge')

	if node.op == .logical_and {
		b.emit3(.br, b.void_type, lhs, ValueID(rhs_block), ValueID(merge_block))
	} else {
		b.emit3(.br, b.void_type, lhs, ValueID(merge_block), ValueID(rhs_block))
	}

	b.cur_block = rhs_block
	rhs := b.build_expr(b.a.child(&node, 1))
	b.emit2(.store, b.void_type, rhs, result_alloca)
	b.emit1(.jmp, b.void_type, ValueID(merge_block))

	b.cur_block = merge_block
	return b.emit1(.load, b.i1_type, result_alloca)
}

fn (mut b Builder) build_prefix(node flat.Node, _id flat.NodeId) ValueID {
	child_id := b.a.child(&node, 0)
	child := b.a.nodes[int(child_id)]
	if node.op == .amp && child.kind == .struct_init {
		return b.build_heap_struct_init(child)
	}
	if node.op == .amp && child.kind == .ident {
		if addr := b.vars[child.value] {
			return addr
		}
	}
	val := b.build_expr(child_id)
	match node.op {
		.minus {
			zero := b.m.get_or_add_const(b.i64_type, '0')
			return b.emit2(.sub, b.value_type(val), zero, val)
		}
		.not {
			zero := b.m.get_or_add_const(b.i1_type, '0')
			return b.emit2(.eq, b.i1_type, val, zero)
		}
		.bit_not {
			minus_one := b.m.get_or_add_const(b.i64_type, '-1')
			return b.emit2(.xor, b.value_type(val), val, minus_one)
		}
		.amp {
			return val
		}
		.mul {
			return b.emit1(.load, b.deref_type(val), val)
		}
		else {
			return val
		}
	}
}

fn (mut b Builder) build_postfix(node flat.Node) ValueID {
	child_id := b.a.child(&node, 0)
	child := b.a.nodes[int(child_id)]
	if child.kind == .ident {
		if addr := b.vars[child.value] {
			cur := b.emit1(.load, b.deref_type(addr), addr)
			one := b.m.get_or_add_const(b.i64_type, '1')
			op := if node.op == .inc { OpCode.add } else { OpCode.sub }
			result := b.emit2(op, b.value_type(cur), cur, one)
			b.emit2(.store, b.void_type, result, addr)
			return cur
		}
	}
	return b.m.get_or_add_const(b.i64_type, '0')
}

fn (mut b Builder) build_call(node flat.Node) ValueID {
	fn_node := b.a.child_node(&node, 0)
	fn_name := fn_node.value

	mut is_method := false
	mut base_id := flat.NodeId(0)
	actual_name := if fn_node.kind == .selector {
		base := b.a.child_node(fn_node, 0)
		if base.kind == .ident && base.value == 'C' {
			fn_node.value
		} else {
			mut found_name := fn_node.value
			if base.kind == .ident {
				full_name := '${base.value}.${fn_node.value}'
				c_name := full_name.replace('.', '__')
				if full_name in b.fn_ids {
					found_name = full_name
				} else if c_name in b.fn_ids {
					found_name = c_name
				}
			}
			if found_name == fn_node.value {
				for fname, _ in b.fn_ids {
					if fname.ends_with('.${fn_node.value}') || fname.ends_with('__${fn_node.value}') {
						found_name = fname
						is_method = true
						base_id = b.a.child(fn_node, 0)
						break
					}
				}
			}
			found_name
		}
	} else {
		fn_name
	}

	if actual_name == 'FILE' {
		if node.children_count > 1 {
			return b.build_expr(b.a.child(&node, 1))
		}
		return b.m.get_or_add_const(b.m.type_store.get_ptr(b.i8_type), '0')
	}
	if actual_name == 'IError' {
		if node.children_count > 1 {
			return b.build_expr(b.a.child(&node, 1))
		}
		return b.m.get_or_add_const(b.m.type_store.get_ptr(b.i8_type), '0')
	}

	mut resolved_name := actual_name
	if resolved_name !in b.fn_ids && resolved_name.contains('.') {
		c_name := resolved_name.replace('.', '__')
		if c_name in b.fn_ids {
			resolved_name = c_name
		}
	}

	mut fn_idx := 0
	if idx := b.fn_ids[resolved_name] {
		fn_idx = idx
	} else {
		cur_name := if b.cur_func >= 0 && b.cur_func < b.m.funcs.len {
			b.m.funcs[b.cur_func].name
		} else {
			'<none>'
		}
		eprintln('ssa debug: unknown function actual="${actual_name}" resolved="${resolved_name}" fn_node.kind=${fn_node.kind} fn_node.value="${fn_node.value}" in=${cur_name} call.children=${node.children_count}')
		for i in 0 .. node.children_count {
			child := b.a.child_node(&node, i)
			eprintln('  child[${i}]: kind=${child.kind} value="${child.value}" typ="${child.typ}" op=${child.op} children=${child.children_count}')
		}
		panic('ssa: unknown function `${actual_name}`')
	}
	fn_ref := b.m.add_value(.func_ref, b.void_type, resolved_name, fn_idx)
	ret_type := b.m.funcs[fn_idx].typ

	mut param_types := []TypeID{}
	if ft_id := b.fn_types[resolved_name] {
		ft := b.m.type_store.types[ft_id]
		param_types = ft.params.clone()
	}

	mut args := []ValueID{}
	args << fn_ref
	if is_method {
		if param_types.len > 0 {
			pt := b.m.type_store.types[param_types[0]]
			if pt.kind == .ptr_t {
				base_node := b.a.nodes[int(base_id)]
				if base_node.kind == .ident {
					if addr := b.vars[base_node.value] {
						args << addr
					} else {
						args << b.build_expr(base_id)
					}
				} else {
					args << b.build_expr(base_id)
				}
			} else {
				args << b.build_expr(base_id)
			}
		} else {
			args << b.build_expr(base_id)
		}
	}
	for i in 1 .. node.children_count {
		arg_id := b.a.child(&node, i)
		param_idx := if is_method { i } else { i - 1 }
		if param_idx < param_types.len {
			pt := b.m.type_store.types[param_types[param_idx]]
			if pt.kind == .ptr_t {
				arg_node := b.a.nodes[int(arg_id)]
				if arg_node.kind == .ident {
					if addr := b.vars[arg_node.value] {
						args << addr
						continue
					}
				}
			}
		}
		args << b.build_expr(arg_id)
	}
	return b.m.add_instr(.call, b.cur_block, ret_type, args)
}

fn (mut b Builder) build_selector(node flat.Node) ValueID {
	base_id := b.a.child(&node, 0)
	base := b.a.nodes[int(base_id)]
	field_name := node.value

	if base.kind == .ident {
		if addr := b.vars[base.value] {
			field_ptr := b.get_field_ptr(addr, field_name)
			return b.emit1(.load, b.deref_type(field_ptr), field_ptr)
		}
	}
	return b.m.get_or_add_const(b.i64_type, '0')
}

fn (mut b Builder) build_struct_init(node flat.Node) ValueID {
	struct_name := node.value
	if typ_id := b.struct_types[struct_name] {
		alloca := b.emit0(.alloca, b.m.type_store.get_ptr(typ_id))
		typ := b.m.type_store.types[typ_id]
		mut initialized := map[string]bool{}
		for i in 0 .. node.children_count {
			field_node := b.a.child_node(&node, i)
			field_val := b.build_expr(b.a.child(field_node, 0))
			for fi, fname in typ.field_names {
				if fname == field_node.value {
					offset := b.m.struct_field_offset(typ_id, fi)
					off_const := b.m.get_or_add_const(b.i64_type, '${offset}')
					field_type := if fi < typ.fields.len { typ.fields[fi] } else { b.i64_type }
					field_ptr := b.emit2(.get_element_ptr, b.m.type_store.get_ptr(field_type),
						alloca, off_const)
					b.emit2(.store, b.void_type, field_val, field_ptr)
					initialized[fname] = true
					break
				}
			}
		}
		zero := b.m.get_or_add_const(b.i64_type, '0')
		for fi, fname in typ.field_names {
			if fname !in initialized {
				offset := b.m.struct_field_offset(typ_id, fi)
				off_const := b.m.get_or_add_const(b.i64_type, '${offset}')
				field_type := if fi < typ.fields.len { typ.fields[fi] } else { b.i64_type }
				field_ptr := b.emit2(.get_element_ptr, b.m.type_store.get_ptr(field_type), alloca,
					off_const)
				b.emit2(.store, b.void_type, zero, field_ptr)
			}
		}
		return b.emit1(.load, typ_id, alloca)
	}
	return b.m.get_or_add_const(b.i64_type, '0')
}

fn (mut b Builder) build_heap_struct_init(node flat.Node) ValueID {
	struct_name := node.value
	if typ_id := b.struct_types[struct_name] {
		alloca := b.emit0(.alloca, b.m.type_store.get_ptr(typ_id))
		typ := b.m.type_store.types[typ_id]
		for i in 0 .. node.children_count {
			field_node := b.a.child_node(&node, i)
			field_val := b.build_expr(b.a.child(field_node, 0))
			for fi, fname in typ.field_names {
				if fname == field_node.value {
					offset := b.m.struct_field_offset(typ_id, fi)
					off_const := b.m.get_or_add_const(b.i64_type, '${offset}')
					field_type := if fi < typ.fields.len { typ.fields[fi] } else { b.i64_type }
					field_ptr := b.emit2(.get_element_ptr, b.m.type_store.get_ptr(field_type),
						alloca, off_const)
					b.emit2(.store, b.void_type, field_val, field_ptr)
					break
				}
			}
		}
		size := b.m.type_size(typ_id)
		size_const := b.m.get_or_add_const(b.i64_type, '${size}')
		ptr_i8 := b.m.type_store.get_ptr(b.i8_type)
		src_cast := b.emit1(.bitcast, ptr_i8, alloca)
		memdup_ref := b.m.add_value(.func_ref, ptr_i8, 'memdup', b.fn_ids['memdup'])
		result := b.emit3(.call, ptr_i8, memdup_ref, src_cast, size_const)
		return b.emit1(.bitcast, b.m.type_store.get_ptr(typ_id), result)
	}
	return b.m.get_or_add_const(b.i64_type, '0')
}

fn (mut b Builder) build_string_interp(node flat.Node) ValueID {
	n := node.children_count
	if n == 0 {
		return b.m.add_value(.string_literal, b.str_type, '', 0)
	}
	mut parts := []ValueID{}
	for i in 0 .. n {
		child_id := b.a.child(&node, i)
		child := b.a.nodes[int(child_id)]
		if child.kind == .string_literal {
			parts << b.m.add_value(.string_literal, b.str_type, child.value, 0)
		} else {
			vtype := b.infer_v_type(child_id)
			if vtype == 'string' {
				parts << b.build_expr(child_id)
			} else {
				val := b.build_expr(child_id)
				int_str_ref := b.m.add_value(.func_ref, b.str_type, 'int_str', b.fn_ids['int_str'])
				parts << b.emit2(.call, b.str_type, int_str_ref, val)
			}
		}
	}
	count_const := b.m.get_or_add_const(b.i64_type, '${parts.len}')
	alloca := b.emit1(.alloca, b.m.type_store.get_ptr(b.str_type), count_const)
	for i, part in parts {
		off_const := b.m.get_or_add_const(b.i64_type, '${i * b.m.type_size(b.str_type)}')
		ptr := b.emit2(.get_element_ptr, b.m.type_store.get_ptr(b.str_type), alloca, off_const)
		b.emit2(.store, b.void_type, part, ptr)
	}
	fn_ref := b.m.add_value(.func_ref, b.str_type, 'string_plus_many', b.fn_ids['string_plus_many'])
	return b.emit3(.call, b.str_type, fn_ref, count_const, alloca)
}

fn (mut b Builder) get_field_ptr(base_addr ValueID, field_name string) ValueID {
	mut struct_typ_id := TypeID(0)
	base_val := b.m.values[base_addr]
	base_type_id := base_val.typ
	if base_type_id > 0 && base_type_id < b.m.type_store.types.len {
		base_type := b.m.type_store.types[base_type_id]
		if base_type.kind == .ptr_t {
			elem_type := b.m.type_store.types[base_type.elem_type]
			if elem_type.kind == .ptr_t {
				struct_typ_id = elem_type.elem_type
			} else if elem_type.kind == .struct_t {
				struct_typ_id = base_type.elem_type
			}
		}
	}

	if struct_typ_id > 0 {
		typ := b.m.type_store.types[struct_typ_id]
		for fi, fname in typ.field_names {
			if fname == field_name {
				offset := b.m.struct_field_offset(struct_typ_id, fi)
				off_const := b.m.get_or_add_const(b.i64_type, '${offset}')
				field_type := if fi < typ.fields.len { typ.fields[fi] } else { b.i64_type }
				ptr_type := b.m.type_store.get_ptr(field_type)

				if b.m.type_store.types[b.m.values[base_addr].typ].kind == .ptr_t {
					inner := b.m.type_store.types[b.m.values[base_addr].typ]
					if inner.kind == .ptr_t && b.m.type_store.types[inner.elem_type].kind == .ptr_t {
						loaded := b.emit1(.load, inner.elem_type, base_addr)
						return b.emit2(.get_element_ptr, ptr_type, loaded, off_const)
					}
				}
				return b.emit2(.get_element_ptr, ptr_type, base_addr, off_const)
			}
		}
	}

	off_const := b.m.get_or_add_const(b.i64_type, '0')
	ptr_type := b.m.type_store.get_ptr(b.i64_type)
	return b.emit2(.get_element_ptr, ptr_type, base_addr, off_const)
}

fn (mut b Builder) resolve_type(name string) TypeID {
	if name.starts_with('&') {
		inner := b.resolve_type(name[1..])
		return b.m.type_store.get_ptr(inner)
	}
	if name.starts_with('[]') || name == 'array' || name == 'Array' {
		return b.array_type
	}
	if name == 'strings.Builder' || name == 'Builder' {
		return b.array_type
	}
	if name.starts_with('map[') || name == 'map' || name == 'Map' {
		return b.map_type
	}
	return match name {
		'int' {
			b.i64_type
		}
		'i8' {
			b.i8_type
		}
		'i16' {
			b.i32_type
		}
		'i32' {
			b.i32_type
		}
		'i64' {
			b.i64_type
		}
		'u8', 'byte' {
			b.i8_type
		}
		'u16' {
			b.i32_type
		}
		'u32' {
			b.i32_type
		}
		'u64' {
			b.i64_type
		}
		'f32' {
			b.i64_type
		}
		'f64' {
			b.i64_type
		}
		'bool' {
			b.i1_type
		}
		'string' {
			b.str_type
		}
		'void', '' {
			b.void_type
		}
		'voidptr' {
			b.m.type_store.get_ptr(b.i8_type)
		}
		else {
			if typ := b.struct_types[name] {
				return typ
			}
			b.i64_type
		}
	}
}

fn (b &Builder) value_type(val_id ValueID) TypeID {
	if val_id <= 0 || val_id >= b.m.values.len {
		return b.i64_type
	}
	v := b.m.values[val_id]
	if v.typ > 0 {
		return v.typ
	}
	return b.i64_type
}

fn (b &Builder) deref_type(ptr_val ValueID) TypeID {
	if ptr_val <= 0 || ptr_val >= b.m.values.len {
		return b.i64_type
	}
	v := b.m.values[ptr_val]
	if v.kind == .instruction {
		instr := b.m.instrs[v.index]
		if instr.op == .alloca || instr.op == .get_element_ptr {
			if v.typ > 0 && v.typ < b.m.type_store.types.len {
				t := b.m.type_store.types[v.typ]
				if t.kind == .ptr_t {
					return t.elem_type
				}
			}
		}
	}
	if v.kind == .global {
		if v.typ > 0 && v.typ < b.m.type_store.types.len {
			t := b.m.type_store.types[v.typ]
			if t.kind == .ptr_t {
				return t.elem_type
			}
		}
	}
	return b.i64_type
}

fn (b &Builder) infer_v_type(id flat.NodeId) string {
	if int(id) < 0 {
		return 'int'
	}
	node := b.a.nodes[int(id)]
	match node.kind {
		.string_literal, .string_interp {
			return 'string'
		}
		.int_literal {
			return 'int'
		}
		.bool_literal {
			return 'bool'
		}
		.ident {
			if addr := b.vars[node.value] {
				val := b.m.values[addr]
				if val.typ == b.str_type || (val.typ > 0 && val.typ < b.m.type_store.types.len
					&& b.m.type_store.types[val.typ].kind == .ptr_t
					&& b.m.type_store.types[val.typ].elem_type == b.str_type) {
					return 'string'
				}
			}
			return 'int'
		}
		.call {
			fn_node := b.a.child_node(&node, 0)
			if fn_node.value == 'int_str' {
				return 'string'
			}
			if fn_idx := b.fn_ids[fn_node.value] {
				ret := b.m.funcs[fn_idx].typ
				if ret == b.str_type {
					return 'string'
				}
			}
			return 'int'
		}
		.infix {
			lt := b.infer_v_type(b.a.child(&node, 0))
			if lt == 'string' {
				return 'string'
			}
			return lt
		}
		else {
			return 'int'
		}
	}
}

fn (mut b Builder) emit0(op OpCode, typ TypeID) ValueID {
	return b.m.add_instr(op, b.cur_block, typ, []ValueID{})
}

fn (mut b Builder) emit1(op OpCode, typ TypeID, a ValueID) ValueID {
	mut ops := []ValueID{}
	ops << a
	return b.m.add_instr(op, b.cur_block, typ, ops)
}

fn (mut b Builder) emit2(op OpCode, typ TypeID, a ValueID, c ValueID) ValueID {
	mut ops := []ValueID{}
	ops << a
	ops << c
	return b.m.add_instr(op, b.cur_block, typ, ops)
}

fn (mut b Builder) emit3(op OpCode, typ TypeID, a ValueID, c ValueID, d ValueID) ValueID {
	mut ops := []ValueID{}
	ops << a
	ops << c
	ops << d
	return b.m.add_instr(op, b.cur_block, typ, ops)
}

fn (b &Builder) compound_to_op(op flat.Op) OpCode {
	return match op {
		.plus_assign { .add }
		.minus_assign { .sub }
		.mul_assign { .mul }
		.div_assign { .sdiv }
		.mod_assign { .srem }
		.amp_assign { .and_ }
		.pipe_assign { .or_ }
		.xor_assign { .xor }
		.left_shift_assign { .shl }
		.right_shift_assign { .ashr }
		else { .add }
	}
}
