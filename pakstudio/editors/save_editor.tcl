# editors/save_editor.tcl — save type & ROM settings panel

namespace eval save_ed {}

proc save_ed::create {parent} {
    set f [ttk::frame $parent.saveed]

    ttk::label $f.title -text "ROM Settings" -font {TkDefaultFont 10 bold}
    ttk::separator $f.sep -orient horizontal

    grid $f.title -row 0 -columnspan 2 -sticky w  -padx 8 -pady {8 2}
    grid $f.sep   -row 1 -columnspan 2 -sticky ew -padx 8 -pady 4

    set ::save_type        "none"
    set ::save_rom_title   ""
    set ::save_resolution  "320x240"
    set ::save_bit_depth   16
    set ::save_framebuffers 3

    # Save type
    ttk::label $f.stlbl -text "Save Type:" -anchor w
    set save_types {none eeprom4k eeprom16k sram flashram}
    ttk::combobox $f.stcmb -textvariable ::save_type -values $save_types \
        -state readonly -width 14
    ttk::label $f.stinfo -text "Note: EEPROM = 8-byte blocks" \
        -foreground #888888 -font {TkDefaultFont 8}

    grid $f.stlbl  -row 2 -column 0 -sticky w  -padx {8 2} -pady 4
    grid $f.stcmb  -row 2 -column 1 -sticky ew -padx {2 8} -pady 4
    grid $f.stinfo -row 3 -column 1 -sticky w  -padx {2 8} -pady {0 8}

    ttk::separator $f.sep2 -orient horizontal
    grid $f.sep2 -row 4 -columnspan 2 -sticky ew -padx 8 -pady 4

    ttk::label $f.rtsub -text "ROM Title Card:" -font {TkDefaultFont 9 bold}
    grid $f.rtsub -row 5 -columnspan 2 -sticky w -padx 8 -pady {4 0}

    ttk::label $f.rtlbl -text "Title (max 20):" -anchor w
    ttk::entry $f.rtent -textvariable ::save_rom_title -width 22
    ttk::label $f.rtlim -text "Displayed on the N64 boot screen" \
        -foreground #888888 -font {TkDefaultFont 8}

    grid $f.rtlbl -row 6 -column 0 -sticky w  -padx {8 2} -pady 2
    grid $f.rtent -row 6 -column 1 -sticky ew -padx {2 8} -pady 2
    grid $f.rtlim -row 7 -column 1 -sticky w  -padx {2 8} -pady {0 8}

    ttk::separator $f.sep3 -orient horizontal
    grid $f.sep3 -row 8 -columnspan 2 -sticky ew -padx 8 -pady 4

    ttk::label $f.dissub -text "Display:" -font {TkDefaultFont 9 bold}
    grid $f.dissub -row 9 -columnspan 2 -sticky w -padx 8 -pady {4 0}

    foreach {key lbl values var row} {
        resolution   "Resolution:"   {"320x240" "640x480"} ::save_resolution   10
        bit_depth    "Bit Depth:"    {16 32}               ::save_bit_depth    11
        framebuffers "Framebuffers:" {2 3}                 ::save_framebuffers 12
    } {
        ttk::label $f.lbl_$key -text $lbl -anchor w
        ttk::combobox $f.cmb_$key -textvariable $var -values $values \
            -state readonly -width 10
        grid $f.lbl_$key -row $row -column 0 -sticky w  -padx {8 2} -pady 2
        grid $f.cmb_$key -row $row -column 1 -sticky ew -padx {2 8} -pady 2
    }

    grid columnconfigure $f 1 -weight 1
    pack $f -fill both -expand 1
    return $f
}

proc save_ed::load_doc {doc} {
    set s [dict get $doc settings]
    set ::save_type         [dict get $s save_type]
    set ::save_resolution   [dict get $s resolution]
    set ::save_bit_depth    [dict get $s bit_depth]
    set ::save_framebuffers [dict get $s framebuffers]
    set ::save_rom_title    [dict get $doc meta rom_title]
}

proc save_ed::save_to_doc {} {
    project::set_field settings save_type    $::save_type
    project::set_field settings resolution   $::save_resolution
    project::set_field settings bit_depth    $::save_bit_depth
    project::set_field settings framebuffers $::save_framebuffers
    project::set_field meta rom_title        $::save_rom_title
}
