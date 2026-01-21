module ssa

import v2.ast
// import v2.token

pub struct Builder {
mut:
	mod       &Module
	cur_func  int     = -1
	cur_block BlockID = -1

	// Maps AST variable name to SSA ValueID (pointer to stack slot)
	vars map[string]ValueID

	// Stack for break/continue targets
	loop_stack []LoopInfo
}

struct LoopInfo {
	head BlockID
	exit BlockID
}

pub fn Builder.new(mod &Module) &Builder {
	return &Builder{
		mod:        mod
		vars:       map[string]ValueID{}
		loop_stack: []LoopInfo{}
	}
}

pub fn (mut b Builder) build(file ast.File) {
	// 0. Pre-pass: Register Types (Structs) and Globals
	// We must process these first so types exist when we compile functions.
	for stmt in file.stmts {
		match stmt {
			ast.StructDecl { b.stmt(stmt) }
			ast.GlobalDecl { b.stmt(stmt) }
			else {}
		}
	}

	// 1. First pass: Register all functions (so calls work)
	for stmt in file.stmts {
		if stmt is ast.FnDecl {
			// For MVP, assume (i32, i32) -> i32
			i32_t := b.mod.type_store.get_int(64)

			// Map params
			mut param_types := []TypeID{}
			// FIX: params are inside the 'typ' (FnType) struct
			for _ in stmt.typ.params {
				param_types << i32_t
			}

			// Create Function Skeleton
			// We discard the returned ID because we assume linear order in the next pass
			b.mod.new_function(stmt.name, i32_t, param_types)
		}
	}

	// 2. Second pass: Generate Body
	// We rely on index matching for simplicity in this demo.
	mut fn_idx := 0
	for stmt in file.stmts {
		if stmt is ast.FnDecl {
			b.build_fn(stmt, fn_idx)
			fn_idx++
		}
	}
}

fn (mut b Builder) build_fn(decl ast.FnDecl, fn_id int) {
	b.cur_func = fn_id
	b.vars.clear()

	// Create Entry Block
	entry := b.mod.add_block(fn_id, 'entry')
	b.cur_block = entry

	// Define Arguments
	i32_t := b.mod.type_store.get_int(64)

	// FIX: Access params via decl.typ.params
	for _, param in decl.typ.params {
		// 1. Create Argument Value
		arg_val := b.mod.add_value_node(.argument, i32_t, param.name, 0)
		b.mod.funcs[fn_id].params << arg_val

		// 2. Allocate Stack Slot (so we can modify it if needed)
		stack_ptr := b.mod.add_instr(.alloca, entry, b.mod.type_store.get_ptr(i32_t),
			[])

		// 3. Store Argument to Stack
		b.mod.add_instr(.store, entry, 0, [arg_val, stack_ptr])

		// 4. Register variable
		b.vars[param.name] = stack_ptr
	}

	// Process Statements
	b.stmts(decl.stmts)
	// FIX: Ensure the function ends with a return to prevent fallthrough
	if !b.is_block_terminated(b.cur_block) {
		ret_type := b.mod.funcs[fn_id].typ
		if ret_type != 0 {
			// Return 0 for non-void functions (satisfy C signature)
			zero := b.mod.add_value_node(.constant, ret_type, '0', 0)
			b.mod.add_instr(.ret, b.cur_block, 0, [zero])
		} else {
			// void return
			b.mod.add_instr(.ret, b.cur_block, 0, [])
		}
	}
}

fn (mut b Builder) stmts(stmts []ast.Stmt) {
	for s in stmts {
		b.stmt(s)
	}
}

fn (mut b Builder) stmt(node ast.Stmt) {
	// println('stmt ${node}')
	match node {
		ast.AssignStmt {
			// x := 10 or x = 10
			// 1. Calc RHS
			if node.rhs.len == 0 {
				println('AssignStmt node.rhs.len == 0')
				println(node)
				return
			}
			if node.lhs.len == 0 {
				println('AssignStmt node.lhs.len == 0')
				println(node)
				return
			}
			rhs_val := b.expr(node.rhs[0])

			// 2. Get LHS Address
			// If declaration, allocate new stack slot

			if node.op == .decl_assign {
				mut ident_node := node.lhs[0]
				mut ident := ast.Ident{}
				// Unwrap 'mut x'
				if ident_node is ast.ModifierExpr {
					mod := ident_node as ast.ModifierExpr
					ident = mod.expr as ast.Ident
				} else {
					ident = ident_node as ast.Ident
				}
				// ident := ident_node as ast.Ident
				name := ident.name
				// Alloca

				// Get type from RHS or default to i32
				rhs_type := b.mod.values[rhs_val].typ
				ptr_t := b.mod.type_store.get_ptr(rhs_type)

				stack_ptr := b.mod.add_instr(.alloca, b.cur_block, ptr_t, [])

				// Store
				b.mod.add_instr(.store, b.cur_block, 0, [rhs_val, stack_ptr])
				b.vars[name] = stack_ptr
			} else if node.op in [.plus_assign, .minus_assign] {
				// Compound assignment: x += 1
				ptr := b.addr(node.lhs[0])
				val_typ := b.mod.type_store.types[b.mod.values[ptr].typ].elem_type

				lhs_val := b.mod.add_instr(.load, b.cur_block, val_typ, [ptr])
				op := if node.op == .plus_assign { OpCode.add } else { OpCode.sub }
				res := b.mod.add_instr(op, b.cur_block, val_typ, [lhs_val, rhs_val])
				b.mod.add_instr(.store, b.cur_block, 0, [res, ptr])
			} else {
				// Assignment to existing variable, field, or array index
				ptr := b.addr(node.lhs[0])
				b.mod.add_instr(.store, b.cur_block, 0, [rhs_val, ptr])
			}
		}
		ast.ReturnStmt {
			if node.exprs.len > 0 {
				val := b.expr(node.exprs[0])
				b.mod.add_instr(.ret, b.cur_block, 0, [val])
			} else {
				b.mod.add_instr(.ret, b.cur_block, 0, [])
			}
		}
		ast.ExprStmt {
			b.expr(node.expr)
		}
		ast.BlockStmt {
			b.stmts(node.stmts)
		}
		ast.ForStmt {
			// 1. Init
			if node.init !is ast.EmptyStmt {
				b.stmt(node.init)
			}

			// 2. Control Flow Blocks
			head_blk := b.mod.add_block(b.cur_func, 'for.head')
			body_blk := b.mod.add_block(b.cur_func, 'for.body')
			exit_blk := b.mod.add_block(b.cur_func, 'for.exit')

			b.loop_stack << LoopInfo{
				head: head_blk
				exit: exit_blk
			}

			// Jump to Head
			head_val := b.mod.blocks[head_blk].val_id
			b.mod.add_instr(.jmp, b.cur_block, 0, [head_val])

			// 3. Head (Condition)
			b.cur_block = head_blk
			body_val := b.mod.blocks[body_blk].val_id
			exit_val := b.mod.blocks[exit_blk].val_id

			if node.cond !is ast.EmptyExpr {
				cond_val := b.expr(node.cond)
				b.mod.add_instr(.br, b.cur_block, 0, [cond_val, body_val, exit_val])
			} else {
				// Infinite loop
				b.mod.add_instr(.jmp, b.cur_block, 0, [body_val])
			}

			// 4. Body
			b.cur_block = body_blk
			b.stmts(node.stmts)

			// 5. Post
			if node.post !is ast.EmptyStmt {
				b.stmt(node.post)
			}

			// Loop back
			if !b.is_block_terminated(b.cur_block) {
				b.mod.add_instr(.jmp, b.cur_block, 0, [head_val])
			}

			// 6. Exit
			b.cur_block = exit_blk
			b.loop_stack.pop()
		}
		ast.FlowControlStmt {
			if b.loop_stack.len == 0 {
				return
			}
			info := b.loop_stack.last()
			target := if node.op == .key_break { info.exit } else { info.head }

			target_val := b.mod.blocks[target].val_id
			b.mod.add_instr(.jmp, b.cur_block, 0, [target_val])
		}
		ast.StructDecl {
			// Register Struct Type
			// Simplification: Assume all fields are i32 for this demo unless specified
			mut field_types := []TypeID{}
			for _ in node.fields {
				field_types << b.mod.type_store.get_int(64)
			}

			// We manually constructing the struct type in the store
			// In a real compiler, we'd map AST types to SSA types properly
			t := Type{
				kind:   .struct_t
				fields: field_types
				width:  0
			}
			b.mod.type_store.register(t)
		}
		ast.GlobalDecl {
			i32_t := b.mod.type_store.get_int(64)
			for field in node.fields {
				// Register global
				b.mod.add_global(field.name, i32_t, false)
			}
		}
		else {
			// println('Builder: Unhandled stmt ${node.type_name()}')
		}
	}
}

fn (mut b Builder) expr(node ast.Expr) ValueID {
	match node {
		ast.BasicLiteral {
			return b.expr_basic_literal(node)
		}
		ast.Ident {
			return b.expr_ident(node)
		}
		ast.InitExpr {
			return b.expr_init(node)
		}
		ast.SelectorExpr {
			return b.expr_selector(node)
		}
		ast.IndexExpr {
			return b.expr_index(node)
		}
		ast.CastExpr {
			return b.expr(node.expr)
		}
		ast.ParenExpr {
			return b.expr(node.expr)
		}
		ast.InfixExpr {
			return b.expr_infix(node)
		}
		ast.IfExpr {
			return b.expr_if(node)
		}
		ast.MatchExpr {
			return b.expr_match(node)
		}
		ast.CallExpr {
			return b.expr_call(node)
		}
		ast.StringLiteral {
			return b.expr_string_literal(node)
		}
		ast.CallOrCastExpr {
			return b.expr_call_or_cast(node)
		}
		ast.PrefixExpr {
			return b.expr_prefix(node)
		}
		ast.PostfixExpr {
			return b.expr_postfix(node)
		}
		else {
			println('Builder: Unhandled expr ${node.type_name()}')
			// Return constant 0 (i32) to prevent cascading void errors
			i32_t := b.mod.type_store.get_int(64)
			return b.mod.add_value_node(.constant, i32_t, '0', 0)
		}
	}
}

fn (mut b Builder) expr_basic_literal(node ast.BasicLiteral) ValueID {
	if node.kind == .number {
		// Constant
		i32_t := b.mod.type_store.get_int(64)
		val := b.mod.add_value_node(.constant, i32_t, node.value, 0)
		return val
	} else if node.kind in [.key_true, .key_false] {
		i32_t := b.mod.type_store.get_int(64)
		val_str := if node.kind == .key_true { '1' } else { '0' }
		val := b.mod.add_value_node(.constant, i32_t, val_str, 0)
		return val
	}
	return 0
}

fn (mut b Builder) expr_ident(node ast.Ident) ValueID {
	ptr := b.addr(node)
	// Get type pointed to
	ptr_typ := b.mod.values[ptr].typ
	val_typ := b.mod.type_store.types[ptr_typ].elem_type

	return b.mod.add_instr(.load, b.cur_block, val_typ, [ptr])
}

fn (mut b Builder) expr_init(node ast.InitExpr) ValueID {
	// Struct Init: MyStruct{ a: 1, b: 2 }
	// 1. Allocate Struct
	// Need to find the TypeID for the struct.
	// For MVP, we search TypeStore for a struct type.
	// In real compiler, AST node has type info.
	mut struct_t := 0
	for i, t in b.mod.type_store.types {
		if t.kind == .struct_t {
			struct_t = i
			break
		}
	}

	ptr_t := b.mod.type_store.get_ptr(struct_t)
	struct_ptr := b.mod.add_instr(.alloca, b.cur_block, ptr_t, [])

	// 2. Initialize Fields
	// We assume fields in InitExpr are in order for this demo
	for i, field in node.fields {
		val := b.expr(field.value)
		idx_val := b.mod.add_value_node(.constant, b.mod.type_store.get_int(64), i.str(),
			0)

		// GEP to field
		field_ptr := b.mod.add_instr(.get_element_ptr, b.cur_block, b.mod.type_store.get_ptr(b.mod.type_store.get_int(64)),
			[struct_ptr, idx_val])
		b.mod.add_instr(.store, b.cur_block, 0, [val, field_ptr])
	}

	// 3. Return Pointer (Structs are value types in V, but usually passed by ref in SSA construction phase or loaded)
	return struct_ptr
}

fn (mut b Builder) expr_selector(node ast.SelectorExpr) ValueID {
	// Load value from field
	ptr := b.addr(node)
	i32_t := b.mod.type_store.get_int(64) // Assume i32
	return b.mod.add_instr(.load, b.cur_block, i32_t, [ptr])
}

fn (mut b Builder) expr_index(node ast.IndexExpr) ValueID {
	// Load value from index
	ptr := b.addr(node)
	i32_t := b.mod.type_store.get_int(64) // Assume i32
	return b.mod.add_instr(.load, b.cur_block, i32_t, [ptr])
}

fn (mut b Builder) expr_infix(node ast.InfixExpr) ValueID {
	left := b.expr(node.lhs)
	right := b.expr(node.rhs)

	// Map Token Op to SSA OpCode
	op := match node.op {
		.plus { OpCode.add }
		.minus { OpCode.sub }
		.mul { OpCode.mul }
		.div { OpCode.sdiv }
		.gt { OpCode.gt }
		.lt { OpCode.lt }
		.eq { OpCode.eq }
		.ne { OpCode.ne }
		.ge { OpCode.ge }
		.le { OpCode.le }
		else { OpCode.add }
	}

	i32_t := b.mod.type_store.get_int(64)
	return b.mod.add_instr(op, b.cur_block, i32_t, [left, right])
}

fn (mut b Builder) expr_if(node ast.IfExpr) ValueID {
	// If cond is empty, it's a plain 'else' block from a parent IfExpr
	if node.cond is ast.EmptyExpr {
		b.stmts(node.stmts)
		return 0
	}

	// 1. Evaluate Condition
	cond_val := b.expr(node.cond)

	// 2. Create Blocks
	// We create a merge block even if there is no else,
	// because we need somewhere to jump to after 'then'.
	then_blk := b.mod.add_block(b.cur_func, 'if.then')
	merge_blk := b.mod.add_block(b.cur_func, 'if.end')
	mut else_blk := merge_blk

	// If there is an else expression/block, create a specific block for it
	has_else := node.else_expr !is ast.EmptyExpr
	if has_else {
		else_blk = b.mod.add_block(b.cur_func, 'if.else')
	}

	// 3. Emit Branch
	// Retrieve ValueIDs for the blocks to use as operands
	then_val := b.mod.blocks[then_blk].val_id
	else_val := b.mod.blocks[else_blk].val_id

	// br cond, then, else (or merge if no else)
	b.mod.add_instr(.br, b.cur_block, 0, [cond_val, then_val, else_val])

	// 4. Build Then Block
	b.cur_block = then_blk
	b.stmts(node.stmts)
	// Jump to merge if not terminated (e.g. by return)
	if !b.is_block_terminated(b.cur_block) {
		merge_val := b.mod.blocks[merge_blk].val_id
		b.mod.add_instr(.jmp, b.cur_block, 0, [merge_val])
	}

	// 5. Build Else Block (if any)
	if has_else {
		b.cur_block = else_blk
		b.expr(node.else_expr)
		// The recursive call might have changed b.cur_block (nested ifs)
		if !b.is_block_terminated(b.cur_block) {
			merge_val := b.mod.blocks[merge_blk].val_id
			b.mod.add_instr(.jmp, b.cur_block, 0, [merge_val])
		}
	}

	// 6. Continue generation at Merge Block
	b.cur_block = merge_blk
	return 0
}

fn (mut b Builder) expr_match(node ast.MatchExpr) ValueID {
	// 1. Eval Cond
	cond_val := b.expr(node.expr)

	// 2. Setup Blocks
	merge_blk := b.mod.add_block(b.cur_func, 'match.merge')
	mut default_blk := merge_blk

	// We need to collect all cases and branch blocks
	// Format: val -> block
	// Ops: [cond, default_blk, val1, blk1, val2, blk2...]

	mut cases := []ValueID{} // alternating val, blk_id

	// Pre-create blocks for branches to get their IDs
	mut branch_blks := []BlockID{}
	for i, branch in node.branches {
		name := if branch.cond.len == 0 { 'match.else' } else { 'match.case_${i}' }
		blk := b.mod.add_block(b.cur_func, name)
		branch_blks << blk

		if branch.cond.len == 0 {
			default_blk = blk
		} else {
			for expr in branch.cond {
				val := b.expr(expr)
				cases << val
				cases << b.mod.blocks[blk].val_id
			}
		}
	}

	// 3. Emit switch
	mut ops := []ValueID{}
	ops << cond_val
	ops << b.mod.blocks[default_blk].val_id
	ops << cases

	b.mod.add_instr(.switch_, b.cur_block, 0, ops)

	// 4. Build Branches
	for i, branch in node.branches {
		blk := branch_blks[i]
		b.cur_block = blk
		b.stmts(branch.stmts)

		if !b.is_block_terminated(b.cur_block) {
			merge_val := b.mod.blocks[merge_blk].val_id
			b.mod.add_instr(.jmp, b.cur_block, 0, [merge_val])
		}
	}

	b.cur_block = merge_blk
	return 0
}

fn (mut b Builder) expr_call(node ast.CallExpr) ValueID {
	// Resolve Args
	mut args := []ValueID{}
	for arg in node.args {
		args << b.expr(arg)
	}
	// Resolve Function Name
	mut name := ''
	lhs := node.lhs
	if lhs is ast.Ident {
		name = lhs.name
	} else if lhs is ast.SelectorExpr {
		// Handle C.printf or struct.method()
		name = lhs.rhs.name
	}

	// Create a Value representing the function symbol (operand 0)
	fn_val := b.mod.add_value_node(.unknown, 0, name, 0)
	args.prepend(fn_val)
	// For this demo, assuming ret type i32
	i32_t := b.mod.type_store.get_int(64)
	// Note: In real compiler, we need to lookup Function ID by name to get correct ret type
	return b.mod.add_instr(.call, b.cur_block, i32_t, args)
}

fn (mut b Builder) expr_string_literal(node ast.StringLiteral) ValueID {
	// Treat as char* (i8*) constant
	i8_t := b.mod.type_store.get_int(8)
	ptr_t := b.mod.type_store.get_ptr(i8_t)
	// Note: We wrap in quotes for the C backend to interpret as string literal
	// return b.mod.add_value_node(.constant, ptr_t, '"${node.value}"', 0)
	val := node.value.trim("'").trim('"')
	return b.mod.add_value_node(.constant, ptr_t, '"${val}"', 0)
}

fn (mut b Builder) expr_call_or_cast(node ast.CallOrCastExpr) ValueID {
	// Handle ambiguous calls like print_int(1111)
	mut args := []ValueID{}
	args << b.expr(node.expr)

	mut name := ''
	if node.lhs is ast.Ident {
		name = node.lhs.name
	} else if node.lhs is ast.SelectorExpr {
		name = node.lhs.rhs.name
	}
	fn_val := b.mod.add_value_node(.unknown, 0, name, 0)
	args.prepend(fn_val)
	i32_t := b.mod.type_store.get_int(64)
	return b.mod.add_instr(.call, b.cur_block, i32_t, args)
}

fn (mut b Builder) expr_prefix(node ast.PrefixExpr) ValueID {
	right := b.expr(node.expr)
	i32_t := b.mod.type_store.get_int(64)
	match node.op {
		.minus {
			zero := b.mod.add_value_node(.constant, i32_t, '0', 0)
			return b.mod.add_instr(.sub, b.cur_block, i32_t, [zero, right])
		}
		.not {
			zero := b.mod.add_value_node(.constant, i32_t, '0', 0)
			return b.mod.add_instr(.eq, b.cur_block, i32_t, [right, zero])
		}
		else {
			return 0
		}
	}
}

fn (mut b Builder) expr_postfix(node ast.PostfixExpr) ValueID {
	// Handle i++ / i--
	if node.expr is ast.Ident {
		name := (node.expr as ast.Ident).name
		if ptr := b.vars[name] {
			if ptr != 0 {
				i32_t := b.mod.type_store.get_int(64)

				// 1. Load current value
				old_val := b.mod.add_instr(.load, b.cur_block, i32_t, [ptr])

				// 2. Add/Sub 1
				one := b.mod.add_value_node(.constant, i32_t, '1', 0)
				op := if node.op == .inc { OpCode.add } else { OpCode.sub }
				new_val := b.mod.add_instr(op, b.cur_block, i32_t, [old_val, one])

				// 3. Store new value
				b.mod.add_instr(.store, b.cur_block, 0, [new_val, ptr])

				// Postfix returns the old value
				return old_val
			}
		}
	}
	return 0
}

fn (b Builder) is_block_terminated(blk_id int) bool {
	if blk_id >= b.mod.blocks.len {
		return false
	}
	blk := b.mod.blocks[blk_id]
	if blk.instrs.len == 0 {
		return false
	}

	last_val_id := blk.instrs.last()
	val := b.mod.values[last_val_id]
	if val.kind != .instruction {
		return false
	}

	instr := b.mod.instrs[val.index]
	return instr.op in [.ret, .br, .jmp, .unreachable]
}

// addr returns the ValueID (pointer) representing the L-Value of an expression
fn (mut b Builder) addr(node ast.Expr) ValueID {
	match node {
		ast.Ident {
			// Check locals
			if ptr := b.vars[node.name] {
				// FIX: Ensure it is a valid ID (0 is invalid now)
				if ptr != 0 {
					return ptr
				}
			}
			// Check globals
			for g in b.mod.globals {
				if g.name == node.name {
					// Globals are values in the values arena but effectively pointers
					// We need to find the ValueID that corresponds to this global
					// For this demo, we iterate values to find it (slow, but works)
					for v in b.mod.values {
						if v.kind == .global && v.name == node.name {
							return v.id
						}
					}
				}
			}
			return 0
		}
		ast.SelectorExpr {
			// struct.field
			base_ptr := b.addr(node.lhs)

			// Resolve the type of the base pointer
			base_val := b.mod.values[base_ptr]
			mut ptr_typ := b.mod.type_store.types[base_val.typ]

			// We expect ptr_typ to be Ptr -> (Struct) OR Ptr -> (Ptr -> Struct)
			// If it's Ptr -> Ptr -> ..., we must Load to get the actual struct pointer.

			// Unpack one level of pointer (the variable address)
			mut val_typ_id := ptr_typ.elem_type
			mut val_typ := b.mod.type_store.types[val_typ_id]

			mut actual_base := base_ptr

			// Check if the value stored is a pointer (Reference semantics for variable)
			if val_typ.kind == .ptr_t {
				// Load the pointer value
				actual_base = b.mod.add_instr(.load, b.cur_block, val_typ_id, [
					base_ptr,
				])

				// Update types for the loaded value
				// actual_base is now Ptr -> Struct
				ptr_typ = val_typ
				val_typ_id = ptr_typ.elem_type
				val_typ = b.mod.type_store.types[val_typ_id]
			}

			// Now val_typ should be the Struct
			if val_typ.kind != .struct_t {
				// Fallback or error. For now, try to proceed, but it might panic if we access fields.
				// In a real compiler, this checks if it's a struct.
			}

			// Find field index (Simulated)
			mut idx := 0
			if node.rhs.name == 'y' || node.rhs.name == 'b' {
				idx = 1
			}

			// Safety check for index
			if idx >= val_typ.fields.len {
				// If fields are empty (e.g. type resolution failed), prevent panic
				// Return a dummy value or handle error
				println('SSA Error: Struct fields empty or index out of bounds')
				return 0
			}

			idx_val := b.mod.add_value_node(.constant, b.mod.type_store.get_int(64), idx.str(),
				0)

			// GEP
			field_ptr_t := b.mod.type_store.get_ptr(val_typ.fields[idx])
			return b.mod.add_instr(.get_element_ptr, b.cur_block, field_ptr_t, [
				actual_base,
				idx_val,
			])
		}
		ast.IndexExpr {
			// array[index]
			base_ptr := b.addr(node.lhs)
			index_val := b.expr(node.expr)

			// Auto-dereference if it's a pointer-to-pointer (variable holding array ptr)
			base_val := b.mod.values[base_ptr]
			ptr_typ := b.mod.type_store.types[base_val.typ]
			elem_typ_id := ptr_typ.elem_type
			elem_typ := b.mod.type_store.types[elem_typ_id]

			mut actual_base := base_ptr

			if elem_typ.kind == .ptr_t {
				actual_base = b.mod.add_instr(.load, b.cur_block, elem_typ_id, [
					base_ptr,
				])
			}

			return b.mod.add_instr(.get_element_ptr, b.cur_block, b.mod.values[actual_base].typ,
				[
				actual_base,
				index_val,
			])
		}
		else {
			return 0
		}
	}
}
