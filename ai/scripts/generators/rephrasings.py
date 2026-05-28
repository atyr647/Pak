"""Generate rephrased instruction variants for existing seed pairs."""


def gen_rephrasings() -> list[dict]:
    """Systematic rephrasings of core Pak concepts — same knowledge, different questions."""
    pairs = []

    def add(instruction, output, cat="rephrase"):
        pairs.append({"instruction": instruction, "output": output,
                       "source": "generated", "category": cat})

    # --- Entry point ---
    entry_answer = (
        "In Pak, the entry point is `entry { }`, not `fn main()`. "
        "Every executable Pak program has exactly one entry block. "
        "There is no main function.\n\n"
        "```pak\nentry {\n    -- program starts here\n}\n```"
    )
    add("What is the entry point of a Pak program?", entry_answer)
    add("How do I start a Pak program?", entry_answer)
    add("Where does execution begin in Pak?", entry_answer)
    add("Does Pak have a main function?",
        "No. Pak uses `entry { }` as its entry point, not `fn main()`. "
        "There is no main function.\n\n```pak\nentry {\n    -- your code here\n}\n```")
    add("Show me a minimal Pak program.",
        "```pak\nuse n64.debug\n\nentry {\n    debug.log(\"Hello from Pak!\")\n}\n```")

    # --- Logical operators ---
    logic_answer = (
        "Pak uses word-based logical operators:\n"
        "- `and` instead of `&&`\n"
        "- `or` instead of `||`\n"
        "- `not` instead of `!`\n\n"
        "```pak\nif a and b { }\nif x or y { }\nif not done { }\n```"
    )
    add("What logical operators does Pak use?", logic_answer)
    add("How do I write AND, OR, NOT in Pak?", logic_answer)
    add("Does Pak support && and ||?",
        "No. Pak uses `and`, `or`, `not` — the symbols `&&`, `||`, `!` do not exist.\n\n"
        "```pak\n-- WRONG: if a && b { }\n-- CORRECT:\nif a and b { }\n```")
    add("Convert `if (x && !y || z)` to Pak.",
        "```pak\nif x and not y or z { }\n```\n\n"
        "Note: no parentheses around the condition, and word operators instead of symbols.")

    # --- None vs null ---
    none_answer = (
        "Pak uses `none` — the keyword `null` does not exist.\n\n"
        "```pak\nlet p: ?*Foo = none\nif ptr == none { return }\n```"
    )
    add("How do I represent null in Pak?", none_answer)
    add("What is Pak's null keyword?", none_answer)
    add("Does Pak have null?",
        "No. Use `none` instead. The word `null` is not valid in Pak.\n\n"
        "```pak\nlet p: ?*i32 = none\nif p == none { return }\n```")

    # --- Type casting ---
    cast_answer = (
        "All casts in Pak are explicit with `as`. There are no implicit conversions.\n\n"
        "```pak\nlet f: f32 = some_i32 as f32\nlet i: i32 = some_f32 as i32\n"
        "let byte_val: u8 = big_int as u8\nlet ptr: *u8 = some_ptr as *u8\n```"
    )
    add("How do I cast types in Pak?", cast_answer)
    add("Does Pak have implicit type conversion?",
        "No. All type conversions must be explicit with `as`.\n\n"
        "```pak\n-- WRONG: let f: f32 = some_i32\n"
        "-- CORRECT:\nlet f: f32 = some_i32 as f32\n```")
    add("How do I convert between numeric types in Pak?", cast_answer)

    # --- Semicolons ---
    semi_answer = (
        "Pak is newline-delimited. Semicolons are not needed.\n\n"
        "```pak\nlet x: i32 = 5\nlet y: f32 = 3.14\nreturn x\n```"
    )
    add("Do I need semicolons in Pak?", semi_answer)
    add("Are semicolons required in Pak?", semi_answer)
    add("What statement terminator does Pak use?",
        "Newlines. Pak is newline-delimited — no semicolons needed.\n\n"
        "```pak\nlet x = 5\nx = x + 1\nreturn x\n```")

    # --- Comments ---
    comment_answer = (
        "Pak supports two single-line comment styles:\n"
        "- `--` (preferred)\n- `//` (also valid)\n\n"
        "There are no block/multi-line comments.\n\n"
        "```pak\n-- this is a comment (preferred)\n// this also works\n```"
    )
    add("How do I write comments in Pak?", comment_answer)
    add("What comment syntax does Pak use?", comment_answer)
    add("Does Pak have multi-line comments?",
        "No. Pak only has single-line comments using `--` (preferred) or `//`. "
        "There are no block comments like `/* */`.")

    # --- Structs ---
    struct_answer = (
        "```pak\nstruct Player {\n    x: f32\n    y: f32\n    health: i32\n}\n\n"
        "impl Player {\n    fn init(self: *Player) {\n        self.x = 0.0\n"
        "        self.y = 0.0\n        self.health = 100\n    }\n\n"
        "    fn is_alive(self: *Player) -> bool {\n        return self.health > 0\n    }\n}\n```"
    )
    add("How do I define a struct with methods in Pak?", struct_answer)
    add("Show me Pak's equivalent of a class.", struct_answer)
    add("Does Pak have classes?",
        "No. Use `struct` for data and `impl` blocks for methods.\n\n" + struct_answer)
    add("How do methods work in Pak?",
        "Methods are defined in `impl` blocks. The first parameter must be `self: *TypeName` "
        "(or `*mut TypeName` for mutable). Call with dot syntax.\n\n"
        "```pak\nimpl Player {\n    fn take_damage(self: *Player, amount: i32) {\n"
        "        self.health -= amount\n    }\n}\n\n-- Usage:\np.take_damage(10)\n```")

    # --- Enums ---
    add("How do I define an enum in Pak?",
        "```pak\nenum Direction {\n    north\n    south\n    east\n    west\n}\n\n"
        "-- with explicit type:\nenum GameState: u8 {\n    title\n    playing\n    paused\n}\n\n"
        "-- with values:\nenum Color: u8 {\n    red = 0\n    green = 1\n    blue = 2\n}\n```")
    add("How do I use match with enums in Pak?",
        "```pak\nmatch direction {\n    .north => { go_north() }\n"
        "    .south => { go_south() }\n    .east  => { go_east() }\n"
        "    .west  => { go_west() }\n}\n```\n\n"
        "Match must be exhaustive — cover all cases or use `_` wildcard.")

    # --- Variants ---
    add("What is a variant in Pak?",
        "A variant is a tagged union (sum type) where different cases can carry different data.\n\n"
        "```pak\nvariant Shape {\n    circle(f32)\n    rect(f32, f32)\n    point\n}\n\n"
        "fn area(s: Shape) -> f32 {\n    match s {\n"
        "        .circle(r)  => { return r * r * 3.14159 }\n"
        "        .rect(w, h) => { return w * h }\n"
        "        .point      => { return 0.0 }\n    }\n}\n```")
    add("When should I use enum vs variant in Pak?",
        "Use `enum` when you just need named tags (no data per case). "
        "Use `variant` when different cases carry different data.\n\n"
        "```pak\n-- enum: pure tags\nenum Direction { north, south, east, west }\n\n"
        "-- variant: cases have payloads\nvariant Pickup {\n    coin(i32)\n"
        "    health_pack(i32)\n    nothing\n}\n```")

    # --- Loops ---
    add("What loop types does Pak support?",
        "Pak has four loop types:\n\n"
        "```pak\n-- infinite loop\nloop {\n    if done { break }\n}\n\n"
        "-- while loop\nwhile condition {\n    -- body\n}\n\n"
        "-- do-while\ndo {\n    -- runs at least once\n} while condition\n\n"
        "-- for range\nfor i in 0..10 {\n    -- i goes 0..9\n}\n```")
    add("How does a for loop work in Pak?",
        "For loops iterate over ranges. The end is exclusive.\n\n"
        "```pak\nfor i in 0..10 {\n    -- i = 0, 1, 2, ..., 9\n}\n\n"
        "-- with index and element\nfor i, x in collection {\n    -- i is index, x is element\n}\n```")

    # --- Memory ---
    add("How does memory management work in Pak?",
        "Pak uses manual memory management. No garbage collector.\n\n"
        "```pak\n-- heap allocation\nlet ptr: *i32 = alloc(i32)\n"
        "let arr: *f32 = alloc(f32, 64)\n\n-- free\nfree(ptr)\nfree(arr)\n\n"
        "-- stack (preferred on N64)\nlet buf: [256]byte = undefined\n```\n\n"
        "On N64, prefer static buffers over heap allocation to avoid fragmentation in 4 MB RAM.")
    add("Should I use alloc or static buffers on N64?",
        "Prefer `static` buffers. The N64 only has 4 MB RAM, and heap fragmentation is a real "
        "problem. Use `alloc` only when the lifetime is truly dynamic.\n\n"
        "```pak\n-- PREFERRED:\nstatic enemy_pool: [16]Enemy = undefined\n\n"
        "-- AVOID unless necessary:\nlet e: *Enemy = alloc(Enemy)\n```")

    # --- Defer ---
    add("How does defer work in Pak?",
        "Defer runs cleanup code when the enclosing scope exits, in reverse order (LIFO).\n\n"
        "```pak\nfn work() {\n    let buf: *u8 = alloc(u8, 256)\n"
        "    defer { free(buf) }\n\n    -- buf freed automatically on return\n"
        "    if error { return }  -- buf still freed\n}\n```")

    # --- Error handling ---
    add("How does error handling work in Pak?",
        "Use `Result(OkType, ErrType)` with `ok()` and `err()` constructors.\n\n"
        "```pak\nenum MyError: u8 { not_found, bad_data }\n\n"
        "fn load(path: *c_char) -> Result(i32, MyError) {\n"
        "    if path == none { return err(MyError.not_found) }\n"
        "    return ok(42)\n}\n\n"
        "match load(\"data.bin\") {\n"
        "    .ok(val) => { use_value(val) }\n"
        "    .err(e)  => { handle_error(e) }\n}\n```")
    add("Does Pak have try/catch?",
        "No. Pak has no exceptions. Use `Result(Ok, Err)` for error handling.\n\n"
        "```pak\n-- WRONG:\ntry { risky() } catch (e) { }\n\n"
        "-- CORRECT:\nmatch risky() {\n    .ok(v)  => { use(v) }\n    .err(e) => { handle(e) }\n}\n```")

    # --- Fixed-point ---
    add("Why should I use fix16.16 on N64?",
        "The MIPS R4300i has a weak FPU — integer math is much faster. "
        "`fix16.16` uses integer operations for fractional math.\n\n"
        "```pak\nlet pos: fix16.16 = 10.5\nlet vel: fix16.16 = 0.25\n"
        "pos = pos + vel  -- integer add under the hood\n\n"
        "-- convert to screen coordinates:\nlet screen_x: i32 = pos as i32\n```")
    add("How do fixed-point numbers work in Pak?",
        "Pak has first-class fixed-point types: `fix16.16`, `fix10.5`, `fix1.15`.\n\n"
        "```pak\nlet a: fix16.16 = 1.5\nlet b: fix16.16 = 2.0\n"
        "let c = a * b    -- 3.0, uses MIPS mult\nlet d = a / b    -- ~0.75\n\n"
        "-- cast to/from integer\nlet i: i32 = a as i32  -- 1 (truncates)\n"
        "let f: fix16.16 = 3 as fix16.16\n```")

    # --- Pointers ---
    add("How do pointers work in Pak?",
        "```pak\n*T          -- immutable pointer\n*mut T      -- mutable pointer\n"
        "?*T         -- nullable pointer (can be none)\n\n"
        "let x: i32 = 42\nlet p: *i32 = &x          -- address-of\n"
        "let mp: *mut i32 = &mut x  -- mutable address\n"
        "let val: i32 = *p          -- dereference\n*mp = 99                   -- write through pointer\n```")

    # --- Assets ---
    add("How do I load sprites and assets in Pak?",
        "Declare assets at the top level with `asset name: Type from \"path\"`.\n\n"
        "```pak\nasset player_sprite: Sprite from \"sprites/player.png\"\n"
        "asset bg: Sprite from \"sprites/bg.png\"\nasset bgm: Sound from \"audio/theme.wav\"\n\n"
        "-- use in code:\nsprite.blit(player_sprite, x, y, 0)\n```")

    # --- Modules ---
    add("What modules can I import in Pak?",
        "N64 modules (import with `use n64.X`):\n"
        "`display`, `controller`, `rdpq`, `sprite`, `timer`, `audio`, "
        "`debug`, `dma`, `cache`, `eeprom`, `rumble`, `cpak`, `tpak`\n\n"
        "3D library: `use t3d`\n\n"
        "There is no math, string, io, os, or networking module.")
    add("How do imports work in Pak?",
        "```pak\nuse n64.display     -- import display module\n"
        "use n64.controller  -- import controller module\nuse t3d             -- import tiny3d\n\n"
        "-- after import, call as:\ndisplay.init(0, 2, 3, 0, 1)\ncontroller.init()\n"
        "t3d.init()\n```\n\nImports must be at the top level, not inside functions.")

    # --- Annotations ---
    add("What annotations does Pak support?",
        "```pak\n@hot          -- optimize function for speed\n"
        "@aligned(N)   -- set alignment (N must be power of 2)\n"
        "@cfg(FEATURE) -- conditional compilation\n"
        "@cfg(not(FEATURE))\n```\n\n"
        "Use `@aligned(16)` on DMA buffers. Use `@hot` on render/update functions.")

    # --- Extern ---
    add("How do I call C functions from Pak?",
        "Use `extern \"C\" { }` blocks to declare C functions.\n\n"
        "```pak\nextern \"C\" {\n    fn memset(ptr: *u8, value: i32, size: u32) -> *u8\n"
        "    fn memcpy(dst: *u8, src: *u8, size: u32) -> *u8\n"
        "    fn strlen(s: *c_char) -> u32\n}\n\n"
        "extern const TICKS_PER_SECOND: u32\n```")

    return pairs
