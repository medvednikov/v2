module builtin

struct array {
mut:
	data      voidptr
	len       int
	cap       int
	elem_size int
}

struct Map {
mut:
	keys     voidptr
	vals     voidptr
	cap      int
	len      int
	key_size int
	val_size int
}

struct IError {
	message string
	code    int
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

fn new_map(key_size int, val_size int, _hash_fn voidptr, _eq_fn voidptr, _clone_fn voidptr, _free_fn voidptr) Map {
	cap := 16
	return Map{
		keys:     C.calloc(cap, key_size)
		vals:     C.calloc(cap, val_size)
		cap:      cap
		len:      0
		key_size: key_size
		val_size: val_size
	}
}

fn map_key_ptr(m &Map, idx int) voidptr {
	return unsafe { &u8(m.keys) + idx * m.key_size }
}

fn map_val_ptr(m &Map, idx int) voidptr {
	return unsafe { &u8(m.vals) + idx * m.val_size }
}

fn map_find(m &Map, key voidptr) int {
	mut i := 0
	for i < m.len {
		if C.memcmp(map_key_ptr(m, i), key, m.key_size) == 0 {
			return i
		}
		i++
	}
	return -1
}

fn map_reserve(m &Map, needed int) {
	if needed <= m.cap {
		return
	}
	mut new_cap := needed * 2
	if new_cap < 16 {
		new_cap = 16
	}
	m.keys = C.realloc(m.keys, new_cap * m.key_size)
	m.vals = C.realloc(m.vals, new_cap * m.val_size)
	m.cap = new_cap
}

fn map__set(m &Map, key voidptr, val voidptr) {
	idx := map_find(m, key)
	if idx >= 0 {
		C.memcpy(map_val_ptr(m, idx), val, m.val_size)
		return
	}
	map_reserve(m, m.len + 1)
	C.memcpy(map_key_ptr(m, m.len), key, m.key_size)
	C.memcpy(map_val_ptr(m, m.len), val, m.val_size)
	m.len++
}

fn map__get(m &Map, key voidptr, zero voidptr) voidptr {
	idx := map_find(m, key)
	if idx >= 0 {
		return map_val_ptr(m, idx)
	}
	return zero
}

fn map__get_check(m &Map, key voidptr) voidptr {
	idx := map_find(m, key)
	if idx >= 0 {
		return map_val_ptr(m, idx)
	}
	return unsafe { nil }
}

fn map__get_or_set(m &Map, key voidptr, zero voidptr) voidptr {
	found := map__get_check(m, key)
	if found != unsafe { nil } {
		return found
	}
	map__set(m, key, zero)
	return map__get(m, key, zero)
}

fn map__exists(m &Map, key voidptr) bool {
	return map_find(m, key) >= 0
}

fn map__delete(m &Map, key voidptr) {
	idx := map_find(m, key)
	if idx < 0 {
		return
	}
	tail := m.len - idx - 1
	if tail > 0 {
		C.memmove(map_key_ptr(m, idx), map_key_ptr(m, idx + 1), tail * m.key_size)
		C.memmove(map_val_ptr(m, idx), map_val_ptr(m, idx + 1), tail * m.val_size)
	}
	m.len--
}

fn map__clone(m &Map) Map {
	mut n := new_map(m.key_size, m.val_size, unsafe { nil }, unsafe { nil }, unsafe { nil },
		unsafe { nil })
	map_reserve(&n, m.len)
	n.len = m.len
	C.memcpy(n.keys, m.keys, m.len * m.key_size)
	C.memcpy(n.vals, m.vals, m.len * m.val_size)
	return n
}

fn map__clear(m &Map) {
	m.len = 0
}

fn strings__new_builder(initial_size int) array {
	cap := if initial_size > 0 { initial_size } else { 64 }
	return array_new(1, 0, cap)
}

fn strings__Builder__write_ptr(b &array, ptr voidptr, len int) {
	if len <= 0 {
		return
	}
	array_push_many_ptr(b, ptr, len)
}

fn strings__Builder__write_string(b &array, s string) {
	strings__Builder__write_ptr(b, s.str, s.len)
}

fn strings__Builder__writeln(b &array, s string) {
	strings__Builder__write_string(b, s)
	lf := u8(10)
	array_push(b, lf)
}

fn strings__Builder__write_u8(b &array, data u8) {
	array_push(b, data)
}

fn strings__Builder__write_runes(_b &array, _runes array) {
}

fn strings__Builder__free(b &array) {
	if b.data != unsafe { nil } {
		C.free(b.data)
	}
	b.data = unsafe { nil }
	b.len = 0
	b.cap = 0
}

fn strings__Builder__spart(b &array, start_pos int, n int) string {
	mut start := start_pos
	if start < 0 {
		start = 0
	}
	mut len := n
	if len < 0 {
		len = 0
	}
	if start > b.len {
		start = b.len
	}
	if start + len > b.len {
		len = b.len - start
	}
	dst := &u8(C.malloc(len))
	if len > 0 {
		C.memcpy(dst, unsafe { &u8(b.data) + start }, len)
	}
	return string{
		str: dst
		len: len
	}
}

fn strings__Builder__last_n(b &array, n int) string {
	if n > b.len {
		return ''
	}
	return strings__Builder__spart(b, b.len - n, n)
}

fn strings__Builder__str(b &array) string {
	return strings__Builder__spart(b, 0, b.len)
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

fn malloc_noscan(len int) voidptr {
	return C.malloc(len)
}

fn isnil(p voidptr) bool {
	return p == unsafe { nil }
}

fn error(message string) IError {
	return IError{
		message: message
		code:    0
	}
}

fn error_with_code(message string, code int) IError {
	return IError{
		message: message
		code:    code
	}
}

fn (err &IError) msg() string {
	return err.message
}

fn (err &IError) code() int {
	return err.code
}

fn tos(s &u8, len int) string {
	return string{
		str: s
		len: len
	}
}

fn tos3(s &u8) string {
	return tos(s, int(C.strlen(s)))
}

fn tos_clone(s &u8) string {
	len := int(C.strlen(s))
	dst := &u8(C.malloc(len))
	C.memcpy(dst, s, len)
	return string{
		str: dst
		len: len
	}
}

fn cstring_to_vstring(s &u8) string {
	return tos_clone(s)
}

fn u8__vstring(s &u8) string {
	return tos(s, int(C.strlen(s)))
}

fn u8__vstring_with_len(s &u8, len int) string {
	return tos(s, len)
}

fn (bp &u8) vstring() string {
	return u8__vstring(bp)
}

fn (bp &u8) vstring_with_len(len int) string {
	return u8__vstring_with_len(bp, len)
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

fn string__byte_at_eq(s string, idx int, c u8) bool {
	return C.memcmp(unsafe { s.str + idx }, c, 1) == 0
}

fn string__is_space_at(s string, idx int) bool {
	return string__byte_at_eq(s, idx, u8(32)) || string__byte_at_eq(s, idx, u8(9))
		|| string__byte_at_eq(s, idx, u8(10)) || string__byte_at_eq(s, idx, u8(13))
}

fn string__trim_left(s string, _cutset string) string {
	mut i := 0
	for i < s.len && string__is_space_at(s, i) {
		i++
	}
	return string__substr(s, i, s.len)
}

fn string__trim_right(s string, _cutset string) string {
	mut i := s.len - 1
	for i >= 0 && string__is_space_at(s, i) {
		i--
	}
	return string__substr(s, 0, i + 1)
}

fn string__trim_space(s string) string {
	return string__trim_right(string__trim_left(s, ''), '')
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

fn (s string) trim_left(cutset string) string {
	return string__trim_left(s, cutset)
}

fn (s string) trim_right(cutset string) string {
	return string__trim_right(s, cutset)
}

fn (s string) trim_space() string {
	return string__trim_space(s)
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
