module markused

import v3.flat
import v3.types

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
			all_fns[node.value] = true
			qname := qualify_fn(cur_module, node.value)
			if qname != node.value {
				all_fns[qname] = true
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
			collect_calls(a, tc, &node, cur_module, imports, receiver_name, receiver_struct, mut callees)
			call_graph[node.value] = callees
			if qname != node.value {
				call_graph[qname] = callees
			}
		}
	}

	// BFS from main
	mut used := map[string]bool{}
	mut queue := ['main']
	used['main'] = true

	for queue.len > 0 {
		name := queue[0]
		queue.delete(0)
		if calls := call_graph[name] {
			for callee in calls {
				if callee in all_fns {
					if callee !in used {
						used[callee] = true
						queue << callee
					}
				} else if callee in resolved_fns {
					if callee !in used {
						used[callee] = true
						queue << callee
					}
				}
				if callee.len > 0 {
					for fn_name, _ in all_fns {
						if fn_name.ends_with('.${callee}') && fn_name !in used {
							used[fn_name] = true
							queue << fn_name
						}
					}
				}
			}
		}
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
							if callee.value in ['println', 'print'] {
								calls << 'int_str'
							}
						} else if callee.kind == .selector && callee.value.len > 0 {
							if callee.children_count > 0 {
								base_id := a.child(&callee, 0)
								if int(base_id) >= 0 {
									base := a.nodes[int(base_id)]
									if base.kind == .ident && base.value.len > 0 {
										if receiver_name.len > 0 && base.value == receiver_name {
											calls << receiver_struct + '.' + callee.value
											qrecv := qualify_fn(cur_module, receiver_struct + '.' + callee.value)
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
				calls << 'int_str'
				calls << 'string_plus_many'
			}
			.infix {
				if child.op == .plus {
					calls << 'string__plus'
				}
			}
			else {}
		}

		collect_calls(a, tc, child, cur_module, imports, receiver_name, receiver_struct, mut calls)
	}
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
	}
	return ''
}
