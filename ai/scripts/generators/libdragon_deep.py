"""Deep libdragon knowledge: rdpq advanced, sprites, fonts, text, filesystem, save formats."""


def gen_libdragon_deep() -> list[dict]:
    pairs = []

    def add(instruction, output):
        pairs.append({"instruction": instruction, "output": output,
                       "source": "generated", "category": "libdragon_deep"})

    # === RDPQ Advanced ===
    add("How do I use rdpq mode push/pop to save and restore render state in Pak?",
        "Use extern to declare rdpq_mode_push and rdpq_mode_pop, then bracket "
        "temporary mode changes:\n\n"
        "```pak\nextern \"C\" {\n    fn rdpq_mode_push()\n    fn rdpq_mode_pop()\n}\n\n"
        "fn render_hud() {\n    rdpq_mode_push()\n"
        "    rdpq.set_mode_fill(0xFFFF00FF)\n"
        "    rdpq.fill_rectangle(10, 10, 100, 30)\n"
        "    rdpq_mode_pop()  -- restores previous mode\n}\n```\n\n"
        "The mode stack has 4 entries. Push before temporary changes, pop after.")

    add("How do I enable Z-buffering in Pak?",
        "Z-buffering requires a Z-buffer surface and mode configuration via extern:\n\n"
        "```pak\nextern \"C\" {\n    fn rdpq_mode_zbuf(compare: bool, update: bool)\n"
        "    fn rdpq_set_z_image(surface: *surface_t)\n}\n\n"
        "-- allocate z-buffer (same resolution as framebuffer)\n"
        "-- must be 16-bit, one entry per pixel\n"
        "-- 320x240 = 153,600 bytes\n\n"
        "fn setup_zbuffer(z_surface: *surface_t) {\n"
        "    rdpq_set_z_image(z_surface)\n"
        "    rdpq_mode_zbuf(true, true)  -- compare and update\n}\n```")

    add("How do I enable fog in Pak?",
        "Fog uses the RDP blender unit. Configure via extern:\n\n"
        "```pak\nextern \"C\" {\n    fn rdpq_mode_fog(fog_blend: u64)\n"
        "    fn rdpq_set_fog_color(r: u8, g: u8, b: u8, a: u8)\n}\n\n"
        "fn setup_fog() {\n"
        "    rdpq_set_fog_color(128, 128, 160, 255)  -- bluish fog\n"
        "    -- fog blending is configured through rdpq_mode_fog\n"
        "    -- t3d handles this automatically when using its fog API\n}\n```\n\n"
        "For 3D games using t3d, fog is typically set through t3d's own API rather "
        "than raw rdpq calls.")

    add("How do I enable anti-aliasing in Pak?",
        "```pak\nextern \"C\" {\n    fn rdpq_mode_antialias(mode: i32)\n}\n\n"
        "-- mode values:\n-- 0 = AA_NONE (disabled)\n-- 1 = AA_STANDARD (edge AA)\n"
        "-- 2 = AA_REDUCED (less quality, better performance)\n\n"
        "fn enable_aa() {\n    rdpq_mode_antialias(1)\n}\n```")

    add("How do I use texture filtering in Pak?",
        "```pak\nextern \"C\" {\n    fn rdpq_mode_filter(filter: i32)\n}\n\n"
        "-- filter values:\n-- 0 = FILTER_POINT (nearest neighbor, pixelated)\n"
        "-- 1 = FILTER_BILINEAR (smooth)\n-- 2 = FILTER_MEDIAN (3-sample median)\n\n"
        "fn set_bilinear() {\n    rdpq_mode_filter(1)\n}\n```\n\n"
        "Point filtering is default and fastest. Bilinear smooths but costs performance.")

    add("How do I use mipmapping in Pak?",
        "```pak\nextern \"C\" {\n    fn rdpq_mode_mipmap(mode: i32, num_levels: i32)\n}\n\n"
        "-- mode values:\n-- 0 = MIPMAP_NONE\n-- 1 = MIPMAP_NEAREST (snap to closest level)\n"
        "-- 2 = MIPMAP_INTERPOLATE (blend between levels)\n\n"
        "fn enable_mipmaps() {\n"
        "    rdpq_mode_mipmap(2, 3)  -- interpolate, 3 mip levels\n}\n```\n\n"
        "Sprites must be built with mipmaps using mksprite. Each mip level halves "
        "the resolution and all must fit in 4 KB TMEM together.")

    add("How does rdpq_mode_combiner work?",
        "The color combiner controls how texture, vertex color, primitive color, "
        "and environment color are blended. It uses a formula:\n"
        "(A - B) * C + D for each of RGB and Alpha.\n\n"
        "Common combiners (use via extern):\n"
        "- Flat color: prim_color only\n"
        "- Textured: texture * vertex_color\n"
        "- Textured + lit: texture * shade_color\n\n"
        "In practice, `rdpq.set_mode_standard()` sets a reasonable default combiner "
        "and `rdpq.set_mode_copy()` bypasses the combiner entirely for fastest blitting.")

    add("How do I use alpha blending in Pak?",
        "```pak\nextern \"C\" {\n    fn rdpq_mode_blender(blend: u64)\n"
        "    fn rdpq_mode_alphacompare(threshold: i32)\n}\n\n"
        "-- alpha compare: pixels with alpha below threshold are discarded\n"
        "-- threshold = 0: disabled\n-- threshold = 1-255: fixed threshold\n"
        "-- threshold = -1: noise-based (random dithered edges)\n\n"
        "fn setup_transparency() {\n"
        "    rdpq.set_mode_standard()  -- enables blending pipeline\n"
        "    rdpq_mode_alphacompare(128)  -- discard pixels with alpha < 128\n}\n```")

    # === Sprite Advanced ===
    add("How do I load sprites at runtime in Pak?",
        "```pak\nuse n64.sprite\n\n-- from filesystem (DragonFS):\n"
        "let spr: *sprite_t = sprite.load(\"sprites/enemy.sprite\")\n\n"
        "-- use it:\nrdpq.set_mode_copy()\nsprite.blit(spr, x, y, 0)\n```\n\n"
        "Note: the file must be a .sprite file built by mksprite, not a raw .png. "
        "The build system converts .png to .sprite format.")

    add("How does the N64 sprite build pipeline work?",
        "1. Create your art as .png files\n"
        "2. The libdragon build system runs `mksprite` to convert .png to .sprite\n"
        "3. .sprite files go into the DragonFS filesystem image\n"
        "4. At runtime, load with `sprite.load(\"path.sprite\")`\n\n"
        "mksprite options control:\n"
        "- Texture format (RGBA16, RGBA32, CI4, CI8, IA, I)\n"
        "- Mipmap generation\n"
        "- Horizontal/vertical tiling for sprite sheets\n\n"
        "In Pak, declare assets with:\n```pak\nasset my_sprite: Sprite from \"sprites/player.png\"\n```\n"
        "The build system handles conversion automatically.")

    add("How do sprite sheets work in Pak?",
        "Sprite sheets are built by mksprite with --tiles flag, which splits the image "
        "into a grid. Access individual tiles via extern:\n\n"
        "```pak\nextern \"C\" {\n    fn sprite_get_tile(spr: *sprite_t, h: i32, v: i32) -> surface_t\n}\n\n"
        "-- for a 4x4 sprite sheet, tile (2, 1) is column 2, row 1:\n"
        "let tile = sprite_get_tile(sheet, 2, 1)\n```\n\n"
        "Each tile must fit in TMEM (4 KB). Common setup: 16x16 tiles in RGBA16 = "
        "512 bytes each, allowing 8 tiles in TMEM simultaneously.")

    add("How do I check if a sprite fits in TMEM?",
        "```pak\nextern \"C\" {\n    fn sprite_fits_tmem(spr: *sprite_t) -> bool\n}\n\n"
        "let spr: *sprite_t = sprite.load(\"big_sprite.sprite\")\n"
        "if not sprite_fits_tmem(spr) {\n"
        "    -- sprite is too large for single TMEM upload\n"
        "    -- use rdpq_sprite_blit which auto-chunks large sprites\n"
        "    -- or split into smaller tiles\n}\n```")

    # === Font/Text ===
    add("How do I render text on N64 in Pak?",
        "libdragon has a full font/text system. Use via extern:\n\n"
        "```pak\nextern \"C\" {\n    fn rdpq_font_load(path: *c_char) -> *rdpq_font_t\n"
        "    fn rdpq_font_free(font: *rdpq_font_t)\n"
        "    fn rdpq_font_style(font: *rdpq_font_t, style_id: u8, style: *rdpq_fontstyle_t)\n"
        "    fn rdpq_text_register_font(font_id: u8, font: *rdpq_font_t)\n"
        "    fn rdpq_text_print(parms: *rdpq_textparms_t, font_id: u8, x: f32, y: f32, text: *c_char) -> rdpq_textmetrics_t\n"
        "}\n\n"
        "static my_font: *rdpq_font_t = none\n\n"
        "fn init_text() {\n"
        "    my_font = rdpq_font_load(\"fonts/main.font64\")\n"
        "    rdpq_text_register_font(1, my_font)\n}\n\n"
        "fn draw_text(x: f32, y: f32, msg: *c_char) {\n"
        "    rdpq_text_print(none, 1, x, y, msg)\n}\n```\n\n"
        "Fonts are built with mkfont from .ttf files. Register with an ID (1-255), "
        "then print using that ID.")

    add("How does the font build pipeline work on N64?",
        "1. Start with a .ttf or .otf font file\n"
        "2. libdragon's `mkfont` converts it to .font64 format\n"
        "3. mkfont rasterizes glyphs at specified size, compresses, and packs\n"
        "4. Place .font64 in the DragonFS filesystem\n"
        "5. Load at runtime with `rdpq_font_load(\"path.font64\")`\n"
        "6. Register with `rdpq_text_register_font(id, font)`\n"
        "7. Render with `rdpq_text_print(parms, id, x, y, text)`\n\n"
        "Font styles control color and can be switched mid-string.")

    # === DragonFS ===
    add("What is DragonFS and how does it work?",
        "DragonFS (DFS) is libdragon's read-only filesystem for N64 ROMs. "
        "Game assets (sprites, models, sounds, fonts, data) are packed into a DFS "
        "image at build time and appended to the ROM.\n\n"
        "At runtime, access files by path:\n"
        "```pak\nlet spr: *sprite_t = sprite.load(\"sprites/player.sprite\")\n"
        "let model: *T3DModel = t3d.model_load(\"models/level.t3dm\")\n```\n\n"
        "The filesystem is read-only — you cannot write to it at runtime. "
        "For persistent data, use EEPROM, Controller Pak, or FlashRAM.")

    add("How do I read raw binary files from the DragonFS in Pak?",
        "Use extern to access the DFS API:\n\n"
        "```pak\nextern \"C\" {\n    fn dfs_open(path: *c_char) -> i32\n"
        "    fn dfs_read(buf: *u8, size: i32, count: i32, handle: i32) -> i32\n"
        "    fn dfs_seek(handle: i32, offset: i32, origin: i32) -> i32\n"
        "    fn dfs_tell(handle: i32) -> i32\n"
        "    fn dfs_close(handle: i32) -> i32\n"
        "    fn dfs_size(handle: i32) -> i32\n}\n\n"
        "fn load_level_data(path: *c_char, dst: *u8, max_size: i32) -> i32 {\n"
        "    let handle: i32 = dfs_open(path)\n"
        "    if handle < 0 { return -1 }\n"
        "    let size: i32 = dfs_size(handle)\n"
        "    let to_read: i32 = if size < max_size { size } else { max_size }\n"
        "    dfs_read(dst, 1, to_read, handle)\n"
        "    dfs_close(handle)\n"
        "    return to_read\n}\n```")

    # === EEPROMFS (higher level) ===
    add("What is eepromfs and how is it different from raw EEPROM?",
        "eepromfs is libdragon's higher-level EEPROM filesystem. Instead of manually "
        "packing bytes into 8-byte blocks, you define named files with sizes and "
        "eepromfs handles block allocation and validation.\n\n"
        "Use via extern:\n"
        "```pak\nextern \"C\" {\n"
        "    fn eepfs_read(path: *c_char, dst: *u8, size: u32) -> i32\n"
        "    fn eepfs_write(path: *c_char, src: *u8, size: u32) -> i32\n"
        "    fn eepfs_verify_signature() -> bool\n"
        "    fn eepfs_wipe()\n}\n\n"
        "-- read a save file:\n"
        "static save_data: [32]u8 = undefined\n"
        "let result: i32 = eepfs_read(\"save.dat\", &save_data[0], 32)\n"
        "if result < 0 {\n    -- file not found or EEPROM not present\n}\n```\n\n"
        "eepromfs must be initialized with a file table at startup (done in C/build system). "
        "Each write takes ~15ms per 8-byte EEPROM block.")

    # === Save formats ===
    add("What save storage options does the N64 have?",
        "| Storage | Size | Speed | Notes |\n"
        "|---|---|---|---|\n"
        "| EEPROM 4K | 512 bytes | 15ms/block | Most common, 64 blocks of 8 bytes |\n"
        "| EEPROM 16K | 2 KB | 15ms/block | 256 blocks of 8 bytes |\n"
        "| SRAM | 32 KB | Fast | Battery-backed, random access |\n"
        "| FlashRAM | 128 KB | Medium | Block-erase, then write |\n"
        "| Controller Pak | 32 KB | Slow | External memory card, player-removable |\n\n"
        "In Pak, EEPROM is directly supported via `use n64.eeprom`. For SRAM and "
        "FlashRAM, use extern to access libdragon's C API. Controller Pak uses `use n64.cpak`.")

    add("How do I use SRAM save storage in Pak?",
        "SRAM is 32 KB of battery-backed RAM on the cartridge. Access via DMA:\n\n"
        "```pak\nuse n64.dma\nuse n64.cache\n\n"
        "const SRAM_ADDR: u32 = 0x08000000  -- SRAM base address\n\n"
        "@aligned(16)\nstatic sram_buf: [256]u8 = undefined\n\n"
        "fn sram_read(offset: u32, size: u32) {\n"
        "    cache.writeback(&sram_buf[0], size)\n"
        "    dma.read(&sram_buf[0], SRAM_ADDR + offset, size)\n"
        "    dma.wait()\n"
        "    cache.invalidate(&sram_buf[0], size)\n}\n\n"
        "fn sram_write(offset: u32, size: u32) {\n"
        "    cache.writeback(&sram_buf[0], size)\n"
        "    dma.write(&sram_buf[0], SRAM_ADDR + offset, size)\n"
        "    dma.wait()\n}\n```\n\n"
        "SRAM is faster than EEPROM and allows random access to 32 KB. "
        "Perfect Dark and many RPGs used SRAM for large save files.")

    add("How do I use FlashRAM in Pak?",
        "FlashRAM provides 128 KB of non-volatile storage. It requires block-erase "
        "before writing (like flash memory). Access via extern:\n\n"
        "```pak\nextern \"C\" {\n"
        "    fn flashram_read(dst: *u8, offset: u32, size: u32) -> i32\n"
        "    fn flashram_erase_block(block: u32) -> i32\n"
        "    fn flashram_write(src: *u8, offset: u32, size: u32) -> i32\n}\n\n"
        "-- FlashRAM blocks are typically 128 bytes\n"
        "-- erase a block before writing to it\n"
        "-- 128 KB = 1024 blocks of 128 bytes\n```\n\n"
        "FlashRAM was used by games like Pokemon Stadium and Zelda: Majora's Mask "
        "for large save files. Slower than SRAM but more capacity.")

    # === Uncached memory ===
    add("What is uncached memory and when do I need it on N64?",
        "Uncached memory bypasses the CPU cache entirely. DMA buffers, audio buffers, "
        "and framebuffers benefit from uncached access because:\n"
        "- No cache writeback/invalidate needed before/after DMA\n"
        "- Hardware can read/write without cache coherency issues\n\n"
        "Access via extern:\n"
        "```pak\nextern \"C\" {\n"
        "    fn malloc_uncached(size: u32) -> *u8\n"
        "    fn malloc_uncached_aligned(align: i32, size: u32) -> *u8\n"
        "    fn free_uncached(ptr: *u8)\n}\n\n"
        "let dma_buf: *u8 = malloc_uncached_aligned(16, 4096)\n"
        "-- no cache.writeback/invalidate needed with uncached memory\n"
        "dma.read(dma_buf, rom_addr, 4096)\ndma.wait()\n"
        "-- data is immediately visible to CPU\n"
        "free_uncached(dma_buf)\n```\n\n"
        "Trade-off: uncached reads are slower (~5x). Use cached memory with manual "
        "cache management for performance-critical buffers.")

    # === System info ===
    add("How do I detect the Expansion Pak in Pak?",
        "```pak\nextern \"C\" {\n"
        "    fn get_memory_size() -> i32\n"
        "    fn is_memory_expanded() -> bool\n}\n\n"
        "fn check_expansion() {\n"
        "    if is_memory_expanded() {\n"
        "        -- 8 MB RAM available\n"
        "        let total: i32 = get_memory_size()  -- 8388608\n"
        "    } else {\n"
        "        -- 4 MB RAM only\n"
        "        let total: i32 = get_memory_size()  -- 4194304\n"
        "    }\n}\n```\n\n"
        "Games like Perfect Dark and Majora's Mask required the Expansion Pak for "
        "hi-res mode or additional features. Rogue Squadron used it for higher-res textures.")

    add("How do I detect NTSC vs PAL in Pak?",
        "```pak\nextern \"C\" {\n"
        "    fn get_tv_type() -> i32\n}\n\n"
        "-- return values:\n-- 0 = PAL (50 Hz, Europe/Australia)\n"
        "-- 1 = NTSC (60 Hz, Americas/Japan)\n-- 2 = MPAL (Brazil)\n\n"
        "fn is_pal() -> bool {\n    return get_tv_type() == 0\n}\n```\n\n"
        "PAL games run at 50 fps vs NTSC 60 fps. Adjust timing accordingly:\n"
        "- Audio buffer size changes (44100/50 = 882 vs 44100/60 = 735 samples)\n"
        "- Physics should use delta time, not fixed frame count")

    # === Timer advanced ===
    add("How do I use high-resolution timing in Pak?",
        "```pak\nextern \"C\" {\n"
        "    fn get_ticks() -> u64\n"
        "    fn get_ticks_us() -> u64\n"
        "    fn get_ticks_ms() -> u64\n"
        "    fn wait_ticks(ticks: u32)\n"
        "    fn wait_ms(ms: u32)\n}\n\n"
        "-- the N64 timer runs at 46,875,000 ticks per second\n"
        "const TICKS_PER_SEC: u64 = 46875000\n\n"
        "fn profile_fn() {\n"
        "    let start: u64 = get_ticks()\n"
        "    expensive_function()\n"
        "    let end: u64 = get_ticks()\n"
        "    let elapsed_us: u64 = get_ticks_us() - start\n}\n```\n\n"
        "Use for profiling render time, physics, or AI per frame.")

    # === Interrupt handling ===
    add("How do interrupts work on the N64?",
        "The N64 uses MIPS coprocessor 0 interrupts. libdragon handles interrupt "
        "dispatch and provides callback registration. Key interrupts:\n\n"
        "- **VI (Vertical Interrupt)**: fires every frame at vblank\n"
        "- **AI (Audio Interrupt)**: fires when audio buffer is consumed\n"
        "- **PI (Parallel Interface)**: fires when DMA completes\n"
        "- **Timer**: programmable countdown interrupt\n\n"
        "In Pak, you generally don't handle interrupts directly — libdragon's "
        "display, audio, and timer subsystems manage them. However, for advanced "
        "use cases, you can register callbacks via extern:\n\n"
        "```pak\nextern \"C\" {\n"
        "    fn register_VI_handler(callback: fn())\n}\n```\n\n"
        "Most game logic should run in the main loop, not in interrupt handlers.")

    return pairs
