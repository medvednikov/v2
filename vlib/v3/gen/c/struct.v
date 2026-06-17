module c

import v3.flat
import v3.types

fn (mut g FlatGen) gen_struct_init(node flat.Node) {
	name := g.tc.c_type(g.tc.parse_type(node.value))
	g.write('(${name}){')
	for i in 0 .. node.children_count {
		field := g.a.child_node(&node, i)
		if i > 0 {
			g.write(', ')
		}
		g.write('.${c_name(field.value)} = ')
		g.gen_expr(g.a.child(field, 0))
	}
	g.write('}')
}

fn (mut g FlatGen) gen_heap_struct_init(node flat.Node) {
	name := g.tc.c_type(g.tc.parse_type(node.value))
	g.write('(${name}*)memdup(&(${name}){')
	for i in 0 .. node.children_count {
		field := g.a.child_node(&node, i)
		if i > 0 {
			g.write(', ')
		}
		g.write('.${c_name(field.value)} = ')
		g.gen_expr(g.a.child(field, 0))
	}
	g.write('}, sizeof(${name}))')
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
	return g.has_builtins && name in ['array', 'map', 'DenseArray', 'MapHashFn', 'MapEqFn', 'MapCloneFn', 'MapFreeFn', 'MapSlot', 'ArrayDataHeader']
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

fn (mut g FlatGen) write_struct_field(struct_name string, f types.StructField) {
	if f.typ is types.FnType {
		ret := if r := f.typ.return_type { g.tc.c_type(r) } else { 'void' }
		mut params := []string{}
		for p in f.typ.params {
			params << g.tc.c_type(p)
		}
		params_str := if params.len > 0 { params.join(', ') } else { 'void' }
		g.writeln('\t${ret} (*${c_name(f.name)})(${params_str});')
	} else if f.typ is types.ArrayFixed {
		c_elem := g.tc.c_type(f.typ.elem_type)
		g.writeln('\t${c_elem} ${c_name(f.name)}[${f.typ.len}];')
	} else {
		ct := g.tc.c_type(f.typ)
		g.writeln('\t${ct} ${c_name(f.name)};')
	}
}
