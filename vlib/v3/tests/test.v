struct Point {
mut:
	x int
	y int
}

struct Node {
mut:
	value int
	left  int
	right int
}

__global (
	g_val   int
	g_count int
	g_flag  bool
	g_point Point
)

// ===================== HELPER FUNCTIONS =====================

fn fib(n int) int {
	if n < 2 {
		return n
	}
	return fib(n - 1) + fib(n - 2)
}

fn factorial(n int) int {
	if n <= 1 {
		return 1
	}
	return n * factorial(n - 1)
}

fn sum_recursive(n int) int {
	if n <= 0 {
		return 0
	}
	return n + sum_recursive(n - 1)
}

fn gcd(a int, b int) int {
	if b == 0 {
		return a
	}
	return gcd(b, a % b)
}

fn power(base int, exp int) int {
	if exp == 0 {
		return 1
	}
	return base * power(base, exp - 1)
}

fn add(a int, b int) int {
	return a + b
}

fn sub(a int, b int) int {
	return a - b
}

fn mul(a int, b int) int {
	return a * b
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

// ===================== MAIN TEST FUNCTION =====================

fn main() {
	print_str('=== v3 Test Suite ===')

	// ==================== 1. STRUCT DECL & INIT (5 tests) ====================
	print_str('--- 1. Struct Declaration & Initialization ---')

	// 1.1 Basic struct init
	p1 := Point{
		x: 10
		y: 20
	}
	print_int(p1.x) // 10
	print_int(p1.y) // 20

	// 1.2 Default zero init
	p2 := Point{}
	print_int(p2.x) // 0
	print_int(p2.y) // 0

	// 1.3 Mutable struct modification
	mut p3 := Point{
		x: 1
		y: 2
	}
	p3.x = 100
	p3.y = 200
	print_int(p3.x) // 100
	print_int(p3.y) // 200

	// 1.4 Struct with computed values
	base := 7
	p4 := Point{
		x: base * 2
		y: base * 3
	}
	print_int(p4.x) // 14
	print_int(p4.y) // 21

	// 1.5 Multiple struct instances
	p5a := Point{
		x: 1
		y: 2
	}
	p5b := Point{
		x: 3
		y: 4
	}
	print_int(p5a.x + p5b.x) // 4
	print_int(p5a.y + p5b.y) // 6

	// ==================== 2. CALLS & SELECTOR ASSIGN (5 tests) ====================
	print_str('--- 2. Calls & Selector Assignment ---')

	// 2.1 Basic function call with selector assign
	mut pt := Point{
		x: 10
		y: 20
	}
	pt.x = add(pt.x, 5)
	print_int(pt.x) // 15

	// 2.2 Chained calls
	pt.y = add(add(pt.y, 10), 5)
	print_int(pt.y) // 35

	// 2.3 Call result to selector with subtraction
	pt.x = sub(pt.x, 3)
	print_int(pt.x) // 12

	// 2.4 Multiple selectors updated via calls
	mut pt2 := Point{
		x: 5
		y: 5
	}
	pt2.x = mul(pt2.x, 3)
	pt2.y = mul(pt2.y, 4)
	print_int(pt2.x) // 15
	print_int(pt2.y) // 20

	// 2.5 Nested function calls with selectors
	mut pt3 := Point{
		x: 10
		y: 20
	}
	pt3.x = add(mul(pt3.x, 2), 5) // 10*2 + 5 = 25
	pt3.y = sub(mul(pt3.y, 3), 10) // 20*3 - 10 = 50
	print_int(pt3.x) // 25
	print_int(pt3.y) // 50

	// ==================== 3. GLOBALS & COMPOUND ASSIGN (5 tests) ====================
	print_str('--- 3. Globals & Compound Assignment ---')

	// 3.1 Basic global assignment and compound add
	g_val = 50
	g_val += 50
	print_int(g_val) // 100

	// 3.2 Compound subtract
	g_val = 100
	g_val -= 30
	print_int(g_val) // 70

	// 3.3 Compound multiply
	g_val = 5
	g_val *= 6
	print_int(g_val) // 30

	// 3.4 Compound divide
	g_val = 100
	g_val /= 4
	print_int(g_val) // 25

	// 3.5 Global struct
	g_point.x = 42
	g_point.y = 84
	g_point.x += 8
	print_int(g_point.x) // 50
	print_int(g_point.y) // 84

	// ==================== 4. BOOL & LOGIC (5 tests) ====================
	print_str('--- 4. Bool & Logic ---')

	// 4.1 Basic bool true
	flag1 := true
	if flag1 {
		print_int(1)
	} else {
		print_int(0)
	}

	// 4.2 Basic bool false
	flag2 := false
	if flag2 {
		print_int(1)
	} else {
		print_int(0)
	}

	// 4.3 Bool from comparison
	cmp_val := 10
	flag3 := cmp_val > 5
	if flag3 {
		print_int(1)
	} else {
		print_int(0)
	}

	// 4.4 Logical AND
	a_bool := true
	b_bool := true
	if a_bool && b_bool {
		print_int(1)
	} else {
		print_int(0)
	}

	// 4.5 Logical OR and NOT
	c_bool := false
	d_bool := true
	if c_bool || d_bool {
		print_int(1) // 1
	} else {
		print_int(0)
	}
	if !c_bool {
		print_int(1) // 1
	} else {
		print_int(0)
	}

	// ==================== 5. LOOP WITH BREAK/CONTINUE (5 tests) ====================
	print_str('--- 5. Loop with Break/Continue ---')

	// 5.1 Basic continue (skip 5)
	mut sum1 := 0
	mut i1 := 0
	for i1 < 10 {
		i1++
		if i1 == 5 {
			continue
		}
		if i1 > 7 {
			break
		}
		sum1 += i1
	}
	print_int(sum1) // 1+2+3+4+6+7 = 23

	// 5.2 Multiple continues (skip even)
	mut sum2 := 0
	mut i2 := 0
	for i2 < 10 {
		i2++
		if i2 % 2 == 0 {
			continue
		}
		sum2 += i2
	}
	print_int(sum2) // 1+3+5+7+9 = 25

	// 5.3 Early break
	mut sum3 := 0
	mut i3 := 0
	for i3 < 100 {
		i3++
		if i3 > 5 {
			break
		}
		sum3 += i3
	}
	print_int(sum3) // 1+2+3+4+5 = 15

	// 5.4 Combined break and continue
	mut sum4 := 0
	mut i4 := 0
	for i4 < 20 {
		i4++
		if i4 % 3 == 0 {
			continue
		}
		if i4 > 10 {
			break
		}
		sum4 += i4
	}
	print_int(sum4) // 1+2+4+5+7+8+10 = 37

	// 5.5 Simple condition loop
	mut sum5 := 0
	mut i5 := 0
	for i5 < 5 {
		sum5 += i5
		i5++
	}
	print_int(sum5) // 0+1+2+3+4 = 10

	// ==================== 6. MATCH (5 tests) ====================
	print_str('--- 6. Match ---')

	// 6.1 Match with else
	x1 := 10
	match x1 {
		1 { print_int(1) }
		2 { print_int(2) }
		else { print_int(777) }
	}

	// 6.2 Match exact case
	x2 := 2
	match x2 {
		1 { print_int(100) }
		2 { print_int(200) }
		3 { print_int(300) }
		else { print_int(0) }
	}

	// 6.3 Match first case
	x3 := 1
	match x3 {
		1 { print_int(111) }
		2 { print_int(222) }
		else { print_int(999) }
	}

	// 6.4 Match with computation
	x4 := 5
	match x4 {
		1 { print_int(x4 * 10) }
		5 { print_int(x4 * 100) }
		else { print_int(0) }
	}

	// 6.5 Match with more cases
	x5 := 4
	match x5 {
		1 { print_int(10) }
		2 { print_int(20) }
		3 { print_int(30) }
		4 { print_int(40) }
		5 { print_int(50) }
		else { print_int(0) }
	}

	// ==================== 7. C-STYLE LOOP & FACTORIAL (5 tests) ====================
	print_str('--- 7. C-style Loop ---')

	// 7.1 Basic factorial
	mut fact1 := 1
	for k := 1; k <= 5; k++ {
		fact1 = fact1 * k
	}
	print_int(fact1) // 120

	// 7.2 Sum 1 to 10
	mut sum7 := 0
	for k := 1; k <= 10; k++ {
		sum7 += k
	}
	print_int(sum7) // 55

	// 7.3 Powers of 2
	mut pow2 := 1
	for k := 0; k < 8; k++ {
		pow2 = pow2 * 2
	}
	print_int(pow2) // 256

	// 7.4 Countdown
	mut countdown := 0
	for k := 10; k > 0; k-- {
		countdown += k
	}
	print_int(countdown) // 55

	// 7.5 Step by 2
	mut sum_even := 0
	for k := 0; k <= 10; k += 2 {
		sum_even += k
	}
	print_int(sum_even) // 0+2+4+6+8+10 = 30

	// ==================== 8. RECURSIVE FUNCTIONS (5 tests) ====================
	print_str('--- 8. Recursive Functions ---')

	// 8.1 Fibonacci
	print_int(fib(10)) // 55

	// 8.2 Factorial recursive
	print_int(factorial(6)) // 720

	// 8.3 Sum recursive
	print_int(sum_recursive(10)) // 55

	// 8.4 GCD
	print_int(gcd(48, 18)) // 6

	// 8.5 Power
	print_int(power(2, 10)) // 1024

	// ==================== 9. NESTED LOOPS (5 tests) ====================
	print_str('--- 9. Nested Loops ---')

	// 9.1 Basic 3x3
	mut count1 := 0
	mut r1 := 0
	for r1 < 3 {
		mut c1 := 0
		for c1 < 3 {
			count1++
			c1++
		}
		r1++
	}
	print_int(count1) // 9

	// 9.2 4x5 grid
	mut count2 := 0
	mut r2 := 0
	for r2 < 4 {
		mut c2 := 0
		for c2 < 5 {
			count2++
			c2++
		}
		r2++
	}
	print_int(count2) // 20

	// 9.3 Sum of products
	mut sum9 := 0
	mut r3 := 1
	for r3 <= 3 {
		mut c3 := 1
		for c3 <= 3 {
			sum9 += r3 * c3
			c3++
		}
		r3++
	}
	print_int(sum9) // (1+2+3) + (2+4+6) + (3+6+9) = 36

	// 9.4 2x3 with accumulator
	mut count4 := 0
	mut r4 := 0
	for r4 < 2 {
		mut c4 := 0
		for c4 < 3 {
			count4 += 1
			c4++
		}
		r4++
	}
	print_int(count4) // 6

	// 9.5 Inner break
	mut count5 := 0
	mut r5 := 0
	for r5 < 5 {
		mut c5 := 0
		for c5 < 10 {
			if c5 >= 3 {
				break
			}
			count5++
			c5++
		}
		r5++
	}
	print_int(count5) // 5*3 = 15

	// ==================== 10. INFINITE LOOP (5 tests) ====================
	print_str('--- 10. Infinite Loop ---')

	// 10.1 Basic infinite with break
	mut iter1 := 0
	for {
		iter1++
		if iter1 == 5 {
			break
		}
	}
	print_int(iter1) // 5

	// 10.2 Sum until threshold
	mut sum10 := 0
	mut n10 := 0
	for {
		n10++
		sum10 += n10
		if sum10 > 20 {
			break
		}
	}
	print_int(sum10) // 21 (1+2+3+4+5+6 = 21)

	// 10.3 Find first power of 2 > 100
	mut pow := 1
	for {
		pow = pow * 2
		if pow > 100 {
			break
		}
	}
	print_int(pow) // 128

	// 10.4 Countdown in infinite loop
	mut cd := 10
	for {
		cd--
		if cd == 0 {
			break
		}
	}
	print_int(cd) // 0

	// 10.5 Simple counter
	mut x10 := 0
	for {
		x10++
		if x10 >= 10 {
			break
		}
	}
	print_int(x10) // 10

	print_str('=== ALL 10 TESTS PASSED ===')
}
