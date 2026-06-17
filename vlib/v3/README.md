# v3

Clean rewrite of the V compiler. Reuses v2's scanner, uses a flat AST parser with Pratt parsing, a type checker with lexical scoping, a transformer for AST simplification (match lowering), a markused pass for dead-code elimination, and two backends: a direct flat-AST-to-C backend and a native ARM64 backend via SSA IR with a built-in linker (no external assembler or linker needed). With `-prod`, the ARM64 backend runs SSA optimization (constant folding, branch folding, dead code elimination, unreachable block removal, block merging), MIR lowering, and instruction selection.

Imports all `vlib/builtin/` V source files — both pure V (`.v`) and C-interop (`.c.v`) — for struct, enum, type alias, interface, C function declarations, and global definitions. `$if` compile-time conditionals are resolved directly in the parser (evaluate condition, parse only the taken branch, skip the other — no AST nodes or transformer pass needed). C runtime functions (println, string ops, int_str, etc.) are still provided via a built-in preamble; builtin function bodies are skipped during C code generation. The type checker resolves V types through scope chains and converts them to C types at emission sites.

## Architecture

```
                                                                        ┌→ gen C → cc
source + vlib/builtin → scanner → flat parser → flat AST → transform → markused ─┤
                                                                        └→ SSA build ──→ ARM64 gen → link
                                                                                     └─→ optimize → MIR → insel ─┘
                                                                                         (-prod only)
```

The parser directly emits a flat AST — no recursive AST intermediate, no flatten step. All nodes live in a single `[]Node` array with children as indices into a separate `[]NodeId` array. No pointer chasing, no recursive sum types during code generation.

All `vlib/builtin/` files (38 files: both `.v` and `.c.v`) are parsed first to collect struct, enum, type alias, interface, C function, and global definitions. `$if` compile-time conditionals (`$if !no_bounds_checking`, `$if gcboehm_opt ?`, `$if freestanding`, etc.) are resolved inline during parsing — the parser evaluates the condition, parses only the taken branch, and skips the other, so no `comptime_if` AST nodes reach the transformer or backends. The type checker (`types/`) uses lexical scopes with parent chains to resolve V types (`resolve_type`) and convert them to C types (`c_type`) at each emission site. `C.` structs and globals are recognized as extern C types and excluded from code generation. Function bodies from builtins are skipped during C code generation — only type and declaration information is used.

The transformer lowers match statements to if/else chains and collects struct/global type info.

The markused pass performs reachability analysis from `main`, building a call graph and BFS-walking to find all used functions. Both backends skip codegen for unreachable functions.

The ARM64 backend builds SSA IR from the flat AST, generates native ARM64 machine code, and links a Mach-O executable directly — the entire path from source to binary uses no external tools.

## Code size

| Component      | Lines |
|----------------|-------|
| flat parser    | 3,034 |
| C gen (flat)   | 1,700 |
| type checker   | 290   |
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
| driver         | 146   |
| builtins       | 89    |
| pref           | 90    |
| scanner        | 582   |
| token          | 687   |
| **total**      | **~14,900** |

The flat parser covers the full V language (all constructs from the old 3,991-line v2 parser), but in ~27% fewer lines thanks to the flat AST representation.

## Performance

Compiling `hello world` (`println('hello world')`) with full builtin import (38 files):

| Step      | Time     | RSS      |
|-----------|----------|----------|
| parse     | 5.1 ms   | 7,632 KB |
| transform | 0.3 ms   | 7,888 KB |
| markused  | 0.9 ms   | 8,528 KB |
| gen C     | 1.4 ms   | 9,184 KB |
| write     | 0.1 ms   | 9,184 KB |
| cc        | 37 ms    | 9,200 KB |
| **total** | **~60 ms** | **9,200 KB** |

Compiling `test.v` (3,788 lines, 92 test sections: structs, globals, match, recursion, nested loops, many args, mut params, assert, heap alloc, bitwise, shifts, modulo, pointers, nested structs, negatives, else-if, early return, clamp, postfix, compound bitwise, boolean chains, iterative algorithms, bit counting, global counters, struct mutation, struct passing, 4-field structs, fibonacci, nested loops, complex match, chained calls, mixed arithmetic, large computations, vector math, matrix ops, prime checking, integer sqrt, number reverse/palindrome, stats tracking, binary search, Ackermann, triangle geometry, digital root, interpolation, bit manipulation, chained struct ops, global accumulation, sieve simulation, complex loop patterns, heap struct computations, multi-function pipeline, stress integration, methods, if-expressions, string interpolation, for-in range, enums, defer, unary ops, complex boolean, comparison expressions, deeply nested if, large constants, mixed operations, edge cases, complex recursion, struct operations, control flow edge cases, array initialization, for-in array, fixed-size arrays, string struct fields, struct field operations, println, algebraic optimizations, dead store elimination, goto, string match return, return if-expression, or blocks/optional/panic, if-guard/optional unwrap, maps, string methods, dynamic arrays):

**C backend:**

| Step      | Time     | RSS      |
|-----------|----------|----------|
| parse     | 8.53 ms  | 10,720 KB |
| transform | 0.54 ms  | 10,832 KB |
| markused  | 20.32 ms | 27,744 KB |
| gen C     | 3.51 ms  | 29,776 KB |
| write     | 0.17 ms  | 29,792 KB |
| cc        | 55 ms    | 29,808 KB |
| **total** | **~106 ms** | **29,808 KB** |

All v3 steps (parse + transform + markused + gen + write) complete in ~8 ms for hello world (including 38 builtin files), ~33 ms for test.v (3,788 lines) with C backend.

Peak RSS: 9-20 MB.

## Comparison with V1

Frontend-only (parse + check + gen C, no `cc`):

| Compiler | hello world | test.v (3,756 lines) | Peak RSS (hello) | Peak RSS (test) |
|----------|------------|----------------------|------------------|-----------------|
| V1 (0.5.1) | 93 ms | 105 ms | 70 MB | 78 MB |
| **v3** | **8 ms** | **33 ms** | **9 MB** | **30 MB** |

v3 is **~3-12x faster** and uses **~3-8x less memory** than V1 for frontend compilation.

v3 parses all `vlib/builtin/` files (38 files: `.v` and `.c.v`) for type definitions, C function declarations, and globals. `$if` compile-time conditionals are resolved inline in the parser. Builtin function bodies are skipped during C code generation — C runtime functions are provided via a compact preamble.

Measured on macOS (Apple Silicon), warm runs. V1 built from `~/code/v5/v` (V 0.5.1).
