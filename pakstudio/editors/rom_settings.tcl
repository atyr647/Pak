namespace eval rom_ed {
    variable _title "MY GAME"
    variable _region NTSC
    variable _save_type EEPROM4K
    variable _debug 0
    variable _tv_mode progressive
}

proc rom_ed::create {parent} {
    set f [ttk::frame $parent -padding 20]
    pack $f -fill both -expand 1

    ttk::label $f.title_lbl -text "ROM Settings" -font {TkDefaultFont 13 bold}
    grid $f.title_lbl -columnspan 2 -sticky w -pady {0 15}

    set row 1

    # ROM Title
    ttk::label $f.lbl_title -text "ROM Title (max 20 chars):" -anchor e
    ttk::entry $f.ent_title -textvariable rom_ed::_title -width 22 -validate key \
        -validatecommand {expr {[string length %P] <= 20}}
    grid $f.lbl_title $f.ent_title -row $row -padx 4 -pady 6 -sticky w
    incr row

    # Region
    ttk::label $f.lbl_region -text "Region:" -anchor e
    ttk::combobox $f.cb_region -textvariable rom_ed::_region -width 12 \
        -state readonly -values {NTSC PAL MPAL}
    grid $f.lbl_region $f.cb_region -row $row -padx 4 -pady 6 -sticky w
    incr row

    # Save Type
    ttk::label $f.lbl_save -text "Save Type:" -anchor e
    ttk::combobox $f.cb_save -textvariable rom_ed::_save_type -width 12 \
        -state readonly -values {None EEPROM4K EEPROM16K SRAM FLASHRAM}
    grid $f.lbl_save $f.cb_save -row $row -padx 4 -pady 6 -sticky w
    incr row

    # TV Mode
    ttk::label $f.lbl_tv -text "TV Mode:" -anchor e
    ttk::combobox $f.cb_tv -textvariable rom_ed::_tv_mode -width 14 \
        -state readonly -values {progressive interlaced}
    grid $f.lbl_tv $f.cb_tv -row $row -padx 4 -pady 6 -sticky w
    incr row

    # Debug
    ttk::checkbutton $f.chk_debug -text "Enable debug output (USB/UART)" \
        -variable rom_ed::_debug
    grid $f.chk_debug - -row $row -padx 4 -pady 6 -sticky w
    incr row

    # Bind changes
    foreach w {ent_title cb_region cb_save cb_tv chk_debug} {
        bind $f.$w <<Modified>> { after idle rom_ed::_push_to_doc }
        bind $f.$w <FocusOut>   { rom_ed::_push_to_doc }
    }
    bind $f.cb_region <<ComboboxSelected>> { rom_ed::_push_to_doc }
    bind $f.cb_save   <<ComboboxSelected>> { rom_ed::_push_to_doc }
    bind $f.cb_tv     <<ComboboxSelected>> { rom_ed::_push_to_doc }
    bind $f.chk_debug <ButtonRelease-1>    { after idle rom_ed::_push_to_doc }

    return $f
}

proc rom_ed::_push_to_doc {} {
    set doc [project::current_doc]
    if {![dict exists $doc platformer]} return
    dict set doc platformer rom title     [string toupper $rom_ed::_title]
    dict set doc platformer rom region    $rom_ed::_region
    dict set doc platformer rom save_type $rom_ed::_save_type
    dict set doc platformer rom tv_mode   $rom_ed::_tv_mode
    dict set doc platformer rom debug     $rom_ed::_debug
    project::set_doc $doc
}

proc rom_ed::load_doc {doc} {
    if {![dict exists $doc platformer rom]} return
    set r [dict get $doc platformer rom]
    if {[dict exists $r title]}     { set rom_ed::_title     [dict get $r title] }
    if {[dict exists $r region]}    { set rom_ed::_region    [dict get $r region] }
    if {[dict exists $r save_type]} { set rom_ed::_save_type [dict get $r save_type] }
    if {[dict exists $r tv_mode]}   { set rom_ed::_tv_mode   [dict get $r tv_mode] }
    if {[dict exists $r debug]}     { set rom_ed::_debug     [dict get $r debug] }
}

proc rom_ed::save_to_doc {} {
    _push_to_doc
}
