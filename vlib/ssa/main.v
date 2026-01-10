module main

import ssa
import backend
import os

fn main() {
	println('--- V SSA to C Compiler Demo ---')

	// 1. Initialize
	mut mod := ssa.Module.new('demo_module')
	int32_t := mod.type_store.get_int(32)
	println('[*] Registered Types: i32 ID=${int32_t}')

	// 2. Create Function
	println('[*] Constructing SSA for function "add_values"...')
	fn_id := mod.new_function('add_values', int32_t, [int32_t, int32_t])

	// 3. Entry Block
	entry_blk := mod.add_block(fn_id, 'entry')

	// 4. Create Params (Use index=0 for now as they don't point to an instruction)
	p0 := mod.add_value_node(.argument, int32_t, 'a', 0)
	p1 := mod.add_value_node(.argument, int32_t, 'b', 0)

	mod.funcs[fn_id].params << p0
	mod.funcs[fn_id].params << p1

	// 5. ADD Instruction
	println('    Adding Instruction: ADD')
	sum_val := mod.add_instr(.add, entry_blk, int32_t, [p0, p1])

	// 6. RET Instruction
	println('    Adding Instruction: RET')
	mod.add_instr(.ret, entry_blk, 0, [sum_val])

	// 7. C Gen
	println('[*] Generating C Code...')
	mut c_gen := backend.CGen.new(mod)
	c_source := c_gen.gen()

	println('\n--- Generated Content ---\n')
	println(c_source)

	// 8. Write
	os.write_file('out.c', c_source) or { panic(err) }
}
