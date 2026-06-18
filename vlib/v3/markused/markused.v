module markused

import v3.flat
import v3.types

const trace_markused = false

pub fn mark_used(a &flat.FlatAst, tc &types.TypeChecker) map[string]bool {
	mut call_graph := map[string][]string{}
	mut all_fns := map[string]bool{}
	mut cur_module := ''
	mut imports := map[string]string{}

	// Build a resolved function name set from the type checker
	mut resolved_fns := map[string]bool{}
	for name, _ in tc.fn_ret_types {
		resolved_fns[name] = true
	}

	// Reverse index: short name (after last '.') -> list of full qualified names
	mut suffix_map := map[string][]string{}

	mut fn_count := 0
	mut fn_with_dot := 0
	mut contains2_total := 0
	mut empty_fns := 0
	mut total_callees := 0
	for node in a.nodes {
		if node.kind == .module_decl {
			cur_module = node.value
			continue
		}
		if node.kind == .import_decl {
			mod := if node.value.contains('.') { node.value.all_after_last('.') } else { node.value }
			imports[node.typ] = mod
			continue
		}
		if node.kind == .fn_decl {
			fn_count++
			if node.value.contains('.') {
				fn_with_dot++
				if trace_markused && fn_with_dot <= 5 {
					eprintln('  fn with dot: "${node.value}"')
				}
			}
			all_fns[node.value] = true
			qname := qualify_fn(cur_module, node.value)
			if qname != node.value {
				all_fns[qname] = true
			}
			// Build suffix_map entries
			if node.value.contains('.') {
				contains2_total++
				short := node.value.all_after_last('.')
				suffix_map[short] << node.value
				if qname != node.value {
					suffix_map[short] << qname
				}
			}
			if qname != node.value && qname.contains('.') {
				short := qname.all_after_last('.')
				if short != node.value.all_after_last('.') {
					suffix_map[short] << qname
				}
			}
			mut receiver_name := ''
			mut receiver_struct := ''
			if node.value.contains('.') {
				receiver_struct = node.value.all_before_last('.')
				for pi in 0 .. node.children_count {
					pc := a.child_node(&node, pi)
					if pc.kind == .param {
						receiver_name = pc.value
						break
					}
				}
			}
			mut callees := []string{}
			collect_calls(a, tc, &node, cur_module, imports, receiver_name, receiver_struct, mut
				callees)
			total_callees += callees.len
			call_graph[node.value] = callees
			if callees.len == 0 && node.children_count > 0 && fn_count <= 2200 {
				empty_fns++
			}
			if qname != node.value {
				call_graph[qname] = callees
			}
		}
	}

	// BFS from main
	mut used := map[string]bool{}
	mut queue := []string{}
	queue << 'main'
	used['main'] = true

	if trace_markused {
		eprintln('markused: fn_count:')
		eprintln(fn_count.str())
		eprintln('fn_with_dot:')
		eprintln(fn_with_dot.str())
		eprintln('contains2_total:')
		eprintln(contains2_total.str())
		eprintln('markused: main in call_graph: ${'main' in call_graph}')
		if 'main' in call_graph {
			main_calls := call_graph['main']
			eprintln('markused: main has ${main_calls.len} callees')
			for mc in main_calls {
				eprintln('  callee: ${mc}')
			}
		}
		eprintln('markused: all_fns count: ${all_fns.len}')
		eprintln('markused: suffix_map count: ${suffix_map.len}')
		mut total_suffix_entries := 0
		for _, vals in suffix_map {
			total_suffix_entries += vals.len
		}
		eprintln('total suffix_map entries (sum of array lens):')
		eprintln(total_suffix_entries.str())
	}

	mut suffix_hits := 0
	// mut suffix_misses := 0
	mut in_cg := 0
	mut not_in_cg := 0
	mut qi := 0
	for qi < queue.len {
		name := queue[qi]
		qi++
		prev_len := queue.len
		if trace_markused && qi <= 10 {
			eprintln('BFS qi=${qi.str()} name="${name}" in_cg=${name in call_graph}')
		}
		if name in call_graph {
			in_cg++
			calls := call_graph[name]
			for callee in calls {
				if callee in all_fns {
					if callee !in used {
						used[callee] = true
						queue << callee
						if trace_markused && qi == 1 {
							eprintln('main: all_fns hit: "${callee}"')
						}
					}
				} else if callee in resolved_fns {
					if callee !in used {
						used[callee] = true
						queue << callee
						if trace_markused && qi == 1 {
							eprintln('main: resolved hit: "${callee}"')
						}
					}
				}
				if callee.len > 0 {
					if callee in suffix_map {
						suffix_hits++
						entries := suffix_map[callee]
						for fn_name in entries {
							if fn_name !in used {
								used[fn_name] = true
								queue << fn_name
								if trace_markused && qi == 1 {
									eprintln('main: suffix hit: "${callee}" -> "${fn_name}"')
								}
							}
						}
					}
				}
			}
		} else {
			not_in_cg++
		}
		new_added := queue.len - prev_len
		if trace_markused && qi <= 10 {
			eprintln('  -> added ${new_added.str()} new entries, queue now ${queue.len.str()}')
		}
	}
	if trace_markused {
		eprintln('empty_fns:')
		eprintln(empty_fns.str())
		eprintln('total_callees:')
		eprintln(total_callees.str())
		eprintln('markused: in_cg:')
		eprintln(in_cg.str())
		eprintln('not_in_cg:')
		eprintln(not_in_cg.str())
		eprintln('queue.len:')
		eprintln(queue.len.str())
		eprintln('markused: suffix_hits:')
		eprintln(suffix_hits.str())
		eprintln('markused: total used: ${used.len}')
	}
	return used
}

fn qualify_fn(mod string, name string) string {
	if mod.len == 0 || mod == 'main' || mod == 'builtin' {
		return name
	}
	return '${mod}.${name}'
}

fn collect_calls(a &flat.FlatAst, tc &types.TypeChecker, node &flat.Node, cur_module string, imports map[string]string, receiver_name string, receiver_struct string, mut calls []string) {
	for i in 0 .. node.children_count {
		child_id := a.child(node, i)
		if int(child_id) < 0 {
			continue
		}
		child := &a.nodes[int(child_id)]
		match child.kind {
			.call {
				if child.children_count > 0 {
					callee_id := a.child(child, 0)
					if int(callee_id) >= 0 {
						callee := a.nodes[int(callee_id)]
						if callee.kind == .ident && callee.value.len > 0 {
							calls << callee.value
							qcallee := qualify_fn(cur_module, callee.value)
							if qcallee != callee.value {
								calls << qcallee
							}
						} else if callee.kind == .selector && callee.value.len > 0 {
							if callee.children_count > 0 {
								base_id := a.child(&callee, 0)
								if int(base_id) >= 0 {
									base := a.nodes[int(base_id)]
									if base.kind == .ident && base.value.len > 0 {
										if receiver_name.len > 0 && base.value == receiver_name {
											calls << receiver_struct + '.' + callee.value
											qrecv := qualify_fn(cur_module, receiver_struct + '.' +
												callee.value)
											if qrecv != receiver_struct + '.' + callee.value {
												calls << qrecv
											}
										}
										mod_name := if base.value in imports {
											imports[base.value]
										} else {
											base.value
										}
										calls << mod_name + '.' + callee.value
									} else if base.kind == .selector && base.children_count > 0 {
										inner_id := a.child(&base, 0)
										if int(inner_id) >= 0 {
											inner := a.nodes[int(inner_id)]
											if inner.kind == .ident && inner.value.len > 0 {
												mod_name := if inner.value in imports {
													imports[inner.value]
												} else {
													inner.value
												}
												calls << mod_name + '.' + base.value + '.' +
													callee.value
											}
										}
									}
									base_type := tc.resolve_type(base_id)
									type_name := resolve_type_name(base_type)
									if type_name.len > 0 {
										calls << type_name + '.' + callee.value
									}
								}
							}
							calls << callee.value
						}
					}
				}
				for ci in 1 .. child.children_count {
					arg_id := a.child(child, ci)
					if int(arg_id) >= 0 {
						arg := a.nodes[int(arg_id)]
						if arg.kind == .ident && arg.value.len > 0 {
							calls << arg.value
						}
					}
				}
			}
			.prefix {
				if child.op == .amp && child.children_count > 0 {
					inner_id := a.child(child, 0)
					if int(inner_id) >= 0 {
						inner := a.nodes[int(inner_id)]
						if inner.kind == .struct_init {
							calls << 'memdup'
						}
					}
				}
			}
			.string_interp {
				calls << 'string_plus_many'
			}
			.infix {
				if child.op == .plus {
					calls << 'string__plus'
				}
				if child.children_count >= 2 {
					lhs_id := a.child(child, 0)
					if int(lhs_id) >= 0 {
						lhs_type := tc.resolve_type(lhs_id)
						lhs_name := resolve_type_name(lhs_type)
						if lhs_name.len > 0 {
							op_name := match child.op {
								.minus { '-' }
								.plus { '+' }
								.eq { '==' }
								.ne { '!=' }
								.lt { '<' }
								.gt { '>' }
								.le { '<=' }
								.ge { '>=' }
								else { '' }
							}

							if op_name.len > 0 {
								calls << lhs_name + '.' + op_name
							}
						}
					}
				}
			}
			.struct_init {
				collect_struct_default_calls(a, tc, child, imports, mut calls)
			}
			else {}
		}

		collect_calls(a, tc, child, cur_module, imports, receiver_name, receiver_struct, mut calls)
	}
}

struct StructDeclInfo {
	node   flat.Node
	module string
}

fn collect_struct_default_calls(a &flat.FlatAst, tc &types.TypeChecker, init &flat.Node, imports map[string]string, mut calls []string) {
	info := find_struct_decl(a, init.value) or { return }
	mut set_fields := map[string]bool{}
	for i in 0 .. init.children_count {
		field := a.child_node(init, i)
		if field.kind == .field_init {
			set_fields[field.value] = true
		}
	}
	for i in 0 .. info.node.children_count {
		field := a.child_node(&info.node, i)
		if field.kind != .field_decl || field.children_count == 0 || field.value in set_fields {
			continue
		}
		collect_calls(a, tc, field, info.module, imports, '', '', mut calls)
	}
}

fn find_struct_decl(a &flat.FlatAst, type_name string) ?StructDeclInfo {
	short_name := if type_name.contains('.') { type_name.all_after_last('.') } else { type_name }
	mut cur_module := ''
	for node in a.nodes {
		if node.kind == .module_decl {
			cur_module = node.value
			continue
		}
		if node.kind != .struct_decl || node.value != short_name {
			continue
		}
		full_name := if cur_module.len > 0 && cur_module != 'main' && cur_module != 'builtin' {
			'${cur_module}.${node.value}'
		} else {
			node.value
		}
		if type_name == node.value || type_name == full_name {
			return StructDeclInfo{
				node:   node
				module: cur_module
			}
		}
	}
	return none
}

fn resolve_type_name(t types.Type) string {
	if t is types.Struct {
		return t.name
	} else if t is types.String {
		return 'string'
	} else if t is types.Array {
		return 'Array'
	} else if t is types.Map {
		return 'map'
	} else if t is types.Pointer {
		return resolve_type_name(t.base_type)
	} else if t is types.Primitive {
		props := int(t.props)
		sz := int(t.size)
		if props & 1 > 0 {
			return 'bool'
		}
		if props & 4 > 0 {
			if props & 8 > 0 {
				return match sz {
					8 { 'u8' }
					16 { 'u16' }
					32 { 'u32' }
					64 { 'u64' }
					else { 'int' }
				}
			}
			return match sz {
				0 { 'int' }
				8 { 'i8' }
				16 { 'i16' }
				32 { 'i32' }
				64 { 'i64' }
				else { 'int' }
			}
		}
		if props & 2 > 0 {
			return match sz {
				32 { 'f32' }
				64 { 'f64' }
				else { 'f64' }
			}
		}
		return 'int'
	} else if t is types.ISize {
		return 'isize'
	} else if t is types.USize {
		return 'usize'
	} else if t is types.Rune {
		return 'rune'
	}
	return ''
}
