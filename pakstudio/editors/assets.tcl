# editors/assets.tcl — asset manager: import sprites & audio, bind to roles.
#
# Binding stores the absolute source path in the project document. On build the
# files are copied into the project tree and converted (PNG→sprite, WAV→wav64,
# XM→xm64). A role left unbound uses the built-in procedural shape / synth.

namespace eval assets_ed {
    variable thumbs        ;# array: role -> photo image (kept alive)
    variable panel ""      ;# path of the panel frame once built
}

# Sprite roles and their human labels.
proc assets_ed::_sprite_roles {} {
    return {
        player       "Player"
        enemy_patrol "Patrol Enemy"
        enemy_jumper "Jumper Enemy"
        coin         "Coin"
        spring       "Spring"
        checkpoint   "Checkpoint"
        goal         "Goal / Exit"
        tile_solid   "Solid Tile"
        tile_oneway  "One-Way Tile"
        tile_hazard  "Hazard Tile"
        tile_ladder  "Ladder Tile"
        background   "Background"
    }
}

proc assets_ed::_audio_roles {} {
    return {
        jump       "Jump"
        coin       "Coin Pickup"
        hurt       "Hurt"
        stomp      "Stomp Enemy"
        spring     "Spring Bounce"
        checkpoint "Checkpoint"
        win        "Win / Goal"
        music      "Background Music"
    }
}

proc assets_ed::create {parent} {
    variable thumbs
    variable panel
    array unset thumbs

    set f [ttk::frame $parent.assetsed]
    set panel $f

    ttk::label $f.title -text "Asset Manager" -font {TkDefaultFont 10 bold}
    ttk::label $f.sub -text \
        "Bind PNG sprites and WAV / XM audio to game roles. Unbound roles use the built-in retro shapes & synth sound." \
        -style Subtitle.TLabel -wraplength 880
    grid $f.title -row 0 -column 0 -columnspan 2 -sticky w -padx 8 -pady {8 0}
    grid $f.sub   -row 1 -column 0 -columnspan 2 -sticky w -padx 8 -pady {0 6}

    ttk::separator $f.sep -orient horizontal
    grid $f.sep -row 2 -column 0 -columnspan 2 -sticky ew -padx 8 -pady 4

    # Two scrollable columns: sprites | audio
    set sprf [ttk::labelframe $f.spr -text " Sprites (PNG) "]
    set audf [ttk::labelframe $f.aud -text " Audio (WAV / XM) "]
    grid $sprf -row 3 -column 0 -sticky nsew -padx {8 4} -pady 4
    grid $audf -row 3 -column 1 -sticky nsew -padx {4 8} -pady 4
    grid columnconfigure $f 0 -weight 3
    grid columnconfigure $f 1 -weight 2
    grid rowconfigure    $f 3 -weight 1

    set r 0
    foreach {role label} [_sprite_roles] {
        _make_sprite_row $sprf $role $label $r
        incr r
    }
    set r 0
    foreach {role label} [_audio_roles] {
        _make_audio_row $audf $role $label $r
        incr r
    }
    grid columnconfigure $sprf 2 -weight 1
    grid columnconfigure $audf 1 -weight 1

    pack $f -fill both -expand 1
    return $f
}

proc assets_ed::_make_sprite_row {parent role label row} {
    set cv [canvas $parent.th_$role -width 30 -height 30 \
        -bg #0d1118 -highlightthickness 1 -highlightbackground #1e2540]
    ttk::label $parent.lbl_$role -text $label -width 13 -anchor w
    ttk::label $parent.file_$role -text "(none)" -style Subtitle.TLabel -anchor w
    ttk::button $parent.imp_$role -text "Import…" -style Toolbutton \
        -command [list assets_ed::_import sprites $role]
    ttk::button $parent.clr_$role -text "✕" -width 2 -style Toolbutton \
        -command [list assets_ed::_clear sprites $role]

    grid $cv               -row $row -column 0 -padx {6 4} -pady 3
    grid $parent.lbl_$role -row $row -column 1 -sticky w -padx 2
    grid $parent.file_$role -row $row -column 2 -sticky ew -padx 4
    grid $parent.imp_$role -row $row -column 3 -padx 1
    grid $parent.clr_$role -row $row -column 4 -padx {1 6}
}

proc assets_ed::_make_audio_row {parent role label row} {
    ttk::label $parent.lbl_$role -text $label -width 15 -anchor w
    ttk::label $parent.file_$role -text "(none)" -style Subtitle.TLabel -anchor w
    ttk::button $parent.imp_$role -text "Import…" -style Toolbutton \
        -command [list assets_ed::_import audio $role]
    ttk::button $parent.clr_$role -text "✕" -width 2 -style Toolbutton \
        -command [list assets_ed::_clear audio $role]

    grid $parent.lbl_$role  -row $row -column 0 -sticky w -padx {6 2} -pady 4
    grid $parent.file_$role -row $row -column 1 -sticky ew -padx 4
    grid $parent.imp_$role  -row $row -column 2 -padx 1
    grid $parent.clr_$role  -row $row -column 3 -padx {1 6}
}

proc assets_ed::_import {kind role} {
    if {$kind eq "sprites"} {
        set types {{"PNG Images" .png} {"All Files" *}}
    } elseif {$role eq "music"} {
        set types {{"Tracker Music" .xm} {"All Files" *}}
    } else {
        set types {{"WAV Audio" .wav} {"All Files" *}}
    }
    set path [tk_getOpenFile -title "Import asset for $role" -filetypes $types]
    if {$path eq ""} return
    project::set_asset $kind $role $path
    _refresh_row $kind $role
    catch { app::status "Bound $role → [file tail $path]" }
    catch { app::_update_title }
}

proc assets_ed::_clear {kind role} {
    project::set_asset $kind $role ""
    _refresh_row $kind $role
    catch { app::_update_title }
}

# Populate every row from the current document.
proc assets_ed::load_doc {doc} {
    foreach {role _} [_sprite_roles] { _refresh_row sprites $role }
    foreach {role _} [_audio_roles]  { _refresh_row audio   $role }
}

proc assets_ed::_refresh_row {kind role} {
    variable thumbs
    set path [project::get_asset $kind $role]

    # Find the row widgets via the labelframe paths under the assets tab.
    set base [_panel]
    if {$base eq ""} return
    if {$kind eq "sprites"} {
        set filelbl $base.spr.file_$role
        set cv      $base.spr.th_$role
    } else {
        set filelbl $base.aud.file_$role
        set cv      ""
    }
    if {![winfo exists $filelbl]} return

    if {$path eq ""} {
        $filelbl configure -text "(none)" -foreground #5a6478
        if {$cv ne "" && [winfo exists $cv]} { $cv delete all }
        return
    }

    $filelbl configure -text [file tail $path] -foreground #9fd2ff

    if {$cv ne "" && [winfo exists $cv]} {
        $cv delete all
        if {[info exists thumbs($role)]} { catch { image delete $thumbs($role) }; unset thumbs($role) }
        if {[catch {
            set orig [image create photo -file $path]
            set w [image width $orig]; set h [image height $orig]
            set s [expr {max(1, int(ceil(double(max($w,$h)) / 28.0)))}]
            set thumb [image create photo]
            $thumb copy $orig -subsample $s $s
            image delete $orig
            set thumbs($role) $thumb
            $cv create image 15 15 -image $thumb
        }]} {
            # Not a Tk-readable image (still a valid build asset) — show a chip.
            $cv create rectangle 6 6 24 24 -fill #2a3450 -outline #4a6080
            $cv create text 15 15 -text "IMG" -fill #88aaff -font {TkDefaultFont 6}
        }
    }
}

# Path of the assets panel frame, or "" if not built yet.
proc assets_ed::_panel {} {
    variable panel
    if {$panel ne "" && [winfo exists $panel]} { return $panel }
    return ""
}
