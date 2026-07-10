// Regression test for https://github.com/vlang/v/issues/23461:
// interpolating a reference to a non-integer variable used to emit a C error.
//
// The default format of a reference is now consistent across every form -
// a local pointer variable (`${p}`), an inline address (`${&x}`), an explicit
// `${p:s}` and a reference passed as an argument all produce the pointee's
// value prefixed with `&`, matching `println` and `.str()`. Previously only
// `&string`/`&bool` locals fell back to printing a raw (non-deterministic)
// pointer address, unlike `&rune`/`&f32`/etc.

fn str_arg(p &string) string {
	return '${p}'
}

fn bool_arg(p &bool) string {
	return '${p}'
}

fn test_string_reference_default_fmt() {
	s := 'Hello'
	sp := &s
	assert '${sp}' == '&Hello'
	assert '${&s}' == '&Hello'
	assert '${sp:s}' == '&Hello'
	assert str_arg(&s) == '&Hello'
}

fn test_bool_reference_default_fmt() {
	b := true
	bp := &b
	assert '${bp}' == '&true'
	assert '${&b}' == '&true'
	assert bool_arg(&b) == '&true'
}

fn test_rune_and_float_reference_default_fmt() {
	r := `A`
	rp := &r
	assert '${rp}' == '&A'
	f := f32(1.5)
	fp := &f
	assert '${fp}' == '&1.5'
}

fn test_int_reference_default_fmt() {
	// integers keep printing the pointee value itself, see
	// https://github.com/vlang/v/issues/15405
	i := 5
	ip := &i
	assert '${ip}' == '5'
}
