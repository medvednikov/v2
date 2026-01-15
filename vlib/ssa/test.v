struct Point {
mut:
	x int
	y int
}

__global (
	g_val int
)

// Helper function to test calls
fn add(a int, b int) int {
	return a + b
}

fn print_rec(n int) {
	if n == 0 {
		return
	}
	print_rec(n / 10)
	rem := n - (n / 10) * 10
	C.putchar(rem + 48)
}

fn print_int(n int) {
	if n == 0 {
		C.putchar(48)
		C.putchar(10)
		return
	}
	mut v := n
	if n < 0 {
		C.putchar(45)
		v = 0 - n
	}
	print_rec(v)
	C.putchar(10)
}

/*
fn print_int(n int) {
	// C.printf(c'%d\n', n)
	println(n)
}
*/

fn main() {
	mut j := 0
	for j < 10 {
		C.printf(c'HI\n')
		j++
	}
	if 4 < 10 {
		C.printf(c'HELLO\n')
	} else {
		C.printf(c'NOT\n')
	}
	print_int(1111)

	// 1. Struct Decl & Init
	mut p := Point{
		x: 10
		y: 20
	}
	print_int(p.x)
	print_int(p.y)

	// 2. Calls & Selector Assign
	p.x = add(p.x, 5) // 10 + 5 = 15
	print_int(p.x)

	// 3. Globals & Compound Assign
	C.puts(c'global:')
	g_val = 50
	g_val += 50
	print_int(g_val) // 100

	// 4. Bool & Logic
	flag := true
	if flag {
		print_int(1)
	} else {
		print_int(0)
	}

	// 5. Loop with Break/Continue
	mut i := 0
	mut sum := 0
	for i < 10 {
		i++
		if i == 5 {
			continue
		}
		if i > 7 {
			break
		}
		sum += i
		// Printed sequence of added numbers: 1, 2, 3, 4, 6, 7
	}
	print_int(sum) // 1+2+3+4+6+7 = 23
}
