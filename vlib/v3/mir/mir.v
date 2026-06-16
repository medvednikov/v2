module mir

import v3.ssa

pub struct Value {
pub mut:
	id    int
	kind  ssa.ValueKind
	typ   ssa.TypeID
	name  string
	index int
	uses  []ssa.ValueID
}

pub struct Instruction {
pub mut:
	op       ssa.OpCode
	operands []ssa.ValueID
	typ      ssa.TypeID
	block    int
}

pub struct BasicBlock {
pub mut:
	id     int
	name   string
	parent int
	instrs []ssa.ValueID
	preds  []ssa.BlockID
	succs  []ssa.BlockID
}

pub struct Function {
pub mut:
	id          int
	name        string
	typ         ssa.TypeID
	blocks      []ssa.BlockID
	params      []ssa.ValueID
	is_c_extern bool
}

@[heap]
pub struct Module {
pub mut:
	type_store ssa.TypeStore
	values     []Value
	instrs     []Instruction
	blocks     []BasicBlock
	funcs      []Function
	globals    []ssa.GlobalVar
}

pub fn lower_from_ssa(m &ssa.Module) Module {
	mut mod := Module{
		type_store: m.type_store
		values:     []Value{len: m.values.len}
		instrs:     []Instruction{len: m.instrs.len}
		blocks:     []BasicBlock{len: m.blocks.len}
		funcs:      []Function{len: m.funcs.len}
		globals:    m.globals
	}

	for i, val in m.values {
		mod.values[i] = Value{
			id:    val.id
			kind:  val.kind
			typ:   val.typ
			name:  val.name
			index: val.index
			uses:  val.uses
		}
	}

	for i, instr in m.instrs {
		mod.instrs[i] = Instruction{
			op:       instr.op
			operands: instr.operands
			typ:      instr.typ
			block:    instr.block
		}
	}

	for i, blk in m.blocks {
		mod.blocks[i] = BasicBlock{
			id:     blk.id
			name:   blk.name
			parent: blk.parent
			instrs: blk.instrs
			preds:  blk.preds
			succs:  blk.succs
		}
	}

	for i, f in m.funcs {
		mod.funcs[i] = Function{
			id:          f.id
			name:        f.name
			typ:         f.typ
			blocks:      f.blocks
			params:      f.params
			is_c_extern: f.is_c_extern
		}
	}

	return mod
}

pub fn (m &Module) type_size(typ_id ssa.TypeID) int {
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

pub fn (m &Module) type_align(typ_id ssa.TypeID) int {
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
