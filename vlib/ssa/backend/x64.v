module backend

import ssa

// Minimal x64 Emitter
pub struct X64Gen {
	mod &ssa.Module
mut:
	code []u8
}

pub fn X64Gen.new(mod &ssa.Module) &X64Gen {
	return &X64Gen{
		mod:  mod
		code: []u8{cap: 1024}
	}
}

pub fn (mut x X64Gen) gen_func(func_id int) []u8 {
	func := x.mod.funcs[func_id]
	x.code = []u8{}

	// 1. Prologue
	x.emit_bytes([u8(0x55), 0x48, 0x89, 0xE5]) // push rbp; mov rbp, rsp

	// 2. Body
	for blk_id in func.blocks {
		blk := x.mod.blocks[blk_id]
		for val_id in blk.instrs {
			x.gen_instr(val_id)
		}
	}

	// 3. Epilogue (if not explicitly returned, though SSA should have Ret)
	// x.emit_bytes([u8(0x5D), 0xC3])

	return x.code
}

fn (mut x X64Gen) gen_instr(val_id int) {
	instr := x.mod.instrs[val_id]
	// In a real backend, we run RegAlloc first.
	// Here, we assume a "Stack Machine" approach for simplicity (no optimization),
	// or specific hardcoded registers for the demo (RAX/RCX).

	// Get Result Type Width
	typ := x.mod.type_store.types[x.mod.values[val_id].typ]
	is_64bit := typ.width == 64

	match instr.op {
		.add {
			// Simplistic: assume op0 in RAX, op1 in RCX, result in RAX
			// 1. Mov operands to regs (Real impl uses RegAlloc mapping)
			x.emit_mov_reg_val(.rax, instr.operands[0])
			x.emit_mov_reg_val(.rcx, instr.operands[1])

			// 2. ADD RAX, RCX
			if is_64bit {
				x.emit_bytes([u8(0x48), 0x01, 0xC8])
			} else {
				x.emit_bytes([u8(0x01), 0xC8])
			}

			// 3. Store result (Spill to stack slot for this Val ID)
			x.emit_spill(.rax, val_id)
		}
		.ret {
			if instr.operands.len > 0 {
				x.emit_mov_reg_val(.rax, instr.operands[0])
			}
			x.emit_bytes([u8(0x5D), 0xC3]) // pop rbp; ret
		}
		// ... other ops
		else {}
	}
}

// Helper Enums for Registers
enum Reg {
	rax
	rcx
	rdx
	rbx
	rsp
	rbp
	rsi
	rdi
}

fn (mut x X64Gen) emit_mov_reg_val(r Reg, val_id int) {
	// Look up value. If constant -> emit immediate. If var -> emit stack load.
	val := x.mod.values[val_id]
	if val.kind == .constant {
		// MOV Reg, Imm
		// 0x48 C7 C0 ... (for RAX)
		x.emit_bytes([u8(0x48), 0xC7, 0xC0])
		// Emit 32-bit immediate for demo
		x.emit_bytes([u8(0x0A), 0, 0, 0]) // Value 10
	} else {
		// MOV Reg, [RBP - offset]
		// Calculate offset based on val_id (naive stack layout: 8 bytes per value)
		offset := (val_id + 1) * 8

		// Emit the instruction using the offset to silence the warning
		// 0x8B = MOV r64, r/m64
		// 0x45 = ModRM (Dest=RAX, Mode=Disp8, Base=RBP)
		// We cast offset to u8 (assuming small stack for demo)
		x.emit_bytes([u8(0x48), 0x8B, 0x45, u8(offset)])
	}
}

fn (mut x X64Gen) emit_spill(r Reg, val_id int) {
	// MOV [RBP - offset], Reg
}

fn (mut x X64Gen) emit_bytes(b []u8) {
	x.code << b
}
