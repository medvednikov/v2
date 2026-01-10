module ssa

import v2.ast
import v2.token

pub struct Builder {
mut:
	mod       &Module
	cur_func  int      = -1
	cur_block BlockID  = -1
	
	// Maps AST variable name to SSA ValueID (pointer to stack slot)
	vars      map[string]ValueID
}

pub fn Builder.new(mod &Module) &Builder {
	return &Builder{
		mod: mod
		vars: map[string]ValueID{}
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
			for _ in stmt.typ.params { param_types << i32_t }
			
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
		stack_ptr := b.mod.add_instr(.alloca, entry, b.mod.type_store.get_ptr(i32_t), [])
		
		// 3. Store Argument to Stack
		b.mod.add_instr(.store, entry, 0, [arg_val, stack_ptr])
		
		// 4. Register variable
		b.vars[param.name] = stack_ptr
	}

	// Process Statements
	b.stmts(decl.stmts)
}

fn (mut b Builder) stmts(stmts []ast.Stmt) {
	for s in stmts { b.stmt(s) }
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
				else { OpCode.add }
			}
			
			i32_t := b.mod.type_store.get_int(32)
			return b.mod.add_instr(op, b.cur_block, i32_t, [left, right])
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
		else {
			// println('Builder: Unhandled expr ${node.type_name()}')
			return 0
		}
	}
}
