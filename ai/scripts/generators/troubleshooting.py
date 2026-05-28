"""Troubleshooting guide: common N64/Pak bugs, performance issues, visual glitches."""


def gen_troubleshooting() -> list[dict]:
    pairs = []

    def add(instruction, output):
        pairs.append({"instruction": instruction, "output": output,
                       "source": "generated", "category": "troubleshooting"})

    # === Frame rate ===
    add("My Pak game runs at 20fps instead of 60fps. What should I check?",
        "Work through this checklist in order:\n\n"
        "**1. Check polygon count:**\n"
        "- Add FPS counter: if it drops when many models are on screen, you're fill-rate limited\n"
        "- Reduce triangle count, add LOD, cull off-screen models\n\n"
        "**2. Check texture switching:**\n"
        "- Are you switching rdpq modes (fill → texture → fill) many times per frame?\n"
        "- Group draw calls by mode. Texture reloads into TMEM are expensive\n\n"
        "**3. Check CPU work per frame:**\n"
        "- Too many active enemies updating AI every frame?\n"
        "- Skip AI for enemies more than 100 units away\n"
        "- Run A* pathfinding over multiple frames, not in one call\n\n"
        "**4. Check audio:**\n"
        "- Too many mixer channels? Keep to 4-8 max\n"
        "- 44100Hz is expensive — try 22050Hz\n\n"
        "**5. Check memory:**\n"
        "- Heap fragmentation from alloc/free every frame?\n"
        "- Switch to object pools\n\n"
        "**6. Add FPS counter to isolate:**\n"
        "```pak\nstatic fps_frames: i32 = 0\n"
        "static fps_timer: f32 = 0.0\n"
        "static fps_display: i32 = 60\n\n"
        "fps_frames = fps_frames + 1\n"
        "fps_timer = fps_timer + dt\n"
        "if fps_timer >= 1.0 {\n"
        "    fps_display = fps_frames\n"
        "    fps_frames = 0\n"
        "    fps_timer = fps_timer - 1.0\n}\n```")

    add("My game stutters occasionally but usually runs fine. What's causing it?",
        "Intermittent stutters on N64 are usually caused by:\n\n"
        "**1. DMA blocking the CPU:**\n"
        "```pak\n-- BAD: dma.wait() blocks until done\ndma.read(&buf[0], rom_addr, size)\ndma.wait()  -- CPU sits idle here\n\n"
        "-- GOOD: start DMA early, do other work, then wait\ndma.read(&buf[0], rom_addr, size)\n-- do CPU work here...\ndma.wait()  -- now wait at the last moment\n```\n\n"
        "**2. Garbage collection / alloc spikes:**\n"
        "- If you call alloc() inside the game loop, you'll get spikes\n"
        "- Pre-allocate everything at level load\n\n"
        "**3. EEPROM access on the main thread:**\n"
        "- `eeprom.write()` blocks for ~2ms per block\n"
        "- Save only on pause/level transitions, never mid-gameplay\n\n"
        "**4. Audio buffer underruns:**\n"
        "- If `audio.get_buffer()` never returns none and you're filling it late,\n"
        "  the audio mixer may stall waiting\n"
        "- Ensure audio fill happens early each frame\n\n"
        "**5. Delta time not capped:**\n"
        "- A long frame makes dt spike, causing physics to jump\n"
        "- Always cap: `if dt > 0.033 { dt = 0.033 }`")

    # === Visual glitches ===
    add("My 3D scene has Z-fighting (flickering polygons). How do I fix it?",
        "Z-fighting happens when two surfaces are at nearly the same depth.\n\n"
        "**Causes and fixes:**\n\n"
        "**1. Near/far plane ratio too large:**\n"
        "```pak\n-- BAD: huge range destroys precision\nt3d.viewport_set_projection(&vp, 70.0, 0.1, 10000.0)\n\n"
        "-- GOOD: keep near/far ratio under 1:1000\nt3d.viewport_set_projection(&vp, 70.0, 1.0, 500.0)\n```\n\n"
        "**2. Coplanar geometry:**\n"
        "- Two faces at exactly the same position fight for depth\n"
        "- Separate them slightly in your 3D editor\n"
        "- Or use polygon offset (if supported by your version of t3d)\n\n"
        "**3. Far plane too close:**\n"
        "- If objects beyond the far plane clip, increase it\n"
        "- But every doubling of the near-far range halves Z precision\n\n"
        "**Rule of thumb:** near plane = 1.0 to 5.0, far plane = 100 to 1000 "
        "depending on scene scale.")

    add("My textures look wrong (corrupted or wrong colors). What's the issue?",
        "Texture corruption on N64 has several common causes:\n\n"
        "**1. Texture exceeds TMEM:**\n"
        "- A 128x128 RGBA16 texture needs 32KB — TMEM is only 4KB!\n"
        "- Max safe size: 64x64 RGBA16\n"
        "- Solution: reduce texture size in your 3D editor/asset pipeline\n\n"
        "**2. Non-power-of-2 dimensions:**\n"
        "- N64 requires power-of-2: 8, 16, 32, 64\n"
        "- A 100x100 texture will wrap/corrupt\n"
        "- Solution: resize to 64x64 or 128x128 in your asset pipeline\n\n"
        "**3. Wrong pixel format:**\n"
        "- Make sure your t3dm conversion settings match the rdpq mode\n"
        "- RGBA16 is the safest and most widely supported format\n\n"
        "**4. DMA cache coherency:**\n"
        "- If streaming textures via DMA, ensure cache.writeback before dma.read\n"
        "- And cache.invalidate after dma.wait\n"
        "- Missing this = stale cache data = wrong pixel values")

    add("My sprites are rendering with garbled pixels or wrong colors.",
        "Sprite rendering issues usually point to format or TMEM problems:\n\n"
        "**1. Check sprite format:**\n"
        "```pak\nextern \"C\" {\n"
        "    fn sprite_get_format(spr: *sprite_t) -> i32\n}\n"
        "-- Format should be FMT_RGBA16 (value 3) for standard sprites\n```\n\n"
        "**2. Check sprite dimensions:**\n"
        "- Width must be multiple of 8 for 16bpp, multiple of 16 for 4bpp\n"
        "- Height has no restriction but power-of-2 is safest\n\n"
        "**3. rdpq mode must match sprite format:**\n"
        "```pak\n-- for standard textured sprites:\nrdpq.set_mode_standard()\n"
        "-- don't mix rdpq.set_mode_fill() with sprite draws\n```\n\n"
        "**4. Ensure rdpq.sync_pipe() between mode switches:**\n"
        "```pak\nrdpq.set_mode_fill(0xFF0000FF)\nrdpq.fill_rectangle(0, 0, 320, 240)\n"
        "rdpq.sync_pipe()  -- REQUIRED before switching modes\n"
        "rdpq.set_mode_standard()\n-- now draw sprites\n```")

    # === Audio issues ===
    add("My audio crackles or pops. How do I fix it?",
        "Audio crackling on N64 is almost always a buffer underrun or overflow:\n\n"
        "**1. Fill audio buffers EVERY frame:**\n"
        "```pak\n-- WRONG: only fill when you remember\nif some_condition {\n"
        "    -- fill audio\n}\n\n"
        "-- CORRECT: check and fill every frame\nlet buf = audio.get_buffer()\n"
        "if buf != none {\n    mixer.poll(*buf)  -- always fill if buffer available\n}\n```\n\n"
        "**2. Don't block the audio thread:**\n"
        "- Never call `dma.wait()` or `eeprom.write()` in the same frame you fill audio\n"
        "- These block the CPU and cause audio starvation\n\n"
        "**3. Audio buffer count:**\n"
        "- `audio.init(44100, 2)` — 2 buffers is minimum, use 3 for stability\n"
        "- `audio.init(44100, 3)` gives more headroom\n\n"
        "**4. Sample rate:**\n"
        "- 44100Hz at 60fps: ~735 samples per buffer (14.7ms)\n"
        "- 22050Hz: more stable, half the CPU cost\n\n"
        "**5. Mixer channel overflow:**\n"
        "- Playing more sounds than channels causes glitches\n"
        "- Check `mixer.ch_playing(ch)` before triggering new sounds")

    add("My music and sound effects don't play at the same time. How do I fix?",
        "```pak\nuse n64.audio\nuse n64.mixer\nuse n64.wav64\nuse n64.xm64\n\n"
        "-- init audio with enough channels for both\naudio.init(44100, 3)\n"
        "mixer.init(16)  -- 16 channels total\n\n"
        "-- music on channel 0\nlet music: xm64player_t = undefined\nxm64player_open(&music, \"rom:/music/theme.xm64\")\n"
        "xm64player_play(&music, 0)  -- channel 0 for music\n\n"
        "-- sound effects on channels 1-7\nlet sfx_explosion: wav64_t = undefined\nwav64_open(&sfx_explosion, \"rom:/sfx/boom.wav64\")\n\n"
        "fn play_sfx(sfx: *wav64_t, ch: i32) {\n"
        "    -- use channels 1-7 for SFX, never channel 0 (music)\n"
        "    if ch < 1 or ch > 7 { return }\n"
        "    if mixer.ch_playing(ch) { return }  -- don't interrupt if busy\n"
        "    wav64_play(sfx, ch)\n}\n\n"
        "-- in game loop:\nlet buf = audio.get_buffer()\nif buf != none {\n"
        "    mixer.poll(*buf)\n}\n```\n\n"
        "**Key rules:**\n"
        "- XM music uses one channel per track instrument\n"
        "- Reserve dedicated channels for music, don't overlap with SFX\n"
        "- mixer.poll() mixes all active channels into the audio buffer")

    # === Controller issues ===
    add("My controller input is laggy or misses presses. How do I fix it?",
        "Controller polling must happen **every frame before reading**:\n\n"
        "```pak\n-- WRONG: reading without polling\nlet pad = controller.read(0)  -- will get stale data!\n\n"
        "-- CORRECT: poll first, then read\ncontroller.poll()\nlet pad = controller.read(0)\n```\n\n"
        "**For 'just pressed' detection**, compare previous and current state:\n"
        "```pak\nstatic prev_a: bool = false\n\nloop {\n"
        "    controller.poll()\n    let pad = controller.read(0)\n\n"
        "    let a_pressed: bool = pad.held.a and not prev_a  -- just pressed\n"
        "    prev_a = pad.held.a\n\n"
        "    if a_pressed {\n        -- handle A button press\n    }\n}\n```\n\n"
        "**Missing presses** usually means you're only reading every other frame. "
        "Always poll + read in the same frame, in that order.")

    # === Memory issues ===
    add("My game crashes with no error after running for a while. What's happening?",
        "Random crashes after running = memory corruption. Common causes:\n\n"
        "**1. Array out of bounds:**\n"
        "```pak\n-- if entity_count can reach 32, this writes past end!\nstatic enemies: [Enemy; 32] = undefined\n"
        "enemies[entity_count].x = 0.0  -- crashes when entity_count == 32\n\n"
        "-- fix: check before writing\nif entity_count < 32 {\n    enemies[entity_count].x = 0.0\n    entity_count = entity_count + 1\n}\n```\n\n"
        "**2. Use-after-free:**\n"
        "```pak\n-- BAD:\nlet ptr: *Enemy = alloc(Enemy)\nfree(ptr)\n"
        "ptr.hp = 10  -- crash! ptr is freed\n\n"
        "-- GOOD: set to none after free\nfree(ptr)\nptr = none\n```\n\n"
        "**3. Stack overflow:**\n"
        "- Very large local arrays overflow the stack\n"
        "- Move large arrays to `static` instead\n"
        "```pak\n-- BAD: 4KB on the stack in a nested function\nlet big: [u8; 4096] = undefined\n\n"
        "-- GOOD:\nstatic big: [u8; 4096] = undefined\n```\n\n"
        "**4. Null pointer dereference:**\n"
        "- Always check pointers returned by alloc() and model_load() before use")

    add("My EEPROM save data is corrupted after loading. How do I debug this?",
        "EEPROM corruption debugging steps:\n\n"
        "**1. Check EEPROM present first:**\n"
        "```pak\nif not eeprom.present() {\n    -- no EEPROM, don't try to read/write\n    return\n}\n```\n\n"
        "**2. Verify block alignment:**\n"
        "- Each EEPROM block = exactly 8 bytes\n"
        "- Struct size must be a multiple of 8\n"
        "```pak\n-- SaveData is 18 bytes — WRONG! Not multiple of 8\nstruct SaveData {\n"
        "    score: i32   -- 4\n    level: u8    -- 1\n"
        "    lives: u8    -- 1\n    flags: u16   -- 2\n"
        "    -- total 8 bytes — OK!\n}\n```\n\n"
        "**3. Always use a magic number and checksum:**\n"
        "```pak\nconst MAGIC: u32 = 0x47414D45  -- 'GAME'\n\n"
        "fn is_valid_save(data: *SaveData) -> bool {\n"
        "    return data.magic == MAGIC and data.checksum_valid\n}\n```\n\n"
        "**4. Read-after-write verification:**\n"
        "```pak\nfn save_verified(data: *SaveData) -> bool {\n"
        "    eeprom.write(0, data as *u8)\n"
        "    let verify: SaveData = undefined\n"
        "    eeprom.read(0, &verify as *u8)\n"
        "    return verify.magic == data.magic\n}\n```")

    # === Compiler errors ===
    add("I get error E201: DMA used without cache.writeback. How do I fix it?",
        "Error E201 means you called `dma.read()` without first calling "
        "`cache.writeback()` on the destination buffer.\n\n"
        "```pak\n-- WRONG (triggers E201):\ndma.read(&buf[0], rom_addr, size)\n\n"
        "-- CORRECT: always writeback before DMA\ncache.writeback(&buf[0], size)\ndma.read(&buf[0], rom_addr, size)\ndma.wait()\ncache.invalidate(&buf[0], size)\n```\n\n"
        "**Why this matters:** The N64's CPU cache and RAM are separate. "
        "Before DMA writes to RAM, you must flush any CPU-cached version of that "
        "region to RAM (writeback). After DMA completes, you invalidate the cache "
        "so the CPU reads fresh DMA data, not its stale cached copy.\n\n"
        "**Full DMA sequence:**\n"
        "1. `cache.writeback(&buf, size)` — flush CPU cache to RAM\n"
        "2. `dma.read(&buf, rom_addr, size)` — DMA from ROM to RAM\n"
        "3. `dma.wait()` — wait for DMA to complete\n"
        "4. `cache.invalidate(&buf, size)` — discard stale CPU cache")

    add("I get error E202: DMA buffer not aligned(16). What does this mean?",
        "Error E202 means your DMA destination buffer doesn't have 16-byte alignment, "
        "which is required by the N64 DMA hardware.\n\n"
        "```pak\n-- WRONG (triggers E202):\nstatic buf: [u8; 1024] = undefined  -- no alignment guarantee\n\n"
        "-- CORRECT: add @aligned(16) annotation\n@aligned(16)\nstatic buf: [u8; 1024] = undefined\n```\n\n"
        "**For heap allocation:**\n"
        "```pak\n-- alloc doesn't guarantee 16-byte alignment\n-- use static @aligned(16) buffers for DMA instead\n@aligned(16)\nstatic dma_buf: [u8; 4096] = undefined\n```\n\n"
        "**Why 16 bytes?** The N64 DMA controller requires the destination address "
        "to be 64-bit (8-byte) aligned, and libdragon requires 16-byte (one cache line) "
        "alignment for correct cache operation. Always use 16.")

    add("I get error E301: Non-exhaustive match. How do I fix it?",
        "Error E301 means your `match` statement doesn't cover all possible enum values.\n\n"
        "```pak\nenum Direction { north, south, east, west }\n\n"
        "-- WRONG (E301): missing east and west\nmatch dir {\n"
        "    Direction.north => { player.z = player.z - 1.0 }\n"
        "    Direction.south => { player.z = player.z + 1.0 }\n}\n\n"
        "-- FIX option 1: add all cases\nmatch dir {\n"
        "    Direction.north => { player.z = player.z - 1.0 }\n"
        "    Direction.south => { player.z = player.z + 1.0 }\n"
        "    Direction.east  => { player.x = player.x + 1.0 }\n"
        "    Direction.west  => { player.x = player.x - 1.0 }\n}\n\n"
        "-- FIX option 2: use wildcard for remaining cases\nmatch dir {\n"
        "    Direction.north => { player.z = player.z - 1.0 }\n"
        "    Direction.south => { player.z = player.z + 1.0 }\n"
        "    _ => { }  -- east and west: do nothing\n}\n```\n\n"
        "Pak requires exhaustive matches to prevent bugs from unhandled cases. "
        "Always add a wildcard `_` if some cases are intentionally no-ops.")

    add("My game compiles but t3d models don't show up on screen. What's wrong?",
        "Invisible t3d models have a few common causes:\n\n"
        "**1. Not calling t3d.frame_start() and frame_end():**\n"
        "```pak\n-- WRONG: drawing without t3d frame wrapping\nt3d.model_draw(model)\n\n"
        "-- CORRECT:\nt3d.frame_start()\nt3d.viewport_attach(&vp)\nt3d.model_draw(model)\nt3d.frame_end()\n```\n\n"
        "**2. Viewport not attached:**\n"
        "- `t3d.viewport_attach()` must be called every frame after `frame_start()`\n\n"
        "**3. Model outside the view frustum:**\n"
        "- Model might be at (0,0,0) behind the camera\n"
        "- Try moving the camera far back: `cam.z = -50.0`\n\n"
        "**4. Wrong near/far plane:**\n"
        "- Model might be closer than `near` or farther than `far`\n"
        "```pak\nt3d.viewport_set_projection(&vp, 70.0, 1.0, 100.0)\n"
        "-- model at z=200 would be clipped! increase far plane\n```\n\n"
        "**5. Model file not found:**\n"
        "- `t3d.model_load()` returns null if file missing\n"
        "- Check DragonFS includes the .t3dm file in the ROM\n"
        "- Add null check: `if model == none { -- handle error }`")

    return pairs
