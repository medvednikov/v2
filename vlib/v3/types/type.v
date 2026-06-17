module types

pub type Type = Void
	| Primitive
	| String
	| Char
	| Rune
	| ISize
	| USize
	| Nil
	| None
	| Array
	| ArrayFixed
	| Map
	| Pointer
	| FnType
	| OptionType
	| ResultType
	| Struct
	| Enum
	| SumType
	| Alias
	| MultiReturn

pub struct Void {
	dummy_ u8
}

pub struct String {
	dummy_ u8
}

pub struct Char {
	dummy_ u8
}

pub struct Rune {
	dummy_ u8
}

pub struct ISize {
	dummy_ u8
}

pub struct USize {
	dummy_ u8
}

pub struct Nil {
	dummy_ u8
}

pub struct None {
	dummy_ u8
}

@[flag]
pub enum Properties {
	boolean
	float
	integer
	unsigned
	untyped
}

pub struct Primitive {
pub:
	props Properties
	size  u8
}

pub struct Array {
pub:
	elem_type Type
}

pub struct ArrayFixed {
pub:
	elem_type Type
	len       int
}

pub struct Map {
pub:
	key_type   Type
	value_type Type
}

pub struct Pointer {
pub:
	base_type Type
}

pub struct FnType {
pub:
	params      []Type
	return_type ?Type
}

pub struct OptionType {
pub:
	base_type Type
}

pub struct ResultType {
pub:
	base_type Type
}

pub struct Struct {
pub:
	name string
}

pub struct Enum {
pub:
	name    string
	is_flag bool
}

pub struct SumType {
pub:
	name string
}

pub struct Alias {
pub:
	name      string
	base_type Type
}

pub struct MultiReturn {
pub:
	types []Type
}

pub struct StructField {
pub:
	name string
	typ  Type
}

pub fn unwrap_pointer(t Type) Type {
	if t is Pointer {
		return t.base_type
	}
	return t
}

pub fn (t Type) is_pointer() bool {
	return t is Pointer
}

pub fn (t Type) is_string() bool {
	return t is String
}

pub fn (t Type) is_integer() bool {
	if t is Primitive {
		return t.props.has(.integer)
	}
	return t is Rune || t is ISize || t is USize
}

pub fn (t Type) is_float() bool {
	if t is Primitive {
		return t.props.has(.float)
	}
	return false
}

pub fn (t Type) name() string {
	match t {
		Void {
			return 'void'
		}
		Nil {
			return 'nil'
		}
		None {
			return 'none'
		}
		String {
			return 'string'
		}
		Char {
			return 'char'
		}
		Rune {
			return 'rune'
		}
		ISize {
			return 'isize'
		}
		USize {
			return 'usize'
		}
		Primitive {
			return prim_name(t)
		}
		Array {
			return '[]${t.elem_type.name()}'
		}
		ArrayFixed {
			return '${t.elem_type.name()}[${t.len}]'
		}
		Map {
			return 'map[${t.key_type.name()}]${t.value_type.name()}'
		}
		Pointer {
			return '&${t.base_type.name()}'
		}
		FnType {
			mut s := 'fn('
			for i, p in t.params {
				if i > 0 {
					s += ', '
				}
				s += p.name()
			}
			s += ')'
			if ret := t.return_type {
				s += ' ${ret.name()}'
			}
			return s
		}
		OptionType {
			return '?${t.base_type.name()}'
		}
		ResultType {
			return '!${t.base_type.name()}'
		}
		Struct {
			return t.name
		}
		Enum {
			return t.name
		}
		SumType {
			return t.name
		}
		Alias {
			return t.name
		}
		MultiReturn {
			mut parts := []string{}
			for ty in t.types {
				parts << ty.name()
			}
			return '(${parts.join(', ')})'
		}
	}
}

fn prim_name(t Primitive) string {
	if t.props.has(.boolean) {
		return 'bool'
	}
	if t.props.has(.integer) {
		if t.props.has(.unsigned) {
			return match t.size {
				8 { 'u8' }
				16 { 'u16' }
				32 { 'u32' }
				64 { 'u64' }
				else { 'u${t.size}' }
			}
		}
		return match t.size {
			0 { 'int' }
			8 { 'i8' }
			16 { 'i16' }
			32 { 'i32' }
			64 { 'i64' }
			else { 'i${t.size}' }
		}
	}
	if t.props.has(.float) {
		return match t.size {
			32 { 'f32' }
			64 { 'f64' }
			else { 'f${t.size}' }
		}
	}
	return 'int'
}
