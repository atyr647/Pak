# editors/audio.tcl — audio event file assignment panel

namespace eval audio_ed {}

proc audio_ed::create {parent} {
    set f [ttk::frame $parent.auded]

    ttk::label $f.title -text "Audio Events" -font {TkDefaultFont 10 bold}
    ttk::separator $f.sep -orient horizontal
    ttk::label $f.info \
        -text "Assign audio files (.wav) to game events.\nLeave blank for no sound on that event." \
        -justify left -foreground #888888 -wraplength 260

    grid $f.title -row 0 -columnspan 3 -sticky w  -padx 8 -pady {8 2}
    grid $f.sep   -row 1 -columnspan 3 -sticky ew -padx 8 -pady 4
    grid $f.info  -row 2 -columnspan 3 -sticky w  -padx 8 -pady {0 8}

    set events {
        jump       "Jump"
        land       "Land"
        coin       "Collect Coin"
        hurt       "Take Damage"
        death      "Die"
        checkpoint "Checkpoint"
        victory    "Level Clear"
        bg_music   "Background Music"
    }

    set row 3
    foreach {key lbl} $events {
        set vname ::audio_$key
        set ::audio_$key ""

        ttk::label $f.lbl_$key -text "${lbl}:" -anchor w -width 18
        ttk::entry $f.ent_$key -textvariable $vname -width 20
        ttk::button $f.btn_$key -text "..." -width 3 \
            -command [list audio_ed::_browse $f.ent_$key $vname]

        grid $f.lbl_$key -row $row -column 0 -sticky w  -padx {8 2} -pady 2
        grid $f.ent_$key -row $row -column 1 -sticky ew -padx 1     -pady 2
        grid $f.btn_$key -row $row -column 2 -sticky w  -padx {1 8} -pady 2
        incr row
    }
    grid columnconfigure $f 1 -weight 1

    pack $f -fill both -expand 1
    return $f
}

proc audio_ed::_browse {ent vname} {
    set path [tk_getOpenFile -title "Select Audio File" \
        -filetypes {{"WAV Files" .wav} {"All Files" *}}]
    if {$path ne ""} {
        set $vname $path
    }
}

proc audio_ed::load_doc {doc} {
    if {![dict exists $doc audio events]} return
    set evts [dict get $doc audio events]
    foreach key {jump land coin hurt death checkpoint victory bg_music} {
        if {[dict exists $evts $key]} {
            set ::audio_$key [dict get $evts $key]
        }
    }
}

proc audio_ed::save_to_doc {} {
    foreach key {jump land coin hurt death checkpoint victory bg_music} {
        project::set_field audio events $key [set ::audio_$key]
    }
}
