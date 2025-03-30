module racedetector

import v.pref
import v.ast
import v.errors
import v.token
// import v.util

// Basically the only goal of this pass is to throw an error if a field/variable is not `shared`
// but is accessed in multiple threads/coroutines.
pub struct RaceDetector {
pub mut:
	pref &pref.Preferences
	// index &IndexState
	table  &ast.Table = unsafe { nil }
	files  []&ast.File
	file   &ast.File // current file
	errors []errors.Error
}

pub fn (mut r RaceDetector) run() {
	// Ensure table is initialized if this is the entry point
	// println(r.table.fns_called_concurrently)
	for file in r.files {
		r.file = file
		// if !file.path.contains('race.v') && !file.path.contains('concurrent') {
		// 	continue
		// }
		// println('Checking file: ${file.path}')
		for stmt in file.stmts {
			r.check_stmt_for_concurrency(stmt)
		}
	}
}

// Check if a top-level statement (like FnDecl) needs race detection
pub fn (mut r RaceDetector) check_stmt_for_concurrency(stmt ast.Stmt) {
	match stmt {
		ast.FnDecl {
			// Only check functions that are known to be called concurrently
			if r.table.fn_is_called_concurrently(stmt) {
				// println('Checking concurrent fn: ${stmt.name} in ${r.file.path}')
				r.fn_decl(stmt)
			}
		}
		// Add other top-level statements if necessary (e.g., global initializers?)
		else {}
	}
}

// Only runs on functions that are known to be called concurrently
pub fn (mut r RaceDetector) fn_decl(node ast.FnDecl) {
	for stmt in node.stmts {
		r.stmt(stmt)
	}
	// println('!!!fn ${node.name}')
}

// Process statements within a concurrent function
pub fn (mut r RaceDetector) stmt(stmt ast.Stmt) {
	match stmt {
		ast.ExprStmt {
			// This handles expressions used as statements, including IfExpr, MatchExpr, GoExpr, etc.
			r.expr(stmt.expr)
		}
		ast.Block {
			for s in stmt.stmts {
				r.stmt(s)
			}
		}
		ast.AssignStmt { // Handles `var = val`, `arr[idx] = val`, `obj.field = val`
			r.assign_stmt(stmt)
		}
		ast.ForStmt { // Check conditions/bodies of loops
			r.expr(stmt.cond)
			for s in stmt.stmts {
				r.stmt(s)
			}
		}
		ast.ForInStmt {
			r.expr(stmt.cond) // Check the collection being iterated
			// Check the expressions inside the loop body
			for s in stmt.stmts {
				r.stmt(s)
			}
		}
		ast.ForCStmt {
			if stmt.has_init {
				r.stmt(stmt.init)
			}
			if stmt.has_cond {
				r.expr(stmt.cond)
			}
			if stmt.has_inc {
				r.stmt(stmt.inc)
			}
			for s in stmt.stmts {
				r.stmt(s)
			}
		}
		ast.Return { // Check expressions being returned
			for expr in stmt.exprs {
				r.expr(expr)
			}
		}
		ast.DeferStmt { // Check deferred statements
			for s in stmt.stmts {
				r.stmt(s)
			}
		}
		// ast.IfExpr, ast.MatchExpr, ast.GoExpr, ast.SpawnExpr, ast.LockExpr
		// are handled via ExprStmt -> r.expr()
		ast.AssertStmt {
			r.expr(stmt.expr)
			// r.expr(stmt.extra) // Check extra message expr if necessary
		}
		// ... other Stmt variants
		else {}
	}
}

// Process expressions
pub fn (mut r RaceDetector) expr(expr ast.Expr) {
	// Recursively check sub-expressions where necessary
	match expr {
		ast.InfixExpr {
			r.infix_expr(expr)
			// Also check operands
			r.expr(expr.left)
			r.expr(expr.right)
		}
		ast.PrefixExpr {
			r.expr(expr.right)
		}
		ast.PostfixExpr {
			r.expr(expr.expr)
		}
		ast.CallExpr {
			r.expr(expr.left) // Check the receiver/function expression
			for arg in expr.args {
				r.expr(arg.expr) // Check arguments
			}
			// Check or block if present
			if expr.or_block.kind != .absent {
				for s in expr.or_block.stmts {
					r.stmt(s)
				}
			}
		}
		ast.IndexExpr {
			// An index expression itself is a read, but could be part of a write (handled in assign_stmt)
			// Check the expression being indexed and the index itself for potential races
			r.expr(expr.left)
			r.expr(expr.index)
			// Check or block if present
			if expr.or_expr.kind != .absent {
				for s in expr.or_expr.stmts {
					r.stmt(s)
				}
			}
		}
		ast.SelectorExpr {
			// A selector itself is often just access, but could be part of a write
			r.expr(expr.expr) // Check the base expression
			// Check or block if present
			if expr.or_block.kind != .absent {
				for s in expr.or_block.stmts {
					r.stmt(s)
				}
			}
		}
		ast.CastExpr {
			r.expr(expr.expr)
			if expr.has_arg {
				r.expr(expr.arg)
			}
		}
		ast.ParExpr {
			r.expr(expr.expr)
		}
		ast.IfExpr { // Check conditions/bodies of if/else if/else
			// Note: This is an If *Expression*
			for branch in expr.branches {
				r.expr(branch.cond)
				for s in branch.stmts { // Check statements in branch body
					r.stmt(s)
				}
			}
		}
		ast.MatchExpr { // Check condition/bodies of match
			// Note: This is a Match *Expression*
			r.expr(expr.cond)
			for branch in expr.branches {
				// Check expressions on the left side of the branch if needed
				for branch_expr in branch.exprs {
					r.expr(branch_expr)
				}
				// Check statements in branch body
				for s in branch.stmts {
					r.stmt(s)
				}
			}
		}
		ast.LockExpr { // Check expressions being locked and body
			for locked_expr in expr.lockeds {
				r.expr(locked_expr)
			}
			for s in expr.stmts {
				r.stmt(s)
			}
		}
		// GoExpr and SpawnExpr are handled via ExprStmt calling this function,
		// which will then likely hit the CallExpr case for the underlying call.
		ast.GoExpr {
			r.expr(ast.Expr(expr.call_expr))
		}
		ast.SpawnExpr {
			r.expr(ast.Expr(expr.call_expr))
		}
		ast.ArrayInit {
			for item_expr in expr.exprs {
				r.expr(item_expr)
			}
			// Check len/cap/init expressions if they exist
			if expr.has_len {
				r.expr(expr.len_expr)
			}
			if expr.has_cap {
				r.expr(expr.cap_expr)
			}
			if expr.has_init {
				r.expr(expr.init_expr)
			}
		}
		ast.MapInit {
			for key_expr in expr.keys {
				r.expr(key_expr)
			}
			for val_expr in expr.vals {
				r.expr(val_expr)
			}
			if expr.has_update_expr {
				r.expr(expr.update_expr)
			}
		}
		// Add other relevant expression types if they can contain sub-expressions
		// or have side effects relevant to race detection.
		else {}
	}
}

// Handles assignments like `var = val`, `arr[idx] = val`, `obj.field = val`
pub fn (mut r RaceDetector) assign_stmt(node ast.AssignStmt) {
	// Check right-hand side expressions for potential issues first
	for right_expr in node.right {
		r.expr(right_expr)
	}

	// Check left-hand side for writes that might need `shared`
	for left_expr in node.left {
		match left_expr {
			ast.IndexExpr { // Potential array/map set: `arr[i] = ...` or `m[k] = ...`
				idx_expr := left_expr
				// Get the type of the variable being indexed (e.g., type of `arr` or `m`)
				left_type := idx_expr.left_type // Type of the collection (array/map)
				left_final_sym := r.table.sym(left_type)

				// Check if it's an array type (dynamic or fixed)
				if left_final_sym.kind == .array || left_final_sym.kind == .array_fixed {
					// It's an array set operation
					r.array_set(idx_expr) // Pass the IndexExpr itself
				}
				// Potential check for maps if needed later:
				// else if left_final_sym.kind == .map {
				// 	r.map_set(idx_expr) // Need to implement map_set if desired
				// }

				// Also check the expressions used *within* the IndexExpr itself (the array expr and the index expr)
				// These were likely already checked by r.expr() if the IndexExpr was part of RHS,
				// but doesn't hurt to check again if it's only on LHS.
				r.expr(idx_expr.left)
				r.expr(idx_expr.index)
			}
			ast.SelectorExpr { // Potential field set: `obj.field = ...`
				sel_expr := left_expr
				// A field set might require the *field* itself to be shared or atomic,
				// OR the containing struct instance if methods modify non-shared fields.
				// This requires more sophisticated analysis (checking field attributes, receiver type).
				// For now, let's focus on arrays and check the base expression recursively.
				r.expr(sel_expr.expr) // Check the expression yielding the object/struct

				// TODO: Add check for non-shared field modification if needed later
				// field_sym := r.table.find_field(sel_expr.expr_type, sel_expr.field_name)
				// if field_sym.share != .shared_t { ... error ... }
			}
			ast.Ident { // Simple variable assignment: `x = ...`
				// Assigning *to* a simple local variable usually doesn't cause a data race
				// on *that variable* directly. Races occur when shared memory (like array elements,
				// struct fields accessed via shared pointers/references, or captured shared vars)
				// is accessed concurrently.
				// We don't flag `x = ...` itself, but rely on checks where `x` (if it holds
				// a non-shared reference to shared data) is *used* later (e.g., x[i]=, x.field=).
			}
			// Handle other potential lvalues if necessary
			else {
				// Recursively check other complex lvalues
				r.expr(left_expr)
			}
		}
	}
}

pub fn (mut r RaceDetector) infix_expr(node ast.InfixExpr) {
	left_type := node.left_type
	left_final_sym := r.table.sym(left_type)

	match node.op {
		.left_shift { // Append: `arr << val`
			if left_final_sym.kind == .array {
				r.array_append(node)
			}
		}
		// Other infix operators usually don't modify the left operand directly in a racey way
		// (e.g., `a + b`). Assignment operators (`+=`, `-=`) are handled by `assign_stmt`.
		else {}
	}
}

// Helper to find the base identifier or selector expression
fn (mut r RaceDetector) find_base_expr(start_expr ast.Expr) ast.Expr {
	mut current_expr := start_expr
	// Loop to peel off IndexExpr layers
	for {
		mut temp_expr := current_expr
		// Use `mut` for smartcasting mutable `temp_expr`
		if mut temp_expr is ast.IndexExpr {
			current_expr = temp_expr.left
		} else {
			break // Not an IndexExpr, stop peeling
		}
	}
	// Now current_expr holds the expression that is not an IndexExpr
	// It could be Ident, SelectorExpr, CallExpr, etc.
	return current_expr
}

// Check for `arr << elem`
pub fn (mut r RaceDetector) array_append(node ast.InfixExpr) {
	array_expr := node.left // The expression resulting in the array (e.g., `arr`, `obj.data`, `get_arr()[i]`)
	array_type := node.left_type // The type of the array itself

	// If the array type itself is marked shared, assume user knows best (for now)
	if array_type.share() == .shared_t {
		return
	}

	// Find the ultimate base expression (Ident or SelectorExpr ideally)
	base_expr := r.find_base_expr(array_expr)

	// Determine *what* should be shared based on the base expression
	mut should_be_shared := ''
	// Use `mut` for smartcasting the non-mutable `base_expr`
	if base_expr is ast.SelectorExpr {
		// Case: base is `obj.data` (from `obj.data << val` or `obj.data[i] << val`)
		sel := base_expr // base_expr is now known to be SelectorExpr
		receiver_sym := r.table.sym(sel.expr_type) // Type of `obj`
		if receiver_sym.name != '' {
			should_be_shared = '${receiver_sym.name}.${sel.field_name}'
		} else {
			should_be_shared = 'field `${sel.field_name}`' // Fallback
		}
	} else if base_expr is ast.Ident {
		// Case: base is `arr` (from `arr << value` or `arr[i] << value`)
		ident := base_expr // base_expr is now known to be Ident
		should_be_shared = ident.name
	} else {
		// Complex case like `get_array()[i] << value`.
		// Base expr is CallExpr or something else. Use generic message.
		should_be_shared = 'array accessed via complex expression'
	}

	r.error_if_not_shared(array_type, node.pos, should_be_shared)
}

// Check for `arr[i] = val`
pub fn (mut r RaceDetector) array_set(node ast.IndexExpr) {
	array_expr := node.left // The expression yielding the array (e.g., `arr`, `obj.data`)
	array_type := node.left_type // The type of the array itself

	// If the array type itself is marked shared, assume user knows best (for now)
	if array_type.share() == .shared_t {
		return
	}

	// Find the ultimate base expression (Ident or SelectorExpr ideally)
	base_expr := r.find_base_expr(array_expr)

	// Determine *what* should be shared based on the base expression
	mut should_be_shared := ''
	// Use `mut` for smartcasting the non-mutable `base_expr`
	if base_expr is ast.SelectorExpr {
		// Case: `obj.data[i] = value` -> base is `obj.data`
		sel := base_expr // base_expr is now known to be SelectorExpr
		receiver_sym := r.table.sym(sel.expr_type) // Type of `obj`
		if receiver_sym.name != '' {
			should_be_shared = '${receiver_sym.name}.${sel.field_name}'
		} else {
			should_be_shared = 'field `${sel.field_name}`' // Fallback
		}
	} else if base_expr is ast.Ident {
		// Case: `arr[i] = value` -> base is `arr`
		ident := base_expr // base_expr is now known to be Ident
		should_be_shared = ident.name
	} else {
		// Complex case like `get_array()[i] = value`.
		// Base expr is CallExpr or something else. Use generic message.
		should_be_shared = 'array accessed via complex expression'
	}

	// Use the position of the IndexExpr itself for the error
	r.error_if_not_shared(array_type, node.pos, should_be_shared)
}

// Error reporting function (details removed)
pub fn (mut r RaceDetector) error_if_not_shared(typ ast.Type, pos token.Pos, target_name string) {
	if typ.share() != .shared_t {
		sym := r.table.sym(typ)
		mut target_desc := ''
		if target_name != '' {
			// Escape backticks in the target name if necessary for the message
			safe_target_name := target_name.replace('`', '\\`')
			target_desc = '`${safe_target_name}` '
		} else {
			target_desc = 'variable/field of type `${sym.name}` ' // Fallback if name couldn't be determined
		}

		if r.pref.is_verbose {
			println('RACE ERROR DETECTED: Type=${sym.name} (${sym.kind}) at ${r.file.path}:${
				pos.line_nr + 1}:${pos.col + 1}, Target=${target_name}')
		}

		err := errors.Error{
			reporter:  .checker
			pos:       pos
			file_path: r.file.path
			message:   'potential data race detected: ${target_desc}should be declared as `shared`'
			// No 'details' field assigned here anymore
		}
		// Avoid duplicate errors for the same position (simple check)
		if !r.errors.any(it.pos == err.pos && it.message == err.message) {
			r.errors << err
			// Also add to file errors if that's standard practice
			if !isnil(r.file) && !r.file.errors.any(it.pos == err.pos && it.message == err.message) {
				r.file.errors << err
			}
		}
	}
}
