#!/usr/bin/env wish
# PakStudio — zero-code N64 game development suite
# Entry point: sets up the main window, sources all modules, wires everything.

package require Tk

# ── Source modules ─────────────────────────────────────────────────────────────

set here [file dirname [file normalize [info script]]]

foreach f {
    app/project.tcl
    codegen/platformer.tcl
    app/codegen.tcl
    app/validate.tcl
    app/build.tcl
    widgets/log_panel.tcl
    widgets/prop_panel.tcl
    widgets/canvas_scroll.tcl
    editors/wizard.tcl
    editors/physics.tcl
    editors/entity.tcl
    editors/level.tcl
    editors/audio.tcl
    editors/save_editor.tcl
} {
    source [file join $here $f]
}

# ── Application state ─────────────────────────────────────────────────────────

namespace eval app {
    variable outdir    ""      ;# current build output directory
    variable log_widget ""     ;# log panel text widget
    variable build_running false
}

# ── Theme ──────────────────────────────────────────────────────────────────────

proc app::setup_theme {} {
    ttk::style theme use clam
    ttk::style configure . \
        -background #1e2433 -foreground #e0e0e0 \
        -fieldbackground #252d3f -selectbackground #2255aa \
        -troughcolor #151c2a -bordercolor #334466

    ttk::style configure TFrame       -background #1e2433
    ttk::style configure TLabel       -background #1e2433 -foreground #e0e0e0
    ttk::style configure TLabelframe  -background #1e2433 -foreground #aaccff
    ttk::style configure TButton      -background #2a3450 -foreground #e0e0e0 \
                                       -relief flat -padding {6 3}
    ttk::style map       TButton      -background {active #3a4a70 pressed #1a2440}
    ttk::style configure Toolbutton   -background #252d3f -foreground #c0c0c0 \
                                       -relief flat -padding {4 2}
    ttk::style map       Toolbutton   -background {active #334466 selected #2255aa}
    ttk::style configure TEntry       -fieldbackground #252d3f -foreground #e0e0e0 \
                                       -insertcolor #ffffff
    ttk::style configure TSpinbox     -fieldbackground #252d3f -foreground #e0e0e0
    ttk::style configure TCombobox    -fieldbackground #252d3f -foreground #e0e0e0
    ttk::style configure TNotebook    -background #1a2030
    ttk::style configure TNotebook.Tab -background #252d3f -foreground #a0a0a0 \
                                        -padding {10 4}
    ttk::style map TNotebook.Tab      -background {selected #1e2433} \
                                       -foreground {selected #ffffff}
    ttk::style configure TSeparator   -background #334466
    ttk::style configure TScrollbar   -background #252d3f -troughcolor #151c2a \
                                       -arrowcolor #a0a0a0

    # Accent (green build button)
    ttk::style configure Accent.TButton \
        -background #226633 -foreground #ffffff -padding {10 4}
    ttk::style map Accent.TButton \
        -background {active #2a8040 pressed #1a4422}

    # Danger (delete button)
    ttk::style configure Danger.TButton \
        -background #662222 -foreground #ffffff -padding {8 3}
    ttk::style map Danger.TButton \
        -background {active #883333 pressed #441111}
}

# ── Main window ────────────────────────────────────────────────────────────────

proc app::create_main_window {} {
    variable log_widget

    wm title    . "PakStudio — N64 Game Dev Suite"
    wm geometry . "1280x800"
    wm minsize  . 960 600

    # Icon (text fallback)
    catch { wm iconname . "PakStudio" }

    setup_theme

    # Menu bar
    _create_menu

    # Main layout: left sidebar | centre editor | right panel
    set pw [ttk::panedwindow . -orient horizontal]
    pack $pw -fill both -expand 1

    # Left: level list + tile palette
    set left [ttk::frame $pw.left -width 190]
    $pw add $left -weight 0
    _create_left_panel $left

    # Centre: notebook (level editor, physics, audio, rom settings)
    set centre [ttk::frame $pw.centre]
    $pw add $centre -weight 3
    _create_centre_panel $centre

    # Right: entity inspector
    set right [ttk::frame $pw.right -width 220]
    $pw add $right -weight 0
    _create_right_panel $right

    # Bottom: build log + status bar
    set bot [ttk::frame . -height 180]
    pack $bot -fill x -side bottom

    ttk::separator .sep_bot -orient horizontal
    pack .sep_bot -fill x -side bottom

    set log_widget [log_panel::create $bot]
    _create_status_bar
}

# ── Left panel (level list + tool help) ───────────────────────────────────────

proc app::_create_left_panel {f} {
    ttk::label $f.hdr -text "Levels" -font {TkDefaultFont 10 bold} \
        -foreground #88ccff
    pack $f.hdr -anchor w -padx 8 -pady {8 2}

    ttk::separator $f.sep -orient horizontal
    pack $f.sep -fill x -padx 8 -pady 4

    # Level listbox
    set lb [listbox $f.lb -selectmode single -bg #252d3f -fg #e0e0e0 \
        -selectbackground #2255aa -borderwidth 0 -highlightthickness 0 \
        -height 8 -font {TkDefaultFont 9}]
    pack $lb -fill x -padx 8

    bind $lb <<ListboxSelect>> [list app::_on_level_select $lb]

    set ::app_level_lb $lb

    set btnf [ttk::frame $f.btnf]
    ttk::button $btnf.add -text "+ Level" -command app::_add_level \
        -style Toolbutton
    ttk::button $btnf.del -text "- Level" -command app::_del_level \
        -style Toolbutton
    pack $btnf.add $btnf.del -side left -padx 2
    pack $btnf -anchor w -padx 8 -pady 4

    ttk::separator $f.sep2 -orient horizontal
    pack $f.sep2 -fill x -padx 8 -pady 8

    # Keyboard shortcut help
    ttk::label $f.help -text "Shortcuts\n  Q  Paint Tile\n  E  Erase\n  R  Place Object\n  S  Select Object\n  1/2/3  Tile Type\n  Scroll  Pan\n  +/-  Zoom" \
        -justify left -foreground #666666 -font {TkDefaultFont 8}
    pack $f.help -anchor w -padx 12 -pady 4
}

proc app::_on_level_select {lb} {
    set sel [$lb curselection]
    if {$sel eq {}} return
    set idx [lindex $sel 0]
    level_ed::load_doc [project::current_doc] $idx
}

proc app::_add_level {} {
    set idx [project::add_level]
    _refresh_level_list
    $::app_level_lb selection clear 0 end
    $::app_level_lb selection set $idx
    level_ed::load_doc [project::current_doc] $idx
}

proc app::_del_level {} {
    set sel [$::app_level_lb curselection]
    if {$sel eq {}} return
    set idx [lindex $sel 0]
    set doc [project::current_doc]
    set lvls [dict get $doc levels]
    if {[llength $lvls] <= 1} {
        tk_messageBox -title "Cannot Delete" \
            -message "A project must have at least one level." -icon warning
        return
    }
    set lvls [lreplace $lvls $idx $idx]
    project::set_field levels $lvls
    _refresh_level_list
    $::app_level_lb selection set 0
    level_ed::load_doc [project::current_doc] 0
}

proc app::_refresh_level_list {} {
    set lb $::app_level_lb
    $lb delete 0 end
    set doc [project::current_doc]
    set i 0
    foreach lvl [dict get $doc levels] {
        $lb insert end "  [expr {$i+1}]. [dict get $lvl name]"
        incr i
    }
}

# ── Centre panel (notebook: level | physics | audio | ROM) ────────────────────

proc app::_create_centre_panel {f} {
    set nb [ttk::notebook $f.nb]
    pack $nb -fill both -expand 1

    # ── Level Editor tab ──────────────────────────────────────────────────────
    set led [ttk::frame $nb.led]
    $nb add $led -text " Level Editor "
    level_ed::create $led \
        app::_on_level_changed \
        app::_on_object_selected

    # ── Physics tab ───────────────────────────────────────────────────────────
    set phy [ttk::frame $nb.phy]
    $nb add $phy -text " Physics "
    physics_ed::create $phy app::_on_physics_changed

    # ── Audio tab ─────────────────────────────────────────────────────────────
    set aud [ttk::frame $nb.aud]
    $nb add $aud -text " Audio "
    audio_ed::create $aud

    # ── ROM Settings tab ──────────────────────────────────────────────────────
    set rom [ttk::frame $nb.rom]
    $nb add $rom -text " ROM Settings "
    save_ed::create $rom

    # Sync settings panels to doc when switching tabs
    bind $nb <<NotebookTabChanged>> app::_on_tab_changed

    set ::app_centre_nb $nb
}

proc app::_on_tab_changed {} {
    set nb $::app_centre_nb
    set tab [$nb tab current -text]
    switch -glob $tab {
        "*Audio*"   { audio_ed::save_to_doc }
        "*ROM*"     { save_ed::save_to_doc  }
        "*Physics*" { physics_ed::save_to_doc }
    }
    _update_title
}

proc app::_on_level_changed {} {
    _update_title
}

proc app::_on_physics_changed {} {
    physics_ed::save_to_doc
    _update_title
}

proc app::_on_object_selected {lvl_idx obj_idx obj} {
    if {$obj eq {}} {
        entity_ed::deselect
    } else {
        entity_ed::select $lvl_idx $obj_idx $obj
    }
}

# ── Right panel (entity inspector) ────────────────────────────────────────────

proc app::_create_right_panel {f} {
    entity_ed::create $f app::_on_entity_changed
}

proc app::_on_entity_changed {} {
    level_ed::refresh
    _update_title
}

# ── Status bar ────────────────────────────────────────────────────────────────

proc app::_create_status_bar {} {
    set sb [ttk::frame . -relief flat]
    pack $sb -fill x -side bottom

    set ::app_status_lbl [ttk::label $sb.msg -text "Ready" \
        -foreground #888888 -anchor w]
    set ::app_status_pos [ttk::label $sb.pos -text "" \
        -foreground #666666 -width 20 -anchor e]
    pack $sb.msg -side left  -padx 8
    pack $sb.pos -side right -padx 8
}

proc app::status {msg} {
    set ::app_status_lbl ""
    $::app_status_lbl configure -text $msg
    update idletasks
}

# ── Menu bar ──────────────────────────────────────────────────────────────────

proc app::_create_menu {} {
    menu .mb
    . configure -menu .mb

    # File
    menu .mb.file -tearoff 0
    .mb add cascade -label "File" -menu .mb.file -underline 0
    .mb.file add command -label "New Project..."   -accelerator "Ctrl+N" \
        -command app::cmd_new
    .mb.file add command -label "Open Project..."  -accelerator "Ctrl+O" \
        -command app::cmd_open
    .mb.file add command -label "Save"             -accelerator "Ctrl+S" \
        -command app::cmd_save
    .mb.file add command -label "Save As..."       -accelerator "Ctrl+Shift+S" \
        -command app::cmd_save_as
    .mb.file add separator
    .mb.file add command -label "Exit"             -command app::cmd_exit

    # Build
    menu .mb.build -tearoff 0
    .mb add cascade -label "Build" -menu .mb.build -underline 0
    .mb.build add command -label "Build ROM"         -accelerator "F5" \
        -command app::cmd_build
    .mb.build add command -label "Run in Emulator"   -accelerator "F6" \
        -command app::cmd_run
    .mb.build add separator
    .mb.build add command -label "Validate (pak check)" \
        -command app::cmd_validate

    # Help
    menu .mb.help -tearoff 0
    .mb add cascade -label "Help" -menu .mb.help -underline 0
    .mb.help add command -label "Keyboard Shortcuts" -command app::_show_shortcuts
    .mb.help add command -label "About PakStudio"    -command app::_show_about

    # Accelerators
    bind . <Control-n> app::cmd_new
    bind . <Control-o> app::cmd_open
    bind . <Control-s> app::cmd_save
    bind . <Control-S> app::cmd_save_as
    bind . <F5>        app::cmd_build
    bind . <F6>        app::cmd_run
}

# ── Commands ──────────────────────────────────────────────────────────────────

proc app::cmd_new {} {
    if {[project::is_dirty]} {
        set r [tk_messageBox -title "Unsaved Changes" \
            -message "Save current project before creating a new one?" \
            -type yesnocancel -icon question]
        if {$r eq "cancel"} return
        if {$r eq "yes"}    { cmd_save }
    }
    set doc [wizard::show .]
    if {$doc eq {}} return
    _load_doc $doc
}

proc app::cmd_open {} {
    if {[project::is_dirty]} {
        set r [tk_messageBox -title "Unsaved Changes" \
            -message "Save before opening?" -type yesnocancel -icon question]
        if {$r eq "cancel"} return
        if {$r eq "yes"}    { cmd_save }
    }
    set path [tk_getOpenFile -title "Open Project" \
        -filetypes {{"PakStudio Projects" .pakstudio} {"All Files" *}}]
    if {$path eq ""} return
    set doc [project::load_from $path]
    _load_doc $doc
}

proc app::cmd_save {} {
    set path [project::current_path]
    if {$path eq ""} { cmd_save_as; return }
    # Flush panel state into doc first
    audio_ed::save_to_doc
    save_ed::save_to_doc
    physics_ed::save_to_doc
    project::save_to $path
    status "Saved: $path"
    _update_title
}

proc app::cmd_save_as {} {
    set path [tk_getSaveFile -title "Save Project As" \
        -filetypes {{"PakStudio Projects" .pakstudio} {"All Files" *}} \
        -defaultextension .pakstudio]
    if {$path eq ""} return
    audio_ed::save_to_doc
    save_ed::save_to_doc
    physics_ed::save_to_doc
    project::save_to $path
    status "Saved: $path"
    _update_title
}

proc app::cmd_exit {} {
    if {[project::is_dirty]} {
        set r [tk_messageBox -title "Unsaved Changes" \
            -message "Save before exiting?" -type yesnocancel -icon question]
        if {$r eq "cancel"} return
        if {$r eq "yes"}    { cmd_save }
    }
    exit 0
}

proc app::cmd_validate {} {
    variable log_widget
    log_panel::clear $log_widget
    log_panel::append $log_widget "--- Running pak check ---"
    audio_ed::save_to_doc
    save_ed::save_to_doc
    physics_ed::save_to_doc
    set doc [project::current_doc]
    set result [validate::check_doc $doc]
    if {[dict get $result ok]} {
        log_panel::append $log_widget "  PASS: pak check clean"
        status "Validation passed"
    } else {
        log_panel::append $log_widget "ERROR: pak check failed"
        foreach line [split [dict get $result errors] "\n"] {
            if {$line ne ""} { log_panel::append $log_widget "  $line" }
        }
        status "Validation failed — see log"
    }
}

proc app::cmd_build {} {
    variable log_widget
    variable build_running
    variable outdir
    if {$build_running} return

    audio_ed::save_to_doc
    save_ed::save_to_doc
    physics_ed::save_to_doc

    # Ask for output directory if not set
    if {$outdir eq "" || ![file isdirectory $outdir]} {
        set outdir [tk_chooseDirectory \
            -title "Choose Build Output Directory" \
            -mustexist 0]
        if {$outdir eq ""} return
        file mkdir $outdir
    }

    log_panel::clear $log_widget
    set build_running true
    status "Building..."

    set doc [project::current_doc]
    set cb  [list log_panel::append $log_widget]

    # Run in a coroutine so the UI stays responsive
    coroutine build_coro app::_run_build $doc $outdir $cb
}

proc app::_run_build {doc outdir cb} {
    variable build_running
    set result [build::run $doc $outdir $cb]
    set build_running false
    if {[dict get $result ok]} {
        status "Build succeeded"
        if {[dict exists $result rom]} {
            set rom [dict get $result rom]
            log_panel::append $::app::log_widget "ROM: $rom"
            set r [tk_messageBox -title "Build Complete" \
                -message "ROM built: $rom\n\nRun in emulator?" \
                -type yesno -icon info]
            if {$r eq "yes"} { cmd_run }
        }
    } else {
        status "Build FAILED — see log"
    }
}

proc app::cmd_run {} {
    variable outdir
    variable log_widget
    if {$outdir eq "" || ![file isdirectory $outdir]} {
        status "Build first before running"
        return
    }
    set cb [list log_panel::append $log_widget]
    log_panel::append $log_widget "--- Launching emulator ---"
    after 0 [list build::run_rom $outdir $cb]
}

# ── Internal helpers ──────────────────────────────────────────────────────────

proc app::_load_doc {doc} {
    physics_ed::load_doc $doc
    audio_ed::load_doc   $doc
    save_ed::load_doc    $doc
    _refresh_level_list
    $::app_level_lb selection clear 0 end
    $::app_level_lb selection set 0
    level_ed::load_doc $doc 0
    entity_ed::deselect
    _update_title
    status "Project loaded"
}

proc app::_update_title {} {
    set name [dict get [project::current_doc] meta name]
    set path [project::current_path]
    set dirty [expr {[project::is_dirty] ? " *" : ""}]
    if {$path ne ""} {
        wm title . "PakStudio — $name$dirty  ($path)"
    } else {
        wm title . "PakStudio — $name$dirty  [unsaved]"
    }
}

proc app::_show_shortcuts {} {
    set w [toplevel .shortcuts]
    wm title $w "Keyboard Shortcuts"
    wm transient $w .
    ttk::label $w.txt -text \
"Ctrl+N    New project
Ctrl+O    Open project
Ctrl+S    Save
F5        Build ROM
F6        Run in emulator

Level Editor:
  Q        Paint tile tool
  E        Eraser tool
  R        Place object
  S        Select object
  1        Solid tile
  2        One-way platform
  3        Hazard tile
  +/-      Zoom in/out
  Scroll   Pan canvas" \
        -justify left -font {TkFixedFont 10} -padding 16
    pack $w.txt
    ttk::button $w.ok -text "Close" -command [list destroy $w]
    pack $w.ok -pady 8
}

proc app::_show_about {} {
    tk_messageBox -title "About PakStudio" \
        -message "PakStudio — Zero-Code N64 Game Development Suite\n\nBuilt on the Pak language & N64 LibDragon.\n\nCreate 2D platformers today,\n3D racers and FPS coming soon." \
        -icon info
}

# ── Launch ────────────────────────────────────────────────────────────────────

app::create_main_window

# Show new project wizard on startup if no args given
if {$argc == 0} {
    after 200 {
        set doc [wizard::show .]
        if {$doc ne {}} {
            app::_load_doc $doc
        } else {
            # Create a default project silently so the UI isn't blank
            project::new platformer "My Platformer"
            app::_load_doc [project::current_doc]
        }
    }
} else {
    # Open file from command line
    set fpath [lindex $argv 0]
    if {[file exists $fpath]} {
        set doc [project::load_from $fpath]
        app::_load_doc $doc
    }
}
