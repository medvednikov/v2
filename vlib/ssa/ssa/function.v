module ssa

pub enum CallConv {
	c_decl
	fast_call
	wasm_std
}

pub enum Linkage {
	external
	private
	internal
}

pub struct Function {
pub:
	id   int
	name string
	typ  TypeID
pub mut:
	blocks []BlockID
	params []ValueID

	linkage   Linkage
	call_conv CallConv
}
