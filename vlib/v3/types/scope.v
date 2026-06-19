module types

@[heap]
pub struct Scope {
pub mut:
	parent      &Scope = unsafe { nil }
	names       []string
	types       []Type
	generations []int
	generation  int
}

// new_scope returns a reusable type-checker scope with an optional parent.
pub fn new_scope(parent &Scope) &Scope {
	unsafe {
		return &Scope{
			parent: parent
		}
	}
}

// reset retargets a pooled scope without clearing its storage.
pub fn (mut s Scope) reset(parent &Scope) {
	s.parent = parent
	s.generation++
}

// lookup returns the nearest visible type binding for `name`.
pub fn (s &Scope) lookup(name string) ?Type {
	if name.len == 0 {
		return none
	}
	for i := s.names.len - 1; i >= 0; i-- {
		if s.generations[i] == s.generation && s.names[i] == name {
			return s.types[i]
		}
	}
	if s.parent != unsafe { nil } {
		return s.parent.lookup(name)
	}
	return none
}

// insert records or updates a type binding in this scope generation.
pub fn (mut s Scope) insert(name string, typ Type) {
	for i := s.names.len - 1; i >= 0; i-- {
		if s.generations[i] == s.generation && s.names[i] == name {
			s.types[i] = typ
			return
		}
	}
	s.names << name
	s.types << typ
	s.generations << s.generation
}
