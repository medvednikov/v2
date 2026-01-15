module backend

import ssa
import encoding.binary

// ARM64 Gen
pub struct Arm64Gen {
	mod &ssa.Module
mut:
	macho &MachOObject
	
	// Current Function State
	stack_map   map[int]int // ValueID -> offset from FP
	stack_size  int
	curr_offset int // text section offset for current func start
	
	block_offsets map[int]int // BlockID -> Offset in text
	pending_labels map[int][]int // BlockID -> List of fixup offsets
}

pub fn Arm64Gen.new(mod &ssa.Module) &Arm64Gen {
	return &Arm64Gen{
		mod:   mod
		macho: MachOObject.new()
	}
}

pub fn (mut g Arm64Gen) gen() {
	// Register Globals
	// In this simple object file generator, globals are in __data usually,
	// but to simplify, we might put them in __text or handle via GOT.
	// For "int" globals, we'll just define symbols at the end of text or assume external.
	// Actually, `test.v` defines `g_val`. We should allocate space for it.
	// We will append a "data" area at the end of the text section for simplicity in this demo.
	
	// Generate Functions
	for func in g.mod.funcs {
		g.gen_func(func)
	}
	
	// Generate Globals storage (simple .long)
	// Align to 8 bytes
	for g.macho.text_data.len % 8 != 0 { g.emit(0xd503201f) } // NOP
	
	for gvar in g.mod.globals {
		addr := u64(g.macho.text_data.len)
		g.macho.add_symbol('_' + gvar.name, addr, true, 1) // 1 = __text section
		g.emit(0) // Init to 0
		g.emit(0) // 64-bit slot
	}
}

fn (mut g Arm64Gen) gen_func(func ssa.Function) {
	g.curr_offset = g.macho.text_data.len
	g.stack_map = map[int]int{}
	g.block_offsets = map[int]int{}
	g.pending_labels = map[int][]int{}
	
	// 1. Calculate Stack Frame
	// Naive: Every value gets 8 bytes.
	// Plus args x0-x7 spill.
	mut val_count := 0
	for blk_id in func.blocks {
		val_count += g.mod.blocks[blk_id].instrs.len
	}
	// Add params
	val_count += func.params.len
	
	// Align stack to 16 bytes
	g.stack_size = (val_count * 8 + 16) & ~0xF
	
	// Add symbol
	g.macho.add_symbol('_' + func.name, u64(g.curr_offset), true, 1)
	
	// 2. Prologue
	// stp fp, lr, [sp, #-16]!  => 0xA9BF7BFD
	g.emit(0xA9BF7BFD)
	// mov fp, sp               => 0x910003FD
	g.emit(0x910003FD)
	// sub sp, sp, #imm
	g.emit_sub_sp(g.stack_size)
	
	// 3. Spill Params to Stack
	// Current slot tracker
	mut slot_offset := 8 // Start at fp + 8? No, fp-8 is first local.
	// Stack grows down. FP points to saved FP. 
	// Locals are at [FP - 8, FP - 16, ...]
	slot_offset = 8
	
	for i, pid in func.params {
		// Map param ID to stack slot
		offset := -slot_offset
		g.stack_map[pid] = offset
		slot_offset += 8
		
		// Store Reg to Stack
		if i < 8 {
			g.emit_str_reg_offset(i, 29, offset) // str xI, [fp, #offset]
		} else {
			// Stack args not supported in this MVP
		}
	}
	
	// Map all instruction results to stack slots
	for blk_id in func.blocks {
		blk := g.mod.blocks[blk_id]
		for val_id in blk.instrs {
			val := g.mod.values[val_id]
			if val.kind != .instruction { continue }
			
			// Void instr doesn't need slot?
			// But for simplicity, alloc for all.
			offset := -slot_offset
			g.stack_map[val_id] = offset
			slot_offset += 8
		}
	}
	
	// 4. Body
	for blk_id in func.blocks {
		blk := g.mod.blocks[blk_id]
		// Record Block Label
		g.block_offsets[blk_id] = g.macho.text_data.len - g.curr_offset
		
		// Resolve pending jumps to this block
		if offsets := g.pending_labels[blk_id] {
			for off in offsets {
				// Rel offset = target - source
				target := g.block_offsets[blk_id]
				source := off
				// Instruction is at g.curr_offset + source
				// B / B.cond offset is encoded as imm / 4
				rel := (target - source) / 4
				
				// Patch the instruction
				abs_off := g.curr_offset + off
				instr := g.read_u32(abs_off)
				
				// Mask is different for B (0x14000000) vs B.cond (0x54000000)
				// B: top 6 bits 000101. Imm26.
				// B.cond: top 8 bits 01010100. Imm19.
				
				mut new_instr := u32(0)
				if (instr & 0xFC000000) == 0x14000000 {
					// B
					new_instr = (instr & 0xFC000000) | (u32(rel) & 0x3FFFFFF)
				} else {
					// B.cond
					new_instr = (instr & 0xFF000000) | ((u32(rel) & 0x7FFFF) << 5) | (instr & 0x1F)
				}
				g.write_u32(abs_off, new_instr)
			}
		}
		
		for val_id in blk.instrs {
			g.gen_instr(val_id)
		}
	}
	
	// Implicit return if fallthrough? (Shouldn't happen with valid SSA)
}

fn (mut g Arm64Gen) gen_instr(val_id int) {
	instr := g.mod.instrs[g.mod.values[val_id].index]
	
	match instr.op {
		.add, .sub, .mul, .sdiv, .eq, .ne, .lt, .gt, .le, .ge {
			// Binary Ops
			// Load Op0 -> x8
			g.load_val_to_reg(8, instr.operands[0])
			// Load Op1 -> x9
			g.load_val_to_reg(9, instr.operands[1])
			
			match instr.op {
				.add { g.emit(0x8B090108) } // add x8, x8, x9
				.sub { g.emit(0xCB090108) } // sub x8, x8, x9
				.mul { g.emit(0x9B097D08) } // mul x8, x8, x9
				.eq, .ne, .lt, .gt, .le, .ge {
					g.emit(0xEB09011F) // cmp x8, x9
					// CSET x8, cond
					cond := match instr.op {
						.eq { 1 } // EQ
						.ne { 0 } // NE (inverted EQ?) - CSET logic: EQ=1.
						// Cond codes: EQ=0000, NE=0001, CS=0010 ... 
						// cset xd, cond => cond is bit 12-15? No, cset is alias for CSINC
						// cset x8, eq => csinc x8, xzr, xzr, ne
						else { 0 }
					}
					// Simplifying: Just use CSET aliases
					// EQ: 0x9A9F17E8 (cset x8, eq)
					// NE: 0x9A9F07E8 (cset x8, ne)
					// LT: 0x9A9FA7E8 (cset x8, lt) (signed)
					// LE: 0x9A9FD7E8 (cset x8, le)
					// GT: 0x9A9FC7E8 (cset x8, gt)
					// GE: 0x9A9FB7E8 (cset x8, ge)
					
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
			
			// Store Result x8 -> Stack
			g.store_reg_to_val(8, val_id)
		}
		.store {
			// store val, ptr
			// val -> x8
			g.load_val_to_reg(8, instr.operands[0])
			// ptr -> x9 (address)
			g.load_val_to_reg(9, instr.operands[1])
			// str x8, [x9]
			g.emit(0xF9000128)
		}
		.load {
			// load res, ptr
			// ptr -> x9
			g.load_val_to_reg(9, instr.operands[0])
			// ldr x8, [x9]
			g.emit(0xF9400128)
			// store x8 -> res
			g.store_reg_to_val(8, val_id)
		}
		.alloca {
			// res = stack_slot_addr
			// We effectively use the slot assigned to 'val_id' as the storage
			// But 'alloca' returns a pointer TO storage.
			// So we need another slot to hold that pointer?
			// In this stack machine:
			// 'val_id' is the pointer value.
			// We allocate SPACE on the stack for the variable.
			// Let's say we reserve extra space at end of frame?
			// Simply: use the address of the slot itself? No, alloca creates new space.
			
			// HACK: Use the slot assigned to val_id to store the ADDRESS of... itself?
			// Real impl: bump stack pointer dynamically or reserve specific area.
			// MVP: The slot for val_id holds the POINTER.
			// Where does it point? To a dedicated area.
			// Let's just point to [fp, offset_of_val_id] for now, essentially making the variable reside in the pointer slot.
			// This works for scalars (int). For structs, we need real space.
			
			// Better: Reserve extra 64 bytes for every alloca (safe for Point struct)
			// and store that address in val_id.
			
			// Expand stack frame dynamically? No, fixed size calculated at start.
			// Re-calc stack size?
			// Let's just grab the stack offset for this val_id, and say the memory IS there.
			// So res = fp + offset.
			offset := g.stack_map[val_id]
			// add x8, fp, #offset
			g.emit_add_fp_imm(8, offset)
			g.store_reg_to_val(8, val_id)
		}
		.get_element_ptr {
			// base -> x8
			g.load_val_to_reg(8, instr.operands[0])
			// index -> x9
			g.load_val_to_reg(9, instr.operands[1])
			
			// assuming index is integer, and we are accessing fields/array of 64-bit/32-bit words
			// element size? 
			// We need type info. For MVP struct Point {x,y}, fields are 4/8 bytes.
			// Assuming all fields 8 bytes or aligned.
			// Struct field index is constant usually.
			// GEP base, index. result = base + index * stride
			// x8 = x8 + x9 * 8 (lsl 3)
			
			// add x8, x8, x9, lsl #3 => 0x8B090D08
			// (actually this instruction is valid: add xd, xn, xm, shift)
			g.emit(0x8B090D08)
			
			g.store_reg_to_val(8, val_id)
		}
		.call {
			// Ops: [FuncVal, Arg1, Arg2...]
			// 1. Setup Args x0..xN
			for i in 1 .. instr.operands.len {
				if i-1 < 8 {
					g.load_val_to_reg(i-1, instr.operands[i])
				}
			}
			
			// 2. Call
			fn_val := g.mod.values[instr.operands[0]]
			// Is it external or internal?
			if fn_val.kind == .unknown {
				// External (like printf)
				// Emit Reloc
				sym_idx := g.macho.add_undefined('_' + fn_val.name)
				g.macho.add_reloc(g.macho.text_data.len, sym_idx, backend.arm64_reloc_branch26, true)
				g.emit(0x94000000) // bl 0
			} else {
				// Internal? If we can find the name.
				// For now, treat all as symbols and reloc (let linker resolve internal too)
				sym_idx := g.macho.add_undefined('_' + fn_val.name)
				g.macho.add_reloc(g.macho.text_data.len, sym_idx, backend.arm64_reloc_branch26, true)
				g.emit(0x94000000)
			}
			
			// 3. Store Result x0
			if g.mod.type_store.types[g.mod.values[val_id].typ].kind != .void_t {
				g.store_reg_to_val(0, val_id)
			}
		}
		.ret {
			// ret val?
			if instr.operands.len > 0 {
				g.load_val_to_reg(0, instr.operands[0])
			}
			// Epilogue
			// mov sp, fp
			g.emit(0x910003BF)
			// ldp fp, lr, [sp], #16
			g.emit(0xA8C17BFD)
			// ret
			g.emit(0xD65F03C0)
		}
		.jmp {
			target_blk := instr.operands[0] // Is value ID of block
			target_idx := g.mod.values[target_blk].index
			
			if off := g.block_offsets[target_idx] {
				// Backward jump
				rel := (off - (g.macho.text_data.len - g.curr_offset)) / 4
				// b rel
				g.emit(0x14000000 | (u32(rel) & 0x3FFFFFF))
			} else {
				// Forward jump
				g.record_pending_label(target_idx)
				g.emit(0x14000000) // Placeholder
			}
		}
		.br {
			// br cond, true_blk, false_blk
			// cond is in op0. Expecting it to be 1 or 0 in a reg.
			g.load_val_to_reg(8, instr.operands[0])
			// cmp x8, #0
			g.emit(0xF100011F)
			// b.ne true_blk
			
			true_blk := g.mod.values[instr.operands[1]].index
			false_blk := g.mod.values[instr.operands[2]].index
			
			// True Branch (NE)
			if off := g.block_offsets[true_blk] {
				rel := (off - (g.macho.text_data.len - g.curr_offset)) / 4
				// b.ne rel (cond=0001) => 0x54000001
				g.emit(0x54000001 | ((u32(rel) & 0x7FFFF) << 5))
			} else {
				g.record_pending_label(true_blk)
				g.emit(0x54000001)
			}
			
			// False Branch (Unconditional)
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

// Helpers
fn (mut g Arm64Gen) load_val_to_reg(reg int, val_id int) {
	val := g.mod.values[val_id]
	if val.kind == .constant {
		// mov xReg, #imm
		// Demo: handle integer constants
		// Assuming val.name holds the number string
		if val.name.starts_with('"') {
			// String Literal
			// Put in __cstring, get address
			str_content := val.name.trim('"')
			
			// Add to str_data
			str_offset := g.macho.str_data.len
			g.macho.str_data << str_content.bytes()
			g.macho.str_data << 0 // null term
			
			// We need to load address of (cstring_start + str_offset)
			// In object file, we use relocs for sections.
			// adrp xReg, offset@PAGE
			// add xReg, xReg, offset@PAGEOFF
			// But here we can use a local symbol for the section start?
			// Simplest: Define a symbol "L_str_N"
			sym_name := 'L_str_${str_offset}'
			// Add symbol for it? No, just use Section 2 offset.
			// Reloc type: PAGE21 / PAGEOFF12 against symbol index.
			// We can define a symbol for the start of cstring section.
			
			// Hack: Create undefined symbol for the label, or use section-based reloc.
			// Let's use `__cstring` section index? Relocs refer to symbol table.
			// Create a non-external symbol for the string.
			sym_idx := g.macho.add_symbol(sym_name, u64(str_offset), false, 2)
			
			// ADRP
			g.macho.add_reloc(g.macho.text_data.len, sym_idx, backend.arm64_reloc_page21, true)
			g.emit(0x90000000 | u32(reg))
			
			// ADD
			g.macho.add_reloc(g.macho.text_data.len, sym_idx, backend.arm64_reloc_pageoff12, false)
			// add reg, reg, #0 (imm encoded later by linker)
			// 0x91000000 | Rd | Rn
			g.emit(0x91000000 | u32(reg) | (u32(reg) << 5))
			
		} else {
			// Integer
			int_val := val.name.int()
			// movz xReg, #imm
			// 0xD2800000 | (imm << 5) | reg
			g.emit(0xD2800000 | (u32(int_val) << 5) | u32(reg))
		}
	} else if val.kind == .global {
		// Load Global Address
		// adrp xReg, _name
		// add xReg, xReg, :lo12:_name
		sym_idx := g.macho.add_undefined('_' + val.name)
		
		g.macho.add_reloc(g.macho.text_data.len, sym_idx, backend.arm64_reloc_got_load_page21, true)
		g.emit(0x90000000 | u32(reg))
		
		g.macho.add_reloc(g.macho.text_data.len, sym_idx, backend.arm64_reloc_got_load_pageoff12, false)
		// ldr xReg, [xReg, #0] (Load GOT entry)
		g.emit(0xF9400000 | u32(reg) | (u32(reg) << 5))
		
		// This gives us the address of the global.
		// If we want the value, we load again?
		// In C logic: 'g_val' is the value. The SSA value for global is a pointer.
		// So we just want the address in the register.
	} else {
		// Stack Load
		offset := g.stack_map[val_id]
		// ldr xReg, [fp, #offset]
		g.emit_ldr_reg_offset(reg, 29, offset)
	}
}

fn (mut g Arm64Gen) store_reg_to_val(reg int, val_id int) {
	offset := g.stack_map[val_id]
	g.emit_str_reg_offset(reg, 29, offset)
}

fn (mut g Arm64Gen) emit_sub_sp(imm int) {
	// sub sp, sp, #imm (uimm12)
	// 0xD10003FF
	g.emit(0xD1000000 | (u32(imm) << 10) | (31 << 5) | 31)
}

fn (mut g Arm64Gen) emit_add_fp_imm(rd int, imm int) {
	// add rd, fp, #imm
	// sub rd, fp, #-imm
	// 0xD1000000 (sub)
	val := -imm
	g.emit(0xD1000000 | (u32(val) << 10) | (29 << 5) | u32(rd))
}

fn (mut g Arm64Gen) emit_str_reg_offset(rt int, rn int, offset int) {
	// stur rt, [rn, #imm9] (signed)
	// 0xF8000000 | (imm9 << 12) | (rn << 5) | rt
	g.emit(0xF8000000 | (u32(offset & 0x1FF) << 12) | (u32(rn) << 5) | u32(rt))
}

fn (mut g Arm64Gen) emit_ldr_reg_offset(rt int, rn int, offset int) {
	// ldur rt, [rn, #imm9]
	// 0xF8400000
	g.emit(0xF8400000 | (u32(offset & 0x1FF) << 12) | (u32(rn) << 5) | u32(rt))
}

fn (mut g Arm64Gen) emit(code u32) {
	g.macho.text_data.write_u32_le(int(code))
}

fn (mut g Arm64Gen) record_pending_label(blk int) {
	// Current instruction index (offset in text)
	off := g.macho.text_data.len - g.curr_offset
	g.pending_labels[blk] << off
}

fn (g Arm64Gen) read_u32(off int) u32 {
	return binary.little_endian_u32(g.macho.text_data[off..off+4])
}

fn (mut g Arm64Gen) write_u32(off int, v u32) {
	binary.little_endian_put_u32(mut g.macho.text_data[off..off+4], v)
}

// Write file
pub fn (mut g Arm64Gen) write_file(path string) {
	g.macho.write(path)
}
