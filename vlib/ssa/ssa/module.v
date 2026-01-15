module ssa

pub struct TargetData {
pub:
	ptr_size      int
	endian_little bool
}

@[heap]
pub struct Module {
pub mut:
	name       string
	target     TargetData
	type_store TypeStore

	// Arenas
	values  []Value
	instrs  []Instruction
	blocks  []BasicBlock
	funcs   []Function
	globals []GlobalVar
}

pub fn Module.new(name string) &Module {
	mut m := &Module{
		name:       name
		type_store: TypeStore.new()
	}
	// Reserve ID 0 to represent "null" or "invalid", avoiding collisions
	// with map lookups returning 0.
	m.values << Value{
		kind: .unknown
		id:   0
	}
	return m
}

pub fn (mut m Module) new_function(name string, ret TypeID, params []TypeID) int {
	id := m.funcs.len
	m.funcs << Function{
		id:   id
		name: name
		typ:  ret
	}
	return id
}

pub fn (mut m Module) add_block(func_id int, name string) BlockID {
	id := m.blocks.len
	// FIX: Sanitize block names for C labels (replace . with _)
	safe_name := name.replace('.', '_')
	unique_name := '${safe_name}_${id}'

	// Store 'id' (index in blocks arena) in the Value
	val_id := m.add_value_node(.basic_block, 0, unique_name, id)

	m.blocks << BasicBlock{
		id:     id
		val_id: val_id
		name:   unique_name
		parent: func_id
	}
	m.funcs[func_id].blocks << id
	return id
}

// Updated to accept 'index'
pub fn (mut m Module) add_value_node(kind ValueKind, typ TypeID, name string, index int) ValueID {
	id := m.values.len
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
	// 1. Save Instruction Index
	instr_idx := m.instrs.len

	instr := Instruction{
		op:       op
		block:    block
		typ:      typ
		operands: operands
	}
	m.instrs << instr

	// 2. Pass instr_idx to Value
	val_id := m.add_value_node(.instruction, typ, 'v${m.values.len}', instr_idx)

	// 3. Link Block
	m.blocks[block].instrs << val_id

	// 4. Update Def-Use
	for op_id in operands {
		if op_id < m.values.len {
			m.values[op_id].uses << val_id
		}
	}

	return val_id
}

pub fn (mut m Module) add_global(name string, typ TypeID, is_const bool) int {
	id := m.globals.len
	g := GlobalVar{
		name:        name
		typ:         typ
		is_constant: is_const
	}
	m.globals << g

	// FIX: The Value representing a global is a POINTER to the data
	ptr_typ := m.type_store.get_ptr(typ)
	return m.add_value_node(.global, ptr_typ, name, id)
}
