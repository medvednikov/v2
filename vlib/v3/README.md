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
| flat parser  | 2,829 |
| C gen       | 817   |
| flat AST    | 230   |
| transformer | 206   |
| driver      | 79    |
| **total**   | **4,161** |

The flat parser covers the full V language (all constructs from the old 3,991-line v2 parser), but in ~30% fewer lines thanks to the flat AST representation.

## Performance

Compiling `hello world` (`println('hello world')`):

| Step      | Time     | RSS      |
|-----------|----------|----------|
| parse     | 0.08 ms  | 2,720 KB |
| transform | 0.01 ms  | 2,784 KB |
| gen C     | 0.03 ms  | 2,880 KB |
| write     | 0.14 ms  | 2,896 KB |
| cc        | 38 ms    | 2,912 KB |
| **total** | **~39 ms** | **2,912 KB** |

Compiling `test.v` (1,002 lines, 20 test sections: structs, globals, match, recursion, nested loops, many args, mut params, assert, heap alloc, bitwise, shifts, modulo, pointers, nested structs, negatives):

| Step      | Time     | RSS      |
|-----------|----------|----------|
| parse     | 0.27 ms  | 3,056 KB |
| transform | 0.03 ms  | 3,088 KB |
| gen C     | 0.44 ms  | 3,456 KB |
| write     | 0.15 ms  | 3,456 KB |
| cc        | 38 ms    | 3,456 KB |
| **total** | **~39 ms** | **3,456 KB** |

All v3 steps (parse + transform + gen + write) complete in ~0.26 ms for hello world, ~0.89 ms for the full test suite. The C compiler (`cc`) dominates at ~38 ms.

Peak RSS: ~3 MB.

Measured on macOS (Apple Silicon), warm runs.
