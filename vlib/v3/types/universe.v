module types

pub const bool_ = Primitive{
	props: .boolean
}
pub const int_ = Primitive{
	props: .integer
}
pub const i8_ = Primitive{
	props: .integer
	size:  8
}
pub const i16_ = Primitive{
	props: .integer
	size:  16
}
pub const i32_ = Primitive{
	props: .integer
	size:  32
}
pub const i64_ = Primitive{
	props: .integer
	size:  64
}
pub const u8_ = Primitive{
	props: .integer | .unsigned
	size:  8
}
pub const u16_ = Primitive{
	props: .integer | .unsigned
	size:  16
}
pub const u32_ = Primitive{
	props: .integer | .unsigned
	size:  32
}
pub const u64_ = Primitive{
	props: .integer | .unsigned
	size:  64
}
pub const f32_ = Primitive{
	props: .float
	size:  32
}
pub const f64_ = Primitive{
	props: .float
	size:  64
}
pub const string_ = String{}
pub const char_ = Char{}
pub const rune_ = Rune{}
pub const isize_ = ISize{}
pub const usize_ = USize{}
pub const void_ = Void{}
pub const nil_ = Nil{}
pub const none_ = None{}
pub const voidptr_ = Pointer{
	base_type: Type(Void{})
}
pub const charptr_ = Pointer{
	base_type: Type(Char{})
}
pub const byteptr_ = Pointer{
	base_type: Type(Primitive{
		props: .integer | .unsigned
		size:  8
	})
}

pub fn builtin_type(name string) ?Type {
	return match name {
		'bool' { Type(bool_) }
		'int' { Type(int_) }
		'i8' { Type(i8_) }
		'i16' { Type(i16_) }
		'i32' { Type(i32_) }
		'i64' { Type(i64_) }
		'u8', 'byte' { Type(u8_) }
		'u16' { Type(u16_) }
		'u32' { Type(u32_) }
		'u64' { Type(u64_) }
		'f32' { Type(f32_) }
		'f64' { Type(f64_) }
		'string' { Type(string_) }
		'char' { Type(char_) }
		'rune' { Type(rune_) }
		'isize' { Type(isize_) }
		'usize' { Type(usize_) }
		'void' { Type(void_) }
		'voidptr' { Type(voidptr_) }
		'array' { Type(Array{elem_type: Type(void_)}) }
		'charptr' { Type(charptr_) }
		'byteptr' { Type(byteptr_) }
		'nil' { Type(nil_) }
		'none' { Type(none_) }
		else { return none }
	}
}
