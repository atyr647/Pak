# Canonical Pak Examples

These are the **gold-standard reference examples** for the Pak language.
Every file here is known-correct. Use them as templates.

Each example focuses on one concept. They are intentionally small.

| File | Concept |
|------|---------|
| `01_hello.pk64` | Minimal program, entry block, debug output |
| `02_variables.pk64` | `let`, `const`, `static`, assignment |
| `03_functions.pk64` | `fn`, parameters, return values, pointer params |
| `04_structs.pk64` | `struct`, struct literals, field access, `impl` methods |
| `05_enums.pk64` | `enum`, discriminant types, `match` on enum |
| `06_variants.pk64` | `variant` (tagged union), payload extraction in `match` |
| `07_control_flow.pk64` | `if/elif/else`, `loop`, `while`, `do-while`, `for`, `break`, `continue` |
| `08_arrays.pk64` | Fixed-size arrays, indexing, passing to functions |
| `09_pointers.pk64` | `*T`, `*mut T`, `?*T`, `&`, `*`, `alloc`, `free` |
| `10_result.pk64` | `Result(Ok, Err)`, `ok()`, `err()`, match on result |
| `11_defer.pk64` | `defer` for cleanup |
| `12_const_static.pk64` | `const` vs `static`, `@aligned` |
| `13_extern.pk64` | `extern "C"` FFI, `extern const` |
| `14_assets.pk64` | `asset` declarations, sprite rendering |
| `15_game_loop.pk64` | Canonical N64 game loop structure |
| `16_fixed_point.pk64` | `fix16.16` arithmetic |
| `17_annotations.pk64` | `@hot`, `@aligned`, `@cfg` |
| `18_dma.pk64` | DMA with cache writeback (safety pattern) |
| `19_traits.pk64` | `trait`, `impl for`, trait objects [PARTIAL] |
| `20_multifile.pk64` | `module`, multi-file structure [PARTIAL] |
