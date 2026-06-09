# widgets/prop_panel.tcl — generic property inspector grid
# Each row is a label + entry/spinbox/combobox etc.

namespace eval prop_panel {}

# Create a scrollable property panel inside $parent.
# Returns the inner frame where rows should be added.
proc prop_panel::create {parent} {
    set outer [ttk::frame $parent.propframe]
    set canvas [canvas $outer.cv -highlightthickness 0 -borderwidth 0]
    set vsb    [ttk::scrollbar $outer.vsb -orient vertical -command [list $canvas yview]]

    $canvas configure -yscrollcommand [list $vsb set]

    set inner [ttk::frame $canvas.inner]
    set win [$canvas create window 0 0 -anchor nw -window $inner]

    bind $inner <Configure> [list prop_panel::_resize $canvas $win]
    bind $canvas <Configure> [list prop_panel::_fit_width $canvas $win $inner]

    # Mouse-wheel scrolling
    bind $canvas <MouseWheel>    [list prop_panel::_scroll $canvas %D]
    bind $canvas <Button-4>      [list $canvas yview scroll -3 units]
    bind $canvas <Button-5>      [list $canvas yview scroll  3 units]

    grid $canvas $vsb -sticky nsew
    grid columnconfigure $outer 0 -weight 1
    grid rowconfigure    $outer 0 -weight 1

    pack $outer -fill both -expand 1
    return $inner
}

proc prop_panel::_resize {cv win} {
    set bbox [$cv bbox all]
    if {$bbox eq {}} return
    $cv configure -scrollregion $bbox
}

proc prop_panel::_fit_width {cv win inner} {
    set w [winfo width $cv]
    $cv itemconfigure $win -width $w
}

proc prop_panel::_scroll {cv delta} {
    if {$delta > 0} {
        $cv yview scroll -3 units
    } else {
        $cv yview scroll  3 units
    }
}

# Add a section header row.
proc prop_panel::add_section {inner label} {
    set row [llength [winfo children $inner]]
    ttk::separator $inner.sep$row -orient horizontal
    ttk::label $inner.hdr$row -text $label -font {TkDefaultFont 9 bold} \
        -foreground #aaccff
    grid $inner.sep$row -row [expr {$row*2}]   -columnspan 2 -sticky ew -pady {8 0}
    grid $inner.hdr$row -row [expr {$row*2+1}] -columnspan 2 -sticky w  -padx 6 -pady {2 4}
}

# Add a label + entry row. Returns the entry widget path.
proc prop_panel::add_entry {inner label varname} {
    set row [llength [winfo children $inner]]
    ttk::label $inner.lbl$row -text $label -anchor w
    ttk::entry $inner.ent$row -textvariable $varname
    grid $inner.lbl$row -row $row -column 0 -sticky w  -padx {6 2} -pady 2
    grid $inner.ent$row -row $row -column 1 -sticky ew -padx {2 6} -pady 2
    grid columnconfigure $inner 1 -weight 1
    return $inner.ent$row
}

# Add a label + spinbox row. Returns the spinbox widget path.
proc prop_panel::add_spin {inner label varname from to increment} {
    set row [llength [winfo children $inner]]
    ttk::label $inner.lbl$row -text $label -anchor w
    ttk::spinbox $inner.spn$row -textvariable $varname \
        -from $from -to $to -increment $increment -width 10
    grid $inner.lbl$row -row $row -column 0 -sticky w  -padx {6 2} -pady 2
    grid $inner.spn$row -row $row -column 1 -sticky ew -padx {2 6} -pady 2
    grid columnconfigure $inner 1 -weight 1
    return $inner.spn$row
}

# Add a label + combobox row. Returns the combobox widget path.
proc prop_panel::add_combo {inner label varname values} {
    set row [llength [winfo children $inner]]
    ttk::label $inner.lbl$row -text $label -anchor w
    ttk::combobox $inner.cmb$row -textvariable $varname \
        -values $values -state readonly -width 14
    grid $inner.lbl$row -row $row -column 0 -sticky w  -padx {6 2} -pady 2
    grid $inner.cmb$row -row $row -column 1 -sticky ew -padx {2 6} -pady 2
    grid columnconfigure $inner 1 -weight 1
    return $inner.cmb$row
}

# Add a label + checkbutton row.
proc prop_panel::add_check {inner label varname} {
    set row [llength [winfo children $inner]]
    ttk::label      $inner.lbl$row -text $label -anchor w
    ttk::checkbutton $inner.chk$row -variable $varname
    grid $inner.lbl$row -row $row -column 0 -sticky w  -padx {6 2} -pady 2
    grid $inner.chk$row -row $row -column 1 -sticky w  -padx {2 6} -pady 2
    return $inner.chk$row
}

# Add a label + read-only label value row.
proc prop_panel::add_readout {inner label text} {
    set row [llength [winfo children $inner]]
    ttk::label $inner.lbl$row -text $label    -anchor w
    ttk::label $inner.val$row -text $text     -anchor w -foreground #aaaaaa
    grid $inner.lbl$row -row $row -column 0 -sticky w  -padx {6 2} -pady 2
    grid $inner.val$row -row $row -column 1 -sticky w  -padx {2 6} -pady 2
}

# Clear all rows from the panel (for dynamic refresh).
proc prop_panel::clear {inner} {
    foreach w [winfo children $inner] { destroy $w }
}
