module c

import strings
import v3.flat
import v3.types

pub struct FlatGen {
mut:
	sb                    strings.Builder
	indent                int
	a                     &flat.FlatAst = unsafe { nil }
	used_fns              map[string]bool
	str_lits              []string
	global_types          map[string]types.Type
	enum_vals             map[string]int
	defers                []flat.NodeId
	interfaces            map[string][]string
	const_vals            map[string]flat.NodeId
	const_modules         map[string]string
	global_modules        map[string]string
	tc                    types.TypeChecker
	has_builtins          bool
	tmp_count             int
	modules               map[string]string // alias -> full module name
	fn_ptr_types          map[string]string // fn_ptr:ret|params -> typedef name
	runtime_inits         []string
	cur_fn_ret            types.Type = types.Type(types.void_)
	needed_optional_types map[string]string
	emitted_fns           map[string]bool
}

pub fn FlatGen.new() FlatGen {
	return FlatGen{
		sb: strings.new_builder(4096)
	}
}

pub fn (mut g FlatGen) gen(a &flat.FlatAst) string {
	return g.gen_with_used(a, map[string]bool{}, types.TypeChecker{})
}

pub fn (mut g FlatGen) gen_with_used(a &flat.FlatAst, used_fns map[string]bool, tc types.TypeChecker) string {
	g.a = a
	g.used_fns = used_fns.clone()
	if tc.a != unsafe { nil } {
		g.tc = tc
	} else {
		g.tc.collect(a)
	}
	g.has_builtins = g.tc.has_builtins
	g.collect_gen_info()
	const_code := g.precompute_consts()
	orig_sb := g.sb
	g.sb = strings.new_builder(4096)
	g.gen_fns()
	fn_code := g.sb.str()
	g.sb = orig_sb
	g.preamble()
	if g.has_builtins {
		g.writeln('typedef struct Array { void* data; int len; int cap; int elem_size; } Array;')
		g.writeln('typedef Array array;')
		g.writeln('typedef Array strings__Builder;')
		g.writeln('typedef struct { unsigned int hash; bool used; } MapSlot;')
		g.writeln('typedef struct { MapSlot* slots; char* keys; char* vals; int cap; int len; int key_size; int val_size; } map;')
		g.writeln('')
	}
	g.enum_decls()
	g.type_alias_decls()
	g.struct_decls()
	g.optional_typedefs()
	g.multi_return_typedefs()
	g.runtime_fns()
	g.global_decls()
	g.fn_ptr_typedefs()
	g.forward_decls()
	g.register_interface_strings()
	g.string_literals()
	g.interface_method_stubs()
	g.sb.write_string(const_code)
	if g.runtime_inits.len > 0 {
		g.writeln('void _vinit() {')
		for ri in g.runtime_inits {
			g.writeln(ri)
		}
		g.writeln('}')
		g.writeln('')
	}
	g.sb.write_string(fn_code)
	return g.sb.str()
}

fn (mut g FlatGen) collect_gen_info() {
	for node in g.a.nodes {
		match node.kind {
			.module_decl {
				g.tc.cur_module = node.value
			}
			.fn_decl {
				for i in 0 .. node.children_count {
					child := g.a.child_node(&node, i)
					if child.kind == .param {
						pt := g.tc.parse_type(child.typ)
						if pt is types.FnType {
							g.resolve_fn_ptr_type(g.tc.c_type(pt))
						}
					}
				}
			}
			.global_decl {
				for i in 0 .. node.children_count {
					f := g.a.child_node(&node, i)
					if f.value.starts_with('C.') {
						continue
					}
					mut ft := g.tc.parse_type(f.typ)
					if ft is types.Void && f.children_count > 0 {
						ft = g.tc.resolve_type(g.a.child(f, 0))
					}
					qname := g.tc.qualify_name(f.value)
					g.global_types[qname] = ft
					g.global_modules[f.value] = g.tc.cur_module
					g.tc.file_scope.insert(f.value, ft)
					if qname != f.value {
						g.tc.file_scope.insert(qname, ft)
					}
				}
			}
			.enum_decl {
				is_flag := node.typ == 'flag'
				mut val := 0
				enum_name := g.tc.qualify_name(node.value)
				for i in 0 .. node.children_count {
					f := g.a.child_node(&node, i)
					if f.children_count > 0 {
						ev := g.a.child_node(f, 0)
						if ev.kind == .int_literal {
							val = ev.value.int()
						}
					}
					if is_flag {
						g.enum_vals['${enum_name}.${f.value}'] = 1 << val
						val++
					} else {
						g.enum_vals['${enum_name}.${f.value}'] = val
						val++
					}
				}
			}
			.interface_decl {
				mut methods := []string{}
				for i in 0 .. node.children_count {
					f := g.a.child_node(&node, i)
					if f.kind == .interface_field {
						methods << f.value
					}
				}
				g.interfaces[g.tc.qualify_name(node.value)] = methods
			}
			.const_decl {
				for i in 0 .. node.children_count {
					f := g.a.child_node(&node, i)
					if f.kind == .const_field && f.children_count > 0 {
						g.const_vals[f.value] = g.a.child(f, 0)
						g.const_modules[f.value] = g.tc.cur_module
					}
				}
			}
			.import_decl {
				g.modules[node.typ] = node.value
			}
			else {}
		}
	}
	g.modules['strings'] = 'strings'
}

fn (mut g FlatGen) expr_to_string(id flat.NodeId) string {
	orig := g.sb
	g.sb = strings.new_builder(64)
	g.gen_expr(id)
	result := g.sb.str()
	g.sb = orig
	return result
}

fn (mut g FlatGen) gen_expr(id flat.NodeId) {
	if int(id) < 0 {
		return
	}
	node := g.a.nodes[int(id)]
	match node.kind {
		.int_literal {
			v := node.value.replace('_', '')
			if v.starts_with('0o') {
				g.write('0${v[2..]}')
			} else {
				g.write(v)
			}
		}
		.float_literal {
			g.write(node.value)
		}
		.bool_literal {
			g.write(node.value)
		}
		.char_literal {
			v := node.value
			if v.len == 1 {
				if v[0] == `\\` {
					g.write("'\\\\'")
				} else if v[0] == `'` {
					g.write("'\\''")
				} else {
					g.write("'${v}'")
				}
			} else if v.starts_with('\\') {
				g.write("'${v}'")
			} else {
				g.write(v)
			}
		}
		.string_literal {
			sid := g.intern_string(node.value)
			g.write('_str_${sid}')
		}
		.string_interp {
			g.gen_string_interp(node)
		}
		.ident {
			looked_up := g.tc.cur_scope.lookup(node.value) or { types.Type(types.void_) }
			is_local := looked_up !is types.Void
			if !is_local && node.value in g.const_vals {
				mod := if node.value in g.const_modules { g.const_modules[node.value] } else { '' }
				if mod.len > 0 && mod != 'main' && mod != 'builtin' {
					g.write(c_name('${mod}.${node.value}'))
				} else {
					g.write(c_name(node.value))
				}
			} else if node.value in g.global_modules {
				mod := g.global_modules[node.value]
				if mod.len > 0 && mod != 'main' && mod != 'builtin' {
					g.write(c_name('${mod}.${node.value}'))
				} else {
					g.write(c_name(node.value))
				}
			} else {
				g.write(c_name(node.value))
			}
		}
		.enum_val {
			for ename, eval in g.enum_vals {
				if ename.ends_with('.${node.value}') {
					g.write('${eval}')
					return
				}
			}
			g.write('0')
		}
		.call {
			g.gen_call(node)
		}
		.infix {
			lhs_id := g.a.child(&node, 0)
			rhs_id := g.a.child(&node, 1)
			lhs_type := g.tc.resolve_type(lhs_id)
			if lhs_type is types.Struct {
				op_name := match node.op {
					.minus { '__minus' }
					.plus { '__plus' }
					.eq { '__eq' }
					.ne { '__ne' }
					.lt { '__lt' }
					.gt { '__gt' }
					.le { '__le' }
					.ge { '__ge' }
					else { '' }
				}
				if op_name.len > 0 {
					g.write('${c_name(lhs_type.name)}${op_name}(')
					g.gen_expr(lhs_id)
					g.write(', ')
					g.gen_expr(rhs_id)
					g.write(')')
				} else {
					g.gen_expr(lhs_id)
					g.write(' ${g.op_str(node.op)} ')
					g.gen_expr(rhs_id)
				}
			} else {
				lhs_node := g.a.nodes[int(lhs_id)]
				rhs_node := g.a.nodes[int(rhs_id)]
				if lhs_node.kind == .infix {
					g.write('(')
					g.gen_expr(lhs_id)
					g.write(')')
				} else {
					g.gen_expr(lhs_id)
				}
				g.write(' ${g.op_str(node.op)} ')
				if rhs_node.kind == .infix {
					g.write('(')
					g.gen_expr(rhs_id)
					g.write(')')
				} else {
					g.gen_expr(rhs_id)
				}
			}
		}
		.prefix {
			child_id := g.a.child(&node, 0)
			child := g.a.nodes[int(child_id)]
			if node.op == .amp && child.kind == .struct_init {
				g.gen_heap_struct_init(child)
			} else if node.op == .amp && child.kind == .cast_expr {
				target_type := g.tc.parse_type(child.value)
				ct := g.tc.c_type(target_type)
				g.write('(${ct}*)(')
				g.gen_expr(g.a.child(&child, 0))
				g.write(')')
			} else if node.op == .amp && child.kind == .call {
				fn_child := g.a.child_node(&child, 0)
				if fn_child.kind == .selector {
					base_child := g.a.child_node(fn_child, 0)
					if base_child.kind == .ident && base_child.value == 'C' {
						c_struct_prefix := if fn_child.value.len > 0 && fn_child.value[0] >= `a` && fn_child.value[0] <= `z` && !fn_child.value.ends_with('_t') {
							'struct '
						} else {
							''
						}
						g.write('(${c_struct_prefix}${fn_child.value}*)(')
						if child.children_count > 1 {
							g.gen_expr(g.a.child(&child, 1))
						} else {
							g.write('0')
						}
						g.write(')')
					} else {
						g.write(g.op_str(node.op))
						g.gen_expr(child_id)
					}
				} else {
					g.write(g.op_str(node.op))
					g.gen_expr(child_id)
				}
			} else {
				g.write(g.op_str(node.op))
				g.gen_expr(child_id)
			}
		}
		.in_expr {
			// NOTE: range membership, inline-array-literal membership, dynamic- and
			// fixed-array membership, and `!in` negation are all lowered by the
			// transformer (transform.transform_in_expr). Only MAP membership reaches
			// the backend, because map__exists needs a C key pointer (compound
			// literal) that cannot be expressed at the AST level.
			lhs_id := g.a.child(&node, 0)
			rhs_id := g.a.child(&node, 1)
			rhs_type := g.tc.resolve_type(rhs_id)
			clean_rhs := types.unwrap_pointer(rhs_type)
			if clean_rhs is types.Map {
				c_key := g.tc.c_type(clean_rhs.key_type)
				is_ptr := rhs_type is types.Pointer
				if is_ptr {
					g.write('map__exists(')
				} else {
					g.write('map__exists(&')
				}
				g.gen_expr(rhs_id)
				g.write(', &(${c_key}[]){')
				g.gen_expr(lhs_id)
				g.write('})')
			} else {
				g.gen_expr(lhs_id)
				g.write(' == ')
				g.gen_expr(rhs_id)
			}
		}
		.postfix {
			g.gen_expr(g.a.child(&node, 0))
			g.write(g.op_str(node.op))
		}
		.paren {
			g.write('(')
			g.gen_expr(g.a.child(&node, 0))
			g.write(')')
		}
		.selector {
			base_id := g.a.child(&node, 0)
			base := g.a.nodes[int(base_id)]
			if base.kind == .ident && base.value == 'C' {
				g.write(node.value)
			} else if base.kind == .ident && (base.value in g.tc.enum_names || g.tc.qualify_name(base.value) in g.tc.enum_names) {
				qbase := if base.value in g.tc.enum_names {
					base.value
				} else {
					g.tc.qualify_name(base.value)
				}
				ekey := '${qbase}.${node.value}'
				if eval := g.enum_vals[ekey] {
					g.write('${eval}')
				} else {
					g.write('0')
				}
			} else if node.value == 'len' && base.kind == .ident {
				base_type := g.tc.resolve_type(base_id)
				if base_type is types.ArrayFixed {
					g.write('${(base_type as types.ArrayFixed).len}')
				} else {
					raw_type := g.tc.cur_scope.lookup(base.value) or { base_type }
					g.gen_expr(base_id)
					if raw_type is types.Pointer {
						g.write('->len')
					} else {
						g.write('.len')
					}
				}
			} else if base.kind == .ident && base.value in g.modules {
				mod := g.modules[base.value]
				short_mod := if mod.contains('.') {
					mod.all_after_last('.')
				} else {
					mod
				}
				g.write(c_name('${short_mod}.${node.value}'))
			} else if base.kind == .selector && base.children_count > 0 && g.is_module_qualified_enum(base) {
				inner_base := g.a.child_node(&base, 0)
				mod := g.modules[inner_base.value]
				short_mod := if mod.contains('.') {
					mod.all_after_last('.')
				} else {
					mod
				}
				qname := '${short_mod}.${base.value}'
				if qname in g.tc.enum_names || base.value in g.tc.enum_names {
					ekey := '${qname}.${node.value}'
					ekey2 := '${base.value}.${node.value}'
					if ekey in g.enum_vals {
						g.write('${g.enum_vals[ekey]}')
					} else if ekey2 in g.enum_vals {
						g.write('${g.enum_vals[ekey2]}')
					} else {
						g.write(c_name('${qname}.${node.value}'))
					}
				} else {
					g.write(c_name('${qname}.${node.value}'))
				}
			} else {
				g.gen_expr(base_id)
				if node.op == .arrow {
					g.write('->')
				} else if node.op == .dot {
					g.write('.')
				} else {
					mut is_ptr := false
					if base.kind == .ident {
						if typ := g.tc.cur_scope.lookup(base.value) {
							is_ptr = typ is types.Pointer
						}
					} else {
						resolved := g.tc.resolve_type(base_id)
						is_ptr = resolved is types.Pointer
					}
					if is_ptr {
						g.write('->')
					} else {
						g.write('.')
					}
				}
				g.write(c_name(node.value))
			}
		}
		.index {
			base_id := g.a.child(&node, 0)
			base_type := g.tc.resolve_type(base_id)
			if node.value == 'range' {
				g.gen_slice_expr(node, base_id, base_type)
			} else if base_type is types.Map {
				c_key := g.tc.c_type(base_type.key_type)
				c_val := g.tc.c_type(base_type.value_type)
				g.write('(*(${c_val}*)map__get(&')
				g.gen_expr(base_id)
				g.write(', &(${c_key}[]){')
				g.gen_expr(g.a.child(&node, 1))
				g.write('}, &(${c_val}[]){0}))')
			} else if base_type is types.Array || (base_type is types.Pointer && (base_type as types.Pointer).base_type is types.Array) {
				arr_type := if base_type is types.Array {
					base_type as types.Array
				} else if base_type is types.Pointer {
					(base_type as types.Pointer).base_type as types.Array
				} else {
					types.Array{}
				}
				c_elem := g.tc.c_type(arr_type.elem_type)
				g.write('(*(${c_elem}*)array_get(')
				if base_type is types.Pointer {
					g.write('*')
				}
				g.gen_expr(base_id)
				g.write(', ')
				g.gen_expr(g.a.child(&node, 1))
				g.write('))')
			} else if base_type is types.String {
				g.gen_expr(base_id)
				g.write('.str[')
				g.gen_expr(g.a.child(&node, 1))
				g.write(']')
			} else if base_type is types.Pointer && (base_type as types.Pointer).base_type is types.Void {
				g.write('((u8*)')
				g.gen_expr(base_id)
				g.write(')[')
				g.gen_expr(g.a.child(&node, 1))
				g.write(']')
			} else {
				g.gen_expr(base_id)
				g.write('[')
				g.gen_expr(g.a.child(&node, 1))
				g.write(']')
			}
		}
		.array_init {
			elem_type := g.tc.parse_type(node.value)
			c_elem := g.tc.c_type(elem_type)
			g.write('array_new(sizeof(${c_elem}), 0, 0)')
		}
		.map_init {
			g.gen_map_init(node)
		}
		.cast_expr {
			target_type := g.tc.parse_type(node.value)
			ct := g.tc.c_type(target_type)
			if node.value in g.interfaces || g.tc.qualify_name(node.value) in g.interfaces {
				g.write('(${ct}){0}')
			} else if target_type is types.SumType {
				inner_id := g.a.child(&node, 0)
				inner := g.a.nodes[int(inner_id)]
				variant_name0 := if inner.kind == .struct_init || inner.kind == .cast_expr {
					inner.value
				} else {
					g.tc.resolve_type(inner_id).name()
				}
				variant_name := g.resolve_variant(target_type.name, variant_name0)
				idx := g.sum_type_index(target_type.name, variant_name)
				field := g.sum_field_name(variant_name)
				if g.variant_references_sum(variant_name, target_type.name) {
					inner_ct := g.tc.c_type(g.tc.parse_type(variant_name))
					if inner.kind == .struct_init {
						g.write('(${ct}){.typ = ${idx}, .${field} = (${inner_ct}*)memdup(&(${inner_ct}){')
						for si in 0 .. inner.children_count {
							sf := g.a.child_node(&inner, si)
							if si > 0 {
								g.write(', ')
							}
							g.write('.${c_name(sf.value)} = ')
							g.gen_expr(g.a.child(sf, 0))
						}
						g.write('}, sizeof(${inner_ct}))}')
					} else {
						g.write('(${ct}){.typ = ${idx}, .${field} = (${inner_ct}*)memdup(&')
						g.gen_expr(inner_id)
						g.write(', sizeof(${inner_ct}))}')
					}
				} else {
					g.write('(${ct}){.typ = ${idx}, .${field} = ')
					g.gen_expr(inner_id)
					g.write('}')
				}
			} else {
				g.write('(${ct})(')
				g.gen_expr(g.a.child(&node, 0))
				g.write(')')
			}
		}
		.struct_init {
			g.gen_struct_init(node)
		}
		.if_expr {
			g.gen_if_expr(node)
		}
		.array_literal {
			g.write('{')
			for i in 0 .. node.children_count {
				if i > 0 {
					g.write(', ')
				}
				g.gen_expr(g.a.child(&node, i))
			}
			g.write('}')
		}
		.nil_literal {
			g.write('NULL')
		}
		.none_expr {
			ct := g.optional_type_name(g.cur_fn_ret)
			g.write('(${ct}){.ok = false}')
		}
		.or_expr {
			g.gen_or_expr(node)
		}
		.block {
			if node.children_count > 1 {
				g.write('({')
				for bi in 0 .. node.children_count - 1 {
					g.gen_node(g.a.child(&node, bi))
				}
				last_id := g.a.child(&node, node.children_count - 1)
				last := g.a.nodes[int(last_id)]
				if last.kind == .expr_stmt {
					g.gen_expr(g.a.child(&last, 0))
				} else if last.kind == .if_expr {
					g.gen_expr(last_id)
				} else {
					g.gen_node(last_id)
				}
				g.write(';})')
			} else if node.children_count > 0 {
				last_id := g.a.child(&node, 0)
				last := g.a.nodes[int(last_id)]
				if last.kind == .expr_stmt {
					g.gen_expr(g.a.child(&last, 0))
				} else {
					g.gen_expr(last_id)
				}
			}
		}
		.is_expr {
			expr_id := g.a.child(&node, 0)
			expr_type := g.tc.resolve_type(expr_id)
			clean := types.unwrap_pointer(expr_type)
			if clean is types.SumType {
				idx := g.sum_type_index(clean.name, node.value)
				if expr_type.is_pointer() {
					g.gen_expr(expr_id)
					g.write('->typ == ${idx}')
				} else {
					g.gen_expr(expr_id)
					g.write('.typ == ${idx}')
				}
			} else {
				g.write('1')
			}
		}
		.as_expr {
			expr_id := g.a.child(&node, 0)
			expr_type := g.tc.resolve_type(expr_id)
			clean := types.unwrap_pointer(expr_type)
			if clean is types.SumType {
				qv := g.resolve_variant(clean.name, node.value)
				field := g.sum_field_name(qv)
				if g.variant_references_sum(qv, clean.name) {
					g.write('(*')
					if expr_type.is_pointer() {
						g.gen_expr(expr_id)
						g.write('->${field})')
					} else {
						g.gen_expr(expr_id)
						g.write('.${field})')
					}
				} else {
					if expr_type.is_pointer() {
						g.gen_expr(expr_id)
						g.write('->${field}')
					} else {
						g.gen_expr(expr_id)
						g.write('.${field}')
					}
				}
			} else {
				g.gen_expr(expr_id)
			}
		}
		.sizeof_expr {
			if _ := g.tc.cur_scope.lookup(node.value) {
				g.write('sizeof(${c_name(node.value)})')
			} else {
				t := g.tc.parse_type(node.value)
				ct := g.tc.c_type(t)
				g.write('sizeof(${ct})')
			}
		}
		.assoc {
			g.gen_assoc_expr(node)
		}
		.empty {}
		else {}
	}
}

fn (g &FlatGen) is_module_qualified_enum(base flat.Node) bool {
	if base.kind != .selector || base.children_count == 0 {
		return false
	}
	inner_base := g.a.child_node(&base, 0)
	if inner_base.kind != .ident || inner_base.value !in g.modules {
		return false
	}
	mod := g.modules[inner_base.value]
	short_mod := if mod.contains('.') { mod.all_after_last('.') } else { mod }
	qname := '${short_mod}.${base.value}'
	return qname in g.tc.enum_names || base.value in g.tc.enum_names
}

fn (mut g FlatGen) preamble() {
	g.writeln('#include <stdio.h>')
	g.writeln('#include <stdlib.h>')
	g.writeln('#include <string.h>')
	g.writeln('#include <stddef.h>')
	g.writeln('#include <unistd.h>')
	if g.has_builtins {
		g.writeln('#include <time.h>')
		g.writeln('#include <sys/time.h>')
		g.writeln('#include <errno.h>')
		g.writeln('#include <signal.h>')
		g.writeln('#include <dirent.h>')
		g.writeln('#include <sys/stat.h>')
		g.writeln('#include <fcntl.h>')
		g.writeln('#include <pthread.h>')
		g.writeln('#include <unistd.h>')
		g.writeln('#ifdef __APPLE__')
		g.writeln('#include <mach/mach_time.h>')
		g.writeln('#endif')
	}
	g.writeln('')
	g.writeln('typedef signed char i8;')
	g.writeln('typedef short i16;')
	g.writeln('typedef int i32;')
	g.writeln('typedef long long i64;')
	g.writeln('typedef unsigned char u8;')
	g.writeln('typedef unsigned char byte;')
	g.writeln('typedef unsigned short u16;')
	g.writeln('typedef unsigned int u32;')
	g.writeln('typedef unsigned long long u64;')
	g.writeln('#ifndef __bool_true_false_are_defined')
	g.writeln('typedef int bool;')
	g.writeln('#endif')
	g.writeln('typedef void* voidptr;')
	g.writeln('#define true 1')
	g.writeln('#define false 0')
	g.writeln('')
	if !g.has_builtins {
		g.writeln('typedef struct {')
		g.writeln('\tchar* str;')
		g.writeln('\tint len;')
		g.writeln('\tint is_lit;')
		g.writeln('} string;')
		g.writeln('')
	}
	g.writeln('#define element_size elem_size')
	g.writeln('#define c_name types__c_name')
	if g.has_builtins {
		return
	}
	g.writeln('typedef struct Array { void* data; int len; int cap; int elem_size; } Array;')
	g.writeln('')
}

fn (mut g FlatGen) runtime_fns() {
	g.writeln('Array array_new(int elem_size, int len, int cap) {')
	g.writeln('\tArray a; a.elem_size = elem_size; a.len = len; a.cap = cap > len ? cap : (len > 0 ? len : 4);')
	g.writeln('\ta.data = calloc(a.cap, elem_size); return a;')
	g.writeln('}')
	g.writeln('Array new_array_from_c_array(int len, int cap, int elem_size, void* data) {')
	g.writeln('\tArray a = array_new(elem_size, len, cap);')
	g.writeln('\tmemcpy(a.data, data, len * elem_size); return a;')
	g.writeln('}')
	g.writeln('void array_push(Array* a, void* elem) {')
	g.writeln('\tif (a->len >= a->cap) { a->cap = a->cap < 4 ? 4 : a->cap * 2; a->data = realloc(a->data, a->cap * a->elem_size); }')
	g.writeln('\tmemcpy((char*)a->data + a->len * a->elem_size, elem, a->elem_size); a->len++;')
	g.writeln('}')
	g.writeln('void array_push_many(Array* a, Array b) {')
	g.writeln('\tint new_len = a->len + b.len;')
	g.writeln('\tif (new_len > a->cap) { a->cap = new_len < 4 ? 4 : new_len * 2; a->data = realloc(a->data, a->cap * a->elem_size); }')
	g.writeln('\tmemcpy((char*)a->data + a->len * a->elem_size, b.data, b.len * a->elem_size); a->len = new_len;')
	g.writeln('}')
	g.writeln('void array_push_many_ptr(Array* a, void* ptr, int len) {')
	g.writeln('\tint new_len = a->len + len;')
	g.writeln('\tif (new_len > a->cap) { a->cap = new_len < 4 ? 4 : new_len * 2; a->data = realloc(a->data, a->cap * a->elem_size); }')
	g.writeln('\tmemcpy((char*)a->data + a->len * a->elem_size, ptr, len * a->elem_size); a->len = new_len;')
	g.writeln('}')
	g.writeln('void* array_get(Array a, int idx) { return (char*)a.data + idx * a.elem_size; }')
	g.writeln('void array_set(Array a, int idx, void* val) { memcpy((char*)a.data + idx * a.elem_size, val, a.elem_size); }')
	g.writeln('Array array_clone(Array a) {')
	g.writeln('\tArray b = array_new(a.elem_size, a.len, a.cap);')
	g.writeln('\tmemcpy(b.data, a.data, a.len * a.elem_size); return b;')
	g.writeln('}')
	g.writeln('Array array_slice(Array a, int start, int end) {')
	g.writeln('\tint slen = end - start; if (slen < 0) slen = 0;')
	g.writeln('\tArray b = array_new(a.elem_size, slen, slen > 0 ? slen : 1);')
	g.writeln('\tif (slen > 0) memcpy(b.data, (char*)a.data + start * a.elem_size, slen * a.elem_size); return b;')
	g.writeln('}')
	g.writeln('void array_delete(Array* a, int idx) {')
	g.writeln('\tif (idx < a->len - 1) memmove((char*)a->data + idx * a->elem_size, (char*)a->data + (idx+1) * a->elem_size, (a->len - idx - 1) * a->elem_size);')
	g.writeln('\ta->len--;')
	g.writeln('}')
	g.writeln('int array_index_int(Array a, int val) {')
	g.writeln('\tfor (int i = 0; i < a.len; i++) if (*(int*)array_get(a, i) == val) return i; return -1;')
	g.writeln('}')
	g.writeln('bool array_contains_int(Array a, int val) { return array_index_int(a, val) >= 0; }')
	g.writeln('')
	g.writeln('static bool string__eq(string a, string b);')
	g.writeln('int array_index_string(Array a, string val) {')
	g.writeln('\tfor (int i = 0; i < a.len; i++) if (string__eq(*(string*)array_get(a, i), val)) return i; return -1;')
	g.writeln('}')
	g.writeln('bool array_contains_string(Array a, string val) { return array_index_string(a, val) >= 0; }')
	g.writeln('bool fixed_array_contains_string(const string* a, int len, string val) {')
	g.writeln('\tfor (int i = 0; i < len; i++) if (string__eq(a[i], val)) return true; return false;')
	g.writeln('}')
	g.writeln('bool fixed_array_contains_int(const int* a, int len, int val) {')
	g.writeln('\tfor (int i = 0; i < len; i++) if (a[i] == val) return true; return false;')
	g.writeln('}')
	g.writeln('')
	if !g.has_builtins {
		g.writeln('typedef struct { unsigned int hash; bool used; } MapSlot;')
		g.writeln('typedef struct { MapSlot* slots; char* keys; char* vals; int cap; int len; int key_size; int val_size; } map;')
	}
	g.writeln('')
	g.writeln('static unsigned int _map_hash_bytes(const void* key, int key_size) {')
	g.writeln('\tunsigned int h = 2166136261u; const unsigned char* p = (const unsigned char*)key;')
	g.writeln('\tfor (int i = 0; i < key_size; i++) { h ^= p[i]; h *= 16777619u; } return h ? h : 1;')
	g.writeln('}')
	g.writeln('static unsigned int _map_hash_string(string key) { return _map_hash_bytes(key.str, key.len); }')
	g.writeln('static void _map_set_internal(map* m, const void* key, unsigned int hash, const void* val);')
	g.writeln('static void _map_grow(map* m) {')
	g.writeln('\tint old_cap = m->cap; MapSlot* old_slots = m->slots; char* old_keys = m->keys; char* old_vals = m->vals;')
	g.writeln('\tm->cap *= 2; m->len = 0;')
	g.writeln('\tm->slots = (MapSlot*)calloc(m->cap, sizeof(MapSlot));')
	g.writeln('\tm->keys = (char*)calloc(m->cap, m->key_size); m->vals = (char*)calloc(m->cap, m->val_size);')
	g.writeln('\tfor (int i = 0; i < old_cap; i++) if (old_slots[i].used)')
	g.writeln('\t\t_map_set_internal(m, old_keys + i * m->key_size, old_slots[i].hash, old_vals + i * m->val_size);')
	g.writeln('\tfree(old_slots); free(old_keys); free(old_vals);')
	g.writeln('}')
	g.writeln('static void _map_set_internal(map* m, const void* key, unsigned int hash, const void* val) {')
	g.writeln('\tif (m->len * 2 >= m->cap) _map_grow(m);')
	g.writeln('\tunsigned int idx = hash & (m->cap - 1);')
	g.writeln('\twhile (m->slots[idx].used) {')
	g.writeln('\t\tif (m->slots[idx].hash == hash && memcmp(m->keys + idx * m->key_size, key, m->key_size) == 0) {')
	g.writeln('\t\t\tmemcpy(m->vals + idx * m->val_size, val, m->val_size); return; }')
	g.writeln('\t\tidx = (idx + 1) & (m->cap - 1);')
	g.writeln('\t}')
	g.writeln('\tm->slots[idx].used = 1; m->slots[idx].hash = hash;')
	g.writeln('\tmemcpy(m->keys + idx * m->key_size, key, m->key_size);')
	g.writeln('\tmemcpy(m->vals + idx * m->val_size, val, m->val_size); m->len++;')
	g.writeln('}')
	g.writeln('map new_map(int key_size, int val_size, void* hash_fn, void* eq_fn, void* clone_fn, void* free_fn) {')
	g.writeln('\tmap m = {0}; m.cap = 16; m.key_size = key_size; m.val_size = val_size;')
	g.writeln('\tm.slots = (MapSlot*)calloc(m.cap, sizeof(MapSlot));')
	g.writeln('\tm.keys = (char*)calloc(m.cap, key_size); m.vals = (char*)calloc(m.cap, val_size); return m;')
	g.writeln('}')
	g.writeln('void map__set(map* m, void* key, void* val) {')
	g.writeln('\tif (m->key_size > (int)sizeof(void*)) {')
	g.writeln('\t\tunsigned int hash = _map_hash_string(*(string*)key);')
	g.writeln('\t\tunsigned int idx = hash & (m->cap - 1);')
	g.writeln('\t\tif (m->len * 2 >= m->cap) _map_grow(m);')
	g.writeln('\t\tidx = hash & (m->cap - 1);')
	g.writeln('\t\twhile (m->slots[idx].used) {')
	g.writeln('\t\t\tif (m->slots[idx].hash == hash && string__eq(*(string*)(m->keys + idx * m->key_size), *(string*)key)) {')
	g.writeln('\t\t\t\tmemcpy(m->vals + idx * m->val_size, val, m->val_size); return; }')
	g.writeln('\t\t\tidx = (idx + 1) & (m->cap - 1);')
	g.writeln('\t\t}')
	g.writeln('\t\tm->slots[idx].used = 1; m->slots[idx].hash = hash;')
	g.writeln('\t\tmemcpy(m->keys + idx * m->key_size, key, m->key_size);')
	g.writeln('\t\tmemcpy(m->vals + idx * m->val_size, val, m->val_size); m->len++;')
	g.writeln('\t} else { _map_set_internal(m, key, _map_hash_bytes(key, m->key_size), val); }')
	g.writeln('}')
	g.writeln('void* map__get(map* m, void* key, void* zero) {')
	g.writeln('\tif (m->len == 0) return zero;')
	g.writeln('\tunsigned int hash = (m->key_size > (int)sizeof(void*)) ? _map_hash_string(*(string*)key) : _map_hash_bytes(key, m->key_size);')
	g.writeln('\tunsigned int idx = hash & (m->cap - 1);')
	g.writeln('\twhile (m->slots[idx].used) {')
	g.writeln('\t\tif (m->slots[idx].hash == hash) {')
	g.writeln('\t\t\tint eq = (m->key_size > (int)sizeof(void*)) ? string__eq(*(string*)(m->keys + idx * m->key_size), *(string*)key) : memcmp(m->keys + idx * m->key_size, key, m->key_size) == 0;')
	g.writeln('\t\t\tif (eq) return m->vals + idx * m->val_size;')
	g.writeln('\t\t}')
	g.writeln('\t\tidx = (idx + 1) & (m->cap - 1);')
	g.writeln('\t} return zero;')
	g.writeln('}')
	g.writeln('void* map__get_check(map* m, void* key) {')
	g.writeln('\tif (m->len == 0) return 0;')
	g.writeln('\tunsigned int hash = (m->key_size > (int)sizeof(void*)) ? _map_hash_string(*(string*)key) : _map_hash_bytes(key, m->key_size);')
	g.writeln('\tunsigned int idx = hash & (m->cap - 1);')
	g.writeln('\twhile (m->slots[idx].used) {')
	g.writeln('\t\tif (m->slots[idx].hash == hash) {')
	g.writeln('\t\t\tint eq = (m->key_size > (int)sizeof(void*)) ? string__eq(*(string*)(m->keys + idx * m->key_size), *(string*)key) : memcmp(m->keys + idx * m->key_size, key, m->key_size) == 0;')
	g.writeln('\t\t\tif (eq) return m->vals + idx * m->val_size;')
	g.writeln('\t\t}')
	g.writeln('\t\tidx = (idx + 1) & (m->cap - 1);')
	g.writeln('\t} return 0;')
	g.writeln('}')
	g.writeln('bool map__exists(map* m, void* key) { return map__get_check(m, key) != 0; }')
	g.writeln('static void _map_delete_idx(map* m, unsigned int idx) {')
	g.writeln('\tm->slots[idx].used = 0; m->len--;')
	g.writeln('\tunsigned int j = (idx + 1) & (m->cap - 1);')
	g.writeln('\twhile (m->slots[j].used) {')
	g.writeln('\t\tunsigned int k = m->slots[j].hash & (m->cap - 1);')
	g.writeln('\t\tif ((j > idx && (k <= idx || k > j)) || (j < idx && k <= idx && k > j)) {')
	g.writeln('\t\t\tm->slots[idx] = m->slots[j];')
	g.writeln('\t\t\tmemcpy(m->keys + idx * m->key_size, m->keys + j * m->key_size, m->key_size);')
	g.writeln('\t\t\tmemcpy(m->vals + idx * m->val_size, m->vals + j * m->val_size, m->val_size);')
	g.writeln('\t\t\tm->slots[j].used = 0; idx = j;')
	g.writeln('\t\t}')
	g.writeln('\t\tj = (j + 1) & (m->cap - 1);')
	g.writeln('\t}')
	g.writeln('}')
	g.writeln('void map__delete(map* m, void* key) {')
	g.writeln('\tunsigned int hash = (m->key_size > (int)sizeof(void*)) ? _map_hash_string(*(string*)key) : _map_hash_bytes(key, m->key_size);')
	g.writeln('\tunsigned int idx = hash & (m->cap - 1);')
	g.writeln('\twhile (m->slots[idx].used) {')
	g.writeln('\t\tif (m->slots[idx].hash == hash) {')
	g.writeln('\t\t\tint eq = (m->key_size > (int)sizeof(void*)) ? string__eq(*(string*)(m->keys + idx * m->key_size), *(string*)key) : memcmp(m->keys + idx * m->key_size, key, m->key_size) == 0;')
	g.writeln('\t\t\tif (eq) { _map_delete_idx(m, idx); return; }')
	g.writeln('\t\t}')
	g.writeln('\t\tidx = (idx + 1) & (m->cap - 1);')
	g.writeln('\t}')
	g.writeln('}')
	g.writeln('map map__clone(map* m) {')
	g.writeln('\tmap n = new_map(m->key_size, m->val_size, 0, 0, 0, 0);')
	g.writeln('\tfree(n.slots); free(n.keys); free(n.vals);')
	g.writeln('\tn.cap = m->cap; n.len = m->len;')
	g.writeln('\tn.slots = (MapSlot*)calloc(m->cap, sizeof(MapSlot)); memcpy(n.slots, m->slots, m->cap * sizeof(MapSlot));')
	g.writeln('\tn.keys = (char*)calloc(m->cap, m->key_size); memcpy(n.keys, m->keys, m->cap * m->key_size);')
	g.writeln('\tn.vals = (char*)calloc(m->cap, m->val_size); memcpy(n.vals, m->vals, m->cap * m->val_size);')
	g.writeln('\treturn n;')
	g.writeln('}')
	g.writeln('void map__clear(map* m) {')
	g.writeln('\tmemset(m->slots, 0, m->cap * sizeof(MapSlot));')
	g.writeln('\tm->len = 0;')
	g.writeln('}')
	g.writeln('')
	g.writeln('void println(string s) {')
	g.writeln('\tfwrite(s.str, 1, s.len, stdout);')
	g.writeln('\tputchar(10);')
	g.writeln('}')
	g.writeln('void print(string s) {')
	g.writeln('\tfwrite(s.str, 1, s.len, stdout);')
	g.writeln('}')
	g.writeln('void eprintln(string s) {')
	g.writeln('\tfwrite(s.str, 1, s.len, stderr);')
	g.writeln('\tputchar(10);')
	g.writeln('}')
	g.writeln('string int_str(int n) {')
	g.writeln('\tchar* buf = malloc(20);')
	g.writeln('\tint len = snprintf(buf, 20, "%d", n);')
	g.writeln('\treturn (string){buf, len, 0};')
	g.writeln('}')
	g.writeln('string string__plus(string a, string b) {')
	g.writeln('\tint len = a.len + b.len;')
	g.writeln('\tchar* s = malloc(len + 1);')
	g.writeln('\tmemcpy(s, a.str, a.len);')
	g.writeln('\tmemcpy(s + a.len, b.str, b.len);')
	g.writeln('\ts[len] = 0;')
	g.writeln('\treturn (string){s, len, 0};')
	g.writeln('}')
	g.writeln('void* memdup(const void* src, int sz) {')
	g.writeln('\tvoid* p = malloc(sz);')
	g.writeln('\tmemcpy(p, src, sz);')
	g.writeln('\treturn p;')
	g.writeln('}')
	g.writeln('bool string__eq(string a, string b) {')
	g.writeln('\tif (a.len != b.len) return 0;')
	g.writeln('\treturn memcmp(a.str, b.str, a.len) == 0;')
	g.writeln('}')
	g.writeln('string tos(u8* s, int len) { return (string){(char*)s, len, 0}; }')
	g.writeln('string tos3(char* s) { return (string){s, s ? (int)strlen(s) : 0, 0}; }')
	g.writeln('string tos_clone(u8* s) { if (!s) return (string){0}; int n = (int)strlen((char*)s); char* p = malloc(n+1); memcpy(p,s,n); p[n]=0; return (string){p,n,0}; }')
	g.writeln('string string__clone(string s) {')
	g.writeln('\tchar* p = malloc(s.len + 1); memcpy(p, s.str, s.len); p[s.len] = 0;')
	g.writeln('\treturn (string){p, s.len, 0};')
	g.writeln('}')
	g.writeln('void string__free(string* s) { if (s->str && !s->is_lit) free((void*)s->str); }')
	g.writeln('string string_plus_many(int count, string* parts) {')
	g.writeln('\tint len = 0;')
	g.writeln('\tfor (int i = 0; i < count; i++) len += parts[i].len;')
	g.writeln('\tchar* s = malloc(len + 1);')
	g.writeln('\tint off = 0;')
	g.writeln('\tfor (int i = 0; i < count; i++) {')
	g.writeln('\t\tmemcpy(s + off, parts[i].str, parts[i].len);')
	g.writeln('\t\toff += parts[i].len;')
	g.writeln('\t}')
	g.writeln('\ts[len] = 0;')
	g.writeln('\treturn (string){s, len, 0};')
	g.writeln('}')
	g.writeln('string i64_str(i64 n) {')
	g.writeln('\tchar* buf = malloc(24); int len = snprintf(buf, 24, "%lld", (long long)n);')
	g.writeln('\treturn (string){buf, len, 0};')
	g.writeln('}')
	g.writeln('string u8_str(u8 n) { return int_str((int)n); }')
	g.writeln('string bool_str(bool b) { return b ? (string){"true", 4, 1} : (string){"false", 5, 1}; }')
	g.writeln('string double_str(double d) {')
	g.writeln('\tchar* buf = malloc(32); int len = snprintf(buf, 32, "%g", d);')
	g.writeln('\treturn (string){buf, len, 0};')
	g.writeln('}')
	g.writeln('bool string__contains(string s, string sub) {')
	g.writeln('\tif (sub.len > s.len) return 0;')
	g.writeln('\tfor (int i = 0; i <= s.len - sub.len; i++) if (memcmp(s.str + i, sub.str, sub.len) == 0) return 1;')
	g.writeln('\treturn 0;')
	g.writeln('}')
	g.writeln('string string__replace(string s, string old_s, string new_s) {')
	g.writeln('\tif (old_s.len == 0 || old_s.len > s.len) return s;')
	g.writeln('\tint count = 0;')
	g.writeln('\tfor (int i = 0; i <= s.len - old_s.len; i++) if (memcmp(s.str+i, old_s.str, old_s.len)==0) { count++; i += old_s.len-1; }')
	g.writeln('\tif (count == 0) return s;')
	g.writeln('\tint new_len = s.len + count * (new_s.len - old_s.len);')
	g.writeln('\tchar* buf = malloc(new_len + 1); int pos = 0;')
	g.writeln('\tfor (int i = 0; i < s.len; ) {')
	g.writeln('\t\tif (i <= s.len - old_s.len && memcmp(s.str+i, old_s.str, old_s.len)==0) { memcpy(buf+pos, new_s.str, new_s.len); pos += new_s.len; i += old_s.len; }')
	g.writeln('\t\telse { buf[pos++] = s.str[i++]; }')
	g.writeln('\t} buf[new_len] = 0; return (string){buf, new_len, 0};')
	g.writeln('}')
	g.writeln('bool string__starts_with(string s, string p) {')
	g.writeln('\tif (p.len > s.len) return 0;')
	g.writeln('\treturn memcmp(s.str, p.str, p.len) == 0;')
	g.writeln('}')
	g.writeln('bool string__ends_with(string s, string p) {')
	g.writeln('\tif (p.len > s.len) return 0;')
	g.writeln('\treturn memcmp(s.str + s.len - p.len, p.str, p.len) == 0;')
	g.writeln('}')
	g.writeln('Array string__bytes(string s) {')
	g.writeln('\tArray a = array_new(1, s.len, s.len);')
	g.writeln('\tmemcpy(a.data, s.str, s.len);')
	g.writeln('\treturn a;')
	g.writeln('}')
	g.writeln('int string__index_u8(string s, u8 c) {')
	g.writeln('\tfor (int i = 0; i < s.len; i++) if (((u8*)s.str)[i] == c) return i;')
	g.writeln('\treturn -1;')
	g.writeln('}')
	g.writeln('int string__last_index_u8(string s, u8 c) {')
	g.writeln('\tfor (int i = s.len - 1; i >= 0; i--) if (((u8*)s.str)[i] == c) return i;')
	g.writeln('\treturn -1;')
	g.writeln('}')
	g.writeln('Optional string__index(string s, string p) {')
	g.writeln('\tif (p.len > s.len) return (Optional){0};')
	g.writeln('\tfor (int i = 0; i <= s.len - p.len; i++) if (memcmp(s.str + i, p.str, p.len) == 0) return (Optional){.ok = true, .value = i};')
	g.writeln('\treturn (Optional){0};')
	g.writeln('}')
	g.writeln('Optional string__last_index(string s, string p) {')
	g.writeln('\tif (p.len > s.len) return (Optional){0};')
	g.writeln('\tfor (int i = s.len - p.len; i >= 0; i--) if (memcmp(s.str + i, p.str, p.len) == 0) return (Optional){.ok = true, .value = i};')
	g.writeln('\treturn (Optional){0};')
	g.writeln('}')
	g.writeln('string string__substr(string s, int start, int end) {')
	g.writeln('\tint slen = end - start; if (slen <= 0) return (string){"", 0, 1};')
	g.writeln('\tchar* buf = malloc(slen + 1); memcpy(buf, s.str + start, slen); buf[slen] = 0;')
	g.writeln('\treturn (string){buf, slen, 0};')
	g.writeln('}')
	g.writeln('string string__all_before(string s, string sub) {')
	g.writeln('\tOptional r = string__index(s, sub); if (!r.ok) return s;')
	g.writeln('\treturn string__substr(s, 0, r.value);')
	g.writeln('}')
	g.writeln('string string__all_before_last(string s, string sub) {')
	g.writeln('\tOptional r = string__last_index(s, sub); if (!r.ok) return s;')
	g.writeln('\treturn string__substr(s, 0, r.value);')
	g.writeln('}')
	g.writeln('string string__all_after(string s, string sub) {')
	g.writeln('\tOptional r = string__index(s, sub); if (!r.ok) return s;')
	g.writeln('\treturn string__substr(s, r.value + sub.len, s.len);')
	g.writeln('}')
	g.writeln('string string__all_after_last(string s, string sub) {')
	g.writeln('\tOptional r = string__last_index(s, sub); if (!r.ok) return s;')
	g.writeln('\treturn string__substr(s, r.value + sub.len, s.len);')
	g.writeln('}')
	g.writeln('string string__trim_left(string s, string cutset) {')
	g.writeln('\tint i = 0; while (i < s.len) { bool found = 0;')
	g.writeln('\t\tfor (int j = 0; j < cutset.len; j++) if (s.str[i] == cutset.str[j]) { found = 1; break; }')
	g.writeln('\t\tif (!found) break; i++; }')
	g.writeln('\treturn string__substr(s, i, s.len);')
	g.writeln('}')
	g.writeln('string string__trim_right(string s, string cutset) {')
	g.writeln('\tint i = s.len - 1; while (i >= 0) { bool found = 0;')
	g.writeln('\t\tfor (int j = 0; j < cutset.len; j++) if (s.str[i] == cutset.str[j]) { found = 1; break; }')
	g.writeln('\t\tif (!found) break; i--; }')
	g.writeln('\treturn string__substr(s, 0, i + 1);')
	g.writeln('}')
	g.writeln('string string__trim_space(string s) {')
	g.writeln('\treturn string__trim_right(string__trim_left(s, (string){" \\t\\n\\r", 4, 1}), (string){" \\t\\n\\r", 4, 1});')
	g.writeln('}')
	g.writeln('bool string__contains_u8(string s, u8 x) { return string__index_u8(s, x) >= 0; }')
	g.writeln('int string__count(string s, string sub) {')
	g.writeln('\tif (sub.len == 0 || sub.len > s.len) return 0; int c = 0;')
	g.writeln('\tfor (int i = 0; i <= s.len - sub.len; i++) if (memcmp(s.str+i, sub.str, sub.len)==0) { c++; i += sub.len-1; }')
	g.writeln('\treturn c;')
	g.writeln('}')
	g.writeln('string string__after(string s, string sub) { return string__all_after(s, sub); }')
	g.writeln('string string__before(string s, string sub) { return string__all_before(s, sub); }')
	g.writeln('int string__int(string s) { return (int)strtol(s.str, NULL, 10); }')
	g.writeln('i64 string__i64(string s) { return (i64)strtoll(s.str, NULL, 10); }')
	g.writeln('Array string__split(string s, string delim) {')
	g.writeln('\tArray a = array_new(sizeof(string), 0, 4);')
	g.writeln('\tif (delim.len == 0) { array_push(&a, &s); return a; }')
	g.writeln('\tint i = 0;')
	g.writeln('\twhile (i <= s.len - delim.len) {')
	g.writeln('\t\tif (memcmp(s.str + i, delim.str, delim.len) == 0) {')
	g.writeln('\t\t\tstring part = string__substr(s, 0, i);')
	g.writeln('\t\t\tarray_push(&a, &part);')
	g.writeln('\t\t\ts = string__substr(s, i + delim.len, s.len);')
	g.writeln('\t\t\ti = 0; continue;')
	g.writeln('\t\t} i++;')
	g.writeln('\t}')
	g.writeln('\tarray_push(&a, &s); return a;')
	g.writeln('}')
	g.writeln('string array_string_join(Array a, string sep) {')
	g.writeln('\tif (a.len == 0) return (string){"", 0, 1};')
	g.writeln('\tint total = 0;')
	g.writeln('\tfor (int i = 0; i < a.len; i++) { total += (*(string*)array_get(a, i)).len; if (i > 0) total += sep.len; }')
	g.writeln('\tchar* buf = malloc(total + 1); int pos = 0;')
	g.writeln('\tfor (int i = 0; i < a.len; i++) {')
	g.writeln('\t\tif (i > 0) { memcpy(buf + pos, sep.str, sep.len); pos += sep.len; }')
	g.writeln('\t\tstring s = *(string*)array_get(a, i); memcpy(buf + pos, s.str, s.len); pos += s.len;')
	g.writeln('\t} buf[total] = 0; return (string){buf, total, 0};')
	g.writeln('}')
	g.writeln('void v_panic(string s) {')
	g.writeln('\tfwrite(s.str, 1, s.len, stderr);')
	g.writeln('\tputc(10, stderr);')
	g.writeln('\texit(1);')
	g.writeln('}')
	g.writeln('Optional optional_ok(int v) { return (Optional){.ok = true, .value = v}; }')
	g.writeln('Optional optional_none() { return (Optional){.ok = false}; }')
	g.writeln('bool isnil(void* p) { return p == NULL; }')
	g.writeln('Optional error_with_code(string msg, int code) { return (Optional){.ok = false}; }')
	g.writeln('Optional check_fwrite(size_t n) { return (Optional){.ok = n > 0, .value = (int)n}; }')
	g.writeln('void* malloc_noscan(size_t n) { return malloc(n); }')
	g.writeln('string u8__vstring(u8* s) { return (string){(char*)s, (int)strlen((char*)s), 0}; }')
	g.writeln('string u8__vstring_with_len(u8* s, int len) { return (string){(char*)s, len, 0}; }')
	g.writeln('char v_char(char c) { return c; }')
	g.writeln('')
	if g.has_builtins {
		g.writeln('extern int g_main_argc;')
		g.writeln('extern void* g_main_argv;')
		g.writeln('string utf32_to_str_no_malloc(u32 code, u8* buf) {')
		g.writeln('\tif (code <= 0x7F) { buf[0] = (u8)code; return tos(buf, 1); }')
		g.writeln('\tif (code <= 0x7FF) { buf[0] = 0xC0|(code>>6); buf[1] = 0x80|(code&0x3F); return tos(buf, 2); }')
		g.writeln('\tif (code <= 0xFFFF) { buf[0] = 0xE0|(code>>12); buf[1] = 0x80|((code>>6)&0x3F); buf[2] = 0x80|(code&0x3F); return tos(buf, 3); }')
		g.writeln('\tbuf[0] = 0xF0|(code>>18); buf[1] = 0x80|((code>>12)&0x3F); buf[2] = 0x80|((code>>6)&0x3F); buf[3] = 0x80|(code&0x3F); return tos(buf, 4);')
		g.writeln('}')
		g.writeln('void array_ensure_cap(Array* a, int cap) {')
		g.writeln('\tif (cap <= a->cap) return;')
		g.writeln('\tint new_cap = a->cap > 0 ? a->cap : 2;')
		g.writeln('\twhile (new_cap < cap) new_cap *= 2;')
		g.writeln('\ta->data = realloc(a->data, new_cap * a->elem_size);')
		g.writeln('\ta->cap = new_cap;')
		g.writeln('}')
		g.writeln('Array arguments(void) {')
		g.writeln('\tchar** argv = (char**)g_main_argv;')
		g.writeln('\tArray a = {0, 0, 0, sizeof(string)};')
		g.writeln('\ta.data = malloc(g_main_argc * sizeof(string));')
		g.writeln('\ta.len = g_main_argc; a.cap = g_main_argc;')
		g.writeln('\tfor (int i = 0; i < g_main_argc; i++) {')
		g.writeln('\t\tint slen = strlen(argv[i]);')
		g.writeln('\t\tchar* s = malloc(slen + 1); memcpy(s, argv[i], slen + 1);')
		g.writeln('\t\t((string*)a.data)[i] = (string){s, slen, 0};')
		g.writeln('\t}')
		g.writeln('\treturn a;')
		g.writeln('}')
		g.writeln('string os__getwd(void) {')
		g.writeln('\tchar buf[4096];')
		g.writeln('\tif (getcwd(buf, sizeof(buf))) {')
		g.writeln('\t\tint len = strlen(buf);')
		g.writeln('\t\tchar* s = malloc(len + 1); memcpy(s, buf, len + 1);')
		g.writeln('\t\treturn (string){s, len, 0};')
		g.writeln('\t}')
		g.writeln('\treturn (string){"", 0, 0};')
		g.writeln('}')
		g.writeln('mach_timebase_info_data_t time__init_time_base(void) {')
		g.writeln('\tmach_timebase_info_data_t tb; mach_timebase_info(&tb); return tb;')
		g.writeln('}')
		g.writeln('Optional os__check_fwrite(size_t n) { return (Optional){.ok = n > 0, .value = (int)n}; }')
		if 'os.File' !in g.tc.structs {
			g.writeln('typedef struct { void* cfile; int fd; bool is_opened; } os__File;')
		}
		if 'os.File.close' !in g.tc.fn_param_types {
			g.writeln('void os__File__close(os__File* f) { if (!f->is_opened) return; f->is_opened = false; fflush((FILE*)f->cfile); fclose((FILE*)f->cfile); f->cfile = 0; }')
		}
		g.writeln('void* memdup_noscan(void* src, int sz) { void* d = malloc(sz); memcpy(d, src, sz); return d; }')
		g.writeln('#include <spawn.h>')
		g.writeln('extern char **environ;')
		g.writeln('static int v_os_execute_capture_start(const char *cmd, int *child_pid, int *read_fd) {')
		g.writeln('\tint pipefd[2]; if (pipe(pipefd) != 0) return -1;')
		g.writeln('\tposix_spawn_file_actions_t fa; posix_spawn_file_actions_init(&fa);')
		g.writeln('\tposix_spawn_file_actions_adddup2(&fa, pipefd[1], 1);')
		g.writeln('\tposix_spawn_file_actions_adddup2(&fa, pipefd[1], 2);')
		g.writeln('\tposix_spawn_file_actions_addclose(&fa, pipefd[0]);')
		g.writeln('\tchar *argv[] = {"/bin/sh", "-c", (char*)cmd, NULL};')
		g.writeln('\tpid_t pid; int ret = posix_spawn(&pid, "/bin/sh", &fa, NULL, argv, environ);')
		g.writeln('\tposix_spawn_file_actions_destroy(&fa); close(pipefd[1]);')
		g.writeln('\tif (ret != 0) { close(pipefd[0]); return -1; }')
		g.writeln('\t*child_pid = pid; *read_fd = pipefd[0]; return 0;')
		g.writeln('}')
		g.writeln('#define vmemcpy memcpy')
		g.writeln('#define vmemset memset')
		g.writeln('')
	} else {
		g.writeln('typedef struct { char* buf; int len; int cap; } strings__Builder;')
		g.writeln('strings__Builder strings__new_builder(int cap) {')
		g.writeln('\tstrings__Builder b; b.cap = cap > 0 ? cap : 64; b.len = 0;')
		g.writeln('\tb.buf = (char*)malloc(b.cap); return b;')
		g.writeln('}')
		g.writeln('void strings__Builder__write_string(strings__Builder* b, string s) {')
		g.writeln('\twhile (b->len + s.len > b->cap) { b->cap *= 2; b->buf = (char*)realloc(b->buf, b->cap); }')
		g.writeln('\tmemcpy(b->buf + b->len, s.str, s.len); b->len += s.len;')
		g.writeln('}')
		g.writeln('void strings__Builder__writeln(strings__Builder* b, string s) {')
		g.writeln('\tstrings__Builder__write_string(b, s);')
		g.writeln('\twhile (b->len + 1 > b->cap) { b->cap *= 2; b->buf = (char*)realloc(b->buf, b->cap); }')
		g.writeln('\tb->buf[b->len++] = 10;')
		g.writeln('}')
		g.writeln('string strings__Builder__str(strings__Builder* b) {')
		g.writeln('\tchar* s = (char*)malloc(b->len + 1); memcpy(s, b->buf, b->len); s[b->len] = 0;')
		g.writeln('\tstring r = {s, b->len, 0}; b->len = 0; return r;')
		g.writeln('}')
		g.writeln('void strings__Builder__write_ptr(strings__Builder* b, void* ptr, int len) {')
		g.writeln('\twhile (b->len + len > b->cap) { b->cap *= 2; b->buf = (char*)realloc(b->buf, b->cap); }')
		g.writeln('\tmemcpy(b->buf + b->len, ptr, len); b->len += len;')
		g.writeln('}')
		g.writeln('void strings__Builder__write_u8(strings__Builder* b, u8 c) {')
		g.writeln('\twhile (b->len + 1 > b->cap) { b->cap *= 2; b->buf = (char*)realloc(b->buf, b->cap); }')
		g.writeln('\tb->buf[b->len++] = c;')
		g.writeln('}')
		g.writeln('')
	}
	g.writeln('bool u8__is_alnum(u8 c) { return (c >= \'a\' && c <= \'z\') || (c >= \'A\' && c <= \'Z\') || (c >= \'0\' && c <= \'9\'); }')
	g.writeln('bool u8__is_digit(u8 c) { return c >= \'0\' && c <= \'9\'; }')
	g.writeln('bool u8__is_alpha(u8 c) { return (c >= \'a\' && c <= \'z\') || (c >= \'A\' && c <= \'Z\'); }')
	g.writeln('bool u8__is_letter(u8 c) { return u8__is_alpha(c) || c == \'_\'; }')
	g.writeln('bool u8__is_hex_digit(u8 c) { return u8__is_digit(c) || (c >= \'a\' && c <= \'f\') || (c >= \'A\' && c <= \'F\'); }')
	g.writeln('bool u8__is_space(u8 c) { return c == \' \' || c == \'\\t\' || c == \'\\n\' || c == \'\\r\' || c == \'\\v\' || c == \'\\f\'; }')
	g.writeln('bool int__is_alnum(int c) { return u8__is_alnum((u8)c); }')
	g.writeln('bool int__is_digit(int c) { return u8__is_digit((u8)c); }')
	g.writeln('bool int__is_alpha(int c) { return u8__is_alpha((u8)c); }')
	g.writeln('bool int__is_letter(int c) { return u8__is_letter((u8)c); }')
	g.writeln('bool int__is_hex_digit(int c) { return u8__is_hex_digit((u8)c); }')
	g.writeln('bool int__is_space(int c) { return u8__is_space((u8)c); }')
	g.writeln('void v_exit(int code) { exit(code); }')
	g.writeln('int v_copy(Array* dst, Array src) {')
	g.writeln('\tint n = dst->len < src.len ? dst->len : src.len;')
	g.writeln('\tif (n > 0) memcpy(dst->data, src.data, n * dst->elem_size);')
	g.writeln('\treturn n;')
	g.writeln('}')
	g.writeln('')
}

fn (mut g FlatGen) global_decls() {
	for name, typ in g.global_types {
		ct := g.tc.c_type(typ)
		if ct == 'void' {
			continue
		}
		if typ is types.Struct && typ.name.starts_with('C.') {
			continue
		}
		g.writeln('${ct} ${c_name(name)};')
	}
	if g.global_types.len > 0 {
		g.writeln('')
	}
}

fn (g &FlatGen) const_refs_other_const(val_id flat.NodeId) bool {
	if int(val_id) < 0 || int(val_id) >= g.a.nodes.len {
		return false
	}
	node := g.a.nodes[int(val_id)]
	if node.kind == .ident && node.value in g.const_vals {
		return true
	}
	for i in 0 .. node.children_count {
		if g.const_refs_other_const(g.a.child(&node, i)) {
			return true
		}
	}
	return false
}

fn (mut g FlatGen) emit_const(name string, val_id flat.NodeId) {
	if name in g.const_modules {
		g.tc.cur_module = g.const_modules[name]
	}
	val_node := g.a.nodes[int(val_id)]
	if val_node.kind == .empty {
		return
	}
	tmp_sb := g.sb
	g.sb = strings.new_builder(256)
	g.gen_expr(val_id)
	expr_str := g.sb.str()
	g.sb = tmp_sb
	if expr_str.trim_space().len == 0 {
		return
	}
	v_type := g.tc.resolve_type(val_id)
	ct := g.tc.c_type(v_type)
	qname := if name in g.const_modules && g.const_modules[name].len > 0 && g.const_modules[name] != 'main' && g.const_modules[name] != 'builtin' {
		c_name('${g.const_modules[name]}.${name}')
	} else {
		c_name(name)
	}
	if !g.is_const_expr(val_id) {
		if v_type is types.ArrayFixed && val_node.kind == .array_literal {
			c_elem := g.tc.c_type(v_type.elem_type)
			g.writeln('${c_elem} ${qname}[${v_type.len}];')
			for ci in 0 .. val_node.children_count {
				elem_id := g.a.child(&val_node, ci)
				tmp2 := g.sb
				g.sb = strings.new_builder(64)
				g.gen_expr(elem_id)
				estr := g.sb.str()
				g.sb = tmp2
				g.runtime_inits << '\t${qname}[${ci}] = ${estr};'
			}
		} else if g.is_runtime_assignable(val_id) {
			g.writeln('${ct} ${qname};')
			g.runtime_inits << '\t${qname} = ${expr_str};'
		}
		return
	}
	if v_type is types.String {
		g.writeln('string ${qname} = ${expr_str};')
	} else if v_type is types.ArrayFixed {
		c_elem := g.tc.c_type(v_type.elem_type)
		g.writeln('const ${c_elem} ${qname}[] = ${expr_str};')
	} else {
		g.writeln('const ${ct} ${qname} = ${expr_str};')
	}
}

fn (mut g FlatGen) precompute_consts() string {
	old_sb := g.sb
	g.sb = strings.new_builder(1024)
	mut deferred := []string{}
	for name, val_id in g.const_vals {
		if int(val_id) < 0 || int(val_id) >= g.a.nodes.len {
			continue
		}
		if g.const_refs_other_const(val_id) {
			deferred << name
		} else {
			g.emit_const(name, val_id)
		}
	}
	for name in deferred {
		g.emit_const(name, g.const_vals[name])
	}
	if g.const_vals.len > 0 {
		g.writeln('')
	}
	result := g.sb.str()
	g.sb = old_sb
	return result
}

fn (g &FlatGen) is_const_expr(id flat.NodeId) bool {
	if int(id) < 0 || int(id) >= g.a.nodes.len {
		return false
	}
	node := g.a.nodes[int(id)]
	return match node.kind {
		.int_literal, .float_literal, .bool_literal, .char_literal, .enum_val {
			true
		}
		.prefix {
			if node.op == .amp {
				false
			} else {
				g.is_const_expr(g.a.child(&node, 0))
			}
		}
		.infix {
			g.is_const_expr(g.a.child(&node, 0)) && g.is_const_expr(g.a.child(&node, 1))
		}
		.paren {
			g.is_const_expr(g.a.child(&node, 0))
		}
		.cast_expr {
			g.is_const_expr(g.a.child(&node, 0))
		}
		.ident {
			node.value in g.const_vals
		}
		.array_literal {
			mut all_const := true
			for ci in 0 .. node.children_count {
				if !g.is_const_expr(g.a.child(&node, ci)) {
					all_const = false
					break
				}
			}
			all_const
		}
		.struct_init {
			mut all_const := true
			for ci in 0 .. node.children_count {
				child := g.a.child_node(&node, ci)
				if child.children_count > 0 && !g.is_const_expr(g.a.child(child, 0)) {
					all_const = false
					break
				}
			}
			all_const
		}
		else {
			false
		}
	}
}

fn (g &FlatGen) is_runtime_assignable(id flat.NodeId) bool {
	if int(id) < 0 || int(id) >= g.a.nodes.len {
		return false
	}
	node := g.a.nodes[int(id)]
	return match node.kind {
		.string_literal, .string_interp {
			true
		}
		.call {
			if node.children_count > 0 {
				callee_id := g.a.child(&node, 0)
				if int(callee_id) >= 0 {
					callee := g.a.nodes[int(callee_id)]
					callee.kind == .ident || callee.kind == .selector
				} else {
					false
				}
			} else {
				false
			}
		}
		.ident {
			true
		}
		.cast_expr, .prefix, .struct_init {
			true
		}
		else {
			false
		}
	}
}

fn (g &FlatGen) op_str(op flat.Op) string {
	return match op {
		.plus { '+' }
		.minus { '-' }
		.mul { '*' }
		.div { '/' }
		.mod { '%' }
		.eq { '==' }
		.ne { '!=' }
		.lt { '<' }
		.gt { '>' }
		.le { '<=' }
		.ge { '>=' }
		.amp { '&' }
		.pipe { '|' }
		.xor { '^' }
		.left_shift { '<<' }
		.right_shift { '>>' }
		.logical_and { '&&' }
		.logical_or { '||' }
		.not { '!' }
		.bit_not { '~' }
		.assign { '=' }
		.plus_assign { '+=' }
		.minus_assign { '-=' }
		.mul_assign { '*=' }
		.div_assign { '/=' }
		.mod_assign { '%=' }
		.amp_assign { '&=' }
		.pipe_assign { '|=' }
		.xor_assign { '^=' }
		.left_shift_assign { '<<=' }
		.right_shift_assign { '>>=' }
		.inc { '++' }
		.dec { '--' }
		.dot { '.' }
		.arrow { '->' }
		.none { '' }
	}
}

fn (mut g FlatGen) write(s string) {
	if g.sb.len == 0 || g.sb.last_n(1) == '\n' {
		g.write_indent()
	}
	g.sb.write_string(s)
}

fn (mut g FlatGen) writeln(s string) {
	if s.len > 0 {
		if g.sb.len == 0 || g.sb.last_n(1) == '\n' {
			g.write_indent()
		}
		g.sb.write_string(s)
	}
	g.sb.write_string('\n')
}

fn (mut g FlatGen) write_indent() {
	for _ in 0 .. g.indent {
		g.sb.write_string('\t')
	}
}
