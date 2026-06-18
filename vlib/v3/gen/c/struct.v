module c

import v3.flat
import v3.types

fn (mut g FlatGen) gen_struct_init(node flat.Node) {
	name := g.struct_init_c_type_name(node.value)
	g.write('(${name}){')
	mut set_fields := map[string]bool{}
	mut has_field := false
	for i in 0 .. node.children_count {
		field := g.a.child_node(&node, i)
		if has_field {
			g.write(', ')
		}
		g.write('.${c_name(field.value)} = ')
		g.gen_expr(g.a.child(field, 0))
		set_fields[field.value] = true
		has_field = true
	}
	qname := g.tc.qualify_name(node.value)
	sname := if qname in g.tc.structs { qname } else { node.value }
	if sname in g.tc.structs {
		has_field = g.gen_struct_default_fields(node.value, mut set_fields, has_field)
		for f in g.tc.structs[sname] {
			if f.name in set_fields {
				continue
			}
			if f.typ is types.Map {
				c_key := g.tc.c_type(f.typ.key_type)
				c_val := g.tc.c_type(f.typ.value_type)
				if has_field {
					g.write(', ')
				}
				g.write('.${c_name(f.name)} = new_map(sizeof(${c_key}), sizeof(${c_val}), 0, 0, 0, 0)')
				has_field = true
			} else if f.typ is types.Array {
				c_elem := g.tc.c_type(f.typ.elem_type)
				if has_field {
					g.write(', ')
				}
				g.write('.${c_name(f.name)} = array_new(sizeof(${c_elem}), 0, 0)')
				has_field = true
			}
		}
	}
	g.write('}')
}

fn (mut g FlatGen) gen_heap_struct_init(node flat.Node) {
	name := g.struct_init_c_type_name(node.value)
	g.write('(${name}*)memdup(&(${name}){')
	mut set_fields := map[string]bool{}
	mut has_field := false
	for i in 0 .. node.children_count {
		field := g.a.child_node(&node, i)
		if has_field {
			g.write(', ')
		}
		g.write('.${c_name(field.value)} = ')
		g.gen_expr(g.a.child(field, 0))
		set_fields[field.value] = true
		has_field = true
	}
	qname := g.tc.qualify_name(node.value)
	sname := if qname in g.tc.structs { qname } else { node.value }
	if sname in g.tc.structs {
		has_field = g.gen_struct_default_fields(node.value, mut set_fields, has_field)
		for f in g.tc.structs[sname] {
			if f.name in set_fields {
				continue
			}
			if f.typ is types.Map {
				c_key := g.tc.c_type(f.typ.key_type)
				c_val := g.tc.c_type(f.typ.value_type)
				if has_field {
					g.write(', ')
				}
				g.write('.${c_name(f.name)} = new_map(sizeof(${c_key}), sizeof(${c_val}), 0, 0, 0, 0)')
				has_field = true
			} else if f.typ is types.Array {
				c_elem := g.tc.c_type(f.typ.elem_type)
				if has_field {
					g.write(', ')
				}
				g.write('.${c_name(f.name)} = array_new(sizeof(${c_elem}), 0, 0)')
				has_field = true
			}
		}
	}
	g.write('}, sizeof(${name}))')
}

fn (mut g FlatGen) gen_struct_default_fields(type_name string, mut set_fields map[string]bool, has_field bool) bool {
	mut has := has_field
	info := g.find_struct_decl(type_name) or { return has }
	old_module := g.tc.cur_module
	g.tc.cur_module = info.module
	for i in 0 .. info.node.children_count {
		field := g.a.child_node(&info.node, i)
		if field.kind != .field_decl || field.children_count == 0 || field.value in set_fields {
			continue
		}
		if has {
			g.write(', ')
		}
		g.write('.${c_name(field.value)} = ')
		g.gen_expr(g.a.child(field, 0))
		set_fields[field.value] = true
		has = true
	}
	g.tc.cur_module = old_module
	return has
}

fn (mut g FlatGen) gen_default_value_for_type(typ types.Type) {
	if typ is types.Struct && !typ.name.starts_with('C.') {
		ct := g.tc.c_type(typ)
		g.write('(${ct}){')
		mut set_fields := map[string]bool{}
		mut has_field := g.gen_struct_default_fields(typ.name, mut set_fields, false)
		sname := if typ.name in g.tc.structs { typ.name } else { g.tc.qualify_name(typ.name) }
		if sname in g.tc.structs {
			for f in g.tc.structs[sname] {
				if f.name in set_fields {
					continue
				}
				if f.typ is types.Map {
					c_key := g.tc.c_type(f.typ.key_type)
					c_val := g.tc.c_type(f.typ.value_type)
					if has_field {
						g.write(', ')
					}
					g.write('.${c_name(f.name)} = new_map(sizeof(${c_key}), sizeof(${c_val}), 0, 0, 0, 0)')
					has_field = true
				} else if f.typ is types.Array {
					c_elem := g.tc.c_type(f.typ.elem_type)
					if has_field {
						g.write(', ')
					}
					g.write('.${c_name(f.name)} = array_new(sizeof(${c_elem}), 0, 0)')
					has_field = true
				}
			}
		}
		g.write('}')
		return
	}
	ct := g.tc.c_type(typ)
	g.write('(${ct}){0}')
}

struct StructDeclInfo {
	node      flat.Node
	module    string
	full_name string
}

fn (g &FlatGen) struct_init_c_type_name(type_name string) string {
	info := g.find_struct_decl(type_name) or { return g.tc.c_type(g.tc.parse_type(type_name)) }
	return c_name(info.full_name)
}

fn (g &FlatGen) find_struct_decl(type_name string) ?StructDeclInfo {
	short_name := if type_name.contains('.') { type_name.all_after_last('.') } else { type_name }
	preferred_name := if !type_name.contains('.') && g.tc.cur_module.len > 0
		&& g.tc.cur_module != 'main' && g.tc.cur_module != 'builtin' {
		'${g.tc.cur_module}.${type_name}'
	} else {
		type_name
	}
	mut cur_module := ''
	for node in g.a.nodes {
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
		if preferred_name == full_name {
			return StructDeclInfo{
				node:      node
				module:    cur_module
				full_name: full_name
			}
		}
	}
	cur_module = ''
	for node in g.a.nodes {
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
				node:      node
				module:    cur_module
				full_name: full_name
			}
		}
	}
	return none
}

fn (mut g FlatGen) gen_return_assoc(node flat.Node) {
	ct := g.tc.c_type(g.tc.parse_type(node.value))
	tmp := g.tmp_name()
	g.write('${ct} ${tmp} = ')
	g.gen_expr(g.a.child(&node, 0))
	g.writeln(';')
	for i in 1 .. node.children_count {
		field := g.a.child_node(&node, i)
		if field.kind == .field_init && field.children_count > 0 {
			g.write('${tmp}.${c_name(field.value)} = ')
			g.gen_expr(g.a.child(field, 0))
			g.writeln(';')
		}
	}
	g.writeln('return ${tmp};')
}

fn (mut g FlatGen) gen_assoc_expr(node flat.Node) {
	ct := g.tc.c_type(g.tc.parse_type(node.value))
	tmp := g.tmp_name()
	g.write('({${ct} ${tmp} = ')
	g.gen_expr(g.a.child(&node, 0))
	g.write(';')
	for i in 1 .. node.children_count {
		field := g.a.child_node(&node, i)
		if field.kind == .field_init && field.children_count > 0 {
			g.write(' ${tmp}.${c_name(field.value)} = ')
			g.gen_expr(g.a.child(field, 0))
			g.write(';')
		}
	}
	g.write(' ${tmp};})')
}

fn (mut g FlatGen) gen_map_init(node flat.Node) {
	map_type := g.tc.parse_type(node.value)
	if map_type is types.Map {
		c_key := g.tc.c_type(map_type.key_type)
		c_val := g.tc.c_type(map_type.value_type)
		g.write('new_map(sizeof(${c_key}), sizeof(${c_val}), 0, 0, 0, 0)')
	} else {
		g.write('new_map(sizeof(int), sizeof(int), 0, 0, 0, 0)')
	}
}

fn (g &FlatGen) skip_builtin_struct(name string) bool {
	_ = g
	_ = name
	return false
}

fn (mut g FlatGen) struct_decls() {
	for name, _ in g.tc.structs {
		if g.skip_builtin_struct(name) {
			continue
		}
		g.writeln('typedef struct ${c_name(name)} ${c_name(name)};')
	}
	for name, variants in g.tc.sum_types {
		g.writeln('typedef struct ${c_name(name)} ${c_name(name)};')
		_ = variants
	}
	for name, _ in g.interfaces {
		g.writeln('typedef struct ${c_name(name)} ${c_name(name)};')
	}
	if g.has_builtins {
		g.writeln('typedef array Array;')
	}
	g.writeln('typedef struct Optional { bool ok; int value; } Optional;')
	g.writeln('')
	mut emitted := map[string]bool{}
	mut remaining := map[string]bool{}
	mut remaining_cnames := map[string]bool{}
	mut iface_remaining := map[string]bool{}
	for name, _ in g.interfaces {
		iface_remaining[name] = true
		remaining_cnames[c_name(name)] = true
	}
	for name, _ in g.tc.structs {
		if g.skip_builtin_struct(name) {
			continue
		}
		remaining[name] = true
		remaining_cnames[c_name(name)] = true
	}
	mut sum_remaining := map[string]bool{}
	for name, _ in g.tc.sum_types {
		sum_remaining[name] = true
		remaining_cnames[c_name(name)] = true
	}
	for _ in 0 .. 30 {
		if remaining.len == 0 && iface_remaining.len == 0 && sum_remaining.len == 0 {
			break
		}
		mut progress := false
		for name, _ in iface_remaining {
			cn := c_name(name)
			mut can_emit := true
			if cn == 'IError' {
				if 'string' !in emitted && 'string' in remaining_cnames {
					can_emit = false
				}
			}
			if can_emit {
				g.writeln('struct ${cn} {')
				g.writeln('\tint _typ;')
				if cn == 'IError' {
					g.writeln('\tvoid* _object;')
					g.writeln('\tstring message;')
					g.writeln('\tint code;')
				}
				g.writeln('};')
				g.writeln('')
				emitted[cn] = true
				iface_remaining.delete(name)
				remaining_cnames.delete(cn)
				progress = true
			}
		}
		for name, _ in remaining {
			cn := c_name(name)
			if cn in emitted {
				remaining.delete(name)
				remaining_cnames.delete(cn)
				progress = true
				continue
			}
			mut can_emit := true
			if name in g.tc.structs {
				for f in g.tc.structs[name] {
					if f.typ is types.Pointer {
						continue
					}
					ct := if f.typ is types.ArrayFixed {
						g.tc.c_type(f.typ.elem_type)
					} else {
						g.tc.c_type(f.typ)
					}
					if ct !in emitted && ct != cn && ct in remaining_cnames {
						can_emit = false
						break
					}
				}
			}
			if can_emit {
				g.emit_struct(name)
				emitted[cn] = true
				remaining.delete(name)
				remaining_cnames.delete(cn)
				progress = true
			}
		}
		for name, _ in sum_remaining {
			cn := c_name(name)
			mut can_emit_sum := true
			if name in g.tc.sum_types {
				for v in g.tc.sum_types[name] {
					if g.variant_references_sum(v, name) {
						continue
					}
					vt := g.tc.parse_type(v)
					if vt is types.SumType {
						if vt.name in sum_remaining {
							can_emit_sum = false
							break
						}
					}
					vct := g.tc.c_type(vt)
					if vct !in emitted && vct in remaining_cnames {
						can_emit_sum = false
						break
					}
				}
			}
			if can_emit_sum {
				g.emit_sum_type(name)
				emitted[cn] = true
				sum_remaining.delete(name)
				remaining_cnames.delete(cn)
				progress = true
			}
		}
		if !progress {
			break
		}
	}
	for name, _ in iface_remaining {
		cn := c_name(name)
		g.writeln('struct ${cn} {')
		g.writeln('\tint _typ;')
		if cn == 'IError' {
			g.writeln('\tvoid* _object;')
			g.writeln('\tstring message;')
			g.writeln('\tint code;')
		}
		g.writeln('};')
		g.writeln('')
	}
	for name, _ in sum_remaining {
		g.emit_sum_type(name)
	}
	for name, _ in remaining {
		g.emit_struct(name)
	}
}

fn (mut g FlatGen) emit_struct(name string) {
	if name in g.tc.structs {
		fields := g.tc.structs[name]
		g.writeln('struct ${c_name(name)} {')
		if fields.len == 0 {
			g.writeln('\tint _dummy;')
		}
		for f in fields {
			g.write_struct_field(name, f)
		}
		g.writeln('};')
		g.writeln('')
	}
}

fn (mut g FlatGen) write_struct_field(_struct_name string, f types.StructField) {
	field_type := if f.typ is types.Alias { f.typ.base_type } else { f.typ }
	if field_type is types.FnType {
		ret := if field_type.return_type is types.Void {
			'void'
		} else {
			g.tc.c_type(field_type.return_type)
		}
		mut params := []string{}
		for p in field_type.params {
			params << g.tc.c_type(p)
		}
		params_str := if params.len > 0 { params.join(', ') } else { 'void' }
		g.writeln('\t${ret} (*${c_name(f.name)})(${params_str});')
	} else if f.typ is types.ArrayFixed {
		c_elem := g.tc.c_type(f.typ.elem_type)
		g.writeln('\t${c_elem} ${c_name(f.name)}[${f.typ.len}];')
	} else {
		mut ct := g.tc.c_type(f.typ)
		if ct.starts_with('fn_ptr:') {
			ct = g.resolve_fn_ptr_type(ct)
		}
		g.writeln('\t${ct} ${c_name(f.name)};')
	}
}
