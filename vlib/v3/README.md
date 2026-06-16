# v3

Clean rewrite of the V compiler. Reuses v2's scanner, uses a flat AST parser with Pratt parsing, a type checker with lexical scoping, a transformer for AST simplification (match lowering), a markused pass for dead-code elimination, and two backends: a direct flat-AST-to-C backend and a native ARM64 backend via SSA IR with a built-in linker (no external assembler or linker needed). With `-prod`, the ARM64 backend runs SSA optimization (constant folding, branch folding, dead code elimination, unreachable block removal, block merging), MIR lowering, and instruction selection.

Imports the actual `vlib/builtin/` V source files for struct/enum/type definitions (string, array, map, etc.), with C runtime functions provided via a built-in preamble. The type checker resolves V types through scope chains and converts them to C types at emission sites.

## Architecture

```
                                                                        ┌→ gen C → cc
source + vlib/builtin → scanner → flat parser → flat AST → transform → markused ─┤
                                                                        └→ SSA build ──→ ARM64 gen → link
                                                                                     └─→ optimize → MIR → insel ─┘
                                                                                         (-prod only)
```

The parser directly emits a flat AST — no recursive AST intermediate, no flatten step. All nodes live in a single `[]Node` array with children as indices into a separate `[]NodeId` array. No pointer chasing, no recursive sum types during code generation.

All `vlib/builtin/*.v` files are parsed first to collect struct, enum, type alias, and interface definitions. The type checker (`types/`) uses lexical scopes with parent chains to resolve V types (`resolve_type`) and convert them to C types (`c_type`) at each emission site. Function bodies from builtins are skipped during C code generation — only type information is used.

The transformer lowers match statements to if/else chains and collects struct/global type info.

The markused pass performs reachability analysis from `main`, building a call graph and BFS-walking to find all used functions. Both backends skip codegen for unreachable functions.

The ARM64 backend builds SSA IR from the flat AST, generates native ARM64 machine code, and links a Mach-O executable directly — the entire path from source to binary uses no external tools.

## Code size

| Component      | Lines |
|----------------|-------|
| flat parser    | 2,949 |
| C gen (flat)   | 1,638 |
| type checker   | 285   |
| scopes         | 32    |
| C gen (AST)    | 656   |
| SSA IR+build   | 1,510 |
| SSA optimize   | 474   |
| MIR            | 188   |
| insel          | 7     |
| ARM64 gen      | 873   |
| ARM64 asm      | 634   |
| Mach-O         | 285   |
| ARM64 linker   | 1,478 |
| flat AST       | 231   |
| AST            | 866   |
| flatten        | 532   |
| transformer    | 243   |
| markused       | 107   |
| driver         | 137   |
| builtins       | 89    |
| scanner        | 582   |
| token          | 687   |
| **total**      | **~14,800** |

The flat parser covers the full V language (all constructs from the old 3,991-line v2 parser), but in ~27% fewer lines thanks to the flat AST representation.

## Performance

Compiling `hello world` (`println('hello world')`) with builtin import:

| Step      | Time     | RSS      |
|-----------|----------|----------|
| parse     | 10.5 ms  | 6,592 KB |
| transform | 0.6 ms   | 6,752 KB |
| markused  | 1.4 ms   | 7,136 KB |
| gen C     | 1.9 ms   | 7,760 KB |
| write     | 0.2 ms   | 7,760 KB |
| cc        | 47 ms    | 7,776 KB |
| **total** | **~90 ms** | **7,776 KB** |

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

All v3 steps (parse + transform + markused + gen + write) complete in ~15 ms for hello world (including builtin parsing), ~13 ms for test.v (3,623 lines) with C backend.

Peak RSS: 7-15 MB.

## Comparison with V1

Frontend-only (parse + check + gen C, no `cc`):

| Compiler | hello world | test.v (3,623 lines) | Peak RSS (hello) | Peak RSS (test) |
|----------|------------|----------------------|------------------|-----------------|
| V1 (0.5.1) | 93 ms | 105 ms | 70 MB | 78 MB |
| **v3** | **15 ms** | **13 ms** | **8 MB** | **15 MB** |

v3 is **~6-8x faster** and uses **~5-9x less memory** than V1 for frontend compilation.

v3 parses `vlib/builtin/*.v` files for type definitions (structs, enums, type aliases), but skips `.c.v` files and builtin function bodies — C runtime functions are provided via a compact preamble.

Measured on macOS (Apple Silicon), warm runs. V1 built from `~/code/v5/v` (V 0.5.1).
