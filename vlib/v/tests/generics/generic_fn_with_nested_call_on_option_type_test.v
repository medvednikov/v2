// Test for generic function that internally calls another generic function
// when the type parameter is instantiated to an option type.
// This tests that g.styp() correctly unwraps generic types before
// checking option flags.

fn get_type_name[T](val T) string {
	return typeof(val).name
}

// Generic function that calls another generic function internally
fn wrapper[T](val T) string {
	// When T is ?Data, this inner call must also resolve T to ?Data
	return get_type_name(val)
}

struct Data {
	value int
}

fn get_optional_data() ?Data {
	return Data{value: 100}
}

fn test_generic_fn_with_nested_call_resolves_option_type() {
	// Direct call with option type
	opt := get_optional_data()
	assert get_type_name(opt) == '?Data'

	// Nested call through wrapper - T should resolve to ?Data
	// in both the wrapper and the inner get_type_name call
	result := wrapper(opt)
	assert result == '?Data'
}

fn test_generic_fn_nested_call_with_various_option_types() {
	// Test with option int
	opt_int := ?int(42)
	assert wrapper(opt_int) == '?int'

	// Test with option string
	opt_str := ?string('hello')
	assert wrapper(opt_str) == '?string'

	// Test with none
	none_val := ?Data(none)
	assert wrapper(none_val) == '?Data'

	// Test with non-option types still work
	assert wrapper(123) == 'int'
	assert wrapper('test') == 'string'
	assert wrapper(Data{value: 1}) == 'Data'
}

// Test with embedded struct calling generic method that has nested generic call
struct Inner {
}

fn (i Inner) transform[T](val T) string {
	return get_type_name(val)
}

struct Outer {
	Inner
}

fn test_embed_with_nested_generic_call_on_option() {
	o := Outer{}

	opt_data := get_optional_data()
	result := o.transform(opt_data)
	assert result == '?Data'

	opt_int := ?int(99)
	assert o.transform(opt_int) == '?int'
}
