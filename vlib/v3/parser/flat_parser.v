module parser

import os
import v3.flat
import v3.pref
import v3.scanner
import v3.token

pub struct FlatParser {
	prefs &pref.Preferences
mut:
	s        &scanner.Scanner
	tok      token.Token
	lit      string
	prev_tok token.Token
	a        flat.FlatAst
}

pub fn FlatParser.new(prefs &pref.Preferences) FlatParser {
	return FlatParser{
		prefs: prefs
		s:     scanner.new_scanner(prefs, .normal)
		a:     flat.FlatAst.new()
	}
}

pub fn (mut p FlatParser) parse_file(path string) &flat.FlatAst {
	src := os.read_file(path) or {
		eprintln('error reading ${path}: ${err}')
		return &p.a
	}
	mut file_set := token.FileSet.new()
	file := file_set.add_file(path, -1, src.len)
	p.s.init(file, src)
	p.next()

	mut ids := []flat.NodeId{}
	for p.tok != .eof {
		id := p.top_level_stmt()
		if int(id) >= 0 {
			ids << id
		}
	}
	start := p.add_children(ids)
	p.a.add_node(flat.Node{
		kind:           .file
		children_start: start
		children_count: ids.len
	})
	return &p.a
}

fn (mut p FlatParser) next() {
	p.prev_tok = p.tok
	p.tok = p.s.scan()
	p.lit = p.s.lit
	for p.tok == .comment {
		p.tok = p.s.scan()
		p.lit = p.s.lit
	}
}

fn (mut p FlatParser) check(expected token.Token) {
	if p.tok == expected {
		p.next()
	}
}

fn (mut p FlatParser) expect(expected token.Token) string {
	lit := p.lit
	if p.tok != expected {
		eprintln('expected ${expected}, got ${p.tok} "${p.lit}"')
	}
	p.next()
	return lit
}

fn (mut p FlatParser) add_children(ids []flat.NodeId) int {
	start := p.a.children.len
	for id in ids {
		p.a.children << id
	}
	return start
}

// ==================== top-level ====================

fn (mut p FlatParser) top_level_stmt() flat.NodeId {
	match p.tok {
		.key_fn {
			return p.fn_decl()
		}
		.key_pub {
			p.next()
			return p.top_level_stmt()
		}
		.key_struct, .key_union {
			return p.struct_decl()
		}
		.key_global {
			return p.global_decl()
		}
		.key_const {
			return p.const_decl()
		}
		.key_enum {
			return p.enum_decl()
		}
		.key_type {
			return p.type_decl()
		}
		.key_interface {
			return p.interface_decl()
		}
		.key_import {
			return p.import_stmt()
		}
		.key_module {
			return p.module_stmt()
		}
		.attribute {
			p.skip_attrs()
			return p.top_level_stmt()
		}
		.dollar {
			p.skip_comptime()
			return flat.empty_node
		}
		.semicolon {
			p.next()
			return flat.empty_node
		}
		else {
			p.next()
			return flat.empty_node
		}
	}
}

fn (mut p FlatParser) fn_decl() flat.NodeId {
	p.check(.key_fn)
	mut name := ''
	if p.tok == .lpar {
		p.next()
		for p.tok != .rpar && p.tok != .eof {
			p.next()
		}
		p.check(.rpar)
	}
	if p.tok == .name {
		name = p.lit
		p.next()
		if p.tok == .dot {
			p.next()
			name = name + '.' + p.lit
			p.next()
		}
	}

	// params
	p.check(.lpar)
	mut param_ids := []flat.NodeId{}
	for p.tok != .rpar && p.tok != .eof {
		param_ids << p.parse_param_group()
	}
	p.check(.rpar)

	// return type
	mut ret_type := 'void'
	if p.tok == .name {
		ret_type = p.lit
		p.next()
	} else if p.tok == .lpar {
		// multi-return — skip
		ret_type = 'int'
		for p.tok != .rpar && p.tok != .eof {
			p.next()
		}
		p.check(.rpar)
	}

	if p.tok != .lcbr {
		for p.tok == .semicolon {
			p.next()
		}
		return p.a.add_node(flat.Node{
			kind:  .c_fn_decl
			value: name
			typ:   ret_type
		})
	}

	// body
	mut body_ids := []flat.NodeId{}
	p.check(.lcbr)
	for p.tok != .rcbr && p.tok != .eof {
		id := p.stmt()
		if int(id) >= 0 {
			body_ids << id
		}
	}
	p.check(.rcbr)

	mut all_ids := []flat.NodeId{cap: param_ids.len + body_ids.len}
	for id in param_ids {
		all_ids << id
	}
	for id in body_ids {
		all_ids << id
	}
	start := p.add_children(all_ids)
	return p.a.add_node(flat.Node{
		kind:           .fn_decl
		value:          name
		typ:            ret_type
		children_start: start
		children_count: all_ids.len
	})
}

fn (mut p FlatParser) parse_param_group() []flat.NodeId {
	mut ids := []flat.NodeId{}
	mut names := []string{}
	if p.tok == .key_mut {
		p.next()
	}
	names << p.lit
	p.next()
	for p.tok == .comma {
		p.next()
		if p.tok == .key_mut {
			p.next()
		}
		if p.tok == .name {
			names << p.lit
			p.next()
		}
	}
	typ := p.parse_type_name()
	for name in names {
		ids << p.a.add_node(flat.Node{
			kind:  .param
			value: name
			typ:   typ
		})
	}
	if p.tok == .comma {
		p.next()
	}
	return ids
}

fn (mut p FlatParser) struct_decl() flat.NodeId {
	p.next() // skip 'struct' or 'union'
	name := p.expect(.name)
	p.check(.lcbr)
	mut ids := []flat.NodeId{}
	for p.tok != .rcbr && p.tok != .eof {
		if p.tok == .name && p.lit == 'mut' {
			p.next()
			p.check(.colon)
			continue
		}
		if p.tok == .name && p.lit == 'pub' {
			p.next()
			if p.tok == .name && p.lit == 'mut' {
				p.next()
			}
			p.check(.colon)
			continue
		}
		if p.tok == .semicolon {
			p.next()
			continue
		}
		if p.tok == .name {
			field_name := p.lit
			p.next()
			field_type := p.parse_type_name()
			ids << p.a.add_node(flat.Node{
				kind:  .field_decl
				value: field_name
				typ:   field_type
			})
			if p.tok == .semicolon {
				p.next()
			}
		} else {
			p.next()
		}
	}
	p.check(.rcbr)
	start := p.add_children(ids)
	return p.a.add_node(flat.Node{
		kind:           .struct_decl
		value:          name
		children_start: start
		children_count: ids.len
	})
}

fn (mut p FlatParser) global_decl() flat.NodeId {
	p.next() // skip '__global'
	p.check(.lpar)
	mut ids := []flat.NodeId{}
	for p.tok != .rpar && p.tok != .eof {
		if p.tok == .semicolon {
			p.next()
			continue
		}
		if p.tok == .name {
			gname := p.lit
			p.next()
			gtype := p.parse_type_name()
			ids << p.a.add_node(flat.Node{
				kind:  .field_decl
				value: gname
				typ:   gtype
			})
			if p.tok == .semicolon {
				p.next()
			}
		} else {
			p.next()
		}
	}
	p.check(.rpar)
	start := p.add_children(ids)
	return p.a.add_node(flat.Node{
		kind:           .global_decl
		children_start: start
		children_count: ids.len
	})
}

fn (mut p FlatParser) const_decl() flat.NodeId {
	p.next() // skip 'const'
	// skip const declarations for now
	if p.tok == .lpar {
		mut depth := 1
		p.next()
		for depth > 0 && p.tok != .eof {
			if p.tok == .lpar {
				depth++
			} else if p.tok == .rpar {
				depth--
			}
			p.next()
		}
	} else {
		// single const: `const name = expr`
		for p.tok != .semicolon && p.tok != .eof {
			p.next()
		}
		if p.tok == .semicolon {
			p.next()
		}
	}
	return flat.empty_node
}

fn (mut p FlatParser) enum_decl() flat.NodeId {
	p.next() // skip 'enum'
	p.expect(.name)
	p.check(.lcbr)
	for p.tok != .rcbr && p.tok != .eof {
		p.next()
	}
	p.check(.rcbr)
	return flat.empty_node
}

fn (mut p FlatParser) type_decl() flat.NodeId {
	p.next() // skip 'type'
	for p.tok != .semicolon && p.tok != .eof {
		p.next()
	}
	if p.tok == .semicolon {
		p.next()
	}
	return flat.empty_node
}

fn (mut p FlatParser) interface_decl() flat.NodeId {
	p.next() // skip 'interface'
	p.expect(.name)
	p.check(.lcbr)
	for p.tok != .rcbr && p.tok != .eof {
		p.next()
	}
	p.check(.rcbr)
	return flat.empty_node
}

fn (mut p FlatParser) import_stmt() flat.NodeId {
	for p.tok != .semicolon && p.tok != .eof {
		p.next()
	}
	if p.tok == .semicolon {
		p.next()
	}
	return flat.empty_node
}

fn (mut p FlatParser) module_stmt() flat.NodeId {
	for p.tok != .semicolon && p.tok != .eof {
		p.next()
	}
	if p.tok == .semicolon {
		p.next()
	}
	return flat.empty_node
}

fn (mut p FlatParser) skip_attrs() {
	// @[...]
	if p.tok == .attribute {
		p.next()
		for p.tok != .rsbr && p.tok != .eof {
			p.next()
		}
		p.check(.rsbr)
	}
}

fn (mut p FlatParser) skip_comptime() {
	// $if ... { } $else ...
	p.next() // skip $
	if p.tok == .key_if {
		p.next()
		for p.tok != .lcbr && p.tok != .eof {
			p.next()
		}
		p.skip_block()
		for p.tok == .dollar {
			p.next()
			if p.tok == .key_else {
				p.next()
				if p.tok == .dollar {
					p.next()
					if p.tok == .key_if {
						p.next()
						for p.tok != .lcbr && p.tok != .eof {
							p.next()
						}
					}
				}
				p.skip_block()
			} else {
				break
			}
		}
	} else {
		// other comptime
		for p.tok != .semicolon && p.tok != .eof {
			p.next()
		}
		if p.tok == .semicolon {
			p.next()
		}
	}
}

fn (mut p FlatParser) skip_block() {
	if p.tok != .lcbr {
		return
	}
	mut depth := 1
	p.next()
	for depth > 0 && p.tok != .eof {
		if p.tok == .lcbr {
			depth++
		} else if p.tok == .rcbr {
			depth--
		}
		p.next()
	}
}

fn (mut p FlatParser) parse_type_name() string {
	mut name := ''
	if p.tok == .amp {
		name = '&'
		p.next()
	}
	if p.tok == .name {
		name += p.lit
		p.next()
	}
	return name
}

// ==================== statements ====================

fn (mut p FlatParser) stmt() flat.NodeId {
	match p.tok {
		.key_return {
			return p.return_stmt()
		}
		.key_if {
			return p.if_stmt()
		}
		.key_for {
			return p.for_stmt()
		}
		.key_match {
			return p.match_stmt()
		}
		.key_break {
			p.next()
			if p.tok == .semicolon {
				p.next()
			}
			return p.a.add(flat.NodeKind.break_stmt)
		}
		.key_continue {
			p.next()
			if p.tok == .semicolon {
				p.next()
			}
			return p.a.add(flat.NodeKind.continue_stmt)
		}
		.key_mut {
			p.next()
			return p.assign_or_expr_stmt()
		}
		.key_unsafe {
			p.next()
			return p.block_stmt()
		}
		.lcbr {
			return p.block_stmt()
		}
		.semicolon {
			p.next()
			return flat.empty_node
		}
		else {
			return p.assign_or_expr_stmt()
		}
	}
}

fn (mut p FlatParser) return_stmt() flat.NodeId {
	p.next() // skip 'return'
	mut ids := []flat.NodeId{}
	if p.tok != .semicolon && p.tok != .rcbr && p.tok != .eof {
		ids << p.expr(.lowest)
		for p.tok == .comma {
			p.next()
			ids << p.expr(.lowest)
		}
	}
	if p.tok == .semicolon {
		p.next()
	}
	start := p.add_children(ids)
	return p.a.add_node(flat.Node{
		kind:           .return_stmt
		children_start: start
		children_count: ids.len
	})
}

fn (mut p FlatParser) if_stmt() flat.NodeId {
	p.next() // skip 'if'
	cond := p.expr(.lowest)
	body := p.block_stmt()
	mut ids := [cond, body]
	if p.tok == .key_else {
		p.next()
		if p.tok == .key_if {
			ids << p.if_stmt()
		} else {
			ids << p.block_stmt()
		}
	}
	start := p.add_children(ids)
	return p.a.add_node(flat.Node{
		kind:           .if_expr
		children_start: start
		children_count: ids.len
	})
}

fn (mut p FlatParser) for_stmt() flat.NodeId {
	p.next() // skip 'for'
	if p.tok == .lcbr {
		// infinite loop: for { ... }
		body_ids := p.parse_block_body()
		empty1 := p.a.add(flat.NodeKind.empty)
		empty2 := p.a.add(flat.NodeKind.empty)
		empty3 := p.a.add(flat.NodeKind.empty)
		mut ids := [empty1, empty2, empty3]
		for id in body_ids {
			ids << id
		}
		start := p.add_children(ids)
		return p.a.add_node(flat.Node{
			kind:           .for_stmt
			children_start: start
			children_count: ids.len
		})
	}

	// Try to determine: condition-only, or C-style (init; cond; post)
	// Peek: if we see `:=` or `=` before `;`, it's a C-style init
	first_expr := p.expr(.lowest)

	if p.tok == .decl_assign || p.tok.is_assignment() {
		// C-style: `for i := 0; ...` — first_expr is lhs of init
		return p.for_c_style(first_expr)
	}

	if p.tok == .semicolon {
		// C-style: `for init; cond; post`
		// first_expr was the init expression... but actually it could be
		// `for i := 0;` already consumed. Let's handle differently.
		// This means first_expr is a standalone init expression (rare).
		// Actually with auto-semicolons this won't happen in V.
		// Fall through to condition-only.
	}

	if p.tok == .lcbr {
		body_ids := p.parse_block_body()
		init_empty := p.a.add(flat.NodeKind.empty)
		post_empty := p.a.add(flat.NodeKind.empty)
		mut ids := [init_empty, first_expr, post_empty]
		for id in body_ids {
			ids << id
		}
		start := p.add_children(ids)
		return p.a.add_node(flat.Node{
			kind:           .for_stmt
			children_start: start
			children_count: ids.len
		})
	}

	// shouldn't reach here
	return flat.empty_node
}

fn (mut p FlatParser) for_c_style(lhs_expr flat.NodeId) flat.NodeId {
	// We have: lhs_expr, and tok is `:=` or assignment
	op := p.tok
	p.next()
	rhs := p.expr(.lowest)

	// Build init statement
	mut init_id := flat.empty_node
	if op == .decl_assign {
		istart := p.add_children([lhs_expr, rhs])
		init_id = p.a.add_node(flat.Node{
			kind:           .decl_assign
			op:             .assign
			children_start: istart
			children_count: 2
		})
	} else {
		istart := p.add_children([lhs_expr, rhs])
		init_id = p.a.add_node(flat.Node{
			kind:           .assign
			op:             token_to_op(op)
			children_start: istart
			children_count: 2
		})
	}

	if p.tok == .semicolon {
		p.next()
	}

	// cond
	cond := p.expr(.lowest)
	if p.tok == .semicolon {
		p.next()
	}

	// post
	post := p.assign_or_expr_inline()

	// body
	body_ids := p.parse_block_body()

	mut ids := [init_id, cond, post]
	for id in body_ids {
		ids << id
	}
	start := p.add_children(ids)
	return p.a.add_node(flat.Node{
		kind:           .for_stmt
		children_start: start
		children_count: ids.len
	})
}

fn (mut p FlatParser) match_stmt() flat.NodeId {
	p.next() // skip 'match'
	match_expr := p.expr(.lowest)
	p.check(.lcbr)

	mut ids := []flat.NodeId{cap: 8}
	ids << match_expr

	for p.tok != .rcbr && p.tok != .eof {
		if p.tok == .semicolon {
			p.next()
			continue
		}
		ids << p.match_branch()
	}
	p.check(.rcbr)

	start := p.add_children(ids)
	return p.a.add_node(flat.Node{
		kind:           .match_stmt
		children_start: start
		children_count: ids.len
	})
}

fn (mut p FlatParser) match_branch() flat.NodeId {
	mut branch_ids := []flat.NodeId{}
	mut is_else := false

	if p.tok == .key_else {
		is_else = true
		p.next()
	} else {
		// condition values
		branch_ids << p.expr(.lowest)
		for p.tok == .comma {
			p.next()
			branch_ids << p.expr(.lowest)
		}
	}

	// branch body
	p.check(.lcbr)
	for p.tok != .rcbr && p.tok != .eof {
		id := p.stmt()
		if int(id) >= 0 {
			branch_ids << id
		}
	}
	p.check(.rcbr)

	bstart := p.add_children(branch_ids)
	return p.a.add_node(flat.Node{
		kind:           .match_branch
		value:          if is_else { 'else' } else { '' }
		children_start: bstart
		children_count: branch_ids.len
	})
}

fn (mut p FlatParser) block_stmt() flat.NodeId {
	ids := p.parse_block_body()
	start := p.add_children(ids)
	return p.a.add_node(flat.Node{
		kind:           .block
		children_start: start
		children_count: ids.len
	})
}

fn (mut p FlatParser) parse_block_body() []flat.NodeId {
	p.check(.lcbr)
	mut ids := []flat.NodeId{}
	for p.tok != .rcbr && p.tok != .eof {
		id := p.stmt()
		if int(id) >= 0 {
			ids << id
		}
	}
	p.check(.rcbr)
	return ids
}

fn (mut p FlatParser) assign_or_expr_stmt() flat.NodeId {
	lhs := p.expr(.lowest)

	if p.tok == .decl_assign {
		p.next()
		rhs := p.expr(.lowest)
		if p.tok == .semicolon {
			p.next()
		}
		lhs_node := p.a.nodes[int(lhs)]
		if lhs_node.kind == .ident {
			// track inferred type later in gen
		}
		istart := p.add_children([lhs, rhs])
		return p.a.add_node(flat.Node{
			kind:           .decl_assign
			op:             .assign
			children_start: istart
			children_count: 2
		})
	}

	if p.tok.is_assignment() {
		op := p.tok
		p.next()
		rhs := p.expr(.lowest)
		if p.tok == .semicolon {
			p.next()
		}
		lhs_node := p.a.nodes[int(lhs)]
		kind := if lhs_node.kind == .selector {
			flat.NodeKind.selector_assign
		} else {
			flat.NodeKind.assign
		}
		istart := p.add_children([lhs, rhs])
		return p.a.add_node(flat.Node{
			kind:           kind
			op:             token_to_op(op)
			children_start: istart
			children_count: 2
		})
	}

	if p.tok == .semicolon {
		p.next()
	}

	// expression statement (e.g. function call)
	estart := p.add_children([lhs])
	return p.a.add_node(flat.Node{
		kind:           .expr_stmt
		children_start: estart
		children_count: 1
	})
}

fn (mut p FlatParser) assign_or_expr_inline() flat.NodeId {
	lhs := p.expr(.lowest)

	if p.tok.is_assignment() {
		op := p.tok
		p.next()
		rhs := p.expr(.lowest)
		lhs_node := p.a.nodes[int(lhs)]
		kind := if lhs_node.kind == .selector {
			flat.NodeKind.selector_assign
		} else {
			flat.NodeKind.assign
		}
		istart := p.add_children([lhs, rhs])
		return p.a.add_node(flat.Node{
			kind:           kind
			op:             token_to_op(op)
			children_start: istart
			children_count: 2
		})
	}

	// postfix as statement (e.g. i++)
	estart := p.add_children([lhs])
	return p.a.add_node(flat.Node{
		kind:           .expr_stmt
		children_start: estart
		children_count: 1
	})
}

// ==================== expressions (Pratt parser) ====================

fn (mut p FlatParser) expr(min_bp token.BindingPower) flat.NodeId {
	mut lhs := p.prefix_expr()

	for {
		if p.tok == .dot {
			lhs = p.selector_or_method(lhs)
			continue
		}
		if p.tok == .lpar {
			lhs = p.call_args(lhs)
			continue
		}
		if p.tok == .lsbr {
			lhs = p.index_expr(lhs)
			continue
		}
		if p.tok.is_postfix() {
			op := p.tok
			p.next()
			pstart := p.add_children([lhs])
			lhs = p.a.add_node(flat.Node{
				kind:           .postfix
				op:             token_to_op(op)
				children_start: pstart
				children_count: 1
			})
			continue
		}
		if !p.tok.is_infix() {
			break
		}
		bp := p.tok.left_binding_power()
		if int(bp) < int(min_bp) {
			break
		}
		op := p.tok
		p.next()
		rhs := p.expr(op.right_binding_power())
		istart := p.add_children([lhs, rhs])
		lhs = p.a.add_node(flat.Node{
			kind:           .infix
			op:             token_to_op(op)
			children_start: istart
			children_count: 2
		})
	}

	return lhs
}

fn (mut p FlatParser) prefix_expr() flat.NodeId {
	match p.tok {
		.number {
			val := p.lit
			p.next()
			return p.a.add_val(.int_literal, val)
		}
		.string {
			val := strip_quotes(p.lit)
			p.next()
			return p.a.add_val(.string_literal, val)
		}
		.char {
			val := p.lit
			p.next()
			return p.a.add_val(.char_literal, val)
		}
		.key_true {
			p.next()
			return p.a.add_val(.bool_literal, 'true')
		}
		.key_false {
			p.next()
			return p.a.add_val(.bool_literal, 'false')
		}
		.name {
			name := p.lit
			p.next()
			if p.tok == .lcbr && name.len > 0 && name[0] >= `A` && name[0] <= `Z` {
				return p.struct_init(name)
			}
			return p.a.add_val(.ident, name)
		}
		.lpar {
			p.next()
			inner := p.expr(.lowest)
			p.check(.rpar)
			pstart := p.add_children([inner])
			return p.a.add_node(flat.Node{
				kind:           .paren
				children_start: pstart
				children_count: 1
			})
		}
		.minus, .not, .bit_not, .amp, .mul {
			op := p.tok
			p.next()
			operand := p.prefix_expr()
			pstart := p.add_children([operand])
			return p.a.add_node(flat.Node{
				kind:           .prefix
				op:             token_to_op(op)
				children_start: pstart
				children_count: 1
			})
		}
		.key_if {
			return p.if_stmt()
		}
		.key_match {
			return p.match_stmt()
		}
		else {
			p.next()
			return p.a.add(flat.NodeKind.empty)
		}
	}
}

fn (mut p FlatParser) selector_or_method(lhs flat.NodeId) flat.NodeId {
	p.next() // skip '.'
	field_name := p.lit
	p.expect(.name)
	sel_start := p.add_children([lhs])
	sel := p.a.add_node(flat.Node{
		kind:           .selector
		value:          field_name
		children_start: sel_start
		children_count: 1
	})
	if p.tok == .lpar {
		return p.call_args(sel)
	}
	return sel
}

fn (mut p FlatParser) call_args(fn_expr flat.NodeId) flat.NodeId {
	p.check(.lpar)
	mut ids := [fn_expr]
	if p.tok != .rpar {
		ids << p.expr(.lowest)
		for p.tok == .comma {
			p.next()
			ids << p.expr(.lowest)
		}
	}
	p.check(.rpar)
	cstart := p.add_children(ids)
	return p.a.add_node(flat.Node{
		kind:           .call
		children_start: cstart
		children_count: ids.len
	})
}

fn (mut p FlatParser) index_expr(lhs flat.NodeId) flat.NodeId {
	p.check(.lsbr)
	idx := p.expr(.lowest)
	p.check(.rsbr)
	istart := p.add_children([lhs, idx])
	return p.a.add_node(flat.Node{
		kind:           .index
		children_start: istart
		children_count: 2
	})
}

fn (mut p FlatParser) struct_init(name string) flat.NodeId {
	p.check(.lcbr)
	mut ids := []flat.NodeId{}
	for p.tok != .rcbr && p.tok != .eof {
		if p.tok == .semicolon {
			p.next()
			continue
		}
		if p.tok == .name {
			fname := p.lit
			p.next()
			p.check(.colon)
			val := p.expr(.lowest)
			vstart := p.add_children([val])
			ids << p.a.add_node(flat.Node{
				kind:           .field_init
				value:          fname
				children_start: vstart
				children_count: 1
			})
		} else {
			p.next()
		}
		if p.tok == .semicolon {
			p.next()
		}
	}
	p.check(.rcbr)
	start := p.add_children(ids)
	return p.a.add_node(flat.Node{
		kind:           .struct_init
		value:          name
		children_start: start
		children_count: ids.len
	})
}

// ==================== helpers ====================

fn strip_quotes(s string) string {
	if s.len >= 2 && ((s[0] == `'` && s[s.len - 1] == `'`) || (s[0] == `"` && s[s.len - 1] == `"`)) {
		return s[1..s.len - 1]
	}
	return s
}

fn token_to_op(tok token.Token) flat.Op {
	return match tok {
		.plus { flat.Op.plus }
		.minus { flat.Op.minus }
		.mul { flat.Op.mul }
		.div { flat.Op.div }
		.mod { flat.Op.mod }
		.eq { flat.Op.eq }
		.ne { flat.Op.ne }
		.lt { flat.Op.lt }
		.gt { flat.Op.gt }
		.le { flat.Op.le }
		.ge { flat.Op.ge }
		.amp { flat.Op.amp }
		.pipe { flat.Op.pipe }
		.xor { flat.Op.xor }
		.left_shift { flat.Op.left_shift }
		.right_shift { flat.Op.right_shift }
		.and { flat.Op.logical_and }
		.logical_or { flat.Op.logical_or }
		.not { flat.Op.not }
		.bit_not { flat.Op.bit_not }
		.assign { flat.Op.assign }
		.plus_assign { flat.Op.plus_assign }
		.minus_assign { flat.Op.minus_assign }
		.mul_assign { flat.Op.mul_assign }
		.div_assign { flat.Op.div_assign }
		.inc { flat.Op.inc }
		.dec { flat.Op.dec }
		.decl_assign { flat.Op.assign }
		else { flat.Op.none }
	}
}
