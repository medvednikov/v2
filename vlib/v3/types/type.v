module types

pub type Type = Void
	| Unknown
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
	| Interface
	| Enum
	| SumType
	| Alias
	| MultiReturn

pub struct Void {
	dummy_ u8
}

pub struct Unknown {
pub:
	reason string
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
	return_type Type
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

pub struct Interface {
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
	if t is Void {
		return 'void'
	}
	if t is Unknown {
		return 'unknown'
	}
	if t is Nil {
		return 'nil'
	}
	if t is None {
		return 'none'
	}
	if t is String {
		return 'string'
	}
	if t is Char {
		return 'char'
	}
	if t is Rune {
		return 'rune'
	}
	if t is ISize {
		return 'isize'
	}
	if t is USize {
		return 'usize'
	}
	if t is Primitive {
		return prim_name_from(t.props, t.size)
	}
	if t is Array {
		elem_name := t.elem_type.name()
		debug_check_string('Type.Array.elem', elem_name)
		return '[]${elem_name}'
	}
	if t is ArrayFixed {
		elem_name := t.elem_type.name()
		debug_check_string('Type.ArrayFixed.elem', elem_name)
		return '${elem_name}[${t.len}]'
	}
	if t is Map {
		key_name := t.key_type.name()
		val_name := t.value_type.name()
		debug_check_string('Type.Map.key', key_name)
		debug_check_string('Type.Map.val', val_name)
		return 'map[${key_name}]${val_name}'
	}
	if t is Pointer {
		base_name := t.base_type.name()
		debug_check_string('Type.Pointer.base', base_name)
		return '&${base_name}'
	}
	if t is FnType {
		mut s := 'fn('
		for i, p in t.params {
			if i > 0 {
				s += ', '
			}
			s += p.name()
		}
		s += ')'
		if t.return_type !is Void {
			s += ' ${t.return_type.name()}'
		}
		return s
	}
	if t is OptionType {
		base_name := t.base_type.name()
		debug_check_string('Type.Option.base', base_name)
		return '?${base_name}'
	}
	if t is ResultType {
		base_name := t.base_type.name()
		debug_check_string('Type.Result.base', base_name)
		return '!${base_name}'
	}
	if t is Struct {
		debug_check_string('Type.Struct.name', t.name)
		return t.name
	}
	if t is Interface {
		debug_check_string('Type.Interface.name', t.name)
		return t.name
	}
	if t is Enum {
		debug_check_string('Type.Enum.name', t.name)
		return t.name
	}
	if t is SumType {
		debug_check_string('Type.SumType.name', t.name)
		return t.name
	}
	if t is Alias {
		debug_check_string('Type.Alias.name', t.name)
		return t.name
	}
	if t is MultiReturn {
		mut parts := []string{}
		for ty in t.types {
			parts << ty.name()
		}
		return '(${parts.join(', ')})'
	}
	return ''
}

fn prim_name_from(props Properties, size u8) string {
	if props.has(.boolean) {
		return 'bool'
	}
	if props.has(.integer) {
		if props.has(.unsigned) {
			return match size {
				8 { 'u8' }
				16 { 'u16' }
				32 { 'u32' }
				64 { 'u64' }
				else { 'u${size}' }
			}
		}
		return match size {
			0 { 'int' }
			8 { 'i8' }
			16 { 'i16' }
			32 { 'i32' }
			64 { 'i64' }
			else { 'i${size}' }
		}
	}
	if props.has(.float) {
		return match size {
			32 { 'f32' }
			64 { 'f64' }
			else { 'f${size}' }
		}
	}
	return 'int'
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
