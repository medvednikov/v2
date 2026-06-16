module builtin

fn print(s string) {
	C.write(1, s.str, s.len)
}

fn println(s string) {
	C.write(1, s.str, s.len)
	nl := '\n'
	C.write(1, nl.str, nl.len)
}

fn memdup(src &u8, len int) &u8 {
	dst := C.malloc(len)
	C.memcpy(dst, src, len)
	return dst
}
