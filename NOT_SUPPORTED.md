# Pak — What Is Not Supported

This file is an explicit list of things Pak does **not** support.
It exists specifically to prevent AI models from hallucinating features.

**Rule:** If something is on this list, do not generate it. If it's not in
`LANGUAGE.md` either, also do not generate it.

---

## Language Constructs That Do Not Exist in Pak

### No `fn main()`
There is no `main` function. The entry point is the `entry { }` block.
```
-- WRONG:
fn main() { ... }

-- CORRECT:
entry { ... }
```

### No Semicolon-Terminated Statements
Pak is newline-delimited. Semicolons are not required and should not be added
to every line. (Semicolons are valid as separators between top-level decls
but are never required after statements.)
```
-- WRONG:
let x: i32 = 5;
return x;

-- CORRECT:
let x: i32 = 5
return x
```

### No `&&`, `||`, `!` Operators
Logical operators are words, not symbols.
```
-- WRONG:
if a && b { ... }
if !ready { ... }

-- CORRECT:
if a and b { ... }
if not ready { ... }
```

### No Implicit Type Conversions
All numeric conversions are explicit with `as`. There is no implicit promotion,
no implicit narrowing, and no implicit integer-to-bool coercion.
```
-- WRONG:
let f: f32 = some_i32    -- no implicit int→float
if count { ... }          -- no implicit int→bool

-- CORRECT:
let f: f32 = some_i32 as f32
if count != 0 { ... }
```

### No `null` Keyword
Use `none`. The keyword `null` does not exist.
```
-- WRONG:
let p: *Foo = null

-- CORRECT:
let p: ?*Foo = none
```

### No `void` Type
Functions with no return value simply omit the `->` return type.
```
-- WRONG:
fn foo() -> void { ... }

-- CORRECT:
fn foo() { ... }
```

### No If-Expressions
`if` is a statement, not an expression. You cannot assign the result of an
`if`/`else` to a variable. Declare the variable with a default and assign in
the branch instead (locals are mutable by default).
```
-- WRONG:
let color: u32 = if selected { RED } else { GRAY }

-- CORRECT:
let color: u32 = GRAY
if selected { color = RED }
```

### No `class` Keyword
Use `struct` with an `impl` block for methods.
```
-- WRONG:
class Player { ... }

-- CORRECT:
struct Player { ... }
impl Player { fn method(self: *Player) { ... } }
```

### No Exceptions
There is no `try`, `throw`, `catch` (as a keyword for exceptions), `raise`,
`except`, or `finally`. Error handling uses `Result(Ok, Err)`.
```
-- WRONG:
try { risky() } catch (e) { ... }
throw MyError()

-- CORRECT:
fn risky() -> Result(i32, MyError) { ... }
match risky() {
    .ok(v)  => { ... }
    .err(e) => { ... }
}
```

Note: `catch` IS a keyword in Pak but it works as a postfix expression on
`Result` values, not as an exception mechanism. See `LANGUAGE.md`.

### No Garbage Collector
Pak has no GC, no reference counting, and no automatic memory management.
All heap allocation uses `alloc(T)` / `free(ptr)` explicitly.
Do not generate code that assumes memory is automatically freed.

### No `new` / `delete`
```
-- WRONG:
let p = new Player()
delete p

-- CORRECT:
let p: *Player = alloc(Player)
free(p)
```

### No Rust-Style `?` Propagation Operator
```
-- WRONG:
let val = might_fail()?

-- CORRECT:
let result = might_fail()
let val = result catch |e| { return err(e) }
-- or:
match might_fail() {
    .ok(v)  => { ... }
    .err(e) => { return err(e) }
}
```

### No `if let` / `while let`
Pattern-binding in conditions does not exist.
```
-- WRONG:
if let Some(x) = maybe_value { ... }

-- CORRECT:
match maybe_value {
    .some(x) => { ... }
    .none    => {}
}
```

### No `#include`, `#define`, `#pragma`
Pak is not a C preprocessor. These directives don't exist.
C interop uses `extern "C" { ... }` blocks.

### No `typedef`
Use `struct`, `enum`, `variant`, or `const` instead.

### No Block Expressions Returning Values
Blocks (`{ ... }`) are statements, not expressions. You cannot do:
```
-- WRONG:
let x = { let a = 5; a + 1 }

-- CORRECT:
fn add_one(a: i32) -> i32 { return a + 1 }
let x = add_one(5)
```

### No Closures Capturing Environment [Currently]
Lambda syntax exists (`fn(x: i32) -> i32 = x + 1`) but closures that
capture variables from outer scope are not fully implemented.
Do not generate code relying on captured variables in function literals.

### No String Interpolation with `$` or `{}`
Pak may have format strings but the standard way to print formatted
output is via `debug.log(...)`. Do not invent `"${var}"` or `f"..."` syntax.

### No Trait Default Methods [Currently]
Traits can declare method signatures but not provide default implementations.

### No `impl Trait` Return Type
```
-- WRONG:
fn get_updatable() -> impl Updatable { ... }
```
Use explicit types or trait objects (`*dyn Trait`) instead.

### No Variadic Functions
Pak does not support variadic function definitions (e.g., `fn foo(args: ...)`).
The N64 `debug.log` module internally maps to `debugf` (variadic C function)
but this is handled by the runtime, not by Pak syntax.

### No Operator Overloading
You cannot define custom `+`, `*`, etc. for user types.

### Integer Pattern Matching — Supported but Limited
Integer literals are accepted as match arm patterns, but the match is not
exhaustiveness-checked (unlike enum/variant match). Use if/elif chains if you
want clarity; use match if the literal pattern reads better.
```
-- WORKS (but not exhaustiveness-checked):
match x {
    0 => { }
    1 => { }
    _ => { }  -- wildcard recommended to silence ambiguity
}

-- ALSO FINE for integer branching:
if x == 0 { }
elif x == 1 { }
```
Range patterns (`0..10 =>`) are not supported — see below.

### No Range Patterns in Match
```
-- WRONG:
match x {
    0..10 => { ... }
}
```

### No Struct Destructuring in `let`
```
-- WRONG:
let { x, y } = point

-- CORRECT:
let x = point.x
let y = point.y
```

### No Tuple Destructuring in `let`
```
-- WRONG:
let (a, b) = my_tuple

-- CORRECT:
let a = my_tuple.0
let b = my_tuple.1
```

---

## Standard Library / API Rules

### Do Not Invent Module Names
The only valid N64 module names (after `use n64.X`) are:
`display`, `controller`, `rdpq`, `sprite`, `timer`, `audio`, `debug`,
`dma`, `cache`, `eeprom`, `rumble`, `cpak`, `tpak`

The only valid 3D module is `t3d`.

There is no `n64.math`, `n64.memory`, `n64.string`, `n64.input`,
`n64.graphics`, `n64.sound`, `n64.file`, `n64.network`, or any other module
not listed in `STDLIB.md`.

### Do Not Invent Function Signatures
If a function is not in `STDLIB.md`, it doesn't exist. Do not invent:
- `display.clear()` — use `rdpq.attach_clear()`
- `controller.button_pressed(btn)` — use the struct fields on the return of `controller.read()`
- `timer.sleep(ms)` — does not exist
- `debug.print(...)` — use `debug.log(...)`
- Any `string.*` module — does not exist
- Any `math.*` module functions beyond what's documented

### Do Not Invent Container Methods
There are no `.push()`, `.pop()`, `.len()`, `.append()`, `.insert()`, etc.
methods on built-in container types unless explicitly documented.

### No Standard String Type
Pak uses `*c_char` for C-compatible strings. There is no heap `String` type,
no `.to_string()`, no string concatenation with `+`, no `.length` property.

### No Standard Print / IO
There is no `print()`, `println()`, `printf()`, `puts()`, `std.out.write()`.
For debug output, use `debug.log(msg)` via `use n64.debug`.

---

## Known Typechecker / Parser Limitations (Current Implementation)

These are not design choices — they are current implementation gaps.
Work around them as shown.

### `let _ = expr` Does Not Work
`_` is a keyword token, not a valid identifier in `let`.
```
-- WRONG (parse error):
let _ = some_value

-- CORRECT: just use the value directly, or assign to a named variable
some_global = some_value
```

### Variant Payload Binding in Match Is Not Typechecked
Parsing `.case(x) => { use x }` succeeds, but the bound name `x` is not
tracked by the typechecker, causing E010 (unknown name).
```
-- COMPILES but typechecker rejects the binding variable:
match shape {
    .circle(r) => { return r * r * 3.14 }  -- 'r' unknown to typechecker
}

-- WORKAROUND: dispatch only, store data in structs
match shape {
    .circle => { return self.radius * self.radius * 3.14 }
}
```

### `.ok(val)` and `.err(e)` Cannot Be Used as Match Patterns
`ok` and `err` are reserved keywords. The pattern parser only accepts
identifiers, so `.ok(val)` fails with E002.
```
-- WRONG (parse error E002):
match result {
    .ok(v)  => { use(v) }
    .err(e) => { handle(e) }
}

-- WORKAROUND: use a struct with a success flag, or restructure
-- to avoid branching on Result in the current implementation
```

### Keyword Names Cannot Be Used as Variant Cases
Do not name variant cases after keywords: `none`, `ok`, `err`, `true`,
`false`, `undefined`, etc. They will fail in match patterns.
```
-- WRONG:
variant Foo { none, ok, err }

-- CORRECT:
variant Foo { empty, success, failure }
```

### Writing Through `alloc`'d Pointer Then `free` May Fail
The move tracker can consider a pointer consumed after a deref-write,
making `free(ptr)` fail with E010. Keep alloc/free patterns simple.
```
-- MAY FAIL:
let p: *mut i32 = alloc(i32)
*p = 42         -- deref-write may move p in tracker
free(p)         -- E010: unknown name 'p'

-- SAFE:
let p: *mut u8 = alloc(u8, 64)
free(p)         -- no intermediate deref-write
```

---

## Things That Look Plausible But Are Wrong

| What you might write       | Why it's wrong                         | What to write instead             |
|----------------------------|----------------------------------------|-----------------------------------|
| `fn main() { }`            | No main function                       | `entry { }`                       |
| `let x = 5;`               | No semicolons needed                   | `let x = 5`                       |
| `if (cond) { }`            | No parens on conditions                | `if cond { }`                     |
| `a && b`                   | No `&&` operator                       | `a and b`                         |
| `!flag`                    | No `!` unary                           | `not flag`                        |
| `ptr == null`              | No `null`                              | `ptr == none`                     |
| `-> void`                  | No void type                           | omit return type                  |
| `enum E { A, B, C }`       | Commas optional, not required          | `enum E { a\n b\n c }` (valid either way) |
| `match x { 0 => ... }`     | No int patterns in match               | `if x == 0 { ... }`               |
| `x.len()`                  | No `.len()` method on arrays/slices    | pass length separately             |
| `alloc<T>()`               | Wrong alloc syntax                     | `alloc(T)`                        |
| `Result<T, E>`             | Wrong Result syntax                    | `Result(T, E)`                    |
| `Option<T>`                | Wrong Option syntax                    | `Option(T)` or `?T`               |
