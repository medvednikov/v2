module types

@[heap]
pub struct Scope {
pub mut:
	parent     &Scope = unsafe { nil }
	objects    map[string]ScopedObject
	generation int
}

struct ScopedObject {
	typ        Type
	generation int
}

pub fn new_scope(parent &Scope) &Scope {
	unsafe {
		return &Scope{
			parent: parent
		}
	}
}

pub fn (mut s Scope) reset(parent &Scope) {
	s.parent = parent
	s.generation++
}

pub fn (s &Scope) lookup(name string) ?Type {
	if name.len == 0 {
		return none
	}
	if obj := s.objects[name] {
		if obj.generation == s.generation {
			return obj.typ
		}
	}
	if s.parent != unsafe { nil } {
		return s.parent.lookup(name)
	}
	return none
}

pub fn (mut s Scope) insert(name string, typ Type) {
	s.objects[name] = ScopedObject{
		typ:        typ
		generation: s.generation
	}
}
