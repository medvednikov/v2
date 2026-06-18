module c

import v3.flat
import v3.types

fn (mut g FlatGen) gen_if(node flat.Node) {
	cond := g.a.child_node(&node, 0)
	if cond.kind == .decl_assign {
		g.gen_if_guard(node, *cond)
		return
	}
	if cond.kind != .empty {
		g.write('if (')
		g.gen_expr(g.a.child(&node, 0))
		g.writeln(') {')
	} else {
		g.writeln('{')
	}
	g.tc.push_scope()
	g.indent++
	if cond.kind == .is_expr {
		g.smartcast_is_expr(cond)
	}
	then_block := g.a.child_node(&node, 1)
	for i in 0 .. then_block.children_count {
		g.gen_node(g.a.child(then_block, i))
	}
	g.indent--
	g.tc.pop_scope()
	g.gen_if_else(node)
}

fn (mut g FlatGen) smartcast_is_expr(cond &flat.Node) {
	expr_id := g.a.child(cond, 0)
	expr_node := g.a.nodes[int(expr_id)]
	if expr_node.kind == .ident {
		sum_type := g.tc.resolve_type(expr_id)
		mut clean_sum := types.unwrap_pointer(sum_type)
		if clean_sum is types.Alias {
			clean_sum = clean_sum.base_type
		}
		if clean_sum is types.SumType {
			variant_name := g.resolve_variant(clean_sum.name, cond.value)
			variant_type := g.tc.parse_type(variant_name)
			if variant_type is types.Void {
				return
			}
			variant_ct := g.tc.c_type(variant_type)
			field_name := g.sum_field_name(variant_name)
			is_ptr_variant := g.variant_references_sum(variant_name, clean_sum.name)
			var_name := c_name(expr_node.value)
			tmp := g.tmp_name()
			if is_ptr_variant {
				g.writeln('${variant_ct} ${tmp} = *${var_name}.${field_name};')
			} else {
				g.writeln('${variant_ct} ${tmp} = ${var_name}.${field_name};')
			}
			g.writeln('${variant_ct} ${var_name} = ${tmp};')
			g.tc.cur_scope.insert(expr_node.value, variant_type)
		}
	}
}

fn (g &FlatGen) expr_key(id flat.NodeId) string {
	node := g.a.nodes[int(id)]
	if node.kind == .ident {
		return node.value
	}
	if node.kind == .selector && node.children_count > 0 {
		base_key := g.expr_key(g.a.child(&node, 0))
		if base_key.len > 0 {
			return '${base_key}.${node.value}'
		}
	}
	return ''
}

fn (mut g FlatGen) gen_if_guard(node flat.Node, cond flat.Node) {
	lhs := g.a.child_node(&cond, 0)
	rhs_id := g.a.child(&cond, 1)
	rhs := g.a.child_node(&cond, 1)
	var_name := c_name(lhs.value)
	tmp := g.tmp_name()
	if rhs.kind == .index {
		base_id := g.a.child(rhs, 0)
		base_type := g.tc.resolve_type(base_id)
		if base_type is types.Map {
			c_val_type := g.tc.c_type(base_type.value_type)
			c_key_type := g.tc.c_type(base_type.key_type)
			g.write('void* ${tmp} = map__get_check(&')
			g.gen_expr(base_id)
			g.write(', &(${c_key_type}[]){')
			g.gen_expr(g.a.child(rhs, 1))
			g.writeln('});')
			g.writeln('if (${tmp} != NULL) {')
			g.tc.push_scope()
			g.indent++
			g.writeln('${c_val_type} ${var_name} = *(${c_val_type}*)${tmp};')
			g.tc.cur_scope.insert(lhs.value, base_type.value_type)
		} else {
			rhs_type := g.tc.resolve_type(rhs_id)
			opt_ct := g.optional_type_name(rhs_type)
			val_ct, val_type := g.optional_value_ct(rhs_type)
			g.write('${opt_ct} ${tmp} = ')
			g.gen_expr(rhs_id)
			g.writeln(';')
			g.writeln('if (${tmp}.ok) {')
			g.tc.push_scope()
			g.indent++
			g.writeln('${val_ct} ${var_name} = ${tmp}.value;')
			g.tc.cur_scope.insert(lhs.value, val_type)
		}
	} else {
		rhs_type := g.tc.resolve_type(rhs_id)
		opt_ct := g.optional_type_name(rhs_type)
		val_ct, val_type := g.optional_value_ct(rhs_type)
		g.write('${opt_ct} ${tmp} = ')
		g.gen_expr(rhs_id)
		g.writeln(';')
		g.writeln('if (${tmp}.ok) {')
		g.tc.push_scope()
		g.indent++
		g.writeln('${val_ct} ${var_name} = ${tmp}.value;')
		g.tc.cur_scope.insert(lhs.value, val_type)
	}
	then_block := g.a.child_node(&node, 1)
	for i in 0 .. then_block.children_count {
		g.gen_node(g.a.child(then_block, i))
	}
	g.indent--
	g.tc.pop_scope()
	g.gen_if_else(node)
}

fn (mut g FlatGen) gen_if_else(node flat.Node) {
	if node.children_count > 2 {
		else_node := g.a.child_node(&node, 2)
		if else_node.kind == .if_expr {
			g.write('} else ')
			g.gen_if(*else_node)
		} else if else_node.kind == .block {
			g.writeln('} else {')
			g.tc.push_scope()
			g.indent++
			for i in 0 .. else_node.children_count {
				g.gen_node(g.a.child(else_node, i))
			}
			g.indent--
			g.tc.pop_scope()
			g.writeln('}')
		} else {
			g.writeln('}')
		}
	} else {
		g.writeln('}')
	}
}

fn (mut g FlatGen) gen_if_expr(node flat.Node) {
	then_block := g.a.child_node(&node, 1)
	mut needs_stmt_expr := then_block.children_count > 1
	if !needs_stmt_expr && node.children_count > 2 {
		else_node := g.a.child_node(&node, 2)
		if else_node.kind == .block && else_node.children_count > 1 {
			needs_stmt_expr = true
		} else if else_node.kind == .if_expr {
			needs_stmt_expr = true
		}
	}
	if needs_stmt_expr {
		g.gen_if_expr_stmt(node)
		return
	}
	g.write('(')
	g.gen_expr(g.a.child(&node, 0))
	g.write(' ? ')
	if then_block.children_count > 0 {
		last := g.a.child_node(then_block, then_block.children_count - 1)
		if last.kind == .expr_stmt {
			g.gen_expr(g.a.child(last, 0))
		} else {
			g.gen_expr(g.a.child(then_block, then_block.children_count - 1))
		}
	}
	g.write(' : ')
	if node.children_count > 2 {
		else_node := g.a.child_node(&node, 2)
		if else_node.kind == .if_expr {
			g.gen_if_expr(*else_node)
		} else if else_node.kind == .block {
			if else_node.children_count > 0 {
				last := g.a.child_node(else_node, else_node.children_count - 1)
				if last.kind == .expr_stmt {
					g.gen_expr(g.a.child(last, 0))
				} else {
					g.gen_expr(g.a.child(else_node, else_node.children_count - 1))
				}
			} else {
				g.write('0')
			}
		}
	} else {
		g.write('0')
	}
	g.write(')')
}

fn (mut g FlatGen) gen_if_expr_block(block &flat.Node) {
	for i in 0 .. block.children_count {
		child := g.a.child_node(block, i)
		if i == block.children_count - 1 {
			if child.kind == .expr_stmt {
				g.write('_ifexpr = ')
				g.gen_expr(g.a.child(child, 0))
				g.writeln(';')
			} else if child.kind == .if_expr {
				g.write('_ifexpr = ')
				g.gen_if_expr(*child)
				g.writeln(';')
			} else {
				g.gen_node(g.a.child(block, i))
			}
		} else {
			g.gen_node(g.a.child(block, i))
		}
	}
}

fn (mut g FlatGen) seed_scope_from_decl(node flat.Node) {
	if node.kind != .decl_assign || node.children_count < 2 {
		return
	}
	lhs := g.a.child_node(&node, 0)
	if lhs.kind != .ident || lhs.value.len == 0 {
		return
	}
	rhs_id := g.a.child(&node, 1)
	g.tc.cur_scope.insert(lhs.value, g.tc.resolve_type(rhs_id))
}

fn (mut g FlatGen) if_expr_block_tail_type(block &flat.Node) types.Type {
	if block.children_count == 0 {
		return types.Type(types.void_)
	}
	g.tc.push_scope()
	for i in 0 .. block.children_count - 1 {
		g.seed_scope_from_decl(*g.a.child_node(block, i))
	}
	last := g.a.child_node(block, block.children_count - 1)
	ret := if last.kind == .expr_stmt {
		g.tc.resolve_type(g.a.child(last, 0))
	} else {
		g.tc.resolve_type(g.a.child(block, block.children_count - 1))
	}
	g.tc.pop_scope()
	return ret
}

fn (mut g FlatGen) if_expr_type(node &flat.Node) types.Type {
	if node.children_count < 2 {
		return types.Type(types.void_)
	}
	then_block := g.a.child_node(node, 1)
	mut ret_type := g.if_expr_block_tail_type(then_block)
	if ret_type is types.Primitive && node.children_count > 2 {
		else_node := g.a.child_node(node, 2)
		if else_node.kind == .block && else_node.children_count > 0 {
			et := g.if_expr_block_tail_type(else_node)
			if et !is types.Primitive {
				ret_type = et
			}
		} else if else_node.kind == .if_expr && else_node.children_count > 2 {
			inner_else := g.a.child_node(else_node, 2)
			if inner_else.kind == .block && inner_else.children_count > 0 {
				et := g.if_expr_block_tail_type(inner_else)
				if et !is types.Primitive {
					ret_type = et
				}
			}
		}
	}
	return ret_type
}

fn (mut g FlatGen) gen_if_expr_stmt(node flat.Node) {
	ret_type := g.if_expr_type(&node)
	then_block := g.a.child_node(&node, 1)
	ct := g.tc.c_type(ret_type)
	g.writeln('({${ct} _ifexpr;')
	g.write('if (')
	g.gen_expr(g.a.child(&node, 0))
	g.writeln(') {')
	g.gen_if_expr_block(then_block)
	g.write('} else ')
	if node.children_count > 2 {
		else_node := g.a.child_node(&node, 2)
		if else_node.kind == .if_expr {
			g.gen_if_expr_else_if(*else_node)
		} else if else_node.kind == .block {
			g.writeln('{')
			g.gen_if_expr_block(else_node)
			g.writeln('}')
		}
	} else {
		g.writeln('{ _ifexpr = (${ct}){0}; }')
	}
	g.write('_ifexpr;})')
}

fn (mut g FlatGen) gen_if_expr_else_if(node flat.Node) {
	then_block := g.a.child_node(&node, 1)
	g.write('if (')
	g.gen_expr(g.a.child(&node, 0))
	g.writeln(') {')
	g.gen_if_expr_block(then_block)
	g.write('} else ')
	if node.children_count > 2 {
		else_node := g.a.child_node(&node, 2)
		if else_node.kind == .if_expr {
			g.gen_if_expr_else_if(*else_node)
		} else if else_node.kind == .block {
			g.writeln('{')
			g.gen_if_expr_block(else_node)
			g.writeln('}')
		}
	} else {
		g.writeln('{ _ifexpr = (typeof(_ifexpr)){0}; }')
	}
}
