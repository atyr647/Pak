# editors/physics.tcl — physics & feel editor panel

namespace eval physics_ed {}

proc physics_ed::create {parent on_change} {
    set f [ttk::frame $parent.physed]

    # Variables
    foreach v {gravity jump_force move_speed max_fall coyote_frames jump_buffer} {
        set ::phys_$v 0
    }

    ttk::label $f.title -text "Physics & Feel" -font {TkDefaultFont 10 bold}
    ttk::separator $f.sep -orient horizontal

    grid $f.title -row 0 -columnspan 3 -sticky w -padx 8 -pady {8 2}
    grid $f.sep   -row 1 -columnspan 3 -sticky ew -padx 8 -pady 4

    set params {
        gravity       "Gravity"       0.05 0.1  2.0
        jump_force    "Jump Force"    0.5  -15  -1.0
        move_speed    "Move Speed"    0.25  0.5  8.0
        max_fall      "Max Fall"      0.5   2.0  20.0
        coyote_frames "Coyote Frames" 1     0    15
        jump_buffer   "Jump Buffer"   1     0    20
    }

    set row 2
    foreach {key lbl step from to} $params {
        set vname ::phys_$key
        ttk::label $f.lbl_$key -text $lbl -anchor w -width 16
        ttk::scale $f.scl_$key -variable $vname -from $from -to $to \
            -orient horizontal -length 160 \
            -command [list physics_ed::_on_change $on_change]
        ttk::spinbox $f.spn_$key -textvariable $vname -width 8 \
            -from $from -to $to -increment $step \
            -command [list physics_ed::_on_change $on_change]
        bind $f.spn_$key <Return>   [list physics_ed::_on_change $on_change {}]
        bind $f.spn_$key <FocusOut> [list physics_ed::_on_change $on_change {}]

        grid $f.lbl_$key -row $row -column 0 -sticky w  -padx {8 2} -pady 3
        grid $f.scl_$key -row $row -column 1 -sticky ew -padx 2     -pady 3
        grid $f.spn_$key -row $row -column 2 -sticky w  -padx {2 8} -pady 3
        incr row
    }
    grid columnconfigure $f 1 -weight 1

    ttk::separator $f.sep2 -orient horizontal
    grid $f.sep2 -row $row -columnspan 3 -sticky ew -padx 8 -pady 8
    incr row

    ttk::label $f.plbl -text "Preset:"
    set presets {"Default" "Floaty" "Heavy" "Slippery" "Custom"}
    ttk::combobox $f.pcmb -values $presets -state readonly -width 14 \
        -textvariable ::phys_preset
    set ::phys_preset "Default"
    bind $f.pcmb <<ComboboxSelected>> [list physics_ed::_apply_preset $on_change]

    grid $f.plbl -row $row -column 0 -sticky w -padx {8 2} -pady 4
    grid $f.pcmb -row $row -column 1 -sticky w -padx 2     -pady 4

    pack $f -fill both -expand 1
    return $f
}

proc physics_ed::_apply_preset {on_change} {
    switch $::phys_preset {
        "Default"   { set ::phys_gravity 0.35; set ::phys_jump_force -7.5; set ::phys_move_speed 2.5 }
        "Floaty"    { set ::phys_gravity 0.20; set ::phys_jump_force -6.0; set ::phys_move_speed 2.2 }
        "Heavy"     { set ::phys_gravity 0.55; set ::phys_jump_force -9.0; set ::phys_move_speed 3.0 }
        "Slippery"  { set ::phys_gravity 0.35; set ::phys_jump_force -7.5; set ::phys_move_speed 4.0 }
    }
    {*}$on_change
}

proc physics_ed::_on_change {on_change args} {
    after cancel "physics_ed::_fire $on_change"
    after 100    "physics_ed::_fire $on_change"
}

proc physics_ed::_fire {on_change} {
    catch {{*}$on_change}
}

proc physics_ed::load_doc {doc} {
    set phys [dict get $doc physics]
    foreach key {gravity jump_force move_speed max_fall coyote_frames jump_buffer} {
        if {[dict exists $phys $key]} {
            set ::phys_$key [dict get $phys $key]
        }
    }
}

proc physics_ed::save_to_doc {} {
    if {![dict exists [project::current_doc] meta]} return
    foreach key {gravity jump_force move_speed max_fall coyote_frames jump_buffer} {
        set val [set ::phys_$key]
        project::set_field physics $key $val
    }
}
