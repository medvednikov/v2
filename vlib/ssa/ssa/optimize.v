module ssa

import time

// Optimize Module
pub fn (mut m Module) optimize() {
	t := time.now()
	// 1. Build Control Flow Graph (Predecessors)
	m.build_cfg()

	// 2. Compute Dominator Tree (Lengauer-Tarjan)
	m.compute_dominators()

	// 3. Promote Memory to Register (Construct SSA / Phi Nodes)
	m.promote_memory_to_register()

	// 4. Scalar Optimizations
	m.constant_fold()
	m.dead_code_elimination()
	m.remove_unreachable_blocks()

	// 5. Eliminate Phi Nodes (Lower to Copies for Backend)
	m.eliminate_phi_nodes()
	println('SSA optimization took ${time.since(t)}')
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

// --- 2. Dominators (Lengauer-Tarjan) ---

struct LTContext {
mut:
	parent   []int   // DFS tree parent
	semi     []int   // Semidominator (BlockID)
	vertex   []int   // Map DFS number -> BlockID
	bucket   [][]int // bucket[w] = set of vertices v s.t. semi[v] = w
	dfnum    []int   // DFS number (0 means unvisited)
	ancestor []int   // DSU parent
	label    []int   // DSU label (min semi in path)
	n        int     // Counter
}

fn (mut m Module) compute_dominators() {
	for func in m.funcs {
		if func.blocks.len == 0 {
			continue
		}

		// Calculate total block count to size arrays correctly
		// Note: func.blocks contains IDs, max_id could be larger than len
		max_id := m.blocks.len

		mut ctx := LTContext{
			parent:   []int{len: max_id, init: -1}
			semi:     []int{len: max_id, init: -1}
			vertex:   []int{len: max_id, init: -1} // we only need size = func.blocks.len + 1 actually
			bucket:   [][]int{len: max_id}
			dfnum:    []int{len: max_id, init: 0}
			ancestor: []int{len: max_id, init: -1}
			label:    []int{len: max_id, init: -1}
			n:        0
		}

		// Initialize DSU labels
		for blk_id in func.blocks {
			ctx.label[blk_id] = blk_id
			ctx.semi[blk_id] = blk_id
			// Initialize idom to -1
			m.blocks[blk_id].idom = -1
		}

		entry := func.blocks[0]
		m.lt_dfs(entry, mut ctx)

		// Process in reverse DFS order (skip root)
		for i := ctx.n; i >= 2; i-- {
			w := ctx.vertex[i]

			// 1. Calculate Semidominator
			for p in m.blocks[w].preds {
				// Only process reachable predecessors
				if ctx.dfnum[p] == 0 {
					continue
				}

				u := ctx.eval(p)
				if ctx.dfnum[ctx.semi[u]] < ctx.dfnum[ctx.semi[w]] {
					ctx.semi[w] = ctx.semi[u]
				}
			}

			// Add w to bucket of its semidominator
			ctx.bucket[ctx.semi[w]] << w

			// Link to parent in forest
			ctx.link(ctx.parent[w], w)

			// 2. Implicitly compute IDom
			parent_w := ctx.parent[w]
			// Drain bucket of parent
			// Note: We copy to iterate because we might clear/modify?
			// Standard algo drains bucket[parent_w] now.
			for v in ctx.bucket[parent_w] {
				u := ctx.eval(v)
				if ctx.semi[u] == ctx.semi[v] {
					m.blocks[v].idom = parent_w
				} else {
					m.blocks[v].idom = u // Deferred: idom[v] = idom[u]
				}
			}
			ctx.bucket[parent_w] = []
		}

		// 3. Explicitly compute IDom
		for i := 2; i <= ctx.n; i++ {
			w := ctx.vertex[i]
			if m.blocks[w].idom != ctx.vertex[ctx.dfnum[ctx.semi[w]]] {
				m.blocks[w].idom = m.blocks[m.blocks[w].idom].idom
			}
		}

		m.blocks[entry].idom = entry

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

fn (mut m Module) lt_dfs(v int, mut ctx LTContext) {
	ctx.n++
	ctx.dfnum[v] = ctx.n
	ctx.vertex[ctx.n] = v

	for w in m.blocks[v].succs {
		if ctx.dfnum[w] == 0 {
			ctx.parent[w] = v
			m.lt_dfs(w, mut ctx)
		}
	}
}

fn (mut ctx LTContext) compress(v int) {
	if ctx.ancestor[ctx.ancestor[v]] != -1 {
		ctx.compress(ctx.ancestor[v])

		// Update label based on ancestor
		if ctx.dfnum[ctx.semi[ctx.label[ctx.ancestor[v]]]] < ctx.dfnum[ctx.semi[ctx.label[v]]] {
			ctx.label[v] = ctx.label[ctx.ancestor[v]]
		}
		ctx.ancestor[v] = ctx.ancestor[ctx.ancestor[v]]
	}
}

fn (mut ctx LTContext) eval(v int) int {
	if ctx.ancestor[v] == -1 {
		return ctx.label[v]
	}
	ctx.compress(v)
	// If label[ancestor[v]] is better than label[v], use it?
	// The path compression updates label[v] to be the best in the path.
	// However, standard EVAL checks:
	if ctx.dfnum[ctx.semi[ctx.label[ctx.ancestor[v]]]] >= ctx.dfnum[ctx.semi[ctx.label[v]]] {
		return ctx.label[v]
	}
	return ctx.label[ctx.ancestor[v]]
}

fn (mut ctx LTContext) link(v int, w int) {
	ctx.ancestor[w] = v
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

		// Insert Phis
		for blk_id, allocs in ctx.phi_placements {
			for alloc_id in allocs {
				typ := m.type_store.types[m.values[alloc_id].typ].elem_type
				phi_val := m.add_instr_front(.phi, blk_id, typ, [])
				m.values[phi_val].name = '${m.values[alloc_id].name}.phi'
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
				// Safety check: idom != -1
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

	// 1. Push Phis to stack
	if phis := ctx.phi_placements[blk_id] {
		for alloc_id in phis {
			name := '${m.values[alloc_id].name}.phi'
			for val_id in blk.instrs {
				instr := m.instrs[m.values[val_id].index]
				if instr.op != .phi {
					break
				}
				if m.values[val_id].name == name {
					ctx.stacks[alloc_id] << val_id
					break
				}
			}
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

	typ := m.values[dest].typ
	m.instrs << Instruction{
		op:       .assign
		block:    blk_id
		typ:      typ
		operands: [ValueID(dest), src]
	}
	val_id := m.add_value_node(.instruction, typ, 'copy', m.instrs.len - 1)

	// Safe insertion: find terminator
	mut insert_idx := m.blocks[blk_id].instrs.len
	if insert_idx > 0 {
		last_val := m.blocks[blk_id].instrs.last()
		last_instr := m.instrs[m.values[last_val].index]

		if last_instr.op in [.ret, .br, .jmp, .switch_, .unreachable] {
			insert_idx = m.blocks[blk_id].instrs.len - 1
		}
	}

	m.blocks[blk_id].instrs.insert(insert_idx, val_id)
}

fn (mut m Module) constant_fold() {
	for func in m.funcs {
		for blk_id in func.blocks {
			mut instrs := m.blocks[blk_id].instrs.clone()

			for val_id in instrs {
				// Ensure value is an instruction
				if m.values[val_id].kind != .instruction {
					continue
				}

				instr := m.instrs[m.values[val_id].index]

				// Example: Binary Ops
				if instr.operands.len == 2 {
					lhs := m.values[instr.operands[0]]
					rhs := m.values[instr.operands[1]]

					if lhs.kind == .constant && rhs.kind == .constant {
						// Assuming integer math for MVP
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
							// Add div check for 0
							else {}
						}

						if folded {
							// Turn the instruction value into a constant
							m.values[val_id].kind = .constant
							m.values[val_id].name = result.str()
							// Clear operands/instr data (optional cleanup)
							// Now users of val_id will see a Constant, not an Instruction
						}
					}
				}
			}
		}
	}
}

fn (mut m Module) dead_code_elimination() {
	mut changed := true
	for changed {
		changed = false
		for func in m.funcs {
			for blk_id in func.blocks {
				mut blk := m.blocks[blk_id]
				mut new_instrs := []int{}
				for val_id in blk.instrs {
					val := m.values[val_id]
					// If converted to constant, it stays (backend handles it)
					// If instruction, check uses and side effects
					if val.kind == .instruction {
						instr := m.instrs[val.index]
						side_effects := instr.op in [.store, .call, .ret, .br, .jmp, .switch_,
							.unreachable]
						if !side_effects && val.uses.len == 0 {
							// Kill
							for op_id in instr.operands {
								m.remove_use(op_id, val_id)
							}
							changed = true
							continue
						}
					}
					new_instrs << val_id
				}
				m.blocks[blk_id].instrs = new_instrs
			}
		}
	}
}

fn (mut m Module) remove_use(val_id int, user_id int) {
	if val_id >= m.values.len {
		return
	}
	mut val := &m.values[val_id]
	for i := 0; i < val.uses.len; i++ {
		if val.uses[i] == user_id {
			val.uses.delete(i)
			break
		}
	}
}

fn (mut m Module) remove_unreachable_blocks() {
	// Re-build CFG first
	m.build_cfg()
	for mut func in m.funcs {
		if func.blocks.len == 0 {
			continue
		}
		// BFS/DFS from entry
		mut reachable := map[int]bool{}
		mut q := [func.blocks[0]]
		reachable[func.blocks[0]] = true

		for q.len > 0 {
			curr := q.pop()
			for succ in m.blocks[curr].succs {
				if !reachable[succ] {
					reachable[succ] = true
					q << succ
				}
			}
		}

		mut new_blocks := []int{}
		for blk in func.blocks {
			if reachable[blk] {
				new_blocks << blk
			}
		}
		func.blocks = new_blocks
	}
}
