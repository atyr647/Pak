# editors/controls.tcl — controller mapping panel
#
# Each control is a read-only combobox showing a friendly label; the panel
# translates label <-> internal code (a_or_b, dpad, …) so the document stores
# stable codes while the UI never exposes raw identifiers.

namespace eval controls_ed {
    # label <-> code maps (ordered: code label code label …)
    variable JUMP {a "A button" b "B button" a_or_b "A or B" z "Z trigger"}
    variable MOVE {dpad "D-Pad" stick "Analog Stick" both "D-Pad + Stick"}
    variable RUN  {none "Off" z "Z trigger" r "R trigger" b "B button"}
}

# Return the list of display labels for a map.
proc controls_ed::_labels {mapname} {
    variable $mapname
    upvar 0 $mapname m
    set out {}
    foreach {code label} $m { lappend out $label }
    return $out
}
proc controls_ed::_code_to_label {mapname code} {
    variable $mapname
    upvar 0 $mapname m
    if {[dict exists $m $code]} { return [dict get $m $code] }
    return [lindex $m 1]
}
proc controls_ed::_label_to_code {mapname label} {
    variable $mapname
    upvar 0 $mapname m
    foreach {code l} $m { if {$l eq $label} { return $code } }
    return [lindex $m 0]
}

proc controls_ed::create {parent} {
    set f [ttk::frame $parent.controlsed]

    ttk::label $f.title -text "Controller" -font {TkDefaultFont 10 bold}
    ttk::separator $f.sep -orient horizontal
    grid $f.title -row 0 -columnspan 2 -sticky w  -padx 8 -pady {8 2}
    grid $f.sep   -row 1 -columnspan 2 -sticky ew -padx 8 -pady 4

    # Display vars hold labels; codes live in the document.
    set ::ctrl_jump_label [_code_to_label JUMP a_or_b]
    set ::ctrl_move_label [_code_to_label MOVE both]
    set ::ctrl_run_label  [_code_to_label RUN  none]
    set ::ctrl_run_mult   1.6

    # Jump button
    ttk::label $f.jlbl -text "Jump Button:" -anchor w
    ttk::combobox $f.jcmb -textvariable ::ctrl_jump_label -state readonly -width 16 \
        -values [_labels JUMP]
    ttk::label $f.jinfo -text "Which button makes the player jump" \
        -foreground #888888 -font {TkDefaultFont 8}
    grid $f.jlbl  -row 2 -column 0 -sticky w  -padx {8 2} -pady 4
    grid $f.jcmb  -row 2 -column 1 -sticky ew -padx {2 8} -pady 4
    grid $f.jinfo -row 3 -column 1 -sticky w  -padx {2 8} -pady {0 8}

    # Movement source
    ttk::label $f.mlbl -text "Movement:" -anchor w
    ttk::combobox $f.mcmb -textvariable ::ctrl_move_label -state readonly -width 16 \
        -values [_labels MOVE]
    ttk::label $f.minfo -text "Read the D-pad, analog stick, or both" \
        -foreground #888888 -font {TkDefaultFont 8}
    grid $f.mlbl  -row 4 -column 0 -sticky w  -padx {8 2} -pady 4
    grid $f.mcmb  -row 4 -column 1 -sticky ew -padx {2 8} -pady 4
    grid $f.minfo -row 5 -column 1 -sticky w  -padx {2 8} -pady {0 8}

    ttk::separator $f.sep2 -orient horizontal
    grid $f.sep2 -row 6 -columnspan 2 -sticky ew -padx 8 -pady 4

    ttk::label $f.rsub -text "Sprint (optional):" -font {TkDefaultFont 9 bold}
    grid $f.rsub -row 7 -columnspan 2 -sticky w -padx 8 -pady {4 0}

    # Run button
    ttk::label $f.rlbl -text "Run Button:" -anchor w
    ttk::combobox $f.rcmb -textvariable ::ctrl_run_label -state readonly -width 16 \
        -values [_labels RUN]
    ttk::label $f.rinfo -text "Hold to move faster (Off = no sprint)" \
        -foreground #888888 -font {TkDefaultFont 8}
    grid $f.rlbl  -row 8 -column 0 -sticky w  -padx {8 2} -pady 4
    grid $f.rcmb  -row 8 -column 1 -sticky ew -padx {2 8} -pady 4
    grid $f.rinfo -row 9 -column 1 -sticky w  -padx {2 8} -pady {0 8}

    # Run speed multiplier
    ttk::label $f.smlbl -text "Run Speed:" -anchor w
    set sf [ttk::frame $f.smfr]
    ttk::scale $sf.sc -from 1.1 -to 3.0 -orient horizontal -length 180 \
        -variable ::ctrl_run_mult \
        -command [list controls_ed::_on_mult]
    ttk::label $sf.val -textvariable ::ctrl_run_mult_disp -width 5
    pack $sf.sc $sf.val -side left -padx 3
    ttk::label $f.sminfo -text "× normal move speed when running" \
        -foreground #888888 -font {TkDefaultFont 8}
    grid $f.smlbl  -row 10 -column 0 -sticky w  -padx {8 2} -pady 4
    grid $f.smfr   -row 10 -column 1 -sticky w  -padx {2 8} -pady 4
    grid $f.sminfo -row 11 -column 1 -sticky w  -padx {2 8} -pady {0 8}

    set ::ctrl_run_mult_disp [format %.2f $::ctrl_run_mult]

    grid columnconfigure $f 1 -weight 1
    pack $f -fill both -expand 1
    return $f
}

proc controls_ed::_on_mult {args} {
    set ::ctrl_run_mult_disp [format %.2f $::ctrl_run_mult]
}

proc controls_ed::load_doc {doc} {
    if {![dict exists $doc controls]} return
    set c [dict get $doc controls]
    set ::ctrl_jump_label [_code_to_label JUMP [dict get $c jump_button]]
    set ::ctrl_move_label [_code_to_label MOVE [dict get $c move_input]]
    set ::ctrl_run_label  [_code_to_label RUN  [dict get $c run_button]]
    set ::ctrl_run_mult   [dict get $c run_mult]
    set ::ctrl_run_mult_disp [format %.2f $::ctrl_run_mult]
}

proc controls_ed::save_to_doc {} {
    project::set_field controls jump_button [_label_to_code JUMP $::ctrl_jump_label]
    project::set_field controls move_input  [_label_to_code MOVE $::ctrl_move_label]
    project::set_field controls run_button  [_label_to_code RUN  $::ctrl_run_label]
    project::set_field controls run_mult     [format %.2f $::ctrl_run_mult]
}
