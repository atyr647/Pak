# editors/entity.tcl — entity/object inspector panel

namespace eval entity_ed {
    variable selected_obj {}   ;# dict of the selected object
    variable selected_idx -1   ;# index in level's objects list
    variable selected_lvl  0   ;# level index
    variable on_change     {}
}

# Create entity inspector panel inside $parent.
# on_change called when user edits an object property.
proc entity_ed::create {parent on_change_cb} {
    variable on_change
    set on_change $on_change_cb

    set f [ttk::frame $parent.entinsp]

    ttk::label $f.title -text "Selected Object" -font {TkDefaultFont 10 bold}
    pack $f.title -anchor w -padx 8 -pady {8 2}

    ttk::separator $f.sep -orient horizontal
    pack $f.sep -fill x -padx 8 -pady 4

    # No-selection placeholder
    set ::entinsp_placeholder "No object selected.\nClick an object in the level to inspect it."
    ttk::label $f.none -textvariable ::entinsp_placeholder \
        -justify center -foreground #666666 -wraplength 200
    pack $f.none -expand 1 -pady 40

    # Detail frame (hidden until an object is selected)
    set df [ttk::frame $f.detail]
    variable detail_frame $df

    ttk::label $df.type_lbl -text "Type:" -anchor w
    ttk::label $df.type_val -textvariable ::entinsp_type -foreground #88ccff
    grid $df.type_lbl $df.type_val -sticky w -padx 8 -pady 3
    grid columnconfigure $df 1 -weight 1

    foreach {key lbl} {x "X (tiles):" y "Y (tiles):"} {
        ttk::label $df.lbl_$key -text $lbl -anchor w
        ttk::spinbox $df.spn_$key -textvariable ::entinsp_$key \
            -from 0 -to 512 -increment 1 -width 8 \
            -command [list entity_ed::_commit]
        bind $df.spn_$key <Return>   [list entity_ed::_commit]
        bind $df.spn_$key <FocusOut> [list entity_ed::_commit]
        set row [expr {[llength [grid slaves $df]] / 2}]
        grid $df.lbl_$key -row $row -column 0 -sticky w -padx 8 -pady 3
        grid $df.spn_$key -row $row -column 1 -sticky w -padx 8 -pady 3
    }

    ttk::separator $df.sep2 -orient horizontal
    set row [expr {[llength [grid slaves $df]] / 2}]
    grid $df.sep2 -row $row -columnspan 2 -sticky ew -padx 8 -pady 6

    ttk::button $df.del -text "Delete Object" -style Danger.TButton \
        -command [list entity_ed::_delete]
    set row [expr {[llength [grid slaves $df]] / 2}]
    grid $df.del -row $row -columnspan 2 -padx 8 -pady 4

    pack $f -fill both -expand 1
    return $f
}

# Select an object for editing.
proc entity_ed::select {lvl_idx obj_idx obj} {
    variable selected_obj  $obj
    variable selected_idx  $obj_idx
    variable selected_lvl  $lvl_idx
    variable detail_frame

    set ::entinsp_type [dict get $obj type]
    set ::entinsp_x    [dict get $obj x]
    set ::entinsp_y    [dict get $obj y]
    set ::entinsp_placeholder ""

    # Show detail frame
    pack forget [winfo parent $detail_frame].none
    pack $detail_frame -fill both -expand 1 -padx 8
}

# Clear selection.
proc entity_ed::deselect {} {
    variable selected_idx
    variable detail_frame
    set selected_idx -1
    set ::entinsp_placeholder "No object selected.\nClick an object in the level to inspect it."
    catch { pack forget $detail_frame }
    catch { pack [winfo parent $detail_frame].none -expand 1 -pady 40 }
}

proc entity_ed::_commit {} {
    variable selected_idx
    variable selected_lvl
    variable on_change
    if {$selected_idx < 0} return
    set lvl  [project::get_level $selected_lvl]
    set objs [dict get $lvl objects]
    set obj  [lindex $objs $selected_idx]
    dict set obj x $::entinsp_x
    dict set obj y $::entinsp_y
    # Write back
    dict set objs $selected_idx $obj
    # Can't use set_tile; patch manually via project namespace
    set doc [project::current_doc]
    set levels [dict get $doc levels]
    set lvl [lindex $levels $selected_lvl]
    dict set lvl objects $objs
    lset levels $selected_lvl $lvl
    project::set_field levels $levels
    {*}$on_change
}

proc entity_ed::_delete {} {
    variable selected_idx
    variable selected_lvl
    variable on_change
    if {$selected_idx < 0} return
    project::remove_object $selected_lvl $selected_idx
    deselect
    {*}$on_change
}
