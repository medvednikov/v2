module ssa

import v3.flat

pub struct Builder {
mut:
	m                &Module       = unsafe { nil }
	a                &flat.FlatAst = unsafe { nil }
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
	fn_types         map[string]TypeID
	fn_ids           map[string]int
	struct_types     map[string]TypeID
	break_targets    []BlockID
	continue_targets []BlockID
}

pub fn build(a_ &flat.FlatAst) &Module {
	return build_with_used(a_, map[string]bool{})
}

pub fn build_with_used(a_ &flat.FlatAst, used_fns map[string]bool) &Module {
	mut b := Builder{
		m:        Module.new()
		a:        unsafe { a_ }
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
	p1 = []TypeID{}
	p1 << ptr_i8
	b.register_extern('puts', b.i64_type, p1)
	p1 = []TypeID{}
	p1 << b.i64_type
	b.register_extern('malloc', ptr_i8, p1)
	p3 = []TypeID{}
	p3 << ptr_i8
	p3 << ptr_i8
	p3 << b.i64_type
	b.register_extern('memcpy', ptr_i8, p3)
	p1 = []TypeID{}
	p1 << b.i64_type
	b.register_extern('exit', b.void_type, p1)
	p1 = []TypeID{}
	p1 << ptr_i8
	b.register_extern('fflush', b.void_type, p1)
	// V externs for string interpolation (stubs for now)
	p1 = []TypeID{}
	p1 << b.i64_type
	b.register_runtime_extern('int_str', b.str_type, p1)
	p1 = []TypeID{}
	p1 << b.i1_type
	b.register_runtime_extern('bool_str', b.str_type, p1)
	p2 = []TypeID{}
	p2 << b.i64_type
	p2 << b.i64_type
	b.register_runtime_extern('strconv__format_int', b.str_type, p2)
	p2 = []TypeID{}
	p2 << b.i64_type
	p2 << b.i64_type
	b.register_runtime_extern('strconv__format_uint', b.str_type, p2)
	p1 = []TypeID{}
	p1 << b.i64_type
	b.register_runtime_extern('strconv__f32_to_str_l', b.str_type, p1)
	p1 = []TypeID{}
	p1 << b.i64_type
	b.register_runtime_extern('strconv__f64_to_str_l', b.str_type, p1)
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
			if b.used_fns.len > 0 && node.value !in b.used_fns {
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

fn (mut b Builder) build_functions() {
	for node in b.a.nodes {
		if node.kind == .fn_decl {
			if b.used_fns.len > 0 && node.value !in b.used_fns {
				continue
			}
			b.build_function(node)
		}
	}
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
			for fname, _ in b.fn_ids {
				if fname.ends_with('.${fn_node.value}') {
					found_name = fname
					is_method = true
					base_id = b.a.child(fn_node, 0)
					break
				}
			}
			found_name
		}
	} else {
		fn_name
	}

	mut fn_idx := 0
	if idx := b.fn_ids[actual_name] {
		fn_idx = idx
	} else {
		panic('ssa: unknown function `${actual_name}`')
	}
	fn_ref := b.m.add_value(.func_ref, b.void_type, actual_name, fn_idx)
	ret_type := b.m.funcs[fn_idx].typ

	mut param_types := []TypeID{}
	if ft_id := b.fn_types[actual_name] {
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
