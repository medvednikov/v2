module markused

import v3.flat
import v3.types

pub fn mark_used(a &flat.FlatAst, tc &types.TypeChecker) map[string]bool {
	mut call_graph := map[string][]string{}
	mut all_fns := map[string]bool{}

	for node in a.nodes {
		if node.kind == .fn_decl {
			all_fns[node.value] = true
			mut callees := []string{}
			collect_calls(a, tc, &node, mut callees)
			call_graph[node.value] = callees
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
				} else {
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

fn collect_calls(a &flat.FlatAst, tc &types.TypeChecker, node &flat.Node, mut calls []string) {
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
							if callee.value in ['println', 'print'] {
								calls << 'int_str'
							}
						} else if callee.kind == .selector && callee.value.len > 0 {
							if callee.children_count > 0 {
								base_id := a.child(&callee, 0)
								if int(base_id) >= 0 {
									base := a.nodes[int(base_id)]
									if base.kind == .ident && base.value.len > 0 {
										calls << base.value + '.' + callee.value
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

		collect_calls(a, tc, child, mut calls)
	}
}

fn resolve_type_name(t types.Type) string {
	return match t {
		types.Struct { t.name }
		types.String { 'string' }
		types.Array { 'Array' }
		types.Map { 'map' }
		types.Pointer { resolve_type_name(t.base_type) }
		else { '' }
	}
}
