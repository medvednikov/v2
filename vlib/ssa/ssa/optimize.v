module ssa

// Optimize Module
pub fn (mut m Module) optimize() {
	// 1. Build Control Flow Graph (Predecessors)
	m.build_cfg()

	// 2. Compute Dominator Tree
	m.compute_dominators()

	// 3. Promote Memory to Register (Construct SSA / Phi Nodes)
	m.promote_memory_to_register()

	// 4. Eliminate Phi Nodes (Lower to Copies for Backend)
	m.eliminate_phi_nodes()
}

// --- 1. CFG Construction ---
fn (mut m Module) build_cfg() {
	for func in m.funcs {
		// Clear existing preds
		for blk_id in func.blocks {
			m.blocks[blk_id].preds = []
		}

		for blk_id in func.blocks {
			blk := m.blocks[blk_id]
			if blk.instrs.len == 0 {
				continue
			}
			term_val_id := blk.instrs.last()
			term := m.instrs[m.values[term_val_id].index]

			mut succs := []int{}
			match term.op {
				.br {
					succs << m.get_block_from_val(term.operands[1])
					succs << m.get_block_from_val(term.operands[2])
				}
				.jmp {
					succs << m.get_block_from_val(term.operands[0])
				}
				.switch_ {
					// default
					succs << m.get_block_from_val(term.operands[1])
					// cases
					for i := 3; i < term.operands.len; i += 2 {
						succs << m.get_block_from_val(term.operands[i])
					}
				}
				else {}
			}

			m.blocks[blk_id].succs = succs
			for s in succs {
				m.blocks[s].preds << blk_id
			}
		}
	}
}

// --- 2. Dominators (Lengauer-Tarjan / Iterative) ---
fn (mut m Module) compute_dominators() {
	for func in m.funcs {
		if func.blocks.len == 0 {
			continue
		}

		entry := func.blocks[0]

		// Initialize
		for blk_id in func.blocks {
			m.blocks[blk_id].idom = -1
		}
		m.blocks[entry].idom = entry

		mut rpo := m.get_rpo(func)

		mut changed := true
		for changed {
			changed = false
			// for blk_id in func.blocks {
			for blk_id in rpo {
				if blk_id == entry {
					continue
				}

				preds := m.blocks[blk_id].preds
				if preds.len == 0 {
					continue
				}

				mut new_idom := -1
				// Find first processed pred
				for p in preds {
					if m.blocks[p].idom != -1 {
						new_idom = p
						break
					}
				}

				if new_idom == -1 {
					continue
				}

				for p in preds {
					if p != new_idom && m.blocks[p].idom != -1 {
						new_idom = m.intersect(p, new_idom)
					}
				}

				if m.blocks[blk_id].idom != new_idom {
					m.blocks[blk_id].idom = new_idom
					changed = true
				}
			}
		}

		// Build Dom Tree Children
		for blk_id in func.blocks {
			m.blocks[blk_id].dom_tree = []
		}
		for blk_id in func.blocks {
			idom := m.blocks[blk_id].idom
			if idom != -1 && idom != blk_id {
				m.blocks[idom].dom_tree << blk_id
			}
		}
	}
}

fn (m Module) intersect(b1 int, b2 int) int {
	mut finger1 := b1
	mut finger2 := b2

	mut ancestors := map[int]bool{}
	mut curr := finger1
	for curr != -1 {
		ancestors[curr] = true
		if curr == m.blocks[curr].idom {
			break
		}
		curr = m.blocks[curr].idom
	}

	curr = finger2
	for curr != -1 {
		if ancestors[curr] {
			return curr
		}
		if curr == m.blocks[curr].idom {
			break
		}
		curr = m.blocks[curr].idom
	}
	return 0
}

// --- 3. Mem2Reg (Promote Allocas) ---
struct Mem2RegCtx {
mut:
	defs           map[int][]int
	uses           map[int][]int
	phi_placements map[int][]int
	stacks         map[int][]int
}

fn (mut m Module) promote_memory_to_register() {
	for func in m.funcs {
		mut ctx := Mem2RegCtx{
			defs:           map[int][]int{}
			uses:           map[int][]int{}
			phi_placements: map[int][]int{}
			stacks:         map[int][]int{}
		}

		// 1. Analyze Allocas
		mut promotable := []int{}
		for blk_id in func.blocks {
			blk := m.blocks[blk_id]
			for val_id in blk.instrs {
				instr := m.instrs[m.values[val_id].index]
				if instr.op == .alloca {
					if m.is_promotable(val_id) {
						promotable << val_id
						ctx.stacks[val_id] = []
					}
				}

				if instr.op == .store {
					ptr := instr.operands[1]
					ctx.defs[ptr] << blk_id
				} else if instr.op == .load {
					ptr := instr.operands[0]
					ctx.uses[ptr] << blk_id
				}
			}
		}

		// 2. Insert Phis (Dominance Frontier)
		df := m.compute_dominance_frontier(func)

		for alloc_id in promotable {
			mut worklist := ctx.defs[alloc_id].clone()
			mut visited := map[int]bool{}
			mut has_phi := map[int]bool{}

			for worklist.len > 0 {
				b := worklist.pop()
				for d in df[b] {
					if !has_phi[d] {
						ctx.phi_placements[d] << alloc_id
						has_phi[d] = true
						if !visited[d] {
							visited[d] = true
							worklist << d
						}
					}
				}
			}
		}

		// 3. Rename Variables
		if func.blocks.len > 0 {
			entry := func.blocks[0]
			m.rename_recursive(entry, mut ctx)
		}
	}
}

fn (m Module) is_promotable(alloc_id int) bool {
	uses := m.values[alloc_id].uses
	for u in uses {
		if u >= m.values.len {
			continue
		}
		user := m.values[u]
		if user.kind != .instruction {
			return false
		}
		instr := m.instrs[user.index]
		match instr.op {
			.load {
				if instr.operands.len == 0 || instr.operands[0] != alloc_id {
					return false
				}
			}
			.store {
				// Only safe if used as pointer (index 1)
				if instr.operands.len < 2 || instr.operands[1] != alloc_id {
					return false
				}
			}
			else {
				// Escape (GEP, Call, Phi, etc.)
				return false
			}
		}
	}
	return true
}

fn (mut m Module) compute_dominance_frontier(func Function) map[int][]int {
	mut df := map[int][]int{}
	for blk_id in func.blocks {
		preds := m.blocks[blk_id].preds
		if preds.len >= 2 {
			for p in preds {
				mut runner := p
				idom := m.blocks[blk_id].idom
				for runner != -1 && runner != idom {
					df[runner] << blk_id
					if runner == m.blocks[runner].idom {
						break
					}
					runner = m.blocks[runner].idom
				}
			}
		}
	}
	return df
}

fn (mut m Module) rename_recursive(blk_id int, mut ctx Mem2RegCtx) {
	blk := m.blocks[blk_id]

	// 1. Insert Phis defined in this block
	if phis := ctx.phi_placements[blk_id] {
		for alloc_id in phis {
			typ := m.type_store.types[m.values[alloc_id].typ].elem_type
			phi_val := m.add_instr_front(.phi, blk_id, typ, [])
			m.values[phi_val].name = '${m.values[alloc_id].name}.phi'
			ctx.stacks[alloc_id] << phi_val
		}
	}

	// 2. Process Instructions
	mut stack_counts := map[int]int{}
	for k, v in ctx.stacks {
		stack_counts[k] = v.len
	}

	mut instrs_to_nop := []int{}

	for val_id in blk.instrs {
		instr := m.instrs[m.values[val_id].index]
		match instr.op {
			.store {
				ptr := instr.operands[1]
				val := instr.operands[0]
				if _ := ctx.stacks[ptr] {
					ctx.stacks[ptr] << val
					instrs_to_nop << val_id
				}
			}
			.load {
				ptr := instr.operands[0]
				if stack := ctx.stacks[ptr] {
					mut repl := 0
					if stack.len > 0 {
						repl = stack.last()
					} else {
						// Undef / Zero
						// Use the type of the value being loaded
						res_type := m.values[val_id].typ
						repl = m.add_value_node(.constant, res_type, '0', 0)
					}
					m.replace_uses(val_id, repl)
					instrs_to_nop << val_id
				}
			}
			.alloca {
				if _ := ctx.stacks[val_id] {
					instrs_to_nop << val_id
				}
			}
			else {}
		}
	}

	for vid in instrs_to_nop {
		m.instrs[m.values[vid].index].op = .bitcast
		m.instrs[m.values[vid].index].operands = []
	}

	// 3. Update Successor Phi Operands
	for succ_id in blk.succs {
		if phis := ctx.phi_placements[succ_id] {
			for alloc_id in phis {
				succ_blk := m.blocks[succ_id]
				for vid in succ_blk.instrs {
					v := m.values[vid]
					if v.kind != .instruction {
						continue
					}
					ins := m.instrs[v.index]
					if ins.op == .phi && v.name == '${m.values[alloc_id].name}.phi' {
						mut val := 0
						if ctx.stacks[alloc_id].len > 0 {
							val = ctx.stacks[alloc_id].last()
						} else {
							val = m.add_value_node(.constant, 0, '0', 0)
						}
						m.instrs[v.index].operands << val
						m.instrs[v.index].operands << m.blocks[blk_id].val_id
					}
				}
			}
		}
	}

	// 4. Recurse Dom Children
	for child in blk.dom_tree {
		m.rename_recursive(child, mut ctx)
	}

	// 5. Pop Stacks
	for k, count in stack_counts {
		for ctx.stacks[k].len > count {
			ctx.stacks[k].pop()
		}
	}
}

// --- 4. Phi Elimination (Lower to Copies) ---
fn (mut m Module) eliminate_phi_nodes() {
	for func in m.funcs {
		for blk_id in func.blocks {
			mut phis := []int{}
			for val_id in m.blocks[blk_id].instrs {
				instr := m.instrs[m.values[val_id].index]
				if instr.op == .phi {
					phis << val_id
				}
			}

			for phi_id in phis {
				instr := m.instrs[m.values[phi_id].index]
				for i := 0; i < instr.operands.len; i += 2 {
					val_in := instr.operands[i]
					blk_val := instr.operands[i + 1]
					pred_blk_idx := m.values[blk_val].index

					m.insert_copy_in_block(pred_blk_idx, phi_id, val_in)
				}
			}
		}
	}
}

fn (mut m Module) insert_copy_in_block(blk_id int, dest int, src int) {
	blk := m.blocks[blk_id]
	if blk.instrs.len == 0 {
		return
	}

	// Insert before terminator
	// We need to identify valid insertion point.
	// If the block ends with Br/Jmp/Ret, insert before it.
	// If we just insert at end - 1, it should be fine for now.

	typ := m.values[dest].typ
	m.instrs << Instruction{
		op:       .assign
		block:    blk_id
		typ:      typ
		operands: [ValueID(dest), src]
	}
	val_id := m.add_value_node(.instruction, typ, 'copy', m.instrs.len - 1)

	// Safety check: insert before last instruction
	if m.blocks[blk_id].instrs.len > 0 {
		m.blocks[blk_id].instrs.insert(m.blocks[blk_id].instrs.len - 1, val_id)
	} else {
		m.blocks[blk_id].instrs << val_id
	}
}
