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
		// Align to 8
		for g.elf.data_data.len % 8 != 0 {
			g.elf.data_data << 0
		}
		addr := u64(g.elf.data_data.len)
		// Section 2 is .data
		g.elf.add_symbol(gvar.name, addr, false, 2)
		// Allocate 8 bytes (i32/ptr)
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

	// Calculate Stack Frame
	// Params pushed by caller or in registers.
	// We spill register params to stack for simplicity in this MVP.
	// System V ABI: rdi, rsi, rdx, rcx, r8, r9
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

			g.stack_map[val_id] = -slot_offset
			slot_offset += 8

			if instr.op == .alloca {
				slot_offset = (slot_offset + 15) & ~0xF
				slot_offset += 64
				g.alloca_offsets[val_id] = -slot_offset
				slot_offset += 8
			}
		}
	}

	// Align stack to 16 bytes
	g.stack_size = (slot_offset + 16) & ~0xF

	// Register function symbol (Section 1 is .text)
	g.elf.add_symbol(func.name, u64(g.curr_offset), true, 1)

	// Prologue
	g.emit(0x55) // push rbp
	g.emit(0x48)
	g.emit(0x89)
	g.emit(0xE5) // mov rbp, rsp
	// sub rsp, stack_size
	g.emit(0x48)
	g.emit(0x81)
	g.emit(0xEC)
	g.emit_u32(u32(g.stack_size))

	// Spill Arguments to Stack
	// regs: rdi(0), rsi(1), rdx(2), rcx(3), r8(4), r9(5)
	// We use our helper map to regs.
	// rdi=7, rsi=6, rdx=2, rcx=1, r8=8, r9=9 (in internal helper mapping)
	// SysV Reg Order: RDI, RSI, RDX, RCX, R8, R9
	regs := [7, 6, 2, 1, 8, 9]

	for i, pid in func.params {
		if i < 6 {
			offset := g.stack_map[pid]
			g.emit_store_reg_mem(regs[i], offset)
		}
	}

	for blk_id in func.blocks {
		blk := g.mod.blocks[blk_id]
		g.block_offsets[blk_id] = g.elf.text_data.len - g.curr_offset

		// Patch pending jumps
		if offsets := g.pending_labels[blk_id] {
			for off in offsets {
				target := g.block_offsets[blk_id]
				// Jump is rel32. Offset 'off' points to the 4-byte immediate.
				// RIP is at off + 4.
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

	// Helper registers
	// RAX (0) - Accumulator / Result
	// RCX (1) - Secondary

	match instr.op {
		.add, .sub, .mul, .eq, .ne, .lt, .gt, .le, .ge {
			g.load_val_to_reg(0, instr.operands[0]) // RAX
			g.load_val_to_reg(1, instr.operands[1]) // RCX

			match instr.op {
				.add {
					// add rax, rcx -> 48 01 c8
					g.emit(0x48)
					g.emit(0x01)
					g.emit(0xC8)
				}
				.sub {
					// sub rax, rcx -> 48 29 c8
					g.emit(0x48)
					g.emit(0x29)
					g.emit(0xC8)
				}
				.mul {
					// imul rax, rcx -> 48 0f af c1
					g.emit(0x48)
					g.emit(0x0F)
					g.emit(0xAF)
					g.emit(0xC1)
				}
				.eq, .ne, .lt, .gt, .le, .ge {
					// cmp rax, rcx -> 48 39 c8
					g.emit(0x48)
					g.emit(0x39)
					g.emit(0xC8)

					// setcc al
					code := match instr.op {
						.eq { 0x94 } // sete
						.ne { 0x95 } // setne
						.lt { 0x9C } // setl
						.gt { 0x9F } // setg
						.le { 0x9E } // setle
						.ge { 0x9D } // setge
						else { 0x94 }
					}
					g.emit(0x0F)
					g.emit(u8(code))
					g.emit(0xC0) // setcc al

					// movzx rax, al -> 48 0f b6 c0
					g.emit(0x48)
					g.emit(0x0F)
					g.emit(0xB6)
					g.emit(0xC0)
				}
				else {}
			}
			g.store_reg_to_val(0, val_id)
		}
		.store {
			g.load_val_to_reg(0, instr.operands[0]) // Val -> RAX
			g.load_val_to_reg(1, instr.operands[1]) // Ptr -> RCX
			// mov [rcx], rax -> 48 89 01
			g.emit(0x48)
			g.emit(0x89)
			g.emit(0x01)
		}
		.load {
			g.load_val_to_reg(1, instr.operands[0]) // Ptr -> RCX
			// mov rax, [rcx] -> 48 8b 01
			g.emit(0x48)
			g.emit(0x8B)
			g.emit(0x01)
			g.store_reg_to_val(0, val_id)
		}
		.alloca {
			off := g.alloca_offsets[val_id]
			// lea rax, [rbp + off]
			// 48 8d 85 <disp32>
			g.emit(0x48)
			g.emit(0x8D)
			g.emit(0x85)
			g.emit_u32(u32(off))
			g.store_reg_to_val(0, val_id)
		}
		.get_element_ptr {
			g.load_val_to_reg(0, instr.operands[0]) // Base -> RAX
			g.load_val_to_reg(1, instr.operands[1]) // Index -> RCX

			// Currently assuming index is i32, and element size is 4 or 8.
			// For generic approach without type size info in backend easily:
			// MVP assumption: Indexing bytes or 4-byte integers.
			// Let's assume we are indexing bytes if Struct member, or array elements.
			// Simplification: add rax, rcx (Assuming byte offset pre-calculated or stride=1)
			// A real backend would multiply RCX by element size.

			// add rax, rcx
			g.emit(0x48)
			g.emit(0x01)
			g.emit(0xC8)
			g.store_reg_to_val(0, val_id)
		}
		.call {
			// Regs: rdi, rsi, rdx, rcx, r8, r9
			// Mapping: RDI=7, RSI=6, RDX=2, RCX=1, R8=8, R9=9
			arg_regs := [7, 6, 2, 1, 8, 9]
			for i in 1 .. instr.operands.len {
				if i - 1 < 6 {
					g.load_val_to_reg(arg_regs[i - 1], instr.operands[i])
				}
			}

			// Call
			fn_val := g.mod.values[instr.operands[0]]
			// 0xE8 <rel32>
			g.emit(0xE8)

			// Relocation
			sym_idx := g.elf.add_undefined(fn_val.name)
			// R_X86_64_PC32 (2) -> Offset is current pos (text len)
			// Addend: -4 (because relocation is applied at start of immediate, pointing to end)
			g.elf.add_text_reloc(u64(g.elf.text_data.len), sym_idx, 4, -4) // 4 = R_X86_64_PLT32 or 2 PC32

			g.emit_u32(0) // Placeholder

			if g.mod.type_store.types[g.mod.values[val_id].typ].kind != .void_t {
				g.store_reg_to_val(0, val_id)
			}
		}
		.ret {
			if instr.operands.len > 0 {
				g.load_val_to_reg(0, instr.operands[0])
			}
			// leave; ret
			g.emit(0xC9)
			g.emit(0xC3)
		}
		.jmp {
			target_blk := instr.operands[0]
			target_idx := g.mod.values[target_blk].index
			g.emit_jmp(target_idx)
		}
		.br {
			g.load_val_to_reg(0, instr.operands[0])
			// test rax, rax -> 48 85 c0
			g.emit(0x48)
			g.emit(0x85)
			g.emit(0xC0)

			true_blk := g.mod.values[instr.operands[1]].index
			false_blk := g.mod.values[instr.operands[2]].index

			// jne true (if rax != 0) -> 0F 85 <rel32>
			g.emit(0x0F)
			g.emit(0x85)
			g.record_pending_label(true_blk)
			g.emit_u32(0)

			// jmp false -> E9 <rel32>
			g.emit(0xE9)
			g.record_pending_label(false_blk)
			g.emit_u32(0)
		}
		else {}
	}
}

// Emits a JMP (E9) to the target block
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

// Loading values into registers
// Reg IDs mapped:
// 0=RAX, 1=RCX, 2=RDX, 3=RBX, 4=RSP, 5=RBP, 6=RSI, 7=RDI, 8=R8, 9=R9
fn (mut g X64Gen) load_val_to_reg(reg int, val_id int) {
	val := g.mod.values[val_id]
	if val.kind == .constant {
		if val.name.starts_with('"') {
			str_content := val.name.trim('"')

			// In ELF, we put string in .rodata
			str_offset := g.elf.rodata.len
			g.elf.rodata << str_content.bytes()
			g.elf.rodata << 0

			// Symbol for string
			sym_name := 'L_str_${g.curr_offset}_${str_offset}'
			// Add symbol pointing to rodata (section 3)
			sym_idx := g.elf.add_symbol(sym_name, u64(str_offset), false, 3)

			// LEA reg, [RIP + disp]
			// opcode 48 8d <reg>
			// reg encoding in ModRM:
			// Mod=00, Reg=reg, RM=101 (RIP rel) -> but 64-bit mode special case.
			// Actually: 48 8D (05 | (reg<<3)) <disp32>
			// hardware reg indices:
			// RAX=0, RCX=1, RDX=2, RBX=3, RSP=4, RBP=5, RSI=6, RDI=7
			hw_reg := g.map_reg(reg)
			mut rex := u8(0x48)
			if hw_reg >= 8 {
				rex |= 4
			}
			// REX.R

			g.emit(rex)
			g.emit(0x8D)
			g.emit(0x05 | ((hw_reg & 7) << 3))

			// Relocation: R_X86_64_PC32
			g.elf.add_text_reloc(u64(g.elf.text_data.len), sym_idx, 2, -4)
			g.emit_u32(0)
		} else {
			int_val := val.name.i64()
			// mov reg, imm64 -> 48 B8+reg <imm64>
			// optimization: mov reg, imm32 (sign extended) -> 48 C7 C0...
			// Simple: MOVABS (48 B8 + reg)
			hw_reg := g.map_reg(reg)
			mut rex := u8(0x48)
			if hw_reg >= 8 {
				rex |= 1
			}
			// REX.B
			g.emit(rex)
			g.emit(0xB8 | (hw_reg & 7))
			g.emit_u64(u64(int_val))
		}
	} else if val.kind == .global {
		// mov reg, [rip + offset]
		// 48 8b 05 <disp32>
		hw_reg := g.map_reg(reg)
		mut rex := u8(0x48)
		if hw_reg >= 8 {
			rex |= 4
		}
		g.emit(rex)
		g.emit(0x8B)
		g.emit(0x05 | ((hw_reg & 7) << 3))

		sym_idx := g.elf.add_undefined(val.name)
		g.elf.add_text_reloc(u64(g.elf.text_data.len), sym_idx, 2, -4) // PC32
		g.emit_u32(0)
	} else {
		// Stack load
		offset := g.stack_map[val_id]
		g.emit_load_reg_mem(reg, offset)
	}
}

fn (mut g X64Gen) store_reg_to_val(reg int, val_id int) {
	offset := g.stack_map[val_id]
	g.emit_store_reg_mem(reg, offset)
}

// Helpers for encoding
// mov reg, [rbp + disp]
fn (mut g X64Gen) emit_load_reg_mem(reg int, disp int) {
	hw_reg := g.map_reg(reg)
	// 48 8b 85 <disp32> (Load 64-bit)
	// ModRM: Mod=10(disp32), Reg=hw_reg, RM=101(rbp/disp32) -> 0x85
	mut rex := u8(0x48)
	if hw_reg >= 8 {
		rex |= 4
	}
	g.emit(rex)
	g.emit(0x8B)
	g.emit(0x85 | ((hw_reg & 7) << 3))
	g.emit_u32(u32(disp))
}

// mov [rbp + disp], reg
fn (mut g X64Gen) emit_store_reg_mem(reg int, disp int) {
	hw_reg := g.map_reg(reg)
	// 48 89 85 <disp32>
	mut rex := u8(0x48)
	if hw_reg >= 8 {
		rex |= 4
	}
	g.emit(rex)
	g.emit(0x89)
	g.emit(0x85 | ((hw_reg & 7) << 3))
	g.emit_u32(u32(disp))
}

// Map internal register IDs to Hardware indices
// 0=RAX(0), 1=RCX(1), 2=RDX(2), 3=RBX(3), 4=RSP(4), 5=RBP(5), 6=RSI(6), 7=RDI(7), 8=R8(8), 9=R9(9)
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
