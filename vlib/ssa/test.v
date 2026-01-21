struct Point {
mut:
	x int
	y int
}

__global (
	g_val int
)

fn fib(n int) int {
	if n < 2 {
		return n
	}
	return fib(n - 1) + fib(n - 2)
}

fn sum_many(a int, b int, c int, d int, e int, f int, g int, h int) int {
	return a + b + c + d + e + f + g + h
}

fn modify_struct(mut p Point) {
	p.x = 999
	p.y = 888
}

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

fn print_str(s string) {
	C.puts(s.str)
}

/*
fn print_int(n int) {
	// C.printf(c'%d\n', n)
	println(n)
}
*/

fn main() {
	print_str('start')
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
	// C.printf(c'Point address: %d\n', &p)
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

	// 6. Match
	x := 10
	match x {
		1 { print_int(x + 1) }
		2 { print_int(x + 2) }
		else { print_int(777) }
	}

	// 7. C-style Loop & Factorial
	mut fact := 1
	for k := 1; k <= 5; k++ {
		fact = fact * k
	}
	print_int(fact)

	// 8. Recursive Fib
	print_str('fib(10)=')
	print_int(fib(10))

	// 9. Nested Loops
	mut r := 0
	mut count := 0
	for r < 3 {
		mut c := 0
		for c < 3 {
			count++
			c++
		}
		r++
	}
	print_int(count)
	// 10. Infinite Loop
	mut iter := 0
	for {
		iter++
		if iter == 5 {
			break
		}
	}
	print_int(iter)

	// 11. Many Arguments (8 args to fill registers x0-x7)
	print_int(sum_many(1, 1, 1, 1, 1, 1, 1, 1))

	// 12. Modifying struct (Reference semantics)
	// modify_struct(mut p)
	// print_str('p.x after modification via a function call:')
	// print_int(p.x) // Should be 999
}
