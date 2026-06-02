# Phase 5: N64 & Decomp Specialization

Goal: handle the specific patterns, APIs, and conventions found in N64 homebrew code
(libdragon) and decompilation projects (SM64, OoT, etc.).

## 5.1 — Libdragon API Mapping

The existing PAK codebase already has a complete mapping of libdragon C functions to PAK
module calls (in `pak/codegen.py` MODULE_API and `pak/mips/n64_runtime.py`). The C-to-PAK
transpiler needs to reverse this mapping.

### Forward Table (C → PAK module call)

| C Function Call | PAK Module Call |
|----------------|-----------------|
| `display_init(...)` | `n64.display.init(...)` |
| `display_get()` | `n64.display.get()` |
| `display_show(disp)` | `n64.display.show(disp)` |
| `joypad_init()` | `n64.controller.init()` |
| `joypad_poll()` | `n64.controller.poll()` |
| `joypad_get_status(port)` | `n64.controller.read(port)` |
| `rdpq_init()` | `n64.rdpq.init()` |
| `rdpq_attach(...)` | `n64.rdpq.attach(...)` |
| `rdpq_detach_show()` | `n64.rdpq.detach_show()` |
| `rdpq_set_mode_standard()` | `n64.rdpq.set_mode_standard()` |
| `rdpq_fill_rectangle(...)` | `n64.rdpq.fill_rectangle(...)` |
| `sprite_load(path)` | `n64.sprite.load(path)` |
| `rdpq_sprite_blit(...)` | `n64.sprite.blit(...)` |
| `timer_init()` | `n64.timer.init()` |
| `debugf(...)` | `n64.debug.log(...)` |
| `audio_init(...)` | `n64.audio.init(...)` |
| `dma_read(...)` | `n64.dma.read(...)` |
| `data_cache_hit_writeback(...)` | `n64.cache.writeback(...)` |
| ... (200+ total) | ... |

### Implementation

Build the reverse lookup table automatically from the existing `MODULE_API` and
`N64_SYMBOLS` dictionaries:

```python
# c2pak/n64_mapper.py
def build_reverse_api():
    """Invert MODULE_API: C function name → (module, pak_function)"""
    reverse = {}
    for (module, fn), c_name in MODULE_API.items():
        if isinstance(c_name, str):
            reverse[c_name] = (module, fn)
    return reverse
```

When the transpiler sees a call to `display_init(...)`, it emits `n64.display.init(...)` and
adds `use n64.display` to the file header.

### Include → use Mapping

| C Include | PAK Use Declaration |
|-----------|-------------------|
| `#include <libdragon.h>` | `use n64.display`, `use n64.controller`, etc. (only what's actually used) |
| `#include <display.h>` | `use n64.display` |
| `#include <rdpq.h>` | `use n64.rdpq` |
| `#include <joypad.h>` | `use n64.controller` |
| `#include <timer.h>` | `use n64.timer` |
| `#include <audio.h>` | `use n64.audio` |
| `#include <sprite.h>` | `use n64.sprite` |
| `#include <t3d/...>` | `use n64.t3d` |

Only emit `use` declarations for modules whose functions are actually called.

## 5.2 — Decomp-Specific Types & Conventions

N64 decomp projects (SM64, OoT, MM, DK64, Banjo, etc.) share common conventions.

### Standard Decomp Type Mappings

| Decomp Type | PAK Type | Source |
|-------------|----------|--------|
| `s8` / `s16` / `s32` / `s64` | `i8` / `i16` / `i32` / `i64` | ultra64 types |
| `u8` / `u16` / `u32` / `u64` | `u8` / `u16` / `u32` / `u64` | ultra64 types |
| `f32` / `f64` | `f32` / `f64` | ultra64 types |
| `Vec3f` | `struct Vec3 { x: f32, y: f32, z: f32 }` | Common in SM64/OoT |
| `Vec3s` | `struct Vec3s { x: i16, y: i16, z: i16 }` | Short vector |
| `Mtx` / `MtxF` | `struct Mat4 { ... }` | 4x4 matrix |
| `Gfx` | Opaque display list type | RDP commands |
| `OSMesg` / `OSMesgQueue` | OS message passing | |
| `Actor` / `ObjectNode` | `variant` (with idiom detection) | |

### Decomp Struct Patterns

Decomp code often has inheritance-like struct patterns:

```c
// OoT-style actor hierarchy
typedef struct {
    /* 0x000 */ Vec3f world_pos;
    /* 0x00C */ Vec3s world_rot;
    /* 0x012 */ u8 flags;
    // ... base actor fields ...
} Actor;

typedef struct {
    /* 0x000 */ Actor actor;  // "inherits" Actor
    /* 0x14C */ s16 action_state;
    /* 0x14E */ s16 timer;
    // ... player-specific fields ...
} Player;
```

→

```pak
struct Actor {
    world_pos: Vec3,
    world_rot: Vec3s,
    flags: u8,
    // ...
}

struct Player {
    actor: Actor,       // composition (PAK doesn't have inheritance)
    action_state: i16,
    timer: i16,
    // ...
}

impl Player {
    // Methods that access self.actor.world_pos, etc.
}
```

### Offset Comments

Decomp code often has byte-offset comments (`/* 0x000 */`). Preserve these as regular
comments in the PAK output for cross-referencing with the original decomp.

## 5.3 — GCC Extensions & Non-Standard C

Decomp and homebrew code frequently uses GCC extensions.

| GCC Extension | Handling |
|--------------|----------|
| `__attribute__((aligned(N)))` | `@aligned(N)` |
| `__attribute__((packed))` | `@packed` |
| `__attribute__((unused))` | Drop (PAK has no unused warnings) |
| `__attribute__((section("...")))` | Emit `@section("...")` annotation or comment |
| `__attribute__((noreturn))` | `@noreturn` annotation |
| `typeof(expr)` | Resolve to concrete type at transpile time |
| `__builtin_expect(x, v)` | Strip — emit just `x` |
| `__builtin_clz(x)` | Emit as `clz(x)` extern call |
| `asm volatile(...)` | `asm("...")` PAK inline assembly |
| Statement expressions `({ ... })` | Extract to temp variable + block |
| Designated initializers `.field = val` | PAK struct literal `Struct { field: val }` |
| `__attribute__((constructor))` | Comment + manual init registration |
| Labels as values (`&&label`) | Not supported — emit warning |
| Zero-length arrays `T arr[0]` | Flexible array → comment + fixed size |

### Inline Assembly

```c
asm volatile (
    "mtc0 %0, $12"
    :
    : "r"(status)
    : "memory"
);
```

→

```pak
asm("mtc0 %0, $12" : : "r"(status) : "memory")
```

Direct mapping — PAK's inline asm syntax mirrors GCC's.

## 5.4 — N64 Hardware Patterns

### DMA Transfer Pattern

```c
// C — common DMA pattern in decomps
__attribute__((aligned(16)))
static u8 dma_buf[0x1000];

void load_segment(u32 rom_addr, u32 size) {
    dma_read(dma_buf, rom_addr, size);
    data_cache_hit_writeback(dma_buf, size);
}
```

→

```pak
@aligned(16)
static mut dma_buf: [4096]u8 = [0; 4096]

fn load_segment(rom_addr: u32, size: u32) {
    n64.dma.read(&mut dma_buf, rom_addr, size)
    n64.cache.writeback(&dma_buf, size)
}
```

### Display List Pattern

```c
Gfx *gfx = display_get();
rdpq_attach(gfx, NULL);
rdpq_set_mode_standard();
// ... draw commands ...
rdpq_detach_show();
```

→

```pak
let gfx = n64.display.get()
n64.rdpq.attach(gfx, none)
n64.rdpq.set_mode_standard()
// ... draw commands ...
n64.rdpq.detach_show()
```

### Main Loop Pattern

```c
int main(void) {
    display_init(RESOLUTION_320x240, DEPTH_16_BPP, 2, GAMMA_NONE, FILTERS_RESAMPLE);
    joypad_init();
    timer_init();

    while (1) {
        joypad_poll();
        surface_t *disp = display_get();
        rdpq_attach(disp, NULL);
        // ... game logic ...
        rdpq_detach_show();
    }
}
```

→

```pak
use n64.display
use n64.controller
use n64.timer
use n64.rdpq

entry {
    display.init(RESOLUTION_320x240, DEPTH_16_BPP, 2, GAMMA_NONE, FILTERS_RESAMPLE)
    controller.init()
    timer.init()

    loop {
        controller.poll()
        let disp = display.get()
        rdpq.attach(disp, none)
        // ... game logic ...
        rdpq.detach_show()
    }
}
```

Detect `int main(void)` or `void main(void)` → PAK `entry { ... }` block.

## 5.5 — Asset Declaration Detection

```c
// C — libdragon asset loading
sprite_t *hero = sprite_load("rom://hero.sprite");
wav64_t music;
wav64_open(&music, "rom://bgm.wav64");
```

→

```pak
asset hero_sprite from "hero.sprite"
asset music from "bgm.wav64"

entry {
    let hero = sprite.load(hero_sprite)
    wav64.open(&mut music, music_asset)
}
```

Detect `sprite_load("rom://...")` and similar asset-loading calls → hoist to top-level
`asset` declarations.

## 5.6 — Milestone Test

A libdragon example program (e.g., the `spritemap` or `rdpqdemo` example from the libdragon
repo):
- Uses display, controller, RDP APIs.
- Has a main loop with input handling.
- Loads sprite assets.

The transpiler produces a `.pk64` file that:
- Uses `n64.*` module calls instead of raw C function names.
- Has an `entry` block instead of `int main`.
- Has `asset` declarations for ROM resources.
- Compiles via the PAK pipeline.
