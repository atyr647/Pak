# codegen/racer.tcl — .pakstudio → N64 rally racing game (.pk64 + pak.toml)
#
# Generates a full T3D rally game from the project doc:
#   • t3d.look_at   — smooth look-at chase camera
#   • t3d.fog_set_* — atmospheric fog
#   • n64.math      — sin/cos/lerp for proper 3D physics
#   • T3DVec3       — camera math
#   • Rally drift   — lateral velocity + handbrake
#   • 2-light shading (warm sun + cool sky fill)
#
# Track waypoints come from doc.levels[0].waypoints.
# Physics constants come from doc.physics.
# Models loaded from doc.assets.sprites (model_* roles → .t3dm).

namespace eval codegen::racer {}

proc codegen::racer::generate {doc} {
    return [dict create \
        "pak.toml"      [_pak_toml $doc] \
        "src/main.pk64" [_main_pk64 $doc] \
    ]
}

# ── pak.toml ──────────────────────────────────────────────────────────────────

proc codegen::racer::_pak_toml {doc} {
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

\[dependencies\]
-- Uncomment when Tiny3D is installed (TINY3D_INST must be set):
-- tiny3d = true
"
}

# ── Physics helpers ───────────────────────────────────────────────────────────

proc codegen::racer::_phys {doc key default} {
    if {[dict exists $doc physics $key]} {
        return [dict get $doc physics $key]
    }
    return $default
}

proc codegen::racer::_f32 {v} {
    if {[string first "." $v] < 0} { return "${v}.0" }
    return $v
}

# ── Track / waypoint helpers ──────────────────────────────────────────────────

proc codegen::racer::_waypoints {doc} {
    if {[dict exists $doc levels] && [llength [dict get $doc levels]] > 0} {
        set lvl [lindex [dict get $doc levels] 0]
        if {[dict exists $lvl waypoints]} {
            return [dict get $lvl waypoints]
        }
    }
    return [list \
        {x  0.0  z -70.0  width 14.0} \
        {x 40.0  z -48.0  width 11.0} \
        {x 68.0  z -10.0  width 10.0} \
        {x 72.0  z  28.0  width  9.0} \
        {x 50.0  z  62.0  width  8.0} \
        {x 10.0  z  72.0  width 10.0} \
        {x -35.0 z  58.0  width 10.0} \
        {x -68.0 z  20.0  width  9.0} \
        {x -72.0 z -18.0  width  9.0} \
        {x -50.0 z -55.0  width 11.0} \
    ]
}

proc codegen::racer::_num_laps {doc} {
    if {[dict exists $doc physics num_laps]} { return [dict get $doc physics num_laps] }
    return 3
}

proc codegen::racer::_ai_count {doc} {
    if {[dict exists $doc physics ai_count]} { return [dict get $doc physics ai_count] }
    return 3
}

# ── Asset helpers ─────────────────────────────────────────────────────────────

proc codegen::racer::_has_audio {doc role} {
    expr {[dict exists $doc assets audio $role]
          && [dict get $doc assets audio $role] ne ""}
}

proc codegen::racer::_has_model {doc role} {
    expr {[dict exists $doc assets sprites $role]
          && [dict get $doc assets sprites $role] ne ""}
}

# ── Main source file ──────────────────────────────────────────────────────────

proc codegen::racer::_main_pk64 {doc} {
    set wps   [_waypoints $doc]
    set nwp   [llength $wps]
    set nlaps [_num_laps $doc]
    set nai   [_ai_count $doc]
    set ncars [expr {$nai + 1}]

    set accel    [_f32 [_phys $doc accel_rate  22.0]]
    set brake    [_f32 [_phys $doc brake_rate  35.0]]
    set maxspd   [_f32 [_phys $doc max_speed   50.0]]
    set steer    [_f32 [_phys $doc steer_rate   2.6]]
    set friction [_f32 [_phys $doc friction     0.964]]
    set gravity  [_f32 [_phys $doc gravity    -20.0]]

    set has_bgm    [_has_audio $doc bgm]
    set has_engine [_has_audio $doc sfx_engine]
    set has_crash  [_has_audio $doc sfx_crash]
    set has_lap    [_has_audio $doc lap_complete]

    set MAX_CARS [expr {max($ncars, 2)}]

    # ── Waypoint initialiser ──────────────────────────────────────────────────
    set wp_lines {}
    set wi 0
    foreach wp $wps {
        set x [_f32 [dict get $wp x]]
        set z [_f32 [dict get $wp z]]
        set w [_f32 [dict get $wp width]]
        lappend wp_lines "    waypoints\[$wi\].x = $x"
        lappend wp_lines "    waypoints\[$wi\].z = $z"
        lappend wp_lines "    waypoints\[$wi\].w = $w"
        incr wi
    }
    set wp_block [join $wp_lines "\n"]

    # ── Audio statics + opens ─────────────────────────────────────────────────
    set audio_statics {}
    set audio_open {}
    set extern_audio {}
    if {$has_engine || $has_crash || $has_lap} {
        lappend extern_audio "    fn wav64_open(wav: *wav64_t, path: *c_char)"
        lappend extern_audio "    fn wav64_play(wav: *wav64_t, channel: i32)"
    }
    if {$has_bgm} {
        lappend extern_audio "    fn xm64player_open(xm: *xm64player_t, path: *c_char)"
        lappend extern_audio "    fn xm64player_play(xm: *xm64player_t, first_ch: i32)"
    }
    if {$has_engine} {
        lappend audio_statics "static sfx_engine: wav64_t = undefined"
        lappend audio_open    "    wav64_open(&sfx_engine, \"rom:/sfx/sfx_engine.wav64\")"
    }
    if {$has_crash} {
        lappend audio_statics "static sfx_crash: wav64_t = undefined"
        lappend audio_open    "    wav64_open(&sfx_crash, \"rom:/sfx/sfx_crash.wav64\")"
    }
    if {$has_lap} {
        lappend audio_statics "static sfx_lap: wav64_t = undefined"
        lappend audio_open    "    wav64_open(&sfx_lap, \"rom:/sfx/lap_complete.wav64\")"
    }
    if {$has_bgm} {
        lappend audio_statics "static bgm: xm64player_t = undefined"
        lappend audio_open    "    xm64player_open(&bgm, \"rom:/music/bgm.xm64\")"
        lappend audio_open    "    xm64player_play(&bgm, 0)"
    }
    set audio_static_block [join $audio_statics "\n"]
    set audio_block        [join $audio_open    "\n"]
    set extern_audio_block [join $extern_audio  "\n"]

    # ── Model load block ──────────────────────────────────────────────────────
    set model_lines {}
    if {[_has_model $doc model_track]} {
        lappend model_lines "    track_model = t3d.model_load(\"rom:/models/model_track.t3dm\")"
    }
    for {set i 0} {$i < $ncars} {incr i} {
        set role "model_car_[expr {$i+1}]"
        if {[_has_model $doc $role]} {
            lappend model_lines "    car_model\[$i\] = t3d.model_load(\"rom:/models/${role}.t3dm\")"
        }
    }
    set model_block [join $model_lines "\n"]

    # ── AI throttle assignments ───────────────────────────────────────────────
    set ai_throttles {}
    for {set i 1} {$i < $ncars} {incr i} {
        set th [format "%.2f" [expr {0.76 + $i * 0.05}]]
        lappend ai_throttles "                    let th${i}: f32 = ${th}f32"
        lappend ai_throttles "                    ai_update(&cars\[$i\], dt, th${i})"
        lappend ai_throttles "                    advance_waypoints(&cars\[$i\])"
    }
    set ai_block [join $ai_throttles "\n"]

    # ── Starting grid Z offsets ───────────────────────────────────────────────
    set start_z [_f32 [lindex [split [lindex $wps 0] "z"] end]]
    # extract first waypoint z
    set wp0 [lindex $wps 0]
    if {[dict exists $wp0 z]} {
        set sz [_f32 [dict get $wp0 z]]
    } else {
        set sz "-70.0"
    }

    return "-- src/main.pk64 — generated by PakStudio (3D Racer)
-- $ncars cars  |  $nwp waypoints  |  $nlaps laps
-- Full T3D pipeline: t3d.look_at camera, fog, 2-light shading, rally drift

use n64.display
use n64.controller
use n64.rdpq
use n64.timer
use n64.audio
use n64.mixer
use n64.math
use t3d

extern \"C\" {
    fn rdpq_mode_push()
    fn rdpq_mode_pop()
    fn rdpq_text_printf(x: i32, y: i32, font: i32, fmt: *c_char, ...) -> i32
${extern_audio_block}
}

extern \"C\" {
    fn t3d_matrix_push(mat: *T3DMat4FP)
    fn t3d_matrix_pop(count: i32)
    fn t3d_mat4fp_from_srt_euler(mat: *T3DMat4FP, scale: *f32, rot: *f32, translate: *f32)
}

-- ============================================================
-- Constants
-- ============================================================
const MAX_CARS:  i32 = $MAX_CARS
const NUM_WP:    i32 = $nwp
const MAX_LAPS:  i32 = $nlaps

const ACCEL:     f32 = $accel
const BRAKE_RATE: f32 = $brake
const MAX_SPEED: f32 = $maxspd
const STEER_RATE: f32 = $steer
const FRICTION:  f32 = $friction

const LAT_GRIP:    f32 = 0.87
const LAT_GRIP_HB: f32 = 0.52

-- Chase camera
const CAM_DIST:   f32 = 14.0
const CAM_HEIGHT: f32 = 5.5
const CAM_AHEAD:  f32 = 6.0
const CAM_SMOOTH: f32 = 5.5

-- Boost
const BOOST_SPEED: f32 = 18.0
const BOOST_COST:  f32 = 0.3
const BOOST_REGEN: f32 = 0.12

-- ============================================================
-- Types
-- ============================================================
enum RaceState { countdown, racing, finished, results }
enum CarState  { normal_driving, spinning }

struct Waypoint {
    x: f32
    z: f32
    w: f32
}

struct LapTime {
    total_ms: i32
    lap_ms:   i32
    best_ms:  i32
}

struct Car {
    x:       f32
    y:       f32
    z:       f32
    vx:      f32
    vz:      f32
    heading: f32
    speed:   f32
    lat_v:   f32
    active:   bool
    is_player: bool
    grounded: bool
    car_state: CarState
    spin_timer: f32
    lap:      i32
    next_wp:  i32
    progress: i32
    place:    i32
    times:    LapTime
    boost:    f32
    boost_cd: f32
}

-- ============================================================
-- Globals
-- ============================================================
static race_state: RaceState = RaceState.countdown
static countdown:  f32 = 3.0
static race_ms:    i32 = 0

static cars:      \[Car;      $MAX_CARS\] = undefined
static waypoints: \[Waypoint; $nwp\]     = undefined
static wp_count:  i32 = 0

-- Smooth-follow camera state
static cam_ex: f32 = 0.0
static cam_ey: f32 = 6.0
static cam_ez: f32 = -94.0

-- T3D
static vp:          T3DViewport = undefined
static track_model: *T3DModel   = none
static car_model:   \[*T3DModel; $MAX_CARS\] = undefined
static car_fp:      \[*T3DMat4FP; $MAX_CARS\] = undefined

${audio_static_block}

-- ============================================================
-- Track waypoints
-- ============================================================
fn init_waypoints() {
${wp_block}
    wp_count = $nwp
}

-- ============================================================
-- Car initialisation
-- ============================================================
fn init_cars() {
    let i: i32 = 0
    loop {
        if i >= MAX_CARS { break }
        cars\[i\].active    = true
        cars\[i\].is_player = (i == 0)
        cars\[i\].x  = (i as f32) * 5.5 - 8.0
        cars\[i\].y  = 0.5
        cars\[i\].z  = ${sz} - (i % 2) as f32 * 5.0
        cars\[i\].vx = 0.0
        cars\[i\].vz = 0.0
        cars\[i\].speed    = 0.0
        cars\[i\].heading  = 0.0
        cars\[i\].lat_v    = 0.0
        cars\[i\].grounded = true
        cars\[i\].car_state  = CarState.normal_driving
        cars\[i\].spin_timer = 0.0
        cars\[i\].lap     = 0
        cars\[i\].next_wp = 0
        cars\[i\].progress = 0
        cars\[i\].place   = i + 1
        cars\[i\].times.total_ms = 0
        cars\[i\].times.lap_ms   = 0
        cars\[i\].times.best_ms  = 999999
        cars\[i\].boost    = 1.0
        cars\[i\].boost_cd = 0.0
        i = i + 1
    }
}

-- ============================================================
-- Chase camera: smooth look-at
-- ============================================================
fn update_camera(dt: f32) {
    let p: *Car = &cars\[0\]
    let sh: f32 = math.sin_f(p.heading)
    let ch: f32 = math.cos_f(p.heading)

    let wx: f32 = p.x - sh * CAM_DIST
    let wy: f32 = p.y + CAM_HEIGHT
    let wz: f32 = p.z - ch * CAM_DIST

    let t: f32 = math.clamp_f(CAM_SMOOTH * dt, 0.0, 1.0)
    cam_ex = math.lerp_f(cam_ex, wx, t)
    cam_ey = math.lerp_f(cam_ey, wy, t)
    cam_ez = math.lerp_f(cam_ez, wz, t)

    let eye: T3DVec3 = undefined
    eye.x = cam_ex
    eye.y = cam_ey
    eye.z = cam_ez

    let tgt: T3DVec3 = undefined
    tgt.x = p.x + sh * CAM_AHEAD
    tgt.y = p.y + 1.8
    tgt.z = p.z + ch * CAM_AHEAD

    let up: T3DVec3 = undefined
    up.x = 0.0
    up.y = 1.0
    up.z = 0.0

    t3d.look_at(&vp, &eye, &tgt, &up)
}

-- ============================================================
-- Rally drift physics
-- ============================================================
fn car_physics(car: *Car, throttle: f32, brk: f32, steer: f32,
               handbrake: bool, dt: f32) {
    if car.car_state == CarState.spinning {
        car.spin_timer = car.spin_timer - dt
        if car.spin_timer <= 0.0 { car.car_state = CarState.normal_driving }
        return
    }

    let sf: f32 = math.clamp_f(car.speed / MAX_SPEED, 0.25, 1.0)
    car.heading = car.heading + steer * STEER_RATE * sf * dt

    car.speed = car.speed + throttle * ACCEL * dt
    car.speed = car.speed - brk * BRAKE_RATE * dt
    car.speed = math.clamp_f(car.speed, 0.0, MAX_SPEED)

    let ff: f32 = 1.0 - (1.0 - FRICTION) * dt * 60.0
    car.speed = car.speed * ff

    let sh: f32 = math.sin_f(car.heading)
    let ch: f32 = math.cos_f(car.heading)

    -- lateral drift build-up
    if math.abs_f(steer) > 0.04 {
        let base: f32 = steer * car.speed * 8.0
        if handbrake { base = steer * car.speed * 22.0 }
        car.lat_v = car.lat_v + base * dt
    }

    let max_lat: f32 = car.speed * 0.65
    if handbrake { max_lat = car.speed * 1.5 }
    car.lat_v = math.clamp_f(car.lat_v, -max_lat, max_lat)

    let grip: f32 = LAT_GRIP
    if handbrake { grip = LAT_GRIP_HB }
    let lf: f32 = 1.0 - (1.0 - grip) * dt * 60.0
    car.lat_v = car.lat_v * lf

    -- right-vector perpendicular to heading
    let rx: f32 = ch
    let rz: f32 = -sh
    car.vx = sh * car.speed * dt + rx * car.lat_v * dt
    car.vz = ch * car.speed * dt + rz * car.lat_v * dt
    car.x  = car.x + car.vx
    car.z  = car.z + car.vz

    car.boost_cd = math.max_f(0.0, car.boost_cd - dt)
    if car.boost < 1.0 and car.boost_cd <= 0.0 {
        car.boost = math.clamp_f(car.boost + BOOST_REGEN * dt, 0.0, 1.0)
    }
}

-- ============================================================
-- Player input
-- ============================================================
fn player_input(dt: f32, pad: *controller_data) {
    let car: *Car = &cars\[0\]

    let sx: i32 = pad.stick_x as i32
    let steer: f32 = 0.0
    if sx > 8  { steer = (sx as f32 - 8.0)  / 72.0 }
    elif sx < -8 { steer = (sx as f32 + 8.0) / 72.0 }

    let throttle: f32 = 0.0
    let brk: f32 = 0.0
    if pad.held.a { throttle = 1.0 }
    if pad.held.b { brk = 1.0 }

    let hb: bool = pad.held.z

    if pad.pressed.c_up and car.boost >= BOOST_COST and car.boost_cd <= 0.0 {
        car.speed   = car.speed + BOOST_SPEED
        car.boost   = car.boost - BOOST_COST
        car.boost_cd = 3.0
    }

    car_physics(car, throttle, brk, steer, hb, dt)
}

-- ============================================================
-- AI: cross-product steering toward next waypoint
-- ============================================================
fn ai_steer_to_wp(car: *Car) -> f32 {
    let wp: *Waypoint = &waypoints\[car.next_wp\]
    let dx: f32 = wp.x - car.x
    let dz: f32 = wp.z - car.z
    let dist: f32 = math.sqrt_f(dx * dx + dz * dz)
    if dist < 0.5 { return 0.0 }
    let sh: f32 = math.sin_f(car.heading)
    let ch: f32 = math.cos_f(car.heading)
    let cross: f32 = sh * dz - ch * dx
    return math.clamp_f(-cross / dist, -1.0, 1.0)
}

fn ai_update(car: *Car, dt: f32, throttle: f32) {
    let steer: f32 = ai_steer_to_wp(car)
    car_physics(car, throttle, 0.0, steer, false, dt)
}

-- ============================================================
-- Waypoint tracking
-- ============================================================
fn advance_waypoints(car: *Car) {
    let wp: *Waypoint = &waypoints\[car.next_wp\]
    let dx: f32 = wp.x - car.x
    let dz: f32 = wp.z - car.z
    if dx * dx + dz * dz < 225.0 {
        car.next_wp = car.next_wp + 1
        if car.next_wp >= wp_count {
            car.next_wp = 0
            car.lap = car.lap + 1
            if car.is_player {
                if car.times.lap_ms < car.times.best_ms {
                    car.times.best_ms = car.times.lap_ms
                }
                car.times.lap_ms = 0
            }
        }
    }
    car.progress = car.lap * wp_count + car.next_wp
}

-- ============================================================
-- Race positions
-- ============================================================
fn update_positions() {
    let i: i32 = 0
    loop {
        if i >= MAX_CARS { break }
        cars\[i\].place = 1
        let j: i32 = 0
        loop {
            if j >= MAX_CARS { break }
            if cars\[j\].progress > cars\[i\].progress {
                cars\[i\].place = cars\[i\].place + 1
            }
            j = j + 1
        }
        i = i + 1
    }
}

-- ============================================================
-- Race timing
-- ============================================================
fn update_timing(dt: f32) {
    let dt_ms: i32 = (dt * 1000.0) as i32
    race_ms = race_ms + dt_ms
    let i: i32 = 0
    loop {
        if i >= MAX_CARS { break }
        if cars\[i\].active {
            cars\[i\].times.total_ms = cars\[i\].times.total_ms + dt_ms
            cars\[i\].times.lap_ms   = cars\[i\].times.lap_ms   + dt_ms
        }
        i = i + 1
    }
}

-- ============================================================
-- Minimap
-- ============================================================
fn render_minimap() {
    let MX: i32 = 244
    let MY: i32 = 162
    let MS: i32 = 72

    rdpq.set_mode_fill(0x0A1018FF)
    rdpq.fill_rectangle(MX - 1, MY - 1, MX + MS + 1, MY + MS + 1)

    let i: i32 = 0
    loop {
        if i >= wp_count { break }
        let wx: i32 = MX + ((waypoints\[i\].x / 90.0 + 0.5) * (MS as f32)) as i32
        let wy: i32 = MY + ((waypoints\[i\].z / 90.0 + 0.5) * (MS as f32)) as i32
        rdpq.set_mode_fill(0x3A6040FF)
        rdpq.fill_rectangle(wx - 2, wy - 2, wx + 2, wy + 2)
        i = i + 1
    }

    let c: i32 = 0
    loop {
        if c >= MAX_CARS { break }
        if cars\[c\].active {
            let cx: i32 = MX + ((cars\[c\].x / 90.0 + 0.5) * (MS as f32)) as i32
            let cy: i32 = MY + ((cars\[c\].z / 90.0 + 0.5) * (MS as f32)) as i32
            if c == 0 {
                rdpq.set_mode_fill(0xFFFFFFFF)
                rdpq.fill_rectangle(cx - 3, cy - 3, cx + 3, cy + 3)
            } else {
                rdpq.set_mode_fill(0x888888FF)
                rdpq.fill_rectangle(cx - 2, cy - 2, cx + 2, cy + 2)
            }
        }
        c = c + 1
    }
}

-- ============================================================
-- HUD
-- ============================================================
fn render_hud() {
    rdpq_mode_push()
    rdpq.set_mode_standard()

    let p: *Car = &cars\[0\]

    -- speed bar
    rdpq.set_mode_fill(0x0A180AFF)
    rdpq.fill_rectangle(8, 207, 122, 217)
    let spct: i32 = (p.speed * 114.0 / MAX_SPEED) as i32
    rdpq.set_mode_fill(0x44FF66FF)
    rdpq.fill_rectangle(8, 207, 8 + spct, 217)

    -- drift bar
    let la: f32 = math.abs_f(p.lat_v)
    let dpct: i32 = (la * 114.0 / (MAX_SPEED * 1.5)) as i32
    if dpct > 114 { dpct = 114 }
    if dpct > 4 {
        rdpq.set_mode_fill(0xFF6600FF)
        rdpq.fill_rectangle(8, 219, 8 + dpct, 227)
    }

    -- boost bar
    rdpq.set_mode_fill(0x1A0A00FF)
    rdpq.fill_rectangle(8, 229, 122, 237)
    let bpct: i32 = (p.boost * 114.0) as i32
    rdpq.set_mode_fill(0xFF8800FF)
    rdpq.fill_rectangle(8, 229, 8 + bpct, 237)

    let kmh: i32 = (p.speed * 4.8) as i32
    rdpq_text_printf(8, 196, 1, \"%d km/h\", kmh)
    rdpq_text_printf(136, 6, 1, \"LAP %d/%d\", p.lap + 1, MAX_LAPS)
    rdpq_text_printf(276, 6, 1, \"P%d\", p.place)

    let ls: i32 = p.times.lap_ms / 1000
    let lf: i32 = (p.times.lap_ms % 1000) / 10
    rdpq_text_printf(8, 6, 1, \"%d.%02d\", ls, lf)

    if p.times.best_ms < 999999 {
        let bs: i32 = p.times.best_ms / 1000
        let bf: i32 = (p.times.best_ms % 1000) / 10
        rdpq_text_printf(8, 18, 1, \"BEST %d.%02d\", bs, bf)
    }

    render_minimap()

    if race_state == RaceState.countdown {
        rdpq.set_mode_fill(0x000000A0)
        rdpq.fill_rectangle(124, 88, 196, 132)
        let cd: i32 = countdown as i32 + 1
        rdpq_text_printf(150, 98, 1, \"%d\", cd)
        rdpq_text_printf(110, 72, 1, \"GET READY!\")
    }

    rdpq_mode_pop()
}

-- ============================================================
-- 3D render: look_at camera + fog + 2-light shading
-- ============================================================
fn render_race(dt: f32) {
    update_camera(dt)

    let fb = display.get()
    rdpq.attach_clear(fb)

    t3d.frame_start()
    t3d.viewport_attach(&vp)

    -- atmospheric mountain fog
    t3d.fog_set_enabled(true)
    t3d.fog_set_range(35.0, 200.0)
    t3d.fog_set_color(0x8CBCD4FF)

    -- warm noon sun + cool sky fill
    t3d.light_set_ambient(52, 58, 72)
    t3d.light_set_directional(0, 255, 248, 208, -0.4, -1.0, 0.3)
    t3d.light_set_directional(1, 68, 82, 128, 0.3, 0.35, -0.65)
    t3d.light_set_count(2)

    if track_model != none { t3d.model_draw(track_model) }

    let i: i32 = 0
    loop {
        if i >= MAX_CARS { break }
        if cars\[i\].active and car_model\[i\] != none and car_fp\[i\] != none {
            let sc: \[f32; 3\] = undefined
            sc\[0\] = 1.0  sc\[1\] = 1.0  sc\[2\] = 1.0
            let eu: \[f32; 3\] = undefined
            eu\[0\] = 0.0  eu\[1\] = cars\[i\].heading  eu\[2\] = 0.0
            let tr: \[f32; 3\] = undefined
            tr\[0\] = cars\[i\].x  tr\[1\] = cars\[i\].y  tr\[2\] = cars\[i\].z
            t3d_mat4fp_from_srt_euler(car_fp\[i\], &sc\[0\], &eu\[0\], &tr\[0\])
            t3d_matrix_push(car_fp\[i\])
            t3d.model_draw(car_model\[i\])
            t3d_matrix_pop(1)
        }
        i = i + 1
    }

    t3d.frame_end()
    render_hud()
    rdpq.detach_show()
}

-- ============================================================
-- Results screen
-- ============================================================
fn render_results() {
    let fb = display.get()
    rdpq.attach_clear(fb)

    rdpq.set_mode_fill(0x040C18FF)
    rdpq.fill_rectangle(0, 0, 320, 240)
    rdpq.set_mode_fill(0xC8960AFF)
    rdpq.fill_rectangle(56, 24, 264, 44)
    rdpq_text_printf(82, 28, 1, \"RALLY CHAMPIONSHIP\")
    rdpq_text_printf(108, 54, 1, \"FINAL RESULTS\")

    let i: i32 = 0
    loop {
        if i >= MAX_CARS { break }
        let y: i32 = 78 + i * 34
        rdpq.set_mode_fill(0x0E2040FF)
        rdpq.fill_rectangle(52, y, 268, y + 28)
        rdpq_text_printf(62, y + 6, 1, \"P%d\", cars\[i\].place)
        let ts: i32 = cars\[i\].times.total_ms / 1000
        let tf: i32 = (cars\[i\].times.total_ms % 1000) / 10
        rdpq_text_printf(110, y + 6, 1, \"%d.%02ds\", ts, tf)
        if cars\[i\].times.best_ms < 999999 {
            let bs: i32 = cars\[i\].times.best_ms / 1000
            let bf: i32 = (cars\[i\].times.best_ms % 1000) / 10
            rdpq_text_printf(110, y + 16, 1, \"best %d.%02d\", bs, bf)
        }
        if cars\[i\].is_player { rdpq_text_printf(238, y + 6, 1, \"<YOU\") }
        i = i + 1
    }

    rdpq_text_printf(80, 224, 1, \"A/START: RACE AGAIN\")
    rdpq.detach_show()
}

-- ============================================================
-- Entry point
-- ============================================================
entry {
    display.init(0, 2, 3, 0, 1)
    rdpq.init()
    controller.init()
    timer.init()
    audio.init(44100, 3)
    mixer.init(8)
    t3d.init()

    vp = t3d.viewport_create()
    t3d.viewport_set_projection(&vp, 72.0, 0.5, 250.0)

${model_block}
${audio_block}

    init_waypoints()
    init_cars()

    let mi: i32 = 0
    loop {
        if mi >= MAX_CARS { break }
        car_fp\[mi\] = Mat4Fp.create()
        mi = mi + 1
    }

    cam_ex = 0.0
    cam_ey = 6.0
    cam_ez = ${sz} - 24.0

    race_state = RaceState.countdown
    countdown  = 3.0

    loop {
        let dt: f32 = timer.delta()
        if dt > 0.033 { dt = 0.033 }

        let abuf = audio.get_buffer()
        if abuf != none { mixer.poll(abuf) }

        controller.poll()
        let pad = controller.read(0)

        match race_state {
            RaceState.countdown => {
                countdown = countdown - dt
                if countdown <= 0.0 {
                    countdown = 0.0
                    race_state = RaceState.racing
                }
                render_race(dt)
            }
            RaceState.racing => {
                update_timing(dt)
                player_input(dt, &pad)
                advance_waypoints(&cars\[0\])
${ai_block}
                update_positions()
                if cars\[0\].lap >= MAX_LAPS {
                    race_state = RaceState.finished
                    countdown  = 0.0
                }
                render_race(dt)
            }
            RaceState.finished => {
                countdown = countdown + dt
                if countdown >= 3.0 { race_state = RaceState.results }
                render_race(dt)
            }
            RaceState.results => {
                if pad.pressed.start or pad.pressed.a {
                    init_cars()
                    race_ms   = 0
                    countdown = 3.0
                    race_state = RaceState.countdown
                    cam_ex = 0.0
                    cam_ey = 6.0
                    cam_ez = ${sz} - 24.0
                }
                render_results()
            }
        }
    }
}
"
}
