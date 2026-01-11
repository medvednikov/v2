struct Point {
	x int
	y int
}

__global (
	g_val int
)

fn main() {
	// 1. Struct Decl & Init & SelectorExpr
	p := Point{x: 10, y: 20}
	
	// 2. Selector Assign (L-Value)
	p.x = 100
	
	// 3. Globals & Compound Assign
	g_val = 5
	g_val += 5
	
	// 4. IndexExpr & Pointers
	// Simulate array via pointer arithmetic logic in Builder/Backend
	// Since we don't have malloc in this MVP, we use the struct pointer as a base
	// or just a stack variable address treated as array base.
	// For valid C output, let's use the struct ptr cast logic implicitly handled.
	
	// 5. Bool & Logic
	flag := true
	if flag {
		p.y = 200
	}

	// 6. Loop with Break/Continue
	i := 0
	sum := 0
	for i < 10 {
		i++
		if i == 5 {
			continue
		}
		if i > 8 {
			break
		}
		sum += i
	}
	
	// 7. Cast (implicit in this backend)
	val := int(sum)
	
	return val
}
