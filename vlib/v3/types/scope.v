module types

@[heap]
pub struct Scope {
pub:
	parent &Scope = unsafe { nil }
pub mut:
	objects map[string]Type
}

pub fn new_scope(parent &Scope) &Scope {
	unsafe {
		return &Scope{
			parent: parent
		}
	}
}

pub fn (s &Scope) lookup(name string) ?Type {
	if name.len == 0 {
		return none
	}
	if name in s.objects {
		return s.objects[name] or { Type(int_) }
	}
	if s.parent != unsafe { nil } {
		return s.parent.lookup(name)
	}
	return none
}

pub fn (mut s Scope) insert(name string, typ Type) {
	s.objects[name] = typ
}
