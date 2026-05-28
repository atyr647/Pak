"""Generate pattern-based training pairs: common game dev patterns in Pak."""


def gen_patterns() -> list[dict]:
    pairs = []

    def add(instruction, output, cat="pattern"):
        pairs.append({"instruction": instruction, "output": output,
                       "source": "generated", "category": cat})

    # === Object pool pattern ===
    add("Write an object pool in Pak for managing bullets.",
        "```pak\nconst MAX_BULLETS: i32 = 32\n\nstruct Bullet {\n    x: fix16.16\n    y: fix16.16\n"
        "    vx: fix16.16\n    vy: fix16.16\n    active: bool\n}\n\n"
        "static bullets: [32]Bullet = undefined\n\n"
        "fn init_pool() {\n    for i in 0..MAX_BULLETS {\n        bullets[i].active = false\n    }\n}\n\n"
        "fn spawn_bullet(x: fix16.16, y: fix16.16, vx: fix16.16, vy: fix16.16) -> bool {\n"
        "    for i in 0..MAX_BULLETS {\n        if not bullets[i].active {\n"
        "            bullets[i].x = x\n            bullets[i].y = y\n"
        "            bullets[i].vx = vx\n            bullets[i].vy = vy\n"
        "            bullets[i].active = true\n            return true\n        }\n    }\n"
        "    return false  -- pool full\n}\n\n"
        "fn update_bullets(dt: fix16.16) {\n    for i in 0..MAX_BULLETS {\n"
        "        if not bullets[i].active { continue }\n"
        "        bullets[i].x = bullets[i].x + bullets[i].vx * dt\n"
        "        bullets[i].y = bullets[i].y + bullets[i].vy * dt\n"
        "        if bullets[i].y as i32 < -10 { bullets[i].active = false }\n    }\n}\n```")

    # === Tile map pattern ===
    add("Write a tile map renderer in Pak.",
        "```pak\nuse n64.rdpq\n\nconst MAP_W: i32 = 20\nconst MAP_H: i32 = 15\n"
        "const TILE_SIZE: i32 = 16\n\n"
        "static tilemap: [300]u8 = undefined  -- 20 * 15\n\n"
        "fn set_tile(x: i32, y: i32, tile: u8) {\n    tilemap[y * MAP_W + x] = tile\n}\n\n"
        "fn get_tile(x: i32, y: i32) -> u8 {\n    return tilemap[y * MAP_W + x]\n}\n\n"
        "fn render_tilemap() {\n    for row in 0..MAP_H {\n        for col in 0..MAP_W {\n"
        "            let tile = get_tile(col, row)\n            if tile == 0 { continue }\n\n"
        "            let px: i32 = col * TILE_SIZE\n            let py: i32 = row * TILE_SIZE\n\n"
        "            -- different colors per tile type\n"
        "            let color: u32 = if tile == 1 { 0x448844FF }\n"
        "                elif tile == 2 { 0x886644FF }\n"
        "                else { 0x888888FF }\n\n"
        "            rdpq.sync_pipe()\n            rdpq.set_mode_fill(color)\n"
        "            rdpq.fill_rectangle(px, py, px + TILE_SIZE, py + TILE_SIZE)\n        }\n    }\n}\n```")

    # === State machine pattern ===
    add("Write a game state machine in Pak.",
        "```pak\nenum Phase: u8 {\n    splash\n    title\n    playing\n    paused\n    game_over\n}\n\n"
        "struct Game {\n    phase: Phase\n    score: i32\n    timer: f32\n}\n\n"
        "fn transition(gs: *Game, new_phase: Phase) {\n    gs.phase = new_phase\n    gs.timer = 0.0\n}\n\n"
        "fn update(gs: *Game, pad: joypad_status_t, dt: f32) {\n    gs.timer = gs.timer + dt\n\n"
        "    match gs.phase {\n"
        "        .splash => {\n            if gs.timer > 3.0 { transition(gs, Phase.title) }\n        }\n"
        "        .title => {\n            if pad.pressed.start { transition(gs, Phase.playing) }\n        }\n"
        "        .playing => {\n            if pad.pressed.start { transition(gs, Phase.paused) }\n"
        "            -- game logic here\n        }\n"
        "        .paused => {\n            if pad.pressed.start { transition(gs, Phase.playing) }\n        }\n"
        "        .game_over => {\n            if pad.pressed.start { transition(gs, Phase.title) }\n        }\n"
        "    }\n}\n```")

    # === AABB collision ===
    add("Write an AABB collision detection function in Pak.",
        "```pak\nstruct Rect {\n    x: i32\n    y: i32\n    w: i32\n    h: i32\n}\n\n"
        "fn rects_overlap(a: Rect, b: Rect) -> bool {\n"
        "    if a.x + a.w <= b.x { return false }\n    if b.x + b.w <= a.x { return false }\n"
        "    if a.y + a.h <= b.y { return false }\n    if b.y + b.h <= a.y { return false }\n"
        "    return true\n}\n\n"
        "fn point_in_rect(px: i32, py: i32, r: Rect) -> bool {\n"
        "    return px >= r.x and px < r.x + r.w and py >= r.y and py < r.y + r.h\n}\n```")

    # === Simple RNG ===
    add("Write a pseudo-random number generator in Pak.",
        "```pak\nstatic rng_seed: i32 = 12345\n\n"
        "fn rand() -> i32 {\n    rng_seed = rng_seed * 1103515245 + 12345\n"
        "    let val = (rng_seed / 65536) % 32768\n    if val < 0 { return -val }\n    return val\n}\n\n"
        "fn rand_range(lo: i32, hi: i32) -> i32 {\n    return lo + rand() % (hi - lo)\n}\n\n"
        "fn rand_seed(s: i32) {\n    rng_seed = s\n}\n```")

    # === Timer/cooldown pattern ===
    add("Write a cooldown timer in Pak.",
        "```pak\nstruct Cooldown {\n    elapsed: fix16.16\n    duration: fix16.16\n    ready: bool\n}\n\n"
        "impl Cooldown {\n    fn init(self: *Cooldown, duration: fix16.16) {\n"
        "        self.elapsed = 0.0 as fix16.16\n        self.duration = duration\n        self.ready = true\n    }\n\n"
        "    fn update(self: *Cooldown, dt: fix16.16) {\n"
        "        if self.ready { return }\n        self.elapsed = self.elapsed + dt\n"
        "        if self.elapsed >= self.duration {\n            self.ready = true\n        }\n    }\n\n"
        "    fn trigger(self: *Cooldown) -> bool {\n"
        "        if not self.ready { return false }\n"
        "        self.ready = false\n        self.elapsed = 0.0 as fix16.16\n        return true\n    }\n}\n```")

    # === Sprite animation ===
    add("Write a sprite animation system in Pak.",
        "```pak\nstruct Animation {\n    frame: i32\n    num_frames: i32\n"
        "    timer: fix16.16\n    frame_duration: fix16.16\n    looping: bool\n}\n\n"
        "impl Animation {\n    fn init(self: *Animation, frames: i32, speed: fix16.16, loop_anim: bool) {\n"
        "        self.frame = 0\n        self.num_frames = frames\n"
        "        self.timer = 0.0 as fix16.16\n        self.frame_duration = speed\n"
        "        self.looping = loop_anim\n    }\n\n"
        "    fn update(self: *Animation, dt: fix16.16) {\n"
        "        self.timer = self.timer + dt\n"
        "        if self.timer >= self.frame_duration {\n"
        "            self.timer = 0.0 as fix16.16\n"
        "            self.frame = self.frame + 1\n"
        "            if self.frame >= self.num_frames {\n"
        "                if self.looping {\n                    self.frame = 0\n"
        "                } else {\n                    self.frame = self.num_frames - 1\n"
        "                }\n            }\n        }\n    }\n}\n```")

    # === Color utility ===
    add("Write a color utility for building RGBA colors in Pak.",
        "```pak\nfn make_color(r: u8, g: u8, b: u8, a: u8) -> u32 {\n"
        "    return (r as u32 << 24) | (g as u32 << 16) | (b as u32 << 8) | a as u32\n}\n\n"
        "const COLOR_BLACK: u32 = 0x000000FF\nconst COLOR_WHITE: u32 = 0xFFFFFFFF\n"
        "const COLOR_RED: u32 = 0xFF0000FF\nconst COLOR_GREEN: u32 = 0x00FF00FF\n"
        "const COLOR_BLUE: u32 = 0x0000FFFF\nconst COLOR_YELLOW: u32 = 0xFFFF00FF\n"
        "const COLOR_CYAN: u32 = 0x00FFFFFF\nconst COLOR_MAGENTA: u32 = 0xFF00FFFF\n```")

    # === Fixed-point math helpers ===
    add("Write fixed-point math helper functions in Pak.",
        "```pak\nfn fix_abs(x: fix16.16) -> fix16.16 {\n"
        "    if x < 0.0 as fix16.16 { return 0.0 as fix16.16 - x }\n    return x\n}\n\n"
        "fn fix_min(a: fix16.16, b: fix16.16) -> fix16.16 {\n"
        "    if a < b { return a }\n    return b\n}\n\n"
        "fn fix_max(a: fix16.16, b: fix16.16) -> fix16.16 {\n"
        "    if a > b { return a }\n    return b\n}\n\n"
        "fn fix_clamp(val: fix16.16, lo: fix16.16, hi: fix16.16) -> fix16.16 {\n"
        "    if val < lo { return lo }\n    if val > hi { return hi }\n    return val\n}\n\n"
        "fn fix_lerp(a: fix16.16, b: fix16.16, t: fix16.16) -> fix16.16 {\n"
        "    return a + (b - a) * t\n}\n```")

    # === Entity component pattern ===
    add("Write a simple entity system in Pak with position, velocity, and health.",
        "```pak\nconst MAX_ENTITIES: i32 = 32\n\n"
        "struct Entity {\n    x: fix16.16\n    y: fix16.16\n    vx: fix16.16\n    vy: fix16.16\n"
        "    health: i32\n    active: bool\n}\n\nstatic entities: [32]Entity = undefined\n"
        "static entity_count: i32 = 0\n\n"
        "fn spawn(x: fix16.16, y: fix16.16, hp: i32) -> i32 {\n"
        "    for i in 0..MAX_ENTITIES {\n        if not entities[i].active {\n"
        "            entities[i].x = x\n            entities[i].y = y\n"
        "            entities[i].vx = 0.0 as fix16.16\n            entities[i].vy = 0.0 as fix16.16\n"
        "            entities[i].health = hp\n            entities[i].active = true\n"
        "            entity_count = entity_count + 1\n            return i\n        }\n    }\n"
        "    return -1\n}\n\n"
        "fn update_all(dt: fix16.16) {\n    for i in 0..MAX_ENTITIES {\n"
        "        if not entities[i].active { continue }\n"
        "        entities[i].x = entities[i].x + entities[i].vx * dt\n"
        "        entities[i].y = entities[i].y + entities[i].vy * dt\n"
        "        if entities[i].health <= 0 {\n            entities[i].active = false\n"
        "            entity_count = entity_count - 1\n        }\n    }\n}\n\n"
        "fn damage(id: i32, amount: i32) {\n    if id < 0 or id >= MAX_ENTITIES { return }\n"
        "    if not entities[id].active { return }\n"
        "    entities[id].health = entities[id].health - amount\n}\n```")

    # === Screen shake ===
    add("Write a screen shake effect in Pak.",
        "```pak\nstatic shake_x: i32 = 0\nstatic shake_y: i32 = 0\n"
        "static shake_timer: i32 = 0\nstatic shake_seed: i32 = 7\n\n"
        "fn shake_rand() -> i32 {\n    shake_seed = shake_seed * 1103515245 + 12345\n"
        "    return (shake_seed / 65536) % 9 - 4  -- -4 to 4\n}\n\n"
        "fn start_shake(frames: i32) {\n    shake_timer = frames\n}\n\n"
        "fn update_shake() {\n    if shake_timer > 0 {\n"
        "        shake_x = shake_rand()\n        shake_y = shake_rand()\n"
        "        shake_timer = shake_timer - 1\n    } else {\n"
        "        shake_x = 0\n        shake_y = 0\n    }\n}\n\n"
        "-- use shake_x and shake_y as offset when drawing:\n"
        "-- rdpq.fill_rectangle(x + shake_x, y + shake_y, ...)\n```")

    # === Simple particle system ===
    add("Write a simple particle system in Pak.",
        "```pak\nconst MAX_PARTICLES: i32 = 64\n\nstruct Particle {\n"
        "    x: fix16.16\n    y: fix16.16\n    vx: fix16.16\n    vy: fix16.16\n"
        "    life: i32\n    active: bool\n}\n\nstatic particles: [64]Particle = undefined\n\n"
        "fn init_particles() {\n    for i in 0..MAX_PARTICLES {\n"
        "        particles[i].active = false\n    }\n}\n\n"
        "fn emit(x: fix16.16, y: fix16.16, count: i32) {\n"
        "    let spawned: i32 = 0\n    for i in 0..MAX_PARTICLES {\n"
        "        if spawned >= count { return }\n        if particles[i].active { continue }\n"
        "        particles[i].x = x\n        particles[i].y = y\n"
        "        particles[i].vx = (rand() % 5 - 2) as fix16.16\n"
        "        particles[i].vy = (-(rand() % 4) - 1) as fix16.16\n"
        "        particles[i].life = 30 + rand() % 20\n"
        "        particles[i].active = true\n        spawned = spawned + 1\n    }\n}\n\n"
        "fn update_particles() {\n    for i in 0..MAX_PARTICLES {\n"
        "        if not particles[i].active { continue }\n"
        "        particles[i].x = particles[i].x + particles[i].vx\n"
        "        particles[i].y = particles[i].y + particles[i].vy\n"
        "        particles[i].vy = particles[i].vy + 0.1 as fix16.16  -- gravity\n"
        "        particles[i].life = particles[i].life - 1\n"
        "        if particles[i].life <= 0 {\n            particles[i].active = false\n        }\n    }\n}\n```")

    # === Input buffer for combos ===
    add("Write an input history buffer for combo detection in Pak.",
        "```pak\nconst HISTORY_SIZE: i32 = 16\n\nstruct InputHistory {\n"
        "    buttons: [16]u16\n    head: i32\n}\n\n"
        "impl InputHistory {\n    fn init(self: *InputHistory) {\n"
        "        self.head = 0\n        for i in 0..HISTORY_SIZE {\n"
        "            self.buttons[i] = 0\n        }\n    }\n\n"
        "    fn record(self: *InputHistory, pressed: u16) {\n"
        "        self.buttons[self.head] = pressed\n"
        "        self.head = (self.head + 1) % HISTORY_SIZE\n    }\n\n"
        "    fn check_sequence(self: *InputHistory, seq: *u16, len: i32) -> bool {\n"
        "        let start: i32 = (self.head - len + HISTORY_SIZE) % HISTORY_SIZE\n"
        "        for i in 0..len {\n"
        "            let idx: i32 = (start + i) % HISTORY_SIZE\n"
        "            if self.buttons[idx] != seq[i] { return false }\n"
        "        }\n        return true\n    }\n}\n```")

    # === Delta-time capped physics ===
    add("Write a capped delta-time physics update in Pak.",
        "```pak\nuse n64.timer\n\nconst MAX_DT: f32 = 0.05  -- cap at 1/20s\n\n"
        "fn physics_update(gs: *GameState) {\n    let raw_dt: f32 = timer.delta()\n"
        "    let dt: f32 = if raw_dt > MAX_DT { MAX_DT } else { raw_dt }\n"
        "    let dt_fixed: fix16.16 = dt as fix16.16\n\n"
        "    -- use dt_fixed for all physics:\n"
        "    gs.player.x = gs.player.x + gs.player.vx * dt_fixed\n"
        "    gs.player.y = gs.player.y + gs.player.vy * dt_fixed\n}\n```")

    # === Multi-block EEPROM save ===
    add("Write a multi-block EEPROM save for a larger save struct in Pak.",
        "```pak\nuse n64.eeprom\n\n-- Save data larger than 8 bytes: use multiple EEPROM blocks\n"
        "-- Each block = 8 bytes. For 24 bytes, use 3 blocks.\n\n"
        "@aligned(8)\nstatic save_block: [8]u8 = undefined\n\n"
        "fn save_multi(data: *u8, num_blocks: i32) {\n"
        "    if not eeprom.present() { return }\n"
        "    for block in 0..num_blocks {\n"
        "        for i in 0..8 {\n"
        "            save_block[i] = data[block * 8 + i]\n        }\n"
        "        eeprom.write(block, &save_block[0])\n    }\n}\n\n"
        "fn load_multi(data: *u8, num_blocks: i32) {\n"
        "    if not eeprom.present() { return }\n"
        "    for block in 0..num_blocks {\n"
        "        eeprom.read(block, &save_block[0])\n"
        "        for i in 0..8 {\n"
        "            data[block * 8 + i] = save_block[i]\n        }\n    }\n}\n```")

    # === Simple scrolling background ===
    add("Write a scrolling background in Pak.",
        "```pak\nuse n64.display\nuse n64.rdpq\n\nconst SCREEN_W: i32 = 320\nconst SCREEN_H: i32 = 240\n\n"
        "static scroll_y: i32 = 0\n\n"
        "fn render_scrolling_bg() {\n    scroll_y = (scroll_y + 1) % SCREEN_H\n\n"
        "    -- draw two-color alternating stripes that scroll\n"
        "    for row in 0..16 {\n        let y: i32 = (row * 16 - scroll_y + SCREEN_H) % SCREEN_H\n"
        "        let color: u32 = if row % 2 == 0 { 0x222244FF } else { 0x333366FF }\n"
        "        rdpq.sync_pipe()\n        rdpq.set_mode_fill(color)\n"
        "        rdpq.fill_rectangle(0, y, SCREEN_W, y + 16)\n    }\n}\n```")

    return pairs
