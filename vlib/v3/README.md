# v3

Clean rewrite of the V compiler. Reuses v2's scanner, uses a flat AST parser with Pratt parsing, a transformer for AST simplification (match lowering), and a direct flat-AST-to-C backend.

## Architecture

```
source → scanner → flat parser → flat AST → transform → gen C → cc
```

The parser directly emits a flat AST — no recursive AST intermediate, no flatten step. All nodes live in a single `[]Node` array with children as indices into a separate `[]NodeId` array. No pointer chasing, no recursive sum types during code generation.

The transformer lowers match statements to if/else chains and collects struct/global type info.

## Code size

| Component   | Lines |
|-------------|-------|
| flat parser  | 2,899 |
| C gen       | 848   |
| flat AST    | 230   |
| transformer | 209   |
| driver      | 79    |
| **total**   | **4,265** |

The flat parser covers the full V language (all constructs from the old 3,991-line v2 parser), but in ~30% fewer lines thanks to the flat AST representation.

## Performance

Compiling `hello world` (`println('hello world')`):

| Step      | Time     | RSS      |
|-----------|----------|----------|
| parse     | 0.03 ms  | 2,784 KB |
| transform | 0.00 ms  | 2,832 KB |
| gen C     | 0.02 ms  | 2,928 KB |
| write     | 0.08 ms  | 2,944 KB |
| cc        | 35 ms    | 2,992 KB |
| **total** | **~35 ms** | **2,992 KB** |

Compiling `test.v` (1,002 lines, 20 test sections: structs, globals, match, recursion, nested loops, many args, mut params, assert, heap alloc, bitwise, shifts, modulo, pointers, nested structs, negatives):

| Step      | Time     | RSS      |
|-----------|----------|----------|
| parse     | 0.65 ms  | 3,584 KB |
| transform | 0.04 ms  | 3,600 KB |
| gen C     | 0.45 ms  | 3,952 KB |
| write     | 0.16 ms  | 3,968 KB |
| cc        | 38 ms    | 4,000 KB |
| **total** | **~40 ms** | **4,000 KB** |

All v3 steps (parse + transform + gen + write) complete in ~0.13 ms for hello world, ~1.30 ms for the full test suite. The C compiler (`cc`) dominates at ~35-38 ms.

Peak RSS: ~3-4 MB.

## Comparison with V1 and V2

Frontend-only (parse + check + gen C, no `cc`):

| Compiler | hello world | test.v | Peak RSS (hello) | Peak RSS (test) |
|----------|------------|--------|------------------|-----------------|
| V1 (0.5.1) | 86 ms | 220 ms | 72 MB | 148 MB |
| V2 | 49 ms (scan+parse only†) | 55 ms (scan+parse only†) | 78 MB | 83 MB |
| **v3** | **0.13 ms** | **1.30 ms** | **3 MB** | **4 MB** |

† V2 currently fails during type checking; only scan+parse time is reported. Full compilation would be higher.

V1 and V2 parse 143 files (~33K lines) of builtins for every compilation. v3 parses only the input file and generates standalone C with a minimal preamble — no builtin parsing overhead.

Generated C output for hello world: V1 emits 4,141 lines, v3 emits 73 lines.

Measured on macOS (Apple Silicon), warm runs.
