module ssa

import v2.ast
import v2.token

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
	// 1. First pass: Register all functions (so calls work)
	for stmt in file.stmts {
		if stmt is ast.FnDecl {
			// For MVP, assume (i32, i32) -> i32
			i32_t := b.mod.type_store.get_int(32)

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
	i32_t := b.mod.type_store.get_int(32)

	// FIX: Access params via decl.typ.params
	for i, param in decl.typ.params {
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
}

fn (mut b Builder) stmts(stmts []ast.Stmt) {
	for s in stmts {
		b.stmt(s)
	}
}

fn (mut b Builder) stmt(node ast.Stmt) {
	match node {
		ast.AssignStmt {
			// x := 10 or x = 10
			// 1. Calc RHS
			rhs_val := b.expr(node.rhs[0])

			// 2. Get Name
			ident := node.lhs[0] as ast.Ident
			name := ident.name

			if node.op == .decl_assign {
				// Alloca
				i32_t := b.mod.type_store.get_int(32)
				ptr_t := b.mod.type_store.get_ptr(i32_t)
				stack_ptr := b.mod.add_instr(.alloca, b.cur_block, ptr_t, [])

				// Store
				b.mod.add_instr(.store, b.cur_block, 0, [rhs_val, stack_ptr])
				b.vars[name] = stack_ptr
			} else {
				// Assignment to existing
				stack_ptr := b.vars[name]
				b.mod.add_instr(.store, b.cur_block, 0, [rhs_val, stack_ptr])
			}
		}
		ast.ReturnStmt {
			val := b.expr(node.exprs[0])
			b.mod.add_instr(.ret, b.cur_block, 0, [val])
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
		}
		ast.StructDecl {
			// Register Struct Type
			// Simplification: Assume all fields are i32 for this demo unless specified
			mut field_types := []TypeID{}
			for _ in node.fields {
				field_types << b.mod.type_store.get_int(32)
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
			i32_t := b.mod.type_store.get_int(32)
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
			if node.kind == .number {
				// Constant
				i32_t := b.mod.type_store.get_int(32)
				val := b.mod.add_value_node(.constant, i32_t, node.value, 0)
				return val
			}
			return 0
		}
		ast.Ident {
			// Load from variable
			stack_ptr := b.vars[node.name]
			i32_t := b.mod.type_store.get_int(32)
			return b.mod.add_instr(.load, b.cur_block, i32_t, [stack_ptr])
		}
		ast.InfixExpr {
			left := b.expr(node.lhs)
			right := b.expr(node.rhs)

			// Map Token Op to SSA OpCode
			op := match node.op {
				.plus { OpCode.add }
				.minus { OpCode.sub }
				.mul { OpCode.mul }
				.div { OpCode.sdiv }
				.gt, .lt, .eq, .ne, .ge, .le { OpCode.icmp }
				else { OpCode.add }
			}

			i32_t := b.mod.type_store.get_int(32)
			return b.mod.add_instr(op, b.cur_block, i32_t, [left, right])
		}
		ast.IfExpr {
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
		ast.CallExpr {
			// Resolve Args
			mut args := []ValueID{}
			for arg in node.args {
				args << b.expr(arg)
			}
			// Resolve Function Name
			name := (node.lhs as ast.Ident).name
			// For this demo, assuming ret type i32
			i32_t := b.mod.type_store.get_int(32)
			// Note: In real compiler, we need to lookup Function ID by name to get correct ret type
			return b.mod.add_instr(.call, b.cur_block, i32_t, args)
		}
		ast.StringLiteral {
			// Treat as char* (i8*) constant
			i8_t := b.mod.type_store.get_int(8)
			ptr_t := b.mod.type_store.get_ptr(i8_t)
			// Note: We wrap in quotes for the C backend to interpret as string literal
			return b.mod.add_value_node(.constant, ptr_t, '"${node.value}"', 0)
		}
		ast.PrefixExpr {
			right := b.expr(node.expr)
			i32_t := b.mod.type_store.get_int(32)
			match node.op {
				.minus {
					zero := b.mod.add_value_node(.constant, i32_t, '0', 0)
					return b.mod.add_instr(.sub, b.cur_block, i32_t, [zero, right])
				}
				.not {
					zero := b.mod.add_value_node(.constant, i32_t, '0', 0)
					return b.mod.add_instr(.icmp, b.cur_block, i32_t, [right, zero])
				}
				else {
					return 0
				}
			}
		}
		ast.PostfixExpr {
			// Handle i++ / i--
			if node.expr is ast.Ident {
				name := (node.expr as ast.Ident).name
				if ptr := b.vars[name] {
					i32_t := b.mod.type_store.get_int(32)

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
			return 0
		}
		else {
			// println('Builder: Unhandled expr ${node.type_name()}')
			return 0
		}
	}
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
