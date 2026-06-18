module optimize

import v3.ssa

fn constant_fold(mut m ssa.Module) bool {
	mut changed := false
	for fi in 0 .. m.funcs.len {
		for blk_id in m.funcs[fi].blocks {
			for val_id in m.blocks[blk_id].instrs {
				if m.values[val_id].kind != .instruction {
					continue
				}
				instr := m.instrs[m.values[val_id].index]
				if instr.operands.len != 2 {
					continue
				}
				lhs := m.values[instr.operands[0]]
				rhs := m.values[instr.operands[1]]
				if lhs.kind != .constant || rhs.kind != .constant {
					continue
				}
				l_int := lhs.name.i64()
				r_int := rhs.name.i64()

				mut result := i64(0)
				mut folded := false

				match instr.op {
					.add {
						result = l_int + r_int
						folded = true
					}
					.sub {
						result = l_int - r_int
						folded = true
					}
					.mul {
						result = l_int * r_int
						folded = true
					}
					.sdiv {
						if r_int != 0 {
							result = l_int / r_int
							folded = true
						}
					}
					.srem {
						if r_int != 0 {
							result = l_int % r_int
							folded = true
						}
					}
					.and_ {
						result = l_int & r_int
						folded = true
					}
					.or_ {
						result = l_int | r_int
						folded = true
					}
					.xor {
						result = l_int ^ r_int
						folded = true
					}
					.shl {
						if r_int >= 0 && r_int < 64 {
							result = i64(u64(l_int) << u64(r_int))
							folded = true
						}
					}
					.ashr {
						if r_int >= 0 && r_int < 64 {
							result = l_int >> u64(r_int)
							folded = true
						}
					}
					.lshr {
						if r_int >= 0 && r_int < 64 {
							result = i64(u64(l_int) >> u64(r_int))
							folded = true
						}
					}
					.eq {
						result = if l_int == r_int { 1 } else { 0 }
						folded = true
					}
					.ne {
						result = if l_int != r_int { 1 } else { 0 }
						folded = true
					}
					.lt {
						result = if l_int < r_int { 1 } else { 0 }
						folded = true
					}
					.gt {
						result = if l_int > r_int { 1 } else { 0 }
						folded = true
					}
					.le {
						result = if l_int <= r_int { 1 } else { 0 }
						folded = true
					}
					.ge {
						result = if l_int >= r_int { 1 } else { 0 }
						folded = true
					}
					else {}
				}

				if folded {
					typ := m.values[val_id].typ
					const_val := m.get_or_add_const(typ, '${result}')
					m.replace_uses(val_id, const_val)
					changed = true
				}
			}
		}
	}
	return changed
}

fn branch_fold(mut m ssa.Module) bool {
	mut changed := false
	for fi in 0 .. m.funcs.len {
		for blk_id in m.funcs[fi].blocks {
			if m.blocks[blk_id].instrs.len == 0 {
				continue
			}
			term_val_id := m.blocks[blk_id].instrs.last()
			term := m.instrs[m.values[term_val_id].index]
			if term.op == .br && term.operands.len >= 3 {
				cond_val := m.values[term.operands[0]]
				if cond_val.kind == .constant {
					cond_int := cond_val.name.i64()
					target := if cond_int != 0 { term.operands[1] } else { term.operands[2] }
					mut jmp_instr := m.instrs[m.values[term_val_id].index]
					jmp_instr.op = .jmp
					mut new_ops := []ssa.ValueID{}
					new_ops << target
					jmp_instr.operands = new_ops
					m.instrs[m.values[term_val_id].index] = jmp_instr
					changed = true
				}
			}
		}
	}
	return changed
}
