module ssa

import v2.token

pub enum OpCode {
	// Terminators
	ret
	br
	jmp
	switch_
	unreachable

	// Binary
	add
	sub
	mul
	sdiv
	udiv
	srem
	urem

	// Bitwise
	shl
	lshr
	ashr
	and_
	or_
	xor

	// Memory
	alloca
	load
	store
	get_element_ptr
	fence
	cmpxchg
	atomicrmw

	// Conversion
	trunc
	zext
	sext
	fptoui
	fptosi
	uitofp
	sitofp
	bitcast

	// Other
	icmp
	fcmp
	phi
	call
	select
}

pub enum AtomicOrdering {
	not_atomic
	unordered
	monotonic
	acquire
	release
	acq_rel
	seq_cst
}

pub struct Instruction {
pub:
	op    OpCode
	block BlockID
	typ   TypeID // Result type

	// Operands are IDs of other Values
	operands []ValueID

	pos        token.Pos
	atomic_ord AtomicOrdering
}
