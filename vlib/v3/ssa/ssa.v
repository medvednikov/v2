module ssa

pub type ValueID = int
pub type TypeID = int
pub type BlockID = int

pub enum OpCode {
	// Terminators
	ret
	br
	jmp
	unreachable
	// Binary (integer)
	add
	sub
	mul
	sdiv
	srem
	udiv
	urem
	// Binary (float)
	fadd
	fsub
	fmul
	fdiv
	frem
	// Bitwise
	shl
	ashr
	lshr
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
	ult
	ugt
	ule
	uge
	eq
	ne
	// Other
	call
	call_indirect
	neg
	trunc
	sext
	zext
	fptoui
	fptosi
	uitofp
	sitofp
	bitcast
	phi
	select
	extractvalue
	insertvalue
	heap_alloc
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
	is_unsigned bool
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

const recursive_type_slot_size = 256

pub fn TypeStore.new() TypeStore {
	mut ts := TypeStore{
		cache: map[string]TypeID{}
	}
	ts.types << Type{
		kind: .void_t
	}
	return ts
}

pub fn (mut ts TypeStore) get_int(width int) TypeID {
	for id, typ in ts.types {
		if typ.kind == .int_t && typ.width == width {
			return TypeID(id)
		}
	}
	id := ts.register(Type{ kind: .int_t, width: width })
	return id
}

pub fn (mut ts TypeStore) get_uint(width int) TypeID {
	key := 'u${width}'
	if id := ts.cache[key] {
		if id > 0 {
			return id
		}
	}
	id := ts.register(Type{ kind: .int_t, width: width, is_unsigned: true })
	ts.cache[key] = id
	return id
}

pub fn (mut ts TypeStore) get_float(width int) TypeID {
	key := 'f${width}'
	if id := ts.cache[key] {
		if id > 0 {
			return id
		}
	}
	id := ts.register(Type{ kind: .float_t, width: width })
	ts.cache[key] = id
	return id
}

pub fn (mut ts TypeStore) get_ptr(elem TypeID) TypeID {
	for id, typ in ts.types {
		if typ.kind == .ptr_t && typ.elem_type == elem {
			return TypeID(id)
		}
	}
	id := ts.register(Type{ kind: .ptr_t, elem_type: elem })
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
	for op_id in m.instrs[instr_idx].value_operands() {
		if op_id > 0 && op_id < m.values.len && val_id !in m.values[op_id].uses {
			mut op_val := m.values[op_id]
			op_val.uses << val_id
			m.values[op_id] = op_val
		}
	}
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
	mut active := []TypeID{}
	return m.type_size_inner(typ_id, 0, mut active)
}

fn type_is_active(typ_id TypeID, active []TypeID) bool {
	for seen in active {
		if seen == typ_id {
			return true
		}
	}
	return false
}

fn (m &Module) type_size_inner(typ_id TypeID, depth int, mut active []TypeID) int {
	if typ_id <= 0 || typ_id >= m.type_store.types.len {
		return 0
	}
	if depth > 32 {
		return recursive_type_slot_size
	}
	typ := m.type_store.types[typ_id]
	if typ.width > 0 {
		return (typ.width + 7) / 8
	}
	if typ.elem_type > 0 && typ.fields.len == 0 {
		return 8
	}
	if typ.fields.len == 0 {
		if typ.params.len > 0 || typ.ret_type > 0 {
			return 8
		}
		return 0
	}
	if typ.fields.len > 256 {
		return 8
	}
	if type_is_active(typ_id, active) {
		return recursive_type_slot_size
	}
	active << typ_id
	mut offset := 0
	mut max_align := 1
	for i in 0 .. typ.fields.len {
		field_typ := typ.fields[i]
		align := m.type_align_inner(field_typ, depth + 1, mut active)
		if align > max_align {
			max_align = align
		}
		if align > 1 && offset % align != 0 {
			offset = (offset + align - 1) & ~(align - 1)
		}
		offset += m.type_size_inner(field_typ, depth + 1, mut active)
	}
	active.delete_last()
	total := if max_align > 1 && offset % max_align != 0 {
		(offset + max_align - 1) & ~(max_align - 1)
	} else {
		offset
	}
	if total > 0 {
		return total
	}
	return 8
}

pub fn (m &Module) type_align(typ_id TypeID) int {
	mut active := []TypeID{}
	return m.type_align_inner(typ_id, 0, mut active)
}

fn (m &Module) type_align_inner(typ_id TypeID, depth int, mut active []TypeID) int {
	if typ_id <= 0 || typ_id >= m.type_store.types.len {
		return 1
	}
	if depth > 32 {
		return 8
	}
	typ := m.type_store.types[typ_id]
	if typ.width > 0 {
		size := (typ.width + 7) / 8
		if size >= 8 {
			return 8
		}
		if size >= 4 {
			return 4
		}
		return 1
	}
	if typ.elem_type > 0 && typ.fields.len == 0 {
		return 8
	}
	if typ.fields.len > 0 {
		if typ.fields.len > 256 {
			return 8
		}
		if type_is_active(typ_id, active) {
			return 8
		}
		active << typ_id
		mut max_align := 1
		for i in 0 .. typ.fields.len {
			field_typ := typ.fields[i]
			a := m.type_align_inner(field_typ, depth + 1, mut active)
			if a > max_align {
				max_align = a
			}
		}
		active.delete_last()
		return max_align
	}
	if typ.params.len > 0 || typ.ret_type > 0 {
		return 8
	}
	size := m.type_size_inner(typ_id, depth + 1, mut active)
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
	if i.op == .phi {
		mut r := []ValueID{}
		for oi := 0; oi < i.operands.len; oi += 2 {
			r << i.operands[oi]
		}
		return r
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
	mut active := []TypeID{}
	active << typ_id
	mut offset := 0
	for i in 0 .. field_idx {
		if i >= typ.fields.len {
			break
		}
		align := m.type_align_inner(typ.fields[i], 1, mut active)
		if align > 1 && offset % align != 0 {
			offset = (offset + align - 1) & ~(align - 1)
		}
		offset += m.type_size_inner(typ.fields[i], 1, mut active)
	}
	if field_idx < typ.fields.len {
		align := m.type_align_inner(typ.fields[field_idx], 1, mut active)
		if align > 1 && offset % align != 0 {
			offset = (offset + align - 1) & ~(align - 1)
		}
	}
	return offset
}

pub fn (m &Module) struct_field_size(typ_id TypeID, field_idx int) int {
	if typ_id <= 0 || typ_id >= m.type_store.types.len {
		return 0
	}
	typ := m.type_store.types[typ_id]
	if typ.kind != .struct_t || field_idx < 0 || field_idx >= typ.fields.len {
		return 0
	}
	mut active := []TypeID{}
	active << typ_id
	return m.type_size_inner(typ.fields[field_idx], 1, mut active)
}
