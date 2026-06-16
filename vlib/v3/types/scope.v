module types

@[heap]
pub struct Scope {
pub:
	parent &Scope = unsafe { nil }
pub mut:
	objects map[string]string
}

pub fn new_scope(parent &Scope) &Scope {
	unsafe {
		return &Scope{parent: parent}
	}
}

pub fn (s &Scope) lookup(name string) ?string {
	if name.len == 0 {
		return none
	}
	if typ := s.objects[name] {
		return typ
	}
	if s.parent != unsafe { nil } {
		return s.parent.lookup(name)
	}
	return none
}

pub fn (mut s Scope) insert(name string, typ string) {
	s.objects[name] = typ
}
