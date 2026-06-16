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

fn int_str(n int) string {
	mut buf := &u8(C.malloc(20))
	mut val := n
	mut is_neg := false
	if val < 0 {
		is_neg = true
		val = -val
	}
	mut i := 19
	if val == 0 {
		i--
		unsafe {
			buf[i] = `0`
		}
	} else {
		for val > 0 {
			i--
			unsafe {
				buf[i] = u8(val % 10) + `0`
			}
			val = val / 10
		}
	}
	if is_neg {
		i--
		unsafe {
			buf[i] = `-`
		}
	}
	slen := 20 - i
	dst := &u8(C.malloc(slen))
	C.memcpy(dst, unsafe { buf + i }, slen)
	C.free(buf)
	return string{
		str: dst
		len: slen
	}
}

fn string__plus(a string, b string) string {
	new_len := a.len + b.len
	dst := &u8(C.malloc(new_len))
	C.memcpy(dst, a.str, a.len)
	C.memcpy(unsafe { dst + a.len }, b.str, b.len)
	return string{
		str: dst
		len: new_len
	}
}

fn string_plus_many(n int, parts &string) string {
	mut total := 0
	mut i := 0
	for i < n {
		total = total + unsafe { parts[i] }.len
		i++
	}
	dst := &u8(C.malloc(total))
	mut offset := 0
	i = 0
	for i < n {
		s := unsafe { parts[i] }
		C.memcpy(unsafe { dst + offset }, s.str, s.len)
		offset = offset + s.len
		i++
	}
	return string{
		str: dst
		len: total
	}
}
