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

	// Register allocation
	reg_map   map[int]int
	used_regs []int
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

	// Globals in __data (Section 3)
	for gvar in g.mod.globals {
		for g.macho.data_data.len % 8 != 0 {
			g.macho.data_data << 0
		}
		addr := u64(g.macho.data_data.len)
		g.macho.add_symbol('_' + gvar.name, addr, true, 3)
		for _ in 0 .. 8 {
			g.macho.data_data << 0
		}
	}

	// Patch symbol addresses
	cstring_base := u64(g.macho.text_data.len)
	data_base := cstring_base + u64(g.macho.str_data.len)

	for mut sym in g.macho.symbols {
		if sym.sect == 2 {
			sym.value += cstring_base
		} else if sym.sect == 3 {
			sym.value += data_base
		}
	}
}

fn (mut g Arm64Gen) gen_func(func ssa.Function) {
	g.curr_offset = g.macho.text_data.len
	g.stack_map = map[int]int{}
	g.alloca_offsets = map[int]int{}
	g.block_offsets = map[int]int{}
	g.pending_labels = map[int][]int{}
	g.reg_map = map[int]int{}
	g.used_regs = []int{}
	g.allocate_registers(func)

	// Stack Frame
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
				// Reserve 64 bytes for data.
				// Align to 16 bytes.
				slot_offset = (slot_offset + 15) & ~0xF
				slot_offset += 64
				g.alloca_offsets[val_id] = -slot_offset

				// CRITICAL FIX: Ensure the next instruction does not use the slot
				// overlapping with the base of the alloca data.
				// alloca_offsets points to the bottom of the block.
				// The next instruction would get -slot_offset (which is the bottom).
				// We advance slot_offset to skip the block completely.
				// Note: slot_offset is already at the bottom.
				// But we need to ensure the *next* usage doesn't pick this address.
				// Since stack_map assignment comes *before* this increment, the next instr
				// will use the current slot_offset.
				// If slot_offset is 96, next gets -96. Data is -96..-32.
				// So we need to bump it so next gets -104.
				slot_offset += 8
			}

			if val_id in g.reg_map {
				continue
			}
			// Assign slot for result of instruction (or pointer for alloca)
			g.stack_map[val_id] = -slot_offset
			slot_offset += 8
		}
	}

	g.stack_size = (slot_offset + 16) & ~0xF

	g.macho.add_symbol('_' + func.name, u64(g.curr_offset), true, 1)

	// Prologue
	g.emit(0xA9BF7BFD) // stp fp, lr, [sp, -16]!
	g.emit(0x910003FD) // mov fp, sp

	// Save callee-saved regs
	for i := 0; i < g.used_regs.len; i += 2 {
		r1 := g.used_regs[i]
		mut r2 := 31 // xzr // r1 // dummy
		if i + 1 < g.used_regs.len {
			r2 = g.used_regs[i + 1]
		}
		// code := 0xA9BF0000 | (u32(r2) << 10) | (u32(r1) << 5) | 0x1F
		code := 0xA9BF0000 | (u32(r2) << 10) | (31 << 5) | u32(r1)
		g.emit(code)
	}

	g.emit_sub_sp(g.stack_size)

	// Spill params
	for i, pid in func.params {
		if i < 8 {
			if reg := g.reg_map[pid] {
				g.emit_mov_reg(reg, i)
			} else {
				offset := g.stack_map[pid]
				g.emit_str_reg_offset(i, 29, offset)
			}
		}
	}

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
				.sdiv {
					g.emit(0x9AC90D08)
				}
				.eq, .ne, .lt, .gt, .le, .ge {
					g.emit(0xEB09011F)
					code := match instr.op {
						.eq { 0x9A9F17E8 }
						.ne { 0x9A9F07E8 }
						.lt { 0x9A9FA7E8 }
						.gt { 0x9A9FD7E8 }
						.le { 0x9A9FC7E8 }
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
			g.load_val_to_reg(8, instr.operands[0])
			g.load_val_to_reg(9, instr.operands[1])
			g.emit(0xF9000128)
		}
		.load {
			g.load_val_to_reg(9, instr.operands[0])
			g.emit(0xF9400128)
			g.store_reg_to_val(8, val_id)
		}
		.alloca {
			data_off := g.alloca_offsets[val_id]
			g.emit_add_fp_imm(8, data_off)
			g.store_reg_to_val(8, val_id)
		}
		.get_element_ptr {
			g.load_val_to_reg(8, instr.operands[0])
			g.load_val_to_reg(9, instr.operands[1])
			g.emit(0x8B090D08)
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
			// Reset SP to the bottom of the callee-saved registers area
			// SP = FP - callee_saved_size
			callee_size := ((g.used_regs.len + 1) / 2) * 16
			g.emit(0xD1000000 | (u32(callee_size) << 10) | (29 << 5) | 31)
			// Restore callee-saved regs
			mut j := g.used_regs.len
			if j % 2 != 0 {
				j += 1
			}
			for j > 0 {
				base := j - 2
				r1 := g.used_regs[base]
				// mut r2 := r1
				mut r2 := 31 // xzr // r1 // dummy
				if base + 1 < g.used_regs.len {
					r2 = g.used_regs[base + 1]
				}
				// ldp r1, r2, [sp], 16
				// code := 0xA8C10000 | (u32(r2) << 10) | (u32(r1) << 5) | 0x1F
				code := 0xA8C10000 | (u32(r2) << 10) | (31 << 5) | u32(r1)
				g.emit(code)
				j -= 2
			}
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
			g.emit(0xF100011F)

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
		.switch_ {
			g.load_val_to_reg(8, instr.operands[0]) // Cond -> x8

			// Iterate cases: pairs of (val, blk) starting at index 2
			for i := 2; i < instr.operands.len; i += 2 {
				// We need val in a register. x9.
				g.load_val_to_reg(9, instr.operands[i])
				g.emit(0xEB09011F) // cmp x8, x9

				// b.eq target
				target_blk_val := instr.operands[i + 1]
				target_blk_idx := g.mod.values[target_blk_val].index

				// Emit branch EQ (cond = 0)
				// B.cond: 01010100 [imm19] 0[cond4] -> 0x54...0
				if off := g.block_offsets[target_blk_idx] {
					rel := (off - (g.macho.text_data.len - g.curr_offset)) / 4
					g.emit(0x54000000 | ((u32(rel) & 0x7FFFF) << 5))
				} else {
					g.record_pending_label(target_blk_idx)
					g.emit(0x54000000)
				}
			}

			// Default (Unconditional Branch)
			def_blk_val := instr.operands[1]
			def_idx := g.mod.values[def_blk_val].index
			if off := g.block_offsets[def_idx] {
				rel := (off - (g.macho.text_data.len - g.curr_offset)) / 4
				g.emit(0x14000000 | (u32(rel) & 0x3FFFFFF))
			} else {
				g.record_pending_label(def_idx)
				g.emit(0x14000000)
			}
		}
		.bitcast {
			if instr.operands.len > 0 {
				g.load_val_to_reg(8, instr.operands[0])
				g.store_reg_to_val(8, val_id)
			}
		}
		.phi {
			// Phi nodes are handled by elim_phi_nodes inserting assignments in predecessors.
			// We just need to ensure the slot exists (handled in gen_func loop).
		}
		.assign {
			// assign dest_id, src_id
			// Used for Phi elimination: store src into dest's slot
			dest_id := instr.operands[0]
			src_id := instr.operands[1]

			g.load_val_to_reg(8, src_id)
			g.store_reg_to_val(8, dest_id)
		}
		else {
			eprintln('arm64: unknown instruction ${instr}')
			exit(1)
		}
	}
}

fn (mut g Arm64Gen) load_val_to_reg(reg int, val_id int) {
	val := g.mod.values[val_id]
	if val.kind == .constant {
		if val.name.starts_with('"') {
			// str_content := val.name.trim('"')

			raw_content := val.name.trim('"')
			// Handle escape sequences
			mut str_content := []u8{}
			mut i := 0
			for i < raw_content.len {
				if raw_content[i] == `\\` && i + 1 < raw_content.len {
					next_char := raw_content[i + 1]
					match next_char {
						`n` { str_content << 10 }
						`t` { str_content << 9 }
						`r` { str_content << 13 }
						`\\` { str_content << 92 }
						`"` { str_content << 34 }
						`'` { str_content << 39 }
						else { str_content << next_char }
					}
					i += 2
				} else {
					str_content << raw_content[i]
					i++
				}
			}

			str_offset := g.macho.str_data.len
			g.macho.str_data << str_content //.bytes()
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
		// Handles .instruction, .argument, etc.
		if reg_idx := g.reg_map[val_id] {
			if reg_idx != reg {
				g.emit_mov_reg(reg, reg_idx)
			}
		} else {
			offset := g.stack_map[val_id]
			g.emit_ldr_reg_offset(reg, 29, offset)
		}
	}
}

fn (mut g Arm64Gen) store_reg_to_val(reg int, val_id int) {
	if reg_idx := g.reg_map[val_id] {
		if reg_idx != reg {
			g.emit_mov_reg(reg_idx, reg)
		}
	} else {
		offset := g.stack_map[val_id]
		g.emit_str_reg_offset(reg, 29, offset)
	}
}

fn (mut g Arm64Gen) emit_sub_sp(imm int) {
	g.emit(0xD1000000 | (u32(imm) << 10) | (31 << 5) | 31)
}

fn (mut g Arm64Gen) emit_add_fp_imm(rd int, imm int) {
	val := -imm
	g.emit(0xD1000000 | (u32(val) << 10) | (29 << 5) | u32(rd))
}

fn (mut g Arm64Gen) emit_str_reg_offset(rt int, rn int, offset int) {
	if offset >= -255 && offset <= 255 {
		imm9 := u32(offset & 0x1FF)
		g.emit(0xF8000000 | (imm9 << 12) | (u32(rn) << 5) | u32(rt))
	} else {
		// Large negative offset; use temp x10 for address
		imm := u64(-offset) // Positive imm
		g.emit_mov_imm(10, imm)
		g.emit(0xCB0A03AA) // sub x10, x29, x10
		g.emit(0xF9000140 | u32(rt)) // str xrt, [x10]
	}
}

fn (mut g Arm64Gen) emit_ldr_reg_offset(rt int, rn int, offset int) {
	if offset >= -255 && offset <= 255 {
		imm9 := u32(offset & 0x1FF)
		g.emit(0xF8400000 | (imm9 << 12) | (u32(rn) << 5) | u32(rt))
	} else {
		// Large negative offset; use temp x10 for address
		imm := u64(-offset) // Positive imm
		g.emit_mov_imm(10, imm)
		g.emit(0xCB0A03AA) // sub x10, x29, x10
		g.emit(0xF9400140 | u32(rt)) // ldr xrt, [x10]
	}
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

fn (mut g Arm64Gen) emit_mov_imm(rd int, imm u64) {
	// Assume imm < 65536; use MOVZ xd, #imm
	g.emit(0xD2800000 | (u32(imm & 0xFFFF) << 5) | u32(rd))
	// For larger imm, add MOVK(s), but not needed for stack sizes.
}

fn (mut g Arm64Gen) emit_mov_reg(rd int, rm int) {
	// ORR xd, xzr, xm
	g.emit(0xAA0003E0 | (u32(rm) << 16) | u32(rd))
}

struct Interval {
mut:
	val_id int
	start  int
	end    int
}

fn (mut g Arm64Gen) allocate_registers(func ssa.Function) {
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
	// x19..x28
	regs := [19, 20, 21, 22, 23, 24, 25, 26, 27, 28]

	for i in sorted {
		for j := 0; j < active.len; j++ {
			if active[j].end < i.start {
				active.delete(j)
				j--
			}
		}

		if active.len < regs.len {
			mut used := []bool{len: 32, init: false}
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
