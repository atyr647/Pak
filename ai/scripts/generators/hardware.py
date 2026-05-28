"""Generate exhaustive N64 hardware knowledge pairs."""


def gen_hardware() -> list[dict]:
    pairs = []

    def add(instruction, output):
        pairs.append({"instruction": instruction, "output": output,
                       "source": "generated", "category": "hardware"})

    # === CPU ===
    add("What CPU does the N64 use?",
        "The N64 uses a MIPS R4300i running at 93.75 MHz. It has:\n"
        "- 32-bit and 64-bit integer instructions\n"
        "- Hardware FPU (but slow — prefer fixed-point for game math)\n"
        "- 16 KB instruction cache, 8 KB data cache\n"
        "- 16-byte cache lines\n"
        "- Big-endian byte order")

    add("How much RAM does the N64 have?",
        "4 MB of RDRAM by default. With the Expansion Pak, 8 MB total.\n"
        "Budget: ~2 MB for game data, ~2 MB for framebuffers + audio + stack.\n"
        "A single 320x240 16-bit framebuffer = 150 KB. Triple buffer = 450 KB.")

    add("What is the N64's endianness?",
        "Big-endian. This matters when serializing data to EEPROM, "
        "interpreting DMA'd data, and doing bitwise operations on multi-byte values. "
        "Store bytes most-significant first.")

    add("How big is the N64's cache?",
        "16 KB instruction cache, 8 KB data cache, 16-byte cache lines. "
        "The data cache is NOT coherent with DMA — you must manually manage it "
        "with `cache.writeback` and `cache.invalidate` around DMA transfers.")

    # === Display ===
    add("What resolutions does the N64 support?",
        "| Resolution | Size | Notes |\n"
        "|---|---|---|\n"
        "| 320x240 | Most common, good performance |\n"
        "| 256x240 | Wider aspect, less fill |\n"
        "| 512x240 | Interlaced, high-res horizontal |\n"
        "| 640x480 | Interlaced high-res, very slow fill |\n"
        "| 512x480 | Interlaced |\n"
        "| 256x480 | Interlaced |\n\n"
        "320x240 is recommended for most games. 640x480 takes 4x the fill bandwidth.\n\n"
        "In Pak: `display.init(0, 2, 3, 0, 1)` for 320x240, 16bpp, triple-buffer.")

    add("What color depths does the N64 support?",
        "Two framebuffer depths:\n"
        "- **16-bit (DEPTH_16_BPP, value 2)**: RGBA 5551 format. Faster fill, uses less RAM. "
        "Most games use this.\n"
        "- **32-bit (DEPTH_32_BPP, value 4)**: RGBA 8888. True color but 2x RAM and fill cost.\n\n"
        "In Pak: the second arg to `display.init()` sets this. Use `2` for 16-bit, `4` for 32-bit.")

    add("What is double buffering vs triple buffering on N64?",
        "- **Double buffering (2)**: Two framebuffers. Simpler, less RAM (~300 KB for 320x240 16bpp). "
        "Can tear if frame takes too long.\n"
        "- **Triple buffering (3)**: Three framebuffers (~450 KB). Smoother — the display always "
        "has a complete frame to show while you render the next one.\n\n"
        "In Pak: the third arg to `display.init()` sets buffer count. Use `3` for smoothest results.")

    add("What display filters does the N64 support?",
        "- `FILTERS_DISABLED (0)`: No filtering. Pixelated output.\n"
        "- `FILTERS_RESAMPLE (1)`: Bilinear interpolation. Smooths pixels.\n"
        "- `FILTERS_RESAMPLE_ANTIALIAS (3)`: Bilinear + anti-aliasing. Smoothest but blurriest.\n\n"
        "In Pak, the 5th arg to `display.init()`: `display.init(0, 2, 3, 0, 1)` uses bilinear resample.")

    add("What gamma correction options does the N64 have?",
        "- `GAMMA_NONE (0)`: No gamma correction (most common)\n"
        "- `GAMMA_CORRECT (1)`: Apply gamma correction\n"
        "- `GAMMA_CORRECT_DITHER (3)`: Gamma + dithering\n\n"
        "Most games use `0` (no gamma). In Pak, it's the 4th arg to `display.init()`.")

    add("How large is a framebuffer on N64?",
        "Framebuffer size = width x height x bytes_per_pixel.\n"
        "- 320x240 @ 16bpp = 320 * 240 * 2 = 153,600 bytes (150 KB)\n"
        "- 320x240 @ 32bpp = 320 * 240 * 4 = 307,200 bytes (300 KB)\n"
        "- 640x480 @ 16bpp = 640 * 480 * 2 = 614,400 bytes (600 KB)\n\n"
        "Triple buffering at 320x240 16bpp uses ~450 KB of the 4 MB RAM.")

    # === RDP ===
    add("What is the RDP?",
        "The Reality Display Processor (RDP) is the N64's hardware rasterizer. It handles:\n"
        "- Triangle/rectangle rasterization\n"
        "- Texture mapping from TMEM\n"
        "- Color combining and blending\n"
        "- Z-buffer operations\n\n"
        "In Pak, access it through `use n64.rdpq` (RDP Queue — libdragon's RDP API).")

    add("What RDP rendering modes exist?",
        "Three primary modes in libdragon/Pak:\n\n"
        "| Mode | Function | Speed | Use |\n"
        "|---|---|---|---|\n"
        "| Fill | `rdpq.set_mode_fill(color)` | Fastest | Solid rectangles, screen clear |\n"
        "| Copy | `rdpq.set_mode_copy()` | Fast | Sprite blitting (no alpha/scale) |\n"
        "| Standard | `rdpq.set_mode_standard()` | Slow | Textured quads, alpha blend |\n\n"
        "Always call `rdpq.sync_pipe()` when switching between modes in the same frame.")

    add("What is TMEM and why does it matter?",
        "TMEM (Texture Memory) is 4 KB of on-chip memory in the RDP. ALL textures must fit "
        "in TMEM before they can be rendered.\n\n"
        "Texture size in TMEM:\n"
        "- RGBA16: width * height * 2 bytes\n"
        "- RGBA32: width * height * 4 bytes\n"
        "- CI4 (4-bit indexed): width * height / 2 bytes + palette\n"
        "- CI8 (8-bit indexed): width * height bytes + palette\n\n"
        "A 64x64 RGBA16 texture = 8,192 bytes — too big for 4 KB TMEM! Use CI4/CI8 "
        "or split into smaller tiles.\n\n"
        "Keep textures power-of-2 dimensions for efficiency.")

    add("What texture formats does the N64 support?",
        "| Format | Bits/pixel | TMEM usage | Notes |\n"
        "|---|---|---|---|\n"
        "| RGBA16 | 16 | w*h*2 | 5551 RGBA, most common |\n"
        "| RGBA32 | 32 | w*h*4 | True color, expensive |\n"
        "| CI4 | 4 | w*h/2 + palette | 16-color indexed, smallest |\n"
        "| CI8 | 8 | w*h + palette | 256-color indexed |\n"
        "| IA16 | 16 | w*h*2 | Intensity + Alpha |\n"
        "| IA8 | 8 | w*h | Intensity + Alpha (4+4) |\n"
        "| IA4 | 4 | w*h/2 | Intensity + Alpha (3+1) |\n"
        "| I8 | 8 | w*h | Grayscale |\n"
        "| I4 | 4 | w*h/2 | Grayscale, smallest |\n\n"
        "TMEM is only 4 KB. Use CI4 for large textures, RGBA16 for small ones.")

    add("What are the N64's texture size limitations?",
        "- TMEM is 4 KB total\n"
        "- Max texture width: 1024 pixels (but TMEM limits practical size)\n"
        "- Textures should be power-of-2 dimensions (8, 16, 32, 64, etc.)\n"
        "- A 32x32 RGBA16 texture = 2 KB (fits in TMEM)\n"
        "- A 64x64 RGBA16 = 8 KB (does NOT fit — use CI4 or tile it)\n"
        "- A 32x64 CI4 = 1 KB + 32 bytes palette (fits easily)\n\n"
        "For large backgrounds, tile the image and render pieces.")

    # === RSP ===
    add("What is the RSP?",
        "The Reality Signal Processor (RSP) is a vector DSP that runs microcode. It handles:\n"
        "- 3D vertex transformation and lighting\n"
        "- Audio mixing and processing\n"
        "- Custom microcode for effects\n\n"
        "libdragon and t3d manage the RSP automatically. You don't program it directly in Pak.")

    # === DMA ===
    add("Why does N64 DMA require cache management?",
        "The MIPS R4300i data cache is NOT coherent with DMA. The DMA engine writes directly "
        "to RAM, bypassing the CPU cache. Without cache management:\n\n"
        "1. **Dirty cache lines** may be evicted AFTER DMA, overwriting DMA'd data\n"
        "2. **Stale cache lines** may be read by CPU instead of fresh DMA'd data\n\n"
        "The required sequence:\n"
        "```pak\ncache.writeback(&buf[0], size)    -- flush dirty lines to RAM\n"
        "dma.read(&buf[0], rom_addr, size) -- DMA: ROM → RAM\n"
        "dma.wait()                        -- wait for completion\n"
        "cache.invalidate(&buf[0], size)   -- invalidate stale lines\n```")

    add("Why must DMA buffers be 16-byte aligned?",
        "The N64's PI (Parallel Interface) DMA requires at least 8-byte alignment. "
        "libdragon uses 16-byte alignment for safety (matches cache line boundaries). "
        "Misaligned DMA transfers can corrupt adjacent memory.\n\n"
        "In Pak, use `@aligned(16)` on the buffer:\n"
        "```pak\n@aligned(16)\nstatic buf: [4096]u8 = undefined\n```")

    add("What is the N64 ROM address space?",
        "Cartridge ROM is mapped at `0x10000000` in the physical address space.\n\n"
        "| Address | Content |\n"
        "|---|---|\n"
        "| `0x10000000` | ROM header (64 bytes: boot code, title, CRC) |\n"
        "| `0x10000040` | Game code and data |\n"
        "| Up to `0x1FBFFFFF` | ~256 MB max ROM space |\n\n"
        "In Pak, DMA from ROM uses these addresses:\n"
        "```pak\nconst ROM_DATA: u32 = 0x10040000  -- after header\n"
        "dma.read(&buf[0], ROM_DATA, size)\n```")

    # === Audio ===
    add("How does the N64 audio system work?",
        "The Audio Interface (AI) plays 16-bit stereo PCM from RAM buffers.\n\n"
        "- Supported sample rates: 22050, 32000, 44100 Hz\n"
        "- Format: interleaved stereo i16 samples [L, R, L, R, ...]\n"
        "- You fill buffers in the game loop, not via interrupts\n"
        "- `audio.get_buffer()` returns `none` if no buffer is ready — always check\n\n"
        "In Pak:\n```pak\naudio.init(44100, 4)  -- 44100 Hz, 4 buffers\n\nlet buf = audio.get_buffer()\n"
        "if buf == none { return }\n-- fill buf with interleaved stereo samples\n```")

    add("How do I calculate the audio buffer size on N64?",
        "Buffer size (in stereo samples) = sample_rate / frame_rate.\n\n"
        "At 44100 Hz, 60 fps: 44100 / 60 = 735 stereo pairs.\n"
        "Each pair = 2 i16 values (left + right) = 4 bytes.\n"
        "Total buffer = 735 * 4 = 2,940 bytes per frame.\n\n"
        "Fill exactly 1470 i16 values (735 left + 735 right, interleaved).")

    add("What audio sample rates does the N64 support?",
        "Three common rates:\n"
        "- **22050 Hz**: Lower quality, less CPU usage\n"
        "- **32000 Hz**: Balanced quality/performance\n"
        "- **44100 Hz**: CD quality, highest CPU usage\n\n"
        "Most N64 games used 22050 or 32000. Use 44100 only if you have CPU budget.")

    add("How many audio buffers should I use on N64?",
        "2-8 buffers. Trade-off:\n"
        "- **2 buffers**: Lowest latency, highest risk of audio crackling\n"
        "- **4 buffers**: Good balance (recommended)\n"
        "- **8 buffers**: Safest, but adds ~100ms latency\n\n"
        "In Pak: `audio.init(44100, 4)`")

    # === Controller ===
    add("What controller inputs does the N64 have?",
        "The N64 controller has:\n"
        "- **Analog stick**: X/Y axes, -128 to +127, ~10 dead zone\n"
        "- **D-pad**: Up, Down, Left, Right\n"
        "- **Face buttons**: A, B, Start\n"
        "- **Trigger**: Z\n"
        "- **Shoulder**: L, R\n"
        "- **C buttons**: C-Up, C-Down, C-Left, C-Right\n\n"
        "In Pak, access via `controller.read(port)` fields:\n"
        "- `pad.held.a`, `pad.pressed.a`, `pad.released.a`\n"
        "- `pad.stick_x`, `pad.stick_y` (i8)")

    add("What is the analog stick dead zone on N64?",
        "The analog stick has slight drift at rest. Apply a dead zone of ~10:\n\n"
        "```pak\nconst DEAD_ZONE: i32 = 10\n\nlet raw_x: i32 = pad.stick_x as i32\n"
        "let dx: i32 = if raw_x > DEAD_ZONE or raw_x < -DEAD_ZONE { raw_x } else { 0 }\n```")

    add("What is the difference between held, pressed, and released in Pak?",
        "- `pad.held.a`: true every frame while A is held down\n"
        "- `pad.pressed.a`: true only on the first frame A is pressed\n"
        "- `pad.released.a`: true only on the frame A is released\n\n"
        "Use `pressed` for one-shot actions (jump, select). Use `held` for continuous "
        "actions (move, accelerate).")

    add("How many controllers does the N64 support?",
        "4 controllers, ports 0-3. Player 1 = port 0.\n\n"
        "```pak\ncontroller.poll()\n"
        "let p1 = controller.read(0)  -- player 1\n"
        "let p2 = controller.read(1)  -- player 2\n"
        "let p3 = controller.read(2)  -- player 3\n"
        "let p4 = controller.read(3)  -- player 4\n```")

    # === EEPROM ===
    add("What EEPROM types does the N64 support?",
        "Two EEPROM sizes:\n"
        "- **4K EEPROM**: 64 blocks x 8 bytes = 512 bytes total\n"
        "- **16K EEPROM**: 256 blocks x 8 bytes = 2,048 bytes total\n\n"
        "Detect with `eeprom.type_detect()`: returns 0 (none), 1 (4K), 2 (16K).\n"
        "Most cartridges have NO EEPROM — always check `eeprom.present()` first.\n"
        "Writes are slow (~15 ms per block).")

    add("How much save data can I store on N64 EEPROM?",
        "- 4K EEPROM: 512 bytes (64 blocks of 8 bytes)\n"
        "- 16K EEPROM: 2,048 bytes (256 blocks of 8 bytes)\n\n"
        "Each block is exactly 8 bytes. Design your save format around 8-byte chunks. "
        "Use a magic number to detect valid saves vs uninitialized EEPROM.")

    # === Peripherals ===
    add("What N64 peripherals does Pak support?",
        "| Peripheral | Module | Purpose |\n"
        "|---|---|---|\n"
        "| Rumble Pak | `n64.rumble` | Vibration feedback |\n"
        "| Controller Pak | `n64.cpak` | Memory card save |\n"
        "| Transfer Pak | `n64.tpak` | Game Boy cartridge read/write |\n"
        "| Expansion Pak | (auto-detected) | Extra 4 MB RAM |\n\n"
        "Note: Rumble Pak and Controller Pak share the same slot — you can't use both simultaneously.")

    add("How does the Rumble Pak work in Pak?",
        "```pak\nuse n64.rumble\n\nrumble.init()     -- call after controller.init()\n"
        "rumble.start(0)   -- start rumble on port 0\nrumble.stop(0)    -- stop rumble\n```\n\n"
        "Port 0-3 matches the controller port. The Rumble Pak occupies the "
        "controller accessory slot, so it can't be used with Controller Pak simultaneously.")

    add("How does the Controller Pak (memory card) work in Pak?",
        "```pak\nuse n64.cpak\n\ncpak.init()\n"
        "if cpak.is_plugged(0) {\n    if not cpak.is_formatted(0) {\n"
        "        cpak.format(0)\n    }\n    cpak.read_sector(0, sector, &buf[0])\n"
        "    cpak.write_sector(0, sector, &buf[0])\n"
        "    let free = cpak.get_free_space(0)\n}\n```\n\n"
        "The Controller Pak provides more storage than EEPROM but requires the "
        "player to have a Controller Pak inserted.")

    add("How does the Transfer Pak work in Pak?",
        "The Transfer Pak allows reading/writing Game Boy cartridge memory:\n\n"
        "```pak\nuse n64.tpak\n\ntpak.init(0)  -- port 0\n"
        "let val: u8 = tpak.get_value(0, 0x0100)  -- read GB address\n"
        "tpak.set_value(0, 0x0100, 0xFF)           -- write GB address\n```\n\n"
        "Used by games like Pokemon Stadium to transfer Pokemon from GB cartridges.")

    # === Memory map ===
    add("What is the N64 memory map?",
        "| Region | Address | Size | Notes |\n"
        "|---|---|---|---|\n"
        "| RDRAM | 0x00000000 - 0x003FFFFF | 4 MB | Main RAM |\n"
        "| RDRAM exp | 0x00400000 - 0x007FFFFF | 4 MB | Expansion Pak |\n"
        "| ROM (PI) | 0x10000000 - 0x1FBFFFFF | ~256 MB | Cartridge |\n"
        "| RDP regs | 0xA4100000 | — | Reality Display Processor |\n"
        "| AI regs | 0xA4500000 | — | Audio Interface |\n"
        "| PI regs | 0xA4600000 | — | Parallel Interface (DMA) |")

    # === Performance ===
    add("What are the key N64 performance rules?",
        "| Rule | Why |\n"
        "|---|---|\n"
        "| Use `fix16.16` for game math | MIPS FPU is slow |\n"
        "| Use `static` buffers, not `alloc` | Avoid heap fragmentation |\n"
        "| Use `rdpq.set_mode_copy()` for 2D | 4x faster than standard |\n"
        "| Keep sprites power-of-2 size | RDP TMEM efficiency |\n"
        "| Budget 2 MB for game data | Leave 2 MB for system |\n"
        "| Keep draw calls < 200/frame | RDP command FIFO limit |\n"
        "| Avoid 640x480 | 4x fill cost vs 320x240 |\n"
        "| TMEM is only 4 KB | Size textures accordingly |")

    add("How much RAM should I budget for game data on N64?",
        "With 4 MB total RAM:\n"
        "- Framebuffers: ~450 KB (triple 320x240 16bpp)\n"
        "- Audio buffers: ~12 KB\n"
        "- Stack: ~8 KB\n"
        "- libdragon/t3d internals: ~200 KB\n"
        "- **Available for game**: ~3.3 MB\n\n"
        "With Expansion Pak (8 MB total): ~7.3 MB for game data.\n"
        "Use static allocations to keep memory predictable.")

    # === Init order ===
    add("What is the correct subsystem initialization order in Pak?",
        "```pak\nentry {\n    display.init(0, 2, 3, 0, 1)  -- 1. Display first\n"
        "    rdpq.init()                   -- 2. RDP (after display)\n"
        "    controller.init()             -- 3. Controller\n"
        "    timer.init()                  -- 4. Timer\n"
        "    audio.init(44100, 4)          -- 5. Audio (optional)\n"
        "    rumble.init()                 -- 6. Rumble (optional, after controller)\n"
        "    t3d.init()                    -- 7. T3D (optional, after rdpq)\n}\n```\n\n"
        "Display MUST come before rdpq. Controller MUST come before rumble.")

    # === Video output ===
    add("What video output does the N64 support?",
        "The N64 outputs composite video and S-Video:\n"
        "- NTSC: 525 lines, 60 Hz (Americas, Japan)\n"
        "- PAL: 625 lines, 50 Hz (Europe, Australia)\n\n"
        "Resolution is set in software via `display.init()`. The video output is always "
        "analog — there is no native HDMI or digital output on the original hardware.")

    # === Common bugs ===
    add("What are the most common N64 hardware-related bugs?",
        "| Bug | Cause | Fix |\n"
        "|---|---|---|\n"
        "| Garbage on screen | DMA without cache.invalidate | Add cache.invalidate after dma.wait |\n"
        "| Stale data after DMA | No cache.writeback | Add cache.writeback before dma.read |\n"
        "| Input always zero | Missing controller.poll() | Call poll() every frame before read() |\n"
        "| Audio crackling | Buffer underrun | Increase audio buffer count |\n"
        "| Corrupt save | No eeprom.present() check | Always check presence first |\n"
        "| Wrong colors | Depth mismatch | Match color packing to bit depth |\n"
        "| Crash on blit | No RDP mode set | Set mode_copy before sprite.blit |\n"
        "| Frame tearing | Show without detach | Use rdpq.detach_show() |")

    return pairs
