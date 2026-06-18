module ssa

pub type ValueID = int
pub type TypeID = int
pub type BlockID = int

pub enum OpCode {
	// Terminators
	ret
	br
	jmp
	// Binary (integer)
	add
	sub
	mul
	sdiv
	srem
	// Bitwise
	shl
	ashr
	and_
	or_
	xor
	// Memory
	alloca
	load
	store
	get_element_ptr
	// Comparisons
	lt
	gt
	le
	ge
	eq
	ne
	// Other
	call
	neg
	bitcast
	struct_init
}

pub enum TypeKind {
	void_t
	int_t
	float_t
	ptr_t
	struct_t
	func_t
}

pub struct Type {
pub:
	kind        TypeKind
	width       int
	elem_type   TypeID
	fields      []TypeID
	field_names []string
	params      []TypeID
	ret_type    TypeID
}

pub struct TypeStore {
pub mut:
	types []Type
	cache map[string]TypeID
}

pub fn TypeStore.new() TypeStore {
	mut ts := TypeStore{}
	ts.types << Type{
		kind: .void_t
	}
	return ts
}

pub fn (mut ts TypeStore) get_int(width int) TypeID {
	key := 'i${width}'
	if id := ts.cache[key] {
		if id > 0 {
			return id
		}
	}
	id := ts.register(Type{ kind: .int_t, width: width })
	ts.cache[key] = id
	return id
}

pub fn (mut ts TypeStore) get_ptr(elem TypeID) TypeID {
	key := 'p${elem}'
	if id := ts.cache[key] {
		if id > 0 {
			return id
		}
	}
	id := ts.register(Type{ kind: .ptr_t, elem_type: elem })
	ts.cache[key] = id
	return id
}

pub fn (mut ts TypeStore) register(t Type) TypeID {
	id := TypeID(ts.types.len)
	ts.types << t
	return id
}

pub enum ValueKind {
	unknown
	constant
	argument
	global
	instruction
	basic_block
	string_literal
	func_ref
}

pub struct Value {
pub mut:
	id    ValueID
	kind  ValueKind
	typ   TypeID
	name  string
	index int
	uses  []ValueID
}

pub struct Instruction {
pub mut:
	op       OpCode
	operands []ValueID
	block    BlockID
	typ      TypeID
}

pub struct BasicBlock {
pub mut:
	id     BlockID
	name   string
	parent int
	instrs []ValueID
	preds  []BlockID
	succs  []BlockID
}

pub struct Function {
pub mut:
	id          int
	name        string
	typ         TypeID
	blocks      []BlockID
	params      []ValueID
	is_c_extern bool
}

pub struct GlobalVar {
pub mut:
	name          string
	typ           TypeID
	initial_value i64
}

@[heap]
pub struct Module {
pub mut:
	type_store TypeStore
	values     []Value
	instrs     []Instruction
	blocks     []BasicBlock
	funcs      []Function
	globals    []GlobalVar
}

pub fn Module.new() &Module {
	mut m := &Module{
		type_store: TypeStore.new()
	}
	m.values << Value{
		kind: .unknown
		id:   0
	}
	return m
}

pub fn (mut m Module) add_value(kind ValueKind, typ TypeID, name string, index int) ValueID {
	id := ValueID(m.values.len)
	m.values << Value{
		id:    id
		kind:  kind
		typ:   typ
		name:  name
		index: index
	}
	return id
}

pub fn (mut m Module) add_instr(op OpCode, block BlockID, typ TypeID, operands []ValueID) ValueID {
	instr_idx := m.instrs.len
	m.instrs << Instruction{
		op:       op
		block:    block
		typ:      typ
		operands: operands
	}
	val_id := m.add_value(.instruction, typ, '', instr_idx)
	mut blk := m.blocks[block]
	blk.instrs << val_id
	m.blocks[block] = blk
	return val_id
}

pub fn (mut m Module) add_block(func_id int, name string) BlockID {
	id := BlockID(m.blocks.len)
	unique := '${name}_${id}'
	m.blocks << BasicBlock{
		id:     id
		name:   unique
		parent: func_id
	}
	mut f := m.funcs[func_id]
	f.blocks << id
	m.funcs[func_id] = f
	return id
}

pub fn (mut m Module) new_function(name string, ret TypeID) int {
	for i, f in m.funcs {
		if f.name == name {
			return i
		}
	}
	id := m.funcs.len
	m.funcs << Function{
		id:   id
		name: name
		typ:  ret
	}
	return id
}

pub fn (mut m Module) add_global(name string, typ TypeID) ValueID {
	id := m.globals.len
	m.globals << GlobalVar{
		name: name
		typ:  typ
	}
	ptr_typ := m.type_store.get_ptr(typ)
	return m.add_value(.global, ptr_typ, name, id)
}

pub fn (mut m Module) get_or_add_const(typ TypeID, name string) ValueID {
	for v in m.values {
		if v.kind == .constant && v.typ == typ && v.name == name {
			return v.id
		}
	}
	return m.add_value(.constant, typ, name, 0)
}

pub fn (m &Module) type_size(typ_id TypeID) int {
	if typ_id <= 0 || typ_id >= m.type_store.types.len {
		return 0
	}
	typ := m.type_store.types[typ_id]
	return match typ.kind {
		.void_t {
			0
		}
		.int_t {
			if typ.width > 0 {
				(typ.width + 7) / 8
			} else {
				8
			}
		}
		.float_t {
			if typ.width > 0 {
				(typ.width + 7) / 8
			} else {
				8
			}
		}
		.ptr_t {
			8
		}
		.struct_t {
			mut offset := 0
			mut max_align := 1
			for field_typ in typ.fields {
				align := m.type_align(field_typ)
				if align > max_align {
					max_align = align
				}
				if align > 1 && offset % align != 0 {
					offset = (offset + align - 1) & ~(align - 1)
				}
				offset += m.type_size(field_typ)
			}
			total := if max_align > 1 && offset % max_align != 0 {
				(offset + max_align - 1) & ~(max_align - 1)
			} else {
				offset
			}
			if total > 0 {
				total
			} else {
				8
			}
		}
		.func_t {
			8
		}
	}
}

pub fn (m &Module) type_align(typ_id TypeID) int {
	if typ_id <= 0 || typ_id >= m.type_store.types.len {
		return 1
	}
	typ := m.type_store.types[typ_id]
	if typ.kind == .struct_t {
		mut max_align := 1
		for field_typ in typ.fields {
			a := m.type_align(field_typ)
			if a > max_align {
				max_align = a
			}
		}
		return max_align
	}
	size := m.type_size(typ_id)
	if size >= 8 {
		return 8
	}
	if size >= 4 {
		return 4
	}
	return 1
}

pub fn (mut m Module) replace_uses(old_id ValueID, new_id ValueID) {
	if old_id <= 0 || old_id >= m.values.len {
		return
	}
	for user_id in m.values[old_id].uses {
		if user_id <= 0 || user_id >= m.values.len {
			continue
		}
		val := m.values[user_id]
		if val.kind != .instruction {
			continue
		}
		mut instr := m.instrs[val.index]
		for i in 0 .. instr.operands.len {
			if instr.operands[i] == old_id {
				instr.operands[i] = new_id
			}
		}
		m.instrs[val.index] = instr
	}
}

pub fn (i &Instruction) value_operands() []ValueID {
	if i.op == .br {
		if i.operands.len > 0 {
			mut r := []ValueID{}
			r << i.operands[0]
			return r
		}
		return []ValueID{}
	}
	if i.op == .jmp {
		return []ValueID{}
	}
	return i.operands
}

pub fn (m &Module) struct_field_offset(typ_id TypeID, field_idx int) int {
	if typ_id <= 0 || typ_id >= m.type_store.types.len {
		return 0
	}
	typ := m.type_store.types[typ_id]
	if typ.kind != .struct_t {
		return 0
	}
	mut offset := 0
	for i in 0 .. field_idx {
		if i >= typ.fields.len {
			break
		}
		align := m.type_align(typ.fields[i])
		if align > 1 && offset % align != 0 {
			offset = (offset + align - 1) & ~(align - 1)
		}
		offset += m.type_size(typ.fields[i])
	}
	if field_idx < typ.fields.len {
		align := m.type_align(typ.fields[field_idx])
		if align > 1 && offset % align != 0 {
			offset = (offset + align - 1) & ~(align - 1)
		}
	}
	return offset
}
