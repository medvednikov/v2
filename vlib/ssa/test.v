fn add(a int, b int) int {
	res := a + b
	return res
}

fn main() {
	x := 10
	if x > 10 {
		b := 20
	} else {
		b := 21
	}
	y := 20
	z := add(x, y)
	return z
}
