module c

import v3.flat
import v3.types

fn (mut g FlatGen) gen_fns() {
	for i, node in g.a.nodes {
		if node.kind == .module_decl {
			g.tc.cur_module = node.value
			continue
		}
		if node.kind == .fn_decl {
			if !g.should_emit_fn_node(node, i) {
				continue
			}
			qfn := g.qualified_fn_name(node.value)
			if qfn in g.emitted_fns {
				continue
			}
			g.emitted_fns[qfn] = true
			g.gen_fn(node)
		}
	}
}

fn (mut g FlatGen) should_emit_fn_node(node flat.Node, node_index int) bool {
	_ = node_index
	dfn := g.dotted_fn_name(node.value)
	if g.used_fns.len > 0 && node.value !in g.used_fns && dfn !in g.used_fns {
		return false
	}
	if g.has_generic_params(node) {
		return false
	}
	if node.value.starts_with('Gen.') && g.tc.cur_module == 'c' {
		return false
	}
	return true
}

fn (g &FlatGen) qualified_fn_name(name string) string {
	if g.tc.cur_module.len > 0 && g.tc.cur_module != 'main' && g.tc.cur_module != 'builtin' {
		return c_name('${g.tc.cur_module}.${name}')
	}
	return c_name(name)
}

fn (g &FlatGen) dotted_fn_name(name string) string {
	if g.tc.cur_module.len > 0 && g.tc.cur_module != 'main' && g.tc.cur_module != 'builtin' {
		return '${g.tc.cur_module}.${name}'
	}
	return name
}

fn (mut g FlatGen) gen_fn(node flat.Node) {
	g.tc.push_scope()
	g.defers = []flat.NodeId{}
	g.set_cur_fn_ret(types.Type(types.void_))
	params := g.fn_params_list(node)
	for p in params {
		if p.value.len > 0 {
			g.tc.cur_scope.insert(p.value, g.tc.parse_type(p.typ))
		}
	}

	if node.value == 'main' {
		g.writeln('int main(int argc, char** argv) {')
		if g.has_builtins {
			g.writeln('\tg_main_argc = argc;')
			g.writeln('\tg_main_argv = argv;')
		}
		if g.runtime_inits.len > 0 {
			g.writeln('\t_vinit();')
		}
	} else {
		ret_type := g.tc.parse_type(node.typ)
		g.set_cur_fn_ret(ret_type)
		g.write(g.optional_type_name(ret_type))
		g.write(' ')
		g.write(g.qualified_fn_name(node.value))
		g.write('(')
		g.write_fn_params(params)
		g.writeln(') {')
	}
	g.indent++

	body := g.fn_body_ids(node)
	for id in body {
		g.gen_node(id)
	}
	g.gen_defers()
	if node.value == 'main' {
		g.writeln('return 0;')
	} else if g.cur_fn_ret_is_optional {
		ct := g.optional_type_name(g.cur_fn_ret)
		g.writeln('return (${ct}){.ok = true};')
	}
	g.indent--
	g.writeln('}')
	g.writeln('')
	g.tc.pop_scope()
}

fn (mut g FlatGen) set_cur_fn_ret(ret_type types.Type) {
	g.cur_fn_ret = ret_type
	g.cur_fn_ret_is_optional = false
	g.cur_fn_ret_base = types.Type(types.void_)
	if ret_type is types.OptionType {
		g.cur_fn_ret_is_optional = true
		g.cur_fn_ret_base = ret_type.base_type
	} else if ret_type is types.ResultType {
		g.cur_fn_ret_is_optional = true
		g.cur_fn_ret_base = ret_type.base_type
	}
}

fn (mut g FlatGen) gen_defers() {
	mut i := g.defers.len - 1
	for i >= 0 {
		defer_body := g.a.nodes[int(g.defers[i])]
		for j in 0 .. defer_body.children_count {
			g.gen_node(g.a.child(&defer_body, j))
		}
		i--
	}
}

fn (g &FlatGen) fn_params_list(node flat.Node) []flat.Node {
	mut params := []flat.Node{}
	for i in 0 .. node.children_count {
		child := g.a.child_node(&node, i)
		if child.kind == .param {
			params << *child
		}
	}
	return params
}

fn (g &FlatGen) fn_body_ids(node flat.Node) []flat.NodeId {
	mut ids := []flat.NodeId{}
	for i in 0 .. node.children_count {
		child := g.a.child_node(&node, i)
		if child.kind != .param {
			ids << g.a.child(&node, i)
		}
	}
	return ids
}

fn (mut g FlatGen) gen_call(node flat.Node) {
	fn_node := g.a.child_node(&node, 0)
	fn_name := fn_node.value
	match fn_name {
		'panic' {
			g.write('v_panic(')
			if node.children_count > 1 {
				arg_id := g.a.child(&node, 1)
				arg_type := g.tc.resolve_type(arg_id)
				if arg_type is types.Struct && arg_type.name == 'IError' {
					g.gen_expr(arg_id)
					g.write('.message')
				} else {
					g.gen_expr(arg_id)
				}
			}
			g.write(')')
			return
		}
		'error' {
			if g.cur_fn_ret_is_optional {
				ct := g.optional_type_name(g.cur_fn_ret)
				g.write('(${ct}){.ok = false}')
			} else {
				ct := g.tc.c_type(g.cur_fn_ret)
				g.write('(${ct}){0}')
			}
			return
		}
		'error_with_code' {
			if g.cur_fn_ret_is_optional {
				ct := g.optional_type_name(g.cur_fn_ret)
				g.write('(${ct}){.ok = false}')
			} else {
				ct := g.tc.c_type(g.cur_fn_ret)
				g.write('(${ct}){0}')
			}
			return
		}
		else {
			mut is_method := false
			mut is_c_call := false
			mut method_name := ''
			mut base_id := flat.NodeId(0)
			if fn_node.kind == .selector {
				base := g.a.child_node(fn_node, 0)
				if base.kind == .ident && base.value == 'C' {
					g.write(fn_node.value)
					is_c_call = true
				} else if g.is_flag_enum_method(fn_node) {
					g.gen_flag_enum_call(node)
					return
				} else if base.kind == .ident && base.value in g.modules {
					mod := g.modules[base.value]
					short_mod := if mod.contains('.') {
						mod.all_after_last('.')
					} else {
						mod
					}
					full_name := '${short_mod}.${fn_node.value}'
					if full_name in g.tc.type_aliases || full_name in g.tc.structs
						|| full_name in g.tc.enum_names || full_name in g.tc.sum_types {
						target_type := g.tc.parse_type(full_name)
						ct := g.tc.c_type(target_type)
						if target_type is types.SumType && node.children_count > 1 {
							inner_id := g.a.child(&node, 1)
							inner := g.a.nodes[int(inner_id)]
							variant_name0 := if inner.kind == .struct_init
								|| inner.kind == .cast_expr {
								inner.value
							} else {
								g.tc.resolve_type(inner_id).name()
							}
							variant_name := g.resolve_variant(target_type.name, variant_name0)
							idx := g.sum_type_index(target_type.name, variant_name)
							field := g.sum_field_name(variant_name)
							if g.variant_references_sum(variant_name, target_type.name) {
								inner_ct := g.tc.c_type(g.tc.parse_type(variant_name))
								g.write('(${ct}){.typ = ${idx}, .${field} = (${inner_ct}*)memdup(&(${inner_ct}){')
								if inner.kind == .struct_init {
									for si in 0 .. inner.children_count {
										sf := g.a.child_node(&inner, si)
										if si > 0 {
											g.write(', ')
										}
										g.write('.${c_name(sf.value)} = ')
										g.gen_expr(g.a.child(sf, 0))
									}
								} else {
									g.gen_expr(inner_id)
								}
								g.write('}, sizeof(${inner_ct}))}')
							} else {
								g.write('(${ct}){.typ = ${idx}, .${field} = ')
								g.gen_expr(inner_id)
								g.write('}')
							}
						} else {
							g.write('(${ct})(')
							for i in 1 .. node.children_count {
								if i > 1 {
									g.write(', ')
								}
								g.gen_expr(g.a.child(&node, i))
							}
							g.write(')')
						}
						return
					}
					g.write(c_name(full_name))
					g.write('(')
					g.gen_call_args(full_name, node, 1)
					g.write(')')
					return
				} else if base.kind == .selector {
					inner := g.a.child_node(base, 0)
					if inner.kind == .ident && inner.value in g.modules {
						mod := g.modules[inner.value]
						short_mod := if mod.contains('.') {
							mod.all_after_last('.')
						} else {
							mod
						}
						full_name := '${short_mod}.${base.value}.${fn_node.value}'
						g.write(c_name(full_name))
						g.write('(')
						g.gen_call_args(full_name, node, 1)
						g.write(')')
						return
					} else {
						base_type := g.tc.resolve_type(g.a.child(fn_node, 0))
						clean_type := types.unwrap_pointer(base_type)
						if clean_type is types.Array {
							g.gen_array_method_call(node, fn_node, clean_type as types.Array)
							return
						}
						if clean_type is types.ArrayFixed && fn_node.value == 'bytestr' {
							af := clean_type as types.ArrayFixed
							g.write('u8__vstring_with_len((u8*)')
							g.gen_expr(g.a.child(fn_node, 0))
							g.write(', ${af.len})')
							return
						}
						if clean_type is types.Map {
							if fn_node.value == 'delete' {
								g.gen_map_delete(node, fn_node, clean_type as types.Map)
								return
							} else if fn_node.value == 'clone' {
								g.write('map__clone(&')
								g.gen_expr(g.a.child(fn_node, 0))
								g.write(')')
								return
							} else if fn_node.value == 'clear' {
								g.write('map__clear(&')
								g.gen_expr(g.a.child(fn_node, 0))
								g.write(')')
								return
							}
						}
						if clean_type is types.String {
							method_name = 'string.${fn_node.value}'
							if method_name in g.tc.fn_param_types {
								is_method = true
								base_id = g.a.child(fn_node, 0)
								g.write(c_name(method_name))
							} else {
								g.write('string__${fn_node.value}(')
								g.gen_expr(g.a.child(fn_node, 0))
								for i in 1 .. node.children_count {
									g.write(', ')
									g.gen_expr(g.a.child(&node, i))
								}
								g.write(')')
								return
							}
						}
						if !is_method && (clean_type is types.Primitive
							|| clean_type is types.ISize || clean_type is types.USize
							|| clean_type is types.Rune) {
							tname := clean_type.name()
							prim_method := '${tname}.${fn_node.value}'
							if prim_method in g.tc.fn_param_types {
								is_method = true
								base_id = g.a.child(fn_node, 0)
								g.write(c_name(prim_method))
							} else {
								mut prim_found := false
								if alias_method := g.find_alias_method(tname, fn_node.value) {
									is_method = true
									prim_found = true
									base_id = g.a.child(fn_node, 0)
									g.write(c_name(alias_method))
								}
								if !prim_found {
									alt_name := g.find_prim_method(fn_node.value)
									if alt_name.len > 0 {
										is_method = true
										base_id = g.a.child(fn_node, 0)
										g.write(alt_name)
									}
								}
							}
						}
						if !is_method {
							struct_name := if clean_type is types.Struct {
								clean_type.name
							} else {
								clean_type.name()
							}
							method_name = '${struct_name}.${fn_node.value}'
							if method_name !in g.tc.fn_param_types {
								for alias, target in g.tc.type_aliases {
									if target == struct_name {
										alias_method := '${alias}.${fn_node.value}'
										if alias_method in g.tc.fn_param_types {
											method_name = alias_method
											break
										}
									}
								}
							}
							if method_name in g.tc.fn_param_types {
								is_method = true
								base_id = g.a.child(fn_node, 0)
								g.write(c_name(method_name))
							} else {
								str_method := 'string.${fn_node.value}'
								if str_method in g.tc.fn_param_types {
									is_method = true
									method_name = str_method
									base_id = g.a.child(fn_node, 0)
									g.write(c_name(str_method))
								} else if struct_name.len > 0 {
									is_method = true
									base_id = g.a.child(fn_node, 0)
									g.write(c_name(method_name))
								} else {
									g.gen_expr(g.a.child(&node, 0))
								}
							}
						}
					}
				} else if base.kind == .ident
					&& (base.value in g.tc.structs || base.value in g.tc.enum_names || g.tc.qualify_name(base.value) in g.tc.structs
					|| g.tc.qualify_name(base.value) in g.tc.enum_names) {
					qname := if base.value in g.tc.structs || base.value in g.tc.enum_names {
						base.value
					} else {
						g.tc.qualify_name(base.value)
					}
					static_name := '${qname}.${fn_node.value}'
					g.write(c_name(static_name))
					g.write('(')
					for i in 1 .. node.children_count {
						if i > 1 {
							g.write(', ')
						}
						g.gen_expr(g.a.child(&node, i))
					}
					g.write(')')
					return
				} else {
					base_type := g.tc.resolve_type(g.a.child(fn_node, 0))
					clean_type := types.unwrap_pointer(base_type)
					if clean_type is types.Array {
						g.gen_array_method_call(node, fn_node, clean_type as types.Array)
						return
					}
					if clean_type is types.ArrayFixed && fn_node.value == 'bytestr' {
						af := clean_type as types.ArrayFixed
						g.write('u8__vstring_with_len((u8*)')
						g.gen_expr(g.a.child(fn_node, 0))
						g.write(', ${af.len})')
						return
					}
					if clean_type is types.Map {
						if fn_node.value == 'delete' {
							g.gen_map_delete(node, fn_node, clean_type as types.Map)
							return
						} else if fn_node.value == 'clone' {
							g.write('map__clone(&')
							g.gen_expr(g.a.child(fn_node, 0))
							g.write(')')
							return
						} else if fn_node.value == 'clear' {
							g.write('map__clear(&')
							g.gen_expr(g.a.child(fn_node, 0))
							g.write(')')
							return
						}
					}
					if clean_type is types.String {
						method_name = 'string.${fn_node.value}'
						if method_name in g.tc.fn_param_types {
							is_method = true
							base_id = g.a.child(fn_node, 0)
							g.write(c_name(method_name))
						} else {
							g.write('string__${fn_node.value}(')
							g.gen_expr(g.a.child(fn_node, 0))
							for i in 1 .. node.children_count {
								g.write(', ')
								g.gen_expr(g.a.child(&node, i))
							}
							g.write(')')
							return
						}
					}
					if !is_method && (clean_type is types.Void || clean_type is types.Primitive)
						&& fn_node.value in ['vstring', 'vstring_with_len'] {
						g.write('u8__${fn_node.value}((u8*)')
						g.gen_expr(g.a.child(fn_node, 0))
						for i in 1 .. node.children_count {
							g.write(', ')
							g.gen_expr(g.a.child(&node, i))
						}
						g.write(')')
						return
					}
					if !is_method && clean_type is types.Struct && clean_type.name == 'IError' {
						if fn_node.value == 'msg' {
							g.gen_expr(g.a.child(fn_node, 0))
							g.write('.message')
							return
						} else if fn_node.value == 'code' {
							g.gen_expr(g.a.child(fn_node, 0))
							g.write('.code')
							return
						}
					}
					if !is_method && (clean_type is types.Primitive
						|| clean_type is types.ISize || clean_type is types.USize
						|| clean_type is types.Rune) {
						tname := clean_type.name()
						prim_method := '${tname}.${fn_node.value}'
						if prim_method in g.tc.fn_param_types {
							is_method = true
							base_id = g.a.child(fn_node, 0)
							g.write(c_name(prim_method))
						} else {
							mut prim_found := false
							if alias_method := g.find_alias_method(tname, fn_node.value) {
								is_method = true
								prim_found = true
								base_id = g.a.child(fn_node, 0)
								g.write(c_name(alias_method))
							}
							if !prim_found {
								alt_name := g.find_prim_method(fn_node.value)
								if alt_name.len > 0 {
									is_method = true
									base_id = g.a.child(fn_node, 0)
									g.write(alt_name)
								}
							}
						}
					}
					if !is_method {
						struct_name := if clean_type is types.Struct {
							clean_type.name
						} else {
							clean_type.name()
						}
						method_name = '${struct_name}.${fn_node.value}'
						if method_name !in g.tc.fn_param_types {
							for alias, target in g.tc.type_aliases {
								if target == struct_name {
									alias_method := '${alias}.${fn_node.value}'
									if alias_method in g.tc.fn_param_types {
										method_name = alias_method
										break
									}
								}
							}
						}
						if method_name in g.tc.fn_param_types {
							is_method = true
							base_id = g.a.child(fn_node, 0)
							g.write(c_name(method_name))
						} else {
							str_method := 'string.${fn_node.value}'
							if str_method in g.tc.fn_param_types {
								is_method = true
								method_name = str_method
								base_id = g.a.child(fn_node, 0)
								g.write(c_name(str_method))
							} else if struct_name.len > 0 {
								is_method = true
								base_id = g.a.child(fn_node, 0)
								g.write(c_name(method_name))
							} else {
								g.gen_expr(g.a.child(&node, 0))
							}
						}
					}
					// !is_method
				}
			} else {
				fn_id := g.a.child(&node, 0)
				fn_ident := g.a.nodes[int(fn_id)]
				if fn_ident.kind == .ident {
					qname := g.tc.qualify_name(fn_ident.value)
					if fn_ident.value in g.tc.type_aliases || qname in g.tc.type_aliases
						|| fn_ident.value in g.tc.structs || qname in g.tc.structs
						|| fn_ident.value in g.tc.enum_names || qname in g.tc.enum_names
						|| fn_ident.value in g.tc.sum_types || qname in g.tc.sum_types {
						target_type := g.tc.parse_type(fn_ident.value)
						ct := g.tc.c_type(target_type)
						if target_type is types.SumType && node.children_count > 1 {
							inner_id := g.a.child(&node, 1)
							inner := g.a.nodes[int(inner_id)]
							variant_name0 := if inner.kind == .struct_init
								|| inner.kind == .cast_expr {
								inner.value
							} else {
								g.tc.resolve_type(inner_id).name()
							}
							variant_name := g.resolve_variant(target_type.name, variant_name0)
							idx := g.sum_type_index(target_type.name, variant_name)
							field := g.sum_field_name(variant_name)
							if g.variant_references_sum(variant_name, target_type.name) {
								inner_ct := g.tc.c_type(g.tc.parse_type(variant_name))
								g.write('(${ct}){.typ = ${idx}, .${field} = (${inner_ct}*)memdup(&(${inner_ct}){')
								if inner.kind == .struct_init {
									for si in 0 .. inner.children_count {
										sf := g.a.child_node(&inner, si)
										if si > 0 {
											g.write(', ')
										}
										g.write('.${c_name(sf.value)} = ')
										g.gen_expr(g.a.child(sf, 0))
									}
								} else {
									g.gen_expr(inner_id)
								}
								g.write('}, sizeof(${inner_ct}))}')
							} else {
								g.write('(${ct}){.typ = ${idx}, .${field} = ')
								g.gen_expr(inner_id)
								g.write('}')
							}
						} else {
							g.write('(${ct})(')
							for i in 1 .. node.children_count {
								if i > 1 {
									g.write(', ')
								}
								g.gen_expr(g.a.child(&node, i))
							}
							g.write(')')
						}
						return
					}
					qfn := g.tc.qualify_fn_name(fn_ident.value)
					if qfn in g.tc.fn_ret_types || qfn in g.tc.fn_param_types {
						g.write(c_name(qfn))
					} else {
						g.write(c_name(fn_ident.value))
					}
				} else {
					g.gen_expr(fn_id)
				}
			}
			g.write('(')
			actual_fn := if is_method {
				method_name
			} else {
				g.tc.qualify_fn_name(fn_name)
			}
			param_types := if actual_fn in g.tc.fn_param_types {
				g.tc.fn_param_types[actual_fn]
			} else if fn_name in g.tc.fn_param_types {
				g.tc.fn_param_types[fn_name]
			} else {
				[]types.Type{}
			}
			mut arg_start := 1
			if is_method {
				base_type := g.tc.resolve_type(base_id)
				is_ptr_base := base_type is types.Pointer
				wants_ptr := param_types.len > 0 && param_types[0] is types.Pointer
				if wants_ptr && !is_ptr_base {
					g.write('&')
				} else if !wants_ptr && is_ptr_base {
					g.write('*')
				}
				g.gen_expr(base_id)
				arg_start = 1
			}
			for i in arg_start .. node.children_count {
				if is_method || i > 1 {
					g.write(', ')
				}
				arg_idx := if is_method { i } else { i - 1 }
				arg_id := g.a.child(&node, i)
				arg_node := g.a.nodes[int(arg_id)]
				mut needs_addr := false
				if !is_c_call && arg_idx < param_types.len && param_types[arg_idx] is types.Pointer
					&& !(arg_node.kind == .prefix && arg_node.op == .amp) {
					arg_type := g.tc.resolve_type(arg_id)
					if arg_type !is types.Pointer {
						needs_addr = true
					}
				}
				if !is_c_call && arg_idx < param_types.len && param_types[arg_idx] is types.Enum {
					g.expected_enum = (param_types[arg_idx] as types.Enum).name
				}
				is_rvalue := arg_node.kind == .call
					|| (arg_node.kind == .index && arg_node.value == 'range')
				if needs_addr && is_rvalue {
					pt := param_types[arg_idx]
					ct := g.tc.c_type(types.unwrap_pointer(pt))
					g.write('({${ct} _t${g.tmp_count} = ')
					g.gen_expr(arg_id)
					g.write('; &_t${g.tmp_count};})')
					g.tmp_count++
				} else {
					if needs_addr {
						g.write('&')
					}
					emitted_variant := !needs_addr && !is_c_call && arg_idx < param_types.len
						&& g.gen_sum_variant_arg(arg_id, param_types[arg_idx])
					if !emitted_variant {
						g.gen_expr(arg_id)
					}
				}
				g.expected_enum = ''
			}
			actual_args := node.children_count - arg_start
			expected_args := if is_method {
				param_types.len - 1
			} else {
				param_types.len
			}
			if !is_c_call && expected_args > 0 && actual_args < expected_args {
				for pi in actual_args .. expected_args {
					if is_method || pi > 0 {
						g.write(', ')
					}
					pidx := if is_method { pi + 1 } else { pi }
					pt := param_types[pidx]
					g.gen_default_value_for_type(pt)
				}
			}
			g.write(')')
		}
	}
}

fn (mut g FlatGen) gen_call_args(fn_name string, node flat.Node, start int) {
	param_types := if fn_name in g.tc.fn_param_types {
		g.tc.fn_param_types[fn_name]
	} else {
		[]types.Type{}
	}
	is_variadic_fn := g.tc.fn_variadic[fn_name] or { false }
	variadic_idx := if is_variadic_fn && param_types.len > 0
		&& param_types[param_types.len - 1] is types.Array {
		param_types.len - 1
	} else {
		-1
	}
	num_args := node.children_count - start
	is_variadic := variadic_idx >= 0 && num_args > param_types.len
	for i in start .. node.children_count {
		if i > start {
			g.write(', ')
		}
		arg_idx := i - start
		arg_id := g.a.child(&node, i)
		arg_node := g.a.nodes[int(arg_id)]
		if is_variadic && arg_idx == variadic_idx {
			variadic_type := param_types[variadic_idx]
			if variadic_type is types.Array {
				c_elem := g.tc.c_type(variadic_type.elem_type)
				count := num_args - variadic_idx
				g.write('new_array_from_c_array(${count}, ${count}, sizeof(${c_elem}), (${c_elem}[]){')
				for j in i .. node.children_count {
					if j > i {
						g.write(', ')
					}
					g.gen_expr(g.a.child(&node, j))
				}
				g.write('})')
			}
			break
		}
		if variadic_idx >= 0 && arg_idx == variadic_idx && num_args == param_types.len {
			arg_type := g.tc.resolve_type(arg_id)
			if arg_type !is types.Array {
				variadic_type := param_types[variadic_idx]
				if variadic_type is types.Array {
					c_elem := g.tc.c_type(variadic_type.elem_type)
					g.write('new_array_from_c_array(1, 1, sizeof(${c_elem}), (${c_elem}[]){')
					g.gen_expr(arg_id)
					g.write('})')
					continue
				}
			}
		}
		mut needs_addr := false
		if arg_idx < param_types.len && param_types[arg_idx] is types.Pointer
			&& !(arg_node.kind == .prefix && arg_node.op == .amp) {
			arg_type := g.tc.resolve_type(arg_id)
			if arg_type !is types.Pointer {
				needs_addr = true
			}
		}
		is_rvalue := arg_node.kind == .call
			|| (arg_node.kind == .index && arg_node.value == 'range')
		if needs_addr && is_rvalue {
			pt := param_types[arg_idx]
			ct := g.tc.c_type(types.unwrap_pointer(pt))
			g.write('({${ct} _t${g.tmp_count} = ')
			g.gen_expr(arg_id)
			g.write('; &_t${g.tmp_count};})')
			g.tmp_count++
		} else {
			if needs_addr {
				g.write('&')
			}
			emitted_variant := !needs_addr && arg_idx < param_types.len
				&& g.gen_sum_variant_arg(arg_id, param_types[arg_idx])
			if !emitted_variant {
				g.gen_expr(arg_id)
			}
		}
		if variadic_idx >= 0 && num_args == variadic_idx {
			if node.children_count > start {
				g.write(', ')
			}
			variadic_type := param_types[variadic_idx]
			if variadic_type is types.Array {
				c_elem := g.tc.c_type(variadic_type.elem_type)
				g.write('new_array_from_c_array(0, 0, sizeof(${c_elem}), (${c_elem}[]){0})')
			}
		}
	}
	num_provided := node.children_count - start
	if num_provided < param_types.len {
		for i in num_provided .. param_types.len {
			if num_provided > 0 || i > num_provided {
				g.write(', ')
			}
			g.gen_default_value_for_type(param_types[i])
		}
	}
}

fn (g &FlatGen) is_flag_enum_method(fn_node &flat.Node) bool {
	if fn_node.kind != .selector {
		return false
	}
	method := fn_node.value
	if method !in ['has', 'all', 'set', 'clear'] {
		return false
	}
	base_type := g.tc.resolve_type(g.a.child(fn_node, 0))
	clean := types.unwrap_pointer(base_type)
	if clean is types.Enum {
		return true
	} else if clean is types.Primitive {
		return clean.props.has(.integer)
	} else if clean is types.Unknown {
		return true
	}
	return false
}

fn (mut g FlatGen) gen_flag_enum_call(node flat.Node) {
	fn_node := g.a.child_node(&node, 0)
	method := fn_node.value
	base_id := g.a.child(fn_node, 0)
	match method {
		'has' {
			g.write('((')
			g.gen_expr(base_id)
			g.write(' & ')
			if node.children_count > 1 {
				g.gen_expr(g.a.child(&node, 1))
			}
			g.write(') != 0)')
		}
		'all' {
			g.write('((')
			g.gen_expr(base_id)
			g.write(' & (')
			if node.children_count > 1 {
				g.gen_expr(g.a.child(&node, 1))
			}
			g.write(')) == (')
			if node.children_count > 1 {
				g.gen_expr(g.a.child(&node, 1))
			}
			g.write('))')
		}
		'set' {
			g.gen_expr(base_id)
			g.write(' |= ')
			if node.children_count > 1 {
				g.gen_expr(g.a.child(&node, 1))
			}
		}
		'clear' {
			g.gen_expr(base_id)
			g.write(' &= ~(')
			if node.children_count > 1 {
				g.gen_expr(g.a.child(&node, 1))
			}
			g.write(')')
		}
		else {}
	}
}

fn is_generic_type(typ string) bool {
	t := typ.trim_left('&?!')
	return t.len == 1 && t[0] >= `A` && t[0] <= `Z`
}

fn (g &FlatGen) has_generic_params(node flat.Node) bool {
	for i in 0 .. node.children_count {
		child := g.a.child_node(&node, i)
		if child.kind == .param && is_generic_type(child.typ) {
			return true
		}
	}
	return is_generic_type(node.typ)
}

fn (g &FlatGen) find_prim_method(method string) string {
	if 'u8.${method}' in g.tc.fn_param_types {
		return c_name('u8.${method}')
	}
	if 'int.${method}' in g.tc.fn_param_types {
		return c_name('int.${method}')
	}
	if 'i64.${method}' in g.tc.fn_param_types {
		return c_name('i64.${method}')
	}
	if 'u32.${method}' in g.tc.fn_param_types {
		return c_name('u32.${method}')
	}
	if 'u64.${method}' in g.tc.fn_param_types {
		return c_name('u64.${method}')
	}
	return ''
}

fn (g &FlatGen) find_alias_method(target string, method string) ?string {
	mut fallback := ''
	for alias, alias_target in g.tc.type_aliases {
		if alias_target != target {
			continue
		}
		alias_method := '${alias}.${method}'
		if alias_method !in g.tc.fn_param_types {
			if alias.contains('.') {
				short_method := '${alias.all_after_last('.')}.${method}'
				if short_method in g.tc.fn_param_types {
					return alias_method
				}
			}
			continue
		}
		if alias.contains('.') {
			return alias_method
		}
		if fallback.len == 0 {
			fallback = alias_method
		}
	}
	if fallback.len > 0 {
		return fallback
	}
	return none
}

fn (mut g FlatGen) gen_sum_variant_arg(arg_id flat.NodeId, expected types.Type) bool {
	mut actual := types.unwrap_pointer(g.tc.resolve_type(arg_id))
	if actual is types.Alias {
		actual = actual.base_type
	}
	mut expected_type := expected
	if expected_type is types.Alias {
		expected_type = expected_type.base_type
	}
	if actual !is types.SumType || expected_type is types.SumType {
		return false
	}
	sum_type := actual as types.SumType
	sum_name := sum_type.name
	variant := g.resolve_variant(sum_name, expected_type.name())
	variants := g.tc.sum_types[sum_name] or { return false }
	if variant !in variants {
		return false
	}
	is_ptr_arg := g.tc.resolve_type(arg_id) is types.Pointer
	is_ref_variant := g.variant_references_sum(variant, sum_name)
	if is_ref_variant {
		g.write('(*')
	}
	g.gen_expr(arg_id)
	if is_ptr_arg {
		g.write('->')
	} else {
		g.write('.')
	}
	g.write(g.sum_field_name(variant))
	if is_ref_variant {
		g.write(')')
	}
	return true
}

fn (mut g FlatGen) forward_decls() {
	for i, node in g.a.nodes {
		if node.kind == .module_decl {
			g.tc.cur_module = node.value
			continue
		}
		if node.kind == .fn_decl && node.value != 'main' {
			_ = i
			dfn := g.dotted_fn_name(node.value)
			if g.used_fns.len > 0 && node.value !in g.used_fns && dfn !in g.used_fns {
				continue
			}
			if g.has_generic_params(node) {
				continue
			}
			params := g.fn_params_list(node)
			ret_type := g.tc.parse_type(node.typ)
			g.write(g.optional_type_name(ret_type))
			g.write(' ')
			g.write(g.qualified_fn_name(node.value))
			g.write('(')
			g.write_fn_params(params)
			g.writeln(');')
		}
	}
	g.writeln('')
}

fn (g &FlatGen) has_c_struct_type(node flat.Node, params []flat.Node) bool {
	ret := g.tc.parse_type(node.typ)
	if ret is types.Struct && ret.name.starts_with('C.') {
		return true
	}
	for p in params {
		pt := g.tc.parse_type(p.typ)
		if pt is types.Struct && pt.name.starts_with('C.') {
			return true
		}
	}
	return false
}

fn (mut g FlatGen) write_fn_params(params []flat.Node) {
	if params.len == 0 {
		g.write('void')
		return
	}
	for i, p in params {
		pt := g.tc.parse_type(p.typ)
		ct := g.tc.c_type(pt)
		if ct.starts_with('fn_ptr:') {
			g.write(g.resolve_fn_ptr_type(ct))
		} else {
			g.write(ct)
		}
		if p.value.len > 0 {
			g.write(' ')
			g.write(c_name(p.value))
		}
		if i < params.len - 1 {
			g.write(', ')
		}
	}
}

fn (mut g FlatGen) fn_ptr_typedefs() {
	for encoded, name in g.fn_ptr_types {
		parts := encoded['fn_ptr:'.len..].split('|')
		ret := parts[0]
		params := if parts.len > 1 { parts[1] } else { 'void' }
		g.writeln('typedef ${ret} (*${name})(${params});')
	}
	if g.fn_ptr_types.len > 0 {
		g.writeln('')
	}
}

fn (mut g FlatGen) multi_return_typedefs() {
	mut emitted := map[string]bool{}
	for _, ret in g.tc.fn_ret_types {
		if ret is types.MultiReturn {
			name := g.tc.c_type(ret)
			if name in emitted {
				continue
			}
			emitted[name] = true
			g.writeln('typedef struct {')
			for i, t in ret.types {
				g.writeln('\t${g.tc.c_type(t)} arg${i};')
			}
			g.writeln('} ${name};')
		}
	}
	if emitted.len > 0 {
		g.writeln('')
	}
}

fn (mut g FlatGen) resolve_fn_ptr_type(typ string) string {
	if typ in g.fn_ptr_types {
		return g.fn_ptr_types[typ]
	}
	name := '_fn_ptr_${g.fn_ptr_types.len}'
	g.fn_ptr_types[typ] = name
	return name
}
