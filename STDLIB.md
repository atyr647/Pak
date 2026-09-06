# Pak Standard Library and Builtin Reference

This is the canonical reference for everything that exists in Pak outside of
user-defined code. Do not invent functions, modules, or types not listed here.

The authoritative source for the module surface is `tcl/module_api.tcl`
(union of `CG_API` and `CG_API_LAMBDA` in `tcl/cg_tables.tcl`). The generated
index below is produced by `tclsh tcl/tools/gen_stdlib.tcl`. The checker uses
the same tables: a function not listed is **E010**, never silently lowered.
`pak check --backend mips` further rejects anything whose C symbol is not
defined in `runtime/standalone/runtime.pk64`.

---

## Built-in Keywords / Expressions

These are built into the language — not imported, not from a module.

### Memory

```pak
alloc(T)          -- allocate one T on the heap, returns *T
alloc(T, n)       -- allocate n T's on the heap (array), returns *T
free(ptr)         -- free a heap-allocated pointer
```

### Type Introspection

```pak
sizeof(Type)             -- byte size of a type (compile-time constant)
sizeof(expr)             -- byte size of expression's type
offsetof(StructName, field)  -- byte offset of struct field (compile-time)
alignof(Type)            -- alignment requirement of a type
```

### Result Constructors

```pak
ok(value)          -- construct Result in Ok state
err(value)         -- construct Result in Err state
```

These are keywords, not function calls. They cannot be overloaded.

### Format Strings (WORKS)

A string literal containing `{name}` is a format string. The named locals are
interpolated using a `snprintf` into a static 256-byte buffer at codegen.

```pak
let n: i32 = 42
debug.print("x={n}")        -- emits snprintf(..., "x=%ld", (long)(n))
```

Use them anywhere a `*c_char` is expected (e.g. `debug.print`, `debug.log`).

---

## Built-in Types (not imported)

```pak
i8 u8 i16 u16 i32 u32 i64 u64   -- integers
f32 f64                           -- floats
bool                              -- boolean
byte                              -- alias for u8
c_char                            -- C char, for FFI strings
fix16.16  fix10.5  fix1.15        -- fixed-point numbers
Vec2 Vec3 Vec4                    -- T3D vector types (have built-in methods)
Mat4                              -- T3D 4x4 float matrix (has built-in methods)
Str                               -- fat string (data + len), maps to PakStr
CStr                              -- const char *
Arena                             -- bump allocator (PakArena)
```

Generic containers (parameterized, no import needed):

```pak
Result(OkType, ErrType)   -- error-or-value type
Option(T)                  -- nullable value
Vec(T)                     -- growable heap array      [IMPLEMENTED]
FixedList(T, N)            -- fixed-capacity list      [IMPLEMENTED]
RingBuffer(T, N)           -- ring buffer              [IMPLEMENTED]
FixedMap(K, V, N)          -- fixed-capacity hash map  [IMPLEMENTED]
Pool(T, N)                 -- object pool              [IMPLEMENTED]
```

---

## Built-in Vector / Matrix Instance Methods

`Vec2`, `Vec3`, `Vec4`, and `Mat4` are real value types (they lower to the
libdragon/T3D `T3DVec2`, `T3DVec3`, `T3DVec4`, `T3DMat4`). They have built-in
methods that require **no import** — they are dispatched directly by codegen.

### Vec3 statics and instance methods

```pak
Vec3.zero()      Vec3.one()       Vec3.up()        -- (0,1,0)
Vec3.right()     -- (1,0,0)       Vec3.forward()   -- (0,0,-1)
Vec3.from(x, y, z)                                 -- construct from components
```

| Method | Signature | Description |
|--------|-----------|-------------|
| `.add(other)` | `(Vec3) -> Vec3` | Component-wise add |
| `.sub(other)` | `(Vec3) -> Vec3` | Component-wise subtract |
| `.scale(s)` | `(f32) -> Vec3` | Scale by scalar |
| `.normalize()` | `() -> Vec3` | Unit vector |
| `.length()` | `() -> f32` | Magnitude |
| `.dot(other)` | `(Vec3) -> f32` | Dot product |
| `.cross(other)` | `(Vec3) -> Vec3` | Cross product |
| `.distance_to(other)` | `(Vec3) -> f32` | Euclidean distance |
| `.direction_to(other)` | `(Vec3) -> Vec3` | Normalized direction |
| `.negate()` | `() -> Vec3` | Negate (scale by -1) |

Methods chain: `pos.add(v).normalize()`.

### Vec2 statics and instance methods

```pak
Vec2.zero()      Vec2.one()
```

| Method | Description |
|--------|-------------|
| `.add(other)` | Component-wise add |
| `.sub(other)` | Component-wise subtract |
| `.scale(s)` | Scale by scalar |
| `.length()` | Magnitude |

### Vec4

```pak
Vec4.zero()
```

### Mat4 statics and instance methods

```pak
Mat4.identity()           -- identity matrix value
```

| Method | Description |
|--------|-------------|
| `.rotate_y(angle)` | Rotate around Y in place |
| `.rotate_x(angle)` | Rotate around X in place |
| `.rotate_z(angle)` | Rotate around Z in place |
| `.set_position(vec3)` | Set translation column |
| `.translate(x, y, z)` | Translate in place |
| `.scale(s)` | Uniform scale in place |
| `.identity()` | Reset to identity in place |
| `.to_fixed(out_fp)` | Convert into a `T3DMat4FP*` |
| `.as_t3d()` | Allocate and return a `T3DMat4FP*` |

### Mat4Fp (T3DMat4FP) allocation

```pak
Mat4Fp.create()           -- malloc_uncached a T3DMat4FP, returns *T3DMat4FP
mat_fp.free()             -- free_uncached the matrix
```

---

## Built-in Numeric / Cast / Misc Methods

Available on any value of the appropriate type — no import needed.

| Method | Applies to | Result |
|--------|-----------|--------|
| `.as_i8/.as_i16/.as_i32/.as_i64` | numeric | C cast to that int type |
| `.as_u8/.as_u16/.as_u32/.as_u64` | numeric | C cast |
| `.as_f32/.as_f64/.as_bool/.as_byte` | numeric | C cast |
| `.as_fix16_16/.as_fix10_5/.as_fix1_15` | float | scale into fixed-point |
| `.integer()` | fix16.16 | integer part (`>> 16`) |
| `.fraction()` | fix16.16 | fractional part as f32 |
| `.clamp(min, max)` | numeric | clamp into range |

---

## Built-in String / Slice / Container Methods

These dispatch on the receiver's type. No import needed (the `CStr`/`Str`
methods are distinct from the `pak.str` module functions).

### `CStr` (`*c_char` / `const char *`) methods

| Method | Description |
|--------|-------------|
| `.len()` | `strlen` as i32 |
| `.contains(sub)` | substring present |
| `.starts_with(pre)` / `.ends_with(suf)` | prefix/suffix test |
| `.eq(other)` / `.cmp(other)` | `strcmp == 0` / raw `strcmp` |
| `.is_empty()` | first byte is `\0` |
| `.as_bytes()` | reinterpret as `*u8` |
| `.to_pakstr()` | convert to `Str` (PakStr) |
| `.find(needle)` | byte offset or -1 |
| `.slice(start)` | pointer offset |
| `.slice(start, len)` | `Str` fat-slice |
| `.copy_to(buf, size)` | `snprintf` copy |
| `.concat_into(buf, size, other)` | append |
| `.format_into(buf, size, ...)` | `snprintf` |

### `Str` (PakStr fat string) methods

| Method | Description |
|--------|-------------|
| `.len()` / `.data()` | length / data pointer |
| `.eq(other)` | content equality |
| `.is_empty()` | length is 0 |
| `.as_cstr()` | data pointer as `*c_char` |
| `.contains(other)` | substring (memmem) |
| `.find(other)` | byte offset or -1 |
| `.slice(start, len)` | sub-slice |
| `.starts_with(pre)` / `.ends_with(suf)` | prefix/suffix |
| `.copy_to(buf, size)` | copy into mutable buffer, null-terminated |

### Slice `[]T` / array `[N]T` methods

| Method | Description |
|--------|-------------|
| `.as_slice()` / `.as_slice_mut()` | array → fat slice |
| `.get_unchecked(i)` | bounds-unchecked index |
| `.len()` | element count |

### Container instance methods (`Vec`, `FixedList`, `Pool`, `RingBuffer`, `FixedMap`)

`Vec(T)`: `.init()` `.push(x)` `.pop()` `.get(i)` `.len()` `.is_empty()`
`.clear()` `.reserve(n)` `.free()`
`FixedList(T,N)` / `Pool(T,N)`: `.init()` `.push(x)` `.pop()` `.remove(i)`
`.items()` / `.slice()` `.len()`; Pool adds `.acquire()` `.release(x)`
`RingBuffer(T,N)`: `.init()` `.push(x)` `.peek_back(i)` `.pop()` `.len()`
`FixedMap(K,V,N)`: `.init()` `.set(k, v)` `.get(k)`

Static initializers: `FixedList.init()`, `RingBuffer.init()`, `FixedMap.init()`,
`Pool.init()` all return a zeroed value.

---

## N64 Modules

Import with `use n64.module_name` before use.
Call functions as `module_name.function(args)`.

The libdragon C header each `use` pulls in is shown per module. Where an argument
name/type is not obvious from codegen, the description says "see libdragon" —
consult the named header in the libdragon sources for exact prototypes.

---

<!-- BEGIN GENERATED MODULE API -->

This index is generated by `tclsh tcl/tools/gen_stdlib.tcl` from
`tcl/module_api.tcl` (union of `CG_API` + `CG_API_LAMBDA`).
A function not listed here is `E010` at `pak check`, never silently
lowered. The **standalone** column is yes only when the C symbol is
defined in `runtime/standalone/runtime.pk64`; `pak check --backend mips`
rejects a no.

The **libdragon** column comes from `tests/libdragon_symbols.txt`,
which `tcl/tools/libdragon_symbols.tcl` computes by compiling a call to
each symbol against the real libdragon and Tiny3D headers:

* `yes` — declared by libdragon
* `tiny3d` — needs `tiny3d = true` in `pak.toml`
* `no` — Pak names it and nothing implements it; the generated C
  will not compile. These are standalone-only where the standalone
  column says yes.

A function lowered to an inline expression rather than a bare call
reads `yes*`: `tcl/tools/libdragon_api_test.tcl` checks those by
compiling the examples that use them.

| Module | Function | C symbol | libdragon | standalone |
|--------|----------|----------|-----------|------------|
| `arena` | `alloc` | `arena_alloc` | yes* | no |
| `arena` | `reset` | `arena_reset` | yes* | no |
| `audio` | `can_write` | `audio_can_write` | yes | yes |
| `audio` | `close` | `audio_close` | yes | yes |
| `audio` | `get_buffer` | `audio_get_buffer` | yes* | yes |
| `audio` | `get_frequency` | `audio_get_frequency` | yes | yes |
| `audio` | `init` | `audio_init` | yes | yes |
| `audio` | `set_buffer_num` | `audio_set_buffer_num` | no | yes |
| `audio` | `write` | `audio_write` | yes | yes |
| `audio` | `write_silence` | `audio_write_silence` | yes | yes |
| `backup` | `read` | `backup_read` | no | no |
| `backup` | `size` | `backup_size` | no | no |
| `backup` | `type` | `backup_type` | no | no |
| `backup` | `write` | `backup_write` | no | no |
| `cache` | `invalidate` | `data_cache_hit_invalidate` | yes | yes |
| `cache` | `writeback` | `data_cache_hit_writeback` | yes | yes |
| `cache` | `writeback_inv` | `data_cache_hit_writeback_invalidate` | yes | yes |
| `controller` | `init` | `joypad_init` | yes | yes |
| `controller` | `poll` | `joypad_poll` | yes | yes |
| `controller` | `read` | `joypad_get_status` | yes* | yes |
| `cpak` | `format` | `cpak_format` | no | no |
| `cpak` | `get_free_space` | `cpak_get_free_space` | no | no |
| `cpak` | `init` | `cpak_init` | no | no |
| `cpak` | `is_formatted` | `cpak_is_formatted` | no | no |
| `cpak` | `is_plugged` | `cpak_is_plugged` | no | no |
| `cpak` | `read_sector` | `cpak_read_sector` | no | no |
| `cpak` | `write_sector` | `cpak_write_sector` | no | no |
| `debug` | `assert` | `assert` | yes | yes |
| `debug` | `flush` | `flush` | no | no |
| `debug` | `init` | `debug_init_isviewer` | yes | no |
| `debug` | `init_isviewer` | `debug_init_isviewer` | yes | no |
| `debug` | `init_usbfs` | `debug_init_usbfs` | no | no |
| `debug` | `log` | `debugf` | yes | yes |
| `debug` | `log_value` | `debugf` | yes* | yes |
| `debug` | `print` | `debugf` | yes | yes |
| `disk` | `close` | `disk_close` | no | no |
| `disk` | `get_disk_type` | `disk_get_disk_type` | no | no |
| `disk` | `init` | `disk_init` | no | no |
| `disk` | `is_present` | `disk_is_present` | no | no |
| `disk` | `read_sector` | `disk_read_sector` | no | no |
| `disk` | `write_sector` | `disk_write_sector` | no | no |
| `display` | `close` | `display_close` | yes | yes |
| `display` | `get` | `display_get` | yes | yes |
| `display` | `init` | `display_init` | yes* | yes |
| `display` | `show` | `display_show` | yes | yes |
| `dma` | `read` | `dma_read` | yes | yes |
| `dma` | `wait` | `dma_wait` | yes | yes |
| `dma` | `write` | `dma_write` | yes | yes |
| `eeprom` | `init` | `eeprom_init` | no | yes |
| `eeprom` | `present` | `eeprom_present` | yes | yes |
| `eeprom` | `read` | `eeprom_read` | yes | yes |
| `eeprom` | `type_detect` | `eeprom_type_detect` | no | yes |
| `eeprom` | `write` | `eeprom_write` | yes | yes |
| `exception` | `get_handler` | `exception_get_handler` | no | yes |
| `exception` | `set_handler` | `exception_set_handler` | no | yes |
| `flashram` | `erase_sector` | `flashram_erase_sector` | no | no |
| `flashram` | `read` | `flashram_read` | no | no |
| `flashram` | `write` | `flashram_write` | no | no |
| `interrupt` | `disable` | `interrupt_disable` | no | yes |
| `interrupt` | `enabled` | `interrupt_enabled` | no | yes |
| `interrupt` | `init` | `interrupt_init` | no | yes |
| `interrupt` | `pending` | `interrupt_pending` | no | yes |
| `interrupt` | `restore` | `interrupt_restore` | no | yes |
| `interrupt` | `vi_count` | `interrupt_vi_count` | no | yes |
| `joypad` | `get_accessory_type` | `joypad_get_accessory_type` | yes | no |
| `joypad` | `get_axis_held` | `joypad_get_axis_held` | yes | no |
| `joypad` | `get_axis_pressed` | `joypad_get_axis_pressed` | yes | no |
| `joypad` | `get_buttons` | `joypad_get_buttons` | yes | no |
| `joypad` | `get_buttons_pressed` | `joypad_get_buttons_pressed` | yes | no |
| `joypad` | `get_buttons_released` | `joypad_get_buttons_released` | yes | no |
| `joypad` | `get_status` | `joypad_get_status` | no | yes |
| `joypad` | `init` | `joypad_init` | yes | yes |
| `joypad` | `is_connected` | `joypad_is_connected` | yes* | no |
| `joypad` | `poll` | `joypad_poll` | yes | yes |
| `math` | `abs_f` | `math_abs_f` | yes* | yes |
| `math` | `abs_i32` | `math_abs_i32` | yes* | yes |
| `math` | `atan2_f` | `math_atan2_f` | yes* | yes |
| `math` | `ceil_f` | `math_ceil_f` | yes* | yes |
| `math` | `clamp_f` | `math_clamp_f` | yes* | yes |
| `math` | `clamp_i32` | `math_clamp_i32` | yes* | yes |
| `math` | `cos_f` | `math_cos_f` | yes* | yes |
| `math` | `f_to_fix` | `math_f_to_fix` | yes* | yes |
| `math` | `fix_cos` | `math_fix_cos` | yes* | yes |
| `math` | `fix_sin` | `math_fix_sin` | yes* | yes |
| `math` | `fix_sqrt` | `math_fix_sqrt` | yes* | yes |
| `math` | `fix_to_f` | `math_fix_to_f` | yes* | yes |
| `math` | `floor_f` | `math_floor_f` | yes* | yes |
| `math` | `lerp_f` | `math_lerp_f` | yes* | yes |
| `math` | `max_f` | `math_max_f` | yes* | yes |
| `math` | `max_i32` | `math_max_i32` | yes* | yes |
| `math` | `min_f` | `math_min_f` | yes* | yes |
| `math` | `min_i32` | `math_min_i32` | yes* | yes |
| `math` | `pow_f` | `math_pow_f` | yes* | yes |
| `math` | `rand` | `math_rand` | yes* | yes |
| `math` | `rand_f` | `math_rand_f` | yes* | yes |
| `math` | `rand_range` | `math_rand_range` | yes* | yes |
| `math` | `rand_seed` | `math_rand_seed` | yes* | yes |
| `math` | `sin_f` | `math_sin_f` | yes* | yes |
| `math` | `sqrt_f` | `math_sqrt_f` | yes* | yes |
| `math` | `tan_f` | `math_tan_f` | yes* | yes |
| `mem` | `alloc` | `mem_alloc` | yes* | no |
| `mem` | `alloc_aligned` | `mem_alloc_aligned` | yes* | no |
| `mem` | `copy` | `mem_copy` | yes* | no |
| `mem` | `free` | `mem_free` | yes* | no |
| `mem` | `move` | `mem_move` | yes* | no |
| `mem` | `realloc` | `mem_realloc` | yes* | no |
| `mem` | `zero` | `mem_zero` | yes* | no |
| `mixer` | `ch_play` | `mixer_ch_play` | yes | no |
| `mixer` | `ch_playing` | `mixer_ch_playing` | yes | no |
| `mixer` | `ch_set_freq` | `mixer_ch_set_freq` | yes | no |
| `mixer` | `ch_set_vol` | `mixer_ch_set_vol` | yes | no |
| `mixer` | `ch_stop` | `mixer_ch_stop` | yes | no |
| `mixer` | `close` | `mixer_close` | yes | no |
| `mixer` | `init` | `mixer_init` | yes | no |
| `mixer` | `poll` | `audio_poll` | no | no |
| `mouse` | `get_buttons` | `mouse_get_buttons` | yes* | no |
| `mouse` | `get_delta_x` | `mouse_get_delta_x` | yes* | no |
| `mouse` | `get_delta_y` | `mouse_get_delta_y` | yes* | no |
| `mouse` | `init` | `joypad_init` | yes | yes |
| `mouse` | `poll` | `joypad_poll` | yes | yes |
| `rdpq` | `attach` | `rdpq_attach` | yes | yes |
| `rdpq` | `attach_clear` | `rdpq_attach_clear` | yes* | yes |
| `rdpq` | `block_begin` | `rdpq_block_begin` | no | no |
| `rdpq` | `block_end` | `rdpq_block_end` | no | no |
| `rdpq` | `block_free` | `rdpq_block_free` | no | no |
| `rdpq` | `block_run` | `rdpq_block_run` | no | no |
| `rdpq` | `call` | `rdpq_call` | no | no |
| `rdpq` | `clear_z` | `rdpq_clear_z` | yes | yes |
| `rdpq` | `close` | `rdpq_close` | yes | yes |
| `rdpq` | `detach` | `rdpq_detach` | yes | yes |
| `rdpq` | `detach_show` | `rdpq_detach_show` | yes | yes |
| `rdpq` | `fill_rectangle` | `rdpq_fill_rectangle` | yes | yes |
| `rdpq` | `flush` | `rspq_flush` | yes | no |
| `rdpq` | `init` | `rdpq_init` | yes | yes |
| `rdpq` | `load_block` | `rdpq_load_block` | yes* | yes |
| `rdpq` | `load_tile` | `rdpq_load_tile` | yes | yes |
| `rdpq` | `load_tlut` | `rdpq_load_tlut` | no | yes |
| `rdpq` | `set_blend_color` | `rdpq_set_blend_color` | yes | yes |
| `rdpq` | `set_color_image` | `rdpq_set_color_image` | yes | yes |
| `rdpq` | `set_combiner_raw` | `rdpq_set_combiner_raw` | yes | yes |
| `rdpq` | `set_convert` | `rdpq_set_convert` | no | yes |
| `rdpq` | `set_env_color` | `rdpq_set_env_color` | yes | yes |
| `rdpq` | `set_fill_color` | `rdpq_set_fill_color` | yes* | yes |
| `rdpq` | `set_fog_color` | `rdpq_set_fog_color` | yes | yes |
| `rdpq` | `set_key_gb` | `rdpq_set_key_gb` | no | yes |
| `rdpq` | `set_key_r` | `rdpq_set_key_r` | no | yes |
| `rdpq` | `set_mode_copy` | `rdpq_set_mode_copy` | yes* | yes |
| `rdpq` | `set_mode_fill` | `rdpq_set_mode_fill` | yes* | yes |
| `rdpq` | `set_mode_standard` | `rdpq_set_mode_standard` | yes | yes |
| `rdpq` | `set_mode_standard_z` | `rdpq_set_mode_standard_z` | no | yes |
| `rdpq` | `set_other_modes_raw` | `rdpq_set_other_modes_raw` | yes | yes |
| `rdpq` | `set_prim_color` | `rdpq_set_prim_color` | yes | yes |
| `rdpq` | `set_prim_depth` | `rdpq_set_prim_depth` | no | yes |
| `rdpq` | `set_scissor` | `rdpq_set_scissor` | yes | yes |
| `rdpq` | `set_texture_image` | `rdpq_set_texture_image` | yes* | yes |
| `rdpq` | `set_tile` | `rdpq_set_tile` | yes | yes |
| `rdpq` | `set_tile_mask` | `rdpq_set_tile_mask` | no | yes |
| `rdpq` | `set_tile_size` | `rdpq_set_tile_size` | yes | yes |
| `rdpq` | `set_tri_z` | `rdpq_set_tri_z` | no | yes |
| `rdpq` | `set_z_image` | `rdpq_set_z_image` | yes | yes |
| `rdpq` | `sync_full` | `rdpq_sync_full` | yes | yes |
| `rdpq` | `sync_load` | `rdpq_sync_load` | yes | yes |
| `rdpq` | `sync_pipe` | `rdpq_sync_pipe` | yes | yes |
| `rdpq` | `sync_tile` | `rdpq_sync_tile` | yes | yes |
| `rdpq` | `texture_rectangle` | `rdpq_texture_rectangle` | yes | yes |
| `rdpq` | `texture_rectangle_flip` | `rdpq_texture_rectangle_flip` | no | yes |
| `rdpq` | `texture_rectangle_scaled` | `rdpq_texture_rectangle_scaled` | yes | yes |
| `rdpq` | `triangle` | `rdpq_triangle` | yes | yes |
| `rdpq` | `triangle_shade` | `rdpq_triangle_shade` | no | yes |
| `rdpq` | `triangle_shade_tex` | `rdpq_triangle_shade_tex` | no | yes |
| `rdpq` | `triangle_shade_tex_z` | `rdpq_triangle_shade_tex_z` | no | yes |
| `rdpq` | `triangle_shade_z` | `rdpq_triangle_shade_z` | no | yes |
| `rdpq` | `triangle_tex` | `rdpq_triangle_tex` | no | yes |
| `rdpq` | `triangle_tex_z` | `rdpq_triangle_tex_z` | no | yes |
| `rdpq` | `triangle_z` | `rdpq_triangle_z` | no | yes |
| `rdpq_font` | `draw_text` | `rdpq_text_print` | yes | no |
| `rdpq_font` | `free` | `rdpq_font_free` | yes | no |
| `rdpq_font` | `load` | `rdpq_font_load` | yes | no |
| `rdpq_font` | `measure` | `rdpq_text_measure` | no | no |
| `rdpq_font` | `register` | `rdpq_font_register` | no | no |
| `rdpq_mode` | `antialias` | `rdpq_mode_antialias` | yes* | no |
| `rdpq_mode` | `blending` | `rdpq_mode_blending` | yes* | no |
| `rdpq_mode` | `combiner` | `rdpq_mode_combiner` | yes | no |
| `rdpq_mode` | `copy` | `rdpq_set_mode_copy` | yes | yes |
| `rdpq_mode` | `dithering` | `rdpq_mode_dithering` | yes* | no |
| `rdpq_mode` | `filter` | `rdpq_mode_filter` | yes* | no |
| `rdpq_mode` | `persp_norm` | `rdpq_mode_persp_norm` | yes* | no |
| `rdpq_mode` | `pop` | `rdpq_mode_pop` | yes | no |
| `rdpq_mode` | `push` | `rdpq_mode_push` | yes | no |
| `rdpq_mode` | `standard` | `rdpq_set_mode_standard` | yes | yes |
| `rdpq_mode` | `tlut` | `rdpq_mode_tlut` | yes* | no |
| `rdpq_mode` | `zbuf` | `rdpq_mode_zbuf` | yes* | no |
| `rdpq_tex` | `multi_begin` | `rdpq_tex_multi_begin` | yes | no |
| `rdpq_tex` | `multi_end` | `rdpq_tex_multi_end` | yes | no |
| `rdpq_tex` | `upload` | `rdpq_tex_upload` | yes | no |
| `rdpq_tex` | `upload_sub` | `rdpq_tex_upload_sub` | yes | no |
| `rsp` | `block_begin` | `rspq_block_begin` | yes | no |
| `rsp` | `block_end` | `rspq_block_end` | yes | no |
| `rsp` | `block_free` | `rspq_block_free` | yes | no |
| `rsp` | `block_run` | `rspq_block_run` | yes | no |
| `rsp` | `close` | `rspq_close` | yes | no |
| `rsp` | `init` | `rspq_init` | yes | no |
| `rsp` | `syncpoint_check` | `rspq_syncpoint_check` | yes | no |
| `rsp` | `syncpoint_new` | `rspq_syncpoint_new` | yes | no |
| `rsp` | `wait` | `rspq_wait` | yes | no |
| `rtc` | `get` | `rtc_get` | yes | no |
| `rtc` | `init` | `rtc_init` | yes | no |
| `rtc` | `is_running` | `rtc_is_running` | yes* | no |
| `rtc` | `is_stopped` | `rtc_is_stopped` | no | no |
| `rtc` | `set` | `rtc_set` | yes | no |
| `rumble` | `init` | `rumble_init` | no | no |
| `rumble` | `is_plugged` | `rumble_is_plugged` | yes* | no |
| `rumble` | `start` | `rumble_start` | yes | no |
| `rumble` | `stop` | `rumble_stop` | yes | no |
| `sp` | `done` | `pak_sp_done` | no | yes |
| `sp` | `init` | `pak_sp_init` | no | yes |
| `sp` | `load_data` | `pak_sp_load_data` | no | yes |
| `sp` | `load_ucode` | `pak_sp_load_ucode` | no | yes |
| `sp` | `read_data` | `pak_sp_read_data` | no | yes |
| `sp` | `run` | `pak_sp_run` | no | yes |
| `sp` | `status` | `pak_sp_status` | no | yes |
| `sp` | `wait` | `pak_sp_wait` | no | yes |
| `sprite` | `blit` | `rdpq_sprite_blit` | yes* | yes |
| `sprite` | `load` | `sprite_load` | yes | yes |
| `sram` | `read` | `sram_read` | no | no |
| `sram` | `write` | `sram_write` | no | no |
| `str` | `concat` | `str_concat` | yes* | no |
| `str` | `data` | `str_data` | yes* | no |
| `str` | `eq` | `str_eq` | yes* | no |
| `str` | `from_cstr` | `pak_str_from_cstr` | yes* | no |
| `str` | `len` | `str_len` | yes* | no |
| `str` | `print` | `str_print` | yes* | no |
| `surface` | `alloc` | `surface_alloc` | yes | no |
| `surface` | `free` | `surface_free` | yes | no |
| `surface` | `make_sub` | `surface_make_sub` | yes | no |
| `system` | `has_expansion` | `system_has_expansion` | yes* | no |
| `system` | `memory_size` | `get_memory_size` | yes | no |
| `system` | `reset` | `system_reset` | yes* | no |
| `system` | `ticks` | `system_ticks` | yes* | no |
| `system` | `ticks_to_ms` | `system_ticks_to_ms` | yes* | no |
| `system` | `tv_type` | `system_tv_type` | yes* | no |
| `t3d` | `anim_attach` | `t3d_anim_attach` | tiny3d | no |
| `t3d` | `anim_create` | `t3d_anim_create` | tiny3d | no |
| `t3d` | `anim_destroy` | `t3d_anim_destroy` | tiny3d | no |
| `t3d` | `anim_set_looping` | `t3d_anim_set_looping` | tiny3d | no |
| `t3d` | `anim_set_playing` | `t3d_anim_set_playing` | tiny3d | no |
| `t3d` | `anim_set_speed` | `t3d_anim_set_speed` | tiny3d | no |
| `t3d` | `anim_update` | `t3d_anim_update` | tiny3d | no |
| `t3d` | `destroy` | `t3d_destroy` | tiny3d | no |
| `t3d` | `draw_indexed` | `t3d_draw_indexed` | no | no |
| `t3d` | `draw_object` | `t3d_draw_object` | no | no |
| `t3d` | `fog_set_color` | `t3d_fog_set_color` | no | no |
| `t3d` | `fog_set_enabled` | `t3d_fog_set_enabled` | yes* | no |
| `t3d` | `fog_set_range` | `t3d_fog_set_range` | tiny3d | no |
| `t3d` | `frame_end` | `rspq_block_run` | yes | no |
| `t3d` | `frame_start` | `t3d_frame_start` | tiny3d | no |
| `t3d` | `init` | `t3d_init` | tiny3d | no |
| `t3d` | `light_set_ambient` | `t3d_light_set_ambient` | tiny3d | no |
| `t3d` | `light_set_count` | `t3d_light_set_count` | tiny3d | no |
| `t3d` | `light_set_directional` | `t3d_light_set_directional` | tiny3d | no |
| `t3d` | `light_set_point` | `t3d_light_set_point` | tiny3d | no |
| `t3d` | `light_set_point_params` | `t3d_light_set_point_params` | no | no |
| `t3d` | `light_set_spot` | `t3d_light_set_spot` | no | no |
| `t3d` | `look_at` | `t3d_look_at` | no | no |
| `t3d` | `mat4_from_srt` | `t3d_mat4_from_srt` | yes* | no |
| `t3d` | `mat4_from_srt_euler` | `t3d_mat4_from_srt_euler` | yes* | no |
| `t3d` | `mat4_identity` | `t3d_mat4_identity` | yes* | no |
| `t3d` | `mat4_invert` | `t3d_mat4_invert` | yes* | no |
| `t3d` | `mat4_mul` | `t3d_mat4_mul` | yes* | no |
| `t3d` | `mat4_rotate_x` | `t3d_mat4_rotate` | yes* | no |
| `t3d` | `mat4_rotate_y` | `t3d_mat4_rotate` | yes* | no |
| `t3d` | `mat4_rotate_z` | `t3d_mat4_rotate` | yes* | no |
| `t3d` | `mat4_scale` | `t3d_mat4_scale` | yes* | no |
| `t3d` | `mat4_translate` | `t3d_mat4_translate` | yes* | no |
| `t3d` | `mat4_transpose` | `t3d_mat4_transpose` | yes* | no |
| `t3d` | `model_bake_pos` | `t3d_model_bake_pos` | no | no |
| `t3d` | `model_draw` | `t3d_model_draw` | tiny3d | no |
| `t3d` | `model_free` | `t3d_model_free` | tiny3d | no |
| `t3d` | `model_get_material` | `t3d_model_get_material` | tiny3d | no |
| `t3d` | `model_get_object_by_index` | `t3d_model_get_object_by_index` | tiny3d | no |
| `t3d` | `model_get_object_by_name` | `t3d_model_get_object_by_name` | no | no |
| `t3d` | `model_get_vertex_count` | `t3d_model_get_vertex_count` | no | no |
| `t3d` | `model_load` | `t3d_model_load` | tiny3d | no |
| `t3d` | `pop_draw_flags` | `t3d_pop_draw_flags` | no | no |
| `t3d` | `push_draw_flags` | `t3d_push_draw_flags` | no | no |
| `t3d` | `quat_from_axis_angle` | `t3d_quat_from_axis_angle` | yes* | no |
| `t3d` | `quat_identity` | `t3d_quat_identity` | yes* | no |
| `t3d` | `quat_mul` | `t3d_quat_mul` | yes* | no |
| `t3d` | `quat_nlerp` | `t3d_quat_nlerp` | yes* | no |
| `t3d` | `quat_slerp` | `t3d_quat_slerp` | yes* | no |
| `t3d` | `rdpq_draw_object` | `t3d_rdpq_draw_object` | no | no |
| `t3d` | `screen_projection` | `t3d_screen_projection` | no | no |
| `t3d` | `segment_set` | `t3d_segment_set` | tiny3d | no |
| `t3d` | `set_camera` | `t3d_set_camera` | no | no |
| `t3d` | `skeleton_create` | `t3d_skeleton_create` | tiny3d | no |
| `t3d` | `skeleton_destroy` | `t3d_skeleton_destroy` | tiny3d | no |
| `t3d` | `skeleton_draw` | `t3d_skeleton_draw` | no | no |
| `t3d` | `skeleton_update` | `t3d_skeleton_update` | tiny3d | no |
| `t3d` | `state_set_drawflags` | `t3d_state_set_drawflags` | tiny3d | no |
| `t3d` | `state_set_vertex_fx` | `t3d_state_set_vertex_fx` | tiny3d | no |
| `t3d` | `tri_draw` | `t3d_tri_draw` | tiny3d | no |
| `t3d` | `tri_sync` | `t3d_tri_sync` | tiny3d | no |
| `t3d` | `vec3_cross` | `t3d_vec3_cross` | yes* | no |
| `t3d` | `vec3_dot` | `t3d_vec3_dot` | yes* | no |
| `t3d` | `vec3_lerp` | `t3d_vec3_lerp` | yes* | no |
| `t3d` | `vec3_norm` | `t3d_vec3_norm` | yes* | no |
| `t3d` | `vert_load` | `t3d_vert_load` | tiny3d | no |
| `t3d` | `vert_load_srt` | `t3d_vert_load_srt` | no | no |
| `t3d` | `viewport_attach` | `t3d_viewport_attach` | tiny3d | no |
| `t3d` | `viewport_create` | `t3d_viewport_create` | tiny3d | no |
| `t3d` | `viewport_set_fov` | `t3d_viewport_set_fov` | no | no |
| `t3d` | `viewport_set_projection` | `t3d_viewport_set_projection` | tiny3d | no |
| `timer` | `delta` | `_pak_delta_time` | yes* | yes |
| `timer` | `get_ticks` | `get_ticks` | yes | yes |
| `timer` | `init` | `timer_init` | yes | yes |
| `timer` | `ticks` | `get_ticks` | yes | yes |
| `tpak` | `get_status` | `tpak_get_status` | yes | no |
| `tpak` | `get_value` | `tpak_get_value` | yes* | no |
| `tpak` | `init` | `tpak_init` | yes | no |
| `tpak` | `read` | `tpak_read` | yes | no |
| `tpak` | `set_power` | `tpak_set_power` | yes | no |
| `tpak` | `set_value` | `tpak_set_value` | yes* | no |
| `tpak` | `write` | `tpak_write` | yes | no |
| `vi` | `get_height` | `vi_get_height` | yes* | no |
| `vi` | `get_width` | `vi_get_width` | yes* | no |
| `vi` | `set_aa_mode` | `vi_set_aa_mode` | no | no |
| `vi` | `set_dedither` | `vi_set_dedither` | no | no |
| `vi` | `set_divot` | `vi_set_divot` | no | no |
| `vi` | `set_gamma` | `vi_set_gamma` | no | no |
| `vi` | `wait_vblank` | `vi_wait_vblank` | yes* | no |
| `vru` | `close` | `vru_close` | no | no |
| `vru` | `init` | `vru_init` | no | no |
| `vru` | `is_ready` | `vru_is_ready` | no | no |
| `vru` | `read_word` | `vru_read_word` | no | no |
| `vru` | `write_word_list` | `vru_write_word_list` | no | no |
| `wav64` | `close` | `wav64_close` | yes | no |
| `wav64` | `open` | `wav64_open` | yes | no |
| `wav64` | `play` | `wav64_play` | yes | no |
| `wav64` | `set_loop` | `wav64_set_loop` | yes | no |
| `xm64` | `close` | `xm64player_close` | yes | no |
| `xm64` | `open` | `xm64player_open` | yes | no |
| `xm64` | `play` | `xm64player_play` | yes | no |
| `xm64` | `set_vol` | `xm64player_set_vol` | yes | no |
| `xm64` | `stop` | `xm64player_stop` | yes | no |

**344 functions** across the module surface; **134** exist on the standalone HAL.

Of the 247 lowered as a direct call: **119** are libdragon's own, **32** need Tiny3D, and **96** are **not implemented on the libdragon backend** — they exist only on the standalone HAL.

<!-- END GENERATED MODULE API -->

### `n64.display` — Framebuffer Output

```pak
use n64.display          -- #include <display.h>
```

| Function | Signature | Description |
|----------|-----------|-------------|
| `display.init` | `(resolution: u32, bit_depth: u32, num_buffers: i32, gamma: u32, filters: u32)` | Initialize display subsystem |
| `display.get` | `() -> *surface_t` | Get the next available framebuffer surface |
| `display.show` | `(surface: *surface_t)` | Show/flip a surface to screen |
| `display.close` | `()` | Shut down display |

These constants are C macros from libdragon. Use their numeric values directly,
or declare them with `extern const`:

```pak
-- resolution: 0=320x240, 1=640x480, 2=256x240, 3=512x240
-- bit_depth:  2=16 bpp, 4=32 bpp
-- gamma:      0=none, 1=correct, 3=correct+dither
-- filters:    0=disabled, 1=resample, 3=resample+antialias
display.init(0, 2, 3, 0, 1)   -- 320x240, 16bpp, triple-buffer, no gamma, bilinear
```

**Behavioral rules:**
- Must be called before `rdpq.init()` or any `rdpq.*` calls.
- `display.get()` blocks until a framebuffer is free — call at render start.
- Prefer `rdpq.detach_show()` over separate `rdpq.detach()` + `display.show(fb)`.
- Do NOT write to a surface after calling `rdpq.detach_show()`.
- See `N64_HARDWARE.md` → Display System for resolution constants and arg table.

---

### `n64.controller` — Joypad Input

```pak
use n64.controller       -- #include <joypad.h>
```

| Function | Signature | Description |
|----------|-----------|-------------|
| `controller.init` | `()` | Initialize joypad subsystem (`joypad_init`) |
| `controller.poll` | `()` | Poll joypad state (call once per frame) |
| `controller.read` | `(port: i32) -> joypad_status_t` | Read current state for port 0–3 |

**CRITICAL: call `controller.poll()` before `controller.read()` every frame.**
Reading without polling returns stale data from the previous frame.
`port` is 0–3 (player 1 = port 0).

The returned `joypad_status_t` exposes `.held.*`, `.pressed.*`, `.released.*`
(all the buttons: `a b start up down left right z l r c_up c_down c_left
c_right`), plus `.stick_x` / `.stick_y` (`i8`, -128..127).

For finer-grained access see the explicit `n64.joypad` module below.

---

### `n64.joypad` — Explicit Joypad API

```pak
use n64.joypad           -- #include <joypad.h>
```

| Function | Maps to | Description |
|----------|---------|-------------|
| `joypad.init` | `joypad_init` | Initialize |
| `joypad.poll` | `joypad_poll` | Poll all ports |
| `joypad.get_status` | `joypad_get_status` | Full status struct for a port |
| `joypad.get_buttons` | `joypad_get_buttons` | Currently-held button mask |
| `joypad.get_buttons_pressed` | `joypad_get_buttons_pressed` | Pressed-this-frame mask |
| `joypad.get_buttons_released` | `joypad_get_buttons_released` | Released-this-frame mask |
| `joypad.get_axis_held` | `joypad_get_axis_held` | Held analog axis value |
| `joypad.get_axis_pressed` | `joypad_get_axis_pressed` | Axis delta this frame |
| `joypad.get_accessory_type` | `joypad_get_accessory_type` | Accessory in a port |
| `joypad.is_connected` | (status.style != NONE) | Port has a controller |

---

### `n64.rdpq` — RDP Graphics (2D Rendering)

```pak
use n64.rdpq             -- #include <rdpq.h> + <rdpq_gfx.h>
```

| Function | Signature | Description |
|----------|-----------|-------------|
| `rdpq.init` | `()` | Initialize RDP queue |
| `rdpq.close` | `()` | Shut down RDP queue |
| `rdpq.attach` | `(surface: *surface_t)` | Attach RDP output to surface |
| `rdpq.attach_clear` | `(surface: *surface_t)` | Attach and clear surface |
| `rdpq.detach` | `()` | Detach current surface |
| `rdpq.detach_show` | `()` | Detach and show surface (flip) |
| `rdpq.set_mode_standard` | `()` | Standard rendering mode |
| `rdpq.set_mode_standard_z` | `()` | 1-cycle + z_compare_en + z_update_en |
| `rdpq.set_mode_copy` | `()` | Fast copy rendering mode |
| `rdpq.set_mode_fill` | `(color: u32)` | Fill mode with color |
| `rdpq.clear_z` | `()` | Fill the reserved Z buffer with 0xFFFC |
| `rdpq.fill_rectangle` | `(x0, y0, x1, y1: i32)` | Draw filled rectangle |
| `rdpq.set_scissor` | `(x0, y0, x1, y1: i32)` | Set scissor rectangle |
| `rdpq.sync_full` | `()` | Wait for RDP to finish all commands |
| `rdpq.sync_pipe` | `()` | Sync RDP pipeline state |
| `rdpq.sync_tile` | `()` | Sync RDP tile state |
| `rdpq.sync_load` | `()` | Sync RDP texture load |
| `rdpq.triangle` | `(x0,y0,x1,y1,x2,y2)` | Flat fill triangle (RDP 0x08) |
| `rdpq.triangle_z` | `(x0,y0,z0, x1,y1,z1, x2,y2,z2)` | Fill + Z (RDP 0x09); z is 0..32767 |
| `rdpq.triangle_tex` | `(tile, x0,y0,s0,t0, x1,y1,s1,t1, x2,y2,s2,t2)` | Affine textured triangle (RDP 0x0A TRI_TEX, s15.16 edges + ST + 1/w) |
| `rdpq.triangle_tex_z` | `(tile, x0,y0,s0,t0, x1,..., x2,...)` | Affine ST + Z (RDP 0x0B); call `set_tri_z` first |
| `rdpq.triangle_shade` | `(x0,y0,c0, x1,y1,c1, x2,y2,c2)` | Gouraud triangle (RDP 0x0C); colours RGBA8888 |
| `rdpq.triangle_shade_z` | `(x0,y0,c0,z0, x1,y1,c1,z1, x2,y2,c2,z2)` | Gouraud + Z (RDP 0x0D); z is 0..32767 |
| `rdpq.triangle_shade_tex` | `(tile, x0,y0,c0,s0,t0, x1,y1,c1,s1,t1, x2,y2,c2,s2,t2)` | Gouraud + affine ST (RDP 0x0E) |
| `rdpq.set_tri_z` | `(z0, z1, z2)` | Vertex Z for the next `triangle_tex_z` / `triangle_shade_tex_z` |
| `rdpq.triangle_shade_tex_z` | `(tile, x0,y0,c0,s0,t0, x1,..., x2,...)` | Gouraud + ST + Z (RDP 0x0F); call `set_tri_z` first |
| `rdpq.texture_rectangle` | `(...)` | Blit textured rect (see libdragon) |
| `rdpq.texture_rectangle_flip` | `(tile, x0,y0,x1,y1,s,t)` | Y-flipped blit (RDP 0x25 TEXTURE_RECTANGLE_FLIP) |
| `rdpq.texture_rectangle_scaled` | `(tile, x0,y0,x1,y1,s,t,dsdx,dtdy)` | Scaled blit (RDP 0x24, s5.10 dsdx/dtdy) |
| `rdpq.set_blend_color` | `(color: u32)` | Blend color register |
| `rdpq.set_fog_color` | `(color: u32)` | Fog color register |
| `rdpq.set_fill_color` | `(color: u32)` | Fill color register |
| `rdpq.set_env_color` | `(color: u32)` | Environment color register |
| `rdpq.set_prim_color` | `(color: u32)` | Primitive color register |
| `rdpq.set_prim_depth` | `(z: u32, dz: u32)` | Primitive Z / delta-Z (RDP 0x2E) |
| `rdpq.set_key_r` | `(width, center, scale)` | Chroma-key red (RDP 0x2B) |
| `rdpq.set_key_gb` | `(wg, wb, cg, sg, cb, sb)` | Chroma-key green/blue (RDP 0x2A) |
| `rdpq.set_convert` | `(k0..k5)` | YUV-to-RGB coefficients (RDP 0x2C, 9-bit) |
| `rdpq.set_z_image` | `(surface: *surface_t)` | Set Z-buffer image |
| `rdpq.set_color_image` | `(surface: *surface_t)` | Set color render target |
| `rdpq.set_tile` | `(tile, fmt, size, line, tmem, palette)` | Tile descriptor, wrap (mask 0) |
| `rdpq.set_tile_mask` | `(..., cms, cmt, mask_s, mask_t)` | SET_TILE with GBI wrap/mirror/clamp and mask |
| `rdpq.set_tile_size` | `(...)` | Set tile size (see libdragon) |
| `rdpq.load_tile` | `(...)` | Load texels into TMEM (see libdragon) |
| `rdpq.load_block` | `(tile, s0, t0, texels, dxt)` | Load a TMEM block (RDP 0x33; SH = texels-1) |
| `rdpq.load_tlut` | `(tile, first, count)` | Load palette LUT (RDP 0x30; colour index in 10.2×4) |
| `rdpq.set_combiner_raw` | `(comb: u64)` | Raw color combiner |
| `rdpq.set_other_modes_raw` | `(modes: u64)` | Raw other-modes word |
| `rdpq.flush` | `()` | Flush rspq queue (`rspq_flush`) |
| `rdpq.block_begin` | `()` | Begin recording a display list block |
| `rdpq.block_end` | `() -> *rspq_block_t` | Finish recording, return block |
| `rdpq.block_run` | `(block: *rspq_block_t)` | Replay a recorded block |
| `rdpq.block_free` | `(block: *rspq_block_t)` | Free a recorded block |
| `rdpq.call` | `(...)` | Call into a sub-block (`rdpq_call`) |

**Behavioral rules:**
- Call `rdpq.init()` after `display.init()` but before any draw calls.
- Set a rendering mode before draw calls. Never draw without setting a mode.
- **Mode switching**: call `rdpq.sync_pipe()` between mode switches in a frame.
- `rdpq.set_mode_copy()` = fastest 2D; no alpha blend, no scale. Use for sprites.
- `rdpq.set_mode_fill(color)` = fast solid fill. `color` is `0xRRGGBBAA`.
- `rdpq.set_mode_standard()` = texture/alpha/blending — slowest mode.
- `rdpq.attach_clear(fb)` and `rdpq.detach_show()` are the preferred combined forms.

**Per-frame render pattern:**
```pak
let fb = display.get()
rdpq.attach_clear(fb)
rdpq.set_mode_fill(0x000000FF)
rdpq.fill_rectangle(0, 0, 320, 240)
rdpq.sync_pipe()
rdpq.set_mode_copy()
sprite.blit(my_sprite, x, y, 0)
rdpq.detach_show()
```

---

### `n64.rdpq_mode` — RDP Mode Helpers

```pak
use n64.rdpq_mode        -- #include <rdpq_mode.h>
```

| Function | Maps to | Description |
|----------|---------|-------------|
| `rdpq_mode.push` | `rdpq_mode_push` | Save current render mode |
| `rdpq_mode.pop` | `rdpq_mode_pop` | Restore saved render mode |
| `rdpq_mode.standard` | `rdpq_set_mode_standard` | Standard mode |
| `rdpq_mode.copy` | `rdpq_set_mode_copy` | Copy mode |
| `rdpq_mode.zbuf` | `rdpq_mode_zbuf(true, arg)` | Enable Z-buffering (default arg `true`) |
| `rdpq_mode.blending` | `rdpq_mode_blending(arg)` | Set blend mode (default `RDPQ_BLENDING_MULTIPLY`) |
| `rdpq_mode.antialias` | `rdpq_mode_antialias(arg)` | AA mode (default `AA_STANDARD`) |
| `rdpq_mode.filter` | `rdpq_mode_filter(arg)` | Texture filter (default `FILTER_BILINEAR`) |
| `rdpq_mode.dithering` | `rdpq_mode_dithering(arg)` | Dither (default `DITHER_SQUARE_SQUARE`) |
| `rdpq_mode.persp_norm` | `rdpq_mode_persp_norm(arg)` | Perspective normalize (default `true`) |
| `rdpq_mode.combiner` | `rdpq_mode_combiner` | Set color combiner |
| `rdpq_mode.tlut` | `rdpq_mode_tlut(arg)` | Palette mode (default `TLUT_RGBA16`) |

---

### `n64.rdpq_tex` — Texture Upload

```pak
use n64.rdpq_tex         -- #include <rdpq_tex.h>
```

| Function | Maps to | Description |
|----------|---------|-------------|
| `rdpq_tex.upload` | `rdpq_tex_upload` | Upload a surface to TMEM |
| `rdpq_tex.upload_sub` | `rdpq_tex_upload_sub` | Upload a sub-rectangle |
| `rdpq_tex.multi_begin` | `rdpq_tex_multi_begin` | Begin multi-texture upload |
| `rdpq_tex.multi_end` | `rdpq_tex_multi_end` | End multi-texture upload |

---

### `n64.rdpq_font` — Text Rendering

```pak
use n64.rdpq_font        -- #include <rdpq_font.h> + <rdpq_text.h>
```

| Function | Maps to | Description |
|----------|---------|-------------|
| `rdpq_font.load` | `rdpq_font_load` | Load an `.fnt` font, returns `*rdpq_font_t` |
| `rdpq_font.free` | `rdpq_font_free` | Free a font |
| `rdpq_font.register` | `rdpq_font_register` | Register a font under an ID |
| `rdpq_font.draw_text` | `rdpq_text_print` | Print text (see libdragon for arg order) |
| `rdpq_font.measure` | `rdpq_text_measure` | Measure text extents |

---

### `n64.sprite` — 2D Sprite Rendering

```pak
use n64.sprite           -- #include <rdpq_sprite.h>
```

| Function | Signature | Description |
|----------|-----------|-------------|
| `sprite.load` | `(path: *c_char) -> *sprite_t` | Load a sprite from filesystem |
| `sprite.blit` | `(sprite: *sprite_t, x: i32, y: i32, flags: u32)` | Draw sprite at (x, y) |

**Behavioral rules:**
- Call `rdpq.set_mode_copy()` before `sprite.blit` — blit requires copy mode.
- `flags` is usually `0`. `x`, `y` are top-left pixel coordinates.
- Asset sprites (`asset name: Sprite from "path"`) are loaded automatically:
  reading the name the first time loads the file, and every read after that
  reuses the handle.

**On the standalone backend:**
- `pak link --fs <archive>` appends a PakFS archive to the ROM past the
  payload; the runtime walks its index and DMAs a file in on demand. A ROM
  linked without `--fs` has no assets and every load returns `none`.
- The archive is named after the CONVERTED file, so `from "sprites/bg.png"`
  looks up `sprites/bg.sprite` — what `pak build` ran through `mksprite` and
  packed. Asset paths are relative to the project's `assets/` directory.
- Only `--compress 0` sprites are readable: a compressed one starts with
  libdragon's "DCA3" container and nothing in the standalone runtime
  decompresses it.
- CI4 and CI8 sprites are skipped rather than drawn, because their palette is
  not loaded into TMEM; so are the 4-bit formats. RGBA16 is what `pak build`
  converts to.
- Sprites larger than TMEM (4 KiB) are drawn as horizontal strips, one
  LOAD_TILE and one TEXTURE_RECTANGLE each.

---

### `n64.surface` — Surface (Framebuffer/Image) Allocation

```pak
use n64.surface          -- #include <surface.h>
```

| Function | Maps to | Description |
|----------|---------|-------------|
| `surface.alloc` | `surface_alloc` | Allocate a `surface_t` (format, w, h) |
| `surface.free` | `surface_free` | Free a surface |
| `surface.make_sub` | `surface_make_sub` | Create a sub-surface view |

---

### `n64.timer` — Timing

```pak
use n64.timer            -- #include <n64sys.h>
```

| Function | Signature | Description |
|----------|-----------|-------------|
| `timer.init` | `()` | Initialize timer subsystem |
| `timer.delta` | `() -> f32` | Delta time in seconds since last call |
| `timer.get_ticks` | `() -> u64` | Raw timer tick count (`get_ticks`) |

---

### `n64.system` — System / Console Info

```pak
use n64.system           -- #include <n64sys.h>
```

| Function | Maps to | Description |
|----------|---------|-------------|
| `system.memory_size` | `get_memory_size` | RAM size in bytes (4 MB or 8 MB) |
| `system.has_expansion` | `> 0x400000` | True if Expansion Pak present |
| `system.ticks` | `TICKS_READ()` | Raw CPU tick counter |
| `system.ticks_to_ms` | `TICKS_TO_MS(x)` | Convert ticks to milliseconds |
| `system.reset` | `n64sys_reset` | Soft-reset the console |
| `system.tv_type` | `sys_tv_type` | NTSC/PAL/MPAL TV type |

---

### `n64.math` — Math Helpers

```pak
use n64.math             -- #include <n64sys.h> + <math.h>
```

This module **exists** (it lowers to C `math.h` / libdragon helpers).

| Function | Maps to | Description |
|----------|---------|-------------|
| `math.abs_i32` | `abs` | Integer absolute value |
| `math.min_i32` | `MIN` | Integer min |
| `math.max_i32` | `MAX` | Integer max |
| `math.clamp_i32` | `CLAMP` | Clamp int into range |
| `math.abs_f` | `fabsf` | Float absolute value |
| `math.min_f` | `fminf` | Float min |
| `math.max_f` | `fmaxf` | Float max |
| `math.clamp_f` | `fminf(fmaxf(...))` | Clamp float into range |
| `math.floor_f` | `floorf` | Floor |
| `math.ceil_f` | `ceilf` | Ceiling |
| `math.sin_f` | `sinf` | Sine (radians) |
| `math.cos_f` | `cosf` | Cosine (radians) |
| `math.tan_f` | `tanf` | Tangent |
| `math.atan2_f` | `atan2f` | Two-arg arctangent |
| `math.sqrt_f` | `sqrtf` | Square root |
| `math.pow_f` | `powf` | Power |
| `math.lerp_f` | `a + (b-a)*t` | Linear interpolation |
| `math.fix_to_f` | `/ 65536.0f` | fix16.16 → f32 |
| `math.f_to_fix` | `* 65536.0f` | f32 → fix16.16 |
| `math.fix_sin` | fixed sine | fix16.16 sine |
| `math.fix_cos` | fixed cosine | fix16.16 cosine |
| `math.fix_sqrt` | fixed sqrt | fix16.16 square root |
| `math.rand` | `__pak_rand()` | Random u32 |
| `math.rand_seed` | `__pak_srand(s)` | Seed the RNG |
| `math.rand_range` | `__pak_rand_range(lo, hi)` | Random int in range |
| `math.rand_f` | `__pak_rand_f()` | Random f32 in [0,1) |

---

### `n64.mem` — Raw Heap / Memory Operations

```pak
use n64.mem              -- #include <malloc.h> + <string.h>
```

| Function | Maps to | Description |
|----------|---------|-------------|
| `mem.alloc` | `malloc(size)` | Allocate raw bytes |
| `mem.alloc_aligned` | `memalign(align, size)` | Aligned allocation |
| `mem.free` | `free(ptr)` | Free |
| `mem.realloc` | `realloc(ptr, size)` | Resize |
| `mem.zero` | `memset(ptr, 0, n)` | Zero a region |
| `mem.copy` | `memcpy(dst, src, n)` | Copy bytes |
| `mem.move` | `memmove(dst, src, n)` | Overlapping copy |

---

### `n64.dma` — Direct Memory Access

```pak
use n64.dma              -- #include <dma.h>
```

| Function | Signature | Description |
|----------|-----------|-------------|
| `dma.read` | `(dst: *u8, src: u32, len: u32)` | DMA from ROM/PI to RAM |
| `dma.write` | `(src: *u8, dst: u32, len: u32)` | DMA from RAM to peripheral |
| `dma.wait` | `()` | Wait for DMA to complete |

**Required sequence — copy exactly:**
```pak
cache.writeback(&buf[0], len)    -- 1. flush cache to RAM
dma.read(&buf[0], rom_addr, len) -- 2. ROM → RAM via PI DMA
dma.wait()                       -- 3. wait for PI DMA completion
cache.invalidate(&buf[0], len)   -- 4. invalidate so CPU reads fresh data
```

**Safety requirements (enforced by checker):**
- `dst` must be `@aligned(16)` (E202 if missing)
- `cache.writeback` must precede DMA (E201 if missing)
- See `N64_HARDWARE.md` → DMA for the full explanation.

---

### `n64.cache` — Cache Management

```pak
use n64.cache            -- #include <n64sys.h>
```

| Function | Maps to | Description |
|----------|---------|-------------|
| `cache.writeback` | `data_cache_hit_writeback` | Writeback cache lines |
| `cache.invalidate` | `data_cache_hit_invalidate` | Invalidate cache lines |
| `cache.writeback_inv` | `data_cache_hit_writeback_invalidate` | Writeback + invalidate |

---

### `n64.rsp` — RSP / Display-List Queue (rspq)

```pak
use n64.rsp              -- #include <rspq.h>
```

| Function | Maps to | Description |
|----------|---------|-------------|
| `rsp.init` | `rspq_init` | Initialize the RSP command queue |
| `rsp.close` | `rspq_close` | Shut down |
| `rsp.wait` | `rspq_wait` | Wait for the RSP to drain |
| `rsp.syncpoint_new` | `rspq_syncpoint_new` | Create a syncpoint |
| `rsp.syncpoint_check` | `rspq_syncpoint_check` | Test if a syncpoint passed |
| `rsp.block_begin` | `rspq_block_begin` | Begin recording a block |
| `rsp.block_end` | `rspq_block_end` | Finish recording |
| `rsp.block_run` | `rspq_block_run` | Replay a block |
| `rsp.block_free` | `rspq_block_free` | Free a block |

---

### `n64.vi` — Video Interface Control

```pak
use n64.vi               -- #include <display.h>
```

| Function | Maps to | Description |
|----------|---------|-------------|
| `vi.set_aa_mode` | `vi_set_aa_mode` | Set anti-alias mode |
| `vi.set_dedither` | `vi_set_dedither` | Enable/disable de-dithering |
| `vi.set_gamma` | `vi_set_gamma` | Set gamma mode |
| `vi.set_divot` | `vi_set_divot` | Enable/disable divot filter |
| `vi.get_width` | `display_get_width` | Current framebuffer width |
| `vi.get_height` | `display_get_height` | Current framebuffer height |
| `vi.wait_vblank` | `vi_wait_vblank` | Block until vertical blank |

---

## Audio Modules

### `n64.audio` — Low-Level Audio

```pak
use n64.audio            -- #include <audio.h> + <xm64.h> + <wav64.h>
```

| Function | Signature | Description |
|----------|-----------|-------------|
| `audio.init` | `(frequency: i32, buffers: i32)` | Initialize audio |
| `audio.close` | `()` | Shut down audio |
| `audio.get_buffer` | `() -> *i16` | Get next output buffer (or `none`) |
| `audio.get_frequency` | `() -> i32` | Active sample rate |
| `audio.can_write` | `() -> bool` | True if a buffer is ready to fill |
| `audio.write` | `(buf: *i16)` | Submit a filled buffer |
| `audio.write_silence` | `()` | Submit a silent buffer |
| `audio.set_buffer_num` | `(n: i32)` | Set number of audio buffers |

**Behavioral rules:**
- `frequency`: `22050`, `32000`, or `44100` (Hz). Other values become 44100.
- `buffers`: `2`–`8`; `4` is a good default. Values outside the range are clamped.
- `audio.get_buffer()` returns `none` if no buffer is ready — always check.
- Buffer is interleaved stereo `i16`: `[L, R, L, R, ...]`. Fill it entirely.
- On the standalone HAL this is a real AI DMA: DACRATE/BITRATE, `get_buffer`
  auto-submits the previous buffer so a fill-only game loop still plays.
- See `N64_HARDWARE.md` → Audio System for buffer size calculation.

---

### `n64.mixer` — Audio Mixer Channels

```pak
use n64.mixer            -- #include <audio.h> + <mixer.h>
```

| Function | Maps to | Description |
|----------|---------|-------------|
| `mixer.init` | `mixer_init` | Initialize the mixer (channel count) |
| `mixer.close` | `mixer_close` | Shut down |
| `mixer.ch_play` | `mixer_ch_play` | Play a waveform on a channel |
| `mixer.ch_stop` | `mixer_ch_stop` | Stop a channel |
| `mixer.ch_set_vol` | `mixer_ch_set_vol` | Set channel volume (L, R) |
| `mixer.ch_set_freq` | `mixer_ch_set_freq` | Set channel frequency |
| `mixer.poll` | `audio_poll` | Pump the mixer (call each frame) |

---

### `n64.xm64` — XM Tracker Music

```pak
use n64.xm64             -- #include <xm64.h>
```

| Function | Maps to | Description |
|----------|---------|-------------|
| `xm64.open` | `xm64player_open` | Open an `.xm64` module into a player |
| `xm64.close` | `xm64player_close` | Close the player |
| `xm64.play` | `xm64player_play` | Start playback on first mixer channel |
| `xm64.stop` | `xm64player_stop` | Stop playback |
| `xm64.set_vol` | `xm64player_set_vol` | Set music volume |

Player state is an `xm64player_t` (opaque libdragon type, see opaque-types note).

---

### `n64.wav64` — WAV Sound Effects

```pak
use n64.wav64            -- #include <wav64.h>
```

| Function | Maps to | Description |
|----------|---------|-------------|
| `wav64.open` | `wav64_open` | Open a `.wav64` into a `wav64_t` |
| `wav64.close` | `wav64_close` | Close it |
| `wav64.play` | `wav64_play` | Play on a mixer channel |
| `wav64.set_loop` | `wav64_set_loop` | Enable/disable looping |

---

## Save / Backup Memory Modules

### `n64.eeprom` — EEPROM Save Storage

```pak
use n64.eeprom           -- #include <eeprom.h>
```

| Function | Signature | Description |
|----------|-----------|-------------|
| `eeprom.init` | `()` | Probe the cartridge EEPROM (`eeprom_init`) |
| `eeprom.present` | `() -> i32` | 1 if 4K or 16K EEPROM is on the cart |
| `eeprom.type_detect` | `() -> i32` | 0 = none, 1 = 4K (64 blocks), 2 = 16K (256 blocks) |
| `eeprom.read` | `(block: i32, dst: *u8)` | Read an 8-byte block |
| `eeprom.write` | `(block: i32, src: *u8)` | Write an 8-byte block |

**Behavioral rules:**
- Each block = exactly **8 bytes**. `dst`/`src` must point to at least 8 bytes.
- EEPROM 4K = 64 blocks (512 B); EEPROM 16K = 256 blocks (2048 B).
- Writes are slow (~15 ms/block) — only write when save data changes.
- Always call `eeprom.present()` before read/write. On the standalone HAL this
  is a real SI/PIF Joybus identify (channel 4); there is no libdragon fallback.
- See `N64_HARDWARE.md` → EEPROM for the save/load pattern.

---

### `n64.sram` — Battery-Backed SRAM

```pak
use n64.sram             -- #include <backup.h>
```

| Function | Maps to | Description |
|----------|---------|-------------|
| `sram.read` | `sram_read` | Read from SRAM |
| `sram.write` | `sram_write` | Write to SRAM |

---

### `n64.flashram` — FlashRAM Save Storage

```pak
use n64.flashram         -- #include <backup.h>
```

| Function | Maps to | Description |
|----------|---------|-------------|
| `flashram.read` | `flashram_read` | Read from FlashRAM |
| `flashram.write` | `flashram_write` | Write to FlashRAM |
| `flashram.erase_sector` | `flashram_erase_sector` | Erase a sector before write |

---

### `n64.backup` — Generic Save-Type Detection

```pak
use n64.backup           -- #include <backup.h>
```

| Function | Maps to | Description |
|----------|---------|-------------|
| `backup.type` | `backup_type` | Detect save type (none/EEPROM/SRAM/Flash) |
| `backup.read` | `backup_read` | Read save data generically |
| `backup.write` | `backup_write` | Write save data generically |
| `backup.size` | `backup_size` | Total save capacity in bytes |

---

## Accessory Modules

### `n64.rumble` — Rumble Pak

```pak
use n64.rumble           -- #include <joypad.h> + <rumble.h>
```

| Function | Signature | Description |
|----------|-----------|-------------|
| `rumble.init` | `()` | Initialize rumble |
| `rumble.start` | `(port: i32)` | Start rumble on port |
| `rumble.stop` | `(port: i32)` | Stop rumble on port |
| `rumble.is_plugged` | `(port: i32) -> bool` | True if a Rumble Pak is in the port |

---

### `n64.cpak` — Controller Pak (Memory Card)

```pak
use n64.cpak             -- #include <cpak.h>
```

| Function | Signature | Description |
|----------|-----------|-------------|
| `cpak.init` | `()` | Initialize controller pak |
| `cpak.is_plugged` | `(port: i32) -> bool` | Check if pak is plugged in |
| `cpak.is_formatted` | `(port: i32) -> bool` | Check if pak is formatted |
| `cpak.format` | `(port: i32)` | Format controller pak |
| `cpak.read_sector` | `(port: i32, sector: i32, dst: *u8)` | Read a sector |
| `cpak.write_sector` | `(port: i32, sector: i32, src: *u8)` | Write a sector |
| `cpak.get_free_space` | `(port: i32) -> i32` | Free space in pages |

---

### `n64.tpak` — Transfer Pak

```pak
use n64.tpak             -- #include <tpak.h>
```

| Function | Maps to | Description |
|----------|---------|-------------|
| `tpak.init` | `tpak_init` | Initialize transfer pak on a port |
| `tpak.set_power` | `tpak_set_power` | Power the inserted Game Boy cart on/off |
| `tpak.get_status` | `tpak_get_status` | Read status register |
| `tpak.read` | `tpak_read` | Read Game Boy cartridge memory |
| `tpak.write` | `tpak_write` | Write Game Boy cartridge memory |

---

### `n64.mouse` — N64 Mouse

```pak
use n64.mouse            -- #include <joypad.h>
```

| Function | Maps to | Description |
|----------|---------|-------------|
| `mouse.init` | `joypad_init` | Initialize (shares joypad subsystem) |
| `mouse.poll` | `joypad_poll` | Poll |
| `mouse.get_delta_x` | `joypad_get_axis_pressed(X)` | X movement since last poll |
| `mouse.get_delta_y` | `joypad_get_axis_pressed(Y)` | Y movement since last poll |
| `mouse.get_buttons` | `joypad_get_buttons_pressed` | Pressed buttons mask |

---

### `n64.vru` — Voice Recognition Unit

```pak
use n64.vru              -- #include <vru.h>
```

| Function | Maps to | Description |
|----------|---------|-------------|
| `vru.init` | `vru_init` | Initialize the VRU |
| `vru.close` | `vru_close` | Shut down |
| `vru.read_word` | `vru_read_word` | Read a recognized word index |
| `vru.write_word_list` | `vru_write_word_list` | Upload the word vocabulary |
| `vru.is_ready` | `vru_is_ready` | True when a result is available |

---

### `n64.rtc` — Real-Time Clock

```pak
use n64.rtc              -- #include <rtc.h>
```

| Function | Maps to | Description |
|----------|---------|-------------|
| `rtc.init` | `rtc_init` | Initialize the RTC |
| `rtc.get` | `rtc_get` | Read current time |
| `rtc.set` | `rtc_set` | Set the time |
| `rtc.is_stopped` | `rtc_is_stopped` | True if the clock is halted |
| `rtc.is_running` | `!rtc_is_stopped()` | True if the clock is running |

---

### `n64.disk` — 64DD Disk Drive

```pak
use n64.disk             -- #include <disk.h>
```

| Function | Maps to | Description |
|----------|---------|-------------|
| `disk.init` | `disk_init` | Initialize the 64DD interface |
| `disk.close` | `disk_close` | Shut down |
| `disk.read_sector` | `disk_read_sector` | Read a disk sector |
| `disk.write_sector` | `disk_write_sector` | Write a disk sector |
| `disk.get_disk_type` | `disk_get_disk_type` | Identify the inserted disk |
| `disk.is_present` | `disk_is_present` | True if a disk is inserted |

---

## Debug / System Modules

### `n64.debug` — Debug Output

```pak
use n64.debug            -- #include <debug.h>
```

| Function | Maps to | Description |
|----------|---------|-------------|
| `debug.log` | `debugf` | Print a debug string (accepts format strings) |
| `debug.print` | `debugf` | Alias of `debug.log` |
| `debug.assert` | `assert` | Halt if condition is false |
| `debug.init` | `debug_init_isviewer` | Initialize IS-Viewer debug channel |
| `debug.init_usbfs` | `debug_init_usbfs` | Initialize USB filesystem debug channel |
| `debug.flush` | `flush` | Flush debug output |

Output goes to the libdragon debug channel — visible only on dev hardware/emu.

---

### `n64.exception` — CPU Exception Handlers

```pak
use n64.exception        -- #include <exception.h>
```

| Function | Maps to | Description |
|----------|---------|-------------|
| `exception.set_handler` | `exception_set_handler` | Install an exception handler |
| `exception.get_handler` | `exception_get_handler` | Get the current handler |

On the standalone MIPS HAL the crt0 installs the four VR4300 vectors
(0x80000000 / 80 / 100 / 180). The default handler fills every framebuffer
with RGBA5551 `0xF801` (solid red) and points the Video Interface at FB0, so
a CPU exception or `assert` is a red screen rather than a black hang. A
non-zero handler installed via `set_handler` is `jalr`'d instead.

---

### `n64.interrupt` — RCP Interrupts (standalone only)

```pak
use n64.interrupt
```

**Standalone backend only.** libdragon has its own interrupt layer
(`enable_interrupts`, `register_VI_handler`) with a different shape, so
`pak check --backend c` reports W005 on every entry here.

| Function | Maps to | Description |
|----------|---------|-------------|
| `interrupt.init()` | `interrupt_init` | Arm the VI source and enable IP2 |
| `interrupt.vi_count()` | `interrupt_vi_count` | Frames the handler has serviced |
| `interrupt.pending()` | `interrupt_pending` | MI sources seen since `init` |
| `interrupt.enabled()` | `interrupt_enabled` | Non-zero once `init` has run |
| `interrupt.disable()` | `interrupt_disable` | Clear `Status.IE`, return the old Status |
| `interrupt.restore(s)` | `interrupt_restore` | Put a saved Status back |

Before `interrupt.init()`, `display.show()` spins on `VI_V_CURRENT`. After it,
the same call waits on the counter the handler bumps and leaves the CPU alone
between frames — nothing else in a program has to change.

```pak
display.init(0, 2, 3, 0, 1)
interrupt.init()

loop {
    let fb: u32 = display.get()
    -- draw
    display.show(fb)      -- now an interrupt-driven wait
}
```

`interrupt.disable()` returns the previous Status rather than a flag, so a
critical section restores what was actually there:

```pak
let saved: u32 = interrupt.disable()
-- ... touch state the handler also touches ...
interrupt.restore(saved)
```

See N64_HARDWARE.md for the three things that must line up for a source to be
delivered, and the per-device acknowledge each one needs.

---

### `n64.sp` — the RSP's registers (standalone only)

```pak
use n64.sp
```

**Standalone backend only**, and not the same thing as `n64.rsp`: that module
is libdragon's rspq command queue, a whole scheduler. This is the SP register
block — load a microcode image, start it, wait for it, move data in and out.
libdragon's `rsp_*` functions have the same shape of name and different
signatures, so these are `pak_sp_*` underneath and `pak check --backend c`
reports W005 on all of them.

| Function | Maps to | Description |
|----------|---------|-------------|
| `sp.init()` | `pak_sp_init` | Halt the RSP and clear its break/step/interrupt state |
| `sp.load_ucode(src, len)` | `pak_sp_load_ucode` | RDRAM → IMEM |
| `sp.load_data(src, off, len)` | `pak_sp_load_data` | RDRAM → DMEM at `off` |
| `sp.read_data(dst, off, len)` | `pak_sp_read_data` | DMEM at `off` → RDRAM |
| `sp.run(pc)` | `pak_sp_run` | Point the RSP at an IMEM offset and release it |
| `sp.wait()` | `pak_sp_wait` | Block until it halts or breaks |
| `sp.done()` | `pak_sp_done` | Non-zero once it has halted or broken |
| `sp.status()` | `pak_sp_status` | Raw SP_STATUS |

**Pak does not compile to the RSP.** It is a different instruction set with a
vector unit; a task's words come from somewhere else. But the RSP's *scalar*
half is a MIPS I subset, so `pak asmobj` can assemble one — which is how
`tcl/tests/ares/rsp_add.S` is built.

Every address and length in an SP DMA must be a multiple of 8; the HAL panics
rather than let the hardware silently truncate a misaligned transfer. `src` and
`dst` are cached RDRAM addresses and the HAL does the writeback and invalidate
around them.

```pak
use n64.sp

@aligned(16)
static ucode: [8]u32 = [ ... ]     -- assembled elsewhere
@aligned(16)
static args: [2]u32 = [a, b]
@aligned(16)
static result: [2]u32 = [0, 0]

sp.init()
sp.load_ucode(&ucode[0] as u32, 32)
sp.load_data(&args[0] as u32, 0, 8)
sp.run(0)
sp.wait()
sp.read_data(&result[0] as u32, 8, 8)
```

A task ends with `break`. Without one the RSP runs off the end of IMEM, never
halts, and `sp.wait()` never returns.

---

## Pak Runtime Modules

These are not libdragon wrappers — they are built into the generated output
(no extra header). Import paths use the `pak.` prefix.

### `pak.str` — Fat-String Helpers

```pak
use pak.str              -- module namespace: str
```

| Function | Lowering | Description |
|----------|----------|-------------|
| `str.from_cstr(s)` | `pak_str_from_cstr` | Build a `Str` from a `*c_char` |
| `str.eq(a, b)` | `pak_str_eq` | Content equality |
| `str.len(s)` | `s.len` | Length |
| `str.data(s)` | `s.data` | Data pointer |
| `str.print(s)` | `debugf("%.*s", ...)` | Print a `Str` to the debug channel |
| `str.concat(a, b)` | runtime concat | Concatenate two strings |

(See also the `Str`/`CStr` instance methods above.)

### `pak.arena` — Bump Allocator

```pak
use pak.arena            -- module namespace: arena
```

| Function | Lowering | Description |
|----------|----------|-------------|
| `arena.alloc(a, size)` | `pak_arena_alloc(&a, size)` | Bump-allocate from the arena |
| `arena.reset(a)` | `pak_arena_reset(&a)` | Reset the arena to empty |

The arena value has type `Arena` (lowers to `PakArena`).

---

## 3D Library (Tiny3D / T3D)

Import any `t3d.*` submodule (`t3d.core`, `t3d.model`, `t3d.math`, `t3d.anim`,
`t3d.light`, `t3d.viewport`, `t3d.skeleton`, `t3d.fog`, `t3d.state`,
`t3d.particles`) — **all of them map to the single `t3d` API namespace.** Call
functions as `t3d.fn(...)`.

```pak
use t3d                  -- or: use t3d.core / use t3d.model / ...
```

Headers pulled in by submodule:
`t3d.core` / `t3d.viewport` / `t3d.fog` / `t3d.state` / `t3d.particles` →
`<t3d/t3d.h>`; `t3d.model` → `<t3d/t3dmodel.h>`; `t3d.math` → `<t3d/t3dmath.h>`;
`t3d.anim` → `<t3d/t3danim.h>`; `t3d.light` → `<t3d/t3dlight.h>`;
`t3d.skeleton` → `<t3d/t3dskeleton.h>`.

For T3D math functions, **the output is the first argument** (a pointer); codegen
inserts `&` automatically if you pass a value.

### Core / Frame

| Function | Description |
|----------|-------------|
| `t3d.init()` | Initialize T3D |
| `t3d.destroy()` | Shut down T3D |
| `t3d.frame_start()` | Begin a 3D frame |
| `t3d.frame_end()` | End/submit a frame (`rspq_block_run`) |
| `t3d.screen_projection(...)` | Set screen-space projection |
| `t3d.segment_set(...)` | Bind a memory segment for the RSP |

### Viewport / Camera

| Function | Description |
|----------|-------------|
| `t3d.viewport_create() -> T3DViewport` | Create a viewport |
| `t3d.viewport_attach(vp: *T3DViewport)` | Make a viewport active |
| `t3d.viewport_set_projection(vp, fov, near, far)` | Set perspective projection |
| `t3d.viewport_set_fov(vp, fov)` | Set FOV only |
| `t3d.set_camera(vp, eye, target)` | Set camera (`t3d_set_camera`) |
| `t3d.look_at(vp, eye, target, up)` | Look-at camera (`t3d_look_at`) |

### Model

| Function | Description |
|----------|-------------|
| `t3d.model_load(path: *c_char) -> *T3DModel` | Load a `.t3dm` model |
| `t3d.model_free(model: *T3DModel)` | Free a model |
| `t3d.model_draw(model: *T3DModel)` | Draw a model |
| `t3d.model_get_object_by_index(model, i)` | Get sub-object by index |
| `t3d.model_get_object_by_name(model, name)` | Get sub-object by name |
| `t3d.model_get_material(model, ...)` | Get a material |
| `t3d.model_get_vertex_count(model)` | Vertex count |
| `t3d.model_bake_pos(...)` | Bake vertex positions |
| `t3d.draw_object(obj: *T3DObject)` | Draw a single model object |
| `t3d.draw_indexed(...)` | Indexed draw |
| `t3d.rdpq_draw_object(...)` | Draw object via rdpq path |

### Matrix Math (output = first arg)

| Function | Description |
|----------|-------------|
| `t3d.mat4_identity(out: *Mat4)` | Identity |
| `t3d.mat4_rotate_x/y/z(out, angle)` | Axis rotation |
| `t3d.mat4_translate(out, x, y, z)` | Translation |
| `t3d.mat4_scale(out, x, y, z)` | Scale |
| `t3d.mat4_mul(out, a, b)` | Matrix multiply |
| `t3d.mat4_from_srt(out, scale, rot, translate)` | Compose from scale/rot/translate |
| `t3d.mat4_from_srt_euler(out, scale, euler, translate)` | Compose with Euler rotation |
| `t3d.mat4_invert(out, in)` | Inverse |
| `t3d.mat4_transpose(out, in)` | Transpose |

### Vector Math (T3DVec3)

| Function | Description |
|----------|-------------|
| `t3d.vec3_norm(out)` | Normalize in place |
| `t3d.vec3_cross(out, a, b)` | Cross product |
| `t3d.vec3_dot(a, b) -> f32` | Dot product |
| `t3d.vec3_lerp(out, a, b, t)` | Linear interpolate |

### Quaternions

| Function | Description |
|----------|-------------|
| `t3d.quat_identity(out)` | Identity quaternion |
| `t3d.quat_from_axis_angle(out, axis, angle)` | From axis + angle |
| `t3d.quat_mul(out, a, b)` | Multiply |
| `t3d.quat_nlerp(out, a, b, t)` | Normalized lerp |
| `t3d.quat_slerp(out, a, b, t)` | Spherical lerp |

### Lighting

| Function | Description |
|----------|-------------|
| `t3d.light_set_ambient(rgba)` | Ambient light color |
| `t3d.light_set_count(n)` | Number of active lights |
| `t3d.light_set_directional(idx, color, dir)` | Directional light |
| `t3d.light_set_point(idx, color, pos, ...)` | Point light |
| `t3d.light_set_point_params(...)` | Point-light attenuation params |
| `t3d.light_set_spot(idx, ...)` | Spot light |

### Fog

| Function | Description |
|----------|-------------|
| `t3d.fog_set_enabled(on)` | Enable/disable fog (default arg `true`) |
| `t3d.fog_set_range(near, far)` | Fog distance range |
| `t3d.fog_set_color(rgba)` | Fog color |

### State

| Function | Description |
|----------|-------------|
| `t3d.state_set_vertex_fx(...)` | Set vertex FX mode |
| `t3d.state_set_drawflags(flags)` | Set draw flags |
| `t3d.push_draw_flags(flags)` | Push draw-flag state |
| `t3d.pop_draw_flags()` | Pop draw-flag state |

### Animation

| Function | Description |
|----------|-------------|
| `t3d.anim_create(model, name) -> T3DAnim` | Create an animation |
| `t3d.anim_destroy(anim)` | Destroy |
| `t3d.anim_set_playing(anim, bool)` | Play/pause |
| `t3d.anim_set_looping(anim, bool)` | Loop on/off |
| `t3d.anim_set_speed(anim, speed)` | Playback speed |
| `t3d.anim_update(anim, dt)` | Advance the animation |
| `t3d.anim_attach(anim, skeleton)` | Attach to a skeleton |

### Skeleton

| Function | Description |
|----------|-------------|
| `t3d.skeleton_create(model) -> T3DSkeleton` | Create a skeleton |
| `t3d.skeleton_destroy(skel)` | Destroy |
| `t3d.skeleton_update(skel)` | Update bone matrices |
| `t3d.skeleton_draw(skel, model)` | Draw a skinned model |

### Low-Level Vertex / Triangle

| Function | Description |
|----------|-------------|
| `t3d.vert_load(...)` | Load vertices into the RSP |
| `t3d.vert_load_srt(...)` | Load with SRT transform |
| `t3d.tri_draw(...)` | Draw a triangle |
| `t3d.tri_sync()` | Sync after triangle batch |

### T3D / Libdragon Opaque Types

The following types are used as opaque externs in Pak code. They come from
the libdragon / Tiny3D C headers (no Pak definition); you typically hold them
as `static ... = undefined` state or behind a pointer, and pass them to the
module functions above:

`T3DViewport`, `T3DModel`, `T3DMat4`, `T3DMat4FP`, `T3DVec3`, `T3DVec2`,
`T3DSkeleton`, `T3DAnim`, `T3DObject`, and the libdragon types
`sprite_t`, `surface_t`, `wav64_t`, `xm64player_t`, `rdpq_font_t`.

`Vec2`/`Vec3`/`Vec4`/`Mat4` are Pak aliases for the corresponding `T3DVec*` /
`T3DMat4` (see the built-in vector/matrix methods section above).

---

## Runtime Helpers (Internal — Do Not Call Directly)

These are emitted by the compiler. Do not call them in Pak source:

- `__pak_fix16_div(dividend, divisor)` — fixed-point division
- `__pak_delta_time()` — backs `timer.delta()`
- `__pak_rand()` / `__pak_srand()` / `__pak_rand_range()` / `__pak_rand_f()` — back `math.rand*`
- `pak_str_*`, `pak_arena_*`, `pak_vec3_*`, `pak_vec2_*`, `pak_mat4_*` — back the
  built-in string / arena / vector / matrix methods.

---

## What Does NOT Exist

- No `string` module — use `pak.str` plus the `Str`/`CStr` instance methods.
- No `io` / `os` / `file` module — no general file I/O in the Pak stdlib.
- No `collections` module — use the built-in generic containers.
- No `network` / threading / concurrency modules.

If a module or function is not in the generated index (and not in
`tcl/module_api.tcl`), it does not exist — do not invent it. `pak check`
reports **E010**.
