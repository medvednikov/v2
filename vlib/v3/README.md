# v3

Clean rewrite of the V compiler. Reuses v2's scanner, uses a flat AST parser with Pratt parsing, a structured type system with sum-type variants, lexical scoping, a transformer for AST simplification (match lowering), a shared type-checking phase, a markused pass for dead-code elimination, recursive import resolution, and two backends: a direct flat-AST-to-C backend and a native ARM64 backend via SSA IR with a built-in linker (no external assembler or linker needed). With `-prod`, the ARM64 backend runs SSA optimization (constant folding, branch folding, dead code elimination, unreachable block removal, block merging), MIR lowering, and instruction selection.

Imports all `vlib/builtin/` V source files — both pure V (`.v`) and C-interop (`.c.v`) — for struct, enum, type alias, interface, C function declarations, and global definitions. `$if` compile-time conditionals are resolved directly in the parser (evaluate condition, parse only the taken branch, skip the other — no AST nodes or transformer pass needed). C runtime functions (println, string ops, int_str, etc.) are still provided via a built-in preamble; builtin function bodies are skipped during C code generation. Maps use the builtin `map` type name and API (`new_map`, `map__set`, `map__get`, `map__delete`, etc.) with a simplified open-addressing implementation until v3 can compile the full builtin map.v.

The type system (`types/`) uses a `Type` sum type with 20 variants (Primitive, Array, Map, Pointer, FnType, Struct, Enum, etc.) instead of string-based type checks. Primitive types use a `Properties` flag enum with `boolean`, `float`, `integer`, `unsigned` flags and a `size` field. The parser produces string type names; `parse_type()` bridges them to structured `Type` values. `resolve_type()` infers types from AST nodes, and `c_type()` lowers to C type strings only at emission sites. Lexical scopes store `Type` values with parent-chain lookups.

Type checking runs as a shared pipeline phase before backend selection: `TypeChecker.collect()` walks the flat AST to extract function signatures, struct fields, enum names, type aliases, sum types, and C function declarations, then registers runtime method signatures. Both the C backend and future backends receive the pre-populated `TypeChecker`.

Imports are resolved recursively: after parsing the input file, the driver collects `import_decl` nodes, resolves module paths (relative to importing file, then vlib), parses module files, and repeats until no new imports are found.

## Architecture

```
                                                                                                  ┌→ gen C → cc
source + vlib/builtin → scanner → flat parser → flat AST → import resolve → transform → check → markused ─┤
                                                                                                  └→ SSA build ──→ ARM64 gen → link
                                                                                                               └─→ optimize → MIR → insel ─┘
                                                                                                                   (-prod only)
```

The parser directly emits a flat AST — no recursive AST intermediate, no flatten step. All nodes live in a single `[]Node` array with children as indices into a separate `[]NodeId` array. No pointer chasing, no recursive sum types during code generation.

All `vlib/builtin/` files (38 files: both `.v` and `.c.v`) are parsed first to collect struct, enum, type alias, interface, C function, and global definitions. `$if` compile-time conditionals (`$if !no_bounds_checking`, `$if gcboehm_opt ?`, `$if freestanding`, etc.) are resolved inline during parsing — the parser evaluates the condition, parses only the taken branch, and skips the other, so no `comptime_if` AST nodes reach the transformer or backends.

After parsing the input file, imports are resolved recursively: the driver scans for `import_decl` nodes, resolves module paths (relative to importing file first, then under `vlib/`), parses module `.v` and `.c.v` files, and repeats until all transitive imports are loaded.

The type system (`types/`) uses a `Type` sum type with structured variants instead of string-based type checks:
- **Primitive** types use a `Properties` flag enum (`boolean`, `float`, `integer`, `unsigned`) and a `size` field — `int`, `i64`, `u8`, `f32`, `bool` are all `Primitive` with different flags
- **Compound** types: `Array{elem_type}`, `ArrayFixed{elem_type, len}`, `Map{key_type, value_type}`, `Pointer{base_type}`, `FnType{params, return_type}`, `OptionType`, `ResultType`, `MultiReturn`
- **Named** types: `Struct{name}`, `Enum{name, is_flag}`, `SumType{name}`, `Alias{name, base_type}`
- **Simple** tags: `Void`, `String`, `Char`, `Rune`, `ISize`, `USize`, `Nil`, `None`

`parse_type(string) Type` bridges parser string output to structured types. `resolve_type(NodeId) Type` infers types from AST nodes. `c_type(Type) string` lowers to C type strings only at final emission. Lexical scopes store `map[string]Type` with parent-chain lookups.

`C.` structs and globals are recognized as extern C types and excluded from code generation. Function bodies from builtins are skipped during C code generation — only type and declaration information is used.

The transformer lowers match statements to if/else chains and collects struct/global type info.

The markused pass performs reachability analysis from `main`, building a call graph and BFS-walking to find all used functions. Method calls are resolved to `Type.method` names using the type checker, reducing false positives from syntactic matching. Both backends skip codegen for unreachable functions.

The ARM64 backend builds SSA IR from the flat AST, generates native ARM64 machine code, and links a Mach-O executable directly — the entire path from source to binary uses no external tools.

## Code size

| Component      | Lines |
|----------------|-------|
| flat parser    | 3,109 |
| C gen (flat)   | 2,429 |
| type system    | 286   |
| type checker   | 709   |
| universe       | 97    |
| scopes         | 34    |
| C gen (AST)    | 656   |
| SSA IR+build   | 1,510 |
| SSA optimize   | 474   |
| ARM64 gen      | 873   |
| ARM64 asm      | 634   |
| Mach-O         | 285   |
| ARM64 linker   | 1,478 |
| flat AST       | 231   |
| AST            | 866   |
| flatten        | 532   |
| transformer    | 243   |
| markused       | 131   |
| driver         | 182   |
| builtins       | 89    |
| pref           | 219   |
| scanner        | 582   |
| token          | 338   |
| **total**      | **~16,000** |

The flat parser covers the full V language (all constructs from the old 3,991-line v2 parser), but in ~27% fewer lines thanks to the flat AST representation.

## Performance

Compiling `hello world` (`println('hello world')`) with full builtin import (38 files):

| Step      | Time     | RSS       |
|-----------|----------|-----------|
| parse     | 22 ms    | 10,880 KB |
| transform | 0.7 ms   | 11,024 KB |
| check     | 1.9 ms   | 11,664 KB |
| markused  | 2.2 ms   | 12,304 KB |
| gen C     | 1.5 ms   | 12,816 KB |
| write     | 0.2 ms   | 12,832 KB |
| cc        | 43 ms    | 12,864 KB |
| **total** | **~92 ms** | **12,864 KB** |

Compiling `test.v` (4,026 lines, 100 test sections: structs, globals, match, recursion, nested loops, many args, mut params, assert, heap alloc, bitwise, shifts, modulo, pointers, nested structs, negatives, else-if, early return, clamp, postfix, compound bitwise, boolean chains, iterative algorithms, bit counting, global counters, struct mutation, struct passing, 4-field structs, fibonacci, nested loops, complex match, chained calls, mixed arithmetic, large computations, vector math, matrix ops, prime checking, integer sqrt, number reverse/palindrome, stats tracking, binary search, Ackermann, triangle geometry, digital root, interpolation, bit manipulation, chained struct ops, global accumulation, sieve simulation, complex loop patterns, heap struct computations, multi-function pipeline, stress integration, methods, if-expressions, string interpolation, for-in range, enums, defer, unary ops, complex boolean, comparison expressions, deeply nested if, large constants, mixed operations, edge cases, complex recursion, struct operations, control flow edge cases, array initialization, for-in array, fixed-size arrays, string struct fields, struct field operations, println, algebraic optimizations, dead store elimination, goto, string match return, return if-expression, or blocks/optional/panic, if-guard/optional unwrap, maps, string methods, dynamic arrays, array methods/slicing/split, map iteration/array init with len, in operator/array join, strings.Builder, static methods, @FILE, unsafe blocks, function pointers):

**C backend:**

| Step      | Time     | RSS      |
|-----------|----------|----------|
| parse     | 25.17 ms | 10,736 KB |
| transform | 1.06 ms  | 10,928 KB |
| markused  | 52.14 ms | 46,128 KB |
| gen C     | 3.57 ms  | 48,320 KB |
| write     | 2.19 ms  | 48,320 KB |
| cc        | 57 ms    | 48,336 KB |
| **total** | **~163 ms** | **48,336 KB** |

All v3 steps (parse + transform + markused + gen + write) complete in ~8 ms for hello world (including 38 builtin files), ~84 ms for test.v (4,026 lines) with C backend.

Peak RSS: 9-20 MB.

## Comparison with V1

Frontend-only (parse + check + gen C, no `cc`):

| Compiler | hello world | test.v (3,756 lines) | Peak RSS (hello) | Peak RSS (test) |
|----------|------------|----------------------|------------------|-----------------|
| V1 (0.5.1) | 93 ms | 105 ms | 70 MB | 78 MB |
| **v3** | **8 ms** | **42 ms** | **9 MB** | **34 MB** |

v3 is **~3-12x faster** and uses **~3-8x less memory** than V1 for frontend compilation.

v3 parses all `vlib/builtin/` files (38 files: `.v` and `.c.v`) for type definitions, C function declarations, and globals. `$if` compile-time conditionals are resolved inline in the parser. Builtin function bodies are skipped during C code generation — C runtime functions are provided via a compact preamble.

Measured on macOS (Apple Silicon), warm runs. V1 built from `~/code/v5/v` (V 0.5.1).
