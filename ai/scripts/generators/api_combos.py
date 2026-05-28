"""Generate API usage pairs for every function in every module."""


def gen_api_combos() -> list[dict]:
    pairs = []

    def add(instruction, output, cat="api_usage"):
        pairs.append({"instruction": instruction, "output": output,
                       "source": "generated", "category": cat})

    # === display ===
    add("How do I initialize the display in Pak?",
        "```pak\nuse n64.display\n\n-- display.init(resolution, bit_depth, num_buffers, gamma, filters)\n"
        "-- 0=320x240, 2=16bpp, 3=triple-buffer, 0=no gamma, 1=bilinear resample\n"
        "display.init(0, 2, 3, 0, 1)\n```")
    add("What do the display.init arguments mean?",
        "```pak\ndisplay.init(resolution, bit_depth, num_buffers, gamma, filters)\n```\n\n"
        "| Arg | Values |\n|---|---|\n"
        "| resolution | 0=320x240, 1=640x480, 2=256x240, 3=512x240 |\n"
        "| bit_depth | 2=16bpp, 4=32bpp |\n"
        "| num_buffers | 2=double, 3=triple |\n"
        "| gamma | 0=none, 1=correct, 3=correct+dither |\n"
        "| filters | 0=disabled, 1=resample, 3=resample+antialias |")
    add("How do I get a framebuffer in Pak?",
        "```pak\nlet fb = display.get()  -- blocks until a framebuffer is free\n```\n\n"
        "Call at the start of each frame's render. Always call before `rdpq.attach`.")
    add("How do I show a framebuffer in Pak?",
        "Preferred method (attach + detach in one):\n"
        "```pak\nlet fb = display.get()\nrdpq.attach_clear(fb)\n-- draw...\nrdpq.detach_show()\n```\n\n"
        "Do NOT use `display.show(fb)` separately — `rdpq.detach_show()` handles both.")

    # === controller ===
    add("How do I read controller input in Pak?",
        "```pak\nuse n64.controller\n\ncontroller.init()  -- once at startup\n\n"
        "-- every frame:\ncontroller.poll()\nlet pad = controller.read(0)  -- port 0 = player 1\n\n"
        "if pad.pressed.a { jump() }\nif pad.held.right { move_right() }\n"
        "let stick_x: i32 = pad.stick_x as i32\n```")
    add("How do I read the analog stick in Pak?",
        "```pak\ncontroller.poll()\nlet pad = controller.read(0)\n\n"
        "let raw_x: i32 = pad.stick_x as i32  -- -128 to 127\n"
        "let raw_y: i32 = pad.stick_y as i32  -- -128 to 127\n\n"
        "-- apply dead zone\nconst DEAD_ZONE: i32 = 10\n"
        "let dx: i32 = if raw_x > DEAD_ZONE or raw_x < -DEAD_ZONE { raw_x } else { 0 }\n"
        "let dy: i32 = if raw_y > DEAD_ZONE or raw_y < -DEAD_ZONE { raw_y } else { 0 }\n```")
    add("How do I handle multiplayer input in Pak?",
        "```pak\ncontroller.poll()  -- poll once updates all ports\n"
        "let p1 = controller.read(0)\nlet p2 = controller.read(1)\n"
        "let p3 = controller.read(2)\nlet p4 = controller.read(3)\n\n"
        "if p1.pressed.a { player1_action() }\nif p2.pressed.a { player2_action() }\n```")

    # === rdpq ===
    add("How do I clear the screen in Pak?",
        "Two approaches:\n\n"
        "```pak\n-- Option 1: attach_clear (clears to black automatically)\n"
        "let fb = display.get()\nrdpq.attach_clear(fb)\n-- draw...\nrdpq.detach_show()\n\n"
        "-- Option 2: manual fill with custom color\n"
        "let fb = display.get()\nrdpq.attach(fb, none)\n"
        "rdpq.set_mode_fill(0x000080FF)  -- dark blue\n"
        "rdpq.fill_rectangle(0, 0, 320, 240)\n-- draw...\nrdpq.detach_show()\n```")
    add("How do I draw a filled rectangle in Pak?",
        "```pak\nrdpq.set_mode_fill(0xFF0000FF)  -- red, RGBA format\n"
        "rdpq.fill_rectangle(x0, y0, x1, y1)  -- top-left to bottom-right\n```\n\n"
        "Color format is 32-bit RGBA: `(r << 24) | (g << 16) | (b << 8) | a`")
    add("How do I draw a sprite in Pak?",
        "```pak\nuse n64.rdpq\nuse n64.sprite\n\nasset my_sprite: Sprite from \"sprite.png\"\n\n"
        "-- in render:\nrdpq.set_mode_copy()  -- REQUIRED before blit\n"
        "sprite.blit(my_sprite, x, y, 0)\n```\n\n"
        "Always set copy mode before blitting. The 4th arg (flags) is usually 0.")
    add("When do I need rdpq.sync_pipe()?",
        "Call `rdpq.sync_pipe()` whenever you switch RDP modes within a frame:\n\n"
        "```pak\nrdpq.set_mode_fill(0x000000FF)\nrdpq.fill_rectangle(0, 0, 320, 240)\n"
        "rdpq.sync_pipe()              -- required!\n"
        "rdpq.set_mode_copy()\nsprite.blit(my_sprite, 10, 10, 0)\n```\n\n"
        "Without it, the RDP pipeline state may be incorrect and rendering will be garbled.")
    add("What color format does rdpq.set_mode_fill use?",
        "32-bit RGBA packed as `0xRRGGBBAA`.\n\n"
        "Common colors:\n"
        "- Black: `0x000000FF`\n- White: `0xFFFFFFFF`\n"
        "- Red: `0xFF0000FF`\n- Green: `0x00FF00FF`\n"
        "- Blue: `0x0000FFFF`\n- Transparent: `0x00000000`\n\n"
        "Build from components: `(r << 24) | (g << 16) | (b << 8) | a`")

    # === timer ===
    add("How do I get delta time in Pak?",
        "```pak\nuse n64.timer\n\ntimer.init()  -- once at startup\n\n"
        "-- in game loop:\nlet dt: f32 = timer.delta()  -- seconds since last call\n"
        "-- at 60 fps, dt ≈ 0.01667\n\n"
        "-- for physics, convert to fixed-point:\nlet dt_fixed: fix16.16 = dt as fix16.16\n```")
    add("How do I cap delta time on N64?",
        "The first call to `timer.delta()` after init returns a large value. Cap it:\n\n"
        "```pak\nlet dt: f32 = timer.delta()\nif dt > 0.05 { dt = 0.05 }  -- cap at 1/20s\n```\n\n"
        "This prevents the 'spiral of death' where a lag spike causes huge physics steps.")

    # === audio ===
    add("How do I initialize audio in Pak?",
        "```pak\nuse n64.audio\n\naudio.init(44100, 4)  -- 44100 Hz sample rate, 4 buffers\n```\n\n"
        "Valid frequencies: 22050, 32000, 44100. Buffer count: 2-8 (4 recommended).")
    add("How do I fill an audio buffer in Pak?",
        "```pak\nfn fill_audio() {\n    let buf: *i16 = audio.get_buffer()\n"
        "    if buf == none { return }  -- not ready, skip\n\n"
        "    -- interleaved stereo: [L0, R0, L1, R1, ...]\n"
        "    -- at 44100 Hz / 60 fps = 735 pairs = 1470 i16 values\n"
        "    let i: i32 = 0\n    loop {\n        if i >= 1470 { break }\n"
        "        buf[i] = left_sample      -- left\n"
        "        buf[i + 1] = right_sample -- right\n"
        "        i = i + 2\n    }\n}\n```")
    add("How do I generate a simple tone in Pak?",
        "```pak\nfn gen_square(t: i32, freq: i32) -> i16 {\n"
        "    let period: i32 = 44100 / freq\n"
        "    if (t % period) < (period / 2) {\n"
        "        return 8000 as i16\n    }\n    return -8000 as i16\n}\n```\n\n"
        "Use this in your audio buffer fill loop to generate a square wave.")

    # === debug ===
    add("How do I print debug messages in Pak?",
        "```pak\nuse n64.debug\n\ndebug.log(\"Hello from Pak!\")\n"
        "debug.log_value(\"score: %d\", score)\n"
        "debug.assert(health >= 0)\n```\n\n"
        "Debug output goes to USB/IS-Viewer. No output on retail hardware.")

    # === dma + cache ===
    add("Show me the complete DMA loading pattern in Pak.",
        "```pak\nuse n64.dma\nuse n64.cache\n\n"
        "@aligned(16)\nstatic buf: [4096]u8 = undefined\n\n"
        "fn load_from_rom(addr: u32, size: i32) {\n"
        "    cache.writeback(&buf[0], size as u32)\n"
        "    dma.read(&buf[0], addr, size as u32)\n"
        "    dma.wait()\n"
        "    cache.invalidate(&buf[0], size as u32)\n}\n```\n\n"
        "This is the ONLY safe DMA pattern. Never skip any step.")
    add("What cache operations does Pak support?",
        "```pak\nuse n64.cache\n\ncache.writeback(ptr, len)      -- flush dirty cache → RAM\n"
        "cache.invalidate(ptr, len)     -- mark cache invalid (CPU reads from RAM)\n"
        "cache.writeback_inv(ptr, len)  -- both in one call\n```\n\n"
        "Use writeback before DMA writes to RAM. Use invalidate after DMA completes.")

    # === eeprom ===
    add("Show me a complete EEPROM save/load in Pak.",
        "```pak\nuse n64.eeprom\n\nconst MAGIC: u32 = 0xDEAD1234\n\n"
        "@aligned(8)\nstatic buf: [8]u8 = undefined\n\n"
        "fn save(score: i32) {\n    if not eeprom.present() { return }\n"
        "    buf[0] = (MAGIC >> 24) as u8\n    buf[1] = (MAGIC >> 16) as u8\n"
        "    buf[2] = (MAGIC >> 8) as u8\n    buf[3] = MAGIC as u8\n"
        "    buf[4] = (score >> 24) as u8\n    buf[5] = (score >> 16) as u8\n"
        "    buf[6] = (score >> 8) as u8\n    buf[7] = score as u8\n"
        "    eeprom.write(0, &buf[0])\n}\n\n"
        "fn load() -> i32 {\n    if not eeprom.present() { return 0 }\n"
        "    eeprom.read(0, &buf[0])\n"
        "    let magic: u32 = (buf[0] as u32 << 24) | (buf[1] as u32 << 16)\n"
        "                   | (buf[2] as u32 << 8) | buf[3] as u32\n"
        "    if magic != MAGIC { return 0 }\n"
        "    return (buf[4] as i32 << 24) | (buf[5] as i32 << 16)\n"
        "         | (buf[6] as i32 << 8) | buf[7] as i32\n}\n```")

    # === t3d ===
    add("How do I set up a 3D scene with tiny3d in Pak?",
        "```pak\nuse n64.display\nuse n64.rdpq\nuse t3d\n\n"
        "entry {\n    display.init(0, 2, 3, 0, 1)\n    rdpq.init()\n    t3d.init()\n\n"
        "    let vp: T3DViewport = t3d.viewport_create()\n"
        "    t3d.viewport_set_projection(&vp, 70.0, 1.0, 100.0)\n\n"
        "    let model: *T3DModel = t3d.model_load(\"model.t3dm\")\n\n"
        "    loop {\n        let fb = display.get()\n        rdpq.attach_clear(fb)\n"
        "        t3d.frame_start()\n        t3d.viewport_attach(&vp)\n"
        "        t3d.model_draw(model)\n        t3d.frame_end()\n"
        "        rdpq.detach_show()\n    }\n}\n```")
    add("How do I set up lighting in tiny3d?",
        "```pak\nuse t3d\n\n-- ambient light (always visible)\n"
        "t3d.light_set_ambient(40, 40, 60)\n\n"
        "-- directional light (index, r, g, b, direction x, y, z)\n"
        "t3d.light_set_directional(0, 255, 240, 200, -0.5, -1.0, 0.5)\n\n"
        "-- number of active directional lights\nt3d.light_set_count(1)\n```")
    add("How do I animate a model in tiny3d?",
        "```pak\nuse t3d\n\nlet model: *T3DModel = t3d.model_load(\"char.t3dm\")\n"
        "let skel: T3DSkeleton = t3d.skeleton_create(model)\n"
        "let anim: T3DAnim = t3d.anim_create(model, \"walk\")\n\n"
        "t3d.anim_attach(&anim, &skel)\nt3d.anim_set_playing(&anim, true)\n"
        "t3d.anim_set_looping(&anim, true)\nt3d.anim_set_speed(&anim, 1.0)\n\n"
        "-- in game loop:\nt3d.anim_update(&anim, dt)\nt3d.skeleton_update(&skel)\n"
        "t3d.skeleton_draw(&skel, model)\n```")
    add("How do I transform a model in tiny3d?",
        "```pak\nuse t3d\n\nlet mat: T3DMat4 = undefined\n"
        "t3d.mat4_identity(&mat)\n"
        "t3d.mat4_translate(&mat, 0.0, 0.0, -10.0)\n"
        "t3d.mat4_rotate_y(&mat, angle)\n"
        "t3d.mat4_scale(&mat, 2.0, 2.0, 2.0)\n\n"
        "-- multiply matrices:\nlet result: T3DMat4 = undefined\n"
        "t3d.mat4_mul(&result, &mat_a, &mat_b)\n```\n\n"
        "Note: output pointer is always the first argument in t3d math functions.")
    add("What math functions does tiny3d provide?",
        "Matrix operations (output first arg):\n"
        "- `t3d.mat4_identity(out)` — set to identity\n"
        "- `t3d.mat4_rotate_x/y/z(out, angle)` — rotation\n"
        "- `t3d.mat4_translate(out, x, y, z)` — translation\n"
        "- `t3d.mat4_scale(out, x, y, z)` — scale\n"
        "- `t3d.mat4_mul(out, a, b)` — multiply\n\n"
        "Vector operations:\n"
        "- `t3d.vec3_norm(out, v)` — normalize\n"
        "- `t3d.vec3_cross(out, a, b)` — cross product\n"
        "- `t3d.vec3_dot(a, b) -> f32` — dot product")
    add("How do I set up a camera in tiny3d?",
        "T3D doesn't have a built-in camera struct. Build a view matrix manually:\n\n"
        "```pak\nuse t3d\n\nstruct Camera {\n    x: f32\n    y: f32\n    z: f32\n    rot_y: f32\n}\n\n"
        "fn camera_view(cam: *Camera, out: *T3DMat4) {\n"
        "    t3d.mat4_identity(out)\n"
        "    t3d.mat4_rotate_y(out, -cam.rot_y)\n"
        "    t3d.mat4_translate(out, -cam.x, -cam.y, -cam.z)\n}\n```")
    add("What types does tiny3d define?",
        "- `T3DViewport` — viewport/projection\n"
        "- `T3DModel` — loaded 3D model\n"
        "- `T3DObject` — sub-object within a model\n"
        "- `T3DMat4` — 4x4 matrix\n"
        "- `T3DVec3` — 3D vector\n"
        "- `T3DSkeleton` — bone hierarchy for animation\n"
        "- `T3DAnim` — animation clip\n\n"
        "All are used as values or pointers in Pak.")

    # === rumble ===
    add("How do I use the Rumble Pak in Pak?",
        "```pak\nuse n64.controller\nuse n64.rumble\n\ncontroller.init()\nrumble.init()  -- after controller.init()\n\n"
        "-- in game:\nrumble.start(0)  -- start rumble, port 0\nrumble.stop(0)   -- stop rumble\n```")

    # === cpak ===
    add("How do I use the Controller Pak in Pak?",
        "```pak\nuse n64.cpak\n\ncpak.init()\nif cpak.is_plugged(0) {\n"
        "    if not cpak.is_formatted(0) { cpak.format(0) }\n"
        "    let free = cpak.get_free_space(0)\n"
        "    cpak.read_sector(0, 0, &buf[0])\n    cpak.write_sector(0, 0, &buf[0])\n}\n```")

    # === tpak ===
    add("How do I use the Transfer Pak in Pak?",
        "```pak\nuse n64.tpak\n\ntpak.init(0)\nlet val: u8 = tpak.get_value(0, 0x0100)\n"
        "tpak.set_value(0, 0x0100, 0xFF)\n```\n\n"
        "Reads/writes Game Boy cartridge memory through the Transfer Pak accessory.")

    return pairs
