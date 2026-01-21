module backend

import ssa
import encoding.binary

pub struct X64Gen {
	mod &ssa.Module
mut:
	elf &ElfObject

	stack_map      map[int]int
	alloca_offsets map[int]int
	stack_size     int
	curr_offset    int

	block_offsets  map[int]int
	pending_labels map[int][]int

	// Register allocation
	reg_map   map[int]int
	used_regs []int
}

pub fn X64Gen.new(mod &ssa.Module) &X64Gen {
	return &X64Gen{
		mod: mod
		elf: ElfObject.new()
	}
}

pub fn (mut g X64Gen) gen() {
	for func in g.mod.funcs {
		g.gen_func(func)
	}

	// Generate Globals in .data
	for gvar in g.mod.globals {
		for g.elf.data_data.len % 8 != 0 {
			g.elf.data_data << 0
		}
		addr := u64(g.elf.data_data.len)
		g.elf.add_symbol(gvar.name, addr, false, 2)
		// Allocate 8 bytes
		for _ in 0 .. 8 {
			g.elf.data_data << 0
		}
	}
}

fn (mut g X64Gen) gen_func(func ssa.Function) {
	g.curr_offset = g.elf.text_data.len
	g.stack_map = map[int]int{}
	g.alloca_offsets = map[int]int{}
	g.block_offsets = map[int]int{}
	g.pending_labels = map[int][]int{}
	g.reg_map = map[int]int{}
	g.used_regs = []int{}

	g.allocate_registers(func)

	// Calculate Stack Frame
	mut slot_offset := 8

	for pid in func.params {
		g.stack_map[pid] = -slot_offset
		slot_offset += 8
	}

	for blk_id in func.blocks {
		blk := g.mod.blocks[blk_id]
		for val_id in blk.instrs {
			val := g.mod.values[val_id]
			if val.kind != .instruction {
				continue
			}
			instr := g.mod.instrs[val.index]

			if instr.op == .alloca {
				// Reserve 64 bytes for data, align to 16
				slot_offset = (slot_offset + 15) & ~0xF
				slot_offset += 64
				g.alloca_offsets[val_id] = -slot_offset
				slot_offset += 8 // Slot for the pointer
			}

			if val_id in g.reg_map {
				continue
			}
			g.stack_map[val_id] = -slot_offset
			slot_offset += 8
		}
	}

	g.stack_size = (slot_offset + 16) & ~0xF

	g.elf.add_symbol(func.name, u64(g.curr_offset), true, 1)

	// Prologue
	g.emit(0x55) // push rbp
	g.emit(0x48)
	g.emit(0x89)
	g.emit(0xE5) // mov rbp, rsp

	// Push callee-saved regs
	// RBX(3), R12(12), R13(13), R14(14), R15(15)
	for r in g.used_regs {
		g.emit_push_reg(r)
	}

	// sub rsp, stack_size
	if g.stack_size > 0 {
		g.emit(0x48)
		g.emit(0x81)
		g.emit(0xEC)
		g.emit_u32(u32(g.stack_size))
	}

	// Move Params (ABI: RDI, RSI, RDX, RCX, R8, R9)
	abi_regs := [7, 6, 2, 1, 8, 9]
	for i, pid in func.params {
		if i < 6 {
			src := abi_regs[i]
			if reg := g.reg_map[pid] {
				g.emit_mov_reg_reg(reg, src)
			} else {
				offset := g.stack_map[pid]
				g.emit_store_reg_mem(src, offset)
			}
		}
	}

	for blk_id in func.blocks {
		blk := g.mod.blocks[blk_id]
		g.block_offsets[blk_id] = g.elf.text_data.len - g.curr_offset

		if offsets := g.pending_labels[blk_id] {
			for off in offsets {
				target := g.block_offsets[blk_id]
				rel := target - (off + 4)
				abs_off := g.curr_offset + off
				g.write_u32(abs_off, u32(rel))
			}
		}

		for val_id in blk.instrs {
			g.gen_instr(val_id)
		}
	}
}

fn (mut g X64Gen) gen_instr(val_id int) {
	instr := g.mod.instrs[g.mod.values[val_id].index]

	// Temps: 0=RAX, 1=RCX

	match instr.op {
		.add, .sub, .mul, .eq, .ne, .lt, .gt, .le, .ge {
			g.load_val_to_reg(0, instr.operands[0]) // RAX
			g.load_val_to_reg(1, instr.operands[1]) // RCX

			match instr.op {
				.add {
					g.emit(0x48)
					g.emit(0x01)
					g.emit(0xC8) // add rax, rcx
				}
				.sub {
					g.emit(0x48)
					g.emit(0x29)
					g.emit(0xC8) // sub rax, rcx
				}
				.mul {
					g.emit(0x48)
					g.emit(0x0F)
					g.emit(0xAF)
					g.emit(0xC1) // imul rax, rcx
				}
				.eq, .ne, .lt, .gt, .le, .ge {
					g.emit(0x48)
					g.emit(0x39)
					g.emit(0xC8) // cmp rax, rcx
					code := match instr.op {
						.eq { 0x94 }
						.ne { 0x95 }
						.lt { 0x9C }
						.gt { 0x9F }
						.le { 0x9E }
						.ge { 0x9D }
						else { 0x94 }
					}
					g.emit(0x0F)
					g.emit(u8(code))
					g.emit(0xC0) // setcc al
					g.emit(0x48)
					g.emit(0x0F)
					g.emit(0xB6)
					g.emit(0xC0) // movzx rax, al
				}
				else {}
			}
			g.store_reg_to_val(0, val_id)
		}
		.store {
			g.load_val_to_reg(0, instr.operands[0]) // Val -> RAX
			g.load_val_to_reg(1, instr.operands[1]) // Ptr -> RCX
			// mov [rcx], rax
			g.emit(0x48)
			g.emit(0x89)
			g.emit(0x01)
		}
		.load {
			g.load_val_to_reg(1, instr.operands[0]) // Ptr -> RCX
			// mov rax, [rcx]
			g.emit(0x48)
			g.emit(0x8B)
			g.emit(0x01)
			g.store_reg_to_val(0, val_id)
		}
		.alloca {
			off := g.alloca_offsets[val_id]
			// lea rax, [rbp + off]
			g.emit(0x48)
			g.emit(0x8D)
			g.emit(0x85)
			g.emit_u32(u32(off))
			g.store_reg_to_val(0, val_id)
		}
		.get_element_ptr {
			g.load_val_to_reg(0, instr.operands[0]) // Base -> RAX
			g.load_val_to_reg(1, instr.operands[1]) // Index -> RCX
			// Mimic arm64 logic: add rax, (rcx << 3)
			// shl rcx, 3
			g.emit(0x48)
			g.emit(0xC1)
			g.emit(0xE1)
			g.emit(0x03)
			// add rax, rcx
			g.emit(0x48)
			g.emit(0x01)
			g.emit(0xC8)
			g.store_reg_to_val(0, val_id)
		}
		.call {
			abi_regs := [7, 6, 2, 1, 8, 9]
			for i in 1 .. instr.operands.len {
				if i - 1 < 6 {
					g.load_val_to_reg(abi_regs[i - 1], instr.operands[i])
				}
			}
			fn_val := g.mod.values[instr.operands[0]]
			g.emit(0xE8) // call rel32
			sym_idx := g.elf.add_undefined(fn_val.name)
			g.elf.add_text_reloc(u64(g.elf.text_data.len), sym_idx, 2, -4)
			g.emit_u32(0)
			if g.mod.type_store.types[g.mod.values[val_id].typ].kind != .void_t {
				g.store_reg_to_val(0, val_id)
			}
		}
		.ret {
			if instr.operands.len > 0 {
				g.load_val_to_reg(0, instr.operands[0])
			}
			// Cleanup Stack
			if g.stack_size > 0 {
				g.emit(0x48)
				g.emit(0x81)
				g.emit(0xC4)
				g.emit_u32(u32(g.stack_size))
			}
			// Pop callee-saved regs (reverse order)
			for i := g.used_regs.len - 1; i >= 0; i-- {
				g.emit_pop_reg(g.used_regs[i])
			}
			// pop rbp; ret
			g.emit(0x5D)
			g.emit(0xC3)
		}
		.jmp {
			target_idx := g.mod.values[instr.operands[0]].index
			g.emit_jmp(target_idx)
		}
		.br {
			g.load_val_to_reg(0, instr.operands[0])
			g.emit(0x48)
			g.emit(0x85)
			g.emit(0xC0) // test rax, rax
			true_blk := g.mod.values[instr.operands[1]].index
			false_blk := g.mod.values[instr.operands[2]].index

			g.emit(0x0F)
			g.emit(0x85) // jne
			g.record_pending_label(true_blk)
			g.emit_u32(0)

			g.emit(0xE9) // jmp
			g.record_pending_label(false_blk)
			g.emit_u32(0)
		}
		.switch_ {
			g.load_val_to_reg(0, instr.operands[0]) // RAX
			for i := 2; i < instr.operands.len; i += 2 {
				g.load_val_to_reg(1, instr.operands[i])
				g.emit(0x48)
				g.emit(0x39)
				g.emit(0xC8) // cmp rax, rcx
				g.emit(0x0F)
				g.emit(0x84) // je
				target_idx := g.mod.values[instr.operands[i + 1]].index
				if off := g.block_offsets[target_idx] {
					rel := off - (g.elf.text_data.len - g.curr_offset + 4)
					g.emit_u32(u32(rel))
				} else {
					g.record_pending_label(target_idx)
					g.emit_u32(0)
				}
			}
			def_idx := g.mod.values[instr.operands[1]].index
			g.emit_jmp(def_idx)
		}
		.assign {
			dest_id := instr.operands[0]
			src_id := instr.operands[1]
			g.load_val_to_reg(0, src_id)
			g.store_reg_to_val(0, dest_id)
		}
		.bitcast {
			if instr.operands.len > 0 {
				g.load_val_to_reg(0, instr.operands[0])
				g.store_reg_to_val(0, val_id)
			}
		}
		else {
			eprintln('x64: unknown op ${instr.op}')
		}
	}
}

fn (mut g X64Gen) emit_jmp(target_idx int) {
	g.emit(0xE9)
	if off := g.block_offsets[target_idx] {
		rel := off - (g.elf.text_data.len - g.curr_offset + 4)
		g.emit_u32(u32(rel))
	} else {
		g.record_pending_label(target_idx)
		g.emit_u32(0)
	}
}

fn (mut g X64Gen) load_val_to_reg(reg int, val_id int) {
	val := g.mod.values[val_id]
	if val.kind == .constant {
		if val.name.starts_with('"') {
			str_content := val.name.trim('"')
			// Handle escapes like arm64.v
			mut raw_bytes := []u8{}
			mut i := 0
			for i < str_content.len {
				if str_content[i] == `\\` && i + 1 < str_content.len {
					match str_content[i + 1] {
						`n` { raw_bytes << 10 }
						`t` { raw_bytes << 9 }
						`r` { raw_bytes << 13 }
						`\\` { raw_bytes << 92 }
						`"` { raw_bytes << 34 }
						`'` { raw_bytes << 39 }
						else { raw_bytes << str_content[i + 1] }
					}
					i += 2
				} else {
					raw_bytes << str_content[i]
					i++
				}
			}

			str_offset := g.elf.rodata.len
			g.elf.rodata << raw_bytes
			g.elf.rodata << 0
			sym_name := 'L_str_${g.curr_offset}_${str_offset}'
			sym_idx := g.elf.add_symbol(sym_name, u64(str_offset), false, 3)

			// lea reg, [rip + disp]
			hw_reg := g.map_reg(reg)
			mut rex := u8(0x48)
			if hw_reg >= 8 {
				rex |= 4
			}
			g.emit(rex)
			g.emit(0x8D)
			g.emit(0x05 | ((hw_reg & 7) << 3))
			g.elf.add_text_reloc(u64(g.elf.text_data.len), sym_idx, 2, -4)
			g.emit_u32(0)
		} else {
			int_val := val.name.i64()
			hw_reg := g.map_reg(reg)
			mut rex := u8(0x48)
			if hw_reg >= 8 {
				rex |= 1
			}
			g.emit(rex)
			g.emit(0xB8 | (hw_reg & 7))
			g.emit_u64(u64(int_val))
		}
	} else if val.kind == .global {
		hw_reg := g.map_reg(reg)
		mut rex := u8(0x48)
		if hw_reg >= 8 {
			rex |= 4
		}
		g.emit(rex)
		g.emit(0x8B)
		g.emit(0x05 | ((hw_reg & 7) << 3))
		sym_idx := g.elf.add_undefined(val.name)
		g.elf.add_text_reloc(u64(g.elf.text_data.len), sym_idx, 2, -4)
		g.emit_u32(0)
	} else {
		if reg_idx := g.reg_map[val_id] {
			if reg_idx != reg {
				g.emit_mov_reg_reg(reg, reg_idx)
			}
		} else {
			offset := g.stack_map[val_id]
			g.emit_load_reg_mem(reg, offset)
		}
	}
}

fn (mut g X64Gen) store_reg_to_val(reg int, val_id int) {
	if reg_idx := g.reg_map[val_id] {
		if reg_idx != reg {
			g.emit_mov_reg_reg(reg_idx, reg)
		}
	} else {
		offset := g.stack_map[val_id]
		g.emit_store_reg_mem(reg, offset)
	}
}

fn (mut g X64Gen) emit_push_reg(reg int) {
	hw_reg := g.map_reg(reg)
	if hw_reg >= 8 {
		g.emit(0x41)
		g.emit(0x50 | (hw_reg & 7))
	} else {
		g.emit(0x50 | hw_reg)
	}
}

fn (mut g X64Gen) emit_pop_reg(reg int) {
	hw_reg := g.map_reg(reg)
	if hw_reg >= 8 {
		g.emit(0x41)
		g.emit(0x58 | (hw_reg & 7))
	} else {
		g.emit(0x58 | hw_reg)
	}
}

fn (mut g X64Gen) emit_mov_reg_reg(dst int, src int) {
	dst_hw := g.map_reg(dst)
	src_hw := g.map_reg(src)
	mut rex := u8(0x48)
	if src_hw >= 8 {
		rex |= 4
	}
	if dst_hw >= 8 {
		rex |= 1
	}
	g.emit(rex)
	g.emit(0x89)
	g.emit(0xC0 | ((src_hw & 7) << 3) | (dst_hw & 7))
}

fn (mut g X64Gen) emit_load_reg_mem(reg int, disp int) {
	hw_reg := g.map_reg(reg)
	mut rex := u8(0x48)
	if hw_reg >= 8 {
		rex |= 4
	}
	g.emit(rex)
	g.emit(0x8B)
	g.emit(0x85 | ((hw_reg & 7) << 3))
	g.emit_u32(u32(disp))
}

fn (mut g X64Gen) emit_store_reg_mem(reg int, disp int) {
	hw_reg := g.map_reg(reg)
	mut rex := u8(0x48)
	if hw_reg >= 8 {
		rex |= 4
	}
	g.emit(rex)
	g.emit(0x89)
	g.emit(0x85 | ((hw_reg & 7) << 3))
	g.emit_u32(u32(disp))
}

fn (g X64Gen) map_reg(r int) u8 {
	return u8(r)
}

fn (mut g X64Gen) emit(b u8) {
	g.elf.text_data << b
}

fn (mut g X64Gen) emit_u32(v u32) {
	g.emit(u8(v))
	g.emit(u8(v >> 8))
	g.emit(u8(v >> 16))
	g.emit(u8(v >> 24))
}

fn (mut g X64Gen) emit_u64(v u64) {
	g.emit_u32(u32(v))
	g.emit_u32(u32(v >> 32))
}

fn (mut g X64Gen) record_pending_label(blk int) {
	off := g.elf.text_data.len - g.curr_offset
	g.pending_labels[blk] << off
}

fn (mut g X64Gen) write_u32(off int, v u32) {
	binary.little_endian_put_u32(mut g.elf.text_data[off..off + 4], v)
}

pub fn (mut g X64Gen) write_file(path string) {
	g.elf.write(path)
}

// Register Allocation Logic

fn (mut g X64Gen) allocate_registers(func ssa.Function) {
	mut intervals := map[int]&Interval{}
	mut instr_idx := 0

	for pid in func.params {
		intervals[pid] = &Interval{
			val_id: pid
			start:  0
			end:    0
		}
	}

	for blk_id in func.blocks {
		blk := g.mod.blocks[blk_id]
		for val_id in blk.instrs {
			val := g.mod.values[val_id]
			if val.kind == .instruction || val.kind == .argument {
				if unsafe { intervals[val_id] == nil } {
					intervals[val_id] = &Interval{
						val_id: val_id
						start:  instr_idx
						end:    instr_idx
					}
				}
			}
			instr := g.mod.instrs[val.index]
			for op in instr.operands {
				if g.mod.values[op].kind in [.instruction, .argument] {
					if mut interval := intervals[op] {
						if instr_idx > interval.end {
							interval.end = instr_idx
						}
					}
				}
			}
			instr_idx++
		}
	}

	mut sorted := []&Interval{}
	for _, i in intervals {
		sorted << i
	}
	sorted.sort(a.start < b.start)

	mut active := []&Interval{}
	// Use callee-saved registers: RBX(3), R12(12), R13(13), R14(14), R15(15)
	regs := [3, 12, 13, 14, 15]

	for i in sorted {
		for j := 0; j < active.len; j++ {
			if active[j].end < i.start {
				active.delete(j)
				j--
			}
		}
		if active.len < regs.len {
			mut used := []bool{len: 16, init: false}
			for a in active {
				used[g.reg_map[a.val_id]] = true
			}
			for r in regs {
				if !used[r] {
					g.reg_map[i.val_id] = r
					active << i
					if r !in g.used_regs {
						g.used_regs << r
					}
					break
				}
			}
		}
	}
	g.used_regs.sort()
}
