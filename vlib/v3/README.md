# v3

Clean rewrite of the V compiler. Reuses v2's scanner, uses a flat AST parser with Pratt parsing, a transformer for AST simplification (match lowering), and two backends: a direct flat-AST-to-C backend and a native ARM64 backend via SSA IR with a built-in linker (no external assembler or linker needed).

## Architecture

```
                                           ┌→ gen C → cc
source → scanner → flat parser → flat AST → transform ─┤
                                           └→ SSA build → ARM64 gen → link
```

The parser directly emits a flat AST — no recursive AST intermediate, no flatten step. All nodes live in a single `[]Node` array with children as indices into a separate `[]NodeId` array. No pointer chasing, no recursive sum types during code generation.

The transformer lowers match statements to if/else chains and collects struct/global type info.

The ARM64 backend builds SSA IR from the flat AST, generates native ARM64 machine code, and links a Mach-O executable directly — the entire path from source to binary uses no external tools.

## Code size

| Component    | Lines |
|--------------|-------|
| flat parser  | 2,915 |
| C gen        | 848   |
| SSA IR       | 1,305 |
| ARM64 gen    | 808   |
| ARM64 asm    | 635   |
| Mach-O       | 285   |
| ARM64 linker | 1,484 |
| flat AST     | 230   |
| transformer  | 209   |
| driver       | 107   |
| builtins     | 17    |
| **total**    | **8,843** |

The flat parser covers the full V language (all constructs from the old 3,991-line v2 parser), but in ~27% fewer lines thanks to the flat AST representation.

## Performance

Compiling `hello world` (`println('hello world')`):

| Step      | Time     | RSS      |
|-----------|----------|----------|
| parse     | 0.03 ms  | 2,848 KB |
| transform | 0.00 ms  | 2,944 KB |
| gen C     | 0.02 ms  | 3,040 KB |
| write     | 0.06 ms  | 3,056 KB |
| cc        | 35 ms    | 3,120 KB |
| **total** | **~35 ms** | **3,120 KB** |

Compiling `test.v` (1,002 lines, 20 test sections: structs, globals, match, recursion, nested loops, many args, mut params, assert, heap alloc, bitwise, shifts, modulo, pointers, nested structs, negatives):

**C backend:**

| Step      | Time     | RSS      |
|-----------|----------|----------|
| parse     | 0.64 ms  | 3,696 KB |
| transform | 0.03 ms  | 3,728 KB |
| gen C     | 0.46 ms  | 4,080 KB |
| write     | 0.13 ms  | 4,096 KB |
| cc        | 37 ms    | 4,112 KB |
| **total** | **~38 ms** | **4,112 KB** |

**ARM64 backend (no cc — straight to native binary):**

| Step      | Time     | RSS      |
|-----------|----------|----------|
| parse     | 0.66 ms  | 3,632 KB |
| transform | 0.04 ms  | 3,696 KB |
| SSA build | 1.58 ms  | 4,352 KB |
| ARM64 gen | 1.79 ms  | 4,848 KB |
| link      | 2.48 ms  | 5,216 KB |
| **total** | **~7 ms** | **5,216 KB** |

All v3 steps (parse + transform + gen + write) complete in ~0.11 ms for hello world, ~1.26 ms for test.v with C backend. The ARM64 backend compiles test.v end-to-end in ~7 ms — no external tools, straight to executable.

Peak RSS: 3-5 MB.

## Comparison with V1

Frontend-only (parse + check + gen C, no `cc`):

| Compiler | hello world | test.v (1,002 lines) | Peak RSS (hello) | Peak RSS (test) |
|----------|------------|----------------------|------------------|-----------------|
| V1 (0.5.1) | 93 ms | 105 ms | 70 MB | 78 MB |
| **v3** | **0.11 ms** | **1.26 ms** | **3 MB** | **4 MB** |

v3 is **~850x faster** and uses **~20x less memory** than V1 for frontend compilation.

V1 parses 143 files (~33K lines) of builtins for every compilation. v3 parses only the input file and generates standalone C with a minimal preamble — no builtin parsing overhead.

Generated C output for hello world: V1 emits 4,147 lines, v3 emits 73 lines.

The ARM64 backend goes further — compiling test.v to a native binary in ~7 ms total, with no dependency on any external C compiler or linker.

Measured on macOS (Apple Silicon), warm runs. V1 built from `~/code/v5/v` (V 0.5.1).
