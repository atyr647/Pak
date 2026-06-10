# codegen/platformer.tcl — .pakstudio → gold-standard .pk64 + pak.toml
# All procs are pure functions (dict in → string out). No I/O, no globals.
#
# Architecture: the bulk of the emitted Pak is a fixed, proven-correct engine
# (bitmap font, procedural audio, save system, player/enemy logic, menus,
# rendering). Only a handful of sections are data-driven from the document:
# physics constants, per-level tile data, level dispatch, entity spawns, and
# the title string. Static blocks are kept in Tcl braced literals so that Pak's
# `[`/`]` array syntax is not interpreted by Tcl; dynamic blocks escape them.

namespace eval codegen::platformer {}

# ── Entry point ──────────────────────────────────────────────────────────────

proc codegen::platformer::generate {doc} {
    return [dict create \
        "pak.toml"      [_pak_toml $doc] \
        "src/main.pk64" [_main_pk64 $doc] \
    ]
}

# ── pak.toml ─────────────────────────────────────────────────────────────────

proc codegen::platformer::_pak_toml {doc} {
    set m    [dict get $doc meta]
    set s    [dict get $doc settings]
    set name [string tolower [regsub -all {\s+} [dict get $m name] "_"]]
    set title [dict get $m rom_title]
    set save  [dict get $s save_type]
    set res   [dict get $s resolution]
    set bpp   [dict get $s bit_depth]
    set fbs   [dict get $s framebuffers]
    return "\[project\]
name = \"$name\"
rom_title = \"$title\"
save_type = \"$save\"

\[display\]
resolution = \"$res\"
bit_depth = $bpp
framebuffers = $fbs

\[build\]
optimization = \"release\"
"
}

# ── Main source assembly ─────────────────────────────────────────────────────

# ── Asset queries ────────────────────────────────────────────────────────────

proc codegen::platformer::_sprite_roles {} {
    return {player enemy_patrol enemy_jumper coin spring checkpoint goal \
            tile_solid tile_oneway tile_hazard tile_ladder background}
}
proc codegen::platformer::_audio_roles {} {
    return {jump coin hurt stomp spring checkpoint win music}
}
proc codegen::platformer::_has_sprite {doc role} {
    expr {[dict exists $doc assets sprites $role]
          && [dict get $doc assets sprites $role] ne ""}
}
proc codegen::platformer::_has_audio {doc role} {
    expr {[dict exists $doc assets audio $role]
          && [dict get $doc assets audio $role] ne ""}
}
proc codegen::platformer::_any_sprite {doc} {
    foreach r [_sprite_roles] { if {[_has_sprite $doc $r]} { return 1 } }
    return 0
}
proc codegen::platformer::_any_sfx {doc} {
    foreach r {jump coin hurt stomp spring checkpoint win} {
        if {[_has_audio $doc $r]} { return 1 }
    }
    return 0
}
proc codegen::platformer::_any_audio {doc} {
    expr {[_any_sfx $doc] || [_has_audio $doc music]}
}

proc codegen::platformer::_main_pk64 {doc} {
    set out {}
    lappend out [_header $doc]
    lappend out [_constants $doc]
    lappend out [_asset_decls $doc]
    lappend out [_font_block]
    lappend out [_audio_block $doc]
    lappend out [_level_data $doc]
    lappend out [_level_dispatch $doc]
    lappend out [_entity_block]
    lappend out [_gamestate_block]
    lappend out [_save_block $doc]
    lappend out [_spawn_block]
    lappend out [_load_level $doc]
    lappend out [_player_block $doc]
    lappend out [_enemy_block]
    lappend out [_render_block $doc]
    lappend out [_render_title $doc]
    lappend out [_render_dispatch]
    lappend out [_update_block]
    lappend out [_entry_block $doc]
    return [join $out "\n"]
}

# ── Save storage ─────────────────────────────────────────────────────────────
# save_type "none" disables persistence entirely (no EEPROM use, stub save/load).
# Every other mode uses EEPROM block 0 for the compact save (high score + best
# stage): it is the universal tiny-save medium and links against stock libdragon.
# The selected type is still advertised in pak.toml / the ROM header.

proc codegen::platformer::_save_type {doc} {
    if {[dict exists $doc settings save_type]} {
        return [dict get $doc settings save_type]
    }
    return "none"
}
proc codegen::platformer::_save_on {doc} {
    expr {[_save_type $doc] ne "none"}
}

# ── Controller mapping ───────────────────────────────────────────────────────
# Each helper returns a Pak boolean expression over `pad` (a joypad_status_t)
# for the configured control. Movement can read the D-pad, the analog stick, or
# both; the analog stick uses CTRL_DEADZONE (N64 stick: +y is up).

proc codegen::platformer::_controls {doc} {
    if {[dict exists $doc controls]} { return [dict get $doc controls] }
    return [dict create jump_button a_or_b move_input both run_button none run_mult 1.6]
}
proc codegen::platformer::_jump_pressed_expr {doc} {
    switch -- [dict get [_controls $doc] jump_button] {
        a       { return "pad.pressed.a" }
        b       { return "pad.pressed.b" }
        z       { return "pad.pressed.z" }
        a_or_b  -
        default { return "pad.pressed.a or pad.pressed.b" }
    }
}
proc codegen::platformer::_left_expr {doc} {
    switch -- [dict get [_controls $doc] move_input] {
        dpad  { return "pad.held.left" }
        stick { return "pad.stick_x < -CTRL_DEADZONE" }
        default { return "(pad.held.left or pad.stick_x < -CTRL_DEADZONE)" }
    }
}
proc codegen::platformer::_right_expr {doc} {
    switch -- [dict get [_controls $doc] move_input] {
        dpad  { return "pad.held.right" }
        stick { return "pad.stick_x > CTRL_DEADZONE" }
        default { return "(pad.held.right or pad.stick_x > CTRL_DEADZONE)" }
    }
}
proc codegen::platformer::_up_expr {doc} {
    switch -- [dict get [_controls $doc] move_input] {
        dpad  { return "pad.held.up" }
        stick { return "pad.stick_y > CTRL_DEADZONE" }
        default { return "(pad.held.up or pad.stick_y > CTRL_DEADZONE)" }
    }
}
proc codegen::platformer::_down_expr {doc} {
    switch -- [dict get [_controls $doc] move_input] {
        dpad  { return "pad.held.down" }
        stick { return "pad.stick_y < -CTRL_DEADZONE" }
        default { return "(pad.held.down or pad.stick_y < -CTRL_DEADZONE)" }
    }
}
proc codegen::platformer::_run_held_expr {doc} {
    switch -- [dict get [_controls $doc] run_button] {
        z       { return "pad.held.z" }
        r       { return "pad.held.r" }
        b       { return "pad.held.b" }
        none    -
        default { return "" }
    }
}

# ── Header ───────────────────────────────────────────────────────────────────

proc codegen::platformer::_header {doc} {
    set name [dict get $doc meta name]
    set lines {}
    lappend lines "-- $name"
    lappend lines "-- Generated by PakStudio. DO NOT EDIT — regenerate from the .pakstudio project."
    lappend lines ""
    lappend lines "use n64.display"
    lappend lines "use n64.controller"
    lappend lines "use n64.rdpq"
    lappend lines "use n64.timer"
    lappend lines "use n64.audio"
    lappend lines "use n64.math"
    if {[_save_on $doc]} {
        lappend lines "use n64.eeprom"
    }
    if {[_any_sprite $doc]} {
        lappend lines "use n64.sprite"
    }
    if {[_any_audio $doc]} {
        lappend lines "use n64.mixer"
        lappend lines ""
        lappend lines "extern \"C\" \{"
        lappend lines "    fn wav64_open(wav: *wav64_t, path: *c_char)"
        lappend lines "    fn wav64_play(wav: *wav64_t, channel: i32)"
        lappend lines "    fn xm64player_open(xm: *xm64player_t, path: *c_char)"
        lappend lines "    fn xm64player_play(xm: *xm64player_t, first_channel: i32)"
        lappend lines "    fn xm64player_stop(xm: *xm64player_t)"
        lappend lines "\}"
    }
    lappend lines ""
    return [join $lines "\n"]
}

# ── Asset declarations ───────────────────────────────────────────────────────
# Sprites declare a `Sprite` asset (auto-loaded, usable as a sprite handle).
# Audio declares static wav64_t / xm64player_t handles loaded at startup.

proc codegen::platformer::_asset_decls {doc} {
    set lines {}
    lappend lines "-- ── Asset bindings ───────────────────────────────────────────────────────────"
    set any 0
    foreach role [_sprite_roles] {
        if {[_has_sprite $doc $role]} {
            lappend lines "asset spr_${role}: Sprite from \"sprites/${role}.png\""
            set any 1
        }
    }
    # Sound assets bundle/convert the source files into the ROM filesystem;
    # the wav64_t/xm64player_t handles are loaded from the rom: path at startup.
    foreach role {jump coin hurt stomp spring checkpoint win} {
        if {[_has_audio $doc $role]} {
            lappend lines "asset snd_${role}_data: Sound from \"audio/${role}.wav\""
            lappend lines "static snd_${role}: wav64_t = undefined"
            set any 1
        }
    }
    if {[_has_audio $doc music]} {
        lappend lines "asset music_data: Sound from \"audio/music.xm\""
        lappend lines "static music_player: xm64player_t = undefined"
        set any 1
    }
    if {!$any} {
        lappend lines "-- (none — using built-in procedural graphics & audio)"
    }
    lappend lines ""
    return [join $lines "\n"]
}

# ── Constants (data-driven physics) ──────────────────────────────────────────

proc codegen::platformer::_constants {doc} {
    set phys [dict get $doc physics]
    set g  [_f [dict get $phys gravity]]
    set jf [_f [dict get $phys jump_force]]
    set ms [_f [dict get $phys move_speed]]
    set mf [_f [dict get $phys max_fall]]
    set cf [dict get $phys coyote_frames]
    set jb [dict get $phys jump_buffer]
    set nlevels [llength [dict get $doc levels]]
    set rm [_f [dict get [_controls $doc] run_mult]]

    return "const SCREEN_W: i32 = 320
const SCREEN_H: i32 = 240
const TILE_SZ:  i32 = 16

const T_EMPTY:  u8 = 0
const T_SOLID:  u8 = 1
const T_ONEWAY: u8 = 2
const T_HAZARD: u8 = 3
const T_LADDER: u8 = 4

const GRAVITY:     f32 = $g
const JUMP_FORCE:  f32 = $jf
const MOVE_SPEED:  f32 = $ms
const MAX_FALL:    f32 = $mf
const CLIMB_SPEED: f32 = 1.6
const SPRING_FORCE: f32 = -11.0
const COYOTE_F:    i32 = $cf
const JUMP_BUF_F:  i32 = $jb
const INVULN_F:    i32 = 60

const CTRL_DEADZONE: i32 = 40
const RUN_MULT:      f32 = $rm

const PLAYER_W: i32 = 12
const PLAYER_H: i32 = 15

const NUM_LEVELS: i32 = $nlevels

const SAVE_BLOCK: i32 = 0
const SAVE_MAGIC_HI: u8 = 0x60
const SAVE_MAGIC_LO: u8 = 0x1D
"
}

# Format a number as a Pak f32 literal (always has a decimal point).
proc codegen::platformer::_f {v} {
    if {[string is integer -strict $v]} { return "${v}.0" }
    if {![string match "*.*" $v] && ![string match "*e*" $v]} { return "${v}.0" }
    return $v
}

# ── Bitmap font + text (static) ──────────────────────────────────────────────

proc codegen::platformer::_font_block {} {
    return {-- ── Bitmap font (3x5 glyphs, asset-free) ─────────────────────────────────────
const NUM_GLYPHS: i32 = 41

static font: [41]u16 = undefined

fn pack_glyph(r0: i32, r1: i32, r2: i32, r3: i32, r4: i32) -> u16 {
    return (r0 | (r1 << 3) | (r2 << 6) | (r3 << 9) | (r4 << 12)) as u16
}

fn init_font() {
    font[0]  = pack_glyph(7, 5, 5, 5, 7)
    font[1]  = pack_glyph(2, 6, 2, 2, 7)
    font[2]  = pack_glyph(7, 1, 7, 4, 7)
    font[3]  = pack_glyph(7, 1, 7, 1, 7)
    font[4]  = pack_glyph(5, 5, 7, 1, 1)
    font[5]  = pack_glyph(7, 4, 7, 1, 7)
    font[6]  = pack_glyph(7, 4, 7, 5, 7)
    font[7]  = pack_glyph(7, 1, 2, 2, 2)
    font[8]  = pack_glyph(7, 5, 7, 5, 7)
    font[9]  = pack_glyph(7, 5, 7, 1, 7)
    font[10] = pack_glyph(7, 5, 7, 5, 5)
    font[11] = pack_glyph(6, 5, 6, 5, 6)
    font[12] = pack_glyph(7, 4, 4, 4, 7)
    font[13] = pack_glyph(6, 5, 5, 5, 6)
    font[14] = pack_glyph(7, 4, 6, 4, 7)
    font[15] = pack_glyph(7, 4, 6, 4, 4)
    font[16] = pack_glyph(7, 4, 5, 5, 7)
    font[17] = pack_glyph(5, 5, 7, 5, 5)
    font[18] = pack_glyph(7, 2, 2, 2, 7)
    font[19] = pack_glyph(1, 1, 1, 5, 7)
    font[20] = pack_glyph(5, 5, 6, 5, 5)
    font[21] = pack_glyph(4, 4, 4, 4, 7)
    font[22] = pack_glyph(5, 7, 7, 5, 5)
    font[23] = pack_glyph(5, 7, 7, 7, 5)
    font[24] = pack_glyph(7, 5, 5, 5, 7)
    font[25] = pack_glyph(7, 5, 7, 4, 4)
    font[26] = pack_glyph(7, 5, 5, 7, 3)
    font[27] = pack_glyph(6, 5, 6, 5, 5)
    font[28] = pack_glyph(7, 4, 7, 1, 7)
    font[29] = pack_glyph(7, 2, 2, 2, 2)
    font[30] = pack_glyph(5, 5, 5, 5, 7)
    font[31] = pack_glyph(5, 5, 5, 5, 2)
    font[32] = pack_glyph(5, 5, 7, 7, 5)
    font[33] = pack_glyph(5, 5, 2, 5, 5)
    font[34] = pack_glyph(5, 5, 2, 2, 2)
    font[35] = pack_glyph(7, 1, 2, 4, 7)
    font[36] = pack_glyph(0, 0, 0, 0, 0)
    font[37] = pack_glyph(0, 2, 0, 2, 0)
    font[38] = pack_glyph(0, 0, 7, 0, 0)
    font[39] = pack_glyph(0, 0, 0, 0, 2)
    font[40] = pack_glyph(2, 2, 2, 0, 2)
}

fn char_index(c: i32) -> i32 {
    if c >= 48 and c <= 57 { return c - 48 }
    if c >= 65 and c <= 90 { return c - 65 + 10 }
    if c >= 97 and c <= 122 { return c - 97 + 10 }
    if c == 58 { return 37 }
    if c == 45 { return 38 }
    if c == 46 { return 39 }
    if c == 33 { return 40 }
    return 36
}

fn draw_glyph(gi: i32, x: i32, y: i32, scale: i32, col: u32) {
    if gi < 0 or gi >= NUM_GLYPHS { return }
    let packed: i32 = font[gi] as i32
    rdpq.set_fill_color(col)
    for row in 0..5 {
        let bits: i32 = (packed >> (row * 3)) & 7
        for cx in 0..3 {
            if (bits >> (2 - cx)) & 1 == 1 {
                let px: i32 = x + cx * scale
                let py: i32 = y + row * scale
                rdpq.fill_rectangle(px, py, px + scale, py + scale)
            }
        }
    }
}

fn draw_text(s: *c_char, x: i32, y: i32, scale: i32, col: u32) {
    let i: i32 = 0
    let step: i32 = 4 * scale
    loop {
        let c: i32 = s[i] as i32
        if c == 0 { break }
        draw_glyph(char_index(c), x + i * step, y, scale, col)
        i += 1
    }
}

fn text_width(s: *c_char, scale: i32) -> i32 {
    let i: i32 = 0
    loop {
        if s[i] as i32 == 0 { break }
        i += 1
    }
    return i * 4 * scale
}

fn draw_text_centered(s: *c_char, cx: i32, y: i32, scale: i32, col: u32) {
    let w: i32 = text_width(s, scale)
    draw_text(s, cx - w / 2, y, scale, col)
}

static numbuf: [10]i32 = undefined

fn draw_number(n: i32, x: i32, y: i32, scale: i32, col: u32) {
    let v: i32 = n
    if v < 0 { v = 0 }
    let cnt: i32 = 0
    if v == 0 {
        numbuf[0] = 0
        cnt = 1
    } else {
        while v > 0 and cnt < 10 {
            numbuf[cnt] = v % 10
            v = v / 10
            cnt += 1
        }
    }
    let step: i32 = 4 * scale
    let i: i32 = 0
    while i < cnt {
        draw_glyph(numbuf[cnt - 1 - i], x + i * step, y, scale, col)
        i += 1
    }
}
}
}

# ── Procedural audio engine (static) ─────────────────────────────────────────

# Sample-based audio engine (used when the project binds any audio asset).
proc codegen::platformer::_audio_block_assets {doc} {
    # channel map for one-shot SFX
    set chan {jump 4 coin 5 hurt 6 stomp 7 spring 8 checkpoint 9 win 10}
    set lines {}
    lappend lines "-- ── Sample-based audio (mixer + wav64/xm64) ──────────────────────────────────"
    lappend lines "fn snd_init() \{"
    lappend lines "    audio.init(44100, 4)"
    lappend lines "    mixer.init(16)"
    foreach role {jump coin hurt stomp spring checkpoint win} {
        if {[_has_audio $doc $role]} {
            lappend lines "    wav64_open(&snd_${role}, \"rom:/audio/${role}.wav64\")"
        }
    }
    if {[_has_audio $doc music]} {
        lappend lines "    xm64player_open(&music_player, \"rom:/audio/music.xm64\")"
    }
    lappend lines "\}"
    lappend lines ""
    lappend lines "fn fill_audio() \{"
    lappend lines "    let abuf = audio.get_buffer()"
    lappend lines "    if abuf != none \{ mixer.poll(*abuf) \}"
    lappend lines "\}"
    lappend lines ""
    if {[_has_audio $doc music]} {
        lappend lines "fn music_start() \{ xm64player_play(&music_player, 0) \}"
        lappend lines "fn music_stop()  \{ xm64player_stop(&music_player) \}"
    } else {
        lappend lines "fn music_start() \{ \}"
        lappend lines "fn music_stop()  \{ \}"
    }
    lappend lines ""
    foreach {role ch} $chan {
        if {[_has_audio $doc $role]} {
            lappend lines "fn sfx_${role}() \{ if not mixer.ch_playing(${ch}) \{ wav64_play(&snd_${role}, ${ch}) \} \}"
        } else {
            lappend lines "fn sfx_${role}() \{ \}"
        }
    }
    lappend lines ""
    return [join $lines "\n"]
}

proc codegen::platformer::_audio_block {doc} {
    if {[_any_audio $doc]} {
        return [_audio_block_assets $doc]
    }
    return {-- ── Procedural sound engine (asset-free) ─────────────────────────────────────
const SR: i32 = 44100

static sfx_len:  i32 = 0
static sfx_left: i32 = 0
static sfx_f0:   i32 = 220
static sfx_f1:   i32 = 220
static sfx_kind: i32 = 0
static snd_t:    i32 = 0
static rng:      i32 = 12345

static music_on: bool = false
static mus_idx:  i32 = 0
static mus_t:    i32 = 0

const MUS_NOTES: i32 = 8
static mus_freq: [8]i32 = undefined

fn init_music_table() {
    mus_freq[0] = 262
    mus_freq[1] = 330
    mus_freq[2] = 392
    mus_freq[3] = 523
    mus_freq[4] = 392
    mus_freq[5] = 330
    mus_freq[6] = 294
    mus_freq[7] = 247
}

fn play_sfx(kind: i32, f0: i32, f1: i32, dur_ms: i32) {
    sfx_kind = kind
    sfx_f0 = f0
    sfx_f1 = f1
    sfx_len = (SR / 1000) * dur_ms
    sfx_left = sfx_len
}

fn sfx_jump()       { play_sfx(0, 300, 720, 120) }
fn sfx_coin()       { play_sfx(0, 880, 1320, 90) }
fn sfx_hurt()       { play_sfx(1, 400, 120, 200) }
fn sfx_stomp()      { play_sfx(0, 500, 140, 110) }
fn sfx_spring()     { play_sfx(0, 400, 1000, 140) }
fn sfx_checkpoint() { play_sfx(0, 660, 990, 160) }
fn sfx_win()        { play_sfx(0, 523, 1046, 400) }

fn next_rng() -> i32 {
    rng = (rng * 1103515245 + 12345) & 0x7FFFFFFF
    return rng
}

fn square_at(freq: i32, t: i32, amp: i32) -> i32 {
    if freq <= 0 { return 0 }
    let period: i32 = SR / freq
    if period <= 0 { return 0 }
    if (t % period) < (period / 2) { return amp }
    return -amp
}

fn sfx_sample() -> i32 {
    if sfx_left <= 0 { return 0 }
    let elapsed: i32 = sfx_len - sfx_left
    let freq: i32 = sfx_f0
    if sfx_len > 0 {
        freq = sfx_f0 + (sfx_f1 - sfx_f0) * elapsed / sfx_len
    }
    let amp: i32 = 5000 * sfx_left / sfx_len
    let s: i32 = 0
    if sfx_kind == 1 {
        if (next_rng() & 1) == 1 { s = amp } else { s = -amp }
    } else {
        s = square_at(freq, snd_t, amp)
    }
    sfx_left -= 1
    return s
}

fn mus_sample() -> i32 {
    if not music_on { return 0 }
    let note_len: i32 = SR / 6
    mus_t += 1
    if mus_t >= note_len {
        mus_t = 0
        mus_idx += 1
        if mus_idx >= MUS_NOTES { mus_idx = 0 }
    }
    return square_at(mus_freq[mus_idx], snd_t, 1600)
}

fn fill_audio() {
    let buf: *i16 = audio.get_buffer()
    if buf == none { return }
    let i: i32 = 0
    loop {
        if i >= 1470 { break }
        let s: i32 = sfx_sample() + mus_sample()
        if s > 32000 { s = 32000 }
        if s < -32000 { s = -32000 }
        buf[i]     = s as i16
        buf[i + 1] = s as i16
        snd_t += 1
        i += 2
    }
}

fn snd_init() {
    audio.init(44100, 4)
    init_music_table()
}

fn music_start() { music_on = true }
fn music_stop()  { music_on = false }
}
}

# ── Level tile data (data-driven) ────────────────────────────────────────────

proc codegen::platformer::_level_data {doc} {
    set lvls [dict get $doc levels]
    set lines {}
    lappend lines "-- ── Level tile data ──────────────────────────────────────────────────────────"
    set li 0
    foreach lvl $lvls {
        set W [dict get $lvl width]
        set H [dict get $lvl height]
        set N [expr {$W * $H}]
        set tiles [dict get $lvl tiles]
        lappend lines "const LVL${li}_W: i32 = $W"
        lappend lines "const LVL${li}_H: i32 = $H"
        lappend lines "static lvl${li}_tiles: \[${N}\]u8 = \["
        set row {}
        set col 0
        foreach t $tiles {
            lappend row $t
            incr col
            if {$col == 16} {
                lappend lines "    [join $row {, }],"
                set row {}
                set col 0
            }
        }
        if {[llength $row] > 0} {
            lappend lines "    [join $row {, }],"
        }
        lappend lines "\]"
        lappend lines ""
        incr li
    }
    return [join $lines "\n"]
}

# ── Level dispatch (data-driven width/height/tile lookups) ───────────────────

proc codegen::platformer::_level_dispatch {doc} {
    set nlevels [llength [dict get $doc levels]]
    set lines {}

    lappend lines "fn level_w(level: i32) -> i32 {"
    for {set i 0} {$i < $nlevels} {incr i} {
        lappend lines "    if level == $i { return LVL${i}_W }"
    }
    lappend lines "    return LVL0_W"
    lappend lines "}"
    lappend lines ""

    lappend lines "fn level_h(level: i32) -> i32 {"
    for {set i 0} {$i < $nlevels} {incr i} {
        lappend lines "    if level == $i { return LVL${i}_H }"
    }
    lappend lines "    return LVL0_H"
    lappend lines "}"
    lappend lines ""

    lappend lines "fn tile_at(level: i32, tx: i32, ty: i32) -> u8 {"
    lappend lines "    let w: i32 = level_w(level)"
    lappend lines "    let h: i32 = level_h(level)"
    lappend lines "    if tx < 0 or tx >= w or ty < 0 { return T_SOLID }"
    lappend lines "    if ty >= h { return T_EMPTY }"
    for {set i 0} {$i < $nlevels} {incr i} {
        lappend lines "    if level == $i { return lvl${i}_tiles\[ty * w + tx\] }"
    }
    lappend lines "    return T_EMPTY"
    lappend lines "}"
    lappend lines ""

    lappend lines {fn is_solid(t: u8) -> bool { return t == T_SOLID }}
    lappend lines {fn is_oneway(t: u8) -> bool { return t == T_ONEWAY }}
    lappend lines {fn is_hazard(t: u8) -> bool { return t == T_HAZARD }}
    lappend lines {fn is_ladder(t: u8) -> bool { return t == T_LADDER }}
    lappend lines ""
    lappend lines "fn solid_at(level: i32, px: i32, py: i32) -> bool \{"
    lappend lines "    return is_solid(tile_at(level, px / TILE_SZ, py / TILE_SZ))"
    lappend lines "\}"
    return [join $lines "\n"]
}

# ── Entity structs + arrays (static) ─────────────────────────────────────────

proc codegen::platformer::_entity_block {} {
    return {-- ── Entities ─────────────────────────────────────────────────────────────────
const MAX_COINS:   i32 = 32
const MAX_ENEMIES: i32 = 16
const MAX_SPRINGS: i32 = 8
const MAX_CHECKS:  i32 = 4

struct Coin {
    x: f32
    y: f32
    active: bool
}

struct Enemy {
    x: f32
    y: f32
    vx: f32
    vy: f32
    health: i32
    alive: bool
    kind: i32
    hop: i32
    squash: i32
    color: u32
}

struct Spring {
    x: f32
    y: f32
}

struct Checkpoint {
    x: f32
    y: f32
    reached: bool
}

struct Goal {
    x: f32
    y: f32
}

static coins:   [32]Coin = undefined
static enemies: [16]Enemy = undefined
static springs: [8]Spring = undefined
static checks:  [4]Checkpoint = undefined
static goal: Goal = undefined

static num_coins:   i32 = 0
static num_enemies: i32 = 0
static num_springs: i32 = 0
static num_checks:  i32 = 0
}
}

# ── Game state (static) ──────────────────────────────────────────────────────

proc codegen::platformer::_gamestate_block {} {
    return {-- ── Game state ───────────────────────────────────────────────────────────────
enum Phase: u8 { title, playing, paused, levelclear, gameover, win }

struct Player {
    x: f32
    y: f32
    vx: f32
    vy: f32
    health: i32
    on_ground: bool
    on_ladder: bool
    coyote: i32
    jump_buf: i32
    invuln: i32
    facing: i32
    spawn_x: f32
    spawn_y: f32
}

struct GameState {
    phase: Phase
    player: Player
    score: i32
    coins: i32
    lives: i32
    cam_x: i32
    cam_y: i32
    level: i32
    frame: i32
    menu_sel: i32
    hi_score: i32
    best_stage: i32
}

static gs: GameState = undefined
}
}

# ── Save / load (static) ─────────────────────────────────────────────────────

proc codegen::platformer::_save_block {doc} {
    if {![_save_on $doc]} {
        return {-- ── Save / load (disabled: save_type = none) ────────────────────────────────
fn save_present() -> bool { return false }

fn load_hi() -> i32 { return 0 }

fn save_hi(score: i32) { }
}
    }
    return {-- ── EEPROM save / load (high score + best stage) ─────────────────────────────
@aligned(16)
static save_buf: [8]u8 = undefined

fn save_present() -> bool {
    return eeprom.present()
}

-- Reads the save block; sets gs.best_stage and returns the stored high score.
fn load_hi() -> i32 {
    if not save_present() { return 0 }
    eeprom.read(SAVE_BLOCK, &save_buf[0])
    if save_buf[0] != SAVE_MAGIC_HI { return 0 }
    if save_buf[1] != SAVE_MAGIC_LO { return 0 }
    gs.best_stage = save_buf[6] as i32
    return (save_buf[2] as i32 << 24)
         | (save_buf[3] as i32 << 16)
         | (save_buf[4] as i32 << 8)
         |  save_buf[5] as i32
}

fn save_hi(score: i32) {
    if not save_present() { return }
    save_buf[0] = SAVE_MAGIC_HI
    save_buf[1] = SAVE_MAGIC_LO
    save_buf[2] = (score >> 24) as u8
    save_buf[3] = (score >> 16) as u8
    save_buf[4] = (score >> 8) as u8
    save_buf[5] = score as u8
    save_buf[6] = gs.best_stage as u8
    save_buf[7] = 0
    eeprom.write(SAVE_BLOCK, &save_buf[0])
}
}
}

# ── Spawn helpers (static) ───────────────────────────────────────────────────

proc codegen::platformer::_spawn_block {} {
    return {-- ── Entity spawn helpers ─────────────────────────────────────────────────────
fn spawn_coin(x: i32, y: i32) {
    if num_coins >= MAX_COINS { return }
    coins[num_coins] = Coin { x: (x * TILE_SZ) as f32, y: (y * TILE_SZ) as f32, active: true }
    num_coins += 1
}

fn spawn_enemy(x: i32, y: i32, kind: i32) {
    let c: u32 = 0xFF4488FF
    if kind == 1 { c = 0xFF8844FF }
    if num_enemies >= MAX_ENEMIES { return }
    enemies[num_enemies] = Enemy {
        x: (x * TILE_SZ) as f32, y: (y * TILE_SZ) as f32,
        vx: 1.2, vy: 0.0, health: 1, alive: true,
        kind: kind, hop: 0, squash: 0, color: c,
    }
    num_enemies += 1
}

fn spawn_spring(x: i32, y: i32) {
    if num_springs >= MAX_SPRINGS { return }
    springs[num_springs] = Spring { x: (x * TILE_SZ) as f32, y: (y * TILE_SZ) as f32 }
    num_springs += 1
}

fn spawn_check(x: i32, y: i32) {
    if num_checks >= MAX_CHECKS { return }
    checks[num_checks] = Checkpoint { x: (x * TILE_SZ) as f32, y: (y * TILE_SZ) as f32, reached: false }
    num_checks += 1
}
}
}

# ── Level loading (data-driven entity spawns) ────────────────────────────────

proc codegen::platformer::_load_level {doc} {
    set lvls [dict get $doc levels]
    set lines {}
    lappend lines "fn load_level(level: i32) \{"
    lappend lines "    num_coins = 0"
    lappend lines "    num_enemies = 0"
    lappend lines "    num_springs = 0"
    lappend lines "    num_checks = 0"
    lappend lines "    gs.player.spawn_x = 32.0"
    lappend lines "    gs.player.spawn_y = 96.0"
    lappend lines "    goal = Goal { x: 100000.0, y: 0.0 }"

    set li 0
    foreach lvl $lvls {
        set W [dict get $lvl width]
        set H [dict get $lvl height]
        set objs [dict get $lvl objects]

        # Defaults derived from the level if no explicit object is placed.
        set spawn_px [expr {2 * 16}]
        set spawn_py [expr {($H - 2) * 16 - 4}]
        set goal_px  [expr {($W - 2) * 16}]
        set goal_py  [expr {($H - 3) * 16}]
        set spawns {}
        set have_goal 0

        foreach obj $objs {
            set ox [dict get $obj x]
            set oy [dict get $obj y]
            switch [dict get $obj type] {
                player_start {
                    set spawn_px [expr {$ox * 16}]
                    set spawn_py [expr {$oy * 16 - 4}]
                }
                coin          { lappend spawns "        spawn_coin($ox, $oy)" }
                enemy_patrol  { lappend spawns "        spawn_enemy($ox, $oy, 0)" }
                enemy_jumper  { lappend spawns "        spawn_enemy($ox, $oy, 1)" }
                spring        { lappend spawns "        spawn_spring($ox, $oy)" }
                checkpoint    { lappend spawns "        spawn_check($ox, $oy)" }
                door -
                goal {
                    set goal_px [expr {$ox * 16}]
                    set goal_py [expr {$oy * 16}]
                    set have_goal 1
                }
            }
        }

        lappend lines "    if level == $li \{"
        lappend lines "        gs.player.spawn_x = ${spawn_px}.0"
        lappend lines "        gs.player.spawn_y = ${spawn_py}.0"
        foreach s $spawns { lappend lines $s }
        lappend lines "        goal = Goal \{ x: ${goal_px}.0, y: ${goal_py}.0 \}"
        lappend lines "    \}"
        incr li
    }

    lappend lines "    gs.player.x = gs.player.spawn_x"
    lappend lines "    gs.player.y = gs.player.spawn_y"
    lappend lines "    gs.player.vx = 0.0"
    lappend lines "    gs.player.vy = 0.0"
    lappend lines "    gs.player.on_ground = false"
    lappend lines "    gs.player.on_ladder = false"
    lappend lines "    gs.player.coyote = 0"
    lappend lines "    gs.player.jump_buf = 0"
    lappend lines "    gs.player.invuln = 0"
    lappend lines "    gs.player.facing = 1"
    lappend lines "    gs.cam_x = 0"
    lappend lines "    gs.cam_y = 0"
    lappend lines "\}"
    return [join $lines "\n"]
}

# ── Player update (static) ───────────────────────────────────────────────────

proc codegen::platformer::_player_block {doc} {
    set run [_run_held_expr $doc]
    if {$run eq ""} {
        set runline ""
    } else {
        set runline "    if $run { spd = MOVE_SPEED * RUN_MULT }\n"
    }
    set tmpl {-- ── Player ───────────────────────────────────────────────────────────────────
fn hurt_player() {
    if gs.player.invuln > 0 { return }
    if gs.player.health > 0 { gs.player.health -= 1 }
    gs.player.invuln = INVULN_F
    sfx_hurt()
    if gs.player.health <= 0 {
        gs.lives -= 1
        if gs.lives <= 0 {
            gs.phase = Phase.gameover
            music_stop()
        } else {
            gs.player.health = 3
            gs.player.x = gs.player.spawn_x
            gs.player.y = gs.player.spawn_y
            gs.player.vx = 0.0
            gs.player.vy = 0.0
        }
    }
}

fn player_update(pad: joypad_status_t) {
    let lvl: i32 = gs.level

    if gs.player.invuln > 0 { gs.player.invuln -= 1 }

    let cx: i32 = gs.player.x as i32 + PLAYER_W / 2
    let cy: i32 = gs.player.y as i32 + PLAYER_H / 2
    let on_lad: bool = is_ladder(tile_at(lvl, cx / TILE_SZ, cy / TILE_SZ))
    gs.player.on_ladder = on_lad and (@@UP@@ or @@DOWN@@)

    gs.player.vx = 0.0
    let spd: f32 = MOVE_SPEED
@@RUNLINE@@    if @@LEFT@@  { gs.player.vx = -spd; gs.player.facing = -1 }
    if @@RIGHT@@ { gs.player.vx =  spd; gs.player.facing =  1 }

    if gs.player.on_ladder {
        gs.player.vy = 0.0
        if @@UP@@   { gs.player.vy = -CLIMB_SPEED }
        if @@DOWN@@ { gs.player.vy =  CLIMB_SPEED }
    } else {
        if gs.player.jump_buf > 0 { gs.player.jump_buf -= 1 }
        if @@JUMP@@ { gs.player.jump_buf = JUMP_BUF_F }

        if gs.player.on_ground {
            gs.player.coyote = COYOTE_F
        } elif gs.player.coyote > 0 {
            gs.player.coyote -= 1
        }

        if gs.player.jump_buf > 0 and gs.player.coyote > 0 {
            gs.player.vy = JUMP_FORCE
            gs.player.jump_buf = 0
            gs.player.coyote = 0
            sfx_jump()
        }

        gs.player.vy += GRAVITY
        if gs.player.vy > MAX_FALL { gs.player.vy = MAX_FALL }
    }

    gs.player.x += gs.player.vx
    let pix: i32 = gs.player.x as i32
    let piy: i32 = gs.player.y as i32
    if gs.player.vx > 0.0 {
        if solid_at(lvl, pix + PLAYER_W, piy + 4) or solid_at(lvl, pix + PLAYER_W, piy + PLAYER_H - 2) {
            gs.player.x = ((pix + PLAYER_W) / TILE_SZ * TILE_SZ - PLAYER_W) as f32
            gs.player.vx = 0.0
        }
    }
    if gs.player.vx < 0.0 {
        if solid_at(lvl, pix, piy + 4) or solid_at(lvl, pix, piy + PLAYER_H - 2) {
            gs.player.x = ((pix / TILE_SZ + 1) * TILE_SZ) as f32
            gs.player.vx = 0.0
        }
    }

    gs.player.y += gs.player.vy
    pix = gs.player.x as i32
    piy = gs.player.y as i32
    gs.player.on_ground = false

    if gs.player.vy >= 0.0 {
        let feet: i32 = piy + PLAYER_H
        let hit_solid: bool = solid_at(lvl, pix + 2, feet) or solid_at(lvl, pix + PLAYER_W - 2, feet)
        let t_left: u8 = tile_at(lvl, (pix + 2) / TILE_SZ, feet / TILE_SZ)
        let t_right: u8 = tile_at(lvl, (pix + PLAYER_W - 2) / TILE_SZ, feet / TILE_SZ)
        let hit_oneway: bool = is_oneway(t_left) or is_oneway(t_right)
        let oneway_land: bool = hit_oneway and (feet % TILE_SZ < 6) and (not @@DOWN@@)
        if hit_solid or oneway_land {
            gs.player.y = (feet / TILE_SZ * TILE_SZ - PLAYER_H) as f32
            gs.player.vy = 0.0
            gs.player.on_ground = true
        }
    }
    if gs.player.vy < 0.0 {
        if solid_at(lvl, pix + 2, piy) or solid_at(lvl, pix + PLAYER_W - 2, piy) {
            gs.player.y = ((piy / TILE_SZ + 1) * TILE_SZ) as f32
            gs.player.vy = 0.0
        }
    }

    if is_hazard(tile_at(lvl, (pix + PLAYER_W / 2) / TILE_SZ, (piy + PLAYER_H / 2) / TILE_SZ)) {
        hurt_player()
    }

    if gs.player.y > (level_h(lvl) * TILE_SZ + 32) as f32 {
        hurt_player()
        gs.player.y = gs.player.spawn_y
        gs.player.x = gs.player.spawn_x
        gs.player.vy = 0.0
    }

    let si: i32 = 0
    while si < num_springs {
        let dx: i32 = math.abs_i32(springs[si].x as i32 - gs.player.x as i32)
        let dy: i32 = math.abs_i32(springs[si].y as i32 - gs.player.y as i32)
        if dx < 14 and dy < 16 and gs.player.vy >= 0.0 {
            gs.player.vy = SPRING_FORCE
            sfx_spring()
        }
        si += 1
    }

    let ki: i32 = 0
    while ki < num_checks {
        if not checks[ki].reached {
            let dx: i32 = math.abs_i32(checks[ki].x as i32 - gs.player.x as i32)
            let dy: i32 = math.abs_i32(checks[ki].y as i32 - gs.player.y as i32)
            if dx < 14 and dy < 16 {
                checks[ki].reached = true
                gs.player.spawn_x = checks[ki].x
                gs.player.spawn_y = checks[ki].y
                sfx_checkpoint()
                gs.score += 50
            }
        }
        ki += 1
    }

    let gdx: i32 = math.abs_i32(goal.x as i32 - gs.player.x as i32)
    let gdy: i32 = math.abs_i32(goal.y as i32 - gs.player.y as i32)
    if gdx < 16 and gdy < 20 {
        sfx_win()
        if gs.level + 1 >= NUM_LEVELS {
            gs.phase = Phase.win
            music_stop()
        } else {
            gs.phase = Phase.levelclear
        }
    }

    gs.cam_x = gs.player.x as i32 - SCREEN_W / 2
    if gs.cam_x < 0 { gs.cam_x = 0 }
    let max_cam: i32 = level_w(lvl) * TILE_SZ - SCREEN_W
    if max_cam < 0 { max_cam = 0 }
    if gs.cam_x > max_cam { gs.cam_x = max_cam }

    gs.cam_y = gs.player.y as i32 - SCREEN_H / 2
    if gs.cam_y < 0 { gs.cam_y = 0 }
    let max_cam_y: i32 = level_h(lvl) * TILE_SZ - SCREEN_H
    if max_cam_y < 0 { max_cam_y = 0 }
    if gs.cam_y > max_cam_y { gs.cam_y = max_cam_y }
}
}
    return [string map [list \
        @@RUNLINE@@ $runline \
        @@JUMP@@  [_jump_pressed_expr $doc] \
        @@LEFT@@  [_left_expr  $doc] \
        @@RIGHT@@ [_right_expr $doc] \
        @@UP@@    [_up_expr    $doc] \
        @@DOWN@@  [_down_expr  $doc] \
    ] $tmpl]
}

# ── Enemy + coin update (static) ─────────────────────────────────────────────

proc codegen::platformer::_enemy_block {} {
    return {-- ── Enemies & coins ──────────────────────────────────────────────────────────
fn enemies_update() {
    let lvl: i32 = gs.level
    let ei: i32 = 0
    while ei < num_enemies {
        if enemies[ei].alive {
            if enemies[ei].squash > 0 { enemies[ei].squash -= 1 }

            enemies[ei].x += enemies[ei].vx
            let ex: i32 = enemies[ei].x as i32
            let ey: i32 = enemies[ei].y as i32
            if enemies[ei].vx > 0.0 and solid_at(lvl, ex + 16, ey + 8) {
                enemies[ei].vx = -enemies[ei].vx
            }
            if enemies[ei].vx < 0.0 and solid_at(lvl, ex - 1, ey + 8) {
                enemies[ei].vx = -enemies[ei].vx
            }
            let foot_x: i32 = ex + 8
            if enemies[ei].vx > 0.0 { foot_x = ex + 16 }
            if enemies[ei].vx < 0.0 { foot_x = ex - 1 }
            if not solid_at(lvl, foot_x, ey + 20) {
                enemies[ei].vx = -enemies[ei].vx
            }

            if enemies[ei].kind == 1 {
                enemies[ei].vy += GRAVITY
                enemies[ei].y += enemies[ei].vy
                let ny: i32 = enemies[ei].y as i32
                if enemies[ei].vy >= 0.0 and solid_at(lvl, ex + 8, ny + 16) {
                    enemies[ei].y = (ny / TILE_SZ * TILE_SZ) as f32
                    enemies[ei].vy = 0.0
                    enemies[ei].hop += 1
                    if enemies[ei].hop >= 40 {
                        enemies[ei].vy = -6.0
                        enemies[ei].hop = 0
                    }
                }
            }

            let px: i32 = gs.player.x as i32
            let py: i32 = gs.player.y as i32
            let dx: i32 = math.abs_i32(ex - px)
            let dy: i32 = math.abs_i32(ey - py)
            if dx < 13 and dy < 14 {
                if py < ey and gs.player.vy > 0.0 {
                    enemies[ei].alive = false
                    enemies[ei].squash = 8
                    gs.player.vy = -5.0
                    gs.score += 200
                    sfx_stomp()
                } else {
                    hurt_player()
                }
            }
        }
        ei += 1
    }
}

fn coins_update() {
    let ci: i32 = 0
    while ci < num_coins {
        if coins[ci].active {
            let dx: i32 = math.abs_i32(coins[ci].x as i32 - gs.player.x as i32)
            let dy: i32 = math.abs_i32(coins[ci].y as i32 - gs.player.y as i32)
            if dx < 14 and dy < 14 {
                coins[ci].active = false
                gs.coins += 1
                gs.score += 100
                sfx_coin()
            }
        }
        ci += 1
    }
}
}
}

# ── Rendering helpers (sprite-aware) ─────────────────────────────────────────

# tile_color + render_world/_entities/_player are sprite-aware; HUD and menus
# are always procedural (they need the bitmap font). When no sprite is bound
# for a role, the emitted code is byte-identical to the proven procedural path.

proc codegen::platformer::_render_block {doc} {
    set out {}
    lappend out [_render_prefix]
    lappend out [_render_world $doc]
    lappend out [_render_entities $doc]
    lappend out [_render_player $doc]
    lappend out [_render_suffix]
    return [join $out "\n"]
}

proc codegen::platformer::_render_prefix {} {
    return {-- ── Rendering ────────────────────────────────────────────────────────────────
fn tile_color(t: u8) -> u32 {
    if t == T_SOLID { return 0x3A5070FF }
    if t == T_ONEWAY { return 0x55AA44FF }
    if t == T_HAZARD { return 0xCC2222FF }
    if t == T_LADDER { return 0x8A6030FF }
    return 0x000000FF
}
}
}

# render_world — background + tiles (sprite-aware via balanced templates).
proc codegen::platformer::_render_world {doc} {
    set tile_sprite 0
    foreach r {tile_solid tile_oneway tile_hazard tile_ladder} {
        if {[_has_sprite $doc $r]} { set tile_sprite 1 }
    }
    set bg_sprite [_has_sprite $doc background]

    if {!$tile_sprite && !$bg_sprite} {
        return {fn render_world() {
    let lvl: i32 = gs.level
    let w: i32 = level_w(lvl)
    let h: i32 = level_h(lvl)

    rdpq.set_mode_fill(0x102840FF)
    rdpq.fill_rectangle(0, 0, SCREEN_W, SCREEN_H / 2)
    rdpq.sync_pipe()
    rdpq.set_mode_fill(0x0D1828FF)
    rdpq.fill_rectangle(0, SCREEN_H / 2, SCREEN_W, SCREEN_H)
    rdpq.sync_pipe()

    let start_tx: i32 = gs.cam_x / TILE_SZ
    let end_tx: i32 = start_tx + SCREEN_W / TILE_SZ + 2
    if end_tx > w { end_tx = w }
    let start_ty: i32 = gs.cam_y / TILE_SZ
    let end_ty: i32 = start_ty + SCREEN_H / TILE_SZ + 2
    if end_ty > h { end_ty = h }

    let ty: i32 = start_ty
    while ty < end_ty {
        let tx: i32 = start_tx
        while tx < end_tx {
            let t: u8 = tile_at(lvl, tx, ty)
            if t != T_EMPTY {
                let sx: i32 = tx * TILE_SZ - gs.cam_x
                let sy: i32 = ty * TILE_SZ - gs.cam_y
                rdpq.set_fill_color(tile_color(t))
                rdpq.fill_rectangle(sx, sy, sx + TILE_SZ, sy + TILE_SZ)
            }
            tx += 1
        }
        ty += 1
    }
}}
    }

    if {$bg_sprite} {
        set bg "    rdpq.sync_pipe()\n    rdpq.set_mode_copy()\n    sprite.blit(spr_background, 0, 0, 0)\n    rdpq.sync_pipe()"
    } else {
        set bg "    rdpq.set_mode_fill(0x102840FF)\n    rdpq.fill_rectangle(0, 0, SCREEN_W, SCREEN_H / 2)\n    rdpq.sync_pipe()\n    rdpq.set_mode_fill(0x0D1828FF)\n    rdpq.fill_rectangle(0, SCREEN_H / 2, SCREEN_W, SCREEN_H)\n    rdpq.sync_pipe()"
    }

    set frags ""
    foreach {const role} {T_SOLID tile_solid T_ONEWAY tile_oneway T_HAZARD tile_hazard T_LADDER tile_ladder} {
        if {[_has_sprite $doc $role]} {
            append frags "    if t == $const \{\n        rdpq.sync_pipe()\n        rdpq.set_mode_copy()\n        sprite.blit(spr_$role, sx, sy, 0)\n        return\n    \}\n"
        }
    }

    set tmpl {fn draw_tile(t: u8, sx: i32, sy: i32) {
@@TILEBRANCHES@@    rdpq.sync_pipe()
    rdpq.set_mode_fill(tile_color(t))
    rdpq.fill_rectangle(sx, sy, sx + TILE_SZ, sy + TILE_SZ)
}

fn render_world() {
    let lvl: i32 = gs.level
    let w: i32 = level_w(lvl)
    let h: i32 = level_h(lvl)
@@BG@@
    let start_tx: i32 = gs.cam_x / TILE_SZ
    let end_tx: i32 = start_tx + SCREEN_W / TILE_SZ + 2
    if end_tx > w { end_tx = w }
    let start_ty: i32 = gs.cam_y / TILE_SZ
    let end_ty: i32 = start_ty + SCREEN_H / TILE_SZ + 2
    if end_ty > h { end_ty = h }
    let ty: i32 = start_ty
    while ty < end_ty {
        let tx: i32 = start_tx
        while tx < end_tx {
            let t: u8 = tile_at(lvl, tx, ty)
            if t != T_EMPTY {
                draw_tile(t, tx * TILE_SZ - gs.cam_x, ty * TILE_SZ - gs.cam_y)
            }
            tx += 1
        }
        ty += 1
    }
}}
    return [string map [list @@TILEBRANCHES@@ $frags @@BG@@ $bg] $tmpl]
}

# render_entities — coins/springs/checkpoints/goal/enemies (sprite-aware).
proc codegen::platformer::_render_entities {doc} {
    set any 0
    foreach r {coin spring checkpoint goal enemy_patrol enemy_jumper} {
        if {[_has_sprite $doc $r]} { set any 1 }
    }
    if {!$any} {
        return {fn render_entities() {
    rdpq.sync_pipe()
    rdpq.set_mode_fill(0xFFDD00FF)
    let ci: i32 = 0
    while ci < num_coins {
        if coins[ci].active {
            let sx: i32 = coins[ci].x as i32 - gs.cam_x
            let sy: i32 = coins[ci].y as i32 - gs.cam_y
            let bob: i32 = (gs.frame / 8 + ci) % 4 - 2
            rdpq.set_fill_color(0xFFDD00FF)
            rdpq.fill_rectangle(sx + 4, sy + 3 + bob, sx + 12, sy + 11 + bob)
        }
        ci += 1
    }
    let si: i32 = 0
    while si < num_springs {
        let sx: i32 = springs[si].x as i32 - gs.cam_x
        let sy: i32 = springs[si].y as i32 - gs.cam_y
        rdpq.set_fill_color(0x44CC88FF)
        rdpq.fill_rectangle(sx + 2, sy + 10, sx + 14, sy + 16)
        si += 1
    }
    let ki: i32 = 0
    while ki < num_checks {
        let sx: i32 = checks[ki].x as i32 - gs.cam_x
        let sy: i32 = checks[ki].y as i32 - gs.cam_y
        let col: u32 = 0x888888FF
        if checks[ki].reached { col = 0x00DDFFFF }
        rdpq.set_fill_color(col)
        rdpq.fill_rectangle(sx + 6, sy, sx + 10, sy + 16)
        ki += 1
    }
    let gx: i32 = goal.x as i32 - gs.cam_x
    let gy: i32 = goal.y as i32 - gs.cam_y
    rdpq.set_fill_color(0xFFFFFFFF)
    rdpq.fill_rectangle(gx + 7, gy - 16, gx + 9, gy + 16)
    rdpq.set_fill_color(0xFFCC00FF)
    rdpq.fill_rectangle(gx + 9, gy - 16, gx + 18, gy - 8)
    let eii: i32 = 0
    while eii < num_enemies {
        if enemies[eii].alive {
            let sx: i32 = enemies[eii].x as i32 - gs.cam_x
            let sy: i32 = enemies[eii].y as i32 - gs.cam_y
            rdpq.set_fill_color(enemies[eii].color)
            rdpq.fill_rectangle(sx, sy, sx + 14, sy + 14)
            rdpq.set_fill_color(0xFFFFFFFF)
            rdpq.fill_rectangle(sx + 3, sy + 3, sx + 6, sy + 6)
            rdpq.fill_rectangle(sx + 8, sy + 3, sx + 11, sy + 6)
        } elif enemies[eii].squash > 0 {
            let sx: i32 = enemies[eii].x as i32 - gs.cam_x
            let sy: i32 = enemies[eii].y as i32 - gs.cam_y
            rdpq.set_fill_color(enemies[eii].color)
            rdpq.fill_rectangle(sx, sy + 10, sx + 14, sy + 14)
        }
        eii += 1
    }
}}
    }

    if {[_has_sprite $doc coin]} {
        set coin {            rdpq.sync_pipe()
            rdpq.set_mode_copy()
            sprite.blit(spr_coin, sx, sy, 0)}
    } else {
        set coin {            let bob: i32 = (gs.frame / 8 + ci) % 4 - 2
            rdpq.sync_pipe()
            rdpq.set_mode_fill(0xFFDD00FF)
            rdpq.fill_rectangle(sx + 4, sy + 3 + bob, sx + 12, sy + 11 + bob)}
    }
    if {[_has_sprite $doc spring]} {
        set spring {        rdpq.sync_pipe()
        rdpq.set_mode_copy()
        sprite.blit(spr_spring, sx, sy, 0)}
    } else {
        set spring {        rdpq.sync_pipe()
        rdpq.set_mode_fill(0x44CC88FF)
        rdpq.fill_rectangle(sx + 2, sy + 10, sx + 14, sy + 16)}
    }
    if {[_has_sprite $doc checkpoint]} {
        set check {        rdpq.sync_pipe()
        rdpq.set_mode_copy()
        sprite.blit(spr_checkpoint, sx, sy, 0)}
    } else {
        set check {        let col: u32 = 0x888888FF
        if checks[ki].reached { col = 0x00DDFFFF }
        rdpq.sync_pipe()
        rdpq.set_mode_fill(col)
        rdpq.fill_rectangle(sx + 6, sy, sx + 10, sy + 16)}
    }
    if {[_has_sprite $doc goal]} {
        set goal {    rdpq.sync_pipe()
    rdpq.set_mode_copy()
    sprite.blit(spr_goal, gx, gy - 16, 0)}
    } else {
        set goal {    rdpq.sync_pipe()
    rdpq.set_mode_fill(0xFFFFFFFF)
    rdpq.fill_rectangle(gx + 7, gy - 16, gx + 9, gy + 16)
    rdpq.set_fill_color(0xFFCC00FF)
    rdpq.fill_rectangle(gx + 9, gy - 16, gx + 18, gy - 8)}
    }
    set ep [_has_sprite $doc enemy_patrol]
    set ej [_has_sprite $doc enemy_jumper]
    if {$ep && $ej} {
        set enemy {            rdpq.sync_pipe()
            rdpq.set_mode_copy()
            if enemies[eii].kind == 1 {
                sprite.blit(spr_enemy_jumper, sx, sy, 0)
            } else {
                sprite.blit(spr_enemy_patrol, sx, sy, 0)
            }}
    } elseif {$ep} {
        set enemy {            if enemies[eii].kind == 0 {
                rdpq.sync_pipe()
                rdpq.set_mode_copy()
                sprite.blit(spr_enemy_patrol, sx, sy, 0)
            } else {
                rdpq.sync_pipe()
                rdpq.set_mode_fill(enemies[eii].color)
                rdpq.fill_rectangle(sx, sy, sx + 14, sy + 14)
            }}
    } elseif {$ej} {
        set enemy {            if enemies[eii].kind == 1 {
                rdpq.sync_pipe()
                rdpq.set_mode_copy()
                sprite.blit(spr_enemy_jumper, sx, sy, 0)
            } else {
                rdpq.sync_pipe()
                rdpq.set_mode_fill(enemies[eii].color)
                rdpq.fill_rectangle(sx, sy, sx + 14, sy + 14)
            }}
    } else {
        set enemy {            rdpq.sync_pipe()
            rdpq.set_mode_fill(enemies[eii].color)
            rdpq.fill_rectangle(sx, sy, sx + 14, sy + 14)
            rdpq.set_fill_color(0xFFFFFFFF)
            rdpq.fill_rectangle(sx + 3, sy + 3, sx + 6, sy + 6)
            rdpq.fill_rectangle(sx + 8, sy + 3, sx + 11, sy + 6)}
    }

    set tmpl {fn render_entities() {
    let ci: i32 = 0
    while ci < num_coins {
        if coins[ci].active {
            let sx: i32 = coins[ci].x as i32 - gs.cam_x
            let sy: i32 = coins[ci].y as i32 - gs.cam_y
@@COIN@@
        }
        ci += 1
    }
    let si: i32 = 0
    while si < num_springs {
        let sx: i32 = springs[si].x as i32 - gs.cam_x
        let sy: i32 = springs[si].y as i32 - gs.cam_y
@@SPRING@@
        si += 1
    }
    let ki: i32 = 0
    while ki < num_checks {
        let sx: i32 = checks[ki].x as i32 - gs.cam_x
        let sy: i32 = checks[ki].y as i32 - gs.cam_y
@@CHECK@@
        ki += 1
    }
    let gx: i32 = goal.x as i32 - gs.cam_x
    let gy: i32 = goal.y as i32 - gs.cam_y
@@GOAL@@
    let eii: i32 = 0
    while eii < num_enemies {
        let sx: i32 = enemies[eii].x as i32 - gs.cam_x
        let sy: i32 = enemies[eii].y as i32 - gs.cam_y
        if enemies[eii].alive {
@@ENEMY@@
        } elif enemies[eii].squash > 0 {
            rdpq.sync_pipe()
            rdpq.set_mode_fill(enemies[eii].color)
            rdpq.fill_rectangle(sx, sy + 10, sx + 14, sy + 14)
        }
        eii += 1
    }
}}
    return [string map [list @@COIN@@ $coin @@SPRING@@ $spring @@CHECK@@ $check @@GOAL@@ $goal @@ENEMY@@ $enemy] $tmpl]
}

# render_player — sprite or procedural body.
proc codegen::platformer::_render_player {doc} {
    if {![_has_sprite $doc player]} {
        return {fn render_player() {
    if gs.player.invuln > 0 and (gs.frame / 3) % 2 == 0 { return }
    let sx: i32 = gs.player.x as i32 - gs.cam_x
    let sy: i32 = gs.player.y as i32 - gs.cam_y
    rdpq.sync_pipe()
    rdpq.set_mode_fill(0xFF4444FF)
    rdpq.fill_rectangle(sx + 2, sy + 4, sx + 10, sy + 15)
    rdpq.set_fill_color(0xFFCC99FF)
    rdpq.fill_rectangle(sx + 2, sy, sx + 10, sy + 5)
    rdpq.set_fill_color(0x000000FF)
    if gs.player.facing > 0 {
        rdpq.fill_rectangle(sx + 7, sy + 2, sx + 9, sy + 4)
    } else {
        rdpq.fill_rectangle(sx + 3, sy + 2, sx + 5, sy + 4)
    }
}
}
    }
    return {fn render_player() {
    if gs.player.invuln > 0 and (gs.frame / 3) % 2 == 0 { return }
    let sx: i32 = gs.player.x as i32 - gs.cam_x
    let sy: i32 = gs.player.y as i32 - gs.cam_y
    rdpq.sync_pipe()
    rdpq.set_mode_copy()
    sprite.blit(spr_player, sx, sy, 0)
}
}
}

proc codegen::platformer::_render_suffix {} {
    return {fn render_hud() {
    rdpq.sync_pipe()
    rdpq.set_mode_fill(0x000000AA)
    rdpq.fill_rectangle(0, 0, SCREEN_W, 16)
    rdpq.sync_pipe()
    draw_text("SCORE", 4, 4, 1, 0xFFFFFFFF)
    draw_number(gs.score, 30, 4, 1, 0xFFDD00FF)
    draw_text("COINS", 110, 4, 1, 0xFFFFFFFF)
    draw_number(gs.coins, 136, 4, 1, 0xFFDD00FF)
    draw_text("LIVES", 200, 4, 1, 0xFFFFFFFF)
    draw_number(gs.lives, 226, 4, 1, 0xFF4444FF)
    draw_text("L", 292, 4, 1, 0xFFFFFFFF)
    draw_number(gs.level + 1, 300, 4, 1, 0x88FF88FF)
    rdpq.sync_pipe()
    rdpq.set_mode_fill(0xFF2222FF)
    let hi: i32 = 0
    while hi < gs.player.health {
        rdpq.fill_rectangle(252 + hi * 8, 4, 258 + hi * 8, 12)
        hi += 1
    }
}

fn render_pause() {
    render_world()
    render_entities()
    render_player()
    render_hud()
    rdpq.sync_pipe()
    rdpq.set_fill_color(0x000000CC)
    rdpq.fill_rectangle(80, 70, 240, 170)
    rdpq.sync_pipe()
    draw_text_centered("PAUSED", SCREEN_W / 2, 84, 2, 0xFFFFFFFF)
    let c0: u32 = 0x888888FF
    let c1: u32 = 0x888888FF
    if gs.menu_sel == 0 { c0 = 0xFFDD00FF }
    if gs.menu_sel == 1 { c1 = 0xFFDD00FF }
    draw_text_centered("RESUME", SCREEN_W / 2, 116, 1, c0)
    draw_text_centered("QUIT", SCREEN_W / 2, 136, 1, c1)
}

fn render_levelclear() {
    rdpq.set_mode_fill(0x0D2818FF)
    rdpq.fill_rectangle(0, 0, SCREEN_W, SCREEN_H)
    rdpq.sync_pipe()
    draw_text_centered("LEVEL CLEAR", SCREEN_W / 2, 80, 2, 0x44FF88FF)
    draw_text("STAGE", 120, 120, 1, 0xFFFFFFFF)
    draw_number(gs.level + 1, 152, 120, 1, 0xFFDD00FF)
    draw_text_centered("PRESS START", SCREEN_W / 2, 160, 1, 0xFFFFFFFF)
}

fn render_gameover() {
    rdpq.set_mode_fill(0x280D0DFF)
    rdpq.fill_rectangle(0, 0, SCREEN_W, SCREEN_H)
    rdpq.sync_pipe()
    draw_text_centered("GAME OVER", SCREEN_W / 2, 80, 3, 0xFF4444FF)
    draw_text("SCORE", 110, 130, 1, 0xFFFFFFFF)
    draw_number(gs.score, 140, 130, 1, 0xFFDD00FF)
    draw_text_centered("PRESS START", SCREEN_W / 2, 170, 1, 0xFFFFFFFF)
}

fn render_win() {
    rdpq.set_mode_fill(0x0D1828FF)
    rdpq.fill_rectangle(0, 0, SCREEN_W, SCREEN_H)
    rdpq.sync_pipe()
    draw_text_centered("YOU WIN", SCREEN_W / 2, 70, 3, 0xFFDD00FF)
    draw_text("SCORE", 110, 130, 1, 0xFFFFFFFF)
    draw_number(gs.score, 140, 130, 1, 0xFFDD00FF)
    draw_text_centered("PRESS START", SCREEN_W / 2, 170, 1, 0xFFFFFFFF)
}
}
}

# ── Title render (data-driven game name) ─────────────────────────────────────

proc codegen::platformer::_render_title {doc} {
    set name [string toupper [dict get $doc meta name]]
    # Sanitise to the font's supported glyphs (A-Z, 0-9, space, : - . !).
    regsub -all {[^A-Z0-9 :.!-]} $name " " name
    set name [string range $name 0 19]
    return "fn render_title() \{
    rdpq.set_mode_fill(0x0A1020FF)
    rdpq.fill_rectangle(0, 0, SCREEN_W, SCREEN_H)
    rdpq.sync_pipe()
    -- animated parallax starfield (asset-free)
    let ph: i32 = gs.frame % SCREEN_W
    let i: i32 = 0
    while i < 48 \{
        let sx: i32 = (i * 71 + 13 + (SCREEN_W - ph) * (1 + i % 3)) % SCREEN_W
        let sy: i32 = (i * 37 + i * i * 7) % SCREEN_H
        if (gs.frame / 4 + i) % 8 < 5 \{
            rdpq.set_fill_color(0xFFFFFFFF)
            rdpq.fill_rectangle(sx, sy, sx + 1 + i % 2, sy + 1 + i % 2)
        \}
        i += 1
    \}
    rdpq.sync_pipe()
    draw_text_centered(\"$name\", SCREEN_W / 2, 60, 2, 0xFFDD00FF)
    draw_text_centered(\"A PAK GAME\", SCREEN_W / 2, 100, 1, 0x88AAFFFF)
    if (gs.frame / 20) % 2 == 0 \{
        draw_text_centered(\"PRESS START\", SCREEN_W / 2, 150, 2, 0xFFFFFFFF)
    \}
    draw_text(\"HI\", 110, 195, 1, 0xFFFFFFFF)
    draw_number(gs.hi_score, 124, 195, 1, 0xFFDD00FF)
    if gs.best_stage > 0 \{
        draw_text(\"BEST STAGE\", 110, 210, 1, 0x88FF88FF)
        draw_number(gs.best_stage, 180, 210, 1, 0x88FF88FF)
    \}
\}
"
}

# ── Render dispatch (static) ─────────────────────────────────────────────────

proc codegen::platformer::_render_dispatch {} {
    return {fn render() {
    let fb = display.get()
    rdpq.attach_clear(fb)
    match gs.phase {
        .title      => { render_title() }
        .playing    => { render_world(); render_entities(); render_player(); render_hud() }
        .paused     => { render_pause() }
        .levelclear => { render_levelclear() }
        .gameover   => { render_gameover() }
        .win        => { render_win() }
    }
    rdpq.detach_show()
}
}
}

# ── Update dispatch (static) ─────────────────────────────────────────────────

proc codegen::platformer::_update_block {} {
    return {-- ── Update ───────────────────────────────────────────────────────────────────
fn start_game() {
    gs.score = 0
    gs.coins = 0
    gs.lives = 3
    gs.level = 0
    gs.player.health = 3
    if gs.best_stage < 1 { gs.best_stage = 1 }
    load_level(0)
    gs.phase = Phase.playing
    music_start()
}

fn update(pad: joypad_status_t) {
    match gs.phase {
        .title => {
            if pad.pressed.start or pad.pressed.a { start_game() }
        }
        .playing => {
            player_update(pad)
            enemies_update()
            coins_update()
            if pad.pressed.start {
                gs.phase = Phase.paused
                gs.menu_sel = 0
            }
        }
        .paused => {
            if pad.pressed.up or pad.pressed.down {
                gs.menu_sel = 1 - gs.menu_sel
            }
            if pad.pressed.a or pad.pressed.start {
                if gs.menu_sel == 0 {
                    gs.phase = Phase.playing
                } else {
                    gs.phase = Phase.title
                    music_stop()
                }
            }
        }
        .levelclear => {
            if pad.pressed.start or pad.pressed.a {
                gs.level += 1
                if gs.level + 1 > gs.best_stage { gs.best_stage = gs.level + 1 }
                load_level(gs.level)
                gs.player.health = 3
                gs.phase = Phase.playing
            }
        }
        .gameover => {
            if pad.pressed.start or pad.pressed.a {
                if gs.score > gs.hi_score { gs.hi_score = gs.score }
                save_hi(gs.hi_score)
                gs.phase = Phase.title
            }
        }
        .win => {
            if pad.pressed.start or pad.pressed.a {
                if gs.score > gs.hi_score { gs.hi_score = gs.score }
                save_hi(gs.hi_score)
                gs.phase = Phase.title
            }
        }
    }
    gs.frame += 1
}
}
}

# ── Entry (static) ───────────────────────────────────────────────────────────

proc codegen::platformer::_entry_block {doc} {
    if {[_save_on $doc]} {
        set eeprom_init "    eeprom.init()\n"
    } else {
        set eeprom_init ""
    }
    set tmpl {-- ── Entry ────────────────────────────────────────────────────────────────────
entry {
    display.init(0, 2, 3, 0, 1)
    rdpq.init()
    controller.init()
    timer.init()
@@EEPROMINIT@@
    defer { rdpq.close() }

    init_font()
    snd_init()

    gs.phase = Phase.title
    gs.frame = 0
    gs.menu_sel = 0
    gs.score = 0
    gs.coins = 0
    gs.lives = 3
    gs.level = 0
    gs.best_stage = 0
    gs.hi_score = load_hi()
    gs.player.health = 3
    gs.player.spawn_x = 32.0
    gs.player.spawn_y = 96.0
    gs.player.x = 32.0
    gs.player.y = 96.0
    gs.player.facing = 1

    loop {
        fill_audio()
        controller.poll()
        let pad = controller.read(0)
        update(pad)
        render()
    }
}
}
    return [string map [list @@EEPROMINIT@@ $eeprom_init] $tmpl]
}
