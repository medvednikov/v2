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
	println(r.table.fns_called_concurrently)
	for file in r.files {
		r.file = file
		if !file.path.contains('race.v') {
			continue
		}
		// println(file)
		for stmt in file.stmts {
			if stmt is ast.FnDecl {
				// if stmt.is_called_concurrently {
				if r.table.fn_is_called_concurrently(stmt) {
					r.fn_decl(stmt)
				}
			}
		}
	}
}

// Only runs on functions that are called concurrently
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
		else {}
	}
}

pub fn (mut r RaceDetector) expr(expr ast.Expr) {
	match expr {
		ast.InfixExpr {
			r.infix_expr(expr)
		}
		else {}
	}
}

pub fn (mut r RaceDetector) infix_expr(node ast.InfixExpr) {
	left_type := node.left_type
	left_final_sym := r.table.sym(left_type)
	match node.op {
		.left_shift {
			if left_final_sym.kind == .array {
				// XTODO
				//|| r.table.sym(c.unwrap_generic(left_type)).kind == .array {
				r.array_append(node)
			}
		}
		else {}
	}
}

pub fn (mut r RaceDetector) array_append(node ast.InfixExpr) {
	// The type is marked as `shared`, nothing to do here
	if node.left_type.share() == .shared_t {
		return
	}
	if node.left is ast.SelectorExpr {
		sel := node.left
		// println('vvvvvvv')
		// println(sel.field_name)
		// println('sel type')
		receiver_sym := r.table.sym(sel.expr_type) // `Table` in `Table.data`
		r.error_if_not_shared(node.left_type, node.pos, receiver_sym.name + '.' + sel.field_name)
		return
	}
	r.error_if_not_shared(node.left_type, node.pos, '')
}

pub fn (mut r RaceDetector) error_if_not_shared(typ ast.Type, pos token.Pos, should_be_shared string) {
	if typ.share() != .shared_t {
		sym := r.table.sym(typ)
		println('RACE ERROR for typ=${sym}')
		err := errors.Error{
			reporter:  .checker
			pos:       pos
			file_path: r.file.path
			message:   'potential data race detected. `${should_be_shared}` should be declared as `shared`'
			// details:   details
		}
		r.errors << err
		r.file.errors << err
		//
		/*
		err2 := errors.Error{
			reporter:  .checker
			pos:       token.Pos{
			file_path: 'race.v'
			message:   'function called concurrently here'
			// details:   details
		}
		r.errors << err
		r.file.errors << err
		*/
	}
}
