module ssa

pub type ValueID = int

pub enum ValueKind {
	unknown
	constant
	argument
	global
	instruction
	basic_block
}

pub struct Value {
pub:
	id   ValueID
	kind ValueKind
	typ  TypeID
	name string
	// Index into the specific arena (instrs, blocks, globals)
	index int
pub mut:
	uses []ValueID
}

pub struct ConstantData {
pub:
	int_val   i64
	float_val f64
	str_val   string
}

pub struct GlobalVar {
pub:
	name        string
	typ         TypeID
	linkage     Linkage
	alignment   int
	is_constant bool
}
