module backend

import ssa
import encoding.binary

pub struct Arm64Gen {
	mod &ssa.Module
mut:
	macho &MachOObject

	stack_map      map[int]int
	alloca_offsets map[int]int
	stack_size     int
	curr_offset    int

	block_offsets  map[int]int
	pending_labels map[int][]int
}

pub fn Arm64Gen.new(mod &ssa.Module) &Arm64Gen {
	return &Arm64Gen{
		mod:   mod
		macho: MachOObject.new()
	}
}

pub fn (mut g Arm64Gen) gen() {
	for func in g.mod.funcs {
		g.gen_func(func)
	}

	// Globals (aligned 8)
	for g.macho.text_data.len % 8 != 0 {
		g.emit(0xd503201f)
	}
	for gvar in g.mod.globals {
		addr := u64(g.macho.text_data.len)
		g.macho.add_symbol('_' + gvar.name, addr, true, 1)
		g.emit(0)
		g.emit(0)
	}

	// Patch symbol addresses for __cstring section (Section 2)
	cstring_base_addr := u64(g.macho.text_data.len)
	for mut sym in g.macho.symbols {
		if sym.sect == 2 {
			sym.value += cstring_base_addr
		}
	}
}

fn (mut g Arm64Gen) gen_func(func ssa.Function) {
	g.curr_offset = g.macho.text_data.len
	g.stack_map = map[int]int{}
	g.alloca_offsets = map[int]int{}
	g.block_offsets = map[int]int{}
	g.pending_labels = map[int][]int{}

	// Calculate Stack Frame
	// Iterate to assign slots
	mut slot_offset := 8 // Starts at 8 (fp-8)

	// Params
	for pid in func.params {
		g.stack_map[pid] = -slot_offset
		slot_offset += 8
	}

	// Instructions
	for blk_id in func.blocks {
		blk := g.mod.blocks[blk_id]
		for val_id in blk.instrs {
			val := g.mod.values[val_id]
			if val.kind != .instruction {
				continue
			}
			instr := g.mod.instrs[val.index]

			// Slot A: The result of the instruction (pointer for alloca, value for others)
			g.stack_map[val_id] = -slot_offset
			slot_offset += 8

			// Slot B: Data storage for Alloca
			if instr.op == .alloca {
				// Allocate extra space. 64 bytes for safety in this demo.
				// Data starts at current slot_offset
				g.alloca_offsets[val_id] = -slot_offset
				slot_offset += 64
			}
		}
	}

	g.stack_size = (slot_offset + 16) & ~0xF // Align 16

	g.macho.add_symbol('_' + func.name, u64(g.curr_offset), true, 1)

	// Prologue
	g.emit(0xA9BF7BFD) // stp fp, lr, [sp, -16]!
	g.emit(0x910003FD) // mov fp, sp
	g.emit_sub_sp(g.stack_size)

	// Spill params
	for i, pid in func.params {
		offset := g.stack_map[pid]
		if i < 8 {
			g.emit_str_reg_offset(i, 29, offset)
		}
	}

	// Body
	for blk_id in func.blocks {
		blk := g.mod.blocks[blk_id]
		g.block_offsets[blk_id] = g.macho.text_data.len - g.curr_offset

		if offsets := g.pending_labels[blk_id] {
			for off in offsets {
				target := g.block_offsets[blk_id]
				rel := (target - off) / 4
				abs_off := g.curr_offset + off
				instr := g.read_u32(abs_off)

				mut new_instr := u32(0)
				if (instr & 0xFC000000) == 0x14000000 {
					new_instr = (instr & 0xFC000000) | (u32(rel) & 0x3FFFFFF)
				} else {
					new_instr = (instr & 0xFF000000) | ((u32(rel) & 0x7FFFF) << 5) | (instr & 0x1F)
				}
				g.write_u32(abs_off, new_instr)
			}
		}

		for val_id in blk.instrs {
			g.gen_instr(val_id)
		}
	}
}

fn (mut g Arm64Gen) gen_instr(val_id int) {
	instr := g.mod.instrs[g.mod.values[val_id].index]

	match instr.op {
		.add, .sub, .mul, .sdiv, .eq, .ne, .lt, .gt, .le, .ge {
			g.load_val_to_reg(8, instr.operands[0])
			g.load_val_to_reg(9, instr.operands[1])

			match instr.op {
				.add {
					g.emit(0x8B090108)
				}
				.sub {
					g.emit(0xCB090108)
				}
				.mul {
					g.emit(0x9B097D08)
				}
				.eq, .ne, .lt, .gt, .le, .ge {
					g.emit(0xEB09011F) // cmp
					code := match instr.op {
						.eq { 0x9A9F17E8 }
						.ne { 0x9A9F07E8 }
						.lt { 0x9A9FA7E8 }
						.gt { 0x9A9FC7E8 }
						.le { 0x9A9FD7E8 }
						.ge { 0x9A9FB7E8 }
						else { 0 }
					}
					g.emit(u32(code))
				}
				else {}
			}
			g.store_reg_to_val(8, val_id)
		}
		.store {
			g.load_val_to_reg(8, instr.operands[0]) // val
			g.load_val_to_reg(9, instr.operands[1]) // ptr (address)
			g.emit(0xF9000128) // str x8, [x9]
		}
		.load {
			g.load_val_to_reg(9, instr.operands[0]) // ptr
			g.emit(0xF9400128) // ldr x8, [x9]
			g.store_reg_to_val(8, val_id)
		}
		.alloca {
			// Get offset of allocated storage (Slot B)
			data_off := g.alloca_offsets[val_id]
			// Compute address fp + data_off
			g.emit_add_fp_imm(8, data_off)
			// Store address into result slot (Slot A)
			g.store_reg_to_val(8, val_id)
		}
		.get_element_ptr {
			g.load_val_to_reg(8, instr.operands[0])
			g.load_val_to_reg(9, instr.operands[1])
			g.emit(0x8B090D08) // add x8, x8, x9, lsl 3
			g.store_reg_to_val(8, val_id)
		}
		.call {
			for i in 1 .. instr.operands.len {
				if i - 1 < 8 {
					g.load_val_to_reg(i - 1, instr.operands[i])
				}
			}
			fn_val := g.mod.values[instr.operands[0]]
			sym_idx := g.macho.add_undefined('_' + fn_val.name)
			g.macho.add_reloc(g.macho.text_data.len, sym_idx, arm64_reloc_branch26, true)
			g.emit(0x94000000)

			if g.mod.type_store.types[g.mod.values[val_id].typ].kind != .void_t {
				g.store_reg_to_val(0, val_id)
			}
		}
		.ret {
			if instr.operands.len > 0 {
				g.load_val_to_reg(0, instr.operands[0])
			}
			g.emit(0x910003BF)
			g.emit(0xA8C17BFD)
			g.emit(0xD65F03C0)
		}
		.jmp {
			target_blk := instr.operands[0]
			target_idx := g.mod.values[target_blk].index
			if off := g.block_offsets[target_idx] {
				rel := (off - (g.macho.text_data.len - g.curr_offset)) / 4
				g.emit(0x14000000 | (u32(rel) & 0x3FFFFFF))
			} else {
				g.record_pending_label(target_idx)
				g.emit(0x14000000)
			}
		}
		.br {
			g.load_val_to_reg(8, instr.operands[0])
			g.emit(0xF100011F) // cmp x8, 0

			true_blk := g.mod.values[instr.operands[1]].index
			false_blk := g.mod.values[instr.operands[2]].index

			if off := g.block_offsets[true_blk] {
				rel := (off - (g.macho.text_data.len - g.curr_offset)) / 4
				g.emit(0x54000001 | ((u32(rel) & 0x7FFFF) << 5))
			} else {
				g.record_pending_label(true_blk)
				g.emit(0x54000001)
			}

			if off := g.block_offsets[false_blk] {
				rel := (off - (g.macho.text_data.len - g.curr_offset)) / 4
				g.emit(0x14000000 | (u32(rel) & 0x3FFFFFF))
			} else {
				g.record_pending_label(false_blk)
				g.emit(0x14000000)
			}
		}
		else {}
	}
}

fn (mut g Arm64Gen) load_val_to_reg(reg int, val_id int) {
	val := g.mod.values[val_id]
	if val.kind == .constant {
		if val.name.starts_with('"') {
			str_content := val.name.trim('"')
			str_offset := g.macho.str_data.len
			g.macho.str_data << str_content.bytes()
			g.macho.str_data << 0

			sym_idx := g.macho.add_symbol('L_str_${str_offset}', u64(str_offset), false,
				2)
			g.macho.add_reloc(g.macho.text_data.len, sym_idx, arm64_reloc_page21, true)
			g.emit(0x90000000 | u32(reg))
			g.macho.add_reloc(g.macho.text_data.len, sym_idx, arm64_reloc_pageoff12, false)
			g.emit(0x91000000 | u32(reg) | (u32(reg) << 5))
		} else {
			int_val := val.name.int()
			g.emit(0xD2800000 | (u32(int_val) << 5) | u32(reg))
		}
	} else if val.kind == .global {
		sym_idx := g.macho.add_undefined('_' + val.name)
		g.macho.add_reloc(g.macho.text_data.len, sym_idx, arm64_reloc_got_load_page21,
			true)
		g.emit(0x90000000 | u32(reg))
		g.macho.add_reloc(g.macho.text_data.len, sym_idx, arm64_reloc_got_load_pageoff12,
			false)
		g.emit(0xF9400000 | u32(reg) | (u32(reg) << 5))
	} else {
		offset := g.stack_map[val_id]
		g.emit_ldr_reg_offset(reg, 29, offset)
	}
}

fn (mut g Arm64Gen) store_reg_to_val(reg int, val_id int) {
	offset := g.stack_map[val_id]
	g.emit_str_reg_offset(reg, 29, offset)
}

fn (mut g Arm64Gen) emit_sub_sp(imm int) {
	g.emit(0xD1000000 | (u32(imm) << 10) | (31 << 5) | 31)
}

fn (mut g Arm64Gen) emit_add_fp_imm(rd int, imm int) {
	val := -imm
	g.emit(0xD1000000 | (u32(val) << 10) | (29 << 5) | u32(rd))
}

fn (mut g Arm64Gen) emit_str_reg_offset(rt int, rn int, offset int) {
	g.emit(0xF8000000 | (u32(offset & 0x1FF) << 12) | (u32(rn) << 5) | u32(rt))
}

fn (mut g Arm64Gen) emit_ldr_reg_offset(rt int, rn int, offset int) {
	g.emit(0xF8400000 | (u32(offset & 0x1FF) << 12) | (u32(rn) << 5) | u32(rt))
}

fn (mut g Arm64Gen) emit(code u32) {
	write_u32_le(mut g.macho.text_data, code)
}

fn (mut g Arm64Gen) record_pending_label(blk int) {
	off := g.macho.text_data.len - g.curr_offset
	g.pending_labels[blk] << off
}

fn (g Arm64Gen) read_u32(off int) u32 {
	return binary.little_endian_u32(g.macho.text_data[off..off + 4])
}

fn (mut g Arm64Gen) write_u32(off int, v u32) {
	binary.little_endian_put_u32(mut g.macho.text_data[off..off + 4], v)
}

pub fn (mut g Arm64Gen) write_file(path string) {
	g.macho.write(path)
}
