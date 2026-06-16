module markused

import v3.flat

pub fn mark_used(a &flat.FlatAst) map[string]bool {
	mut call_graph := map[string][]string{}
	mut all_fns := map[string]bool{}

	for node in a.nodes {
		if node.kind == .fn_decl {
			all_fns[node.value] = true
			mut callees := []string{}
			collect_calls(a, &node, mut callees)
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
				if callee !in used && callee in all_fns {
					used[callee] = true
					queue << callee
				}
			}
		}
	}
	return used
}

fn collect_calls(a &flat.FlatAst, node &flat.Node, mut calls []string) {
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
		collect_calls(a, child, mut calls)
	}
}
