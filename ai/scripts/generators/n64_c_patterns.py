"""N64 C patterns: how Pak maps to C, extern bridging, libdragon C idioms."""


def gen_n64_c_patterns() -> list[dict]:
    pairs = []

    def add(instruction, output):
        pairs.append({"instruction": instruction, "output": output,
                       "source": "generated", "category": "n64_c_patterns"})

    # === Pak to C mapping ===
    add("How does Pak code compile to C?",
        "Pak transpiles to C targeting libdragon. Key mappings:\n\n"
        "| Pak | C Output |\n"
        "|---|---|\n"
        "| `entry { ... }` | `int main(void) { ... }` |\n"
        "| `let x: i32 = 5` | `int32_t x = 5;` |\n"
        "| `let mut x: f32 = 1.0` | `float x = 1.0f;` |\n"
        "| `fn add(a: i32, b: i32) -> i32` | `int32_t add(int32_t a, int32_t b)` |\n"
        "| `struct Foo { x: i32 }` | `typedef struct { int32_t x; } Foo;` |\n"
        "| `and` / `or` / `not` | `&&` / `||` / `!` |\n"
        "| `none` | `NULL` |\n"
        "| `as` cast | C cast: `(type)expr` |\n"
        "| `alloc(T)` | `malloc(sizeof(T))` |\n"
        "| `free(ptr)` | `free(ptr)` |\n"
        "| `defer` | Emitted at scope exit |\n"
        "| `-- comment` | `// comment` |\n\n"
        "The compiler handles all type mappings: i32->int32_t, u8->uint8_t, "
        "f32->float, bool->bool, etc.")

    add("How do I use extern to call C functions from Pak?",
        "Use `extern \"C\"` to declare C functions:\n\n"
        "```pak\n-- declare C functions from libdragon or custom C code\n"
        "extern \"C\" {\n"
        "    fn memcpy(dst: *u8, src: *u8, n: u32)\n"
        "    fn memset(dst: *u8, val: i32, n: u32)\n"
        "    fn strlen(s: *c_char) -> u32\n"
        "    fn sprintf(buf: *c_char, fmt: *c_char, ...) -> i32\n}\n\n"
        "-- use them directly:\n"
        "let buf: [u8; 256] = undefined\n"
        "memset(&buf[0], 0, 256)\n```\n\n"
        "Extern declarations tell Pak the function exists in C. No body is needed. "
        "The linker resolves them from libdragon or your own C files.")

    add("How do I use extern C structs in Pak?",
        "Declare C structs with extern for direct access:\n\n"
        "```pak\n-- many libdragon types are opaque pointers in Pak\n"
        "-- use them as *TypeName\n\n"
        "extern \"C\" {\n"
        "    -- sprite_t is defined in libdragon C headers\n"
        "    fn sprite_load(path: *c_char) -> *sprite_t\n"
        "    fn sprite_free(spr: *sprite_t)\n"
        "    fn sprite_get_width(spr: *sprite_t) -> i32\n"
        "    fn sprite_get_height(spr: *sprite_t) -> i32\n}\n\n"
        "let spr: *sprite_t = sprite_load(\"gfx/player.sprite\")\n"
        "let w: i32 = sprite_get_width(spr)\n"
        "let h: i32 = sprite_get_height(spr)\n```\n\n"
        "For opaque C types, just use pointer access (*type_t). "
        "You don't need to know the struct layout.")

    add("How do I pass callbacks from Pak to C?",
        "Use function pointers via extern:\n\n"
        "```pak\nextern \"C\" {\n"
        "    fn timer_new(ticks: i32, callback: *fn(), repeating: bool) -> i32\n"
        "    fn timer_stop(timer_id: i32)\n}\n\n"
        "fn my_callback() {\n"
        "    -- this runs when the timer fires\n"
        "    -- be careful: runs in interrupt context\n"
        "    -- keep it minimal\n}\n\n"
        "entry {\n    timer.init()\n"
        "    let tid: i32 = timer_new(46875000, &my_callback, true)  -- 1 second\n"
        "    loop { }\n}\n```\n\n"
        "Function pointers in Pak use `*fn(args) -> ret` syntax. "
        "Pass with `&function_name`.")

    # === C patterns for N64 ===
    add("What are the key C patterns that Pak handles for N64 development?",
        "Pak handles several critical N64 C patterns automatically:\n\n"
        "**1. Cache management** — Pak's DMA module wraps cache ops:\n"
        "```pak\n-- Pak:\ncache.writeback(&buf[0], size)\n"
        "-- Generates: data_cache_hit_writeback_invalidate(buf, size);\n```\n\n"
        "**2. Aligned allocation** — @aligned annotation:\n"
        "```pak\n-- Pak:\n@aligned(16)\nstatic dma_buf: [u8; 1024] = undefined\n"
        "-- Generates: __attribute__((aligned(16))) static uint8_t dma_buf[1024];\n```\n\n"
        "**3. Volatile access** — for hardware registers:\n"
        "```pak\n-- Pak: use raw pointer casts for MMIO\nextern \"C\" {\n"
        "    fn io_read(addr: u32) -> u32\n    fn io_write(addr: u32, val: u32)\n}\n```\n\n"
        "**4. Big-endian awareness** — N64 is big-endian. Pak's integer types "
        "match the hardware byte order. No byte swapping needed for local data.")

    add("How does Pak handle N64 memory-mapped I/O?",
        "N64 hardware registers are accessed through memory-mapped addresses. "
        "In Pak, use extern C functions from libdragon:\n\n"
        "```pak\nextern \"C\" {\n"
        "    fn io_read(addr: u32) -> u32\n"
        "    fn io_write(addr: u32, val: u32)\n}\n\n"
        "-- N64 hardware register addresses:\n"
        "-- 0x04600000: PI (parallel interface / ROM)\n"
        "-- 0x04400000: VI (video interface)\n"
        "-- 0x04500000: AI (audio interface)\n"
        "-- 0x04300000: MI (MIPS interface)\n\n"
        "-- example: read VI status\n"
        "let vi_status: u32 = io_read(0x04400000)\n```\n\n"
        "In practice, use libdragon's API instead of raw register access. "
        "Direct register access is only needed for very low-level custom code.")

    add("How do I write inline C in Pak for performance-critical code?",
        "Pak doesn't support inline C directly. Instead, write a separate .c file "
        "and call it via extern:\n\n"
        "**fast_math.c:**\n"
        "```c\n#include <libdragon.h>\n\n"
        "// fast inverse square root (N64 has no FPU sqrt)\n"
        "float fast_invsqrt(float x) {\n"
        "    float xhalf = 0.5f * x;\n"
        "    int i = *(int*)&x;\n"
        "    i = 0x5f3759df - (i >> 1);\n"
        "    x = *(float*)&i;\n"
        "    x = x * (1.5f - xhalf * x * x);\n"
        "    return x;\n}\n```\n\n"
        "**game.pak:**\n"
        "```pak\nextern \"C\" {\n"
        "    fn fast_invsqrt(x: f32) -> f32\n}\n\n"
        "fn normalize_2d(x: *f32, y: *f32) {\n"
        "    let len_sq: f32 = (*x) * (*x) + (*y) * (*y)\n"
        "    if len_sq > 0.0001 {\n"
        "        let inv: f32 = fast_invsqrt(len_sq)\n"
        "        *x = (*x) * inv\n"
        "        *y = (*y) * inv\n"
        "    }\n}\n```\n\n"
        "Link the .c file in your Makefile. Pak and C objects link together normally.")

    add("What are the common libdragon C types I'll use from Pak?",
        "| C Type | Pak Usage | Description |\n"
        "|---|---|---|\n"
        "| `surface_t` | `*surface_t` | Framebuffer surface |\n"
        "| `sprite_t` | `*sprite_t` | 2D sprite |\n"
        "| `rdpq_font_t` | `*rdpq_font_t` | Bitmap font |\n"
        "| `wav64_t` | `wav64_t` (by value) | WAV64 audio |\n"
        "| `xm64player_t` | `xm64player_t` (by value) | XM music player |\n"
        "| `controller_data` | returned by controller.read() | Button/stick state |\n"
        "| `color_t` | `u32` (RGBA packed) | Color value |\n"
        "| `T3DViewport` | `T3DViewport` (by value) | 3D viewport |\n"
        "| `T3DModel` | `*T3DModel` (pointer) | 3D model |\n"
        "| `T3DMat4` | `T3DMat4` (by value) | 4x4 matrix |\n"
        "| `T3DVec3` | `T3DVec3` (by value) | 3D vector |\n"
        "| `T3DSkeleton` | `T3DSkeleton` (by value) | Skeleton |\n"
        "| `T3DAnim` | `T3DAnim` (by value) | Animation |\n\n"
        "Small types (vec3, mat4, etc.) are used by value. Large or opaque types "
        "(models, sprites) are used as pointers.")

    add("How do I handle C strings in Pak?",
        "Pak uses `*c_char` for C-compatible strings:\n\n"
        "```pak\nextern \"C\" {\n"
        "    fn strlen(s: *c_char) -> u32\n"
        "    fn strcmp(a: *c_char, b: *c_char) -> i32\n"
        "    fn strcpy(dst: *c_char, src: *c_char)\n"
        "    fn sprintf(buf: *c_char, fmt: *c_char, ...) -> i32\n}\n\n"
        "-- string literals are *c_char:\n"
        "let name: *c_char = \"Player 1\"\n"
        "let len: u32 = strlen(name)\n\n"
        "-- format numbers into strings:\n"
        "let buf: [c_char; 32] = undefined\n"
        "sprintf(&buf[0], \"Score: %d\", score)\n```\n\n"
        "String literals in Pak are null-terminated like C strings. "
        "There is no Pak-specific string type.")

    add("How do I use C arrays and buffers from Pak?",
        "```pak\n-- fixed-size arrays\n"
        "let buf: [u8; 1024] = undefined\n"
        "buf[0] = 0xFF\n\n"
        "-- get pointer to array start for C functions\n"
        "extern \"C\" {\n    fn memset(dst: *u8, val: i32, n: u32)\n}\n"
        "memset(&buf[0], 0, 1024)\n\n"
        "-- heap arrays\n"
        "let data: *u8 = alloc(u8, 4096)\n"
        "data[0] = 42\n"
        "data[100] = 0\n"
        "free(data)\n\n"
        "-- DMA-safe aligned buffer\n"
        "@aligned(16)\n"
        "static rom_buf: [u8; 2048] = undefined\n```\n\n"
        "Arrays decay to pointers when passed to extern C functions via &arr[0]. "
        "Use `alloc(T, n)` for runtime-sized arrays.")

    add("How does Pak handle struct layout compatibility with C?",
        "Pak structs have C-compatible layout (no padding surprises):\n\n"
        "```pak\n-- this Pak struct:\nstruct GameState {\n"
        "    score: i32      -- offset 0, 4 bytes\n"
        "    lives: u8       -- offset 4, 1 byte\n"
        "    level: u8       -- offset 5, 1 byte\n"
        "    padding: u16    -- offset 6, 2 bytes (manual padding)\n"
        "    timer: f32      -- offset 8, 4 bytes\n}\n\n"
        "-- generates this C struct:\n"
        "-- typedef struct {\n"
        "--     int32_t score;\n"
        "--     uint8_t lives;\n"
        "--     uint8_t level;\n"
        "--     uint16_t padding;\n"
        "--     float timer;\n"
        "-- } GameState;\n```\n\n"
        "Field order and alignment match C exactly. This matters for:\n"
        "- Saving structs to EEPROM/SRAM\n"
        "- DMA transfers\n"
        "- Passing structs to C functions")

    return pairs
