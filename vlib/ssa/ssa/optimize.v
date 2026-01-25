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
	
	// 5. Simplify Phi nodes (remove trivial phis)
	m.simplify_phi_nodes()
	
	m.merge_blocks()
	m.remove_unreachable_blocks()

	// 6. Eliminate Phi Nodes (Lower to Copies for Backend)
	// This includes Critical Edge Splitting and Briggs Parallel Copy Resolution
	m.eliminate_phi_nodes()
	
	println('SSA optimization took ${time.since(t)}')
}

// --- 1. CFG Construction ---
fn (mut m Module) build_cfg() {
	for func in m.funcs {
		// Clear existing preds/succs
		for blk_id in func.blocks {
			m.blocks[blk_id].preds = []
			m.blocks[blk_id].succs = []
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

			// Deduplicate successors
			mut unique_succs := []int{}
			for s in succs {
				if s !in unique_succs {
					unique_succs << s
				}
			}

			m.blocks[blk_id].succs = unique_succs
			for s in unique_succs {
				if blk_id !in m.blocks[s].preds {
					m.blocks[s].preds << blk_id
				}
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

		max_id := m.blocks.len

		mut ctx := LTContext{
			parent:   []int{len: max_id, init: -1}
			semi:     []int{len: max_id, init: -1}
			vertex:   []int{len: max_id, init: -1}
			bucket:   [][]int{len: max_id}
			dfnum:    []int{len: max_id, init: 0}
			ancestor: []int{len: max_id, init: -1}
			label:    []int{len: max_id, init: -1}
			n:        0
		}

		for blk_id in func.blocks {
			ctx.label[blk_id] = blk_id
			ctx.semi[blk_id] = blk_id
			m.blocks[blk_id].idom = -1
		}

		entry := func.blocks[0]
		m.lt_dfs(entry, mut ctx)

		for i := ctx.n; i >= 2; i-- {
			w := ctx.vertex[i]

			for p in m.blocks[w].preds {
				if ctx.dfnum[p] == 0 {
					continue
				}

				u := ctx.eval(p)
				if ctx.dfnum[ctx.semi[u]] < ctx.dfnum[ctx.semi[w]] {
					ctx.semi[w] = ctx.semi[u]
				}
			}

			ctx.bucket[ctx.semi[w]] << w
			ctx.link(ctx.parent[w], w)

			parent_w := ctx.parent[w]
			for v in ctx.bucket[parent_w] {
				u := ctx.eval(v)
				if ctx.semi[u] == ctx.semi[v] {
					m.blocks[v].idom = parent_w
				} else {
					m.blocks[v].idom = u
				}
			}
			ctx.bucket[parent_w] = []
		}

		for i := 2; i <= ctx.n; i++ {
			w := ctx.vertex[i]
			if m.blocks[w].idom != ctx.vertex[ctx.dfnum[ctx.semi[w]]] {
				m.blocks[w].idom = m.blocks[m.blocks[w].idom].idom
			}
		}

		m.blocks[entry].idom = entry

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
					if blk_id !in ctx.defs[ptr] {
						ctx.defs[ptr] << blk_id
					}
				} else if instr.op == .load {
					ptr := instr.operands[0]
					if blk_id !in ctx.uses[ptr] {
						ctx.uses[ptr] << blk_id
					}
				}
			}
		}

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

		for blk_id, allocs in ctx.phi_placements {
			for alloc_id in allocs {
				typ := m.type_store.types[m.values[alloc_id].typ].elem_type
				phi_val := m.add_instr_front(.phi, blk_id, typ, [])
				m.values[phi_val].name = '${m.values[alloc_id].name}.phi'
			}
		}

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
				if instr.operands.len < 2 || instr.operands[1] != alloc_id {
					return false
				}
			}
			else {
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
					if blk_id !in df[runner] {
						df[runner] << blk_id
					}
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

	for child in blk.dom_tree {
		m.rename_recursive(child, mut ctx)
	}

	for k, count in stack_counts {
		for ctx.stacks[k].len > count {
			ctx.stacks[k].pop()
		}
	}
}

// --- 4. Simplify Phi Nodes ---
// Remove trivial phi nodes where all operands are the same or self-referential
fn (mut m Module) simplify_phi_nodes() {
	mut changed := true
	for changed {
		changed = false
		for func in m.funcs {
			for blk_id in func.blocks {
				for val_id in m.blocks[blk_id].instrs {
					if m.values[val_id].kind != .instruction {
						continue
					}
					instr := m.instrs[m.values[val_id].index]
					if instr.op != .phi {
						continue
					}
					
					// Check if phi is trivial (all non-self operands are the same)
					mut unique_val := -1
					mut is_trivial := true
					
					for i := 0; i < instr.operands.len; i += 2 {
						op_val := instr.operands[i]
						// Skip self-references
						if op_val == val_id {
							continue
						}
						if unique_val == -1 {
							unique_val = op_val
						} else if unique_val != op_val {
							is_trivial = false
							break
						}
					}
					
					if is_trivial && unique_val != -1 {
						// Replace all uses of this phi with the unique value
						m.replace_uses(val_id, unique_val)
						// Mark phi as dead
						m.instrs[m.values[val_id].index].op = .bitcast
						m.instrs[m.values[val_id].index].operands = []
						changed = true
					}
				}
			}
		}
	}
}

// --- 5. Critical Edge Splitting ---
// A critical edge is an edge from a block with multiple successors to a block with multiple predecessors.
// We must split these edges to correctly place phi copies.
fn (mut m Module) split_critical_edges() {
	m.build_cfg()

	for mut func in m.funcs {
		mut new_blocks := []ssa.BlockID{}
		
		// Collect edges to split (can't modify while iterating)
		mut edges_to_split := [][]ssa.BlockID{} // [pred_id, succ_id]

		for blk_id in func.blocks {
			blk := m.blocks[blk_id]
			if blk.succs.len > 1 {
				for succ_id in blk.succs {
					if m.blocks[succ_id].preds.len > 1 {
						edges_to_split << [blk_id, succ_id]
					}
				}
			}
		}

		// Split each critical edge
		for edge in edges_to_split {
			pred_id := edge[0]
			succ_id := edge[1]
			
			// Create new block
			split_blk := m.add_block(func.id, 'split_${pred_id}_${succ_id}')
			new_blocks << split_blk

			// Add jump from split block to successor
			succ_val := m.blocks[succ_id].val_id
			m.add_instr(.jmp, split_blk, 0, [succ_val])

			// Update predecessor's terminator to jump to split block instead
			pred_blk := m.blocks[pred_id]
			if pred_blk.instrs.len > 0 {
				term_val_id := pred_blk.instrs.last()
				mut term := &m.instrs[m.values[term_val_id].index]

				old_succ_val := m.blocks[succ_id].val_id
				new_succ_val := m.blocks[split_blk].val_id

				// Replace only ONE occurrence (for switch with duplicate targets)
				mut replaced := false
				for i in 0 .. term.operands.len {
					if !replaced && term.operands[i] == old_succ_val {
						term.operands[i] = new_succ_val
						replaced = true
					}
				}
			}

			// Update phi nodes in successor to reference split block instead of pred
			for val_id in m.blocks[succ_id].instrs {
				if m.values[val_id].kind != .instruction {
					continue
				}
				mut instr := &m.instrs[m.values[val_id].index]
				if instr.op == .phi {
					old_pred_val := m.blocks[pred_id].val_id
					new_pred_val := m.blocks[split_blk].val_id
					for i := 1; i < instr.operands.len; i += 2 {
						if instr.operands[i] == old_pred_val {
							instr.operands[i] = new_pred_val
							break // Only replace first occurrence
						}
					}
				}
			}
		}

		func.blocks << new_blocks
	}

	m.build_cfg()
}

// --- 6. Phi Elimination with Briggs Parallel Copy Resolution ---
struct ParallelCopy {
	dest int
	src  int
}

fn (mut m Module) eliminate_phi_nodes() {
	// First split critical edges
	m.split_critical_edges()

	for func in m.funcs {
		// Map: pred_block -> list of (dest, src) pairs
		mut pred_copies := map[int][]ParallelCopy{}

		// Collect all phi copies grouped by predecessor
		for blk_id in func.blocks {
			for val_id in m.blocks[blk_id].instrs {
				if m.values[val_id].kind != .instruction {
					continue
				}
				instr := m.instrs[m.values[val_id].index]
				if instr.op == .phi {
					for i := 0; i < instr.operands.len; i += 2 {
						val_in := instr.operands[i]
						blk_val := instr.operands[i + 1]
						pred_blk_idx := m.values[blk_val].index

						pred_copies[pred_blk_idx] << ParallelCopy{
							dest: val_id
							src:  val_in
						}
					}
				}
			}
		}

		// For each predecessor, resolve parallel copies using Briggs algorithm
		for pred_blk, copies in pred_copies {
			m.resolve_parallel_copies_briggs(pred_blk, copies)
		}

		// Remove phi instructions
		for blk_id in func.blocks {
			for val_id in m.blocks[blk_id].instrs {
				if m.values[val_id].kind != .instruction {
					continue
				}
				if m.instrs[m.values[val_id].index].op == .phi {
					m.instrs[m.values[val_id].index].op = .bitcast
					m.instrs[m.values[val_id].index].operands = []
				}
			}
		}
	}
}

// Briggs Parallel Copy Resolution Algorithm
// Sequences parallel copies to handle dependencies and cycles correctly.
// Reference: Briggs et al., "Practical Improvements to the Construction and 
// Destruction of Static Single Assignment Form"
fn (mut m Module) resolve_parallel_copies_briggs(blk_id int, copies []ParallelCopy) {
	if copies.len == 0 {
		return
	}

	// Filter out self-copies and build working set
	mut worklist := []ParallelCopy{}
	for copy in copies {
		if copy.dest != copy.src {
			worklist << copy
		}
	}
	
	if worklist.len == 0 {
		return
	}

	// Build maps for the algorithm
	// loc[b] = current location of value originally in b
	// pred[a] = the source for destination a
	mut loc := map[int]int{}
	mut pred := map[int]int{}
	
	// Set of destinations that still need to be written
	mut to_do := map[int]bool{}
	
	// Initialize
	for copy in worklist {
		loc[copy.src] = copy.src
		pred[copy.dest] = copy.src
		to_do[copy.dest] = true
	}
	
	// Ready set: destinations whose sources are not themselves destinations
	mut ready := []int{}
	
	for copy in worklist {
		// A copy is ready if its source is not a destination
		if !to_do[copy.src] {
			ready << copy.dest
		}
	}
	
	// Sequenced copies to emit
	mut sequenced := []ParallelCopy{}
	
	for to_do.len > 0 {
		if ready.len > 0 {
			// Process a ready copy
			b := ready.pop()
			a := pred[b]
			c := loc[a]
			
			// Emit: b <- c
			sequenced << ParallelCopy{ dest: b, src: c }
			
			// Update location: value originally at a is now at b
			loc[a] = b
			to_do.delete(b)
			
			// Check if this makes another copy ready
			// If a was a destination that was blocked, it might now be ready
			if to_do[a] {
				// a is ready if its source's current location is not a destination
				src_of_a := pred[a]
				loc_of_src := if l := loc[src_of_a] { l } else { src_of_a }
				if !to_do[loc_of_src] {
					ready << a
				}
			}
		} else {
			// We have a cycle - need to break it with a temporary
			// Pick any remaining destination
			mut b := 0
			for dest, _ in to_do {
				b = dest
				break
			}
			
			// Create a temporary
			typ := m.values[b].typ
			temp := m.add_value_node(.instruction, typ, 'phi_tmp_${m.values.len}', 0)
			
			// Save the current location of b to temp
			c := loc[b]
			sequenced << ParallelCopy{ dest: temp, src: c }
			
			// Update: value originally at b is now at temp
			loc[b] = temp
			
			// Now b should be ready (its source is no longer blocking)
			ready << b
		}
	}
	
	// Emit the sequenced copies as assign instructions
	for copy in sequenced {
		m.insert_copy_in_block(blk_id, copy.dest, copy.src)
	}
}

fn (mut m Module) insert_copy_in_block(blk_id int, dest int, src int) {
	typ := m.values[dest].typ
	m.instrs << Instruction{
		op:       .assign
		block:    blk_id
		typ:      typ
		operands: [ValueID(dest), src]
	}
	val_id := m.add_value_node(.instruction, typ, 'copy', m.instrs.len - 1)

	// Insert before terminator
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

// --- Other Optimizations ---

fn (mut m Module) constant_fold() {
	for func in m.funcs {
		for blk_id in func.blocks {
			mut instrs := m.blocks[blk_id].instrs.clone()

			for val_id in instrs {
				if m.values[val_id].kind != .instruction {
					continue
				}

				instr := m.instrs[m.values[val_id].index]

				if instr.operands.len == 2 {
					lhs := m.values[instr.operands[0]]
					rhs := m.values[instr.operands[1]]

					if lhs.kind == .constant && rhs.kind == .constant {
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
							m.values[val_id].kind = .constant
							m.values[val_id].name = result.str()
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
					if val.kind == .instruction {
						instr := m.instrs[val.index]
						side_effects := instr.op in [.store, .call, .ret, .br, .jmp, .switch_,
							.unreachable, .assign]
						if !side_effects && val.uses.len == 0 {
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
	m.build_cfg()
	for mut func in m.funcs {
		if func.blocks.len == 0 {
			continue
		}
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

		mut new_blocks := []ssa.BlockID{}
		for blk in func.blocks {
			if reachable[blk] {
				new_blocks << blk
			}
		}
		func.blocks = new_blocks
	}
}

fn (mut m Module) merge_blocks() {
	mut changed := true
	for changed {
		changed = false
		m.build_cfg()

		for mut func in m.funcs {
			mut merged := map[int]bool{}

			for blk_id in func.blocks {
				if merged[blk_id] {
					continue
				}
				blk := m.blocks[blk_id]

				if blk.instrs.len > 0 {
					last_val := blk.instrs.last()
					last_instr := m.instrs[m.values[last_val].index]

					if last_instr.op == .jmp {
						target_val := last_instr.operands[0]
						target_id := m.get_block_from_val(target_val)

						if target_id != blk_id && m.blocks[target_id].preds.len == 1
							&& m.blocks[target_id].preds[0] == blk_id {
							// MERGE
							m.blocks[blk_id].instrs.delete_last()
							m.blocks[blk_id].instrs << m.blocks[target_id].instrs

							for succ_id in m.blocks[target_id].succs {
								succ := m.blocks[succ_id]
								for iv in succ.instrs {
									v := m.values[iv]
									if v.kind != .instruction {
										continue
									}
									mut ins := m.instrs[v.index]
									if ins.op == .phi {
										for i := 1; i < ins.operands.len; i += 2 {
											if ins.operands[i] == m.blocks[target_id].val_id {
												m.instrs[v.index].operands[i] = m.blocks[blk_id].val_id
											}
										}
									}
								}
							}

							merged[target_id] = true
							changed = true
						}
					}
				}
			}

			if changed {
				mut new_blks := []int{}
				for b in func.blocks {
					if !merged[b] {
						new_blks << b
					}
				}
				func.blocks = new_blks
			}
		}
	}
}
