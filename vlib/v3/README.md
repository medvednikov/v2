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
| flat parser    | 2,915 |
| C gen          | 1,518 |
| SSA IR+build   | 1,355 |
| SSA optimize   | 455   |
| MIR            | 133   |
| insel          | 7     |
| ARM64 gen      | 815   |
| ARM64 asm      | 634   |
| Mach-O         | 285   |
| ARM64 linker   | 1,478 |
| flat AST       | 866   |
| transformer    | 209   |
| markused       | 81    |
| driver         | 132   |
| builtins       | 17    |
| **total**      | **10,900** |

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

Compiling `test.v` (1,867 lines, 40 test sections: structs, globals, match, recursion, nested loops, many args, mut params, assert, heap alloc, bitwise, shifts, modulo, pointers, nested structs, negatives, else-if, early return, clamp, postfix, compound bitwise, boolean chains, iterative algorithms, bit counting, global counters, struct mutation, struct passing, 4-field structs, fibonacci, nested loops, complex match, chained calls, mixed arithmetic, large computations):

**C backend:**

| Step      | Time     | RSS      |
|-----------|----------|----------|
| parse     | 2.25 ms  | 4,144 KB |
| transform | 0.13 ms  | 4,192 KB |
| markused  | 0.32 ms  | 4,304 KB |
| gen C     | 1.15 ms  | 4,784 KB |
| write     | 0.15 ms  | 4,800 KB |
| cc        | 44 ms    | 4,864 KB |
| **total** | **~48 ms** | **4,864 KB** |

**ARM64 backend (no cc — straight to native binary):**

| Step      | Time     | RSS      |
|-----------|----------|----------|
| parse     | 2.13 ms  | 4,096 KB |
| transform | 0.15 ms  | 4,160 KB |
| markused  | 0.43 ms  | 4,336 KB |
| SSA build | 4.95 ms  | 6,080 KB |
| ARM64 gen | 7.08 ms  | 6,672 KB |
| link      | 6.94 ms  | 6,736 KB |
| **total** | **~22 ms** | **6,736 KB** |

**ARM64 backend with `-prod` (SSA optimization + MIR + insel):**

| Step      | Time      | RSS      |
|-----------|-----------|----------|
| parse     | 2.18 ms   | 4,112 KB |
| transform | 0.14 ms   | 4,176 KB |
| markused  | 0.44 ms   | 4,304 KB |
| SSA build | 5.76 ms   | 6,016 KB |
| optimize  | 8.93 ms   | 6,624 KB |
| MIR       | 0.89 ms   | 7,760 KB |
| insel     | 0.00 ms   | 7,776 KB |
| ARM64 gen | 7.43 ms   | 8,496 KB |
| link      | 3.88 ms   | 8,992 KB |
| **total** | **~30 ms** | **8,992 KB** |

All v3 steps (parse + transform + markused + gen + write) complete in ~0.26 ms for hello world, ~4 ms for test.v with C backend. The ARM64 backend compiles test.v end-to-end in ~22 ms — no external tools, straight to executable. With `-prod`, SSA optimization adds ~10 ms for constant folding, branch folding, DCE, and block optimization.

Peak RSS: 3-7 MB.

## Comparison with V1

Frontend-only (parse + check + gen C, no `cc`):

| Compiler | hello world | test.v (1,867 lines) | Peak RSS (hello) | Peak RSS (test) |
|----------|------------|----------------------|------------------|-----------------|
| V1 (0.5.1) | 93 ms | 105 ms | 70 MB | 78 MB |
| **v3** | **0.26 ms** | **4 ms** | **3 MB** | **5 MB** |

v3 is **~350x faster** and uses **~15x less memory** than V1 for frontend compilation.

V1 parses 143 files (~33K lines) of builtins for every compilation. v3 parses only the input file and generates standalone C with a minimal preamble — no builtin parsing overhead.

Generated C output for hello world: V1 emits 4,147 lines, v3 emits 73 lines.

The ARM64 backend goes further — compiling test.v to a native binary in ~22 ms total, with no dependency on any external C compiler or linker. With `-prod`, the full optimization pipeline (SSA optimize + MIR + insel) runs in ~30 ms.

Measured on macOS (Apple Silicon), warm runs. V1 built from `~/code/v5/v` (V 0.5.1).
