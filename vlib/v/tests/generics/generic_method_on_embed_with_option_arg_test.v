// Test for generic method defined on an embedded struct
// when called with an option type argument.
// This tests that generic type resolution works correctly
// for methods found through struct embedding.

struct Base {
}

fn (b Base) process[T](val T) string {
	return typeof(val).name
}

struct Container {
	Base
}

struct Data {
	id int
}

fn get_data() ?Data {
	return Data{id: 42}
}

fn test_generic_method_on_embed_with_option_arg() {
	c := Container{}

	// Test with non-option type
	data := Data{id: 1}
	assert c.process(data) == 'Data'

	// Test with option type - this is the key test case
	// The generic method is on Base (embedded), called through Container,
	// with an option type argument
	opt_data := get_data()
	result := c.process(opt_data)
	assert result == '?Data'
}

fn test_generic_method_on_embed_with_various_types() {
	c := Container{}

	// Test with primitive types
	assert c.process(123) == 'int'
	assert c.process('hello') == 'string'

	// Test with option primitive
	opt_int := ?int(42)
	assert c.process(opt_int) == '?int'

	// Test with none
	none_val := ?int(none)
	assert c.process(none_val) == '?int'
}
