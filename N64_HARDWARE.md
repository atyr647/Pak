# N64 Hardware Reference for Pak

This file documents the N64 hardware facts, constants, and behavioral rules
that every Pak program must respect. The compiler enforces what it can (DMA
alignment, cache coherency, exhaustive match) — the rest is documented here.

**Read this before writing any N64 API calls.**

---

## Hardware Overview

| Component | Spec |
|-----------|------|
| CPU | MIPS R4300i, 93.75 MHz |
| RAM | 4 MB (8 MB with Expansion Pak) |
| RDP | Reality Display Processor (2D/3D rasterizer) |
| RSP | Reality Signal Processor (vector DSP, runs microcode) |
| ROM bus | Parallel Interface (PI), 64-pin cartridge |
| Audio | 16-bit stereo PCM, mixed by AI (Audio Interface) |
| Display | Composite/S-Video, 525-line NTSC or 625-line PAL |
| Cache | 16 KB I-cache, 8 KB D-cache, 16-byte cache lines |
| Endianness | **Big-endian** |

---

## Display System

### Initialization — `display.init`

```pak
display.init(resolution, bit_depth, num_buffers, gamma, filters)
```

**Pass the raw integer value for each argument.** The `RESOLUTION_*`,
`DEPTH_*`, `GAMMA_*`, and `FILTERS_*` names below are libdragon C macros,
listed here for reference — Pak does not predefine them as identifiers, so
writing them bare (e.g. `display.init(RESOLUTION_320x240, …)`) fails with
`E010 unknown name`. Use the integers, as every canonical example does.

| Arg | Type | Value (libdragon name) | Notes |
|-----|------|-------------|-------|
| `resolution` | `u32` | see resolution table below | Screen resolution |
| `bit_depth` | `u32` | `2` (`DEPTH_16_BPP`), `4` (`DEPTH_32_BPP`) | 16 bpp = faster fill; 32 bpp = true color |
| `num_buffers` | `i32` | `2` or `3` | 2 = double-buffer, 3 = triple-buffer (smoother) |
| `gamma` | `u32` | `0` (`GAMMA_NONE`), `1` (`GAMMA_CORRECT`), `3` (`GAMMA_CORRECT_DITHER`) | Usually `0` |
| `filters` | `u32` | `0` (`FILTERS_DISABLED`), `1` (`FILTERS_RESAMPLE`), `3` (`FILTERS_RESAMPLE_ANTIALIAS`) | `1` = bilinear scale |

**Resolution values:**

| Value | libdragon name | Width × Height | Use Case |
|-------|----------------|---------------|----------|
| `0` | `RESOLUTION_320x240` | 320 × 240 | Most common; good performance |
| `1` | `RESOLUTION_640x480` | 640 × 480 | Interlaced high-res; very slow to fill |
| `2` | `RESOLUTION_256x240` | 256 × 240 | Wider aspect, less fill |
| `3` | `RESOLUTION_512x240` | 512 × 240 | Interlaced, high-res horizontal |

`512x480` and `256x480` exist in libdragon as further interlaced modes; pass
the corresponding integer from your libdragon headers if you need them.

**On the standalone backend (`--backend mips`) only `0` (320x240) and a
`bit_depth` of `2` work.** The toolchain-free HAL carves three fixed
320x240x16 framebuffers out of RDRAM at fixed addresses, with the Z buffer and
the display list immediately after them, so another resolution or depth would
move every one of those. `display.init` panics (red screen, halt) rather than
letting a scene render into a wrong-sized buffer. `num_buffers` (1-3), `gamma`
and `filters` are all honoured. The libdragon backend (`--backend c`) supports
the full table.

**Typical game setup:**
```pak
-- display.init(resolution, bit_depth, num_buffers, gamma, filters)
-- 0=320x240, 2=16bpp, 3=triple-buffer, 0=no gamma, 1=bilinear resample
display.init(0, 2, 3, 0, 1)
```

### Double-Buffer Render Loop

The correct rendering sequence every frame:

```pak
-- 1. Get next free framebuffer (blocks until one is available)
let fb = display.get()

-- 2. Attach RDP to it (clears to black)
rdpq.attach_clear(fb)

-- 3. ... draw everything ...

-- 4. Detach and flip (shows to screen)
rdpq.detach_show()
```

**Rules:**
- `display.get()` MUST be called before `rdpq.attach_clear()`.
- `rdpq.detach_show()` replaces the two-call sequence `rdpq.detach()` + `display.show(fb)` — prefer it.
- Never write to a surface after calling `rdpq.detach_show()` or `display.show()`.

---

## Controller Input

### Initialization and Polling

```pak
controller.init()    -- call ONCE at startup

-- In game loop (every frame, in this order):
controller.poll()                -- updates internal state
let pad = controller.read(0)     -- read port 0 (player 1), ports 0–3
```

**CRITICAL: `controller.poll()` must be called before `controller.read()` every frame.**
Reading without polling returns stale data from the previous frame.

### Button Fields

```pak
-- All fields exist on: pad.held, pad.pressed, pad.released
pad.held.a       -- A button
pad.held.b       -- B button
pad.held.start   -- Start
pad.held.z       -- Z trigger
pad.held.l       -- L trigger
pad.held.r       -- R trigger
pad.held.up      pad.held.down   pad.held.left   pad.held.right   -- D-pad
pad.held.c_up    pad.held.c_down pad.held.c_left pad.held.c_right -- C buttons

-- Analog stick (-128 to +127, dead zone ~10)
pad.stick_x    -- i8: negative = left
pad.stick_y    -- i8: negative = down
```

### Dead Zone Pattern

The analog stick always has slight drift even at rest. Apply a dead zone:

```pak
const DEAD_ZONE: i32 = 10

let raw_x: i32 = pad.stick_x as i32
let raw_y: i32 = pad.stick_y as i32

let dx: i32 = if raw_x > DEAD_ZONE or raw_x < -DEAD_ZONE { raw_x } else { 0 }
let dy: i32 = if raw_y > DEAD_ZONE or raw_y < -DEAD_ZONE { raw_y } else { 0 }
```

---

## RDP (2D Rendering)

### Rendering Modes

The RDP has distinct modes. Set one per draw call batch:

| Mode | Function | Use Case |
|------|----------|----------|
| Fill | `rdpq.set_mode_fill(color)` | Solid color rectangles, clearing |
| Copy | `rdpq.set_mode_copy()` | Fast sprite blitting (no scaling/alpha) |
| Standard | `rdpq.set_mode_standard()` | Textured quads, alpha blending |

**Rules:**
- Set the mode once, then issue multiple draw calls.
- Switching modes mid-frame requires `rdpq.sync_pipe()` between them.
- Copy mode is fastest — use for all 2D sprites when possible.

### Color Format

`rdpq.set_mode_fill(color)` takes a 32-bit packed RGBA color.
Build it from components: `(r << 24) | (g << 16) | (b << 8) | a`

Common colors:
```pak
const COLOR_BLACK:  u32 = 0x000000FF
const COLOR_WHITE:  u32 = 0xFFFFFFFF
const COLOR_RED:    u32 = 0xFF0000FF
const COLOR_GREEN:  u32 = 0x00FF00FF
const COLOR_BLUE:   u32 = 0x0000FFFF
const COLOR_CLEAR:  u32 = 0x00000000
```

### Mode-Switching Sync Pattern

```pak
-- Start with fill (clear background)
rdpq.set_mode_fill(COLOR_BLACK)
rdpq.fill_rectangle(0, 0, 320, 240)

-- Switch to copy for sprites
rdpq.sync_pipe()           -- required between mode switches
rdpq.set_mode_copy()
sprite.blit(my_sprite, 100, 80, 0)
```

---

## DMA (Direct Memory Access)

The N64's PI (Parallel Interface) DMA moves data from ROM to RAM. The MIPS
D-cache is not coherent with DMA — you must manage it manually.

### Required Sequence

```pak
use n64.dma
use n64.cache

@aligned(16)                           -- required: 16-byte alignment (E202 if missing)
static buf: [SIZE]u8 = undefined

fn load_data() {
    cache.writeback(&buf[0], SIZE)     -- flush D-cache → RAM  (E201 if missing)
    dma.read(&buf[0], ROM_ADDR, SIZE)  -- ROM → RAM via PI DMA
    dma.wait()                         -- wait for PI DMA to finish
    cache.invalidate(&buf[0], SIZE)    -- invalidate D-cache so CPU reads fresh RAM
    -- buf is now safe to read
}
```

### Why Each Step Is Required

1. **`@aligned(16)`**: PI DMA requires 8-byte alignment minimum; libdragon uses 16.
2. **`cache.writeback`**: Before DMA writes to RAM, evict dirty cache lines — otherwise the CPU's stale cached values will overwrite the DMA'd data when the cache is evicted later.
3. **`dma.read`**: Transfers `SIZE` bytes from cartridge ROM address `ROM_ADDR` to RAM pointer `buf`.
4. **`dma.wait`**: PI DMA is asynchronous; this blocks until transfer completes.
5. **`cache.invalidate`**: Marks the cache lines as invalid so the next CPU read fetches from RAM (where DMA wrote), not the stale cache.

### ROM Address Space

N64 cartridge ROM starts at `0x10000000` in the physical address space.
libdragon uses the PI bus window. Typical ROM data at:

```pak
const ROM_START: i32 = 0x10040000   -- after N64 ROM header (256 bytes at 0x10000000)
```

---

## Audio System

### Initialization

```pak
use n64.audio

-- Must be called once before any audio output
audio.init(44100, 4)    -- frequency: Hz, buffers: count (2–8)
```

| Arg | Valid Values | Notes |
|-----|-------------|-------|
| `frequency` | `22050`, `32000`, `44100` | 44100 Hz = CD quality; lower = less CPU |
| `buffers` | `2`–`8` | More buffers = lower risk of underrun, higher latency |

### Audio Buffer Fill Pattern

```pak
use n64.audio

fn audio_callback() {
    let buf: *i16 = audio.get_buffer()
    if buf == none { return }

    -- Fill buf with interleaved stereo samples: [L, R, L, R, ...]
    -- Buffer size = frequency / frame_rate * 2 channels * 2 bytes/sample
    -- At 44100 Hz, 60 fps: ~1470 samples × 2 channels = 2940 i16 values

    let i: i32 = 0
    -- ... fill samples ...
}
```

**Rules:**
- `audio.get_buffer()` returns `none` if no buffer is ready — always check.
- Buffer is interleaved stereo: even indices = left channel, odd = right.
- Call audio fill in your game loop, not on an interrupt.

---

## EEPROM (Save Data)

### Detection and Read/Write

```pak
use n64.eeprom

-- Check before any EEPROM operation
if not eeprom.present() {
    -- no save hardware
    return
}

-- Detect type (determines block count)
let etype = eeprom.type_detect()
-- 0 = none, 1 = EEPROM 4K (64 blocks × 8 bytes = 512 bytes)
--           2 = EEPROM 16K (256 blocks × 8 bytes = 2048 bytes)

-- Read block 0 (8 bytes) into dst
@aligned(8)
static save_buf: [8]u8 = undefined

eeprom.read(0, &save_buf[0])   -- block index, destination

-- Write block 0 from src
eeprom.write(0, &save_buf[0])  -- block index, source
```

**Rules:**
- Each EEPROM block is exactly **8 bytes**.
- EEPROM 4K has 64 blocks (512 bytes total save data).
- EEPROM 16K has 256 blocks (2048 bytes total save data).
- Writes are slow (~15 ms per block) — minimize write calls.
- Always check `eeprom.present()` — most carts don't have EEPROM.

### Simple Save Pattern

```pak
struct SaveData {
    magic: u32      -- identify valid save (e.g. 0xDEAD1234)
    score: i32
    level: u8
    pad: [3]u8      -- align to 8 bytes
}

const SAVE_MAGIC: u32 = 0xDEAD1234

@aligned(8)
static raw_save: [8]u8 = undefined

fn save_game(data: *SaveData) {
    if not eeprom.present() { return }
    -- Copy struct into raw buffer (manual serialization)
    raw_save[0] = (data.magic >> 24) as u8
    raw_save[1] = (data.magic >> 16) as u8
    raw_save[2] = (data.magic >> 8)  as u8
    raw_save[3] =  data.magic        as u8
    -- ... fill remaining fields ...
    eeprom.write(0, &raw_save[0])
}

fn load_game(data: *SaveData) -> bool {
    if not eeprom.present() { return false }
    eeprom.read(0, &raw_save[0])
    let magic: u32 = (raw_save[0] as u32 << 24)
                   | (raw_save[1] as u32 << 16)
                   | (raw_save[2] as u32 << 8)
                   |  raw_save[3] as u32
    if magic != SAVE_MAGIC { return false }
    -- ... parse remaining fields ...
    return true
}
```

---

## Interrupts (standalone backend)

The RCP has six interrupt sources — SP, SI, AI, VI, PI, DP — and they all
arrive on one CPU line, IP2. Getting one delivered means three things being
true at once, and a missing any of them looks identical from the outside:

1. **CP0 Status** has `IE` (bit 0) and `IM2` (bit 10) set.
2. **MI_MASK** (`0xA430000C`) has that source armed. It is write-only and takes
   a *pair* of bits per source, clear and set, so arming one never disturbs the
   others: VI is `0x0080` to arm, `0x0040` to disarm.
3. The **device** is configured to raise it. For the VI that means `VI_V_INTR`
   (`0xA440000C`) naming a halfline inside the frame; parking it at `0x200` is
   how you turn VI interrupts off without touching the mask.

```pak
display.init(0, 2, 3, 0, 1)
interrupt.init()          -- arms the VI and enables IP2
```

After `interrupt.init()`, `display.show()` waits on the counter the handler
bumps rather than spinning on `VI_V_CURRENT`, so the CPU is free between
frames. `interrupt.vi_count()` is that counter and `interrupt.pending()` is
every source the handler has seen since it started.

**Every source must be acknowledged, at the device.** The RCP holds its line
high until the device is told to drop it, so a source the handler leaves alone
re-enters the handler forever:

| Source | Acknowledge by writing |
|--------|------------------------|
| VI | anything to `VI_V_CURRENT` (`0xA4400010`) |
| PI | `0x02` to `PI_STATUS` (`0xA4600010`) |
| SI | anything to `SI_STATUS` (`0xA4800018`) |
| AI | anything to `AI_STATUS` (`0xA450000C`) |
| SP | `0x08` to `SP_STATUS` (`0xA4040010`) |
| DP | `0x0800` to `MI_MODE` (`0xA4300000`) |

`MI_INTERRUPT` reports every source that is asserting, **masked or not**, so a
handler that acts on the raw word will acknowledge — and so discard — a flag
nobody asked it to touch. Filter by what you armed.

For a critical section, `interrupt.disable()` returns the previous Status and
`interrupt.restore(s)` puts it back. Do not assume interrupts were on.

Two things the handler itself must respect, because `Status.EXL` is set for the
whole of it and nothing else can be serviced until it returns: it must not wait
on hardware, and it must not be long.

---

## Cache maintenance

The CPU's data cache does not see DMA, and DMA does not see the data cache. So
every transfer needs one of these on the CPU side, and getting the opcode wrong
is silent — the program keeps working on an emulator with no cache model and
returns stale data on hardware.

The `cache` instruction's operand is `(op << 2) | cache_select`, where
`cache_select` is **0 for the instruction cache and 1 for the data cache**:

| Operand | Meaning | Use |
|---------|---------|-----|
| `0x19` | Hit_Writeback_D | before a DMA **out** of a buffer you wrote |
| `0x11` | Hit_Invalidate_D | after a DMA **into** a buffer you will read |
| `0x15` | Hit_Writeback_Invalidate_D | both, when the buffer goes each way |
| `0x10` | Hit_Invalidate_I | after writing instructions the CPU will execute |

`0x14` is a plausible-looking typo for `0x11` and means Hit_Writeback_Invalidate
on the **instruction** cache: it invalidates nothing in the D-cache at all.

`cache.writeback` / `cache.invalidate` / `cache.writeback_inv` do the right
thing; this table is here for anyone writing the inline assembly by hand.

---

## Memory Map (Summary)

| Region | Address Range | Size | Notes |
|--------|--------------|------|-------|
| RDRAM (RAM) | `0x00000000`–`0x003FFFFF` | 4 MB | Main RAM |
| RDRAM exp | `0x00400000`–`0x007FFFFF` | 4 MB | Expansion Pak only |
| ROM (PI) | `0x10000000`–`0x1FBFFFFF` | ~256 MB | Cartridge ROM |
| ROM header | `0x10000000` | 64 bytes | Boot code, title, CRC |
| ROM data | `0x10000040` | rest | Your assets and data |
| RDP regs | `0xA4100000` | — | Reality Display Processor |
| MI regs | `0xA4300000` | — | MIPS Interface (interrupt mask/status) |
| VI regs | `0xA4400000` | — | Video Interface |
| AI regs | `0xA4500000` | — | Audio Interface |
| PI regs | `0xA4600000` | — | Parallel Interface (DMA) |
| SI regs | `0xA4800000` | — | Serial Interface (Joybus); STATUS is `+0x18` |
| RSP DMEM | `0xA4000000` | 4 KB | CPU-addressable directly, or by SP DMA |
| RSP IMEM | `0xA4001000` | 4 KB | Microcode |
| SP regs | `0xA4040000` | — | SP DMA and status; SP_PC is at `0xA4080000` |

---

## Performance Guidelines

| Rule | Why |
|------|-----|
| Use `fix16.16` for game logic math | MIPS FPU is slow; integer ops are fast |
| Use `static` buffers, not `alloc` | Avoid heap fragmentation in 4 MB RAM |
| Call `rdpq.set_mode_copy()` for 2D sprites | 4× faster than standard mode |
| Keep sprites to power-of-2 dimensions | RDP texture cache efficiency |
| Budget 2 MB RAM for game data | Leave 2 MB for framebuffers + audio + stack |
| Framebuffer size: 320×240×2 bytes = 150 KB | Two framebuffers = 300 KB |
| Keep draw call count < 200 per frame | RDP has limited command FIFO |
| Avoid 640×480 unless required | Takes 4× fill bandwidth vs 320×240 |

---

## Required Initialization Order

For a typical game, initialize in this order:

```pak
entry {
    -- 1. Debug output first (catches crashes during init)
    -- (debug.log is always available, no init needed)

    -- 2. Display (must come before rdpq)
    -- 0=320x240, 2=16bpp, 3=triple-buffer, 0=GAMMA_NONE, 1=FILTERS_RESAMPLE
    display.init(0, 2, 3, 0, 1)

    -- 3. RDP (must come after display)
    rdpq.init()

    -- 4. Controller
    controller.init()

    -- 5. Timer
    timer.init()

    -- 6. Audio (optional)
    audio.init(44100, 4)

    -- 7. Rumble (optional, after controller)
    rumble.init()

    -- 8. Game-specific init (load assets, build state, etc.)

    loop {
        -- main game loop body
    }
}
```

**Do not call RDP functions before `rdpq.init()`.** Do not call `rdpq.attach_clear` before `display.init`.

---

## Common Bugs Caused by Hardware

| Bug | Cause | Fix |
|-----|-------|-----|
| Screen shows garbage/noise | DMA without cache invalidate | Add `cache.invalidate` after `dma.wait` |
| Stale data after DMA | Cache not written back | Add `cache.writeback` before `dma.read` |
| Input always reads zero | Forgot `controller.poll()` | Call `controller.poll()` every frame before `controller.read()` |
| Audio crackling | Buffer underrun | Increase `buffers` arg to `audio.init`; fill buffer reliably each frame |
| Corrupt save data | EEPROM read before `present()` check | Always check `eeprom.present()` first |
| Display shows wrong colors | Wrong bit depth for color format | Ensure color packing matches `DEPTH_16_BPP` vs `DEPTH_32_BPP` |
| Crash during sprite blit | Mode not set before blit | Call `rdpq.set_mode_copy()` or `rdpq.set_mode_standard()` first |
| Frame tearing | `display.show` without `rdpq.detach` | Use `rdpq.detach_show()` which does both atomically |
