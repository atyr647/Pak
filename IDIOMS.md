# Pak Idioms

Canonical patterns for writing idiomatic Pak. These are how things are
*meant* to be written, not just how they *can* be written.

---

## 1. Game Entry Structure

Every N64 game follows this pattern:

```pak
use n64.display
use n64.controller
use n64.rdpq
use n64.timer

struct GameState {
    score: i32
}

fn update(gs: *GameState, input: joypad_status_t) {
    -- advance game state from input
}

fn render(gs: *GameState) {
    -- draw the current state
}

entry {
    -- 1. Initialize subsystems
    -- display.init(resolution, bit_depth, num_buffers, gamma, filters)
    -- 0=320x240, 2=16bpp, 3=triple-buffer, 0=no gamma, 1=bilinear resample
    display.init(0, 2, 3, 0, 1)
    controller.init()
    rdpq.init()
    timer.init()

    let state: GameState = GameState { score: 0 }

    -- 2. Main game loop
    loop {
        -- a. Poll input
        controller.poll()
        let input = controller.read(0)

        -- b. Update game state
        update(&state, input)

        -- c. Render
        let fb = display.get()
        rdpq.attach_clear(fb)
        render(&state)
        rdpq.detach_show()
    }
}
```

Key rules:
- **Always call `controller.poll()` before `controller.read()`** each frame.
- `display.get()` blocks until a buffer is available — call it at the start of render.
- `rdpq.detach_show()` both detaches and flips — use this instead of `detach` + `show` separately.

---

## 2. Game State Pattern

Keep all mutable game state in a struct. Pass by pointer.

```pak
struct GameState {
    x: f32
    y: f32
    health: i32
    score: i32
    phase: GamePhase
}

enum GamePhase: u8 { title, playing, paused, gameover }

fn update(gs: *GameState, input: joypad_status_t) {
    match gs.phase {
        .title   => { update_title(gs, input) }
        .playing => { update_play(gs, input) }
        .paused  => { update_pause(gs, input) }
        .gameover => {}
    }
}

entry {
    let mut gs = GameState {
        x: 160.0, y: 120.0,
        health: 3, score: 0,
        phase: GamePhase.title,
    }

    loop {
        controller.poll()
        update(&gs, controller.read(0))
        -- render...
    }
}
```

---

## 3. Fixed-Point for Position/Physics

Use `fix16.16` instead of `f32` for position and velocity on N64. The MIPS R4300i
has a weak FPU — integer math is faster for most game logic.

```pak
struct Entity {
    x: fix16.16
    y: fix16.16
    vx: fix16.16
    vy: fix16.16
}

fn entity_move(e: *Entity) {
    e.x += e.vx
    e.y += e.vy
}

fn entity_set_speed(e: *Entity, speed: fix16.16, angle_cos: fix16.16, angle_sin: fix16.16) {
    e.vx = speed * angle_cos
    e.vy = speed * angle_sin
}
```

Convert to screen coordinates for rendering:

```pak
let screen_x: i32 = entity.x as i32
let screen_y: i32 = entity.y as i32
rdpq.fill_rectangle(screen_x, screen_y, screen_x + 8, screen_y + 8)
```

---

## 4. Error Handling (Result Pattern)

Return `Result(Value, Error)` from functions that can fail. Handle at call site.

```pak
enum IoError: u8 { not_found, bad_format, out_of_memory }

fn load_config(path: *c_char) -> Result(i32, IoError) {
    -- check preconditions
    if path == none { return err(IoError.not_found) }

    -- ... do work ...

    return ok(loaded_value)
}

-- At call site:
fn init() -> Result(i32, IoError) {
    let cfg = load_config("config.bin")
    match cfg {
        .err(e) => { return err(e) }     -- propagate
        .ok(v)  => {
            -- use v
        }
    }
    return ok(0)
}
```

---

## 5. DMA Loading Pattern

Always follow this exact sequence. The typechecker enforces E201/E202 if you deviate.

```pak
use n64.dma
use n64.cache

@aligned(16)
static data_buf: [4096]u8 = undefined

fn load_rom_data() {
    -- REQUIRED order: writeback → read → wait → invalidate
    cache.writeback(&data_buf[0], 4096)
    dma.read(&data_buf[0], 0x10040000, 4096)
    dma.wait()
    cache.invalidate(&data_buf[0], 4096)
}
```

Rules:
1. Buffer **must** be `@aligned(16)` — declare it as a static.
2. Call `cache.writeback` **before** `dma.read`.
3. Call `dma.wait` before using the data.
4. Call `cache.invalidate` after `dma.wait` so the CPU sees fresh data.
5. Use inline literals for address and size args (named constants trigger false-positive checker warnings).

---

## 6. Struct with Methods (OOP Style)

Put data in a struct, behavior in an `impl` block.

```pak
struct Timer {
    elapsed: fix16.16
    limit: fix16.16
    fired: bool
}

impl Timer {
    fn init(self: *Timer, limit: fix16.16) {
        self.elapsed = 0.0
        self.limit = limit
        self.fired = false
    }

    fn update(self: *Timer, dt: fix16.16) {
        if self.fired { return }
        self.elapsed += dt
        if self.elapsed >= self.limit {
            self.fired = true
        }
    }

    fn reset(self: *Timer) {
        self.elapsed = 0.0
        self.fired = false
    }
}

-- Usage:
let mut t: Timer = undefined
t.init(3.0)    -- 3-second timer

-- in game loop:
t.update(dt)
if t.fired { trigger_event() }
```

---

## 7. Static Buffers, Not Heap Allocation

For N64, prefer `static` buffers over `alloc`. Heap fragmentation on 4 MB RAM hurts.

```pak
-- PREFERRED: static allocation
static enemy_pool: [16]Enemy = undefined
static enemy_count: i32 = 0

fn spawn_enemy(x: f32, y: f32) -> bool {
    if enemy_count >= 16 { return false }
    enemy_pool[enemy_count].x = x
    enemy_pool[enemy_count].y = y
    enemy_count += 1
    return true
}

-- AVOID unless necessary:
-- let e: *Enemy = alloc(Enemy)
```

---

## 8. Naming Conventions

| Thing | Convention | Example |
|-------|-----------|---------|
| Types (struct, enum, variant) | PascalCase | `PlayerState`, `TileKind` |
| Functions and methods | snake_case | `update_player`, `get_health` |
| Variables and parameters | snake_case | `tile_index`, `frame_dt` |
| Constants (`const`) | UPPER_SNAKE | `MAX_ENEMIES`, `SCREEN_W` |
| Statics | snake_case | `frame_count`, `score_table` |
| Enum cases | snake_case | `game_over`, `tile_wall` |
| Module-level `use` | top of file | before all declarations |
| Assets | snake_case | `player_sprite`, `bg_music` |

---

## 9. Module Organization (Multi-File)

For larger projects, split by system:

```
src/
  main.pak        -- entry block only, module main
  player.pak      -- module game.player
  enemies.pak     -- module game.enemies
  render.pak      -- module game.render
  ui.pak          -- module game.ui
```

Each non-entry file starts with `module`:

```pak
-- player.pak
module game.player

struct Player { ... }

fn player_update(p: *Player, dt: f32) { ... }
```

Main file uses them:

```pak
-- main.pak
module main

use game.player
use game.render

entry {
    let mut p: Player = undefined
    loop {
        player_update(&p, 0.016)
        render_frame(&p)
    }
}
```

---

## 10. Variant for Sum Types, Enum for Tags

Use `enum` when you just need named integer values.
Use `variant` when different cases carry different data.

```pak
-- enum: pure tag, no data
enum Direction { north, south, east, west }

-- variant: cases carry different shapes of data
variant Pickup {
    coin(i32)           -- value
    health_pack(i32)    -- amount
    key(u8)             -- key_id
    nothing
}

fn apply_pickup(player: *Player, p: Pickup) {
    match p {
        .coin(v)        => { player.score += v }
        .health_pack(h) => { player.health += h }
        .key(id)        => { player.keys |= (1 << id as i32) }
        .nothing        => {}
    }
}
```

---

## 11. Defer for Cleanup

Use `defer` for any resource that needs cleanup — it runs on scope exit
even on early `return`.

```pak
fn process_file(path: *c_char) -> Result(i32, IoError) {
    let buf: *mut u8 = alloc(u8, 4096)
    defer { free(buf) }   -- always runs, even if we return early below

    let handle = open_file(path)
    if handle == none { return err(IoError.not_found) }
    defer { close_file(handle) }

    -- ... do work ...
    return ok(result)
}
```

---

## 12. Reading Controller Input

```pak
use n64.controller

controller.init()    -- once at startup

-- in game loop:
controller.poll()                    -- must call every frame
let pad = controller.read(0)         -- port 0 = player 1

-- Digital buttons
if pad.pressed.a     { jump() }      -- true only on the frame pressed
if pad.held.right    { move_right() } -- true while held
if pad.released.b    { stop_action() }

-- Analog stick (-128 to 127)
let dx: i32 = pad.stick_x as i32
let dy: i32 = pad.stick_y as i32
```

---

## 13. Annotations — When to Use Each

```pak
-- @hot: put on functions called every frame or in tight loops
@hot
fn render_sprites(fb: *u8, sprites: *Sprite, count: i32) { ... }

-- @aligned(16): required for DMA buffers; use on statics and structs
@aligned(16)
static transfer_buf: [2048]u8 = undefined

-- @aligned(8): good for structs that benefit from 8-byte alignment
@aligned(8)
struct Vertex { x: f32, y: f32, z: f32, u: f32, v: f32 }

-- @cfg(DEBUG): include debug code only in debug builds
@cfg(DEBUG)
fn dump_state(gs: *GameState) { debug.log("state dump") }
```

---

## 14. Audio Buffer Fill Pattern

Call audio fill once per frame in your game loop.

```pak
use n64.audio

-- Called once at startup
audio.init(44100, 4)    -- 44100 Hz, 4 buffers

-- Called in game loop:
fn fill_audio() {
    let buf: *i16 = audio.get_buffer()
    if buf == none { return }    -- buffer not ready yet; skip

    -- buf is interleaved stereo: [L0, R0, L1, R1, ...]
    -- At 44100 Hz / 60 fps ≈ 735 stereo pairs = 1470 i16 values
    let i: i32 = 0
    loop {
        if i >= 1470 { break }
        buf[i]     = generate_left_sample(i / 2)   -- left
        buf[i + 1] = generate_right_sample(i / 2)  -- right
        i = i + 2
    }
}
```

Rules:
- `audio.get_buffer()` returns `none` if the hardware isn't ready — always check.
- Buffer is always **interleaved stereo** even for mono games (duplicate L→R).
- Silence is `0` for both channels.
- Never write past the buffer end — know the sample count from frequency / framerate.

---

## 15. EEPROM Save / Load

Always check presence before any EEPROM operation.

```pak
use n64.eeprom

-- Data layout: must fit in multiples of 8 bytes (one EEPROM block = 8 bytes)
const SAVE_MAGIC: u32 = 0xPAK10001   -- unique ID to detect valid saves
const SAVE_BLOCK: i32 = 0            -- which EEPROM block to use (0-indexed)

@aligned(8)
static save_raw: [8]u8 = undefined   -- one EEPROM block

fn save(score: i32) {
    if not eeprom.present() { return }
    -- Pack magic (4 bytes) + score (4 bytes) into 8-byte block
    save_raw[0] = (SAVE_MAGIC >> 24) as u8
    save_raw[1] = (SAVE_MAGIC >> 16) as u8
    save_raw[2] = (SAVE_MAGIC >> 8)  as u8
    save_raw[3] =  SAVE_MAGIC        as u8
    save_raw[4] = (score >> 24) as u8
    save_raw[5] = (score >> 16) as u8
    save_raw[6] = (score >> 8)  as u8
    save_raw[7] =  score        as u8
    eeprom.write(SAVE_BLOCK, &save_raw[0])
}

fn load() -> i32 {
    if not eeprom.present() { return 0 }
    eeprom.read(SAVE_BLOCK, &save_raw[0])
    let magic: u32 = (save_raw[0] as u32 << 24)
                   | (save_raw[1] as u32 << 16)
                   | (save_raw[2] as u32 << 8)
                   |  save_raw[3] as u32
    if magic != SAVE_MAGIC { return 0 }   -- no valid save
    return (save_raw[4] as i32 << 24)
         | (save_raw[5] as i32 << 16)
         | (save_raw[6] as i32 << 8)
         |  save_raw[7] as i32
}
```

---

## 16. RDP Fill → Sprite Render (Mode Switch)

Switch modes mid-frame requires a pipeline sync.

```pak
use n64.display
use n64.rdpq
use n64.sprite

asset player: Sprite from "sprites/player.png"
asset bg: Sprite from "sprites/bg.png"

fn render(player_x: i32, player_y: i32) {
    let fb = display.get()
    rdpq.attach_clear(fb)

    -- Fill background with solid color
    rdpq.set_mode_fill(0x1A1A2EFF)            -- dark blue background
    rdpq.fill_rectangle(0, 0, 320, 240)

    -- Switch to copy mode for sprites (sync required)
    rdpq.sync_pipe()
    rdpq.set_mode_copy()

    sprite.blit(bg, 0, 0, 0)                  -- background sprite
    sprite.blit(player, player_x, player_y, 0) -- player sprite

    rdpq.detach_show()
}
```

Rules:
- Always `rdpq.sync_pipe()` between mode changes within a frame.
- `rdpq.set_mode_copy()` must be active before any `sprite.blit()` call.
- Coordinates are screen pixels; (0,0) = top-left.
- Call `rdpq.detach_show()` exactly once per frame at the end.

---

## 17. Rumble Pattern

```pak
use n64.controller
use n64.rumble

rumble.init()           -- after controller.init(), once at startup

-- In game event handler:
fn on_player_hit() {
    rumble.start(0)     -- port 0 = player 1
}

fn on_hit_resolved() {
    rumble.stop(0)
}
```

Rules:
- Call `rumble.init()` after `controller.init()`.
- `port` is 0–3 matching `controller.read(port)`.
- Rumble Pak is not always present — in production code check with `cpak` APIs.

---

## 18. Frame Rate and Timing

```pak
use n64.timer

timer.init()    -- once at startup

-- In game loop:
let dt: f32 = timer.delta()   -- seconds since last call (e.g. 0.0167 at 60 fps)

-- Convert to fix16.16 for physics:
let dt_fixed: fix16.16 = dt as fix16.16

-- Cap dt to avoid spiral of death on lag frames:
-- (use a static to accumulate, or cap dt to 1/30s maximum)
```

Rules:
- `timer.delta()` returns `f32` seconds. At 60 fps ≈ `0.01667`.
- First call after `timer.init()` may return a large value — ignore it or cap.
- For physics, convert to `fix16.16` for speed.
- Cap delta: if `dt > 0.05` { `dt = 0.05` } prevents spiral of death on lag frames.
