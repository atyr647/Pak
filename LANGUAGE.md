# Pak Language Reference

This is the canonical syntax reference for the Pak programming language.
Generated from the parser, lexer, and AST source — not from aspirational docs.

Every feature is tagged:
- `[IMPLEMENTED]` — fully parsed, type-checked, and code-generated
- `[PARTIAL]` — parsed and may type-check, but codegen may be incomplete
- `[PLANNED]` — exists in design docs but NOT in the current implementation

**Do not use `[PLANNED]` features in generated code.**

---

## Table of Contents

1. [File Structure](#1-file-structure)
2. [Comments](#2-comments)
3. [Keywords](#3-keywords)
4. [Primitive Types](#4-primitive-types)
5. [Composite Types](#5-composite-types)
6. [Declarations — Top Level](#6-declarations--top-level)
7. [Functions](#7-functions)
8. [Variables and Constants](#8-variables-and-constants)
9. [Expressions](#9-expressions)
10. [Operators and Precedence](#10-operators-and-precedence)
11. [Statements and Control Flow](#11-statements-and-control-flow)
12. [Pattern Matching](#12-pattern-matching)
13. [Modules and Imports](#13-modules-and-imports)
14. [Assets](#14-assets)
15. [Entry Point](#15-entry-point)
16. [Annotations](#16-annotations)
17. [Memory](#17-memory)
18. [Inline Assembly](#18-inline-assembly)
19. [Fixed-Point Numbers](#19-fixed-point-numbers)
20. [Error Handling (Result)](#20-error-handling-result)
21. [What Is Never Legal](#21-what-is-never-legal)

---

## 1. File Structure

A `.pk64` file is a flat sequence of top-level declarations. There is no mandatory
header or boilerplate. Order of declarations matters for forward references.

```pak
-- optional imports
use n64.display

-- optional assets
asset bg: Sprite from "bg.png"

-- type declarations (struct, enum, variant, union, trait)
-- function declarations (fn, impl)
-- constants and statics (const, static)
-- entry point (entry { ... })
```

Multiple source files are linked via `module` declarations. [IMPLEMENTED]

---

## 2. Comments

```pak
-- single line comment (preferred)
// single line comment (also valid)
```

There are no block/multi-line comments.

---

## 3. Keywords

Reserved words that cannot be used as identifiers:

```
use       asset     from      entry     module
struct    enum      variant   union     trait
fn        impl      self      extern
let       static    const
if        elif      else
loop      while     do        for       in
match     break     continue  return    defer
and       or        not
as        catch
ok        err
true      false     undefined none
mut       volatile  comptime
sizeof    size_of   offsetof  alignof   align_of
alloc     free
asm       goto      dyn
_
```

---

## 4. Primitive Types

[IMPLEMENTED]

| Type       | Description                        | Size   |
|------------|------------------------------------|--------|
| `i8`       | Signed 8-bit integer               | 1 byte |
| `u8`       | Unsigned 8-bit integer             | 1 byte |
| `i16`      | Signed 16-bit integer              | 2 bytes|
| `u16`      | Unsigned 16-bit integer            | 2 bytes|
| `i32`      | Signed 32-bit integer              | 4 bytes|
| `u32`      | Unsigned 32-bit integer            | 4 bytes|
| `i64`      | Signed 64-bit integer              | 8 bytes|
| `u64`      | Unsigned 64-bit integer            | 8 bytes|
| `f32`      | 32-bit float                       | 4 bytes|
| `f64`      | 64-bit float                       | 8 bytes|
| `bool`     | Boolean (`true` / `false`)         | 1 byte |
| `byte`     | Alias for `u8`                     | 1 byte |
| `c_char`   | C `char` (for C interop)           | 1 byte |

### Fixed-Point Types [IMPLEMENTED]

| Type        | Format   | Storage | Fractional bits |
|-------------|----------|---------|-----------------|
| `fix16.16`  | Q16.16   | `i32`   | 16              |
| `fix10.5`   | Q10.5    | `i16`   | 5               |
| `fix1.15`   | Q1.15    | `i16`   | 15              |

Fixed-point types are first-class. Arithmetic uses MIPS `mult`/`div` sequences.

---

## 5. Composite Types

### Pointer Types [IMPLEMENTED]

```pak
*T           -- immutable pointer to T
*mut T       -- mutable pointer to T
?*T          -- nullable pointer to T (can be none)
*volatile T  -- volatile-qualified pointer (hardware registers)
volatile T   -- volatile value type
```

### Array Types [IMPLEMENTED]

```pak
[N]T         -- fixed-size array of N elements of type T
[N]byte      -- common: byte buffer of size N
```

`N` must be a compile-time integer constant.

### Slice Types [PARTIAL]

```pak
[]T          -- immutable slice (pointer + length)
[]mut T      -- mutable slice
```

### Tuple Types [PARTIAL]

```pak
(T1, T2)     -- two-element tuple
(T1, T2, T3) -- three-element tuple
()           -- unit / empty tuple
```

Access elements with `.0`, `.1`, etc.

### Result Type [IMPLEMENTED]

```pak
Result(OkType, ErrType)
```

Constructed with `ok(value)` and `err(value)`. See [Section 20](#20-error-handling-result).

### Option Type [PARTIAL]

```pak
Option(T)    -- T or none
?T           -- shorthand for Option(T) (nullable value)
```

### Function Pointer Types [PARTIAL]

```pak
fn(A, B) -> R     -- function pointer taking A, B returning R
fn(A)             -- function pointer with no return
```

### Generic Container Types [IMPLEMENTED]

Built-in parameterized types (do NOT invent others):

```pak
Vec(T)              -- growable array (heap)
FixedList(T, N)     -- fixed-capacity list
RingBuffer(T, N)    -- ring buffer, capacity N
FixedMap(K, V, N)   -- fixed-capacity hash map
Pool(T, N)          -- object pool, capacity N
```

N must be a compile-time integer literal. See `examples/canonical/23_containers.pk64`.

### Trait Objects [PARTIAL]

```pak
dyn TraitName        -- dynamic dispatch trait object
*dyn TraitName       -- pointer to trait object
```

---

## 6. Declarations — Top Level

### Struct [IMPLEMENTED]

```pak
struct Name {
    field_name: Type
    field_name: Type
}

-- with annotations
@aligned(16)
struct AlignedBuffer {
    data: [4096]byte
}

-- with default values
struct Config {
    width: i32 = 320
    height: i32 = 240
}

-- generic struct
struct Pair<T> {
    first: T
    second: T
}
```

Field separators: newlines or commas. Trailing comma allowed.

### Enum [IMPLEMENTED]

```pak
enum Name {
    case_one
    case_two
    case_three
}

-- with explicit base type
enum Status: u8 {
    ok
    error
    pending
}

-- with explicit discriminant values
enum Color: u8 {
    red = 0
    green = 1
    blue = 2
}
```

### Variant (Tagged Union / Sum Type) [IMPLEMENTED]

```pak
variant Name {
    case_name                      -- unit case (no data)
    case_name(Type)                -- one payload
    case_name(Type, Type)          -- multiple positional payloads
    case_name { field: Type }      -- named fields
}
```

Examples:

```pak
variant Entity {
    player
    enemy
    projectile(f32, f32)    -- x, y
    none
}

variant Event {
    key_press { key: u8 }
    mouse_move { x: i32, y: i32 }
    quit
}
```

### Union (Untagged) [PARTIAL]

```pak
union Name {
    field_a: TypeA
    field_b: TypeB
}
```

Untagged C-style union. Use `variant` for safe tagged unions.

### Trait [IMPLEMENTED]

```pak
trait Name {
    fn method_name(self: *Self) -> RetType      -- required (no body)
    fn other_method(self: *Self, arg: i32)
    fn with_default(self: *Self) -> i32 {        -- default method (has a body)
        return 0
    }
}
```

A trait method **with a body** is a *default*: an `impl` may omit it and inherit
the default (specialized for the implementing type). A trait method **without a
body** is *required* — an `impl` that omits it raises `E602`.

### Impl Block [IMPLEMENTED]

```pak
impl TypeName {
    fn method(self: *TypeName) { ... }
    fn method_mut(self: *mut TypeName, arg: i32) -> bool { ... }
}

-- generic impl
impl TypeName<T> {
    fn get(self: *TypeName<T>) -> T { ... }
}
```

### Impl Trait [IMPLEMENTED]

```pak
impl TypeName for TraitName {
    fn required_method(self: *TypeName) -> i32 { ... }
    -- methods with a default body in the trait may be omitted here
}
```

### Extern Block [IMPLEMENTED]

Declares C functions for FFI:

```pak
extern "C" {
    fn c_function_name(arg: i32) -> i32
    fn another(ptr: *u8, len: u32)
    -- trailing `...` declares a C-style variadic function (e.g. printf-family)
    fn rdpq_text_printf(x: i32, y: i32, font: i32, fmt: *c_char, ...) -> i32
    static some_global: i32
}

-- extern constant (C macro or extern value)
extern const SCREEN_WIDTH: i32
```

The `...` marker is only meaningful for `extern` declarations — it tells the
compiler the C function accepts extra trailing arguments. Pak itself has no
`va_arg` mechanism, so you cannot write a variadic Pak function body.

---

## 7. Functions

[IMPLEMENTED]

```pak
-- basic function
fn name(param: Type, param2: Type) -> ReturnType {
    -- body
}

-- no return value (void)
fn name(param: Type) {
    -- body
}

-- generic function
fn name<T>(param: T) -> T {
    return param
}

-- method (first param must be named 'self')
fn update(self: *Player, dt: f32) {
    -- ...
}

-- with annotation
@hot
fn critical_path(data: *u8, len: i32) {
    -- ...
}
```

### Parameters

- Parameters are immutable by default.
- `mut param: Type` makes the parameter mutable (copy-on-write for value types).
- Default values: `fn foo(x: i32 = 0)` [PARTIAL]
- Named arguments at call site: `foo(x: 5, y: 10)` [PARTIAL]

### Methods (inside `impl`)

```pak
impl Player {
    fn init(self: *Player) {
        self.x = 0.0
        self.y = 0.0
    }

    fn move(self: *mut Player, dx: f32, dy: f32) {
        self.x += dx
        self.y += dy
    }
}
```

Call methods with dot syntax:

```pak
let p: Player = undefined
p.init()        -- calls Player_init(&p)
p.move(1.0, 0.0)
```

---

## 8. Variables and Constants

### Let (local variable) [IMPLEMENTED]

```pak
let name: Type = value
let name = value           -- type inferred
let mut name: Type = value -- explicit mutable (all lets are mutable by default)
```

Variables in Pak are **mutable by default**. The `mut` keyword is redundant but valid.

### Static (global variable) [IMPLEMENTED]

```pak
static name: Type = value
static name: Type = undefined    -- zero/undefined initialized
```

Statics live for the program lifetime. They are file-scoped unless accessed via module path.

### Const [IMPLEMENTED]

```pak
const NAME: Type = expr
const MAX_SIZE = 256        -- type inferred
```

Constants are evaluated at compile time. Maps to `#define` or `static const` in C output.

---

## 9. Expressions

### Literals [IMPLEMENTED]

```pak
42          -- integer
0xFF        -- hex integer
3.14        -- float
3.14f       -- float with explicit suffix
true        -- bool
false       -- bool
"hello"     -- string (null-terminated)
none        -- null/None
undefined   -- uninitialized memory
```

String escape sequences: `\n`, `\t`, `\r`, `\\`, `\"`, `\0`

### Identifiers [IMPLEMENTED]

```pak
x
player_health
MAX_SIZE
```

### Struct Literal [IMPLEMENTED]

```pak
TypeName { field: value, field2: value2 }
TypeName { x: 1.0, y: 0.0, health: 100 }
```

All fields must be specified (no partial struct init unless defaults exist).

### Array Literal [IMPLEMENTED]

```pak
[1, 2, 3]               -- array literal
[0; 256]                -- repeat: 256 zeros (PARTIAL)
```

### Tuple Literal [PARTIAL]

```pak
(1, 2)
(x, y, z)
```

### Function Call [IMPLEMENTED]

```pak
foo(a, b, c)
obj.method(arg)
module.function(arg)
```

### Field Access [IMPLEMENTED]

```pak
player.x
sprite.transform.position
```

### Index Access [IMPLEMENTED]

```pak
arr[i]
buf[offset]
```

### Slice Expression [PARTIAL]

```pak
arr[start..end]
arr[0..len]
```

### Arithmetic and Logic [IMPLEMENTED]

See Section 10 for full operator table.

### Type Cast [IMPLEMENTED]

```pak
value as TargetType
x as f32
ptr as *u8
```

### Address-Of [IMPLEMENTED]

```pak
&value          -- take address (immutable)
&mut value      -- take mutable address
```

### Dereference [IMPLEMENTED]

```pak
*ptr
```

### Range [IMPLEMENTED]

```pak
0..10       -- exclusive range [0, 10)
```

### Result Constructors [IMPLEMENTED]

```pak
ok(value)
err(error_value)
```

### Catch Expression [PARTIAL]

```pak
result catch |err| { fallback_value }
```

Unwraps a `Result`, running the handler block on `err`.

### Null Check Expression [PARTIAL]

```pak
ptr? binding { fallback }
```

### Memory [IMPLEMENTED]

```pak
alloc(Type)           -- allocate one T on heap, returns *T
alloc(Type, n)        -- allocate n T's on heap, returns *T
free(ptr)             -- free heap pointer
```

### Sizeof / Offsetof / Alignof [IMPLEMENTED]

```pak
sizeof(Type)          -- byte size of a type
sizeof(expr)          -- byte size of expression's type
offsetof(Struct, field)   -- byte offset of a field
alignof(Type)         -- alignment requirement
align_of(Type)        -- alias
size_of(Type)         -- alias
```

### Closures / Lambda [PARTIAL]

```pak
fn(x: i32) -> i32 { x + 1 }
fn(x: i32) -> i32 = x + 1    -- expression body
```

### Explicit Type Arguments [IMPLEMENTED]

Generic functions and generic struct literals accept explicit type arguments
with angle-bracket syntax directly before the call/braces. (Rust-style `::<>`
turbofish is **not** supported.)

```pak
foo<i32>(arg)            -- explicit type argument on a generic call
pair<i32, f32>(a, b)     -- multiple type arguments
Box<i32> { value: 42 }   -- explicit type argument on a generic struct literal
```

When omitted, type arguments are inferred from the call arguments.

### Inline Assembly Expression [IMPLEMENTED]

```pak
asm("template" : outputs : inputs : clobbers)
```

---

## 10. Operators and Precedence

Listed from **lowest** to **highest** precedence:

| Level | Operators              | Description               | Associativity |
|-------|------------------------|---------------------------|---------------|
| 1     | `or`                   | Logical OR                | left          |
| 2     | `and`                  | Logical AND               | left          |
| 3     | `==` `!=` `<` `>` `<=` `>=` | Comparison           | left          |
| 4     | `\|`                    | Bitwise OR                | left          |
| 5     | `^`                    | Bitwise XOR               | left          |
| 6     | `&`                    | Bitwise AND               | left          |
| 7     | `<<` `>>`              | Bit shift                 | left          |
| 8     | `+` `-`                | Addition, subtraction     | left          |
| 9     | `*` `/` `%`            | Multiply, divide, modulo  | left          |
| 10    | `not` `-` `~` `*` `&`  | Unary ops                 | right         |
| 11    | `as`                   | Type cast                 | left          |
| 12    | `.` `[]` `()`          | Field, index, call        | left          |

**Logical operators use words:** `and`, `or`, `not` — NOT `&&`, `||`, `!`

### Assignment Operators [IMPLEMENTED]

```
=   +=   -=   *=   /=   %=
&=  |=   ^=   <<=  >>=
```

---

## 11. Statements and Control Flow

### Variable Declaration (as statement)

```pak
let x: i32 = 5
let name = "pak"
static buf: [256]byte = undefined
```

### Assignment [IMPLEMENTED]

```pak
x = 10
player.x += 1.0
arr[i] = value
*ptr = new_value
```

### If / Elif / Else [IMPLEMENTED]

```pak
if condition {
    -- ...
}

if condition {
    -- ...
} elif other_condition {
    -- ...
} else {
    -- ...
}
```

Conditions do **not** require parentheses. Braces are required.

### Loop (infinite) [IMPLEMENTED]

```pak
loop {
    -- runs forever until break
    if done { break }
}
```

### While [IMPLEMENTED]

```pak
while condition {
    -- ...
}
```

### Do-While [IMPLEMENTED]

```pak
do {
    -- runs at least once
} while condition
```

### For Loop [IMPLEMENTED]

Iterates over a range or iterable:

```pak
for x in 0..10 {
    -- x goes 0, 1, ..., 9
}

-- with index
for i, x in collection {
    -- i is index, x is element
}
```

### Match [IMPLEMENTED]

See [Section 12](#12-pattern-matching).

### Break / Continue [IMPLEMENTED]

```pak
break           -- exit loop
continue        -- next iteration
break value     -- break with value (PARTIAL)
```

### Return [IMPLEMENTED]

```pak
return          -- void return
return value    -- return a value
```

### Defer [IMPLEMENTED]

Runs the body when the enclosing scope exits (in reverse order of declaration):

```pak
defer { cleanup() }
defer free(ptr)
```

### Goto / Label [PARTIAL]

```pak
goto label_name
label_name:
```

### Comptime If [PARTIAL]

```pak
comptime if FEATURE_FLAG {
    -- included if flag defined at compile time
} else {
    -- ...
}
```

Maps to `#if` / `#else` / `#endif` in C output.

### Inline Assembly Statement [IMPLEMENTED]

```pak
asm {
    "addiu $v0, $zero, 0"
    "jr $ra"
    "nop"
}
```

---

## 12. Pattern Matching

[IMPLEMENTED]

### Match on Enum

```pak
match direction {
    .north => { go_north() }
    .south => { go_south() }
    .east  => { go_east()  }
    .west  => { go_west()  }
}
```

Match arms use `.case_name` syntax. **Match must be exhaustive** — all cases covered
or a compile error `E301` is raised.

### Match on Variant with Payload

```pak
match entity {
    .player          => { handle_player() }
    .enemy           => { handle_enemy() }
    .projectile(x, y) => { handle_proj(x, y) }
    .none            => {}
}
```

### Match with Guard [PARTIAL]

```pak
match value {
    .some(x) if x > 0 => { positive(x) }
    .some(x)           => { non_positive(x) }
    .none              => {}
}
```

### Wildcard Pattern [IMPLEMENTED]

```pak
match state {
    .playing => { update() }
    _        => {}          -- matches everything else
}
```

---

## 13. Modules and Imports

### Use Declaration [IMPLEMENTED]

```pak
use n64.display
use n64.controller
use n64.rdpq
use n64.timer
use n64.audio
use n64.debug
use n64.dma
use n64.cache
use n64.eeprom
use n64.rumble
use n64.cpak
use n64.tpak
use t3d              -- 3D library
```

After `use n64.display`, call functions as `display.init(...)`, `display.get()`, etc.

### Use with Alias [PARTIAL]

```pak
use n64.display as disp
```

### Module Declaration [IMPLEMENTED]

```pak
module my.module.name
```

Declares the current file as belonging to a module. In a multi-file project,
every `.pk64` file under the project root is parsed, type-checked against a
shared symbol environment, and compiled. A `use my.module.name` brings another
file's module into scope; functions and types are shared via a flat namespace.

- Exactly one `entry` block may exist across the whole project (`E103`).
- A `use path` that matches no declared `module path` raises `E105`.
- Each module compiles to its own `.c` plus a generated `pakmod_<path>.h`
  header (the `pakmod_` prefix avoids colliding with C standard-library
  headers such as `<math.h>`).

---

## 14. Assets

[IMPLEMENTED]

```pak
asset name from "path/to/file.ext"
asset name: AssetType from "path/to/file.ext"
```

Asset types: `Sprite`, `Model`, `Sound`, `Data` (and others defined by the runtime).

Examples:

```pak
asset player_sprite: Sprite from "sprites/player.png"
asset level_data from "levels/level1.bin"
asset bgm: Sound from "audio/theme.wav"
```

---

## 15. Entry Point

[IMPLEMENTED]

Every executable Pak program has exactly one `entry` block:

```pak
entry {
    -- program starts here
    -- runs after hardware init
}
```

- There is no `fn main()`. Use `entry { ... }`.
- There is only one `entry` per program (not per file in multi-file projects).
- The entry block has an implicit `loop {}` wrapping if you want to run forever — you must write the loop explicitly.

---

## 16. Annotations

[IMPLEMENTED]

Annotations appear immediately before a declaration or field.

```pak
@hot                    -- mark function as hot (optimize for speed)
@aligned(N)             -- set alignment to N bytes (N must be power of 2)
@cfg(FEATURE)           -- include only if FEATURE is defined
@cfg(not(FEATURE))      -- include only if FEATURE is NOT defined
```

Examples:

```pak
@hot
fn render_frame(fb: *u8) { ... }

@aligned(16)
struct DMABuffer {
    data: [4096]byte
}

@cfg(DEBUG)
fn debug_print(msg: *c_char) { ... }
```

---

## 17. Memory

[IMPLEMENTED]

Pak uses **manual memory management**. No garbage collector.

```pak
-- allocate on heap
let ptr: *i32 = alloc(i32)
let arr: *f32 = alloc(f32, 64)     -- array of 64 floats

-- free heap memory
free(ptr)
free(arr)

-- stack allocation: use let with fixed array
let buf: [256]byte = undefined

-- take address of stack variable
let p: *i32 = &my_int
let mp: *mut i32 = &mut my_int
```

DMA safety rules (enforced by typechecker):

- **E201**: Buffer passed to DMA must have `data_cache_hit_writeback` called first.
- **E202**: Buffer passed to DMA must be `@aligned(16)`.

---

## 18. Inline Assembly

[IMPLEMENTED]

### Statement form (bare asm block):

```pak
asm {
    "li $v0, 0"
    "jr $ra"
    "nop"
}
```

### Expression form (with I/O constraints):

```pak
asm("instruction" : outputs : inputs : clobbers)
```

---

## 19. Fixed-Point Numbers

[IMPLEMENTED]

```pak
let a: fix16.16 = 1.5
let b: fix16.16 = 2.0
let c: fix16.16 = a * b    -- uses MIPS mult sequence, result is fix16.16
let d: fix16.16 = a / b    -- calls __pak_fix16_div runtime helper
```

Arithmetic between same fixed-point types works with `+`, `-`, `*`, `/`.
Cast between fixed-point and integer with `as`:

```pak
let i: i32 = a as i32        -- truncates fractional part
let f: fix16.16 = i as fix16.16
```

---

## 20. Error Handling (Result)

[IMPLEMENTED]

```pak
fn load(path: *c_char) -> Result(i32, LoadError) {
    if bad { return err(LoadError.file_not_found) }
    return ok(42)
}

-- call and handle
let result = load("data.bin")
match result {
    .ok(val)  => { use_value(val) }
    .err(e)   => { handle_error(e) }
}
```

`ok(v)` and `err(e)` are built-in constructors, not function calls to library code.

---

## 21. What Is Never Legal

These constructs **do not exist** in Pak. Do not generate them.

- `fn main()` — use `entry { }` instead
- `;;` or `;` after every statement — Pak is newline-delimited
- `&&`, `||`, `!` — use `and`, `or`, `not`
- `->` in expressions (only in function signatures and match arms via `=>`)
- Implicit numeric conversions — all casts are explicit with `as`
- `null` — use `none`
- `void` return type — omit the `->` entirely
- `#include`, `#define`, `#pragma` — Pak is not C
- `class` — use `struct` + `impl`
- Exceptions / `try` / `throw` — use `Result(Ok, Err)`
- `new` / `delete` — use `alloc()` / `free()`
- Rust-style `?` operator — use `catch` or explicit `match`
- `if let` / `while let` — use `match` or `null_check`
- Trailing `?` on types meaning Option — use `Option(T)` or `?T`
- `:=` (Go-style) — use `let`
- `=>` outside of match arms
- Block-level `use` — imports are top-level only
