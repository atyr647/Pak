# Phase 4: Preprocessor & Multi-File Support

Goal: handle C preprocessor constructs and support converting multi-file C projects
(multiple `.c` + `.h` files) into coherent PAK modules.

## 4.1 — #define → const / Inline

### Simple Constants

```c
#define MAX_ENTITIES 64
#define GRAVITY 0x0000CCCC  // 0.8 in Q16.16
#define SCREEN_W 320
#define SCREEN_H 240
#define PI 3.14159265f
```

→

```pak
const MAX_ENTITIES: i32 = 64
const GRAVITY: fix16.16 = 0.8 as fix16.16   // with idiom detection
const SCREEN_W: i32 = 320
const SCREEN_H: i32 = 240
const PI: f32 = 3.14159265
```

Rules:
- Integer `#define` → `const NAME: i32 = value`.
- Float `#define` → `const NAME: f32 = value`.
- Hex constants used in fixed-point context (Phase 3 idiom detection) → `fix16.16` literals.
- Type inference: if the constant is only used in a specific type context, use that type.

### Function-like Macros

```c
#define MIN(a, b) ((a) < (b) ? (a) : (b))
#define MAX(a, b) ((a) > (b) ? (a) : (b))
#define ABS(x) ((x) < 0 ? -(x) : (x))
#define ARRAY_LEN(arr) (sizeof(arr) / sizeof((arr)[0]))
```

→

```pak
// Option A: generic functions (if PAK generics support the pattern)
fn min<T>(a: T, b: T) -> T { if a < b { a } else { b } }
fn max<T>(a: T, b: T) -> T { if a > b { a } else { b } }
fn abs<T>(x: T) -> T { if x < 0 { -x } else { x } }

// Option B: inline at call sites (for complex macros)
// ARRAY_LEN(arr) → arr.len (if arr is a known-size array)
```

Strategy:
- Recognize common utility macros (`MIN`, `MAX`, `ABS`, `CLAMP`, `SWAP`) → generic functions.
- `ARRAY_LEN` / `ARRAY_COUNT` → `.len` property or `sizeof` expression.
- Type-specific macros: inline at call sites with appropriate type casts.
- Complex macros (multi-statement, using `do { } while(0)`): expand and transpile the
  expanded body. Emit as a function if the macro is used in multiple places.

### Conditional Compilation

```c
#ifdef DEBUG
    printf("debug: x = %d\n", x);
#endif

#if defined(N64)
    #include <libdragon.h>
#else
    #include <SDL.h>
#endif
```

→

```pak
// Option A: strip to target platform (default for decomp)
// Just keep the N64 branch, drop SDL

// Option B: cfg annotation
@cfg(DEBUG)
debug.log("debug: x = ", x)
```

Strategy:
- Default: resolve `#ifdef` for the target platform (N64). Keep the relevant branch, drop
  the rest.
- `--preserve-ifdefs` flag: convert to `@cfg(FEATURE)` annotations where possible.
- `#ifdef DEBUG` → `@cfg(DEBUG)` (natural mapping to PAK's conditional compilation).

## 4.2 — #include → use / Module Resolution

### Header File Analysis

C headers serve multiple purposes that PAK handles differently:

| C Header Pattern | PAK Equivalent |
|-----------------|----------------|
| Type declarations (struct, enum, typedef) | Declarations in `.pk64` file (shared via module) |
| Function prototypes | Not needed — PAK resolves within module |
| `#define` constants | `const` declarations |
| `extern` variable declarations | `extern` declarations or `use` imports |
| Inline function definitions | Regular `fn` definitions |

### Conversion Strategy

1. **Parse all `.h` files first** to build a type/symbol table.
2. **Parse each `.c` file** using the symbol table for type resolution.
3. **Merge `.c` + `.h` pairs**: If `player.c` includes `player.h`, merge them into one
   `player.pk64` module.
4. **Shared headers** (`types.h`, `common.h`): Become a shared PAK module that others `use`.

### Example

```
project/
├── include/
│   ├── types.h       # shared type definitions
│   ├── player.h      # Player struct + function prototypes
│   └── enemy.h       # Enemy struct + function prototypes
├── src/
│   ├── main.c
│   ├── player.c
│   └── enemy.c
```

→

```
project_pak/
├── types.pk64         # shared types (from types.h)
├── player.pk64        # merged player.h + player.c
├── enemy.pk64         # merged enemy.h + enemy.c
└── main.pk64          # main.c, with `use player` and `use enemy`
```

### Include Graph Resolution

1. Build the full `#include` dependency graph.
2. Identify "leaf" headers (included by many files) → shared PAK modules.
3. Identify "paired" headers (`foo.h` + `foo.c`) → single PAK module.
4. Resolve circular includes by merging into a single module or using forward references.

## 4.3 — Multi-File Project Conversion

### Batch Mode CLI

```
pak convert project/src/ \
    --include project/include/ \
    --output project_pak/ \
    --decomp
```

### Steps

1. Discover all `.c` and `.h` files.
2. Run the preprocessor to resolve `#include` chains and `#define` constants.
3. Build the global type table (all structs, enums, typedefs across all files).
4. Convert each `.c` file individually, referencing the global type table.
5. Emit `use` declarations for cross-module references.
6. Write each `.pk64` file to the output directory.

### Handling Extern Declarations

```c
// player.h
extern int player_count;
void player_spawn(Vec2 pos);

// player.c
int player_count = 0;
void player_spawn(Vec2 pos) { /* ... */ }
```

In the merged `player.pk64`:
```pak
static mut player_count: i32 = 0

fn spawn(pos: Vec2) { ... }
```

Other modules that reference `player_count` or call `player_spawn`:
```pak
use player

entry {
    player.spawn(Vec2 { x: 0.0, y: 0.0 })
}
```

## 4.4 — Milestone Test

A 3-file C project with:
- A shared `types.h` (structs, enums, constants).
- Two implementation files that `#include` the shared header.
- Cross-file function calls.
- `#define` constants and one function-like macro.

The transpiler produces 3 `.pk64` files with correct `use` declarations, and all three
compile and type-check successfully.
