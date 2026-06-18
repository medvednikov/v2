module parser

import os
import strings
import v3.flat
import v3.pref
import v3.scanner
import v3.token

pub struct Parser {
	prefs &pref.Preferences
mut:
	s          &scanner.Scanner
	tok        token.Token
	lit        string
	prev_tok   token.Token
	peek_tok   token.Token = .eof
	peek_lit   string
	has_peek   bool
	a          flat.FlatAst
	cur_file   string
	cur_module string
}

pub fn Parser.new(prefs &pref.Preferences) Parser {
	return Parser{
		prefs: prefs
		s:     scanner.new_scanner(prefs, .normal)
		a:     flat.FlatAst.new()
	}
}

pub fn (mut p Parser) parse_file(path string) &flat.FlatAst {
	p.parse_into(path)
	return &p.a
}

pub fn (mut p Parser) parse_files(paths []string) &flat.FlatAst {
	for path in paths {
		p.parse_into(path)
	}
	return &p.a
}

pub fn (mut p Parser) parse_into(path string) {
	p.cur_file = path
	// File marker before content so import resolver can track source files
	p.a.add_node(flat.Node{
		kind:  .file
		value: path
	})
	src := os.read_file(path) or {
		eprintln('error reading ${path}: ${err}')
		return
	}
	mut file_set := token.FileSet.new()
	file := file_set.add_file(path, -1, src.len)
	p.s.init(file, src)
	p.next()

	mut ids := []flat.NodeId{}
	for p.tok != .eof {
		if p.tok == .key_module {
			p.next()
			p.cur_module = p.lit
			mod_id := p.a.add_node(flat.Node{
				kind:  .module_decl
				value: p.lit
			})
			ids << mod_id
			p.next()
			continue
		}
		id := p.top_level_stmt()
		if int(id) >= 0 {
			ids << id
		}
	}
	start := p.add_children(ids)
	p.a.add_node(flat.Node{
		kind:           .file
		value:          path
		children_start: start
		children_count: ids.len
	})
}

fn (mut p Parser) next() {
	p.prev_tok = p.tok
	if p.has_peek {
		p.tok = p.peek_tok
		p.lit = p.peek_lit
		p.has_peek = false
		return
	}
	p.tok = p.s.scan()
	p.lit = p.s.lit
	for p.tok == .comment {
		p.tok = p.s.scan()
		p.lit = p.s.lit
	}
}

fn (mut p Parser) peek() token.Token {
	if !p.has_peek {
		p.peek_tok = p.s.scan()
		p.peek_lit = p.s.lit
		for p.peek_tok == .comment {
			p.peek_tok = p.s.scan()
			p.peek_lit = p.s.lit
		}
		p.has_peek = true
	}
	return p.peek_tok
}

fn (mut p Parser) check(expected token.Token) {
	if p.tok == expected {
		p.next()
	}
}

fn (mut p Parser) expect(expected token.Token) string {
	lit := p.lit
	if p.tok != expected {
		eprintln('expected ${expected}, got ${p.tok} "${p.lit}"')
	}
	p.next()
	return lit
}

fn (mut p Parser) expect_name() string {
	name := p.lit
	if p.tok != .name {
		eprintln('expected name, got ${p.tok} "${p.lit}"')
	}
	p.next()
	return name
}

fn (mut p Parser) expect_name_or_keyword() string {
	name := p.lit
	p.next()
	return name
}

fn (mut p Parser) add_children(ids []flat.NodeId) int {
	start := p.a.children.len
	for id in ids {
		p.a.children << id
	}
	return start
}

fn (mut p Parser) add_child(id flat.NodeId) int {
	start := p.a.children.len
	p.a.children << id
	return start
}

fn (mut p Parser) add_children2(a flat.NodeId, b flat.NodeId) int {
	start := p.a.children.len
	p.a.children << a
	p.a.children << b
	return start
}

// ==================== top-level ====================

fn (mut p Parser) top_level_stmt() flat.NodeId {
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
		.lsbr {
			p.skip_attrs()
			return p.top_level_stmt()
		}
		.dollar {
			return p.parse_comptime_if()
		}
		.hash {
			return p.directive()
		}
		.key_assert {
			return p.assert_stmt()
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

fn (mut p Parser) fn_decl() flat.NodeId {
	p.check(.key_fn)
	mut name := ''
	mut receiver_name := ''
	mut receiver_type := ''
	mut is_method := false

	// method receiver: fn (mut r Type) name()
	if p.tok == .lpar {
		is_method = true
		p.next()
		mut is_mut := false
		if p.tok == .key_mut || p.tok == .key_shared {
			is_mut = p.tok == .key_mut
			p.next()
		}
		receiver_name = p.expect_name()
		receiver_type = p.parse_type_name()
		if is_mut {
			receiver_type = '&' + receiver_type
		}
		p.check(.rpar)

		// operator overload: fn (r Type) + (other Type) RetType { }
		if p.tok != .name && p.tok != .eof {
			if p.tok.is_overloadable() {
				op_name := p.tok.str()
				p.next()
				return p.fn_operator_overload(receiver_name, receiver_type, op_name)
			}
		}
	}

	// function name
	if p.tok == .name {
		name = p.lit
		p.next()
		if p.tok == .dot {
			p.next()
			if name == 'C' || name == 'JS' {
				// C.func or JS.func
				name = p.expect_name_or_keyword()
				for p.tok == .dot {
					p.next()
					name += '.' + p.expect_name_or_keyword()
				}
				if is_method {
					clean_type := receiver_type.trim_left('&')
					name = '${clean_type}.${name}'
				}
				return p.fn_decl_body(name, receiver_name, receiver_type, is_method, true)
			}
			// module.func or Type.static_method
			second := p.expect_name_or_keyword()
			if is_method {
				// This shouldn't happen for methods
				name = name + '.' + second
			} else {
				// Static method: Type.name
				receiver_type = name
				name = second
				is_method = true
			}
		}
	}

	if is_method && receiver_type.len > 0 {
		clean_type := receiver_type.trim_left('&')
		name = '${clean_type}.${name}'
	}

	return p.fn_decl_body(name, receiver_name, receiver_type, is_method, false)
}

fn (mut p Parser) fn_operator_overload(receiver_name string, receiver_type string, op_name string) flat.NodeId {
	// parse parameter
	p.check(.lpar)
	mut param_ids := []flat.NodeId{}
	// receiver
	param_ids << p.a.add_node(flat.Node{
		kind:  .param
		value: receiver_name
		typ:   receiver_type
	})
	// operator param
	if p.tok == .key_mut {
		p.next()
	}
	for p.tok != .rpar && p.tok != .eof {
		param_ids << p.parse_param_group()
	}
	p.check(.rpar)

	mut ret_type := 'void'
	if p.tok != .lcbr && p.tok != .semicolon && p.tok != .eof {
		ret_type = p.parse_type_name()
	}

	clean_type := receiver_type.trim_left('&')
	name := '${clean_type}.${op_name}'

	mut body_ids := []flat.NodeId{}
	if p.tok == .lcbr {
		p.check(.lcbr)
		for p.tok != .rcbr && p.tok != .eof {
			id := p.stmt()
			if int(id) >= 0 {
				body_ids << id
			}
		}
		p.check(.rcbr)
	}

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

fn (mut p Parser) fn_decl_body(name string, receiver_name string, receiver_type string, is_method bool, _ bool) flat.NodeId {
	// generic params — skip
	if p.tok == .lsbr {
		p.skip_brackets()
	}

	// params
	p.check(.lpar)
	mut param_ids := []flat.NodeId{}
	if is_method && receiver_name.len > 0 {
		param_ids << p.a.add_node(flat.Node{
			kind:  .param
			value: receiver_name
			typ:   receiver_type
		})
	}
	for p.tok != .rpar && p.tok != .eof {
		param_ids << p.parse_param_group()
	}
	p.check(.rpar)

	// return type
	mut ret_type := 'void'
	if p.tok == .name || p.tok == .amp || p.tok == .question || p.tok == .not || p.tok == .lsbr || p.tok == .lpar || p.tok == .key_fn || p.tok == .ellipsis {
		ret_type = p.parse_type_name()
	}

	// no body — extern/C declaration
	if p.tok != .lcbr {
		for p.tok == .semicolon {
			p.next()
		}
		start := p.add_children(param_ids)
		return p.a.add_node(flat.Node{
			kind:           .c_fn_decl
			value:          name
			typ:            ret_type
			children_start: start
			children_count: param_ids.len
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

fn (mut p Parser) parse_param_group() []flat.NodeId {
	mut ids := []flat.NodeId{}
	mut names := []string{}
	mut is_mut := false
	if p.tok == .key_mut {
		is_mut = true
		p.next()
	}
	if p.tok == .key_shared {
		p.next()
	}
	// variadic ...Type (no param name)
	if p.tok == .ellipsis {
		typ := p.parse_type_name()
		ids << p.a.add_node(flat.Node{
			kind:  .param
			value: ''
			typ:   typ
		})
		if p.tok == .comma {
			p.next()
		}
		return ids
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
	mut typ := p.parse_type_name()
	if is_mut {
		typ = '&' + typ
	}
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

fn (mut p Parser) struct_decl() flat.NodeId {
	p.next() // skip 'struct' or 'union'
	name := p.expect(.name)
	// generic params — skip
	if p.tok == .lsbr {
		p.skip_brackets()
	}
	// implements clause
	if p.tok == .name && p.lit == 'implements' {
		p.next()
		p.parse_type_name()
		for p.tok == .comma {
			p.next()
			p.parse_type_name()
		}
	}
	// no body (C struct forward decl)
	if p.tok != .lcbr {
		if p.tok == .semicolon {
			p.next()
		}
		return p.a.add_node(flat.Node{
			kind:  .struct_decl
			value: name
		})
	}
	p.check(.lcbr)
	mut ids := []flat.NodeId{}
	for p.tok != .rcbr && p.tok != .eof {
		// access modifiers
		if p.tok == .key_pub {
			p.next()
			if p.tok == .key_mut {
				p.next()
			}
			if p.tok == .name && p.lit == 'module_mut' {
				p.next()
			}
			if p.tok == .colon {
				p.next()
			}
			continue
		}
		if p.tok == .key_mut {
			p.next()
			if p.tok == .colon {
				p.next()
			}
			continue
		}
		if p.tok == .semicolon {
			p.next()
			continue
		}
		// comptime $if in struct fields
		if p.tok == .dollar {
			id := p.parse_comptime_if()
			if int(id) >= 0 {
				ids << id
			}
			continue
		}
		// attributes — skip
		if p.tok == .attribute {
			p.skip_attrs()
			continue
		}
		// field: name type [= default] [@[attrs]]
		if p.tok == .name || p.tok.is_keyword() {
			field_name := p.expect_name_or_keyword()
			// embedded struct (type on its own line, followed by semicolon)
			if p.tok == .semicolon || p.tok == .rcbr {
				if p.tok == .semicolon {
					p.next()
				}
				continue
			}
			// grouped fields: x, y int
			if p.tok == .comma {
				mut names := []string{}
				names << field_name
				for p.tok == .comma {
					p.next()
					names << p.expect_name_or_keyword()
				}
				field_type := p.parse_type_name()
				for n in names {
					ids << p.a.add_node(flat.Node{
						kind:  .field_decl
						value: n
						typ:   field_type
					})
				}
				if p.tok == .semicolon {
					p.next()
				}
				continue
			}
			// For embedded structs followed by access modifier or another field,
			// check if the next token could be a type
			field_type := p.parse_type_name()
			// default value
			if p.tok == .assign {
				p.next()
				p.expr(.lowest) // consume value, don't store
			}
			// trailing field attributes — skip
			if p.tok == .attribute || p.tok == .lsbr {
				p.skip_attrs()
			}
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

fn (mut p Parser) global_decl() flat.NodeId {
	p.next() // skip '__global'
	is_grouped := p.tok == .lpar
	if is_grouped {
		p.next()
	}
	mut ids := []flat.NodeId{}
	for {
		if p.tok == .semicolon {
			p.next()
			if !is_grouped {
				break
			}
			if p.tok == .rpar {
				p.next()
				if p.tok == .semicolon {
					p.next()
				}
				break
			}
			continue
		}
		if p.tok == .key_pub {
			p.next()
		}
		if p.tok == .key_mut {
			p.next()
		}
		if p.tok == .name || p.tok.is_keyword() {
			gname := p.expect_name_or_keyword()
			// handle qualified names: C.errno
			mut full_name := gname
			for p.tok == .dot {
				p.next()
				full_name += '.' + p.expect_name_or_keyword()
			}
			if p.tok == .assign {
				// global with initializer: __global name = expr
				p.next()
				val_id := p.expr(.lowest)
				vstart := p.add_child(val_id)
				ids << p.a.add_node(flat.Node{
					kind:           .field_decl
					value:          full_name
					typ:            ''
					children_start: vstart
					children_count: 1
				})
			} else {
				gtype := p.parse_type_name()
				ids << p.a.add_node(flat.Node{
					kind:  .field_decl
					value: full_name
					typ:   gtype
				})
			}
			if p.tok == .semicolon {
				p.next()
			}
			if !is_grouped {
				break
			}
			if is_grouped && p.tok == .rpar {
				p.next()
				if p.tok == .semicolon {
					p.next()
				}
				break
			}
		} else if p.tok == .rpar {
			p.next()
			if p.tok == .semicolon {
				p.next()
			}
			break
		} else {
			p.next()
			if !is_grouped {
				break
			}
		}
	}
	start := p.add_children(ids)
	return p.a.add_node(flat.Node{
		kind:           .global_decl
		children_start: start
		children_count: ids.len
	})
}

fn (mut p Parser) const_decl() flat.NodeId {
	p.next() // skip 'const'
	is_grouped := p.tok == .lpar
	if is_grouped {
		p.next()
	}
	mut ids := []flat.NodeId{}
	for {
		if p.tok == .semicolon {
			p.next()
			if !is_grouped {
				break
			}
			if p.tok == .rpar {
				p.next()
				if p.tok == .semicolon {
					p.next()
				}
				break
			}
			continue
		}
		if p.tok == .name {
			cname := p.expect_name()
			mut full_name := cname
			// C.NAME
			if full_name == 'C' && p.tok == .dot {
				p.next()
				full_name = 'C.' + p.expect_name_or_keyword()
			}
			if p.tok == .assign {
				p.next()
				val_id := p.expr(.lowest)
				vstart := p.add_child(val_id)
				ids << p.a.add_node(flat.Node{
					kind:           .const_field
					value:          full_name
					children_start: vstart
					children_count: 1
				})
			} else {
				// const with type only (header files)
				ctype := p.parse_type_name()
				ids << p.a.add_node(flat.Node{
					kind:  .const_field
					value: full_name
					typ:   ctype
				})
			}
			if p.tok == .semicolon {
				p.next()
			}
			if !is_grouped {
				break
			}
			if is_grouped && p.tok == .rpar {
				p.next()
				if p.tok == .semicolon {
					p.next()
				}
				break
			}
		} else if p.tok == .rpar {
			p.next()
			if p.tok == .semicolon {
				p.next()
			}
			break
		} else {
			p.next()
			if !is_grouped {
				break
			}
		}
	}
	start := p.add_children(ids)
	return p.a.add_node(flat.Node{
		kind:           .const_decl
		children_start: start
		children_count: ids.len
	})
}

fn (mut p Parser) enum_decl() flat.NodeId {
	p.next() // skip 'enum'
	name := p.expect(.name)
	// `as` type
	if p.tok == .key_as {
		p.next()
		p.parse_type_name()
	}
	p.check(.lcbr)
	mut ids := []flat.NodeId{}
	for p.tok != .rcbr && p.tok != .eof {
		if p.tok == .semicolon {
			p.next()
			continue
		}
		// attributes on enum fields — skip
		if p.tok == .attribute || p.tok == .lsbr {
			p.skip_attrs()
			continue
		}
		field_name := p.expect_name_or_keyword()
		if p.tok == .assign {
			p.next()
			val_id := p.expr(.lowest)
			vstart := p.add_child(val_id)
			ids << p.a.add_node(flat.Node{
				kind:           .enum_field
				value:          field_name
				children_start: vstart
				children_count: 1
			})
		} else {
			ids << p.a.add_node(flat.Node{
				kind:  .enum_field
				value: field_name
			})
		}
		if p.tok == .semicolon {
			p.next()
		}
	}
	p.check(.rcbr)
	start := p.add_children(ids)
	return p.a.add_node(flat.Node{
		kind:           .enum_decl
		value:          name
		children_start: start
		children_count: ids.len
	})
}

fn (mut p Parser) type_decl() flat.NodeId {
	p.next() // skip 'type'
	// C. or JS. prefix
	if p.tok == .name && (p.lit == 'C' || p.lit == 'JS') {
		p.next()
		if p.tok == .dot {
			p.next()
		}
	}
	name := p.expect_name()
	// generic params
	if p.tok == .lsbr {
		p.skip_brackets()
	}
	p.expect(.assign)
	first_type := p.parse_type_name()
	// check for sum type: type T = A | B | C
	// skip auto-semicolon before pipe
	if p.tok == .pipe || (p.tok == .semicolon && p.peek() == .pipe) {
		mut variants := []flat.NodeId{}
		variants << p.a.add_val(.ident, first_type)
		for p.tok == .pipe || (p.tok == .semicolon && p.peek() == .pipe) {
			if p.tok == .semicolon {
				p.next()
			}
			p.next() // skip |
			variant_type := p.parse_type_name()
			variants << p.a.add_val(.ident, variant_type)
		}
		if p.tok == .semicolon {
			p.next()
		}
		start := p.add_children(variants)
		return p.a.add_node(flat.Node{
			kind:           .type_decl
			value:          name
			children_start: start
			children_count: variants.len
		})
	}
	if p.tok == .semicolon {
		p.next()
	}
	// type alias
	return p.a.add_node(flat.Node{
		kind:  .type_decl
		value: name
		typ:   first_type
	})
}

fn (mut p Parser) interface_decl() flat.NodeId {
	p.next() // skip 'interface'
	mut name := p.expect(.name)
	for p.tok == .dot {
		p.next()
		name += '.' + p.expect(.name)
	}
	// generic params
	if p.tok == .lsbr {
		p.skip_brackets()
	}
	p.check(.lcbr)
	mut ids := []flat.NodeId{}
	for p.tok != .rcbr && p.tok != .eof {
		if p.tok == .key_mut {
			p.next()
			if p.tok == .colon {
				p.next()
			}
			continue
		}
		if p.tok == .semicolon {
			p.next()
			continue
		}
		field_name := p.expect_name_or_keyword()
		if p.tok == .lpar {
			// method: name(params) ret_type
			p.next() // skip (
			mut ptypes := []string{}
			for p.tok != .rpar && p.tok != .eof {
				if p.tok == .key_mut {
					p.next()
				}
				ptype := p.parse_type_name()
				if p.tok == .name {
					// param has a name before type, consume the actual type
					ptype2 := p.parse_type_name()
					ptypes << ptype2
				} else {
					ptypes << ptype
				}
				if p.tok == .comma {
					p.next()
				}
			}
			p.check(.rpar) // skip )
			mut ret_type := ''
			if p.tok != .semicolon && p.tok != .rcbr && p.tok != .eof {
				ret_type = p.parse_type_name()
			}
			ids << p.a.add_node(flat.Node{
				kind:  .interface_field
				value: field_name
				typ:   ret_type
			})
		} else if p.tok == .semicolon || p.tok == .rcbr {
			// embedded type or field without explicit type
			ids << p.a.add_node(flat.Node{
				kind:  .interface_field
				value: field_name
			})
		} else {
			// field: name type
			ftype := p.parse_type_name()
			ids << p.a.add_node(flat.Node{
				kind:  .interface_field
				value: field_name
				typ:   ftype
			})
		}
		if p.tok == .semicolon {
			p.next()
		}
	}
	p.check(.rcbr)
	start := p.add_children(ids)
	return p.a.add_node(flat.Node{
		kind:           .interface_decl
		value:          name
		children_start: start
		children_count: ids.len
	})
}

fn (mut p Parser) import_stmt() flat.NodeId {
	p.next() // skip 'import'
	mut name := p.expect_name()
	mut alias := name
	for p.tok == .dot {
		p.next()
		alias = p.expect_name()
		name += '.' + alias
	}
	if p.tok == .key_as {
		p.next()
		alias = p.expect_name()
	}
	// selective import: import mod { sym1, sym2 }
	if p.tok == .lcbr {
		p.next()
		for p.tok != .rcbr && p.tok != .eof {
			p.expect_name_or_keyword()
			if p.tok == .comma {
				p.next()
			}
		}
		p.check(.rcbr)
	}
	if p.tok == .semicolon {
		p.next()
	}
	return p.a.add_node(flat.Node{
		kind:  .import_decl
		value: name
		typ:   alias
	})
}

fn (mut p Parser) module_stmt() flat.NodeId {
	p.next() // skip 'module'
	name := p.expect_name()
	if p.tok == .semicolon {
		p.next()
	}
	return p.a.add_node(flat.Node{
		kind:  .module_decl
		value: name
	})
}

fn (mut p Parser) directive() flat.NodeId {
	full := p.lit
	p.next() // skip '#' (lit already contains the full line)
	mut name := full
	mut value := ''
	space_idx := full.index_u8(` `)
	if space_idx > 0 {
		name = full[..space_idx]
		value = full[space_idx + 1..].trim_space()
	}
	if p.tok == .semicolon {
		p.next()
	}
	return p.a.add_node(flat.Node{
		kind:  .directive
		value: name
		typ:   value
	})
}

fn (mut p Parser) skip_attrs() {
	if p.tok == .attribute {
		p.next()
		for p.tok != .rsbr && p.tok != .eof {
			p.next()
		}
		p.check(.rsbr)
		return
	}
	if p.tok == .lsbr {
		p.skip_brackets()
	}
}

fn (mut p Parser) parse_comptime_if() flat.NodeId {
	p.next() // skip $
	if p.tok != .key_if {
		// $for or other comptime — skip
		if p.tok == .key_for {
			p.next()
			for p.tok != .lcbr && p.tok != .eof {
				p.next()
			}
			p.skip_block()
		} else {
			for p.tok != .semicolon && p.tok != .eof {
				p.next()
			}
			if p.tok == .semicolon {
				p.next()
			}
		}
		return flat.empty_node
	}
	p.next() // skip 'if'
	cond := p.parse_comptime_cond()
	taken := eval_comptime_cond(p.prefs, cond)
	if taken {
		result := p.block_stmt()
		p.skip_comptime_else()
		return result
	} else {
		p.skip_block()
		return p.parse_comptime_else()
	}
}

fn (mut p Parser) parse_comptime_cond() string {
	mut cond := strings.new_builder(64)
	for p.tok != .lcbr && p.tok != .eof {
		tok_str := if p.lit.len > 0 { p.lit } else { p.tok.str() }
		if cond.len > 0 && tok_str != '?' {
			cond.write_string(' ')
		}
		cond.write_string(tok_str)
		p.next()
	}
	return cond.str()
}

fn (mut p Parser) skip_comptime_else() {
	if p.tok == .semicolon && p.peek() == .dollar {
		p.next()
	}
	if p.tok != .dollar {
		return
	}
	if p.peek() != .key_else {
		return
	}
	p.next() // skip $
	p.next() // skip else
	if p.tok == .dollar || (p.tok == .semicolon && p.peek() == .dollar) {
		if p.tok == .semicolon {
			p.next()
		}
		// $else $if — skip nested
		p.next() // skip $
		if p.tok == .key_if {
			p.next()
			for p.tok != .lcbr && p.tok != .eof {
				p.next()
			}
		}
		p.skip_block()
		p.skip_comptime_else()
	} else {
		p.skip_block()
	}
}

fn (mut p Parser) parse_comptime_else() flat.NodeId {
	// Skip auto-semicolons before $else
	if p.tok == .semicolon && p.peek() == .dollar {
		p.next()
	}
	if p.tok != .dollar {
		return flat.empty_node
	}
	if p.peek() != .key_else {
		return flat.empty_node
	}
	p.next() // skip $
	p.next() // skip else
	// $else $if — recurse
	if p.tok == .dollar || (p.tok == .semicolon && p.peek() == .dollar) {
		if p.tok == .semicolon {
			p.next()
		}
		return p.parse_comptime_if()
	}
	return p.block_stmt()
}

fn eval_comptime_cond(prefs &pref.Preferences, cond string) bool {
	c := cond.trim_space()
	if c.starts_with('!') {
		return !eval_comptime_cond(prefs, c[1..])
	}
	if c.contains('&&') {
		parts := c.split('&&')
		for part in parts {
			if !eval_comptime_cond(prefs, part) {
				return false
			}
		}
		return true
	}
	if c.contains('||') {
		parts := c.split('||')
		for part in parts {
			if eval_comptime_cond(prefs, part) {
				return true
			}
		}
		return false
	}
	flag := c.trim_space().trim_right('? ')
	return pref.comptime_flag_value(prefs, flag)
}

fn (mut p Parser) skip_block() {
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

fn (mut p Parser) skip_brackets() {
	if p.tok != .lsbr {
		return
	}
	mut depth := 1
	p.next()
	for depth > 0 && p.tok != .eof {
		if p.tok == .lsbr {
			depth++
		} else if p.tok == .rsbr {
			depth--
		}
		p.next()
	}
}

// ==================== statements ====================

fn (mut p Parser) stmt() flat.NodeId {
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
		.key_defer {
			return p.defer_stmt()
		}
		.key_assert {
			return p.assert_stmt()
		}
		.key_goto {
			return p.goto_stmt()
		}
		.key_go, .key_spawn {
			p.next()
			spawn_expr := p.expr(.lowest)
			if p.tok == .semicolon {
				p.next()
			}
			sstart := p.add_child(spawn_expr)
			return p.a.add_node(flat.Node{
				kind:           .expr_stmt
				children_start: sstart
				children_count: 1
			})
		}
		.key_asm {
			return p.asm_stmt()
		}
		.dollar {
			return p.parse_comptime_if()
		}
		.hash {
			return p.directive()
		}
		.lcbr {
			return p.block_stmt()
		}
		.semicolon {
			p.next()
			return flat.empty_node
		}
		.name {
			// label: name followed by ':'
			if p.peek() == .colon {
				label_name := p.lit
				p.next() // skip name
				p.next() // skip :
				if p.tok == .semicolon {
					p.next()
				}
				return p.a.add_val(.label_stmt, label_name)
			}
			return p.assign_or_expr_stmt()
		}
		else {
			return p.assign_or_expr_stmt()
		}
	}
}

fn (mut p Parser) return_stmt() flat.NodeId {
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

fn (mut p Parser) if_stmt() flat.NodeId {
	p.next() // skip 'if'
	cond := p.expr(.lowest)

	// if-guard: if a, b := expr { ... } or if val := expr { ... }
	mut guard_cond := cond
	if p.tok == .comma || p.tok == .decl_assign {
		// Simple if-guard; treat as regular condition for flat AST
		if p.tok == .decl_assign {
			p.next()
			rhs := p.expr(.lowest)
			istart := p.add_children2(guard_cond, rhs)
			guard_cond = p.a.add_node(flat.Node{
				kind:           .decl_assign
				op:             .assign
				children_start: istart
				children_count: 2
			})
		} else {
			// comma case: if a, b := expr
			for p.tok == .comma {
				p.next()
				p.expr(.lowest) // consume additional LHS
			}
			if p.tok == .decl_assign {
				p.next()
				p.expr(.lowest) // consume RHS
			}
		}
	}

	// skip auto-semicolon before {
	if p.tok == .semicolon && p.peek() == .lcbr {
		p.next()
	}
	body := p.block_stmt()
	mut ids := []flat.NodeId{}
	ids << guard_cond
	ids << body

	// skip auto-semicolon between } and else
	if p.tok == .semicolon && p.peek() == .key_else {
		p.next()
	}
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

fn (mut p Parser) for_stmt() flat.NodeId {
	p.next() // skip 'for'
	if p.tok == .lcbr {
		// infinite loop: for { ... }
		body_ids := p.parse_block_body()
		empty1 := p.a.add(flat.NodeKind.empty)
		empty2 := p.a.add(flat.NodeKind.empty)
		empty3 := p.a.add(flat.NodeKind.empty)
		mut ids := []flat.NodeId{}
		ids << empty1
		ids << empty2
		ids << empty3
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

	// Check for for-in: `for x in ...` or `for i, x in ...` or `for mut x in ...`
	if p.tok == .name && (p.peek() == .key_in || p.peek() == .comma) {
		first_expr := p.expr(.bit_or)
		return p.for_in(first_expr)
	}
	if p.tok == .key_mut && p.peek() == .name {
		p.next()
		first_expr := p.a.add_val(.ident, p.expect_name())
		if p.tok == .key_in || p.tok == .comma {
			return p.for_in(first_expr)
		}
	}

	first_expr := p.expr(.lowest)

	// for-in: `for x in expr` or `for i, x in expr`
	if p.tok == .key_in || p.tok == .comma {
		return p.for_in(first_expr)
	}

	// C-style: `for i := 0; ...`
	if p.tok == .decl_assign || p.tok.is_assignment() {
		return p.for_c_style(first_expr)
	}

	if p.tok == .semicolon {
		// could be C-style with expression init, or just a separator
		// peek to check
		pk := p.peek()
		if pk == .semicolon || pk == .lcbr {
			// condition-only: `for cond { }`
			// fall through
		} else if pk != .rcbr && pk != .eof {
			// might be C-style: `for expr; cond; post`
			p.next() // skip ;
			cond := p.expr(.lowest)
			if p.tok == .semicolon {
				p.next()
			}
			post := if p.tok != .lcbr && p.tok != .eof {
				p.assign_or_expr_inline()
			} else {
				p.a.add(flat.NodeKind.empty)
			}
			body_ids := p.parse_block_body()
			// first_expr becomes init as expr_stmt
			init_start := p.add_child(first_expr)
			init_id := p.a.add_node(flat.Node{
				kind:           .expr_stmt
				children_start: init_start
				children_count: 1
			})
			mut ids := []flat.NodeId{}
		ids << init_id
		ids << cond
		ids << post
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
	}

	// condition-only: `for cond { ... }`
	if p.tok == .lcbr {
		body_ids := p.parse_block_body()
		init_empty := p.a.add(flat.NodeKind.empty)
		post_empty := p.a.add(flat.NodeKind.empty)
		mut ids := []flat.NodeId{}
		ids << init_empty
		ids << first_expr
		ids << post_empty
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

	return flat.empty_node
}

fn (mut p Parser) for_c_style(lhs_expr flat.NodeId) flat.NodeId {
	op := p.tok
	p.next()
	rhs := p.expr(.lowest)

	mut init_id := flat.empty_node
	if op == .decl_assign {
		istart := p.add_children2(lhs_expr, rhs)
		init_id = p.a.add_node(flat.Node{
			kind:           .decl_assign
			op:             .assign
			children_start: istart
			children_count: 2
		})
	} else {
		istart := p.add_children2(lhs_expr, rhs)
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

	cond := p.expr(.lowest)
	if p.tok == .semicolon {
		p.next()
	}

	post := p.assign_or_expr_inline()

	body_ids := p.parse_block_body()

	mut ids := []flat.NodeId{}
		ids << init_id
		ids << cond
		ids << post
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

fn (mut p Parser) for_in(first_expr flat.NodeId) flat.NodeId {
	// first_expr is either the key var or the only var
	mut key_id := first_expr
	mut val_id := flat.empty_node

	if p.tok == .comma {
		p.next()
		// second variable
		if p.tok == .key_mut {
			p.next()
		}
		val_id = p.a.add_val(.ident, p.expect_name())
	}

	p.check(.key_in)
	container := p.expr(.lowest)

	// optional range: `for i in 0 .. n`
	mut range_end := flat.empty_node
	if p.tok == .dotdot {
		p.next()
		range_end = p.expr(.lowest)
	}

	body_ids := p.parse_block_body()

	mut ids := []flat.NodeId{cap: 4 + body_ids.len}
	ids << key_id
	ids << val_id
	ids << container
	if int(range_end) >= 0 {
		ids << range_end
	}
	for id in body_ids {
		ids << id
	}
	start := p.add_children(ids)
	return p.a.add_node(flat.Node{
		kind:           .for_in_stmt
		children_start: start
		children_count: ids.len
		// value field stores the count of header elements (key, val, container, [range_end])
		// so gen knows where body starts
		value: if int(range_end) >= 0 { '4' } else { '3' }
	})
}

fn (mut p Parser) match_stmt() flat.NodeId {
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

fn (mut p Parser) match_branch_cond() flat.NodeId {
	if p.tok == .name && p.lit.len > 0 && p.lit[0] >= `A` && p.lit[0] <= `Z` && p.peek() == .lcbr {
		name := p.lit
		p.next()
		return p.a.add_val(.ident, name)
	}
	if p.tok == .name && is_builtin_type(p.lit) && p.peek() == .lcbr {
		name := p.lit
		p.next()
		return p.a.add_val(.ident, name)
	}
	if p.tok == .name && p.peek() == .dot {
		mod_name := p.lit
		p.next()
		p.next()
		if p.tok == .name && p.lit.len > 0 && p.lit[0] >= `A` && p.lit[0] <= `Z` && p.peek() == .lcbr {
			type_name := p.lit
			p.next()
			mod_id := p.a.add_val(.ident, mod_name)
			start := p.add_child(mod_id)
			return p.a.add_node(flat.Node{
				kind:           .selector
				value:          type_name
				children_start: start
				children_count: 1
			})
		}
		base_id := p.a.add_val(.ident, mod_name)
		start := p.add_child(base_id)
		sel := p.a.add_node(flat.Node{
			kind:           .selector
			value:          p.lit
			children_start: start
			children_count: 1
		})
		if p.tok == .name {
			p.next()
		}
		return sel
	}
	return p.expr(.lowest)
}

fn (mut p Parser) match_branch() flat.NodeId {
	mut branch_ids := []flat.NodeId{}
	mut is_else := false
	mut n_conds := 0

	if p.tok == .key_else {
		is_else = true
		p.next()
	} else {
		branch_ids << p.match_branch_cond()
		n_conds = 1
		for p.tok == .comma {
			p.next()
			branch_ids << p.match_branch_cond()
			n_conds++
		}
	}

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
		value:          if is_else { 'else' } else { '${n_conds}' }
		children_start: bstart
		children_count: branch_ids.len
	})
}

fn (mut p Parser) block_stmt() flat.NodeId {
	ids := p.parse_block_body()
	start := p.add_children(ids)
	return p.a.add_node(flat.Node{
		kind:           .block
		children_start: start
		children_count: ids.len
	})
}

fn (mut p Parser) parse_block_body() []flat.NodeId {
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

fn (mut p Parser) assign_or_expr_stmt() flat.NodeId {
	lhs := p.expr(.lowest)

	// multi-assign: a, b := expr1, expr2
	if p.tok == .comma {
		mut lhs_ids := []flat.NodeId{}
		lhs_ids << lhs
		for p.tok == .comma {
			p.next()
			if p.tok == .key_mut {
				p.next()
			}
			lhs_ids << p.expr(.lowest)
		}
		if p.tok == .decl_assign || p.tok.is_assignment() {
			op := p.tok
			p.next()
			mut rhs_ids := []flat.NodeId{}
			rhs_ids << p.expr(.lowest)
			for p.tok == .comma {
				p.next()
				rhs_ids << p.expr(.lowest)
			}
			if p.tok == .semicolon {
				p.next()
			}
			mut all_ids := []flat.NodeId{cap: lhs_ids.len * 2}
			for i in 0 .. lhs_ids.len {
				all_ids << lhs_ids[i]
				if i < rhs_ids.len {
					all_ids << rhs_ids[i]
				}
			}
			istart := p.add_children(all_ids)
			return p.a.add_node(flat.Node{
				kind:           if op == .decl_assign {
					flat.NodeKind.decl_assign
				} else {
					flat.NodeKind.assign
				}
				op:             token_to_op(op)
				children_start: istart
				children_count: all_ids.len
			})
		}
	}

	if p.tok == .decl_assign {
		p.next()
		rhs := p.expr(.lowest)
		if p.tok == .semicolon {
			p.next()
		}
		istart := p.add_children2(lhs, rhs)
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
		} else if lhs_node.kind == .index {
			flat.NodeKind.index_assign
		} else {
			flat.NodeKind.assign
		}
		istart := p.add_children2(lhs, rhs)
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

	estart := p.add_child(lhs)
	return p.a.add_node(flat.Node{
		kind:           .expr_stmt
		children_start: estart
		children_count: 1
	})
}

fn (mut p Parser) assign_or_expr_inline() flat.NodeId {
	lhs := p.expr(.lowest)

	if p.tok.is_assignment() {
		op := p.tok
		p.next()
		rhs := p.expr(.lowest)
		lhs_node := p.a.nodes[int(lhs)]
		kind := if lhs_node.kind == .selector {
			flat.NodeKind.selector_assign
		} else if lhs_node.kind == .index {
			flat.NodeKind.index_assign
		} else {
			flat.NodeKind.assign
		}
		istart := p.add_children2(lhs, rhs)
		return p.a.add_node(flat.Node{
			kind:           kind
			op:             token_to_op(op)
			children_start: istart
			children_count: 2
		})
	}

	estart := p.add_child(lhs)
	return p.a.add_node(flat.Node{
		kind:           .expr_stmt
		children_start: estart
		children_count: 1
	})
}

fn (mut p Parser) defer_stmt() flat.NodeId {
	p.next() // skip 'defer'
	if p.tok == .lpar {
		p.next()
		if p.tok == .key_fn {
			p.next()
		}
		p.check(.rpar)
	}
	body := p.block_stmt()
	dstart := p.add_child(body)
	return p.a.add_node(flat.Node{
		kind:           .defer_stmt
		children_start: dstart
		children_count: 1
	})
}

fn (mut p Parser) assert_stmt() flat.NodeId {
	p.next() // skip 'assert'
	cond := p.expr(.lowest)
	mut ids := []flat.NodeId{}
	ids << cond
	// optional message: assert cond, 'message'
	if p.tok == .comma {
		p.next()
		ids << p.expr(.lowest)
	}
	if p.tok == .semicolon {
		p.next()
	}
	astart := p.add_children(ids)
	return p.a.add_node(flat.Node{
		kind:           .assert_stmt
		children_start: astart
		children_count: ids.len
	})
}

fn (mut p Parser) goto_stmt() flat.NodeId {
	p.next() // skip 'goto'
	label := p.expect_name()
	if p.tok == .semicolon {
		p.next()
	}
	return p.a.add_val(.goto_stmt, label)
}

fn (mut p Parser) asm_stmt() flat.NodeId {
	p.next() // skip 'asm'
	// consume optional volatile keyword
	if p.tok == .name && p.lit == 'volatile' {
		p.next()
	}
	// consume the asm block
	if p.tok == .lcbr {
		p.skip_block()
	}
	if p.tok == .semicolon {
		p.next()
	}
	return p.a.add(flat.NodeKind.asm_stmt)
}

// ==================== expressions (Pratt parser) ====================

fn (mut p Parser) expr(min_bp token.BindingPower) flat.NodeId {
	mut lhs := p.prefix_expr()

	for {
		// selector / method call
		if p.tok == .dot {
			lhs = p.selector_or_method(lhs)
			continue
		}
		// module-qualified struct init: module.Type{} or module.Type{field: val, ...}
		if p.tok == .lcbr {
			lhs_node := p.a.nodes[int(lhs)]
			if lhs_node.kind == .selector && lhs_node.value.len > 0 && (p.peek() == .rcbr || p.peek() == .name || p.peek() == .ellipsis) {
				base := p.a.child_node(&lhs_node, 0)
				if base.kind == .ident && (base.value == 'C' || (lhs_node.value[0] >= `A` && lhs_node.value[0] <= `Z`)) {
					full_name := '${base.value}.${lhs_node.value}'
					lhs = p.struct_init(full_name)
					continue
				}
			}
		}
		// function call
		if p.tok == .lpar {
			lhs = p.call_args(lhs)
			continue
		}
		// index / generic
		if p.tok == .lsbr {
			lhs = p.index_expr(lhs)
			continue
		}
		// postfix: ++ -- ? !
		if p.tok.is_postfix() {
			op := p.tok
			p.next()
			pstart := p.add_child(lhs)
			lhs = p.a.add_node(flat.Node{
				kind:           .postfix
				op:             token_to_op(op)
				children_start: pstart
				children_count: 1
			})
			continue
		}
		// postfix `!` error propagation: expr!
		if p.tok == .not {
			p.next()
			ostart := p.add_children2(lhs, p.a.add(flat.NodeKind.empty))
			lhs = p.a.add_node(flat.Node{
				kind:           .or_expr
				value:          '!'
				children_start: ostart
				children_count: 2
			})
			continue
		}
		// postfix `?` optional propagation: expr?
		if p.tok == .question {
			p.next()
			ostart := p.add_children2(lhs, p.a.add(flat.NodeKind.empty))
			lhs = p.a.add_node(flat.Node{
				kind:           .or_expr
				value:          '?'
				children_start: ostart
				children_count: 2
			})
			continue
		}
		// `as` cast: expr as Type
		if p.tok == .key_as {
			p.next()
			type_name := p.parse_type_name()
			astart := p.add_child(lhs)
			lhs = p.a.add_node(flat.Node{
				kind:           .as_expr
				value:          type_name
				children_start: astart
				children_count: 1
			})
			continue
		}
		// `or` block: expr or { ... }
		if p.tok == .key_or {
			p.next()
			or_body := p.block_stmt()
			ostart := p.add_children2(lhs, or_body)
			lhs = p.a.add_node(flat.Node{
				kind:           .or_expr
				children_start: ostart
				children_count: 2
			})
			continue
		}
		// range: expr .. expr
		if p.tok == .dotdot {
			if int(min_bp) > int(token.BindingPower.lowest) {
				break
			}
			p.next()
			rhs := p.expr(.lowest)
			rstart := p.add_children2(lhs, rhs)
			lhs = p.a.add_node(flat.Node{
				kind:           .range
				children_start: rstart
				children_count: 2
			})
			continue
		}
		// `is` / `!is` / `not_is` type check
		if p.tok == .key_is || p.tok == .not_is {
			bp := token.BindingPower.compare
			if int(bp) < int(min_bp) {
				break
			}
			is_negated := p.tok == .not_is
			p.next()
			type_name := p.parse_type_name()
			istart := p.add_child(lhs)
			is_node := p.a.add_node(flat.Node{
				kind:           .is_expr
				value:          type_name
				children_start: istart
				children_count: 1
			})
			if is_negated {
				nstart := p.add_child(is_node)
				lhs = p.a.add_node(flat.Node{
					kind:           .prefix
					op:             .not
					children_start: nstart
					children_count: 1
				})
			} else {
				lhs = is_node
			}
			continue
		}
		if p.tok == .not && p.peek() == .key_is {
			bp := token.BindingPower.compare
			if int(bp) < int(min_bp) {
				break
			}
			p.next() // skip !
			p.next() // skip is
			type_name := p.parse_type_name()
			istart := p.add_child(lhs)
			is_node := p.a.add_node(flat.Node{
				kind:           .is_expr
				value:          type_name
				children_start: istart
				children_count: 1
			})
			nstart := p.add_child(is_node)
			lhs = p.a.add_node(flat.Node{
				kind:           .prefix
				op:             .not
				children_start: nstart
				children_count: 1
			})
			continue
		}
		// `in` / `!in` / `not_in`
		if p.tok == .key_in || p.tok == .not_in {
			is_negated := p.tok == .not_in
			bp := token.BindingPower.compare
			if int(bp) < int(min_bp) {
				break
			}
			p.next()
			rhs := p.expr(token.BindingPower.bit_or)
			istart := p.add_children2(lhs, rhs)
			in_node := p.a.add_node(flat.Node{
				kind:           .in_expr
				children_start: istart
				children_count: 2
			})
			if is_negated {
				nstart := p.add_child(in_node)
				lhs = p.a.add_node(flat.Node{
					kind:           .prefix
					op:             .not
					children_start: nstart
					children_count: 1
				})
			} else {
				lhs = in_node
			}
			continue
		}
		if p.tok == .not && p.peek() == .key_in {
			bp := token.BindingPower.compare
			if int(bp) < int(min_bp) {
				break
			}
			p.next() // skip !
			p.next() // skip in
			rhs := p.expr(token.BindingPower.bit_or)
			istart := p.add_children2(lhs, rhs)
			in_node := p.a.add_node(flat.Node{
				kind:           .in_expr
				children_start: istart
				children_count: 2
			})
			nstart := p.add_child(in_node)
			lhs = p.a.add_node(flat.Node{
				kind:           .prefix
				op:             .not
				children_start: nstart
				children_count: 1
			})
			continue
		}
		// infix operators
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
		istart := p.add_children2(lhs, rhs)
		lhs = p.a.add_node(flat.Node{
			kind:           .infix
			op:             token_to_op(op)
			children_start: istart
			children_count: 2
		})
	}

	return lhs
}

fn (mut p Parser) prefix_expr() flat.NodeId {
	match p.tok {
		.number {
			val := p.lit
			p.next()
			kind := if val.contains('.') || val.contains('e') || val.contains('E') {
				flat.NodeKind.float_literal
			} else {
				flat.NodeKind.int_literal
			}
			return p.a.add_val(kind, val)
		}
		.string {
			return p.string_literal()
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
		.key_nil {
			p.next()
			return p.a.add(.nil_literal)
		}
		.key_none {
			p.next()
			return p.a.add(.none_expr)
		}
		.name {
			name := p.lit
			p.next()
			if name == '@FILE' {
				return p.a.add_val(.string_literal, p.cur_file)
			}
			if name == '@LINE' {
				return p.a.add_val(.int_literal, '0')
			}
			if name == '@FN' {
				return p.a.add_val(.string_literal, '')
			}
			// map init: map[K]V{} or map[K]V{k1: v1, ...}
			if name == 'map' && p.tok == .lsbr {
				p.next() // skip [
				key_type := p.parse_type_name()
				p.check(.rsbr)
				val_type := p.parse_type_name()
				map_type := 'map[${key_type}]${val_type}'
				if p.tok == .lcbr {
					p.next() // skip {
					mut ids := []flat.NodeId{}
					for p.tok != .rcbr && p.tok != .eof {
						if p.tok == .semicolon {
							p.next()
							continue
						}
						k := p.expr(.lowest)
						p.check(.colon)
						v := p.expr(.lowest)
						ids << k
						ids << v
						if p.tok == .comma || p.tok == .semicolon {
							p.next()
						}
					}
					p.check(.rcbr)
					if ids.len > 0 {
						istart := p.add_children(ids)
						return p.a.add_node(flat.Node{
							kind:           .map_init
							value:          map_type
							children_start: istart
							children_count: ids.len
						})
					}
				}
				return p.a.add_val(.map_init, map_type)
			}
			// struct init: Name{...}
			if p.tok == .lcbr && name.len > 0 && name[0] >= `A` && name[0] <= `Z` {
				return p.struct_init(name)
			}
			// type cast: TypeName(expr) or builtin_type(expr)
			if p.tok == .lpar && name.len > 0 && ((name[0] >= `A` && name[0] <= `Z`) || is_builtin_type(name)) {
				p.next() // skip (
				inner := p.expr(.lowest)
				p.check(.rpar)
				cstart := p.add_child(inner)
				return p.a.add_node(flat.Node{
					kind:           .cast_expr
					value:          name
					children_start: cstart
					children_count: 1
				})
			}
			return p.a.add_val(.ident, name)
		}
		.lpar {
			p.next()
			inner := p.expr(.lowest)
			p.check(.rpar)
			pstart := p.add_child(inner)
			return p.a.add_node(flat.Node{
				kind:           .paren
				children_start: pstart
				children_count: 1
			})
		}
		.minus, .not, .bit_not, .amp, .mul {
			op := p.tok
			p.next()
			operand := p.expr(.highest)
			pstart := p.add_child(operand)
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
		.key_fn {
			return p.fn_literal()
		}
		.key_go, .key_spawn {
			p.next()
			inner := p.expr(.lowest)
			sstart := p.add_child(inner)
			return p.a.add_node(flat.Node{
				kind:           .spawn_expr
				children_start: sstart
				children_count: 1
			})
		}
		.key_lock, .key_rlock {
			return p.lock_expr()
		}
		.key_select {
			return p.select_expr()
		}
		.key_sizeof {
			return p.sizeof_expr()
		}
		.key_typeof {
			return p.typeof_expr()
		}
		.key_offsetof {
			return p.offsetof_expr()
		}
		.key_dump {
			return p.dump_expr()
		}
		.key_likely, .key_unlikely {
			p.next()
			p.check(.lpar)
			inner := p.expr(.lowest)
			p.check(.rpar)
			return inner
		}
		.key_isreftype {
			p.next()
			p.check(.lpar)
			p.parse_type_name()
			p.check(.rpar)
			return p.a.add_val(.bool_literal, 'false')
		}
		.dot {
			// enum value: .member
			p.next()
			member := p.expect_name_or_keyword()
			return p.a.add_val(.enum_val, member)
		}
		.lsbr {
			return p.array_literal()
		}
		.key_unsafe {
			p.next()
			return p.block_stmt()
		}
		.ellipsis {
			// spread: ...expr
			p.next()
			inner := p.expr(.lowest)
			pstart := p.add_child(inner)
			return p.a.add_node(flat.Node{
				kind:           .prefix
				op:             .none
				value:          '...'
				children_start: pstart
				children_count: 1
			})
		}
		.dollar {
			return p.parse_comptime_if()
		}
		else {
			p.next()
			return p.a.add(flat.NodeKind.empty)
		}
	}
}

fn (mut p Parser) selector_or_method(lhs flat.NodeId) flat.NodeId {
	p.next() // skip '.'
	field_name := p.expect_name_or_keyword()
	sel_start := p.add_child(lhs)
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

fn (mut p Parser) call_args(fn_expr flat.NodeId) flat.NodeId {
	p.check(.lpar)
	mut ids := []flat.NodeId{}
	ids << fn_expr
	for p.tok != .rpar && p.tok != .eof {
		if p.tok == .key_mut || p.tok == .key_shared {
			p.next()
		}
		// vararg spread: ...expr
		if p.tok == .ellipsis {
			p.next()
			inner := p.expr(.lowest)
			sstart := p.add_child(inner)
			ids << p.a.add_node(flat.Node{
				kind:           .prefix
				op:             .none
				value:          '...'
				children_start: sstart
				children_count: 1
			})
		} else if p.tok == .logical_or {
			// lambda no args: || expr
			p.next()
			lambda_body := p.expr(.lowest)
			lstart := p.add_child(lambda_body)
			ids << p.a.add_node(flat.Node{
				kind:           .lambda_expr
				children_start: lstart
				children_count: 1
			})
		} else if p.tok == .pipe {
			// lambda with args: |a, b| expr
			p.next()
			mut lambda_params := []flat.NodeId{}
			lambda_params << p.a.add_val(.ident, p.expect_name())
			for p.tok == .comma {
				p.next()
				lambda_params << p.a.add_val(.ident, p.expect_name())
			}
			p.check(.pipe)
			lambda_body := p.expr(.lowest)
			mut lids := lambda_params.clone()
			lids << lambda_body
			lstart := p.add_children(lids)
			ids << p.a.add_node(flat.Node{
				kind:           .lambda_expr
				children_start: lstart
				children_count: lids.len
			})
		} else {
			arg := p.expr(.lowest)
			// struct config syntax: name: value
			if p.tok == .colon {
				p.next()
				val := p.expr(.lowest)
				arg_node := p.a.nodes[int(arg)]
				vstart := p.add_child(val)
				ids << p.a.add_node(flat.Node{
					kind:           .field_init
					value:          arg_node.value
					children_start: vstart
					children_count: 1
				})
				if p.tok == .semicolon {
					p.next()
				}
			} else {
				ids << arg
			}
		}
		if p.tok == .comma {
			p.next()
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

fn (mut p Parser) index_expr(lhs flat.NodeId) flat.NodeId {
	p.check(.lsbr)
	// range index: arr[..b]
	if p.tok == .dotdot {
		p.next()
		mut end_id := flat.empty_node
		if p.tok != .rsbr {
			end_id = p.expr(.lowest)
		}
		p.check(.rsbr)
		start_id := p.a.add(flat.NodeKind.empty)
		mut ids := []flat.NodeId{}
	ids << lhs
	ids << start_id
		if int(end_id) >= 0 {
			ids << end_id
		}
		istart := p.add_children(ids)
		return p.a.add_node(flat.Node{
			kind:           .index
			value:          'range'
			children_start: istart
			children_count: ids.len
		})
	}
	idx := p.expr(.logical_or)
	// range index: arr[a..b]
	if p.tok == .dotdot {
		p.next()
		mut end_id := flat.empty_node
		if p.tok != .rsbr {
			end_id = p.expr(.lowest)
		}
		p.check(.rsbr)
		mut ids := []flat.NodeId{}
		ids << lhs
		ids << idx
		if int(end_id) >= 0 {
			ids << end_id
		}
		istart := p.add_children(ids)
		return p.a.add_node(flat.Node{
			kind:           .index
			value:          'range'
			children_start: istart
			children_count: ids.len
		})
	}
	p.check(.rsbr)
	istart := p.add_children2(lhs, idx)
	return p.a.add_node(flat.Node{
		kind:           .index
		children_start: istart
		children_count: 2
	})
}

fn (mut p Parser) struct_init(name string) flat.NodeId {
	p.check(.lcbr)
	mut ids := []flat.NodeId{}
	// assoc syntax: Type{...base, field: val}
	if p.tok == .ellipsis {
		p.next()
		base_expr := p.expr(.lowest)
		if p.tok == .comma || p.tok == .semicolon {
			p.next()
		}
		mut field_ids := []flat.NodeId{}
		field_ids << base_expr
		for p.tok != .rcbr && p.tok != .eof {
			if p.tok == .comma {
				p.next()
			}
			fname := p.expect_name_or_keyword()
			p.check(.colon)
			val := p.expr(.lowest)
			vstart := p.add_child(val)
			field_ids << p.a.add_node(flat.Node{
				kind:           .field_init
				value:          fname
				children_start: vstart
				children_count: 1
			})
			if p.tok == .semicolon {
				p.next()
			}
		}
		p.check(.rcbr)
		start := p.add_children(field_ids)
		return p.a.add_node(flat.Node{
			kind:           .assoc
			value:          name
			children_start: start
			children_count: field_ids.len
		})
	}
	for p.tok != .rcbr && p.tok != .eof {
		if p.tok == .semicolon {
			p.next()
			continue
		}
		// named field: name: expr
		if (p.tok == .name || p.tok.is_keyword()) && p.peek() == .colon {
			fname := p.expect_name_or_keyword()
			p.check(.colon)
			val := p.expr(.lowest)
			vstart := p.add_child(val)
			ids << p.a.add_node(flat.Node{
				kind:           .field_init
				value:          fname
				children_start: vstart
				children_count: 1
			})
		} else {
			// positional value (unnamed)
			val := p.expr(.lowest)
			vstart := p.add_child(val)
			ids << p.a.add_node(flat.Node{
				kind:           .field_init
				children_start: vstart
				children_count: 1
			})
		}
		if p.tok == .comma {
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

fn (mut p Parser) string_literal() flat.NodeId {
	val := strip_quotes(p.lit)
	p.next()
	if p.tok != .str_dollar {
		return p.a.add_val(.string_literal, val)
	}
	// string interpolation
	return p.string_interp(val)
}

fn (mut p Parser) string_interp(first_part string) flat.NodeId {
	mut ids := []flat.NodeId{}
	if first_part.len > 0 {
		ids << p.a.add_val(.string_literal, first_part)
	}
	for p.tok == .str_dollar {
		p.next() // skip $
		p.check(.lcbr) // skip {
		ids << p.expr(.lowest)
		// format spec: :fmt
		if p.tok == .colon {
			p.next()
			for p.tok != .rcbr && p.tok != .eof {
				p.next()
			}
		}
		p.check(.rcbr) // skip }
		if p.tok == .string {
			part := strip_quotes(p.lit)
			p.next()
			if part.len > 0 {
				ids << p.a.add_val(.string_literal, part)
			}
			// check for more interpolation after this string part
		}
	}
	start := p.add_children(ids)
	return p.a.add_node(flat.Node{
		kind:           .string_interp
		children_start: start
		children_count: ids.len
	})
}

fn (mut p Parser) array_literal() flat.NodeId {
	p.next() // skip '['
	// empty array or fixed array type: []Type{} or [N]Type{}
	if p.tok == .rsbr {
		p.next()
		elem_type := p.parse_type_name()
		// array init: []Type{len: n, cap: c, init: v}
		if p.tok == .lcbr {
			p.next()
			mut ids := []flat.NodeId{}
			for p.tok != .rcbr && p.tok != .eof {
				if p.tok == .semicolon {
					p.next()
					continue
				}
				if p.tok == .name && p.peek() == .colon {
					fname := p.expect_name()
					p.check(.colon)
					val := p.expr(.lowest)
					vstart := p.add_child(val)
					ids << p.a.add_node(flat.Node{
						kind:           .field_init
						value:          fname
						children_start: vstart
						children_count: 1
					})
				} else {
					ids << p.expr(.lowest)
				}
				if p.tok == .comma {
					p.next()
				}
			}
			p.check(.rcbr)
			start := p.add_children(ids)
			return p.a.add_node(flat.Node{
				kind:           .array_init
				value:          elem_type
				children_start: start
				children_count: ids.len
			})
		}
		return p.a.add_val(.array_init, elem_type)
	}
	// array literal: [1, 2, 3]
	// or fixed array type: [3]int
	mut ids := []flat.NodeId{}
	ids << p.expr(.lowest)
	// check if it's [N]Type (fixed array type)
	if p.tok == .rsbr {
		p.next()
		if p.tok == .name || p.tok == .amp || p.tok == .lsbr || p.tok == .question {
			// fixed array type: [N]Type
			elem_type := p.parse_type_name()
			// may have init
			if p.tok == .lcbr {
				p.next()
				mut init_ids := []flat.NodeId{}
				for p.tok != .rcbr && p.tok != .eof {
					if p.tok == .semicolon {
						p.next()
						continue
					}
					if p.tok == .name && p.peek() == .colon {
						fname := p.expect_name()
						p.check(.colon)
						val := p.expr(.lowest)
						vstart := p.add_child(val)
						init_ids << p.a.add_node(flat.Node{
							kind:           .field_init
							value:          fname
							children_start: vstart
							children_count: 1
						})
					} else {
						init_ids << p.expr(.lowest)
					}
					if p.tok == .comma {
						p.next()
					}
				}
				p.check(.rcbr)
				start := p.add_children(init_ids)
				return p.a.add_node(flat.Node{
					kind:           .array_init
					value:          elem_type
					children_start: start
					children_count: init_ids.len
				})
			}
			return p.a.add_val(.array_init, elem_type)
		}
		// single-element array: [expr]
		start := p.add_children(ids)
		return p.a.add_node(flat.Node{
			kind:           .array_literal
			children_start: start
			children_count: ids.len
		})
	}
	// multi-element array: [a, b, c]
	for p.tok == .comma {
		p.next()
		if p.tok == .rsbr {
			break
		}
		ids << p.expr(.lowest)
	}
	p.check(.rsbr)
	// check for `!` (fixed array with values)
	if p.tok == .not {
		p.next()
	}
	start := p.add_children(ids)
	return p.a.add_node(flat.Node{
		kind:           .array_literal
		children_start: start
		children_count: ids.len
	})
}

fn (mut p Parser) fn_literal() flat.NodeId {
	p.next() // skip 'fn'
	// capture list: fn [a, b] (params) ret { }
	mut capture_ids := []flat.NodeId{}
	if p.tok == .lsbr {
		p.next()
		for p.tok != .rsbr && p.tok != .eof {
			if p.tok == .key_mut {
				p.next()
			}
			capture_ids << p.a.add_val(.ident, p.expect_name())
			if p.tok == .comma {
				p.next()
			}
		}
		p.check(.rsbr)
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
	if p.tok != .lcbr && p.tok != .semicolon && p.tok != .eof {
		if p.tok == .name || p.tok == .amp || p.tok == .question || p.tok == .not || p.tok == .lsbr || p.tok == .lpar || p.tok == .key_fn {
			ret_type = p.parse_type_name()
		}
	}
	// body
	mut body_ids := []flat.NodeId{}
	if p.tok == .lcbr {
		p.check(.lcbr)
		for p.tok != .rcbr && p.tok != .eof {
			id := p.stmt()
			if int(id) >= 0 {
				body_ids << id
			}
		}
		p.check(.rcbr)
	}
	mut all_ids := []flat.NodeId{cap: capture_ids.len + param_ids.len + body_ids.len}
	for id in capture_ids {
		all_ids << id
	}
	for id in param_ids {
		all_ids << id
	}
	for id in body_ids {
		all_ids << id
	}
	start := p.add_children(all_ids)
	return p.a.add_node(flat.Node{
		kind:           .fn_literal
		typ:            ret_type
		children_start: start
		children_count: all_ids.len
	})
}

fn (mut p Parser) lock_expr() flat.NodeId {
	is_rlock := p.tok == .key_rlock
	p.next() // skip 'lock' or 'rlock'
	mut obj_ids := []flat.NodeId{}
	// lock objects
	if p.tok != .lcbr {
		obj_ids << p.a.add_val(.ident, p.expect_name())
		for p.tok == .comma {
			p.next()
			obj_ids << p.a.add_val(.ident, p.expect_name())
		}
	}
	body := p.block_stmt()
	mut ids := obj_ids.clone()
	ids << body
	lstart := p.add_children(ids)
	return p.a.add_node(flat.Node{
		kind:           .lock_expr
		value:          if is_rlock { 'rlock' } else { 'lock' }
		children_start: lstart
		children_count: ids.len
	})
}

fn (mut p Parser) select_expr() flat.NodeId {
	p.next() // skip 'select'
	p.check(.lcbr)
	mut ids := []flat.NodeId{}
	for p.tok != .rcbr && p.tok != .eof {
		if p.tok == .semicolon {
			p.next()
			continue
		}
		ids << p.select_branch()
	}
	p.check(.rcbr)
	start := p.add_children(ids)
	return p.a.add_node(flat.Node{
		kind:           .select_stmt
		children_start: start
		children_count: ids.len
	})
}

fn (mut p Parser) select_branch() flat.NodeId {
	mut is_else := false
	mut cond_ids := []flat.NodeId{}
	if p.tok == .key_else {
		is_else = true
		p.next()
	} else {
		cond_ids << p.expr(.lowest)
		// could be assignment: ch <- val or val := <-ch
		if p.tok.is_assignment() || p.tok == .decl_assign {
			op := p.tok
			p.next()
			cond_ids << p.expr(.lowest)
			_ = op
		}
	}
	mut body_ids := []flat.NodeId{}
	if p.tok == .lcbr {
		body_ids = p.parse_block_body()
	}
	mut all_ids := cond_ids.clone()
	for id in body_ids {
		all_ids << id
	}
	start := p.add_children(all_ids)
	return p.a.add_node(flat.Node{
		kind:           .select_branch
		value:          if is_else { 'else' } else { '' }
		children_start: start
		children_count: all_ids.len
	})
}

fn (mut p Parser) sizeof_expr() flat.NodeId {
	p.next() // skip 'sizeof'
	p.check(.lpar)
	type_name := p.parse_type_name()
	p.check(.rpar)
	return p.a.add_val(.sizeof_expr, type_name)
}

fn (mut p Parser) typeof_expr() flat.NodeId {
	p.next() // skip 'typeof'
	p.check(.lpar)
	inner := p.expr(.lowest)
	p.check(.rpar)
	tstart := p.add_child(inner)
	return p.a.add_node(flat.Node{
		kind:           .typeof_expr
		children_start: tstart
		children_count: 1
	})
}

fn (mut p Parser) dump_expr() flat.NodeId {
	p.next() // skip 'dump'
	p.check(.lpar)
	inner := p.expr(.lowest)
	p.check(.rpar)
	dstart := p.add_child(inner)
	return p.a.add_node(flat.Node{
		kind:           .dump_expr
		children_start: dstart
		children_count: 1
	})
}

fn (mut p Parser) offsetof_expr() flat.NodeId {
	p.next() // skip '__offsetof'
	p.check(.lpar)
	type_name := p.parse_type_name()
	p.check(.comma)
	field_name := p.expect_name()
	p.check(.rpar)
	return p.a.add_node(flat.Node{
		kind:  .offsetof_expr
		value: type_name
		typ:   field_name
	})
}

// ==================== types ====================

fn (mut p Parser) parse_type_name() string {
	// option ?T
	if p.tok == .question {
		p.next()
		inner := p.parse_type_name()
		if inner.len > 0 {
			return '?' + inner
		}
		return '?'
	}
	// result !T
	if p.tok == .not {
		p.next()
		inner := p.parse_type_name()
		if inner.len > 0 {
			return '!' + inner
		}
		return '!'
	}
	// pointer &T
	if p.tok == .amp {
		p.next()
		return '&' + p.parse_type_name()
	}
	// variadic ...T
	if p.tok == .ellipsis {
		p.next()
		return '...' + p.parse_type_name()
	}
	// array []T or fixed [N]T
	if p.tok == .lsbr {
		p.next()
		if p.tok == .rsbr {
			p.next()
			return '[]' + p.parse_type_name()
		}
		// fixed array [N]T
		mut len_lit := p.lit
		p.next()
		p.check(.rsbr)
		return '[${len_lit}]' + p.parse_type_name()
	}
	// multi-return (T, U)
	if p.tok == .lpar {
		p.next()
		mut type_list := []string{}
		type_list << p.parse_type_name()
		for p.tok == .comma {
			p.next()
			type_list << p.parse_type_name()
		}
		p.check(.rpar)
		return '(' + type_list.join(', ') + ')'
	}
	// function type fn(T) U
	if p.tok == .key_fn {
		p.next()
		if p.tok != .lpar {
			return 'fn'
		}
		p.next()
		mut ptypes := []string{}
		for p.tok != .rpar && p.tok != .eof {
			typ := p.parse_type_name()
			if p.tok != .comma && p.tok != .rpar && p.tok != .eof {
				ptypes << p.parse_type_name()
			} else {
				ptypes << typ
			}
			if p.tok == .comma {
				p.next()
			}
		}
		p.check(.rpar)
		mut ret := ''
		if p.tok == .name || p.tok == .amp || p.tok == .question || p.tok == .not || p.tok == .lsbr || p.tok == .lpar || p.tok == .key_fn {
			ret = p.parse_type_name()
		}
		if ret.len > 0 {
			return 'fn(${ptypes.join(', ')}) ${ret}'
		}
		return 'fn(${ptypes.join(', ')})'
	}
	// atomic / shared modifier
	if p.tok == .key_atomic || p.tok == .key_shared {
		modifier := p.lit
		p.next()
		return '${modifier} ' + p.parse_type_name()
	}
	// nil type
	if p.tok == .key_nil {
		p.next()
		return 'nil'
	}
	// none type
	if p.tok == .key_none {
		p.next()
		return 'none'
	}
	// struct type (inline/anonymous)
	if p.tok == .key_struct {
		p.next()
		if p.tok == .lcbr {
			p.skip_block()
		}
		return 'struct'
	}
	// name
	mut name := ''
	if p.tok == .name {
		name = p.lit
		p.next()
		// map[K]V
		if name == 'map' && p.tok == .lsbr {
			p.next()
			key := p.parse_type_name()
			p.check(.rsbr)
			val := p.parse_type_name()
			return 'map[${key}]${val}'
		}
		// chan T
		if name == 'chan' {
			if p.tok == .name || p.tok == .amp || p.tok == .lsbr || p.tok == .question {
				elem := p.parse_type_name()
				return 'chan ${elem}'
			}
			return 'chan'
		}
		// thread T
		if name == 'thread' {
			if p.tok == .name || p.tok == .amp || p.tok == .lsbr || p.tok == .question {
				elem := p.parse_type_name()
				return 'thread ${elem}'
			}
			return 'thread'
		}
		// qualified: mod.Type
		if p.tok == .dot {
			p.next()
			if p.tok == .name {
				name += '.' + p.lit
				p.next()
			}
		}
		// generic: Type[T, U]
		if p.tok == .lsbr {
			// peek ahead to distinguish generic from index
			pk := p.peek()
			if pk == .name || pk == .amp || pk == .lsbr || pk == .question || pk == .rsbr || pk == .key_fn {
				p.next() // skip [
				mut params := []string{}
				params << p.parse_type_name()
				for p.tok == .comma {
					p.next()
					params << p.parse_type_name()
				}
				p.check(.rsbr)
				name += '[' + params.join(', ') + ']'
			}
		}
	}
	return name
}

// ==================== helpers ====================

fn strip_quotes(s string) string {
	if s.len >= 2 && ((s[0] == `'` && s[s.len - 1] == `'`) || (s[0] == `"` && s[s.len - 1] == `"`)) {
		return s[1..s.len - 1]
	}
	if s.len >= 1 && (s[0] == `'` || s[0] == `"`) {
		return s[1..]
	}
	if s.len >= 1 && (s[s.len - 1] == `'` || s[s.len - 1] == `"`) {
		return s[..s.len - 1]
	}
	return s
}

fn is_builtin_type(name string) bool {
	return name in ['int', 'i8', 'i16', 'i32', 'i64', 'u8', 'u16', 'u32', 'u64', 'f32', 'f64',
		'byte', 'bool', 'string', 'rune', 'char', 'voidptr', 'charptr', 'usize', 'isize']
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
		.mod_assign { flat.Op.mod_assign }
		.and_assign { flat.Op.amp_assign }
		.or_assign { flat.Op.pipe_assign }
		.xor_assign { flat.Op.xor_assign }
		.left_shift_assign { flat.Op.left_shift_assign }
		.right_shift_assign { flat.Op.right_shift_assign }
		.inc { flat.Op.inc }
		.dec { flat.Op.dec }
		.decl_assign { flat.Op.assign }
		else { flat.Op.none }
	}
}
