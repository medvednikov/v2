module optimize

import v3.ssa

pub fn optimize(mut m ssa.Module) {
	rebuild_use_lists(mut m)
	build_cfg(mut m)

	constant_fold(mut m)
	rebuild_use_lists(mut m)

	branch_fold(mut m)
	rebuild_use_lists(mut m)
	build_cfg(mut m)

	dead_code_elimination(mut m)
	rebuild_use_lists(mut m)
	build_cfg(mut m)

	remove_unreachable_blocks(mut m)

	merge_blocks(mut m)
	rebuild_use_lists(mut m)
	build_cfg(mut m)
}

fn rebuild_use_lists(mut m ssa.Module) {
	for vi in 0 .. m.values.len {
		mut val := m.values[vi]
		val.uses = []
		m.values[vi] = val
	}
	for fi in 0 .. m.funcs.len {
		for blk_id in m.funcs[fi].blocks {
			if blk_id < 0 || blk_id >= m.blocks.len {
				continue
			}
			for val_id in m.blocks[blk_id].instrs {
				if val_id <= 0 || val_id >= m.values.len || m.values[val_id].kind != .instruction {
					continue
				}
				instr_idx := m.values[val_id].index
				if instr_idx < 0 || instr_idx >= m.instrs.len {
					continue
				}
				instr := m.instrs[instr_idx]

				for op_id in instr.value_operands() {
					if op_id >= 0 && op_id < m.values.len && val_id !in m.values[op_id].uses {
						mut op_val := m.values[op_id]
						op_val.uses << val_id
						m.values[op_id] = op_val
					}
				}
			}
		}
	}
}
