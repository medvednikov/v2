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
	// is_assert   bool
	// inside_dump bool
	//
	// strings_builder_type ast.Type = ast.no_type
}

/*
pub fn RaceDetector.new(p &pref.Preferences) &RaceDetector {
	return &RaceDetector{
		pref: p
	}
}
*/

pub fn (mut r RaceDetector) run() {
	println('RaceDetector.run2()')
	// Ensure table is initialized if this is the entry point
	if isnil(r.table) {
		println('Warning: RaceDetector.table is nil. Cannot run.')
		return
	}
	println(r.table.fns_called_concurrently)
	for file in r.files {
		r.file = file
		// Example filter, adjust as needed
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

pub fn (mut r RaceDetector) stmt(stmt ast.Stmt) {
	match stmt {
		ast.ExprStmt {
			r.expr(stmt.expr)
		}
		ast.Block {
			for s in stmt.stmts {
				r.stmt(s)
			}
		}
		ast.AssignStmt { // <--- Added case for assignment
			r.assign_stmt(stmt)
		}
		ast.ForStmt { // Check conditions/bodies of loops
			r.expr(stmt.cond)
			for s in stmt.stmts {
				r.stmt(s)
			}
		}
		ast.ForInStmt {
			r.expr(stmt.cond)
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
		ast.IfExpr { // Check conditions/bodies of if/else if/else
			for branch in stmt.branches {
				r.expr(branch.cond)
				for s in branch.stmts {
					r.stmt(s)
				}
			}
		}
		ast.MatchExpr { // Check condition/bodies of match
			r.expr(stmt.cond)
			for branch in stmt.branches {
				// Potentially check branch.exprs too if they can cause side effects
				for s in branch.stmts {
					r.stmt(s)
				}
			}
		}
		ast.Return { // Check expressions being returned
			for expr in stmt.exprs {
				r.expr(expr)
			}
		}
		ast.GoExpr { // Check the call inside go
			r.expr(ast.Expr(stmt.call_expr))
		}
		ast.SpawnExpr { // Check the call inside spawn
			r.expr(ast.Expr(stmt.call_expr))
		}
		ast.DeferStmt { // Check deferred statements
			for s in stmt.stmts {
				r.stmt(s)
			}
		}
		ast.LockExpr { // Check statements inside lock (though less likely racey)
			for locked_expr in stmt.lockeds {
				r.expr(locked_expr)
			}
			for s in stmt.stmts {
				r.stmt(s)
			}
		}
		// Add other relevant statement types (Select, Unsafe, etc.) if needed
		else {}
	}
}

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
		}
		ast.IndexExpr {
			// An index expression itself is a read, but could be part of a write (handled in assign_stmt)
			// Check the expression being indexed and the index itself
			r.expr(expr.left)
			r.expr(expr.index)
		}
		ast.SelectorExpr {
			// A selector itself is often just access, but could be part of a write
			r.expr(expr.expr) // Check the base expression
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
				// Get the type of the variable being indexed (e.g., type of `arr` or `m`)
				left_type := left_expr.left_type
				left_final_sym := r.table.sym(left_type)

				// Check if it's an array type (dynamic or fixed)
				if left_final_sym.kind == .array || left_final_sym.kind == .array_fixed {
					// It's an array set operation
					r.array_set(left_expr)
				}
				// Potential check for maps if needed later:
				// else if left_final_sym.kind == .map {
				// 	r.map_set(left_expr) // Need to implement map_set if desired
				// }

				// Also check the expressions used within the IndexExpr itself
				r.expr(left_expr.left)
				r.expr(left_expr.index)
			}
			ast.SelectorExpr { // Potential field set: `obj.field = ...`
				// A field set might require the *field* itself to be shared or atomic,
				// or the containing struct instance if methods modify non-shared fields.
				// This is more complex. For now, let's focus on arrays.
				// We still need to check the base expression.
				r.expr(left_expr.expr)
			}
			ast.Ident { // Simple variable assignment: `x = ...`
				// Usually assigning *to* a simple variable isn't the race itself,
				// unless the variable *was* shared and reassigned. The race occurs
				// when a non-shared variable is *read* or *written* concurrently.
				// This path (`Ident` on LHS) doesn't directly indicate a write *to shared data*,
				// but rather overwrites a local variable reference.
				// However, if the variable `x` *itself* needs to be shared (e.g., captured by closures),
				// other checks might catch it. Let's skip direct error here for `x = ...`.
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

// Check for `arr << elem`
pub fn (mut r RaceDetector) array_append(node ast.InfixExpr) {
	array_expr := node.left
	array_type := node.left_type

	// If the array type itself is marked shared, assume user knows best (for now)
	if array_type.share() == .shared_t {
		return
	}

	// Determine *what* should be shared
	mut should_be_shared := ''
	if array_expr is ast.SelectorExpr {
		// Case: `obj.data << value`
		sel := array_expr
		receiver_sym := r.table.sym(sel.expr_type) // Type of `obj`
		should_be_shared = '${receiver_sym.name}.${sel.field_name}'
	} else if array_expr is ast.Ident {
		// Case: `arr << value`
		ident := array_expr
		should_be_shared = ident.name
	} else {
		// Complex case like `get_array()[i] << value` - harder to name precisely.
		// Maybe leave the name blank or use a generic placeholder.
		// For now, try to get the base identifier if possible.
		mut base_expr := array_expr
		for base_expr is ast.IndexExpr {
			base_expr = base_expr.left
		}
		if base_expr is ast.SelectorExpr {
			sel := base_expr
			receiver_sym := r.table.sym(sel.expr_type)
			should_be_shared = '${receiver_sym.name}.${sel.field_name}'
		} else if base_expr is ast.Ident {
			should_be_shared = base_expr.name
		}
	}

	r.error_if_not_shared(array_type, node.pos, should_be_shared)
}

// NEW: Check for `arr[i] = val`
pub fn (mut r RaceDetector) array_set(node ast.IndexExpr) {
	array_expr := node.left // The expression yielding the array (e.g., `arr`, `obj.data`)
	array_type := node.left_type // The type of the array itself

	// If the array type itself is marked shared, assume user knows best (for now)
	if array_type.share() == .shared_t {
		return
	}

	// Determine *what* should be shared (similar logic to array_append)
	mut should_be_shared := ''
	if array_expr is ast.SelectorExpr {
		// Case: `obj.data[i] = value`
		sel := array_expr
		receiver_sym := r.table.sym(sel.expr_type) // Type of `obj`
		// Check if the receiver symbol could be resolved
		if receiver_sym.name != '' {
			should_be_shared = '${receiver_sym.name}.${sel.field_name}'
		} else {
			// Fallback if receiver type name is unknown
			should_be_shared = 'field `${sel.field_name}`'
		}
	} else if array_expr is ast.Ident {
		// Case: `arr[i] = value`
		ident := array_expr
		should_be_shared = ident.name
	} else {
		// Complex case like `get_array()[i] = value`. Try to find base name.
		mut base_expr := array_expr
		for base_expr is ast.IndexExpr { // Handle nested indexing like `arr[i][j] = val`
			base_expr = base_expr.left
		}
		if base_expr is ast.SelectorExpr {
			sel := base_expr
			receiver_sym := r.table.sym(sel.expr_type)
			if receiver_sym.name != '' {
				should_be_shared = '${receiver_sym.name}.${sel.field_name}'
			} else {
				should_be_shared = 'field `${sel.field_name}`'
			}
		} else if base_expr is ast.Ident {
			should_be_shared = base_expr.name
		} else {
			// Use a generic message if we can't determine the name
			should_be_shared = 'array accessed via complex expression'
		}
	}

	// Use the position of the IndexExpr itself for the error
	r.error_if_not_shared(array_type, node.pos, should_be_shared)
}

// Error reporting function (slightly modified for clarity)
pub fn (mut r RaceDetector) error_if_not_shared(typ ast.Type, pos token.Pos, target_name string) {
	if typ.share() != .shared_t {
		sym := r.table.sym(typ)
		mut target_desc := ''
		if target_name != '' {
			target_desc = '`${target_name}` '
		} else {
			target_desc = 'variable/field of type `${sym.name}` ' // Fallback if name couldn't be determined
		}

		println('RACE ERROR DETECTED: Type=${sym.name} (${sym.kind}) at ${pos.line_nr}:${pos.col+1}, Target=${target_name}')
		details := 'Variable or field ${target_desc}is modified concurrently but is not declared as `shared`.'

		err := errors.Error{
			reporter:  .checker
			pos:       pos
			file_path: r.file.path
			message:   'potential data race detected: ${target_desc}should be declared as `shared`'
			details:   details
		}
		// Avoid duplicate errors for the same position (simple check)
		if !r.errors.any(it.pos == err.pos && it.message == err.message) {
			r.errors << err
			// Also add to file errors if that's standard practice
			if !r.file.errors.any(it.pos == err.pos && it.message == err.message) {
				r.file.errors << err
			}
		}
	}
}
