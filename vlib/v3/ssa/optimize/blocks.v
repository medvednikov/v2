module optimize

import v3.ssa

fn remove_unreachable_blocks(mut m ssa.Module) {
	build_cfg(mut m)
	for fi in 0 .. m.funcs.len {
		if m.funcs[fi].blocks.len == 0 {
			continue
		}
		mut reachable := map[int]bool{}
		mut q := [m.funcs[fi].blocks[0]]
		reachable[m.funcs[fi].blocks[0]] = true

		for q.len > 0 {
			curr := q.last()
			q.delete_last()
			for succ in m.blocks[curr].succs {
				if !reachable[succ] {
					reachable[succ] = true
					q << succ
				}
			}
		}

		mut new_blocks := []int{}
		for blk in m.funcs[fi].blocks {
			if reachable[blk] {
				new_blocks << blk
			}
		}
		mut func := m.funcs[fi]
		func.blocks = new_blocks
		m.funcs[fi] = func
	}
}

fn merge_blocks(mut m ssa.Module) {
	mut changed := true
	mut first := true
	for changed {
		changed = false
		if first {
			build_cfg(mut m)
			first = false
		}

		for fi in 0 .. m.funcs.len {
			mut merged := map[int]bool{}

			for blk_id in m.funcs[fi].blocks {
				if merged[blk_id] {
					continue
				}
				if m.blocks[blk_id].instrs.len == 0 {
					continue
				}
				last_val := m.blocks[blk_id].instrs.last()
				last_instr := m.instrs[m.values[last_val].index]
				if last_instr.op != .jmp || last_instr.operands.len < 1 {
					continue
				}
				target_id := int(last_instr.operands[0])
				if target_id < 0 || target_id == blk_id {
					continue
				}
				if m.blocks[target_id].preds.len != 1 || m.blocks[target_id].preds[0] != blk_id {
					continue
				}

				// Merge: remove jmp from A, append B's instrs
				mut blk := m.blocks[blk_id]
				blk.instrs.delete_last()
				for moved_val in m.blocks[target_id].instrs {
					blk.instrs << moved_val
					if moved_val > 0 && moved_val < m.values.len
						&& m.values[moved_val].kind == .instruction {
						instr_idx := m.values[moved_val].index
						if instr_idx >= 0 && instr_idx < m.instrs.len {
							mut instr := m.instrs[instr_idx]
							instr.block = blk_id
							m.instrs[instr_idx] = instr
						}
					}
				}
				m.blocks[blk_id] = blk

				merged[target_id] = true
				changed = true
			}

			if merged.len > 0 {
				mut new_blks := []int{}
				for b in m.funcs[fi].blocks {
					if !merged[b] {
						new_blks << b
					}
				}
				mut func := m.funcs[fi]
				func.blocks = new_blks
				m.funcs[fi] = func
			}
		}
		if changed {
			build_cfg(mut m)
		}
	}
}
