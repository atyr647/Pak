# app/project.tcl — .pakstudio document model
# All persistent state lives in a Tcl dict (the "doc"). This module owns
# creation, load, save, and schema helpers. No GUI dependencies.

namespace eval project {
    variable path  ""       ;# current file path ("" = unsaved)
    variable dirty false    ;# unsaved changes?
    variable doc   {}       ;# current document dict

    # ── Schema version ──────────────────────────────────────────────────
    variable SCHEMA_VERSION 1
}

# ── Constructors ────────────────────────────────────────────────────────────

proc project::new {genre {name "Untitled"}} {
    variable SCHEMA_VERSION
    variable path
    variable dirty
    variable doc
    set newdoc [dict create \
        schema  $SCHEMA_VERSION \
        meta    [dict create \
            genre   $genre \
            name    $name \
            rom_title [string toupper [string range $name 0 19]] \
            created [clock seconds] \
        ] \
        settings [dict create \
            resolution  "320x240" \
            bit_depth   16 \
            framebuffers 3 \
            save_type   "none" \
            palette     "arcade" \
        ] \
        physics  [_default_physics $genre] \
        controls [_default_controls] \
        levels   [list [_default_level 1 "Level 1"]] \
        tilesets [list [_default_tileset]] \
        entities [dict create \
            types [_default_entity_types $genre] \
        ] \
        audio    [dict create \
            events [_default_audio_events $genre] \
        ] \
        dialogue [list] \
        quests   [list] \
        flags    [dict create] \
        assets   [_default_assets] \
    ]
    set path  ""
    set dirty false
    set doc   $newdoc
    return $newdoc
}

# Asset bindings. Each value is an absolute source-file path the user imported,
# or "" meaning "use the built-in procedural shape/synth for this role".
# Sprite roles convert PNG → .sprite; audio roles convert WAV → .wav64 (sfx)
# or XM → .xm64 (music). An empty project assigns nothing and stays asset-free.
proc project::_default_assets {} {
    return [dict create \
        sprites [dict create \
            player       "" \
            enemy_patrol "" \
            enemy_jumper "" \
            coin         "" \
            spring       "" \
            checkpoint   "" \
            goal         "" \
            tile_solid   "" \
            tile_oneway  "" \
            tile_hazard  "" \
            tile_ladder  "" \
            background   "" \
        ] \
        audio [dict create \
            jump       "" \
            coin       "" \
            hurt       "" \
            stomp      "" \
            spring     "" \
            checkpoint "" \
            win        "" \
            music      "" \
        ] \
    ]
}

# Controller mapping. jump_button: a | b | a_or_b | z. move_input: dpad |
# stick | both. run_button: none | z | r | b (hold to sprint). run_mult is the
# speed multiplier applied while the run button is held.
proc project::_default_controls {} {
    return [dict create \
        jump_button "a_or_b" \
        move_input  "both" \
        run_button  "none" \
        run_mult    1.6 \
    ]
}

proc project::_default_physics {genre} {
    switch $genre {
        platformer { return [dict create \
            gravity       0.35 \
            jump_force   -7.5  \
            move_speed    2.5  \
            max_fall     10.0  \
            coyote_frames 6    \
            jump_buffer   8    \
        ]}
        topdown    { return [dict create \
            move_speed    3.0  \
        ]}
        default    { return [dict create move_speed 2.5] }
    }
}

proc project::_default_level {id name} {
    # 32×15 blank level: row 14 = solid ground, rest = empty
    set W 32
    set H 15
    set tiles [lrepeat [expr {$W * $H}] 0]
    # Solid ground row
    for {set x 0} {$x < $W} {incr x} {
        lset tiles [expr {14 * $W + $x}] 1
    }
    # A couple of platforms
    foreach {px py} {6 11  12 9  20 11  26 9} {
        for {set dx 0} {$dx < 4} {incr dx} {
            lset tiles [expr {$py * $W + $px + $dx}] 1
        }
    }
    # A fresh project is a complete, winnable game out of the box:
    # spawn, a few coins, one patrol enemy, a checkpoint, and a goal.
    return [dict create \
        id       $id \
        name     $name \
        width    $W \
        height   $H \
        tileset  0 \
        bg_color "0x0D1B2AFF" \
        music    "" \
        tiles    $tiles \
        objects  [list \
            [dict create type player_start x 2  y 13] \
            [dict create type coin         x 6  y 10] \
            [dict create type coin         x 7  y 10] \
            [dict create type coin         x 12 y 8] \
            [dict create type enemy_patrol x 16 y 13] \
            [dict create type checkpoint   x 20 y 13] \
            [dict create type goal         x 30 y 13] \
        ] \
    ]
}

proc project::_default_tileset {} {
    return [dict create \
        id    0 \
        file  "" \
        tile_size 16 \
        types [dict create \
            0 empty \
            1 solid \
            2 one_way \
            3 hazard \
            4 ladder \
        ] \
        colors [dict create \
            1 "#AA5533" \
            2 "#558844" \
            3 "#FF2200" \
            4 "#AA8844" \
        ] \
    ]
}

proc project::_default_entity_types {genre} {
    switch $genre {
        platformer {
            return [list \
                [dict create id enemy_patrol  label "Patrol Enemy"  ai patrol  health 1  speed 1.5  loot ""      color "#FF4488"] \
                [dict create id enemy_jumper  label "Jump Enemy"    ai jumper  health 1  speed 1.0  loot ""      color "#FF8844"] \
                [dict create id coin          label "Coin"          ai static  health 0  speed 0.0  loot ""      color "#FFDD00"] \
                [dict create id checkpoint    label "Checkpoint"    ai static  health 0  speed 0.0  loot ""      color "#00FFAA"] \
                [dict create id spring        label "Spring"        ai static  health 0  speed 0.0  loot ""      color "#FFCC00"] \
                [dict create id door          label "Door"          ai static  health 0  speed 0.0  loot ""      color "#8844AA"] \
                [dict create id goal          label "Goal / Exit"   ai static  health 0  speed 0.0  loot ""      color "#FFFFFF"] \
            ]
        }
        topdown {
            return [list \
                [dict create id npc    label "NPC"    ai wander  health 0 speed 1.0 loot "" color "#44AAFF"] \
                [dict create id enemy  label "Enemy"  ai chase   health 2 speed 2.0 loot "" color "#FF4444"] \
                [dict create id chest  label "Chest"  ai static  health 0 speed 0.0 loot "" color "#AAAA44"] \
            ]
        }
        default { return [list] }
    }
}

proc project::_default_audio_events {genre} {
    switch $genre {
        platformer {
            return [dict create \
                jump      "" \
                land      "" \
                coin      "" \
                hurt      "" \
                death     "" \
                checkpoint "" \
                victory   "" \
                bg_music  "" \
            ]
        }
        default { return [dict create bg_music ""] }
    }
}

# ── Persistence ─────────────────────────────────────────────────────────────

proc project::save_to {filepath} {
    variable doc
    variable path
    variable dirty
    set f [open $filepath w]
    puts $f $doc
    close $f
    set path  $filepath
    set dirty false
}

proc project::load_from {filepath} {
    variable path
    variable dirty
    variable doc
    variable SCHEMA_VERSION
    set f [open $filepath r]
    set raw [read $f]
    close $f
    # Basic schema check
    if {![dict exists $raw schema]} { error "Not a .pakstudio file" }
    set ver [dict get $raw schema]
    if {$ver > $SCHEMA_VERSION} { error "File requires newer PakStudio (schema v$ver)" }
    # Forward-migrate projects saved before the asset pipeline existed.
    if {![dict exists $raw assets]} {
        dict set raw assets [_default_assets]
    }
    # Forward-migrate projects saved before controller config existed.
    if {![dict exists $raw controls]} {
        dict set raw controls [_default_controls]
    }
    set doc   $raw
    set path  $filepath
    set dirty false
    return $doc
}

# ── Accessors / mutators ─────────────────────────────────────────────────────

# Bind (or clear with "") an asset path for a role. kind is "sprites" or "audio".
proc project::set_asset {kind role path} {
    variable doc
    variable dirty
    if {![dict exists $doc assets]} { dict set doc assets [_default_assets] }
    dict set doc assets $kind $role $path
    set dirty true
}

proc project::get_asset {kind role} {
    variable doc
    if {![dict exists $doc assets $kind $role]} { return "" }
    return [dict get $doc assets $kind $role]
}

proc project::get {args} {
    variable doc
    return [dict get $doc {*}$args]
}

proc project::set_field {args} {
    # Last arg is value; preceding args are the key path
    variable doc
    variable dirty
    set value [lindex $args end]
    set keys  [lrange $args 0 end-1]
    dict set doc {*}$keys $value
    set dirty true
}

proc project::mark_dirty {} {
    variable dirty
    set dirty true
}

proc project::is_dirty {} {
    variable dirty
    return $dirty
}

proc project::current_path {} {
    variable path
    return $path
}

proc project::current_doc {} {
    variable doc
    return $doc
}

# ── Level helpers ────────────────────────────────────────────────────────────

proc project::get_level {idx} {
    variable doc
    return [lindex [dict get $doc levels] $idx]
}

proc project::set_tile {level_idx tx ty type} {
    variable doc
    variable dirty
    set lvl [lindex [dict get $doc levels] $level_idx]
    set W   [dict get $lvl width]
    set tiles [dict get $lvl tiles]
    lset tiles [expr {$ty * $W + $tx}] $type
    dict set lvl tiles $tiles
    set levels [dict get $doc levels]
    lset levels $level_idx $lvl
    dict set doc levels $levels
    set dirty true
}

proc project::add_object {level_idx obj} {
    variable doc
    variable dirty
    set lvl  [lindex [dict get $doc levels] $level_idx]
    set objs [dict get $lvl objects]
    lappend objs $obj
    dict set lvl objects $objs
    set levels [dict get $doc levels]
    lset levels $level_idx $lvl
    dict set doc levels $levels
    set dirty true
}

proc project::remove_object {level_idx obj_idx} {
    variable doc
    variable dirty
    set lvl  [lindex [dict get $doc levels] $level_idx]
    set objs [dict get $lvl objects]
    set objs [lreplace $objs $obj_idx $obj_idx]
    dict set lvl objects $objs
    set levels [dict get $doc levels]
    lset levels $level_idx $lvl
    dict set doc levels $levels
    set dirty true
}

proc project::add_level {} {
    variable doc
    variable dirty
    set levels [dict get $doc levels]
    set id     [expr {[llength $levels] + 1}]
    lappend levels [_default_level $id "Level $id"]
    dict set doc levels $levels
    set dirty true
    return [expr {$id - 1}]
}
