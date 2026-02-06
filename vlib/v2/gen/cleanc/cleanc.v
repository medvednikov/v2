// Copyright (c) 2026 Alexander Medvednikov. All rights reserved.
// Use of this source code is governed by an MIT license
// that can be found in the LICENSE file.

module cleanc

import v2.ast
import v2.pref
import v2.types
import strings

pub struct Gen {
	files []ast.File
	env   &types.Environment = unsafe { nil }
	pref  &pref.Preferences  = unsafe { nil }
mut:
	sb                strings.Builder
	indent            int
	cur_fn_scope      &types.Scope = unsafe { nil }
	cur_fn_name       string
	cur_module        string
	emitted_types     map[string]bool
	array_aliases     map[string]bool
	map_aliases       map[string]bool
	result_aliases    map[string]bool
	option_aliases    map[string]bool
	module_type_names map[string]bool
}

struct StructDeclInfo {
	decl   ast.StructDecl
	module string
}

const primitive_types = ['int', 'i8', 'i16', 'i32', 'i64', 'u8', 'u16', 'u32', 'u64', 'f32', 'f64',
	'bool', 'rune', 'byte', 'voidptr', 'charptr', 'usize', 'isize', 'void', 'char', 'byteptr',
	'float_literal', 'int_literal']

fn is_empty_stmt(s ast.Stmt) bool {
	return s is ast.EmptyStmt
}

fn is_empty_expr(e ast.Expr) bool {
	return e is ast.EmptyExpr
}

pub fn Gen.new(files []ast.File) &Gen {
	return Gen.new_with_env_and_pref(files, unsafe { nil }, unsafe { nil })
}

pub fn Gen.new_with_env(files []ast.File, env &types.Environment) &Gen {
	return Gen.new_with_env_and_pref(files, env, unsafe { nil })
}

pub fn Gen.new_with_env_and_pref(files []ast.File, env &types.Environment, p &pref.Preferences) &Gen {
	return &Gen{
		files:             files
		env:               unsafe { env }
		pref:              unsafe { p }
		sb:                strings.new_builder(4096)
		array_aliases:     map[string]bool{}
		map_aliases:       map[string]bool{}
		result_aliases:    map[string]bool{}
		option_aliases:    map[string]bool{}
		module_type_names: map[string]bool{}
	}
}

pub fn (mut g Gen) gen() string {
	g.write_preamble()
	g.collect_module_type_names()
	g.collect_runtime_aliases()

	// Pass 1: Forward declarations for all structs/unions/sumtypes/interfaces (needed for mutual references)
	for file in g.files {
		g.set_file_module(file)
		for stmt in file.stmts {
			if stmt is ast.StructDecl {
				if stmt.language == .c {
					continue
				}
				name := g.get_struct_name(stmt)
				if name in g.emitted_types {
					continue
				}
				g.emitted_types[name] = true
				keyword := if stmt.is_union { 'union' } else { 'struct' }
				g.sb.writeln('typedef ${keyword} ${name} ${name};')
			} else if stmt is ast.TypeDecl {
				if stmt.variants.len > 0 {
					// Sum type needs forward struct declaration
					name := g.get_type_decl_name(stmt)
					if name !in g.emitted_types {
						g.emitted_types[name] = true
						g.sb.writeln('typedef struct ${name} ${name};')
					}
				}
			} else if stmt is ast.InterfaceDecl {
				name := g.get_interface_name(stmt)
				if name !in g.emitted_types {
					g.emitted_types[name] = true
					g.sb.writeln('typedef struct ${name} ${name};')
				}
			}
		}
	}
	g.sb.writeln('')
	g.emit_runtime_aliases()
	g.sb.writeln('')

	// Pass 2: Enum declarations, type aliases, interface structs, and sum type structs
	// (before struct definitions that may reference them)
	for file in g.files {
		g.set_file_module(file)
		for stmt in file.stmts {
			if stmt is ast.EnumDecl {
				g.gen_enum_decl(stmt)
			} else if stmt is ast.TypeDecl {
				if stmt.variants.len == 0 && stmt.base_type !is ast.EmptyExpr {
					g.gen_type_alias(stmt)
				} else if stmt.variants.len > 0 {
					g.gen_sum_type_decl(stmt)
				}
			} else if stmt is ast.InterfaceDecl {
				g.gen_interface_decl(stmt)
			}
		}
	}

	// Pass 3: Full struct definitions (use named struct/union to match forward decls)
	// Collect all struct decls, then emit in dependency order
	mut all_structs := []StructDeclInfo{}
	for file in g.files {
		g.set_file_module(file)
		for stmt in file.stmts {
			if stmt is ast.StructDecl {
				if stmt.language == .c {
					continue
				}
				all_structs << StructDeclInfo{
					decl:   stmt
					module: g.cur_module
				}
			}
		}
	}
	// Emit structs with only primitive fields first, then the rest
	// Repeat until all are emitted (simple topo sort)
	for _ in 0 .. all_structs.len {
		mut emitted_any := false
		for info in all_structs {
			g.cur_module = info.module
			name := g.get_struct_name(info.decl)
			if 'body_${name}' in g.emitted_types {
				continue
			}
			// Check if all field types are already defined
			if g.struct_fields_resolved(info.decl) {
				g.gen_struct_decl(info.decl)
				emitted_any = true
			}
		}
		if !emitted_any {
			break
		}
	}
	// Emit any remaining structs (circular deps - just emit them)
	for info in all_structs {
		g.cur_module = info.module
		g.gen_struct_decl(info.decl)
	}

	// Pass 4: Function forward declarations
	for file in g.files {
		g.set_file_module(file)
		for stmt in file.stmts {
				if stmt is ast.FnDecl {
					if stmt.language == .c {
						continue
					}
					fn_name := g.get_fn_name(stmt)
					if fn_name == '' {
						continue
					}
					if g.env != unsafe { nil } {
						if fn_scope := g.env.get_fn_scope(g.cur_module, fn_name) {
							g.cur_fn_scope = fn_scope
						}
					}
				g.gen_fn_head(stmt)
				g.sb.writeln(';')
			}
		}
	}
	g.sb.writeln('')

	// Pass 5: Everything else (function bodies, consts, globals, etc.)
	for file in g.files {
		g.gen_file(file)
	}

	return g.sb.str()
}

fn (mut g Gen) write_preamble() {
	g.sb.writeln('// Generated by V Clean C Backend')
	g.sb.writeln('#include <stdio.h>')
	g.sb.writeln('#include <stdlib.h>')
	g.sb.writeln('#include <stdbool.h>')
	g.sb.writeln('#include <stdint.h>')
	g.sb.writeln('#include <stddef.h>')
	g.sb.writeln('#include <string.h>')
	g.sb.writeln('')

	// V primitive type aliases
	g.sb.writeln('// V primitive types')
	g.sb.writeln('typedef int8_t i8;')
	g.sb.writeln('typedef int16_t i16;')
	g.sb.writeln('typedef int32_t i32;')
	g.sb.writeln('typedef int64_t i64;')
	g.sb.writeln('typedef uint8_t u8;')
	g.sb.writeln('typedef uint16_t u16;')
	g.sb.writeln('typedef uint32_t u32;')
	g.sb.writeln('typedef uint64_t u64;')
	g.sb.writeln('typedef float f32;')
	g.sb.writeln('typedef double f64;')
	g.sb.writeln('typedef u8 byte;')
	g.sb.writeln('typedef size_t usize;')
	g.sb.writeln('typedef ptrdiff_t isize;')
	g.sb.writeln('typedef u32 rune;')
	g.sb.writeln('typedef char* byteptr;')
	g.sb.writeln('typedef char* charptr;')
	g.sb.writeln('typedef void* voidptr;')
	g.sb.writeln('typedef void* chan;')
	g.sb.writeln('typedef double float_literal;')
	g.sb.writeln('typedef int64_t int_literal;')
	// Minimal wyhash symbols used by builtin/map and hash modules.
	g.sb.writeln('static const u64 _wyp[4] = {0xa0761d6478bd642full, 0xe7037ed1a0b428dbull, 0x8ebc6af09c88c6e3ull, 0x589965cc75374cc3ull};')
	g.sb.writeln('static inline u64 wyhash(const void* key, u64 len, u64 seed, const u64* secret) { (void)key; (void)len; (void)seed; (void)secret; return 0; }')
	g.sb.writeln('static inline u64 wyhash64(u64 a, u64 b) { (void)a; (void)b; return 0; }')
	g.sb.writeln('')
	g.sb.writeln('')
}

fn is_c_identifier_like(name string) bool {
	if name.len == 0 {
		return false
	}
	for ch in name {
		if !(ch.is_letter() || ch.is_digit() || ch == `_`) {
			return false
		}
	}
	return true
}

fn (mut g Gen) collect_module_type_names() {
	for file in g.files {
		g.set_file_module(file)
		for stmt in file.stmts {
			match stmt {
				ast.StructDecl {
					if stmt.language == .c {
						continue
					}
					g.module_type_names['${g.cur_module}::${stmt.name}'] = true
				}
				ast.EnumDecl {
					g.module_type_names['${g.cur_module}::${stmt.name}'] = true
				}
				ast.TypeDecl {
					if stmt.language == .c {
						continue
					}
					g.module_type_names['${g.cur_module}::${stmt.name}'] = true
				}
				ast.InterfaceDecl {
					g.module_type_names['${g.cur_module}::${stmt.name}'] = true
				}
				else {}
			}
		}
	}
}

fn (mut g Gen) collect_runtime_aliases() {
	for file in g.files {
		g.set_file_module(file)
		for stmt in file.stmts {
			g.collect_decl_type_aliases_from_stmt(stmt)
		}
	}
	// Also use type-checker output so aliases used only in expressions are captured.
	if g.env != unsafe { nil } {
		for _, typ in g.env.expr_types {
			g.collect_aliases_from_type(typ)
		}
	}
}

fn (mut g Gen) collect_aliases_from_type(t types.Type) {
	match t {
		types.Array {
			g.collect_aliases_from_type(t.elem_type)
			g.register_alias_type('Array_${g.types_type_to_c(t.elem_type)}')
		}
		types.ArrayFixed {
			g.collect_aliases_from_type(t.elem_type)
			g.register_alias_type('Array_${g.types_type_to_c(t.elem_type)}')
		}
		types.Map {
			g.collect_aliases_from_type(t.key_type)
			g.collect_aliases_from_type(t.value_type)
			g.register_alias_type('Map_${g.types_type_to_c(t.key_type)}_${g.types_type_to_c(t.value_type)}')
		}
		types.OptionType {
			g.collect_aliases_from_type(t.base_type)
			g.register_alias_type('_option_${g.types_type_to_c(t.base_type)}')
		}
		types.ResultType {
			g.collect_aliases_from_type(t.base_type)
			g.register_alias_type('_result_${g.types_type_to_c(t.base_type)}')
		}
		types.Alias {
			g.collect_aliases_from_type(t.base_type)
			g.register_alias_type(t.name)
		}
		types.Pointer {
			g.collect_aliases_from_type(t.base_type)
		}
		else {}
	}
}

fn (mut g Gen) collect_decl_type_aliases_from_stmt(stmt ast.Stmt) {
	match stmt {
		ast.StructDecl {
			if stmt.language == .c {
				return
			}
			for emb in stmt.embedded {
				_ = g.expr_type_to_c(emb)
			}
			for field in stmt.fields {
				if field.typ !is ast.EmptyExpr {
					_ = g.expr_type_to_c(field.typ)
				}
			}
		}
		ast.InterfaceDecl {
			for field in stmt.fields {
				if field.typ !is ast.EmptyExpr {
					_ = g.expr_type_to_c(field.typ)
				}
			}
		}
		ast.TypeDecl {
			if stmt.language == .c {
				return
			}
			if stmt.base_type !is ast.EmptyExpr {
				_ = g.expr_type_to_c(stmt.base_type)
			}
			for variant in stmt.variants {
				_ = g.expr_type_to_c(variant)
			}
		}
		ast.FnDecl {
			if stmt.language == .c {
				return
			}
			if stmt.is_method && stmt.receiver.typ !is ast.EmptyExpr {
				_ = g.expr_type_to_c(stmt.receiver.typ)
			}
			for param in stmt.typ.params {
				_ = g.expr_type_to_c(param.typ)
			}
			if stmt.typ.return_type !is ast.EmptyExpr {
				_ = g.expr_type_to_c(stmt.typ.return_type)
			}
		}
		ast.GlobalDecl {
			for field in stmt.fields {
				if field.typ !is ast.EmptyExpr {
					_ = g.expr_type_to_c(field.typ)
				}
			}
		}
		else {}
	}
}

fn (mut g Gen) register_alias_type(name string) {
	if !is_c_identifier_like(name) {
		return
	}
	if name.starts_with('Array_') || name.starts_with('Array_fixed_') {
		g.array_aliases[name] = true
		return
	}
	if name.starts_with('Map_') {
		g.map_aliases[name] = true
		return
	}
	if name.starts_with('_result_') {
		g.result_aliases[name] = true
		return
	}
	if name.starts_with('_option_') {
		g.option_aliases[name] = true
	}
}

fn (mut g Gen) emit_runtime_aliases() {
	mut array_names := g.array_aliases.keys()
	array_names.sort()
	for name in array_names {
		g.sb.writeln('typedef array ${name};')
	}
	mut map_names := g.map_aliases.keys()
	map_names.sort()
	for name in map_names {
		g.sb.writeln('typedef map ${name};')
	}
	mut option_names := g.option_aliases.keys()
	option_names.sort()
	for name in option_names {
		g.sb.writeln('typedef _option ${name};')
	}
	mut result_names := g.result_aliases.keys()
	result_names.sort()
	for name in result_names {
		g.sb.writeln('typedef _result ${name};')
	}
}

fn (mut g Gen) set_file_module(file ast.File) {
	for stmt in file.stmts {
		if stmt is ast.ModuleStmt {
			g.cur_module = stmt.name.replace('.', '_')
			return
		}
	}
	// Files without a module declaration are in the 'main' module
	g.cur_module = 'main'
}

fn (mut g Gen) gen_file(file ast.File) {
	g.set_file_module(file)
	for stmt in file.stmts {
		// Skip struct/enum/type/interface decls - already emitted in earlier passes
		if stmt is ast.StructDecl || stmt is ast.EnumDecl || stmt is ast.TypeDecl
			|| stmt is ast.InterfaceDecl {
			continue
		}
		g.gen_stmt(stmt)
	}
}

fn (mut g Gen) gen_stmts(stmts []ast.Stmt) {
	for s in stmts {
		g.gen_stmt(s)
	}
}

fn (mut g Gen) gen_stmt(node ast.Stmt) {
	match node {
		ast.FnDecl {
			g.gen_fn_decl(node)
		}
		ast.AssignStmt {
			g.gen_assign_stmt(node)
		}
		ast.ExprStmt {
			g.write_indent()
			g.gen_expr(node.expr)
			g.sb.writeln(';')
		}
		ast.ReturnStmt {
			g.write_indent()
			g.sb.write_string('return')
			if node.exprs.len > 0 {
				g.sb.write_string(' ')
				g.gen_expr(node.exprs[0])
			}
			g.sb.writeln(';')
		}
		ast.ForStmt {
			g.gen_for_stmt(node)
		}
		ast.FlowControlStmt {
			g.write_indent()
			if node.op == .key_break {
				g.sb.writeln('break;')
			} else if node.op == .key_continue {
				g.sb.writeln('continue;')
			}
		}
		ast.ModuleStmt {
			g.cur_module = node.name.replace('.', '_')
		}
		ast.ImportStmt {}
		ast.ConstDecl {
			g.gen_const_decl(node)
		}
		ast.StructDecl {
			g.gen_struct_decl(node)
		}
		ast.EnumDecl {
			g.gen_enum_decl(node)
		}
		ast.TypeDecl {
			if node.variants.len > 0 {
				g.gen_sum_type_decl(node)
			} else if node.base_type !is ast.EmptyExpr {
				g.gen_type_alias(node)
			}
		}
		ast.InterfaceDecl {
			g.gen_interface_decl(node)
		}
		ast.GlobalDecl {
			g.write_indent()
			g.sb.writeln('/* [TODO] GlobalDecl (${node.fields.len} fields) */')
		}
		ast.Directive {
			g.write_indent()
			g.sb.writeln('/* [TODO] Directive: #${node.name} ${node.value} */')
		}
		ast.ForInStmt {
			panic('bug in v2 compiler: ForInStmt should have been lowered in v2.transformer')
		}
		ast.DeferStmt {
			panic('bug in v2 compiler: DeferStmt should have been lowered in v2.transformer')
		}
		ast.AssertStmt {
			g.write_indent()
			g.sb.writeln('/* [TODO] AssertStmt */')
		}
		ast.ComptimeStmt {
			panic('bug in v2 compiler: ComptimeStmt should have been handled in v2.transformer')
		}
		ast.BlockStmt {
			g.write_indent()
			g.sb.writeln('/* [TODO] BlockStmt */')
		}
		ast.LabelStmt {
			g.write_indent()
			g.sb.writeln('/* [TODO] LabelStmt: ${node.name} */')
		}
		ast.AsmStmt {
			g.write_indent()
			g.sb.writeln('/* [TODO] AsmStmt */')
		}
		[]ast.Attribute {}
		ast.EmptyStmt {}
		// else {}
	}
}

fn (mut g Gen) gen_fn_decl(node ast.FnDecl) {
	// Skip C extern function declarations (e.g., fn C.puts(...))
	if node.language == .c {
		return
	}
	fn_name := g.get_fn_name(node)
	if fn_name == '' {
		return
	}

	// Set function scope for type lookups
	g.cur_fn_name = node.name
	if g.env != unsafe { nil } {
		if fn_scope := g.env.get_fn_scope(g.cur_module, fn_name) {
			g.cur_fn_scope = fn_scope
		} else {
			g.cur_fn_scope = unsafe { nil }
		}
	}

	// Generate function header
	g.gen_fn_head(node)
	g.sb.writeln(' {')
	g.indent++

	// Main function: initialize argc/argv
	if node.name == 'main' {
		g.write_indent()
		g.sb.writeln('(void)___argc; (void)___argv;')
	}

	g.gen_stmts(node.stmts)

	// Implicit return 0 for main
	if node.name == 'main' {
		g.write_indent()
		g.sb.writeln('return 0;')
	}

	g.indent--
	g.sb.writeln('}')
	g.sb.writeln('')
}

fn (mut g Gen) gen_fn_head(node ast.FnDecl) {
	mut ret := 'void'
	if node.typ.return_type !is ast.EmptyExpr {
		ret = g.expr_type_to_c(node.typ.return_type)
	}
	if node.name == 'main' {
		ret = 'int'
	}

	fn_name := g.get_fn_name(node)

	// main takes argc/argv
	if node.name == 'main' {
		g.sb.write_string('${ret} ${fn_name}(int ___argc, char** ___argv)')
		return
	}

	g.sb.write_string('${ret} ${fn_name}(')

	mut first := true
	// Receiver as first param for methods
	if node.is_method && node.receiver.name != '' {
		receiver_type := g.expr_type_to_c(node.receiver.typ)
		if node.receiver.is_mut {
			g.sb.write_string('${receiver_type}* ${node.receiver.name}')
		} else {
			g.sb.write_string('${receiver_type} ${node.receiver.name}')
		}
		first = false
	}

	for param in node.typ.params {
		if !first {
			g.sb.write_string(', ')
		}
		first = false
		t := g.expr_type_to_c(param.typ)
		if param.is_mut {
			g.sb.write_string('${t}* ${param.name}')
		} else {
			g.sb.write_string('${t} ${param.name}')
		}
	}
	g.sb.write_string(')')
}

fn (mut g Gen) get_fn_name(node ast.FnDecl) string {
	if node.name == 'main' {
		return 'main'
	}
	// Prevent collisions with libc symbols from builtin wrappers.
	if !node.is_method && node.name in c_stdlib_fns
		&& (g.cur_module == '' || g.cur_module == 'main' || g.cur_module == 'builtin') {
		return ''
	}
	name := sanitize_fn_ident(node.name)
	// Methods: ReceiverType__method_name
	if node.is_method && node.receiver.name != '' {
		receiver_type := g.expr_type_to_c(node.receiver.typ)
		// Strip pointer suffix for method naming
		base_type := if receiver_type.ends_with('*') {
			receiver_type[..receiver_type.len - 1]
		} else {
			receiver_type
		}
		return '${base_type}__${name}'
	}
	if g.cur_module != '' && g.cur_module != 'main' && g.cur_module != 'builtin' {
		return '${g.cur_module}__${name}'
	}
	return name
}

fn (mut g Gen) gen_assign_stmt(node ast.AssignStmt) {
	lhs := node.lhs[0]
	rhs := node.rhs[0]

	// Check for blank identifier
	if lhs is ast.Ident && lhs.name == '_' {
		g.write_indent()
		g.sb.write_string('(void)(')
		g.gen_expr(rhs)
		g.sb.writeln(');')
		return
	}

	g.write_indent()
	if node.op == .decl_assign {
		// Variable declaration: type name = expr
		mut name := ''
		if lhs is ast.Ident {
			name = lhs.name
		} else if lhs is ast.ModifierExpr {
			if lhs.expr is ast.Ident {
				name = lhs.expr.name
			}
		}
		typ := g.get_expr_type(rhs)
		g.sb.write_string('${typ} ${name} = ')
		g.gen_expr(rhs)
		g.sb.writeln(';')
	} else {
		// Assignment
		g.gen_expr(lhs)
		op_str := match node.op {
			.assign { '=' }
			.plus_assign { '+=' }
			.minus_assign { '-=' }
			.mul_assign { '*=' }
			.div_assign { '/=' }
			.mod_assign { '%=' }
			.and_assign { '&=' }
			.or_assign { '|=' }
			.xor_assign { '^=' }
			.left_shift_assign { '<<=' }
			.right_shift_assign { '>>=' }
			else { '=' }
		}
		g.sb.write_string(' ${op_str} ')
		g.gen_expr(rhs)
		g.sb.writeln(';')
	}
}

fn (mut g Gen) gen_for_stmt(node ast.ForStmt) {
	g.write_indent()
	has_init := !is_empty_stmt(node.init)
	has_cond := !is_empty_expr(node.cond)
	has_post := !is_empty_stmt(node.post)

	if has_init || has_post {
		// C-style for loop: for (init; cond; post)
		g.sb.write_string('for (')
		if has_init {
			g.gen_stmt_inline(node.init)
		}
		g.sb.write_string('; ')
		if has_cond {
			g.gen_expr(node.cond)
		}
		g.sb.write_string('; ')
		if has_post {
			g.gen_stmt_inline(node.post)
		}
		g.sb.writeln(') {')
	} else if has_cond {
		// while-style: for cond {
		g.sb.write_string('while (')
		g.gen_expr(node.cond)
		g.sb.writeln(') {')
	} else {
		// Infinite loop: for {
		g.sb.writeln('for (;;) {')
	}

	g.indent++
	g.gen_stmts(node.stmts)
	g.indent--
	g.write_indent()
	g.sb.writeln('}')
}

fn (mut g Gen) gen_stmt_inline(node ast.Stmt) {
	match node {
		ast.AssignStmt {
			lhs := node.lhs[0]
			rhs := node.rhs[0]
			if node.op == .decl_assign {
				mut name := ''
				if lhs is ast.Ident {
					name = lhs.name
				}
				typ := g.get_expr_type(rhs)
				g.sb.write_string('${typ} ${name} = ')
				g.gen_expr(rhs)
			} else {
				g.gen_expr(lhs)
				op_str := match node.op {
					.assign { '=' }
					.plus_assign { '+=' }
					.minus_assign { '-=' }
					else { '=' }
				}
				g.sb.write_string(' ${op_str} ')
				g.gen_expr(rhs)
			}
		}
		ast.ExprStmt {
			g.gen_expr(node.expr)
		}
		else {}
	}
}

const c_keywords = ['auto', 'break', 'case', 'char', 'const', 'continue', 'default', 'do', 'double',
	'else', 'enum', 'extern', 'float', 'for', 'goto', 'if', 'inline', 'int', 'long', 'register',
	'restrict', 'return', 'short', 'signed', 'sizeof', 'static', 'struct', 'switch', 'typedef',
	'union', 'unsigned', 'void', 'volatile', 'while', '_Bool', '_Complex', '_Imaginary']

const c_stdlib_fns = ['malloc', 'calloc', 'realloc', 'free', 'atoi', 'atof', 'atol', 'memcpy',
	'memset', 'memmove', 'strlen', 'strcpy', 'strcat', 'strcmp', 'memcmp']

fn escape_c_keyword(name string) string {
	if name in c_keywords {
		return '_${name}'
	}
	return name
}

fn sanitize_fn_ident(name string) string {
	return match name {
		'+' { 'plus' }
		'-' { 'minus' }
		'*' { 'mul' }
		'/' { 'div' }
		'%' { 'mod' }
		'==' { 'eq' }
		'!=' { 'ne' }
		'<' { 'lt' }
		'>' { 'gt' }
		'<=' { 'le' }
		'>=' { 'ge' }
		'|' { 'pipe' }
		'^' { 'xor' }
		else { name }
	}
}

// Check if all non-pointer field types of a struct are already defined
fn (g &Gen) struct_fields_resolved(node ast.StructDecl) bool {
	for field in node.fields {
		typ_name := g.field_type_name(field.typ)
		if typ_name == '' {
			continue
		}
		// Pointer types are fine with forward declarations
		if g.is_pointer_type(field.typ) {
			continue
		}
		// Primitive types are always resolved
		if typ_name in primitive_types {
			continue
		}
		// Check if this type's body has been emitted
		if 'body_${typ_name}' !in g.emitted_types && 'enum_${typ_name}' !in g.emitted_types
			&& 'alias_${typ_name}' !in g.emitted_types {
			return false
		}
	}
	return true
}

fn (g &Gen) field_type_name(e ast.Expr) string {
	match e {
		ast.Ident {
			if g.is_module_local_type(e.name) {
				return '${g.cur_module}__${e.name}'
			}
			return e.name
		}
		ast.SelectorExpr {
			if e.lhs is ast.Ident {
				return '${e.lhs.name}__${e.rhs.name}'
			}
			return ''
		}
		ast.PrefixExpr {
			return g.field_type_name(e.expr)
		}
		else {
			return ''
		}
	}
}

fn (g &Gen) is_pointer_type(e ast.Expr) bool {
	if e is ast.PrefixExpr {
		return e.op == .amp
	}
	if e is ast.Ident {
		return e.name in ['voidptr', 'charptr', 'byteptr']
	}
	return false
}

fn (mut g Gen) get_struct_name(node ast.StructDecl) string {
	if g.cur_module != '' && g.cur_module != 'main' && g.cur_module != 'builtin' {
		return '${g.cur_module}__${node.name}'
	}
	return node.name
}

fn (mut g Gen) gen_struct_decl(node ast.StructDecl) {
	// Skip C extern struct declarations
	if node.language == .c {
		return
	}

	name := g.get_struct_name(node)
	body_key := 'body_${name}'
	if body_key in g.emitted_types {
		return
	}
	g.emitted_types[body_key] = true
	keyword := if node.is_union { 'union' } else { 'struct' }

	// Use named struct to match the forward declaration: typedef struct name name;
	g.sb.writeln('${keyword} ${name} {')
	// Embedded structs as fields
	for emb in node.embedded {
		emb_type := g.expr_type_to_c(emb)
		g.sb.writeln('\t${emb_type} ${emb_type};')
	}
	// Regular fields
	for field in node.fields {
		field_name := escape_c_keyword(field.name)
		field_type := g.expr_type_to_c(field.typ)
		g.sb.writeln('\t${field_type} ${field_name};')
	}
	g.sb.writeln('};')
	g.sb.writeln('')
}

fn (mut g Gen) get_enum_name(node ast.EnumDecl) string {
	if g.cur_module != '' && g.cur_module != 'main' && g.cur_module != 'builtin' {
		return '${g.cur_module}__${node.name}'
	}
	return node.name
}

fn (mut g Gen) gen_enum_decl(node ast.EnumDecl) {
	name := g.get_enum_name(node)
	enum_key := 'enum_${name}'
	if enum_key in g.emitted_types {
		return
	}
	g.emitted_types[enum_key] = true
	is_flag := node.attributes.has('flag')

	g.sb.writeln('typedef enum {')
	for i, field in node.fields {
		g.sb.write_string('\t${name}__${field.name}')
		if field.value !is ast.EmptyExpr {
			g.sb.write_string(' = ')
			g.gen_expr(field.value)
		} else if is_flag {
			g.sb.write_string(' = ${u64(1) << i}U')
		}
		if i < node.fields.len - 1 {
			g.sb.writeln(',')
		} else {
			g.sb.writeln('')
		}
	}
	g.sb.writeln('} ${name};')
	g.sb.writeln('')
}

fn (mut g Gen) get_type_decl_name(node ast.TypeDecl) string {
	if g.cur_module != '' && g.cur_module != 'main' && g.cur_module != 'builtin' {
		return '${g.cur_module}__${node.name}'
	}
	return node.name
}

fn (mut g Gen) gen_type_alias(node ast.TypeDecl) {
	name := g.get_type_decl_name(node)
	// System-provided typedefs should not be redefined by generated builtin aliases.
	if name in ['intptr_t', 'uintptr_t'] {
		return
	}
	alias_key := 'alias_${name}'
	if alias_key in g.emitted_types {
		return
	}
	g.emitted_types[alias_key] = true

	// Check if base type is a function type - needs special syntax
	if node.base_type is ast.Type {
		if node.base_type is ast.FnType {
			fn_type := node.base_type as ast.FnType
			mut ret_type := 'void'
			if fn_type.return_type !is ast.EmptyExpr {
				ret_type = g.expr_type_to_c(fn_type.return_type)
			}
			g.sb.write_string('typedef ${ret_type} (*${name})(')
			for i, param in fn_type.params {
				if i > 0 {
					g.sb.write_string(', ')
				}
				param_type := g.expr_type_to_c(param.typ)
				if param.is_mut {
					g.sb.write_string('${param_type}*')
				} else {
					g.sb.write_string(param_type)
				}
			}
			g.sb.writeln(');')
			return
		}
	}
	base_type := g.expr_type_to_c(node.base_type)
	g.sb.writeln('typedef ${base_type} ${name};')
}

fn (mut g Gen) gen_sum_type_decl(node ast.TypeDecl) {
	name := g.get_type_decl_name(node)
	body_key := 'body_${name}'
	if body_key in g.emitted_types {
		return
	}
	g.emitted_types[body_key] = true

	g.sb.writeln('struct ${name} {')
	g.sb.writeln('\tint _tag;')
	g.sb.writeln('\tunion {')
	for i, variant in node.variants {
		variant_name := g.get_variant_field_name(variant, i)
		g.sb.writeln('\t\tvoid* ${variant_name};')
	}
	g.sb.writeln('\t} _data;')
	g.sb.writeln('};')
	g.sb.writeln('')
}

fn (g &Gen) get_variant_field_name(variant ast.Expr, idx int) string {
	if variant is ast.Ident {
		return '_${variant.name}'
	} else if variant is ast.SelectorExpr {
		if variant.lhs is ast.Ident {
			return '_${variant.lhs.name}__${variant.rhs.name}'
		}
		return '_${variant.rhs.name}'
	} else if variant is ast.Type {
		if variant is ast.ArrayType {
			elem := g.field_type_name(variant.elem_type)
			return '_Array_${elem}'
		}
		if variant is ast.MapType {
			key := g.field_type_name(variant.key_type)
			val := g.field_type_name(variant.value_type)
			return '_Map_${key}_${val}'
		}
	}
	return '_v${idx}'
}

fn (mut g Gen) get_interface_name(node ast.InterfaceDecl) string {
	if g.cur_module != '' && g.cur_module != 'main' && g.cur_module != 'builtin' {
		return '${g.cur_module}__${node.name}'
	}
	return node.name
}

fn (mut g Gen) gen_interface_decl(node ast.InterfaceDecl) {
	name := g.get_interface_name(node)
	body_key := 'body_${name}'
	if body_key in g.emitted_types {
		return
	}
	g.emitted_types[body_key] = true

	g.sb.writeln('struct ${name} {')
	g.sb.writeln('\tvoid* _object;')
	g.sb.writeln('\tint _type_id;')
	// Generate function pointers for each method
	for field in node.fields {
		if fn_type := g.get_fn_type_from_expr(field.typ) {
			mut ret := 'void'
			if fn_type.return_type !is ast.EmptyExpr {
				ret = g.expr_type_to_c(fn_type.return_type)
			}
			g.sb.write_string('\t${ret} (*${field.name})(void*')
			for param in fn_type.params {
				g.sb.write_string(', ')
				t := g.expr_type_to_c(param.typ)
				g.sb.write_string(t)
			}
			g.sb.writeln(');')
		} else {
			// Regular field
			t := g.expr_type_to_c(field.typ)
			g.sb.writeln('\t${t} ${field.name};')
		}
	}
	g.sb.writeln('};')
	g.sb.writeln('')
}

fn (g &Gen) is_enum_type(name string) bool {
	// Check emitted_types for enum_Name or enum_module__Name
	if 'enum_${name}' in g.emitted_types {
		return true
	}
	qualified := g.get_qualified_name(name)
	if 'enum_${qualified}' in g.emitted_types {
		return true
	}
	// Also check the types.Environment
	if g.env != unsafe { nil } {
		mut scope := lock g.env.scopes {
			g.env.scopes[g.cur_module] or { unsafe { nil } }
		}
		if scope != unsafe { nil } {
			if obj := scope.lookup_parent(name, 0) {
				if obj is types.Type {
					if obj is types.Enum {
						return true
					}
				}
			}
		}
	}
	return false
}

fn (g &Gen) get_qualified_name(name string) string {
	if g.cur_module != '' && g.cur_module != 'main' && g.cur_module != 'builtin' {
		return '${g.cur_module}__${name}'
	}
	return name
}

fn (g &Gen) is_type_name(name string) bool {
	if name in primitive_types {
		return true
	}
	// Check if it's a known emitted type (enum, struct, alias, sum type, interface)
	qualified := g.get_qualified_name(name)
	if 'enum_${name}' in g.emitted_types || 'enum_${qualified}' in g.emitted_types {
		return true
	}
	if 'body_${name}' in g.emitted_types || 'body_${qualified}' in g.emitted_types {
		return true
	}
	if 'alias_${name}' in g.emitted_types || 'alias_${qualified}' in g.emitted_types {
		return true
	}
	if name in g.emitted_types || qualified in g.emitted_types {
		return true
	}
	return false
}

// Helper to extract FnType from an Expr (handles ast.Type wrapping)
fn (g Gen) get_fn_type_from_expr(e ast.Expr) ?ast.FnType {
	if e is ast.Type {
		if e is ast.FnType {
			return e
		}
	}
	return none
}

fn (mut g Gen) gen_expr(node ast.Expr) {
	match node {
		ast.BasicLiteral {
			if node.kind == .key_true {
				g.sb.write_string('true')
			} else if node.kind == .key_false {
				g.sb.write_string('false')
			} else {
				g.sb.write_string(node.value)
			}
		}
		ast.StringLiteral {
			val := node.value.trim("'").trim('"')
			escaped := val.replace('"', '\\"')
			if node.kind == .c {
				// C string literal: emit raw C string
				g.sb.write_string('"${escaped}"')
			} else {
				g.sb.write_string('(string){"${escaped}", ${val.len}}')
			}
		}
		ast.Ident {
			if node.name == 'nil' {
				g.sb.write_string('NULL')
			} else {
				g.sb.write_string(node.name)
			}
		}
		ast.ParenExpr {
			g.sb.write_string('(')
			g.gen_expr(node.expr)
			g.sb.write_string(')')
		}
		ast.InfixExpr {
			g.sb.write_string('(')
			g.gen_expr(node.lhs)
			op := match node.op {
				.plus { '+' }
				.minus { '-' }
				.mul { '*' }
				.div { '/' }
				.mod { '%' }
				.gt { '>' }
				.lt { '<' }
				.eq { '==' }
				.ne { '!=' }
				.ge { '>=' }
				.le { '<=' }
				.and { '&&' }
				.logical_or { '||' }
				.amp { '&' }
				.pipe { '|' }
				.xor { '^' }
				.left_shift { '<<' }
				.right_shift { '>>' }
				else { '?' }
			}
			g.sb.write_string(' ${op} ')
			g.gen_expr(node.rhs)
			g.sb.write_string(')')
		}
		ast.PrefixExpr {
			// &T(x) in unsafe contexts is used as a pointer cast in V stdlib code.
			// Emit it as (T*)(x) so `*unsafe { &T(p) }` becomes `*((T*)p)`.
			if node.op == .amp {
				if node.expr is ast.CastExpr {
					target_type := g.expr_type_to_c(node.expr.typ)
					g.sb.write_string('((${target_type}*)(')
					g.gen_expr(node.expr.expr)
					g.sb.write_string('))')
					return
				}
				if node.expr is ast.CallOrCastExpr {
					if node.expr.lhs is ast.Ident && g.is_type_name(node.expr.lhs.name) {
						target_type := g.expr_type_to_c(node.expr.lhs)
						g.sb.write_string('((${target_type}*)(')
						g.gen_expr(node.expr.expr)
						g.sb.write_string('))')
						return
					}
				}
				if node.expr is ast.ParenExpr {
					if node.expr.expr is ast.CastExpr {
						target_type := g.expr_type_to_c(node.expr.expr.typ)
						g.sb.write_string('((${target_type}*)(')
						g.gen_expr(node.expr.expr.expr)
						g.sb.write_string('))')
						return
					}
					if node.expr.expr is ast.CallOrCastExpr {
						if node.expr.expr.lhs is ast.Ident && g.is_type_name(node.expr.expr.lhs.name) {
							target_type := g.expr_type_to_c(node.expr.expr.lhs)
							g.sb.write_string('((${target_type}*)(')
							g.gen_expr(node.expr.expr.expr)
							g.sb.write_string('))')
							return
						}
					}
				}
			}
			op := match node.op {
				.minus { '-' }
				.not { '!' }
				.amp { '&' }
				.mul { '*' }
				.bit_not { '~' }
				else { '' }
			}
			g.sb.write_string(op)
			g.gen_expr(node.expr)
		}
		ast.CallExpr {
			g.gen_call_expr(node.lhs, node.args)
		}
		ast.CallOrCastExpr {
			// Check if this is a type cast: int(x), MyInt(42), etc.
			if node.lhs is ast.Ident && g.is_type_name(node.lhs.name) {
				type_name := g.expr_type_to_c(node.lhs)
				g.sb.write_string('((${type_name})(')
				g.gen_expr(node.expr)
				g.sb.write_string('))')
			} else {
				// Single-arg call: println(x) is parsed as CallOrCastExpr
				g.gen_call_expr(node.lhs, [node.expr])
			}
		}
		ast.SelectorExpr {
			// C.<ident> references C macros/constants directly (e.g. C.EOF -> EOF).
			if node.lhs is ast.Ident && node.lhs.name == 'C' {
				g.sb.write_string(node.rhs.name)
				return
			}
			// Check if LHS is an enum type name -> emit EnumName__field
			if node.lhs is ast.Ident && g.is_enum_type(node.lhs.name) {
				enum_name := g.get_qualified_name(node.lhs.name)
				g.sb.write_string('${enum_name}__${node.rhs.name}')
			} else {
				g.gen_expr(node.lhs)
				g.sb.write_string('.${node.rhs.name}')
			}
		}
		ast.IfExpr {
			// Skip empty conditions (pure else blocks shouldn't appear at top level)
			if node.cond is ast.EmptyExpr {
				return
			}
			g.sb.write_string('if (')
			g.gen_expr(node.cond)
			g.sb.writeln(') {')
			g.indent++
			g.gen_stmts(node.stmts)
			g.indent--
			g.write_indent()
			g.sb.write_string('}')
			// Handle else / else-if
			if node.else_expr !is ast.EmptyExpr {
				if node.else_expr is ast.IfExpr {
					else_if := node.else_expr as ast.IfExpr
					if else_if.cond is ast.EmptyExpr {
						g.sb.writeln(' else {')
						g.indent++
						g.gen_stmts(else_if.stmts)
						g.indent--
						g.write_indent()
						g.sb.write_string('}')
					} else {
						g.sb.write_string(' else ')
						g.gen_expr(node.else_expr)
					}
				} else {
					g.sb.writeln(' else {')
					g.indent++
					g.gen_stmts_from_expr(node.else_expr)
					g.indent--
					g.write_indent()
					g.sb.write_string('}')
				}
			}
			g.sb.writeln('')
		}
		ast.PostfixExpr {
			g.gen_expr(node.expr)
			op := match node.op {
				.inc { '++' }
				.dec { '--' }
				else { '' }
			}
			g.sb.write_string(op)
		}
		ast.ModifierExpr {
			g.gen_expr(node.expr)
		}
		ast.CastExpr {
			g.gen_cast_expr(node)
		}
		ast.IndexExpr {
			g.gen_index_expr(node)
		}
		ast.ArrayInitExpr {
			g.gen_array_init_expr(node)
		}
		ast.InitExpr {
			g.gen_init_expr(node)
		}
		ast.MapInitExpr {
			g.gen_map_init_expr(node)
		}
		ast.MatchExpr {
			panic('bug in v2 compiler: MatchExpr should have been lowered in v2.transformer')
		}
		ast.UnsafeExpr {
			g.gen_unsafe_expr(node)
		}
		ast.OrExpr {
			panic('bug in v2 compiler: OrExpr should have been expanded in v2.transformer')
		}
		ast.AsCastExpr {
			g.gen_as_cast_expr(node)
		}
		ast.StringInterLiteral {
			g.gen_string_inter_literal(node)
		}
		ast.FnLiteral {
			g.sb.write_string('/* [TODO] FnLiteral */ NULL')
		}
		ast.LambdaExpr {
			g.sb.write_string('/* [TODO] LambdaExpr */ NULL')
		}
		ast.ComptimeExpr {
			// $if comptime should be resolved by transformer; @FN etc. handled here
			if node.expr is ast.IfExpr {
				panic('bug in v2 compiler: comptime \$if should have been resolved in v2.transformer')
			}
			g.gen_comptime_expr(node)
		}
		ast.Keyword {
			g.gen_keyword(node)
		}
		ast.KeywordOperator {
			g.gen_keyword_operator(node)
		}
		ast.RangeExpr {
			g.gen_range_expr(node)
		}
		ast.SelectExpr {
			g.sb.write_string('/* [TODO] SelectExpr */ 0')
		}
		ast.LockExpr {
			panic('bug in v2 compiler: LockExpr should have been lowered in v2.transformer')
		}
		ast.Type {
			g.sb.write_string('/* [TODO] Type */ 0')
		}
		ast.AssocExpr {
			g.sb.write_string('/* [TODO] AssocExpr */ {0}')
		}
		ast.Tuple {
			g.sb.write_string('/* [TODO] Tuple */ {0}')
		}
		ast.FieldInit {
			g.sb.write_string('/* [TODO] FieldInit */ 0')
		}
		ast.IfGuardExpr {
			panic('bug in v2 compiler: IfGuardExpr should have been expanded in v2.transformer')
		}
		ast.GenericArgs {
			panic('bug in v2 compiler: GenericArgs should have been resolved during type checking')
		}
		ast.GenericArgOrIndexExpr {
			panic('bug in v2 compiler: GenericArgOrIndexExpr should have been resolved during type checking')
		}
		ast.SqlExpr {
			g.sb.write_string('/* [TODO] SqlExpr */ 0')
		}
		ast.EmptyExpr {}
	}
}

fn (mut g Gen) gen_keyword(node ast.Keyword) {
	match node.tok {
		.key_nil {
			g.sb.write_string('NULL')
		}
		.key_none {
			g.sb.write_string('0')
		}
		.key_true {
			g.sb.write_string('true')
		}
		.key_false {
			g.sb.write_string('false')
		}
		.key_struct {
			g.sb.write_string('struct')
		}
		else {
			g.sb.write_string('0')
		}
	}
}

fn (mut g Gen) gen_map_init_expr(node ast.MapInitExpr) {
	// Non-empty map literals are lowered in transformer to
	// builtin__new_map_init_noscan_value(...).
	if node.keys.len > 0 {
		panic('bug in v2 compiler: non-empty MapInitExpr should have been lowered in v2.transformer')
	}
	mut map_type := ''
	if node.typ !is ast.EmptyExpr {
		map_type = g.expr_type_to_c(node.typ)
	}
	if map_type == '' {
		if raw_type := g.get_raw_type(node) {
			if raw_type is types.Map {
				map_type = g.types_type_to_c(raw_type)
			}
		}
	}
	if map_type == '' {
		if env_type := g.get_expr_type_from_env(node) {
			if env_type.starts_with('Map_') {
				map_type = env_type
			}
		}
	}
	if map_type == '' {
		map_type = 'map'
	}
	g.sb.write_string('((${map_type}){0})')
}

fn (mut g Gen) gen_range_expr(node ast.RangeExpr) {
	// Standalone ranges should be lowered or appear only in IndexExpr slicing.
	if node.start is ast.EmptyExpr && node.end is ast.EmptyExpr {
		g.sb.write_string('0')
		return
	}
	g.sb.write_string('0')
}

fn (mut g Gen) gen_stmts_from_expr(e ast.Expr) {
	if e is ast.IfExpr {
		g.gen_stmts(e.stmts)
	}
}

fn (mut g Gen) gen_call_expr(lhs ast.Expr, args []ast.Expr) {
	mut name := ''
	if lhs is ast.Ident {
		name = sanitize_fn_ident(lhs.name)
	} else if lhs is ast.SelectorExpr {
		// Handle C.puts, C.putchar etc.
		if lhs.lhs is ast.Ident && lhs.lhs.name == 'C' {
			name = lhs.rhs.name
			g.sb.write_string('${name}(')
			for i, arg in args {
				if i > 0 {
					g.sb.write_string(', ')
				}
				g.gen_expr(arg)
			}
			g.sb.write_string(')')
			return
		}
	}

	// Handle builtin print functions with type-aware argument conversion
	if name in ['println', 'eprintln', 'print', 'eprint'] {
		if args.len == 1 {
			arg := args[0]
			arg_type := g.get_expr_type(arg)

			c_name := if g.cur_module == 'builtin' {
				name
			} else {
				'builtin__${name}'
			}

			if arg_type == 'string' {
				g.sb.write_string('${c_name}(')
				g.gen_expr(arg)
				g.sb.write_string(')')
			} else if arg_type in ['int', 'i8', 'i16', 'i32'] {
				g.sb.write_string('${c_name}(int_str(')
				g.gen_expr(arg)
				g.sb.write_string('))')
			} else if arg_type == 'i64' {
				g.sb.write_string('${c_name}(i64_str(')
				g.gen_expr(arg)
				g.sb.write_string('))')
			} else if arg_type == 'u64' {
				g.sb.write_string('${c_name}(u64_str(')
				g.gen_expr(arg)
				g.sb.write_string('))')
			} else if arg_type == 'bool' {
				g.sb.write_string('${c_name}(bool_str(')
				g.gen_expr(arg)
				g.sb.write_string('))')
			} else {
				// Fallback
				g.sb.write_string('${c_name}(/* ${arg_type} */ int_str(')
				g.gen_expr(arg)
				g.sb.write_string('))')
			}
			return
		}
	}

	// Regular function call - mangle name based on module
	c_name := if name != '' && g.cur_module != '' && g.cur_module != 'main'
		&& g.cur_module != 'builtin' {
		'${g.cur_module}__${name}'
	} else {
		name
	}
	g.sb.write_string('${c_name}(')
	for i, arg in args {
		if i > 0 {
			g.sb.write_string(', ')
		}
		g.gen_expr(arg)
	}
	g.sb.write_string(')')
}

// types_type_to_c converts a types.Type to a C type string
fn (g &Gen) types_type_to_c(t types.Type) string {
	match t {
		types.Primitive {
			if t.props.has(.integer) {
				if t.props.has(.untyped) {
					return 'int'
				}
				size := if t.size == 0 { 32 } else { int(t.size) }
				is_signed := !t.props.has(.unsigned)
				return if is_signed {
					match size {
						8 { 'i8' }
						16 { 'i16' }
						32 { 'int' }
						64 { 'i64' }
						else { 'int' }
					}
				} else {
					match size {
						8 { 'u8' }
						16 { 'u16' }
						32 { 'u32' }
						else { 'u64' }
					}
				}
			} else if t.props.has(.float) {
				if t.props.has(.untyped) {
					return 'f64'
				}
				return if t.size == 32 { 'f32' } else { 'f64' }
			} else if t.props.has(.boolean) {
				return 'bool'
			}
			return 'int'
		}
		types.Pointer {
			base := g.types_type_to_c(t.base_type)
			return '${base}*'
		}
		types.Array {
			elem := g.types_type_to_c(t.elem_type)
			return 'Array_${elem}'
		}
		types.ArrayFixed {
			elem := g.types_type_to_c(t.elem_type)
			return 'Array_${elem}'
		}
		types.Struct {
			return t.name
		}
		types.String {
			return 'string'
		}
		types.Alias {
			return t.name
		}
		types.Char {
			return 'char'
		}
		types.Rune {
			return 'rune'
		}
		types.Void {
			return 'void'
		}
		types.Enum {
			return t.name
		}
		types.Interface {
			return t.name
		}
		types.SumType {
			return t.get_name()
		}
		types.Map {
			key := g.types_type_to_c(t.key_type)
			val := g.types_type_to_c(t.value_type)
			return 'Map_${key}_${val}'
		}
		types.OptionType {
			base := g.types_type_to_c(t.base_type)
			return '_option_${base}'
		}
		types.ResultType {
			base := g.types_type_to_c(t.base_type)
			return '_result_${base}'
		}
		types.FnType {
			return 'void*'
		}
		types.ISize {
			return 'isize'
		}
		types.USize {
			return 'usize'
		}
		types.Nil {
			return 'void*'
		}
		types.None {
			return 'void'
		}
		else {
			return 'int'
		}
	}
}

// get_expr_type_from_env retrieves the C type string for an expression from the Environment
fn (g &Gen) get_expr_type_from_env(e ast.Expr) ?string {
	if g.env == unsafe { nil } {
		return none
	}
	pos := e.pos()
	if pos != 0 {
		if typ := g.env.get_expr_type(pos) {
			return g.types_type_to_c(typ)
		}
	}
	return none
}

// get_expr_type returns the C type string for an expression
fn (mut g Gen) get_expr_type(node ast.Expr) string {
	// For identifiers, check function scope first
	if node is ast.Ident {
		if g.cur_fn_scope != unsafe { nil } {
			if obj := g.cur_fn_scope.lookup_parent(node.name, 0) {
				if obj is types.Module {
					return 'int'
				}
				return g.types_type_to_c(obj.typ())
			}
		}
	}
	// Try environment lookup
	if t := g.get_expr_type_from_env(node) {
		return t
	}
	// Fallback inference
	match node {
		ast.BasicLiteral {
			if node.kind == .key_true || node.kind == .key_false {
				return 'bool'
			}
			return 'int'
		}
		ast.StringLiteral {
			return 'string'
		}
		ast.InfixExpr {
			if node.op in [.eq, .ne, .lt, .gt, .le, .ge, .and, .logical_or] {
				return 'bool'
			}
			return g.get_expr_type(node.lhs)
		}
		ast.ParenExpr {
			return g.get_expr_type(node.expr)
		}
		ast.UnsafeExpr {
			// Infer from last statement in the block
			if node.stmts.len > 0 {
				last := node.stmts[node.stmts.len - 1]
				if last is ast.ExprStmt {
					return g.get_expr_type(last.expr)
				}
			}
			return 'int'
		}
		ast.IndexExpr {
			// Slicing returns the same type as the source container.
			if node.expr is ast.RangeExpr {
				return g.get_expr_type(node.lhs)
			}
			// Try to get element type from LHS type
			if raw_type := g.get_raw_type(node.lhs) {
				match raw_type {
					types.Array {
						return g.types_type_to_c(raw_type.elem_type)
					}
					types.ArrayFixed {
						return g.types_type_to_c(raw_type.elem_type)
					}
					types.String {
						return 'u8'
					}
					else {}
				}
			}
			return 'int'
		}
		ast.MapInitExpr {
			if node.typ !is ast.EmptyExpr {
				return g.expr_type_to_c(node.typ)
			}
			if raw_type := g.get_raw_type(node) {
				if raw_type is types.Map {
					return g.types_type_to_c(raw_type)
				}
			}
			if node.keys.len > 0 && node.vals.len > 0 {
				return 'Map_${g.get_expr_type(node.keys[0])}_${g.get_expr_type(node.vals[0])}'
			}
			return 'map'
		}
		ast.InitExpr {
			return g.expr_type_to_c(node.typ)
		}
		ast.ArrayInitExpr {
			elem := g.extract_array_elem_type(node.typ)
			if elem != '' {
				if g.is_dynamic_array_type(node.typ) {
					return 'Array_${elem}'
				}
				return 'Array_fixed_${elem}_${node.exprs.len}'
			}
			return 'array'
		}
		ast.CastExpr {
			return g.expr_type_to_c(node.typ)
		}
		ast.AsCastExpr {
			return g.expr_type_to_c(node.typ)
		}
		ast.StringInterLiteral {
			return 'string'
		}
		else {
			return 'int'
		}
	}
}

// expr_type_to_c converts an AST type expression to a C type string
fn (mut g Gen) expr_type_to_c(e ast.Expr) string {
	match e {
		ast.Ident {
			name := e.name
			if name in ['int', 'i64', 'i32', 'i16', 'i8', 'u64', 'u32', 'u16', 'u8', 'byte', 'rune',
				'f32', 'f64', 'usize', 'isize'] {
				return name
			}
			if name == 'bool' {
				return 'bool'
			}
			if name == 'string' {
				return 'string'
			}
			if name == 'voidptr' {
				return 'void*'
			}
			if name == 'charptr' {
				return 'char*'
			}
			if g.is_module_local_type(name) {
				return '${g.cur_module}__${name}'
			}
			g.register_alias_type(name)
			return name
		}
		ast.PrefixExpr {
			if e.op == .amp {
				return g.expr_type_to_c(e.expr) + '*'
			}
			return 'void*'
		}
		ast.SelectorExpr {
			if e.lhs is ast.Ident {
				return '${e.lhs.name}__${e.rhs.name}'
			}
			return g.expr_type_to_c(e.lhs) + '__${e.rhs.name}'
		}
		ast.EmptyExpr {
			return 'void'
		}
		ast.Type {
			if e is ast.ArrayType {
				elem_type := g.expr_type_to_c(e.elem_type)
				array_type := 'Array_${elem_type}'
				g.register_alias_type(array_type)
				return array_type
			}
			if e is ast.MapType {
				key_type := g.expr_type_to_c(e.key_type)
				value_type := g.expr_type_to_c(e.value_type)
				map_type := 'Map_${key_type}_${value_type}'
				g.register_alias_type(map_type)
				return map_type
			}
			if e is ast.OptionType {
				base_type := g.expr_type_to_c(e.base_type)
				option_type := '_option_${base_type}'
				g.register_alias_type(option_type)
				return option_type
			}
			if e is ast.ResultType {
				base_type := g.expr_type_to_c(e.base_type)
				result_type := '_result_${base_type}'
				g.register_alias_type(result_type)
				return result_type
			}
			if e is ast.FnType {
				return 'void*'
			}
			return 'int'
		}
		else {
			return 'int'
		}
	}
}

fn (g &Gen) is_module_local_type(name string) bool {
	if g.cur_module == '' || g.cur_module == 'main' || g.cur_module == 'builtin' {
		return false
	}
	if name in primitive_types {
		return false
	}
	if name in ['bool', 'string', 'voidptr', 'charptr', 'byteptr'] {
		return false
	}
	if name.contains('__') || name.starts_with('Array_') || name.starts_with('Array_fixed_')
		|| name.starts_with('Map_') || name.starts_with('_result_') || name.starts_with('_option_') {
		return false
	}
	return '${g.cur_module}::${name}' in g.module_type_names
}

// get_raw_type returns the raw types.Type for an expression from the Environment
fn (mut g Gen) get_raw_type(node ast.Expr) ?types.Type {
	if g.env == unsafe { nil } {
		return none
	}
	// For identifiers, check function scope first
	if node is ast.Ident {
		if g.cur_fn_scope != unsafe { nil } {
			if obj := g.cur_fn_scope.lookup_parent(node.name, 0) {
				if obj is types.Module {
					return none
				}
				return obj.typ()
			}
		}
	}
	// Try environment lookup by position
	pos := node.pos()
	if pos != 0 {
		return g.env.get_expr_type(pos)
	}
	return none
}

fn (mut g Gen) gen_unsafe_expr(node ast.UnsafeExpr) {
	if node.stmts.len == 0 {
		g.sb.write_string('0')
		return
	}
	if node.stmts.len == 1 {
		stmt := node.stmts[0]
		if stmt is ast.ExprStmt {
			g.gen_expr(stmt.expr)
		} else {
			// Single non-expression statement (e.g., return) - emit directly
			g.gen_stmt(stmt)
		}
		return
	}
	// Multi-statement: use GCC compound expression ({ ... })
	g.sb.write_string('({ ')
	for i, stmt in node.stmts {
		if i < node.stmts.len - 1 {
			g.gen_stmt(stmt)
		}
	}
	// Last statement - if it's an ExprStmt, its value is the block's value
	last := node.stmts[node.stmts.len - 1]
	if last is ast.ExprStmt {
		g.gen_expr(last.expr)
		g.sb.write_string('; ')
	} else {
		g.gen_stmt(last)
		g.sb.write_string('0; ')
	}
	g.sb.write_string('})')
}

fn (mut g Gen) gen_index_expr(node ast.IndexExpr) {
	// Slice syntax: arr[a..b], arr[..b], arr[a..], s[a..b]
	if node.expr is ast.RangeExpr {
		panic('bug in v2 compiler: slice IndexExpr should have been lowered in v2.transformer')
	}
	// Check LHS type from environment to determine indexing strategy
	if raw_type := g.get_raw_type(node.lhs) {
		if raw_type is types.ArrayFixed {
			// Fixed arrays are C arrays - direct indexing
			g.gen_expr(node.lhs)
			g.sb.write_string('[')
			g.gen_expr(node.expr)
			g.sb.write_string(']')
			return
		}
		if raw_type is types.Array {
			// Dynamic arrays: ((elem_type*)arr.data)[idx]
			elem_type := g.types_type_to_c(raw_type.elem_type)
			g.sb.write_string('((${elem_type}*)')
			g.gen_expr(node.lhs)
			g.sb.write_string('.data)[')
			g.gen_expr(node.expr)
			g.sb.write_string(']')
			return
		}
		if raw_type is types.String {
			// String character access: lhs.str[idx]
			g.gen_expr(node.lhs)
			g.sb.write_string('.str[')
			g.gen_expr(node.expr)
			g.sb.write_string(']')
			return
		}
		if raw_type is types.Pointer {
			// Pointer to array: use -> accessor
			if raw_type.base_type is types.Array {
				elem_type := g.types_type_to_c(raw_type.base_type.elem_type)
				g.sb.write_string('((${elem_type}*)')
				g.gen_expr(node.lhs)
				g.sb.write_string('->data)[')
				g.gen_expr(node.expr)
				g.sb.write_string(']')
				return
			}
		}
	}
	// Fallback: direct C array indexing
	g.gen_expr(node.lhs)
	g.sb.write_string('[')
	g.gen_expr(node.expr)
	g.sb.write_string(']')
}

fn (mut g Gen) gen_comptime_expr(node ast.ComptimeExpr) {
	if node.expr is ast.Ident {
		name := node.expr.name
		match name {
			'FN', 'METHOD', 'FUNCTION' {
				fn_name := g.cur_fn_name
				g.sb.write_string('(string){"${fn_name}", ${fn_name.len}}')
			}
			'MOD' {
				mod_name := g.cur_module
				g.sb.write_string('(string){"${mod_name}", ${mod_name.len}}')
			}
			'FILE' {
				g.sb.write_string('(string){__FILE__, sizeof(__FILE__)-1}')
			}
			'LINE' {
				g.sb.write_string('__LINE__')
			}
			'VCURRENTHASH' {
				g.sb.write_string('(string){"VCURRENTHASH", 12}')
			}
			'VEXE' {
				g.sb.write_string('__vexe_path()')
			}
			else {
				g.sb.write_string('(string){"", 0} /* unknown comptime: ${name} */')
			}
		}
		return
	}
	// Fallback: emit the inner expression
	g.gen_expr(node.expr)
}

fn (mut g Gen) gen_init_expr(node ast.InitExpr) {
	type_name := g.expr_type_to_c(node.typ)
	if node.fields.len == 0 {
		g.sb.write_string('((${type_name}){0})')
		return
	}
	g.sb.write_string('((${type_name}){')
	for i, field in node.fields {
		if i > 0 {
			g.sb.write_string(',')
		}
		g.sb.write_string('.${field.name} = ')
		g.gen_expr(field.value)
	}
	g.sb.write_string('})')
}

fn (mut g Gen) gen_array_init_expr(node ast.ArrayInitExpr) {
	elem_type := g.extract_array_elem_type(node.typ)
	if node.exprs.len > 0 {
		// Has elements
		if elem_type != '' && g.is_dynamic_array_type(node.typ) {
			// Dynamic array compound literal: (elem_type[N]){e1, e2, ...}
			g.sb.write_string('(${elem_type}[${node.exprs.len}]){')
			for i, e in node.exprs {
				if i > 0 {
					g.sb.write_string(', ')
				}
				g.gen_expr(e)
			}
			g.sb.write_string('}')
			return
		}
		// Fixed-size array or untyped: {e1, e2, ...}
		g.sb.write_string('{')
		for i, e in node.exprs {
			if i > 0 {
				g.sb.write_string(', ')
			}
			g.gen_expr(e)
		}
		g.sb.write_string('}')
		return
	}
	// Empty array: should have been lowered by transformer to __new_array_with_default_noscan()
	// Fallback: zero-init
	g.sb.write_string('(array){0}')
}

// extract_array_elem_type extracts the element C type from an array type expression
fn (mut g Gen) extract_array_elem_type(e ast.Expr) string {
	match e {
		ast.Type {
			if e is ast.ArrayType {
				return g.expr_type_to_c(e.elem_type)
			}
			if e is ast.ArrayFixedType {
				return g.expr_type_to_c(e.elem_type)
			}
		}
		else {}
	}
	return ''
}

// is_dynamic_array_type checks if the type expression is a dynamic array (ArrayType, not ArrayFixedType)
fn (g &Gen) is_dynamic_array_type(e ast.Expr) bool {
	match e {
		ast.Type {
			if e is ast.ArrayType {
				return true
			}
		}
		else {}
	}
	return false
}

fn (mut g Gen) gen_const_decl(node ast.ConstDecl) {
	for field in node.fields {
		name := if g.cur_module != '' && g.cur_module != 'main' && g.cur_module != 'builtin' {
			'${g.cur_module}__${field.name}'
		} else {
			field.name
		}
		typ := g.get_expr_type(field.value)
		if typ == 'string' {
			// String constants need a global variable
			g.sb.write_string('string ${name} = ')
			g.gen_expr(field.value)
			g.sb.writeln(';')
		} else {
			// Integer/other constants: use #define for TCC compatibility
			g.sb.write_string('#define ${name} ')
			g.gen_expr(field.value)
			g.sb.writeln('')
		}
	}
}

fn (mut g Gen) gen_cast_expr(node ast.CastExpr) {
	type_name := g.expr_type_to_c(node.typ)
	g.sb.write_string('((${type_name})(')
	g.gen_expr(node.expr)
	g.sb.write_string('))')
}

fn (mut g Gen) gen_keyword_operator(node ast.KeywordOperator) {
	match node.op {
		.key_sizeof {
			if node.exprs.len > 0 {
				g.sb.write_string('sizeof(')
				g.sb.write_string(g.expr_type_to_c(node.exprs[0]))
				g.sb.write_string(')')
			} else {
				g.sb.write_string('0')
			}
		}
		.key_typeof {
			if node.exprs.len > 0 {
				type_name := g.expr_type_to_c(node.exprs[0])
				g.sb.write_string('(string){"${type_name}", ${type_name.len}}')
			} else {
				g.sb.write_string('(string){"", 0}')
			}
		}
		.key_offsetof {
			if node.exprs.len >= 2 {
				g.sb.write_string('offsetof(')
				g.sb.write_string(g.expr_type_to_c(node.exprs[0]))
				g.sb.write_string(', ')
				field_expr := node.exprs[1]
				if field_expr is ast.Ident {
					g.sb.write_string(field_expr.name)
				} else {
					g.gen_expr(field_expr)
				}
				g.sb.write_string(')')
			} else {
				g.sb.write_string('0')
			}
		}
		.key_isreftype {
			g.sb.write_string('0')
		}
		.key_likely {
			if node.exprs.len > 0 {
				g.sb.write_string('__builtin_expect((')
				g.gen_expr(node.exprs[0])
				g.sb.write_string('), 1)')
			} else {
				g.sb.write_string('1')
			}
		}
		.key_unlikely {
			if node.exprs.len > 0 {
				g.sb.write_string('__builtin_expect((')
				g.gen_expr(node.exprs[0])
				g.sb.write_string('), 0)')
			} else {
				g.sb.write_string('0')
			}
		}
		.key_dump {
			// dump(expr) - just evaluate the expression
			if node.exprs.len > 0 {
				g.gen_expr(node.exprs[0])
			} else {
				g.sb.write_string('0')
			}
		}
		else {
			g.sb.write_string('/* KeywordOperator: ${node.op} */ 0')
		}
	}
}

fn (mut g Gen) gen_as_cast_expr(node ast.AsCastExpr) {
	// a as Cat => (*((main__Cat*)a._data._Cat))
	type_name := g.expr_type_to_c(node.typ)
	// Short variant name for _data._ accessor (strip module prefix)
	short_name := if type_name.contains('__') {
		type_name.all_after_last('__')
	} else {
		type_name
	}
	g.sb.write_string('(*((${type_name}*)(')
	g.gen_expr(node.expr)
	g.sb.write_string(')._data._${short_name}))')
}

fn (mut g Gen) gen_string_inter_literal(node ast.StringInterLiteral) {
	// Use sprintf approach with asprintf (allocates automatically)
	// Wrapped in GCC compound expression ({ ... })
	// Build format string, stripping V string delimiters from values
	mut fmt_str := strings.new_builder(64)
	for i, raw_val in node.values {
		mut val := raw_val
		// Strip V string delimiters: leading quote from first value, trailing from last
		if i == 0 {
			val = val.trim_left('\'"')
		}
		if i == node.values.len - 1 {
			val = val.trim_right('\'"')
		}
		escaped := val.replace('\\', '\\\\').replace('"', '\\"').replace('\n', '\\n').replace('\t',
			'\\t')
		fmt_str.write_string(escaped)
		if i < node.inters.len {
			inter := node.inters[i]
			fmt_str.write_string(g.get_sprintf_format(inter))
		}
	}
	fmt := fmt_str.str()
	g.sb.write_string('({ char* _sip; int _sil = asprintf(&_sip, "${fmt}"')
	// Write arguments
	for inter in node.inters {
		g.sb.write_string(', ')
		g.write_sprintf_arg(inter)
	}
	g.sb.write_string('); (string){_sip, _sil}; })')
}

fn (mut g Gen) write_sprintf_arg(inter ast.StringInter) {
	expr_type := g.get_expr_type(inter.expr)
	if expr_type == 'string' {
		g.gen_expr(inter.expr)
		g.sb.write_string('.str')
	} else if expr_type == 'bool' {
		g.sb.write_string('(')
		g.gen_expr(inter.expr)
		g.sb.write_string(' ? "true" : "false")')
	} else {
		g.gen_expr(inter.expr)
	}
}

fn (mut g Gen) get_sprintf_format(inter ast.StringInter) string {
	mut fmt := '%'
	// Width
	if inter.width > 0 {
		fmt += '${inter.width}'
	}
	// Precision
	if inter.precision > 0 {
		fmt += '.${inter.precision}'
	}
	// Format specifier
	if inter.format != .unformatted {
		match inter.format {
			.decimal { fmt += 'd' }
			.float { fmt += 'f' }
			.hex { fmt += 'x' }
			.octal { fmt += 'o' }
			.character { fmt += 'c' }
			.exponent { fmt += 'e' }
			.exponent_short { fmt += 'g' }
			.binary { fmt += 'd' } // binary not supported in printf, fallback to decimal
			.pointer_address { fmt += 'p' }
			.string { fmt += 's' }
			.unformatted { fmt += 'd' }
		}
		return fmt
	}
	// Infer from expression type
	expr_type := g.get_expr_type(inter.expr)
	match expr_type {
		'string' { return '%s' }
		'int', 'i8', 'i16', 'i32' { return '%d' }
		'i64' { return '%lld' }
		'u8', 'u16', 'u32' { return '%u' }
		'u64' { return '%llu' }
		'f32', 'f64', 'float_literal' { return '%f' }
		'bool' { return '%s' }
		'rune' { return '%c' }
		'char' { return '%c' }
		else { return '%d' }
	}
}

fn (mut g Gen) write_indent() {
	for _ in 0 .. g.indent {
		g.sb.write_string('\t')
	}
}
