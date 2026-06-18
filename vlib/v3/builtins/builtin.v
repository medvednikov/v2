module builtin

struct array {
mut:
	data      voidptr
	len       int
	cap       int
	elem_size int
}

fn print(s string) {
	C.write(1, s.str, s.len)
}

fn println(s string) {
	C.write(1, s.str, s.len)
	C.putchar(10)
}

fn eprint(s string) {
	C.write(2, s.str, s.len)
}

fn eprintln(s string) {
	C.write(2, s.str, s.len)
	C.write(2, '\n', 1)
}

fn exit(code int) {
	C.exit(code)
	for {}
}

fn arguments() []string {
	return []string{}
}

fn array_new(elem_size int, len int, cap int) array {
	mut actual_cap := cap
	if actual_cap <= len {
		if len > 0 {
			actual_cap = len
		} else {
			actual_cap = 4
		}
	}
	return array{
		data:      C.calloc(actual_cap, elem_size)
		len:       len
		cap:       actual_cap
		elem_size: elem_size
	}
}

fn array_reserve(a &array, needed int) {
	if needed <= a.cap {
		return
	}
	mut new_cap := needed * 2
	if new_cap < 4 {
		new_cap = 4
	}
	a.data = C.realloc(a.data, new_cap * a.elem_size)
	a.cap = new_cap
}

fn array_push(a &array, elem voidptr) {
	array_reserve(a, a.len + 1)
	C.memcpy(unsafe { &u8(a.data) + a.len * a.elem_size }, elem, a.elem_size)
	a.len++
}

fn array_push_many(a &array, b array) {
	new_len := a.len + b.len
	array_reserve(a, new_len)
	C.memcpy(unsafe { &u8(a.data) + a.len * a.elem_size }, b.data, b.len * a.elem_size)
	a.len = new_len
}

fn array_push_many_ptr(a &array, ptr voidptr, len int) {
	new_len := a.len + len
	array_reserve(a, new_len)
	C.memcpy(unsafe { &u8(a.data) + a.len * a.elem_size }, ptr, len * a.elem_size)
	a.len = new_len
}

fn array_get(a array, idx int) voidptr {
	return unsafe { &u8(a.data) + idx * a.elem_size }
}

fn array_set(a array, idx int, val voidptr) {
	C.memcpy(unsafe { &u8(a.data) + idx * a.elem_size }, val, a.elem_size)
}

fn array_clone(a array) array {
	mut b := array_new(a.elem_size, a.len, a.cap)
	C.memcpy(b.data, a.data, a.len * a.elem_size)
	return b
}

fn array_slice(a array, start int, end int) array {
	mut slen := end - start
	if slen < 0 {
		slen = 0
	}
	mut b := array_new(a.elem_size, slen, slen)
	if slen > 0 {
		C.memcpy(b.data, unsafe { &u8(a.data) + start * a.elem_size }, slen * a.elem_size)
	}
	return b
}

fn bool_str(b bool) string {
	if b {
		return 'true'
	}
	return 'false'
}

fn strconv__format_int(n i64, radix int) string {
	if radix != 10 {
		return int_str(int(n))
	}
	return int_str(int(n))
}

fn strconv__format_uint(n u64, radix int) string {
	if radix != 10 {
		return int_str(int(n))
	}
	return int_str(int(n))
}

fn strconv__f32_to_str_l(n f32) string {
	return int_str(int(n))
}

fn strconv__f64_to_str_l(n f64) string {
	return int_str(int(n))
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

fn string__eq(a string, b string) bool {
	if a.len != b.len {
		return false
	}
	return C.memcmp(a.str, b.str, a.len) == 0
}

fn string__substr(s string, start int, end int) string {
	slen := end - start
	if slen <= 0 {
		return ''
	}
	dst := &u8(C.malloc(slen))
	C.memcpy(dst, unsafe { s.str + start }, slen)
	return string{
		str: dst
		len: slen
	}
}

fn string__index_plain(s string, sub string) int {
	if sub.len > s.len {
		return -1
	}
	mut i := 0
	for i <= s.len - sub.len {
		if C.memcmp(unsafe { s.str + i }, sub.str, sub.len) == 0 {
			return i
		}
		i++
	}
	return -1
}

fn string__last_index_plain(s string, sub string) int {
	if sub.len > s.len {
		return -1
	}
	mut i := s.len - sub.len
	for i >= 0 {
		if C.memcmp(unsafe { s.str + i }, sub.str, sub.len) == 0 {
			return i
		}
		i--
	}
	return -1
}

fn string__all_before(s string, sub string) string {
	idx := string__index_plain(s, sub)
	if idx < 0 {
		return s
	}
	return string__substr(s, 0, idx)
}

fn string__all_before_last(s string, sub string) string {
	idx := string__last_index_plain(s, sub)
	if idx < 0 {
		return s
	}
	return string__substr(s, 0, idx)
}

fn string__all_after(s string, sub string) string {
	idx := string__index_plain(s, sub)
	if idx < 0 {
		return s
	}
	return string__substr(s, idx + sub.len, s.len)
}

fn string__all_after_last(s string, sub string) string {
	idx := string__last_index_plain(s, sub)
	if idx < 0 {
		return s
	}
	return string__substr(s, idx + sub.len, s.len)
}

fn (s string) all_before(sub string) string {
	return string__all_before(s, sub)
}

fn (s string) all_before_last(sub string) string {
	return string__all_before_last(s, sub)
}

fn (s string) all_after(sub string) string {
	return string__all_after(s, sub)
}

fn (s string) all_after_last(sub string) string {
	return string__all_after_last(s, sub)
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
