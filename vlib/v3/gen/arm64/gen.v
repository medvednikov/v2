module arm64

import v3.ssa

pub struct Gen {
mut:
	m                    &ssa.Module  = unsafe { nil }
	macho                &MachOObject = unsafe { nil }
	stack_map            map[int]int
	alloca_offset        map[int]int
	alloca_size          map[int]int
	stack_size           int
	block_offsets        []int
	pending_jmps         []PendingJmp
	fn_offsets           map[string]int
	string_cache         map[string]int
	cur_func_ret_type    ssa.TypeID
	cur_func_sret_offset int
}

struct PendingJmp {
	text_pos int
	block_id int
}

pub fn Gen.new(m &ssa.Module) &Gen {
	return &Gen{
		m:             m
		macho:         MachOObject.new()
		stack_map:     map[int]int{}
		alloca_offset: map[int]int{}
		alloca_size:   map[int]int{}
		block_offsets: []int{}
		pending_jmps:  []PendingJmp{}
		fn_offsets:    map[string]int{}
		string_cache:  map[string]int{}
	}
}

pub fn (mut g Gen) gen() {
	g.gen_pre_pass()
	for fi in 0 .. g.m.funcs.len {
		g.gen_func(fi)
	}
	g.gen_post_pass()
}

pub fn (mut g Gen) write_and_link(output string) {
	mut l := Linker.new(g.macho)
	l.link(output, '_main')
}

fn (mut g Gen) gen_pre_pass() {
	mut data_offset := u64(0)
	for gi in 0 .. g.m.globals.len {
		data_offset = (data_offset + 7) & ~u64(7)
		g.macho.add_symbol('_' + g.m.globals[gi].name, data_offset, true, 3)
		size := g.m.type_size(g.m.globals[gi].typ)
		data_offset += u64(if size > 0 { size } else { 8 })
	}
}

fn (mut g Gen) gen_post_pass() {
	for gi in 0 .. g.m.globals.len {
		for g.macho.data_data.len % 8 != 0 {
			g.macho.data_data << 0
		}
		size := g.m.type_size(g.m.globals[gi].typ)
		actual := if size > 0 { size } else { 8 }
		for _ in 0 .. actual {
			g.macho.data_data << 0
		}
	}

	cstring_base := u64(g.macho.text_data.len)
	data_base := (cstring_base + u64(g.macho.str_data.len) + 7) & ~u64(7)
	for i in 0 .. g.macho.symbols.len {
		if g.macho.symbols[i].sect == 2 {
			g.macho.symbols[i].value += cstring_base
		} else if g.macho.symbols[i].sect == 3 {
			g.macho.symbols[i].value += data_base
		}
	}
}

fn (mut g Gen) gen_func(func_idx int) {
	func := g.m.funcs[func_idx]
	if func.is_c_extern {
		return
	}
	if func.blocks.len == 0 {
		fn_start := g.macho.text_data.len
		sym_name := '_' + func.name
		g.macho.add_symbol(sym_name, u64(fn_start), false, 1)
		g.emit32(asm_ret())
		g.fn_offsets[func.name] = fn_start
		return
	}

	g.stack_map.clear()
	g.alloca_offset.clear()
	g.pending_jmps.clear()

	n_blks := g.m.blocks.len
	g.block_offsets = []int{len: n_blks, init: -1}

	// Frame layout (all at negative offsets from fp):
	// fp + 0: saved fp
	// fp + 8: saved lr
	// fp - 8: first local slot
	// fp - 16: second local slot ...
	mut slot_offset := 0
	g.cur_func_ret_type = func.typ
	g.cur_func_sret_offset = 0
	if g.is_large_struct_type(func.typ) {
		slot_offset += 8
		g.cur_func_sret_offset = -slot_offset
	}

	for _, pid in func.params {
		param_val := g.m.values[pid]
		param_size := g.m.type_size(param_val.typ)
		alloc_size := if param_size > 8 { (param_size + 7) & ~7 } else { 8 }
		slot_offset += alloc_size
		g.stack_map[pid] = -slot_offset
	}

	for blk_id in func.blocks {
		blk := g.m.blocks[blk_id]
		for val_id in blk.instrs {
			val := g.m.values[val_id]
			if val.kind != .instruction {
				continue
			}
			instr := g.m.instrs[val.index]
			if instr.op == .alloca {
				ptr_type := g.m.type_store.types[val.typ]
				elem_size := g.m.type_size(ptr_type.elem_type)
				mut count := 1
				if instr.operands.len > 0 {
					count_val := g.m.values[instr.operands[0]]
					if count_val.kind == .constant {
						n := parse_arm64_int(count_val.name)
						if n > 1 {
							count = int(n)
						} else {
							count = 1
						}
					} else {
						count = 1
					}
				}
				alloc_size := if elem_size > 0 { (elem_size * count + 7) & ~7 } else { 8 }
				slot_offset = (slot_offset + 15) & ~0xF
				slot_offset += alloc_size
				g.alloca_offset[val_id] = -slot_offset
				g.alloca_size[val_id] = alloc_size
				slot_offset += 8
			} else if instr.op != .store && instr.op != .ret && instr.op != .br && instr.op != .jmp
				&& instr.op != .unreachable {
				result_size := g.m.type_size(val.typ)
				alloc_size := if result_size > 8 && val.typ > 0
					&& val.typ < g.m.type_store.types.len
					&& g.m.type_store.types[val.typ].kind == .struct_t {
					(result_size + 7) & ~7
				} else {
					8
				}
				slot_offset += alloc_size
				g.stack_map[val_id] = -slot_offset
			}
		}
	}

	// Allocate stack slots for string literals used by this function
	for val in g.m.values {
		if val.kind == .string_literal && val.id !in g.stack_map {
			slot_offset += 16
			g.stack_map[val.id] = -slot_offset
		}
	}

	g.stack_size = (slot_offset + 15) & ~0xF

	fn_start := g.macho.text_data.len
	sym_name := '_' + func.name
	g.macho.add_symbol(sym_name, u64(fn_start), false, 1)
	g.fn_offsets[func.name] = fn_start

	// Prologue: stp fp, lr, [sp, -16]! ; mov fp, sp ; sub sp, sp, #frame
	g.emit32(asm_stp_fp_lr_pre())
	g.emit32(asm_mov_fp_sp())
	if g.stack_size > 0 {
		g.emit_sub_sp(g.stack_size)
	}
	if g.cur_func_sret_offset != 0 {
		g.emit_store_fp(8, g.cur_func_sret_offset)
	}

	if func.name == 'main' {
		g.store_entry_arg_to_global(0, 'g_main_argc')
		g.store_entry_arg_to_global(1, 'g_main_argv')
	}

	// Spill params from registers to stack
	mut reg_idx := 0
	mut stack_arg_off := 16
	for _, pid in func.params {
		param_val := g.m.values[pid]
		param_size := g.m.type_size(param_val.typ)
		n_words := if param_size > 8 { (param_size + 7) / 8 } else { 1 }
		off := g.stack_map[pid]
		if reg_idx + n_words <= 8 {
			for wi in 0 .. n_words {
				g.emit_store_fp(reg_idx, off + wi * 8)
				reg_idx++
			}
		} else {
			for wi in 0 .. n_words {
				g.emit_load_fp(8, stack_arg_off + wi * 8)
				g.emit_store_fp(8, off + wi * 8)
			}
			stack_arg_off += n_words * 8
		}
	}

	// Generate blocks
	for blk_id in func.blocks {
		g.block_offsets[blk_id] = g.macho.text_data.len
		g.resolve_pending_jmps(blk_id)
		blk := g.m.blocks[blk_id]
		for val_id in blk.instrs {
			g.gen_instr(val_id)
		}
	}

	g.resolve_all_pending()
}

fn (g &Gen) is_large_struct_type(typ_id ssa.TypeID) bool {
	if typ_id <= 0 || typ_id >= g.m.type_store.types.len {
		return false
	}
	typ := g.m.type_store.types[typ_id]
	return typ.kind == .struct_t && g.m.type_size(typ_id) > 16
}

fn (g &Gen) is_aggregate_type(typ_id ssa.TypeID) bool {
	if typ_id <= 0 || typ_id >= g.m.type_store.types.len {
		return false
	}
	typ := g.m.type_store.types[typ_id]
	return typ.kind == .struct_t && g.m.type_size(typ_id) > 8
}

fn (g &Gen) is_zero_const(val_id int) bool {
	if val_id <= 0 || val_id >= g.m.values.len {
		return false
	}
	val := g.m.values[val_id]
	return val.kind == .constant && parse_arm64_int(val.name) == 0
}

fn (mut g Gen) emit_zero_aggregate(ptr_reg int, typ_id ssa.TypeID, max_size int) {
	mut size := g.m.type_size(typ_id)
	if max_size > 0 && max_size < size {
		size = max_size
	}
	n_words := (size + 7) / 8
	for wi in 0 .. n_words {
		g.emit32(asm_str_imm(xzr, Reg(ptr_reg), u32(wi)))
	}
}

fn (g &Gen) aggregate_store_size(ptr_id int, typ_id ssa.TypeID) int {
	mut size := g.m.type_size(typ_id)
	if slot_size := g.stack_slot_size(ptr_id) {
		if slot_size > 0 && slot_size < size {
			size = slot_size
		}
		return size
	}
	if remaining := g.stack_alloca_remaining(ptr_id) {
		if remaining > 0 && remaining < size {
			size = remaining
		}
	}
	return size
}

fn (g &Gen) aggregate_load_size(ptr_id int, typ_id ssa.TypeID) int {
	return g.aggregate_store_size(ptr_id, typ_id)
}

fn (g &Gen) stack_slot_size(ptr_id int) ?int {
	mut cur := ptr_id
	mut slot_size := 0
	for _ in 0 .. 8 {
		if cur <= 0 || cur >= g.m.values.len {
			return none
		}
		val := g.m.values[cur]
		if val.kind != .instruction {
			return none
		}
		instr := g.m.instrs[val.index]
		match instr.op {
			.alloca {
				if slot_size > 0 {
					return slot_size
				}
				return g.alloca_size[cur]
			}
			.get_element_ptr {
				if instr.operands.len < 2 {
					return none
				}
				if slot_size == 0 {
					base_id := int(instr.operands[0])
					base_type := g.ptr_elem_type(base_id)
					if base_type > 0 && base_type < g.m.type_store.types.len {
						base := g.m.type_store.types[base_type]
						if base.kind == .struct_t {
							off_id := instr.operands[1]
							if off_id > 0 && off_id < g.m.values.len {
								off_val := g.m.values[off_id]
								if off_val.kind == .constant {
									field_off := int(parse_arm64_int(off_val.name))
									for fi in 0 .. base.fields.len {
										if g.m.struct_field_offset(base_type, fi) == field_off {
											field_size := g.m.struct_field_size(base_type, fi)
											if field_size > 0 {
												slot_size = field_size
											}
											break
										}
									}
								}
							}
						}
					}
				}
				cur = int(instr.operands[0])
			}
			.bitcast {
				if instr.operands.len == 0 {
					return none
				}
				cur = int(instr.operands[0])
			}
			else {
				return none
			}
		}
	}
	return none
}

fn (g &Gen) stack_alloca_remaining(ptr_id int) ?int {
	mut cur := ptr_id
	mut total_offset := 0
	for _ in 0 .. 8 {
		if cur <= 0 || cur >= g.m.values.len {
			return none
		}
		val := g.m.values[cur]
		if val.kind != .instruction {
			return none
		}
		instr := g.m.instrs[val.index]
		match instr.op {
			.alloca {
				size := g.alloca_size[cur] or { return none }
				remaining := size - total_offset
				if remaining > 0 {
					return remaining
				}
				return none
			}
			.get_element_ptr {
				if instr.operands.len < 2 {
					return none
				}
				off_id := instr.operands[1]
				if off_id > 0 && off_id < g.m.values.len {
					off_val := g.m.values[off_id]
					if off_val.kind == .constant {
						total_offset += int(parse_arm64_int(off_val.name))
					}
				}
				cur = int(instr.operands[0])
			}
			.bitcast {
				if instr.operands.len == 0 {
					return none
				}
				cur = int(instr.operands[0])
			}
			else {
				return none
			}
		}
	}
	return none
}

fn (mut g Gen) gen_instr(val_id int) {
	if val_id <= 0 || val_id >= g.m.values.len {
		return
	}
	val := g.m.values[val_id]
	if val.kind != .instruction {
		return
	}
	instr := g.m.instrs[val.index]

	match instr.op {
		.alloca {
			off := g.alloca_offset[val_id]
			g.emit_lea_fp(8, off)
			g.store_val(8, val_id)
		}
		.store {
			if instr.operands.len < 2 {
				return
			}
			src_id := instr.operands[0]
			ptr_id := instr.operands[1]

			src_val := g.m.values[src_id]
			if src_val.kind == .string_literal {
				g.materialize_string(src_id, 8)
				ptr_reg := g.load_val(ptr_id, 9)
				g.emit32(asm_str(Reg(8), Reg(ptr_reg)))
				g.emit32(asm_str_imm(Reg(10), Reg(ptr_reg), 1))
			} else {
				src_size := g.m.type_size(src_val.typ)
				if src_size > 8 && src_val.typ > 0 && src_val.typ < g.m.type_store.types.len
					&& g.m.type_store.types[src_val.typ].kind == .struct_t {
					if src_off := g.stack_map[src_id] {
						ptr_reg := g.load_val(ptr_id, 9)
						copy_size := g.aggregate_store_size(ptr_id, src_val.typ)
						n_words := (copy_size + 7) / 8
						for wi in 0 .. n_words {
							g.emit_load_fp(8, src_off + wi * 8)
							g.emit32(asm_str_imm(Reg(8), Reg(ptr_reg), u32(wi)))
						}
					} else {
						src_reg := g.load_val(src_id, 8)
						ptr_reg := g.load_val(ptr_id, 9)
						g.emit32(asm_str(Reg(src_reg), Reg(ptr_reg)))
					}
				} else {
					ptr_reg := g.load_val(ptr_id, 9)
					dest_type := g.ptr_elem_type(ptr_id)
					if g.is_zero_const(src_id) && g.is_aggregate_type(dest_type) {
						g.emit_zero_aggregate(ptr_reg, dest_type, g.aggregate_store_size(ptr_id,
							dest_type))
						return
					}
					src_reg := g.load_val(src_id, 8)
					store_typ := if int(dest_type) > 0 { dest_type } else { src_val.typ }
					g.emit_store_typed(src_reg, ptr_reg, store_typ)
				}
			}
		}
		.load {
			if instr.operands.len < 1 {
				return
			}
			ptr_id := instr.operands[0]
			ptr_val := g.m.values[ptr_id]

			if ptr_val.kind == .global {
				g.emit_global_addr(8, ptr_val.name)
				g.emit32(asm_ldr(Reg(8), Reg(8)))
				g.store_val(8, val_id)
			} else if ptr_val.kind == .string_literal {
				g.materialize_string(ptr_id, 8)
				g.store_val(8, val_id)
				if off := g.stack_map[val_id] {
					g.emit_store_fp(10, off + 8)
				}
			} else {
				ptr_reg := g.load_val(ptr_id, 9)
				result_size := g.m.type_size(val.typ)
				if result_size > 8 && val.typ > 0 && val.typ < g.m.type_store.types.len {
					typ := g.m.type_store.types[val.typ]
					if typ.kind == .struct_t {
						if off := g.stack_map[val_id] {
							if g.is_string_struct_type(val.typ) {
								copy_size := g.aggregate_load_size(ptr_id, val.typ)
								if copy_size > 0 {
									g.emit32(asm_ldr(Reg(8), Reg(ptr_reg)))
									g.emit_store_fp(8, off)
								} else {
									g.emit_mov_imm(8, 0)
									g.emit_store_fp(8, off)
								}
								if copy_size > 8 {
									g.emit32(asm_ldr_imm(Reg(10), Reg(ptr_reg), 1))
									g.emit_store_fp(10, off + 8)
								} else {
									g.emit_mov_imm(10, 0)
									g.emit_store_fp(10, off + 8)
								}
							} else {
								copy_size := g.aggregate_load_size(ptr_id, val.typ)
								copy_words := (copy_size + 7) / 8
								total_words := (result_size + 7) / 8
								for wi in 0 .. copy_words {
									g.emit32(asm_ldr_imm(Reg(8), Reg(ptr_reg), u32(wi)))
									g.emit_store_fp(8, off + wi * 8)
								}
								if copy_words < total_words {
									g.emit_mov_imm(8, 0)
									for wi in copy_words .. total_words {
										g.emit_store_fp(8, off + wi * 8)
									}
								}
							}
						}
						return
					}
				}
				g.emit_load_typed(8, ptr_reg, val.typ)
				g.store_val(8, val_id)
			}
		}
		.get_element_ptr {
			if instr.operands.len < 2 {
				return
			}
			base_reg := g.load_val(instr.operands[0], 8)
			off_reg := g.load_val(instr.operands[1], 9)
			g.emit32(asm_add_reg(Reg(8), Reg(base_reg), Reg(off_reg)))
			g.store_val(8, val_id)
		}
		.add, .sub, .mul, .sdiv, .srem, .udiv, .urem, .and_, .or_, .xor, .shl, .ashr, .lshr {
			lhs_reg := g.load_val(instr.operands[0], 8)
			rhs_reg := g.load_val(instr.operands[1], 9)
			match instr.op {
				.add {
					g.emit32(asm_add_reg(Reg(8), Reg(lhs_reg), Reg(rhs_reg)))
				}
				.sub {
					g.emit32(asm_sub_reg(Reg(8), Reg(lhs_reg), Reg(rhs_reg)))
				}
				.mul {
					g.emit32(asm_mul(Reg(8), Reg(lhs_reg), Reg(rhs_reg)))
				}
				.sdiv {
					g.emit32(asm_sdiv(Reg(8), Reg(lhs_reg), Reg(rhs_reg)))
				}
				.srem {
					g.emit32(asm_sdiv(Reg(10), Reg(lhs_reg), Reg(rhs_reg)))
					g.emit32(asm_msub(Reg(8), Reg(10), Reg(rhs_reg), Reg(lhs_reg)))
				}
				.udiv {
					g.emit32(asm_udiv(Reg(8), Reg(lhs_reg), Reg(rhs_reg)))
				}
				.urem {
					g.emit32(asm_udiv(Reg(10), Reg(lhs_reg), Reg(rhs_reg)))
					g.emit32(asm_msub(Reg(8), Reg(10), Reg(rhs_reg), Reg(lhs_reg)))
				}
				.and_ {
					g.emit32(asm_and(Reg(8), Reg(lhs_reg), Reg(rhs_reg)))
				}
				.or_ {
					g.emit32(asm_orr(Reg(8), Reg(lhs_reg), Reg(rhs_reg)))
				}
				.xor {
					g.emit32(asm_eor(Reg(8), Reg(lhs_reg), Reg(rhs_reg)))
				}
				.shl {
					g.emit32(asm_lslv(Reg(8), Reg(lhs_reg), Reg(rhs_reg)))
				}
				.ashr {
					g.emit32(asm_asrv(Reg(8), Reg(lhs_reg), Reg(rhs_reg)))
				}
				.lshr {
					g.emit32(asm_lsrv(Reg(8), Reg(lhs_reg), Reg(rhs_reg)))
				}
				else {}
			}

			g.store_val(8, val_id)
		}
		.eq, .ne, .lt, .gt, .le, .ge, .ult, .ugt, .ule, .uge {
			lhs_reg := g.load_val(instr.operands[0], 8)
			rhs_reg := g.load_val(instr.operands[1], 9)
			g.emit32(asm_cmp_reg(Reg(lhs_reg), Reg(rhs_reg)))
			match instr.op {
				.eq { g.emit32(asm_cset_eq(Reg(8))) }
				.ne { g.emit32(asm_cset_ne(Reg(8))) }
				.lt { g.emit32(asm_cset_lt(Reg(8))) }
				.gt { g.emit32(asm_cset_gt(Reg(8))) }
				.le { g.emit32(asm_cset_le(Reg(8))) }
				.ge { g.emit32(asm_cset_ge(Reg(8))) }
				.ult { g.emit32(asm_cset_lo(Reg(8))) }
				.ugt { g.emit32(asm_cset_hi(Reg(8))) }
				.ule { g.emit32(asm_cset_ls(Reg(8))) }
				.uge { g.emit32(asm_cset_hs(Reg(8))) }
				else {}
			}

			g.store_val(8, val_id)
		}
		.neg {
			src_reg := g.load_val(instr.operands[0], 8)
			g.emit32(asm_sub_reg(Reg(8), xzr, Reg(src_reg)))
			g.store_val(8, val_id)
		}
		.zext {
			if instr.operands.len > 0 {
				src_id := instr.operands[0]
				src_reg := g.load_val(src_id, 8)
				src_typ := g.m.values[src_id].typ
				src_width := if src_typ > 0 && src_typ < g.m.type_store.types.len {
					g.m.type_store.types[src_typ].width
				} else {
					64
				}
				if src_width > 0 && src_width < 64 {
					g.emit32(asm_ubfx_lower(Reg(8), Reg(src_reg), u32(src_width)))
				} else if src_reg != 8 {
					g.emit32(asm_mov_reg(Reg(8), Reg(src_reg)))
				}
				g.store_val(8, val_id)
			}
		}
		.sext {
			if instr.operands.len > 0 {
				src_id := instr.operands[0]
				src_reg := g.load_val(src_id, 8)
				src_typ := g.m.values[src_id].typ
				src_width := if src_typ > 0 && src_typ < g.m.type_store.types.len {
					g.m.type_store.types[src_typ].width
				} else {
					64
				}
				match src_width {
					8 {
						g.emit32(asm_sxtb(Reg(8), Reg(src_reg)))
					}
					16 {
						g.emit32(asm_sxth(Reg(8), Reg(src_reg)))
					}
					32 {
						g.emit32(asm_sxtw(Reg(8), Reg(src_reg)))
					}
					else {
						if src_reg != 8 {
							g.emit32(asm_mov_reg(Reg(8), Reg(src_reg)))
						}
					}
				}

				g.store_val(8, val_id)
			}
		}
		.trunc {
			if instr.operands.len > 0 {
				src_reg := g.load_val(instr.operands[0], 8)
				dst_width := if val.typ > 0 && val.typ < g.m.type_store.types.len {
					g.m.type_store.types[val.typ].width
				} else {
					64
				}
				if dst_width > 0 && dst_width < 64 {
					g.emit32(asm_ubfx_lower(Reg(8), Reg(src_reg), u32(dst_width)))
				} else if src_reg != 8 {
					g.emit32(asm_mov_reg(Reg(8), Reg(src_reg)))
				}
				g.store_val(8, val_id)
			}
		}
		.bitcast {
			if instr.operands.len > 0 {
				src_reg := g.load_val(instr.operands[0], 8)
				if src_reg != 8 {
					g.emit32(asm_mov_reg(Reg(8), Reg(src_reg)))
				}
				g.store_val(8, val_id)
			}
		}
		.call {
			g.gen_call(val_id, instr)
		}
		.call_indirect {
			g.gen_call(val_id, instr)
		}
		.ret {
			if g.cur_func_sret_offset != 0 {
				ret_size := g.m.type_size(g.cur_func_ret_type)
				n_words := (ret_size + 7) / 8
				g.emit_load_fp(9, g.cur_func_sret_offset)
				if instr.operands.len > 0 && instr.operands[0] > 0 {
					ret_id := instr.operands[0]
					if off := g.stack_map[ret_id] {
						for wi in 0 .. n_words {
							g.emit_load_fp(8, off + wi * 8)
							g.emit32(asm_str_imm(Reg(8), Reg(9), u32(wi)))
						}
					} else {
						g.emit_mov_imm(8, 0)
						for wi in 0 .. n_words {
							g.emit32(asm_str_imm(Reg(8), Reg(9), u32(wi)))
						}
					}
				} else {
					g.emit_mov_imm(8, 0)
					for wi in 0 .. n_words {
						g.emit32(asm_str_imm(Reg(8), Reg(9), u32(wi)))
					}
				}
				if g.stack_size > 0 {
					g.emit_add_sp(g.stack_size)
				}
				g.emit32(asm_ldp_fp_lr_post())
				g.emit32(asm_ret())
				return
			}
			if instr.operands.len > 0 && instr.operands[0] > 0 {
				ret_id := instr.operands[0]
				ret_val := g.m.values[ret_id]
				if ret_val.kind == .string_literal {
					g.materialize_string(ret_id, 0)
					g.emit32(asm_mov_reg(Reg(1), Reg(10)))
				} else {
					ret_size := g.m.type_size(ret_val.typ)
					if ret_size > 8 && ret_val.typ > 0 && ret_val.typ < g.m.type_store.types.len
						&& g.m.type_store.types[ret_val.typ].kind == .struct_t {
						if off := g.stack_map[ret_id] {
							if g.is_string_struct_type(ret_val.typ) {
								g.emit_load_string_regs_from_fp(off, 0, 1, ret_val.typ)
							} else {
								n_words := (ret_size + 7) / 8
								for wi in 0 .. n_words {
									if wi < 8 {
										g.emit_load_fp(wi, off + wi * 8)
									}
								}
							}
						}
					} else {
						src_reg := g.load_val(ret_id, 0)
						if src_reg != 0 {
							g.emit32(asm_mov_reg(Reg(0), Reg(src_reg)))
						}
					}
				}
			} else {
				g.emit_mov_imm(0, 0)
			}
			// Epilogue
			if g.stack_size > 0 {
				g.emit_add_sp(g.stack_size)
			}
			g.emit32(asm_ldp_fp_lr_post())
			g.emit32(asm_ret())
		}
		.br {
			if instr.operands.len < 3 {
				return
			}
			cond_reg := g.load_val(instr.operands[0], 8)
			then_blk := int(instr.operands[1])
			else_blk := int(instr.operands[2])

			g.emit32(asm_cbnz(Reg(cond_reg), 2))
			g.emit_branch_to_block(else_blk)
			g.emit_branch_to_block(then_blk)
		}
		.jmp {
			if instr.operands.len < 1 {
				return
			}
			target_blk := int(instr.operands[0])
			g.emit_phi_edge_copies(instr.block, target_blk)
			g.emit_branch_to_block(target_blk)
		}
		.unreachable {
			g.emit32(asm_udf())
		}
		.phi {}
		.struct_init {}
		else {}
	}
}

fn (mut g Gen) gen_call(val_id int, instr ssa.Instruction) {
	if instr.operands.len < 1 {
		return
	}
	fn_ref_id := instr.operands[0]
	is_indirect := instr.op == .call_indirect
	fn_ref := g.m.values[fn_ref_id]
	mut fn_name := ''
	if !is_indirect {
		fn_name = fn_ref.name
	}
	ret_indirect := g.is_large_struct_type(instr.typ)

	out_stack_size := g.call_stack_arg_size(instr)
	if out_stack_size > 0 {
		g.emit_sub_sp(out_stack_size)
	}

	mut arg_reg := 0
	mut stack_off := 0
	for ai in 1 .. instr.operands.len {
		arg_id := instr.operands[ai]
		arg_val := g.m.values[arg_id]

		if arg_val.kind == .string_literal {
			if arg_reg + 2 <= 8 {
				g.materialize_string(arg_id, arg_reg)
				g.emit32(asm_mov_reg(Reg(arg_reg + 1), Reg(10)))
				arg_reg += 2
			} else {
				g.materialize_string(arg_id, 8)
				g.emit_store_sp(8, stack_off)
				g.emit_store_sp(10, stack_off + 8)
				stack_off += 16
			}
		} else {
			arg_type_id := arg_val.typ
			arg_size := g.m.type_size(arg_type_id)
			if arg_size > 8 && arg_type_id > 0 && arg_type_id < g.m.type_store.types.len {
				typ := g.m.type_store.types[arg_type_id]
				if typ.kind == .struct_t {
					if g.is_string_struct_type(arg_type_id) {
						if arg_reg + 2 <= 8 {
							if off := g.stack_map[arg_id] {
								g.emit_load_string_regs_from_fp(off, arg_reg, arg_reg + 1,
									arg_type_id)
							} else {
								src_reg := g.load_val(arg_id, arg_reg)
								if src_reg != arg_reg {
									g.emit32(asm_mov_reg(Reg(arg_reg), Reg(src_reg)))
								}
								g.emit_mov_imm(arg_reg + 1, 0)
							}
							arg_reg += 2
						} else {
							if off := g.stack_map[arg_id] {
								g.emit_load_string_regs_from_fp(off, 8, 10, arg_type_id)
								g.emit_store_sp(8, stack_off)
								g.emit_store_sp(10, stack_off + 8)
							} else {
								src_reg := g.load_val(arg_id, 8)
								g.emit_store_sp(src_reg, stack_off)
								g.emit_mov_imm(10, 0)
								g.emit_store_sp(10, stack_off + 8)
							}
							stack_off += 16
						}
						continue
					}
					n_words := (arg_size + 7) / 8
					if arg_reg + n_words <= 8 {
						if off := g.stack_map[arg_id] {
							for wi in 0 .. n_words {
								g.emit_load_fp(arg_reg + wi, off + wi * 8)
							}
						} else {
							src_reg := g.load_val(arg_id, arg_reg)
							if src_reg != arg_reg {
								g.emit32(asm_mov_reg(Reg(arg_reg), Reg(src_reg)))
							}
						}
						arg_reg += n_words
					} else {
						if off := g.stack_map[arg_id] {
							for wi in 0 .. n_words {
								g.emit_load_fp(8, off + wi * 8)
								g.emit_store_sp(8, stack_off + wi * 8)
							}
						} else {
							src_reg := g.load_val(arg_id, 8)
							g.emit_store_sp(src_reg, stack_off)
						}
						stack_off += n_words * 8
					}
					continue
				}
			}

			if arg_val.kind == .instruction {
				arg_instr := g.m.instrs[arg_val.index]
				if arg_instr.op == .alloca {
					if alloca_off := g.alloca_offset[arg_id] {
						if arg_reg < 8 {
							g.emit_lea_fp(arg_reg, alloca_off)
							arg_reg += 1
						} else {
							g.emit_lea_fp(8, alloca_off)
							g.emit_store_sp(8, stack_off)
							stack_off += 8
						}
						continue
					}
				}
			}

			if arg_reg < 8 {
				src_reg := g.load_val(arg_id, arg_reg)
				if src_reg != arg_reg {
					g.emit32(asm_mov_reg(Reg(arg_reg), Reg(src_reg)))
				}
				arg_reg += 1
			} else {
				src_reg := g.load_val(arg_id, 8)
				g.emit_store_sp(src_reg, stack_off)
				stack_off += 8
			}
		}
	}

	if ret_indirect {
		if off := g.stack_map[val_id] {
			g.emit_lea_fp(8, off)
		}
	}

	is_c_extern := fn_ref.kind == .func_ref && fn_ref.index >= 0 && fn_ref.index < g.m.funcs.len
		&& g.m.funcs[fn_ref.index].is_c_extern
	if is_indirect {
		target_reg := g.load_val(fn_ref_id, 16)
		g.emit32(asm_blr(Reg(target_reg)))
	} else if !is_c_extern && fn_name in g.fn_offsets {
		target := g.fn_offsets[fn_name]
		offset := (target - g.macho.text_data.len) / 4
		g.emit32(asm_bl(i32(offset)))
	} else {
		sym_idx := g.macho.add_undefined('_' + fn_name)
		g.macho.add_reloc(g.macho.text_data.len, sym_idx, arm64_reloc_branch26, true)
		g.emit32(asm_bl(0))
	}

	if out_stack_size > 0 {
		g.emit_add_sp(out_stack_size)
	}

	if ret_indirect {
		return
	}

	if instr.typ != 0 {
		ret_size := g.m.type_size(instr.typ)
		if ret_size > 8 && instr.typ > 0 && instr.typ < g.m.type_store.types.len {
			typ := g.m.type_store.types[instr.typ]
			if typ.kind == .struct_t {
				if off := g.stack_map[val_id] {
					if g.is_string_struct_type(instr.typ) {
						g.emit_store_fp(0, off)
						g.emit_store_fp(1, off + 8)
						return
					}
					n_words := (ret_size + 7) / 8
					for wi in 0 .. n_words {
						if wi < 8 {
							g.emit_store_fp(wi, off + wi * 8)
						}
					}
				}
				return
			}
		}
		g.store_val(0, val_id)
	}
}

fn (g &Gen) call_stack_arg_size(instr ssa.Instruction) int {
	mut arg_reg := 0
	mut stack_words := 0
	for ai in 1 .. instr.operands.len {
		arg_id := instr.operands[ai]
		if arg_id <= 0 || arg_id >= g.m.values.len {
			continue
		}
		arg_val := g.m.values[arg_id]
		mut n_words := 1
		if arg_val.kind == .string_literal {
			n_words = 2
		} else {
			arg_size := g.m.type_size(arg_val.typ)
			if arg_size > 8 && arg_val.typ > 0 && arg_val.typ < g.m.type_store.types.len
				&& g.m.type_store.types[arg_val.typ].kind == .struct_t {
				n_words = (arg_size + 7) / 8
			}
		}
		if arg_reg + n_words <= 8 {
			arg_reg += n_words
		} else {
			stack_words += n_words
		}
	}
	if stack_words == 0 {
		return 0
	}
	return (stack_words * 8 + 15) & ~0xF
}

// ==================== Value loading/storing ====================

fn (mut g Gen) load_val(val_id int, reg int) int {
	if val_id <= 0 || val_id >= g.m.values.len {
		g.emit_mov_imm(reg, 0)
		return reg
	}
	val := g.m.values[val_id]
	match val.kind {
		.constant {
			n := parse_arm64_int(val.name)
			g.emit_mov_imm(reg, n)
			return reg
		}
		.string_literal {
			g.materialize_string(val_id, reg)
			return reg
		}
		.global {
			g.emit_global_addr(reg, val.name)
			return reg
		}
		.func_ref {
			g.emit_global_addr(reg, val.name)
			return reg
		}
		.instruction {
			instr := g.m.instrs[val.index]
			if instr.op == .alloca {
				if off := g.alloca_offset[val_id] {
					g.emit_lea_fp(reg, off)
					return reg
				}
			}
			if off := g.stack_map[val_id] {
				g.emit_load_fp(reg, off)
				return reg
			}
			g.emit_mov_imm(reg, 0)
			return reg
		}
		.argument {
			if off := g.stack_map[val_id] {
				g.emit_load_fp(reg, off)
				return reg
			}
			g.emit_mov_imm(reg, 0)
			return reg
		}
		else {
			g.emit_mov_imm(reg, 0)
			return reg
		}
	}
}

fn (mut g Gen) store_val(reg int, val_id int) {
	if off := g.stack_map[val_id] {
		g.emit_store_fp(reg, off)
	}
}

// ==================== String materialization ====================

fn (mut g Gen) materialize_string(val_id int, reg int) {
	val := g.m.values[val_id]
	str_content := val.name
	str_len := str_content.len

	mut str_offset := 0
	if cached := g.string_cache[str_content] {
		str_offset = cached
	} else {
		str_offset = g.macho.str_data.len
		g.string_cache[str_content] = str_offset
		g.macho.str_data << str_content.bytes()
		g.macho.str_data << 0
	}

	str_sym_name := 'L_str_${str_offset}'
	str_sym_idx := g.macho.add_symbol(str_sym_name, u64(str_offset), false, 2)

	// ADRP + ADD to load address
	g.macho.add_reloc(g.macho.text_data.len, str_sym_idx, arm64_reloc_page21, true)
	g.emit32(asm_adrp(Reg(reg)))
	g.macho.add_reloc(g.macho.text_data.len, str_sym_idx, arm64_reloc_pageoff12, false)
	g.emit32(asm_add_pageoff(Reg(reg)))

	g.emit_mov_imm(10, i64(str_len))
}

// ==================== Global access ====================

fn (mut g Gen) emit_global_addr(reg int, name string) {
	sym_name := '_' + name
	mut sym_idx := 0
	if existing := g.macho.sym_by_name[sym_name] {
		sym_idx = existing
	} else {
		sym_idx = g.macho.add_undefined(sym_name)
	}
	g.macho.add_reloc(g.macho.text_data.len, sym_idx, arm64_reloc_page21, true)
	g.emit32(asm_adrp(Reg(reg)))
	g.macho.add_reloc(g.macho.text_data.len, sym_idx, arm64_reloc_pageoff12, false)
	g.emit32(asm_add_pageoff(Reg(reg)))
}

fn (g &Gen) find_global_idx_by_name(name string) int {
	for i, global in g.m.globals {
		if global.name == name {
			return i
		}
	}
	return -1
}

fn (mut g Gen) store_entry_arg_to_global(reg int, global_name string) {
	global_idx := g.find_global_idx_by_name(global_name)
	if global_idx < 0 {
		return
	}
	g.emit_global_addr(9, global_name)
	g.emit_store_typed(reg, 9, g.m.globals[global_idx].typ)
}

// ==================== Branch handling ====================

fn (mut g Gen) emit_branch_to_block(blk_id int) {
	if blk_id >= 0 && blk_id < g.block_offsets.len && g.block_offsets[blk_id] >= 0 {
		target := g.block_offsets[blk_id]
		offset := (target - g.macho.text_data.len) / 4
		g.emit32(asm_b(i32(offset)))
	} else {
		g.pending_jmps << PendingJmp{
			text_pos: g.macho.text_data.len
			block_id: blk_id
		}
		g.emit32(asm_b(0))
	}
}

fn (mut g Gen) emit_phi_edge_copies(from_blk int, to_blk int) {
	if to_blk < 0 || to_blk >= g.m.blocks.len {
		return
	}
	for val_id in g.m.blocks[to_blk].instrs {
		if val_id <= 0 || val_id >= g.m.values.len {
			continue
		}
		val := g.m.values[val_id]
		if val.kind != .instruction {
			continue
		}
		instr := g.m.instrs[val.index]
		if instr.op != .phi {
			break
		}
		for oi := 0; oi + 1 < instr.operands.len; oi += 2 {
			if int(instr.operands[oi + 1]) != from_blk {
				continue
			}
			src_id := instr.operands[oi]
			g.emit_phi_copy_value(src_id, val_id)
			break
		}
	}
}

fn (mut g Gen) emit_phi_copy_value(src_id int, dst_id int) {
	if dst_id <= 0 || dst_id >= g.m.values.len {
		return
	}
	dst := g.m.values[dst_id]
	if dst.typ > 0 && dst.typ < g.m.type_store.types.len && g.is_aggregate_type(dst.typ) {
		dst_off := g.stack_map[dst_id] or { return }
		size := g.m.type_size(dst.typ)
		n_words := (size + 7) / 8
		src := g.m.values[src_id]
		if src.kind == .string_literal {
			g.materialize_string(src_id, 8)
			g.emit_store_fp(8, dst_off)
			if n_words > 1 {
				g.emit_store_fp(10, dst_off + 8)
			}
			return
		}
		if src_off := g.stack_map[src_id] {
			for wi in 0 .. n_words {
				g.emit_load_fp(8, src_off + wi * 8)
				g.emit_store_fp(8, dst_off + wi * 8)
			}
			return
		}
		src_reg := g.load_val(src_id, 8)
		if src_reg != 8 {
			g.emit32(asm_mov_reg(Reg(8), Reg(src_reg)))
		}
		g.emit_store_fp(8, dst_off)
		g.emit_mov_imm(8, 0)
		for wi in 1 .. n_words {
			g.emit_store_fp(8, dst_off + wi * 8)
		}
		return
	}
	src_reg := g.load_val(src_id, 8)
	if src_reg != 8 {
		g.emit32(asm_mov_reg(Reg(8), Reg(src_reg)))
	}
	g.store_val(8, dst_id)
}

fn (mut g Gen) resolve_pending_jmps(blk_id int) {
	target := g.macho.text_data.len
	mut remaining := []PendingJmp{}
	for pj in g.pending_jmps {
		if pj.block_id == blk_id {
			offset := (target - pj.text_pos) / 4
			g.patch_branch(pj.text_pos, offset)
		} else {
			remaining << pj
		}
	}
	g.pending_jmps = remaining
}

fn (mut g Gen) resolve_all_pending() {
	for pj in g.pending_jmps {
		if pj.block_id >= 0 && pj.block_id < g.block_offsets.len
			&& g.block_offsets[pj.block_id] >= 0 {
			offset := (g.block_offsets[pj.block_id] - pj.text_pos) / 4
			g.patch_branch(pj.text_pos, offset)
		}
	}
	g.pending_jmps.clear()
}

fn (mut g Gen) patch_branch(text_pos int, offset int) {
	existing := read_u32_le(g.macho.text_data, text_pos)
	opcode := existing & 0xFC000000
	imm26 := u32(offset) & 0x03FFFFFF
	patched := opcode | imm26
	write_u32_le_at_arr(mut g.macho.text_data, text_pos, patched)
}

// ==================== Low-level emission helpers ====================

fn (mut g Gen) emit32(instr u32) {
	g.macho.text_data << u8(instr)
	g.macho.text_data << u8(instr >> 8)
	g.macho.text_data << u8(instr >> 16)
	g.macho.text_data << u8(instr >> 24)
}

fn (mut g Gen) emit_mov_imm(reg int, val i64) {
	if val >= 0 && val < 65536 {
		g.emit32(asm_movz(Reg(reg), u32(val)))
	} else if val >= 0 && val < i64(0xFFFFFFFF) {
		lo := u32(val) & 0xFFFF
		hi := (u32(val) >> 16) & 0xFFFF
		g.emit32(asm_movz(Reg(reg), lo))
		if hi != 0 {
			g.emit32(asm_movk(Reg(reg), hi, 1))
		}
	} else if val < 0 && val >= -65536 {
		g.emit32(asm_movn(Reg(reg), u32(~val)))
	} else {
		uval := u64(val)
		g.emit32(asm_movz(Reg(reg), u32(uval & 0xFFFF)))
		if (uval >> 16) & 0xFFFF != 0 {
			g.emit32(asm_movk(Reg(reg), u32((uval >> 16) & 0xFFFF), 1))
		}
		if (uval >> 32) & 0xFFFF != 0 {
			g.emit32(asm_movk(Reg(reg), u32((uval >> 32) & 0xFFFF), 2))
		}
		if (uval >> 48) & 0xFFFF != 0 {
			g.emit32(asm_movk(Reg(reg), u32((uval >> 48) & 0xFFFF), 3))
		}
	}
}

fn (mut g Gen) emit_store_fp(reg int, offset int) {
	if offset >= -255 && offset < 0 {
		g.emit32(asm_stur(Reg(reg), fp, i32(offset)))
	} else if offset < -255 {
		g.emit_mov_imm(11, i64(offset))
		g.emit32(asm_add_reg(Reg(11), fp, Reg(11)))
		g.emit32(asm_str(Reg(reg), Reg(11)))
	} else {
		g.emit32(asm_str_imm(Reg(reg), fp, u32(offset / 8)))
	}
}

fn (mut g Gen) emit_store_sp(reg int, offset int) {
	if offset >= 0 && offset < 32768 && offset % 8 == 0 {
		g.emit32(asm_str_imm(Reg(reg), sp, u32(offset / 8)))
	} else {
		g.emit_mov_imm(11, i64(offset))
		g.emit32(asm_add_reg(Reg(11), sp, Reg(11)))
		g.emit32(asm_str(Reg(reg), Reg(11)))
	}
}

fn (mut g Gen) emit_load_fp(reg int, offset int) {
	if offset >= -255 && offset < 0 {
		g.emit32(asm_ldur(Reg(reg), fp, i32(offset)))
	} else if offset < -255 {
		g.emit_mov_imm(11, i64(offset))
		g.emit32(asm_add_reg(Reg(11), fp, Reg(11)))
		g.emit32(asm_ldr(Reg(reg), Reg(11)))
	} else {
		g.emit32(asm_ldr_imm(Reg(reg), fp, u32(offset / 8)))
	}
}

fn (mut g Gen) emit_lea_fp(reg int, offset int) {
	if offset >= 0 && offset < 4096 {
		g.emit32(asm_add_imm(Reg(reg), fp, u32(offset)))
	} else if offset < 0 && -offset < 4096 {
		g.emit32(asm_sub_imm(Reg(reg), fp, u32(-offset)))
	} else {
		g.emit_mov_imm(reg, i64(offset))
		g.emit32(asm_add_reg(Reg(reg), fp, Reg(reg)))
	}
}

fn (g &Gen) ptr_elem_type(val_id int) ssa.TypeID {
	if val_id <= 0 || val_id >= g.m.values.len {
		return 0
	}
	typ_id := g.m.values[val_id].typ
	if typ_id > 0 && typ_id < g.m.type_store.types.len {
		typ := g.m.type_store.types[typ_id]
		if typ.kind == .ptr_t {
			return typ.elem_type
		}
	}
	return 0
}

fn (g &Gen) is_string_struct_type(typ_id ssa.TypeID) bool {
	if typ_id <= 0 || typ_id >= g.m.type_store.types.len {
		return false
	}
	typ := g.m.type_store.types[typ_id]
	if typ.kind != .struct_t || typ.fields.len != 2 || g.m.type_size(typ_id) != 16 {
		return false
	}
	first := g.m.type_store.types[typ.fields[0]]
	second := g.m.type_store.types[typ.fields[1]]
	return first.kind == .ptr_t && second.kind == .int_t && second.width == 32
}

fn (mut g Gen) emit_load_string_regs_from_ptr(ptr_reg int, data_reg int, len_reg int, typ_id ssa.TypeID) {
	typ := g.m.type_store.types[typ_id]
	g.emit_load_typed(data_reg, ptr_reg, typ.fields[0])
	g.emit32(asm_add_imm(Reg(11), Reg(ptr_reg), 8))
	g.emit_load_typed(len_reg, 11, typ.fields[1])
}

fn (mut g Gen) emit_load_string_regs_from_fp(off int, data_reg int, len_reg int, typ_id ssa.TypeID) {
	typ := g.m.type_store.types[typ_id]
	g.emit_load_fp(data_reg, off)
	g.emit_lea_fp(11, off + 8)
	g.emit_load_typed(len_reg, 11, typ.fields[1])
}

fn (mut g Gen) emit_store_typed(src_reg int, ptr_reg int, typ ssa.TypeID) {
	size := g.m.type_size(typ)
	match size {
		1 { g.emit32(asm_str_b(Reg(src_reg), Reg(ptr_reg))) }
		2 { g.emit32(asm_str_h(Reg(src_reg), Reg(ptr_reg))) }
		4 { g.emit32(asm_str_w(Reg(src_reg), Reg(ptr_reg))) }
		else { g.emit32(asm_str(Reg(src_reg), Reg(ptr_reg))) }
	}
}

fn (mut g Gen) emit_load_typed(dst_reg int, ptr_reg int, typ ssa.TypeID) {
	size := g.m.type_size(typ)
	match size {
		1 {
			g.emit32(asm_ldr_b(Reg(dst_reg), Reg(ptr_reg)))
		}
		2 {
			g.emit32(asm_ldr_h(Reg(dst_reg), Reg(ptr_reg)))
		}
		4 {
			if g.is_signed_int_type(typ) {
				g.emit32(asm_ldrsw(Reg(dst_reg), Reg(ptr_reg)))
			} else {
				g.emit32(asm_ldr_w(Reg(dst_reg), Reg(ptr_reg)))
			}
		}
		else {
			g.emit32(asm_ldr(Reg(dst_reg), Reg(ptr_reg)))
		}
	}
}

fn (g &Gen) is_signed_int_type(typ_id ssa.TypeID) bool {
	if typ_id <= 0 || typ_id >= g.m.type_store.types.len {
		return false
	}
	typ := g.m.type_store.types[typ_id]
	return typ.kind == .int_t && !typ.is_unsigned
}

fn (mut g Gen) emit_sub_sp(size int) {
	if size > 0 && size < 4096 {
		g.emit32(asm_sub_imm(sp, sp, u32(size)))
	} else if size >= 4096 {
		g.emit_mov_imm(11, i64(size))
		g.emit32(asm_sub_sp_reg(Reg(11)))
	}
}

fn (mut g Gen) emit_add_sp(size int) {
	if size > 0 && size < 4096 {
		g.emit32(asm_add_imm(sp, sp, u32(size)))
	} else if size >= 4096 {
		g.emit_mov_imm(11, i64(size))
		g.emit32(asm_add_sp_reg(Reg(11)))
	}
}

fn parse_arm64_int(s string) i64 {
	if s.len == 0 {
		return 0
	}
	mut neg := false
	mut start := 0
	if s[0] == `-` {
		neg = true
		start = 1
	}
	mut base := u64(10)
	mut digits_start := start
	if s.len > start + 2 && s[start] == `0` {
		if s[start + 1] == `x` || s[start + 1] == `X` {
			base = 16
			digits_start = start + 2
		} else if s[start + 1] == `b` || s[start + 1] == `B` {
			base = 2
			digits_start = start + 2
		} else if s[start + 1] == `o` || s[start + 1] == `O` {
			base = 8
			digits_start = start + 2
		}
	}
	mut n := u64(0)
	for i in digits_start .. s.len {
		c := s[i]
		mut digit := u64(base)
		if c >= `0` && c <= `9` {
			digit = u64(c - `0`)
		} else if c >= `a` && c <= `f` {
			digit = u64(c - `a` + 10)
		} else if c >= `A` && c <= `F` {
			digit = u64(c - `A` + 10)
		}
		if digit < base {
			n = n * base + digit
		}
	}
	wrapped := i64(n)
	return if neg { -wrapped } else { wrapped }
}
