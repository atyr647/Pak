# codegen/racer.tcl — .pakstudio → N64 3D racing game .pk64 + pak.toml
#
# Generates a complete racing game based on the racing.pk64 reference:
# car physics, lap timing, AI opponents, HUD, optional 3D model loading.
# Track waypoints come from doc.levels[0].waypoints; physics constants
# come from doc.physics.

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
    # Ensure value has a decimal point so Pak sees it as f32
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
    # Default oval (matches racing.pk64 reference)
    return [list \
        {x  0.0  z -60.0  width 12.0} \
        {x 40.0  z -50.0  width 12.0} \
        {x 60.0  z -20.0  width 12.0} \
        {x 60.0  z  20.0  width 12.0} \
        {x 40.0  z  50.0  width 12.0} \
        {x  0.0  z  60.0  width 12.0} \
        {x -40.0 z  50.0  width 12.0} \
        {x -60.0 z  20.0  width 12.0} \
        {x -60.0 z -20.0  width 12.0} \
        {x -40.0 z -50.0  width 12.0} \
    ]
}

proc codegen::racer::_num_laps {doc} {
    if {[dict exists $doc physics num_laps]} {
        return [dict get $doc physics num_laps]
    }
    return 3
}

proc codegen::racer::_ai_count {doc} {
    if {[dict exists $doc physics ai_count]} {
        return [dict get $doc physics ai_count]
    }
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
    set wps      [_waypoints $doc]
    set nwp      [llength $wps]
    set nlaps    [_num_laps $doc]
    set nai      [_ai_count $doc]
    set ncars    [expr {$nai + 1}]  ;# player + AI

    set accel    [_f32 [_phys $doc accel_rate  18.0]]
    set brake    [_f32 [_phys $doc brake_rate  30.0]]
    set maxspd   [_f32 [_phys $doc max_speed   45.0]]
    set steer    [_f32 [_phys $doc steer_rate   2.2]]
    set friction [_f32 [_phys $doc friction     0.97]]
    set gravity  [_f32 [_phys $doc gravity    -20.0]]
    set twidth   [_f32 [_phys $doc track_width 12.0]]

    set has_bgm      [_has_audio $doc bgm]
    set has_engine   [_has_audio $doc sfx_engine]
    set has_crash    [_has_audio $doc sfx_crash]
    set has_lap      [_has_audio $doc lap_complete]
    set has_track_m  [_has_model $doc model_track]

    # Build model declarations for car slots
    set car_model_decls {}
    set car_model_loads {}
    for {set i 0} {$i < $ncars} {incr i} {
        set role "model_car_[expr {$i+1}]"
        if {[_has_model $doc $role]} {
            lappend car_model_loads "    car_models\[$i\] = t3d.model_load(\"rom:/models/${role}.t3dm\")"
        }
    }

    # ── Waypoint initializer block ────────────────────────────────────────────
    set wp_lines {}
    set wi 0
    foreach wp $wps {
        set x [_f32 [dict get $wp x]]
        set z [_f32 [dict get $wp z]]
        set w [_f32 [dict get $wp width]]
        lappend wp_lines "    waypoints\[$wi\].x = $x"
        lappend wp_lines "    waypoints\[$wi\].z = $z"
        lappend wp_lines "    waypoints\[$wi\].width = $w"
        incr wi
    }
    set wp_block [join $wp_lines "\n"]

    # ── Audio open/play block ─────────────────────────────────────────────────
    set audio_open {}
    if {$has_engine} { lappend audio_open "    wav64_open(&sfx_engine, \"rom:/sfx/sfx_engine.wav64\")" }
    if {$has_crash}  { lappend audio_open "    wav64_open(&sfx_crash, \"rom:/sfx/sfx_crash.wav64\")" }
    if {$has_lap}    { lappend audio_open "    wav64_open(&sfx_lap, \"rom:/sfx/lap_complete.wav64\")" }
    if {$has_bgm}    {
        lappend audio_open "    xm64player_open(&music, \"rom:/music/bgm.xm64\")"
        lappend audio_open "    xm64player_play(&music, 0)"
    }
    set audio_block [join $audio_open "\n"]

    # ── Model load block ──────────────────────────────────────────────────────
    set model_lines {}
    if {$has_track_m} {
        lappend model_lines "    track_model = t3d.model_load(\"rom:/models/model_track.t3dm\")"
    }
    foreach ml $car_model_loads { lappend model_lines $ml }
    set model_block [join $model_lines "\n"]

    # ── Static declarations for optional audio ────────────────────────────────
    set audio_statics {}
    if {$has_engine} { lappend audio_statics "static sfx_engine: wav64_t = undefined" }
    if {$has_crash}  { lappend audio_statics "static sfx_crash: wav64_t = undefined" }
    if {$has_lap}    { lappend audio_statics "static sfx_lap: wav64_t = undefined" }
    if {$has_bgm}    { lappend audio_statics "static music: xm64player_t = undefined" }
    set audio_static_block [join $audio_statics "\n"]

    # ── extern "C" audio declarations ─────────────────────────────────────────
    set extern_audio {}
    if {$has_engine || $has_crash || $has_lap} {
        lappend extern_audio "    fn wav64_open(wav: *wav64_t, path: *c_char)"
        lappend extern_audio "    fn wav64_play(wav: *wav64_t, channel: i32)"
    }
    if {$has_bgm} {
        lappend extern_audio "    fn xm64player_open(xm: *xm64player_t, path: *c_char)"
        lappend extern_audio "    fn xm64player_play(xm: *xm64player_t, first_ch: i32)"
    }
    set extern_audio_block [join $extern_audio "\n"]

    set MAX_CARS [expr {max($ncars, 2)}]

    return "-- src/main.pk64 — generated by PakStudio (Racer)
-- $ncars cars  |  $nwp waypoints  |  $nlaps laps

use n64.display
use n64.controller
use n64.rdpq
use n64.timer
use n64.audio
use n64.mixer
use t3d

extern \"C\" {
    fn rdpq_mode_push()
    fn rdpq_mode_pop()
    fn rdpq_text_printf(x: i32, y: i32, font: i32, fmt: *c_char, ...) -> i32
${extern_audio_block}
}

-- ============================================================
-- Constants
-- ============================================================
const MAX_CARS: i32 = $MAX_CARS
const MAX_WAYPOINTS: i32 = $nwp
const MAX_LAPS: i32 = $nlaps
const TRACK_WIDTH: f32 = $twidth

const CAR_ACCEL: f32 = $accel
const CAR_BRAKE: f32 = $brake
const CAR_MAX_SPEED: f32 = $maxspd
const CAR_STEER: f32 = $steer
const CAR_FRICTION: f32 = $friction
const GRAVITY: f32 = $gravity

-- ============================================================
-- Types
-- ============================================================
enum RaceState { countdown, racing, finished, results }
enum CarState  { racing_car, spinning, off_track }

struct Waypoint {
    x: f32
    z: f32
    width: f32
}

struct RaceTime {
    total_ms: i32
    lap_ms: i32
    best_lap_ms: i32
}

struct Car {
    active: bool
    is_player: bool
    x: f32
    y: f32
    z: f32
    vx: f32
    vy: f32
    vz: f32
    speed: f32
    heading: f32
    angular_vel: f32
    grounded: bool
    lap: i32
    next_wp: i32
    wp_progress: f32
    race_pos: i32
    times: RaceTime
    car_state: CarState
    spin_timer: f32
    turbo: f32
    turbo_cooldown: f32
    place_display: i32
}

-- ============================================================
-- Globals
-- ============================================================
static race_state: RaceState = RaceState.countdown
static countdown_timer: f32 = 3.0
static race_time_ms: i32 = 0

static cars: \[Car; $MAX_CARS\] = undefined
static waypoints: \[Waypoint; $nwp\] = undefined
static waypoint_count: i32 = 0

static viewport: T3DViewport = undefined
static track_model: *T3DModel = none
static car_models: \[*T3DModel; $MAX_CARS\] = undefined

${audio_static_block}

-- ============================================================
-- Track Setup
-- ============================================================
fn init_waypoints() {
${wp_block}
    waypoint_count = $nwp
}

fn init_cars() {
    let i: i32 = 0
    loop {
        if i >= MAX_CARS { break }
        cars\[i\].active = true
        cars\[i\].is_player = i == 0
        cars\[i\].x = (i as f32) * 4.0 - 6.0
        cars\[i\].y = 1.0
        cars\[i\].z = -55.0
        cars\[i\].vx = 0.0
        cars\[i\].vy = 0.0
        cars\[i\].vz = 0.0
        cars\[i\].speed = 0.0
        cars\[i\].heading = 0.0
        cars\[i\].angular_vel = 0.0
        cars\[i\].grounded = true
        cars\[i\].lap = 0
        cars\[i\].next_wp = 0
        cars\[i\].wp_progress = 0.0
        cars\[i\].race_pos = i + 1
        cars\[i\].car_state = CarState.racing_car
        cars\[i\].spin_timer = 0.0
        cars\[i\].turbo = 1.0
        cars\[i\].turbo_cooldown = 0.0
        cars\[i\].times.total_ms = 0
        cars\[i\].times.lap_ms = 0
        cars\[i\].times.best_lap_ms = 999999
        cars\[i\].place_display = i + 1
        i = i + 1
    }
}

-- ============================================================
-- Player Input
-- ============================================================
fn player_car_input(car: *Car, dt: f32, pad: *controller_data) {
    if car.car_state == CarState.spinning { return }

    let throttle: f32 = 0.0
    let brake_val: f32 = 0.0
    let steer: f32 = 0.0

    let sx: i32 = pad.stick_x as i32
    if sx > 10 { steer = (sx as f32 - 10.0) / 70.0 }
    elif sx < -10 { steer = (sx as f32 + 10.0) / 70.0 }

    if pad.held.a { throttle = 1.0 }
    if pad.held.b { brake_val = 1.0 }

    if pad.pressed.z and car.turbo >= 0.3 and car.turbo_cooldown <= 0.0 {
        car.speed = car.speed + 15.0
        car.turbo = car.turbo - 0.3
        car.turbo_cooldown = 2.0
    }

    apply_car_physics(car, throttle, brake_val, steer, dt)
}

-- ============================================================
-- Car Physics
-- ============================================================
fn apply_car_physics(car: *Car, throttle: f32, brake_val: f32,
                     steer: f32, dt: f32) {
    let steer_factor: f32 = 1.0 - car.speed / (CAR_MAX_SPEED * 2.0)
    if steer_factor < 0.3 { steer_factor = 0.3 }
    car.heading = car.heading + steer * CAR_STEER * steer_factor * dt

    if throttle > 0.0 {
        car.speed = car.speed + CAR_ACCEL * throttle * dt
    }

    if brake_val > 0.0 {
        car.speed = car.speed - CAR_BRAKE * brake_val * dt
        if car.speed < 0.0 { car.speed = 0.0 }
    }

    let friction_frame: f32 = 1.0 - (1.0 - CAR_FRICTION) * dt * 60.0
    car.speed = car.speed * friction_frame

    if car.speed > CAR_MAX_SPEED { car.speed = CAR_MAX_SPEED }
    if car.speed < 0.0 { car.speed = 0.0 }

    car.vx = car.heading * car.speed * dt
    car.vz = car.speed * dt
    car.x = car.x + car.vx
    car.z = car.z + car.vz

    car.turbo_cooldown = car.turbo_cooldown - dt
    if car.turbo_cooldown < 0.0 { car.turbo_cooldown = 0.0 }
    if car.turbo < 1.0 and car.turbo_cooldown <= 0.0 {
        car.turbo = car.turbo + 0.1 * dt
        if car.turbo > 1.0 { car.turbo = 1.0 }
    }
}

-- ============================================================
-- AI Cars
-- ============================================================
fn ai_car_update(car: *Car, dt: f32) {
    if car.car_state == CarState.spinning {
        car.spin_timer = car.spin_timer - dt
        if car.spin_timer <= 0.0 {
            car.car_state = CarState.racing_car
        }
        return
    }

    let wp: *Waypoint = &waypoints\[car.next_wp\]
    let dx: f32 = wp.x - car.x
    let dz: f32 = wp.z - car.z
    let dist_sq: f32 = dx * dx + dz * dz

    if dist_sq < 100.0 {
        car.next_wp = car.next_wp + 1
        if car.next_wp >= waypoint_count {
            car.next_wp = 0
            car.lap = car.lap + 1
        }
    }

    let target_heading: f32 = dx / 50.0
    let steer: f32 = target_heading - car.heading
    if steer > 1.0 { steer = 1.0 }
    if steer < -1.0 { steer = -1.0 }

    apply_car_physics(car, 0.8, 0.0, steer, dt)
}

-- ============================================================
-- Waypoint Progress & Positions
-- ============================================================
fn update_waypoint_progress(car: *Car) {
    car.wp_progress = car.lap as f32 * (waypoint_count as f32) +
                      (car.next_wp as f32)
}

fn sort_race_positions() {
    let i: i32 = 0
    loop {
        if i >= MAX_CARS { break }
        update_waypoint_progress(&cars\[i\])
        i = i + 1
    }
    let pos: i32 = 1
    let i2: i32 = 0
    loop {
        if i2 >= MAX_CARS { break }
        cars\[i2\].place_display = pos
        pos = pos + 1
        i2 = i2 + 1
    }
}

-- ============================================================
-- Timing
-- ============================================================
fn update_race_time(dt: f32) {
    let dt_ms: i32 = (dt * 1000.0) as i32
    race_time_ms = race_time_ms + dt_ms
    let i: i32 = 0
    loop {
        if i >= MAX_CARS { break }
        if cars\[i\].active {
            cars\[i\].times.total_ms = cars\[i\].times.total_ms + dt_ms
            cars\[i\].times.lap_ms  = cars\[i\].times.lap_ms  + dt_ms
        }
        i = i + 1
    }
}

-- ============================================================
-- HUD
-- ============================================================
fn render_hud() {
    rdpq_mode_push()
    rdpq.set_mode_standard()

    let player: *Car = &cars\[0\]

    -- speed bar
    rdpq.set_mode_fill(0x002200FF)
    rdpq.fill_rectangle(8, 210, 108, 220)
    let speed_pct: i32 = (player.speed * 100 as f32 / CAR_MAX_SPEED) as i32
    if speed_pct > 100 { speed_pct = 100 }
    rdpq.set_mode_fill(0x00FF44FF)
    rdpq.fill_rectangle(8, 210, 8 + speed_pct, 220)

    -- turbo bar
    rdpq.set_mode_fill(0x220000FF)
    rdpq.fill_rectangle(8, 222, 108, 230)
    let turbo_pct: i32 = (player.turbo * 100.0) as i32
    rdpq.set_mode_fill(0xFF8800FF)
    rdpq.fill_rectangle(8, 222, 8 + turbo_pct, 230)

    -- lap / position / time
    rdpq_text_printf(140, 8, 1, \"LAP %d/%d\", player.lap + 1, MAX_LAPS)
    rdpq_text_printf(260, 8, 1, \"P%d\", player.place_display)
    let secs: i32 = player.times.lap_ms / 1000
    let frac: i32 = (player.times.lap_ms % 1000) / 100
    rdpq_text_printf(8, 8, 1, \"%d.%d\", secs, frac)
    if player.times.best_lap_ms < 999999 {
        let bsecs: i32 = player.times.best_lap_ms / 1000
        let bfrac: i32 = (player.times.best_lap_ms % 1000) / 100
        rdpq_text_printf(8, 20, 1, \"BEST %d.%d\", bsecs, bfrac)
    }

    if race_state == RaceState.countdown {
        rdpq.set_mode_fill(0xFF000088)
        rdpq.fill_rectangle(130, 100, 190, 140)
        let cd: i32 = countdown_timer as i32 + 1
        rdpq_text_printf(155, 110, 1, \"%d\", cd)
    }

    rdpq_mode_pop()
}

-- ============================================================
-- Render
-- ============================================================
fn render_race() {
    let fb = display.get()
    rdpq.attach_clear(fb)

    t3d.frame_start()
    t3d.viewport_attach(&viewport)

    t3d.light_set_ambient(80, 80, 100)
    t3d.light_set_directional(0, 255, 245, 220, -0.4, -1.0, 0.2)
    t3d.light_set_count(1)

    if track_model != none { t3d.model_draw(track_model) }

    let i: i32 = 0
    loop {
        if i >= MAX_CARS { break }
        if cars\[i\].active and car_models\[i\] != none {
            t3d.model_draw(car_models\[i\])
        }
        i = i + 1
    }

    t3d.frame_end()
    render_hud()
    rdpq.detach_show()
}

fn render_results() {
    let fb = display.get()
    rdpq.attach_clear(fb)

    rdpq.set_mode_fill(0x000033FF)
    rdpq.fill_rectangle(0, 0, 320, 240)
    rdpq.set_mode_fill(0xFFFFFFFF)
    rdpq.fill_rectangle(60, 30, 260, 50)

    let i: i32 = 0
    loop {
        if i >= MAX_CARS { break }
        let y: i32 = 60 + i * 30
        rdpq_text_printf(70, y, 1, \"P%d\", cars\[i\].place_display)
        let secs: i32 = cars\[i\].times.total_ms / 1000
        rdpq_text_printf(180, y, 1, \"%d.%d s\", secs,
                         (cars\[i\].times.total_ms % 1000) / 100)
        i = i + 1
    }

    rdpq.detach_show()
}

-- ============================================================
-- Entry Point
-- ============================================================
entry {
    display.init(0, 2, 3, 0, 1)
    rdpq.init()
    controller.init()
    timer.init()
    audio.init(44100, 3)
    mixer.init(8)
    t3d.init()

    viewport = t3d.viewport_create()
    t3d.viewport_set_projection(&viewport, 75.0, 1.0, 200.0)

${model_block}
${audio_block}

    init_waypoints()
    init_cars()

    race_state = RaceState.countdown
    countdown_timer = 3.0

    loop {
        let dt: f32 = timer.delta()
        if dt > 0.033 { dt = 0.033 }

        let abuf = audio.get_buffer()
        if abuf != none { mixer.poll(*abuf) }

        controller.poll()
        let pad = controller.read(0)

        match race_state {
            RaceState.countdown => {
                countdown_timer = countdown_timer - dt
                if countdown_timer <= 0.0 {
                    race_state = RaceState.racing
                }
                render_race()
            }
            RaceState.racing => {
                update_race_time(dt)
                player_car_input(&cars\[0\], dt, &pad)
                let i: i32 = 1
                loop {
                    if i >= MAX_CARS { break }
                    ai_car_update(&cars\[i\], dt)
                    i = i + 1
                }
                if cars\[0\].lap >= MAX_LAPS {
                    race_state = RaceState.finished
                    countdown_timer = 0.0
                }
                sort_race_positions()
                render_race()
            }
            RaceState.finished => {
                countdown_timer = countdown_timer + dt
                if countdown_timer > 2.0 {
                    race_state = RaceState.results
                }
                render_race()
            }
            RaceState.results => {
                if pad.pressed.start or pad.pressed.a {
                    init_cars()
                    race_time_ms = 0
                    race_state = RaceState.countdown
                    countdown_timer = 3.0
                }
                render_results()
            }
        }
    }
}
"
}
