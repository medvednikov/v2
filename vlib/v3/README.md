# v3

Clean rewrite of the V compiler. Reuses v2's scanner, uses a flat AST parser with Pratt parsing, a transformer for AST simplification (match lowering), a markused pass for dead-code elimination, and two backends: a direct flat-AST-to-C backend and a native ARM64 backend via SSA IR with a built-in linker (no external assembler or linker needed). With `-prod`, the ARM64 backend runs SSA optimization (constant folding, branch folding, dead code elimination, unreachable block removal, block merging), MIR lowering, and instruction selection.

## Architecture

```
                                                      ┌→ gen C → cc
source → scanner → flat parser → flat AST → transform → markused ─┤
                                                      └→ SSA build ──→ ARM64 gen → link
                                                                   └─→ optimize → MIR → insel ─┘
                                                                       (-prod only)
```

The parser directly emits a flat AST — no recursive AST intermediate, no flatten step. All nodes live in a single `[]Node` array with children as indices into a separate `[]NodeId` array. No pointer chasing, no recursive sum types during code generation.

The transformer lowers match statements to if/else chains and collects struct/global type info.

The markused pass performs reachability analysis from `main`, building a call graph and BFS-walking to find all used functions. Both backends skip codegen for unreachable functions.

The ARM64 backend builds SSA IR from the flat AST, generates native ARM64 machine code, and links a Mach-O executable directly — the entire path from source to binary uses no external tools.

## Code size

| Component      | Lines |
|----------------|-------|
| flat parser    | 2,927 |
| C gen (flat)   | 1,175 |
| C gen (AST)    | 656   |
| SSA IR+build   | 1,510 |
| SSA optimize   | 474   |
| MIR            | 188   |
| insel          | 7     |
| ARM64 gen      | 873   |
| ARM64 asm      | 634   |
| Mach-O         | 285   |
| ARM64 linker   | 1,478 |
| flat AST       | 230   |
| AST            | 866   |
| flatten        | 532   |
| transformer    | 243   |
| markused       | 107   |
| driver         | 123   |
| builtins       | 89    |
| scanner        | 582   |
| token          | 687   |
| **total**      | **~13,900** |

The flat parser covers the full V language (all constructs from the old 3,991-line v2 parser), but in ~27% fewer lines thanks to the flat AST representation.

## Performance

Compiling `hello world` (`println('hello world')`):

| Step      | Time     | RSS      |
|-----------|----------|----------|
| parse     | 0.08 ms  | 2,880 KB |
| transform | 0.01 ms  | 2,928 KB |
| markused  | 0.01 ms  | 2,960 KB |
| gen C     | 0.03 ms  | 3,056 KB |
| write     | 0.13 ms  | 3,088 KB |
| cc        | 38 ms    | 3,104 KB |
| **total** | **~38 ms** | **3,104 KB** |

Compiling `test.v` (3,623 lines, 87 test sections: structs, globals, match, recursion, nested loops, many args, mut params, assert, heap alloc, bitwise, shifts, modulo, pointers, nested structs, negatives, else-if, early return, clamp, postfix, compound bitwise, boolean chains, iterative algorithms, bit counting, global counters, struct mutation, struct passing, 4-field structs, fibonacci, nested loops, complex match, chained calls, mixed arithmetic, large computations, vector math, matrix ops, prime checking, integer sqrt, number reverse/palindrome, stats tracking, binary search, Ackermann, triangle geometry, digital root, interpolation, bit manipulation, chained struct ops, global accumulation, sieve simulation, complex loop patterns, heap struct computations, multi-function pipeline, stress integration, methods, if-expressions, string interpolation, for-in range, enums, defer, unary ops, complex boolean, comparison expressions, deeply nested if, large constants, mixed operations, edge cases, complex recursion, struct operations, control flow edge cases, array initialization, for-in array, fixed-size arrays, string struct fields, struct field operations, println, algebraic optimizations, dead store elimination, goto, string match return, return if-expression):

**C backend:**

| Step      | Time     | RSS      |
|-----------|----------|----------|
| parse     | 4.17 ms  | 4,960 KB |
| transform | 0.20 ms  | 5,008 KB |
| markused  | 1.85 ms  | 5,728 KB |
| gen C     | 2.43 ms  | 6,768 KB |
| write     | 0.15 ms  | 6,784 KB |
| cc        | 52 ms    | 6,800 KB |
| **total** | **~69 ms** | **6,800 KB** |

All v3 steps (parse + transform + markused + gen + write) complete in ~0.26 ms for hello world, ~9 ms for test.v (3,623 lines) with C backend.

Peak RSS: 3-7 MB.

## Comparison with V1

Frontend-only (parse + check + gen C, no `cc`):

| Compiler | hello world | test.v (3,623 lines) | Peak RSS (hello) | Peak RSS (test) |
|----------|------------|----------------------|------------------|-----------------|
| V1 (0.5.1) | 93 ms | 105 ms | 70 MB | 78 MB |
| **v3** | **0.26 ms** | **9 ms** | **3 MB** | **7 MB** |

v3 is **~350x faster** and uses **~10x less memory** than V1 for frontend compilation.

V1 parses 143 files (~33K lines) of builtins for every compilation. v3 parses only the input file and generates standalone C with a minimal preamble — no builtin parsing overhead.

Generated C output for hello world: V1 emits 4,147 lines, v3 emits 73 lines.

Measured on macOS (Apple Silicon), warm runs. V1 built from `~/code/v5/v` (V 0.5.1).
