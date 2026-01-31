// Test for issue #15971: Assigning C.var to var with same name
// should not cause compiler bug when name conflicts with C macros like errno.

#include <errno.h>

fn test_c_errno_assign_to_same_name() {
	// This should not cause a C compilation error.
	// The V variable 'errno' should be renamed to '__v_errno' in generated C code
	// to avoid conflict with the C errno macro.
	errno := C.errno
	assert errno >= 0 || errno < 0 // errno can be any value, just verify it compiles
}

fn test_c_errno_assign_to_different_name() {
	// This should work as expected
	my_errno := C.errno
	assert my_errno >= 0 || my_errno < 0
}
