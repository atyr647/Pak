"""Generate bug-fix training pairs: broken code + explanation + fix."""


def gen_bugfixes() -> list[dict]:
    pairs = []

    def add(instruction, output):
        pairs.append({"instruction": instruction, "output": output,
                       "source": "generated", "category": "debugging"})

    # --- Missing controller.poll() ---
    add(
        "Fix this Pak code — input never changes:\n\n```pak\nuse n64.controller\n\nentry {\n    controller.init()\n    loop {\n        let pad = controller.read(0)\n        if pad.held.a { }\n    }\n}\n```",
        "The bug is that `controller.poll()` is missing before `controller.read()`. Without polling, the input state is never updated and returns stale data from the previous frame.\n\nFixed:\n```pak\nuse n64.controller\n\nentry {\n    controller.init()\n    loop {\n        controller.poll()\n        let pad = controller.read(0)\n        if pad.held.a { }\n    }\n}\n```"
    )

    # --- Using && instead of and ---
    add(
        "Fix this Pak code — it won't compile:\n\n```pak\nif x > 0 && y > 0 {\n    do_something()\n}\n```",
        "Pak uses `and`, `or`, `not` — not `&&`, `||`, `!`.\n\nFixed:\n```pak\nif x > 0 and y > 0 {\n    do_something()\n}\n```"
    )

    # --- Using null instead of none ---
    add(
        "Fix this Pak code:\n\n```pak\nlet p: ?*Foo = null\nif p != null { use_p(p) }\n```",
        "Pak uses `none`, not `null`. The keyword `null` does not exist.\n\nFixed:\n```pak\nlet p: ?*Foo = none\nif p != none { use_p(p) }\n```"
    )

    # --- Using fn main() ---
    add(
        "Fix this Pak program — it gives error E103:\n\n```pak\nuse n64.debug\n\nfn main() {\n    debug.log(\"hello\")\n}\n```",
        "Pak has no `fn main()`. The entry point is `entry { }`.\n\nFixed:\n```pak\nuse n64.debug\n\nentry {\n    debug.log(\"hello\")\n}\n```"
    )

    # --- Semicolons ---
    add(
        "Fix this Pak code:\n\n```pak\nlet x: i32 = 5;\nlet y: f32 = 3.14;\nreturn x;\n```",
        "Pak is newline-delimited — semicolons are not needed.\n\nFixed:\n```pak\nlet x: i32 = 5\nlet y: f32 = 3.14\nreturn x\n```"
    )

    # --- Missing @aligned(16) on DMA buffer ---
    add(
        "Fix this Pak code — it gives error E202:\n\n```pak\nuse n64.dma\nuse n64.cache\n\nstatic buf: [4096]u8 = undefined\n\nentry {\n    cache.writeback(&buf[0], 4096)\n    dma.read(&buf[0], 0x10040000, 4096)\n    dma.wait()\n    cache.invalidate(&buf[0], 4096)\n}\n```",
        "Error E202 means the DMA buffer is not `@aligned(16)`. N64 DMA requires 16-byte alignment.\n\nFixed:\n```pak\nuse n64.dma\nuse n64.cache\n\n@aligned(16)\nstatic buf: [4096]u8 = undefined\n\nentry {\n    cache.writeback(&buf[0], 4096)\n    dma.read(&buf[0], 0x10040000, 4096)\n    dma.wait()\n    cache.invalidate(&buf[0], 4096)\n}\n```"
    )

    # --- Missing cache.writeback before DMA ---
    add(
        "Fix this Pak code — it gives error E201:\n\n```pak\nuse n64.dma\nuse n64.cache\n\n@aligned(16)\nstatic buf: [4096]u8 = undefined\n\nentry {\n    dma.read(&buf[0], 0x10040000, 4096)\n    dma.wait()\n    cache.invalidate(&buf[0], 4096)\n}\n```",
        "Error E201 means `cache.writeback` was not called before DMA. The cache must be flushed to RAM first.\n\nFixed:\n```pak\nuse n64.dma\nuse n64.cache\n\n@aligned(16)\nstatic buf: [4096]u8 = undefined\n\nentry {\n    cache.writeback(&buf[0], 4096)\n    dma.read(&buf[0], 0x10040000, 4096)\n    dma.wait()\n    cache.invalidate(&buf[0], 4096)\n}\n```"
    )

    # --- Missing rdpq.sync_pipe() between mode switches ---
    add(
        "Fix this Pak code — graphics are corrupted after switching RDP modes:\n\n```pak\nrdpq.set_mode_fill(0x000000FF)\nrdpq.fill_rectangle(0, 0, 320, 240)\nrdpq.set_mode_copy()\nsprite.blit(my_sprite, 10, 10, 0)\n```",
        "Missing `rdpq.sync_pipe()` between mode switches. The RDP pipeline must be synced when changing modes.\n\nFixed:\n```pak\nrdpq.set_mode_fill(0x000000FF)\nrdpq.fill_rectangle(0, 0, 320, 240)\nrdpq.sync_pipe()\nrdpq.set_mode_copy()\nsprite.blit(my_sprite, 10, 10, 0)\n```"
    )

    # --- Wrong init order ---
    add(
        "Fix this Pak code — it crashes on startup:\n\n```pak\nuse n64.display\nuse n64.rdpq\n\nentry {\n    rdpq.init()\n    display.init(0, 2, 3, 0, 1)\n}\n```",
        "Wrong initialization order. `display.init()` must be called BEFORE `rdpq.init()`. The RDP depends on the display subsystem being ready.\n\nFixed:\n```pak\nuse n64.display\nuse n64.rdpq\n\nentry {\n    display.init(0, 2, 3, 0, 1)\n    rdpq.init()\n}\n```"
    )

    # --- Implicit cast ---
    add(
        "Fix this Pak code — it won't compile:\n\n```pak\nlet i: i32 = 42\nlet f: f32 = i\n```",
        "Pak has no implicit type conversions. All casts must be explicit with `as`.\n\nFixed:\n```pak\nlet i: i32 = 42\nlet f: f32 = i as f32\n```"
    )

    # --- Using void return type ---
    add(
        "Fix this Pak function:\n\n```pak\nfn reset() -> void {\n    score = 0\n}\n```",
        "Pak has no `void` type. Omit the return type for functions that return nothing.\n\nFixed:\n```pak\nfn reset() {\n    score = 0\n}\n```"
    )

    # --- Using class ---
    add(
        "Fix this Pak code:\n\n```pak\nclass Player {\n    x: f32\n    y: f32\n}\n```",
        "Pak has no `class` keyword. Use `struct` + `impl`.\n\nFixed:\n```pak\nstruct Player {\n    x: f32\n    y: f32\n}\n\nimpl Player {\n    fn init(self: *Player) {\n        self.x = 0.0\n        self.y = 0.0\n    }\n}\n```"
    )

    # --- Using new/delete ---
    add(
        "Fix this Pak code:\n\n```pak\nlet p = new Player()\ndelete p\n```",
        "Pak has no `new`/`delete`. Use `alloc()`/`free()`.\n\nFixed:\n```pak\nlet p: *Player = alloc(Player)\nfree(p)\n```"
    )

    # --- Using ! instead of not ---
    add(
        "Fix this Pak code:\n\n```pak\nif !ready {\n    prepare()\n}\n```",
        "Pak uses `not` for logical negation, not `!`.\n\nFixed:\n```pak\nif not ready {\n    prepare()\n}\n```"
    )

    # --- Writing to framebuffer after detach_show ---
    add(
        "Fix this Pak code — screen flickers:\n\n```pak\nlet fb = display.get()\nrdpq.attach_clear(fb)\nrdpq.detach_show()\nrdpq.set_mode_fill(0xFF0000FF)\nrdpq.fill_rectangle(10, 10, 50, 50)\n```",
        "Drawing after `rdpq.detach_show()` writes to a buffer that's already been submitted for display. All draw calls must happen between `attach` and `detach_show`.\n\nFixed:\n```pak\nlet fb = display.get()\nrdpq.attach_clear(fb)\nrdpq.set_mode_fill(0xFF0000FF)\nrdpq.fill_rectangle(10, 10, 50, 50)\nrdpq.detach_show()\n```"
    )

    # --- Missing eeprom.present() check ---
    add(
        "Fix this Pak code — crashes on cartridges without EEPROM:\n\n```pak\nuse n64.eeprom\n\n@aligned(8)\nstatic buf: [8]u8 = undefined\n\nentry {\n    eeprom.read(0, &buf[0])\n}\n```",
        "Always check `eeprom.present()` before any EEPROM operation. Most cartridges don't have EEPROM.\n\nFixed:\n```pak\nuse n64.eeprom\n\n@aligned(8)\nstatic buf: [8]u8 = undefined\n\nentry {\n    if eeprom.present() {\n        eeprom.read(0, &buf[0])\n    }\n}\n```"
    )

    # --- audio.get_buffer() not checking none ---
    add(
        "Fix this Pak code — audio crackles:\n\n```pak\nuse n64.audio\n\nfn fill_audio() {\n    let buf: *i16 = audio.get_buffer()\n    buf[0] = 0\n}\n```",
        "`audio.get_buffer()` returns `none` when no buffer is ready. Writing to none crashes.\n\nFixed:\n```pak\nuse n64.audio\n\nfn fill_audio() {\n    let buf: *i16 = audio.get_buffer()\n    if buf == none { return }\n    buf[0] = 0\n}\n```"
    )

    # --- Parentheses on if condition ---
    add(
        "Fix this Pak code:\n\n```pak\nif (x > 10) {\n    do_thing()\n}\n```",
        "Pak conditions don't use parentheses.\n\nFixed:\n```pak\nif x > 10 {\n    do_thing()\n}\n```"
    )

    # --- Using try/catch ---
    add(
        "Fix this Pak code:\n\n```pak\ntry {\n    risky_operation()\n} catch (e) {\n    handle_error(e)\n}\n```",
        "Pak has no exceptions or try/catch. Use Result with match.\n\nFixed:\n```pak\nmatch risky_operation() {\n    .ok(v)  => { use_value(v) }\n    .err(e) => { handle_error(e) }\n}\n```"
    )

    # --- Non-exhaustive match ---
    add(
        "Fix this Pak code — it gives error E301:\n\n```pak\nenum State: u8 { idle, running, jumping }\n\nmatch state {\n    .idle    => { }\n    .running => { }\n}\n```",
        "Error E301 means the match is not exhaustive — not all cases are covered. Add the missing case or a wildcard `_`.\n\nFixed:\n```pak\nmatch state {\n    .idle    => { }\n    .running => { }\n    .jumping => { }\n}\n\n-- or with wildcard:\nmatch state {\n    .idle    => { }\n    .running => { }\n    _        => { }\n}\n```"
    )

    # --- Missing rdpq.set_mode before sprite.blit ---
    add(
        "Fix this Pak code — sprite doesn't render:\n\n```pak\nuse n64.rdpq\nuse n64.sprite\n\nasset my_sprite: Sprite from \"sprite.png\"\n\nlet fb = display.get()\nrdpq.attach_clear(fb)\nsprite.blit(my_sprite, 10, 10, 0)\nrdpq.detach_show()\n```",
        "Missing `rdpq.set_mode_copy()` before `sprite.blit()`. Blitting requires copy mode.\n\nFixed:\n```pak\nuse n64.rdpq\nuse n64.sprite\n\nasset my_sprite: Sprite from \"sprite.png\"\n\nlet fb = display.get()\nrdpq.attach_clear(fb)\nrdpq.set_mode_copy()\nsprite.blit(my_sprite, 10, 10, 0)\nrdpq.detach_show()\n```"
    )

    # --- Using Result<T,E> instead of Result(T,E) ---
    add(
        "Fix this Pak code — syntax error:\n\n```pak\nfn load() -> Result<i32, MyError> {\n    return ok(42)\n}\n```",
        "Pak uses parentheses for generic types, not angle brackets.\n\nFixed:\n```pak\nfn load() -> Result(i32, MyError) {\n    return ok(42)\n}\n```"
    )

    # --- Implicit bool coercion ---
    add(
        "Fix this Pak code:\n\n```pak\nlet count: i32 = get_count()\nif count {\n    process()\n}\n```",
        "Pak has no implicit integer-to-bool coercion. Compare explicitly.\n\nFixed:\n```pak\nlet count: i32 = get_count()\nif count != 0 {\n    process()\n}\n```"
    )

    return pairs
