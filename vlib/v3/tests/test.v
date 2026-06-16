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

struct Rectangle {
mut:
	width  int
	height int
	origin Point
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

fn sum_many(a int, b int, c int, d int, e int, f int, g int, h int) int {
	return a + b + c + d + e + f + g + h
}

fn mul_many(a int, b int, c int, d int, e int, f int, g int, h int) int {
	return a * b * c * d * e * f * g * h
}

fn max_of_eight(a int, b int, c int, d int, e int, f int, g int, h int) int {
	mut m := a
	if b > m {
		m = b
	}
	if c > m {
		m = c
	}
	if d > m {
		m = d
	}
	if e > m {
		m = e
	}
	if f > m {
		m = f
	}
	if g > m {
		m = g
	}
	if h > m {
		m = h
	}
	return m
}

fn weighted_sum(a int, b int, c int, d int, e int, f int, g int, h int) int {
	return a * 1 + b * 2 + c * 3 + d * 4 + e * 5 + f * 6 + g * 7 + h * 8
}

struct Color {
mut:
	r int
	g int
	b int
	a int
}

fn make_point(px int, py int) Point {
	return Point{
		x: px
		y: py
	}
}

fn add_points(a Point, b Point) Point {
	return Point{
		x: a.x + b.x
		y: a.y + b.y
	}
}

fn abs_val(n int) int {
	if n < 0 {
		return 0 - n
	}
	return n
}

fn min_val(a int, b int) int {
	if a < b {
		return a
	}
	return b
}

fn max_val(a int, b int) int {
	if a > b {
		return a
	}
	return b
}

fn clamp(val int, lo int, hi int) int {
	if val < lo {
		return lo
	}
	if val > hi {
		return hi
	}
	return val
}

fn collatz_steps(start int) int {
	mut v := start
	mut steps := 0
	for v != 1 {
		if v % 2 == 0 {
			v = v / 2
		} else {
			v = v * 3 + 1
		}
		steps++
	}
	return steps
}

fn sum_digits(n int) int {
	mut v := n
	if v < 0 {
		v = 0 - v
	}
	mut s := 0
	for v > 0 {
		s += v % 10
		v = v / 10
	}
	return s
}

fn count_bits(n int) int {
	mut v := n
	mut count := 0
	for v != 0 {
		count += v & 1
		v = v >> 1
	}
	return count
}

fn classify(n int) int {
	if n > 100 {
		return 3
	} else if n > 50 {
		return 2
	} else if n > 0 {
		return 1
	} else {
		return 0
	}
}

fn point_quadrant(p Point) int {
	if p.x > 0 && p.y > 0 {
		return 1
	} else if p.x < 0 && p.y > 0 {
		return 2
	} else if p.x < 0 && p.y < 0 {
		return 3
	} else if p.x > 0 && p.y < 0 {
		return 4
	} else {
		return 0
	}
}

fn make_color(r int, g int, b int, a int) Color {
	return Color{
		r: r
		g: g
		b: b
		a: a
	}
}

fn color_brightness(c Color) int {
	return (c.r + c.g + c.b) / 3
}

fn scale_rect(mut r Rectangle, factor int) {
	r.width = r.width * factor
	r.height = r.height * factor
}

fn modify_struct(mut p Point) {
	p.x = 999
	p.y = 888
}

fn swap_point(mut p Point) {
	tmp := p.x
	p.x = p.y
	p.y = tmp
}

fn scale_point(mut p Point, factor int) {
	p.x = p.x * factor
	p.y = p.y * factor
}

fn translate_point(mut p Point, dx int, dy int) {
	p.x = p.x + dx
	p.y = p.y + dy
}

fn reset_point(mut p Point) {
	p.x = 0
	p.y = 0
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

	// ==================== 11. MANY ARGUMENTS (5 tests) ====================
	print_str('--- 11. Many Arguments ---')

	// 11.1 Sum of 8 ones
	print_int(sum_many(1, 1, 1, 1, 1, 1, 1, 1)) // 8

	// 11.2 Sum of sequence
	print_int(sum_many(1, 2, 3, 4, 5, 6, 7, 8)) // 36

	// 11.3 Product of small numbers
	print_int(mul_many(1, 2, 1, 2, 1, 2, 1, 2)) // 16

	// 11.4 Max of 8
	print_int(max_of_eight(3, 7, 2, 9, 1, 8, 4, 6)) // 9

	// 11.5 Weighted sum
	print_int(weighted_sum(1, 1, 1, 1, 1, 1, 1, 1)) // 1+2+3+4+5+6+7+8 = 36

	// ==================== 12. MODIFYING STRUCT (5 tests) ====================
	print_str('--- 12. Modifying Struct via Function ---')

	// 12.1 Basic modify
	mut pm1 := Point{
		x: 10
		y: 20
	}
	modify_struct(mut pm1)
	print_int(pm1.x) // 999
	print_int(pm1.y) // 888

	// 12.2 Swap
	mut pm2 := Point{
		x: 5
		y: 15
	}
	swap_point(mut pm2)
	print_int(pm2.x) // 15
	print_int(pm2.y) // 5

	// 12.3 Scale
	mut pm3 := Point{
		x: 10
		y: 20
	}
	scale_point(mut pm3, 3)
	print_int(pm3.x) // 30
	print_int(pm3.y) // 60

	// 12.4 Translate
	mut pm4 := Point{
		x: 5
		y: 10
	}
	translate_point(mut pm4, 100, 200)
	print_int(pm4.x) // 105
	print_int(pm4.y) // 210

	// 12.5 Reset
	mut pm5 := Point{
		x: 999
		y: 888
	}
	reset_point(mut pm5)
	print_int(pm5.x) // 0
	print_int(pm5.y) // 0

	// ==================== 13. ASSERT (5 tests) ====================
	print_str('--- 13. Assert ---')

	// 13.1 Basic equality
	assert 1 == 1
	print_str('Assert 1 passed')

	// 13.2 Computed equality
	assert 2 + 2 == 4
	print_str('Assert 2 passed')

	// 13.3 Boolean assert
	assert true
	print_str('Assert 3 passed')

	// 13.4 Comparison assert
	assert 10 > 5
	print_str('Assert 4 passed')

	// 13.5 Complex expression
	assert (3 * 4) == (2 * 6)
	print_str('Assert 5 passed')

	// ==================== 14. HEAP ALLOCATION (5 tests) ====================
	print_str('--- 14. Heap Allocation ---')

	// 14.1 Basic heap Point
	hp1 := &Point{
		x: 10
		y: 20
	}
	print_int(hp1.x) // 10
	print_int(hp1.y) // 20

	// 14.2 Heap with zero
	hp2 := &Point{
		x: 0
		y: 0
	}
	print_int(hp2.x) // 0
	print_int(hp2.y) // 0

	// 14.3 Heap with computed values
	hp3 := &Point{
		x: 5 * 5
		y: 6 * 6
	}
	print_int(hp3.x) // 25
	print_int(hp3.y) // 36

	// 14.4 Heap Rectangle
	hr := &Rectangle{
		width:  100
		height: 200
		origin: Point{
			x: 10
			y: 20
		}
	}
	print_int(hr.width) // 100
	print_int(hr.height) // 200

	// 14.5 Heap Node
	hn := &Node{
		value: 42
		left:  1
		right: 2
	}
	print_int(hn.value) // 42
	print_int(hn.left) // 1
	print_int(hn.right) // 2

	// ==================== 15. BITWISE OPERATIONS (5 tests) ====================
	print_str('--- 15. Bitwise Operations ---')

	// 15.1 Basic AND
	print_int(0b1100 & 0b1010) // 8

	// 15.2 Basic OR
	print_int(0b1100 | 0b1010) // 14

	// 15.3 Basic XOR
	print_int(0b1100 ^ 0b1010) // 6

	// 15.4 Mask extraction
	num := 0xABCD
	low_byte := num & 0xFF
	print_int(low_byte) // 0xCD = 205

	// 15.5 Bit set/clear
	mut flags := 0
	flags = flags | 0b0001 // set bit 0
	flags = flags | 0b0100 // set bit 2
	print_int(flags) // 5
	flags = flags & 0b1110 // clear bit 0
	print_int(flags) // 4

	// ==================== 16. SHIFT OPERATIONS (5 tests) ====================
	print_str('--- 16. Shift Operations ---')

	// 16.1 Left shift basic
	print_int(1 << 4) // 16

	// 16.2 Right shift basic
	print_int(32 >> 2) // 8

	// 16.3 Multiple shifts
	print_int(255 >> 4) // 15

	// 16.4 Shift for multiply
	val16 := 7
	print_int(val16 << 3) // 7 * 8 = 56

	// 16.5 Shift for divide
	val17 := 96
	print_int(val17 >> 4) // 96 / 16 = 6

	// ==================== 17. MODULO (5 tests) ====================
	print_str('--- 17. Modulo ---')

	// 17.1 Basic modulo
	print_int(17 % 5) // 2

	// 17.2 Modulo with larger divisor
	print_int(100 % 7) // 2

	// 17.3 Even/odd check
	print_int(15 % 2) // 1 (odd)
	print_int(16 % 2) // 0 (even)

	// 17.4 Clock arithmetic
	hour := 23
	new_hour := (hour + 5) % 24
	print_int(new_hour) // 4

	// 17.5 Digit extraction
	num17 := 12345
	last_digit := num17 % 10
	print_int(last_digit) // 5
	second_digit := (num17 / 10) % 10
	print_int(second_digit) // 4

	// ==================== 18. POINTER ARITHMETIC (5 tests) ====================
	print_str('--- 18. Pointer Arithmetic ---')

	// 18.1 Heap struct access
	hp_arr1 := &Point{
		x: 10
		y: 20
	}
	print_int(hp_arr1.x) // 10
	print_int(hp_arr1.y) // 20

	// 18.2 Multiple heap structs
	hp_arr2 := &Point{
		x: 100
		y: 200
	}
	hp_arr3 := &Point{
		x: 300
		y: 400
	}
	print_int(hp_arr2.x + hp_arr3.x) // 400
	print_int(hp_arr2.y + hp_arr3.y) // 600

	// 18.3 Heap struct with computed values
	base18 := 5
	hp_arr4 := &Point{
		x: base18 * 10
		y: base18 * 20
	}
	print_int(hp_arr4.x) // 50
	print_int(hp_arr4.y) // 100

	// 18.4 Multiple heap allocations in loop
	mut sum18 := 0
	mut i18 := 0
	for i18 < 3 {
		hp := &Point{
			x: i18 * 10
			y: i18 * 20
		}
		sum18 = sum18 + hp.x + hp.y
		i18++
	}
	print_int(sum18) // 0+0 + 10+20 + 20+40 = 90

	// 18.5 Heap node tree structure
	node1 := &Node{
		value: 100
		left:  0
		right: 0
	}
	node2 := &Node{
		value: 200
		left:  0
		right: 0
	}
	print_int(node1.value + node2.value) // 300

	// ==================== 19. NESTED STRUCT ACCESS (5 tests) ====================
	print_str('--- 19. Nested Struct Access ---')

	// 19.1 Basic nested access
	rect := Rectangle{
		width:  100
		height: 200
		origin: Point{
			x: 10
			y: 20
		}
	}
	print_int(rect.width) // 100
	print_int(rect.height) // 200

	// 19.2 Nested struct field via intermediate
	rect2 := Rectangle{
		width:  50
		height: 60
		origin: Point{
			x: 5
			y: 6
		}
	}
	print_int(rect2.width + rect2.height) // 110

	// 19.3 Mutable nested struct modification
	mut rect3 := Rectangle{
		width:  10
		height: 20
		origin: Point{
			x: 1
			y: 2
		}
	}
	rect3.width = 100
	rect3.height = 200
	print_int(rect3.width) // 100
	print_int(rect3.height) // 200

	// 19.4 Multiple rectangles
	rect4a := Rectangle{
		width:  10
		height: 20
		origin: Point{
			x: 0
			y: 0
		}
	}
	rect4b := Rectangle{
		width:  30
		height: 40
		origin: Point{
			x: 0
			y: 0
		}
	}
	print_int(rect4a.width + rect4b.width) // 40
	print_int(rect4a.height + rect4b.height) // 60

	// 19.5 Rectangle area
	rect5 := Rectangle{
		width:  12
		height: 10
		origin: Point{
			x: 0
			y: 0
		}
	}
	area := rect5.width * rect5.height
	print_int(area) // 120

	// ==================== 20. NEGATIVE NUMBERS (5 tests) ====================
	print_str('--- 20. Negative Numbers ---')

	// 20.1 Unary minus
	n1 := 0 - 42
	print_int(n1) // -42

	// 20.2 Negative addition
	n2 := 0 - 10
	n3 := n2 + 5
	print_int(n3) // -5

	// 20.3 Negative subtraction
	n4 := 0 - 20
	n5 := n4 - 10
	print_int(n5) // -30

	// 20.4 Negative multiplication
	n6 := 0 - 7
	n7 := n6 * 3
	print_int(n7) // -21

	// 20.5 Double negative (positive)
	n8 := 0 - 50
	n9 := 0 - n8
	print_int(n9) // 50

	// ==================== 21. ELSE-IF CHAINS (5 tests) ====================
	print_str('--- 21. Else-If Chains ---')

	// 21.1 classify function (> 100)
	print_int(classify(200)) // 3

	// 21.2 classify (> 50)
	print_int(classify(75)) // 2

	// 21.3 classify (> 0)
	print_int(classify(25)) // 1

	// 21.4 classify (<= 0)
	print_int(classify(0)) // 0

	// 21.5 Multiple else-if inline
	val21 := 42
	mut r21 := 0
	if val21 > 100 {
		r21 = 5
	} else if val21 > 50 {
		r21 = 4
	} else if val21 > 40 {
		r21 = 3
	} else if val21 > 30 {
		r21 = 2
	} else {
		r21 = 1
	}
	print_int(r21) // 3

	// ==================== 22. FUNCTION RETURNING STRUCT (5 tests) ====================
	print_str('--- 22. Function Returning Struct ---')

	// 22.1 Basic make_point
	rp1 := make_point(10, 20)
	print_int(rp1.x) // 10
	print_int(rp1.y) // 20

	// 22.2 make_point with computation
	rp2 := make_point(3 * 5, 4 * 6)
	print_int(rp2.x) // 15
	print_int(rp2.y) // 24

	// 22.3 add_points
	rp3 := add_points(Point{x: 10, y: 20}, Point{x: 30, y: 40})
	print_int(rp3.x) // 40
	print_int(rp3.y) // 60

	// 22.4 Chained struct returns
	rp4 := add_points(make_point(1, 2), make_point(3, 4))
	print_int(rp4.x) // 4
	print_int(rp4.y) // 6

	// 22.5 Return struct used in arithmetic
	rp5 := make_point(100, 200)
	print_int(rp5.x + rp5.y) // 300

	// ==================== 23. EARLY RETURN (5 tests) ====================
	print_str('--- 23. Early Return ---')

	// 23.1 abs positive
	print_int(abs_val(42)) // 42

	// 23.2 abs negative
	print_int(abs_val(0 - 17)) // 17

	// 23.3 abs zero
	print_int(abs_val(0)) // 0

	// 23.4 min
	print_int(min_val(10, 20)) // 10

	// 23.5 max
	print_int(max_val(10, 20)) // 20

	// ==================== 24. CLAMP & MULTI-ARG FUNCTIONS (5 tests) ====================
	print_str('--- 24. Clamp & Multi-Arg Functions ---')

	// 24.1 clamp below
	print_int(clamp(5, 10, 100)) // 10

	// 24.2 clamp above
	print_int(clamp(200, 10, 100)) // 100

	// 24.3 clamp in range
	print_int(clamp(50, 10, 100)) // 50

	// 24.4 clamp at boundary
	print_int(clamp(10, 10, 100)) // 10

	// 24.5 clamp at upper boundary
	print_int(clamp(100, 10, 100)) // 100

	// ==================== 25. POSTFIX INC/DEC (5 tests) ====================
	print_str('--- 25. Postfix Inc/Dec ---')

	// 25.1 Basic increment
	mut pi1 := 10
	pi1++
	print_int(pi1) // 11

	// 25.2 Basic decrement
	mut pd1 := 10
	pd1--
	print_int(pd1) // 9

	// 25.3 Multiple increments
	mut pi2 := 0
	pi2++
	pi2++
	pi2++
	pi2++
	pi2++
	print_int(pi2) // 5

	// 25.4 Inc and dec combined
	mut pid := 100
	pid++
	pid++
	pid--
	print_int(pid) // 101

	// 25.5 Postfix in loop
	mut pi3 := 0
	mut cnt25 := 0
	for pi3 < 10 {
		pi3++
		cnt25++
	}
	print_int(cnt25) // 10

	// ==================== 26. COMPOUND BITWISE ASSIGNMENT (5 tests) ====================
	print_str('--- 26. Compound Bitwise Assignment ---')

	// 26.1 OR assign
	mut bw1 := 0b0011
	bw1 |= 0b1100
	print_int(bw1) // 15

	// 26.2 AND assign
	mut bw2 := 0b1111
	bw2 &= 0b1010
	print_int(bw2) // 10

	// 26.3 XOR assign
	mut bw3 := 0b1100
	bw3 ^= 0b1010
	print_int(bw3) // 6

	// 26.4 Shift left assign
	mut bw4 := 1
	bw4 <<= 4
	print_int(bw4) // 16

	// 26.5 Shift right assign
	mut bw5 := 128
	bw5 >>= 3
	print_int(bw5) // 16

	// ==================== 27. COMPLEX BOOLEAN (5 tests) ====================
	print_str('--- 27. Complex Boolean ---')

	// 27.1 AND chain
	if 10 > 5 && 20 > 10 && 30 > 20 {
		print_int(1)
	} else {
		print_int(0)
	}

	// 27.2 OR chain
	if false || false || true {
		print_int(1)
	} else {
		print_int(0)
	}

	// 27.3 Mixed AND/OR
	if (true && false) || (true && true) {
		print_int(1)
	} else {
		print_int(0)
	}

	// 27.4 NOT with AND
	if !false && !false {
		print_int(1)
	} else {
		print_int(0)
	}

	// 27.5 Complex condition
	v27 := 42
	if v27 > 10 && v27 < 100 && v27 % 2 == 0 {
		print_int(1)
	} else {
		print_int(0)
	}

	// ==================== 28. ITERATIVE ALGORITHMS (5 tests) ====================
	print_str('--- 28. Iterative Algorithms ---')

	// 28.1 Collatz for 6 (6->3->10->5->16->8->4->2->1 = 8 steps)
	print_int(collatz_steps(6)) // 8

	// 28.2 Collatz for 27 (111 steps)
	print_int(collatz_steps(27)) // 111

	// 28.3 Collatz for 1 (0 steps)
	print_int(collatz_steps(1)) // 0

	// 28.4 Sum digits
	print_int(sum_digits(12345)) // 15

	// 28.5 Sum digits of large number
	print_int(sum_digits(99999)) // 45

	// ==================== 29. BIT COUNTING (5 tests) ====================
	print_str('--- 29. Bit Counting ---')

	// 29.1 count_bits of 0
	print_int(count_bits(0)) // 0

	// 29.2 count_bits of 7 (111)
	print_int(count_bits(7)) // 3

	// 29.3 count_bits of 255 (11111111)
	print_int(count_bits(255)) // 8

	// 29.4 count_bits of 1024 (10000000000)
	print_int(count_bits(1024)) // 1

	// 29.5 count_bits of 0b10101010
	print_int(count_bits(0b10101010)) // 4

	// ==================== 30. GLOBAL COUNTER PATTERNS (5 tests) ====================
	print_str('--- 30. Global Counter Patterns ---')

	// 30.1 Global counter in loop
	g_count = 0
	mut ig := 0
	for ig < 10 {
		g_count += ig
		ig++
	}
	print_int(g_count) // 45

	// 30.2 Global flag
	g_flag = false
	if g_count > 40 {
		g_flag = true
	}
	if g_flag {
		print_int(1)
	} else {
		print_int(0)
	}

	// 30.3 Global struct modification in loop
	g_point.x = 0
	g_point.y = 0
	mut ig2 := 1
	for ig2 <= 5 {
		g_point.x += ig2
		g_point.y += ig2 * ig2
		ig2++
	}
	print_int(g_point.x) // 15
	print_int(g_point.y) // 55

	// 30.4 Global with compound multiply
	g_val = 1
	mut ig3 := 1
	for ig3 <= 5 {
		g_val *= ig3
		ig3++
	}
	print_int(g_val) // 120

	// 30.5 Global reset and reuse
	g_val = 999
	g_val = 0
	g_val += 42
	print_int(g_val) // 42

	// ==================== 31. NESTED STRUCT MUTATION (5 tests) ====================
	print_str('--- 31. Nested Struct Mutation ---')

	// 31.1 Modify nested struct width/height
	mut rm1 := Rectangle{
		width:  10
		height: 20
		origin: Point{
			x: 1
			y: 2
		}
	}
	rm1.width = 50
	rm1.height = 60
	print_int(rm1.width) // 50
	print_int(rm1.height) // 60

	// 31.2 Scale rectangle via function
	mut rm2 := Rectangle{
		width:  10
		height: 20
		origin: Point{
			x: 0
			y: 0
		}
	}
	scale_rect(mut rm2, 5)
	print_int(rm2.width) // 50
	print_int(rm2.height) // 100

	// 31.3 Multiple rectangle modifications
	mut rm3 := Rectangle{
		width:  5
		height: 5
		origin: Point{
			x: 0
			y: 0
		}
	}
	rm3.width += 10
	rm3.height += 20
	print_int(rm3.width) // 15
	print_int(rm3.height) // 25

	// 31.4 Rectangle area after modification
	mut rm4 := Rectangle{
		width:  3
		height: 4
		origin: Point{
			x: 0
			y: 0
		}
	}
	rm4.width *= 10
	rm4.height *= 10
	print_int(rm4.width * rm4.height) // 1200

	// 31.5 Modify struct then pass to function
	mut rm5 := Point{
		x: 5
		y: 10
	}
	rm5.x *= 2
	rm5.y *= 3
	scale_point(mut rm5, 2)
	print_int(rm5.x) // 20
	print_int(rm5.y) // 60

	// ==================== 32. QUADRANT & STRUCT PASSING (5 tests) ====================
	print_str('--- 32. Quadrant & Struct Passing ---')

	// 32.1 Quadrant 1
	print_int(point_quadrant(Point{x: 5, y: 5})) // 1

	// 32.2 Quadrant 2
	print_int(point_quadrant(Point{x: 0 - 5, y: 5})) // 2

	// 32.3 Quadrant 3
	print_int(point_quadrant(Point{x: 0 - 5, y: 0 - 5})) // 3

	// 32.4 Quadrant 4
	print_int(point_quadrant(Point{x: 5, y: 0 - 5})) // 4

	// 32.5 Origin
	print_int(point_quadrant(Point{x: 0, y: 0})) // 0

	// ==================== 33. 4-FIELD STRUCT (5 tests) ====================
	print_str('--- 33. 4-Field Struct ---')

	// 33.1 Basic Color init
	c1 := Color{
		r: 255
		g: 128
		b: 64
		a: 255
	}
	print_int(c1.r) // 255
	print_int(c1.g) // 128

	// 33.2 Color brightness
	c2 := Color{
		r: 90
		g: 120
		b: 90
		a: 255
	}
	print_int(color_brightness(c2)) // 100

	// 33.3 make_color function return
	c3 := make_color(10, 20, 30, 40)
	print_int(c3.r + c3.g + c3.b + c3.a) // 100

	// 33.4 Color with zero alpha
	c4 := Color{
		r: 100
		g: 200
		b: 50
		a: 0
	}
	print_int(c4.a) // 0
	print_int(c4.b) // 50

	// 33.5 Mutable color
	mut c5 := Color{
		r: 0
		g: 0
		b: 0
		a: 0
	}
	c5.r = 255
	c5.g = 255
	c5.b = 255
	c5.a = 128
	print_int(c5.r + c5.g + c5.b) // 765
	print_int(c5.a) // 128

	// ==================== 34. FIBONACCI ITERATIVE (5 tests) ====================
	print_str('--- 34. Fibonacci Iterative ---')

	// 34.1 Fib(10) iteratively
	mut fa := 0
	mut fb := 1
	for fi := 0; fi < 10; fi++ {
		tmp := fa + fb
		fa = fb
		fb = tmp
	}
	print_int(fa) // 55

	// 34.2 Fib(20) iteratively
	fa = 0
	fb = 1
	for fi := 0; fi < 20; fi++ {
		tmp := fa + fb
		fa = fb
		fb = tmp
	}
	print_int(fa) // 6765

	// 34.3 Sum of first 10 fib numbers
	mut fsum := 0
	fa = 0
	fb = 1
	for fi := 0; fi < 10; fi++ {
		fsum += fa
		tmp := fa + fb
		fa = fb
		fb = tmp
	}
	print_int(fsum) // 88

	// 34.4 Count fib numbers below 100
	mut fcnt := 0
	fa = 0
	fb = 1
	for fa < 100 {
		fcnt++
		tmp := fa + fb
		fa = fb
		fb = tmp
	}
	print_int(fcnt) // 12

	// 34.5 Largest fib below 1000
	fa = 0
	fb = 1
	for fb < 1000 {
		tmp := fa + fb
		fa = fb
		fb = tmp
	}
	print_int(fa) // 987

	// ==================== 35. NESTED LOOPS WITH FLOW CONTROL (5 tests) ====================
	print_str('--- 35. Nested Loops with Flow Control ---')

	// 35.1 Nested with outer break
	mut sum35 := 0
	mut r35 := 0
	for r35 < 10 {
		mut c35 := 0
		for c35 < 10 {
			sum35++
			c35++
		}
		r35++
		if r35 >= 3 {
			break
		}
	}
	print_int(sum35) // 30

	// 35.2 Nested with inner continue
	mut sum35b := 0
	for r35b := 0; r35b < 5; r35b++ {
		for c35b := 0; c35b < 5; c35b++ {
			if c35b % 2 == 0 {
				continue
			}
			sum35b++
		}
	}
	print_int(sum35b) // 10 (5 rows * 2 odd cols)

	// 35.3 Triple nested
	mut sum35c := 0
	for i35 := 0; i35 < 3; i35++ {
		for j35 := 0; j35 < 3; j35++ {
			for k35 := 0; k35 < 3; k35++ {
				sum35c++
			}
		}
	}
	print_int(sum35c) // 27

	// 35.4 Nested with accumulating product
	mut prod35 := 0
	for i35 := 1; i35 <= 3; i35++ {
		for j35 := 1; j35 <= 3; j35++ {
			prod35 += i35 * j35
		}
	}
	print_int(prod35) // 36

	// 35.5 Skip diagonal
	mut sum35d := 0
	for i35 := 0; i35 < 4; i35++ {
		for j35 := 0; j35 < 4; j35++ {
			if i35 == j35 {
				continue
			}
			sum35d++
		}
	}
	print_int(sum35d) // 12

	// ==================== 36. COMPLEX MATCH (5 tests) ====================
	print_str('--- 36. Complex Match ---')

	// 36.1 Match with function call in body
	x36 := 3
	match x36 {
		1 { print_int(fib(5)) }
		2 { print_int(fib(6)) }
		3 { print_int(fib(7)) }
		else { print_int(0) }
	}
	// 13

	// 36.2 Match with computation in body
	x36b := 2
	match x36b {
		1 { print_int(10 * 10) }
		2 { print_int(20 * 20) }
		3 { print_int(30 * 30) }
		else { print_int(0) }
	}
	// 400

	// 36.3 Match on computed value
	x36c := 15 % 4
	match x36c {
		0 { print_int(100) }
		1 { print_int(200) }
		2 { print_int(300) }
		3 { print_int(400) }
		else { print_int(500) }
	}
	// 400

	// 36.4 Match in loop
	mut sum36 := 0
	for i36 := 0; i36 < 5; i36++ {
		match i36 {
			0 { sum36 += 1 }
			1 { sum36 += 10 }
			2 { sum36 += 100 }
			else { sum36 += 1000 }
		}
	}
	print_int(sum36) // 1 + 10 + 100 + 1000 + 1000 = 2111

	// 36.5 Sequential matches
	mut r36 := 0
	x36d := 5
	match x36d {
		5 { r36 += 100 }
		else { r36 += 1 }
	}
	match x36d {
		5 { r36 += 200 }
		else { r36 += 2 }
	}
	print_int(r36) // 300

	// ==================== 37. CHAINED FUNCTION CALLS (5 tests) ====================
	print_str('--- 37. Chained Function Calls ---')

	// 37.1 add(add(add(1,2),3),4) = 10
	print_int(add(add(add(1, 2), 3), 4)) // 10

	// 37.2 Nested mul and add
	print_int(add(mul(3, 4), mul(5, 6))) // 42

	// 37.3 sub(mul(add(2,3),4),5) = 15
	print_int(sub(mul(add(2, 3), 4), 5)) // 15

	// 37.4 min of max
	print_int(min_val(max_val(10, 20), max_val(5, 15))) // 15

	// 37.5 max of min
	print_int(max_val(min_val(10, 20), min_val(25, 30))) // 25

	// ==================== 38. MIXED ARITHMETIC (5 tests) ====================
	print_str('--- 38. Mixed Arithmetic ---')

	// 38.1 Shift + add
	print_int((1 << 8) + 1) // 257

	// 38.2 Bitwise + arithmetic
	print_int((0xFF & 0x0F) + 16) // 31

	// 38.3 Modulo + multiply
	print_int((100 % 7) * 10) // 20

	// 38.4 Shift + bitwise
	print_int((1 << 4) | (1 << 2)) // 20

	// 38.5 Complex expression
	v38 := 100
	print_int((v38 * 2 + v38 / 2) - (v38 % 3)) // 249

	// ==================== 39. LARGE COMPUTATIONS (5 tests) ====================
	print_str('--- 39. Large Computations ---')

	// 39.1 Large factorial (10!)
	mut lf := 1
	for li := 1; li <= 10; li++ {
		lf *= li
	}
	print_int(lf) // 3628800

	// 39.2 Power of 2^20
	mut lp := 1
	for li := 0; li < 20; li++ {
		lp *= 2
	}
	print_int(lp) // 1048576

	// 39.3 Sum of squares 1..20
	mut lsq := 0
	for li := 1; li <= 20; li++ {
		lsq += li * li
	}
	print_int(lsq) // 2870

	// 39.4 Triangular number T(100)
	mut tri := 0
	for li := 1; li <= 100; li++ {
		tri += li
	}
	print_int(tri) // 5050

	// 39.5 Product of 1..8
	print_int(mul_many(1, 2, 3, 4, 5, 6, 7, 8)) // 40320

	// ==================== 40. INTEGRATION TEST (5 tests) ====================
	print_str('--- 40. Integration Test ---')

	// 40.1 Struct + loop + function
	mut ip := make_point(0, 0)
	for ii := 1; ii <= 5; ii++ {
		ip = add_points(ip, make_point(ii, ii * 2))
	}
	print_int(ip.x) // 15
	print_int(ip.y) // 30

	// 40.2 Conditional + struct + global
	g_val = 0
	mut ip2 := Point{
		x: 1
		y: 1
	}
	for ii := 0; ii < 10; ii++ {
		if ii % 2 == 0 {
			ip2.x += ii
			g_val += 1
		} else {
			ip2.y += ii
		}
	}
	print_int(ip2.x) // 1 + 0 + 2 + 4 + 6 + 8 = 21
	print_int(ip2.y) // 1 + 1 + 3 + 5 + 7 + 9 = 26
	print_int(g_val) // 5

	// 40.3 Nested function + assert
	assert abs_val(0 - 42) == 42
	assert min_val(10, 20) == 10
	assert max_val(10, 20) == 20
	print_str('Integration asserts passed')

	// 40.4 Algorithm + match
	mut sum40 := 0
	for ii := 1; ii <= 10; ii++ {
		match classify(ii * 10) {
			1 { sum40 += 1 }
			2 { sum40 += 10 }
			3 { sum40 += 100 }
			else { sum40 += 0 }
		}
	}
	print_int(sum40) // 10: 1, 20: 1, 30: 1, 40: 1, 50: 1, 60: 10, 70: 10, 80: 10, 90: 10, 100: 10 = 5 + 50 = 55
	// Actually: 10->1, 20->1, 30->1, 40->1, 50->1, 60->2(>50), 70->2, 80->2, 90->2, 100->2(not >100)
	// so: 1*5 + 10*5 = 55

	// 40.5 Heap struct in loop with accumulation
	mut hsum := 0
	for ii := 0; ii < 5; ii++ {
		hp := &Point{
			x: ii * 3
			y: ii * 7
		}
		hsum += hp.x + hp.y
	}
	print_int(hsum) // (0+0)+(3+7)+(6+14)+(9+21)+(12+28) = 0+10+20+30+40 = 100

	print_str('=== ALL 40 TESTS PASSED ===')
}
